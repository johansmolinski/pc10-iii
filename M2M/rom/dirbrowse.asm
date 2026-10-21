; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; Directory Browser (with sorted output)
;
; Change in 2023: While this was originally made to be reusable also outside
; of the context of the Shell, from now on dirbrowse.asm is dependent on the
; global variable SF_CONTEXT in shell_vars.asm which will be handed over as a
; parameter R10 to the filter function in _DIRBR_FILTWRAP. To undo this
; change, delete this comment and everything tagged with SF_CONTEXT in
; _DIRBR_FILTWRAP.
;
; done by sy2002 in 2022, 2023 and licensed under GPL v3
; ****************************************************************************

#include "llist.asm"

_DIRBR_DOT      .ASCII_W "."                    ; filter this from dir. views
_DIRBR_DOTDOT   .ASCII_W ".."                   ; (M2M-UPSTREAM sd-host)
_DIRBR_UPDIR    .ASCII_W "<..>"                 ; (M2M-UPSTREAM cfg-strings)
_DIRBR_DS       .EQU    0x3C                    ; ASCII of "<"
_DIRBR_DE       .EQU    0x3E                    ; ASCII of ">"
_DIRBR_DSDESIZE .EQU    2                       ; amount of characters in sum

; ----------------------------------------------------------------------------
; Read and sort all contents of the given path into a heap memory structure
; Input:
;   R8: Pointer to valid device handle
;   R9: Pointer to path that shall be listed (zero-terminated string)
;  R10: Pointer to heap
;  R11: Maximum amount of available heap memory
;  R12: Optional filter function that filters out files of a certain name.
;       The filter function takes a pointer to a string in R8 and a directory
;       flag in R9 (0=it is a file, 1=it is a directory) and returns 0 in R8,
;       if the file shall not be filtered and 1 if it shall be filtered.
;       The string provided in R8 is always in upper case.
;       If R12 is zero, then no filter is applied.
; Output:
;   R8: (unchanged) Pointer to valid device handle
;   R9: Amount of directory entries read
;  R10: head of sorted linked list
;  R11: Return code:
;       0 = OK
;       1 = directory not found
;       2 = more directory items available than memory permits
;       <other value> = error code
; ----------------------------------------------------------------------------

DIRBROWSE_READ  INCRB
                MOVE    R8, R0
                MOVE    R12, R1
                INCRB

                MOVE    R10, R0                 ; R0: head of the heap
                MOVE    R10, R1                 ; R1: current heap ptr
                MOVE    R11, R2                 ; R2: max memory on heap
                XOR     R3, R3                  ; R3: current heap mem. usage
                XOR     R4, R4                  ; R4: amount of entries read
                XOR     R5, R5                  ; R5: head of linked list
                XOR     R6, R6                  ; R6: filter function or 0
                                                ; R7: directory handle

                CMP     0, R12                  ; filter function given?
                RBRA    _DIRBR_START, Z         ; no: get started
                MOVE    _DIRBR_FILTERFN, R6     ; yes: remember custom func.
                MOVE    R12, @R6
                MOVE    _DIRBR_FILTWRAP, R6     ; R6: internal wrapper func.

                ; change directory to given path and then obtain the
                ; directory handle: R8: device handle, R9: path
_DIRBR_START    XOR     R10, R10                ; use "/" as separator char
                SYSCALL(f32_cd, 1)              ; change directory
                CMP     0, R9                   ; everything OK?
                RBRA    _DIRBR_RD_ECD, !Z       ; no: error and exit
                                                ; R8: still contains dev. hndl
                MOVE    _DIRBR_FH, R9           ; R9: empty directory handle
                SYSCALL(f32_od, 1)              ; obtain directory handle
                MOVE    R8, R7                  ; R7: directory handle
                CMP     0, R9                   ; everything OK?
                RBRA    _DIRBR_RD_EDH, !Z       ; no: exit with error code

                ; iterate through the current directory
