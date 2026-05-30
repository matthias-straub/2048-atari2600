; -----------------------------------------------------------------------------
; 2048 for the Atari 2600 / VCS
; DASM source, NTSC, 4K ROM, no external include files required.
;
; Build example:
;   dasm 2048_atari2600.asm -f3 -v5 -o2048_atari2600.bin -l2048_atari2600.lst
;
; Controls:
;   Joystick directions move/merge all tiles, 2048-style.
;   On the title/game-over screens, press the console RESET switch to start.
;   During play, console RESET starts a new game.
;
; Display note:
;   This version draws compact tile labels in the playfield.  Each 10-pixel cell
;   uses a constrained glyph set so values up to 512 fit; 1024=1K, 2048=2K. Title-only 0 is supported.
;   Tile colors are NTSC playfield SCORE colors: one color per half-row.
;   Sound plays on successful moves, merges, invalid moves, win, and game over.
; -----------------------------------------------------------------------------

        processor 6502

; --- TIA write registers ------------------------------------------------------
VSYNC   = $00
VBLANK  = $01
WSYNC   = $02
NUSIZ0  = $04
NUSIZ1  = $05
COLUP0  = $06
COLUP1  = $07
COLUPF  = $08
COLUBK  = $09
CTRLPF  = $0A
PF0     = $0D
PF1     = $0E
PF2     = $0F
RESP0   = $10
RESP1   = $11
GRP0    = $1B
GRP1    = $1C
HMOVE   = $2A
HMCLR   = $2B
AUDC0   = $15
AUDC1   = $16
AUDF0   = $17
AUDF1   = $18
AUDV0   = $19
AUDV1   = $1A

; --- RIOT registers -----------------------------------------------------------
SWCHA   = $0280          ; joystick ports, active low
SWCHB   = $0282          ; console switches
INTIM   = $0284
TIM64T  = $0296

; P0 joystick bits in SWCHA, active low
JOY_UP      = %00010000
JOY_DOWN    = %00100000
JOY_LEFT    = %01000000
JOY_RIGHT   = %10000000

; Colors below are NTSC values. PAL users should remap the table.
COLOR_EMPTY = $00
COLOR_GRID  = $0E
COLOR_TEXT  = $0E
COLOR_WIN   = $1E

; Tile exponents: 0=empty, 1=2, 2=4, ... 10=1024, 11=2048
; Title-only tile code 12 draws a visible 0 tile.
WIN_EXP     = 11

; --- RAM ----------------------------------------------------------------------
        SEG.U vars
        ORG $80
Board           ds 16     ; one byte per cell, 0..15. Easier and faster than nibbles.
LineBuf         ds 4
WorkBuf         ds 4
RowBase         ds 1
ColIndex        ds 1
BoardChanged    ds 1
SpawnCount      ds 1
SpawnIndex      ds 1
Rng             ds 1
Debounce        ds 1
ResetDebounce   ds 1
MoveRequest     ds 1
FrameCtr        ds 1
FlashCtr        ds 1
GameState       ds 1     ; 0=title/attract, 1=playing, 2=game over
MergeFlag       ds 1
WonFlag         ds 1
SoundTimer      ds 1
DrawColor0      ds 1
DrawColor1      ds 1
DrawColor2      ds 1
DrawColor3      ds 1
Temp            ds 1
Temp2           ds 1
LPF0            ds 1
LPF1            ds 1
LPF2            ds 1
RPF0            ds 1
RPF1            ds 1
RPF2            ds 1
PairLeft        ds 1
PairRight       ds 1

        SEG code
        ORG $F000

Reset
        sei
        cld

; Clear RAM, TIA, and initialize stack pointer. Classic compact VCS init.
        ldx #0
        txa
ClearAll
        dex
        txs
        pha
        bne ClearAll

        lda #$5A
        sta Rng
        jsr InitTitle

MainFrame
; --- VSYNC: 3 scanlines -------------------------------------------------------
        lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC

; --- VBLANK: 37 scanlines -----------------------------------------------------
        lda #%01000010
        sta VBLANK
        lda #44
        sta TIM64T

        jsr UpdateRng
        jsr CheckConsoleReset
        lda GameState
        cmp #1
        bne SkipGameInput
        jsr ReadJoystickAndMove
SkipGameInput
        jsr UpdateSound

WaitVBlank
        lda INTIM
        bne WaitVBlank
        sta WSYNC
        lda #0
        sta VBLANK

; --- Visible screen: 192 scanlines -------------------------------------------
        lda GameState
        beq VisibleTitle
        cmp #2
        beq VisibleGameOver
        jsr DrawBoard
        jmp VisibleDone
VisibleTitle
        jsr DrawTitle
        jmp VisibleDone
VisibleGameOver
        jsr DrawGameOver
VisibleDone

; --- Overscan: 30 scanlines ---------------------------------------------------
        lda #%01000010
        sta VBLANK
        lda #35
        sta TIM64T
