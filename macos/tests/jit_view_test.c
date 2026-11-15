/*
 * Checks memory allocated with Wine's MEM_EXTENDED_PARAMETER_WINE_UNIX_JIT attribute on the
 * native arm64 macOS Wine build. Such a view is backed by MAP_JIT memory: writable or executable
 * per thread, switched by its owner (an x86 emulator's Unix library) with
 * pthread_jit_write_protect_np(). This program is Windows code and can't switch, so it only
 * sees the executable state: a write into such a page must raise an access violation, and Wine
 * says why on stderr. What it can check is that the pages follow their protection: mprotect()
 * fails on MAP_JIT memory, so Wine replaces pages that stop being exec+write with ordinary
 * memory and maps them MAP_JIT again later, keeping the contents both ways.
 *
 * Built with the build's own winegcc for aarch64-windows against Wine's CRT (see check-wave3b.sh).
 *
 *  a  the attribute is refused without MEM_COMMIT and with a protection other than
 *     PAGE_EXECUTE_READWRITE
 *  b  a 64K allocation with it: committed, PAGE_EXECUTE_READWRITE, reads as zero, a write raises
 *     an access violation at the address written
 *  c  one 16K host page made PAGE_READWRITE: writable; code and a pattern written to it are still
 *     there after it is made PAGE_EXECUTE_READWRITE again, the code runs, a write faults again,
 *     and the host pages next to it never became writable
 *  d  one 4K page of a host page made PAGE_READONLY and back: both protections are reported, the
 *     rest of the host page keeps its contents and a write to it still faults
 *  e  a host page decommitted and committed again: reads as zero, a write faults
 *  f  PAGE_GUARD on a host page: one guard page exception, then the contents of part c are
 *     still there and a write faults
 *  g  the allocation is released; ordinary PAGE_EXECUTE_READWRITE memory allocated afterwards
 *     can be written and run
 * Prints "jit_view_test: PASS" and exits 0 if everything worked. An exception that the part at
 * hand does not expect is reported and fails the test.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <ntstatus.h>
#define WIN32_NO_STATUS
#include <windef.h>
#include <winbase.h>
#include <winternl.h>

#define JIT_ATTRIBUTE 0x80000000  /* MEM_EXTENDED_PARAMETER_WINE_UNIX_JIT */
#define HOST_PAGE     0x4000
#define VIEW_SIZE     0x10000

static LONG failures;
/* shared with the exception handler, which the compiler does not see being called */
static volatile LONG av_count, guard_count;
static void * volatile last_av_addr;
static volatile ULONG_PTR last_av_kind;
static volatile BOOL expect_av;

typedef int (*code_func)(void);

static void failure( const char *part, const char *fmt, ... )
{
    va_list args;

    failures++;
    printf( "FAIL %s: ", part );
    va_start( args, fmt );
    vprintf( fmt, args );
    va_end( args );
    printf( "\n" );
    fflush( stdout );
}

/* a single store instruction followed by the return, so that the handler can step over it */
static DECLSPEC_NOINLINE void store_byte( volatile BYTE *ptr, BYTE value )
{
    *ptr = value;
}

static DECLSPEC_NOINLINE BYTE load_byte( volatile BYTE *ptr )
{
    return *ptr;
}

