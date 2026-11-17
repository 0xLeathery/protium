/* What a game sees of the graphics adapter from two sides: DXGI, and Windows' display devices
 * (EnumDisplayDevicesW). The Last of Us Part II builds a "PCI\VEN_..&DEV_.." id from its DXGI
 * adapter's description and looks for the display device with that id, to read the driver's
 * version from; when none has it, the game says that it found no GPU.
 *
 * Prints one line, "dxgi <id> display <id> match <0|1>", and exits 0 on a match. */
#define COBJMACROS
#include <windows.h>
#include <dxgi.h>
#include <stdio.h>

int main(void)
{
    DISPLAY_DEVICEW dd, first = { 0 };
    IDXGIFactory1 *factory;
    IDXGIAdapter1 *adapter;
    DXGI_ADAPTER_DESC1 desc;
    WCHAR id[128];
    DWORD i;
    int found = 0;

    if (FAILED(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory)) ||
        FAILED(IDXGIFactory1_EnumAdapters1(factory, 0, &adapter)) ||
        FAILED(IDXGIAdapter1_GetDesc1(adapter, &desc)))
    {
        printf("no DXGI adapter\n");
        return 2;
    }
    swprintf(id, 128, L"PCI\\VEN_%04X&DEV_%04X&SUBSYS_%08X&REV_%02X",
             (unsigned)desc.VendorId, (unsigned)desc.DeviceId, (unsigned)desc.SubSysId, (unsigned)desc.Revision);

    for (i = 0; ; i++)
    {
        memset(&dd, 0, sizeof(dd));
        dd.cb = sizeof(dd);
        if (!EnumDisplayDevicesW(NULL, i, &dd, 0)) break;
        if (!i) first = dd;
        if (!_wcsnicmp(dd.DeviceID, id, wcslen(id))) { first = dd; found = 1; break; }
    }
    printf("dxgi %ls display %ls match %d\n", id, first.DeviceID, found);
    return !found;
}
