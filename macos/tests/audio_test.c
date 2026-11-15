/*
 * Plays a short buffer of silence through the default audio output: winmm's waveOut, which goes
 * through mmdevapi to Wine's audio driver (winecoreaudio.drv on macOS). Nothing is heard.
 *
 * Prints one line, e.g.
 *   audio: devices 1, first "MacBook Pro Speakers", open 0, write 0, done 1, position 14400/14400
 * and exits 0 when there is an output device, it opens at 48 kHz 16 bit stereo, the buffer is
 * accepted and the device reports it as played to the end.
 *
 * Built for x86_64 with the mingw compiler: -lwinmm.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <mmsystem.h>

#define RATE    48000
#define FRAMES  (RATE * 3 / 10)   /* 300 ms */

int main(void)
{
    WAVEFORMATEX format = { WAVE_FORMAT_PCM, 2, RATE, RATE * 4, 4, 16, 0 };
    WAVEOUTCAPSA caps = { 0 };
    WAVEHDR header = { 0 };
    MMTIME time = { TIME_SAMPLES };
    HWAVEOUT out = NULL;
    UINT devices = waveOutGetNumDevs();
    MMRESULT open_res = MMSYSERR_NODRIVER, write_res = MMSYSERR_ERROR;
    DWORD position = 0, end;
    int done = 0;

    if (devices) waveOutGetDevCapsA( 0, &caps, sizeof(caps) );
    if (devices) open_res = waveOutOpen( &out, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL );
    if (open_res == MMSYSERR_NOERROR)
    {
        header.dwBufferLength = FRAMES * 4;
        header.lpData = calloc( 1, header.dwBufferLength );
        if (waveOutPrepareHeader( out, &header, sizeof(header) ) == MMSYSERR_NOERROR)
            write_res = waveOutWrite( out, &header, sizeof(header) );
        for (end = GetTickCount() + 3000; write_res == MMSYSERR_NOERROR && (int)(end - GetTickCount()) > 0; Sleep( 10 ))
        {
            if (header.dwFlags & WHDR_DONE) { done = 1; break; }
        }
        if (waveOutGetPosition( out, &time, sizeof(time) ) == MMSYSERR_NOERROR && time.wType == TIME_SAMPLES)
            position = time.u.sample;
        waveOutReset( out );
        waveOutUnprepareHeader( out, &header, sizeof(header) );
        waveOutClose( out );
    }
    printf( "audio: devices %u, first \"%s\", open %u, write %u, done %d, position %lu/%d\n",
            devices, caps.szPname, open_res, write_res, done, (unsigned long)position, FRAMES );
    return (devices && open_res == MMSYSERR_NOERROR && write_res == MMSYSERR_NOERROR && done && position >= FRAMES) ? 0 : 1;
}
