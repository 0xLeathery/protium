/*
 * Times the same small pieces of work as native code and as x86 code through FEX:
 *
 *   cpu_tax.exe
 *
 * Built for aarch64, x86_64 and i686 by cpu-bench.sh, which prints the three side by side. The
 * first group is plain computing (integer, memory, floating point, calls, atomics, a small
 * memcpy), which shows what translation costs. The second calls into Windows DLLs, which are
 * native ARM64EC code under FEX, so it shows the cost of leaving and re-entering translated
 * code. The third makes system calls. On 2026-11-24 FEX switched a thread off hardware TSO
 * before every system call and on again after it, two kernel traps: QueryPerformanceCounter
 * took 220 ns from x86_64 code against 16 ns native and 21 ns with software TSO
 * (FEX_HARDWARE_TSO=0), a poll of an event 246 against 43 and 47.
 *
 * Prints one line per measurement, nanoseconds for one pass, the best of three rounds. It is a
 * measurement, not a check: nothing passes or fails.
 */
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

NTSTATUS WINAPI NtYieldExecution(void);
static LARGE_INTEGER freq;
static double now(void) { LARGE_INTEGER t; QueryPerformanceCounter( &t ); return t.QuadPart * 1e9 / freq.QuadPart; }
#define NOINLINE __attribute__((noinline))
#define BENCH(name, n, body) do { double best = 1e30; for (int r = 0; r < 3; r++) { double a = now(); body; double d = (now() - a) / (n); if (d < best) best = d; } printf( "%-14s %9.2f ns\n", name, best ); fflush( stdout ); } while (0)

static volatile unsigned int sink;
/* read for every round, or the compiler computes a loop without side effects once for all three */
static volatile int count_n = 50000000;
static unsigned int cells[1 << 16];
static double dcells[4096];
static float fa[4096], fb[4096], fc[4096];

NOINLINE static unsigned int int_loop( int n ) { unsigned int x = 1, h = 0; for (int i = 0; i < n; i++) { x = x * 1664525u + 1013904223u; h ^= (x >> 13) + (h << 5) + (x % 7); } return h; }
NOINLINE static unsigned int store_loop( int n ) { unsigned int x = 1; for (int i = 0; i < n; i++) { x = x * 1664525u + 1013904223u; cells[x >> 16] += x; } return cells[5]; }
NOINLINE static unsigned int load_loop( int n ) { unsigned int x = 1, s = 0; for (int i = 0; i < n; i++) { x = x * 1664525u + 1013904223u; s += cells[x >> 16]; } return s; }
NOINLINE static double fp_loop( int n ) { double s = 0.5; for (int i = 0; i < n; i++) { s = s * 1.0000001 + dcells[i & 4095] / (s + 2.0); } return s; }
NOINLINE static double sqrt_loop( int n ) { double s = 0; for (int i = 0; i < n; i++) s += sqrt( (double)i + s ); return s; }
NOINLINE static float vec_loop( int n ) { float s = 0; for (int r = 0; r < n / 4096; r++) { for (int i = 0; i < 4096; i++) fc[i] = fa[i] * fb[i] + fc[i]; s += fc[r & 4095]; } return s; }
NOINLINE static int leaf( int a, int b ) { return a * 31 + b; }
static int (*volatile leaf_ptr)( int, int ) = leaf;
NOINLINE static int call_loop( int n ) { int s = 0; for (int i = 0; i < n; i++) s = leaf( s, i ); return s; }
NOINLINE static int icall_loop( int n ) { int s = 0; for (int i = 0; i < n; i++) s = leaf_ptr( s, i ); return s; }
NOINLINE static int sw( int v, int s ) { switch (v & 7) { case 0: return s + 1; case 1: return s ^ 3; case 2: return s * 3; case 3: return s - 7; case 4: return s + v; case 5: return s ^ v; case 6: return s << 1; default: return s >> 1; } }
NOINLINE static int branch_loop( int n ) { unsigned int x = 1; int s = 0; for (int i = 0; i < n; i++) { x = x * 1664525u + 1013904223u; s = sw( x >> 20, s ); } return s; }
NOINLINE static long atomic_loop( int n ) { static volatile LONG v; for (int i = 0; i < n; i++) InterlockedIncrement( &v ); return v; }
NOINLINE static long cas_loop( int n ) { static volatile LONG v; for (int i = 0; i < n; i++) InterlockedCompareExchange( &v, i + 1, i ); return v; }
NOINLINE static void copy_loop( int n ) { static char a[4096], b[4096]; for (int i = 0; i < n; i++) { memcpy( a, b, 256 + (i & 63) ); a[i & 255]++; } sink = a[3]; }

