/* Linux-only fault injection for synthetic, temporary SQLite qualification stores.
 * Intercept only pwrite calls to the exact selected database or its SQLite sidecars,
 * and only while the Swift probe explicitly enables the switch after initialization.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#if !defined(__linux__) || (!defined(__x86_64__) && !defined(__aarch64__))
#error "This qualification interceptor requires 64-bit Linux pwrite64 syscall semantics."
#endif

static int should_fail(int descriptor) {
    const char *enabled = getenv("PECHPECH_PROBE_ENOSPC");
    const char *database = getenv("PECHPECH_PROBE_DB");
    if (enabled == NULL || strcmp(enabled, "1") != 0 || database == NULL || database[0] == '\0') {
        return 0;
    }
    char descriptor_path[64];
    char actual_path[4096];
    int length = snprintf(descriptor_path, sizeof(descriptor_path), "/proc/self/fd/%d", descriptor);
    if (length < 0 || (size_t)length >= sizeof(descriptor_path)) {
        return 0;
    }
    ssize_t actual_length = readlink(descriptor_path, actual_path, sizeof(actual_path) - 1);
    if (actual_length < 0 || (size_t)actual_length >= sizeof(actual_path) - 1) {
        return 0;
    }
    actual_path[actual_length] = '\0';
    size_t database_length = strlen(database);
    if (strncmp(actual_path, database, database_length) != 0) {
        return 0;
    }
    const char *suffix = actual_path + database_length;
    if (strcmp(suffix, "") != 0 && strcmp(suffix, "-wal") != 0 &&
        strcmp(suffix, "-shm") != 0 && strcmp(suffix, "-journal") != 0) {
        return 0;
    }
    const char *marker = getenv("PECHPECH_PROBE_FAULT_MARKER");
    if (marker != NULL && marker[0] != '\0') {
        int marker_fd = open(marker, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
        if (marker_fd >= 0) {
            const char record[] = "ENOSPC\n";
            (void)syscall(SYS_write, marker_fd, record, sizeof(record) - 1);
            (void)close(marker_fd);
        }
    }
    return 1;
}

ssize_t pwrite(int descriptor, const void *buffer, size_t count, off_t offset) {
    if (should_fail(descriptor)) {
        errno = ENOSPC;
        return -1;
    }
    return syscall(SYS_pwrite64, descriptor, buffer, count, offset);
}

ssize_t pwrite64(int descriptor, const void *buffer, size_t count, off64_t offset) {
    if (should_fail(descriptor)) {
        errno = ENOSPC;
        return -1;
    }
    return syscall(SYS_pwrite64, descriptor, buffer, count, offset);
}
