/*
 * Counts the display modes the first output lists in each format a display can be driven in,
 * the way a game asks before it offers resolutions:
 *
 *   display_modes_test.exe
 *
 * prints e.g.
 *   display modes: R8G8B8A8_UNORM 49, R8G8B8A8_UNORM_SRGB 49, ..., R10G10B10_XR_BIAS_A2_UNORM 49
 * and exits 1 when R8G8B8A8_UNORM lists none, another of these formats lists fewer, or a mode
 * comes back without a size or in another format. Wine's own DXGI and DXVK list the display's
 * 32-bit modes for each of them; DXMT listed none for the ones Metal cannot present (B8G8R8X8,
 * R10G10B10_XR_BIAS_A2) until macos/patches/dxmt/0004. A game that finds no modes offers no
 * resolutions. Built with the mingw compiler: -ldxgi -ldxguid -luuid.
 */
#define COBJMACROS
#include <windows.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>

static const struct
{
    DXGI_FORMAT format;
    const char *name;
} formats[] =
{
    { DXGI_FORMAT_R8G8B8A8_UNORM, "R8G8B8A8_UNORM" },
    { DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, "R8G8B8A8_UNORM_SRGB" },
    { DXGI_FORMAT_B8G8R8A8_UNORM, "B8G8R8A8_UNORM" },
    { DXGI_FORMAT_B8G8R8A8_UNORM_SRGB, "B8G8R8A8_UNORM_SRGB" },
    { DXGI_FORMAT_B8G8R8X8_UNORM, "B8G8R8X8_UNORM" },
    { DXGI_FORMAT_B8G8R8X8_UNORM_SRGB, "B8G8R8X8_UNORM_SRGB" },
    { DXGI_FORMAT_R10G10B10A2_UNORM, "R10G10B10A2_UNORM" },
    { DXGI_FORMAT_R10G10B10_XR_BIAS_A2_UNORM, "R10G10B10_XR_BIAS_A2_UNORM" },
};

int main(void)
{
    IDXGIFactory1 *factory;
    IDXGIAdapter1 *adapter;
    IDXGIOutput *output;
    DXGI_MODE_DESC *modes;
    UINT i, j, count, reference = 0;
    int bad = 0;

    if (FAILED(CreateDXGIFactory1( &IID_IDXGIFactory1, (void **)&factory )) ||
        FAILED(IDXGIFactory1_EnumAdapters1( factory, 0, &adapter )) ||
        FAILED(IDXGIAdapter1_EnumOutputs( adapter, 0, &output )))
    {
        printf( "display modes: no output\n" );
        return 1;
    }

    printf( "display modes:" );
    for (i = 0; i < ARRAYSIZE(formats); i++)
    {
        count = 0;
        if (FAILED(IDXGIOutput_GetDisplayModeList( output, formats[i].format, 0, &count, NULL ))) count = 0;
        if (count && (modes = calloc( count, sizeof(*modes) )))
        {
            if (FAILED(IDXGIOutput_GetDisplayModeList( output, formats[i].format, 0, &count, modes ))) bad = 1;
            for (j = 0; j < count; j++)
                if (modes[j].Format != formats[i].format || !modes[j].Width || !modes[j].Height) bad = 1;
            free( modes );
        }
        if (!i) reference = count;
        else if (count < reference) bad = 1;
        printf( "%s %s %u", i ? "," : "", formats[i].name, count );
    }
    printf( "\n" );
    return !reference || bad;
}
