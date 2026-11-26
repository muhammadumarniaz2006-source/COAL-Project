; ==========================================================================
;  mainc.asm  -  SPACE SHOOTER : CONSOLE EDITION
;  x86 (32-bit) MASM + Irvine32 library.  Everything lives in this one file.
;
;  HOW THE FILE IS ORGANISED (top to bottom)
;    1. Constants and macros      - numbers/names used everywhere
;    2. .data                     - every variable, table and text string
;    3. Small helper procedures   - draw a char / text / number at x,y
;    4. Menu and information screens
;    5. Game set-up and the main game loop
;    6. Input, player, bullets, enemies, explosions, collisions
;    7. Drawing (HUD + all objects)
;    8. High score file, then main
;
;  HOW A GAME RUNS
;    main -> ShowMenu -> RunGame (loop, one pass = one frame) -> ShowGameOver
;    One frame = read keys, move bullets, hit-test, move enemies, spawn,
;    hit-test again, update level, draw everything, sleep a few milliseconds.
;
;  REGISTER HABITS USED IN THIS FILE
;    DL = column (x), DH = row (y)    <- same as Irvine32's Gotoxy
;    AL = character to draw           BL = colour attribute
;    ESI = pointer to a text string   (or index of a bullet / enemy)
;    Every procedure restores the registers it changes (PROC ... USES),
;    except the register that carries its answer back to the caller.
; ==========================================================================

INCLUDE Irvine32.inc

; --------------------------------------------------------------------------
;  1. CONSTANTS   ("=" constants are replaced by the assembler, they use no memory)
; --------------------------------------------------------------------------
SCREEN_W        = 70        ; console width in columns
HUD_ROW         = 0             ; row 0  : score / lives / level bar
PLAY_TOP        = 1             ; row 1  : first playfield row (enemies spawn here)
PLAYER_ROW      = 24            ; row 24 : the ship lives here
LEFT_LIMIT      = 1             ; ship / enemy leftmost column
RIGHT_LIMIT     = 65            ; ship / enemy rightmost column (col 79 is avoided)

MAX_BULLETS     = 6             ; bullets allowed on screen at once
MAX_ENEMIES     = 3            ; enemies allowed on screen at once
MAX_EXPL        = 8             ; explosions allowed on screen at once
ENEMY_TYPES     = 3             ; Drone, Striker, Tank

START_LIVES     = 5
POINTS_PER_LEVEL = 130          ; every 150 points = next level
MAX_LEVEL       = 10
FIRE_COOLDOWN   = 3             ; frames to wait between two shots
EXPL_FRAMES     = 6             ; how many frames an explosion stays visible
FRAME_MS        = 30            ; Delay at the end of every frame (milliseconds)

SPAWN_BASE      = 40            ; frames between enemy spawns at level 1
SPAWN_STEP      = 3             ; spawns this many frames sooner for each level
SPAWN_MIN       = 12            ; but never faster than this

; --- colours (foreground + background*16, Irvine32 colour names) ---
CLR_DEFAULT     = lightGray + (black * 16)
CLR_SELECT      = blue + (lightGreen * 16)     ; highlighted menu item
CLR_HUD         = white + (blue * 16)           ; top bar background / text
CLR_HUD_LABEL   = lightCyan + (blue * 16)
CLR_HUD_NUM     = yellow + (blue * 16)
CLR_HUD_HI      = lightMagenta + (blue * 16)
CLR_HUD_HINT    = lightGray + (blue * 16)
CLR_PLAYER      = lightGreen
CLR_BULLET      = white

; --------------------------------------------------------------------------
;  MACROS - tiny shortcuts that expand into the normal instructions
;     TEXTAT     r, c, colour, string   : print a string at row r, column c
;     TEXTCENTER r, colour, string      : print a string centred on row r
; --------------------------------------------------------------------------
TEXTAT MACRO rowN, colN, clrN, txtN
    mov dh, rowN
    mov dl, colN
    mov bl, clrN
    mov esi, OFFSET txtN
    call PrintAt    ; calls PrintAt (line 282)
ENDM

TEXTCENTER MACRO rowN, clrN, txtN
    mov dh, rowN
    mov bl, clrN
    mov esi, OFFSET txtN
    call PrintCentered    ; calls PrintCentered (line 300)
ENDM

; ==========================================================================
;  2. DATA
; ==========================================================================
.data

; ---- player -------------------------------------------------------------
playerX         BYTE 40                     ; ship column (row is always PLAYER_ROW)

; ---- bullet pool: parallel arrays, slot i is described by index i in each ----
bulletX         BYTE MAX_BULLETS DUP(0)    ; constants: MAX_BULLETS (line 40)
bulletY         BYTE MAX_BULLETS DUP(0)    ; constants: MAX_BULLETS (line 40)
bulletActive    BYTE MAX_BULLETS DUP(0)     ; 1 = in use, 0 = free slot  | constants: MAX_BULLETS (line 40)

; ---- enemy pool ---------------------------------------------------------
enemyX          BYTE MAX_ENEMIES DUP(0)    ; constants: MAX_ENEMIES (line 41)
enemyY          BYTE MAX_ENEMIES DUP(0)    ; constants: MAX_ENEMIES (line 41)
enemyActive     BYTE MAX_ENEMIES DUP(0)    ; constants: MAX_ENEMIES (line 41)
enemyType       BYTE MAX_ENEMIES DUP(0)     ; 0 Drone, 1 Striker, 2 Tank  | constants: MAX_ENEMIES (line 41)
enemyHP         BYTE MAX_ENEMIES DUP(0)     ; hits left before it dies  | constants: MAX_ENEMIES (line 41)
enemyTimer      BYTE MAX_ENEMIES DUP(0)     ; frames left until this enemy steps down  | constants: MAX_ENEMIES (line 41)

; ---- explosion pool (little '*' that blink for a few frames) -------------
explX           BYTE MAX_EXPL DUP(0)    ; constants: MAX_EXPL (line 42)
explY           BYTE MAX_EXPL DUP(0)    ; constants: MAX_EXPL (line 42)
explTimer       BYTE MAX_EXPL DUP(0)        ; 0 = free slot  | constants: MAX_EXPL (line 42)

; ---- per enemy-type tables (index = enemy type) --------------------------
;                       Drone   Striker   Tank
typeChar        BYTE    'O',    'X',      '#'
typeColor       BYTE    lightRed, yellow, lightMagenta
typeHurtColor   BYTE    lightRed, yellow, magenta       ; colour after being damaged
typeHP          BYTE    1,      1,        2
typePoints      BYTE    10,     20,       30
typeMoveBase    BYTE    10,     6,        16            ; frames per step at level 1
typeMoveMin     BYTE    4,      2,        7             ; never steps faster than this

; ---- game numbers ----------------------------------------------------------
score           DWORD 0
highScore       DWORD 0
level           DWORD 1
lives           BYTE  START_LIVES    ; constants: START_LIVES (line 45)
spawnCounter    DWORD 0                     ; counts down to the next enemy spawn
fireCooldown    BYTE  0                     ; counts down to the next allowed shot
keyBudget       DWORD 0                     ; max keys we read in one frame
levelFlash      DWORD 0                     ; frames left to show the LEVEL UP banner
quitFlag        BYTE  0                     ; 1 = player pressed ESC / quit from pause
hudDirty        BYTE  1                     ; 1 = HUD numbers must be redrawn
newHigh         BYTE  0                     ; 1 = a new high score was set this game

; ---- menu state ------------------------------------------------------------
menuSel         BYTE  0                     ; 0 Start, 1 Instructions, 2 Exit
menuTick        BYTE  0
subColor        BYTE  lightGreen            ; blinking colour of the sub-title

; ---- console cursor + high-score file --------------------------------------
cursorInfo      CONSOLE_CURSOR_INFO <25, 0>
hsFileName      BYTE "highscore.txt",0
hsText          BYTE 16 DUP(0)              ; score written as decimal text
hsHandle        DWORD 0
hsStart         DWORD 0                     ; address of the first digit while saving
hsLen           DWORD 0                     ; number of digits while saving

; ---- block-letter title (generated, 5 rows per word) -----------------------
bnA1 BYTE " #### ####   ###   #### #####",0
bnA2 BYTE "#     #   # #   # #     #    ",0
bnA3 BYTE " ###  ####  ##### #     #### ",0
bnA4 BYTE "    # #     #   # #     #    ",0
bnA5 BYTE "####  #     #   #  #### #####",0
bnB1 BYTE " #### #   #  ###   ###  ##### ##### #### ",0
bnB2 BYTE "#     #   # #   # #   #   #   #     #   #",0
bnB3 BYTE " ###  ##### #   # #   #   #   ####  #### ",0
bnB4 BYTE "    # #   # #   # #   #   #   #     #  # ",0
bnB5 BYTE "####  #   #  ###   ###    #   ##### #   #",0

