/*
 * Checks that a session ends when its last ordinary program has, in the arrangement Proton
 * starts every game in:
 *
 *   session_end_test.exe          the part of Proton's steam.exe: starts the "game" (itself,
 *                                 with the argument below), makes itself a system process and
 *                                 waits for the wineserver's shutdown event, which comes when no
 *                                 process is left but system processes
 *   session_end_test.exe child    the "game": sleeps two seconds and ends
 *
 * Prints one line, e.g.
 *   session end: the shutdown event came, 2.1 s after the start
 * and exits 0 when it came.
 *
 * It has to be started by its full path, as Proton starts steam.exe. Given a bare name that is
 * no file in the current folder, Wine starts start.exe /exec to look for the program, and
 * start.exe waits for it and is an ordinary program itself: the event then never comes
 * (macos/steamplay-run.sh did that with steam.exe, and Steam went on showing a game as running
 * after it had been quit).
 *
 * Built for x86_64 with the mingw compiler: -lntdll.
 */
#include <windows.h>
#include <winternl.h>
#include <stdio.h>

int main( int argc, char **argv )
{
    char path[MAX_PATH], cmd[MAX_PATH + 16];
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    HANDLE event = NULL;
    NTSTATUS status;
    DWORD ret, start = GetTickCount();

    if (argc > 1)
    {
        Sleep( 2000 );
        return 0;
    }

    GetModuleFileNameA( NULL, path, sizeof(path) );
    snprintf( cmd, sizeof(cmd), "\"%s\" child", path );
    if (!CreateProcessA( NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi ))
    {
        printf( "session end: the child did not start, error %lu\n", GetLastError() );
        return 2;
    }
    /* ProcessWineMakeProcessSystem: gives back the event that is set when the shutdown starts */
    status = NtSetInformationProcess( GetCurrentProcess(), 1000, &event, sizeof(HANDLE *) );
    if (status)
    {
        printf( "session end: not made a system process, status %#lx\n", (unsigned long)status );
        return 2;
    }
    ret = WaitForSingleObject( event, 20000 );
    if (ret == WAIT_OBJECT_0)
        printf( "session end: the shutdown event came, %.1f s after the start\n", (GetTickCount() - start) / 1000.0 );
    else
        printf( "session end: the shutdown event did not come in 20 s, though the child ended after 2\n" );
    fflush( stdout );
    return ret == WAIT_OBJECT_0 ? 0 : 1;
}
