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
%define SYS_RT_SIGACTION 13
%define SYS_IOCTL       16
%define SYS_ACCESS      21
%define SYS_PIPE        22
%define SYS_DUP2        33
%define SYS_NANOSLEEP   35
%define SYS_GETPID      39
%define SYS_FORK        57
%define SYS_EXECVE      59
%define SYS_EXIT        60
%define SYS_UNAME       63
%define SYS_GETCWD      79
%define SYS_GETUID     102
%define SYS_GETGID     104
%define SYS_GETEUID    107
%define SYS_GETEGID    108
%define SYS_SYNC       162

%define STDIN            0
%define STDOUT           1
%define STDERR           2

%define O_RDONLY         0

%define BUF_SIZE     65536

; struct stat offsets (x86-64 Linux)
%define STAT_SIZE       48      ; st_size offset in struct stat
%define STAT_MODE       24      ; st_mode offset
%define STAT_STRUCT_SIZE 144    ; sizeof(struct stat)

; File type masks
%define S_IFMT      0o170000
%define S_IFREG     0o100000

; Signal numbers
%define SIGPIPE     13

; Signal action constants
%define SIG_IGN      1