bannerRows  DWORD OFFSET bnA1, OFFSET bnA2, OFFSET bnA3, OFFSET bnA4, OFFSET bnA5
            DWORD OFFSET bnB1, OFFSET bnB2, OFFSET bnB3, OFFSET bnB4, OFFSET bnB5
bannerRowY  BYTE 1, 2, 3, 4, 5, 7, 8, 9, 10, 11
bannerColor BYTE lightCyan, lightCyan, cyan, cyan, lightBlue
            BYTE yellow, yellow, brown, lightRed, lightRed

; ---- menu texts (all three options are 20 characters wide so the bar is even) ----
mt0         BYTE "     START GAME     ",0
mt1         BYTE "    INSTRUCTIONS    ",0
mt2         BYTE "        EXIT        ",0
menuText    DWORD OFFSET mt0, OFFSET mt1, OFFSET mt2

msgSub      BYTE "-  C O N S O L E   E D I T I O N  -",0
msgMenuHint BYTE "W / S or UP / DOWN : choose      ENTER : select",0
msgHiLabel  BYTE "HIGH SCORE :",0
msgCredit   BYTE "x86 assembly - MASM - Irvine32",0

; ---- HUD texts ---------------------------------------------------------------
hudScore    BYTE "SCORE:",0
hudLives    BYTE "LIVES:",0
hudLevel    BYTE "LEVEL:",0
hudHi       BYTE "HI:",0
hudHint     BYTE "P=Pause",0
msgLevelUp  BYTE " *** LEVEL UP! *** ",0
msgBlank    BYTE "                   ",0

; ---- pause box ---------------------------------------------------------------
pz1 BYTE "+--------------------+",0
pz2 BYTE "|       PAUSED       |",0
pz3 BYTE "|                    |",0
pz4 BYTE "|   P   - Resume     |",0
pz5 BYTE "|  ESC  - Main menu  |",0

; ---- instructions screen -----------------------------------------------------
inTitle     BYTE "H O W   T O   P L A Y",0
inCtl       BYTE "CONTROLS",0
inK1        BYTE "A / LEFT ARROW",0
inK2        BYTE "D / RIGHT ARROW",0
inK3        BYTE "SPACE",0
inK4        BYTE "P",0
inK5        BYTE "ESC",0
inD1        BYTE "move the ship left",0
inD2        BYTE "move the ship right",0
inD3        BYTE "fire a bullet",0
inD4        BYTE "pause / resume",0
inD5        BYTE "quit to the main menu",0
inEnemies   BYTE "ENEMIES",0
inPts       BYTE "pts",0
nmDrone     BYTE "Drone",0
nmStriker   BYTE "Striker",0
nmTank      BYTE "Tank",0
typeName    DWORD OFFSET nmDrone, OFFSET nmStriker, OFFSET nmTank
dsDrone     BYTE "normal speed",0
dsStriker   BYTE "fast and dangerous",0
dsTank      BYTE "slow, takes 2 hits",0
typeDesc    DWORD OFFSET dsDrone, OFFSET dsStriker, OFFSET dsTank
inRules     BYTE "RULES",0
inR1        BYTE "You start with 3 lives. Lose them all and the game is over.",0
inR2        BYTE "An enemy that reaches the bottom row (or hits you) costs a life.",0
inR3        BYTE "Every 150 points = next level: enemies come faster and more often.",0
inBack      BYTE "Press any key to return to the menu",0

; ---- game over screen ----------------------------------------------------------
goTitle     BYTE "*  G A M E   O V E R  *",0
goScore     BYTE "FINAL SCORE   :",0
goLevel     BYTE "LEVEL REACHED :",0
goHigh      BYTE "HIGH SCORE    :",0
goNew       BYTE "*** NEW HIGH SCORE! ***",0
goRetry     BYTE "R or ENTER  -  play again",0
goMenu      BYTE "M or ESC    -  main menu",0

windowTitle BYTE "Space Shooter - Console Edition",0

; ==========================================================================
;  3. SMALL HELPER PROCEDURES  (used by almost everything else)
; ==========================================================================
.code

; --------------------------------------------------------------------------
;  PutCharAt
;  HOW IT WORKS : Sets the text colour, moves the cursor to the spot, then
;                 prints one character.  This is the single place where
;                 "draw one cell" really happens.
;  INPUT        : DL = column, DH = row, AL = character, BL = colour
;  CONNECTS TO  : Called by EraseCell and by every Draw... procedure.  It calls
;                 Irvine32's SetTextColor, Gotoxy and WriteChar.
; --------------------------------------------------------------------------
PutCharAt PROC USES eax ebx edx
    push eax                    ; keep the character, SetTextColor needs EAX
    movzx eax, bl
    call SetTextColor           ; colour for everything printed next
    call Gotoxy                 ; DH = row, DL = column (already set by caller)
    pop eax                     ; get the character back into AL
    call WriteChar
    ret
PutCharAt ENDP

; --------------------------------------------------------------------------
;  EraseCell
;  HOW IT WORKS : Draws a blank space on one cell, which removes whatever was
;                 drawn there before.  This is how we avoid clearing the whole
;                 screen every frame (clearing would make the screen flicker).
;  INPUT        : DL = column, DH = row
;  CONNECTS TO  : Used by the bullet, enemy, explosion and player-move code
;                 right before an object changes position.  Calls PutCharAt.
; --------------------------------------------------------------------------
EraseCell PROC USES eax ebx
    mov al, ' '
    mov bl, CLR_DEFAULT    ; constants: CLR_DEFAULT (line 57)
    call PutCharAt    ; calls PutCharAt (line 248)
    ret
EraseCell ENDP

; --------------------------------------------------------------------------
;  PrintAt
;  HOW IT WORKS : Colours the text, moves the cursor, and prints a
;                 zero-terminated string.
;  INPUT        : DL = column, DH = row, BL = colour, ESI = address of string
;  CONNECTS TO  : Used by the menu, instructions, game-over, pause and HUD
;                 screens (most of them through the TEXTAT macro).
; --------------------------------------------------------------------------
PrintAt PROC USES eax edx
    movzx eax, bl
    call SetTextColor
    call Gotoxy
    mov edx, esi                ; WriteString wants the address in EDX
    call WriteString
    ret
PrintAt ENDP

; --------------------------------------------------------------------------
;  PrintCentered
;  HOW IT WORKS : Asks Irvine32's Str_length how long the text is, works out
;                 the column that puts it in the middle of the 80-column
;                 screen ((80 - length) / 2), then lets PrintAt print it.
;  INPUT        : DH = row, BL = colour, ESI = address of string
;  CONNECTS TO  : Calls Str_length and PrintAt.  Used by the menu, banner,
;                 pause box, level-up message and game-over screen.
; --------------------------------------------------------------------------
PrintCentered PROC USES eax edx
    INVOKE Str_length, esi      ; EAX = number of characters  | invokes Str_length (library routine, defined outside this file)
    neg eax
    add eax, SCREEN_W           ; EAX = 80 - length  | constants: SCREEN_W (line 33)
    shr eax, 1                  ; divide by 2 with a shift (Lab 09)
    mov dl, al                  ; DL = starting column
    call PrintAt    ; calls PrintAt (line 282)
    ret
PrintCentered ENDP

; --------------------------------------------------------------------------
;  PrintNumAt
;  HOW IT WORKS : Colours and positions the cursor, then writes the number in
;                 EAX as a decimal value with Irvine32's WriteDec.
;  INPUT        : DL = column, DH = row, BL = colour, EAX = the number
;  CONNECTS TO  : Used by DrawHUD (score, lives, level, high score), the
;                 menu high-score line, the instructions and game-over screens.
; --------------------------------------------------------------------------
PrintNumAt PROC USES eax edx
    push eax                    ; keep the number
    movzx eax, bl
    call SetTextColor
    call Gotoxy
    pop eax
    call WriteDec
    ret
PrintNumAt ENDP

; --------------------------------------------------------------------------
;  DrawHLine
;  HOW IT WORKS : Prints the same character ECX times in a row, starting at
;                 DL,DH.  A small loop that calls WriteChar.
;  INPUT        : DL = start column, DH = row, ECX = count, AL = char, BL = colour
;  CONNECTS TO  : Used by DrawHUDStatic to paint the blue score bar.
; --------------------------------------------------------------------------
DrawHLine PROC USES eax ecx edx
    jecxz LineDone              ; a count of 0 would loop 4 billion times, so skip
    push eax
    movzx eax, bl
    call SetTextColor
    call Gotoxy
    pop eax
LineLoop:
    call WriteChar
    loop LineLoop               ; repeat ECX times
LineDone:
    ret
DrawHLine ENDP

