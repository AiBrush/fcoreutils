; linux.inc — Linux x86-64 syscall numbers and constants
; Shared across all fcoreutils assembly tools (canonical superset)

%ifndef LINUX_INC
%define LINUX_INC

; ── Syscall Numbers ──
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_STAT            4
%define SYS_FSTAT           5
%define SYS_LSEEK           8
%define SYS_MMAP            9
%define SYS_MUNMAP         11
%define SYS_BRK            12
%define SYS_RT_SIGACTION   13
%define SYS_RT_SIGPROCMASK 14
%define SYS_IOCTL          16
%define SYS_ACCESS         21
%define SYS_PIPE           22
%define SYS_DUP2           33
%define SYS_NANOSLEEP      35
%define SYS_GETPID         39
%define SYS_SENDFILE       40
%define SYS_FORK           57
%define SYS_EXECVE         59
%define SYS_EXIT           60
%define SYS_UNAME          63
%define SYS_GETCWD         79
%define SYS_GETUID        102
%define SYS_GETGID        104
%define SYS_GETEUID       107
%define SYS_GETEGID       108
%define SYS_SYNC          162
%define SYS_OPENAT        257

; ── File Descriptors ──
%define STDIN               0
%define STDOUT              1
%define STDERR              2

; ── Open Flags ──
%define O_RDONLY            0
%define O_WRONLY            1
%define O_RDWR              2
%define O_CREAT          0x40
%define O_TRUNC         0x200
%define O_APPEND        0x400

; ── Signal Numbers ──
%define SIGPIPE            13
%define SIG_BLOCK           0
%define SIG_IGN             1

; ── Error Codes (negated) ──
%define EINTR              -4
%define ENOENT             -2
%define EACCES            -13
%define EPIPE             -32

; ── Buffer Sizes ──
%define BUF_SIZE        65536
%define ARG_BUF          4096
%define PATH_MAX         4096

; ── struct stat offsets (x86-64 Linux) ──
%define STAT_MODE          24
%define STAT_SIZE          48
%define STAT_STRUCT_SIZE  144

; ── File type masks ──
%define S_IFMT          0o170000
%define S_IFREG         0o100000

%endif
