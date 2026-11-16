/*
 * A 32-bit x86 program: Wine runs it in a WoW64 process, whose code FEX's WoW64 module
 * (libwow64fex.dll) translates. Everything of such a process lives below 4 GB.
 *
 * Prints one line, e.g.
 *   hello from 32-bit x86 code on macOS: 6*7=42, pointer size 4, processor architecture 0, native 9, wow64 1
 * and exits 0.
 *
 * Built for i686 with the mingw compiler.
 */
#include <stdio.h>
#include <windows.h>

int main(void)
{
    SYSTEM_INFO si, native;
    volatile unsigned int a = 6, b = 7;
    BOOL wow64 = FALSE;

    GetSystemInfo( &si );
    GetNativeSystemInfo( &native );
    IsWow64Process( GetCurrentProcess(), &wow64 );
#if defined(__i386__)
    printf( "hello from 32-bit x86 code on macOS: 6*7=%u, pointer size %u, processor architecture %u, native %u, wow64 %d\n",
            a * b, (unsigned int)sizeof(void *), si.wProcessorArchitecture, native.wProcessorArchitecture, wow64 );
#else
    printf( "not 32-bit x86 code\n" );
#endif
    return 0;
}