_DIRBR_LOOP     MOVE    R7, R8                  ; R8: directory handle
                MOVE    _DIRBR_ENTRY, R9        ; R9: empty dir. entry struct
                MOVE    FAT32$FA_DEFAULT, R10   ; R10: browse for all
                                                ; non-hidden files and dirs
                SYSCALL(f32_ld, 1)              ; get next directory entry
                CMP     0, R11                  ; any errors?
                RBRA    _DIRBR_RD_RET, !Z       ; yes: exit with error in R11
                CMP     1, R10                  ; current entry valid?
                RBRA    _DIRBR_LOOPEND, !Z      ; no: end loop

                MOVE    _DIRBR_DOT, R8          ; filter the "single dot"
                MOVE    _DIRBR_ENTRY, R9
                ADD     FAT32$DE_NAME, R9
                SYSCALL(strcmp, 1)
                CMP     0, R10
                RBRA    _DIRBR_LOOP, Z

                MOVE    R1, R8                  ; R1: current heap ptr
                MOVE    R2, R9                  ; R2: maximum heap memory
                MOVE    R3, R10                 ; R3: current heap memory
                RSUB    _DIRBR_NEWELM, 1        ; new element on heap
                MOVE    R8, R1                  ; R1: new heap ptr
                MOVE    R10, R3                 ; R3: new current heap memory
                CMP     0, R11                  ; out-of-memory?
                RBRA    _DIRBR_RD_WOOM, !Z      ; yes: exit

                ADD     1, R4                   ; one more entry read

                MOVE    R5, R8                  ; R8: head of linked list
                                                ; R9: still has new element
                MOVE    _DIRBR_COMPARE, R10     ; R10: compare function
                MOVE    R6, R11                 ; R11: filter func. or 0

                RSUB    SLL$S_INSERT, 1
                MOVE    R8, R5                  ; R5: (new) head of linked lst
                RBRA    _DIRBR_LOOP, 1          ; next iteration

                ; M2M-UPSTREAM sd-host (two slots), in the Shell only (R6: a
                ; filter is given): the root of a card has no "..", so the
                ; Shell gets one: it leads to the list of the cards
                ; (SELECT_FILE). It goes to the head of the list.
_DIRBR_LOOPEND  CMP     0, R6
                RBRA    _DIRBR_LEND2, Z
                MOVE    @R7, R8                 ; the device handle (of the
                RSUB    FB_ATROOT, 1            ; directory handle in R7)
                RBRA    _DIRBR_XS, !C
                MOVE    _DIRBR_ENTRY, R9        ; ".." as a directory entry
                ADD     FAT32$DE_NAME, R9
                MOVE    _DIRBR_DOTDOT, R8
                SYSCALL(strcpy, 1)
                MOVE    _DIRBR_ENTRY, R9
                ADD     FAT32$DE_ATTRIB, R9
                MOVE    FAT32$FA_DIR, @R9
                MOVE    R1, R8
                MOVE    R2, R9
                MOVE    R3, R10
                RSUB    _DIRBR_NEWELM, 1
                MOVE    R8, R1
                MOVE    R10, R3
                CMP     0, R11
                RBRA    _DIRBR_RD_WOOM, !Z
                MOVE    R9, R10                 ; at the head
                ADD     SLL$NEXT, R10
                MOVE    R5, @R10
                CMP     0, R5
                RBRA    _DIRBR_UPH, Z
                MOVE    R5, R10
                ADD     SLL$PREV, R10
                MOVE    R9, @R10
_DIRBR_UPH      MOVE    R9, R5
                ADD     1, R4

                ; M2M-UPSTREAM cfg-strings (Megamiga): entries of the core
                ; that are no files (BROWSE_EXTRA, e.g. SD card partitions),
                ; in the Shell only (R6: a filter is given). They come first,
                ; behind "<..>", in the order of the core, unsorted; their flag
                ; word is 2 + the id of the core (see SELECT_FILE).
                ; M2M-UPSTREAM sd-host: here BROWSE_EXTRA gets R11 = 0xFFFF
                ; (a directory); for the list of the cards, the slot.
