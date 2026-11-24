/*
 * Reads what FEX counts about its own work in a running game: how long each thread spent
 * translating x86 code, how many blocks it translated, and how often the translated-code
 * disk cache had a block or not. Stops nothing in the game.
 *
 *   cc -O2 -o fex_stats macos/tests/fex_stats.c
 *   fex_stats <pid of the game's Wine process> [threads]
 *
 * The game must have been started with FEX_PROFILESTATS=1 (e.g. in
 * ~/Library/Application Support/SteamPlay/env.<app id>): FEX then keeps its counters in the
 * shared memory object fex-<pid>-stats (FEXCore/Utils/SHMStats.h). One line is printed:
 *   threads 61 jit 41.2 s blocks 913022 cache hit 0 miss 0 lookup 0.0 s smc 12 lock 0.3 s
 * "threads" as a second argument adds a line per thread that translated for over 0.1 s.
 * Times are counter ticks divided by the counter's frequency (24 MHz on Apple Silicon).
 *
 * Needs FEX with macos/patches/fex/0003: before it, any program with more than 38 threads died
 * or hung when it was started with FEX_PROFILESTATS=1 (Call of Duty: WWII and Red Dead
 * Redemption 2's launcher did, on 2026-11-24), because the counters' memory could not grow.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct header
{
    uint8_t version, app_type;
    uint16_t stats_size;
    char fex_version[48];
    uint32_t head, size, pad;
};

struct stats
{
    uint32_t next, tid;
    uint64_t jit_time, signal_time, sigbus, smc, float_fallback, cache_miss, read_lock, write_lock,
             jit_count, disk_hit, disk_miss, disk_lookup;
};

int main( int argc, char **argv )
{
    char name[64];
    struct stat st;
    struct header *h;
    struct stats total = {0};
    uint64_t freq;
    uint32_t off;
    int fd, threads = 0, per_thread = argc > 2 && !strcmp( argv[2], "threads" );

    if (argc < 2) { fprintf( stderr, "usage: fex_stats <pid> [threads]\n" ); return 2; }
    snprintf( name, sizeof(name), "fex-%s-stats", argv[1] );
    if ((fd = shm_open( name, O_RDONLY, 0 )) == -1) { perror( name ); return 1; }
    if (fstat( fd, &st ) || st.st_size < (off_t)sizeof(*h)) { fprintf( stderr, "%s: too small\n", name ); return 1; }
    h = mmap( NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0 );
    if (h == MAP_FAILED) { perror( "mmap" ); return 1; }
    __asm__( "mrs %0, cntfrq_el0" : "=r"(freq) );

    for (off = h->head; off && off + sizeof(struct stats) <= (uint64_t)st.st_size && off < h->size; )
    {
        struct stats s;
        memcpy( &s, (char *)h + off, sizeof(s) < h->stats_size ? sizeof(s) : h->stats_size );
        total.jit_time += s.jit_time; total.jit_count += s.jit_count; total.smc += s.smc;
        total.disk_hit += s.disk_hit; total.disk_miss += s.disk_miss; total.disk_lookup += s.disk_lookup;
        total.read_lock += s.read_lock; total.write_lock += s.write_lock;
        total.cache_miss += s.cache_miss; total.float_fallback += s.float_fallback;
        threads++;
        if (per_thread && s.jit_time > freq / 10)
            printf( "  thread %#x jit %.1f s blocks %llu\n", s.tid, (double)s.jit_time / freq, (unsigned long long)s.jit_count );
        off = s.next;
    }
    printf( "threads %d jit %.1f s blocks %llu cache hit %llu miss %llu lookup %.1f s smc %llu lock %.1f s l1miss %llu x87fallback %llu (fex %.48s)\n",
            threads, (double)total.jit_time / freq, (unsigned long long)total.jit_count,
            (unsigned long long)total.disk_hit, (unsigned long long)total.disk_miss,
            (double)total.disk_lookup / freq, (unsigned long long)total.smc,
            (double)(total.read_lock + total.write_lock) / freq,
            (unsigned long long)total.cache_miss, (unsigned long long)total.float_fallback, h->fex_version );
    return 0;
}