WaitOverscan
        lda INTIM
        bne WaitOverscan
        jmp MainFrame

; -----------------------------------------------------------------------------
; Title/attract and start/reset game state
; -----------------------------------------------------------------------------
InitTitle
        lda #0
        ldx #15
TitleClearLoop
        sta Board,x
        dex
        bpl TitleClearLoop
        ; Tiny title/attract board: 2, 0, 4, 8 in the first row.
        ; Tile code 12 is title-only and draws the digit 0; real game cells
        ; still use 0 for empty and 1..11 for 2..2048.
        lda #1
        sta Board+0
        lda #12
        sta Board+1
        lda #2
        sta Board+2
        lda #3
        sta Board+3
        lda #0
        sta Debounce
        sta ResetDebounce
        sta SoundTimer
        sta FlashCtr
        sta MergeFlag
        sta WonFlag
        sta BoardChanged
        sta MoveRequest
        sta GameState
        rts

NewGame
        lda #0
        ldx #15
ClearBoardLoop
        sta Board,x
        dex
        bpl ClearBoardLoop
        lda #0
        sta Debounce
        sta MoveRequest
        sta BoardChanged
        sta FlashCtr
        sta SoundTimer
        sta FrameCtr
        sta MergeFlag
        sta WonFlag
        lda #1
        sta GameState
        jsr SpawnTile
        jsr SpawnTile
        rts

; -----------------------------------------------------------------------------
; Simple 8-bit LFSR-ish random update. Also called every frame.
; -----------------------------------------------------------------------------
UpdateRng
        lda Rng
        asl
        bcc NoRngXor
        eor #$1D
NoRngXor
        eor FrameCtr
        sta Rng
        inc FrameCtr
        rts


; -----------------------------------------------------------------------------
; Console RESET switch handler. SWCHB bit 0 is active low.
; On title/game-over it starts play; during play it restarts the game.
; The latch prevents repeated new boards while the switch is held down.
; -----------------------------------------------------------------------------
CheckConsoleReset
        lda SWCHB
        and #%00000001
        bne ConsoleResetReleased
        lda ResetDebounce
        bne NoConsoleReset
        lda #1
        sta ResetDebounce
        jsr NewGame
        rts
ConsoleResetReleased
        lda #0
        sta ResetDebounce
NoConsoleReset
        rts

; -----------------------------------------------------------------------------
; Input gate/debounce and movement dispatch.
; One move is made per press; release the stick before another move.
; -----------------------------------------------------------------------------
ReadJoystickAndMove
        lda SWCHA
        and #%11110000
        cmp #%11110000
        bne JoySomethingPressed
        lda #0
        sta Debounce
        rts

JoySomethingPressed
        lda Debounce
        beq JoyAccept
        rts
JoyAccept
        lda #1
        sta Debounce

        lda SWCHA
        and #JOY_LEFT
        beq DoLeft
        lda SWCHA
        and #JOY_RIGHT
        beq DoRight
        lda SWCHA
        and #JOY_UP
        beq DoUp
        lda SWCHA
        and #JOY_DOWN
        beq DoDown
        rts

DoLeft
        jsr MoveLeft
        jmp AfterMove
DoRight
        jsr MoveRight
        jmp AfterMove
DoUp
        jsr MoveUp
        jmp AfterMove
DoDown
        jsr MoveDown
AfterMove
        lda BoardChanged
        beq InvalidMoveFeedback
        lda MergeFlag
        beq PlaySlideFeedback
        jsr StartMergeSound
        jmp ContinueAfterMove
PlaySlideFeedback
        jsr StartMoveSound
ContinueAfterMove
        jsr SpawnTile
        jsr CheckWin
        jsr CheckGameOver
        rts
InvalidMoveFeedback
        jsr StartInvalidSound
        rts

; -----------------------------------------------------------------------------
; Move routines. They load each row/column into LineBuf, collapse it left, then
; store it back. Right/down load and store in reversed order.
; -----------------------------------------------------------------------------
MoveLeft
        lda #0
        sta BoardChanged
        sta MergeFlag
        lda #0
        sta RowBase
        jsr LoadRowLeft
        jsr CollapseLine
        jsr StoreRowLeft
        lda #4
        sta RowBase
        jsr LoadRowLeft
        jsr CollapseLine
        jsr StoreRowLeft
        lda #8
        sta RowBase
        jsr LoadRowLeft
        jsr CollapseLine
        jsr StoreRowLeft
        lda #12
        sta RowBase
        jsr LoadRowLeft
        jsr CollapseLine
        jsr StoreRowLeft
        rts

MoveRight
        lda #0
        sta BoardChanged
        sta MergeFlag
        lda #0
        sta RowBase
        jsr LoadRowRight
        jsr CollapseLine
        jsr StoreRowRight
        lda #4
        sta RowBase
        jsr LoadRowRight
        jsr CollapseLine
        jsr StoreRowRight
        lda #8
        sta RowBase
        jsr LoadRowRight
        jsr CollapseLine
        jsr StoreRowRight
        lda #12
        sta RowBase
        jsr LoadRowRight
        jsr CollapseLine
        jsr StoreRowRight
        rts

