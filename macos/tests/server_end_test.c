/*
 * A launcher and its game, for the check of what becomes of a session's processes when its
 * wineserver ends, and of a game when its launcher does (macos/tests/check-wave5.sh, item 24):
 *
 *   server_end_test.exe <seconds> <file>         the launcher: starts the game and ends at once
 *   server_end_test.exe game <seconds> <file>    the game: sleeps that long, then writes one
 *                                                line to the file and ends:
 *                                                  server end: the game ran 3.0 s
 *
 * The launcher prints
 *   server end: the launcher started the game
 * and exits 0. The game is found in the list of processes by its name, and it gets its launcher's
 * stderr, where Wine writes why it ended a process.
 *
 * Built for x86_64 with the mingw compiler.
 *
 * Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main( int argc, char **argv )
{
    char path[MAX_PATH], cmd[3 * MAX_PATH];
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;

    if (argc == 4 && !strcmp( argv[1], "game" ))
    {
        DWORD start = GetTickCount();
        FILE *f;

        Sleep( atoi( argv[2] ) * 1000 );
        if (!(f = fopen( argv[3], "w" ))) return 2;
        fprintf( f, "server end: the game ran %.1f s\n", (GetTickCount() - start) / 1000.0 );
        fclose( f );
        return 0;
    }
    if (argc != 3)
    {
        printf( "usage: server_end_test.exe <seconds> <file>\n" );
        return 2;
    }
    GetModuleFileNameA( NULL, path, sizeof(path) );
    snprintf( cmd, sizeof(cmd), "\"%s\" game %s \"%s\"", path, argv[1], argv[2] );
    if (!CreateProcessA( NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi ))
    {
        printf( "server end: the game did not start, error %lu\n", GetLastError() );
        return 2;
    }
    printf( "server end: the launcher started the game\n" );
    fflush( stdout );
    return 0;
}
