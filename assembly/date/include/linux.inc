; Linux x86_64 syscall numbers
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_STAT        4
%define SYS_FSTAT       5
%define SYS_EXIT       60
%define SYS_CLOCK_GETTIME 228

; Clock IDs
%define CLOCK_REALTIME  0

; File descriptors
%define STDIN           0
%define STDOUT          1
%define STDERR          2

; Buffer sizes
%define BUF_SIZE    65536
%define ARG_BUF      4096
%define PATH_MAX     4096