_DIRBR_XS       XOR     R0, R0                  ; R0: insert behind (0: head)
                CMP     0, R5
                RBRA    _DIRBR_X0, Z
                MOVE    R5, R8                  ; the list starts with "<..>"?
                ADD     SLL$DATA, R8
                MOVE    _DIRBR_UPDIR, R9
                SYSCALL(strcmp, 1)
                CMP     0, R10
                RBRA    _DIRBR_X0, !Z
                MOVE    R5, R0
_DIRBR_X0       XOR     R7, R7                  ; R7: index of the entry
_DIRBR_XL       MOVE    R7, R8
                MOVE    SF_CONTEXT, R9
                MOVE    @R9, R9
                MOVE    SF_CONTEXT_DATA, R10
                MOVE    @R10, R10
                MOVE    0xFFFF, R11             ; (a directory)
                RSUB    BROWSE_EXTRA, 1         ; R8: name (0: no more), R9: id
                CMP     0, R8
                RBRA    _DIRBR_LEND2, Z
                MOVE    R9, R12                 ; R12: the id
                MOVE    _DIRBR_ENTRY, R9        ; as a directory entry
                ADD     FAT32$DE_NAME, R9
                SYSCALL(strcpy, 1)
                MOVE    _DIRBR_ENTRY, R9
                ADD     FAT32$DE_ATTRIB, R9
                MOVE    0, @R9
                MOVE    R1, R8
                MOVE    R2, R9
                MOVE    R3, R10
                RSUB    _DIRBR_NEWELM, 1
                MOVE    R8, R1
                MOVE    R10, R3
                CMP     0, R11
                RBRA    _DIRBR_RD_WOOM, !Z
                MOVE    R1, R10                 ; its flag word: the last one
                SUB     1, R10
                ADD     2, R12
                MOVE    R12, @R10
                MOVE    R9, R10                 ; R10: the new element
                CMP     0, R0
                RBRA    _DIRBR_XH, Z
                MOVE    R0, R11                 ; behind R0
                ADD     SLL$NEXT, R11
                MOVE    @R11, R12               ; R12: its successor
                MOVE    R10, @R11
                MOVE    R10, R11
                ADD     SLL$NEXT, R11
                MOVE    R12, @R11
                MOVE    R10, R11
                ADD     SLL$PREV, R11
                MOVE    R0, @R11
                CMP     0, R12
                RBRA    _DIRBR_XN, Z
                ADD     SLL$PREV, R12
                MOVE    R10, @R12
                RBRA    _DIRBR_XN, 1
_DIRBR_XH       MOVE    R10, R11                ; at the head
                ADD     SLL$NEXT, R11
                MOVE    R5, @R11
                MOVE    R10, R11
                ADD     SLL$PREV, R11
                MOVE    0, @R11
                CMP     0, R5
                RBRA    _DIRBR_XH2, Z
                MOVE    R5, R11
                ADD     SLL$PREV, R11
                MOVE    R10, @R11
_DIRBR_XH2      MOVE    R10, R5
_DIRBR_XN       MOVE    R10, R0
                ADD     1, R4
                ADD     1, R7
                RBRA    _DIRBR_XL, 1

_DIRBR_LEND2    MOVE    R4, R9                  ; return amount of entries
                MOVE    R5, R10                 ; R10: head of linked list
                XOR     R11, R11                ; 0 = no error
                RBRA    _DIRBR_RD_RET, 1

_DIRBR_RD_ECD   MOVE    1, R11                  ; directory not found
                RBRA    _DIRBR_RD_RET, 1
_DIRBR_RD_WOOM  MOVE    2, R11                  ; out-of-memory
                MOVE    R4, R9                  ; amount of entries
                MOVE    R5, R10                 ; head of linked list
                RBRA    _DIRBR_RD_RET, 1
_DIRBR_RD_EDH   MOVE    R9, R11                 ; return R9 as error code
_DIRBR_RD_RET   DECRB
                MOVE    R0, R8
                MOVE    R1, R12
                DECRB
                RET

