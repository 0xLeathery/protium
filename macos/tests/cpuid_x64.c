/* x86_64 test program: the CPU features that x86 code is told about (CPUID). Under FEX these
 * come from what Wine reports of the host's ARM64 ID registers. */
#include <stdio.h>
#include <cpuid.h>

int main(void)
{
    unsigned int a, b, c, d, a7 = 0, b7 = 0, c7 = 0, d7 = 0;

    __cpuid( 1, a, b, c, d );
    __cpuid_count( 7, 0, a7, b7, c7, d7 );
    printf( "cpuid: sse3=%u pclmulqdq=%u ssse3=%u sse4.1=%u sse4.2=%u popcnt=%u aes=%u sha=%u\n",
            c & 1, (c >> 1) & 1, (c >> 9) & 1, (c >> 19) & 1, (c >> 20) & 1, (c >> 23) & 1,
            (c >> 25) & 1, (b7 >> 29) & 1 );
    return 0;
}
