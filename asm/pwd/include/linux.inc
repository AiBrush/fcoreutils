; Linux x86_64 syscall numbers
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_STAT        4
%define SYS_FSTAT       5
%define SYS_EXIT       60
%define SYS_NANOSLEEP  35
%define SYS_GETCWD     79
%define SYS_GETUID     102
%define SYS_GETEUID    107
%define SYS_UNAME      63
%define SYS_SYNC       162

; File descriptors
%define STDIN           0
%define STDOUT          1
%define STDERR          2

; Buffer sizes
%define BUF_SIZE    65536
%define ARG_BUF      4096
%define PATH_MAX     4096
%define STAT_SIZE     144
