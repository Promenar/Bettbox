#include "OwnedBackend.h"
#include <spawn.h>
#include <sys/wait.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <libproc.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <time.h>
#include <errno.h>
static int owned_pipe(int pair[2]) {
    int raw[2];
    pair[0] = pair[1] = -1;
    if (pipe(raw) != 0) return -1;
    pair[0] = fcntl(raw[0], F_DUPFD_CLOEXEC, 3);
    pair[1] = fcntl(raw[1], F_DUPFD_CLOEXEC, 3);
    close(raw[0]); close(raw[1]);
    if (pair[0] < 0 || pair[1] < 0) {
        if (pair[0] >= 0) close(pair[0]);
        if (pair[1] >= 0) close(pair[1]);
        pair[0] = pair[1] = -1;
        return -1;
    }
    return 0;
}
static void close_pair(int pair[2]) {
    if (pair[0] >= 0) close(pair[0]);
    if (pair[1] >= 0) close(pair[1]);
}
static int spawn_fixed(const char *path, OCChild *result, int public_fixture) {
    if (!path || !result) return -1;
    result->pid = -1; result->input_writer = result->output_reader = -1;
    // 生产与公开fixture均显式创建独立child组。
    const pid_t group = 0;
    int input[2] = {-1, -1}, output[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int actions_ready = 0, attributes_ready = 0, status = -1;
    if (owned_pipe(input) != 0 || owned_pipe(output) != 0) goto finish;
    if (posix_spawn_file_actions_init(&actions) != 0) goto finish;
    actions_ready = 1;
    if (posix_spawnattr_init(&attributes) != 0) goto finish;
    attributes_ready = 1;
    // 组策略显式设置，不依赖Foundation；0按SDK合同创建新child组。
    if (posix_spawnattr_setpgroup(&attributes, group) != 0) goto finish;
    sigset_t empty, defaults;
    sigemptyset(&empty); sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT);
    if (posix_spawnattr_setsigmask(&attributes, &empty) != 0 ||
        posix_spawnattr_setsigdefault(&attributes, &defaults) != 0 ||
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                  POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF) != 0) goto finish;
    if (posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) != 0 ||
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) != 0 ||
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) != 0) goto finish;
    for (int i = 0; i < 2; ++i) {
        if (posix_spawn_file_actions_addclose(&actions, input[i]) != 0 ||
            posix_spawn_file_actions_addclose(&actions, output[i]) != 0) goto finish;
    }
    char *argv[] = {(char *)path, public_fixture == 1 ? "20" : (public_fixture == 0 ? NULL : "--owned-pipe-v1"), NULL};
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
    pid_t pid;
    if (posix_spawn(&pid, path, &actions, &attributes, argv, environment) != 0) goto finish;
    // 从这里起资源只移交一次；不得将已spawn子进程当作普通FD失败路径丢弃。
    result->pid = pid; result->input_writer = input[1]; result->output_reader = output[0];
    input[1] = output[0] = -1;
    status = 0;
finish:
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    close_pair(input); close_pair(output);
    return status;
}

OCError OCSpawnSealed(const char *path, OCChild *child) {
    if (!path || !child) return OC_INVALID;
    return spawn_fixed(path, child, -1) == 0 ? OC_OK : OC_SPAWN;
}
#ifdef OWNED_PUBLIC_FIXTURE
OCError OCSpawnPublicFixture(int fixture, OCChild *child) {
    /* 固定公开stub不读取路径/配置；sleep使用固定20秒参数。 */
    if (!child || (fixture != 0 && fixture != 1)) return OC_INVALID;
    return spawn_fixed(fixture == 0 ? "/usr/bin/true" : "/bin/sleep", child, fixture) == 0 ? OC_OK : OC_SPAWN;
}
#endif
OCObservation OCObserve(pid_t pid) {
    OCObservation result = {-1, pid, 0, 0};
    if (pid <= 0) return result;
    siginfo_t info; memset(&info, 0, sizeof(info));
    int rc;
    do { rc = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT); } while (rc != 0 && errno == EINTR);
    if (rc != 0) return result;
    if (!info.si_pid) { result.state = 0; return result; }
    if (info.si_pid != pid || (info.si_code != CLD_EXITED && info.si_code != CLD_KILLED && info.si_code != CLD_DUMPED)) return result;
    result.state = 1; result.normal = info.si_code == CLD_EXITED; result.code = info.si_status; return result;
}
OCError OCReadStamp(pid_t pid, OCStamp *stamp) {
    if (pid <= 0 || !stamp) return OC_INVALID;
    struct proc_bsdinfo info; memset(&info, 0, sizeof(info));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != (int)sizeof(info) ||
        info.pbi_pid != (uint32_t)pid || !info.pbi_start_tvsec || info.pbi_start_tvusec >= 1000000) return OC_KERNEL;
    *stamp = (OCStamp){(pid_t)info.pbi_pid, (pid_t)info.pbi_ppid, (pid_t)info.pbi_pgid,
        info.pbi_uid, info.pbi_ruid, info.pbi_start_tvsec, info.pbi_start_tvusec, info.pbi_status == SZOMB};
    return OC_OK;
}
OCError OCSignal(pid_t pid, int group, int number) {
    if (pid <= 0 || (number != SIGTERM && number != SIGKILL)) return OC_INVALID;
    return kill(group ? -pid : pid, number) == 0 ? OC_OK : OC_SIGNAL;
}
OCError OCReap(pid_t pid, OCObservation expected) {
    if (pid <= 0 || expected.state != 1 || expected.pid != pid) return OC_INVALID;
    int status = 0; pid_t rc;
    /* EINTR表示未完成，重试不增加成功reap次数；不得另调用wait(-1)。 */
    do { rc = waitpid(pid, &status, WNOHANG); } while (rc < 0 && errno == EINTR);
    if (rc != pid) return OC_REAP;
    if (expected.normal ? (!WIFEXITED(status) || WEXITSTATUS(status) != expected.code) :
        (!WIFSIGNALED(status) || WTERMSIG(status) != expected.code)) return OC_REAP;
    return OC_OK;
}
void OCClose(int fd) { if (fd >= 0) close(fd); }
uint64_t OCMonotonicNanos(void) { struct timespec t; if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0; return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec; }
pid_t OCSelfPID(void) { return getpid(); }
uid_t OCSelfUID(void) { return geteuid(); }
uid_t OCSelfRealUID(void) { return getuid(); }
