/*
 * Calls back from native code into x86 code many times: qsort() of the C runtime, which is
 * native (ARM64EC) code in an x86_64 process, calls a comparison function of the program,
 * which is x86 code that FEX runs.
 *
 *   callback_x64.exe [elements, default 1000000]
 *
 * Prints one line, e.g.
 *   callback: 1000000 elements, 19645469 callbacks, sorted 1
 * and exits 0 when the array came back sorted.
 *
 * Each return from such a callback takes an entry from FEX's call-return stack that no call
 * put there. FEX expects to run off the end of that stack sooner or later and catches it with
 * a 4K guard page behind it. Where the host has 16K pages and Wine cannot give it 4K ones, the
 * guard page shares a host page with the last page of the stack and does not fault; the
 * accesses go on to the next host page, which is outside what FEX takes for its guard, and the
 * program gets an access violation it did not cause.
 *
 * Built for x86_64 with the mingw compiler.
 */
#include <stdio.h>
#include <stdlib.h>

static unsigned long long callbacks;

static int compare( const void *a, const void *b )
{
    unsigned int x = *(const unsigned int *)a, y = *(const unsigned int *)b;

    callbacks++;
    return (x > y) - (x < y);
}

int main( int argc, char **argv )
{
    int count = argc > 1 ? atoi( argv[1] ) : 1000000, i, sorted = 1;
    unsigned int *values, seed = 12345;

    if (count < 2 || !(values = malloc( count * sizeof(*values) ))) return 2;
    for (i = 0; i < count; i++) values[i] = seed = seed * 1664525u + 1013904223u;
    qsort( values, count, sizeof(*values), compare );
    for (i = 1; i < count; i++) if (values[i - 1] > values[i]) sorted = 0;
    printf( "callback: %d elements, %llu callbacks, sorted %d\n", count, callbacks, sorted );
    fflush( stdout );
    return sorted ? 0 : 1;
}