MoveUp
        lda #0
        sta BoardChanged
        sta MergeFlag
        lda #0
        sta ColIndex
        jsr LoadColUp
        jsr CollapseLine
        jsr StoreColUp
        lda #1
        sta ColIndex
        jsr LoadColUp
        jsr CollapseLine
        jsr StoreColUp
        lda #2
        sta ColIndex
        jsr LoadColUp
        jsr CollapseLine
        jsr StoreColUp
        lda #3
        sta ColIndex
        jsr LoadColUp
        jsr CollapseLine
        jsr StoreColUp
        rts

MoveDown
        lda #0
        sta BoardChanged
        sta MergeFlag
        lda #0
        sta ColIndex
        jsr LoadColDown
        jsr CollapseLine
        jsr StoreColDown
        lda #1
        sta ColIndex
        jsr LoadColDown
        jsr CollapseLine
        jsr StoreColDown
        lda #2
        sta ColIndex
        jsr LoadColDown
        jsr CollapseLine
        jsr StoreColDown
        lda #3
        sta ColIndex
        jsr LoadColDown
        jsr CollapseLine
        jsr StoreColDown
        rts

; --- row load/store -----------------------------------------------------------
LoadRowLeft
        ldx RowBase
        lda Board,x
        sta LineBuf+0
        inx
        lda Board,x
        sta LineBuf+1
        inx
        lda Board,x
        sta LineBuf+2
        inx
        lda Board,x
        sta LineBuf+3
        rts

StoreRowLeft
        ldx RowBase
        lda LineBuf+0
        jsr StoreACompareX
        inx
        lda LineBuf+1
        jsr StoreACompareX
        inx
        lda LineBuf+2
        jsr StoreACompareX
        inx
        lda LineBuf+3
        jsr StoreACompareX
        rts

LoadRowRight
        ldx RowBase
        inx
        inx
        inx
        lda Board,x
        sta LineBuf+0
        dex
        lda Board,x
        sta LineBuf+1
        dex
        lda Board,x
        sta LineBuf+2
        dex
        lda Board,x
        sta LineBuf+3
        rts

StoreRowRight
        ldx RowBase
        inx
        inx
        inx
        lda LineBuf+0
        jsr StoreACompareX
        dex
        lda LineBuf+1
        jsr StoreACompareX
        dex
        lda LineBuf+2
        jsr StoreACompareX
        dex
        lda LineBuf+3
        jsr StoreACompareX
        rts

; --- column load/store --------------------------------------------------------
LoadColUp
        ldx ColIndex
        lda Board,x
        sta LineBuf+0
        txa
        clc
        adc #4
        tax
        lda Board,x
        sta LineBuf+1
        txa
        clc
        adc #4
        tax
        lda Board,x
        sta LineBuf+2
        txa
        clc
        adc #4
        tax
        lda Board,x
        sta LineBuf+3
        rts

StoreColUp
        ldx ColIndex
        lda LineBuf+0
        jsr StoreACompareX
        txa
        clc
        adc #4
        tax
        lda LineBuf+1
        jsr StoreACompareX
        txa
        clc
        adc #4
        tax
        lda LineBuf+2
        jsr StoreACompareX
        txa
        clc
        adc #4
        tax
        lda LineBuf+3
        jsr StoreACompareX
        rts

LoadColDown
        lda ColIndex
        clc
        adc #12
        tax
        lda Board,x
        sta LineBuf+0
        txa
        sec
        sbc #4
        tax
        lda Board,x
        sta LineBuf+1
        txa
        sec
        sbc #4
        tax
        lda Board,x
        sta LineBuf+2
        txa
        sec
        sbc #4
        tax
        lda Board,x
        sta LineBuf+3
        rts

StoreColDown
        lda ColIndex
        clc
        adc #12
        tax
        lda LineBuf+0
        jsr StoreACompareX
        txa
        sec
        sbc #4
        tax
        lda LineBuf+1
        jsr StoreACompareX
        txa
        sec
        sbc #4
        tax
        lda LineBuf+2
        jsr StoreACompareX
        txa
        sec
        sbc #4
        tax
        lda LineBuf+3
        jsr StoreACompareX
        rts

; Store A into Board,X and set BoardChanged if it differs.
StoreACompareX
        cmp Board,x
        beq StoreNoChange
        sta Board,x
        lda #1
        sta BoardChanged
        rts
StoreNoChange
        sta Board,x
        rts

