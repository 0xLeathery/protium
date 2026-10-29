/*
 * Standalone probe for the TSD slot Wine uses for the TEB on arm64 macOS.
 *
 * The macOS kernel doesn't preserve x18, so Windows ARM64 code can't find its TEB there. Wine
 * keeps the TEB in TSD slot 6 instead, which Apple's libpthread/libsyscall reserve for Windows
 * code ("slot 6 is reserved for Windows/WINE compatibility reasons", xnu libsyscall/os/tsd.h;
 * tsd_private.h: "we leave slots 6 and 11 unused"). PE code reads it with
 *     mrs xN, tpidrro_el0 ; and xN, xN, #~7 ; ldr xN, [xN, #slot*8]
 *
 * This probe checks, on the main thread, on its own pthreads and on threads created by system
 * libraries (libdispatch workers):
 *  - the slot starts out zero (nothing in a process that has loaded libSystem, libdispatch,
 *    CoreFoundation and libobjc uses it);
 *  - dynamic keys from pthread_key_create can't land on it, and the public pthread_setspecific
 *    refuses it (it is a static, reserved key);
 *  - a value written directly into the slot survives preemption, syscalls, signals and library
 *    calls, reads the same through the inline sequence and pthread_getspecific, and is per thread;
 *  - nothing else writes it (dispatch workers that never set it still read zero afterwards).
 *
 *   cc -O2 -o tsd_slot_probe tsd_slot_probe.c -framework CoreFoundation && ./tsd_slot_probe [slot]
 *
 * Prints "RESULT PASS slot=6 offset=0x30" (exit 0) or "RESULT FAIL ..." (exit 1).
 */
#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/time.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>

#ifndef __aarch64__
#error "arm64 only"
#endif

static unsigned int slot = 6;
static atomic_int failures, checks, sig_checks, sig_bad, nonzero_at_start;
static atomic_ullong low_bits_seen;

static inline uint64_t raw_tpidrro( void )
{
    uint64_t v;
    __asm__ volatile( "mrs %0, tpidrro_el0" : "=r" (v) );
    return v;
}

static inline void **tsd_base( void )
{
    return (void **)(raw_tpidrro() & ~(uint64_t)7);
}

/* the sequence Wine's PE code uses for NtCurrentTeb() */
static inline void *slot_inline( void )
{
    void *v;
    __asm__ volatile( "mrs %0, tpidrro_el0\n\t"
                      "and %0, %0, #0xfffffffffffffff8\n\t"
                      "ldr %0, [%0, %1]"
                      : "=&r" (v) : "r" ((uint64_t)slot * 8) );
    return v;
}

static void fail( const char *what, const char *thread, void *got, void *want )
{
    atomic_fetch_add( &failures, 1 );
    fprintf( stderr, "FAIL %s on %s: got %p want %p\n", what, thread, got, want );
}

static void check( const char *thread, void *want )
{
    void *a = slot_inline(), *b = pthread_getspecific( slot ), *c = tsd_base()[slot];
    atomic_fetch_add( &checks, 1 );
    atomic_fetch_or( &low_bits_seen, raw_tpidrro() & 7 );
    if (a != want || b != want || c != want) fail( "slot value", thread, a != want ? a : b != want ? b : c, want );
}

static __thread void *thread_want;  /* host TLS, only to give the signal handler the expected value */

static void alarm_handler( int sig )
{
    (void)sig;
    if (!thread_want) return;
    atomic_fetch_add( &sig_checks, 1 );
    if (slot_inline() != thread_want) atomic_fetch_add( &sig_bad, 1 );
}

static void stress( const char *name, void *want, int iterations )
{
    char buf[64];
    int fd = open( "/dev/null", O_WRONLY );

    for (int i = 0; i < iterations; i++)
    {
        volatile int spin = 5000;
        while (spin--) ;                                  /* preemption */
        if (i % 8 == 0) usleep( 10 );                     /* blocking syscall */
        if (i % 8 == 1) write( fd, buf, 1 );              /* syscall */
        if (i % 8 == 2) free( malloc( 1 + (i % 4096) ) ); /* libmalloc */
        if (i % 8 == 3) { time_t t = time( NULL ); struct tm tm; localtime_r( &t, &tm ); }  /* libc TSD keys */
        if (i % 64 == 4)
        {
            CFStringRef s = CFStringCreateWithFormat( NULL, NULL, CFSTR("%d"), i );  /* CF / objc TSD keys */
            CFRelease( s );
        }
        check( name, want );
    }
    close( fd );
}

struct worker_arg { int index; void *initial; };

static void *worker( void *p )
{
    struct worker_arg *arg = p;
    char name[32];
    void *want = (void *)(0x7f0000000000ULL + ((uint64_t)arg->index << 16));

    snprintf( name, sizeof(name), "pthread %d", arg->index );
    arg->initial = tsd_base()[slot];
    if (arg->initial) atomic_fetch_add( &nonzero_at_start, 1 );
    tsd_base()[slot] = want;
    thread_want = want;
    stress( name, want, 4000 );
    return NULL;
}

