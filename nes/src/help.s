;
; Help screen for 240p test suite
; Copyright 2015-2018 Damian Yerrick
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
.import helptitles_hi, helptitles_lo
.import helppages_hi, helppages_lo, help_cumul_pages
.importzp helpsect_240p_test_suite, helpsect_about, helpsect_health_warning
.importzp HELP_NUM_PAGES, HELP_NUM_SECTS

.assert .bank(helppages_lo) = .bank(helpscreen_cb), error, "HELPDATA and CODE02 banks differ"

.zeropage
help_cur_doc:   .res 1
help_cur_page:  .res 1
help_cur_line:  .res 1
help_reload:    .res 1
help_ok_keys:   .res 1
prev_nonblank:  .res 1
cur_nonblank:   .res 1
help_cursor_y:  .res 1
cursor_dirty:   .res 1
vram_copydstlo: .res 1
vram_copydsthi: .res 1
flashing_ok:    .res 1
.bss
help_line_buffer:.res HELP_LINE_LEN
TITLE_REPEAT_CODE = $0F

.code

;;
; Reads the controller, and if Start was just pressed, displays
; a help screen.
; @param A the help screen to display if Start was pressed
; @return C true iff Start was pressed
.proc read_pads_helpcheck
  pha
  jsr read_pads
  pla
.endproc
.proc helpcheck
  tax
  lda new_keys+0
  and #KEY_START
  beq not_help
    lda help_cur_page
    pha
    lda help_cursor_y
    pha
    jsr helpscreen_abslr
    pla
    sta help_cursor_y
    pla
    sta help_cur_page
    sec
    rts
  not_help:

  clc
return:
  rts
.endproc

.proc flashing_consent
  lda flashing_ok
  bne already_accepted 
    ldx #helpsect_health_warning
    jsr helpscreen_abslr
    lda new_keys
    and #KEY_A|KEY_START
    sta flashing_ok
  already_accepted:
  rts
.endproc

.proc do_credits
  ldx #helpsect_240p_test_suite
  bne helpscreen_abslr
.endproc

.proc do_about
  ldx #helpsect_about
  ; fall through
.endproc

.proc helpscreen_abslr
  lda #KEY_B|KEY_A|KEY_START|KEY_LEFT|KEY_RIGHT
  ; fall through
.endproc

;;
; @param A the keys that are OK to use
;   usually this includes KEY_LEFT|KEY_RIGHT
;   for menu selection, use KEY_UP|KEY_DOWN|KEY_A|KEY_START
;   for going back, use KEY_B
; @param X the document number
; @param help_cur_page the page to start on.
;   If not within the segment, goes to the segment's first page.
; @return A: number of page within segment; Y: cursor Y position
.proc helpscreen
  sta help_ok_keys
  stx help_cur_doc

  ; If the help page needs to be reloaded, reload it.
  ; This is the only time the compressed data bank is accessed.
  ; After this, all data comes from the help bank.
  lda help_reload
  bpl partial_reload
    jsr helpscreen_load
    lda #0
    sta prev_nonblank
    sta help_reload
    beq reload_done
  partial_reload:
    jsr rtl  ; switch in CODE02
    jsr helpscreen_load_palette
  reload_done:
  jmp helpscreen_cb
.endproc

; the rest is in the help bank
.segment "CODE02"
.proc helpscreen_cb
  ldx #0
  ldy #8
  lda #VBLANK_NMI|BG_0000|OBJ_8X16
  stx PPUSCROLL
  sty PPUSCROLL
  sta PPUCTRL

  ; If not within this document, move to the first page
  ldx help_cur_doc
  lda help_cur_page
  cmp help_cumul_pages,x
  bcc movetofirstpage
  cmp help_cumul_pages+1,x
  bcc nomovepage
movetofirstpage:
  lda help_cumul_pages,x
  sta help_cur_page
  lda #0
  sta help_cursor_y
nomovepage:
  lda #0
  sta help_cur_line
  lda #2
  sta cursor_dirty
  sta cur_nonblank

loop:
  jsr help_prepare_line
  jsr helpscreen_load_oam
  jsr ppu_wait_vblank
  ldx #0
  stx OAMADDR
  lda #>OAM
  sta OAM_DMA

  lda vram_copydsthi
  bmi nocopytxt
  ldy vram_copydstlo
  jsr copyLineImg_helpscreen
  lda #$FF
  sta vram_copydsthi
  bpl vramdone
nocopytxt:
  lda cursor_dirty
  beq vramdone
  jsr help_draw_cursor
  lda #0
  sta cursor_dirty