; ----------------------------------------------------------------------------
; M2M-UPSTREAM sd-host (two slots): the list of the SD cards for SELECT_FILE,
; above the roots: for every slot with a card "<SD0: internal card>" or
; "<SD1: external card>" (a directory entry) and behind it the entries that
; BROWSE_EXTRA names for that card (R11 = the slot; flag word 2 + id), in this
; order, unsorted.
; Input:
;  R10: Pointer to heap
;  R11: Maximum amount of available heap memory
; Output:
;   R9: Amount of entries
;  R10: head of the linked list
;  R11: 0 = OK, 2 = more entries than memory permits
; ----------------------------------------------------------------------------

DIRBROWSE_CARDS INCRB
                MOVE    R10, R1                 ; R1: current heap ptr
                MOVE    R11, R2                 ; R2: max memory on heap
                XOR     R3, R3                  ; R3: current heap mem. usage
                XOR     R4, R4                  ; R4: amount of entries
                XOR     R5, R5                  ; R5: head of linked list
                XOR     R6, R6                  ; R6: its tail
                XOR     R7, R7                  ; R7: slot

_DBC_SL         MOVE    R7, R8
                RSUB    SDC$PRESENT, 1
                RBRA    _DBC_NS, !C             ; no card in this slot
                MOVE    _DBC_NAMES, R8          ; the card: a directory
                ADD     R7, R8
                MOVE    @R8, R8
                MOVE    _DIRBR_ENTRY, R9
                ADD     FAT32$DE_NAME, R9
                SYSCALL(strcpy, 1)
                MOVE    _DIRBR_ENTRY, R9
                ADD     FAT32$DE_ATTRIB, R9
                MOVE    FAT32$FA_DIR, @R9
                RSUB    _DBC_ADD, 1
                RBRA    _DBC_OOM, C

                XOR     R0, R0                  ; R0: index of the extra entry
_DBC_XL         MOVE    R0, R8
                MOVE    SF_CONTEXT, R9
                MOVE    @R9, R9
                MOVE    SF_CONTEXT_DATA, R10
                MOVE    @R10, R10
                MOVE    R7, R11                 ; the slot
                RSUB    BROWSE_EXTRA, 1         ; R8: name (0: no more), R9: id
                CMP     0, R8
                RBRA    _DBC_NS, Z
                MOVE    R9, @--SP               ; (the id)
                MOVE    _DIRBR_ENTRY, R9        ; as a file entry
                ADD     FAT32$DE_NAME, R9
                SYSCALL(strcpy, 1)
                MOVE    _DIRBR_ENTRY, R9
                ADD     FAT32$DE_ATTRIB, R9
                MOVE    0, @R9
                RSUB    _DBC_ADD, 1
                MOVE    @SP++, R12              ; (MOVE keeps C)
                RBRA    _DBC_OOM, C
                MOVE    R1, R10                 ; its flag word: the last one
                SUB     1, R10
                ADD     2, R12
                MOVE    R12, @R10
                ADD     1, R0
                RBRA    _DBC_XL, 1

_DBC_NS         ADD     1, R7
                CMP     2, R7
                RBRA    _DBC_SL, !Z
                XOR     R11, R11                ; 0 = no error
                RBRA    _DBC_RET, 1
_DBC_OOM        MOVE    2, R11
_DBC_RET        MOVE    R4, R9
                MOVE    R5, R10
                DECRB
                RET

; _DBC_ADD: the entry in _DIRBR_ENTRY as a new element at the tail of the list
; (registers of DIRBROWSE_CARDS). C=1 if the memory is full.
_DBC_ADD        MOVE    R1, R8
                MOVE    R2, R9
                MOVE    R3, R10
                RSUB    _DIRBR_NEWELM, 1
                MOVE    R8, R1
                MOVE    R10, R3
                CMP     0, R11
                RBRA    _DBCA_OOM, !Z
                CMP     0, R6                   ; the first one: the head
                RBRA    _DBCA_T, !Z
                MOVE    R9, R5
                RBRA    _DBCA_E, 1
_DBCA_T         MOVE    R6, R10                 ; behind the tail
                ADD     SLL$NEXT, R10
                MOVE    R9, @R10
                MOVE    R9, R10
                ADD     SLL$PREV, R10
                MOVE    R6, @R10
_DBCA_E         MOVE    R9, R6
                ADD     1, R4
                AND     0xFFFB, SR              ; C=0
                RET