; --------------------------------------------------------------------------
;  ClearScreen
;  HOW IT WORKS : Sets the default grey-on-black colour first (so the cleared
;                 screen is black), then clears the console.
;  CONNECTS TO  : Called when switching between menu, game and other screens.
; --------------------------------------------------------------------------
ClearScreen PROC USES eax
    mov eax, CLR_DEFAULT    ; constants: CLR_DEFAULT (line 57)
    call SetTextColor
    call Clrscr
    ret
ClearScreen ENDP

; --------------------------------------------------------------------------
;  SetCursorVisible
;  HOW IT WORKS : Shows or hides the blinking console cursor with the Windows
;                 function SetConsoleCursorInfo (the cursor looks ugly while
;                 we jump around drawing things).
;  INPUT        : EAX = 0 hide, 1 show
;  CONNECTS TO  : Called by InitConsole (hide) and by main on exit (show).
; --------------------------------------------------------------------------
SetCursorVisible PROC USES eax
    mov cursorInfo.bVisible, eax    ; structure CONSOLE_CURSOR_INFO instance cursorInfo (line 142)
    INVOKE GetStdHandle, STD_OUTPUT_HANDLE      ; EAX = console output handle  | invokes GetStdHandle (library routine, defined outside this file)
    INVOKE SetConsoleCursorInfo, eax, ADDR cursorInfo    ; invokes SetConsoleCursorInfo (library routine, defined outside this file); ADDR cursorInfo defined at line 142 | structure CONSOLE_CURSOR_INFO instance cursorInfo (line 142)
    ret
SetCursorVisible ENDP

; --------------------------------------------------------------------------
;  InitConsole
;  HOW IT WORKS : One-time console set-up: window title and hidden cursor.
;  CONNECTS TO  : Called once at the start of main.  Uses SetCursorVisible.
; --------------------------------------------------------------------------
InitConsole PROC USES eax
    INVOKE SetConsoleTitle, ADDR windowTitle    ; invokes SetConsoleTitle (library routine, defined outside this file); ADDR windowTitle defined at line 232
    mov eax, 0
    call SetCursorVisible    ; calls SetCursorVisible (line 370)
    ret
InitConsole ENDP

; ==========================================================================
;  4. MENU AND INFORMATION SCREENS
; ==========================================================================

; --------------------------------------------------------------------------
;  DrawStars
;  HOW IT WORKS : Scatters 70 little coloured stars at random places using
;                 RandomRange.  The kind of star ('.', '*', '+') is random too.
;  CONNECTS TO  : Called by DrawMenuStatic to make the menu background.
; --------------------------------------------------------------------------
DrawStars PROC USES eax ebx ecx edx
    mov ecx, 70                 ; number of stars
StarLoop:
    push ecx                    ; RandomRange keeps ECX, but we stay safe
    mov eax, 79
    call RandomRange            ; 0..78
    mov dl, al                  ; column
    mov eax, 23
    call RandomRange            ; 0..22
    inc al                      ; 1..23  (never row 0 or row 24)
    mov dh, al                  ; row
    mov eax, 3
    call RandomRange            ; 0, 1 or 2 picks the star style
    cmp eax, 0
    je DimStar
    cmp eax, 1
    je MidStar
    mov al, '+'
    mov bl, red
    jmp PutStar
DimStar:
    mov al, '.'
    mov bl, gray
    jmp PutStar
MidStar:
    mov al, '*'
    mov bl, lightBlue
PutStar:
    call PutCharAt    ; calls PutCharAt (line 248)
    pop ecx
    dec ecx
    jnz StarLoop                ; (loop body is long, so no LOOP instruction)
    ret
DrawStars ENDP

; --------------------------------------------------------------------------
;  DrawBanner
;  HOW IT WORKS : Draws the 10 rows of the big "SPACE SHOOTER" block letters.
;                 Each row's address, screen row and colour come from three
;                 tables in .data (bannerRows, bannerRowY, bannerColor).
;  CONNECTS TO  : Called by DrawMenuStatic.  Uses PrintCentered.
; --------------------------------------------------------------------------
DrawBanner PROC USES ebx edx esi edi
    mov edi, 0                  ; row index 0..9
BannerLoop:
    mov esi, bannerRows[edi * TYPE bannerRows]
    mov dh, bannerRowY[edi]
    mov bl, bannerColor[edi]
    call PrintCentered    ; calls PrintCentered (line 300)
    inc edi
    cmp edi, LENGTHOF bannerRowY
    jb BannerLoop
    ret
DrawBanner ENDP

; --------------------------------------------------------------------------
;  DrawSubtitle
;  HOW IT WORKS : Prints "CONSOLE EDITION" using the colour stored in
;                 subColor.  ShowMenu flips that colour now and then so the
;                 line seems to blink.
;  CONNECTS TO  : Called by DrawMenuStatic and by ShowMenu's idle animation.
; --------------------------------------------------------------------------
DrawSubtitle PROC USES ebx edx esi
    TEXTCENTER 13, subColor, msgSub    ; calls PrintCentered (line 300)
    ret
DrawSubtitle ENDP

; --------------------------------------------------------------------------
;  DrawMenuOptions
;  HOW IT WORKS : Draws the three menu bars.  The one whose number equals
;                 menuSel gets the bright highlight colour, the others are grey.
;  CONNECTS TO  : Called by DrawMenuStatic and again by ShowMenu every time the
;                 player moves the selection.
; --------------------------------------------------------------------------
DrawMenuOptions PROC USES eax ebx edx esi edi
    mov edi, 0                  ; option number 0..2
OptLoop:
    mov esi, menuText[edi * TYPE menuText]
    mov eax, edi
    shl eax, 1                  ; option * 2  (one blank row between options)
    add eax, 15                 ; first option is on row 15
    mov dh, al
    mov bl, CLR_DEFAULT    ; constants: CLR_DEFAULT (line 57)
    movzx eax, menuSel
    cmp eax, edi
    jne NotSelected
    mov bl, CLR_SELECT          ; this is the chosen option  | constants: CLR_SELECT (line 58)
NotSelected:
    call PrintCentered    ; calls PrintCentered (line 300)
    inc edi
    cmp edi, 3
    jb OptLoop
    ret
DrawMenuOptions ENDP

; --------------------------------------------------------------------------
;  DrawMenuStatic
;  HOW IT WORKS : Builds the whole menu picture once: clear screen, stars,
;                 big title, blinking sub-title, options, key hint, the saved
;                 high score and a small credit line.
;  CONNECTS TO  : Called at the start of ShowMenu.  Uses DrawStars,
;                 DrawBanner, DrawSubtitle, DrawMenuOptions, PrintNumAt.
; --------------------------------------------------------------------------
DrawMenuStatic PROC USES eax ebx edx esi
    call ClearScreen    ; calls ClearScreen (line 355)
    call DrawStars    ; calls DrawStars (line 399)
    call DrawBanner    ; calls DrawBanner (line 441)
    call DrawSubtitle    ; calls DrawSubtitle (line 461)
    call DrawMenuOptions    ; calls DrawMenuOptions (line 473)
    TEXTCENTER 21, gray, msgMenuHint    ; calls PrintCentered (line 300)
    TEXTAT 23, 24, brown, msgCredit    ; calls PrintAt (line 282)
    TEXTAT 22, 29, lightCyan, msgHiLabel    ; calls PrintAt (line 282)
    mov dh, 22
    mov dl, 42
    mov bl, yellow
    mov eax, highScore
    call PrintNumAt    ; calls PrintNumAt (line 318)
    ret
DrawMenuStatic ENDP

; --------------------------------------------------------------------------
;  ShowMenu
;  HOW IT WORKS : Draws the menu, then loops: read a key without waiting
;                 (ReadKey); UP/DOWN (or W/S) move the highlight, ENTER or
;                 SPACE choose, ESC means Exit.  When no key is waiting the
;                 sub-title colour is toggled a bit to animate the screen.
;  OUTPUT       : EAX = 0 Start game, 1 Instructions, 2 Exit
;  CONNECTS TO  : Called by main.  Uses DrawMenuStatic / DrawMenuOptions /
;                 DrawSubtitle.  ReadKey gives the key in DX (virtual-key code).
; --------------------------------------------------------------------------
ShowMenu PROC USES ebx ecx edx esi
    call DrawMenuStatic    ; calls DrawMenuStatic (line 502)
    call ReadKeyFlush           ; throw away keys pressed earlier
MenuLoop:
    call ReadKey                ; ZF = 1 when no key is waiting
    jz NoKey
    cmp dx, VK_UP
    je GoUp
    cmp dx, 'W'
    je GoUp
    cmp dx, VK_DOWN
    je GoDown
    cmp dx, 'S'
    je GoDown
    cmp dx, VK_RETURN
    je Chosen
    cmp dx, VK_SPACE
    je Chosen
    cmp dx, VK_ESCAPE
    je EscChosen
    jmp MenuLoop

GoUp:
    mov al, menuSel
    cmp al, 0
    jne UpNormal
    mov al, 2                   ; from the first option wrap to the last
    jmp SetSel
