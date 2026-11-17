/*
 * Samples where the threads of another Windows process are, as x86_64 instruction pointers:
 *
 *   thread_rip_sampler.exe <process name substring> [samples, default 200] [interval ms, default 10]
 *   thread_rip_sampler.exe <process name substring> regs <thread id> [count, default 5]
 *   thread_rip_sampler.exe <process name substring> stack [thread id, or 0 for all] [bytes, default 0x6000]
 *
 * Finds the process of that name, or else the first whose name contains it, then for each sample
 * suspends each of its threads, reads its context (Rip and Rsp), and resumes it. Prints, per
 * thread with any samples, the most frequent instruction pointers with the module they are in
 * and their offset from its base, e.g.
 *   thread 0x1a4: 200 samples
 *     188  0x14123abcd  Godot_v4.7.2-stable_win64.exe+0x123abcd
 * Under FEX an x86_64 process runs as ARM64EC, and a suspended thread's context is its x86_64
 * state, so this names the guest code a thread is in. With "regs", it prints that thread's integer
 * registers and RIP count times, a second apart, to tell a loop that makes progress from one
 * that does not. With "stack", it prints where each thread is and every value on its stack that
 * points into a loaded module, as module+offset: the return addresses of its call chain, among
 * some stale ones. This reads a waiting thread's callers without attaching as a debugger, which
 * some games end themselves over. Built for x86_64 with the mingw compiler: -lpsapi.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_THREADS 256
#define MAX_RIPS 4096

struct rip_count { DWORD tid; DWORD64 rip; int count; };

static struct rip_count rips[MAX_RIPS];
static int nrips;

static void add_rip( DWORD tid, DWORD64 rip )
{
    int i;
    for (i = 0; i < nrips; i++)
        if (rips[i].tid == tid && rips[i].rip == rip) { rips[i].count++; return; }
    if (nrips < MAX_RIPS) { rips[nrips].tid = tid; rips[nrips].rip = rip; rips[nrips++].count = 1; }
}

static int by_count( const void *a, const void *b )
{
    const struct rip_count *x = a, *y = b;
    if (x->tid != y->tid) return x->tid < y->tid ? -1 : 1;
    return y->count - x->count;
}

static void describe( HANDLE process, DWORD64 rip, char *out, size_t size )
{
    HMODULE modules[512];
    DWORD needed, i;
    MODULEINFO info;
    char name[MAX_PATH];

    snprintf( out, size, "?" );
    if (!EnumProcessModulesEx( process, modules, sizeof(modules), &needed, LIST_MODULES_ALL )) return;
    for (i = 0; i < needed / sizeof(HMODULE); i++)
    {
        if (!GetModuleInformation( process, modules[i], &info, sizeof(info) )) continue;
        if (rip < (DWORD64)info.lpBaseOfDll || rip >= (DWORD64)info.lpBaseOfDll + info.SizeOfImage) continue;
        if (!GetModuleBaseNameA( process, modules[i], name, sizeof(name) )) strcpy( name, "?" );
        snprintf( out, size, "%s+0x%llx", name, (unsigned long long)(rip - (DWORD64)info.lpBaseOfDll) );
        return;
    }
}

struct module { DWORD64 base, size; char name[64]; };
static struct module mods[1024];
static int nmods;

static void load_modules( HANDLE process )
{
    HMODULE modules[1024];
    DWORD needed, i;
    MODULEINFO info;

    if (!EnumProcessModulesEx( process, modules, sizeof(modules), &needed, LIST_MODULES_ALL )) return;
    for (i = 0; i < needed / sizeof(HMODULE) && nmods < 1024; i++)
    {
        if (!GetModuleInformation( process, modules[i], &info, sizeof(info) )) continue;
        mods[nmods].base = (DWORD64)info.lpBaseOfDll;
        mods[nmods].size = info.SizeOfImage;
        if (!GetModuleBaseNameA( process, modules[i], mods[nmods].name, sizeof(mods[nmods].name) ))
            strcpy( mods[nmods].name, "?" );
        nmods++;
    }
}

static const struct module *find_module( DWORD64 addr )
{
    int i;
    for (i = 0; i < nmods; i++) if (addr >= mods[i].base && addr - mods[i].base < mods[i].size) return &mods[i];
    return NULL;
}

/* where a thread is, and the values on its stack that point into modules */
static void scan_stack( HANDLE process, DWORD tid, SIZE_T bytes )
{
    HANDLE thread = OpenThread( THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, tid );
    CONTEXT ctx = { 0 };
    const struct module *mod;
    DWORD64 *stack;
    SIZE_T got = 0, chunk, i;

    if (!thread) { printf( "thread %#lx: OpenThread failed, error %lu\n", tid, GetLastError() ); return; }
    if (!(stack = malloc( bytes ))) return;
    ctx.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
    if (SuspendThread( thread ) == (DWORD)-1 || !GetThreadContext( thread, &ctx ))
    {
        printf( "thread %#lx: no context, error %lu\n", tid, GetLastError() );
        ResumeThread( thread );
        CloseHandle( thread );
        free( stack );
        return;
    }
    /* page by page, as the stack may end before the requested size */
    while (got < bytes)
    {
        chunk = 0x1000 - ((ctx.Rsp + got) & 0xfff);
        if (chunk > bytes - got) chunk = bytes - got;
        if (!ReadProcessMemory( process, (void *)(ctx.Rsp + got), (char *)stack + got, chunk, NULL )) break;
        got += chunk;
    }
    ResumeThread( thread );
    CloseHandle( thread );

    mod = find_module( ctx.Rip );
    printf( "thread %#lx: rip %#llx %s+%#llx, rsp %#llx, %#lx bytes of stack\n", tid, (unsigned long long)ctx.Rip,
            mod ? mod->name : "?", (unsigned long long)(mod ? ctx.Rip - mod->base : 0),
            (unsigned long long)ctx.Rsp, (unsigned long)got );
    for (i = 0; i < got / sizeof(*stack); i++)
        if ((mod = find_module( stack[i] )))
            printf( "  +%#06lx  %s+%#llx\n", (unsigned long)(i * sizeof(*stack)), mod->name,
                    (unsigned long long)(stack[i] - mod->base) );
    free( stack );
}