_DBCA_OOM       OR      0x0004, SR              ; C=1
                RET

_DBC_NAMES      .DW     STR_SD0_CARD, STR_SD1_CARD

; ----------------------------------------------------------------------------
; Internal helper functions
; ----------------------------------------------------------------------------

; Create new linked-list element on the heap, manage the heap-head and return
; a pointer to the new element in R8
; Input:
;   R8: Pointer to the head of the heap
;   assumes a valid directoy entry structure in _DIRBR_ENTRY
;   R9: maximum heap memory
;  R10: current heap memory
; Output;
;   R8: Adjusted pointer to the head of the heap
;   R9: Pointer to new linked-list element on the heap
;  R10: new current heap memory
;  R11: 0: OK, 1: out-of-memory
_DIRBR_NEWELM   INCRB

                MOVE    R8, R11                 ; R11: new linked-list elm.
                MOVE    R8, R0                  ; R0: NEXT
                MOVE    R8, R1                  ; R1: PREV
                MOVE    R8, R2                  ; R2: DATA-SIZE
                MOVE    R8, R3                  ; R3: DATA
                MOVE    R9, R4                  ; R4: maximum heap memory
                MOVE    R10, R5                 ; R5: current heap memory
                XOR     R6, R6                  ; R6: is it a directory?
                ADD     SLL$NEXT, R0            ; init NEXT with 0 
                MOVE    0, @R0
                ADD     SLL$PREV, R1            ; init PREV with 0
                MOVE    0, @R1
                ADD     SLL$DATA_SIZE, R2
                ADD     SLL$DATA, R3

                ; determine the length of the file/directory name and
                ; calculate the size of the data blob
                MOVE    _DIRBR_ENTRY, R7
                ADD     FAT32$DE_NAME, R7
                MOVE    R7, R8
                SYSCALL(strlen, 1)
                ADD     1, R9                   ; R9: length of file name str.
                ADD     1, R9                   ; space for attributes
                MOVE    _DIRBR_ENTRY, R7
                ADD     FAT32$DE_ATTRIB, R7
                AND     FAT32$FA_DIR, @R7       ; is it a directory?
                RBRA    _DIRBR_NEWELM2, Z       ; no
                ADD     _DIRBR_DSDESIZE, R9     ; add size of "<" ">"
                MOVE    1, R6                   ; R6: directory flag = 1

                ; R9 now contains the heap space needed: check if we still
                ; have enough heap to accommodate R9: create the linked-list
                ; data blob using this memory layout:
                ; filename (+ "<" and ">" if directory)
                ; dir-flag: 0: normal file, 1: directory
_DIRBR_NEWELM2  MOVE    R5, R7                  ; current heap memory
                ADD     R9, R7                  ; memory needed by new entry
                MOVE    R7, R10                 ; return new heap memory
                ADD     SLL$OVRHD_SIZE, R10
                CMP     R7, R4                  ; current+new <= max?
                RBRA    _DIRBR_NEOOM, N         ; no: out-of-memory!

                MOVE    R9, @R2                 ; put data size in SLL struct.
                CMP     1, R6                   ; is it a directory?
                RBRA    _DIRBR_NEWELM3, !Z      ; no: continue
                MOVE    _DIRBR_DS, @R3++        ; add "<" before name
_DIRBR_NEWELM3  MOVE    _DIRBR_ENTRY, R7        ; copy file name
                ADD     FAT32$DE_NAME, R7
                MOVE    R7, R8
                MOVE    R3, R9
                SYSCALL(strcpy, 1)

                SYSCALL(strlen, 1)              ; R9 contains len of filename
                ADD     R9, R3                  ; R3 points to zero terminator
                CMP     1, R6                   ; is it a directory?
                RBRA    _DIRBR_NEWELM4, !Z      ; no: continue
                MOVE    _DIRBR_DE, @R3++        ; add ">" after name
                MOVE    0, @R3