UpNormal:
    dec al
    jmp SetSel
GoDown:
    mov al, menuSel
    inc al
    cmp al, 3
    jb SetSel
    mov al, 0                   ; from the last option wrap to the first
SetSel:
    mov menuSel, al
    call DrawMenuOptions    ; calls DrawMenuOptions (line 473)
    jmp MenuLoop

NoKey:                          ; idle: blink the sub-title every 5 passes
    inc menuTick
    cmp menuTick, 5
    jb MenuIdle
    mov menuTick, 0
    xor subColor, 8             ; flips bright green <-> dark green
    call DrawSubtitle    ; calls DrawSubtitle (line 461)
MenuIdle:
    mov eax, 60
    call Delay
    jmp MenuLoop

EscChosen:
    mov menuSel, 2              ; ESC acts like choosing Exit
Chosen:
    movzx eax, menuSel
    ret
ShowMenu ENDP

; --------------------------------------------------------------------------
;  ShowInstructions
;  HOW IT WORKS : Clears the screen and prints controls, the list of enemy
;                 types and the rules.  The enemy rows are drawn from the very
;                 same tables the game uses (symbol, colour, points, name,
;                 description), so this page can never disagree with the game.
;                 Then it waits for any key.
;  CONNECTS TO  : Called by main when "INSTRUCTIONS" is chosen.
; --------------------------------------------------------------------------
ShowInstructions PROC USES eax ebx ecx edx esi edi
    call ClearScreen    ; calls ClearScreen (line 355)
    TEXTCENTER 1, yellow, inTitle    ; calls PrintCentered (line 300)
    TEXTAT 3, 10, lightCyan, inCtl    ; calls PrintAt (line 282)
    TEXTAT 4, 12, white, inK1    ; calls PrintAt (line 282)
    TEXTAT 4, 36, lightGray, inD1    ; calls PrintAt (line 282)
    TEXTAT 5, 12, white, inK2    ; calls PrintAt (line 282)
    TEXTAT 5, 36, lightGray, inD2    ; calls PrintAt (line 282)
    TEXTAT 6, 12, white, inK3    ; calls PrintAt (line 282)
    TEXTAT 6, 36, lightGray, inD3    ; calls PrintAt (line 282)
    TEXTAT 7, 12, white, inK4    ; calls PrintAt (line 282)
    TEXTAT 7, 36, lightGray, inD4    ; calls PrintAt (line 282)
    TEXTAT 8, 12, white, inK5    ; calls PrintAt (line 282)
    TEXTAT 8, 36, lightGray, inD5    ; calls PrintAt (line 282)

    TEXTAT 10, 10, lightCyan, inEnemies    ; calls PrintAt (line 282)
    mov edi, 0                  ; enemy type 0..2
EnemyRow:
    mov eax, edi
    add eax, 11                 ; rows 11, 12, 13
    mov dh, al
    mov dl, 12
    mov al, typeChar[edi]       ; the enemy's own symbol...
    mov bl, typeColor[edi]      ; ...in the enemy's own colour
    call PutCharAt    ; calls PutCharAt (line 248)
    mov dl, 15
    mov bl, white
    mov esi, typeName[edi * TYPE typeName]
    call PrintAt    ; calls PrintAt (line 282)
    mov dl, 24
    movzx eax, typePoints[edi]
    mov bl, yellow
    call PrintNumAt    ; calls PrintNumAt (line 318)
    mov dl, 27
    mov bl, yellow
    mov esi, OFFSET inPts
    call PrintAt    ; calls PrintAt (line 282)
    mov dl, 36
    mov bl, lightGray
    mov esi, typeDesc[edi * TYPE typeDesc]
    call PrintAt    ; calls PrintAt (line 282)
    inc edi
    cmp edi, ENEMY_TYPES    ; constants: ENEMY_TYPES (line 43)
    jb EnemyRow

    TEXTAT 15, 10, lightCyan, inRules    ; calls PrintAt (line 282)
    TEXTAT 16, 12, lightGray, inR1    ; calls PrintAt (line 282)
    TEXTAT 17, 12, lightGray, inR2    ; calls PrintAt (line 282)
    TEXTAT 18, 12, lightGray, inR3    ; calls PrintAt (line 282)
    TEXTCENTER 22, lightGreen, inBack    ; calls PrintCentered (line 300)

    call ReadKeyFlush
WaitKey:
    call ReadKey
    jnz HelpDone                ; a key was pressed
    mov eax, 50
    call Delay
    jmp WaitKey
HelpDone:
    ret
ShowInstructions ENDP

; --------------------------------------------------------------------------
;  ShowGameOver
;  HOW IT WORKS : Shows the final score, level and high score (plus a flashy
;                 line if it is a new record) and waits for R/ENTER (retry)
;                 or M/ESC (menu).
;  OUTPUT       : EAX = 1 play again, 0 go to the main menu
;  CONNECTS TO  : Called by main after RunGame reports the player died.
; --------------------------------------------------------------------------
ShowGameOver PROC USES ebx ecx edx esi
    call ClearScreen    ; calls ClearScreen (line 355)
    TEXTCENTER 5, lightRed, goTitle    ; calls PrintCentered (line 300)
    TEXTAT 9, 28, lightCyan, goScore    ; calls PrintAt (line 282)
    mov dh, 9
    mov dl, 44
    mov bl, yellow
    mov eax, score
    call PrintNumAt    ; calls PrintNumAt (line 318)
    TEXTAT 10, 28, lightCyan, goLevel    ; calls PrintAt (line 282)
    mov dh, 10
    mov dl, 44
    mov bl, yellow
    mov eax, level
    call PrintNumAt    ; calls PrintNumAt (line 318)
    TEXTAT 11, 28, lightCyan, goHigh    ; calls PrintAt (line 282)
    mov dh, 11
    mov dl, 44
    mov bl, lightMagenta
    mov eax, highScore
    call PrintNumAt    ; calls PrintNumAt (line 318)
    cmp newHigh, 1
    jne NoRecord
    TEXTCENTER 13, yellow, goNew    ; calls PrintCentered (line 300)
NoRecord:
    TEXTCENTER 16, lightGreen, goRetry    ; calls PrintCentered (line 300)
    TEXTCENTER 17, lightGray, goMenu    ; calls PrintCentered (line 300)
    call ReadKeyFlush
OverWait:
    call ReadKey
    jz OverSleep
    cmp dx, 'R'
    je Retry
    cmp dx, VK_RETURN
    je Retry
    cmp dx, 'M'
    je ToMenu
    cmp dx, VK_ESCAPE
    je ToMenu
OverSleep:
    mov eax, 50
    call Delay
    jmp OverWait
Retry:
    mov eax, 1
    ret
ToMenu:
    mov eax, 0
    ret
ShowGameOver ENDP

; ==========================================================================
;  5. GAME SET-UP AND THE MAIN GAME LOOP
; ==========================================================================

; --------------------------------------------------------------------------
;  InitGame
;  HOW IT WORKS : Puts every game number back to its start value: score 0,
;                 level 1, full lives, ship in the middle.  The three pools
;                 (bullets, enemies, explosions) are emptied with REP STOSB,
;                 which fills a block of memory with zeros in one instruction.
;  CONNECTS TO  : Called at the start of every game by RunGame.
; --------------------------------------------------------------------------
InitGame PROC USES eax ecx edi
    cld                         ; string instructions must walk forward
    mov al, 0
    mov edi, OFFSET bulletActive
    mov ecx, MAX_BULLETS    ; constants: MAX_BULLETS (line 40)
    rep stosb
    mov edi, OFFSET enemyActive
    mov ecx, MAX_ENEMIES    ; constants: MAX_ENEMIES (line 41)
    rep stosb
    mov edi, OFFSET explTimer
    mov ecx, MAX_EXPL    ; constants: MAX_EXPL (line 42)
    rep stosb

    mov score, 0
    mov level, 1
    mov lives, START_LIVES    ; constants: START_LIVES (line 45)
    mov playerX, 40
    mov spawnCounter, 20        ; first enemy appears after about a second
    mov fireCooldown, 0
    mov quitFlag, 0
    mov hudDirty, 1
    mov levelFlash, 0
    mov newHigh, 0
    ret
InitGame ENDP