vramdone:

  ldx #0
  ldy #8
  lda #VBLANK_NMI|BG_0000|OBJ_8X16
  sec
  jsr ppu_screen_on
  jsr read_pads
  ldx #0
  jsr autorepeat
  lda das_keys+0
  and #KEY_UP|KEY_DOWN
  sta das_keys+0
  lda new_keys+0
  and help_ok_keys
  sta new_keys+0

  and #KEY_RIGHT
  beq notNextPage
  ldx help_cur_doc
  lda help_cumul_pages+1,x
  sec
  sbc help_cur_page
  bcc notNextPage
  cmp #2
  bcc notNextPage
  inc help_cur_page
  lda #0
  sta help_cur_line  ; 0 in current line triggers new page
notNextPage:

  lda new_keys+0
  and #KEY_LEFT
  beq notPrevPage
  ldx help_cur_doc
  lda help_cumul_pages,x
  cmp help_cur_page
  bcs notPrevPage
  dec help_cur_page
  lda #0
  sta help_cur_line
notPrevPage:

  lda new_keys+0
  and #KEY_UP
  beq notCursorUp
  lda help_cursor_y
  beq notCursorUp
  sta cursor_dirty
  dec help_cursor_y
notCursorUp:

  lda new_keys+0
  and #KEY_DOWN
  beq notCursorDown
  lda prev_nonblank
  sec
  sbc help_cursor_y
  bcc notCursorDown
  cmp #4
  bcc notCursorDown
  sta cursor_dirty
  inc help_cursor_y
notCursorDown:

  ; B: Exit  
  lda new_keys+0
  and #KEY_B
  bne done

  ; A: Exit if has drawn up to the cursor Y
  lda new_keys+0
  and #KEY_A|KEY_START
  beq notPressA
  lda help_cursor_y
  clc
  adc #2
  cmp help_cur_line
  bcc done
  
notPressA:

  jmp loop
done:
  ldx help_cur_doc
  lda help_cur_page
  sec
  sbc help_cumul_pages,x
  ldy help_cursor_y
  rts
.endproc

.proc help_prepare_line
  jsr clearLineImg
  lda help_cur_line
  bne not_title_line

  ; Title line: Set ciSrc to the start of the page, then
  ; draw the section's title
  ldx help_cur_page
  lda helppages_hi,x
  sta ciSrc+1
  lda helppages_lo,x
  sta ciSrc+0
  ldx help_cur_doc
  lda helptitles_hi,x
  ldy helptitles_lo,x
  jsr undte_line
have_line_buffer:
  lda #>help_line_buffer
  ldy #<help_line_buffer
have_ay:
  ldx #0
have_axy:
  jsr vwfPuts
finish_line:
  lda help_cur_line
  inc help_cur_line
  clc
  adc #$0500>>7
  lsr a
  sta vram_copydsthi
  lda #0
  ror a
  sta vram_copydstlo
  lda #16
  jmp invertTiles

not_title_line:
  cmp #1
  bne not_pagenum_line

  lda help_ok_keys
  and #KEY_B
  beq no_draw_b_exit
    lda #>b_exit_msg
    ldy #<b_exit_msg
    ldx #96
    jmp have_lower_right_msg
  no_draw_b_exit:
    ; Draw TV system instead
    ldx tvSystem
    lda tvSystemNameHi,x
    ldy tvSystemNameLo,x
    ldx #100
  have_lower_right_msg:
  jsr vwfPuts

  lda help_ok_keys
  and #KEY_DOWN
  beq no_draw_updowna
    lda #>updowna_msg
    ldy #<updowna_msg
    ldx #38
    jsr vwfPuts
  no_draw_updowna:

  ldy #0
pagenum_template_loop:
  lda pagenum_template,y
  sta help_line_buffer,y
  beq pagenum_template_done
  iny
  bne pagenum_template_loop
pagenum_template_done:
  
  ldx help_cur_doc
  lda help_cur_page
  sec
  sbc help_cumul_pages,x
  ; Page numbers are 1-based, but subtraction leaves carry set
  adc #'0'  ; Currently do not allow more than 9 pages per document
  sta help_line_buffer+2
  lda help_cumul_pages+1,x
  sec
  sbc help_cumul_pages,x
  ; Skip drawing page number if fewer than two
  cmp #2
  bcc finish_line
  adc #'0'-1  ; minus 1 because carry is set
  sta help_line_buffer+4
  lda #2
  sta cur_nonblank
  jmp have_line_buffer