_DIRBR_NEWELM4  ADD     1, R3                   ; skip zero terminator
                MOVE    R6, @R3++               ; add directory flag

                MOVE    R3, R8                  ; R8: adjusted head of heap
                MOVE    R11, R9                 ; R9: pointer to new element
                XOR     R11, R11                ; R11: no error
                RBRA    _DIRBR_NERET, 1         ; return

                ; out of memory
_DIRBR_NEOOM    MOVE    R11, R8                 ; heap head did not change
                XOR     R9, R9                  ; no new element
                MOVE    R5, R10                 ; heap usage did not change
                MOVE    1, R11

                ; return
_DIRBR_NERET    DECRB
                RET

; SLL$S_INSERT compare function that returns negative if (S0 < S1),
; zero if (S0 == S1), positive if (S0 > S1). These semantic are
; basically compatible with STR$CMP, but instead of expecting pointers
; to two strings, this compare function is expecting two pointers to
; SLL records, while the pointer to the first one is given in R8 and
; treated as "S0" and the second one in R9 and treated as "S1".
; Also, this compare function compares case-insensitive.

_DIRBR_COMPARE  INCRB
                MOVE    R8, R0 
                MOVE    R9, R1
                INCRB
                MOVE    R8, R0
                MOVE    R9, R1

                ADD     SLL$DATA, R0            ; R0: pointer to first string
                ADD     SLL$DATA, R1            ; R1: pointer to second string

                ; copy R0 to the stack and make it upper case
_DIRBR_CMP      MOVE    R0, R8                  ; copy string to stack
                SYSCALL(strlen, 1)
                ADD     1, R9               
                SUB     R9, SP
                MOVE    R9, R4                  ; R4: stack restore amount
                MOVE    SP, R9
                SYSCALL(strcpy, 1)
                MOVE    R9, R8
                SYSCALL(str2upper, 1)
                MOVE    R8, R0

                ; copy R1 to the stack and make it upper case
                MOVE    R1, R8
                SYSCALL(strlen, 1)
                ADD     1, R9
                SUB     R9, SP
                ADD     R9, R4                  ; R4: update stack rest. amnt.
                MOVE    SP, R9
                SYSCALL(strcpy, 1)
                MOVE    R9, R8
                SYSCALL(str2upper, 1)
                MOVE    R8, R1

                ; replace the brackets in directory names like <this> by
                ; low ASCII characters to ensure they have sorting priority
                CMP     _DIRBR_DS, @R0          ; performance optimization
                RBRA    _DIRBR_NXTDS, !Z
                MOVE    _DIRBR_DS, R8           ; replace < by 1 in R0
                MOVE    1, R9
                MOVE    R0, R10
                SYSCALL(strrplchr, 1)
                MOVE    _DIRBR_DE, R8           ; replace > by 2 in R0
                MOVE    2, R9
                SYSCALL(strrplchr, 1)

_DIRBR_NXTDS    CMP     _DIRBR_DS, @R1
                RBRA    _DIRBR_DOISANUM, !Z
                MOVE    _DIRBR_DS, R8
                MOVE    1, R9                   ; replace < by 1 in R1
                MOVE    R1, R10
                SYSCALL(strrplchr, 1)
                MOVE    _DIRBR_DE, R8           ; replace > by 2 in R1
                MOVE    2, R9
                SYSCALL(strrplchr, 1)

                ; special treatment for names that are numbers so that files
                ; and folders like 1, 2, 3, ..., 10, 11, ..., 100, 101, ...
                ; are sorted in ascending order: If a string that represents
                ; a number is shorter than another string that represents a
                ; number then the first string is "smaller" than the second
                ; in the context of being a number
_DIRBR_DOISANUM MOVE    R0, R8                  ; if R0 is NaN: norm. strcmp
                RSUB    _DIRBR_ISANUM, 1
                RBRA    _DIRBR_DOCMP, !C
                MOVE    R1, R8                  ; if R1 is NaN: norm. strcmp
                RSUB    _DIRBR_ISANUM, 1
                RBRA    _DIRBR_DOCMP, !C

                MOVE    R0, R8
                SYSCALL(strlen, 1)
                MOVE    R9, R7                  ; R7: strlen of R0
                MOVE    R1, R8
                SYSCALL(strlen, 1)              ; R9: strlen of R1
                CMP     R7, R9
                RBRA    _DIRBR_DOCMP, Z         ; R5=R6: normal strcmp works
                RBRA    _DIRBR_R1, N            ; strlen(R0)>strlen(R1)
                MOVE    -1, R10                 ; R0 < R1
                RBRA    _DIRBR_RET, 1
