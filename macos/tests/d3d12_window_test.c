/*
 * Presents Direct3D 12 frames in a window: a flip-model swap chain on a window of its own,
 * each back buffer cleared to a colour and presented, a number of times.
 *
 *   d3d12_window_test.exe [frames, default 60] [resizable]
 *
 * Prints one line, e.g.
 *   d3d12 window: vkd3d 1, swap chain 0, 640x360, presented 60/60, back buffer 33cc66
 * and exits 0 when the swap chain was created, every Present() succeeded and the last back
 * buffer read back as the colour it was cleared to. That shows the path up to the hand-over of a
 * frame; whether the frame is on the screen is for someone looking at it, or for a check
 * outside Wine. The colour is not the one of d3d11_window_test.exe, so that the two windows can
 * be told apart. With "resizable" the window is an ordinary one, which can be resized from outside
 * while the frames are presented; the swap chain keeps its size, so the picture should be
 * stretched to the window.
 *
 * Built for x86_64 with the mingw compiler: -ld3d12 -ldxgi -ldxguid -luuid -luser32.
 */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <dxgi1_4.h>
#include <d3d12.h>

#define WIDTH   640
#define HEIGHT  360
#define BUFFERS 2

static ID3D12Device *device;
static ID3D12CommandQueue *queue;
static ID3D12Fence *fence;
static HANDLE fence_event;
static UINT64 fence_value;

