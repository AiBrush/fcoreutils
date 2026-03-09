; linux.inc — Linux x86-64 syscall numbers and constants for fcat

%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_RT_SIGPROCMASK 14
%define SYS_SENDFILE       40
%define SYS_EXIT           60

%define STDIN               0
%define STDOUT              1
%define STDERR              2

%define O_RDONLY            0

%define EINTR               4
%define EPIPE              32

%define SIGPIPE            13

; struct stat offsets (x86-64 Linux)
%define STAT_MODE          24      ; st_mode offset
%define STAT_SIZE          48      ; st_size offset
%define STAT_STRUCT_SIZE  144      ; sizeof(struct stat)

; File type masks
%define S_IFMT          0o170000
%define S_IFREG         0o100000

; I/O buffer sizes
%define READ_BUF_SIZE   131072     ; 128KB read buffer
%define OUT_BUF_SIZE    262144     ; 256KB output buffer (worst case: -v doubles size)
%define FLUSH_THRESHOLD 131072     ; flush when output buffer >= 128KB
