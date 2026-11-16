/*
 * A resizable Direct3D 11 window whose swap chain keeps its first size, as a game in a fixed
 * windowed resolution does, presenting for a number of seconds:
 *
 *   d3d11_resize_test.exe [seconds, default 20] [resize]
 *
 * With "resize" it calls ResizeBuffers on every WM_SIZE instead. Prints the client size it
 * started with and the one it ended with, and the swap chain's buffer size, e.g.
 *   d3d11 resize: client 640x360 -> 1084x668, buffers 640x360, presented 1200
 * On Windows the picture of a swap chain with DXGI_SCALING_STRETCH fills the client area
 * whatever the buffer size; whether it does here is for someone looking at the window.
 *
 * Built for x86_64 with the mingw compiler: -ld3d11 -ldxguid -luuid -luser32.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static IDXGISwapChain *swapchain;
static BOOL resize_buffers;

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_SIZE && resize_buffers && swapchain && LOWORD(lp) && HIWORD(lp))
        IDXGISwapChain_ResizeBuffers( swapchain, 0, LOWORD(lp), HIWORD(lp), DXGI_FORMAT_UNKNOWN, 0 );
    if (msg == WM_CLOSE) { PostQuitMessage( 0 ); return 0; }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

int main( int argc, char **argv )
{
    static const float colour[4] = { 0.8f, 0.3f, 0.2f, 1.0f };
    int seconds = argc > 1 ? atoi( argv[1] ) : 20, presented = 0;
    DXGI_SWAP_CHAIN_DESC sd = { 0 };
    WNDCLASSA cls = { 0 };
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    ID3D11Texture2D *back;
    ID3D11RenderTargetView *rtv;
    RECT rc, start_rc;
    DWORD end;
    MSG msg;
    HWND hwnd;
    HRESULT hr;

    resize_buffers = argc > 2 && !strcmp( argv[2], "resize" );
    cls.lpfnWndProc = wndproc;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.lpszClassName = "d3d11_resize_test";
    cls.hCursor = LoadCursorA( NULL, (LPCSTR)IDC_ARROW );
    RegisterClassA( &cls );
    rc.left = 0; rc.top = 0; rc.right = 640; rc.bottom = 360;
    AdjustWindowRect( &rc, WS_OVERLAPPEDWINDOW, FALSE );
    hwnd = CreateWindowExA( 0, "d3d11_resize_test", "d3d11_resize_test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            160, 160, rc.right - rc.left, rc.bottom - rc.top, 0, 0, cls.hInstance, NULL );
    GetClientRect( hwnd, &start_rc );

    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = D3D11CreateDeviceAndSwapChain( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                        &sd, &swapchain, &device, NULL, &context );
    if (FAILED(hr)) { printf( "d3d11 resize: no device or swap chain, %#lx\n", hr ); return 1; }

    end = GetTickCount() + seconds * 1000;
    while (GetTickCount() < end)
    {
        while (PeekMessageA( &msg, 0, 0, 0, PM_REMOVE ))
        {
            if (msg.message == WM_QUIT) end = 0;
            DispatchMessageA( &msg );
        }
        if (FAILED(IDXGISwapChain_GetBuffer( swapchain, 0, &IID_ID3D11Texture2D, (void **)&back ))) break;
        ID3D11Device_CreateRenderTargetView( device, (ID3D11Resource *)back, NULL, &rtv );
        ID3D11DeviceContext_ClearRenderTargetView( context, rtv, colour );
        ID3D11RenderTargetView_Release( rtv );
        ID3D11Texture2D_Release( back );
        if (SUCCEEDED(IDXGISwapChain_Present( swapchain, 1, 0 ))) presented++;
    }
    GetClientRect( hwnd, &rc );
    IDXGISwapChain_GetDesc( swapchain, &sd );
    printf( "d3d11 resize: client %ldx%ld -> %ldx%ld, buffers %ux%u, presented %d\n",
            start_rc.right, start_rc.bottom, rc.right, rc.bottom,
            sd.BufferDesc.Width, sd.BufferDesc.Height, presented );
    return 0;
}