; --------------------------------------------------------------------------
;  RunGame
;  HOW IT WORKS : This is THE GAME LOOP.  After InitGame it repeats one frame:
;                   1 HandleInput      - keys: move, shoot, pause, quit
;                   2 UpdateBullets    - bullets fly up
;                   3 CheckCollisions  - did a bullet hit an enemy?
;                   4 UpdateEnemies    - enemies step down / reach the bottom
;                   5 SpawnEnemy       - maybe create a new enemy
;                   6 CheckCollisions  - again (see the note in that procedure)
;                   7 UpdateExplosions - age and erase explosions
;                   8 UpdateDifficulty - raise the level when the score allows
;                   9 DrawAll          - paint everything
;                  10 Delay            - short sleep = steady frame rate
;                 The loop ends when lives reach 0 or the player quits.
;  OUTPUT       : EAX = 1 the player died, 0 the player quit with ESC
;  CONNECTS TO  : Called by main.  It is the "boss" that calls nearly every
;                 other game procedure below, in the order listed above.
; --------------------------------------------------------------------------
RunGame PROC USES ebx ecx edx esi edi
    call InitGame    ; calls InitGame (line 732)
    call ClearScreen    ; calls ClearScreen (line 355)
    call DrawHUDStatic    ; calls DrawHUDStatic (line 1308)
GameFrame:
    call HandleInput    ; calls HandleInput (line 898)
    cmp quitFlag, 1
    je PlayerQuit
    call UpdateBullets    ; calls UpdateBullets (line 993)
    call CheckCollisions    ; calls CheckCollisions (line 1268)
    call UpdateEnemies    ; calls UpdateEnemies (line 1135)
    call SpawnEnemy    ; calls SpawnEnemy (line 1049)
    call CheckCollisions    ; calls CheckCollisions (line 1268)
    call UpdateExplosions    ; calls UpdateExplosions (line 1192)
    call UpdateDifficulty    ; calls UpdateDifficulty (line 826)
    call DrawAll    ; calls DrawAll (line 1456)
    cmp lives, 0
    je PlayerDied
    mov eax, FRAME_MS    ; constants: FRAME_MS (line 50)
    call Delay
    jmp GameFrame

PlayerDied:
    mov eax, 900                ; hold the last frame so the player sees the hit
    call Delay
    cmp newHigh, 1
    jne DiedNoSave
    call SaveHighScore    ; calls SaveHighScore (line 1529)
DiedNoSave:
    mov eax, 1
    ret

PlayerQuit:
    cmp newHigh, 1
    jne QuitNoSave
    call SaveHighScore    ; calls SaveHighScore (line 1529)
QuitNoSave:
    mov eax, 0
    ret
RunGame ENDP

; --------------------------------------------------------------------------
;  UpdateDifficulty
;  HOW IT WORKS : level = score / 150 + 1 (DIV gives the whole-number part),
;                 capped at MAX_LEVEL.  If the level went up it flags the HUD
;                 for redraw and starts the "LEVEL UP!" banner timer.  The
;                 level number itself is what makes enemies faster: see
;                 EnemyInterval and SpawnEnemy, which read it.
;  CONNECTS TO  : Called every frame by RunGame.  Reads score, writes level.
; --------------------------------------------------------------------------
UpdateDifficulty PROC USES eax ebx edx
    mov edx, 0                  ; DIV needs EDX = 0 for a 32-bit dividend
    mov eax, score
    mov ebx, POINTS_PER_LEVEL    ; constants: POINTS_PER_LEVEL (line 46)
    div ebx                     ; EAX = score / 150
    inc eax                     ; levels start at 1
    cmp eax, MAX_LEVEL    ; constants: MAX_LEVEL (line 47)
    jbe LevelOk
    mov eax, MAX_LEVEL    ; constants: MAX_LEVEL (line 47)
LevelOk:
    cmp eax, level
    je NoChange
    mov level, eax
    mov hudDirty, 1
    mov levelFlash, 36          ; show the banner for 36 frames
NoChange:
    ret
UpdateDifficulty ENDP

; --------------------------------------------------------------------------
;  PauseGame
;  HOW IT WORKS : Draws a small box in the middle and waits.  P resumes; ESC
;                 sets quitFlag so RunGame goes back to the menu.  When
;                 resuming, the screen is cleared and the HUD bar redrawn
;                 (the box covered part of the playfield); DrawAll then paints
;                 the ships and enemies again on the next frame.
;  CONNECTS TO  : Called by HandleInput when the player presses P.
; --------------------------------------------------------------------------
PauseGame PROC USES eax ebx edx esi
    TEXTCENTER 10, lightCyan, pz1    ; calls PrintCentered (line 300)
    TEXTCENTER 11, yellow, pz2    ; calls PrintCentered (line 300)
    TEXTCENTER 12, lightCyan, pz3    ; calls PrintCentered (line 300)
    TEXTCENTER 13, white, pz4    ; calls PrintCentered (line 300)
    TEXTCENTER 14, white, pz5    ; calls PrintCentered (line 300)
    TEXTCENTER 15, lightCyan, pz1    ; calls PrintCentered (line 300)
    call ReadKeyFlush
PauseWait:
    call ReadKey
    jz PauseSleep
    cmp dx, 'P'
    je Resume
    cmp dx, VK_ESCAPE
    je QuitPause
PauseSleep:
    mov eax, 40
    call Delay
    jmp PauseWait
QuitPause:
    mov quitFlag, 1
    ret
Resume:
    call ClearScreen    ; calls ClearScreen (line 355)
    call DrawHUDStatic    ; calls DrawHUDStatic (line 1308)
    mov hudDirty, 1
    ret
PauseGame ENDP

; ==========================================================================
;  6. INPUT, PLAYER, BULLETS, ENEMIES, EXPLOSIONS, COLLISIONS
; ==========================================================================

; --------------------------------------------------------------------------
;  HandleInput
;  HOW IT WORKS : Counts the fire cool-down down by one, then reads up to 3
;                 waiting keys with ReadKey (it never waits, so the game keeps
;                 running when nothing is pressed).  ReadKey returns the
;                 virtual-key code in DX, which is the same for upper and lower
;                 case letters.  A / D and the arrow keys move; SPACE fires; P
;                 pauses; ESC quits.  The ship may not leave columns 1..78.
;  CONNECTS TO  : Called first in every frame by RunGame.  Calls FireBullet
;                 and PauseGame, uses EraseCell to wipe the ship's old cell.
; --------------------------------------------------------------------------
HandleInput PROC USES eax ebx edx
    cmp fireCooldown, 0
    je CooledDown
    dec fireCooldown
CooledDown:
    mov keyBudget, 3            ; (kept in memory: ReadKey changes EBX)
KeyLoop:
    call ReadKey
    jz KeysDone                 ; nothing waiting
    cmp dx, VK_LEFT
    je MoveLeft
    cmp dx, 'A'
    je MoveLeft
    cmp dx, VK_RIGHT
    je MoveRight
    cmp dx, 'D'
    je MoveRight
    cmp dx, VK_SPACE
    je DoFire
    cmp dx, 'P'
    je DoPause
    cmp dx, VK_ESCAPE
    je DoQuit
    jmp NextKey

MoveLeft:
    cmp playerX, LEFT_LIMIT    ; constants: LEFT_LIMIT (line 37)
    jbe NextKey                 ; already at the left wall
    mov dl, playerX
    mov dh, PLAYER_ROW    ; constants: PLAYER_ROW (line 36)
    call EraseCell              ; wipe the old ship cell first  | calls EraseCell (line 267)
    dec playerX
    jmp NextKey
MoveRight:
    cmp playerX, RIGHT_LIMIT    ; constants: RIGHT_LIMIT (line 38)
    jae NextKey                 ; already at the right wall
    mov dl, playerX
    mov dh, PLAYER_ROW    ; constants: PLAYER_ROW (line 36)
    call EraseCell    ; calls EraseCell (line 267)
    inc playerX
    jmp NextKey
DoFire:
    cmp fireCooldown, 0
    jne NextKey                 ; still cooling down
    call FireBullet    ; calls FireBullet (line 968)
    mov fireCooldown, FIRE_COOLDOWN    ; constants: FIRE_COOLDOWN (line 48)
    jmp NextKey
DoPause:
    call PauseGame    ; calls PauseGame (line 854)
    jmp KeysDone                ; stop reading, the screen was redrawn
DoQuit:
    mov quitFlag, 1
    jmp KeysDone

NextKey:
    dec keyBudget
    jnz KeyLoop
KeysDone:
    ret
HandleInput ENDP

; --------------------------------------------------------------------------
;  FireBullet
;  HOW IT WORKS : Looks through the bullet pool for a free slot (bulletActive
;                 = 0).  If it finds one, the bullet is switched on just above
;                 the ship.  If all 6 are busy nothing happens, which is the
;                 limit that keeps the game balanced.
;  CONNECTS TO  : Called by HandleInput when SPACE is pressed.  The bullet is
;                 then moved by UpdateBullets and drawn by DrawBullets.
; --------------------------------------------------------------------------
FireBullet PROC USES eax ecx esi
    mov esi, 0
    mov ecx, MAX_BULLETS    ; constants: MAX_BULLETS (line 40)
FindSlot:
    cmp bulletActive[esi], 0
    je SlotFound
    inc esi
    loop FindSlot
    ret                         ; no free slot
SlotFound:
    mov al, playerX
    mov bulletX[esi], al
    mov bulletY[esi], PLAYER_ROW - 1    ; constants: PLAYER_ROW (line 36)
    mov bulletActive[esi], 1
    ret
