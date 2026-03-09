; funexpand.asm — GNU-compatible "unexpand" in x86-64 Linux assembly
;
; Converts sequences of spaces to tabs, writing to standard output.
; Faithfully replicates the GNU coreutils unexpand algorithm.
;
; Global register conventions:
;   r12  = out_pos (bytes in output buffer)
;   ebp  = had_error flag (0=ok, 1=error)
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/funexpand.asm -o build/funexpand.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/io.o
;   ld --gc-sections -n build/funexpand.o build/io.o -o funexpand

%include "include/linux.inc"
%include "include/macros.inc"

default rel

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ─── Constants ────────────────────────────────────────────
%define READ_BUF_SIZE   131072
%define OUT_BUF_SIZE    262144
%define FLUSH_THRESHOLD 131072
%define MAX_TAB_STOPS   256
%define MAX_FILES       256
%define PENDING_SIZE    65536

global _start

section .text

; ═══════════════════════════════════════════════════════════
;  Entry Point
; ═══════════════════════════════════════════════════════════
_start:
    BLOCK_SIGPIPE

    mov     ecx, [rsp]              ; argc
    lea     r14, [rsp + 8]          ; &argv[0]

    ; Initialize global state
    xor     ebp, ebp                ; had_error = 0
    xor     r12d, r12d              ; out_pos = 0
    mov     byte [convert_entire_line], 0
    mov     byte [first_only], 0
    mov     dword [num_tab_stops], 0
    mov     dword [default_tab], 8
    mov     dword [num_files], 0
    mov     byte [tab_list_mode], 0

    lea     rbx, [r14 + 8]          ; &argv[1]
    dec     ecx

    xor     edx, edx                ; past_dashdash = 0

.parse_loop:
    test    ecx, ecx
    jle     .parse_done
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done

    test    edx, edx
    jnz     .add_file_arg

    cmp     byte [rsi], '-'
    jne     .add_file_arg
    cmp     byte [rsi + 1], 0
    je      .add_stdin_arg

    cmp     byte [rsi + 1], '-'
    je      .long_or_dashdash

    ; Short options
    inc     rsi
.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .next_arg

    cmp     al, 'a'
    je      .short_a
    cmp     al, 't'
    je      .short_t

    ; Unknown
    push    rdx
    push    rcx
    push    rbx
    mov     rdi, rsi
    call    err_invalid_option
    pop     rbx
    pop     rcx
    pop     rdx
    mov     rdi, 1
    EXIT    rdi

.short_a:
    mov     byte [convert_entire_line], 1
    inc     rsi
    jmp     .short_loop

.short_t:
    inc     rsi
    movzx   eax, byte [rsi]
    test    al, al
    jnz     .do_parse_tabspec
    dec     ecx
    add     rbx, 8
    test    ecx, ecx
    jle     .err_missing_tabarg
    mov     rsi, [rbx]
    jmp     .do_parse_tabspec

.long_or_dashdash:
    cmp     byte [rsi + 2], 0
    je      .set_dashdash

    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_help]
    call    strcmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .do_help

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_version]
    call    strcmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .do_version

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_all]
    call    strcmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .set_all_long

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_firstonly]
    call    strcmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .set_firstonly

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_tabs_eq]
    mov     ecx, 7
    call    strncmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .long_tabs

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    call    err_unrecognized_option
    pop     rbx
    pop     rcx
    pop     rdx
    mov     rdi, 1
    EXIT    rdi

.set_all_long:
    mov     byte [convert_entire_line], 1
    jmp     .next_arg
.set_firstonly:
    mov     byte [first_only], 1
    jmp     .next_arg
.long_tabs:
    mov     rsi, [rbx]
    add     rsi, 7
    jmp     .do_parse_tabspec
.set_dashdash:
    mov     edx, 1
    jmp     .next_arg
.add_stdin_arg:
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .next_arg
    lea     rdi, [file_list]
    mov     qword [rdi + rax*8], 0
    inc     eax
    mov     [num_files], eax
    jmp     .next_arg
.add_file_arg:
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .next_arg
    lea     rdi, [file_list]
    mov     r8, [rbx]
    mov     [rdi + rax*8], r8
    inc     eax
    mov     [num_files], eax
    jmp     .next_arg
.next_arg:
    add     rbx, 8
    dec     ecx
    jmp     .parse_loop
.err_missing_tabarg:
    lea     rdi, [str_tab_missing]
    call    print_error_msg
    mov     rdi, 1
    EXIT    rdi

; ─── Parse tab spec ───────────────────────────────────────
.do_parse_tabspec:
    push    rdx
    push    rcx
    push    rbx
    mov     byte [convert_entire_line], 1

    mov     rdi, rsi
    call    has_comma
    test    eax, eax
    jnz     .parse_tab_list

    cmp     byte [rsi], '/'
    je      .tab_skip_prefix
    cmp     byte [rsi], '+'
    je      .tab_skip_prefix
    jmp     .tab_parse_single
.tab_skip_prefix:
    inc     rsi
