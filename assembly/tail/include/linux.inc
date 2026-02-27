; linux.inc — Linux x86-64 syscall numbers and constants

%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_STAT         4
%define SYS_FSTAT        5
%define SYS_LSEEK        8
%define SYS_MMAP         9
%define SYS_MUNMAP      11
%define SYS_BRK         12
%define SYS_RT_SIGPROCMASK 14
%define SYS_IOCTL       16
%define SYS_ACCESS      21
%define SYS_EXIT        60
%define SYS_UNAME       63

%define STDIN            0
%define STDOUT           1
%define STDERR           2

%define O_RDONLY         0

%define SEEK_SET         0
%define SEEK_CUR         1
%define SEEK_END         2

%define PROT_READ        1
%define PROT_WRITE       2
%define MAP_PRIVATE      2
%define MAP_ANONYMOUS    0x20

%define S_IFMT           0xF000
%define S_IFREG          0x8000

; struct stat offsets (x86-64 Linux)
%define STAT_ST_MODE     24
%define STAT_ST_SIZE     48
%define STAT_SIZE        144

%define SIGPIPE          13

%define BUF_SIZE         65536

%define EINTR            -4
%define EPIPE            -32
