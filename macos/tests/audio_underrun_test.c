/*
 * A WASAPI stream that runs dry for a known time, to check winecoreaudio's audio line
 * (WINE_PROCESS_STATS) against:
 *
 *   audio_underrun_test.exe starve|control
 *
 * Opens the default output in shared mode with a 200 ms buffer and keeps it full, in silent
 * buffers (nothing is heard), every 10 ms. "starve" stops writing for 1 s after the first second,
 * so the device plays out the buffer and then gets nothing for about 800 ms; "control" never stops.
 * Either way it goes on until 6 s after that, so that a line falls after it. Prints:
 *   audio underrun test: starve, fed 1000 ms, starved 1000 ms, fed 6000 ms, buffer 200 ms
 *
 * Built for x86_64 with llvm-mingw: -lole32 -luuid -lksuser.
 *
 * Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.
 */
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <stdio.h>
#include <string.h>

static void feed( IAudioClient *client, IAudioRenderClient *render, UINT32 frames_total, DWORD ms )
{
    DWORD start = GetTickCount();

    while (GetTickCount() - start < ms)
    {
        UINT32 padding = 0;
        BYTE *data;

        if (SUCCEEDED( IAudioClient_GetCurrentPadding( client, &padding ) ) && frames_total > padding &&
            SUCCEEDED( IAudioRenderClient_GetBuffer( render, frames_total - padding, &data ) ))
            IAudioRenderClient_ReleaseBuffer( render, frames_total - padding, AUDCLNT_BUFFERFLAGS_SILENT );
        Sleep( 10 );
    }
}

int main( int argc, char **argv )
{
    const char *mode = argc > 1 ? argv[1] : "starve";
    IMMDeviceEnumerator *enumerator;
    IAudioRenderClient *render;
    IAudioClient *client;
    WAVEFORMATEX *format;
    IMMDevice *device;
    UINT32 frames;
    HRESULT hr;

    CoInitializeEx( NULL, COINIT_MULTITHREADED );
    hr = CoCreateInstance( &CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&enumerator );
    if (SUCCEEDED( hr )) hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint( enumerator, eRender, eConsole, &device );
    if (SUCCEEDED( hr )) hr = IMMDevice_Activate( device, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client );
    if (SUCCEEDED( hr )) hr = IAudioClient_GetMixFormat( client, &format );
    if (SUCCEEDED( hr )) hr = IAudioClient_Initialize( client, AUDCLNT_SHAREMODE_SHARED, 0, 2000000, 0, format, NULL );
    if (SUCCEEDED( hr )) hr = IAudioClient_GetBufferSize( client, &frames );
    if (SUCCEEDED( hr )) hr = IAudioClient_GetService( client, &IID_IAudioRenderClient, (void **)&render );
    if (FAILED( hr ))
    {
        printf( "audio underrun test: no output stream (%#lx)\n", hr );
        return 1;
    }

    feed( client, render, frames, 30 );   /* full before it starts */
    IAudioClient_Start( client );
    feed( client, render, frames, 1000 );
    if (!strcmp( mode, "starve" )) Sleep( 1000 );
    else feed( client, render, frames, 1000 );
    feed( client, render, frames, 6000 );
    IAudioClient_Stop( client );
    printf( "audio underrun test: %s, fed 1000 ms, %s 1000 ms, fed 6000 ms, buffer %u ms\n", mode,
            strcmp( mode, "starve" ) ? "fed" : "starved", (unsigned)(frames * 1000ull / format->nSamplesPerSec) );
    return 0;
}
