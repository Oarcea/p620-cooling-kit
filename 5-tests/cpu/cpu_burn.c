// All-core AVX2/FMA power load for the Threadripper PRO 3975WX.
// Build: gcc -O2 -mavx2 -mfma -fopenmp cpu_burn.c -o cpu_burn
// Run:   ./cpu_burn <seconds> [threads]   (default: all logical CPUs)
#include <immintrin.h>
#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
    double secs = argc > 1 ? atof(argv[1]) : 60;
    if (argc > 2) omp_set_num_threads(atoi(argv[2]));
    double end = now() + secs, sink = 0;
    long long total = 0;
#pragma omp parallel reduction(+:sink, total)
    {
        int id = omp_get_thread_num();
        __m256 a[10];
        for (int i = 0; i < 10; i++) a[i] = _mm256_set1_ps(1.0f + 0.001f * (i + id));
        const __m256 m = _mm256_set1_ps(0.99999f), c = _mm256_set1_ps(1e-5f);
        long long n = 0;
        while (now() < end) {
            for (int k = 0; k < 1000000; k++) {          // 10 independent FMA chains
                for (int i = 0; i < 10; i++) a[i] = _mm256_fmadd_ps(a[i], m, c);
            }
            n++;
        }
        float tmp[8];
        for (int i = 0; i < 10; i++) { _mm256_storeu_ps(tmp, a[i]); sink += tmp[0]; }
        total += n;
    }
    // 1e6 iterations x 10 FMAs x 8 lanes x 2 flop
    printf("threads=%d  %.1f GFLOPS  (sink %.3f)\n", omp_get_max_threads(),
           total * 1e6 * 10 * 8 * 2 / secs / 1e9, sink);
    return 0;
}
