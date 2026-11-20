/*
 * Prints how busy each thread of a process is, by name, without stopping it.
 *
 *   threadcpu <pid> [seconds, default 1]
 *
 * Reads every thread's CPU time (proc_pidinfo) twice, that many seconds apart, and prints one
 * line: the process's memory footprint in MB (what Activity Monitor shows, with the memory its
 * graphics hold), then the per cent of a core each thread used in between, busiest first,
 * threads under 3% left out, e.g.
 *   mem 7419 | Main 84, Server 80, Backend 54, ?#5 95, Sound mix thread 41
 * A thread without a name is "?#" and its place in the process's list. Unlike macOS's sample,
 * which stops the threads for every stack it reads (a game stutters and can lose its sound
 * while it is sampled), this only reads counters. For a native arm64 build: cc -O2.
 */
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_THREADS 1024

struct thread { uint64_t id, ns; char name[64]; int found; };

static int read_threads( int pid, struct thread *threads )
{
    static uint64_t ids[MAX_THREADS];
    int i, n = proc_pidinfo( pid, PROC_PIDLISTTHREADS, 0, ids, sizeof(ids) ) / sizeof(ids[0]);

    for (i = 0; i < n; i++)
    {
        struct proc_threadinfo info;

        threads[i].id = ids[i];
        threads[i].found = proc_pidinfo( pid, PROC_PIDTHREADINFO, ids[i], &info, sizeof(info) ) == sizeof(info);
        if (!threads[i].found) continue;
        threads[i].ns = info.pth_user_time + info.pth_system_time;
        if (info.pth_name[0]) snprintf( threads[i].name, sizeof(threads[i].name), "%s", info.pth_name );
        else snprintf( threads[i].name, sizeof(threads[i].name), "?#%d", i );
    }
    return n;
}

static struct thread before[MAX_THREADS], after[MAX_THREADS];
static struct { int pct; const char *name; } busy[MAX_THREADS];

int main( int argc, char **argv )
{
    int pid = argc > 1 ? atoi( argv[1] ) : 0, secs = argc > 2 ? atoi( argv[2] ) : 1;
    int i, j, k, n, m, count = 0;
    struct rusage_info_v2 usage;
    uint64_t start, elapsed;
    mach_timebase_info_data_t tb;

    if (!pid) { fprintf( stderr, "usage: threadcpu <pid> [seconds]\n" ); return 2; }
    mach_timebase_info( &tb );
    start = mach_absolute_time();
    if ((n = read_threads( pid, before )) <= 0) { fprintf( stderr, "no threads for pid %d\n", pid ); return 1; }
    sleep( secs );
    m = read_threads( pid, after );
    elapsed = (mach_absolute_time() - start) * tb.numer / tb.denom;

    for (i = 0; i < m; i++)
    {
        uint64_t used;

        if (!after[i].found) continue;
        for (j = 0; j < n; j++) if (before[j].id == after[i].id && before[j].found) break;
        if (j == n) continue;
        /* thread times are in nanoseconds already */
        used = after[i].ns - before[j].ns;
        if (used * 100 / elapsed < 3) continue;
        for (k = count++; k > 0 && busy[k - 1].pct < (int)(used * 100 / elapsed); k--) busy[k] = busy[k - 1];
        busy[k].pct = used * 100 / elapsed;
        busy[k].name = after[i].name;
    }
    if (!proc_pid_rusage( pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage ))
        printf( "mem %llu | ", (unsigned long long)(usage.ri_phys_footprint >> 20) );
    for (i = 0; i < count; i++) printf( "%s%s %d", i ? ", " : "", busy[i].name, busy[i].pct );
    printf( "\n" );
    return 0;
}
