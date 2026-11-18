/*
 * Checks the Windows synchronisation objects the way programs use them, so that a fast path for
 * them (fsync) can be compared with the wineserver's own:
 *
 *   sync_test.exe
 *
 * Events (auto and manual, PulseEvent, SignalObjectAndWait), semaphores to their limit, mutex
 * recursion and abandonment (by a thread that ends, one that is terminated, and a process that
 * is killed), waits on any and on all of several objects, timeouts (none, relative, absolute,
 * and one racing a signal), alertable waits and SleepEx woken by QueueUserAPC, objects the
 * server itself signals (thread and process handles, waitable timers, overlapped pipe I/O,
 * completion ports, MsgWaitForMultipleObjects woken by a posted message), named objects used
 * by two processes, a peer killed while it waits, worker threads that wait for (work, quit)
 * with every token counted, the same with an event per worker, churn of creating and closing,
 * two thousand threads that each wait alertably and end (files opened before must still be
 * readable), ten thousand threads of which some start while others end (each must get to its
 * first instruction: under FEX one in a few thousand did not, see emulator_thread_section in
 * Wine's signal_arm64ec.c), and SuspendThread across a wait.
 *
 * Prints one line per group and at the end, e.g.
 *   sync test: 15/15 passed
 * and exits 0 when all passed. The results must be the same with WINEFSYNC=1 and without.
 *
 * Built for x86_64 and i686 with the mingw compiler: -luser32 -lntdll.
 */
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int groups, passed;
static char detail[256];

static void result( const char *name, BOOL ok )
{
    groups++;
    if (ok) passed++;
    printf( "%s: %s%s%s\n", name, ok ? "ok" : "FAIL", detail[0] ? " - " : "", detail );
    fflush( stdout );
    detail[0] = 0;
}

#define CHECK(cond) do { if (!(cond)) { if (!detail[0]) snprintf( detail, sizeof(detail), "line %d: %s", __LINE__, #cond ); ok = FALSE; } } while (0)

static double now_ms(void)
{
    LARGE_INTEGER c, f;
    QueryPerformanceCounter( &c );
    QueryPerformanceFrequency( &f );
    return (double)c.QuadPart * 1000.0 / f.QuadPart;
}

/* ---------------------------------------------------------------- helpers run on threads */

struct delayed { HANDLE handle; DWORD delay; int action; LONG count; };

static DWORD CALLBACK delayed_signal( void *arg )
{
    struct delayed *d = arg;
    Sleep( d->delay );
    if (d->action == 0) SetEvent( d->handle );
    else if (d->action == 1) ReleaseSemaphore( d->handle, d->count, NULL );
    else if (d->action == 2) PulseEvent( d->handle );
    return 0;
}

static HANDLE run_delayed( struct delayed *d ) { return CreateThread( NULL, 0, delayed_signal, d, 0, NULL ); }

static DWORD CALLBACK take_mutex_and_end( void *arg )
{
    WaitForSingleObject( arg, INFINITE );
    return 0;
}

static HANDLE held;
static DWORD CALLBACK take_mutex_and_sleep( void *arg )
{
    WaitForSingleObject( arg, INFINITE );
    SetEvent( held );
    Sleep( INFINITE );
    return 0;
}

static LONG apc_runs;
static void CALLBACK count_apc( ULONG_PTR arg ) { InterlockedIncrement( &apc_runs ); }

struct alertable { HANDLE objs[2]; int mode; DWORD ret; HANDLE ready; LONG loops; volatile LONG stop; };

static DWORD CALLBACK alertable_waiter( void *arg )
{
    struct alertable *a = arg;
    SetEvent( a->ready );
    if (a->mode == 0) a->ret = WaitForSingleObjectEx( a->objs[0], 10000, TRUE );
    else if (a->mode == 1) a->ret = WaitForMultipleObjectsEx( 2, a->objs, FALSE, 10000, TRUE );
    else if (a->mode == 2) a->ret = SleepEx( 10000, TRUE );
    else while (!a->stop) { if (WaitForMultipleObjectsEx( 2, a->objs, FALSE, 20, TRUE ) == WAIT_IO_COMPLETION) InterlockedIncrement( &a->loops ); }
    return 0;
}

/* ---------------------------------------------------------------- workers */

struct pool { HANDLE work, quit, ack, own[8]; LONG taken; int nworkers; };
struct worker { struct pool *pool; int index; };

static DWORD CALLBACK shared_worker( void *arg )
{
    struct worker *w = arg;
    HANDLE objs[2] = { w->pool->work, w->pool->quit };
    for (;;)
    {
        DWORD r = WaitForMultipleObjects( 2, objs, FALSE, INFINITE );
        if (r != WAIT_OBJECT_0) return r == WAIT_OBJECT_0 + 1 ? 0 : 1;
        InterlockedIncrement( &w->pool->taken );
    }
}

