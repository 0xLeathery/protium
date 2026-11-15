#include <stdio.h>
#include <windows.h>

int main(void)
{
    SYSTEM_INFO si, native;
    volatile unsigned long long a = 6, b = 7;

    GetSystemInfo( &si );
    GetNativeSystemInfo( &native );
#if defined(__x86_64__) && !defined(__arm64ec__)
    printf( "hello from x86_64 code on macOS: 6*7=%llu, processor architecture %u, native %u, page size %lu\n",
            a * b, si.wProcessorArchitecture, native.wProcessorArchitecture, si.dwPageSize );
#else
    printf( "not x86_64 code\n" );
#endif
    return 0;
}
