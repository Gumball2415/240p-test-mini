#!/usr/bin/env python3
"""
Help file compressor for 144p Test Suite
Copyright 2015, 2023 Damian Yerrick

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
"""
import sys, os, argparse, string
from vwfbuild import rgbasm_bytearray
from collections import Counter
from itertools import chain

# Find common tools
commontoolspath = os.path.normpath(os.path.join(
    os.path.dirname(sys.argv[0]), "..", "..", "common", "tools"
))
sys.path.append(commontoolspath)
from parsepages import lines_to_docs
from dtefe import dte_compress
import cp144p  # registers encoding "cp144p" used by GB and GBA suites

# must match src/undte.z80
DTE_MIN_CODEUNIT = 128
FIRST_PRINTABLE_CU = 24

# Reencoding given a replacements table #############################

# The compressed text that jroatch's encoder emits isn't optimal and
# can be improved, even with a greedy algorithm.

def dtedec(s, replacements):
    """Decode a byteslike using a DTE table."""
    stack = bytearray(reversed(s))
    out = bytearray()
    while stack:
        c = stack.pop()
        if c < DTE_MIN_CODEUNIT:
            out.append(c)
        else:
            stack.extend(reversed(replacements[c - DTE_MIN_CODEUNIT]))
    return bytes(out)

def dtemakeenctable(replacements):
    """Make a greedy encoding table for DTE"""
    encs = [(dtedec(r, replacements), bytes([i + DTE_MIN_CODEUNIT]))
            for i, r in enumerate(replacements)]
    # put longer replacement first (greedy algorithm)
    encs.sort(key=lambda x: len(x[0]), reverse=True)
    return encs

def dteenc(s, enctable):
    for needle, replacement in enctable:
        s = s.replace(needle, replacement)
    return s

def dtereenc(txt, oldenc, enctable, printoldbetter=False):
    """Encode to DTE then keep the shorter of corresponding lines.

Neither jroatch's algorithm nor my algorithm is optimal.
So I compare them line by line and take whatever's better.
"""
    newenc = dteenc(txt, enctable).split(b"\n")
    oldenc = oldenc.split(b"\n")
    if printoldbetter: txt = txt.split(b"\n")
    bestenc = []
    for u, o, n in zip(txt, oldenc, newenc):
        if len(o) < len(n):
            if printoldbetter:
                print(u.decode("cp144p"), file=sys.stderr)
                print("jr-dte:", o.hex(), file=sys.stderr)
                print("greedy:", n.hex(), file=sys.stderr)
            bestenc.append(o)
        else:
            bestenc.append(n)
    return b"\n".join(bestenc)

# Encoding for RGBDS assembler ######################################

def rgbasm_escape_bytes(blo):
    """Encode an iterable of ints in 0-255, mostly ASCII, for rgbasm db statement"""
    runs = []
    for c in blo:
        if 32 <= c <= 126 and c != 34:
            if runs and isinstance(runs[-1], bytearray):
                runs[-1].append(c)
            else:
                runs.append(bytearray([c]))
        else:
            runs.append(c)
    runs = ['"%s"' % r.decode('ascii')
            if isinstance(r, bytearray)
            else '%d' % r
            for r in runs]
    return ','.join(runs)

