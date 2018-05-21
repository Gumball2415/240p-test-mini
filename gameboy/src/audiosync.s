;
; Audio sync test for 240p test suite
; Copyright 2018 Damian Yerrick
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
include "src/gb.inc"
include "src/global.inc"

  rsset hTestState
progress rb 1
unpaused rb 1

section "audiosync",ROM0

PULSE_1K = 2048-131

activity_audiosync::
.restart:
  call lcd_off
  xor a
  ld [help_bg_loaded],a
  ldh [unpaused],a
  ldh [rSCX],a
  ldh [rSCY],a
  ldh [progress],a

  ; Load tiles 0: color 0; 1: color 3: 2: dot
  ld hl,CHRRAM0
  ; xor a
  ld c,16
  call memset_tiny
  dec a
  ld c,16
  call memset_tiny
  ld a,%11000000
  ld [hl+],a
  ld [hl+],a
  ld [hl+],a
  ld [hl+],a
  xor a
  ld c,16
  call memset_tiny

  ; Load map
  ld de,_SCRN0
  ld bc,32*18
  ld h,0
  call memset
  ld hl,_SCRN0+32*15
  ld a,1
  ld c,20
  call memset_tiny

  ld a,$80
  ldh [rNR52],a  ; Bring audio circuit out of reset
  ld a,$FF
  ldh [rNR51],a  ; Set panning
  ld a,$77
  ldh [rNR50],a  ; Set master volume
  xor a
  ldh [rNR10],a  ; Disable sweep
  ld a,$80
  ldh [rNR11],a  ; Duty 50%

  ; Turn on rendering (no sprites)
  xor a
  call set_bgp
  call set_obp0
  call set_obp1
  ld a,$FF
  ldh [rLYC],a  ; disable lyc irq
  ld a,LCDCF_ON|BG_NT0|BG_CHR01|OBJ_ON
  ld [vblank_lcdc_value],a
  ldh [rLCDC],a

.loop:
  ld b,helpsect_audio_sync_test
  call read_pad_help_check
  jr nz,.restart

  ld a,[new_keys]
  ld b,a
  bit PADB_B,b
  jr z,.not_quit
    xor a
    ld [rNR52],a  ; Disable audio chip
    ret
  .not_quit:

  ; A: Toggle pause, and start over if paused
  bit PADB_A,b
  jr z,.not_toggle_pause
    ld a,[unpaused]
    xor $01  ; CPL doesn't set Z
    ld [unpaused],a
    jr nz,.startover
  .not_toggle_pause:


  ld a,[progress]
  cp 122
  jr c,.notstartover
  .startover:
    xor a
    ld [progress],a

    ; End beep
    ldh [rNR12],a  ; volume and decay
    ld a,$80
    ldh [rNR14],a  ; freq hi and note start
  .notstartover:
  cp 120
  jr nz,.no_start_beep

    ; Start beep
    ld a,$F0
    ldh [rNR12],a  ; volume and decay
    ld a,low(PULSE_1K)
    ldh [rNR13],a  ; freq lo
    ld a,high(PULSE_1K) | $80
    ldh [rNR14],a  ; freq hi and note start
    scf
  .no_start_beep:
  jr nc,.clock_despite_pause
  ld a,[unpaused]
  or a
  jr z,.skip_clocking
  .clock_despite_pause:
    ld a,[progress]
    inc a
    ld [progress],a
  .skip_clocking:
  
  call audiosync_draw_sprite
  call wait_vblank_irq
  call run_dma
  call audiosync_draw_row

  ldh a,[progress]
  cp 120
  sbc a  ; A=$00 during beep or $FF during test
  and %00011011
  call set_bgp
  call set_obp0

  jp .loop
  ret


  rsset hLocals
dtr_t0 rb 1
dtr_t1 rb 1
dtr_t2 rb 1
dtr_t3 rb 1

;;
; Draws tiles closing in as progress increases to 40, 60, 80, or 100
audiosync_draw_row:
  ldh a,[progress]
  ld b,a
  cp 40
  sbc a
  inc a
  ldh [dtr_t0],a
  ld a,b
  cp 60
  sbc a
  inc a
  ldh [dtr_t1],a
  ld a,b
  cp 80
  sbc a
  inc a
  ldh [dtr_t2],a
  ld a,b
  cp 100
  sbc a
  inc a
  ldh [dtr_t3],a

  ld b,3
  ld hl,_SCRN0+32*4
  ld de,12
.rowloop:
  ldh a,[dtr_t0]
  ld [hl+],a
  ld [hl+],a
  ldh a,[dtr_t1]
  ld [hl+],a
  ld [hl+],a
  ldh a,[dtr_t2]
  ld [hl+],a
  ld [hl+],a
  ldh a,[dtr_t3]
  ld [hl+],a
  ld [hl+],a
  xor a
  ld [hl+],a
  ld [hl+],a
  ld [hl+],a
  ld [hl+],a
  ldh a,[dtr_t3]
  ld [hl+],a
  ld [hl+],a
  ldh a,[dtr_t2]
  ld [hl+],a
  ld [hl+],a
  ldh a,[dtr_t1]
  ld [hl+],a
  ld [hl+],a
  ldh a,[dtr_t0]
  ld [hl+],a
  ld [hl+],a
  add hl,de
  dec b
  jr nz,.rowloop
  ret

audiosync_draw_sprite:
  ld hl,SOAM
  ldh a,[progress]
  cp 60
  jr nc,.is_descending
    cpl
    add 121
  .is_descending:
  add 16
  ld [hl+],a
  ld a,79+8
  ld [hl+],a
  ld a,2
  ld [hl+],a
  xor a
  ld [hl+],a


  ld a,l
  ld [oam_used],a
  jp lcd_clear_oam