; -----------------------------------------------------------------------------
; CollapseLine: implements a 2048 move to the left on LineBuf[0..3].
; 1. Compress non-zero cells into WorkBuf.
; 2. Merge equal neighbours once.
; 3. Copy result back to LineBuf.
; -----------------------------------------------------------------------------
CollapseLine
        lda #0
        sta WorkBuf+0
        sta WorkBuf+1
        sta WorkBuf+2
        sta WorkBuf+3

        ldy #0
        ldx #0
PackLoop
        lda LineBuf,x
        beq PackSkip
        sta WorkBuf,y
        iny
PackSkip
        inx
        cpx #4
        bne PackLoop

; merge 0/1
        lda WorkBuf+0
        beq NoMerge01
        cmp WorkBuf+1
        bne NoMerge01
        inc WorkBuf+0
        lda #1
        sta MergeFlag
        lda WorkBuf+2
        sta WorkBuf+1
        lda WorkBuf+3
        sta WorkBuf+2
        lda #0
        sta WorkBuf+3
NoMerge01
; merge 1/2
        lda WorkBuf+1
        beq NoMerge12
        cmp WorkBuf+2
        bne NoMerge12
        inc WorkBuf+1
        lda #1
        sta MergeFlag
        lda WorkBuf+3
        sta WorkBuf+2
        lda #0
        sta WorkBuf+3
NoMerge12
; merge 2/3
        lda WorkBuf+2
        beq NoMerge23
        cmp WorkBuf+3
        bne NoMerge23
        inc WorkBuf+2
        lda #1
        sta MergeFlag
        lda #0
        sta WorkBuf+3
NoMerge23
        lda WorkBuf+0
        sta LineBuf+0
        lda WorkBuf+1
        sta LineBuf+1
        lda WorkBuf+2
        sta LineBuf+2
        lda WorkBuf+3
        sta LineBuf+3
        rts

; -----------------------------------------------------------------------------
; Spawn a new tile in a random empty location. If full, it returns unchanged.
; 90-ish percent exponent 1 (tile 2), otherwise exponent 2 (tile 4).
; -----------------------------------------------------------------------------
SpawnTile
        ldx #0
        lda #0
CountEmptyLoop
        lda Board,x
        bne CountNotEmpty
        inc SpawnCount
CountNotEmpty
        inx
        cpx #16
        bne CountEmptyLoop

        lda SpawnCount
        bne HasEmpty
        rts
HasEmpty
        lda Rng
        and #$0F
        sta SpawnIndex
FindEmptyLoop
        ldx SpawnIndex
        lda Board,x
        beq PlaceTileHere
        inc SpawnIndex
        lda SpawnIndex
        and #$0F
        sta SpawnIndex
        jmp FindEmptyLoop
PlaceTileHere
        lda Rng
        and #$07
        beq SpawnFour
        lda #1
        bne StoreSpawn
SpawnFour
        lda #2
StoreSpawn
        sta Board,x
        lda #0
        sta SpawnCount
        rts

CheckWin
        lda WonFlag
        beq CheckWinScan
        rts
CheckWinScan
        ldx #15
WinLoop
        lda Board,x
        cmp #WIN_EXP
        beq WinFound
        dex
        bpl WinLoop
        rts
WinFound
        lda #1
        sta WonFlag
        lda #90
        sta FlashCtr
        jsr StartWinSound
        rts

CheckGameOver
        ldx #15
GameOverEmptyLoop
        lda Board,x
        beq GameStillPlayable
        dex
        bpl GameOverEmptyLoop

        ; Full board: rows still playable if any horizontal neighbour matches.
        ldx #0
GameOverRowLoop
        lda Board,x
        cmp Board+1,x
        beq GameStillPlayable
        lda Board+1,x
        cmp Board+2,x
        beq GameStillPlayable
        lda Board+2,x
        cmp Board+3,x
        beq GameStillPlayable
        txa
        clc
        adc #4
        tax
        cpx #16
        bne GameOverRowLoop

        ; Columns still playable if any vertical neighbour matches.
        ldx #0
GameOverColLoop
        lda Board,x
        cmp Board+4,x
        beq GameStillPlayable
        inx
        cpx #12
        bne GameOverColLoop

        lda #2
        sta GameState
        lda #180
        sta FlashCtr
        jsr StartGameOverSound
GameStillPlayable
        rts

; -----------------------------------------------------------------------------
; Sound polish: distinct cues on TIA channel 0.
; -----------------------------------------------------------------------------
StartMoveSound
        lda #$04            ; short slide tick
        sta AUDC0
        lda #$0C
        sta AUDF0
        lda #$06
        sta AUDV0
        lda #7
        sta SoundTimer
        rts

StartMergeSound
        lda #$06            ; fuller merge bump
        sta AUDC0
        lda #$06
        sta AUDF0
        lda #$0A
        sta AUDV0
        lda #14
        sta SoundTimer
        rts

StartInvalidSound
        lda #$08            ; dull invalid thud
        sta AUDC0
        lda #$1C
        sta AUDF0
        lda #$06
        sta AUDV0
        lda #9
        sta SoundTimer
        rts

