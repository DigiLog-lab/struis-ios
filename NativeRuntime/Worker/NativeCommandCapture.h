#ifndef STRUIS_NATIVE_COMMAND_CAPTURE_H
#define STRUIS_NATIVE_COMMAND_CAPTURE_H
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef STRUIS_COMMAND_CAPTURE_READ
#define STRUIS_COMMAND_CAPTURE_READ read
#endif

/* The trusted owner publishes finished only after flushing and closing its
 * writers. Observe that publication BEFORE read: an empty read followed by a
 * newly published finish does not prove the pipe is empty anymore. */
static inline int StruisCaptureCommandOutput(int reader, const atomic_bool *finished,
        unsigned char *suffix, size_t capacity, size_t *length, bool *truncated) {
    if (!finished || !suffix || !capacity || !length || !truncated) return EINVAL;
    *length = 0;
    *truncated = false;
    unsigned char buffer[8192];
    for (;;) {
        bool completedBeforeRead = atomic_load_explicit(finished, memory_order_acquire);
        ssize_t count = STRUIS_COMMAND_CAPTURE_READ(reader, buffer, sizeof(buffer));
        if (count == 0) return 0;
        if (count < 0) {
            int error = errno;
            if (error == EINTR) continue;
            if (error != EAGAIN && error != EWOULDBLOCK) return error;
            if (completedBeforeRead) return 0;
            struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000 };
            while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
            continue;
        }
        size_t incoming = (size_t)count;
        if (incoming >= capacity) {
            if (*length || incoming > capacity) *truncated = true;
            memcpy(suffix, buffer + incoming - capacity, capacity);
            *length = capacity;
        } else {
            if (*length > capacity - incoming) {
                size_t discard = *length - (capacity - incoming);
                memmove(suffix, suffix + discard, *length - discard);
                *length -= discard;
                *truncated = true;
            }
            memcpy(suffix + *length, buffer, incoming);
            *length += incoming;
        }
    }
}
#endif