static void pump(void)
{
    MSG msg;
    while (PeekMessageA( &msg, 0, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
}

static int fail( const char *what, HRESULT hr )
{
    printf( "d3d12 window: %s failed, hr %08lx\n", what, (unsigned long)hr );
    return 2;
}

/* wait until the GPU has done everything submitted so far */
static int wait_for_gpu(void)
{
    if (FAILED( ID3D12CommandQueue_Signal( queue, fence, ++fence_value ) )) return 0;
    if (FAILED( ID3D12Fence_SetEventOnCompletion( fence, fence_value, fence_event ) )) return 0;
    return WaitForSingleObject( fence_event, 30000 ) == WAIT_OBJECT_0;
}

static void transition( ID3D12GraphicsCommandList *list, ID3D12Resource *resource,
                        D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after )
{
    D3D12_RESOURCE_BARRIER barrier = { 0 };

    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    ID3D12GraphicsCommandList_ResourceBarrier( list, 1, &barrier );
}

int main( int argc, char **argv )
{
    static const float colour[4] = { 0.2f, 0.8f, 0.4f, 1.0f };
    int frames = argc > 1 ? atoi( argv[1] ) : 60, presented = 0, i, vkd3d;
    D3D12_COMMAND_QUEUE_DESC queue_desc = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, BUFFERS };
    D3D12_HEAP_PROPERTIES readback_heap = { D3D12_HEAP_TYPE_READBACK };
    D3D12_RESOURCE_DESC buffer_desc = { 0 }, target_desc;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint = { 0 };
    D3D12_TEXTURE_COPY_LOCATION copy_src = { 0 }, copy_dst = { 0 };
    D3D12_RANGE read_range = { 0, 0 }, no_write = { 0, 0 };
    D3D12_CPU_DESCRIPTOR_HANDLE rtv[BUFFERS];
    DXGI_SWAP_CHAIN_DESC1 sd = { 0 };
    WNDCLASSA cls = { 0 };
    IDXGIFactory4 *factory = NULL;
    IDXGISwapChain1 *swapchain1 = NULL;
    IDXGISwapChain3 *swapchain = NULL;
    ID3D12CommandAllocator *allocator = NULL;
    ID3D12GraphicsCommandList *list = NULL;
    ID3D12DescriptorHeap *rtv_heap = NULL;
    ID3D12Resource *buffers[BUFFERS] = { NULL }, *readback = NULL;
    unsigned char pixel[4] = { 0 }, *data = NULL;
    UINT64 total_bytes = 0;
    UINT rtv_size, index;
    HMODULE core;
    HRESULT hr, sc_hr;
    HWND hwnd;

    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.hCursor = LoadCursorA( 0, (const char *)IDC_ARROW );
    cls.lpszClassName = "d3d12_window_test";
    RegisterClassA( &cls );
    hwnd = CreateWindowExA( 0, "d3d12_window_test", "d3d12_window_test",
                            (argc > 2 && !strcmp( argv[2], "resizable" ) ? WS_OVERLAPPEDWINDOW : WS_POPUP) | WS_VISIBLE,
                            200, 200, WIDTH, HEIGHT, 0, 0, cls.hInstance, NULL );
    if (!hwnd)
    {
        printf( "d3d12 window: CreateWindowEx failed, error %lu\n", GetLastError() );
        return 1;
    }
    pump();

    if (FAILED(hr = CreateDXGIFactory1( &IID_IDXGIFactory4, (void **)&factory ))) return fail( "CreateDXGIFactory1", hr );
    if (FAILED(hr = D3D12CreateDevice( NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device )))
        return fail( "D3D12CreateDevice", hr );
    core = GetModuleHandleA( "d3d12core.dll" );
    vkd3d = core && GetProcAddress( core, "D3D12GetInterface" );
    if (FAILED(hr = ID3D12Device_CreateCommandQueue( device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue )))
        return fail( "CreateCommandQueue", hr );
    if (FAILED(hr = ID3D12Device_CreateCommandAllocator( device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&allocator )))
        return fail( "CreateCommandAllocator", hr );
    if (FAILED(hr = ID3D12Device_CreateCommandList( device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
                                                    &IID_ID3D12GraphicsCommandList, (void **)&list )))
        return fail( "CreateCommandList", hr );
    ID3D12GraphicsCommandList_Close( list );
    if (FAILED(hr = ID3D12Device_CreateFence( device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence )))
        return fail( "CreateFence", hr );
    fence_event = CreateEventA( NULL, FALSE, FALSE, NULL );

    /* a Direct3D 12 swap chain is made on the command queue and has to be of the flip model */
    sd.Width = WIDTH;
    sd.Height = HEIGHT;
    sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = BUFFERS;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sc_hr = IDXGIFactory4_CreateSwapChainForHwnd( factory, (IUnknown *)queue, hwnd, &sd, NULL, NULL, &swapchain1 );
    if (SUCCEEDED( sc_hr )) sc_hr = IDXGISwapChain1_QueryInterface( swapchain1, &IID_IDXGISwapChain3, (void **)&swapchain );
    if (FAILED( sc_hr ) || !swapchain)
    {
        printf( "d3d12 window: vkd3d %d, swap chain %08lx\n", vkd3d, (unsigned long)sc_hr );
        return 1;
    }

    if (FAILED(hr = ID3D12Device_CreateDescriptorHeap( device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap )))
        return fail( "CreateDescriptorHeap", hr );
    rtv_size = ID3D12Device_GetDescriptorHandleIncrementSize( device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV );
    for (i = 0; i < BUFFERS; i++)
    {
        if (FAILED(hr = IDXGISwapChain3_GetBuffer( swapchain, i, &IID_ID3D12Resource, (void **)&buffers[i] )))
            return fail( "GetBuffer", hr );
        rtv[i] = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart( rtv_heap );
        rtv[i].ptr += i * rtv_size;
        ID3D12Device_CreateRenderTargetView( device, buffers[i], NULL, rtv[i] );
    }

    /* the buffer the last frame is read back through */
    target_desc = ID3D12Resource_GetDesc( buffers[0] );
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

    for (i = 0; i < frames; i++)
    {
        index = IDXGISwapChain3_GetCurrentBackBufferIndex( swapchain );
        if (index >= BUFFERS) return fail( "GetCurrentBackBufferIndex gave an index out of range, it", index );
        ID3D12CommandAllocator_Reset( allocator );
        ID3D12GraphicsCommandList_Reset( list, allocator, NULL );
        transition( list, buffers[index], D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET );
        ID3D12GraphicsCommandList_OMSetRenderTargets( list, 1, &rtv[index], FALSE, NULL );
        ID3D12GraphicsCommandList_ClearRenderTargetView( list, rtv[index], colour, 0, NULL );
        if (i == frames - 1)
        {
            /* read the last frame back before it is presented */
            transition( list, buffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE );
            copy_src.pResource = buffers[index];
            copy_src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            copy_dst.pResource = readback;
            copy_dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            copy_dst.PlacedFootprint = footprint;
            ID3D12GraphicsCommandList_CopyTextureRegion( list, &copy_dst, 0, 0, 0, &copy_src, NULL );
            transition( list, buffers[index], D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT );
        }
        else transition( list, buffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT );
        if (FAILED(hr = ID3D12GraphicsCommandList_Close( list ))) return fail( "Close", hr );
        ID3D12CommandQueue_ExecuteCommandLists( queue, 1, (ID3D12CommandList **)&list );
        if (SUCCEEDED( IDXGISwapChain3_Present( swapchain, 1, 0 ) )) presented++;
        if (!wait_for_gpu())
        {
            printf( "d3d12 window: the GPU did not finish frame %d within 30 s (presented %d)\n", i, presented );
            return 2;
        }
        pump();
    }
    if (FAILED(hr = ID3D12Device_GetDeviceRemovedReason( device ))) return fail( "the device was removed, GetDeviceRemovedReason", hr );

    read_range.End = (SIZE_T)total_bytes;
    if (SUCCEEDED( ID3D12Resource_Map( readback, 0, &read_range, (void **)&data ) ))
    {
        memcpy( pixel, data + footprint.Offset + (HEIGHT / 2) * footprint.Footprint.RowPitch + (WIDTH / 2) * 4, 4 );
        ID3D12Resource_Unmap( readback, 0, &no_write );
    }

    printf( "d3d12 window: vkd3d %d, swap chain %lx, %dx%d, presented %d/%d, back buffer %02x%02x%02x\n",
            vkd3d, (unsigned long)sc_hr, WIDTH, HEIGHT, presented, frames, pixel[0], pixel[1], pixel[2] );
    fflush( stdout );
    /* a swap chain has to be released before its window goes */
    for (i = 0; i < BUFFERS; i++) ID3D12Resource_Release( buffers[i] );
    IDXGISwapChain3_Release( swapchain );
    IDXGISwapChain1_Release( swapchain1 );
    DestroyWindow( hwnd );
    return (presented == frames && abs( pixel[0] - 0x33 ) <= 1 && abs( pixel[1] - 0xcc ) <= 1 && abs( pixel[2] - 0x66 ) <= 1) ? 0 : 1;
}
