/*
 * What macOS counts for a process's threads, checked against work of a known amount, before Wine's
 * per-process line (ntdll, wave 2 of the frame recorder) relies on the counters:
 *
 *   cc -O2 -o rusage_probe macos/tests/rusage_probe.c && ./rusage_probe
 *
 * Prints one line per counter, expected against measured:
 *   - proc_pid_rusage(RUSAGE_INFO_V6) times: in which unit (against getrusage), whether
 *     ri_runnable_time includes running (one spinner alone), what it says when threads wait for a
 *     core (3 x ncpu spinners for 2 s: waiting = runnable - cpu = (K - ncpu) x 2 s), and the share
 *     of time on performance cores (ri_user_ptime + ri_system_ptime) for background-QoS spinners,
 *     which macOS keeps on efficiency cores, against user-interactive ones;
 *   - proc_pidinfo(PROC_PIDTASKINFO): unix system calls, mach calls and context switches;
 *   - task_info(TASK_VM_INFO) and ri_phys_footprint: 256 MB touched;
 *   - the cost of what the line adds per event: mach_absolute_time and a relaxed atomic add, with two
 *     threads adding to the same counter.
 *
 * Native arm64 only (it measures macOS, not Wine). Runs about 15 s and keeps every core busy for
 * 4 s of it: not while a game is played.
 *
 * Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.
 */
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <unistd.h>

static mach_timebase_info_data_t timebase;
static double ns(uint64_t ticks) { return (double)ticks * timebase.numer / timebase.denom; }
static uint64_t now(void) { return mach_absolute_time(); }

struct sample { struct rusage_info_v6 ri; struct proc_taskinfo ti; };

static void take(struct sample *s)
{
    memset(s, 0, sizeof(*s));
    proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&s->ri);
    proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &s->ti, sizeof(s->ti));
}

static atomic_int stop;
static void *spin(void *arg)
{
    qos_class_t qos = (qos_class_t)(intptr_t)arg;
    if (qos) pthread_set_qos_class_self_np(qos, 0);
    while (!atomic_load_explicit(&stop, memory_order_relaxed)) {}
    return NULL;
}

/* run k spinners of the given QoS for the given seconds; return the rusage deltas in seconds */
static void spinners(int k, qos_class_t qos, double seconds, double *cpu, double *runnable, double *ptime)
{
    pthread_t *t = calloc(k, sizeof(*t));
    struct sample a, b;
    take(&a);
    atomic_store(&stop, 0);
    for (int i = 0; i < k; i++) pthread_create(&t[i], NULL, spin, (void *)(intptr_t)qos);
    usleep((useconds_t)(seconds * 1e6));
    atomic_store(&stop, 1);
    for (int i = 0; i < k; i++) pthread_join(t[i], NULL);
    take(&b);
    *cpu = ns((b.ri.ri_user_time - a.ri.ri_user_time) + (b.ri.ri_system_time - a.ri.ri_system_time)) / 1e9;
    *runnable = ns(b.ri.ri_runnable_time - a.ri.ri_runnable_time) / 1e9;
    *ptime = ns((b.ri.ri_user_ptime - a.ri.ri_user_ptime) + (b.ri.ri_system_ptime - a.ri.ri_system_ptime)) / 1e9;
    free(t);
}

static _Atomic uint64_t shared_counter;
static void *adder(void *arg)
{
    for (int i = 0; i < 10000000; i++) atomic_fetch_add_explicit(&shared_counter, 1, memory_order_relaxed);
    return arg;
}

