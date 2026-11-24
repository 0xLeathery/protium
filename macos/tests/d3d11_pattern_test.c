/*
 * Fills the screen with a pattern that shows whether each pixel a program draws is one pixel of
 * the display: columns that are white and black in turn, one pixel wide, through Direct3D 11.
 *
 *   d3d11_pattern_test.exe [milliseconds, default 5000] [width height]
 *
 * It opens a window over the whole screen with a swap chain of the screen's size (or of the size
 * given, which the display then has to enlarge), writes the pattern into the back buffer and
 * presents it for that long. Prints "pattern <w>x<h> screen <w>x<h>". In a screenshot of the
 * display's pixels the columns are then white and black in turn when the picture is exact, and
 * grey where it was enlarged or smoothed: macos/tests/pattern_check.py counts them.
 * Built for x86_64 with the mingw compiler: -ld3d11 -ldxguid -luuid -luser32.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int main(int argc, char **argv)
{
    DWORD wait = argc > 1 ? atoi(argv[1]) : 5000, end, *pixels;
    DXGI_SWAP_CHAIN_DESC desc = { 0 };
    ID3D11DeviceContext *context;
    ID3D11Texture2D *buffer;
    IDXGISwapChain *chain;
    ID3D11Device *device;
    WNDCLASSW cls = { 0 };
    int sw, sh, w, h, x, y;
    HWND hwnd;
    MSG msg;

    SetProcessDPIAware();
    sw = GetSystemMetrics(SM_CXSCREEN);
    sh = GetSystemMetrics(SM_CYSCREEN);
    w = argc > 3 ? atoi(argv[2]) : sw;
    h = argc > 3 ? atoi(argv[3]) : sh;

    cls.lpfnWndProc = wndproc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.hbrBackground = GetStockObject(BLACK_BRUSH);
    cls.lpszClassName = L"d3d11_pattern_test";
    RegisterClassW(&cls);
    hwnd = CreateWindowExW(WS_EX_TOPMOST, cls.lpszClassName, L"pattern", WS_POPUP | WS_VISIBLE, 0, 0, sw, sh, NULL, NULL, cls.hInstance, NULL);
    SetForegroundWindow(hwnd);

    desc.BufferCount = 2;
    desc.BufferDesc.Width = w;
    desc.BufferDesc.Height = h;
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.OutputWindow = hwnd;
    desc.SampleDesc.Count = 1;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    if (FAILED(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                             &desc, &chain, &device, NULL, &context)))
    {
        printf("no device\n");
        return 1;
    }
    pixels = malloc((size_t)w * h * 4);
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++) pixels[y * w + x] = (x & 1) ? 0xff000000 : 0xffffffff;

    printf("pattern %dx%d screen %dx%d\n", w, h, sw, sh);
    fflush(stdout);
    end = GetTickCount() + wait;
    while ((int)(end - GetTickCount()) > 0)
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        if (FAILED(IDXGISwapChain_GetBuffer(chain, 0, &IID_ID3D11Texture2D, (void **)&buffer))) break;
        ID3D11DeviceContext_UpdateSubresource(context, (ID3D11Resource *)buffer, 0, NULL, pixels, w * 4, 0);
        ID3D11Texture2D_Release(buffer);
        IDXGISwapChain_Present(chain, 1, 0);
    }
    return 0;
}
