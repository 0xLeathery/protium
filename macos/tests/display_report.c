/*
 * Prints what a program is told about the primary display, each on a line of its own:
 *
 *   display_report.exe [unaware]
 *
 *   monitor 3840x2160            the primary monitor's rectangle
 *   current 3840x2160@60         the current display mode
 *   largest 3840x2160            the largest mode in the list
 *   modes 42                     how many modes are listed
 *   metrics 3840x2160            SM_CXSCREEN x SM_CYSCREEN
 *   devcaps 3840x2160            GetDeviceCaps HORZRES x VERTRES of the screen
 *   dpi 192 system 192           LOGPIXELSX of the screen, and GetDpiForSystem
 *
 * On a Mac's HiDPI display these are its pixels when Wine's Mac driver is in Retina mode and
 * its points when it is not, and all of them have to agree: macos/tests/check-hires.sh compares
 * them. With "unaware" it does not say that it lays itself out for the display's DPI, as most
 * older games do not: Windows then tells it sizes as they would be at 96 DPI. A console program: it opens no window. Built with the mingw compiler: -luser32 -lgdi32.
 */
#define _WIN32_WINNT 0x0A00   /* GetDpiForSystem */
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    MONITORINFO info = { sizeof(info) };
    DEVMODEW mode = { .dmSize = sizeof(mode) };
    unsigned int i, count = 0, best_w = 0, best_h = 0;
    HDC dc = GetDC(NULL);

    /* say that this program lays itself out for the display's DPI, so that it is told the
     * real numbers; without it Windows answers 96 whatever the display */
    if (argc < 2 || strcmp(argv[1], "unaware")) SetProcessDPIAware();

    GetMonitorInfoW(MonitorFromPoint((POINT){ 0, 0 }, MONITOR_DEFAULTTOPRIMARY), &info);
    printf("monitor %ldx%ld\n", info.rcMonitor.right - info.rcMonitor.left, info.rcMonitor.bottom - info.rcMonitor.top);

    if (EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &mode))
        printf("current %lux%lu@%lu\n", mode.dmPelsWidth, mode.dmPelsHeight, mode.dmDisplayFrequency);
    for (i = 0; EnumDisplaySettingsW(NULL, i, &mode); i++)
    {
        count++;
        if ((unsigned long long)mode.dmPelsWidth * mode.dmPelsHeight > (unsigned long long)best_w * best_h)
        {
            best_w = mode.dmPelsWidth;
            best_h = mode.dmPelsHeight;
        }
    }
    printf("largest %ux%u\nmodes %u\n", best_w, best_h, count);
    printf("metrics %dx%d\n", GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    printf("devcaps %dx%d\n", GetDeviceCaps(dc, HORZRES), GetDeviceCaps(dc, VERTRES));
    printf("dpi %d system %u\n", GetDeviceCaps(dc, LOGPIXELSX), GetDpiForSystem());
    ReleaseDC(NULL, dc);
    return 0;
}
