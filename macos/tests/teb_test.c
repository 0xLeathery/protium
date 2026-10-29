/*
 * Checks that NtCurrentTeb() stays correct in Windows ARM64 code on the native arm64 macOS Wine
 * build. The TEB is in x18, as on Windows; the macOS kernel only preserves x18 on threads that
 * opted into Apple's custom x18 ABI.
 *
 * Built with the build's own winegcc for aarch64-windows against Wine's CRT (see
 * check-wave3a.sh). Built with -DWINE_TEB_TSD_SLOT=N, it checks the Wave 2b TSD slot instead of x18.
 *
 * On the main thread, on threads created with CreateThread and on thread pool workers created by
 * Wine, while they spin, Sleep, yield, wait and make syscalls, and inside and after handled
 * exceptions (a raised software exception and a hardware access violation), every check compares
 *  - NtCurrentTeb() with the TEB address the kernel side reports (NtQueryInformationThread),
 *  - Tib.Self with the TEB itself,
 *  - ClientId with the thread and process ids the kernel side reports and GetCurrentThreadId(),
 *  - the raw x18 register (or, with WINE_TEB_TSD_SLOT, the raw TSD slot) with the TEB.
 * Prints "teb_test: PASS" and exits 0 if everything matched.
 */
#include <stdarg.h>
#include <stdio.h>
#include <windef.h>
#include <winbase.h>
#include <winternl.h>

#define NUM_THREADS   8
#define NUM_POOL_WORK 16
#define ITERATIONS    3000

static LONG checks, failures, handler_calls, pool_done;
static volatile ULONG_PTR bad_address = 0x10;
static HANDLE wait_event, pool_event;
static DWORD handler_tls;  /* per-thread count of handler calls (no compiler TLS: it would read x18) */

static void failure( const char *where, const char *what, const void *got, const void *want )
{
    InterlockedIncrement( &failures );
    printf( "FAIL %s (thread %04lx): %s: got %p, want %p\n", where, GetCurrentThreadId(), what, got, want );
    fflush( stdout );
}

#ifdef WINE_TEB_TSD_SLOT
/* read the slot directly, as the PE code compiled for macOS does it */
static TEB *slot_teb( void )
{
    TEB *teb;
    __asm__ volatile( "mrs %0, tpidrro_el0\n\t"
                      "and %0, %0, #0xfffffffffffffff8\n\t"
                      "ldr %0, [%0, %1]"
                      : "=&r" (teb) : "i" (WINE_TEB_TSD_SLOT * 8) );
    return teb;
}
#else
/* read x18 itself, not through the compiler's NtCurrentTeb() */
static TEB *raw_x18( void )
{
    TEB *teb;
    __asm__ volatile( "mov %0, x18" : "=r" (teb) );
    return teb;
}
#endif

static void check_teb( const char *where )
{
    THREAD_BASIC_INFORMATION info;
    TEB *teb = NtCurrentTeb();
    NTSTATUS status;

    InterlockedIncrement( &checks );
    status = NtQueryInformationThread( GetCurrentThread(), ThreadBasicInformation, &info, sizeof(info), NULL );
    if (status) { failure( where, "NtQueryInformationThread status", ULongToPtr( status ), NULL ); return; }
    if (teb != info.TebBaseAddress) failure( where, "NtCurrentTeb() vs TebBaseAddress", teb, info.TebBaseAddress );
    if (teb->Tib.Self != &teb->Tib) failure( where, "Tib.Self", teb->Tib.Self, &teb->Tib );
    if (teb->ClientId.UniqueThread != info.ClientId.UniqueThread)
        failure( where, "ClientId.UniqueThread", teb->ClientId.UniqueThread, info.ClientId.UniqueThread );
    if (teb->ClientId.UniqueProcess != info.ClientId.UniqueProcess)
        failure( where, "ClientId.UniqueProcess", teb->ClientId.UniqueProcess, info.ClientId.UniqueProcess );
    if (HandleToULong( info.ClientId.UniqueThread ) != GetCurrentThreadId())
        failure( where, "GetCurrentThreadId()", ULongToPtr( GetCurrentThreadId() ), info.ClientId.UniqueThread );
#ifdef WINE_TEB_TSD_SLOT
    if (slot_teb() != teb) failure( where, "TSD slot", slot_teb(), teb );
#else
    if (raw_x18() != info.TebBaseAddress) failure( where, "raw x18", raw_x18(), info.TebBaseAddress );
#endif
}

