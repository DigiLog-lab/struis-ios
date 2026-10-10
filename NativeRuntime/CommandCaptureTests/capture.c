#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>

static atomic_bool finished;
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int writerFD;
static bool raceEnabled;
static bool emptyObserved;
static bool writerCompleted;
static ssize_t controlled_read(int fd, void *buffer, size_t count) {
    ssize_t result = read(fd, buffer, count);
    int saved = errno;
    if (result < 0 && saved == EAGAIN && raceEnabled) {
        assert(pthread_mutex_lock(&gate) == 0);
        emptyObserved = true;
        assert(pthread_cond_broadcast(&changed) == 0);
        while (!writerCompleted) assert(pthread_cond_wait(&changed, &gate) == 0);
        assert(pthread_mutex_unlock(&gate) == 0);
        raceEnabled = false;
    }
    errno = saved;
    return result;
}
#define STRUIS_COMMAND_CAPTURE_READ controlled_read
#include "../Worker/NativeCommandCapture.h"

static const unsigned char marker[] = "NATIVE_PYTHON_THREAD_OK\n";
static void *late_writer(void *unused) {
    (void)unused;
    assert(pthread_mutex_lock(&gate) == 0);
    while (!emptyObserved) assert(pthread_cond_wait(&changed, &gate) == 0);
    assert(write(writerFD, marker, sizeof(marker) - 1) == (ssize_t)sizeof(marker) - 1);
    assert(close(writerFD) == 0);
    atomic_store_explicit(&finished, true, memory_order_release);
    writerCompleted = true;
    assert(pthread_cond_broadcast(&changed) == 0);
    assert(pthread_mutex_unlock(&gate) == 0);
    return NULL;
}

static void pipe_pair(int descriptors[2]) {
    assert(pipe(descriptors) == 0);
    int flags = fcntl(descriptors[0], F_GETFL);
    assert(flags >= 0 && fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) == 0);
}

static void finish_race(void) {
    int descriptors[2];
    pipe_pair(descriptors);
    writerFD = descriptors[1];
    raceEnabled = true;
    emptyObserved = writerCompleted = false;
    atomic_init(&finished, false);
    pthread_t writer;
    assert(pthread_create(&writer, NULL, late_writer, NULL) == 0);
    unsigned char output[128];
    size_t length = 0;
    bool truncated = false;
    assert(StruisCaptureCommandOutput(descriptors[0], &finished, output, sizeof(output), &length, &truncated) == 0);
    assert(pthread_join(writer, NULL) == 0);
    assert(length == sizeof(marker) - 1 && !truncated);
    assert(memcmp(output, marker, length) == 0);
    assert(close(descriptors[0]) == 0);
    puts("PASS real empty-read -> writer-close/finish race retains complete marker");
}

static unsigned char payload[262145];
static void *large_writer(void *argument) {
    int fd = *(int *)argument;
    size_t offset = 0;
    while (offset < sizeof(payload)) {
        ssize_t count = write(fd, payload + offset, sizeof(payload) - offset);
        if (count < 0 && errno == EINTR) continue;
        assert(count > 0);
        offset += (size_t)count;
    }
    assert(close(fd) == 0);
    atomic_store_explicit(&finished, true, memory_order_release);
    return NULL;
}

static void bounded_suffix(void) {
    int descriptors[2];
    pipe_pair(descriptors);
    for (size_t index = 0; index < sizeof(payload); index++) payload[index] = (unsigned char)(index % 251);
    atomic_init(&finished, false);
    pthread_t writer;
    assert(pthread_create(&writer, NULL, large_writer, &descriptors[1]) == 0);
    unsigned char suffix[96000];
    size_t length = 0;
    bool truncated = false;
    assert(StruisCaptureCommandOutput(descriptors[0], &finished, suffix, sizeof(suffix), &length, &truncated) == 0);
    assert(pthread_join(writer, NULL) == 0);
    assert(length == sizeof(suffix) && truncated);
    assert(memcmp(suffix, payload + sizeof(payload) - sizeof(suffix), sizeof(suffix)) == 0);
    assert(close(descriptors[0]) == 0);
    puts("PASS real capacity-exceeding binary pipe retains exact bounded suffix");
}

static void inherited_writer(void) {
    int descriptors[2];
    pipe_pair(descriptors);
    atomic_init(&finished, true);
    unsigned char output[8];
    size_t length = 1;
    bool truncated = true;
    /* Owner completion permits a bounded exit even if a duplicate writer remains. */
    assert(StruisCaptureCommandOutput(descriptors[0], &finished, output, sizeof(output), &length, &truncated) == 0);
    assert(length == 0 && !truncated);
    assert(close(descriptors[0]) == 0 && close(descriptors[1]) == 0);
    puts("PASS published completion terminates empty pipe without requiring EOF");
}

static void small_suffix(void) {
    int descriptors[2];
    pipe_pair(descriptors);
    assert(write(descriptors[1], payload, 256) == 256);
    assert(close(descriptors[1]) == 0);
    atomic_init(&finished, true);
    unsigned char suffix[7];
    size_t length = 0;
    bool truncated = false;
    assert(StruisCaptureCommandOutput(descriptors[0], &finished, suffix, sizeof(suffix), &length, &truncated) == 0);
    assert(length == sizeof(suffix) && truncated);
    assert(memcmp(suffix, payload + 256 - sizeof(suffix), sizeof(suffix)) == 0);
    assert(close(descriptors[0]) == 0);
    puts("PASS binary read larger than suffix capacity retains exact tail");
}

static void read_failure(void) {
    atomic_init(&finished, false);
    unsigned char output[8];
    size_t length = 0;
    bool truncated = false;
    assert(StruisCaptureCommandOutput(-1, &finished, output, sizeof(output), &length, &truncated) == EBADF);
    assert(length == 0 && !truncated);
    puts("PASS actual read failure returns errno instead of successful capture");
}

int main(void) {
    finish_race();
    bounded_suffix();
    inherited_writer();
    small_suffix();
    read_failure();
    return 0;
}
