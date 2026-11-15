/* x86_64 test program: a lot of code that runs once, so that an emulator's JIT keeps
 * compiling. FUNCS distinct functions are called in turn, ROUNDS times; the first round is
 * all compilation, the later ones run what is already compiled.
 *
 *   jit_x64.exe [rounds]      prints a checksum and the time of the first and of the later rounds
 */
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>  /* built natively for the expected checksum */
#endif

#define F(n) __attribute__((noinline)) static unsigned f##n( unsigned x ) \
    { x ^= n * 2654435761u; x = (x << 7) | (x >> 25); x += n; return x * 31 + (x >> 3); }
#define F10(n) F(n##0) F(n##1) F(n##2) F(n##3) F(n##4) F(n##5) F(n##6) F(n##7) F(n##8) F(n##9)
#define F100(n) F10(n##0) F10(n##1) F10(n##2) F10(n##3) F10(n##4) F10(n##5) F10(n##6) F10(n##7) F10(n##8) F10(n##9)
#define F1000(n) F100(n##0) F100(n##1) F100(n##2) F100(n##3) F100(n##4) F100(n##5) F100(n##6) F100(n##7) F100(n##8) F100(n##9)
F1000(1) F1000(2) F1000(3) F1000(4)

#define P(n) f##n,
#define P10(n) P(n##0) P(n##1) P(n##2) P(n##3) P(n##4) P(n##5) P(n##6) P(n##7) P(n##8) P(n##9)
#define P100(n) P10(n##0) P10(n##1) P10(n##2) P10(n##3) P10(n##4) P10(n##5) P10(n##6) P10(n##7) P10(n##8) P10(n##9)
#define P1000(n) P100(n##0) P100(n##1) P100(n##2) P100(n##3) P100(n##4) P100(n##5) P100(n##6) P100(n##7) P100(n##8) P100(n##9)
static unsigned (*volatile funcs[])( unsigned ) = { P1000(1) P1000(2) P1000(3) P1000(4) };
#define FUNCS (sizeof(funcs) / sizeof(funcs[0]))

static double now(void)
{
#ifdef _WIN32
    LARGE_INTEGER t, f;
    QueryPerformanceCounter( &t );
    QueryPerformanceFrequency( &f );
    return (double)t.QuadPart / f.QuadPart;
#else
    struct timespec t;
    clock_gettime( CLOCK_MONOTONIC, &t );
    return t.tv_sec + t.tv_nsec / 1e9;
#endif
}

int main( int argc, char **argv )
{
    int rounds = argc > 1 ? atoi( argv[1] ) : 20, r;
    unsigned sum = 1;
    double t0, t1, t2;
    size_t i;

    t0 = now();
    for (i = 0; i < FUNCS; i++) sum = funcs[i]( sum );
    t1 = now();
    for (r = 1; r < rounds; r++) for (i = 0; i < FUNCS; i++) sum = funcs[i]( sum );
    t2 = now();
    printf( "jit: %u functions, checksum %08x, first round %.1f ms, %d later rounds %.2f ms each\n",
            (unsigned)FUNCS, sum, (t1 - t0) * 1e3, rounds - 1, rounds > 1 ? (t2 - t1) * 1e3 / (rounds - 1) : 0.0 );
    return 0;
}
