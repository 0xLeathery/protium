/*
 * Times how soon threads of each priority start on work handed to them and how fast they then
 * run it, the way a game's job system hands out a frame's jobs (Red Dead Redemption 2 runs its
 * eight job workers at THREAD_PRIORITY_LOWEST):
 *
 *   thread_wake_bench.exe [busy threads, default 0]
 *
 * Eight workers at one priority wait on an event each. The main thread sets the events; each
 * worker notes when it woke, does a fixed piece of work (about 200 us on a performance core) and
 * counts down; the main thread waits for the last one, sleeps 2 ms and goes again. NORMAL,
 * BELOW_NORMAL and LOWEST take turns, 100 batches at a time, 300 batches each. Prints e.g.
 *   lowest:       wake 40/120 us, work 210 us (slow 12%), batch 450 us
 * the median and 90th percentile of the time from SetEvent to the worker running, the median
 * time of the fixed work and the share of it that took over 1.5 times as long as on the main
 * thread (an efficiency core, or the worker put off the core midway), and the median time of a
 * whole batch. The busy threads, at normal priority, spin all the while, as a game's main and
 * render threads do. Run it with WINEFSYNC=1, as steamplay-run.sh runs games: without it the
 * wineserver wakes the workers instead of the main thread, and macOS then leaves threads below
 * Mach priority 28 (Wine's BELOW_NORMAL and LOWEST) waiting about a millisecond on an idle
 * machine, which games do not see. Built with the mingw compiler, no libraries.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#define WORKERS 8
#define ROUNDS 3
#define BATCHES 100

static const struct
{
    int priority;
    const char *name;
} levels[] =
{
    { THREAD_PRIORITY_NORMAL, "normal" },
    { THREAD_PRIORITY_BELOW_NORMAL, "below_normal" },
    { THREAD_PRIORITY_LOWEST, "lowest" },
};

static HANDLE wake_event[WORKERS], done_event;
static volatile LONG remaining, stop_workers, stop_busy, slot_base = -1;
static LARGE_INTEGER signalled[WORKERS];
static LONGLONG wake_ticks[ARRAYSIZE(levels)][ROUNDS * BATCHES * WORKERS];
static LONGLONG work_ticks[ARRAYSIZE(levels)][ROUNDS * BATCHES * WORKERS];
static LONGLONG batch_ticks[ARRAYSIZE(levels)][ROUNDS * BATCHES];
static int level;
static unsigned int work_loops;
static volatile unsigned int sink[WORKERS + 1];

static unsigned int work( unsigned int loops )
{
    unsigned int i, x = 1;
    for (i = 0; i < loops; i++) x = x * 1664525 + 1013904223;
    return x;
}

static DWORD WINAPI worker( void *arg )
{
    int index = (INT_PTR)arg;
    LARGE_INTEGER woke, done;

    for (;;)
    {
        WaitForSingleObject( wake_event[index], INFINITE );
        if (stop_workers) break;
        QueryPerformanceCounter( &woke );
        sink[index] += work( work_loops );
        QueryPerformanceCounter( &done );
        if (slot_base >= 0)
        {
            wake_ticks[level][slot_base + index] = woke.QuadPart - signalled[index].QuadPart;
            work_ticks[level][slot_base + index] = done.QuadPart - woke.QuadPart;
        }
        if (!InterlockedDecrement( &remaining )) SetEvent( done_event );
    }
    return 0;
}

static DWORD WINAPI busy( void *arg )
{
    unsigned int x = 0;
    while (!stop_busy) x += work( 10000 );
    return x;
}

/* BATCHES batches with the workers at levels[l], recorded from batch number first on */
static void run( int l, int first )
{
    HANDLE threads[WORKERS];
    LARGE_INTEGER start, end;
    int i, b;

    level = l;
    stop_workers = 0;
    for (i = 0; i < WORKERS; i++)
    {
        wake_event[i] = CreateEventW( NULL, FALSE, FALSE, NULL );
        threads[i] = CreateThread( NULL, 0, worker, (void *)(INT_PTR)i, CREATE_SUSPENDED, NULL );
        SetThreadPriority( threads[i], levels[l].priority );
        ResumeThread( threads[i] );
    }
    for (b = -10; b < BATCHES; b++) /* the first ten only warm up */
    {
        slot_base = b < 0 ? -1 : (first + b) * WORKERS;
        remaining = WORKERS;
        Sleep( 2 );
        QueryPerformanceCounter( &start );
        for (i = 0; i < WORKERS; i++)
        {
            QueryPerformanceCounter( &signalled[i] );
            SetEvent( wake_event[i] );
        }
        WaitForSingleObject( done_event, INFINITE );
        QueryPerformanceCounter( &end );
        if (b >= 0) batch_ticks[l][first + b] = end.QuadPart - start.QuadPart;
    }
    stop_workers = 1;
    for (i = 0; i < WORKERS; i++) SetEvent( wake_event[i] );
    WaitForMultipleObjects( WORKERS, threads, TRUE, INFINITE );
    for (i = 0; i < WORKERS; i++)
    {
        CloseHandle( threads[i] );
        CloseHandle( wake_event[i] );
    }
}

