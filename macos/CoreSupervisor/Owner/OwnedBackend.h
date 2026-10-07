#ifndef OWNED_BACKEND_H
#define OWNED_BACKEND_H
#include <stdint.h>
#include <sys/types.h>
typedef enum { OC_OK=0, OC_INVALID=1, OC_SPAWN=2, OC_WAIT=3, OC_KERNEL=4, OC_SIGNAL=5, OC_REAP=6 } OCError;
typedef struct { pid_t pid; int input_writer; int output_reader; } OCChild;
typedef struct { pid_t pid, ppid, pgid; uid_t uid, ruid; uint64_t seconds, micros; int zombie; } OCStamp;
typedef struct { int state; pid_t pid; int normal; int code; } OCObservation;
/* 私有模块ABI：路径只能来自sealed身份模块的内部产物，不是外部输入。 */
OCError OCSpawnSealed(const char *path, OCChild *child);
#ifdef OWNED_PUBLIC_FIXTURE
OCError OCSpawnPublicFixture(int fixture, OCChild *child);
#endif
OCObservation OCObserve(pid_t pid);
OCError OCReadStamp(pid_t pid, OCStamp *stamp);
OCError OCSignal(pid_t pid, int group, int signal_number);
OCError OCReap(pid_t pid, OCObservation expected);
void OCClose(int fd);
uint64_t OCMonotonicNanos(void);
pid_t OCSelfPID(void);
uid_t OCSelfUID(void);
uid_t OCSelfRealUID(void);
#endif
