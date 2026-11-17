/*
 * Renders with Direct3D 12 into a texture and reads a pixel back: no window and no swap chain,
 * so it shows the device, the shader translation and the draw path without the display driver.
 *
 * Creates a device on the first DXGI adapter, compiles two HLSL shaders with D3DCompile, makes
 * a root signature and a pipeline state from them, clears a 64x64 render target, draws a
 * triangle that covers it in another colour, copies the target into a read-back buffer and
 * maps it. Then it makes a shader resource view and an unordered access view of no elements
 * (NumElements 0) on a buffer, as The Last of Us Part II does while it starts: Vulkan has no
 * buffer view of range 0, and the driver aborted the process on the one vkd3d-proton asked for.
 * Last it registers a video memory budget event with the adapter and expects it signalled at
 * once, as Windows does: Red Dead Redemption 2 waits for that before it makes its window.
 *
 * Prints one line, e.g.
 *   d3d12: vkd3d 1, adapter "Apple M4 Pro", feature level c100, pixel 4080bfff, expected 4080bfff
 * and exits 0 when the pixel is the colour drawn (each channel within 1). "vkd3d" says whether
 * d3d12core.dll, which Wine's own Direct3D 12 does not load its devices from, is in the
 * process and exports vkd3d-proton's entry point for it (D3D12GetInterface).
 *
 * Built for x86_64 with the mingw compiler: -ld3d12 -ldxgi -ld3dcompiler_47 -ldxguid -luuid.
 */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <dxgi1_4.h>
#include <d3d12.h>
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
    printf( "d3d12: %s failed, hr %08lx\n", what, (unsigned long)hr );
    return 2;
}

static HRESULT compile( const char *source, const char *target, ID3DBlob **code )
{
    ID3DBlob *errors = NULL;
    HRESULT hr = D3DCompile( source, strlen( source ), NULL, NULL, NULL, "main", target, 0, 0, code, &errors );

    if (errors) ID3D10Blob_Release( errors );
    return hr;
}

static int close_to( unsigned int a, unsigned int b )
{
    return a > b ? a - b <= 1 : b - a <= 1;
}

