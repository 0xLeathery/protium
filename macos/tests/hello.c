/*
 * Minimal Windows ARM64 program for the native arm64 macOS Wine build.
 *
 * Built with the build's own winegcc for aarch64-windows against Wine's CRT (ucrtbase), not the
 * mingw-w64 CRT, see check-wave2b.sh.
 */
#include <stdio.h>

int main( void )
{
    printf( "hello from Windows ARM64 code on macOS\n" );
    fflush( stdout );
    return 0;
}
