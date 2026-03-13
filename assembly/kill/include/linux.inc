; linux.inc — Linux x86-64 syscall numbers and constants

%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_KILL        62
%define SYS_EXIT        60
%define SYS_GETPID      39

%define STDIN            0
%define STDOUT           1
%define STDERR           2

%define EINTR            4

%define BUF_SIZE     65536