StartWinSound
        lda #$0C            ; bright celebratory chirp
        sta AUDC0
        lda #$03
        sta AUDF0
        lda #$0F
        sta AUDV0
        lda #36
        sta SoundTimer
        rts

StartGameOverSound
        lda #$0F            ; low game-over buzz
        sta AUDC0
        lda #$1F
        sta AUDF0
        lda #$0C
        sta AUDV0
        lda #48
        sta SoundTimer
        rts

UpdateSound
        lda SoundTimer
        beq SoundOff
        dec SoundTimer
        lda GameState
        cmp #2
        beq SoundGameOverDecay
        lda SoundTimer
        and #$0F
        sta AUDF0
        lda SoundTimer
        lsr
        lsr
        ora #2
        and #$0F
        sta AUDV0
        rts
SoundGameOverDecay
        lda SoundTimer
        lsr
        ora #$10
        sta AUDF0
        lda SoundTimer
        lsr
        lsr
        lsr
        and #$0F
        sta AUDV0
        rts
SoundOff
        lda #0
        sta AUDV0
        rts

; -----------------------------------------------------------------------------
; Drawing - numbered playfield board, title, and game-over feedback
; -----------------------------------------------------------------------------
DrawTitle
        ; The title screen reuses the stable board renderer with a small
        ; attract board initialized by InitTitle.  Press RESET to start.
        jsr DrawBoard
        rts

DrawGameOver
        ; Keep the final board visible while DrawBoard pulses the background.
        jsr DrawBoard
        rts

DrawBoard
        lda GameState
        beq DrawTitleBackground
        cmp #2
        beq DrawGameOverBackground
        lda #0
        jmp StoreDrawBackground
DrawTitleBackground
        lda FrameCtr
        and #$20
        beq TitleBgDark
        lda #$02
        bne StoreDrawBackground
TitleBgDark
        lda #0
        beq StoreDrawBackground
DrawGameOverBackground
        lda FrameCtr
        and #$10
        beq GameOverBgDark
        lda #$36
        bne StoreDrawBackground
GameOverBgDark
        lda #0
StoreDrawBackground
        sta COLUBK
        sta PF0
        sta PF1
        sta PF2
        lda #%00000010
        sta CTRLPF          ; SCORE mode: left half uses COLUP0, right half uses COLUP1
        lda #COLOR_TEXT
        sta COLUPF          ; fallback only; SCORE mode uses player colors for playfield

        ldx #12
        jsr DrawBlankLines

        ldx #0
        stx RowBase
        jsr DrawOneBoardRow
        ldx #8
        jsr DrawBlankLines

        ldx #4
        stx RowBase
        jsr DrawOneBoardRow
        ldx #8
        jsr DrawBlankLines

        ldx #8
        stx RowBase
        jsr DrawOneBoardRow
        ldx #8
        jsr DrawBlankLines

        ldx #12
        stx RowBase
        jsr DrawOneBoardRow

        ldx #12
        jsr DrawBlankLines
        rts

DrawBlankLines
        ; Do not touch TIA playfield registers until after WSYNC.
        ; Otherwise the tail of the previous asymmetric scanline is corrupted.
BlankLineLoop
        sta WSYNC
        lda #0
        sta PF0
        sta PF1
        sta PF2
        dex
        bne BlankLineLoop
        rts

; A board row is 32 scanlines.  The old version changed the RAM-side
; playfield buffers between visible scanlines without first blanking the TIA.
; That left one or more stale/right-half playfield scanlines visible whenever
; the setup code crossed a scanline boundary.  Each glyph row now has a safe
; blank/setup scanline before the two visible doubled scanlines.
DrawOneBoardRow
        jsr PrepPairIndexes
        ldx #8
        jsr DrawBlankLines

        jsr BlankAndSetupGlyphRow0
        jsr DrawGlyphLine
        jsr DrawGlyphLine
        jsr BlankAndSetupGlyphRow1
        jsr DrawGlyphLine
        jsr DrawGlyphLine
        jsr BlankAndSetupGlyphRow2
        jsr DrawGlyphLine
        jsr DrawGlyphLine
        jsr BlankAndSetupGlyphRow3
        jsr DrawGlyphLine
        jsr DrawGlyphLine
        jsr BlankAndSetupGlyphRow4
        jsr DrawGlyphLine
        jsr DrawGlyphLine

        ldx #9
        jsr DrawBlankLines
        lda FlashCtr
        beq NoDecFlashDraw
        dec FlashCtr
NoDecFlashDraw
        rts

BlankOneSetupLine
        sta WSYNC
        lda #0
        sta PF0
        sta PF1
        sta PF2
        ; Color changes must happen on the blank/setup scanline.
        ; Doing these writes on the visible glyph scanline delays PF0/PF1/PF2
        ; and corrupts the asymmetric playfield timing.
        lda DrawColor0
        sta COLUP0
        lda DrawColor1
        sta COLUP1
        rts

