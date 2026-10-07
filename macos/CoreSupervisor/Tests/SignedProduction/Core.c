#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
/* 公开framed Core，仅固定HELLO/ACK与单action/result；无配置、网络或Mihomo代码。 */
static int all(int fd, void *buffer, size_t count, int writing) {
    unsigned char *p = buffer;
    while (count) { ssize_t n = writing ? write(fd, p, count) : read(fd, p, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 1;
        p += n; count -= (size_t)n;
    } return 0;
}
static int expect(const char *text) {
    unsigned char header[4], body[4096];
    if (all(0, header, 4, 0)) return 1;
    uint32_t n = (uint32_t)header[0] | (uint32_t)header[1]<<8 | (uint32_t)header[2]<<16 | (uint32_t)header[3]<<24;
    if (!n || n > sizeof(body) || n != strlen(text) || all(0, body, n, 0)) return 1;
    return memcmp(body, text, n) != 0;
}
static int emit(const char *text) {
    uint32_t n = (uint32_t)strlen(text);
    unsigned char header[4] = {(unsigned char)n, (unsigned char)(n>>8), (unsigned char)(n>>16), (unsigned char)(n>>24)};
    return all(1, header, 4, 1) || all(1, (void *)text, n, 1);
}
int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--owned-pipe-v1")) return 65;
    for (int fd = 0; fd <= 1; ++fd) {
        int flags = fcntl(fd, F_GETFD);
        if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) || !(fcntl(fd, F_GETFD) & FD_CLOEXEC)) return 66;
    }
    if (expect("{\"type\":\"hello\",\"protocol\":1,\"generation\":1}")) return 67;
    if (emit("{\"type\":\"ack\",\"protocol\":1,\"generation\":1}")) return 68;
    if (expect("{\"protocol\":1,\"generation\":1,\"action\":{\"id\":\"fixture\",\"method\":\"public_fixture\",\"data\":null}}")) return 69;
    if (emit("{\"protocol\":1,\"generation\":1,\"result\":{\"id\":\"fixture\",\"data\":\"ok\"}}")) return 70;
    unsigned char byte;
    for (;;) { ssize_t n = read(0, &byte, 1); if (!n) return 0;
        if (n < 0 && errno == EINTR) continue;
        return 71;
    }
}
