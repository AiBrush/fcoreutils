; ============================================================
; fdircolors_unified.asm — GNU-compatible 'dircolors' command
; Builds with: nasm -f bin fdircolors_unified.asm -o fdircolors
;
; dircolors: Output commands to set LS_COLORS.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   ebx  = flags (bit 0 = -b/--sh, bit 1 = -c/--csh, bit 2 = -p/--print-database)
;   r12  = file arg pointer (if any)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_EXIT        60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

%define O_RDONLY        0

; BSS layout: 0x500000
%define BSS_ADDR       0x500000
%define BSS_SIZE       65536
%define FILE_BUF       BSS_ADDR                ; 32768 bytes - file read buffer
%define OUT_BUF        (BSS_ADDR + 32768)      ; 16384 bytes - output buffer
%define OUT_POS        (BSS_ADDR + 49152)      ; 8 bytes

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2, 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw 64, 56, 3, 64, 0, 0

; --- Program Headers ---
phdr:
    ; PT_LOAD: code + data (R+X)
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    ; PT_LOAD: BSS (R+W)
    dd 1, 6
    dq 0, BSS_ADDR, BSS_ADDR, 0, BSS_SIZE, 0x200000

    ; PT_GNU_STACK (NX)
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================
; Code
; ============================================================
_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0
    bts     qword [rsp], SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    mov     edi, SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Save argc/argv
    mov     r14d, [rsp]
    lea     r15, [rsp + 8]

    ; Initialize flags
    xor     ebx, ebx            ; default to Bourne shell (-b)
    xor     r12d, r12d          ; no file arg
    mov     ecx, 1

; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .got_file
    cmp     byte [rdi + 1], 0
    je      .read_stdin
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'b'
    je      .set_sh
    cmp     al, 'c'
    je      .set_csh
    cmp     al, 'p'
    je      .set_print
    ; Invalid
    mov     r13, rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    mov     rsi, r13
    mov     edx, 1
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 2
    jmp     do_exit

.set_sh:
    and     bl, ~2              ; clear csh
    or      bl, 1
    inc     rdi
    jmp     .short_loop

.set_csh:
    and     bl, ~1              ; clear sh
    or      bl, 2
    inc     rdi
    jmp     .short_loop

.set_print:
    or      bl, 4
    inc     rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r13, rdi
    push    rcx
    ; --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    ; --version
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    ; --sh / --bourne-shell
    mov     rdi, r13
    mov     rsi, str_sh_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_sh
    mov     rdi, r13
    mov     rsi, str_bourne_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_sh
    ; --csh / --c-shell
    mov     rdi, r13
    mov     rsi, str_csh_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_csh
    mov     rdi, r13
    mov     rsi, str_cshell_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_csh
    ; --print-database
    mov     rdi, r13
    mov     rsi, str_printdb_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_print
    ; --print-ls-colors (skip, non-standard)
    ; Unrecognized
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog
    mov     edx, str_unrecog_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    pop     rcx
    mov     edi, 2
    jmp     do_exit

.pop_show_help:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_show_version:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_set_sh:
    pop     rcx
    and     bl, ~2
    or      bl, 1
    inc     ecx
    jmp     .parse_opts

.pop_set_csh:
    pop     rcx
    and     bl, ~1
    or      bl, 2
    inc     ecx
    jmp     .parse_opts

.pop_set_print:
    pop     rcx
    or      bl, 4
    inc     ecx
    jmp     .parse_opts

.double_dash:
    inc     ecx
    ; Next arg must be file
    cmp     ecx, r14d
    jge     .done_opts
    mov     r12, [r15 + rcx*8]
    inc     ecx
    jmp     .done_opts

.read_stdin:
    ; "-" means stdin (fd 0)
    mov     r12, rdi            ; save "-" pointer as marker
    inc     ecx
    jmp     .done_opts

.got_file:
    mov     r12, rdi
    inc     ecx

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; Check -p / --print-database
    test    bl, 4
    jnz     .do_print_database

    ; Default: output LS_COLORS setting from default database
    ; Using Bourne shell unless -c was set
    mov     qword [OUT_POS], 0

    test    bl, 2
    jnz     .output_csh

    ; Bourne shell output
    mov     rsi, str_sh_prefix
    mov     edx, str_sh_prefix_len
    call    buf_write
    mov     rsi, default_ls_colors
    mov     edx, default_ls_colors_len
    call    buf_write
    mov     rsi, str_sh_suffix
    mov     edx, str_sh_suffix_len
    call    buf_write
    call    buf_flush
    xor     edi, edi
    jmp     do_exit

