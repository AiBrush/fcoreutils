; linux.inc — Linux x86-64 syscall numbers and constants for fdu

%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_STAT            4
%define SYS_FSTAT           5
%define SYS_LSTAT           6
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60
%define SYS_GETDENTS64    217
%define SYS_OPENAT        257

; File descriptors
%define STDIN               0
%define STDOUT              1
%define STDERR              2

; Open flags
%define O_RDONLY            0
%define O_DIRECTORY     0x10000

; Error numbers
%define EINTR               4
%define EPIPE              32
%define ENOENT              2
%define EACCES             13
%define ENOTDIR            20
%define ELOOP              40

; struct stat offsets (x86-64 Linux)
%define STAT_DEV            0
%define STAT_INO            8
%define STAT_NLINK         16
%define STAT_MODE          24
%define STAT_UID           28
%define STAT_GID           32
%define STAT_RDEV          40
%define STAT_SIZE          48
%define STAT_BLKSIZE       56
%define STAT_BLOCKS        64
%define STAT_ATIME         72
%define STAT_MTIME         88
%define STAT_CTIME        104
%define STAT_STRUCT_SIZE  144

; File type masks
%define S_IFMT          0o170000
%define S_IFDIR         0o040000
%define S_IFREG         0o100000
%define S_IFLNK         0o120000

; struct linux_dirent64
%define DIRENT_INO          0
%define DIRENT_OFF          8
%define DIRENT_RECLEN      16
%define DIRENT_TYPE        18
%define DIRENT_NAME        19

%define DT_DIR              4
%define DT_REG              8
%define DT_LNK             10

; Buffer sizes
%define OUT_BUF_SIZE    262144
%define FLUSH_THRESHOLD 131072
%define GETDENTS_SIZE    32768
%define PATH_MAX          4096
%define MAX_DEPTH         256