int main(void)
{
    static const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_0,
                                                D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    static const float clear_colour[4] = { 1.0f, 0.0f, 0.0f, 1.0f };
    static const unsigned char expected[4] = { 0x40, 0x80, 0xbf, 0xff };
    D3D12_FEATURE_DATA_FEATURE_LEVELS level_data = { ARRAYSIZE(levels), levels, 0 };
    D3D12_COMMAND_QUEUE_DESC queue_desc = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1 };
    D3D12_HEAP_PROPERTIES default_heap = { D3D12_HEAP_TYPE_DEFAULT }, readback_heap = { D3D12_HEAP_TYPE_READBACK };
    D3D12_RESOURCE_DESC target_desc = { 0 }, buffer_desc = { 0 };
    D3D12_CLEAR_VALUE clear_value = { DXGI_FORMAT_R8G8B8A8_UNORM };
    D3D12_ROOT_SIGNATURE_DESC root_desc = { 0 };
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pso_desc = { 0 };
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint = { 0 };
    D3D12_TEXTURE_COPY_LOCATION copy_src = { 0 }, copy_dst = { 0 };
    D3D12_RESOURCE_BARRIER barrier = { 0 };
    D3D12_VIEWPORT viewport = { 0, 0, SIZE, SIZE, 0, 1 };
    D3D12_RECT scissor = { 0, 0, SIZE, SIZE };
    D3D12_RANGE read_range = { 0, 0 }, no_write = { 0, 0 };
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    DXGI_ADAPTER_DESC1 adapter_desc = { { 0 } };
    IDXGIFactory4 *factory = NULL;
    IDXGIAdapter1 *adapter = NULL;
    ID3D12Device *device = NULL;
    ID3D12CommandQueue *queue = NULL;
    ID3D12CommandAllocator *allocator = NULL;
    ID3D12GraphicsCommandList *list = NULL;
    ID3D12DescriptorHeap *rtv_heap = NULL;
    ID3D12Resource *target = NULL, *readback = NULL;
    ID3D12RootSignature *root = NULL;
    ID3D12PipelineState *pso = NULL;
    ID3D12Fence *fence = NULL;
    ID3DBlob *vs_code = NULL, *ps_code = NULL, *root_blob = NULL;
    HMODULE core = GetModuleHandleA( "d3d12core.dll" );
    UINT64 total_bytes = 0;
    HANDLE event;
    unsigned char *data = NULL, pixel[4];
    char name[128] = "";
    HRESULT hr;
    int vkd3d, ok;

    if (FAILED(hr = CreateDXGIFactory1( &IID_IDXGIFactory4, (void **)&factory ))) return fail( "CreateDXGIFactory1", hr );
    if (FAILED(hr = IDXGIFactory4_EnumAdapters1( factory, 0, &adapter ))) return fail( "EnumAdapters1", hr );
    IDXGIAdapter1_GetDesc1( adapter, &adapter_desc );
    WideCharToMultiByte( CP_UTF8, 0, adapter_desc.Description, -1, name, sizeof(name), NULL, NULL );

    if (FAILED(hr = D3D12CreateDevice( (IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device )))
        return fail( "D3D12CreateDevice", hr );
    core = GetModuleHandleA( "d3d12core.dll" );
    vkd3d = core && GetProcAddress( core, "D3D12GetInterface" );
    ID3D12Device_CheckFeatureSupport( device, D3D12_FEATURE_FEATURE_LEVELS, &level_data, sizeof(level_data) );

    if (FAILED(hr = ID3D12Device_CreateCommandQueue( device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue )))
        return fail( "CreateCommandQueue", hr );
    if (FAILED(hr = ID3D12Device_CreateCommandAllocator( device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&allocator )))
        return fail( "CreateCommandAllocator", hr );
    if (FAILED(hr = ID3D12Device_CreateFence( device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence )))
        return fail( "CreateFence", hr );

    /* the render target and its view */
    target_desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    target_desc.Width = SIZE;
    target_desc.Height = SIZE;
    target_desc.DepthOrArraySize = 1;
    target_desc.MipLevels = 1;
    target_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    target_desc.SampleDesc.Count = 1;
    target_desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    memcpy( clear_value.Color, clear_colour, sizeof(clear_colour) );
    if (FAILED(hr = ID3D12Device_CreateCommittedResource( device, &default_heap, D3D12_HEAP_FLAG_NONE, &target_desc,
                                                          D3D12_RESOURCE_STATE_RENDER_TARGET, &clear_value,
                                                          &IID_ID3D12Resource, (void **)&target )))
        return fail( "CreateCommittedResource (render target)", hr );
    if (FAILED(hr = ID3D12Device_CreateDescriptorHeap( device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap )))
        return fail( "CreateDescriptorHeap", hr );
    rtv = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart( rtv_heap );
    ID3D12Device_CreateRenderTargetView( device, target, NULL, rtv );

    /* the buffer the target is read back through */
    ID3D12Device_GetCopyableFootprints( device, &target_desc, 0, 1, 0, &footprint, NULL, NULL, &total_bytes );
    buffer_desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    buffer_desc.Width = total_bytes;
    buffer_desc.Height = 1;
    buffer_desc.DepthOrArraySize = 1;
    buffer_desc.MipLevels = 1;
    buffer_desc.SampleDesc.Count = 1;
    buffer_desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if (FAILED(hr = ID3D12Device_CreateCommittedResource( device, &readback_heap, D3D12_HEAP_FLAG_NONE, &buffer_desc,
                                                          D3D12_RESOURCE_STATE_COPY_DEST, NULL,
                                                          &IID_ID3D12Resource, (void **)&readback )))
        return fail( "CreateCommittedResource (read-back buffer)", hr );

    /* shaders, root signature and pipeline state */
    if (FAILED(hr = compile( vs_source, "vs_5_0", &vs_code ))) return fail( "D3DCompile (vertex shader)", hr );
    if (FAILED(hr = compile( ps_source, "ps_5_0", &ps_code ))) return fail( "D3DCompile (pixel shader)", hr );
    if (FAILED(hr = D3D12SerializeRootSignature( &root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &root_blob, NULL )))
        return fail( "D3D12SerializeRootSignature", hr );
    if (FAILED(hr = ID3D12Device_CreateRootSignature( device, 0, ID3D10Blob_GetBufferPointer( root_blob ),
                                                      ID3D10Blob_GetBufferSize( root_blob ),
                                                      &IID_ID3D12RootSignature, (void **)&root )))
        return fail( "CreateRootSignature", hr );
    pso_desc.pRootSignature = root;
    pso_desc.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer( vs_code );
    pso_desc.VS.BytecodeLength = ID3D10Blob_GetBufferSize( vs_code );
    pso_desc.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer( ps_code );
    pso_desc.PS.BytecodeLength = ID3D10Blob_GetBufferSize( ps_code );
    pso_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pso_desc.SampleMask = ~0u;
    pso_desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pso_desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pso_desc.RasterizerState.DepthClipEnable = TRUE;
    pso_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pso_desc.NumRenderTargets = 1;
    pso_desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pso_desc.SampleDesc.Count = 1;
    if (FAILED(hr = ID3D12Device_CreateGraphicsPipelineState( device, &pso_desc, &IID_ID3D12PipelineState, (void **)&pso )))
        return fail( "CreateGraphicsPipelineState", hr );

    /* clear, draw, copy */
    if (FAILED(hr = ID3D12Device_CreateCommandList( device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, pso,
                                                    &IID_ID3D12GraphicsCommandList, (void **)&list )))
        return fail( "CreateCommandList", hr );
    ID3D12GraphicsCommandList_SetGraphicsRootSignature( list, root );
    ID3D12GraphicsCommandList_RSSetViewports( list, 1, &viewport );
    ID3D12GraphicsCommandList_RSSetScissorRects( list, 1, &scissor );
    ID3D12GraphicsCommandList_OMSetRenderTargets( list, 1, &rtv, FALSE, NULL );
    ID3D12GraphicsCommandList_ClearRenderTargetView( list, rtv, clear_colour, 0, NULL );
    ID3D12GraphicsCommandList_IASetPrimitiveTopology( list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST );
    ID3D12GraphicsCommandList_DrawInstanced( list, 3, 1, 0, 0 );
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = target;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    ID3D12GraphicsCommandList_ResourceBarrier( list, 1, &barrier );
    copy_src.pResource = target;
    copy_src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    copy_src.SubresourceIndex = 0;
    copy_dst.pResource = readback;
    copy_dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    copy_dst.PlacedFootprint = footprint;
    ID3D12GraphicsCommandList_CopyTextureRegion( list, &copy_dst, 0, 0, 0, &copy_src, NULL );
    if (FAILED(hr = ID3D12GraphicsCommandList_Close( list ))) return fail( "Close", hr );
    ID3D12CommandQueue_ExecuteCommandLists( queue, 1, (ID3D12CommandList **)&list );

    /* wait for the GPU */
    event = CreateEventA( NULL, FALSE, FALSE, NULL );
    if (FAILED(hr = ID3D12CommandQueue_Signal( queue, fence, 1 ))) return fail( "Signal", hr );
    if (FAILED(hr = ID3D12Fence_SetEventOnCompletion( fence, 1, event ))) return fail( "SetEventOnCompletion", hr );
    if (WaitForSingleObject( event, 30000 ) != WAIT_OBJECT_0)
    {
        printf( "d3d12: the GPU did not finish within 30 s (fence at %lu)\n", (unsigned long)ID3D12Fence_GetCompletedValue( fence ) );
        return 2;
    }
    if (FAILED(hr = ID3D12Device_GetDeviceRemovedReason( device ))) return fail( "the device was removed, GetDeviceRemovedReason", hr );

    read_range.End = (SIZE_T)total_bytes;
    if (FAILED(hr = ID3D12Resource_Map( readback, 0, &read_range, (void **)&data ))) return fail( "Map", hr );
    memcpy( pixel, data + footprint.Offset + (SIZE / 2) * footprint.Footprint.RowPitch + (SIZE / 2) * 4, 4 );
    ID3D12Resource_Unmap( readback, 0, &no_write );

    /* views of no elements */
    {
        D3D12_DESCRIPTOR_HEAP_DESC view_heap_desc = { D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 2 };
        D3D12_SHADER_RESOURCE_VIEW_DESC srv_desc = { DXGI_FORMAT_R32_UINT, D3D12_SRV_DIMENSION_BUFFER,
                                                     D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING };
        D3D12_UNORDERED_ACCESS_VIEW_DESC uav_desc = { DXGI_FORMAT_R32_UINT, D3D12_UAV_DIMENSION_BUFFER };
        D3D12_RESOURCE_DESC empty_desc = buffer_desc;
        D3D12_CPU_DESCRIPTOR_HANDLE handle;
        ID3D12DescriptorHeap *view_heap;
        ID3D12Resource *empty_buffer;

        empty_desc.Width = 4096;
        empty_desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        if (FAILED(hr = ID3D12Device_CreateCommittedResource( device, &default_heap, D3D12_HEAP_FLAG_NONE, &empty_desc,
                                                              D3D12_RESOURCE_STATE_COMMON, NULL,
                                                              &IID_ID3D12Resource, (void **)&empty_buffer )))
            return fail( "CreateCommittedResource (buffer for the views of no elements)", hr );
        if (FAILED(hr = ID3D12Device_CreateDescriptorHeap( device, &view_heap_desc, &IID_ID3D12DescriptorHeap, (void **)&view_heap )))
            return fail( "CreateDescriptorHeap (views of no elements)", hr );
        handle = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart( view_heap );
        ID3D12Device_CreateShaderResourceView( device, empty_buffer, &srv_desc, handle );
        handle.ptr += ID3D12Device_GetDescriptorHandleIncrementSize( device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV );
        ID3D12Device_CreateUnorderedAccessView( device, empty_buffer, NULL, &uav_desc, handle );
        if (FAILED(hr = ID3D12Device_GetDeviceRemovedReason( device )))
            return fail( "the device was removed by the views of no elements, GetDeviceRemovedReason", hr );
    }

    /* Windows signals a video memory budget event once as it is registered. Red Dead Redemption 2
     * registers one after it has made its devices and waits for it without a timeout. */
    {
        HANDLE budget_event = CreateEventW( NULL, FALSE, FALSE, NULL );
        IDXGIAdapter3 *adapter3;
        DWORD cookie = 0;

        if (FAILED(hr = IDXGIAdapter1_QueryInterface( adapter, &IID_IDXGIAdapter3, (void **)&adapter3 )))
            return fail( "QueryInterface (IDXGIAdapter3)", hr );
        if (FAILED(hr = IDXGIAdapter3_RegisterVideoMemoryBudgetChangeNotificationEvent( adapter3, budget_event, &cookie )))
            return fail( "RegisterVideoMemoryBudgetChangeNotificationEvent", hr );
        if (WaitForSingleObject( budget_event, 2000 ) != WAIT_OBJECT_0)
        {
            printf( "d3d12: the video memory budget event was not signalled when it was registered\n" );
            return 2;
        }
        IDXGIAdapter3_UnregisterVideoMemoryBudgetChangeNotification( adapter3, cookie );
        IDXGIAdapter3_Release( adapter3 );
    }

    ok = close_to( pixel[0], expected[0] ) && close_to( pixel[1], expected[1] ) && close_to( pixel[2], expected[2] ) && close_to( pixel[3], expected[3] );
    printf( "d3d12: vkd3d %d, adapter \"%s\", feature level %x, pixel %02x%02x%02x%02x, expected %02x%02x%02x%02x\n",
            vkd3d, name, (unsigned int)level_data.MaxSupportedFeatureLevel, pixel[0], pixel[1], pixel[2], pixel[3],
            expected[0], expected[1], expected[2], expected[3] );
    fflush( stdout );
    return ok ? 0 : 1;
}
