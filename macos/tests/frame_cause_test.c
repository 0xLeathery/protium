/*
 * Makes Direct3D 11 frames that are slow for a known reason, so that what the frame recorder says
 * about a frame (DXMT's "DXGI:" lines in the log) can be held against what was done to it:
 *
 *   frame_cause_test.exe [frames=N] [every=N] [causes=sleep,shaders,map,query,heavy] [sync=0|1]
 *                        [loop=N] [size=WxH] [salt=HEX] [lines=N] [binds=N] [flushes=N]
 *
 * A window of its own with a swap chain. Every frame clears, draws one triangle over the whole
 * window with a pixel shader that goes round a loop `loop` times for each pixel (the GPU's work
 * for a frame; default 64), and presents with the sync interval `sync` (default 1). Every `every`
 * frames (default 600) the next of the causes is made, and a line on stdout says what was done:
 *
 *   sleep     the thread sleeps 150 ms before it presents
 *               truth: frame 600 (5.01 s, 14:02:11.250): sleep, 150.2 ms
 *   shaders   a vertex and a pixel shader that no run has had before are created and drawn with
 *             (the pixel shader has `lines` statements, default 400, so that it takes a while to
 *             compile; `salt` makes them the same as an earlier run's, for the shader cache)
 *               truth: frame 1200 (10.02 s, 14:02:16.260): shaders, 2 new and 1 pipeline, created in 0.31 ms
 *   map       one triangle with a loop long enough for 60 ms of GPU time is drawn to a texture,
 *             the texture copied to a staging texture and that one mapped: the thread waits for
 *             the GPU
 *               truth: frame 1800 (15.10 s, 14:02:21.340): map, waited 61.4 ms
 *   query     the same draw, then an event query that is asked with GetData until it has come
 *               truth: frame 2400 (20.21 s, 14:02:26.450): query, 51200 polls in 60.8 ms
 *   heavy     120 frames whose loop is 8 times as long
 *               truth: frames 3000 to 3119 (25.30 s, 14:02:31.540): heavy, loop 512
 *
 * Before the frames it measures what the GPU takes for the texture's triangle at two loop
 * lengths, each drawn and read back 8 times with nothing else going on, and says so:
 *   calibration: 1024x1024, loop 256: 2.10 ms; loop 1024: 8.31 ms; 7.9 ns a pixel and thousand rounds
 *
 * binds=N adds N small draws to each frame, each after binding another texture; flushes=N adds N
 * small draws each followed by Flush(), which ends a command buffer: what the recorder costs for
 * a bind and for a command buffer is measured with them. The small draws, and the one with the
 * new shaders, go to 4 pixels square in a corner: a triangle over the whole window would hide
 * the frame's own, and a GPU that renders in tiles does not shade what is hidden.
 *
 * Last line, and exit status 0 when every Present succeeded:
 *   frame cause test: 7200 frames in 60.2 s, 0 not presented, loop 64, sync 1, salt 5f3a9c01
 *
 * Built for x86_64 with the mingw compiler: -ld3d11 -ld3dcompiler -ldxguid -luuid -luser32.
 *
 * Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.
 */
#define COBJMACROS
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>

#define TEXTURE_SIZE 1024
#define MAX_NEW_SHADERS 16

static ID3D11Device *device;
static ID3D11DeviceContext *context;
static LARGE_INTEGER frequency, first_present;

static double now_ms(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter( &t );
    return t.QuadPart * 1000.0 / frequency.QuadPart;
}