.output_csh:
    mov     rsi, str_csh_prefix
    mov     edx, str_csh_prefix_len
    call    buf_write
    mov     rsi, default_ls_colors
    mov     edx, default_ls_colors_len
    call    buf_write
    mov     rsi, str_csh_suffix
    mov     edx, str_csh_suffix_len
    call    buf_write
    call    buf_flush
    xor     edi, edi
    jmp     do_exit

.do_print_database:
    mov     edi, STDOUT
    mov     rsi, default_database
    mov     edx, default_database_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

; ============================================================
; Output buffer routines
; ============================================================
buf_write:
    push    rdi
    push    rcx
    mov     rcx, [OUT_POS]
    xor     eax, eax
.bw_loop:
    cmp     eax, edx
    jge     .bw_done
    movzx   r8d, byte [rsi + rax]
    mov     byte [OUT_BUF + rcx], r8b
    inc     rcx
    inc     eax
    cmp     ecx, 16000
    jl      .bw_loop
    mov     [OUT_POS], rcx
    push    rsi
    push    rdx
    push    rax
    call    buf_flush
    pop     rax
    pop     rdx
    pop     rsi
    xor     ecx, ecx
    jmp     .bw_loop
.bw_done:
    mov     [OUT_POS], rcx
    pop     rcx
    pop     rdi
    ret

buf_flush:
    mov     rcx, [OUT_POS]
    test    rcx, rcx
    jz      .bf_done
    mov     edi, STDOUT
    mov     rsi, OUT_BUF
    mov     edx, ecx
    call    do_write
    mov     qword [OUT_POS], 0
.bf_done:
    ret

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

do_write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

str_eq:
    xor     r8d, r8d