static DWORD CALLBACK own_event_worker( void *arg )
{
    struct worker *w = arg;
    HANDLE objs[2] = { w->pool->own[w->index], w->pool->quit };
    for (;;)
    {
        DWORD r = WaitForMultipleObjects( 2, objs, FALSE, INFINITE );
        if (r != WAIT_OBJECT_0) return r == WAIT_OBJECT_0 + 1 ? 0 : 1;
        InterlockedIncrement( &w->pool->taken );
        ReleaseSemaphore( w->pool->ack, 1, NULL );
    }
}

static DWORD CALLBACK greedy_taker( void *arg )
{
    struct pool *p = arg;
    HANDLE objs[2] = { p->work, p->quit };
    for (;;)
    {
        DWORD r = WaitForMultipleObjects( 2, objs, FALSE, INFINITE );
        if (r != WAIT_OBJECT_0) return 0;
        InterlockedIncrement( &p->taken );
    }
}

static DWORD CALLBACK short_alertable( void *arg )
{
    HANDLE objs[2] = { arg, arg };
    WaitForSingleObjectEx( arg, 0, TRUE );
    WaitForMultipleObjectsEx( 1, objs, FALSE, 0, TRUE );
    SleepEx( 0, TRUE );
    return 0;
}

static DWORD CALLBACK wait_then_flag( void *arg )
{
    HANDLE *h = arg;
    WaitForSingleObject( h[0], INFINITE );
    SetEvent( h[1] );
    return 0;
}

/* ---------------------------------------------------------------- the other process */

static int child_main( int argc, char **argv )
{
    if (!strcmp( argv[1], "exit" )) return 7;
    if (!strcmp( argv[1], "abandon" ))
    {
        HANDLE mutex = OpenMutexA( SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE, argv[2] );
        HANDLE got = OpenEventA( EVENT_MODIFY_STATE, FALSE, argv[3] );
        WaitForSingleObject( mutex, INFINITE );
        SetEvent( got );
        Sleep( INFINITE );
    }
    if (!strcmp( argv[1], "pingpong" ))
    {
        HANDLE ping = OpenEventA( SYNCHRONIZE, FALSE, argv[2] );
        HANDLE pong = OpenSemaphoreA( SEMAPHORE_MODIFY_STATE, FALSE, argv[3] );
        int i, rounds = atoi( argv[4] );
        for (i = 0; i < rounds; i++)
        {
            if (WaitForSingleObject( ping, 20000 ) != WAIT_OBJECT_0) return 1;
            ReleaseSemaphore( pong, 1, NULL );
        }
        return 0;
    }
    if (!strcmp( argv[1], "sleeper" ))
    {
        HANDLE event = OpenEventA( SYNCHRONIZE, FALSE, argv[2] );
        HANDLE other = OpenEventA( SYNCHRONIZE, FALSE, argv[3] );
        HANDLE objs[2] = { event, other };
        HANDLE ready = OpenEventA( EVENT_MODIFY_STATE, FALSE, argv[4] );
        SetEvent( ready );
        WaitForMultipleObjects( 2, objs, TRUE, INFINITE );
        return 0;
    }
    return 2;
}

static HANDLE spawn( const char *args )
{
    char path[MAX_PATH], cmd[MAX_PATH + 256];
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;

    GetModuleFileNameA( NULL, path, sizeof(path) );
    snprintf( cmd, sizeof(cmd), "\"%s\" %s", path, args );
    if (!CreateProcessA( NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi )) return NULL;
    CloseHandle( pi.hThread );
    return pi.hProcess;
}

/* ---------------------------------------------------------------- the groups */

