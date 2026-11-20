/*
 * Checks what VirtualQuery() says about large reservations that are committed, decommitted,
 * protected and released piece by piece, against a model the test keeps itself, and times a
 * commit inside a large reservation.
 *
 *   vprot_run_test.exe [seed, default 1] [operations, default 4000]
 *
 * Wine keeps a byte of protection per page and answers a query by reading the bytes up to the
 * first one that differs. On macOS it remembers long runs of equal bytes (ntdll's vprot_runs),
 * because an x86 emulator queries the region before every commit and protect, and reading all
 * of a 64 GB reservation for each took 2.8 ms: Call of Duty: WWII's level load spent most of
 * its loader thread's time there. A remembered run that is wrong shows as a wrong region size
 * here. The arenas are large enough for their runs to be remembered (64 MB and more).
 *
 * Prints one line per wrong answer (at most 20), then
 *   vprot run test: <queries> queries, <wrong> wrong, commit <n> us
 * where the time is that of one 64 KB commit in a 16 GB reservation, in microseconds.
 * 64-bit only. Built with the mingw compiler.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#define ARENAS     3
#define SLOT       ((SIZE_T)0x200000)   /* 2 MB */
#define SLOTS      4096                 /* 8 GB an arena */

enum { RESERVED, READWRITE, READONLY };

static char *arena[ARENAS];
static unsigned char model[ARENAS][SLOTS];
static unsigned int seed;
static int queries, wrong;

static unsigned int rnd(void)
{
    seed = seed * 1103515245 + 12345;
    return (seed >> 8) & 0xffffff;
}

static void query( int a, int slot, SIZE_T offset )
{
    MEMORY_BASIC_INFORMATION info;
    char *addr = arena[a] + slot * SLOT + offset;
    DWORD state = model[a][slot] == RESERVED ? MEM_RESERVE : MEM_COMMIT;
    DWORD prot = model[a][slot] == RESERVED ? 0 : model[a][slot] == READWRITE ? PAGE_READWRITE : PAGE_READONLY;
    SIZE_T size;
    int end = slot;

    while (end < SLOTS && model[a][end] == model[a][slot]) end++;
    size = (end - slot) * SLOT - offset;

    queries++;
    if (VirtualQuery( addr, &info, sizeof(info) ) != sizeof(info) || info.BaseAddress != addr ||
        info.AllocationBase != arena[a] || info.RegionSize != size || info.State != state || info.Protect != prot)
    {
        if (wrong++ < 20)
            printf( "wrong: arena %d slot %d+%#Ix: base %p size %#Ix state %#lx prot %#lx, expected %p %#Ix %#lx %#lx\n",
                    a, slot, offset, info.BaseAddress, info.RegionSize, info.State, info.Protect, addr, size, state, prot );
    }
}

static BOOL reserve( int a )
{
    int i;

    if (!(arena[a] = VirtualAlloc( NULL, SLOT * SLOTS, MEM_RESERVE, PAGE_READWRITE ))) return FALSE;
    for (i = 0; i < SLOTS; i++) model[a][i] = RESERVED;
    return TRUE;
}

static double now(void)
{
    LARGE_INTEGER count, freq;
    QueryPerformanceCounter( &count );
    QueryPerformanceFrequency( &freq );
    return (double)count.QuadPart / freq.QuadPart;
}

int main( int argc, char **argv )
{
    int ops = argc > 2 ? atoi( argv[2] ) : 4000, op, a, i, first, count;
    double start, commit_us = -1;
    char *big;
    DWORD old;

    seed = argc > 1 ? atoi( argv[1] ) : 1;
    for (a = 0; a < ARENAS; a++)
        if (!reserve( a )) { printf( "reserve failed, error %lu\n", GetLastError() ); return 1; }

    for (op = 0; op < ops; op++)
    {
        a = rnd() % ARENAS;
        first = rnd() % SLOTS;
        /* mostly short pieces, as an allocator takes them, at times a long one */
        count = (rnd() % 8) ? 1 + rnd() % 4 : 1 + rnd() % 600;
        if (first + count > SLOTS) count = SLOTS - first;

        switch (rnd() % 8)
        {
        case 0: case 1: case 2:  /* commit, in ascending order half of the time */
            if (rnd() % 2) for (first = 0; first < SLOTS - 1 && model[a][first] != RESERVED; first++) ;
            if (first + count > SLOTS) count = SLOTS - first;
            if (VirtualAlloc( arena[a] + first * SLOT, count * SLOT, MEM_COMMIT, PAGE_READWRITE ))
                for (i = first; i < first + count; i++) model[a][i] = READWRITE;
            else printf( "commit failed, error %lu\n", GetLastError() ), wrong++;
            break;
        case 3: case 4:  /* decommit */
            /* Wine keeps the protection of a decommitted page and ends a reserved region where
             * it changes, which Windows does not; that is not what this test is about, so the
             * pages are made read-write first */
            for (i = first; i < first + count; i++)
                if (model[a][i] == READONLY) VirtualProtect( arena[a] + i * SLOT, SLOT, PAGE_READWRITE, &old );
            if (VirtualFree( arena[a] + first * SLOT, count * SLOT, MEM_DECOMMIT ))
                for (i = first; i < first + count; i++) model[a][i] = RESERVED;
            else printf( "decommit failed, error %lu\n", GetLastError() ), wrong++;
            break;
        case 5: case 6:  /* protect what is committed of the piece, from its start */
        {
            int state = (rnd() % 2) ? READONLY : READWRITE;
            for (i = first; i < first + count && model[a][i] != RESERVED; i++) ;
            if (i == first) break;
            if (VirtualProtect( arena[a] + first * SLOT, (i - first) * SLOT,
                                state == READONLY ? PAGE_READONLY : PAGE_READWRITE, &old ))
                for (count = i, i = first; i < count; i++) model[a][i] = state;
            else printf( "protect failed, error %lu\n", GetLastError() ), wrong++;
            break;
        }
        case 7:  /* now and then release the arena and reserve another */
            if (rnd() % 40) break;
            if (!VirtualFree( arena[a], 0, MEM_RELEASE )) printf( "release failed, error %lu\n", GetLastError() ), wrong++;
            if (!reserve( a )) { printf( "reserve failed, error %lu\n", GetLastError() ); return 1; }
            break;
        }

        /* around the piece, at its start and inside it, and somewhere else in every arena */
        if (first > 0) query( a, first - 1, 0 );
        query( a, first, 0 );
        query( a, first, (rnd() % (SLOT / 0x1000)) * 0x1000 );
        if (first + count < SLOTS) query( a, first + count, 0 );
        for (i = 0; i < ARENAS; i++) query( i, rnd() % SLOTS, (rnd() % 2) ? 0 : (rnd() % (SLOT / 0x1000)) * 0x1000 );
        if (!(op % 500)) for (i = 0; i < ARENAS; i++) query( i, 0, 0 );
    }

    /* what an emulated program pays for a commit while most of a large reservation is unused */
    if ((big = VirtualAlloc( NULL, (SIZE_T)16 << 30, MEM_RESERVE, PAGE_READWRITE )))
    {
        VirtualAlloc( big, 0x10000, MEM_COMMIT, PAGE_READWRITE );
        start = now();
        for (i = 1; i <= 2000; i++) VirtualAlloc( big + i * 0x10000, 0x10000, MEM_COMMIT, PAGE_READWRITE );
        commit_us = (now() - start) / 2000 * 1e6;
    }

    printf( "vprot run test: %d queries, %d wrong, commit %.1f us\n", queries, wrong, commit_us );
    return wrong != 0;
}
