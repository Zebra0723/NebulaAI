// Counts heap allocations made by the calling thread between begin and end,
// so a test can prove the per-frame path never allocates. Linux only (glibc):
// on other platforms `nebula_alloc_supported` returns 0.
#pragma once

int nebula_alloc_supported(void);
void nebula_alloc_begin(void);
/// Allocations made on this thread since `nebula_alloc_begin`.
long nebula_alloc_end(void);
/// Prints where the first counted allocation came from, to stderr.
void nebula_alloc_print_trace(void);