static void test_events(void)
{
    BOOL ok = TRUE;
    HANDLE a = CreateEventW( NULL, FALSE, FALSE, NULL ), m = CreateEventW( NULL, TRUE, FALSE, NULL ), t;
    struct delayed d = { m, 80, 2 };
    double t0;

    CHECK( WaitForSingleObject( a, 0 ) == WAIT_TIMEOUT );
    CHECK( SetEvent( a ) );
    CHECK( WaitForSingleObject( a, 0 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( a, 0 ) == WAIT_TIMEOUT );   /* an auto event is taken by the wait */
    CHECK( SetEvent( a ) && SetEvent( a ) );
    CHECK( WaitForSingleObject( a, 0 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( a, 0 ) == WAIT_TIMEOUT );   /* and holds one signal, not two */
    CHECK( SetEvent( m ) );
    CHECK( WaitForSingleObject( m, 0 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( m, 0 ) == WAIT_OBJECT_0 );  /* a manual one stays */
    CHECK( ResetEvent( m ) );
    CHECK( WaitForSingleObject( m, 0 ) == WAIT_TIMEOUT );
    /* a pulse wakes a thread that is already waiting and leaves the event unsignalled */
    t = run_delayed( &d );
    t0 = now_ms();
    CHECK( WaitForSingleObject( m, 5000 ) == WAIT_OBJECT_0 );
    CHECK( now_ms() - t0 < 3000 );
    WaitForSingleObject( t, INFINITE );
    CHECK( WaitForSingleObject( m, 0 ) == WAIT_TIMEOUT );
    /* signal one, wait for the other */
    CHECK( SetEvent( m ) );
    CHECK( SignalObjectAndWait( a, m, 1000, FALSE ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( a, 0 ) == WAIT_OBJECT_0 );
    CloseHandle( t ); CloseHandle( a ); CloseHandle( m );
    result( "events", ok );
}

static void test_semaphores(void)
{
    BOOL ok = TRUE;
    HANDLE s = CreateSemaphoreW( NULL, 0, 3, NULL ), t;
    struct delayed d = { s, 50, 1, 2 };
    LONG prev = -1;

    CHECK( WaitForSingleObject( s, 0 ) == WAIT_TIMEOUT );
    CHECK( ReleaseSemaphore( s, 2, &prev ) && prev == 0 );
    SetLastError( 0 );
    CHECK( !ReleaseSemaphore( s, 2, &prev ) && GetLastError() == ERROR_TOO_MANY_POSTS );
    CHECK( ReleaseSemaphore( s, 1, &prev ) && prev == 2 );
    CHECK( WaitForSingleObject( s, 0 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( s, 0 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( s, 0 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( s, 0 ) == WAIT_TIMEOUT );
    t = run_delayed( &d );     /* two tokens at once wake two waits */
    CHECK( WaitForSingleObject( s, 5000 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( s, 5000 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( s, 0 ) == WAIT_TIMEOUT );
    WaitForSingleObject( t, INFINITE );
    CloseHandle( t ); CloseHandle( s );
    result( "semaphores", ok );
}

static void test_mutexes(void)
{
    BOOL ok = TRUE;
    HANDLE m = CreateMutexW( NULL, FALSE, NULL ), t, child, got;
    char args[128];

    CHECK( WaitForSingleObject( m, 0 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( m, 0 ) == WAIT_OBJECT_0 );   /* its owner may take it again */
    CHECK( ReleaseMutex( m ) && ReleaseMutex( m ) );
    SetLastError( 0 );
    CHECK( !ReleaseMutex( m ) && GetLastError() == ERROR_NOT_OWNER );
    /* a thread that ends while it holds the mutex abandons it */
    t = CreateThread( NULL, 0, take_mutex_and_end, m, 0, NULL );
    WaitForSingleObject( t, INFINITE ); CloseHandle( t );
    CHECK( WaitForSingleObject( m, 2000 ) == WAIT_ABANDONED );
    CHECK( ReleaseMutex( m ) );
    CHECK( WaitForSingleObject( m, 0 ) == WAIT_OBJECT_0 );   /* once told, it is a mutex like any other */
    CHECK( ReleaseMutex( m ) );
    /* so does a thread that is terminated */
    held = CreateEventW( NULL, FALSE, FALSE, NULL );
    t = CreateThread( NULL, 0, take_mutex_and_sleep, m, 0, NULL );
    CHECK( WaitForSingleObject( held, 5000 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( m, 0 ) == WAIT_TIMEOUT );
    TerminateThread( t, 0 );
    WaitForSingleObject( t, INFINITE ); CloseHandle( t );
    CHECK( WaitForSingleObject( m, 2000 ) == WAIT_ABANDONED );
    CHECK( ReleaseMutex( m ) );
    CloseHandle( m );
    /* and a process that is killed */
    snprintf( args, sizeof(args), "sync_test_mutex_%lu", GetCurrentProcessId() );
    m = CreateMutexA( NULL, FALSE, args );
    snprintf( args, sizeof(args), "sync_test_got_%lu", GetCurrentProcessId() );
    got = CreateEventA( NULL, FALSE, FALSE, args );
    snprintf( args, sizeof(args), "abandon sync_test_mutex_%lu sync_test_got_%lu", GetCurrentProcessId(), GetCurrentProcessId() );
    child = spawn( args );
    CHECK( child != NULL );
    CHECK( WaitForSingleObject( got, 20000 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( m, 0 ) == WAIT_TIMEOUT );
    TerminateProcess( child, 0 );
    WaitForSingleObject( child, INFINITE ); CloseHandle( child );
    CHECK( WaitForSingleObject( m, 5000 ) == WAIT_ABANDONED );
    CHECK( ReleaseMutex( m ) );
    CloseHandle( m ); CloseHandle( got ); CloseHandle( held );
    result( "mutexes", ok );
}

static void test_wait_any(void)
{
    BOOL ok = TRUE;
    HANDLE objs[3] = { CreateEventW( NULL, FALSE, FALSE, NULL ), CreateEventW( NULL, TRUE, FALSE, NULL ),
                       CreateSemaphoreW( NULL, 0, 10, NULL ) }, t;
    struct delayed d = { objs[1], 60, 0 }, d2 = { objs[2], 60, 1, 1 };
    double t0;

    t0 = now_ms();
    CHECK( WaitForMultipleObjects( 3, objs, FALSE, 60 ) == WAIT_TIMEOUT );
    CHECK( now_ms() - t0 >= 40 && now_ms() - t0 < 1500 );
    t = run_delayed( &d );
    CHECK( WaitForMultipleObjects( 3, objs, FALSE, 5000 ) == WAIT_OBJECT_0 + 1 );
    WaitForSingleObject( t, INFINITE ); CloseHandle( t );
    ResetEvent( objs[1] );
    t = run_delayed( &d2 );
    CHECK( WaitForMultipleObjects( 3, objs, FALSE, 5000 ) == WAIT_OBJECT_0 + 2 );
    WaitForSingleObject( t, INFINITE ); CloseHandle( t );
    /* the first signalled one in the list is the one that is taken */
    SetEvent( objs[0] ); ReleaseSemaphore( objs[2], 1, NULL );
    CHECK( WaitForMultipleObjects( 3, objs, FALSE, 0 ) == WAIT_OBJECT_0 );
    CHECK( WaitForMultipleObjects( 3, objs, FALSE, 0 ) == WAIT_OBJECT_0 + 2 );
    CHECK( WaitForMultipleObjects( 3, objs, FALSE, 0 ) == WAIT_TIMEOUT );
    CloseHandle( objs[0] ); CloseHandle( objs[1] ); CloseHandle( objs[2] );
    result( "wait for any", ok );
}

static void test_wait_all(void)
{
    BOOL ok = TRUE;
    struct pool pool = { CreateSemaphoreW( NULL, 0, 0x7fffffff, NULL ), CreateEventW( NULL, TRUE, FALSE, NULL ) };
    HANDLE objs[3] = { CreateEventW( NULL, FALSE, FALSE, NULL ), CreateEventW( NULL, TRUE, FALSE, NULL ), pool.work }, t, taker;
    struct delayed d = { objs[1], 60, 0 };
    LONG mine = 0, i;
    const LONG tokens = 4000;

    SetEvent( objs[0] );
    CHECK( WaitForMultipleObjects( 2, objs, TRUE, 30 ) == WAIT_TIMEOUT );
    CHECK( WaitForSingleObject( objs[0], 0 ) == WAIT_OBJECT_0 );   /* a wait for all that failed took nothing */
    SetEvent( objs[0] );
    t = run_delayed( &d );
    CHECK( WaitForMultipleObjects( 2, objs, TRUE, 5000 ) == WAIT_OBJECT_0 );
    WaitForSingleObject( t, INFINITE ); CloseHandle( t );
    CHECK( WaitForSingleObject( objs[0], 0 ) == WAIT_TIMEOUT );    /* and one that succeeded took the auto event */
    /* a wait for all against a thread that takes whatever it can: no token may be lost or made */
    taker = CreateThread( NULL, 0, greedy_taker, &pool, 0, NULL );
    for (i = 0; i < tokens; i++)
    {
        ReleaseSemaphore( pool.work, 1, NULL );
        if (WaitForMultipleObjects( 2, objs + 1, TRUE, 0 ) == WAIT_OBJECT_0) mine++;
    }
    for (i = 0; i < 200 && mine + pool.taken < tokens; i++) Sleep( 10 );
    CHECK( mine + pool.taken == tokens );
    if (mine + pool.taken != tokens) snprintf( detail, sizeof(detail), "%ld + %ld of %ld tokens", mine, pool.taken, tokens );
    SetEvent( pool.quit );
    CHECK( WaitForSingleObject( taker, 5000 ) == WAIT_OBJECT_0 );
    CloseHandle( taker ); CloseHandle( objs[0] ); CloseHandle( objs[1] ); CloseHandle( pool.work ); CloseHandle( pool.quit );
    result( "wait for all", ok );
}

static void test_timeouts(void)
{
    BOOL ok = TRUE;
    HANDLE e = CreateEventW( NULL, FALSE, FALSE, NULL ), t;
    struct delayed d = { e, 30, 0 };
    LARGE_INTEGER when;
    FILETIME ft;
    double t0;
    int i, signalled = 0, timed_out = 0;

    t0 = now_ms();
    CHECK( WaitForSingleObject( e, 0 ) == WAIT_TIMEOUT );
    CHECK( now_ms() - t0 < 50 );
    t0 = now_ms();
    CHECK( WaitForSingleObject( e, 50 ) == WAIT_TIMEOUT );
    CHECK( now_ms() - t0 >= 35 && now_ms() - t0 < 1500 );
    /* until a time of day */
    GetSystemTimeAsFileTime( &ft );
    when.LowPart = ft.dwLowDateTime; when.HighPart = ft.dwHighDateTime;
    when.QuadPart += 50 * 10000;
    t0 = now_ms();
    CHECK( NtWaitForSingleObject( e, FALSE, &when ) == STATUS_TIMEOUT );
    CHECK( now_ms() - t0 >= 30 && now_ms() - t0 < 1500 );
    /* a signal that arrives about when the time is up: the wait says one or the other, and the
     * event is taken exactly when the wait said so */
    for (i = 0; i < 40; i++)
    {
        DWORD r;
        t = run_delayed( &d );
        r = WaitForSingleObject( e, 30 );
        WaitForSingleObject( t, INFINITE ); CloseHandle( t );
        if (r == WAIT_OBJECT_0) { signalled++; CHECK( WaitForSingleObject( e, 0 ) == WAIT_TIMEOUT ); }
        else { timed_out++; CHECK( r == WAIT_TIMEOUT ); CHECK( WaitForSingleObject( e, 0 ) == WAIT_OBJECT_0 ); }
    }
    CHECK( signalled + timed_out == 40 );
    CloseHandle( e );
    result( "timeouts", ok );
}

static void test_apcs(void)
{
    BOOL ok = TRUE;
    struct alertable a = { { CreateEventW( NULL, FALSE, FALSE, NULL ), CreateEventW( NULL, FALSE, FALSE, NULL ) } };
    HANDLE t;
    int mode, i;

    a.ready = CreateEventW( NULL, FALSE, FALSE, NULL );
    for (mode = 0; mode < 3; mode++)
    {
        LONG before = apc_runs;
        a.mode = mode; a.ret = 0xdead;
        t = CreateThread( NULL, 0, alertable_waiter, &a, 0, NULL );
        WaitForSingleObject( a.ready, INFINITE );
        Sleep( 40 );   /* let it get into its wait */
        CHECK( QueueUserAPC( count_apc, t, 0 ) );
        CHECK( WaitForSingleObject( t, 5000 ) == WAIT_OBJECT_0 );
        CHECK( a.ret == WAIT_IO_COMPLETION );
        CHECK( apc_runs == before + 1 );
        CloseHandle( t );
    }
    /* many of them, into a thread that keeps going back into an alertable wait on two objects */
    {
        LONG before = apc_runs;
        a.mode = 3; a.stop = 0; a.loops = 0;
        t = CreateThread( NULL, 0, alertable_waiter, &a, 0, NULL );
        WaitForSingleObject( a.ready, INFINITE );
        for (i = 0; i < 2000; i++) { CHECK( QueueUserAPC( count_apc, t, 0 ) ); if (!(i & 63)) Sleep( 1 ); }
        for (i = 0; i < 300 && apc_runs < before + 2000; i++) Sleep( 10 );
        CHECK( apc_runs == before + 2000 );
        if (apc_runs != before + 2000) snprintf( detail, sizeof(detail), "%ld of 2000 APCs ran", apc_runs - before );
        a.stop = 1;
        CHECK( WaitForSingleObject( t, 5000 ) == WAIT_OBJECT_0 );
        CloseHandle( t );
    }
    /* an APC queued before the wait is run by it, and a wait that is not alertable ignores it */
    CHECK( QueueUserAPC( count_apc, GetCurrentThread(), 0 ) );
    i = apc_runs;
    CHECK( WaitForSingleObject( a.objs[0], 20 ) == WAIT_TIMEOUT && apc_runs == i );
    CHECK( WaitForSingleObjectEx( a.objs[0], 1000, TRUE ) == WAIT_IO_COMPLETION && apc_runs == i + 1 );
    CloseHandle( a.objs[0] ); CloseHandle( a.objs[1] ); CloseHandle( a.ready );
    result( "alertable waits", ok );
}

static DWORD CALLBACK post_message_later( void *arg )
{
    Sleep( 60 );
    PostThreadMessageA( (DWORD)(ULONG_PTR)arg, WM_USER + 1, 1, 2 );
    return 0;
}

static DWORD CALLBACK completion_waiter( void *arg )
{
    DWORD bytes = 0; ULONG_PTR key = 0; OVERLAPPED *ov = NULL;
    if (!GetQueuedCompletionStatus( arg, &bytes, &key, &ov, 5000 )) return 1;
    return bytes == 123 && key == 456 ? 0 : 2;
}

static void test_server_objects(void)
{
    BOOL ok = TRUE;
    HANDLE t, child, timer, port, e = CreateEventW( NULL, FALSE, FALSE, NULL ), pipe_server, pipe_client;
    struct delayed d = { e, 50, 0 };
    LARGE_INTEGER due;
    OVERLAPPED ov = { 0 };
    char name[64], buf[16];
    DWORD code = 0, n = 0;
    MSG msg;
    double t0;

    /* a thread's handle is signalled when the thread ends, a process's when the process does */
    t = run_delayed( &d );
    CHECK( WaitForSingleObject( t, 0 ) == WAIT_TIMEOUT );
    CHECK( WaitForSingleObject( t, 5000 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( t, 0 ) == WAIT_OBJECT_0 );
    CloseHandle( t );
    child = spawn( "exit" );
    CHECK( child != NULL );
    CHECK( WaitForSingleObject( child, 30000 ) == WAIT_OBJECT_0 );
    CHECK( GetExitCodeProcess( child, &code ) && code == 7 );
    CloseHandle( child );
    /* a timer */
    timer = CreateWaitableTimerW( NULL, FALSE, NULL );
    due.QuadPart = -50 * 10000;
    t0 = now_ms();
    CHECK( SetWaitableTimer( timer, &due, 0, NULL, NULL, FALSE ) );
    CHECK( WaitForSingleObject( timer, 0 ) == WAIT_TIMEOUT );
    {
        HANDLE objs[2] = { e, timer };
        WaitForSingleObject( e, 0 );
        CHECK( WaitForMultipleObjects( 2, objs, FALSE, 5000 ) == WAIT_OBJECT_0 + 1 );
        CHECK( now_ms() - t0 >= 35 );
    }
    CloseHandle( timer );
    /* overlapped I/O on a pipe: the read's event is set when the other end writes */
    snprintf( name, sizeof(name), "\\\\.\\pipe\\sync_test_%lu", GetCurrentProcessId() );
    pipe_server = CreateNamedPipeA( name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED, PIPE_TYPE_BYTE, 1, 256, 256, 0, NULL );
    pipe_client = CreateFileA( name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL );
    CHECK( pipe_server != INVALID_HANDLE_VALUE && pipe_client != INVALID_HANDLE_VALUE );
    ov.hEvent = CreateEventW( NULL, TRUE, FALSE, NULL );
    CHECK( !ReadFile( pipe_server, buf, sizeof(buf), NULL, &ov ) && GetLastError() == ERROR_IO_PENDING );
    CHECK( WaitForSingleObject( ov.hEvent, 30 ) == WAIT_TIMEOUT );
    CHECK( WriteFile( pipe_client, "hello", 5, &n, NULL ) );
    CHECK( WaitForSingleObject( ov.hEvent, 5000 ) == WAIT_OBJECT_0 );
    CHECK( GetOverlappedResult( pipe_server, &ov, &n, FALSE ) && n == 5 );
    CloseHandle( ov.hEvent ); CloseHandle( pipe_client ); CloseHandle( pipe_server );
    /* a completion port with a thread waiting on it */
    port = CreateIoCompletionPort( INVALID_HANDLE_VALUE, NULL, 0, 0 );
    t = CreateThread( NULL, 0, completion_waiter, port, 0, NULL );
    Sleep( 40 );
    CHECK( PostQueuedCompletionStatus( port, 123, 456, NULL ) );
    CHECK( WaitForSingleObject( t, 6000 ) == WAIT_OBJECT_0 );
    CHECK( GetExitCodeThread( t, &code ) && code == 0 );
    CloseHandle( t ); CloseHandle( port );
    /* a wait that also ends when a message arrives */
    PeekMessageA( &msg, NULL, 0, 0, PM_NOREMOVE );   /* makes the thread's queue */
    t = CreateThread( NULL, 0, post_message_later, (void *)(ULONG_PTR)GetCurrentThreadId(), 0, NULL );
    CHECK( MsgWaitForMultipleObjects( 1, &e, FALSE, 5000, QS_ALLINPUT ) == WAIT_OBJECT_0 + 1 );
    CHECK( PeekMessageA( &msg, NULL, 0, 0, PM_REMOVE ) && msg.message == WM_USER + 1 );
    WaitForSingleObject( t, INFINITE ); CloseHandle( t );
    SetEvent( e );
    CHECK( MsgWaitForMultipleObjects( 1, &e, FALSE, 5000, QS_ALLINPUT ) == WAIT_OBJECT_0 );
    CloseHandle( e );
    result( "objects the server signals", ok );
}

static void test_two_processes(void)
{
    BOOL ok = TRUE;
    char ping_name[64], pong_name[64], ready_name[64], args[256];
    HANDLE ping, pong, ready, child, other;
    const int rounds = 3000;
    DWORD code = 99;
    int i;

    snprintf( ping_name, sizeof(ping_name), "sync_test_ping_%lu", GetCurrentProcessId() );
    snprintf( pong_name, sizeof(pong_name), "sync_test_pong_%lu", GetCurrentProcessId() );
    snprintf( ready_name, sizeof(ready_name), "sync_test_ready_%lu", GetCurrentProcessId() );
    ping = CreateEventA( NULL, FALSE, FALSE, ping_name );
    pong = CreateSemaphoreA( NULL, 0, 1000, pong_name );
    ready = CreateEventA( NULL, FALSE, FALSE, ready_name );
    snprintf( args, sizeof(args), "pingpong %s %s %d", ping_name, pong_name, rounds );
    child = spawn( args );
    CHECK( child != NULL );
    for (i = 0; i < rounds && ok; i++)
    {
        SetEvent( ping );
        CHECK( WaitForSingleObject( pong, 20000 ) == WAIT_OBJECT_0 );
    }
    if (!ok && !detail[0]) snprintf( detail, sizeof(detail), "round %d of %d", i, rounds );
    CHECK( WaitForSingleObject( child, 20000 ) == WAIT_OBJECT_0 );
    CHECK( GetExitCodeProcess( child, &code ) && code == 0 );
    CloseHandle( child );
    /* the other process is killed while it waits for these objects; they go on working */
    snprintf( args, sizeof(args), "sleeper %s %s %s", ping_name, pong_name, ready_name );
    other = CreateEventA( NULL, FALSE, FALSE, pong_name );   /* fails: the name is a semaphore's */
    CHECK( other == NULL );
    snprintf( pong_name, sizeof(pong_name), "sync_test_other_%lu", GetCurrentProcessId() );
    other = CreateEventA( NULL, FALSE, FALSE, pong_name );
    snprintf( args, sizeof(args), "sleeper %s %s %s", ping_name, pong_name, ready_name );
    child = spawn( args );
    CHECK( child != NULL );
    CHECK( WaitForSingleObject( ready, 20000 ) == WAIT_OBJECT_0 );
    Sleep( 50 );
    TerminateProcess( child, 0 );
    WaitForSingleObject( child, INFINITE ); CloseHandle( child );
    CHECK( SetEvent( ping ) && WaitForSingleObject( ping, 1000 ) == WAIT_OBJECT_0 );
    CHECK( SetEvent( other ) && WaitForSingleObject( other, 1000 ) == WAIT_OBJECT_0 );
    CloseHandle( ping ); CloseHandle( pong ); CloseHandle( ready ); CloseHandle( other );
    result( "two processes", ok );
}

static void test_workers(void)
{
    BOOL ok = TRUE;
    struct pool pool = { CreateSemaphoreW( NULL, 0, 0x7fffffff, NULL ), CreateEventW( NULL, TRUE, FALSE, NULL ) };
    struct worker workers[8];
    HANDLE threads[8];
    const LONG tokens = 40000;
    LONG i;
    double t0;

    pool.nworkers = 8;
    for (i = 0; i < 8; i++) { workers[i].pool = &pool; workers[i].index = i; threads[i] = CreateThread( NULL, 0, shared_worker, &workers[i], 0, NULL ); }
    for (i = 0; i < tokens; i++) ReleaseSemaphore( pool.work, 1, NULL );
    t0 = now_ms();
    while (pool.taken < tokens && now_ms() - t0 < 30000) Sleep( 5 );
    CHECK( pool.taken == tokens );
    if (pool.taken != tokens) snprintf( detail, sizeof(detail), "%ld of %ld tokens taken", pool.taken, tokens );
    SetEvent( pool.quit );
    CHECK( WaitForMultipleObjects( 8, threads, TRUE, 10000 ) == WAIT_OBJECT_0 );
    for (i = 0; i < 8; i++) { DWORD code = 1; GetExitCodeThread( threads[i], &code ); CHECK( code == 0 ); CloseHandle( threads[i] ); }
    CHECK( WaitForSingleObject( pool.work, 0 ) == WAIT_TIMEOUT );
    CloseHandle( pool.work ); CloseHandle( pool.quit );
    result( "workers on one queue", ok );
}

static void test_workers_own_events(void)
{
    BOOL ok = TRUE;
    struct pool pool = { NULL, CreateEventW( NULL, TRUE, FALSE, NULL ), CreateSemaphoreW( NULL, 0, 0x7fffffff, NULL ) };
    struct worker workers[8];
    HANDLE threads[8];
    const LONG jobs = 20000;
    LONG i;

    for (i = 0; i < 8; i++)
    {
        pool.own[i] = CreateEventW( NULL, FALSE, FALSE, NULL );
        workers[i].pool = &pool; workers[i].index = i;
        threads[i] = CreateThread( NULL, 0, own_event_worker, &workers[i], 0, NULL );
    }
    for (i = 0; i < jobs && ok; i++)
    {
        SetEvent( pool.own[i & 7] );
        CHECK( WaitForSingleObject( pool.ack, 20000 ) == WAIT_OBJECT_0 );
    }
    CHECK( pool.taken == jobs );
    if (pool.taken != jobs) snprintf( detail, sizeof(detail), "%ld of %ld jobs done", pool.taken, jobs );
    SetEvent( pool.quit );
    CHECK( WaitForMultipleObjects( 8, threads, TRUE, 10000 ) == WAIT_OBJECT_0 );
    for (i = 0; i < 8; i++) { CloseHandle( threads[i] ); CloseHandle( pool.own[i] ); }
    CloseHandle( pool.ack ); CloseHandle( pool.quit );
    result( "workers with an event each", ok );
}

static void test_churn(void)
{
    BOOL ok = TRUE;
    int i;

    for (i = 0; i < 20000 && ok; i++)
    {
        HANDLE e = CreateEventW( NULL, i & 1, FALSE, NULL ), s = CreateSemaphoreW( NULL, 1, 2, NULL ), m = CreateMutexW( NULL, TRUE, NULL ), d;
        CHECK( e && s && m );
        CHECK( SetEvent( e ) && WaitForSingleObject( e, 0 ) == WAIT_OBJECT_0 );
        CHECK( WaitForSingleObject( s, 0 ) == WAIT_OBJECT_0 && WaitForSingleObject( s, 0 ) == WAIT_TIMEOUT );
        CHECK( DuplicateHandle( GetCurrentProcess(), s, GetCurrentProcess(), &d, 0, FALSE, DUPLICATE_SAME_ACCESS ) );
        CloseHandle( s );
        CHECK( ReleaseSemaphore( d, 1, NULL ) && WaitForSingleObject( d, 0 ) == WAIT_OBJECT_0 );   /* the duplicate is the same object */
        CHECK( ReleaseMutex( m ) );
        CloseHandle( e ); CloseHandle( d ); CloseHandle( m );
    }
    if (!ok && !detail[0]) snprintf( detail, sizeof(detail), "round %d", i );
    result( "create and close", ok );
}

static void test_thread_churn(void)
{
    BOOL ok = TRUE;
    HANDLE files[4], e = CreateEventW( NULL, FALSE, FALSE, NULL ), batch[50];
    char path[MAX_PATH], tmp[MAX_PATH], buf[32];
    DWORD n;
    int i, j;

    GetTempPathA( sizeof(tmp), tmp );
    for (i = 0; i < 4; i++)
    {
        snprintf( path, sizeof(path), "%ssync_test_%lu_%d.tmp", tmp, GetCurrentProcessId(), i );
        files[i] = CreateFileA( path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_FLAG_DELETE_ON_CLOSE, NULL );
        CHECK( files[i] != INVALID_HANDLE_VALUE );
        snprintf( buf, sizeof(buf), "file number %d", i );
        CHECK( WriteFile( files[i], buf, strlen( buf ), &n, NULL ) );
    }
    /* each of these threads waits alertably and ends; ending must not close anything that is
     * not the thread's own */
    for (i = 0; i < 40 && ok; i++)
    {
        for (j = 0; j < 50; j++) batch[j] = CreateThread( NULL, 0x10000, short_alertable, e, 0, NULL );
        for (j = 0; j < 50; j++) { CHECK( batch[j] != NULL ); WaitForSingleObject( batch[j], INFINITE ); CloseHandle( batch[j] ); }
    }
    for (i = 0; i < 4; i++)
    {
        char expect[32];
        snprintf( expect, sizeof(expect), "file number %d", i );
        memset( buf, 0, sizeof(buf) );
        CHECK( SetFilePointer( files[i], 0, NULL, FILE_BEGIN ) == 0 );
        CHECK( ReadFile( files[i], buf, sizeof(buf) - 1, &n, NULL ) && !strcmp( buf, expect ) );
        CloseHandle( files[i] );
    }
    CHECK( SetEvent( e ) && WaitForSingleObject( e, 0 ) == WAIT_OBJECT_0 );
    CloseHandle( e );
    result( "threads that wait and end", ok );
}

static LONG bodies_run;
static DWORD CALLBACK count_and_end( void *arg )
{
    InterlockedIncrement( &bodies_run );
    return 0;
}

static void test_thread_overlap(void)
{
    BOOL ok = TRUE;
    HANDLE batch[50];
    const int rounds = 200;
    int i, j;

    /* fifty at a time, and each ends at once: later ones of a batch start while earlier ones end */
    for (i = 0; i < rounds && ok; i++)
    {
        for (j = 0; j < 50; j++) batch[j] = CreateThread( NULL, 0x10000, count_and_end, NULL, 0, NULL );
        for (j = 0; j < 50; j++)
        {
            if (!batch[j] || (ok && WaitForSingleObject( batch[j], 10000 ) != WAIT_OBJECT_0))
            {
                if (ok) snprintf( detail, sizeof(detail), "thread %d of round %d did not end, %ld of %d ran",
                                  j, i, bodies_run, i * 50 + 50 );
                ok = FALSE;
            }
            if (batch[j]) CloseHandle( batch[j] );
        }
    }
    CHECK( bodies_run == rounds * 50 );
    result( "threads that start while others end", ok );
}

static void test_suspend(void)
{
    BOOL ok = TRUE;
    HANDLE h[2] = { CreateEventW( NULL, FALSE, FALSE, NULL ), CreateEventW( NULL, FALSE, FALSE, NULL ) }, t;

    t = CreateThread( NULL, 0, wait_then_flag, h, 0, NULL );
    Sleep( 40 );
    CHECK( SuspendThread( t ) == 0 );
    SetEvent( h[0] );
    CHECK( WaitForSingleObject( h[1], 100 ) == WAIT_TIMEOUT );   /* it is suspended: it cannot go on */
    CHECK( ResumeThread( t ) == 1 );
    CHECK( WaitForSingleObject( h[1], 5000 ) == WAIT_OBJECT_0 );
    CHECK( WaitForSingleObject( t, 5000 ) == WAIT_OBJECT_0 );
    CloseHandle( t ); CloseHandle( h[0] ); CloseHandle( h[1] );
    result( "suspended across a wait", ok );
}

int main( int argc, char **argv )
{
    if (argc > 1) return child_main( argc, argv );

    test_events();
    test_semaphores();
    test_mutexes();
    test_wait_any();
    test_wait_all();
    test_timeouts();
    test_apcs();
    test_server_objects();
    test_two_processes();
    test_workers();
    test_workers_own_events();
    test_churn();
    test_thread_churn();
    test_thread_overlap();
    test_suspend();
    printf( "sync test: %d/%d passed\n", passed, groups );
    fflush( stdout );
    return passed == groups ? 0 : 1;
}
