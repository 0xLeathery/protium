/*
 * Checks that memory which is both writable and executable in Windows terms works in Windows
 * ARM64 code on the native arm64 macOS Wine build. macOS refuses mappings that are writable and
 * executable at once, so Wine maps such pages either writable or executable and flips them on
 * write and execute faults.
 *
 * Built with the build's own winegcc for aarch64-windows against Wine's CRT (see check-wave3a.sh).
 *
 *  a  VirtualAlloc(PAGE_EXECUTE_READWRITE): write "mov w0, #42; ret", flush, call it; rewrite it to
 *     return 43, flush, call it; ten rounds.
 *  b  two 4K Windows pages in one 16K host page, one PAGE_EXECUTE_READWRITE code page and one
 *     PAGE_READWRITE data page, written and executed alternately; VirtualQuery reports both
 *     protections unchanged.
 *  c  8 threads rewrite and run their own code on one shared page at the same time for at least
 *     2 seconds; every call returns what its thread just wrote.
 *  d  HeapCreate(HEAP_CREATE_ENABLE_EXECUTE): the heap exists, HeapAlloc works (small and large
 *     blocks), and code written into a block runs.
 * Any exception that reaches the program (an access violation that Wine did not handle as a page
 * flip) is reported and fails the test. Prints "wx_test: PASS" and exits 0 if everything worked.
 */
#include <stdarg.h>
#include <stdio.h>
#include <windef.h>
#include <winbase.h>
#include <winternl.h>

#define NUM_THREADS   8
#define THREAD_MSECS  2500

static LONG failures, stop_threads;
static BYTE *shared_code;

typedef int (*code_func)(void);

static void failure( const char *part, const char *fmt, ... )
{
    va_list args;

    InterlockedIncrement( &failures );
    printf( "FAIL %s (thread %04lx): ", part, GetCurrentThreadId() );
    va_start( args, fmt );
    vprintf( fmt, args );
    va_end( args );
    printf( "\n" );
    fflush( stdout );
}

/* "mov w0, #value; ret" */
static void write_code( BYTE *ptr, unsigned int value )
{
    volatile DWORD *code = (volatile DWORD *)ptr;

    code[0] = 0x52800000 | ((value & 0xffff) << 5);  /* movz w0, #value */
    code[1] = 0xd65f03c0;                             /* ret */
    FlushInstructionCache( GetCurrentProcess(), ptr, 8 );
}

static int run_code( BYTE *ptr )
{
    return ((code_func)ptr)();
}

static LONG CALLBACK handler( EXCEPTION_POINTERS *ptrs )
{
    EXCEPTION_RECORD *rec = ptrs->ExceptionRecord;

    printf( "FAIL exception (thread %04lx): code %08lx at %p, info %Ix %Ix\n", GetCurrentThreadId(),
            rec->ExceptionCode, rec->ExceptionAddress,
            rec->NumberParameters > 0 ? rec->ExceptionInformation[0] : 0,
            rec->NumberParameters > 1 ? rec->ExceptionInformation[1] : 0 );
    printf( "wx_test: FAIL\n" );
    fflush( stdout );
    ExitProcess( 3 );
    return EXCEPTION_CONTINUE_SEARCH;
}

static void check_protect( const char *part, void *ptr, DWORD want )
{
    MEMORY_BASIC_INFORMATION info;

    if (!VirtualQuery( ptr, &info, sizeof(info) )) failure( part, "VirtualQuery(%p) failed %lu", ptr, GetLastError() );
    else if (info.Protect != want || info.State != MEM_COMMIT)
        failure( part, "%p: protect %#lx state %#lx, want protect %#lx committed", ptr, info.Protect, info.State, want );
}

static void test_rewrite( void )
{
    BYTE *code = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    unsigned int round;
    int ret;

    if (!code) { failure( "a", "VirtualAlloc(PAGE_EXECUTE_READWRITE) failed %lu", GetLastError() ); return; }
    check_protect( "a", code, PAGE_EXECUTE_READWRITE );
    for (round = 0; round < 10; round++)
    {
        write_code( code, 42 );
        if ((ret = run_code( code )) != 42) failure( "a", "round %u: got %d, want 42", round, ret );
        write_code( code, 43 );
        if ((ret = run_code( code )) != 43) failure( "a", "round %u: got %d, want 43", round, ret );
    }
    check_protect( "a", code, PAGE_EXECUTE_READWRITE );
    printf( "a: PAGE_EXECUTE_READWRITE at %p: 10 rounds of write 42/run/write 43/run\n", code );
    VirtualFree( code, 0, MEM_RELEASE );
}