not_pagenum_line:
  cmp #22
  bcs page_done

  ; 0: End of page
  ; 1: End of page if not multicart
  ldy #0
  lda (ciSrc),y

  .if ::IS_MULTICART
    beq is_null_line
    lsr a
    bne not_multicart_only_line
      inc ciSrc
      bne not_multicart_only_line
      inc ciSrc+1
    not_multicart_only_line:
  .else
    lsr a
    beq is_null_line
  .endif

  ; Mark this line as having something on it
  ; prev_nonblank is how many lines are actually not blank
  ; cur_nonblank is how many lines will be not blank after this
  ; page completes
  ldy help_cur_line
  iny
  sty cur_nonblank
  cpy prev_nonblank
  bcc :+
    sty prev_nonblank
  :

  ; Does this line repeat a title (0F xx)?
  ldy #0
  lda (ciSrc),y
  cmp #TITLE_REPEAT_CODE
  bne normal_dte_line
    iny
    lda (ciSrc),y
    tax
    lda helptitles_hi,x
    ldy helptitles_lo,x
    jsr undte_line
    clc
    lda #2
    bpl compressed_line_length_A_CF
  normal_dte_line:
    ; Decompress line
    lda ciSrc+1
    ldy ciSrc
    jsr undte_line
    tay  ; A: number of compressed bytes written
    dey  ; Read last compressed byte and set CF if not NUL terminator
    lda ($00),y
    cmp #$01
    ; Add Y bytes if on NUL or Y+1 otherwise (usually LF)
    tya
  compressed_line_length_A_CF:
    adc ciSrc
    sta ciSrc
    bcc :+
      inc ciSrc+1
    :

  ; Indent iff a cursor is displayed
  ldx #0
  lda help_ok_keys
  and #KEY_DOWN
  beq no_indent
    ldx #12
  no_indent:
  lda #>help_line_buffer
  ldy #<help_line_buffer
  jmp have_axy
is_null_line:
  ldy cur_nonblank
  dey
  dey
  dey
  cpy help_cursor_y
  bcs :+
    sty cursor_dirty
    sty help_cursor_y
  :

  lda help_cur_line
  cmp prev_nonblank
  bcs page_done
;  lda #'n'
;  ldx #16
;  jsr vwfPutTile
  jmp finish_line
page_done:
  lda cur_nonblank
  sta prev_nonblank
  lda #$FF
  sta help_cur_line
  rts
.endproc

.proc help_draw_cursor
  lda #$20
  sta PPUADDR
  lda #$CE
  sta PPUADDR
  lda #VBLANK_NMI|VRAM_DOWN
  sta PPUCTRL
  ldy help_cursor_y
  iny
  lda help_ok_keys
  and #KEY_DOWN
  bne :+
    ldy #0
  :
  clc
  lda #$60
cursorloop:
  tax
  dey
  bne :+
    ldx #$4F
  :
  stx PPUDATA
  adc #8
  bcc cursorloop
  rts
.endproc

; Help screen background ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.segment "CODE02"
.proc helpscreen_load_oam
  ; Prepare Gus sprite
strip_y = $00
strip_height = $01
tilenum = $02

  ldx #0
  ldy #0
  jsr sprstriploop
  ldy nmis
  cpy #8
  ldy #gus_eyes2-gus_sprite_strips
  bcc :+
    ldy #gus_eyes1-gus_sprite_strips
  :
  jsr sprstriploop
  jmp ppu_clear_oam
sprstriploop:
  lda gus_sprite_strips+0,y
  cmp #$FF
  bcs sprstripdone
  sta strip_y
  lda gus_sprite_strips+1,y
  sta tilenum
  lda gus_sprite_strips+4,y
  sta strip_height
sprstripentryloop:
  lda strip_y
  sta OAM,x
  inx
  clc
  adc #16
  sta strip_y
  lda tilenum
  inc tilenum
  inc tilenum
  sta OAM,x
  inx
  lda gus_sprite_strips+2,y
  sta OAM,x
  inx
  lda gus_sprite_strips+3,y
  sta OAM,x
  inx
  dec strip_height
  bne sprstripentryloop
  tya
  clc
  adc #5
  tay
  bcc sprstriploop
sprstripdone:
  rts
.endproc

.code
; Begin loading the help screen
.proc helpscreen_load
  ; Load background image
  lda #0
  jsr load_sb53_file
  jmp helpscreen_load_cb
.endproc

