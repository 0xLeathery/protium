/*
 * Times what a game does when it looks for input devices over and over: SetupAPI's enumeration
 * of the HID device interfaces, with each interface's path, as Call of Duty: WWII does on one of
 * its threads the whole time it runs.
 *
 *   devenum_bench.exe [passes, default 200]
 *
 * Each pass is SetupDiGetClassDevsW(GUID_DEVINTERFACE_HID, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE),
 * SetupDiEnumDeviceInterfaces and SetupDiGetDeviceInterfaceDetailW for every interface, then
 * SetupDiDestroyDeviceInfoList. Prints
 *   devenum: <passes> passes, <n> HID interfaces, <us> us a pass
 * Every registry call in there is a request to the wineserver; run with the server's -d1 to
 * count them. Built with the mingw compiler: -lsetupapi -luuid.
 */
#include <windows.h>
#include <setupapi.h>
#include <initguid.h>
#include <hidclass.h>
#include <stdio.h>
#include <stdlib.h>

int main( int argc, char **argv )
{
    int passes = argc > 1 ? atoi( argv[1] ) : 200, pass, count = 0;
    SP_DEVICE_INTERFACE_DATA iface = { sizeof(iface) };
    char buffer[2048];
    SP_DEVICE_INTERFACE_DETAIL_DATA_W *detail = (void *)buffer;
    LARGE_INTEGER start, end, freq;
    HDEVINFO set;
    DWORD i;

    QueryPerformanceFrequency( &freq );
    QueryPerformanceCounter( &start );
    for (pass = 0; pass < passes; pass++)
    {
        set = SetupDiGetClassDevsW( &GUID_DEVINTERFACE_HID, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE );
        if (set == INVALID_HANDLE_VALUE) { printf( "devenum: SetupDiGetClassDevsW failed, error %lu\n", GetLastError() ); return 1; }
        for (i = 0; SetupDiEnumDeviceInterfaces( set, NULL, &GUID_DEVINTERFACE_HID, i, &iface ); i++)
        {
            detail->cbSize = sizeof(*detail);
            SetupDiGetDeviceInterfaceDetailW( set, &iface, detail, sizeof(buffer), NULL, NULL );
        }
        count = i;
        SetupDiDestroyDeviceInfoList( set );
    }
    QueryPerformanceCounter( &end );
    printf( "devenum: %d passes, %d HID interfaces, %.0f us a pass\n", passes, count,
            (double)(end.QuadPart - start.QuadPart) * 1e6 / freq.QuadPart / passes );
    return 0;
}