.se_loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     r8d
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: dircolors [OPTION]... [FILE]", 10
    db "Output commands to set the LS_COLORS environment variable.", 10, 10
    db "Determine format of output:", 10
    db "  -b, --sh, --bourne-shell    output Bourne shell code to set LS_COLORS", 10
    db "  -c, --csh, --c-shell        output C shell code to set LS_COLORS", 10
    db "  -p, --print-database        output defaults", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "If FILE is specified, read it to determine which colors to use for which", 10
    db "file types and extensions.  Otherwise, a precompiled database is used.", 10
    db "For details on the format of these files, run 'dircolors --print-database'.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/dircolors>", 10
    db "or available locally via: info '(coreutils) dircolors invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "dircolors (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by H. Peter Anvin.", 10
str_version_len equ $ - str_version

str_prefix:      db "dircolors: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_sq_nl:       db "'", 10
str_try:         db "Try 'dircolors --help' for more information.", 10
str_try_len      equ $ - str_try
; @@DATA_END@@

str_help_flag:    db "--help", 0
str_version_flag: db "--version", 0
str_sh_flag:      db "--sh", 0
str_bourne_flag:  db "--bourne-shell", 0
str_csh_flag:     db "--csh", 0
str_cshell_flag:  db "--c-shell", 0
str_printdb_flag: db "--print-database", 0

; Shell output wrappers
str_sh_prefix:   db "LS_COLORS='"
str_sh_prefix_len equ $ - str_sh_prefix
str_sh_suffix:   db "';" , 10, "export LS_COLORS", 10
str_sh_suffix_len equ $ - str_sh_suffix
str_csh_prefix:  db "setenv LS_COLORS '"
str_csh_prefix_len equ $ - str_csh_prefix
str_csh_suffix:  db "'" , 10
str_csh_suffix_len equ $ - str_csh_suffix

; Default LS_COLORS value (GNU coreutils default)
default_ls_colors:
    db "rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=00:tw=30;42:ow=34;42:st=37;44:ex=01;32:"
    db "*.tar=01;31:*.tgz=01;31:*.arc=01;31:*.arj=01;31:*.taz=01;31:*.lha=01;31:*.lz4=01;31:*.lzh=01;31:*.lzma=01;31:*.tlz=01;31:*.txz=01;31:*.tzo=01;31:*.t7z=01;31:*.zip=01;31:*.z=01;31:*.dz=01;31:*.gz=01;31:*.lrz=01;31:*.lz=01;31:*.lzo=01;31:*.xz=01;31:*.zst=01;31:*.tzst=01;31:*.bz2=01;31:*.bz=01;31:*.tbz=01;31:*.tbz2=01;31:*.tz=01;31:*.deb=01;31:*.rpm=01;31:*.jar=01;31:*.war=01;31:*.ear=01;31:*.sar=01;31:*.rar=01;31:*.alz=01;31:*.ace=01;31:*.zoo=01;31:*.cpio=01;31:*.7z=01;31:*.rz=01;31:*.cab=01;31:*.wim=01;31:*.swm=01;31:*.dwm=01;31:*.esd=01;31:"
    db "*.avif=01;35:*.jpg=01;35:*.jpeg=01;35:*.mjpg=01;35:*.mjpeg=01;35:*.gif=01;35:*.bmp=01;35:*.pbm=01;35:*.pgm=01;35:*.ppm=01;35:*.tga=01;35:*.xbm=01;35:*.xpm=01;35:*.tif=01;35:*.tiff=01;35:*.png=01;35:*.svg=01;35:*.svgz=01;35:*.mng=01;35:*.pcx=01;35:*.mov=01;35:*.mpg=01;35:*.mpeg=01;35:*.m2v=01;35:*.mkv=01;35:*.webm=01;35:*.webp=01;35:*.ogm=01;35:*.mp4=01;35:*.m4v=01;35:*.mp4v=01;35:*.vob=01;35:*.qt=01;35:*.nuv=01;35:*.wmv=01;35:*.asf=01;35:*.rm=01;35:*.rmvb=01;35:*.flc=01;35:*.avi=01;35:*.fli=01;35:*.flv=01;35:*.gl=01;35:*.dl=01;35:*.xcf=01;35:*.xwd=01;35:*.yuv=01;35:*.cgm=01;35:*.emf=01;35:*.ogv=01;35:*.ogx=01;35:"
    db "*.aac=00;36:*.au=00;36:*.flac=00;36:*.m4a=00;36:*.mid=00;36:*.midi=00;36:*.mka=00;36:*.mp3=00;36:*.mpc=00;36:*.ogg=00;36:*.ra=00;36:*.wav=00;36:*.oga=00;36:*.opus=00;36:*.spx=00;36:*.xspf=00;36:"
default_ls_colors_len equ $ - default_ls_colors

; Default database for -p / --print-database
default_database:
    db "# Configuration file for dircolors, a utility to help you set the", 10
    db "# LS_COLORS environment variable used by GNU ls with the --color option.", 10
    db "# The keywords COLOR, OPTIONS, and EIGHTBIT (strstrting strith ISO 8859) are", 10
    db "# recognized and stripped.  Below are TERM://entries, which can be a glob", 10
    db "# pattern, to determine which terminal supports color.", 10
    db "# ", 10
    db "TERM Eterm", 10
    db "TERM ansi", 10
    db "TERM *color*", 10
    db "TERM con[0-9]*x[0-9]*", 10
    db "TERM cons25", 10
    db "TERM console", 10
    db "TERM cygwin", 10
    db "TERM *direct*", 10
    db "TERM dtterm", 10
    db "TERM gnome", 10
    db "TERM hurd", 10
    db "TERM jfbterm", 10
    db "TERM konsole", 10
    db "TERM kterm", 10
    db "TERM linux", 10
    db "TERM linux-c", 10
    db "TERM mlterm", 10
    db "TERM putty", 10
    db "TERM rxvt*", 10
    db "TERM screen*", 10
    db "TERM st", 10
    db "TERM terminator", 10
    db "TERM tmux*", 10
    db "TERM vt100", 10
    db "TERM xterm*", 10
    db "# ", 10
    db "# Below are the color init strings for the basic file types.", 10
    db "# One can use codes for 256 or more colors supported by modern terminals.", 10
    db "# The default color codes use the capabilities of an 8 color terminal", 10
    db "# with some strstrings strstrstrith a bold attribute.", 10
    db "# ", 10
    db "# Below, there should be one TERM entry for each termtype that is colorizable", 10
    db "NORMAL 00", 10
    db "FILE 00", 10
    db "RESET 0", 10
    db "DIR 01;34", 10
    db "LINK 01;36", 10
    db "MULTIHARDLINK 00", 10
    db "FIFO 40;33", 10
    db "SOCK 01;35", 10
    db "DOOR 01;35", 10
    db "BLK 40;33;01", 10
    db "CHR 40;33;01", 10
    db "ORPHAN 40;31;01", 10
    db "MISSING 00", 10
    db "SETUID 37;41", 10
    db "SETGID 30;43", 10
    db "CAPABILITY 00", 10
    db "STICKY_OTHER_WRITABLE 30;42", 10
    db "OTHER_WRITABLE 34;42", 10
    db "STICKY 37;44", 10
    db "EXEC 01;32", 10
    db "# ", 10
    db "# List any file extensions like '.gz' or '.tar' that you would like ls", 10
    db "# to color below. Put the extension, a space, and the color init string.", 10
    db ".tar 01;31", 10
    db ".tgz 01;31", 10
    db ".arc 01;31", 10
    db ".arj 01;31", 10
    db ".taz 01;31", 10
    db ".lha 01;31", 10
    db ".lz4 01;31", 10
    db ".lzh 01;31", 10
    db ".lzma 01;31", 10
    db ".tlz 01;31", 10
    db ".txz 01;31", 10
    db ".tzo 01;31", 10
    db ".t7z 01;31", 10
    db ".zip 01;31", 10
    db ".z 01;31", 10
    db ".dz 01;31", 10
    db ".gz 01;31", 10
    db ".lrz 01;31", 10
    db ".lz 01;31", 10
    db ".lzo 01;31", 10
    db ".xz 01;31", 10
    db ".zst 01;31", 10
    db ".tzst 01;31", 10
    db ".bz2 01;31", 10
    db ".bz 01;31", 10
    db ".tbz 01;31", 10
    db ".tbz2 01;31", 10
    db ".tz 01;31", 10
    db ".deb 01;31", 10
    db ".rpm 01;31", 10
    db ".jar 01;31", 10
    db ".war 01;31", 10
    db ".ear 01;31", 10
    db ".sar 01;31", 10
    db ".rar 01;31", 10
    db ".alz 01;31", 10
    db ".ace 01;31", 10
    db ".zoo 01;31", 10
    db ".cpio 01;31", 10
    db ".7z 01;31", 10
    db ".rz 01;31", 10
    db ".cab 01;31", 10
    db ".wim 01;31", 10
    db ".swm 01;31", 10
    db ".dwm 01;31", 10
    db ".esd 01;31", 10
    db ".avif 01;35", 10
    db ".jpg 01;35", 10
    db ".jpeg 01;35", 10
    db ".mjpg 01;35", 10
    db ".mjpeg 01;35", 10
    db ".gif 01;35", 10
    db ".bmp 01;35", 10
    db ".pbm 01;35", 10
    db ".pgm 01;35", 10
    db ".ppm 01;35", 10
    db ".tga 01;35", 10
    db ".xbm 01;35", 10
    db ".xpm 01;35", 10
    db ".tif 01;35", 10
    db ".tiff 01;35", 10
    db ".png 01;35", 10
    db ".svg 01;35", 10
    db ".svgz 01;35", 10
    db ".mng 01;35", 10
    db ".pcx 01;35", 10
    db ".mov 01;35", 10
    db ".mpg 01;35", 10
    db ".mpeg 01;35", 10
    db ".m2v 01;35", 10
    db ".mkv 01;35", 10
    db ".webm 01;35", 10
    db ".webp 01;35", 10
    db ".ogm 01;35", 10
    db ".mp4 01;35", 10
    db ".m4v 01;35", 10
    db ".mp4v 01;35", 10
    db ".vob 01;35", 10
    db ".qt 01;35", 10
    db ".nuv 01;35", 10
    db ".wmv 01;35", 10
    db ".asf 01;35", 10
    db ".rm 01;35", 10
    db ".rmvb 01;35", 10
    db ".flc 01;35", 10
    db ".avi 01;35", 10
    db ".fli 01;35", 10
    db ".flv 01;35", 10
    db ".gl 01;35", 10
    db ".dl 01;35", 10
    db ".xcf 01;35", 10
    db ".xwd 01;35", 10
    db ".yuv 01;35", 10
    db ".cgm 01;35", 10
    db ".emf 01;35", 10
    db ".ogv 01;35", 10
    db ".ogx 01;35", 10
    db ".aac 00;36", 10
    db ".au 00;36", 10
    db ".flac 00;36", 10
    db ".m4a 00;36", 10
    db ".mid 00;36", 10
    db ".midi 00;36", 10
    db ".mka 00;36", 10
    db ".mp3 00;36", 10
    db ".mpc 00;36", 10
    db ".ogg 00;36", 10
    db ".ra 00;36", 10
    db ".wav 00;36", 10
    db ".oga 00;36", 10
    db ".opus 00;36", 10
    db ".spx 00;36", 10
    db ".xspf 00;36", 10
default_database_len equ $ - default_database

file_size equ $ - $$