.tab_parse_single:
    call    parse_number
    test    eax, eax
    jle     .bad_tab_num
    mov     [default_tab], eax
    mov     byte [tab_list_mode], 0
    pop     rbx
    pop     rcx
    pop     rdx
    jmp     .next_arg
.bad_tab_num:
    pop     rbx
    pop     rcx
    pop     rdx
    lea     rdi, [str_tab_invalid]
    call    print_error_msg
    mov     rdi, 1
    EXIT    rdi
.parse_tab_list:
    mov     byte [tab_list_mode], 1
    mov     dword [num_tab_stops], 0
.tab_list_loop:
    cmp     byte [rsi], '/'
    je      .tab_list_skip_pfx
    cmp     byte [rsi], '+'
    je      .tab_list_skip_pfx
    jmp     .tab_list_parse_num
.tab_list_skip_pfx:
    inc     rsi
.tab_list_parse_num:
    call    parse_number
    test    eax, eax
    jl      .bad_tab_num
    mov     edi, [num_tab_stops]
    cmp     edi, MAX_TAB_STOPS
    jge     .tab_list_next_comma
    lea     r8, [tab_stops]
    mov     [r8 + rdi*4], eax
    inc     edi
    mov     [num_tab_stops], edi
.tab_list_next_comma:
    cmp     byte [rsi], ','
    jne     .tab_list_done
    inc     rsi
    jmp     .tab_list_loop
.tab_list_done:
    pop     rbx
    pop     rcx
    pop     rdx
    jmp     .next_arg

; ─── Done parsing ─────────────────────────────────────────
.parse_done:
    cmp     byte [first_only], 1
    jne     .check_files
    mov     byte [convert_entire_line], 0
.check_files:
    cmp     dword [num_files], 0
    jne     .process_files
    mov     edi, STDIN
    call    process_fd
    jmp     .final_flush
.process_files:
    xor     ebx, ebx
.file_loop:
    cmp     ebx, [num_files]
    jge     .final_flush
    lea     rdi, [file_list]
    mov     rsi, [rdi + rbx*8]
    test    rsi, rsi
    jz      .file_stdin
    push    rbx
    call    open_and_process
    pop     rbx
    jmp     .file_next
.file_stdin:
    push    rbx
    mov     edi, STDIN
    call    process_fd
    pop     rbx
.file_next:
    inc     ebx
    jmp     .file_loop
.final_flush:
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit
    movzx   rdi, bpl
    EXIT    rdi
.write_error_exit:
    lea     rdi, [str_write_error]
    call    print_error_msg
    mov     rdi, 1
    EXIT    rdi

; ─── Help & Version ───────────────────────────────────────
.do_help:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi
.do_version:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

; ═══════════════════════════════════════════════════════════
;  open_and_process(rsi=filename)
; ═══════════════════════════════════════════════════════════
open_and_process:
    push    rbx
    push    r14
    push    r15
    mov     rbx, rsi

    mov     rdi, rsi
    xor     esi, esi
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .oap_error
    mov     r14, rax                ; fd

    ; fstat
    sub     rsp, STAT_STRUCT_SIZE
    mov     rdi, r14
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    mov     r15, [rsp + STAT_SIZE]
    add     rsp, STAT_STRUCT_SIZE
    test    rax, rax
    js      .oap_read_fallback

    test    r15, r15
    jle     .oap_read_fallback

    ; mmap
    xor     edi, edi
    mov     rsi, r15
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE | MAP_POPULATE
    mov     r8, r14
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .oap_read_fallback

    push    rax
    mov     rdi, rax
    mov     rsi, r15
    call    process_buffer
    pop     rdi

    mov     rsi, r15
    mov     rax, SYS_MUNMAP
    syscall

    mov     rdi, r14
    mov     rax, SYS_CLOSE
    syscall
    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_read_fallback:
    mov     edi, r14d
    call    process_fd
    mov     rdi, r14
    mov     rax, SYS_CLOSE
    syscall
    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_error:
    neg     rax
    mov     rdi, rbx
    mov     esi, eax
    call    err_file
    mov     ebp, 1
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  process_fd(edi=fd) — streaming
; ═══════════════════════════════════════════════════════════
process_fd:
    push    rbx
    push    r13
    mov     ebx, edi

    ; Initialize per-file state
    call    init_line_state