FireBullet ENDP

; --------------------------------------------------------------------------
;  UpdateBullets
;  HOW IT WORKS : For every active bullet: erase its old cell, move it one row
;                 up, and switch it off if it flew past the top of the
;                 playfield.  (Drawing the new position is done later by
;                 DrawBullets.)
;  CONNECTS TO  : Called by RunGame every frame, before the first collision test.
; --------------------------------------------------------------------------
UpdateBullets PROC USES edx esi
    mov esi, 0
BulletLoop:
    cmp bulletActive[esi], 0
    je NextBullet
    mov dl, bulletX[esi]
    mov dh, bulletY[esi]
    call EraseCell    ; calls EraseCell (line 267)
    dec bulletY[esi]            ; one row up
    cmp bulletY[esi], PLAY_TOP    ; constants: PLAY_TOP (line 35)
    jae NextBullet              ; still inside the playfield
    mov bulletActive[esi], 0    ; left the top: free the slot
NextBullet:
    inc esi
    cmp esi, MAX_BULLETS    ; constants: MAX_BULLETS (line 40)
    jb BulletLoop
    ret
UpdateBullets ENDP

; --------------------------------------------------------------------------
;  EnemyInterval
;  HOW IT WORKS : Works out how many frames an enemy waits between two steps
;                 down:  base time of its type  minus (level - 1), but never
;                 below that type's minimum.  So higher level = faster enemies,
;                 and each type keeps its own personality (Striker fast, Tank
;                 slow).
;  INPUT        : BL = enemy type          OUTPUT : AL = frames per step
;  CONNECTS TO  : Used by SpawnEnemy (first timer) and UpdateEnemies (reload).
; --------------------------------------------------------------------------
EnemyInterval PROC USES ebx ecx edx
    movzx ebx, bl
    movzx eax, typeMoveBase[ebx]
    mov ecx, level
    dec ecx
    sub eax, ecx                ; base - (level - 1)
    movzx edx, typeMoveMin[ebx]
    cmp eax, edx
    jge IntervalOk              ; signed compare: eax may have gone negative
    mov eax, edx
IntervalOk:
    ret
EnemyInterval ENDP

; --------------------------------------------------------------------------
;  SpawnEnemy
;  HOW IT WORKS : A countdown (spawnCounter) ticks down once per frame.  When
;                 it hits 0 it is reloaded with a shorter value as the level
;                 rises (40 - 3*(level-1) frames, min 12) and one enemy is made:
;                    - a free slot is found in the enemy pool,
;                    - the TYPE is picked at random: Drones always, Strikers
;                      join from level 2, Tanks from level 3,
;                    - a random column 1..78 is chosen, row 1 (top),
;                    - hit points and first step timer come from the type tables.
;  CONNECTS TO  : Called every frame by RunGame.  Uses RandomRange and
;                 EnemyInterval.  The enemy is later moved by UpdateEnemies.
; --------------------------------------------------------------------------
SpawnEnemy PROC USES eax ebx ecx edx esi
    dec spawnCounter
    jnz SpawnDone               ; not time yet

    mov eax, level              ; reload the countdown for next time
    dec eax
    imul eax, SPAWN_STEP    ; constants: SPAWN_STEP (line 53)
    neg eax
    add eax, SPAWN_BASE         ; 40 - 3*(level-1)  | constants: SPAWN_BASE (line 52)
    cmp eax, SPAWN_MIN    ; constants: SPAWN_MIN (line 54)
    jge IntervalSet
    mov eax, SPAWN_MIN    ; constants: SPAWN_MIN (line 54)
IntervalSet:
    mov spawnCounter, eax

    mov esi, 0                  ; find a free enemy slot
    mov ecx, MAX_ENEMIES    ; constants: MAX_ENEMIES (line 41)
FreeSlot:
    cmp enemyActive[esi], 0
    je GotSlot
    inc esi
    dec ecx
    jnz FreeSlot
    ret                         ; screen is full of enemies, skip this spawn
GotSlot:

    mov eax, 100                ; pick the type
    call RandomRange            ; 0..99
    mov bl, 0                   ; default: Drone
    cmp level, 3
    jb TryStriker
    cmp eax, 85
    jb TryStriker
    mov bl, 2                   ; Tank (level 3+, 15 % chance)
    jmp TypeChosen
TryStriker:
    cmp level, 2
    jb TypeChosen
    cmp eax, 55
    jb TypeChosen
    mov bl, 1                   ; Striker (level 2+, 30 % chance)
TypeChosen:
    mov enemyType[esi], bl
    movzx ecx, bl
    mov al, typeHP[ecx]
    mov enemyHP[esi], al
    mov enemyY[esi], PLAY_TOP    ; constants: PLAY_TOP (line 35)
    mov eax, RIGHT_LIMIT - LEFT_LIMIT + 1    ; constants: RIGHT_LIMIT (line 38), LEFT_LIMIT (line 37)
    call RandomRange            ; 0..77
    add al, LEFT_LIMIT          ; 1..78  | constants: LEFT_LIMIT (line 37)
    mov enemyX[esi], al
    call EnemyInterval          ; BL = type  ->  AL = frames per step  | calls EnemyInterval (line 1022)
    mov enemyTimer[esi], al
    mov enemyActive[esi], 1
SpawnDone:
    ret
SpawnEnemy ENDP

; --------------------------------------------------------------------------
;  LoseLife
;  HOW IT WORKS : Takes one life away (never below 0) and asks the HUD to be
;                 redrawn so the player sees the new number.
;  CONNECTS TO  : Called by UpdateEnemies when an enemy reaches the bottom row.
;                 RunGame notices lives = 0 and ends the game.
; --------------------------------------------------------------------------
LoseLife PROC
    cmp lives, 0
    je AlreadyZero
    dec lives
    mov hudDirty, 1
AlreadyZero:
    ret
LoseLife ENDP

; --------------------------------------------------------------------------
;  UpdateEnemies
;  HOW IT WORKS : Each active enemy has its own little timer.  Every frame the
;                 timer goes down; at 0 the enemy erases itself, steps one row
;                 down and reloads its timer (so different types walk at
;                 different speeds).  An enemy that steps onto the ship's row
;                 (row 24) either crashed into the ship (same column) or slipped
;                 past it - the rules treat both the same: it disappears in an
;                 explosion and the player loses one life.
;  CONNECTS TO  : Called every frame by RunGame.  Uses EnemyInterval, EraseCell,
;                 AddExplosion and LoseLife.
; --------------------------------------------------------------------------
UpdateEnemies PROC USES eax ebx edx esi
    mov esi, 0
EnemyLoop:
    cmp enemyActive[esi], 0
    je NextEnemy
    dec enemyTimer[esi]
    jnz NextEnemy               ; not its turn to move yet
    mov bl, enemyType[esi]
    call EnemyInterval    ; calls EnemyInterval (line 1022)
    mov enemyTimer[esi], al     ; reload the timer
    mov dl, enemyX[esi]
    mov dh, enemyY[esi]
    call EraseCell              ; wipe the old cell  | calls EraseCell (line 267)
    inc enemyY[esi]             ; step down
    cmp enemyY[esi], PLAYER_ROW    ; constants: PLAYER_ROW (line 36)
    jb NextEnemy                ; still above the ship's row
    mov enemyActive[esi], 0     ; reached the bottom: it is gone...
    mov dh, PLAYER_ROW    ; constants: PLAYER_ROW (line 36)
    call AddExplosion           ; ...with a bang (DL still holds the column)  | calls AddExplosion (line 1170)
    call LoseLife               ; ...and it costs a life  | calls LoseLife (line 1114)
NextEnemy:
    inc esi
    cmp esi, MAX_ENEMIES    ; constants: MAX_ENEMIES (line 41)
    jb EnemyLoop
    ret
UpdateEnemies ENDP

; --------------------------------------------------------------------------
;  AddExplosion
;  HOW IT WORKS : Finds a free slot in the explosion pool and starts a '*'
;                 there that will stay for EXPL_FRAMES frames.
;  INPUT        : DL = column, DH = row
;  CONNECTS TO  : Called when an enemy dies or reaches the bottom.  The star
;                 is aged/erased by UpdateExplosions and drawn by DrawExplosions.
; --------------------------------------------------------------------------
AddExplosion PROC USES esi
    mov esi, 0
ExplFind:
    cmp explTimer[esi], 0
    je ExplFree
    inc esi
    cmp esi, MAX_EXPL    ; constants: MAX_EXPL (line 42)
    jb ExplFind
    ret                         ; pool full, skip the visual effect
ExplFree:
    mov explX[esi], dl
    mov explY[esi], dh
    mov explTimer[esi], EXPL_FRAMES    ; constants: EXPL_FRAMES (line 49)
    ret
