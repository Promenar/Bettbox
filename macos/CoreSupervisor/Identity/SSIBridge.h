#ifndef BETTBOX_SUPERVISOR_IDENTITY_BRIDGE_H
#define BETTBOX_SUPERVISOR_IDENTITY_BRIDGE_H
#include <stdint.h>
#include <Security/CSCommon.h>
#include <libproc.h>
#include <sys/param.h>
#include <sys/proc_info.h>
#include <sys/proc.h>

// 由当前公开SDK计算，避免Swift importer无法导入枚举成员或表达式宏。
static inline uint32_t SSIAdhocSignatureMask(void) {
    return (uint32_t)kSecCodeSignatureAdhoc;
}
static inline uint32_t SSIPIDPathBufferCapacity(void) {
    return (uint32_t)PROC_PIDPATHINFO_MAXSIZE;
}
#endif