static void pump(void)
{
    MSG msg;
    while (PeekMessageA( &msg, 0, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
}

/* "(5.01 s, 14:02:11.250)": since the first Present, and by the clock the log's lines have */
static const char *when(void)
{
    static char text[64];
    LARGE_INTEGER t;
    SYSTEMTIME st;

    QueryPerformanceCounter( &t );
    GetLocalTime( &st );
    snprintf( text, sizeof(text), "(%.2f s, %02u:%02u:%02u.%03u)",
              first_present.QuadPart ? (double)(t.QuadPart - first_present.QuadPart) / frequency.QuadPart : 0.0,
              st.wHour, st.wMinute, st.wSecond, st.wMilliseconds );
    return text;
}

static ID3DBlob *compile( const char *source, const char *target )
{
    ID3DBlob *code = NULL, *errors = NULL;
    HRESULT hr = D3DCompile( source, strlen( source ), NULL, NULL, NULL, "main", target, 0, 0, &code, &errors );

    if (FAILED( hr ))
    {
        printf( "frame cause test: D3DCompile %s failed, hr %08lx: %s\n", target, (unsigned long)hr,
                errors ? (const char *)ID3D10Blob_GetBufferPointer( errors ) : "" );
        return NULL;
    }
    return code;
}

/* The vertex shader: one triangle over the whole target. The salt is the depth it gives, which
 * nothing uses. */
static ID3DBlob *compile_vs( unsigned int salt )
{
    char source[512];

    snprintf( source, sizeof(source),
              "float4 main(uint id : SV_VertexID) : SV_Position\n"
              "{\n"
              "    float2 p = float2((id << 1) & 2, id & 2);\n"
              "    return float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), %.9f, 1.0);\n"
              "}\n", (salt % 1000000u) / 2000000.0 );
    return compile( source, "vs_4_0" );
}

/* The pixel shader: `lines` statements, then a loop of loop_count rounds. The salt is in every
 * statement and in the green it gives. */
static ID3DBlob *compile_ps( unsigned int salt, int lines )
{
    size_t size = 1024 + (size_t)lines * 96, used;
    char *source = malloc( size );
    ID3DBlob *code;
    int i;

    used = snprintf( source, size,
                     "cbuffer params : register(b0) { uint loop_count; uint pad0; uint pad1; uint pad2; };\n"
                     "float4 main(float4 pos : SV_Position) : SV_Target\n"
                     "{\n"
                     "    float v = frac(pos.x * 0.37 + pos.y * 0.71);\n" );
    for (i = 0; i < lines; i++)
        used += snprintf( source + used, size - used, "    v = frac(v * %.6f + sin(v * %.6f + %.6f));\n",
                          1.0 + ((salt + i * 7919u) % 9973u) / 9973.0, 2.0 + (i % 89) / 89.0, (salt % 1000u) / 1000.0 + i );
    used += snprintf( source + used, size - used,
                      "    for (uint i = 0; i < loop_count; i++)\n"
                      "        v = frac(v * 1.618034 + 0.5772157 * sin(v + i));\n"
                      "    return float4(v, %.9f, 0.75, 1.0);\n"
                      "}\n", (salt % 1000000u) / 1000000.0 );
    code = compile( source, "ps_4_0" );
    free( source );
    return code;
}

static void set_loop( ID3D11Buffer *params, unsigned int loop )
{
    unsigned int data[4] = { loop, 0, 0, 0 };
    ID3D11DeviceContext_UpdateSubresource( context, (ID3D11Resource *)params, 0, NULL, data, 0, 0 );
}

static void draw_to( ID3D11RenderTargetView *view, unsigned int width, unsigned int height )
{
    D3D11_VIEWPORT viewport = { 0.0f, 0.0f, (float)width, (float)height, 0.0f, 1.0f };

    ID3D11DeviceContext_OMSetRenderTargets( context, 1, &view, NULL );
    ID3D11DeviceContext_RSSetViewports( context, 1, &viewport );
    ID3D11DeviceContext_Draw( context, 3, 0 );
}

/* a draw of 4 pixels square, with whatever is bound */
static void draw_small( unsigned int width, unsigned int height )
{
    D3D11_VIEWPORT corner = { 0.0f, 0.0f, 4.0f, 4.0f, 0.0f, 1.0f };
    D3D11_VIEWPORT whole = { 0.0f, 0.0f, (float)width, (float)height, 0.0f, 1.0f };

    ID3D11DeviceContext_RSSetViewports( context, 1, &corner );
    ID3D11DeviceContext_Draw( context, 3, 0 );
    ID3D11DeviceContext_RSSetViewports( context, 1, &whole );
}

/* the texture's triangle with this loop, read back: how long the thread waits for the GPU */
static double draw_and_map( ID3D11Buffer *params, ID3D11RenderTargetView *texture_view, ID3D11Texture2D *texture,
                            ID3D11Texture2D *staging, unsigned int loop )
{
    D3D11_MAPPED_SUBRESOURCE map;
    double start, waited = -1.0;

    set_loop( params, loop );
    draw_to( texture_view, TEXTURE_SIZE, TEXTURE_SIZE );
    ID3D11DeviceContext_CopyResource( context, (ID3D11Resource *)staging, (ID3D11Resource *)texture );
    start = now_ms();
    if (SUCCEEDED( ID3D11DeviceContext_Map( context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map ) ))
    {
        waited = now_ms() - start;
        ID3D11DeviceContext_Unmap( context, (ID3D11Resource *)staging, 0 );
    }
    return waited;
}

int main( int argc, char **argv )
{
    static const float colour[4] = { 0.1f, 0.1f, 0.1f, 1.0f };
    static const char *all_causes[] = { "sleep", "shaders", "map", "query", "heavy" };
    int frames = 7200, every = 600, sync = 1, lines = 400, binds = 0, flushes = 0, width = 1280, height = 720;
    unsigned int loop = 64, salt = 0, heavy_loop, small_loop = 1;
    int causes[16], cause_count = 0, next_cause = 0, heavy_left = 0, not_presented = 0, new_shaders = 0, i, frame;
    D3D11_TEXTURE2D_DESC desc = { TEXTURE_SIZE, TEXTURE_SIZE, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 }, D3D11_USAGE_DEFAULT,
                                  D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE };
    D3D11_BUFFER_DESC buffer_desc = { 16, D3D11_USAGE_DEFAULT, D3D11_BIND_CONSTANT_BUFFER };
    D3D11_QUERY_DESC query_desc = { D3D11_QUERY_EVENT, 0 };
    DXGI_SWAP_CHAIN_DESC sd = { 0 };
    WNDCLASSA cls = { 0 };
    D3D_FEATURE_LEVEL level = 0;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Texture2D *backbuffer = NULL, *texture = NULL, *staging = NULL, *small[2] = { NULL, NULL };
    ID3D11RenderTargetView *view = NULL, *texture_view = NULL;
    ID3D11ShaderResourceView *small_view[2] = { NULL, NULL };
    ID3D11VertexShader *vs = NULL, *new_vs[MAX_NEW_SHADERS] = { NULL };
    ID3D11PixelShader *ps = NULL, *new_ps[MAX_NEW_SHADERS] = { NULL };
    ID3DBlob *vs_code, *ps_code, *new_vs_code[MAX_NEW_SHADERS] = { NULL }, *new_ps_code[MAX_NEW_SHADERS] = { NULL };
    ID3D11Buffer *params = NULL;
    ID3D11Query *query = NULL;
    double start, took, ms_short, ms_long, per_round;
    HRESULT hr;
    HWND hwnd;

    for (i = 1; i < argc; i++)
    {
        if (!strncmp( argv[i], "frames=", 7 )) frames = atoi( argv[i] + 7 );
        else if (!strncmp( argv[i], "every=", 6 )) every = atoi( argv[i] + 6 );
        else if (!strncmp( argv[i], "sync=", 5 )) sync = atoi( argv[i] + 5 );
        else if (!strncmp( argv[i], "loop=", 5 )) loop = strtoul( argv[i] + 5, NULL, 10 );
        else if (!strncmp( argv[i], "lines=", 6 )) lines = atoi( argv[i] + 6 );
        else if (!strncmp( argv[i], "binds=", 6 )) binds = atoi( argv[i] + 6 );
        else if (!strncmp( argv[i], "flushes=", 8 )) flushes = atoi( argv[i] + 8 );
        else if (!strncmp( argv[i], "salt=", 5 )) salt = strtoul( argv[i] + 5, NULL, 16 );
        else if (!strncmp( argv[i], "size=", 5 )) sscanf( argv[i] + 5, "%dx%d", &width, &height );
        else if (!strncmp( argv[i], "causes=", 7 ))
        {
            char *list = argv[i] + 7, *name;
            unsigned int k;

            for (name = strtok( list, "," ); name && cause_count < 16; name = strtok( NULL, "," ))
            {
                for (k = 0; k < ARRAYSIZE(all_causes); k++) if (!strcmp( name, all_causes[k] )) break;
                if (k == ARRAYSIZE(all_causes))
                {
                    printf( "frame cause test: no cause '%s'\n", name );
                    return 2;
                }
                causes[cause_count++] = k;
            }
        }
        else
        {
            printf( "frame cause test: no option '%s'\n", argv[i] );
            return 2;
        }
    }
    if (!cause_count && !strstr( GetCommandLineA(), "causes=" ))
        for (i = 0; i < (int)ARRAYSIZE(all_causes); i++) causes[cause_count++] = i;
    if (every < 1) every = 1;
    QueryPerformanceFrequency( &frequency );
    if (!salt) salt = (GetTickCount() * 2654435761u) ^ (GetCurrentProcessId() << 16) ^ (unsigned int)time( NULL );

    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = GetModuleHandleA( NULL );
    cls.hCursor = LoadCursorA( 0, (const char *)IDC_ARROW );
    cls.lpszClassName = "frame_cause_test";
    RegisterClassA( &cls );
    hwnd = CreateWindowExA( 0, "frame_cause_test", "frame_cause_test", WS_POPUP | WS_VISIBLE, 160, 160, width, height,
                            0, 0, cls.hInstance, NULL );
    if (!hwnd)
    {
        printf( "frame cause test: CreateWindowEx failed, error %lu\n", GetLastError() );
        return 1;
    }
    pump();

    sd.BufferCount = 2;
    sd.BufferDesc.Width = width;
    sd.BufferDesc.Height = height;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    hr = D3D11CreateDeviceAndSwapChain( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &sd,
                                        &swapchain, &device, &level, &context );
    if (FAILED( hr ) || !swapchain)
    {
        printf( "frame cause test: no device and swap chain, hr %08lx\n", (unsigned long)hr );
        return 1;
    }
    hr = IDXGISwapChain_GetBuffer( swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer );
    if (SUCCEEDED( hr )) hr = ID3D11Device_CreateRenderTargetView( device, (ID3D11Resource *)backbuffer, NULL, &view );
    if (SUCCEEDED( hr )) hr = ID3D11Device_CreateTexture2D( device, &desc, NULL, &texture );
    if (SUCCEEDED( hr )) hr = ID3D11Device_CreateRenderTargetView( device, (ID3D11Resource *)texture, NULL, &texture_view );
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (SUCCEEDED( hr )) hr = ID3D11Device_CreateTexture2D( device, &desc, NULL, &staging );
    desc.Width = desc.Height = 4;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = 0;
    for (i = 0; i < 2 && SUCCEEDED( hr ); i++)
    {
        hr = ID3D11Device_CreateTexture2D( device, &desc, NULL, &small[i] );
        if (SUCCEEDED( hr )) hr = ID3D11Device_CreateShaderResourceView( device, (ID3D11Resource *)small[i], NULL, &small_view[i] );
    }
    if (SUCCEEDED( hr )) hr = ID3D11Device_CreateBuffer( device, &buffer_desc, NULL, &params );
    if (SUCCEEDED( hr )) hr = ID3D11Device_CreateQuery( device, &query_desc, &query );
    if (FAILED( hr ))
    {
        printf( "frame cause test: a texture, view, buffer or query failed, hr %08lx\n", (unsigned long)hr );
        return 1;
    }

    /* the shaders of every frame have no statements but the loop; those of the "shaders" cause are
     * compiled to bytecode here, so that only Direct3D's own work on them falls into their frame */
    if (!(vs_code = compile_vs( salt )) || !(ps_code = compile_ps( salt, 0 ))) return 1;
    hr = ID3D11Device_CreateVertexShader( device, ID3D10Blob_GetBufferPointer( vs_code ), ID3D10Blob_GetBufferSize( vs_code ), NULL, &vs );
    if (SUCCEEDED( hr ))
        hr = ID3D11Device_CreatePixelShader( device, ID3D10Blob_GetBufferPointer( ps_code ), ID3D10Blob_GetBufferSize( ps_code ), NULL, &ps );
    if (FAILED( hr ))
    {
        printf( "frame cause test: the shaders were not created, hr %08lx\n", (unsigned long)hr );
        return 1;
    }
    for (i = 0; i < cause_count; i++) if (causes[i] == 1) break;
    if (i < cause_count)
        for (i = 0; i < MAX_NEW_SHADERS && i * every * cause_count < frames; i++)
            if (!(new_vs_code[i] = compile_vs( salt + 1 + i )) || !(new_ps_code[i] = compile_ps( salt + 1 + i, lines ))) return 1;

    ID3D11DeviceContext_IASetPrimitiveTopology( context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST );
    ID3D11DeviceContext_VSSetShader( context, vs, NULL, 0 );
    ID3D11DeviceContext_PSSetShader( context, ps, NULL, 0 );
    ID3D11DeviceContext_PSSetConstantBuffers( context, 0, 1, &params );

    /* what the GPU takes for the texture's triangle, with nothing else going on */
    draw_and_map( params, texture_view, texture, staging, 16 );
    for (i = 0, ms_short = ms_long = 0.0; i < 8; i++)
    {
        ms_short += draw_and_map( params, texture_view, texture, staging, 256 ) / 8.0;
        ms_long += draw_and_map( params, texture_view, texture, staging, 1024 ) / 8.0;
    }
    per_round = (ms_long - ms_short) / 768.0;   /* ms for one more round of the loop over the texture */
    printf( "calibration: %dx%d, loop 256: %.2f ms; loop 1024: %.2f ms; %.1f ns a pixel and thousand rounds\n",
            TEXTURE_SIZE, TEXTURE_SIZE, ms_short, ms_long, per_round * 1e6 / (TEXTURE_SIZE * TEXTURE_SIZE) * 1000.0 );
    fflush( stdout );
    heavy_loop = per_round > 0.0 ? (unsigned int)(60.0 / per_round) : 4096;   /* 60 ms of it */
    if (heavy_loop < 64) heavy_loop = 64;
    if (heavy_loop > 2000000) heavy_loop = 2000000;

    start = now_ms();
    for (frame = 0; frame < frames; frame++)
    {
        int cause = -1;

        if (frame && !(frame % every) && cause_count) cause = causes[next_cause++ % cause_count];
        if (cause == 4)
        {
            heavy_left = 120;
            printf( "truth: frames %d to %d %s: heavy, loop %u\n", frame, frame + heavy_left - 1, when(), loop * 8 );
            fflush( stdout );
        }
        set_loop( params, heavy_left ? loop * 8 : loop );
        if (heavy_left) heavy_left--;
        ID3D11DeviceContext_ClearRenderTargetView( context, view, colour );
        draw_to( view, width, height );

        if (binds || flushes)
        {
            set_loop( params, small_loop );
            for (i = 0; i < binds; i++)
            {
                ID3D11DeviceContext_PSSetShaderResources( context, 0, 1, &small_view[i & 1] );
                draw_small( width, height );
            }
            for (i = 0; i < flushes; i++)
            {
                draw_small( width, height );
                ID3D11DeviceContext_Flush( context );
            }
        }

        switch (cause)
        {
        case 0:
            took = now_ms();
            Sleep( 150 );
            printf( "truth: frame %d %s: sleep, %.1f ms\n", frame, when(), now_ms() - took );
            break;
        case 1:
            if (new_shaders < MAX_NEW_SHADERS && new_vs_code[new_shaders])
            {
                ID3DBlob *v = new_vs_code[new_shaders], *p = new_ps_code[new_shaders];

                took = now_ms();
                hr = ID3D11Device_CreateVertexShader( device, ID3D10Blob_GetBufferPointer( v ), ID3D10Blob_GetBufferSize( v ), NULL, &new_vs[new_shaders] );
                if (SUCCEEDED( hr ))
                    hr = ID3D11Device_CreatePixelShader( device, ID3D10Blob_GetBufferPointer( p ), ID3D10Blob_GetBufferSize( p ), NULL, &new_ps[new_shaders] );
                if (SUCCEEDED( hr ))
                {
                    ID3D11DeviceContext_VSSetShader( context, new_vs[new_shaders], NULL, 0 );
                    ID3D11DeviceContext_PSSetShader( context, new_ps[new_shaders], NULL, 0 );
                    set_loop( params, small_loop );
                    draw_small( width, height );
                    ID3D11DeviceContext_VSSetShader( context, vs, NULL, 0 );
                    ID3D11DeviceContext_PSSetShader( context, ps, NULL, 0 );
                    printf( "truth: frame %d %s: shaders, 2 new and 1 pipeline, created in %.2f ms\n", frame, when(), now_ms() - took );
                }
                else printf( "truth: frame %d %s: shaders, not created, hr %08lx\n", frame, when(), (unsigned long)hr );
                new_shaders++;
            }
            break;
        case 2:
            took = draw_and_map( params, texture_view, texture, staging, heavy_loop );
            printf( "truth: frame %d %s: map, waited %.1f ms\n", frame, when(), took );
            break;
        case 3:
        {
            unsigned int polls = 0;
            BOOL done = FALSE;

            set_loop( params, heavy_loop );
            draw_to( texture_view, TEXTURE_SIZE, TEXTURE_SIZE );
            ID3D11DeviceContext_End( context, (ID3D11Asynchronous *)query );
            took = now_ms();
            while (ID3D11DeviceContext_GetData( context, (ID3D11Asynchronous *)query, &done, sizeof(done), 0 ) != S_OK)
                if (++polls == 200000000u) break;
            printf( "truth: frame %d %s: query, %u polls in %.1f ms\n", frame, when(), polls, now_ms() - took );
            break;
        }
        }
        if (cause >= 0) fflush( stdout );

        hr = IDXGISwapChain_Present( swapchain, sync, 0 );
        if (hr != S_OK) not_presented++;
        if (!first_present.QuadPart) QueryPerformanceCounter( &first_present );
        pump();
    }

    printf( "frame cause test: %d frames in %.1f s, %d not presented, loop %u, sync %d, salt %08x\n", frames,
            (now_ms() - start) / 1000.0, not_presented, loop, sync, salt );
    fflush( stdout );
    /* the swap chain's own end has the recorder's last lines */
    ID3D11DeviceContext_ClearState( context );
    ID3D11RenderTargetView_Release( view );
    ID3D11Texture2D_Release( backbuffer );
    IDXGISwapChain_Release( swapchain );
    DestroyWindow( hwnd );
    return not_presented ? 1 : 0;
}