int main(void)
{
    int ncpu = 0;
    size_t len = sizeof(ncpu);
    double cpu, runnable, ptime;
    struct sample a, b;
    struct rusage ru0, ru1;

    mach_timebase_info(&timebase);
    sysctlbyname("hw.ncpu", &ncpu, &len, NULL, 0);
    printf("timebase %u/%u; %d cores\n", timebase.numer, timebase.denom, ncpu);

    /* units: one spinner for 1 s, against getrusage */
    getrusage(RUSAGE_SELF, &ru0);
    spinners(1, 0, 1.0, &cpu, &runnable, &ptime);
    getrusage(RUSAGE_SELF, &ru1);
    double gr = (ru1.ru_utime.tv_sec - ru0.ru_utime.tv_sec) + (ru1.ru_utime.tv_usec - ru0.ru_utime.tv_usec) / 1e6
              + (ru1.ru_stime.tv_sec - ru0.ru_stime.tv_sec) + (ru1.ru_stime.tv_usec - ru0.ru_stime.tv_usec) / 1e6;
    printf("one spinner 1 s: cpu %.3f s (getrusage %.3f s), runnable %.3f s, P cores %.0f%%\n",
           cpu, gr, runnable, cpu > 0 ? ptime / cpu * 100 : 0);
    printf("  -> runnable %s running time\n", runnable > 0.8 * cpu ? "INCLUDES" : "does not include");

    /* waiting for a core: 3 x ncpu spinners for 2 s */
    spinners(3 * ncpu, 0, 2.0, &cpu, &runnable, &ptime);
    printf("%d spinners 2 s: cpu %.2f s (expected about %.0f), runnable %.2f s (about %.0f), "
           "waiting = runnable - cpu %.2f s (about %.0f), P cores %.0f%%\n",
           3 * ncpu, cpu, 2.0 * ncpu, runnable, 2.0 * 3 * ncpu, runnable - cpu, 2.0 * 2 * ncpu,
           cpu > 0 ? ptime / cpu * 100 : 0);

    /* performance-core share by QoS */
    spinners(2, QOS_CLASS_BACKGROUND, 1.0, &cpu, &runnable, &ptime);
    printf("2 background spinners 1 s: P cores %.0f%% (expected near 0)\n", cpu > 0 ? ptime / cpu * 100 : 0);
    spinners(2, QOS_CLASS_USER_INTERACTIVE, 1.0, &cpu, &runnable, &ptime);
    printf("2 user-interactive spinners 1 s: P cores %.0f%% (expected near 100)\n", cpu > 0 ? ptime / cpu * 100 : 0);

    /* calls and switches */
    take(&a);
    for (int i = 0; i < 100000; i++) getppid();
    for (int i = 0; i < 100000; i++) mach_thread_self();
    for (int i = 0; i < 10000; i++) sched_yield();
    take(&b);
    printf("100000 getppid + 10000 sched_yield: unix syscalls +%d; 100000 mach_thread_self: mach calls +%d; "
           "switches +%d\n", b.ti.pti_syscalls_unix - a.ti.pti_syscalls_unix,
           b.ti.pti_syscalls_mach - a.ti.pti_syscalls_mach, b.ti.pti_csw - a.ti.pti_csw);

    /* memory: 256 MB touched */
    {
        task_vm_info_data_t v0, v1;
        mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
        size_t size = 256u << 20;
        volatile char *m;   /* volatile: the writes would otherwise be dropped, the memory being freed unread */
        task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v0, &n);
        take(&a);
        m = malloc(size);
        for (size_t i = 0; i < size; i += 16384) m[i] = 1;
        n = TASK_VM_INFO_COUNT;
        task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v1, &n);
        take(&b);
        printf("256 MB touched: task_info phys_footprint +%.0f MB, ri_phys_footprint +%.0f MB, faults +%d, "
               "compressed %.0f MB, graphics %.0f MB\n",
               (v1.phys_footprint - v0.phys_footprint) / 1048576.0,
               ((double)b.ri.ri_phys_footprint - (double)a.ri.ri_phys_footprint) / 1048576.0,
               b.ti.pti_faults - a.ti.pti_faults, v1.compressed / 1048576.0,
               v1.ledger_tag_graphics_footprint / 1048576.0);
        free((void *)m);
    }

    /* what the line adds per event */
    {
        const int count = 10000000;
        uint64_t t0 = now(), sink = 0;
        pthread_t t1, t2;
        for (int i = 0; i < count; i++) sink += mach_absolute_time();
        uint64_t t1v = now();
        pthread_create(&t1, NULL, adder, NULL);
        pthread_create(&t2, NULL, adder, NULL);
        pthread_join(t1, NULL);
        pthread_join(t2, NULL);
        uint64_t t2v = now();
        printf("mach_absolute_time %.1f ns; relaxed atomic add, two threads on one counter, %.1f ns an add (%llu)\n",
               ns(t1v - t0) / count, ns(t2v - t1v) / (2.0 * count), (unsigned long long)(sink & 1));
    }
    return 0;
}
