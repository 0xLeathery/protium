/*
 * Asks for a thread's context, and sets one, with pointers Windows cannot use:
 *
 *   thread_context_test.exe
 *
 * Windows reads and writes a CONTEXT in the kernel, so GetThreadContext() and
 * SetThreadContext() with a null or unmapped pointer fail with ERROR_NOACCESS; they do not
 * raise an exception in the caller. Call of Duty: WWII calls GetThreadContext() with a null
 * context as it starts and goes on when that fails. Where Wine converts the context in user
 * mode (an x86-64 program on ARM64, which runs as ARM64EC) the bad pointer was an access
 * violation in the game instead, and the game ended on it.
 *
 * Also asks for the context of a suspended thread properly, which must still work. Prints one
 * line, e.g.
 *   thread context: null get 0 error 998, null set 0 error 998, bad get 0 error 998, good get 1 ip set 1, exceptions 0
 * and exits 0 when the three bad calls failed with ERROR_NOACCESS (998), the good one gave an
 * instruction pointer and nothing raised an exception.
 *
 * Built for x86_64 and i686 with the mingw compiler.
 */
#include <windows.h>
#include <stdio.h>

static LONG exceptions;

static LONG CALLBACK count_exception( EXCEPTION_POINTERS *info )
{
    if (info->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) InterlockedIncrement( &exceptions );
    return EXCEPTION_CONTINUE_SEARCH;
}

static DWORD CALLBACK sleeper( void *arg )
{
    Sleep( INFINITE );
    return 0;
}

int main(void)
{
    HANDLE thread = CreateThread( NULL, 0, sleeper, NULL, CREATE_SUSPENDED, NULL );
    void *unmapped = VirtualAlloc( NULL, 0x10000, MEM_RESERVE, PAGE_NOACCESS );
    BOOL null_get, null_set, bad_get, good_get, ok;
    DWORD null_get_err, null_set_err, bad_get_err;
    CONTEXT ctx;

    AddVectoredExceptionHandler( 1, count_exception );

    SetLastError( 0xdeadbeef );
    null_get = GetThreadContext( thread, NULL );
    null_get_err = GetLastError();
    SetLastError( 0xdeadbeef );
    null_set = SetThreadContext( thread, NULL );
    null_set_err = GetLastError();
    SetLastError( 0xdeadbeef );
    bad_get = GetThreadContext( thread, unmapped );
    bad_get_err = GetLastError();

    memset( &ctx, 0, sizeof(ctx) );
    ctx.ContextFlags = CONTEXT_CONTROL;
    good_get = GetThreadContext( thread, &ctx );
#ifdef _WIN64
#define CTX_IP ctx.Rip
#else
#define CTX_IP ctx.Eip
#endif
    ok = !null_get && null_get_err == ERROR_NOACCESS && !null_set && null_set_err == ERROR_NOACCESS
         && !bad_get && bad_get_err == ERROR_NOACCESS && good_get && CTX_IP && !exceptions;
    printf( "thread context: null get %d error %lu, null set %d error %lu, bad get %d error %lu, good get %d ip set %d, exceptions %ld\n",
            null_get, null_get_err, null_set, null_set_err, bad_get, bad_get_err, good_get, CTX_IP != 0, exceptions );
    fflush( stdout );
    TerminateThread( thread, 0 );
    return ok ? 0 : 1;
}
