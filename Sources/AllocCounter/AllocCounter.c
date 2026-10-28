#include "AllocCounter.h"
#include <stddef.h>
#include <stdlib.h>

#if defined(__linux__) && defined(__GLIBC__)
#include <stddef.h>

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void *__libc_memalign(size_t, size_t);
extern void __libc_free(void *);

#include <execinfo.h>
#include <unistd.h>

static __thread int counting = 0;
static __thread long count = 0;
static __thread void *trace[48];
static __thread int traceDepth = 0;

static void note(void) {
    if (!counting) return;
    count++;
    if (count == 1) {
        counting = 0; // backtrace() must not count itself
        traceDepth = backtrace(trace, 48);
        counting = 1;
    }
}

void *malloc(size_t n) {
    note();
    return __libc_malloc(n);
}

void *calloc(size_t a, size_t b) {
    note();
    return __libc_calloc(a, b);
}

void *realloc(void *p, size_t n) {
    note();
    return __libc_realloc(p, n);
}

void *memalign(size_t align, size_t n) {
    note();
    return __libc_memalign(align, n);
}

void *aligned_alloc(size_t align, size_t n) {
    note();
    return __libc_memalign(align, n);
}

int posix_memalign(void **out, size_t align, size_t n) {
    note();
    void *p = __libc_memalign(align, n);
    if (!p) return 12; // ENOMEM
    *out = p;
    return 0;
}

void free(void *p) { __libc_free(p); }

int nebula_alloc_supported(void) { return 1; }
void nebula_alloc_begin(void) {
    static __thread int warmed = 0;
    if (!warmed) { void *b[2]; backtrace(b, 2); warmed = 1; }
    count = 0;
    traceDepth = 0;
    counting = 1;
}
void nebula_alloc_print_trace(void) { if (traceDepth) backtrace_symbols_fd(trace, traceDepth, 2); }
long nebula_alloc_end(void) { counting = 0; return count; }

#else

int nebula_alloc_supported(void) { return 0; }
void nebula_alloc_print_trace(void) {}
void nebula_alloc_begin(void) {}
long nebula_alloc_end(void) { return 0; }

#endif