.segment "CODE02"
.proc helpscreen_load_cb

  ; Load character sprite tiles
  ldx #$10
  ldy #$00
  lda #5
  jsr unpb53_file

  ; Load arrow tiles
  ldx #$04
  ldy #$E0
  lda #6
  jsr unpb53_file

  ; Load tilemap for VWF
dstlo   = $00
dsthi   = $01
tilenum = $02

  ldx #$50
  lda #$20  ; $20CE: Body text (16x20 tiles)
  sta dsthi
  ldy #$CE
  sty dstlo
  ldy #$8E  ; $208E: Page title (16x1 tiles)
  jsr setup_one_vwf_line
  lda #$23  ; $236E: Page number (16x1 tiles)
  ldy #$6E
  jsr setup_one_vwf_line
  
vwfmap_rowloop:
  lda dsthi
  ldy dstlo
  jsr setup_one_vwf_line
  lda dstlo
  clc
  adc #32
  sta dstlo
  bcc :+
    inc dsthi
  :
  cpx #0
  bne vwfmap_rowloop

  jsr helpscreen_load_palette

  ; Clear out the tiles in the VWF text area ($0500-$0FFF)
  lda #$FF
  tay
  ldx #$05
  jsr ppu_clear_nt
  ldx #$08
  jsr ppu_clear_nt
  ldx #$0C
  jmp ppu_clear_nt

setup_one_vwf_line:
  sta PPUADDR
  sty PPUADDR
  ldy #4
vwfmap_tileloop:
  txa
  inx
  sta PPUDATA
  stx PPUDATA
  sta PPUDATA
  stx PPUDATA
  inx
  dey
  bne vwfmap_tileloop
  rts
  ; fall through to helpscreen_load_palette
.endproc
.proc helpscreen_load_palette
  ; Wait for actual vblank
  lda nmis
  :
    cmp nmis
    beq :-

  ; Load palette for sprite and VWF text
  lda #$3F
  sta PPUADDR
  ldy #helpscreen_palette_skip
  sty PPUADDR
palloop:
  lda helpscreen_palette-helpscreen_palette_skip,y
  iny
  sta PPUDATA
  cpy #helpscreen_palette_skip + helpscreen_palette_size
  bcc palloop
  rts
.endproc

.segment "HELPDATA"
; Y, Start tile, Attr, X, Height
gus_sprite_strips:
  .byte 115,$21,$41,32, 3  ; Elbows
  .byte 115,$21,$01,88, 3


  .byte  69,$11,$43,48, 2  ; Head excl. eye
  .byte  55,$01,$43,56, 2
  .byte  55,$01,$03,64, 2
  .byte  69,$11,$03,72, 2

  .byte 103,$27,$41,40, 3  ; Arms and torso (upper)
  .byte 103,$17,$41,48, 3
  .byte 103,$07,$41,56, 3
  .byte 103,$07,$01,64, 3
  .byte 103,$17,$01,72, 3
  .byte 103,$27,$01,80, 3

  .byte 151,$2d,$40,40, 2  ; Arms and torso (lower)
  .byte 151,$1d,$40,48, 2
  .byte 151,$0d,$40,56, 1
  .byte 167,$0f,$42,56, 1
  .byte 151,$0d,$00,64, 1
  .byte 167,$0f,$02,64, 1
  .byte 151,$1d,$00,72, 2
  .byte 151,$2d,$00,80, 2

  .byte $FF
gus_eyes1:  ; eyes open
  .byte  87,$05,$42,56, 1
  .byte  87,$05,$02,64, 1
  .byte $FF
gus_eyes2:  ; eyes shut
  .byte  87,$15,$42,56, 1
  .byte  87,$15,$02,64, 1
  .byte $FF

helpscreen_palette_skip = $09
helpscreen_palette:
  .byte                                       $20,$0F,$20, $0F,$0F,$20,$20
  .byte $0F,$02,$27,$38, $0F,$18,$27,$38, $0F,$02,$27,$20, $0F,$02,$27,$12
helpscreen_palette_size = * - helpscreen_palette
pagenum_template:  .byte 134," 1/1 ",135,0
updowna_msg:       .byte 132,133,"A: Select",0
b_exit_msg:        .byte "B: Exit",0

tvSystemNameLo: .lobytes name_ntsc, name_pal, name_dendy
tvSystemNameHi: .hibytes name_ntsc, name_pal, name_dendy
name_ntsc:   .byte "NTSC",0
name_pal:    .byte "PAL",0
name_dendy:  .byte "Dendy",0
