/*
 * Looks at the page at 0x7ffe0000, where Windows keeps KUSER_SHARED_DATA and where programs
 * read it without asking anyone: the tick count, the system time, the processor features.
 *
 * Prints one line, e.g.
 *   shared data: base 7ffe0000, allocation base 7ffe0000, size 1000, protect 2, tick 269760719
 * and exits 0 when the page is a read-only region of its own of one 4K page and holds a tick
 * count that is not 0 (KUSER_SHARED_DATA.TickCountQuad, at offset 0x320).
 *
 * On arm64 macOS this takes memory below 4 GB, which the loader only has with the
 * cross-architecture entitlement. Without it nothing is there. Before Wine mapped the page
 * there, a block of TEBs was: the address was readable and the tick count read as 0.
 *
 * Built with the mingw compiler, for i686 and for x86_64.
 */
#include <stdio.h>
#include <windows.h>

int main(void)
{
    MEMORY_BASIC_INFORMATION mbi = { 0 };
    unsigned long long tick = 0;
    int ok;

    if (!VirtualQuery( (void *)0x7ffe0000, &mbi, sizeof(mbi) ))
    {
        printf( "shared data: VirtualQuery failed, error %lu\n", GetLastError() );
        return 1;
    }
    if (mbi.State == MEM_COMMIT && !IsBadReadPtr( (void *)0x7ffe0320, 8 )) tick = *(volatile unsigned long long *)0x7ffe0320;
    printf( "shared data: base %lx, allocation base %lx, size %lx, protect %lx, tick %llu\n",
            (unsigned long)(ULONG_PTR)mbi.BaseAddress, (unsigned long)(ULONG_PTR)mbi.AllocationBase,
            (unsigned long)mbi.RegionSize, mbi.Protect, tick );
    ok = (ULONG_PTR)mbi.BaseAddress == 0x7ffe0000 && (ULONG_PTR)mbi.AllocationBase == 0x7ffe0000 &&
         mbi.RegionSize == 0x1000 && mbi.Protect == PAGE_READONLY && tick;
    return ok ? 0 : 1;
}
