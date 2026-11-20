/*
 * Prints the video memory a game is told it has, the way a game asks: the adapter's
 * DedicatedVideoMemory and the budget of IDXGIAdapter3::QueryVideoMemoryInfo(), local and
 * non-local, in MB.
 *
 *   vram_budget_test.exe
 *
 * prints e.g.
 *   vram budget: dedicated 9113 MB, local budget 9113 MB, non-local budget 9113 MB, usage 0 MB
 *
 * With unified memory DXMT reported three quarters of the Mac's memory as the budget, which
 * Call of Duty: WWII filled until the Mac swapped; macos/patches/dxmt/0003 makes it the
 * dedicated video memory, half of that, and DXMT_VIDEO_MEMORY_BUDGET_MB sets another.
 * Built with the mingw compiler: -ldxgi -ldxguid -luuid.
 */
#define COBJMACROS
#include <windows.h>
#include <dxgi1_4.h>
#include <stdio.h>

int main(void)
{
    DXGI_QUERY_VIDEO_MEMORY_INFO local, nonlocal;
    IDXGIFactory1 *factory;
    IDXGIAdapter1 *adapter;
    IDXGIAdapter3 *adapter3;
    DXGI_ADAPTER_DESC1 desc;

    if (FAILED(CreateDXGIFactory1( &IID_IDXGIFactory1, (void **)&factory )) ||
        FAILED(IDXGIFactory1_EnumAdapters1( factory, 0, &adapter )) ||
        FAILED(IDXGIAdapter1_GetDesc1( adapter, &desc )))
    {
        printf( "vram budget: no adapter\n" );
        return 1;
    }
    if (FAILED(IDXGIAdapter1_QueryInterface( adapter, &IID_IDXGIAdapter3, (void **)&adapter3 )) ||
        FAILED(IDXGIAdapter3_QueryVideoMemoryInfo( adapter3, 0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &local )) ||
        FAILED(IDXGIAdapter3_QueryVideoMemoryInfo( adapter3, 0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &nonlocal )))
    {
        printf( "vram budget: dedicated %llu MB, no IDXGIAdapter3 budget\n",
                (unsigned long long)(desc.DedicatedVideoMemory >> 20) );
        return 1;
    }
    printf( "vram budget: dedicated %llu MB, local budget %llu MB, non-local budget %llu MB, usage %llu MB\n",
            (unsigned long long)(desc.DedicatedVideoMemory >> 20), (unsigned long long)(local.Budget >> 20),
            (unsigned long long)(nonlocal.Budget >> 20), (unsigned long long)(local.CurrentUsage >> 20) );
    return 0;
}
