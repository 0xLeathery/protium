/*
 * Switches a Direct3D 11 swap chain between windowed and fullscreen, as games do with Alt+Enter
 * or a display setting, and checks the window's client area after each switch:
 *
 *   fullscreen_test.exe [screenshot pause in ms, default 0]
 *
 * Lists the output's display modes, then three times: SetFullscreenState(TRUE), ResizeBuffers to
 * the client size, present 30 frames, check that the client area covers the output; then
 * SetFullscreenState(FALSE), present, check that the window has its first size again. The output
 * may change its mode to the one nearest the buffers, as on Windows. Prints one
 * line, e.g.
 *   fullscreen: 12 modes, 3/3 switches, fullscreen 640x480, windowed 640x360
 * and exits 0 when every switch succeeded with the expected sizes. With a pause, it waits that long
 * in each state, for a screenshot from outside.
 *
 * Built for x86_64 with the mingw compiler: -ld3d11 -ldxgi -ldxguid -luuid -luser32.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>

static IDXGISwapChain *swapchain;
static ID3D11Device *device;
static ID3D11DeviceContext *context;

static void pump(void)
{
    MSG msg;
    while (PeekMessageA( &msg, 0, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
}

static void present( int frames, const float *colour )
{
    ID3D11Texture2D *back;
    ID3D11RenderTargetView *rtv;
    int i;

    for (i = 0; i < frames; i++)
    {
        pump();
        if (FAILED(IDXGISwapChain_GetBuffer( swapchain, 0, &IID_ID3D11Texture2D, (void **)&back ))) return;
        ID3D11Device_CreateRenderTargetView( device, (ID3D11Resource *)back, NULL, &rtv );
        ID3D11DeviceContext_ClearRenderTargetView( context, rtv, colour );
        ID3D11RenderTargetView_Release( rtv );
        ID3D11Texture2D_Release( back );
        IDXGISwapChain_Present( swapchain, 1, 0 );
    }
}

static void resize_to_client( HWND hwnd )
{
    RECT rc;
    GetClientRect( hwnd, &rc );
    IDXGISwapChain_ResizeBuffers( swapchain, 0, rc.right, rc.bottom, DXGI_FORMAT_UNKNOWN, 0 );
}

int main( int argc, char **argv )
{
    static const float green[4] = { 0.2f, 0.8f, 0.4f, 1.0f }, blue[4] = { 0.2f, 0.4f, 0.8f, 1.0f };
    int pause = argc > 1 ? atoi( argv[1] ) : 0, done = 0, i;
    DXGI_SWAP_CHAIN_DESC sd = { 0 };
    DXGI_OUTPUT_DESC od;
    IDXGIOutput *output;
    WNDCLASSA cls = { 0 };
    RECT rc, first, client = { 0 };
    UINT modes = 0;
    HWND hwnd;
    HRESULT hr;

    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.hCursor = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    cls.lpszClassName = "fullscreen_test";
    RegisterClassA( &cls );
    rc.left = 0; rc.top = 0; rc.right = 640; rc.bottom = 360;
    AdjustWindowRect( &rc, WS_OVERLAPPEDWINDOW, FALSE );
    hwnd = CreateWindowExA( 0, "fullscreen_test", "fullscreen_test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            160, 160, rc.right - rc.left, rc.bottom - rc.top, 0, 0, cls.hInstance, NULL );
    pump();
    GetClientRect( hwnd, &first );

    sd.BufferCount = 2;
    sd.BufferDesc.Width = first.right;
    sd.BufferDesc.Height = first.bottom;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;
    if (FAILED(hr = D3D11CreateDeviceAndSwapChain( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                                   &sd, &swapchain, &device, NULL, &context )))
    {
        printf( "fullscreen: no device or swap chain, %#lx\n", hr );
        return 1;
    }
    if (FAILED(hr = IDXGISwapChain_GetContainingOutput( swapchain, &output )))
    {
        printf( "fullscreen: no output, %#lx\n", hr );
        return 1;
    }
    IDXGIOutput_GetDesc( output, &od );
    IDXGIOutput_GetDisplayModeList( output, DXGI_FORMAT_R8G8B8A8_UNORM, 0, &modes, NULL );
    present( 30, blue );

    for (i = 0; i < 3; i++)
    {
        if (FAILED(hr = IDXGISwapChain_SetFullscreenState( swapchain, TRUE, NULL )))
        {
            printf( "fullscreen: switch %d to fullscreen failed, %#lx\n", i, hr );
            break;
        }
        resize_to_client( hwnd );
        present( 30, green );
        if (pause) Sleep( pause );
        GetClientRect( hwnd, &client );
        /* with DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH the output takes the mode nearest the buffers,
         * as on Windows: compare with the output as it is now */
        IDXGIOutput_GetDesc( output, &od );
        if (client.right != od.DesktopCoordinates.right - od.DesktopCoordinates.left ||
            client.bottom != od.DesktopCoordinates.bottom - od.DesktopCoordinates.top)
        {
            printf( "fullscreen: switch %d, client %ldx%ld is not the output's %ldx%ld\n", i, client.right, client.bottom,
                    od.DesktopCoordinates.right - od.DesktopCoordinates.left, od.DesktopCoordinates.bottom - od.DesktopCoordinates.top );
            break;
        }
        if (FAILED(hr = IDXGISwapChain_SetFullscreenState( swapchain, FALSE, NULL )))
        {
            printf( "fullscreen: switch %d back to windowed failed, %#lx\n", i, hr );
            break;
        }
        resize_to_client( hwnd );
        present( 30, blue );
        if (pause) Sleep( pause );
        GetClientRect( hwnd, &rc );
        if (!EqualRect( &rc, &first ))
        {
            printf( "fullscreen: switch %d, windowed client %ldx%ld is not the first %ldx%ld\n", i, rc.right, rc.bottom,
                    first.right, first.bottom );
            break;
        }
        done++;
    }
    if (done == 3)
        printf( "fullscreen: %u modes, 3/3 switches, fullscreen %ldx%ld, windowed %ldx%ld\n", modes, client.right,
                client.bottom, first.right, first.bottom );
    return done == 3 ? 0 : 1;
}
