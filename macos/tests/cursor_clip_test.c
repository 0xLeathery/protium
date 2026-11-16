/*
 * Clips the cursor to a single point and releases it, as a game does when it locks the mouse for
 * aiming and frees it for a pause menu, and checks after every step where Windows says the
 * cursor is:
 *
 *   cursor_clip_test.exe [rounds, default 2000]
 *
 * Each round: ClipCursor() to one point (the rectangle Unity uses, left == right and top ==
 * bottom), SetCursorPos() elsewhere, and GetCursorPos() must give the point; then
 * ClipCursor(NULL), SetCursorPos() elsewhere, and GetCursorPos() must give that place, and
 * GetClipCursor() the whole screen. Every 100 rounds another window takes the focus and gives it
 * back. Prints one line, e.g.
 *   cursor clip: 2000/2000 rounds
 * or the first round and step that failed, and exits 0 when every round passed. It moves the
 * Mac's pointer while it runs.
 *
 * Built for x86_64 with the mingw compiler: -luser32 -lgdi32.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static void pump(void)
{
    MSG msg;
    while (PeekMessageA( &msg, 0, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
}

static HWND make_window( const char *title, int x )
{
    HWND hwnd = CreateWindowExA( 0, "cursor_clip_test", title, WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                 x, 200, 400, 300, 0, 0, GetModuleHandleA( NULL ), NULL );
    pump();
    return hwnd;
}

int main( int argc, char **argv )
{
    int rounds = argc > 1 ? atoi( argv[1] ) : 2000, i;
    WNDCLASSA cls = { 0 };
    RECT rect, clip, screen;
    POINT centre, pos;
    HWND main_hwnd, other;

    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.hCursor = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    cls.lpszClassName = "cursor_clip_test";
    RegisterClassA( &cls );
    main_hwnd = make_window( "cursor_clip_test", 200 );
    other = make_window( "cursor_clip_test other", 700 );
    SetForegroundWindow( main_hwnd );
    pump();
    Sleep( 500 );

    GetClientRect( main_hwnd, &rect );
    centre.x = rect.right / 2;
    centre.y = rect.bottom / 2;
    ClientToScreen( main_hwnd, &centre );
    screen.left = GetSystemMetrics( SM_XVIRTUALSCREEN );
    screen.top = GetSystemMetrics( SM_YVIRTUALSCREEN );
    screen.right = screen.left + GetSystemMetrics( SM_CXVIRTUALSCREEN );
    screen.bottom = screen.top + GetSystemMetrics( SM_CYVIRTUALSCREEN );

    for (i = 0; i < rounds; i++)
    {
        int dx = 40 + i % 60, dy = 30 + i % 40;

        if (i && !(i % 100))
        {
            SetForegroundWindow( other );
            pump();
            SetForegroundWindow( main_hwnd );
            pump();
        }

        rect.left = rect.right = centre.x;
        rect.top = rect.bottom = centre.y;
        ClipCursor( &rect );
        SetCursorPos( centre.x + dx, centre.y + dy );
        pump();
        GetCursorPos( &pos );
        if (abs( pos.x - centre.x ) > 1 || abs( pos.y - centre.y ) > 1)
        {
            printf( "cursor clip: round %d, clipped to (%ld,%ld) but the cursor is at (%ld,%ld)\n",
                    i, centre.x, centre.y, pos.x, pos.y );
            ClipCursor( NULL );
            return 1;
        }

        ClipCursor( NULL );
        SetCursorPos( centre.x - dx, centre.y - dy );
        pump();
        GetCursorPos( &pos );
        GetClipCursor( &clip );
        if (pos.x != centre.x - dx || pos.y != centre.y - dy || !EqualRect( &clip, &screen ))
        {
            printf( "cursor clip: round %d, released but the cursor is at (%ld,%ld), not (%ld,%ld), clip (%ld,%ld)-(%ld,%ld)\n",
                    i, pos.x, pos.y, centre.x - dx, centre.y - dy, clip.left, clip.top, clip.right, clip.bottom );
            return 1;
        }
    }
    printf( "cursor clip: %d/%d rounds\n", rounds, rounds );
    return 0;
}
