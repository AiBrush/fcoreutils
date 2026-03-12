; Linux x86_64 syscall numbers
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_STAT        4
%define SYS_FSTAT       5
%define SYS_FORK       57
%define SYS_EXECVE     59
%define SYS_EXIT       60
%define SYS_WAIT4      61
%define SYS_KILL       62
%define SYS_NANOSLEEP  35
%define SYS_ALARM      37
%define SYS_GETPID     39
%define SYS_SETPGID    109
%define SYS_GETPGID    121
%define SYS_RT_SIGACTION 13
%define SYS_RT_SIGPROCMASK 14
%define SYS_CLOCK_GETTIME 228
%define SYS_EXIT_GROUP 231

; Signal numbers
%define SIGALRM         14
%define SIGTERM         15
%define SIGKILL          9
%define SIGCHLD         17
%define SIGINT           2
%define SIGHUP           1

; Signal action flags
%define SA_RESTART      0x10000000
%define SA_RESTORER     0x04000000
%define SA_SIGINFO      0x00000004

; Wait flags
%define WNOHANG         1
%define WUNTRACED       2

; File descriptors
%define STDIN           0
%define STDOUT          1
%define STDERR          2

; Buffer sizes
%define BUF_SIZE    65536
%define ARG_BUF      4096
%define PATH_MAX     4096