static void test_mixed_host_page( void )
{
    SYSTEM_INFO si;
    BYTE *base, *code, *data;
    unsigned int round;
    DWORD old;
    int ret;

    GetSystemInfo( &si );
    /* allocations are 64K aligned, so the first two 4K pages are in the same 16K host page */
    if (!(base = VirtualAlloc( NULL, 0x10000, MEM_RESERVE, PAGE_NOACCESS )))
    {
        failure( "b", "VirtualAlloc(MEM_RESERVE) failed %lu", GetLastError() );
        return;
    }
    code = base;
    data = base + 0x1000;
    if (!VirtualAlloc( code, 0x1000, MEM_COMMIT, PAGE_EXECUTE_READWRITE ) ||
        !VirtualAlloc( data, 0x1000, MEM_COMMIT, PAGE_READWRITE ))
    {
        failure( "b", "VirtualAlloc(MEM_COMMIT) failed %lu", GetLastError() );
        VirtualFree( base, 0, MEM_RELEASE );
        return;
    }
    for (round = 0; round < 50; round++)
    {
        write_code( code, 100 + round );
        ((volatile DWORD *)data)[round] = 0xda7a0000 + round;
        if ((ret = run_code( code )) != 100 + round) failure( "b", "round %u: code got %d, want %u", round, ret, 100 + round );
        ((volatile DWORD *)data)[512 + round] = round;
        if (((volatile DWORD *)data)[round] != 0xda7a0000 + round) failure( "b", "round %u: data lost", round );
        if ((ret = run_code( code )) != 100 + round) failure( "b", "round %u: second run got %d", round, ret );
    }
    for (round = 0; round < 50; round++)
        if (((DWORD *)data)[round] != 0xda7a0000 + round || ((DWORD *)data)[512 + round] != round)
            failure( "b", "data word %u changed", round );
    check_protect( "b", code, PAGE_EXECUTE_READWRITE );
    check_protect( "b", data, PAGE_READWRITE );
    /* a protection change on the data page keeps the code page working */
    if (!VirtualProtect( data, 0x1000, PAGE_READONLY, &old ) || old != PAGE_READWRITE)
        failure( "b", "VirtualProtect(data, PAGE_READONLY) failed %lu, old %#lx", GetLastError(), old );
    write_code( code, 7 );
    if ((ret = run_code( code )) != 7) failure( "b", "after VirtualProtect: got %d, want 7", ret );
    check_protect( "b", data, PAGE_READONLY );
    check_protect( "b", code, PAGE_EXECUTE_READWRITE );
    printf( "b: code page %p (PAGE_EXECUTE_READWRITE) and data page %p (PAGE_READWRITE) in one %lu-byte "
            "allocation unit: 50 rounds\n", code, data, si.dwAllocationGranularity );
    VirtualFree( base, 0, MEM_RELEASE );
}

static DWORD WINAPI thread_proc( void *arg )
{
    unsigned int index = PtrToUlong( arg ), iter = 0, value;
    BYTE *slot = shared_code + 16 + index * 64;  /* own slot; slot 0 is the common function */
    LONG count = 0;
    int ret;

    while (!stop_threads)
    {
        value = (index << 12) | (iter++ & 0xfff);
        write_code( slot, value );
        if ((ret = run_code( slot )) != (int)value)
        {
            failure( "c", "iteration %u: own code got %#x, want %#x", iter, ret, value );
            if (failures > 20) break;
        }
        if ((ret = run_code( shared_code )) != 7) failure( "c", "common code got %d, want 7", ret );
        count++;
    }
    return count;
}

static void test_threads( void )
{
    HANDLE threads[NUM_THREADS];
    DWORD start, elapsed, code;
    LONG total = 0;
    unsigned int i;

    if (!(shared_code = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE )))
    {
        failure( "c", "VirtualAlloc(PAGE_EXECUTE_READWRITE) failed %lu", GetLastError() );
        return;
    }
    write_code( shared_code, 7 );
    start = GetTickCount();
    for (i = 0; i < NUM_THREADS; i++) threads[i] = CreateThread( NULL, 0, thread_proc, ULongToPtr( i ), 0, NULL );
    Sleep( THREAD_MSECS );
    InterlockedExchange( &stop_threads, 1 );
    WaitForMultipleObjects( NUM_THREADS, threads, TRUE, INFINITE );
    elapsed = GetTickCount() - start;
    for (i = 0; i < NUM_THREADS; i++)
    {
        GetExitCodeThread( threads[i], &code );
        if (!code) failure( "c", "thread %u made no progress", i );
        total += code;
        CloseHandle( threads[i] );
    }
    printf( "c: %u threads rewrote and ran code on page %p for %lu ms: %ld write/run iterations\n",
            NUM_THREADS, shared_code, elapsed, total );
    if (elapsed < 2000) failure( "c", "ran for only %lu ms", elapsed );
    VirtualFree( shared_code, 0, MEM_RELEASE );
}

static void test_exec_heap( void )
{
    HANDLE heap = HeapCreate( HEAP_CREATE_ENABLE_EXECUTE, 0, 0 );
    BYTE *small, *large;
    unsigned int i;
    int ret;

    if (!heap) { failure( "d", "HeapCreate(HEAP_CREATE_ENABLE_EXECUTE) failed %lu", GetLastError() ); return; }
    if (!(small = HeapAlloc( heap, HEAP_ZERO_MEMORY, 64 ))) failure( "d", "HeapAlloc(64) failed" );
    if (!(large = HeapAlloc( heap, 0, 0x200000 ))) failure( "d", "HeapAlloc(2MB) failed" );
    if (small && large)
    {
        for (i = 0; i < 0x200000; i += 0x1000) large[i] = (BYTE)i;
        for (i = 0; i < 0x200000; i += 0x1000) if (large[i] != (BYTE)i) failure( "d", "large block byte %#x", i );
        write_code( small, 99 );
        if ((ret = run_code( small )) != 99) failure( "d", "code in a heap block got %d, want 99", ret );
        small[16] = 1;  /* write the block again after running it */
        if (!HeapFree( heap, 0, large )) failure( "d", "HeapFree failed" );
        if (!HeapFree( heap, 0, small )) failure( "d", "HeapFree failed" );
    }
    printf( "d: HeapCreate(HEAP_CREATE_ENABLE_EXECUTE) = %p, small block %p, large block %p\n", heap, small, large );
    if (!HeapDestroy( heap )) failure( "d", "HeapDestroy failed" );
}

int main( void )
{
    AddVectoredExceptionHandler( 1, handler );
    test_rewrite();
    test_mixed_host_page();
    test_threads();
    test_exec_heap();
    printf( "wx_test: %ld failures\n", failures );
    printf( "wx_test: %s\n", failures ? "FAIL" : "PASS" );
    fflush( stdout );
    return failures ? 1 : 0;
}
