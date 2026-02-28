# Linux x86_64 syscall numbers (GAS syntax)
.equ SYS_READ,       0
.equ SYS_WRITE,      1
.equ SYS_OPEN,       2
.equ SYS_CLOSE,      3
.equ SYS_STAT,       4
.equ SYS_FSTAT,      5
.equ SYS_EXIT,      60
.equ SYS_NANOSLEEP, 35
.equ SYS_GETCWD,    79
.equ SYS_GETUID,   102
.equ SYS_GETEUID,  107
.equ SYS_UNAME,     63
.equ SYS_SYNC,     162

# File descriptors
.equ STDIN,          0
.equ STDOUT,         1
.equ STDERR,         2

# Buffer sizes
.equ BUF_SIZE,   65536
.equ ARG_BUF,     4096
.equ PATH_MAX,    4096

# utsname struct field size (65 bytes each on Linux x86_64)
.equ UTSNAME_FIELD_LEN, 65
# Offsets within struct utsname
.equ UTS_SYSNAME,   0
.equ UTS_NODENAME,  65
.equ UTS_RELEASE,   130
.equ UTS_VERSION,   195
.equ UTS_MACHINE,   260
.equ UTS_DOMAINNAME,325
.equ UTSNAME_SIZE,  390
