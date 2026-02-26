; args.asm - argument parsing helpers for sync
; This module is intentionally minimal for sync
; The main parsing is done in tools/fsync.asm

%include "include/linux.inc"

global asm_parse_long_opt

section .text

; asm_parse_long_opt - placeholder for shared arg parsing
; For sync, all parsing is done inline in the tool
asm_parse_long_opt:
    ret
