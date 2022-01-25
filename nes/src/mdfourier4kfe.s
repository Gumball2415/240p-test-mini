.include "nes.inc"
.include "global.inc"

; Aims to support use with mapper 0, 1, 2, 4, 7, or 218
; Mapper 7 is the most emulator compatible
MAPPERNUM = 7

; Rumor has it that PPU A13 passes through the audio inverter
; and can affect noise
MDF_PA13_HIGH = 1

; Strobing controller 1 is also rumored to interfere with audio
MDF_NO_JOY1 = 0

test_good_phase := test_state+6


.segment "INESHDR"
.if MAPPERNUM = 218
  MIRRORING = 9
.else
  MIRRORING = 1
.endif
.byte "NES", $1A, 1, 0
.byte (MAPPERNUM << 4) & $F0 | MIRRORING
.byte MAPPERNUM & $F0

; Space for you to patch in whatever initialization your mapper needs
.segment "STUB15"
stub15start:
.repeat 96 - 9
  nop
.endrepeat
jmp reset_handler
.addr nmi_handler, stub15start, irq_handler
.assert *-stub15start = 96, error, "maper init area not 96 bytes!"

.zeropage
nmis: .res 1
cur_keys: .res 2
new_keys: .res 2
test_state: .res SIZEOF_TEST_STATE

.bss
mdfourier_good_phase: .res 1

.code
; Bare minimum NMI handler allows sync to vblank in a 6-cycle window
; using a CMP/BEQ loop.  Even if the NMI handler isn't this trivial,
; the sync can't be improved by much because 6-cycle instructions
; such as JSR aaaa or STA (dd),Y aren't interruptible.
nmi_handler:
  inc nmis
irq_handler:
  rti

.proc reset_handler
  sei
  ldx #$FF
  txs
  inx
  stx PPUCTRL
  stx PPUMASK
  bit $4015  ; ack some IRQs
  lda #$40
  sta $4017  ; disable frame counter IRQ
  bit PPUSTATUS  ; ack vblank NMI
  vwait1:
    bit PPUSTATUS  ; wait for first warmup vblank
    bpl vwait1
  txa
  :
    sta $00,x  ; clear zero page
    inx
    bne :-
  vwait2:
    bit PPUSTATUS  ; wait for second warmup vblank
    bpl vwait2
  lda #1
  sta mdfourier_good_phase
  ; fall through
restart:
  jsr mdfourier_init_apu
  jsr mdfourier_push_apu
  lda #$FF
  lda #VBLANK_NMI
  sta PPUCTRL
  asl a
  tay
  sta PPUMASK

  ; Copy tiles to CHR RAM
  sty PPUADDR
  sty PPUADDR
  lda #<chrdata
  sta $00
  lda #>chrdata
  sta $01
  ldx #>(chrdata_end-chrdata)
  :
    lda ($00),y
    sta PPUDATA
    iny
    bne :-
    inc $01
    dex
    bne :-

  ; Clear nametable
  lda #$20
  sta PPUADDR
  lda #$00
  sta PPUADDR
  ldy #$FC
  jsr write_4y_of_a
  lda #$55
  ldy #4
  jsr write_4y_of_a
  
  ; Write copyright notice at very bottom of title safe area
  ; $2343 = (24, 208)
  lda #$23
  sta PPUADDR
  lda #$43
  sta PPUADDR
  ldx #1
  ldy #27
  jsr write_x_thru_xpym1
  
  ; Write title
  lda #$21
  sta PPUADDR
  lda #$03
  sta PPUADDR
  ldx #1
  ldy #17
  jsr write_x_thru_xpym1

  ; Write triangle phase
  lda #$21
  sta PPUADDR
  lda #$43
  sta PPUADDR
  ldy #2  ; Width of triangle wave icon
  jsr write_x_thru_xpym1
  ldy #2  ; Width of "OK" = 2
  lda mdfourier_good_phase
  bne have_phase_xy
  iny  ; Width of "Done" = 3
  ldx #22
  lda test_good_phase
  bne have_phase_xy
  iny  ; Width of "Trash" = 4
  ldx #25
have_phase_xy:
  jsr write_x_thru_xpym1

  ; Write palette and turn on display
  jsr vsync
  lda #$3F
  sta PPUADDR
  sty PPUADDR
  :
    lda uipalette,y
    sta PPUDATA
    iny
    cpy #uipalette_end-uipalette
    bne :-
  lda #VBLANK_NMI
  sta PPUCTRL
  asl a
  sta PPUSCROLL
  sta PPUSCROLL
  lda #BG_ON
  sta PPUMASK

  ; Wait for A press
  .if ::MDF_NO_JOY1
    ; read pads only after 1 test
    lda mdfourier_good_phase
    beq keywait
    ; Display the copyright screen for 5-ish seconds
    lda #$FF
    :
    cmp nmis
    bne :-
    jmp skippads
  .endif
  
  keywait:
    jsr read_pads
    jsr vsync
    lda new_keys
    bpl keywait

  skippads:

  ; reduce interference from the PPU as far as we possibly can
  ldy #$3F
  lda #$00
  ldx #$0D
  sta PPUMASK
  sty PPUADDR
  sta PPUADDR
  stx PPUDATA
  sta PPUADDR
  sta PPUADDR

  .if ::MDF_PA13_HIGH
    ldx #$20
    stx PPUADDR
    sta PPUADDR
  .endif

  jsr mdfourier_run
  jmp restart
.endproc

.proc write_4y_of_a
  :
    .repeat 4
      sta PPUDATA
    .endrepeat
    dey
    bne :-
  rts
.endproc

.proc write_x_thru_xpym1
  :
    stx PPUDATA
    inx
    dey
    bne :-
  rts
.endproc

.proc mdfourier_present
  bit new_keys
  bvc no_B_press
    lda mdfourier_good_phase
    sta test_good_phase
    rts
  no_B_press:
  jsr vsync
  jsr mdfourier_push_apu
  .if ::MDF_NO_JOY1
    lda mdfourier_good_phase
    beq :+
    rts
    :
  .endif
  jmp read_pads
.endproc

.proc vsync
  lda nmis
  :
    cmp nmis
    beq :-
  rts
.endproc

.rodata
chrdata: .incbin "obj/nes/mdf4k_chr.chr"
chrdata_end:

uipalette: .byte $0F, $20, $0F, $20, $0F, $0F, $10, $10
uipalette_end: