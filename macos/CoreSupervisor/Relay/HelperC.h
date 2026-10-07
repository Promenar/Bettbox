#ifndef BETTBOX_HELPER_RELAY_H
#define BETTBOX_HELPER_RELAY_H
#include "Bridge.h"
#include <stddef.h>
#include <stdint.h>
typedef struct { int32_t fd; int16_t events; int16_t returned; } HRPoll;
enum { HR_READ=1, HR_WRITE=2, HR_HUP=4, HR_ERROR=8 };
int HRConfigure(int32_t fd);
int HRPollOnce(HRPoll *items, size_t count, int timeout_ms);
// -2表示暂不可用，-1表示失败，0表示EOF，其它为已完成字节数。
int64_t HRRead(int32_t fd, void *bytes, size_t count);
int64_t HRWrite(int32_t fd, const void *bytes, size_t count);
void HRIgnorePipeSignal(void);
#endif
