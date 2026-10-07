#include "HelperC.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
int HRConfigure(int32_t fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ? -1 : 0;
}
void HRIgnorePipeSignal(void) { signal(SIGPIPE, SIG_IGN); }
int HRPollOnce(HRPoll *items, size_t count, int timeout_ms) {
    if (count > 4 || timeout_ms < 0 || timeout_ms > 20) return -1;
    struct pollfd native[4];
    for (size_t i=0;i<count;i++) {
        native[i].fd=items[i].fd; native[i].events=0; native[i].revents=0;
        if (items[i].events & HR_READ) native[i].events |= POLLIN;
        if (items[i].events & HR_WRITE) native[i].events |= POLLOUT;
        items[i].returned=0;
    }
    int result=poll(native,(nfds_t)count,timeout_ms);
    if (result < 0) return errno == EINTR ? 0 : -1;
    for (size_t i=0;i<count;i++) {
        short value=native[i].revents;
        if (value & POLLIN) items[i].returned |= HR_READ;
        if (value & POLLOUT) items[i].returned |= HR_WRITE;
        if (value & POLLHUP) items[i].returned |= HR_HUP;
        if (value & (POLLERR|POLLNVAL)) items[i].returned |= HR_ERROR;
    }
    return result;
}
int64_t HRRead(int32_t fd, void *bytes, size_t count) {
    ssize_t result=read(fd,bytes,count);
    return result < 0 ? ((errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR) ? -2 : -1) : result;
}
int64_t HRWrite(int32_t fd, const void *bytes, size_t count) {
    ssize_t result=write(fd,bytes,count);
    return result < 0 ? ((errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR) ? -2 : -1) : result;
}
