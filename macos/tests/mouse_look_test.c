/*
 * Reads the mouse the way a first-person game does, and prints what every frame got:
 *
 *   mouse_look_test.exe recentre|rawinput|menu [seconds, default 8]
 *
 * It opens a borderless window over the screen and, 60 times a second:
 *   recentre  hides the pointer, pumps messages, asks where the pointer is (GetCursorPos), takes
 *             its distance from the middle of the window as the movement, and puts it back there
 *             (SetCursorPos). Call of Duty: World at War and Modern Warfare Remastered do this.
 *   rawinput  the same, but the movement is the sum of the WM_INPUT messages of the frame, as in
 *             Red Dead Redemption 2.
 *   menu      does the first for a second, then shows the pointer and leaves it alone, and prints
 *             for every click where the click was and where the pointer is.
 *   hidden    a menu with a pointer the game draws itself: the pointer stays hidden and is put
 *             in the middle once, then left alone; prints clicks as menu does, and at the end
 *             where the pointer is.
 * Lines, to stdout:
 *   start <ms>                                   the loop starts (ms since the program began)
 *   frame <n> <ms> <dx> <dy> <get us> <set us>   a frame, and how long the two calls took
 *   shown <x> <y> last set <x> <y>               menu: the pointer when it shows again
 *   click <x> <y> pointer <x> <y>                menu, hidden: a click and the pointer at that moment
 *   end pointer <x> <y>                          hidden: where the pointer is at the end
 * macos/tests/mouse_feed.swift moves the mouse meanwhile and macos/tests/check-mouse.sh reads
 * the lines. It takes the pointer and the front of the screen while it runs.
 *
 * Built for x86_64 with the mingw compiler: -luser32 -lgdi32.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static LONG raw_x, raw_y;
static BOOL hide_pointer = TRUE;
static LARGE_INTEGER freq, began;

static double now_ms(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter( &t );
    return (t.QuadPart - began.QuadPart) * 1000.0 / freq.QuadPart;
}

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    switch (msg)
    {
    case WM_SETCURSOR:
        if (hide_pointer) { SetCursor( NULL ); return TRUE; }
        break;
    case WM_INPUT:
    {
        RAWINPUT in;
        UINT size = sizeof(in);
        if (GetRawInputData( (HRAWINPUT)lp, RID_INPUT, &in, &size, sizeof(RAWINPUTHEADER) ) != (UINT)-1 &&
            in.header.dwType == RIM_TYPEMOUSE && !(in.data.mouse.usFlags & MOUSE_MOVE_ABSOLUTE))
        {
            raw_x += in.data.mouse.lLastX;
            raw_y += in.data.mouse.lLastY;
        }
        break;
    }
    case WM_LBUTTONDOWN:
    {
        POINT click = { (short)LOWORD(lp), (short)HIWORD(lp) }, pos;
        ClientToScreen( hwnd, &click );
        GetCursorPos( &pos );
        printf( "click %ld %ld pointer %ld %ld\n", click.x, click.y, pos.x, pos.y );
        fflush( stdout );
        return 0;
    }
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static void pump(void)
{
    MSG msg;
    while (PeekMessageA( &msg, 0, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
}

int main( int argc, char **argv )
{
    const char *mode = argc > 1 ? argv[1] : "recentre";
    double seconds = argc > 2 ? atof( argv[2] ) : 8, next, end;
    BOOL raw = !strcmp( mode, "rawinput" ), menu = !strcmp( mode, "menu" ), hidden = !strcmp( mode, "hidden" );
    int w = GetSystemMetrics( SM_CXSCREEN ), h = GetSystemMetrics( SM_CYSCREEN ), frame = 0;
    WNDCLASSA cls = { 0 };
    POINT centre = { w / 2, h / 2 }, pos;
    LARGE_INTEGER a, b, c;
    HWND hwnd;

    QueryPerformanceFrequency( &freq );
    QueryPerformanceCounter( &began );
    cls.lpfnWndProc = wndproc;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.hbrBackground = (HBRUSH)GetStockObject( DKGRAY_BRUSH );
    cls.lpszClassName = "mouse_look_test";
    RegisterClassA( &cls );
    hwnd = CreateWindowExA( WS_EX_TOPMOST, "mouse_look_test", "mouse_look_test", WS_POPUP | WS_VISIBLE,
                            0, 0, w, h, 0, 0, cls.hInstance, NULL );
    SetForegroundWindow( hwnd );
    pump();
    if (raw)
    {
        RAWINPUTDEVICE dev = { 1, 2, 0, hwnd };
        if (!RegisterRawInputDevices( &dev, 1, sizeof(dev) )) { printf( "no raw input: %lu\n", GetLastError() ); return 2; }
    }
    while (ShowCursor( FALSE ) >= 0) {}
    SetCursor( NULL );
    SetCursorPos( centre.x, centre.y );
    Sleep( 1500 );
    pump();
    SetCursorPos( centre.x, centre.y );
    raw_x = raw_y = 0;

    printf( "screen %d %d centre %ld %ld mode %s\nstart %.3f\n", w, h, centre.x, centre.y, mode, now_ms() );
    fflush( stdout );
    if (hidden)
    {
        end = now_ms() + seconds * 1000;
        while (now_ms() < end) { pump(); Sleep( 5 ); }
        GetCursorPos( &pos );
        printf( "end pointer %ld %ld\n", pos.x, pos.y );
        fflush( stdout );
        DestroyWindow( hwnd );
        return 0;
    }
    next = now_ms();
    end = next + (menu ? 1000 : seconds * 1000);
    while (now_ms() < end)
    {
        long dx, dy;

        pump();
        QueryPerformanceCounter( &a );
        GetCursorPos( &pos );
        QueryPerformanceCounter( &b );
        SetCursorPos( centre.x, centre.y );
        QueryPerformanceCounter( &c );
        dx = raw ? raw_x : pos.x - centre.x;
        dy = raw ? raw_y : pos.y - centre.y;
        raw_x = raw_y = 0;
        printf( "frame %d %.3f %ld %ld %ld %ld\n", frame++, now_ms(), dx, dy,
                (long)((b.QuadPart - a.QuadPart) * 1000000 / freq.QuadPart),
                (long)((c.QuadPart - b.QuadPart) * 1000000 / freq.QuadPart) );
        next += 1000.0 / 60;
        while (now_ms() < next - 1.5) Sleep( 1 );
        while (now_ms() < next) {}
    }
    if (menu)
    {
        POINT target = { centre.x + 300, centre.y - 200 };
        SetCursorPos( target.x, target.y );
        hide_pointer = FALSE;
        while (ShowCursor( TRUE ) < 0) {}
        SetCursor( LoadCursorA( NULL, (LPCSTR)IDC_ARROW ) );
        pump();
        Sleep( 300 );
        pump();
        GetCursorPos( &pos );
        printf( "shown %ld %ld last set %ld %ld\n", pos.x, pos.y, target.x, target.y );
        fflush( stdout );
        end = now_ms() + seconds * 1000;
        while (now_ms() < end) { pump(); Sleep( 5 ); }
    }
    fflush( stdout );
    DestroyWindow( hwnd );
    return 0;
}
