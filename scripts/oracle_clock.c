/* Developer-only SQL oracle clock. This is never linked into dxt. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static int fixed_epoch(time_t *epoch) {
    const char *text = getenv("DXT_ORACLE_EPOCH_SECONDS");
    if (text == NULL) return 0;
    char *end;
    errno = 0;
    long long value = strtoll(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < 0 ||
        (long long)(time_t)value != value) {
        static const char message[] = "invalid developer oracle wall clock\n";
        size_t offset = 0;
        while (offset < sizeof(message) - 1) {
            ssize_t count = write(STDERR_FILENO, message + offset,
                                  sizeof(message) - 1 - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            offset += (size_t)count;
        }
        _exit(125);
    }
    *epoch = (time_t)value;
    return 1;
}

static void *next_symbol(const char *name) {
    void *symbol = dlsym(RTLD_NEXT, name);
    if (symbol == NULL) _exit(125);
    return symbol;
}

int clock_gettime(clockid_t clock, struct timespec *value) {
    time_t epoch;
    if ((clock == CLOCK_REALTIME || clock == CLOCK_REALTIME_COARSE) && fixed_epoch(&epoch)) {
        value->tv_sec = epoch;
        value->tv_nsec = 0;
        return 0;
    }
    /* Deadlines, sleeps, performance counters and CPU clocks remain real. */
    int (*real_clock)(clockid_t, struct timespec *) = next_symbol("clock_gettime");
    return real_clock(clock, value);
}

int gettimeofday(struct timeval *value, void *zone) {
    time_t epoch;
    if (fixed_epoch(&epoch)) {
        if (zone != NULL) {
            int (*real_clock)(struct timeval *, void *) = next_symbol("gettimeofday");
            if (real_clock(value, zone) != 0) return -1;
        }
        value->tv_sec = epoch;
        value->tv_usec = 0;
        return 0;
    }
    int (*real_clock)(struct timeval *, void *) = next_symbol("gettimeofday");
    return real_clock(value, zone);
}

time_t time(time_t *value) {
    time_t epoch;
    if (fixed_epoch(&epoch)) {
        if (value != NULL) *value = epoch;
        return epoch;
    }
    time_t (*real_clock)(time_t *) = next_symbol("time");
    return real_clock(value);
}
