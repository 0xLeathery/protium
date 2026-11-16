/*
 * Fetches an https:// address through WinHTTP, which uses Windows' TLS (schannel), as games and
 * launchers do for log-ins, news and updates:
 *
 *   https_test.exe [host, default store.steampowered.com] [path, default /]
 *
 * Prints one line, e.g.
 *   https: store.steampowered.com, status 200, 51234 bytes
 * and exits 0 when the request got any HTTP status over TLS. Wine needs GnuTLS for schannel;
 * without it the request fails with ERROR_WINHTTP_SECURE_FAILURE (12175) or similar.
 *
 * Built for x86_64 with the mingw compiler: -lwinhttp.
 */
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

int main( int argc, char **argv )
{
    WCHAR host[256], path[1024];
    DWORD status = 0, size = sizeof(status), got, total = 0;
    HINTERNET session, connect, request;
    char buffer[4096];

    MultiByteToWideChar( CP_UTF8, 0, argc > 1 ? argv[1] : "store.steampowered.com", -1, host, ARRAYSIZE(host) );
    MultiByteToWideChar( CP_UTF8, 0, argc > 2 ? argv[2] : "/", -1, path, ARRAYSIZE(path) );

    if (!(session = WinHttpOpen( L"https_test/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0 )) ||
        !(connect = WinHttpConnect( session, host, INTERNET_DEFAULT_HTTPS_PORT, 0 )) ||
        !(request = WinHttpOpenRequest( connect, L"GET", path, NULL, NULL, NULL, WINHTTP_FLAG_SECURE )))
    {
        printf( "https: %ls, setting up the request failed, error %lu\n", host, GetLastError() );
        return 1;
    }
    if (!WinHttpSendRequest( request, NULL, 0, NULL, 0, 0, 0 ) || !WinHttpReceiveResponse( request, NULL ))
    {
        printf( "https: %ls, request failed, error %lu\n", host, GetLastError() );
        return 1;
    }
    WinHttpQueryHeaders( request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &size, NULL );
    while (WinHttpReadData( request, buffer, sizeof(buffer), &got ) && got) total += got;
    printf( "https: %ls, status %lu, %lu bytes\n", host, status, total );
    return 0;
}
