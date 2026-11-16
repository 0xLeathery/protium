/*
 * Decodes a video file through Media Foundation, as games play cutscenes: an IMFSourceReader
 * with RGB32 video and PCM audio output.
 *
 *   mf_video_test.exe <file>
 *
 * Prints one line, e.g.
 *   mf video: 30 frames 320x240 (0-966 ms), first centre 3366cc, audio 48000 bytes
 * and exits 0 when at least one frame and some audio were decoded. The test files are one second
 * of a single colour, so the centre of the first frame is that colour (within rounding).
 *
 * Built for x86_64 or i686 with the mingw compiler: -lmfplat -lmfreadwrite -lmfuuid -lole32.
 */
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdio.h>

int main( int argc, char **argv )
{
    IMFSourceReader *reader;
    IMFMediaType *type;
    IMFSample *sample;
    IMFMediaBuffer *buffer;
    WCHAR path[MAX_PATH];
    UINT32 width = 0, height = 0;
    DWORD flags, stream, max, len, frames = 0, audio = 0, colour = 0, ended = 0, selected = 0, i;
    BOOL on;
    LONGLONG time, first = -1, last = -1;
    BYTE *data;
    HRESULT hr;

    if (argc != 2) { printf( "usage: mf_video_test.exe <file>\n" ); return 2; }
    MultiByteToWideChar( CP_ACP, 0, argv[1], -1, path, MAX_PATH );
    CoInitializeEx( NULL, COINIT_MULTITHREADED );
    if (FAILED(hr = MFStartup( MF_VERSION, 0 ))) { printf( "mf video: MFStartup %#lx\n", hr ); return 1; }
    /* decoders give YUV; RGB32 needs the reader's video processing after them, as on Windows */
    IMFAttributes *attrs;
    MFCreateAttributes( &attrs, 1 );
    IMFAttributes_SetUINT32( attrs, &MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE );
    if (FAILED(hr = MFCreateSourceReaderFromURL( path, attrs, &reader )))
    {
        printf( "mf video: MFCreateSourceReaderFromURL %#lx\n", hr );
        return 1;
    }

    MFCreateMediaType( &type );
    IMFMediaType_SetGUID( type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video );
    IMFMediaType_SetGUID( type, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32 );
    if (FAILED(hr = IMFSourceReader_SetCurrentMediaType( reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, type )))
    {
        printf( "mf video: no RGB32 video output, %#lx\n", hr );
        return 1;
    }
    IMFMediaType_Release( type );
    MFCreateMediaType( &type );
    IMFMediaType_SetGUID( type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio );
    IMFMediaType_SetGUID( type, &MF_MT_SUBTYPE, &MFAudioFormat_PCM );
    IMFSourceReader_SetCurrentMediaType( reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, type );
    IMFMediaType_Release( type );
    if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType( reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &type )))
    {
        UINT64 size;
        if (SUCCEEDED(IMFMediaType_GetUINT64( type, &MF_MT_FRAME_SIZE, &size )))
            width = size >> 32, height = (UINT32)size;
        IMFMediaType_Release( type );
    }

    for (i = 0; i < 32 && SUCCEEDED(IMFSourceReader_GetStreamSelection( reader, i, &on )); i++)
        if (on) selected |= 1u << i;

    for (;;)
    {
        hr = IMFSourceReader_ReadSample( reader, MF_SOURCE_READER_ANY_STREAM, 0, &stream, &flags, &time, &sample );
        if (FAILED(hr)) { printf( "mf video: ReadSample %#lx after %lu frames\n", hr, frames ); return 1; }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM)
        {
            /* the flag is for one stream: read on until every selected stream has ended */
            ended |= 1u << stream;
            IMFSourceReader_SetStreamSelection( reader, stream, FALSE );
            if (ended == selected) break;
            continue;
        }
        if (!sample) continue;
        if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer( sample, &buffer )))
        {
            if (SUCCEEDED(IMFMediaBuffer_Lock( buffer, &data, &max, &len )))
            {
                IMFMediaType *current;
                GUID major = { 0 };
                if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType( reader, stream, &current )))
                {
                    IMFMediaType_GetGUID( current, &MF_MT_MAJOR_TYPE, &major );
                    IMFMediaType_Release( current );
                }
                if (IsEqualGUID( &major, &MFMediaType_Video ))
                {
                    if (!frames && width && height && len >= width * height * 4)
                    {
                        const BYTE *p = data + ((height / 2) * width + width / 2) * 4;
                        colour = p[2] << 16 | p[1] << 8 | p[0];
                    }
                    if (first < 0) first = time;
                    last = time;
                    frames++;
                }
                else audio += len;
                IMFMediaBuffer_Unlock( buffer );
            }
            IMFMediaBuffer_Release( buffer );
        }
        IMFSample_Release( sample );
    }

    printf( "mf video: %lu frames %ux%u (%lld-%lld ms), first centre %06lx, audio %lu bytes\n", frames, width,
            height, first / 10000, last / 10000, colour, audio );
    return frames && audio ? 0 : 1;
}
