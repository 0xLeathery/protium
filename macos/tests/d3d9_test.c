/*
 * Draws with Direct3D 9 into an offscreen render target and reads the colour back:
 *
 *   d3d9_test.exe
 *
 * The device's window is never shown, so no Mac window appears. Prints one line, e.g.
 *   d3d9: adapter "Apple M4 Pro", hal 1, pixel 3366cc
 * and exits 0 when a HAL device was created and the pixel read back as the colour it was
 * cleared to.
 *
 * Built for x86_64 or i686 with the mingw compiler: -ld3d9 -luser32.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>

int main( void )
{
    D3DPRESENT_PARAMETERS pp = { 0 };
    D3DADAPTER_IDENTIFIER9 id = { 0 };
    IDirect3DSurface9 *target, *sysmem;
    IDirect3DDevice9 *device;
    D3DLOCKED_RECT locked;
    IDirect3D9 *d3d;
    DWORD pixel = 0;
    HWND hwnd;
    HRESULT hr;

    hwnd = CreateWindowExA( 0, "static", "d3d9_test", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64, 0, 0, 0, NULL );
    if (!(d3d = Direct3DCreate9( D3D_SDK_VERSION ))) { printf( "d3d9: Direct3DCreate9 failed\n" ); return 1; }
    IDirect3D9_GetAdapterIdentifier( d3d, D3DADAPTER_DEFAULT, 0, &id );

    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = 64;
    pp.BackBufferHeight = 64;
    pp.hDeviceWindow = hwnd;
    if (FAILED(hr = IDirect3D9_CreateDevice( d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                             D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device )))
    {
        printf( "d3d9: adapter \"%s\", CreateDevice %#lx\n", id.Description, hr );
        return 1;
    }
    IDirect3DDevice9_CreateRenderTarget( device, 64, 64, D3DFMT_X8R8G8B8, D3DMULTISAMPLE_NONE, 0, FALSE, &target, NULL );
    IDirect3DDevice9_CreateOffscreenPlainSurface( device, 64, 64, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &sysmem, NULL );
    IDirect3DDevice9_SetRenderTarget( device, 0, target );
    IDirect3DDevice9_Clear( device, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB( 0x33, 0x66, 0xcc ), 1.0f, 0 );
    if (SUCCEEDED(IDirect3DDevice9_GetRenderTargetData( device, target, sysmem )) &&
        SUCCEEDED(IDirect3DSurface9_LockRect( sysmem, &locked, NULL, D3DLOCK_READONLY )))
    {
        pixel = ((DWORD *)locked.pBits)[32 * locked.Pitch / 4 + 32] & 0xffffff;
        IDirect3DSurface9_UnlockRect( sysmem );
    }
    printf( "d3d9: adapter \"%s\", hal 1, pixel %06lx\n", id.Description, pixel );
    return pixel == 0x3366cc ? 0 : 1;
}
