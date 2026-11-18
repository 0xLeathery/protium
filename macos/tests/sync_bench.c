/*
 * Times the Windows synchronisation calls a game's job system makes all the time:
 *
 *   sync_bench.exe
 *
 * Polling an event (WaitForSingleObject with no timeout), setting and resetting one, releasing
 * and taking a semaphore, and for comparison a critical section, which never leaves the
 * process; then the event poll from 2, 4 and 8 threads at once. On Windows each of the first
 * three is a fraction of a microsecond, and Proton on Linux keeps them that cheap with fsync or
 * ntsync. Where Wine has neither, every one is a request to the wineserver, one process that
 * serves them in turn: on 2026-11-18 this build took 11 us for a poll, 20 us for a set and
 * reset, and 8 threads together got little more than twice what one thread gets (278,000
 * polls a second in all), against 0.017 us for the critical section. Call of Duty: WWII's
 * workers poll events this way, and its level load crawled with half the processor idle.
 *
 * Prints one line per measurement. It is a measurement, not a check: nothing passes or fails.
 * Built for x86_64 with the mingw compiler.
 */
#include <windows.h>
#include <stdio.h>
#define N 100000
static HANDLE event;
static volatile LONG go;
static DWORD CALLBACK poller( void *arg )
{
    int i;
    while (!go) Sleep( 0 );
    for (i = 0; i < N; i++) WaitForSingleObject( event, 0 );
    return 0;
}
static double now(void) { LARGE_INTEGER c, f; QueryPerformanceCounter( &c ); QueryPerformanceFrequency( &f ); return (double)c.QuadPart / f.QuadPart; }
int main(void)
{
    HANDLE threads[8], sem = CreateSemaphoreW( NULL, 0, 0x7fffffff, NULL );
    CRITICAL_SECTION cs;
    double t;
    int i, n;

    event = CreateEventW( NULL, TRUE, FALSE, NULL );
    t = now(); for (i = 0; i < N; i++) WaitForSingleObject( event, 0 );
    printf( "poll an event, 1 thread: %.2f us per call\n", (now() - t) / N * 1e6 );
    t = now(); for (i = 0; i < N; i++) { SetEvent( event ); ResetEvent( event ); }
    printf( "set + reset an event: %.2f us per pair\n", (now() - t) / N * 1e6 );
    t = now(); for (i = 0; i < N; i++) { ReleaseSemaphore( sem, 1, NULL ); WaitForSingleObject( sem, INFINITE ); }
    printf( "release + take a semaphore: %.2f us per pair\n", (now() - t) / N * 1e6 );
    InitializeCriticalSection( &cs );
    t = now(); for (i = 0; i < N; i++) { EnterCriticalSection( &cs ); LeaveCriticalSection( &cs ); }
    printf( "critical section (never leaves the process): %.3f us per pair\n", (now() - t) / N * 1e6 );
    for (n = 2; n <= 8; n *= 2)
    {
        go = 0;
        for (i = 0; i < n; i++) threads[i] = CreateThread( NULL, 0, poller, NULL, 0, NULL );
        t = now(); go = 1;
        WaitForMultipleObjects( n, threads, TRUE, INFINITE );
        t = now() - t;
        printf( "poll an event, %d threads at once: %.2f us per call, %.0f calls a second in all\n", n, t / N * 1e6, n * N / t );
        for (i = 0; i < n; i++) CloseHandle( threads[i] );
    }
    return 0;
}
