/*
 * Presents Direct3D 11 frames in a window: a swap chain on a window of its own, cleared to a
 * colour and presented a number of times.
 *
 *   d3d11_window_test.exe [frames, default 60]
 *
 * Prints one line, e.g.
 *   d3d11 window: dxmt 1, swap chain 0, 640x360, presented 60/60, back buffer 3366cc
 * and exits 0 when the swap chain was created, every Present() succeeded and the back buffer
 * read back as the colour it was cleared to. That shows the path up to the hand-over of a frame;
 * whether the frame is on the screen is for someone looking at it, or for a check outside Wine.
 *
 * Built for x86_64 with the mingw compiler: -ld3d11 -ldxguid -luuid -luser32.
 */
#define COBJMACROS
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>
#include <d3d11.h>

#define WIDTH   640
#define HEIGHT  360

static void pump(void)
{
    MSG msg;
    while (PeekMessageA( &msg, 0, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
}

int main( int argc, char **argv )
{
    static const float colour[4] = { 0.2f, 0.4f, 0.8f, 1.0f };
    int frames = argc > 1 ? atoi( argv[1] ) : 60, presented = 0, i;
    D3D11_TEXTURE2D_DESC desc;
    D3D11_MAPPED_SUBRESOURCE map;
    DXGI_SWAP_CHAIN_DESC sd = { 0 };
    WNDCLASSA cls = { 0 };
    D3D_FEATURE_LEVEL level = 0;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Texture2D *backbuffer = NULL, *staging = NULL;
    ID3D11RenderTargetView *view = NULL;
    unsigned char pixel[4] = { 0 };
    HRESULT hr, sc_hr;
    HWND hwnd;

    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.hCursor = LoadCursorA( 0, (const char *)IDC_ARROW );
    cls.lpszClassName = "d3d11_window_test";
    RegisterClassA( &cls );
    hwnd = CreateWindowExA( 0, "d3d11_window_test", "d3d11_window_test", WS_POPUP | WS_VISIBLE,
                            160, 160, WIDTH, HEIGHT, 0, 0, cls.hInstance, NULL );
    if (!hwnd)
    {
        printf( "d3d11 window: CreateWindowEx failed, error %lu\n", GetLastError() );
        return 1;
    }
    pump();

    sd.BufferCount = 2;
    sd.BufferDesc.Width = WIDTH;
    sd.BufferDesc.Height = HEIGHT;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    sc_hr = D3D11CreateDeviceAndSwapChain( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                           &sd, &swapchain, &device, &level, &context );
    if (FAILED( sc_hr ) || !swapchain)
    {
        printf( "d3d11 window: dxmt %d, swap chain %08lx\n", GetModuleHandleA( "winemetal.dll" ) != NULL, (unsigned long)sc_hr );
        return 1;
    }
    hr = IDXGISwapChain_GetBuffer( swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer );
    if (SUCCEEDED( hr )) hr = ID3D11Device_CreateRenderTargetView( device, (ID3D11Resource *)backbuffer, NULL, &view );
    if (FAILED( hr ))
    {
        printf( "d3d11 window: back buffer or its view failed, hr %08lx\n", (unsigned long)hr );
        return 1;
    }

    for (i = 0; i < frames; i++)
    {
        ID3D11DeviceContext_OMSetRenderTargets( context, 1, &view, NULL );
        ID3D11DeviceContext_ClearRenderTargetView( context, view, colour );
        if (i == frames - 1)
        {
            /* read the last frame back before it is presented */
            ID3D11Texture2D_GetDesc( backbuffer, &desc );
            desc.Usage = D3D11_USAGE_STAGING;
            desc.BindFlags = 0;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            desc.MiscFlags = 0;
            if (SUCCEEDED( ID3D11Device_CreateTexture2D( device, &desc, NULL, &staging ) ))
            {
                ID3D11DeviceContext_CopyResource( context, (ID3D11Resource *)staging, (ID3D11Resource *)backbuffer );
                if (SUCCEEDED( ID3D11DeviceContext_Map( context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map ) ))
                {
                    memcpy( pixel, (const unsigned char *)map.pData + (HEIGHT / 2) * map.RowPitch + (WIDTH / 2) * 4, 4 );
                    ID3D11DeviceContext_Unmap( context, (ID3D11Resource *)staging, 0 );
                }
            }
        }
        if (SUCCEEDED( IDXGISwapChain_Present( swapchain, 1, 0 ) )) presented++;
        pump();
    }

    printf( "d3d11 window: dxmt %d, swap chain %lx, %dx%d, presented %d/%d, back buffer %02x%02x%02x\n",
            GetModuleHandleA( "winemetal.dll" ) != NULL, (unsigned long)sc_hr, WIDTH, HEIGHT, presented, frames,
            pixel[0], pixel[1], pixel[2] );
    fflush( stdout );
    DestroyWindow( hwnd );
    return (presented == frames && abs( pixel[0] - 0x33 ) <= 1 && abs( pixel[1] - 0x66 ) <= 1 && abs( pixel[2] - 0xcc ) <= 1) ? 0 : 1;
}
