/*
 * Shows a window whose cursor is a plain 32x32 block of one colour (255,0,255), puts the pointer
 * in the middle of the window and keeps it there:
 *
 *   cursor_size_test.exe [milliseconds, default 4000]
 *
 * Prints "cursor 32x32 at <x> <y>" (the pointer's place, in the program's pixels) once the window
 * is up. A screenshot with the pointer in it (screencapture -C) then shows how large the block is
 * on the screen: macos/tests/check-hires.sh counts its pixels. A program's own cursor should
 * cover as much of the screen whether Wine's Mac driver shows the display in points or in
 * pixels. It takes the pointer: run it only while nobody is using the Mac.
 * Built with the mingw compiler: -luser32 -lgdi32.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int main(int argc, char **argv)
{
    DWORD wait = argc > 1 ? atoi(argv[1]) : 4000, end;
    BITMAPINFO info = { { sizeof(BITMAPINFOHEADER), 32, -32, 1, 32, BI_RGB } };
    DWORD pixels[32 * 32], mask[32] = { 0 };
    ICONINFO icon = { FALSE, 0, 0 };
    WNDCLASSW cls = { 0 };
    HCURSOR cursor;
    HWND hwnd;
    POINT pt;
    MSG msg;
    HDC dc;
    int i;

    for (i = 0; i < 32 * 32; i++) pixels[i] = 0xffff00ff;
    dc = GetDC(NULL);
    icon.hbmColor = CreateDIBitmap(dc, &info.bmiHeader, CBM_INIT, pixels, &info, DIB_RGB_COLORS);
    icon.hbmMask = CreateBitmap(32, 32, 1, 1, mask);
    ReleaseDC(NULL, dc);
    if (!(cursor = CreateIconIndirect(&icon))) { printf("no cursor\n"); return 1; }

    cls.lpfnWndProc = wndproc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hCursor = cursor;
    cls.hbrBackground = GetStockObject(BLACK_BRUSH);
    cls.lpszClassName = L"cursor_size_test";
    RegisterClassW(&cls);
    hwnd = CreateWindowW(cls.lpszClassName, L"cursor size", WS_POPUP | WS_VISIBLE, 200, 200, 800, 600, NULL, NULL, cls.hInstance, NULL);
    SetForegroundWindow(hwnd);
    SetCursorPos(600, 500);
    SetCursor(cursor);

    end = GetTickCount() + wait;
    GetCursorPos(&pt);
    printf("cursor 32x32 at %ld %ld\n", pt.x, pt.y);
    fflush(stdout);
    while ((int)(end - GetTickCount()) > 0)
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        Sleep(10);
    }
    return 0;
}
