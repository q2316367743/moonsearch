#pragma once

/* memrchr() is a GNU extension.  macOS does not provide it, so the benchmark
 * build force-includes this shim on Darwin. */

#include <stddef.h>
#include <string.h>
#include <sys/types.h>

#if defined(__APPLE__)
/* Linux exposes off64_t; on macOS off_t is already 64-bit. */
typedef off_t off64_t;
#endif

#if defined(__APPLE__) && !defined(HAVE_MEMRCHR)
static inline void *
memrchr(const void *s, int c, size_t n) {
    const unsigned char *p = (const unsigned char *)s;
    const unsigned char needle = (unsigned char)c;
    while (n > 0) {
        --n;
        if (p[n] == needle) {
            return (void *)(p + n);
        }
    }
    return NULL;
}
#endif