static int compare( const void *a, const void *b )
{
    LONGLONG x = *(const LONGLONG *)a, y = *(const LONGLONG *)b;
    return x < y ? -1 : x > y;
}

int main( int argc, char **argv )
{
    int busy_count = argc > 1 ? atoi( argv[1] ) : 0, i, l, r, n = ROUNDS * BATCHES * WORKERS, slow;
    LARGE_INTEGER freq, start, end;
    LONGLONG fastest = 0, t;
    HANDLE *busy_threads = calloc( busy_count + 1, sizeof(*busy_threads) );
    double us;

    QueryPerformanceFrequency( &freq );
    us = 1e6 / freq.QuadPart;
    done_event = CreateEventW( NULL, FALSE, FALSE, NULL );

    /* size the work to about 200 us here, at the main thread's priority */
    for (work_loops = 1000; work_loops < 1u << 30; work_loops *= 2)
    {
        QueryPerformanceCounter( &start );
        sink[WORKERS] += work( work_loops );
        QueryPerformanceCounter( &end );
        if ((end.QuadPart - start.QuadPart) * us > 2000) break;
    }
    work_loops /= 10;
    for (i = 0; i < 20; i++)
    {
        QueryPerformanceCounter( &start );
        sink[WORKERS] += work( work_loops );
        QueryPerformanceCounter( &end );
        t = end.QuadPart - start.QuadPart;
        if (!fastest || t < fastest) fastest = t;
    }

    for (i = 0; i < busy_count; i++) busy_threads[i] = CreateThread( NULL, 0, busy, NULL, 0, NULL );
    for (r = 0; r < ROUNDS; r++)
        for (l = 0; l < ARRAYSIZE(levels); l++) run( l, r * BATCHES );
    stop_busy = 1;
    if (busy_count) WaitForMultipleObjects( busy_count, busy_threads, TRUE, INFINITE );

    printf( "thread wake: %d workers, %d batches, %d busy threads, work %.0f us\n",
            WORKERS, ROUNDS * BATCHES, busy_count, fastest * us );
    for (l = 0; l < ARRAYSIZE(levels); l++)
    {
        for (i = slow = 0; i < n; i++) if (work_ticks[l][i] * 2 > fastest * 3) slow++;
        qsort( wake_ticks[l], n, sizeof(LONGLONG), compare );
        qsort( work_ticks[l], n, sizeof(LONGLONG), compare );
        qsort( batch_ticks[l], ROUNDS * BATCHES, sizeof(LONGLONG), compare );
        printf( "  %-13s wake %.0f/%.0f us, work %.0f us (slow %d%%), batch %.0f us\n", levels[l].name,
                wake_ticks[l][n / 2] * us, wake_ticks[l][n * 9 / 10] * us, work_ticks[l][n / 2] * us,
                100 * slow / n, batch_ticks[l][ROUNDS * BATCHES / 2] * us );
    }
    return 0;
}