BlankAndSetupGlyphRow0
        jsr BlankOneSetupLine
        jmp SetupGlyphRow0
BlankAndSetupGlyphRow1
        jsr BlankOneSetupLine
        jmp SetupGlyphRow1
BlankAndSetupGlyphRow2
        jsr BlankOneSetupLine
        jmp SetupGlyphRow2
BlankAndSetupGlyphRow3
        jsr BlankOneSetupLine
        jmp SetupGlyphRow3
BlankAndSetupGlyphRow4
        jsr BlankOneSetupLine
        jmp SetupGlyphRow4

; PairLeft = Board[col0]*12 + Board[col1], PairRight = Board[col2]*12 + Board[col3]
PrepPairIndexes
        ldx RowBase
        lda Board,x
        cmp #12
        bcc PL0OK
        lda #11
PL0OK
        tax
        lda Mul13,x
        sta Temp
        ldx RowBase
        inx
        lda Board,x
        cmp #12
        bcc PL1OK
        lda #11
PL1OK
        clc
        adc Temp
        sta PairLeft
        ; Title-only override: first row left pair is "2 0".
        ; It uses one compact extra pair-table entry instead of expanding
        ; all pair tables to 13x13, which would exceed a 4K ROM.
        lda GameState
        bne NoTitleZeroPair
        lda RowBase
        bne NoTitleZeroPair
        lda #144
        sta PairLeft
NoTitleZeroPair

        ldx RowBase
        inx
        inx
        lda Board,x
        cmp #12
        bcc PR0OK
        lda #11
PR0OK
        tax
        lda Mul13,x
        sta Temp
        ldx RowBase
        inx
        inx
        inx
        lda Board,x
        cmp #12
        bcc PR1OK
        lda #11
PR1OK
        clc
        adc Temp
        sta PairRight

        ; Pick one color per half-row.  The 2600 playfield can only change
        ; color cheaply by half in SCORE mode, so each pair uses the larger
        ; tile's color.
        ldx RowBase
        lda Board,x
        sta Temp
        inx
        lda Board,x
        cmp Temp
        bcc LeftColorReady
        sta Temp
LeftColorReady
        ldx Temp
        lda TileColorTable,x
        sta DrawColor0

        ldx RowBase
        inx
        inx
        lda Board,x
        sta Temp
        inx
        lda Board,x
        cmp Temp
        bcc RightColorReady
        sta Temp
RightColorReady
        ldx Temp
        lda TileColorTable,x
        sta DrawColor1
        rts

; Draw one scanline. All TIA playfield writes happen after WSYNC and before
; returning.  This avoids corrupting the previous scanline, which was the source
; of the horizontal-bar artifacts in Stella.
DrawGlyphLine
        sta WSYNC          ; CPU resumes at cycle 0 of the new scanline

        ; Colors were already loaded during the blank/setup scanline so the
        ; visible scanline keeps the original stable playfield timing.
        ; Left half must be loaded before visible playfield begins at color clock 68.
        lda LPF0
        sta PF0
        lda LPF1
        sta PF1
        lda LPF2
        sta PF2

        ; Wait until after left PF0 has finished, then write the right-half PF0.
        nop
        nop
        nop
        nop
        lda RPF0
        sta PF0

        ; Right-half PF1 window.
        lda RPF1
        sta PF1

        ; Right-half PF2 must not be written until after left PF2 is done.
        nop
        nop
        nop
        lda RPF2
        sta PF2
        rts

SetupGlyphRow0
        ldy PairLeft
        lda PairPF0R0,y
        sta LPF0
        lda PairPF1R0,y
        sta LPF1
        lda PairPF2R0,y
        sta LPF2
        ldy PairRight
        lda PairPF0R0,y
        sta RPF0
        lda PairPF1R0,y
        sta RPF1
        lda PairPF2R0,y
        sta RPF2
        rts
SetupGlyphRow1
        ldy PairLeft
        lda PairPF0R1,y
        sta LPF0
        lda PairPF1R1,y
        sta LPF1
        lda PairPF2R1,y
        sta LPF2
        ldy PairRight
        lda PairPF0R1,y
        sta RPF0
        lda PairPF1R1,y
        sta RPF1
        lda PairPF2R1,y
        sta RPF2
        rts
SetupGlyphRow2
        ldy PairLeft
        lda PairPF0R2,y
        sta LPF0
        lda PairPF1R2,y
        sta LPF1
        lda PairPF2R2,y
        sta LPF2
        ldy PairRight
        lda PairPF0R2,y
        sta RPF0
        lda PairPF1R2,y
        sta RPF1
        lda PairPF2R2,y
        sta RPF2
        rts
SetupGlyphRow3
        ldy PairLeft
        lda PairPF0R3,y
        sta LPF0
        lda PairPF1R3,y
        sta LPF1
        lda PairPF2R3,y
        sta LPF2
        ldy PairRight
        lda PairPF0R3,y
        sta RPF0
        lda PairPF1R3,y
        sta RPF1
        lda PairPF2R3,y
        sta RPF2
        rts