int main( int argc, char **argv )
{
    CRITICAL_SECTION cs; SRWLOCK srw = SRWLOCK_INIT; LARGE_INTEGER q; FILETIME ft; MEMORY_BASIC_INFORMATION mbi;
    HANDLE ev = CreateEventW( NULL, TRUE, FALSE, NULL ), heap = GetProcessHeap();
    int M = 2000000;
#define N count_n
    QueryPerformanceFrequency( &freq );
    InitializeCriticalSection( &cs );
    for (int i = 0; i < 4096; i++) { dcells[i] = i * 0.37; fa[i] = i * 0.5f; fb[i] = 1.0f / (i + 1); }

    BENCH( "int", N, sink = int_loop( N ) );
    BENCH( "store", N, sink = store_loop( N ) );
    BENCH( "load", N, sink = load_loop( N ) );
    BENCH( "fp", N, sink = (unsigned int)fp_loop( N ) );
    BENCH( "sqrt", N, sink = (unsigned int)sqrt_loop( N ) );
    BENCH( "vec4", N, sink = (unsigned int)vec_loop( N ) );
    BENCH( "call", N, sink = call_loop( N ) );
    BENCH( "icall", N, sink = icall_loop( N ) );
    BENCH( "branch", N, sink = branch_loop( N ) );
    BENCH( "atomic_inc", N, sink = atomic_loop( N ) );
    BENCH( "cas", N, sink = cas_loop( N ) );
    BENCH( "memcpy~288", N / 5, copy_loop( N / 5 ) );
    /* calls into Windows DLLs (native ARM64EC code under FEX) */
    BENCH( "GetLastError", M, for (int i = 0; i < M; i++) sink += GetLastError() );
    BENCH( "GetTickCount", M, for (int i = 0; i < M; i++) sink += GetTickCount() );
    BENCH( "QPC", M, for (int i = 0; i < M; i++) { QueryPerformanceCounter( &q ); sink += q.LowPart; } );
    BENCH( "critsec", M, for (int i = 0; i < M; i++) { EnterCriticalSection( &cs ); LeaveCriticalSection( &cs ); } );
    BENCH( "srwlock", M, for (int i = 0; i < M; i++) { AcquireSRWLockExclusive( &srw ); ReleaseSRWLockExclusive( &srw ); } );
    BENCH( "heap 64", M, for (int i = 0; i < M; i++) { void *p = HeapAlloc( heap, 0, 64 ); HeapFree( heap, 0, p ); } );
    BENCH( "TlsGetValue", M, for (int i = 0; i < M; i++) sink += (unsigned int)(ULONG_PTR)TlsGetValue( 1 ) );
    /* system calls */
    BENCH( "NtYield", M, for (int i = 0; i < M; i++) NtYieldExecution() );
    BENCH( "systime(ft)", M, for (int i = 0; i < M; i++) GetSystemTimeAsFileTime( &ft ) );
    BENCH( "wait ev 0", M, for (int i = 0; i < M; i++) WaitForSingleObject( ev, 0 ) );
    BENCH( "set+reset", M, for (int i = 0; i < M; i++) { SetEvent( ev ); ResetEvent( ev ); } );
    BENCH( "VirtualQuery", M / 4, for (int i = 0; i < M / 4; i++) VirtualQuery( &cs, &mbi, sizeof(mbi) ) );
    BENCH( "Sleep(0)", M / 4, for (int i = 0; i < M / 4; i++) Sleep( 0 ) );
    return 0;
}