_DIRBR_R1       MOVE    1, R10                  ; R0 > R1
                RBRA    _DIRBR_RET, 1

                ; case-insensitive comparison (because we are comparing
                ; upper case versions of the names)
_DIRBR_DOCMP    MOVE    R0, R8
                MOVE    R1, R9
                SYSCALL(strcmp, 1)

_DIRBR_RET      ADD     R4, SP                  ; restore stack pointer

                DECRB                
                MOVE    R0, R8
                MOVE    R1, R9   
                DECRB
                RET

; helper function to check if a string is actually a number
; directory brackets like <this> are ignored, i.e. <123> is a number
; R8: string
; Carry flag C=1 if it is a number, C=0 otherwise
_DIRBR_ISANUM   INCRB

                MOVE    R8, R0                  ; zero-string is not a number
                CMP     0, @R0
                RBRA    _DIRBR_IAN_C0, Z

_DIRBR_IAN_LP   MOVE    @R0++, R1               ; checked until the end..
                RBRA    _DIRBR_IAN_C1, Z        ; ..so it is a number
                CMP     1, R1                   ; ignore if <
                RBRA    _DIRBR_IAN_LP, Z
                CMP     2, R1                   ; ignore if >
                RBRA    _DIRBR_IAN_LP, Z
                CMP     R1, 47                  ; > ASCII 47 means 0...
                RBRA    _DIRBR_IAN_C0, !N       ; no: not a number
                CMP     R1, 57                  ; <= ASCII 57 means ...9
                RBRA    _DIRBR_IAN_C0, N        ; no: not a number
                RBRA    _DIRBR_IAN_LP, 1

_DIRBR_IAN_C1   OR      0x0004, SR              ; is a num: set Carry
                RBRA    _DIRBR_IAN_RET, 1

_DIRBR_IAN_C0   AND     0xFFFB, SR              ; not a num: clear Carry

_DIRBR_IAN_RET  DECRB
                RET

; SLL$S_INSERT filter function which is a wrapper for the user-defined
; function specified for DIRBROWSE_READ. This is a simplification so that
; DIRBROWSE_READ just expects a filter function that compares strings and
; that does not need to be aware of the SLL semantics
_DIRBR_FILTWRAP INCRB

                MOVE    R9, R0                  ; backup R9, R10 & R11
                MOVE    R10, R6                 ; SF_CONTEXT
                MOVE    R11, R7                 ; SF_CONTEXT
        
                ; copy the string to the stack and make it upper case
                ADD     SLL$DATA, R8            ; R8: pointer to string
                SYSCALL(strlen, 1)              ; R9: length of string
                ADD     1, R9

                MOVE    R9, R3                  ; behind string sits flag
                ADD     R8, R3
                MOVE    @R3, R3                 ; R3: file/directory flag

                SUB     R9, SP
                MOVE    R9, R2
                MOVE    SP, R9
                SYSCALL(strcpy, 1)
                MOVE    R9, R8
                SYSCALL(str2upper, 1)           ; R8 contains upper string

                MOVE    R3, R9

                ; SF_CONTEXT
                MOVE    SF_CONTEXT, R10
                MOVE    @R10, R10
                MOVE    SF_CONTEXT_DATA, R11
                MOVE    @R11, R11

                ; call filter function (callback function)
                ; R8: filename in upper-case
                ; R9: 0=file/1=directory
                ; R10: SF_CONTEXT
                MOVE    _DIRBR_FILTERFN, R1
                ASUB    @R1, 1

                ADD     R2, SP                  ; restore stack
                MOVE    R0, R9                  ; restore R9, R10 & R11
                MOVE    R6, R10                 ; SF_CONTEXT
                MOVE    R7, R11                 ; SF_CONTEXT
                DECRB
                RET
