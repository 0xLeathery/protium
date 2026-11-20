/*
 * Checks what a thread is told about threads (priority, exit code, thread id) right after
 * each of them changes, and times the question a game asks most: its own priority.
 *
 *   thread_info_test.exe
 *
 * GetThreadPriority(), GetExitCodeThread() and GetThreadId() are one request to the wineserver
 * each (NtQueryInformationThread, ThreadBasicInformation). Call of Duty: WWII's main and
 * server threads spent about 30% of their time in that request while playing. On macOS Wine
 * therefore keeps, for a short time, what the server said about the calling thread itself; what
 * is kept must never be told when it is no longer true. The groups:
 *
 *  1  a thread sets its own priority, by the pseudo handle and by a real one, and reads it back
 *     at once, a thousand times
 *  2  another thread sets this thread's priority through a real handle; this thread reads the new
 *     value at once, without having waited for anything
 *  3  a handle to this thread is closed and its value comes back as a handle to another thread:
 *     the thread id read through it is the other thread's
 *  4  another thread's exit code is STILL_ACTIVE while it runs and its own once it has ended,
 *     also when this thread asked a moment before
 *  5  the calling thread's id and exit code through a real handle and the pseudo handle
 *
 * Prints a line per failure, then
 *   thread info test: <passed>/5 passed, own priority <n> us
 * where the time is that of one GetThreadPriority(GetCurrentThread()), in microseconds.
 * Built with the mingw compiler.
 */
#include <windows.h>
#include <stdio.h>

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf( __VA_ARGS__ ); printf( "\n" ); } } while (0)

static HANDLE self_handle;       /* a real handle to the main thread */
static volatile LONG other_done; /* set by set_main_priority() when it has set it */
static HANDLE go, stay;

static HANDLE real_handle(void)
{
    HANDLE h = NULL;
    DuplicateHandle( GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &h, 0, FALSE, DUPLICATE_SAME_ACCESS );
    return h;
}

static DWORD WINAPI set_main_priority( void *arg )
{
    SetThreadPriority( self_handle, (int)(INT_PTR)arg );
    InterlockedExchange( &other_done, 1 );
    return 0;
}

static DWORD WINAPI wait_then_exit( void *arg )
{
    WaitForSingleObject( go, INFINITE );
    return (DWORD)(DWORD_PTR)arg;
}

static DWORD WINAPI stay_alive( void *arg )
{
    WaitForSingleObject( stay, INFINITE );
    return 0;
}

static double now(void)
{
    LARGE_INTEGER count, freq;
    QueryPerformanceCounter( &count );
    QueryPerformanceFrequency( &freq );
    return (double)count.QuadPart / freq.QuadPart;
}

