/*
 * Reads a Windows Media file (ASF with WMV and WMA in it) with the Windows Media reader, which is
 * what a game's intro video goes through when the game plays it with DirectShow or with the
 * Windows Media Format SDK itself (Rise of Nations: Extended Edition does, and showed a black
 * window for ever when the file could not be opened). On this port the reader is winegstreamer's
 * and GStreamer opens the file, so this needs GStreamer's ASF demuxer and FFmpeg's decoders.
 *
 *   wm_video_test.exe <file>
 *
 * Prints one line, e.g.
 *   wm video: 2 outputs, video 30 samples (230400 bytes at most, centre 3366cc), audio 22 samples, last at 1013 ms
 * (the centre is the middle pixel of the last picture, as red, green and blue) and exits 0 when
 * the file had a video output whose samples came with data in them; 1 with
 *   wm video: Open failed, hr c00d0bc2
 * or a line with what was missing.
 *
 * Built for x86_64 and i686 with the mingw compiler: -lole32. wmvcore.dll is loaded as the
 * program runs: the compiler has no import library for it.
 *
 * Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.
 */
#define COBJMACROS
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>
#include <initguid.h>
#include <dshow.h>
#include <wmsdk.h>

#ifndef NS_E_NO_MORE_SAMPLES
#define NS_E_NO_MORE_SAMPLES ((HRESULT)0xC00D0BCFL)
#endif

int main( int argc, char **argv )
{
    WCHAR path[MAX_PATH];
    IWMSyncReader *reader = NULL;
    DWORD outputs = 0, i, video_output = ~0u, audio_output = ~0u, video_bytes = 0, width = 0, height = 0, depth = 0;
    unsigned char centre[3] = { 0, 0, 0 };
    unsigned int video = 0, audio = 0;
    HRESULT (WINAPI *create_reader)( IUnknown *, DWORD, IWMSyncReader ** );
    QWORD last = 0;
    HRESULT hr;

    if (argc != 2)
    {
        printf( "usage: wm_video_test.exe <file>\n" );
        return 2;
    }
    MultiByteToWideChar( CP_ACP, 0, argv[1], -1, path, MAX_PATH );
    CoInitializeEx( NULL, COINIT_MULTITHREADED );
    create_reader = (void *)GetProcAddress( LoadLibraryA( "wmvcore.dll" ), "WMCreateSyncReader" );
    if (!create_reader)
    {
        printf( "wm video: no WMCreateSyncReader in wmvcore.dll\n" );
        return 1;
    }
    if (FAILED( hr = create_reader( NULL, 0, &reader ) ))
    {
        printf( "wm video: no reader, hr %08lx\n", (unsigned long)hr );
        return 1;
    }
    if (FAILED( hr = IWMSyncReader_Open( reader, path ) ))
    {
        printf( "wm video: Open failed, hr %08lx\n", (unsigned long)hr );
        return 1;
    }
    IWMSyncReader_GetOutputCount( reader, &outputs );
    for (i = 0; i < outputs; i++)
    {
        IWMOutputMediaProps *props;
        GUID major;

        if (FAILED( IWMSyncReader_GetOutputProps( reader, i, &props ) )) continue;
        if (SUCCEEDED( IWMOutputMediaProps_GetType( props, &major ) ))
        {
            if (IsEqualGUID( &major, &WMMEDIATYPE_Video ))
            {
                static char type_buffer[2048];
                WM_MEDIA_TYPE *type = (WM_MEDIA_TYPE *)type_buffer;
                DWORD size = sizeof(type_buffer);

                video_output = i;
                /* the size of the pictures, to find the middle of one */
                if (SUCCEEDED( IWMOutputMediaProps_GetMediaType( props, type, &size ) ) && type->pbFormat
                    && type->cbFormat >= sizeof(VIDEOINFOHEADER))
                {
                    const BITMAPINFOHEADER *header = &((VIDEOINFOHEADER *)type->pbFormat)->bmiHeader;
                    width = header->biWidth;
                    height = abs( header->biHeight );
                    depth = header->biBitCount / 8;
                }
            }
            else if (IsEqualGUID( &major, &WMMEDIATYPE_Audio )) audio_output = i;
        }
        IWMOutputMediaProps_Release( props );
    }
    for (;;)
    {
        INSSBuffer *sample;
        QWORD time, duration;
        DWORD flags, output, length = 0;
        BYTE *data = NULL;
        WORD stream;

        if (FAILED( hr = IWMSyncReader_GetNextSample( reader, 0, &sample, &time, &duration, &flags, &output, &stream ) )) break;
        /* not GetLength, which Wine's buffer does not have */
        if (FAILED( INSSBuffer_GetBufferAndLength( sample, &data, &length ) )) length = 0;
        if (output == video_output)
        {
            video++;
            if (length > video_bytes) video_bytes = length;
            if (depth >= 3 && length >= width * height * depth && data)
            {
                const BYTE *pixel = data + ((height / 2) * width + width / 2) * depth;   /* blue, green, red */
                centre[0] = pixel[2]; centre[1] = pixel[1]; centre[2] = pixel[0];
            }
        }
        else if (output == audio_output) audio++;
        last = time;
        INSSBuffer_Release( sample );
    }
    printf( "wm video: %lu outputs, video %u samples (%lu bytes at most, centre %02x%02x%02x), audio %u samples, last at %lu ms%s\n",
            outputs, video, video_bytes, centre[0], centre[1], centre[2], audio, (unsigned long)(last / 10000),
            hr == NS_E_NO_MORE_SAMPLES ? "" : ", and the reading ended with an error" );
    if (hr != NS_E_NO_MORE_SAMPLES) printf( "wm video: GetNextSample hr %08lx\n", (unsigned long)hr );
    fflush( stdout );
    IWMSyncReader_Close( reader );
    IWMSyncReader_Release( reader );
    return (video && video_bytes) ? 0 : 1;
}
