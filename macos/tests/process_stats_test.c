/*
 * Work of known amounts, to check Wine's per-process line (WINE_PROCESS_STATS, ntdll) against:
 *
 *   process_stats_test.exe [seconds to stay at the end, default 6]
 *
 * In order, each timed by the program itself:
 *   20000 registry reads (RegQueryValueExW: a wineserver call each),
 *   10000 SwitchToThread (NtYieldExecution),
 *   50 Sleep(20) (NtDelayExecution, not alertable),
 *   50 waits of 20 ms on an event that is never set (with fsync, a futex wait in shared memory),
 *   50 WaitOnAddress of 20 ms (NtWaitForAlertByThreadId),
 *   50 waits of 20 ms on the process itself (a wait the wineserver does: processes are not in fsync),
 *   2 x ncpu threads spinning for 2 s (time waiting for a core),
 *   256 MB allocated, touched and held to the end.
 * Then prints two lines:
 *   truth: registry 20000 <ms> ms, yields 10000 <ms> ms, sleeps 50 <ms> ms, event waits 50 <ms> ms,
 *          address waits 50 <ms> ms, process waits 50 <ms> ms, spin <threads> threads <s> s, memory 256 MB
 *   cost: registry read <ns> ns, yield <ns> ns   (best of 3 rounds, to compare runs with and without the line)
 * and stays the given seconds, so that a line falls after the work.
 *
 * Built for x86_64, i686 and aarch64 with llvm-mingw: -ladvapi32 -lsynchronization.
 *
 * Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.
 */
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static double frequency;

static LONGLONG counter(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter( &t );
    return t.QuadPart;
}

static double ms_since( LONGLONG start )
{
    return (counter() - start) * 1000.0 / frequency;
}

static volatile LONG stop;

static DWORD WINAPI spin( void *arg )
{
    while (!stop) {}
    return 0;
}

static double registry_reads( HKEY key, int count )
{
    WCHAR value[256];
    LONGLONG t0 = counter();
    int i;

    for (i = 0; i < count; i++)
    {
        DWORD size = sizeof(value);
        RegQueryValueExW( key, L"ProductName", NULL, NULL, (BYTE *)value, &size );
    }
    return ms_since( t0 );
}

static double yields( int count )
{
    LONGLONG t0 = counter();
    int i;

    for (i = 0; i < count; i++) SwitchToThread();
    return ms_since( t0 );
}

int main( int argc, char **argv )
{
    double reg_ms, yield_ms, sleep_ms, event_ms, address_ms, process_ms, spin_s, best_reg = 1e30, best_yield = 1e30;
    int stay = argc > 1 ? atoi( argv[1] ) : 6, threads, i;
    LONG address = 0, same = 0;
    HANDLE event, *spinners;
    SYSTEM_INFO info;
    LARGE_INTEGER f;
    LONGLONG t0;
    HKEY key;
    char *memory;

    QueryPerformanceFrequency( &f );
    frequency = (double)f.QuadPart;
    if (RegOpenKeyExW( HKEY_LOCAL_MACHINE, L"Software\\Microsoft\\Windows NT\\CurrentVersion", 0, KEY_READ, &key ))
    {
        printf( "no registry key\n" );
        return 1;
    }

    reg_ms = registry_reads( key, 20000 );
    yield_ms = yields( 10000 );

    t0 = counter();
    for (i = 0; i < 50; i++) Sleep( 20 );
    sleep_ms = ms_since( t0 );

    event = CreateEventW( NULL, TRUE, FALSE, NULL );
    t0 = counter();
    for (i = 0; i < 50; i++) WaitForSingleObject( event, 20 );
    event_ms = ms_since( t0 );

    t0 = counter();
    for (i = 0; i < 50; i++) WaitOnAddress( &address, &same, sizeof(address), 20 );
    address_ms = ms_since( t0 );
    /* WaitOnAddress waits while the value is the one given: it stays so, and each wait runs out its 20 ms */

    t0 = counter();
    for (i = 0; i < 50; i++) WaitForSingleObject( GetCurrentProcess(), 20 );
    process_ms = ms_since( t0 );

    GetSystemInfo( &info );
    threads = 2 * info.dwNumberOfProcessors;
    spinners = calloc( threads, sizeof(*spinners) );
    stop = 0;
    t0 = counter();
    for (i = 0; i < threads; i++) spinners[i] = CreateThread( NULL, 0, spin, NULL, 0, NULL );
    Sleep( 2000 );
    stop = 1;
    WaitForMultipleObjects( threads, spinners, TRUE, INFINITE );
    spin_s = ms_since( t0 ) / 1000.0;

    memory = VirtualAlloc( NULL, 256u << 20, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE );
    for (i = 0; memory && i < (256 << 20); i += 4096) memory[i] = 1;

    printf( "truth: registry 20000 %.0f ms, yields 10000 %.0f ms, sleeps 50 %.0f ms, event waits 50 %.0f ms, "
            "address waits 50 %.0f ms, process waits 50 %.0f ms, spin %d threads %.2f s, memory %d MB\n",
            reg_ms, yield_ms, sleep_ms, event_ms, address_ms, process_ms, threads, spin_s, memory ? 256 : 0 );

    for (i = 0; i < 3; i++)
    {
        double r = registry_reads( key, 2000 ) * 1e6 / 2000, y = yields( 10000 ) * 1e6 / 10000;
        if (r < best_reg) best_reg = r;
        if (y < best_yield) best_yield = y;
    }
    printf( "cost: registry read %.0f ns, yield %.0f ns\n", best_reg, best_yield );
    fflush( stdout );

    Sleep( stay * 1000 );
    return memory[0] == 1 ? 0 : 2;
}
