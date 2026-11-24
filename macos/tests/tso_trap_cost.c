/*
 * Times a system call that does nearly nothing, a million times, from x86-64 code:
 *
 *   tso_trap_cost.exe [calls, default 1000000]
 *
 * NtYieldExecution goes through ntdll's system call dispatcher into sched_yield and back. Under
 * FEX with hardware TSO switched per thread, each call also traps into the kernel twice, to
 * switch the thread off TSO before native code runs and on again before JIT code does (see
 * Module.S in FEX). Run once as it is and once with FEX_HARDWARE_TSO=0 (software TSO, no
 * switching): the difference is what the two traps cost. Also times a loop of plain x86 code
 * with memory writes, which is what hardware TSO makes faster, so that both sides of the trade
 * are seen. Prints, e.g.
 *   syscall: 1000000 calls, 412 ns each
 *   memory:  200000000 stores, 0.61 ns each
 *
 * Built for x86_64 with the mingw compiler.
 */
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <stdlib.h>

NTSTATUS WINAPI NtYieldExecution(void);

int main( int argc, char **argv )
{
    int calls = argc > 1 ? atoi( argv[1] ) : 1000000, i, round;
    static volatile unsigned int cells[4096];
    LARGE_INTEGER freq, a, b;
    unsigned int x = 1;

    QueryPerformanceFrequency( &freq );
    for (round = 0; round < 3; round++)
    {
        QueryPerformanceCounter( &a );
        for (i = 0; i < calls; i++) NtYieldExecution();
        QueryPerformanceCounter( &b );
        printf( "syscall: %d calls, %.0f ns each\n", calls, (b.QuadPart - a.QuadPart) * 1e9 / freq.QuadPart / calls );
    }
    QueryPerformanceCounter( &a );
    for (i = 0; i < 200000000; i++) { x = x * 1664525u + 1013904223u; cells[x >> 20] += x; }
    QueryPerformanceCounter( &b );
    printf( "memory:  200000000 stores, %.2f ns each\n", (b.QuadPart - a.QuadPart) * 1e9 / freq.QuadPart / 200000000 );
    return 0;
}