static LONG CALLBACK handler( EXCEPTION_POINTERS *ptrs )
{
    EXCEPTION_RECORD *rec = ptrs->ExceptionRecord;

    if (rec->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && expect_av)
    {
        av_count++;
        last_av_kind = rec->ExceptionInformation[0];
        last_av_addr = (void *)rec->ExceptionInformation[1];
        ptrs->ContextRecord->Pc += 4;  /* step over the store */
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (rec->ExceptionCode == STATUS_GUARD_PAGE_VIOLATION)
    {
        guard_count++;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    printf( "FAIL: unexpected exception %08lx at %p, info %p %p\n", (long)rec->ExceptionCode, rec->ExceptionAddress,
            (void *)rec->ExceptionInformation[0], (void *)rec->ExceptionInformation[1] );
    fflush( stdout );
    ExitProcess( 1 );
}

/* whether a write to ptr raises an access violation for a write at ptr */
static BOOL write_faults( BYTE *ptr )
{
    LONG before = av_count;

    last_av_addr = NULL;
    expect_av = TRUE;
    store_byte( ptr, 0x5a );
    expect_av = FALSE;
    return av_count == before + 1 && last_av_addr == ptr && last_av_kind == EXCEPTION_WRITE_FAULT;
}

static NTSTATUS alloc_jit( void **addr, SIZE_T size, ULONG type, ULONG protect )
{
    MEM_EXTENDED_PARAMETER param;

    memset( &param, 0, sizeof(param) );
    param.Type = MemExtendedParameterAttributeFlags;
    param.ULong64 = JIT_ATTRIBUTE;
    *addr = NULL;
    return NtAllocateVirtualMemoryEx( GetCurrentProcess(), addr, &size, type, protect, &param, 1 );
}

static DWORD query_protect( void *addr, DWORD *state )
{
    MEMORY_BASIC_INFORMATION info;

    memset( &info, 0, sizeof(info) );
    VirtualQuery( addr, &info, sizeof(info) );
    if (state) *state = info.State;
    return info.Protect;
}

/* "mov w0, #value; ret" */
static void write_code( BYTE *ptr, unsigned int value )
{
    volatile DWORD *code = (volatile DWORD *)ptr;

    code[0] = 0x52800000 | ((value & 0xffff) << 5);  /* movz w0, #value */
    code[1] = 0xd65f03c0;                             /* ret */
}

int main(void)
{
    BYTE *view, *page, *plain;
    NTSTATUS status;
    DWORD old, state;
    void *addr;
    unsigned int i, bad;
    int ret;

    AddVectoredExceptionHandler( 1, handler );

    /* a */
    status = alloc_jit( &addr, VIEW_SIZE, MEM_RESERVE, PAGE_EXECUTE_READWRITE );
    if (status != STATUS_INVALID_PARAMETER) failure( "a", "MEM_RESERVE alone: status %08lx", status );
    status = alloc_jit( &addr, VIEW_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    if (status != STATUS_INVALID_PARAMETER) failure( "a", "PAGE_READWRITE: status %08lx", status );

    /* b */
    status = alloc_jit( &addr, VIEW_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    if (status || !addr)
    {
        failure( "b", "allocation failed, status %08lx", status );
        printf( "jit_view_test: FAIL (%ld)\n", failures );
        return 1;
    }
    view = addr;
    if (query_protect( view, &state ) != PAGE_EXECUTE_READWRITE || state != MEM_COMMIT)
        failure( "b", "protection %lx state %lx", query_protect( view, NULL ), state );
    for (i = bad = 0; i < VIEW_SIZE; i += 0x1000) if (load_byte( view + i )) bad++;
    if (bad) failure( "b", "%u pages don't read as zero", bad );
    if (!write_faults( view )) failure( "b", "a write did not raise an access violation at %p (count %ld, at %p)", view, av_count, last_av_addr );

    /* c */
    page = view + HOST_PAGE;
    if (!VirtualProtect( page, HOST_PAGE, PAGE_READWRITE, &old )) failure( "c", "VirtualProtect(PAGE_READWRITE) failed %lu", GetLastError() );
    else if (old != PAGE_EXECUTE_READWRITE) failure( "c", "old protection %lx", old );
    if (write_faults( page + 0x100 )) failure( "c", "a PAGE_READWRITE page is not writable" );
    write_code( page, 42 );
    for (i = 0x200; i < HOST_PAGE; i++) page[i] = (BYTE)(i * 7 + 3);
    if (!write_faults( view + 0x800 )) failure( "c", "the host page before became writable" );
    if (!write_faults( view + 2 * HOST_PAGE + 0x800 )) failure( "c", "the host page after became writable" );
    if (!VirtualProtect( page, HOST_PAGE, PAGE_EXECUTE_READWRITE, &old )) failure( "c", "VirtualProtect(PAGE_EXECUTE_READWRITE) failed %lu", GetLastError() );
    for (i = 0x200, bad = 0; i < HOST_PAGE; i++) if (load_byte( page + i ) != (BYTE)(i * 7 + 3)) bad++;
    if (bad) failure( "c", "%u bytes of the pattern were lost", bad );
    FlushInstructionCache( GetCurrentProcess(), page, 8 );
    if ((ret = ((code_func)page)()) != 42) failure( "c", "the code returned %d", ret );
    if (!write_faults( page + 0x300 )) failure( "c", "a write to the page that is exec+write again did not fault" );
    if (load_byte( page + 0x300 ) != (BYTE)(0x300 * 7 + 3)) failure( "c", "the faulting write changed the page" );

    /* d */
    page = view + 2 * HOST_PAGE;
    if (!VirtualProtect( page + 0x1000, 0x1000, PAGE_READONLY, &old )) failure( "d", "VirtualProtect(PAGE_READONLY) failed %lu", GetLastError() );
    if (query_protect( page + 0x1000, NULL ) != PAGE_READONLY) failure( "d", "the 4K page reports %lx", query_protect( page + 0x1000, NULL ) );
    if (query_protect( page, NULL ) != PAGE_EXECUTE_READWRITE) failure( "d", "the page before it reports %lx", query_protect( page, NULL ) );
    if (load_byte( page ) || load_byte( page + 0x1000 ) || load_byte( page + 0x2000 )) failure( "d", "the host page lost its contents" );
    if (!write_faults( page + 0x2000 )) failure( "d", "a write to the rest of the host page did not fault" );
    if (!VirtualProtect( page + 0x1000, 0x1000, PAGE_EXECUTE_READWRITE, &old ) || old != PAGE_READONLY)
        failure( "d", "restoring the 4K page failed %lu, old %lx", GetLastError(), old );
    if (!write_faults( page + 0x1000 )) failure( "d", "a write to the restored 4K page did not fault" );

    /* e */
    page = view + 3 * HOST_PAGE;
    if (!VirtualFree( page, HOST_PAGE, MEM_DECOMMIT )) failure( "e", "decommit failed %lu", GetLastError() );
    query_protect( page, &state );
    if (state != MEM_RESERVE) failure( "e", "state %lx after the decommit", state );
    if (VirtualAlloc( page, HOST_PAGE, MEM_COMMIT, PAGE_EXECUTE_READWRITE ) != page) failure( "e", "commit failed %lu", GetLastError() );
    if (load_byte( page ) || load_byte( page + HOST_PAGE - 1 )) failure( "e", "the committed page does not read as zero" );
    if (!write_faults( page + 0x10 )) failure( "e", "a write to the committed page did not fault" );

    /* f */
    page = view + HOST_PAGE;
    if (!VirtualProtect( page, HOST_PAGE, PAGE_EXECUTE_READWRITE | PAGE_GUARD, &old )) failure( "f", "VirtualProtect(PAGE_GUARD) failed %lu", GetLastError() );
    guard_count = 0;
    if (load_byte( page + 0x400 ) != (BYTE)(0x400 * 7 + 3)) failure( "f", "the pattern is gone behind the guard" );
    if (guard_count != 1) failure( "f", "%ld guard page exceptions", guard_count );
    if ((ret = ((code_func)page)()) != 42) failure( "f", "the code returned %d", ret );
    if (!write_faults( page + 0x500 )) failure( "f", "a write after the guard page exception did not fault" );

    /* g */
    if (!VirtualFree( view, 0, MEM_RELEASE )) failure( "g", "release failed %lu", GetLastError() );
    plain = VirtualAlloc( NULL, VIEW_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    if (!plain) failure( "g", "plain allocation failed %lu", GetLastError() );
    else
    {
        for (i = 0; i < VIEW_SIZE; i += HOST_PAGE)
        {
            if (write_faults( plain + i + 0x80 )) failure( "g", "ordinary memory at +%x is not writable", i );
            write_code( plain + i, 40 + i / HOST_PAGE );
            FlushInstructionCache( GetCurrentProcess(), plain + i, 8 );
            if ((ret = ((code_func)(plain + i))()) != 40 + i / HOST_PAGE) failure( "g", "code at +%x returned %d", i, ret );
        }
        VirtualFree( plain, 0, MEM_RELEASE );
    }

    if (failures)
    {
        printf( "jit_view_test: FAIL (%ld)\n", failures );
        return 1;
    }
    printf( "jit_view_test: PASS (%ld expected access violations)\n", av_count );
    return 0;
}
