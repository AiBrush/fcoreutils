; Linux x86_64 syscall numbers
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_GETUID     102
%define SYS_GETGID     104
%define SYS_GETEUID    107
%define SYS_GETEGID    108
%define SYS_GETGROUPS  115

; File descriptors
%define STDIN           0
%define STDOUT          1
%define STDERR          2

; Open flags
%define O_RDONLY        0

; Buffer sizes
%define BUF_SIZE    65536
%define MAX_GROUPS    256
