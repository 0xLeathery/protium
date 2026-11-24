/*
 * Times bulk work done by native code that x86 code calls without a system call in between:
 *
 *   native_tso.exe
 *
 * ntdll's memory move, fill and CRC-32 are native ARM64EC code under FEX. A thread that runs
 * translated code with hardware TSO keeps it while such a call runs, so this shows what native
 * code loses under TSO: compare a run as it is with one under FEX_HARDWARE_TSO=0, where native
 * code never runs under TSO. On 2026-11-24: fill 4.1 ms against 2.2 ms, move 5.5 against 4.5,
 * CRC-32 (reads only) the same.
 *
 * Prints one line per measurement, the best of five rounds. Built for x86_64.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
ULONG WINAPI RtlComputeCrc32( ULONG, const BYTE *, ULONG );
static LARGE_INTEGER freq;
static double now(void) { LARGE_INTEGER t; QueryPerformanceCounter( &t ); return t.QuadPart * 1e3 / freq.QuadPart; }
int main(void)
{
    SIZE_T size = 64 << 20; char *a = VirtualAlloc( 0, size, MEM_COMMIT, PAGE_READWRITE ), *b = VirtualAlloc( 0, size, MEM_COMMIT, PAGE_READWRITE );
    HMODULE nt = GetModuleHandleA( "ntdll" );
    void (WINAPI *move)( void *, const void *, SIZE_T ) = (void *)GetProcAddress( nt, "RtlMoveMemory" );
    void (WINAPI *fill)( void *, SIZE_T, BYTE ) = (void *)GetProcAddress( nt, "RtlFillMemory" );
    volatile ULONG s = 0; double t, best;
    QueryPerformanceFrequency( &freq ); memset( a, 1, size ); memset( b, 2, size );
    best = 1e9; for (int r = 0; r < 5; r++) { t = now(); for (int i = 0; i < 4; i++) move( a, b, size ); t = now() - t; if (t < best) best = t; } printf( "move 4x64MB   %.1f ms\n", best );
    best = 1e9; for (int r = 0; r < 5; r++) { t = now(); for (int i = 0; i < 20000; i++) move( a + (i & 1023) * 4096, b, 16384 ); t = now() - t; if (t < best) best = t; } printf( "move 20000x16K %.1f ms\n", best );
    best = 1e9; for (int r = 0; r < 5; r++) { t = now(); for (int i = 0; i < 4; i++) fill( a, size, i ); t = now() - t; if (t < best) best = t; } printf( "fill 4x64MB   %.1f ms\n", best );
    best = 1e9; for (int r = 0; r < 5; r++) { t = now(); s += RtlComputeCrc32( 0, (BYTE *)a, size ); t = now() - t; if (t < best) best = t; } printf( "crc32 64MB    %.1f ms\n", best );
    return 0;
}