SetupGlyphRow4
        ldy PairLeft
        lda PairPF0R4,y
        sta LPF0
        lda PairPF1R4,y
        sta LPF1
        lda PairPF2R4,y
        sta LPF2
        ldy PairRight
        lda PairPF0R4,y
        sta RPF0
        lda PairPF1R4,y
        sta RPF1
        lda PairPF2R4,y
        sta RPF2
        rts

; -----------------------------------------------------------------------------
; Data
; -----------------------------------------------------------------------------
Mul13
        .byte 0,12,24,36,48,60,72,84,96,108,120,132

; NTSC tile colors indexed by exponent: 0 empty, 1=2, ... 11=2048, 12=title-only 0.
TileColorTable
        .byte $04,$1A,$2A,$3A,$4A,$5A,$6A,$7A,$8A,$9A,$AA,$CA,$0E

PairPF0R0
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0
        .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0
        .byte $D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0
        .byte $60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60
        .byte $60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0
        .byte $80
PairPF1R0
        .byte $00,$00,$00,$00,$00,$01,$01,$02,$01,$01,$00,$01
        .byte $C0,$C0,$C0,$C0,$C0,$C1,$C1,$C2,$C1,$C1,$C0,$C1
        .byte $40,$40,$40,$40,$40,$41,$41,$42,$41,$41,$40,$41
        .byte $C0,$C0,$C0,$C0,$C0,$C1,$C1,$C2,$C1,$C1,$C0,$C1
        .byte $E0,$E0,$E0,$E0,$E0,$E1,$E1,$E2,$E1,$E1,$E0,$E1
        .byte $70,$70,$70,$70,$70,$71,$71,$72,$71,$71,$70,$71
        .byte $50,$50,$50,$50,$50,$51,$51,$52,$51,$51,$50,$51
        .byte $B8,$B8,$B8,$B8,$B8,$B9,$B9,$BA,$B9,$B9,$B8,$B9
        .byte $D8,$D8,$D8,$D8,$D8,$D9,$D9,$DA,$D9,$D9,$D8,$D9
        .byte $58,$58,$58,$58,$58,$59,$59,$5A,$59,$59,$58,$59
        .byte $A0,$A0,$A0,$A0,$A0,$A1,$A1,$A2,$A1,$A1,$A0,$A1
        .byte $50,$50,$50,$50,$50,$51,$51,$52,$51,$51,$50,$51
        .byte $C0
PairPF2R0
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $00,$0E,$0A,$0E,$1D,$3B,$2B,$77,$6D,$69,$15,$2B
        .byte $0E
PairPF0R1
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $20,$20,$20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        .byte $10,$10,$10,$10,$10,$10,$10,$10,$10,$10,$10,$10
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $20,$20,$20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $00
PairPF1R1
        .byte $00,$00,$00,$00,$00,$00,$01,$02,$00,$01,$00,$00
        .byte $40,$40,$40,$40,$40,$40,$41,$42,$40,$41,$40,$40
        .byte $40,$40,$40,$40,$40,$40,$41,$42,$40,$41,$40,$40
        .byte $40,$40,$40,$40,$40,$40,$41,$42,$40,$41,$40,$40
        .byte $80,$80,$80,$80,$80,$80,$81,$82,$80,$81,$80,$80
        .byte $10,$10,$10,$10,$10,$10,$11,$12,$10,$11,$10,$10
        .byte $50,$50,$50,$50,$50,$50,$51,$52,$50,$51,$50,$50
        .byte $A8,$A8,$A8,$A8,$A8,$A8,$A9,$AA,$A8,$A9,$A8,$A8
        .byte $90,$90,$90,$90,$90,$90,$91,$92,$90,$91,$90,$90
        .byte $C8,$C8,$C8,$C8,$C8,$C8,$C9,$CA,$C8,$C9,$C8,$C8
        .byte $C0,$C0,$C0,$C0,$C0,$C0,$C1,$C2,$C0,$C1,$C0,$C0
        .byte $60,$60,$60,$60,$60,$60,$61,$62,$60,$61,$60,$60
        .byte $40
PairPF2R1
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $00,$08,$0A,$0A,$05,$22,$28,$54,$25,$4C,$0D,$1A
        .byte $0A
PairPF0R2
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0
        .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0
        .byte $D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0
        .byte $60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60
        .byte $60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0
        .byte $80
