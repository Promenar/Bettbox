// 公开子进程验证内核不存在分类；不读取其它进程或客户端数据。
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <spawn.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
int main(void) {
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof(info));
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 1;
    pid_t child = 0;
    char *argv[] = { "/usr/bin/true", NULL };
    char *env[] = { "PATH=/usr/bin:/bin", NULL };
    if (posix_spawn(&child, argv[0], NULL, NULL, argv, env) != 0) return 2;
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 3;
    errno = 0;
    int count = proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (count != 0 || errno != ESRCH) return 4;
    puts("KERNEL_REAPED_ABSENT_OK");
    return 0;
}
