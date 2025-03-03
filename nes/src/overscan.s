;
; Overscan test for 240p test suite
; Copyright 2015-2019 Damian Yerrick
;
; This program is free software; you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation; either version 2 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License along
; with this program; if not, write to the Free Software Foundation, Inc.,
; 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
;

.include "nes.inc"
.include "global.inc"
.include "rectfill.inc"
.importzp helpsect_overscan, helpsect_safe_areas
.importzp RF_overscan, RF_safearea_1, RF_safearea_2, RF_safearea_3

.segment "RODATA"

; BCD-encoded permill amounts
; To regenerate the next two lines in python3:
; print("  .byte", ",".join('$%02d' % (min(99, i * 1000 // 240)) for i in range(25)))
; print("  .byte", ",".join('$%02d' % (i * 1000 // 256) for i in range(25)))
vert_pctages:
  .byte $00,$04,$08,$12,$16,$20,$25,$29,$33,$37,$41,$45,$50,$54,$58,$62,$66,$70,$75,$79,$83,$87,$91,$95,$99
horz_pctages:
  .byte $00,$03,$07,$11,$15,$19,$23,$27,$31,$35,$39,$42,$46,$50,$54,$58,$62,$66,$70,$74,$78,$82,$85,$89,$93

;                    top  bot left right
arrow_xadd1:  .byte  124, 124,   0,<-15
arrow_yadd1:  .byte  <-1,<-32, 115, 115
arrow_xadd2:  .byte    0,   0,   8,   8
arrow_yadd2:  .byte    8,   8,   0,   0
arrow_xmask:  .byte    0,   0, $FF, $FF
arrow_ymask:  .byte  $FF, $FF,   0,   0
arrow_negate: .byte    0, $FF,   0, $FF

NUM_OVERSCAN_PALETTES = 3
palette_paper:  .byte $00, $0F, $20
palette_ink:    .byte $20, $20, $0F
palette_border: .byte $0F, $02, $12

.segment "CODE02"

amt_top      = test_state+0
amt_bottom   = test_state+1
amt_left     = test_state+2
amt_right    = test_state+3
change_dir   = test_state+4
upd_progress = test_state+5
palette      = test_state+6

.proc do_overscan
  ; set test_state to 4, 4, 4, 4, 0, 0, 0
  ldx #6
  :
    txa
    and #$04
    eor #$04
    sta test_state,x
    dex
    bpl :-

restart:
  lda #VBLANK_NMI
  sta PPUCTRL
  sta help_reload
  asl a
  sta PPUMASK

  tax
  tay
  lda #9
  jsr unpb53_file

  lda #8  ; solid tile
  ldy #0
  ldx #$24
  jsr ppu_clear_nt
  lda #RF_overscan
  jsr rf_load_layout
  lda #3
  jsr overscan_prepare_side_a
  jsr overscan_copy4cols
  lda #2
  jsr overscan_prepare_side_a
  jsr overscan_copy4cols
  lda #VBLANK_NMI
  sta PPUCTRL
  jsr overscan_prepare_pxcounts
  jsr rf_copy8tiles
  jsr overscan_prepare_pctages
  jsr rf_copy8tiles

  ; Sprite map:
  ; 0: bottom border
  ; 1-2: arrows
  ; 3-10:
  
  ; Fill OAM with $20 $00 pattern.  This puts all sprites behind
  ; background, with a don't care opaque tile, and with X = 0.
  ldx #0
  txa
  :
    eor #$20
    sta OAM,x
    inx
    bne :-
  ; And clear the Y coords
  jsr ppu_clear_oam

loop:
  lda #helpsect_overscan
  jsr read_pads_helpcheck
  bcs restart
  ldx #0
  lda das_keys
  and #KEY_UP|KEY_DOWN|KEY_LEFT|KEY_RIGHT
  sta das_keys
  jsr autorepeat

  ; B: exit
  bit new_keys+0
  bvc not_b
    rts
  not_b:

  ; Select: cycle palette
  lda new_keys+0
  and #KEY_SELECT
  beq not_select
    ldy palette
    iny
    cpy #NUM_OVERSCAN_PALETTES
    bcc have_new_palette
      ldy #0
    have_new_palette:
    sty palette
  not_select:

  ; Control Pad: Choose or move an edge
  lda new_keys+0
  and #KEY_UP|KEY_DOWN|KEY_LEFT|KEY_RIGHT
  beq not_move
    ldy #4
    whichbtnloop:
      dey
      lsr a
      bcc whichbtnloop
    ; Control Pad (without A):
    bit cur_keys+0
    bmi try_adjusting
      sty change_dir
      bpl not_move
    try_adjusting:
      tya
      eor change_dir
      cmp #2
      bcs not_move
      ; 1: increase; 0: decrease
      asl a
      adc #$FF
      clc
      ldx change_dir
      adc test_state,x
      cmp #25
      bcs not_move
      sta test_state,x
      lda #0
      sta upd_progress
  not_move:
  jsr overscan_prepare_sprites

  ; Find something to update
  ldy upd_progress
  bne upd_not0
    lda change_dir
    jsr overscan_prepare_side_a
    inc upd_progress
    bne upd_done
  upd_not0:
  dey
  bne upd_not1
    jsr overscan_prepare_pxcounts
    inc upd_progress
    bne upd_done
  upd_not1:
  dey
  bne upd_done
    jsr overscan_prepare_pctages
    inc upd_progress
  upd_done:

  ; Sprite 0 waiting
  lda amt_bottom
  beq no_s0_wait
    lda #$C0
    s0wait0:
      bit PPUSTATUS
      bvs s0wait0
    s0wait1:
      bit PPUSTATUS
      beq s0wait1
    lda #VBLANK_NMI|BG_0000|OBJ_0000|1
    sta PPUCTRL
  no_s0_wait:

  ldx palette
  ldy #$3F
  jsr ppu_wait_vblank

  ; Upload OAM first because some capture cards capture the start of
  ; vblank and can see the palette update rainbow.  But set the
  lda #0
  sta OAMADDR
  sty PPUADDR
  lda #>OAM
  sta OAM_DMA

  .assert >OAM = $02, error, "shadow OAM address high isn't $02: fix this assumption"
  sta PPUADDR  ; Point VRAM address to palette first

  ; Upload background palette
  lda palette_paper,x
  sta PPUDATA
  lda palette_ink,x
  sta PPUDATA

  ; Upload sprite palette
  sty PPUADDR
  lda #$10
  sta PPUADDR
  lda palette_border,x
  sta PPUDATA
  lda #$10  ; Inactive arrow
  bit cur_keys+0
  bpl :+
    lda #$26  ; Active arrow
  :
  sta PPUDATA
  lda palette_paper,x
  sta PPUDATA
  lda palette_ink,x
  sta PPUDATA

  ; If something is prepared, copy it
  bit vram_copydsthi
  bmi isnocopy
  bvs iscolcopy
    jsr rf_copy8tiles
    jmp iscopydone
  iscolcopy:
    jsr overscan_copy4cols
  iscopydone:
    lda #$FF
    sta vram_copydsthi
  isnocopy:

  lda #VBLANK_NMI|BG_0000|OBJ_0000|1
  sec
  jsr ppu_screen_on_xy0

  ; Sprite overflow waiting
  lda amt_top
  beq no_sov_wait
    lda #$A0
    sovwait0:
      bit PPUSTATUS
      bne sovwait0
    sovwait1:
      bit PPUSTATUS
      beq sovwait1
  no_sov_wait:
  lda #VBLANK_NMI|BG_0000|OBJ_0000|0
  sta PPUCTRL

  jmp loop
.endproc

.proc overscan_prepare_sprites
  ; Sprite 0 at the bottom border
  lda #238
  sec
  sbc amt_bottom
  sta OAM+0

  ; Sprites 3-11 at the top border
  ldx amt_top
  dex
  txa
  ldx #3*4
  :
    sta OAM,x
    inx
    inx
    inx
    inx
    cpx #12*4
    bcc :-

  ; Sprites 1-2: Arrows for control of the current edge
  ldy change_dir

  ; X coordinate
  lda test_state,y
  eor arrow_negate,y
  and arrow_xmask,y
  clc
  adc arrow_xadd1,y
  sta OAM+7
  clc
  adc arrow_xadd2,y
  sta OAM+11

  ; Y coordinate
  lda test_state,y
  eor arrow_negate,y
  and arrow_ymask,y
  clc
  adc arrow_yadd1,y
  sta OAM+4
  clc
  adc arrow_yadd2,y
  sta OAM+8

  ; Tile number
  tya
  lsr a
  and #$01
OVERSCAN_ARROW_TILE = $10
  ora #OVERSCAN_ARROW_TILE
  sta OAM+5
  sta OAM+9

  ; Attribute
  lda #0
  sta OAM+6
  lda #$C0
  sta OAM+10
  rts
.endproc

; Drawing the numbers in the middle ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.proc overscan_prepare_pxcounts
table_index = $02
base_x = $03
  jsr clearLineImg
  lda #$0F
  sta vram_copydsthi
  ldx #$00
  stx vram_copydstlo
  stx base_x
  loop:
    stx table_index
    lda test_state,x
    jsr bcd8bit
    ora #'0'
    tay
    lda base_x
    ora #8
    tax
    tya
    jsr vwfPutTile
    lda bcd_highdigits
    beq less_than_ten
      lda base_x
      ora #3
      tax
      lda bcd_highdigits
      ora #'0'
      jsr vwfPutTile
    less_than_ten:
    lda base_x
    clc
    adc #16
    sta base_x
    ldx table_index
    inx
    cpx #4
    bcc loop
  lda #%1001
  jmp rf_color_lineImgBuf
.endproc

.proc overscan_prepare_pctages
table_index = $02
base_x = $03

  jsr clearLineImg
  
  ldx amt_top
  lda vert_pctages,x
  sta $0C
  ldx amt_bottom
  lda vert_pctages,x
  sta $0D
  ldx amt_left
  lda horz_pctages,x
  sta $0E
  ldx amt_right
  lda horz_pctages,x
  sta $0F

  lda #$0F
  sta vram_copydsthi
  ldx #$80
  stx vram_copydstlo
  ldx #$00
  stx base_x
  loop:
    stx table_index
    lda $0C,x
    lsr a
    lsr a
    lsr a
    lsr a
    ora #'0'
    sta lineImgBuf+96
    lda #'.'
    sta lineImgBuf+97
    lda $0C,x
    and #$0F
    ora #'0'
    sta lineImgBuf+98
    lda #'%'
    sta lineImgBuf+99
    ldx base_x
    txa
    clc
    adc #16
    sta base_x
    ldy #<(lineImgBuf+96)
    lda #>(lineImgBuf+96)
    jsr vwfPuts
    ldx table_index
    inx
    cpx #4
    bcc loop
  lda #%1001
  jmp rf_color_lineImgBuf
.endproc

; Drawing the edges ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.code

.proc overscan_prepare_left
  lda #$60
  sta vram_copydsthi
  lda #$00
  sta vram_copydstlo
  lda amt_left
  ldx #$00
  ldy #$FF
  bne overscan_prepare_bulk
.endproc

.proc overscan_prepare_right
  lda #$60
  sta vram_copydsthi
  lda #$1C
  sta vram_copydstlo
  lda #7
  sec
  sbc amt_right
  ldx #$08
  ldy #$18
.endproc

.proc overscan_prepare_bulk
amt = $00
tilebase = $01
eortype = $02
  sta amt
  stx tilebase
  sty eortype

  ; Draw the long lines.  The caller fixes up the corner.
  ldx #0
  setverts:
    txa
    lsr a
    lsr a
    eor eortype
    sec
    adc amt
    bpl :+
      lda #0
    :
    cmp #8
    bcc :+
      lda #8
    :
    eor tilebase
    sta lineImgBuf,x
    txa
    clc
    adc #32
    tax
    bpl setverts
  rts
.endproc

.proc overscan_prepare_side_a
  asl a
  tax
  lda sideprocs+1,x
  pha
  lda sideprocs,x
  pha
overscan_prepare_top:
overscan_prepare_bottom:
  rts
sideprocs:
  .addr overscan_prepare_top-1
  .addr overscan_prepare_bottom-1
  .addr overscan_prepare_left-1
  .addr overscan_prepare_right-1
.endproc

.proc overscan_copy4cols
  clc
  ldx #VBLANK_NMI|VRAM_DOWN
  stx PPUCTRL
  ldx #0
  colloop:
    lda vram_copydsthi
    sta PPUADDR
    lda vram_copydstlo
    sta PPUADDR
    inc vram_copydstlo
    ldy #10
    lda lineImgBuf,x
    partloop:
      .repeat 3
        sta PPUDATA
      .endrepeat
      dey
      bne partloop
    txa
    clc
    adc #32
    tax
    bpl colloop
  rts
.endproc

.proc do_safearea
whichpage = test_state+0
restart:
  jsr rf_load_tiles
  jsr rf_load_tiles_1000
  jsr ppu_wait_vblank
  lda #$3F
  sta PPUADDR
  ldy #$00
  sty PPUADDR
  ldx #2
  palloop2:
    ldy #$00
    palloop:
      lda safe_areas_palette,y
      sta PPUDATA
      iny
      cpy #16
      bcc palloop
      dex
      bne palloop2

  lda #RF_safearea_1
  jsr rf_load_layout
  lda #RF_safearea_2
  jsr rf_load_layout
  lda #RF_safearea_3
  jsr rf_load_layout

  ldx #0
  jsr ppu_clear_oam
  ldx #16
  ; Load sprite columns at sides
  objloadloop:
    dex
    txa
    inx
    sta OAM+0,x
    sta OAM+4,x
    txa
    and #$08
    eor #$14
    sta OAM+1,x
    eor #1
    sta OAM+5,x
    lda #2
    sta OAM+2,x
    sta OAM+6,x
    lda #0
    sta OAM+3,x
    lda #248
    sta OAM+7,x
    txa
    clc
    adc #8
    tax
    cmp #232
    bcc objloadloop
  ; Set sprite 0
  lda #$07
  sta OAM+0
  lda #$0F
  sta OAM+1
  lda #$20
  sta OAM+2
  sta OAM+3

loop:
  jsr ppu_wait_vblank

  ldx #0
  stx OAMADDR
  lda #>OAM
  sta OAM_DMA
  ldy #240-8
  lda #VBLANK_NMI|BG_0000|OBJ_0000|1
  sec
  jsr ppu_screen_on

  lda #helpsect_safe_areas
  jsr read_pads_helpcheck
  bcc :+
    jmp restart
  :

  ; Sprite 0 to switch $2000 at top of PocketNES, above
  lda #$C0
  s0offloop:
    bit PPUSTATUS
    bvs s0offloop
  s0onloop:
    bit PPUSTATUS
    beq s0onloop
  bmi s0nope
    lda #VBLANK_NMI|BG_0000|OBJ_0000|0
    sta PPUCTRL
    ldx #>-3326
    ldy #<-3326
    lda tvSystem
    cmp #1
    bne notPalNES1
      ldx #>-3118
      ldy #<-3118
    notPalNES1:
    jsr waitminusxy
    lda #VBLANK_NMI|BG_1000|OBJ_0000|0
    sta PPUCTRL
    ldx #>-1469
    ldy #<-1469
    lda tvSystem
    cmp #1
    bne notPalNES2
      ldx #>-1377
      ldy #<-1377
    notPalNES2:
    jsr waitminusxy
    lda #VBLANK_NMI|BG_0000|OBJ_0000|1
    sta PPUCTRL
  s0nope:

  lda new_keys+0
  and #KEY_B
  beq loop
  rts
.endproc

waitminusxy:
  iny
  bne waitminusxy
  inx
  bne waitminusxy
  rts

.rodata
safe_areas_palette:
  ; the duplicate $0F is for sprite 0
  .byte $0F,$00,$10,$0F, $0F,$16,$26,$36, $0F,$28,$38,$30, $0F,$12,$22,$32