AddExplosion ENDP

; --------------------------------------------------------------------------
;  UpdateExplosions
;  HOW IT WORKS : Counts every explosion's timer down.  When one reaches 0 its
;                 '*' is erased and the slot becomes free again.
;  CONNECTS TO  : Called every frame by RunGame (after the collision tests).
; --------------------------------------------------------------------------
UpdateExplosions PROC USES edx esi
    mov esi, 0
ExplLoop:
    cmp explTimer[esi], 0
    je NextExpl
    dec explTimer[esi]
    jnz NextExpl                ; still burning
    mov dl, explX[esi]
    mov dh, explY[esi]
    call EraseCell              ; burnt out: remove the star  | calls EraseCell (line 267)
NextExpl:
    inc esi
    cmp esi, MAX_EXPL    ; constants: MAX_EXPL (line 42)
    jb ExplLoop
    ret
UpdateExplosions ENDP

; --------------------------------------------------------------------------
;  HandleHit
;  HOW IT WORKS : Called when bullet ESI and enemy EDI are on the same cell.
;                 The bullet is always used up (erased and freed).  The enemy
;                 loses 1 hit point; if it still has some (a Tank's first hit)
;                 it simply survives and will be drawn in its "hurt" colour.
;                 If it reaches 0 it is erased, an explosion starts, and points
;                 are added:  type points + 2*(level-1)  (more at higher levels).
;                 The high score is raised if the score passes it.
;  INPUT        : ESI = bullet index, EDI = enemy index
;  CONNECTS TO  : Called by CheckCollisions.  Sets hudDirty so DrawHUD updates.
; --------------------------------------------------------------------------
HandleHit PROC USES eax ebx ecx edx
    mov dl, bulletX[esi]
    mov dh, bulletY[esi]
    call EraseCell              ; remove the bullet  | calls EraseCell (line 267)
    mov bulletActive[esi], 0

    dec enemyHP[edi]
    jnz HitDone                 ; enemy survived (damaged Tank)

    mov dl, enemyX[edi]
    mov dh, enemyY[edi]
    call EraseCell              ; remove the dead enemy  | calls EraseCell (line 267)
    mov enemyActive[edi], 0
    call AddExplosion           ; boom (DL, DH = enemy position)  | calls AddExplosion (line 1170)

    movzx ebx, enemyType[edi]
    movzx eax, typePoints[ebx]  ; base points of this type
    mov ecx, level
    dec ecx
    shl ecx, 1                  ; 2 * (level - 1)
    add eax, ecx
    add score, eax
    mov hudDirty, 1

    mov eax, score
    cmp eax, highScore
    jbe HitDone
    mov highScore, eax          ; new record
    mov newHigh, 1
HitDone:
    ret
HandleHit ENDP

; --------------------------------------------------------------------------
;  CheckCollisions
;  HOW IT WORKS : Two nested loops: the outer one walks every active bullet,
;                 the inner one every active enemy.  If both share the same
;                 column AND the same row they hit, and HandleHit deals with it
;                 (a bullet can hit only one enemy, so the inner loop stops).
;                 (An enemy touching the ship is handled in UpdateEnemies,
;                 because the ship lives on the bottom row where enemies end.)
;                 WHY RunGame CALLS THIS TWICE PER FRAME: bullets move up and
;                 enemies move down in the same frame, so they could swap rows
;                 without ever sharing a cell and the bullet would pass right
;                 through.  Testing after each movement closes that gap.
;  CONNECTS TO  : Called twice per frame by RunGame.  Uses HandleHit.
; --------------------------------------------------------------------------
CheckCollisions PROC USES eax esi edi
    mov esi, 0                  ; bullet index
BulletTest:
    cmp bulletActive[esi], 0
    je NextBulletTest
    mov edi, 0                  ; enemy index
EnemyTest:
    cmp enemyActive[edi], 0
    je NextEnemyTest
    mov al, bulletX[esi]
    cmp al, enemyX[edi]
    jne NextEnemyTest           ; different column
    mov al, bulletY[esi]
    cmp al, enemyY[edi]
    jne NextEnemyTest           ; different row
    call HandleHit              ; same cell = HIT  | calls HandleHit (line 1221)
    jmp NextBulletTest          ; this bullet is used up
NextEnemyTest:
    inc edi
    cmp edi, MAX_ENEMIES    ; constants: MAX_ENEMIES (line 41)
    jb EnemyTest
NextBulletTest:
    inc esi
    cmp esi, MAX_BULLETS    ; constants: MAX_BULLETS (line 40)
    jb BulletTest
    ret
CheckCollisions ENDP

; ==========================================================================
;  7. DRAWING
; ==========================================================================

; --------------------------------------------------------------------------
;  DrawHUDStatic
;  HOW IT WORKS : Paints the blue bar on row 0 (80 blue spaces) and writes the
;                 fixed words SCORE / LIVES / LEVEL / HI and the P=Pause hint.
;                 The changing numbers are added by DrawHUD.
;  CONNECTS TO  : Called when a game starts and after the pause box closes.
;                 Uses DrawHLine and TEXTAT (PrintAt).
; --------------------------------------------------------------------------
DrawHUDStatic PROC USES eax ebx ecx edx esi
    mov dh, HUD_ROW    ; constants: HUD_ROW (line 34)
    mov dl, 0
    mov ecx, SCREEN_W    ; constants: SCREEN_W (line 33)
    mov al, ' '
    mov bl, CLR_HUD    ; constants: CLR_HUD (line 59)
    call DrawHLine    ; calls DrawHLine (line 335)
    TEXTAT HUD_ROW, 1, CLR_HUD_LABEL, hudScore    ; calls PrintAt (line 282) | constants: HUD_ROW (line 34), CLR_HUD_LABEL (line 60)
    TEXTAT HUD_ROW, 24, CLR_HUD_LABEL, hudLives    ; calls PrintAt (line 282) | constants: HUD_ROW (line 34), CLR_HUD_LABEL (line 60)
    TEXTAT HUD_ROW, 40, CLR_HUD_LABEL, hudLevel    ; calls PrintAt (line 282) | constants: HUD_ROW (line 34), CLR_HUD_LABEL (line 60)
    TEXTAT HUD_ROW, 56, CLR_HUD_LABEL, hudHi    ; calls PrintAt (line 282) | constants: HUD_ROW (line 34), CLR_HUD_LABEL (line 60)
    TEXTAT HUD_ROW, 70, CLR_HUD_HINT, hudHint    ; calls PrintAt (line 282) | constants: HUD_ROW (line 34), CLR_HUD_HINT (line 63)
    ret
DrawHUDStatic ENDP

; --------------------------------------------------------------------------
;  DrawHUD
;  HOW IT WORKS : Rewrites the four numbers in the top bar, but only when
;                 hudDirty = 1 (something changed), which saves work.  The lives
;                 number turns green -> yellow -> red as lives run out.
;  CONNECTS TO  : Called every frame by DrawAll.  Reads score, lives, level and
;                 highScore; uses PrintNumAt.
; --------------------------------------------------------------------------
DrawHUD PROC USES eax ebx edx
    cmp hudDirty, 0
    je HudDone
    mov hudDirty, 0

    mov dh, HUD_ROW    ; constants: HUD_ROW (line 34)
    mov dl, 8
    mov bl, CLR_HUD_NUM    ; constants: CLR_HUD_NUM (line 61)
    mov eax, score
    call PrintNumAt    ; calls PrintNumAt (line 318)

    movzx eax, lives
    mov bl, lightGreen + (blue * 16)
    cmp eax, 3
    jae LivesColour
    mov bl, yellow + (blue * 16)
    cmp eax, 2
    jae LivesColour
    mov bl, lightRed + (blue * 16)
LivesColour:
    mov dl, 31
    call PrintNumAt    ; calls PrintNumAt (line 318)

    mov dl, 47
    mov bl, CLR_HUD_NUM    ; constants: CLR_HUD_NUM (line 61)
    mov eax, level
    call PrintNumAt    ; calls PrintNumAt (line 318)

    mov dl, 60
    mov bl, CLR_HUD_HI    ; constants: CLR_HUD_HI (line 62)
    mov eax, highScore
    call PrintNumAt    ; calls PrintNumAt (line 318)
HudDone:
    ret
DrawHUD ENDP

; --------------------------------------------------------------------------
;  DrawExplosions / DrawEnemies / DrawBullets / DrawPlayer
;  HOW THEY WORK: Each walks its pool and draws every active object with
;                 PutCharAt in the object's colour.  Explosions blink between
;                 yellow and red.  Enemies use the symbol and colour of their
;                 type, and the "hurt" colour once their hit points drop below
;                 the type's full value.
;  CONNECTS TO  : All four are called, in this order, by DrawAll.  The order
;                 matters: later ones are painted on top (ship last).
; --------------------------------------------------------------------------
DrawExplosions PROC USES eax ebx edx esi
    mov esi, 0
DrawExplLoop:
    cmp explTimer[esi], 0
    je NextDrawExpl
    mov bl, yellow
    test explTimer[esi], 1
    jz ExplColourSet
    mov bl, lightRed            ; odd frames are red, even frames yellow
ExplColourSet:
    mov dl, explX[esi]
    mov dh, explY[esi]
    mov al, '*'
    call PutCharAt    ; calls PutCharAt (line 248)
NextDrawExpl:
    inc esi
    cmp esi, MAX_EXPL    ; constants: MAX_EXPL (line 42)
    jb DrawExplLoop
    ret
DrawExplosions ENDP

DrawEnemies PROC USES eax ebx ecx edx esi
    mov esi, 0
DrawEnemyLoop:
    cmp enemyActive[esi], 0
    je NextDrawEnemy
    movzx ecx, enemyType[esi]
    mov al, typeChar[ecx]
    mov bl, typeColor[ecx]
    mov dl, enemyHP[esi]
    cmp dl, typeHP[ecx]
    jae FullHealth
    mov bl, typeHurtColor[ecx]  ; damaged: use the hurt colour
FullHealth:
    mov dl, enemyX[esi]
    mov dh, enemyY[esi]
    call PutCharAt    ; calls PutCharAt (line 248)
NextDrawEnemy:
    inc esi
    cmp esi, MAX_ENEMIES    ; constants: MAX_ENEMIES (line 41)
    jb DrawEnemyLoop
    ret
DrawEnemies ENDP

DrawBullets PROC USES eax ebx edx esi
    mov esi, 0
DrawBulletLoop:
    cmp bulletActive[esi], 0
    je NextDrawBullet
    mov dl, bulletX[esi]
    mov dh, bulletY[esi]
    mov al, '|'
    mov bl, CLR_BULLET    ; constants: CLR_BULLET (line 65)
    call PutCharAt    ; calls PutCharAt (line 248)
NextDrawBullet:
    inc esi
    cmp esi, MAX_BULLETS    ; constants: MAX_BULLETS (line 40)
    jb DrawBulletLoop
    ret
DrawBullets ENDP

DrawPlayer PROC USES eax ebx edx
    mov dl, playerX
    mov dh, PLAYER_ROW    ; constants: PLAYER_ROW (line 36)
    mov al, 'A'
    mov bl, CLR_PLAYER    ; constants: CLR_PLAYER (line 64)
    call PutCharAt    ; calls PutCharAt (line 248)
    ret
DrawPlayer ENDP

; --------------------------------------------------------------------------
;  DrawAll
;  HOW IT WORKS : Paints one complete frame.  First the "LEVEL UP!" banner (if
;                 its timer is running - it blinks, and is wiped when the
;                 timer ends), then explosions, enemies, bullets, the ship and
;                 finally the HUD numbers.  Old positions were already erased
;                 by the Update... procedures, so only new positions are drawn.
;  CONNECTS TO  : Called once per frame by RunGame (step 9).
; --------------------------------------------------------------------------
DrawAll PROC USES eax ebx edx esi
    cmp levelFlash, 0
    je NoBanner
    dec levelFlash
    mov bl, yellow
    test levelFlash, 4
    jz BannerColour
    mov bl, lightRed
BannerColour:
    mov dh, 12
    mov esi, OFFSET msgLevelUp
    call PrintCentered    ; calls PrintCentered (line 300)
    cmp levelFlash, 0
    jne NoBanner
    mov bl, CLR_DEFAULT         ; timer ran out: overwrite the banner with blanks  | constants: CLR_DEFAULT (line 57)
    mov dh, 12
    mov esi, OFFSET msgBlank
    call PrintCentered    ; calls PrintCentered (line 300)
NoBanner:
    call DrawExplosions    ; calls DrawExplosions (line 1377)
    call DrawEnemies    ; calls DrawEnemies (line 1398)
    call DrawBullets    ; calls DrawBullets (line 1421)
    call DrawPlayer    ; calls DrawPlayer (line 1438)
    call DrawHUD    ; calls DrawHUD (line 1331)
    ret
DrawAll ENDP

; ==========================================================================
;  8. HIGH SCORE FILE
;  The best score is kept as plain decimal text in "highscore.txt" next to the
;  program, so it is still there the next time the game starts.
; ==========================================================================

; --------------------------------------------------------------------------
;  LoadHighScore
;  HOW IT WORKS : Tries to open highscore.txt.  If the file does not exist
;                 (first run) it just leaves the high score at 0.  Otherwise it
;                 reads the text and converts it to a number with Irvine32's
;                 ParseDecimal32; bad or empty content is ignored.
;  CONNECTS TO  : Called once by main at start-up.  Sets highScore, which the
;                 menu, HUD and game-over screens display.
; --------------------------------------------------------------------------
LoadHighScore PROC USES eax ecx edx
    mov edx, OFFSET hsFileName
    call OpenInputFile          ; EAX = file handle or INVALID_HANDLE_VALUE
    cmp eax, INVALID_HANDLE_VALUE
    je LoadDone                 ; no file yet: nothing to load
    mov hsHandle, eax
    mov edx, OFFSET hsText
    mov ecx, 10
    call ReadFromFile           ; EAX = bytes read, carry set on error
    jc CloseIt
    mov ecx, eax                ; ECX = text length
    jecxz CloseIt               ; empty file
    mov edx, OFFSET hsText
    call ParseDecimal32         ; EAX = value, carry set if not a number
    jc CloseIt
    mov highScore, eax
CloseIt:
    mov eax, hsHandle
    call CloseFile
LoadDone:
    ret
LoadHighScore ENDP

; --------------------------------------------------------------------------
;  SaveHighScore
;  HOW IT WORKS : Turns the number into text digits: it divides by 10 again and
;                 again with DIV; each remainder is one digit (add '0' to make
;                 it a character), filled from right to left into hsText.  Then
;                 the file is created and the digits are written.
;  CONNECTS TO  : Called by RunGame at the end of a game that set a new record.
; --------------------------------------------------------------------------
SaveHighScore PROC USES eax ebx ecx edx edi
    mov eax, highScore
    mov edi, OFFSET hsText + 10 ; one past the end of a 10-byte work area
    mov ebx, 10
    mov ecx, 0                  ; digit counter
DigitLoop:
    mov edx, 0
    div ebx                     ; EAX = rest of the number, EDX = last digit
    add dl, '0'
    dec edi
    mov [edi], dl
    inc ecx
    cmp eax, 0
    jne DigitLoop               ; stop when nothing is left

    mov hsStart, edi            ; Irvine's file procedures may change ECX/EDI,
    mov hsLen, ecx              ; so keep the digits' address and count in memory
    mov edx, OFFSET hsFileName
    call CreateOutputFile       ; EAX = handle
    cmp eax, INVALID_HANDLE_VALUE
    je SaveDone
    mov hsHandle, eax
    mov edx, hsStart            ; EDX = address of the first digit
    mov ecx, hsLen              ; ECX = number of digits
    call WriteToFile            ; EAX = handle (still)
    mov eax, hsHandle
    call CloseFile
SaveDone:
    ret
SaveHighScore ENDP

; ==========================================================================
;  MAIN
; ==========================================================================

; --------------------------------------------------------------------------
;  main
;  HOW IT WORKS : Seeds the random generator, prepares the console and loads the
;                 high score, then runs the screen flow:
;                      menu -> (start) -> game -> game over -> retry or menu
;                           -> (instructions) -> back to menu
;                           -> (exit) -> restore the console and quit.
;  CONNECTS TO  : Top of everything - it calls ShowMenu, RunGame,
;                 ShowGameOver and ShowInstructions.
; --------------------------------------------------------------------------
main PROC C
    call Randomize              ; different random numbers on every run
    call InitConsole    ; calls InitConsole (line 382)
    call LoadHighScore    ; calls LoadHighScore (line 1498)
ShowMainMenu:
    call ShowMenu               ; EAX = choice  | calls ShowMenu (line 529)
    cmp eax, 1
    je ShowHelp
    cmp eax, 2
    je QuitProgram
PlayGame:
    call RunGame                ; EAX = 1 if the player died, 0 if quit by ESC  | calls RunGame (line 776)
    cmp eax, 1
    jne ShowMainMenu            ; quit: straight back to the menu
    call ShowGameOver           ; EAX = 1 retry, 0 menu  | calls ShowGameOver (line 669)
    cmp eax, 1
    je PlayGame
    jmp ShowMainMenu
ShowHelp:
    call ShowInstructions    ; calls ShowInstructions (line 599)
    jmp ShowMainMenu

QuitProgram:
    call ClearScreen    ; calls ClearScreen (line 355)
    mov eax, 1
    call SetCursorVisible       ; give the cursor back  | calls SetCursorVisible (line 370)
    exit                        ; ExitProcess(0)
main ENDP

END main