int main( int argc, char **argv )
{
    int samples = argc > 2 ? atoi( argv[2] ) : 200, interval = argc > 3 ? atoi( argv[3] ) : 10, s, i, shown = 0;
    DWORD pid = 0, tids[MAX_THREADS], ntids = 0, last = 0;
    PROCESSENTRY32 pe = { sizeof(pe) };
    THREADENTRY32 te = { sizeof(te) };
    HANDLE snap, process;
    char where[MAX_PATH + 32];

    if (argc < 2) { printf( "usage: thread_rip_sampler.exe <process name substring> [samples] [interval ms]\n" ); return 2; }
    snap = CreateToolhelp32Snapshot( TH32CS_SNAPPROCESS | TH32CS_SNAPTHREAD, 0 );
    /* the program of exactly that name if there is one ("RDR2.exe" is also in "PlayRDR2.exe") */
    for (BOOL ok = Process32First( snap, &pe ); ok; ok = Process32Next( snap, &pe ))
        if (!_stricmp( pe.szExeFile, argv[1] )) { pid = pe.th32ProcessID; break; }
    if (!pid)
    {
        pe.dwSize = sizeof(pe);
        for (BOOL ok = Process32First( snap, &pe ); ok; ok = Process32Next( snap, &pe ))
            if (strstr( pe.szExeFile, argv[1] )) { pid = pe.th32ProcessID; break; }
    }
    if (!pid) { printf( "sampler: no process with \"%s\" in its name\n", argv[1] ); return 1; }
    for (BOOL ok = Thread32First( snap, &te ); ok; ok = Thread32Next( snap, &te ))
        if (te.th32OwnerProcessID == pid && ntids < MAX_THREADS) tids[ntids++] = te.th32ThreadID;
    CloseHandle( snap );
    if (!(process = OpenProcess( PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid )))
    {
        printf( "sampler: OpenProcess %#lx failed, error %lu\n", pid, GetLastError() );
        return 1;
    }
    if (argc > 2 && !strcmp( argv[2], "stack" ))
    {
        DWORD tid = argc > 3 ? strtoul( argv[3], NULL, 16 ) : 0;
        SIZE_T bytes = argc > 4 ? strtoul( argv[4], NULL, 0 ) : 0x6000;

        load_modules( process );
        printf( "sampler: process %#lx (%s), %lu threads, %d modules\n", pid, pe.szExeFile, ntids, nmods );
        for (i = 0; i < nmods; i++)
            printf( "module %#llx %#llx %s\n", (unsigned long long)mods[i].base, (unsigned long long)mods[i].size, mods[i].name );
        for (i = 0; i < (int)ntids; i++) if (!tid || tids[i] == tid) scan_stack( process, tids[i], bytes );
        return 0;
    }
    if (argc > 3 && !strcmp( argv[2], "regs" ))
    {
        DWORD tid = strtoul( argv[3], NULL, 16 );
        int count = argc > 4 ? atoi( argv[4] ) : 5, k;
        HANDLE thread = OpenThread( THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT, FALSE, tid );
        if (!thread) { printf( "sampler: OpenThread %#lx failed, error %lu\n", tid, GetLastError() ); return 1; }
        for (k = 0; k < count; k++)
        {
            CONTEXT c = { 0 };
            c.ContextFlags = CONTEXT_FULL;
            SuspendThread( thread );
            GetThreadContext( thread, &c );
            ResumeThread( thread );
            describe( process, c.Rip, where, sizeof(where) );
            printf( "rip %s rax %llx rbx %llx rcx %llx rdx %llx rsi %llx rdi %llx rbp %llx rsp %llx\n"
                    "    r8 %llx r9 %llx r10 %llx r11 %llx r12 %llx r13 %llx r14 %llx r15 %llx\n", where,
                    c.Rax, c.Rbx, c.Rcx, c.Rdx, c.Rsi, c.Rdi, c.Rbp, c.Rsp, c.R8, c.R9, c.R10, c.R11, c.R12, c.R13, c.R14, c.R15 );
            Sleep( 1000 );
        }
        return 0;
    }
    printf( "sampler: process %#lx (%s), %lu threads, %d samples every %d ms\n", pid, pe.szExeFile, ntids, samples, interval );

    for (s = 0; s < samples; s++)
    {
        for (i = 0; i < (int)ntids; i++)
        {
            HANDLE thread = OpenThread( THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, tids[i] );
            CONTEXT ctx = { 0 };
            if (!thread) continue;
            ctx.ContextFlags = CONTEXT_CONTROL;
            if (SuspendThread( thread ) != (DWORD)-1)
            {
                if (GetThreadContext( thread, &ctx )) add_rip( tids[i], ctx.Rip );
                ResumeThread( thread );
            }
            CloseHandle( thread );
        }
        Sleep( interval );
    }

    qsort( rips, nrips, sizeof(*rips), by_count );
    for (i = 0; i < nrips; i++)
    {
        if (rips[i].tid != last)
        {
            int total = 0, j;
            for (j = i; j < nrips && rips[j].tid == rips[i].tid; j++) total += rips[j].count;
            printf( "thread %#lx: %d samples, %d places\n", rips[i].tid, total, j - i );
            last = rips[i].tid;
            shown = 0;
        }
        if (shown++ >= 6) continue;
        describe( process, rips[i].rip, where, sizeof(where) );
        printf( "  %5d  0x%llx  %s\n", rips[i].count, (unsigned long long)rips[i].rip, where );
    }
    return 0;
}