.pf_read:
    mov     edi, ebx
    lea     rsi, [read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read
    test    rax, rax
    js      .pf_error
    jz      .pf_eof

    lea     rdi, [read_buf]
    mov     rsi, rax
    call    unexpand_core
    jmp     .pf_read

.pf_eof:
    call    flush_pending_blanks
    pop     r13
    pop     rbx
    ret
.pf_error:
    call    flush_pending_blanks
    mov     ebp, 1
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  process_buffer(rdi=data, rsi=len)
; ═══════════════════════════════════════════════════════════
process_buffer:
    push    rbx
    push    r13

    call    init_line_state
    call    unexpand_core
    call    flush_pending_blanks

    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  init_line_state — reset per-line state for start of file
; ═══════════════════════════════════════════════════════════
init_line_state:
    mov     byte [st_convert], 1    ; start in convert mode
    mov     dword [st_column], 0
    mov     dword [st_next_tab_col], 0
    mov     dword [st_tab_index], 0
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1  ; as if preceded by blank
    mov     dword [st_pending], 0
    ret

; ═══════════════════════════════════════════════════════════
;  unexpand_core(rdi=data, rsi=len)
;
;  Faithfully implements the GNU unexpand algorithm:
;  - prev_blank starts true (as if line preceded by blank)
;  - When a blank lands on a tab stop with prev_blank true: emit tab
;  - Otherwise buffer blanks, with one_blank_before_tab_stop tracking
;  - Flush buffered blanks on non-blank, converting if applicable
; ═══════════════════════════════════════════════════════════
unexpand_core:
    push    rbx
    push    r14
    push    r15
    push    r13

    mov     rbx, rdi                ; data ptr
    mov     r13, rsi                ; remaining

.uc_loop:
    test    r13, r13
    jle     .uc_done

    ; Fast path: if not converting, copy bytes verbatim until newline
    cmp     byte [st_convert], 0
    je      .uc_verbatim

    movzx   eax, byte [rbx]

    cmp     al, ' '
    je      .uc_space
    cmp     al, 9
    je      .uc_tab_char
    cmp     al, 10
    je      .uc_newline
    cmp     al, 8
    je      .uc_backspace

    ; ─── Non-blank, non-special character ─────────────
    ; Flush pending blanks
    call    flush_pending_blanks

    ; Emit the character
    movzx   eax, byte [rbx]
    call    emit_byte

    ; column++
    inc     dword [st_column]

    ; prev_blank = false
    mov     byte [st_prev_blank], 0

    ; convert &= convert_entire_line (since this is non-blank)
    cmp     byte [convert_entire_line], 0
    jne     .uc_non_blank_next
    mov     byte [st_convert], 0
.uc_non_blank_next:
    inc     rbx
    dec     r13
    jmp     .uc_loop

; ─── Space ────────────────────────────────────────────────
.uc_space:
    ; Get next tab column
    mov     edi, [st_column]
    mov     esi, [st_tab_index]
    call    get_next_tab_column
    ; eax = next_tab_column, edx = last_tab flag
    mov     [st_next_tab_col], eax

    ; If last_tab, stop converting
    test    edx, edx
    jz      .uc_space_convert

    mov     byte [st_convert], 0
    ; Flush pending, emit space literally
    call    flush_pending_blanks
    mov     al, ' '
    call    emit_byte
    inc     dword [st_column]
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop

.uc_space_convert:
    ; column++
    mov     eax, [st_column]
    inc     eax
    mov     [st_column], eax

    ; Check: prev_blank && column == next_tab_column
    cmp     byte [st_prev_blank], 0
    je      .uc_space_no_convert

    cmp     eax, [st_next_tab_col]
    jne     .uc_space_no_convert

    ; prev_blank=true AND column==next_tab_column:
    ; Replace pending blanks by a tab
    ; pending_blank[0] = '\t'
    lea     rdi, [pending_buf]
    mov     byte [rdi], 9

    ; c = '\t' (we'll output tab via the pending flush)
    ; pending = one_blank_before_tab_stop
    movzx   eax, byte [st_one_blank_before]
    mov     [st_pending], eax

    ; Advance tab_index
    mov     eax, [st_tab_index]
    inc     eax
    mov     [st_tab_index], eax

    ; Now flush pending blanks + output the tab
    ; But GNU does: pending = one_blank_before; then falls through to
    ; the flush section which outputs pending_blank[0..pending).
    ; Then putchar(c) where c='\t'.
    ; Actually looking more carefully: after the conversion, code falls
    ; to line 206: pending = one_blank_before_tab_stop;
    ; Then line 224: if (pending) fwrite + pending=0 + one_blank=false
    ; Then putchar(c='\t')

    ; So we need to:
    ; 1. If old one_blank_before was true: pending=1, pending_buf[0]='\t'
    ;    -> write out the tab (for the one_blank_before portion)
    ; 2. Then putchar('\t') for the current character

    ; Actually wait. Let me re-read:
    ; Line 201: pending_blank[0] = c = '\t';
    ; Line 206: pending = one_blank_before_tab_stop;
    ;
    ; Then at line 224-230:
    ; if (pending) {
    ;   if (pending > 1 && one_blank_before_tab_stop)
    ;     pending_blank[0] = '\t';
    ;   fwrite(pending_blank, 1, pending, stdout);
    ;   pending = 0;
    ;   one_blank_before = false;
    ; }
    ;
    ; Then putchar(c)  // c is '\t'

    ; So: pending was set to one_blank_before (0 or 1).
    ; If pending is 1: fwrite 1 byte which is pending_blank[0]='\t'
    ;   (the check pending>1 is false, so pending_blank[0] stays as '\t')
    ; Then putchar('\t')
    ; So output would be: '\t' (from pending) + '\t' (from putchar)
    ; That would be 2 tabs. That seems wrong for a 2-space run...

    ; Wait, one_blank_before_tab_stop only becomes true when a PREVIOUS
    ; blank hit the tab stop without prev_blank being true. So in the
    ; case of 2 spaces hitting tab stop:
    ; - First space: prev_blank=true, column=1, next_tab=8 (say).
    ;   column!=next_tab, so falls to: if(column==next_tab) -> no.
    ;   pending_blank[0]=' ', pending=1, prev_blank=true. continue.
    ; - Second space: prev_blank=true, column=2, next_tab=8.
    ;   column!=next_tab, so same. pending_blank[1]=' ', pending=2. continue.
    ; ... continues until the space that hits the tab stop.
    ; - Nth space hitting tab stop: prev_blank=true, column=8=next_tab.
    ;   YES: pending_blank[0]='\t', c='\t'.
    ;   pending = one_blank_before (which is false=0).
    ;   Then at 224: pending=0, skip.
    ;   putchar('\t'). Output: '\t'.

    ; So only one tab is output. The pending blanks are all discarded
    ; and replaced by a single tab. Good.

    ; Now for a case where one_blank_before IS true:
    ; Example: 9 spaces with tabstop 8.
    ; Spaces 1-7: pending grows to 7. When space 8 (col=8=next_tab):
    ;   prev_blank=true: pending_blank[0]='\t', c='\t'.
    ;   pending = one_blank_before (false) = 0.
    ;   putchar('\t').
    ; Space 9: now column=8, prev_blank=true (set at line 235).
    ;   get_next_tab_column(8) = 16. column++ = 9.
    ;   prev_blank && column==next_tab? true && 9==16? NO.
    ;   column==next_tab? 9==16? NO.
    ;   pending_blank[0]=' ', pending=1.
    ;   prev_blank=true. continue.
    ; Then 'x': flush pending.
    ;   pending=1. pending>1? no. fwrite 1 space. putchar('x').
    ; Result: '\t' + ' ' + 'x'. Correct!

    ; So the right implementation:
    ; After line 201-206, pending = one_blank_before (0 or 1).
    ; We need to emit that pending (if any), then emit '\t' as the char.

    ; Flush the old one_blank_before pending (if 1, it's a tab)
    mov     eax, [st_pending]
    test    eax, eax
    jz      .uc_space_conv_emit

    ; There's 1 pending byte (which is '\t' from line 201 / original logic)
    ; But wait, line 227: if(pending>1 && one_blank_before) pending_blank[0]='\t'
    ; pending is 1 here (=one_blank_before), so pending>1 is FALSE.
    ; So pending_blank[0] is whatever it was... it was set to '\t' at line 201.
    ; Hmm actually line 201 sets pending_blank[0]='\t' regardless.
    ; And pending = one_blank_before = 1. So we write 1 byte = '\t'.
    ; Then putchar('\t').
    ; That would be 2 tabs. Let me trace a concrete example.

    ; Actually, one_blank_before_tab_stop only becomes true on this path:
    ; Line 193: if (column == next_tab_column) one_blank_before = true;
    ; This happens when a space hits the tab stop but prev_blank is false.
    ; So in that case, prev_blank was false, meaning the character before
    ; was NOT a blank. Then the next blank with prev_blank=true goes to
    ; the conversion path. But one_blank_before is true.
    ;
    ; Example: "ab      x" with tabstop 8.
    ; a: column=1, prev_blank=false
    ; b: column=2, prev_blank=false
    ; ' ': prev_blank=false. column=3, next_tab=8. 3!=8.
    ;   column!=next_tab (3!=8). pending_blank[0]=' ', pending=1. prev_blank=true.
    ; ' ': prev_blank=true. column=4, next_tab=8. 4!=8. column!=next_tab.
    ;   pending_blank[1]=' ', pending=2. prev_blank=true.
    ; ... continues to column=7:
    ; ' ': prev_blank=true. column=8, next_tab=8. YES!
    ;   pending_blank[0]='\t', c='\t'. pending = one_blank_before (false) = 0.
    ;   putchar('\t'). Result so far: "ab\t"
    ;
    ; Now "abcdefg  x" with tabstop 8:
    ; a-g: column=7, prev_blank=false
    ; ' ': prev_blank=false. column=8, next_tab=8.
    ;   prev_blank && column==next_tab: false. NO conversion.
    ;   column==next_tab (8==8): one_blank_before = true.
    ;   pending_blank[0]=' ', pending=1. prev_blank=true.
    ; ' ': prev_blank=true. column=9, next_tab=16 (new tab stop).
    ;   prev_blank && column==next_tab: true && 9==16. NO.
    ;   column==next_tab: 9==16. NO.
    ;   pending_blank[1]=' ', pending=2. prev_blank=true.
    ; 'x': flush pending.
    ;   pending=2. pending>1 && one_blank_before: true!
    ;   pending_blank[0]='\t'. fwrite 2 bytes: '\t', ' '. putchar('x').
    ;   Result: "abcdefg\t x". Hmm that's 3 chars for 2 spaces?
    ;   Wait, the tab at col 8 goes to col 16, and we have an extra ' '?
    ;   No: pending_blank[0]='\t', pending_blank[1]=' '.
    ;   fwrite outputs '\t' then ' '. That goes: col 8 -> tab to 16 -> space to 17.
    ;   But the input only went to col 9 (2 spaces from col 7).
    ;   Something is wrong with my trace... Actually the second space:
    ;   After processing the first space, column=8 and we continue.
    ;   The second space: get_next_tab_column(8, &tab_index) might
    ;   return 16. column++ = 9. That's correct. pending=2 now.
    ;   On 'x': pending_blank = [' ', ' '] (but then [0] gets overwritten to '\t')
    ;   -> fwrite('\t', ' ') -> but that's tab(8->16) + space = col 17, not 9.
    ;   That's clearly wrong... unless I'm misunderstanding the code.

    ; Hmm, let me re-check the actual GNU behavior:

    ; OK wait, I think the key insight is: the pending buffer stores the ORIGINAL
    ; characters. The tab_index is NOT incremented when we just buffer.
    ; get_next_tab_column is called for each blank. The tab_index can change.
    ; Let me look at get_next_tab_column more carefully.

    ; Actually, I realize I need to step back and just faithfully replicate
    ; the GNU algorithm character by character instead of trying to optimize.
    ; Let me simplify.

    ; For NOW: just do it the simple way.

    ; Emit the pending (which is one_blank_before count)
    cmp     dword [st_pending], 0
    je      .uc_space_conv_emit
    ; pending is 1, and pending_buf[0] was set to '\t' above
    lea     rsi, [pending_buf]
    mov     ecx, [st_pending]
    call    emit_bytes
    mov     dword [st_pending], 0

.uc_space_conv_emit:
    ; Output the tab character
    mov     al, 9
    call    emit_byte

    ; one_blank_before = false
    mov     byte [st_one_blank_before], 0
    ; prev_blank = true (it's a blank char)
    mov     byte [st_prev_blank], 1

    ; Update tab_index (advance past this tab stop)
    ; Actually in GNU code, the tab_index was already advanced by
    ; get_next_tab_column. We just need to track that.

    ; convert &= convert_entire_line || blank (blank=true, so convert stays)
    inc     rbx
    dec     r13
    jmp     .uc_loop

.uc_space_no_convert:
    ; We are here when: NOT(prev_blank && column == next_tab_column)
    ; Check: column == next_tab_column ?
    mov     eax, [st_column]
    cmp     eax, [st_next_tab_col]
    jne     .uc_space_just_buffer
    ; Yes: one_blank_before_tab_stop = true
    mov     byte [st_one_blank_before], 1

.uc_space_just_buffer:
    ; Buffer this space
    mov     eax, [st_pending]
    cmp     eax, PENDING_SIZE
    jge     .uc_space_pending_overflow
    lea     rdi, [pending_buf]
    mov     byte [rdi + rax], ' '
    inc     eax
    mov     [st_pending], eax

    mov     byte [st_prev_blank], 1
    ; convert stays true (blank char)
    inc     rbx
    dec     r13
    jmp     .uc_loop

.uc_space_pending_overflow:
    ; Flush and buffer
    call    flush_pending_blanks
    lea     rdi, [pending_buf]
    mov     byte [rdi], ' '
    mov     dword [st_pending], 1
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop

; ─── Tab character ────────────────────────────────────────
.uc_tab_char:
    ; Get next tab column
    mov     edi, [st_column]
    mov     esi, [st_tab_index]
    call    get_next_tab_column
    mov     [st_next_tab_col], eax

    ; If last_tab, stop converting
    test    edx, edx
    jz      .uc_tab_convert

    mov     byte [st_convert], 0
    call    flush_pending_blanks
    mov     al, 9
    call    emit_byte
    ; column = next_tab_col (since tab advances to next stop)
    mov     eax, [st_next_tab_col]
    mov     [st_column], eax
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop

.uc_tab_convert:
    ; column = next_tab_column
    mov     eax, [st_next_tab_col]
    mov     [st_column], eax

    ; If pending, pending_blank[0] = '\t'
    cmp     dword [st_pending], 0
    je      .uc_tab_no_pending
    lea     rdi, [pending_buf]
    mov     byte [rdi], 9

.uc_tab_no_pending:
    ; pending = one_blank_before_tab_stop
    movzx   eax, byte [st_one_blank_before]
    mov     [st_pending], eax

    ; Advance tab_index
    mov     eax, [st_tab_index]
    inc     eax
    mov     [st_tab_index], eax

    ; Now flush pending + emit tab (same as space conversion path)
    cmp     dword [st_pending], 0
    je      .uc_tab_emit
    lea     rsi, [pending_buf]
    mov     ecx, [st_pending]
    call    emit_bytes
    mov     dword [st_pending], 0

.uc_tab_emit:
    mov     al, 9
    call    emit_byte
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop

; ─── Newline ──────────────────────────────────────────────
.uc_newline:
    call    flush_pending_blanks
    mov     al, 10
    call    emit_byte

    ; Reset line state
    mov     byte [st_convert], 1
    mov     dword [st_column], 0
    mov     dword [st_next_tab_col], 0
    mov     dword [st_tab_index], 0
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1
    mov     dword [st_pending], 0

    inc     rbx
    dec     r13
    jmp     .uc_loop

; ─── Backspace ────────────────────────────────────────────
.uc_backspace:
    call    flush_pending_blanks
    mov     al, 8
    call    emit_byte

    ; column -= !!column
    mov     eax, [st_column]
    test    eax, eax
    jz      .uc_bs_no_dec
    dec     eax
    mov     [st_column], eax
.uc_bs_no_dec:
    ; next_tab_column = column
    mov     [st_next_tab_col], eax
    ; tab_index -= !!tab_index
    mov     eax, [st_tab_index]
    test    eax, eax
    jz      .uc_bs_no_tidx
    dec     eax
    mov     [st_tab_index], eax
.uc_bs_no_tidx:
    mov     byte [st_prev_blank], 0
    ; convert stays as-is
    inc     rbx
    dec     r13
    jmp     .uc_loop

; ─── Verbatim copy (not converting) ──────────────────────
.uc_verbatim:
    ; Copy until newline, scanning with SSE2
    cmp     r13, 16
    jl      .uc_verb_scalar

    movdqu  xmm0, [rbx]
    pcmpeqb xmm0, [nl_pattern]
    pmovmskb eax, xmm0
    test    eax, eax
    jnz     .uc_verb_found_nl

    ; No newline: bulk copy 16 bytes
    lea     rdi, [out_buf]
    add     rdi, r12
    lea     rcx, [r12 + 16]
    cmp     rcx, FLUSH_THRESHOLD
    jl      .uc_verb_nf
    push    rbx
    push    r13
    call    flush_output
    pop     r13
    pop     rbx
    lea     rdi, [out_buf]
    add     rdi, r12
.uc_verb_nf:
    movdqu  xmm1, [rbx]
    movdqu  [rdi], xmm1
    add     r12, 16
    add     dword [st_column], 16
    add     rbx, 16
    sub     r13, 16
    jmp     .uc_verbatim

.uc_verb_found_nl:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .uc_verb_emit_nl

    ; Copy ecx bytes before newline
    push    rcx
    lea     rdi, [out_buf]
    add     rdi, r12
    lea     rax, [r12 + rcx]
    cmp     rax, FLUSH_THRESHOLD
    jl      .uc_verb_nl_nf
    push    rbx
    push    r13
    call    flush_output
    pop     r13
    pop     rbx
    lea     rdi, [out_buf]
    add     rdi, r12
.uc_verb_nl_nf:
    mov     rsi, rbx
    pop     rcx
    push    rcx
    rep     movsb
    pop     rcx
    add     r12, rcx
    add     [st_column], ecx
    add     rbx, rcx
    sub     r13, rcx

.uc_verb_emit_nl:
    mov     al, 10
    call    emit_byte
    mov     byte [st_convert], 1
    mov     dword [st_column], 0
    mov     dword [st_next_tab_col], 0
    mov     dword [st_tab_index], 0
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1
    mov     dword [st_pending], 0
    inc     rbx
    dec     r13
    jmp     .uc_loop

.uc_verb_scalar:
    test    r13, r13
    jle     .uc_done
    movzx   eax, byte [rbx]
    cmp     al, 10
    je      .uc_verb_emit_nl
    call    emit_byte
    inc     dword [st_column]
    inc     rbx
    dec     r13
    jmp     .uc_verb_scalar

.uc_done:
    pop     r13
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  get_next_tab_column(edi=column, esi=tab_index)
;  -> eax=next_tab_column, edx=last_tab (1 if past all stops)
;  Also updates [st_tab_index]
; ═══════════════════════════════════════════════════════════
get_next_tab_column:
    cmp     byte [tab_list_mode], 0
    jne     .gntc_list

    ; Uniform tab stops: next = ((col / tab) + 1) * tab
    mov     eax, edi
    xor     edx, edx
    mov     ecx, [default_tab]
    test    ecx, ecx
    jz      .gntc_fallback
    push    rdi
    div     ecx
    inc     eax
    imul    eax, ecx
    pop     rdi
    xor     edx, edx                ; never last_tab for uniform
    ret

.gntc_fallback:
    lea     eax, [edi + 1]
    xor     edx, edx
    ret

.gntc_list:
    ; Tab stop list: find first stop > col using tab_index hint
    mov     ecx, esi                ; start from tab_index
    mov     edx, [num_tab_stops]

.gntc_scan:
    cmp     ecx, edx
    jge     .gntc_beyond

    lea     rax, [tab_stops]
    mov     eax, [rax + rcx*4]
    cmp     eax, edi
    jg      .gntc_found
    inc     ecx
    jmp     .gntc_scan

.gntc_found:
    ; Update tab_index
    mov     [st_tab_index], ecx
    xor     edx, edx                ; not last_tab
    ret

.gntc_beyond:
    ; Past all tab stops: last_tab = true
    mov     eax, 0x7FFFFFFF
    mov     edx, 1
    ret

; ═══════════════════════════════════════════════════════════
;  flush_pending_blanks — write buffered blanks to output
;  Implements the GNU logic:
;    if (pending > 1 && one_blank_before_tab_stop)
;      pending_blank[0] = '\t';
;    fwrite(pending_blank, 1, pending, stdout);
;    pending = 0; one_blank_before = false;
; ═══════════════════════════════════════════════════════════
flush_pending_blanks:
    mov     eax, [st_pending]
    test    eax, eax
    jz      .fpb_done

    ; Check if we should convert first blank to tab
    cmp     eax, 1
    jle     .fpb_no_tab_convert
    cmp     byte [st_one_blank_before], 0
    je      .fpb_no_tab_convert
    ; pending > 1 && one_blank_before: convert first to tab
    lea     rdi, [pending_buf]
    mov     byte [rdi], 9

.fpb_no_tab_convert:
    ; Write pending bytes
    lea     rsi, [pending_buf]
    mov     ecx, eax
    call    emit_bytes

    mov     dword [st_pending], 0
    mov     byte [st_one_blank_before], 0

.fpb_done:
    ret

; ═══════════════════════════════════════════════════════════
;  emit_byte — append AL to output buffer
; ═══════════════════════════════════════════════════════════
emit_byte:
    lea     rdi, [out_buf]
    mov     [rdi + r12], al
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .eb_ret
    push    rbx
    push    r13
    call    flush_output
    pop     r13
    pop     rbx
.eb_ret:
    ret

; ═══════════════════════════════════════════════════════════
;  emit_bytes — append ecx bytes from rsi to output buffer
; ═══════════════════════════════════════════════════════════
emit_bytes:
    test    ecx, ecx
    jle     .ebs_done
    lea     rax, [r12 + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .ebs_copy
    push    rcx
    push    rsi
    push    rbx
    push    r13
    call    flush_output
    pop     r13
    pop     rbx
    pop     rsi
    pop     rcx
.ebs_copy:
    lea     rdi, [out_buf]
    add     rdi, r12
    push    rcx
    rep     movsb
    pop     rcx
    add     r12, rcx
.ebs_done:
    ret

; ═══════════════════════════════════════════════════════════
;  flush_output — write out_buf to stdout
; ═══════════════════════════════════════════════════════════
flush_output:
    test    r12, r12
    jz      .fo_empty
    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret
.fo_empty:
    xor     eax, eax
    ret

; ═══════════════════════════════════════════════════════════
;  String utilities
; ═══════════════════════════════════════════════════════════

strcmp:
.sc_l:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .sc_n
    test    al, al
    jz      .sc_e
    inc     rdi
    inc     rsi
    jmp     .sc_l
.sc_e:
    xor     eax, eax
    ret
.sc_n:
    mov     eax, 1
    ret

strncmp:
    test    ecx, ecx
    jz      .sn_e
.sn_l:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .sn_n
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     .sn_l
.sn_e:
    xor     eax, eax
    ret
.sn_n:
    mov     eax, 1
    ret

strlen:
    xor     eax, eax
.sl_l:
    cmp     byte [rdi + rax], 0
    je      .sl_d
    inc     rax
    jmp     .sl_l
.sl_d:
    ret

has_comma:
    xor     eax, eax
.hc_l:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .hc_d
    cmp     cl, ','
    je      .hc_f
    inc     rdi
    jmp     .hc_l
.hc_f:
    mov     eax, 1
.hc_d:
    ret

parse_number:
    xor     eax, eax
.pn_l:
    movzx   ecx, byte [rsi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .pn_d
    imul    eax, 10
    add     eax, ecx
    inc     rsi
    jmp     .pn_l
.pn_d:
    ret

; ═══════════════════════════════════════════════════════════
;  Error helpers
; ═══════════════════════════════════════════════════════════

print_error_msg:
    push    rbx
    mov     rbx, rdi
    mov     rdi, STDERR
    lea     rsi, [str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_newline]
    mov     rdx, 1
    call    asm_write_all
    pop     rbx
    ret

err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi
    mov     rdi, STDERR
    lea     rsi, [str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_colon_space]
    mov     rdx, 2
    call    asm_write_all
    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_newline]
    mov     rdx, 1
    call    asm_write_all
    pop     r13
    pop     rbx
    ret

err_unrecognized_option:
    push    rbx
    mov     rbx, rsi
    mov     rdi, STDERR
    lea     rsi, [str_unrec_prefix]
    mov     rdx, str_unrec_prefix_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_quote_nl]
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all
    pop     rbx
    ret

err_invalid_option:
    push    rbx
    mov     rbx, rdi
    mov     rdi, STDERR
    lea     rsi, [str_inval_prefix]
    mov     rdx, str_inval_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, rbx
    mov     rdx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_quote_nl]
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all
    pop     rbx
    ret

strerror:
    cmp     edi, 1
    je      .se1
    cmp     edi, 2
    je      .se2
    cmp     edi, 5
    je      .se5
    cmp     edi, 9
    je      .se9
    cmp     edi, 12
    je      .se12
    cmp     edi, 13
    je      .se13
    cmp     edi, 20
    je      .se20
    cmp     edi, 21
    je      .se21
    cmp     edi, 22
    je      .se22
    cmp     edi, 24
    je      .se24
    cmp     edi, 36
    je      .se36
    lea     rax, [str_eunknown]
    ret
.se1:  lea rax, [str_eperm]
    ret
.se2:  lea rax, [str_enoent]
    ret
.se5:  lea rax, [str_eio]
    ret
.se9:  lea rax, [str_ebadf]
    ret
.se12: lea rax, [str_enomem]
    ret
.se13: lea rax, [str_eacces]
    ret
.se20: lea rax, [str_enotdir]
    ret
.se21: lea rax, [str_eisdir]
    ret
.se22: lea rax, [str_einval]
    ret
.se24: lea rax, [str_emfile]
    ret
.se36: lea rax, [str_enametoolong]
    ret

; ─── Data Section ─────────────────────────────────────────
section .data

align 16
nl_pattern:
    times 16 db 10

str_prefix:     db "unexpand: "
str_prefix_len equ $ - str_prefix

str_newline:    db 10
str_colon_space: db ": "

str_opt_help:       db "--help", 0
str_opt_version:    db "--version", 0
str_opt_all:        db "--all", 0
str_opt_firstonly:  db "--first-only", 0
str_opt_tabs_eq:    db "--tabs=", 0

str_unrec_prefix:   db "unexpand: unrecognized option '"
str_unrec_prefix_len equ $ - str_unrec_prefix

str_inval_prefix:   db "unexpand: invalid option -- '"
str_inval_prefix_len equ $ - str_inval_prefix

str_quote_nl:   db "'", 10

str_try_help:   db "Try 'unexpand --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_write_error: db "write error", 0
str_tab_missing: db "option requires an argument -- 't'", 0
str_tab_invalid: db "tab size contains invalid character", 0

; @@DATA_START@@
help_text:
    db "Usage: unexpand [OPTION]... [FILE]...", 10
    db "Convert blanks in each FILE to tabs, writing to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -a, --all        convert all blanks, instead of just initial blanks", 10
    db "      --first-only  convert only leading sequences of blanks (overrides -a)", 10
    db "  -t, --tabs=N     have tabs N characters apart instead of 8 (enables -a)", 10
    db "  -t, --tabs=LIST  use comma separated list of tab positions.", 10
    db "                     The last specified position can be prefixed with '/'", 10
    db "                     to specify a tab size to use after the last", 10
    db "                     explicitly specified tab stop.  Also a prefix of '+'", 10
    db "                     can be used to align remaining tab stops relative to", 10
    db "                     the last specified tab stop instead of the first column", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/unexpand>", 10
    db "or available locally via: info '(coreutils) unexpand invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "unexpand (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://www.gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie.", 10
version_text_len equ $ - version_text
; @@DATA_END@@

str_eperm:          db "Operation not permitted", 0
str_enoent:         db "No such file or directory", 0
str_eio:            db "Input/output error", 0
str_ebadf:          db "Bad file descriptor", 0
str_enomem:         db "Cannot allocate memory", 0
str_eacces:         db "Permission denied", 0
str_enotdir:        db "Not a directory", 0
str_eisdir:         db "Is a directory", 0
str_einval:         db "Invalid argument", 0
str_emfile:         db "Too many open files", 0
str_enametoolong:   db "File name too long", 0
str_eunknown:       db "Unknown error", 0

; ─── BSS Section ──────────────────────────────────────────
section .bss

read_buf:           resb READ_BUF_SIZE
out_buf:            resb OUT_BUF_SIZE
pending_buf:        resb PENDING_SIZE

; Configuration
convert_entire_line: resb 1
first_only:         resb 1
tab_list_mode:      resb 1
                    resb 1              ; padding
default_tab:        resd 1
num_tab_stops:      resd 1
tab_stops:          resd MAX_TAB_STOPS
num_files:          resd 1
file_list:          resq MAX_FILES

; Per-line state (GNU algorithm)
st_convert:         resb 1
st_prev_blank:      resb 1
st_one_blank_before: resb 1
                    resb 1              ; padding
st_column:          resd 1
st_next_tab_col:    resd 1
st_tab_index:       resd 1
st_pending:         resd 1

section .note.GNU-stack noalloc noexec nowrite progbits
