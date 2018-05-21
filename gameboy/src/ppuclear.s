;
; Basic LCD routines for Game Boy
;
; Copyright 2018 Damian Yerrick
; 
; This software is provided 'as-is', without any express or implied
; warranty.  In no event will the authors be held liable for any damages
; arising from the use of this software.
; 
; Permission is granted to anyone to use this software for any purpose,
; including commercial applications, and to alter it and redistribute it
; freely, subject to the following restrictions:
; 
; 1. The origin of this software must not be misrepresented; you must not
;    claim that you wrote the original software. If you use this software
;    in a product, an acknowledgment in the product documentation would be
;    appreciated but is not required.
; 2. Altered source versions must be plainly marked as such, and must not be
;    misrepresented as being the original software.
; 3. This notice may not be removed or altered from any source distribution.
;
include "src/gb.inc"
include "src/global.inc"

section "irqvars",HRAM
; Used for bankswitching BG CHR RAM
vblank_lcdc_value:: ds 1
stat_lcdc_value:: ds 1

; The display list at $CE00-$CE9F gets DMA'd to OAM after every frame
; in which sprites moved.  Also called "shadow OAM".
section "ram_ppuclear",WRAM0[$CE00]
SOAM:: ds 160
nmis:: ds 1
oam_used:: ds 1  ; How much of the display list is used

SECTION "rom_ppuclear", ROM0

;;
; Waits for blanking and turns off rendering.
;
; Unlike NES and Super NES, which continuously generate a video
; signal to keep the TV's hsync and vsync circuits occupied, the
; Game Boy LCD uses freesync.  Thus the LCD driver halts entirely
; when rendering is off, not increasing rLY.  Stopping the video
; signal outside vblank confuses the circuitry in the LCD panel,
; causing it to get stuck on a scanline.  This stuck state is the
; same as the dark horizontal line when you turn off the Game Boy.
;
; Turning rendering on, by contrast, can be done at any time and
; is done by writing the nametable base addresses and sprite size
; to rLCDC with bit 7 set to true.
lcd_off::
  call busy_wait_vblank

  ; Use a RMW instruction to turn off only bit 7
  ld hl, rLCDC
  res 7, [hl]
  ret

;;
; Waits for the vblank ISR to increment the count of vertical blanks.
; Will lock up if DI, vblank IRQ off, or LCD off.
; Clobbers A, HL
wait_vblank_irq::
  ld hl,nmis
  ld a,[hl]
.loop:
  halt
  cp [hl]
  jr z,.loop
  ret

;;
; Waits for forced blank (rLCDC bit 7 clear) or vertical blank
; (rLY >= 144).  Use before VRAM upload or before clearing rLCDC bit 7.
busy_wait_vblank::
  ; If rLCDC bit 7 already clear, we're already in forced blanking
  ldh a,[rLCDC]
  rlca
  ret nc

  ; Otherwise, wait for rLCDC to become 144 (not 145) because rLY=0
  ; represents both the prerender line and the first visible line.
  ; This differs from Super NES, where the first visible line is 1,
  ; and NES, which has a post-render line numbered 240 between
  ; picture and vblank.
.wait:
  ldh a, [rLY]
  cp 144
  jr c, .wait
  ret

;;
; Busy-wait for being out of vblank.  Use this for game loop timing
; if interrupts aren't in use yet.
wait_not_vblank::
  ldh a, [rLY]
  cp 144
  jr nc, wait_not_vblank
  ret

;;
; Moves sprites in the display list from SOAM+[oam_used] through
; SOAM+$9C offscreen by setting their Y coordinate to 0, which is
; completely above the screen top (16).
lcd_clear_oam::
  ; Destination address in shadow OAM
  ld h,high(SOAM)
  ld a,[oam_used]
  and $FC
  ld l,a

  ; iteration count
  rrca
  rrca
  add 256 - 40
  ld c,a

  xor a
.rowloop:
  ld [hl+],a
  inc l
  inc l
  inc l
  inc c
  jr nz, .rowloop
  ret

vblank_handler::
  push af
  ld a,[nmis]
  inc a
  ld [nmis],a
  ld a,[vblank_lcdc_value]
  ldh [rLCDC],a
  pop af
  reti

stat_handler::
  push af
  ld a,[stat_lcdc_value]
  ldh [rLCDC],a
  pop af
  reti

;;
; Emulates mono palette feature on Game Boy Color.
; Call this only during blanking.
set_obp1::
  ldh [rOBP1],a
  ld bc,$8400 + low(rOCPS)
  jr set_gbc_mono_palette

;;
; Emulates mono palette feature on Game Boy Color.
; Call this only during blanking.
set_obp0::
  ldh [rOBP0],a
  ld bc,$8000 + low(rOCPS)
  jr set_gbc_mono_palette

;;
; Emulates mono palette feature on Game Boy Color.
; Call this only during blanking.
set_bgp::
  ldh [rBGP],a
  ld bc,$8000 + low(rBCPS)

;; Emulates
; @param A BGP or OBP0 value
; @param B offset into palette memory (0, 4, 8, 12, ..., 28) plus $80
; @param C palette port to write: LOW(rBCPS) or LOW(rOCPS)
; @return AEHL clobbered, B=0, C increased by 1, D unchanged
set_gbc_mono_palette::
  rlca
  ld e,a
  ld a,b  ; Regmap now: E=BGP<<1, A=palette offset, C=address port
  ld [$FF00+c],a
  inc c   ; ad
  ld b,4
  ld hl,gbmonopalette
  ; Regmap now: B=count of remaining colors, C=data port address,
  ;   E=BGP value rlc 1, HL=pointer to start ofpalette
  loop:
    ld a,l
    xor e
    and %11111001
    xor e
    ld l,a  ; now L points to this color so stuff it into the palette
    ld a,[hl+]
    ld [$FF00+c],a
    ld a,[hl]
    ld [$FF00+c],a
    rrc e  ; move to next bitfield of BGP
    rrc e
    dec b
    jr nz,loop

  ; Restore BGP value
  ld a,e
  rrca
  ret

section "GBMONOPALETTE", ROM0, ALIGN[3]
gbmonopalette::
  dw 31*33, 21*33, 11*33, 0*33