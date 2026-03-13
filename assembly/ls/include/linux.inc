; linux.inc — Linux x86-64 syscall numbers and constants for fls

%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_STAT            4
%define SYS_FSTAT           5
%define SYS_LSTAT           6
%define SYS_IOCTL          16
%define SYS_READLINK       89
%define SYS_GETDENTS64    217
%define SYS_OPENAT        257
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60
%define SYS_GETUID        102
%define SYS_GETGID        104

; File descriptors
%define STDIN               0
%define STDOUT              1
%define STDERR              2

; Open flags
%define O_RDONLY            0
%define O_DIRECTORY     0x10000
%define AT_FDCWD           -100

; ioctl for terminal width
%define TIOCGWINSZ      0x5413

; Error numbers
%define EINTR               4
%define EPIPE              32
%define ENOENT              2
%define EACCES             13
%define ENOTDIR            20
%define ELOOP              40

; struct stat offsets (x86-64 Linux)
%define STAT_DEV            0       ; st_dev
%define STAT_INO            8       ; st_ino
%define STAT_NLINK         16       ; st_nlink
%define STAT_MODE          24       ; st_mode
%define STAT_UID           28       ; st_uid
%define STAT_GID           32       ; st_gid
%define STAT_RDEV          40       ; st_rdev
%define STAT_SIZE          48       ; st_size
%define STAT_BLKSIZE       56       ; st_blksize
%define STAT_BLOCKS        64       ; st_blocks
%define STAT_ATIME         72       ; st_atime
%define STAT_MTIME         88       ; st_mtime
%define STAT_CTIME        104       ; st_ctime
%define STAT_STRUCT_SIZE  144       ; sizeof(struct stat)

; File type masks
%define S_IFMT          0o170000
%define S_IFDIR         0o040000
%define S_IFCHR         0o020000
%define S_IFBLK         0o060000
%define S_IFREG         0o100000
%define S_IFIFO         0o010000
%define S_IFLNK         0o120000
%define S_IFSOCK        0o140000

; Permission bits
%define S_IRUSR         0o400
%define S_IWUSR         0o200
%define S_IXUSR         0o100
%define S_IRGRP         0o040
%define S_IWGRP         0o020
%define S_IXGRP         0o010
%define S_IROTH         0o004
%define S_IWOTH         0o002
%define S_IXOTH         0o001
%define S_ISUID         0o4000
%define S_ISGID         0o2000
%define S_ISVTX         0o1000

; struct linux_dirent64
%define DIRENT_INO          0     ; d_ino (8 bytes)
%define DIRENT_OFF          8     ; d_off (8 bytes)
%define DIRENT_RECLEN      16     ; d_reclen (2 bytes)
%define DIRENT_TYPE        18     ; d_type (1 byte)
%define DIRENT_NAME        19     ; d_name (variable)

; d_type values
%define DT_UNKNOWN          0
%define DT_FIFO             1
%define DT_CHR              2
%define DT_DIR              4
%define DT_BLK              6
%define DT_REG              8
%define DT_LNK            10
%define DT_SOCK            12

; Buffer sizes
%define READ_BUF_SIZE   131072     ; 128KB read buffer
%define OUT_BUF_SIZE    262144     ; 256KB output buffer
%define FLUSH_THRESHOLD 131072     ; flush when output buffer >= 128KB
%define GETDENTS_SIZE    32768     ; 32KB for getdents64
%define PATH_MAX          4096
%define MAX_ENTRIES       8192     ; max dir entries we can sort