int main(void)
{
    static const int prios[] = { THREAD_PRIORITY_ABOVE_NORMAL, THREAD_PRIORITY_NORMAL, THREAD_PRIORITY_BELOW_NORMAL,
                                 THREAD_PRIORITY_HIGHEST, THREAD_PRIORITY_LOWEST };
    int i, before, passed = 0, group, sink = 0;
    HANDLE thread, h, others[64];
    DWORD code, tid;
    double start, us;

    self_handle = real_handle();
    go = CreateEventA( NULL, TRUE, FALSE, NULL );
    stay = CreateEventA( NULL, TRUE, FALSE, NULL );

    /* 1 */
    before = failures;
    for (i = 0; i < 1000; i++)
    {
        int prio = prios[i % 5];
        HANDLE target = (i & 1) ? self_handle : GetCurrentThread();
        GetThreadPriority( GetCurrentThread() );  /* what may be kept */
        SetThreadPriority( target, prio );
        CHECK( GetThreadPriority( GetCurrentThread() ) == prio, "1: round %d: pseudo handle says %d, set %d", i,
               GetThreadPriority( GetCurrentThread() ), prio );
        CHECK( GetThreadPriority( self_handle ) == prio, "1: round %d: real handle says %d, set %d", i,
               GetThreadPriority( self_handle ), prio );
        if (failures - before > 5) break;
    }
    passed += failures == before;

    /* 2 */
    before = failures;
    for (i = 0; i < 200; i++)
    {
        int prio = prios[i % 5];
        InterlockedExchange( &other_done, 0 );
        GetThreadPriority( GetCurrentThread() );
        GetThreadPriority( self_handle );
        thread = CreateThread( NULL, 0, set_main_priority, (void *)(INT_PTR)prio, 0, NULL );
        while (!other_done) sink += GetThreadPriority( GetCurrentThread() ) != 12345;  /* no wait, and keeps asking */
        CHECK( GetThreadPriority( GetCurrentThread() ) == prio, "2: round %d: pseudo handle says %d, another thread set %d", i,
               GetThreadPriority( GetCurrentThread() ), prio );
        CHECK( GetThreadPriority( self_handle ) == prio, "2: round %d: real handle says %d, another thread set %d", i,
               GetThreadPriority( self_handle ), prio );
        WaitForSingleObject( thread, INFINITE );
        CloseHandle( thread );
        if (failures - before > 5) break;
    }
    SetThreadPriority( GetCurrentThread(), THREAD_PRIORITY_NORMAL );
    passed += failures == before;

    /* 3 */
    before = failures;
    for (group = 0; group < 50; group++)
    {
        int n, found = 0;

        h = real_handle();
        CHECK( GetThreadId( h ) == GetCurrentThreadId(), "3: a handle to this thread says thread %lu", GetThreadId( h ) );
        GetThreadPriority( h );
        CloseHandle( h );
        for (n = 0; n < 64; n++)
        {
            others[n] = CreateThread( NULL, 0, stay_alive, NULL, 0, &tid );
            if (others[n] != h) continue;
            found = 1;
            CHECK( GetThreadId( h ) == tid, "3: the handle value now names thread %lu and says %lu (this thread is %lu)",
                   tid, GetThreadId( h ), GetCurrentThreadId() );
            n++;
            break;
        }
        SetEvent( stay );
        WaitForMultipleObjects( n, others, TRUE, INFINITE );
        while (n--) CloseHandle( others[n] );
        ResetEvent( stay );
        if (found && group >= 10) break;
        if (group == 49 && !found) printf( "3: the handle value never came back, not checked\n" );
    }
    passed += failures == before;

    /* 4 */
    before = failures;
    for (i = 0; i < 200; i++)
    {
        ResetEvent( go );
        thread = CreateThread( NULL, 0, wait_then_exit, (void *)(DWORD_PTR)(1000 + i), 0, NULL );
        code = 0;
        CHECK( GetExitCodeThread( thread, &code ) && code == STILL_ACTIVE, "4: round %d: a running thread's exit code is %lu", i, code );
        SetEvent( go );
        if (i & 1) WaitForSingleObject( thread, INFINITE );
        else do GetExitCodeThread( thread, &code ); while (code == STILL_ACTIVE);  /* asked a moment before it ends */
        code = 0;
        CHECK( GetExitCodeThread( thread, &code ) && code == 1000 + i, "4: round %d: an ended thread's exit code is %lu, not %d", i, code, 1000 + i );
        CloseHandle( thread );
        if (failures - before > 5) break;
    }
    passed += failures == before;

    /* 5 */
    before = failures;
    code = 0;
    CHECK( GetThreadId( self_handle ) == GetCurrentThreadId(), "5: real handle: thread %lu", GetThreadId( self_handle ) );
    CHECK( GetThreadId( GetCurrentThread() ) == GetCurrentThreadId(), "5: pseudo handle: thread %lu", GetThreadId( GetCurrentThread() ) );
    CHECK( GetExitCodeThread( self_handle, &code ) && code == STILL_ACTIVE, "5: real handle: exit code %lu", code );
    CHECK( GetExitCodeThread( GetCurrentThread(), &code ) && code == STILL_ACTIVE, "5: pseudo handle: exit code %lu", code );
    passed += failures == before;

    start = now();
    for (i = 0; i < 100000; i++) sink += GetThreadPriority( GetCurrentThread() );
    us = (now() - start) / 100000 * 1e6;

    printf( "thread info test: %d/5 passed, own priority %.2f us\n", passed, us );
    return failures != 0 || sink == 12345;
}
