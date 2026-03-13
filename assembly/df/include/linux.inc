; linux.inc — Linux x86-64 syscall numbers and constants for fdf

%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_STAT            4
%define SYS_STATFS        137
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60

; File descriptors
%define STDIN               0
%define STDOUT              1
%define STDERR              2

; Open flags
%define O_RDONLY            0

; Error numbers
%define EINTR               4
%define EPIPE              32

; struct statfs offsets (x86-64 Linux)
; struct statfs {
;   __fsword_t f_type;     /* 0: type of filesystem */
;   __fsword_t f_bsize;    /* 8: optimal transfer block size */
;   fsblkcnt_t f_blocks;   /* 16: total data blocks */
;   fsblkcnt_t f_bfree;    /* 24: free blocks */
;   fsblkcnt_t f_bavail;   /* 32: free blocks for unprivileged */
;   fsfilcnt_t f_files;    /* 40: total file nodes */
;   fsfilcnt_t f_ffree;    /* 48: free file nodes */
;   __kernel_fsid_t f_fsid; /* 56: filesystem id */
;   __fsword_t f_namelen;  /* 64: max length of filenames */
;   __fsword_t f_frsize;   /* 72: fragment size */
;   __fsword_t f_flags;    /* 80: mount flags */
;   __fsword_t f_spare[4]; /* 88: padding */
; };
%define STATFS_TYPE         0
%define STATFS_BSIZE        8
%define STATFS_BLOCKS      16
%define STATFS_BFREE       24
%define STATFS_BAVAIL      32
%define STATFS_FILES       40
%define STATFS_FFREE       48
%define STATFS_NAMELEN     64
%define STATFS_FRSIZE      72
%define STATFS_STRUCT_SIZE 120

; Buffer sizes
%define OUT_BUF_SIZE    262144
%define FLUSH_THRESHOLD 131072
%define READ_BUF_SIZE    65536
%define PATH_MAX          4096
%define MAX_MOUNTS        256
%define MOUNT_LINE_MAX   1024
