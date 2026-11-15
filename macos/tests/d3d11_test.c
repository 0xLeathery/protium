/*
 * Renders with Direct3D 11 into a texture and reads a pixel back: no window and no swap chain,
 * so it shows the device, the shader compiler and the draw path without the display driver.
 *
 * Creates a hardware device, compiles two HLSL shaders with D3DCompile, draws a triangle that
 * covers a 64x64 render target in one colour, copies the target to a staging texture and maps
 * it.
 *
 * Prints one line, e.g.
 *   d3d11: dxmt 1, adapter "Apple M4 Pro", feature level b000, pixel 4080bfff, expected 4080bfff
 * and exits 0 when the pixel is the colour drawn (each channel within 1). "dxmt" says whether
 * DXMT's winemetal.dll is in the process, that is whether Direct3D is DXMT's.
 *
 * Built for x86_64 with the mingw compiler: -ld3d11 -ld3dcompiler_47 -ldxguid -luuid.
 */
#define COBJMACROS
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>

#define SIZE 64

static const char vs_source[] =
    "float4 main(uint id : SV_VertexID) : SV_Position\n"
    "{\n"
    "    float2 p = float2((id << 1) & 2, id & 2);\n"
    "    return float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);\n"
    "}\n";
static const char ps_source[] =
    "float4 main() : SV_Target\n"
    "{\n"
    "    return float4(0.25, 0.5, 0.75, 1.0);\n"
    "}\n";

static int fail( const char *what, HRESULT hr )
{
    printf( "d3d11: %s failed, hr %08lx\n", what, (unsigned long)hr );
    return 1;
}

static ID3DBlob *compile( const char *source, const char *target )
{
    ID3DBlob *code = NULL, *errors = NULL;
    HRESULT hr = D3DCompile( source, strlen( source ), NULL, NULL, NULL, "main", target, 0, 0, &code, &errors );

    if (FAILED( hr ))
    {
        printf( "d3d11: D3DCompile %s failed, hr %08lx: %s\n", target, (unsigned long)hr,
                errors ? (const char *)ID3D10Blob_GetBufferPointer( errors ) : "" );
        return NULL;
    }
    return code;
}

int main(void)
{
    static const float black[4] = { 0.0f, 0.0f, 0.0f, 1.0f };
    static const unsigned char expected[4] = { 0x40, 0x80, 0xbf, 0xff };
    D3D11_TEXTURE2D_DESC desc = { SIZE, SIZE, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 }, D3D11_USAGE_DEFAULT,
                                  D3D11_BIND_RENDER_TARGET };
    D3D11_VIEWPORT viewport = { 0.0f, 0.0f, SIZE, SIZE, 0.0f, 1.0f };
    D3D11_MAPPED_SUBRESOURCE map;
    D3D_FEATURE_LEVEL level = 0;
    DXGI_ADAPTER_DESC adapter_desc;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    ID3D11Texture2D *target = NULL, *staging = NULL;
    ID3D11RenderTargetView *view = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    ID3DBlob *vs_code, *ps_code;
    char adapter_name[128] = "?";
    const unsigned char *pixel;
    HRESULT hr;
    int i, ok = 1;

    hr = D3D11CreateDevice( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &device, &level, &context );
    if (FAILED( hr )) return fail( "D3D11CreateDevice", hr );

    if (SUCCEEDED( ID3D11Device_QueryInterface( device, &IID_IDXGIDevice, (void **)&dxgi_device ) ) &&
        SUCCEEDED( IDXGIDevice_GetAdapter( dxgi_device, &adapter ) ) &&
        SUCCEEDED( IDXGIAdapter_GetDesc( adapter, &adapter_desc ) ))
        WideCharToMultiByte( CP_ACP, 0, adapter_desc.Description, -1, adapter_name, sizeof(adapter_name), NULL, NULL );

    if (!(vs_code = compile( vs_source, "vs_4_0" )) || !(ps_code = compile( ps_source, "ps_4_0" ))) return 1;
    hr = ID3D11Device_CreateVertexShader( device, ID3D10Blob_GetBufferPointer( vs_code ), ID3D10Blob_GetBufferSize( vs_code ), NULL, &vs );
    if (FAILED( hr )) return fail( "CreateVertexShader", hr );
    hr = ID3D11Device_CreatePixelShader( device, ID3D10Blob_GetBufferPointer( ps_code ), ID3D10Blob_GetBufferSize( ps_code ), NULL, &ps );
    if (FAILED( hr )) return fail( "CreatePixelShader", hr );

    hr = ID3D11Device_CreateTexture2D( device, &desc, NULL, &target );
    if (FAILED( hr )) return fail( "CreateTexture2D (render target)", hr );
    hr = ID3D11Device_CreateRenderTargetView( device, (ID3D11Resource *)target, NULL, &view );
    if (FAILED( hr )) return fail( "CreateRenderTargetView", hr );
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    hr = ID3D11Device_CreateTexture2D( device, &desc, NULL, &staging );
    if (FAILED( hr )) return fail( "CreateTexture2D (staging)", hr );

    ID3D11DeviceContext_ClearRenderTargetView( context, view, black );
    ID3D11DeviceContext_OMSetRenderTargets( context, 1, &view, NULL );
    ID3D11DeviceContext_RSSetViewports( context, 1, &viewport );
    ID3D11DeviceContext_IASetPrimitiveTopology( context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST );
    ID3D11DeviceContext_VSSetShader( context, vs, NULL, 0 );
    ID3D11DeviceContext_PSSetShader( context, ps, NULL, 0 );
    ID3D11DeviceContext_Draw( context, 3, 0 );
    ID3D11DeviceContext_CopyResource( context, (ID3D11Resource *)staging, (ID3D11Resource *)target );

    hr = ID3D11DeviceContext_Map( context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map );
    if (FAILED( hr )) return fail( "Map", hr );
    pixel = (const unsigned char *)map.pData + (SIZE / 2) * map.RowPitch + (SIZE / 2) * 4;
    for (i = 0; i < 4; i++) if (abs( (int)pixel[i] - (int)expected[i] ) > 1) ok = 0;
    printf( "d3d11: dxmt %d, adapter \"%s\", feature level %x, pixel %02x%02x%02x%02x, expected %02x%02x%02x%02x\n",
            GetModuleHandleA( "winemetal.dll" ) != NULL, adapter_name, (unsigned int)level,
            pixel[0], pixel[1], pixel[2], pixel[3], expected[0], expected[1], expected[2], expected[3] );
    ID3D11DeviceContext_Unmap( context, (ID3D11Resource *)staging, 0 );
    return ok ? 0 : 1;
}
