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
 *  e  code in a PAGE_EXECUTE_READWRITE page stores into that page (plain stores, a store pair and a
 *     load-exclusive/store-exclusive increment), many rounds.
 *  f  a PAGE_EXECUTE_READ code page stores into a PAGE_READWRITE data page of the same 16K host
 *     page (as at an image's .text/.data boundary): plain stores and an exclusive increment.
 *  g  code in the program's own .text, made PAGE_EXECUTE_READWRITE, patches a function in the same
 *     host page, which then returns the patched value.
 *  h  a registry query (NtQueryValueKey, the server's reply) into an executed RWX buffer.
 *  i  NtWriteVirtualMemory/WriteProcessMemory into an executed RWX page of this process and of a
 *     child process, which then runs the new code; writes into a read-only page still fail.
 *  j  4 threads increment one counter with the exclusive code of part f (code and counter in one
 *     host page) while 4 threads run store code into their own words of that page: no increment is
 *     lost and nothing spins.
 *  k  a lone store-exclusive (no retry loop) into its own page: Wine can't run it elsewhere and
 *     raises an access violation at it instead of spinning.
 * The parts to run can be given on the command line ("wx_test ef"); the default is all of them.
 * Any exception that reaches the program (an access violation that Wine did not handle as a page
 * flip) is reported and fails the test. Prints "wx_test: PASS" and exits 0 if everything worked.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <windef.h>
#include <winbase.h>
#include <winternl.h>

#define NUM_THREADS   8
#define THREAD_MSECS  2500

static LONG failures, stop_threads;
static BYTE *shared_code;
static const char *parts = "abcdefghijk";
static void *expect_av_at;     /* part k: an access violation expected at this address */
static LONG expected_avs;

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

    if (expect_av_at && rec->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && rec->ExceptionAddress == expect_av_at)
    {
        InterlockedIncrement( &expected_avs );
        ptrs->ContextRecord->Pc += 4;  /* skip the store */
        return EXCEPTION_CONTINUE_EXECUTION;
    }

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

/* code at ptr that stores 1 at ptr + off with str, 2 and 3 at ptr + off + 4 with stp, and returns 5 */
static void write_store_code( BYTE *ptr, unsigned int off )
{
    DWORD *code = (DWORD *)ptr;

    code[0] = 0x10000001 | ((off & 3) << 29) | ((off >> 2) << 5);  /* adr x1, #off */
    code[1] = 0x52800022;  /* mov w2, #1 */
    code[2] = 0xb9000022;  /* str w2, [x1] */
    code[3] = 0x52800042;  /* mov w2, #2 */
    code[4] = 0x52800063;  /* mov w3, #3 */
    code[5] = 0x29008c22;  /* stp w2, w3, [x1, #4] */
    code[6] = 0x528000a0;  /* mov w0, #5 */
    code[7] = 0xd65f03c0;  /* ret */
    FlushInstructionCache( GetCurrentProcess(), ptr, 32 );
}

/* code at ptr that increments the word at ptr + off with ldaxr/stlxr and returns the new value */
static void write_exclusive_code( BYTE *ptr, unsigned int off )
{
    DWORD *code = (DWORD *)ptr;

    code[0] = 0x10000001 | ((off & 3) << 29) | ((off >> 2) << 5);  /* adr x1, #off */
    code[1] = 0x885ffc22;  /* 1: ldaxr w2, [x1] */
    code[2] = 0x11000442;  /* add w2, w2, #1 */
    code[3] = 0x8803fc22;  /* stlxr w3, w2, [x1] */
    code[4] = 0x35ffffa3;  /* cbnz w3, 1b */
    code[5] = 0x2a0203e0;  /* mov w0, w2 */
    code[6] = 0xd65f03c0;  /* ret */
    FlushInstructionCache( GetCurrentProcess(), ptr, 28 );
}

static void check_stores( const char *part, BYTE *code, BYTE *target, unsigned int rounds )
{
    unsigned int round;
    int ret;

    for (round = 0; round < rounds; round++)
    {
        memset( target, 0, 12 );
        if ((ret = run_code( code )) != 5) failure( part, "round %u: store code returned %d", round, ret );
        if (((DWORD *)target)[0] != 1 || ((DWORD *)target)[1] != 2 || ((DWORD *)target)[2] != 3)
            failure( part, "round %u: stored %lu %lu %lu, want 1 2 3", round,
                     ((DWORD *)target)[0], ((DWORD *)target)[1], ((DWORD *)target)[2] );
    }
}

static void check_exclusive( const char *part, BYTE *code, BYTE *target, unsigned int rounds )
{
    unsigned int round;
    int ret;

    *(DWORD *)target = 0;
    for (round = 1; round <= rounds; round++)
        if ((ret = run_code( code )) != (int)round) failure( part, "exclusive increment %u returned %d", round, ret );
    if (*(DWORD *)target != rounds) failure( part, "counter %lu, want %u", *(DWORD *)target, rounds );
}

static void test_store_same_page( void )
{
    BYTE *page = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );

    if (!page) { failure( "e", "VirtualAlloc failed %lu", GetLastError() ); return; }
    write_store_code( page, 0x800 );
    check_stores( "e", page, page + 0x800, 100 );
    write_exclusive_code( page + 0x100, 0x700 );
    check_exclusive( "e", page + 0x100, page + 0x800, 100 );
    check_protect( "e", page, PAGE_EXECUTE_READWRITE );
    printf( "e: code at %p stored into its own PAGE_EXECUTE_READWRITE page: 100 store rounds, 100 exclusive increments\n", page );
    VirtualFree( page, 0, MEM_RELEASE );
}

static void test_store_mixed_host_page( void )
{
    BYTE *base = VirtualAlloc( NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    DWORD old;

    if (!base) { failure( "f", "VirtualAlloc failed %lu", GetLastError() ); return; }
    write_store_code( base, 0x1000 );
    write_exclusive_code( base + 0x100, 0x1f00 );  /* base + 0x2000 */
    if (!VirtualProtect( base, 0x1000, PAGE_EXECUTE_READ, &old ))
        failure( "f", "VirtualProtect(PAGE_EXECUTE_READ) failed %lu", GetLastError() );
    check_protect( "f", base, PAGE_EXECUTE_READ );
    check_protect( "f", base + 0x1000, PAGE_READWRITE );
    check_stores( "f", base, base + 0x1000, 100 );
    check_exclusive( "f", base + 0x100, base + 0x2000, 100 );
    printf( "f: PAGE_EXECUTE_READ code at %p stored into the PAGE_READWRITE pages at %p and %p: "
            "100 store rounds, 100 exclusive increments\n", base, base + 0x1000, base + 0x2000 );
    VirtualFree( base, 0, MEM_RELEASE );
}

/* the patcher and the function it patches, next to each other in .text */
static __attribute__((noinline, section(".text$wxg"))) int patch_target( void )
{
    return 1;
}

static __attribute__((noinline, section(".text$wxg"))) void patch_function( volatile DWORD *code, unsigned int value )
{
    code[0] = 0x52800000 | ((value & 0xffff) << 5);  /* mov w0, #value */
    code[1] = 0xd65f03c0;                             /* ret */
}

static void test_hotpatch( void )
{
    int (*volatile target)(void) = patch_target;
    BYTE *code = (BYTE *)patch_target;
    DWORD old, old2;
    unsigned int i;
    int ret;

    if (((ULONG_PTR)code & ~0x3fff) != ((ULONG_PTR)patch_function & ~0x3fff))
    {
        failure( "g", "patch_target %p and patch_function %p are not in one 16K page", code, patch_function );
        return;
    }
    if (!VirtualProtect( code, 8, PAGE_EXECUTE_READWRITE, &old ))
    {
        failure( "g", "VirtualProtect(PAGE_EXECUTE_READWRITE) failed %lu", GetLastError() );
        return;
    }
    for (i = 0; i < 20; i++)
    {
        patch_function( (volatile DWORD *)code, 7 + i );
        FlushInstructionCache( GetCurrentProcess(), code, 8 );
        if ((ret = target()) != (int)(7 + i)) failure( "g", "patched function returned %d, want %u", ret, 7 + i );
    }
    if (!VirtualProtect( code, 8, old, &old2 )) failure( "g", "VirtualProtect back failed %lu", GetLastError() );
    if ((ret = target()) != 26) failure( "g", "after restoring %#lx: returned %d, want 26", old, ret );
    printf( "g: patch_function %p patched patch_target %p in the same host page of .text (protection %#lx): 20 rounds\n",
            patch_function, code, old );
}

static void test_reply_buffer( void )
{
    static const WCHAR value[] = L"server reply into executed code";
    BYTE *page = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    KEY_VALUE_PARTIAL_INFORMATION *info = (KEY_VALUE_PARTIAL_INFORMATION *)(page + 0x100);
    UNICODE_STRING name, key_name;
    OBJECT_ATTRIBUTES attr;
    HANDLE root, key;
    NTSTATUS status;
    ULONG len = 0;
    int ret;

    if (!page) { failure( "h", "VirtualAlloc failed %lu", GetLastError() ); return; }
    RtlInitUnicodeString( &key_name, L"Software\\Wine\\wx_test" );
    RtlInitUnicodeString( &name, L"v" );
    if ((status = RtlOpenCurrentUser( KEY_ALL_ACCESS, &root )))
    {
        failure( "h", "RtlOpenCurrentUser failed %08lx", status );
        return;
    }
    InitializeObjectAttributes( &attr, &key_name, 0, root, NULL );
    if ((status = NtCreateKey( &key, KEY_ALL_ACCESS, &attr, 0, NULL, 0, NULL )))
    {
        failure( "h", "NtCreateKey failed %08lx", status );
        NtClose( root );
        return;
    }
    NtSetValueKey( key, &name, 0, REG_SZ, (void *)value, sizeof(value) );
    write_code( page, 21 );
    if ((ret = run_code( page )) != 21) failure( "h", "code returned %d", ret );  /* the page is executable now */
    status = NtQueryValueKey( key, &name, KeyValuePartialInformation, info, 0x200, &len );
    if (status) failure( "h", "NtQueryValueKey into the executed page: status %08lx", status );
    else if (info->DataLength != sizeof(value) || memcmp( info->Data, value, sizeof(value) ))
        failure( "h", "NtQueryValueKey returned the wrong data (%lu bytes)", info->DataLength );
    if ((ret = run_code( page )) != 21) failure( "h", "code returned %d after the query", ret );
    NtDeleteKey( key );
    NtClose( key );
    NtClose( root );
    printf( "h: NtQueryValueKey into executed PAGE_EXECUTE_READWRITE page %p: status %08lx, %lu bytes\n", page, status, len );
    VirtualFree( page, 0, MEM_RELEASE );
}

#define CONC_THREADS 8
#define CONC_ROUNDS  2000
static BYTE *conc_base;

static DWORD WINAPI conc_thread( void *arg )
{
    unsigned int index = PtrToUlong( arg ), i;
    BYTE *code = conc_base + 0x200 + 0x40 * index;
    BYTE *data = conc_base + 0x1000 + 0x40 * index;
    int ret;

    for (i = 0; i < CONC_ROUNDS; i++)
    {
        if (index & 1) run_code( conc_base + 0x100 );  /* exclusive increment of the shared counter */
        else if ((ret = run_code( code )) != 5 || ((DWORD *)data)[0] != 1)
        {
            failure( "j", "thread %u round %u: store code returned %d, stored %lu", index, i, ret, ((DWORD *)data)[0] );
            break;
        }
    }
    return 0;
}

static void test_concurrent_displaced( void )
{
    HANDLE threads[CONC_THREADS];
    DWORD start, elapsed, old;
    unsigned int i;

    if (!(conc_base = VirtualAlloc( NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE )))
    {
        failure( "j", "VirtualAlloc failed %lu", GetLastError() );
        return;
    }
    write_exclusive_code( conc_base + 0x100, 0x1f00 );  /* the counter at conc_base + 0x2000 */
    for (i = 0; i < CONC_THREADS; i += 2)
        write_store_code( conc_base + 0x200 + 0x40 * i, 0xe00 );  /* into conc_base + 0x1000 + 0x40 * i */
    VirtualProtect( conc_base, 0x1000, PAGE_EXECUTE_READ, &old );
    start = GetTickCount();
    for (i = 0; i < CONC_THREADS; i++) threads[i] = CreateThread( NULL, 0, conc_thread, ULongToPtr( i ), 0, NULL );
    if (WaitForMultipleObjects( CONC_THREADS, threads, TRUE, 60000 ))
        failure( "j", "threads didn't finish in 60 s" );
    elapsed = GetTickCount() - start;
    for (i = 0; i < CONC_THREADS; i++) CloseHandle( threads[i] );
    if (*(DWORD *)(conc_base + 0x2000) != CONC_THREADS / 2 * CONC_ROUNDS)
        failure( "j", "counter %lu, want %u", *(DWORD *)(conc_base + 0x2000), CONC_THREADS / 2 * CONC_ROUNDS );
    printf( "j: %u threads: %u exclusive increments (counter %lu) and %u same-page store rounds in %lu ms\n",
            CONC_THREADS, CONC_THREADS / 2 * CONC_ROUNDS, *(DWORD *)(conc_base + 0x2000),
            CONC_THREADS / 2 * CONC_ROUNDS, elapsed );
    VirtualFree( conc_base, 0, MEM_RELEASE );
}

static void test_refused_store( void )
{
    BYTE *page = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    DWORD *code = (DWORD *)page;
    int ret;

    if (!page) { failure( "k", "VirtualAlloc failed %lu", GetLastError() ); return; }
    code[0] = 0x10000001 | ((0x800 >> 2) << 5);  /* adr x1, #0x800 */
    code[1] = 0x885ffc22;  /* ldaxr w2, [x1] */
    code[2] = 0x11000442;  /* add w2, w2, #1 */
    code[3] = 0x52800043;  /* mov w3, #2 */
    code[4] = 0x8803fc22;  /* stlxr w3, w2, [x1] (no retry loop) */
    code[5] = 0x2a0303e0;  /* mov w0, w3 */
    code[6] = 0xd65f03c0;  /* ret */
    FlushInstructionCache( GetCurrentProcess(), page, 28 );
    expect_av_at = page + 16;
    ret = run_code( page );
    expect_av_at = NULL;
    if (expected_avs != 1) failure( "k", "%ld access violations at the lone store-exclusive, want 1", expected_avs );
    if (ret != 2) failure( "k", "returned %d, want 2 (the skipped store-exclusive left w3 alone)", ret );
    printf( "k: lone store-exclusive at %p into its own page: %ld access violation, returned %d\n", page + 16, expected_avs, ret );
    VirtualFree( page, 0, MEM_RELEASE );
}

/* child of part i: runs code in an RWX page, reports it, then runs it again once the parent rewrote it */
static int child_main( const char *event_name )
{
    BYTE *page = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    BYTE *ro = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    HANDLE event = OpenEventA( SYNCHRONIZE, FALSE, event_name );
    DWORD old;
    int ret;

    if (!page || !ro || !event) return 100;
    write_code( page, 1 );
    if ((ret = run_code( page )) != 1) return 101;  /* the page is executable now */
    memset( ro, 0x5a, 16 );
    VirtualProtect( ro, 0x1000, PAGE_READONLY, &old );
    printf( "child %p %p\n", page, ro );
    fflush( stdout );
    if (WaitForSingleObject( event, 60000 )) return 102;
    if (ro[0] != 0x5a) return 103;  /* the read-only page was written */
    return run_code( page );  /* the parent wrote "return 2" */
}

static void test_write_process_memory( void )
{
    DWORD code[2] = { 0x52800000 | (77 << 5), 0xd65f03c0 }, child_code[2] = { 0x52800000 | (2 << 5), 0xd65f03c0 };
    BYTE *page = VirtualAlloc( NULL, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    char exe[MAX_PATH], cmdline[MAX_PATH + 64], event_name[64], line[128] = "", *p = line;
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    PROCESS_INFORMATION pi;
    STARTUPINFOA si = { sizeof(si) };
    void *child_page = NULL, *child_ro = NULL;
    HANDLE read_pipe, write_pipe, event;
    DWORD exit_code = 0, n;
    NTSTATUS status;
    SIZE_T written;
    int ret;

    /* this process */
    if (!page) { failure( "i", "VirtualAlloc failed %lu", GetLastError() ); return; }
    write_code( page, 11 );
    if ((ret = run_code( page )) != 11) failure( "i", "code returned %d", ret );
    status = NtWriteVirtualMemory( GetCurrentProcess(), page, code, sizeof(code), &written );
    if (status) failure( "i", "NtWriteVirtualMemory into this process's executed page: status %08lx", status );
    FlushInstructionCache( GetCurrentProcess(), page, 8 );
    if ((ret = run_code( page )) != 77) failure( "i", "after NtWriteVirtualMemory: returned %d, want 77", ret );
    write_code( page, 11 );
    run_code( page );
    if (!WriteProcessMemory( GetCurrentProcess(), page, code, sizeof(code), &written ))
        failure( "i", "WriteProcessMemory into this process's executed page failed %lu", GetLastError() );
    FlushInstructionCache( GetCurrentProcess(), page, 8 );
    if ((ret = run_code( page )) != 77) failure( "i", "after WriteProcessMemory: returned %d, want 77", ret );

    /* a child process */
    sprintf( event_name, "wx_test_go_%lu", GetCurrentProcessId() );
    event = CreateEventA( NULL, TRUE, FALSE, event_name );
    CreatePipe( &read_pipe, &write_pipe, &sa, 0 );
    SetHandleInformation( read_pipe, HANDLE_FLAG_INHERIT, 0 );
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = write_pipe;
    si.hStdError = GetStdHandle( STD_ERROR_HANDLE );
    GetModuleFileNameA( NULL, exe, sizeof(exe) );
    sprintf( cmdline, "\"%s\" child %s", exe, event_name );
    if (!CreateProcessA( exe, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi ))
    {
        failure( "i", "CreateProcess failed %lu", GetLastError() );
        return;
    }
    CloseHandle( write_pipe );
    while (p < line + sizeof(line) - 1 && ReadFile( read_pipe, p, 1, &n, NULL ) && n && *p != '\n') p++;
    *p = 0;
    if (sscanf( line, "child %p %p", &child_page, &child_ro ) != 2) failure( "i", "child said '%s'", line );
    else
    {
        if (!WriteProcessMemory( pi.hProcess, child_page, child_code, sizeof(child_code), &written ))
            failure( "i", "WriteProcessMemory into the child's executed page %p failed %lu", child_page, GetLastError() );
        FlushInstructionCache( pi.hProcess, child_page, 8 );
        status = NtWriteVirtualMemory( pi.hProcess, child_ro, code, sizeof(code), &written );
        if (!status) failure( "i", "NtWriteVirtualMemory into the child's read-only page succeeded" );
    }
    SetEvent( event );
    if (WaitForSingleObject( pi.hProcess, 60000 )) failure( "i", "child timed out" );
    GetExitCodeProcess( pi.hProcess, &exit_code );
    if (exit_code != 2) failure( "i", "child exited with %lu, want 2 (the code written into it)", exit_code );
    printf( "i: wrote code into executed RWX pages of this process (%p) and of a child (%p, which then returned %lu); "
            "read-only page: status %08lx\n", page, child_page, exit_code, status );
    CloseHandle( pi.hProcess );
    CloseHandle( pi.hThread );
    CloseHandle( read_pipe );
    CloseHandle( event );
    VirtualFree( page, 0, MEM_RELEASE );
}

int main( int argc, char **argv )
{
    if (argc > 2 && !strcmp( argv[1], "child" )) return child_main( argv[2] );
    if (argc > 1) parts = argv[1];
    AddVectoredExceptionHandler( 1, handler );
    if (strchr( parts, 'a' )) test_rewrite();
    if (strchr( parts, 'b' )) test_mixed_host_page();
    if (strchr( parts, 'c' )) test_threads();
    if (strchr( parts, 'd' )) test_exec_heap();
    if (strchr( parts, 'e' )) test_store_same_page();
    if (strchr( parts, 'f' )) test_store_mixed_host_page();
    if (strchr( parts, 'g' )) test_hotpatch();
    if (strchr( parts, 'h' )) test_reply_buffer();
    if (strchr( parts, 'i' )) test_write_process_memory();
    if (strchr( parts, 'j' )) test_concurrent_displaced();
    if (strchr( parts, 'k' )) test_refused_store();
    printf( "wx_test: %ld failures\n", failures );
    printf( "wx_test: %s\n", failures ? "FAIL" : "PASS" );
    fflush( stdout );
    return failures ? 1 : 0;
}