static LONG CALLBACK handler( EXCEPTION_POINTERS *ptrs )
{
    EXCEPTION_RECORD *rec = ptrs->ExceptionRecord;

    InterlockedIncrement( &handler_calls );
    TlsSetValue( handler_tls, (char *)TlsGetValue( handler_tls ) + 1 );
    check_teb( "exception handler" );
    if (rec->ExceptionCode == 0xe0000001) return EXCEPTION_CONTINUE_EXECUTION;
    if (rec->ExceptionCode == EXCEPTION_ACCESS_VIOLATION &&
        rec->ExceptionInformation[1] == bad_address)
    {
        ptrs->ContextRecord->Pc += 4;  /* skip the faulting store */
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static void exceptions( const char *where )
{
    ULONG_PTR before = (ULONG_PTR)TlsGetValue( handler_tls );

    RaiseException( 0xe0000001, 0, 0, NULL );
    check_teb( where );
    *(volatile int *)bad_address = 1;  /* hardware fault: through the Unix signal handler */
    check_teb( where );
    if ((ULONG_PTR)TlsGetValue( handler_tls ) != before + 2)
        failure( where, "exception handler calls on this thread",
                 (void *)((ULONG_PTR)TlsGetValue( handler_tls ) - before), ULongToPtr( 2 ) );
}

static void work( const char *where, unsigned int index )
{
    for (unsigned int i = 0; i < ITERATIONS; i++)
    {
        volatile unsigned int spin = 2000 + (index * 997 + i * 131) % 4000;
        while (spin--) ;                                            /* preemption */
        switch (i % 6)
        {
        case 0: Sleep( 0 ); break;
        case 1: if (i % 60 == 1) Sleep( 1 ); break;
        case 2: SwitchToThread(); break;
        case 3: if (i % 30 == 3) WaitForSingleObject( wait_event, 1 ); break;
        case 4: NtYieldExecution(); break;
        case 5: if (i % 500 == 5) exceptions( where ); break;
        }
        check_teb( where );
    }
}

static DWORD WINAPI thread_proc( void *arg )
{
    unsigned int index = PtrToUlong( arg );

    check_teb( "CreateThread thread start" );
    work( "CreateThread thread", index );
    printf( "thread %04lx (CreateThread %u): teb %p ok\n", GetCurrentThreadId(), index, NtCurrentTeb() );
    fflush( stdout );
    return 0;
}

static void CALLBACK pool_callback( TP_CALLBACK_INSTANCE *instance, void *arg )
{
    check_teb( "thread pool worker" );
    exceptions( "thread pool worker" );
    for (unsigned int i = 0; i < 200; i++) { Sleep( 0 ); check_teb( "thread pool worker" ); }
    printf( "thread %04lx (thread pool work %lu): teb %p ok\n", GetCurrentThreadId(), PtrToUlong( arg ), NtCurrentTeb() );
    fflush( stdout );
    if (InterlockedIncrement( &pool_done ) == NUM_POOL_WORK) SetEvent( pool_event );
}

int main( void )
{
    HANDLE threads[NUM_THREADS];
    unsigned int i;

#ifdef WINE_TEB_TSD_SLOT
    printf( "teb_test: TEB read from TSD slot %u (TPIDRRO_EL0 + %#x)\n", WINE_TEB_TSD_SLOT, WINE_TEB_TSD_SLOT * 8 );
#else
    printf( "teb_test: built without WINE_TEB_TSD_SLOT, TEB read from x18\n" );
#endif
    fflush( stdout );

    handler_tls = TlsAlloc();
    wait_event = CreateEventW( NULL, TRUE, FALSE, NULL );
    pool_event = CreateEventW( NULL, TRUE, FALSE, NULL );
    AddVectoredExceptionHandler( 1, handler );

    check_teb( "main thread" );
    exceptions( "main thread" );

    for (i = 0; i < NUM_THREADS; i++)
        threads[i] = CreateThread( NULL, 0, thread_proc, ULongToPtr( i ), 0, NULL );
    for (i = 0; i < NUM_POOL_WORK; i++)
        if (!TrySubmitThreadpoolCallback( pool_callback, ULongToPtr( i ), NULL ))
            failure( "main thread", "TrySubmitThreadpoolCallback", NULL, ULongToPtr( 1 ) );

    work( "main thread", NUM_THREADS );
    printf( "thread %04lx (main): teb %p ok\n", GetCurrentThreadId(), NtCurrentTeb() );

    WaitForMultipleObjects( NUM_THREADS, threads, TRUE, INFINITE );
    if (WaitForSingleObject( pool_event, 60000 )) failure( "main thread", "thread pool work timed out", NULL, NULL );
    check_teb( "main thread end" );

    printf( "teb_test: %ld checks, %ld exception handler calls, %ld failures\n", checks, handler_calls, failures );
    printf( "teb_test: %s\n", failures ? "FAIL" : "PASS" );
    fflush( stdout );
    return failures ? 1 : 0;
}
