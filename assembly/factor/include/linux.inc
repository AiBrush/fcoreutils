; linux.inc — Linux x86-64 syscall numbers and constants

%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_CLOSE        3
%define SYS_LSEEK        8
%define SYS_MMAP         9
%define SYS_MUNMAP      11
%define SYS_BRK         12
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT        60

%define STDIN            0
%define STDOUT           1
%define STDERR           2

%define BUF_SIZE     65536

; Signal numbers
%define SIGPIPE     13
%define SIG_IGN      1
