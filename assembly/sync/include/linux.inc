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
%define SYS_FSYNC      74
%define SYS_FDATASYNC  75
%define SYS_SYNCFS     306

; open() flags
%define O_RDONLY        0

; File descriptors
%define STDIN           0
%define STDOUT          1
%define STDERR          2

; Error numbers (negative)
%define EINTR           4
%define ENOENT          2
%define EACCES          13
%define ELOOP           40
%define ENAMETOOLONG    36
%define ENOTDIR         20
%define ENOMEM          12
%define EMFILE          24
%define ENFILE          23
%define EISDIR          21
%define EIO             5
%define EBADF           9
%define EINVAL          22

; Buffer sizes
%define BUF_SIZE    65536
%define ARG_BUF      4096
%define PATH_MAX     4096
