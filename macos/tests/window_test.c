/*
 * Opens a window through Wine's display driver, paints it and reads a pixel back.
 *
 *   window_test.exe [milliseconds to keep the window open after it is painted, default 1500]
 *
 * Prints one line, e.g.
 *   window: driver winemac.drv, screen 1728x1117, 320x240 at 120,120, painted 1, pixel 563412, visible 1
 * and exits 0 when the Mac driver is loaded, the window got its WM_PAINT and the pixel is the
 * colour that was painted. While the window is open, something outside Wine can check that
 * macOS has a window of that size (see list_windows.c).
 *
 * Built for aarch64, ARM64EC or x86_64; it only uses kernel32, user32 and gdi32.
 */
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

#define WIDTH   320
#define HEIGHT  240
#define COLOUR  RGB( 0x12, 0x34, 0x56 )

static int painted;

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_PAINT)
    {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint( hwnd, &ps );
        HBRUSH brush = CreateSolidBrush( COLOUR );
        RECT rect;

        GetClientRect( hwnd, &rect );
        FillRect( dc, &rect, brush );
        DeleteObject( brush );
        EndPaint( hwnd, &ps );
        painted = 1;
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static void pump( DWORD ms )
{
    DWORD end = GetTickCount() + ms;
    MSG msg;

    while ((int)(end - GetTickCount()) > 0)
    {
        while (PeekMessageA( &msg, 0, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
        MsgWaitForMultipleObjects( 0, NULL, FALSE, 20, QS_ALLINPUT );
    }
}

int main( int argc, char **argv )
{
    DWORD hold = argc > 1 ? atoi( argv[1] ) : 1500;
    const char *driver = "none";
    WNDCLASSA cls = { 0 };
    COLORREF pixel;
    RECT rect = { 0 };
    HWND hwnd;
    HDC dc;
    int ok;

    cls.lpfnWndProc = wndproc;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.hCursor = LoadCursorA( 0, (const char *)IDC_ARROW );
    cls.lpszClassName = "window_test";
    RegisterClassA( &cls );

    hwnd = CreateWindowExA( 0, "window_test", "window_test", WS_POPUP | WS_VISIBLE,
                            120, 120, WIDTH, HEIGHT, 0, 0, cls.hInstance, NULL );
    if (!hwnd)
    {
        printf( "window: CreateWindowEx failed, error %lu\n", GetLastError() );
        return 1;
    }
    UpdateWindow( hwnd );
    pump( 300 );

    if (GetModuleHandleA( "winemac.drv" )) driver = "winemac.drv";
    else if (GetModuleHandleA( "winex11.drv" )) driver = "winex11.drv";
    else if (GetModuleHandleA( "winewayland.drv" )) driver = "winewayland.drv";

    dc = GetDC( hwnd );
    pixel = GetPixel( dc, 10, 10 );
    ReleaseDC( hwnd, dc );
    GetWindowRect( hwnd, &rect );
    ok = !strcmp( driver, "winemac.drv" ) && painted && pixel == COLOUR;
    printf( "window: driver %s, screen %dx%d, %dx%d at %d,%d, painted %d, pixel %06lx, visible %d\n",
            driver, GetSystemMetrics( SM_CXSCREEN ), GetSystemMetrics( SM_CYSCREEN ),
            (int)(rect.right - rect.left), (int)(rect.bottom - rect.top), (int)rect.left, (int)rect.top,
            painted, (unsigned long)pixel, IsWindowVisible( hwnd ) );
    fflush( stdout );

    pump( hold );
    DestroyWindow( hwnd );
    return ok ? 0 : 1;
}