PairPF1R2
        .byte $00,$00,$00,$00,$00,$01,$01,$02,$01,$01,$00,$01
        .byte $C0,$C0,$C0,$C0,$C0,$C1,$C1,$C2,$C1,$C1,$C0,$C1
        .byte $C0,$C0,$C0,$C0,$C0,$C1,$C1,$C2,$C1,$C1,$C0,$C1
        .byte $C0,$C0,$C0,$C0,$C0,$C1,$C1,$C2,$C1,$C1,$C0,$C1
        .byte $E0,$E0,$E0,$E0,$E0,$E1,$E1,$E2,$E1,$E1,$E0,$E1
        .byte $70,$70,$70,$70,$70,$71,$71,$72,$71,$71,$70,$71
        .byte $70,$70,$70,$70,$70,$71,$71,$72,$71,$71,$70,$71
        .byte $B8,$B8,$B8,$B8,$B8,$B9,$B9,$BA,$B9,$B9,$B8,$B9
        .byte $D8,$D8,$D8,$D8,$D8,$D9,$D9,$DA,$D9,$D9,$D8,$D9
        .byte $58,$58,$58,$58,$58,$59,$59,$5A,$59,$59,$58,$59
        .byte $80,$80,$80,$80,$80,$81,$81,$82,$81,$81,$80,$81
        .byte $40,$40,$40,$40,$40,$41,$41,$42,$41,$41,$40,$41
        .byte $C0
PairPF2R2
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $00,$0E,$0E,$0E,$1D,$3B,$3B,$77,$6D,$69,$05,$0B
        .byte $0A
PairPF0R3
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $A0,$A0,$A0,$A0,$A0,$A0,$A0,$A0,$A0,$A0,$A0,$A0
        .byte $50,$50,$50,$50,$50,$50,$50,$50,$50,$50,$50,$50
        .byte $20,$20,$20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $20,$20,$20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        .byte $80
PairPF1R3
        .byte $00,$00,$00,$00,$00,$00,$01,$02,$01,$00,$00,$01
        .byte $00,$00,$00,$00,$00,$00,$01,$02,$01,$00,$00,$01
        .byte $40,$40,$40,$40,$40,$40,$41,$42,$41,$40,$40,$41
        .byte $40,$40,$40,$40,$40,$40,$41,$42,$41,$40,$40,$41
        .byte $A0,$A0,$A0,$A0,$A0,$A0,$A1,$A2,$A1,$A0,$A0,$A1
        .byte $40,$40,$40,$40,$40,$40,$41,$42,$41,$40,$40,$41
        .byte $10,$10,$10,$10,$10,$10,$11,$12,$11,$10,$10,$11
        .byte $28,$28,$28,$28,$28,$28,$29,$2A,$29,$28,$28,$29
        .byte $58,$58,$58,$58,$58,$58,$59,$5A,$59,$58,$58,$59
        .byte $50,$50,$50,$50,$50,$50,$51,$52,$51,$50,$50,$51
        .byte $C0,$C0,$C0,$C0,$C0,$C0,$C1,$C2,$C1,$C0,$C0,$C1
        .byte $60,$60,$60,$60,$60,$60,$61,$62,$61,$60,$60,$61
        .byte $00
PairPF2R3
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $00,$02,$08,$0A,$15,$0A,$22,$51,$68,$29,$0D,$18
        .byte $0A
PairPF0R4
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80,$80
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0
        .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0
        .byte $D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0,$D0
        .byte $60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60
        .byte $60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60,$60
        .byte $40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40,$40
        .byte $E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0,$E0
        .byte $80
PairPF1R4
        .byte $00,$00,$00,$00,$00,$01,$01,$02,$01,$01,$00,$01
        .byte $C0,$C0,$C0,$C0,$C0,$C1,$C1,$C2,$C1,$C1,$C0,$C1
        .byte $40,$40,$40,$40,$40,$41,$41,$42,$41,$41,$40,$41
        .byte $C0,$C0,$C0,$C0,$C0,$C1,$C1,$C2,$C1,$C1,$C0,$C1
        .byte $E0,$E0,$E0,$E0,$E0,$E1,$E1,$E2,$E1,$E1,$E0,$E1
        .byte $70,$70,$70,$70,$70,$71,$71,$72,$71,$71,$70,$71
        .byte $10,$10,$10,$10,$10,$11,$11,$12,$11,$11,$10,$11
        .byte $B8,$B8,$B8,$B8,$B8,$B9,$B9,$BA,$B9,$B9,$B8,$B9
        .byte $D8,$D8,$D8,$D8,$D8,$D9,$D9,$DA,$D9,$D9,$D8,$D9
        .byte $D8,$D8,$D8,$D8,$D8,$D9,$D9,$DA,$D9,$D9,$D8,$D9
        .byte $A0,$A0,$A0,$A0,$A0,$A1,$A1,$A2,$A1,$A1,$A0,$A1
        .byte $50,$50,$50,$50,$50,$51,$51,$52,$51,$51,$50,$51
        .byte $C0
PairPF2R4
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $00,$0E,$08,$0E,$1D,$3B,$23,$77,$6D,$6D,$15,$2B
        .byte $0E
; Pad and vectors
        ORG $FFFA
        .word Reset
        .word Reset
        .word Reset
        END