def render_help(docs, defines=None, verbose=False, inputlog=None):
    lines = ["""
; Help data generated with paginate_help.py - do not edit

section "helppages",ROMX
"""]
    lines.extend('helpsect_%s equ %d' % (doc[1], i)
                 for i, doc in enumerate(docs))
    lines.extend('export helpsect_%s' % (doc[1])
                 for i, doc in enumerate(docs))

    defines = dict(defines or {})
    allpages, cumul_pages = [], [0]
    for doc in docs:
        for page in doc[-1]:
            page = [string.Template(line).safe_substitute(defines)
                    for line in page]
            page = b"\x0A".join(line.encode("cp144p") for line in page)
            allpages.append(page + b"\x00")
        assert len(allpages) == cumul_pages[-1] + len(doc[-1])
        cumul_pages.append(len(allpages))

    # DTE compress titles and bodies
    helptitledata = [doc[0].encode("cp144p") for doc in docs]
    dtepages = list(allpages)
    dtepages.extend(helptitledata)
    oldsize = sum(len(x) for x in dtepages)
    result = dte_compress(dtepages, mincodeunit=DTE_MIN_CODEUNIT,
                          compctrl=FIRST_PRINTABLE_CU, inputlog=inputlog)
    dtepages, replacements, pairfreqs = result
    newsize = 2 * len(replacements) + sum(len(x) for x in dtepages)

    # Try an alternate encoder with the same dictionary
    reenctable = dtemakeenctable(replacements)
    greedysaved = 0
    for i, txt in enumerate(chain(allpages, helptitledata)):
        newpage = dtereenc(txt, dtepages[i], reenctable,
                           printoldbetter=inputlog or verbose)
        assert dtedec(newpage, replacements) == txt
        svd = len(dtepages[i]) - len(newpage)
        bytes_pl = "bytes" if abs(svd) != 1 else "byte"
        if svd > 0:
            if inputlog:
                loglines = [
                    "For the text", "", txt.decode("cp144p"), "",
                    "jroatch dte gives", dtepages[i].hex(),
                    "while greedy recompression saves %d %s" % (svd, bytes_pl),
                    newpage.hex(), ""
                ]
                print("\n".join(loglines), file=sys.stderr)
            dtepages[i] = newpage
            greedysaved += svd

    newnewsize = 2 * len(replacements) + sum(len(x) for x in dtepages)
    assert newnewsize == newsize - greedysaved

    # Put most commonly repeated lines in/after title table
    uniquelines = Counter()
    linecount = 0
    for page in dtepages:
        page = page.rstrip(b'\x00').split(b"\n")
        uniquelines.update(x for x in page if x)
    repeatedlines = {k for k, v in uniquelines.items() if v > 1}

    # Document titles come last
    helptitledata = dtepages[len(allpages):]
    del dtepages[len(allpages):]

    # Append repeated lines that aren't titles as if they were
    repeatedlines.difference_update(helptitledata)
    helptitledata.extend(repeatedlines)
    lines.append('helptitles::')
    lines.extend('  dw helptitle_%d' % i for i in range(len(helptitledata)))

    # Failed experiment to see if I could optimize suffixes
    # Didn't save much
    endswithtest = [
        (i, j) for i in helptitledata for j in helptitledata
        if i.endswith(j) and i != j
    ]
    if False:
        for i, j in endswithtest:
            print("%s ends with %s"
                  % (dtedec(i, replacements).decode("cp144p"),
                     dtedec(j, replacements).decode("cp144p")),
                  file=sys.stderr)

    # Match lines of text to document titles
    # (reuse of title of document id 0 is currently buggy)
    helptitleinv = {t: idx for idx, t in enumerate(helptitledata) if idx}

    # Replace lines matching helplines with references
    for i, page in enumerate(dtepages):
        page = page.rstrip(b'\x00').split(b"\n")
        newpage = bytearray()
        for j, line in enumerate(page):
            helptitleid = helptitleinv.get(line)
            if helptitleid is not None:
                newpage.extend([0x0F, helptitleid])
            else:
                newpage.extend(line)
                if j != len(page) - 1:
                    newpage.append(0x0A)
        newpage.append(0)
        dtepages[i] = bytes(newpage)

    code_usage = Counter()
    for pagenum, page in enumerate(dtepages):
        lines.append("helppage_%03d:" % pagenum)
        lines.append("  db %s" % rgbasm_escape_bytes(page))
        code_usage.update(page)  # Make histogram

    lines.extend('helptitle_%d: db %s,0'
                 % (i, rgbasm_escape_bytes(dtetitle))
                 for i, dtetitle in enumerate(helptitledata))
    lines.append('help_cumul_pages::')
    lines.append(rgbasm_bytearray(cumul_pages))
    lines.append('HELP_NUM_PAGES equ %d' % cumul_pages[-1])
    lines.append('HELP_NUM_SECTS equ %d' % len(docs))
    lines.append('export HELP_NUM_PAGES, HELP_NUM_SECTS')
    lines.append('helppages::')
    lines.extend('  dw helppage_%03d' % i for i in range(cumul_pages[-1]))
    lines.append("dte_replacements::")
    lines.extend("  db %s" % rgbasm_escape_bytes(r) for r in replacements)

    lines.append("; compressed help from %d bytes to %d bytes"
                 % (oldsize, newsize))
    if greedysaved > 0:
        lines.append("; the greedy reencoder saved %d more making %d bytes"
                     % (greedysaved, newnewsize))

    if verbose:
        for i, r in enumerate(replacements):
            out = dtedec(r, replacements).decode("cp144p")
            lines.append("; $%02X: %s (%d)"
                         % (i + DTE_MIN_CODEUNIT, repr(out),
                            code_usage.get(i + DTE_MIN_CODEUNIT, 0)))
        lines.append("; Repeated lines that aren't document titles")
        print(repeatedlines, file=sys.stderr)
        lines.extend(
            "; %s (%d)"
            % (dtedec(r, replacements).decode("cp144p"), uniquelines[r])
            for r in repeatedlines
        )

    lines.append("")
    return "\n".join(lines)

def parse_define(s):
    kv = s.split('=', 1)
    if len(kv) < 2:
        raise ValueError("expected KEY=value; got %s" % s)
    return tuple(kv)

def parse_argv(argv):
    p = argparse.ArgumentParser()
    p.add_argument("INFILE")
    p.add_argument("-o", "--output", metavar="OUTFILE", default='-',
                   help="write asm output here instead of standard output")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="write replacements")
    p.add_argument("-D", metavar="WORD=value",
                   type=parse_define, dest="defines", nargs='*',
                   help="define a word for $WORD or ${WORD} substitution")
    p.add_argument("--dte-input-log",
                   help="store input to jroatch's DTE here")
    return p.parse_args(argv[1:])

def main(argv=None):
    args = parse_argv(argv or sys.argv)

    with open(args.INFILE, 'r', encoding="utf-8") as infp:
        lines = [line.rstrip() for line in infp]
    docs = lines_to_docs(args.INFILE, lines, maxpagelen=14)
    help_asm = render_help(docs, defines=args.defines, verbose=args.verbose,
                           inputlog=args.dte_input_log)
    if args.output != '-':
        with open(args.output, "w", encoding="utf-8") as outfp:
            outfp.write(help_asm)
    else:
        sys.stdout.write(help_asm)

if __name__=='__main__':
    if 'idlelib' in sys.modules:
        main(['paginate_help.py', '../src/helppages.txt'])
    else:
        main()
