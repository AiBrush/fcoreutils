; linux.inc — Linux x86-64 syscall numbers and constants
; Shared across all fcoreutils assembly tools

%ifndef LINUX_INC
%define LINUX_INC

; ── Syscall Numbers ──
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_MMAP            9
%define SYS_MUNMAP         11
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60

; ── File Descriptors ──
%define STDIN               0
%define STDOUT              1
%define STDERR              2

; ── Open Flags ──
%define O_RDONLY            0

; ── Signal Numbers ──
%define SIGPIPE            13
%define SIG_BLOCK           0

; ── Error Codes (negated for cmp against syscall return) ──
%define EINTR              -4
%define EPIPE             -32
%define ENOENT             -2
%define EACCES            -13
%define EISDIR            -21
%define ELOOP             -40
%define ENAMETOOLONG      -36
%define ENOMEM            -12
%define ENOTDIR           -20

; ── mmap constants ──
%define PROT_READ           1
%define MAP_PRIVATE         2

; ── struct stat offsets (x86-64 Linux) ──
%define STAT_MODE          24      ; st_mode offset
%define STAT_SIZE          48      ; st_size offset
%define STAT_STRUCT_SIZE  144      ; sizeof(struct stat)

; ── File type masks ──
%define S_IFMT          0o170000
%define S_IFREG         0o100000

; ── I/O buffer sizes ──
%define READ_BUF_SIZE   131072     ; 128KB read buffer
%define OUT_BUF_SIZE    262144     ; 256KB output buffer
%define FLUSH_THRESHOLD 131072     ; flush at 128KB

%endif