int main( int argc, char **argv )
{
    struct itimerval it = { {0, 500}, {0, 500} }, off = {{0}};
    struct worker_arg args[32];
    pthread_t threads[32];
    pthread_key_t key;
    void *main_initial, *main_want = (void *)0x7e0000010000ULL;
    int nthreads = 16, rc, dispatch_bad = 0;
    __block atomic_int dispatch_nonzero = 0, dispatch_runs = 0;

    if (argc > 1) slot = strtoul( argv[1], NULL, 0 );
    printf( "slot %u offset %#x\n", slot, slot * 8 );
    printf( "TPIDRRO_EL0 %#llx (low 3 bits %llu)\n", (unsigned long long)raw_tpidrro(),
            (unsigned long long)(raw_tpidrro() & 7) );

    /* private SPI that could also claim a static key, for the record (not used) */
    printf( "SPI pthread_key_init_np: %s, _pthread_setspecific_static: %s\n",
            dlsym( RTLD_DEFAULT, "pthread_key_init_np" ) ? "exported" : "absent",
            dlsym( RTLD_DEFAULT, "_pthread_setspecific_static" ) ? "exported" : "absent" );

    /* load CoreFoundation/objc and start libdispatch before looking at the slot */
    CFRelease( CFStringCreateWithCString( NULL, "probe", kCFStringEncodingUTF8 ) );
    dispatch_sync( dispatch_get_global_queue( QOS_CLASS_DEFAULT, 0 ), ^{ } );

    main_initial = tsd_base()[slot];
    printf( "main thread initial slot value %p\n", main_initial );
    if (main_initial) { atomic_fetch_add( &nonzero_at_start, 1 ); fail( "initial value", "main", main_initial, NULL ); }

    /* dynamic keys start at 256: they can't collide with a static slot */
    rc = pthread_key_create( &key, NULL );
    printf( "pthread_key_create -> %d, key %lu\n", rc, (unsigned long)key );
    if (rc || key < 256) fail( "dynamic key range", "main", (void *)(uintptr_t)key, (void *)256 );
    /* the public API refuses the reserved static slot */
    rc = pthread_setspecific( slot, (void *)1 );
    printf( "pthread_setspecific(%u) -> %d (%s)\n", slot, rc, rc == EINVAL ? "EINVAL, reserved" : "accepted" );
    if (tsd_base()[slot] == (void *)1) tsd_base()[slot] = NULL;

    tsd_base()[slot] = main_want;
    thread_want = main_want;
    signal( SIGALRM, alarm_handler );
    setitimer( ITIMER_REAL, &it, NULL );

    for (int i = 0; i < nthreads; i++)
    {
        args[i].index = i + 1;
        pthread_create( &threads[i], NULL, worker, &args[i] );
    }
    stress( "main", main_want, 4000 );
    for (int i = 0; i < nthreads; i++) pthread_join( threads[i], NULL );

    /* threads created by libdispatch never set the slot: it must still read zero there */
    dispatch_apply( 256, dispatch_get_global_queue( QOS_CLASS_DEFAULT, 0 ), ^(size_t i) {
        volatile int spin = 20000;
        (void)i;
        while (spin--) ;
        atomic_fetch_add( &dispatch_runs, 1 );
        if (!pthread_main_np() && tsd_base()[slot]) atomic_fetch_add( &dispatch_nonzero, 1 );
    } );
    setitimer( ITIMER_REAL, &off, NULL );
    check( "main (end)", main_want );

    for (int i = 0; i < nthreads; i++)
        if (args[i].initial) fail( "initial value", "pthread", args[i].initial, NULL );
    /* (dispatch_apply also runs some blocks on the main thread, which has the slot set) */
    dispatch_bad = atomic_load( &dispatch_nonzero );
    if (dispatch_bad) fail( "value on a libdispatch worker", "dispatch", (void *)(uintptr_t)dispatch_bad, NULL );
    printf( "threads %d, checks %d, failures %d, signal-handler checks %d mismatches %d\n",
            nthreads + 1, atomic_load( &checks ), atomic_load( &failures ),
            atomic_load( &sig_checks ), atomic_load( &sig_bad ) );
    printf( "initial nonzero %d, dispatch blocks %d, nonzero on libdispatch workers %d\n",
            atomic_load( &nonzero_at_start ), atomic_load( &dispatch_runs ), dispatch_bad );
    printf( "low 3 bits of TPIDRRO_EL0 ever set: %#llx\n", (unsigned long long)atomic_load( &low_bits_seen ) );

    if (atomic_load( &failures ) || atomic_load( &sig_bad ) || !atomic_load( &sig_checks ))
    {
        printf( "RESULT FAIL slot=%u offset=%#x\n", slot, slot * 8 );
        return 1;
    }
    printf( "RESULT PASS slot=%u offset=%#x\n", slot, slot * 8 );
    return 0;
}
