/*
 * Print the on-screen windows of the processes whose executable is below DIR, as macOS sees
 * them:
 *
 *   list_windows DIR        ->  PID <tab> WIDTHxHEIGHT <tab> X,Y <tab> layer <tab> executable
 *
 * A check uses it to see that a window a Windows program opened through Wine is a real window
 * of the window server and not only one Wine believes in. It needs no screen recording
 * permission: bounds and owners are public, titles and contents are not asked for.
 *
 * Build: clang -O1 -Wall -o list_windows list_windows.c -framework CoreGraphics -framework CoreFoundation
 */

#include <CoreGraphics/CoreGraphics.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main( int argc, char *argv[] )
{
    char dir[PROC_PIDPATHINFO_MAXSIZE], file[PROC_PIDPATHINFO_MAXSIZE];
    CFArrayRef windows;
    size_t dir_len;
    CFIndex i;

    if (argc != 2 || !realpath( argv[1], dir ))
    {
        fprintf( stderr, "usage: %s DIR\n", argv[0] );
        return 2;
    }
    dir_len = strlen( dir );
    if (!(windows = CGWindowListCopyWindowInfo( kCGWindowListOptionOnScreenOnly, kCGNullWindowID ))) return 1;

    for (i = 0; i < CFArrayGetCount( windows ); i++)
    {
        CFDictionaryRef info = CFArrayGetValueAtIndex( windows, i );
        CFNumberRef pid_ref = CFDictionaryGetValue( info, kCGWindowOwnerPID );
        CFNumberRef layer_ref = CFDictionaryGetValue( info, kCGWindowLayer );
        CFDictionaryRef bounds_ref = CFDictionaryGetValue( info, kCGWindowBounds );
        int pid = 0, layer = 0;
        CGRect bounds;

        if (!pid_ref || !bounds_ref || !CFNumberGetValue( pid_ref, kCFNumberIntType, &pid )) continue;
        if (layer_ref) CFNumberGetValue( layer_ref, kCFNumberIntType, &layer );
        if (!CGRectMakeWithDictionaryRepresentation( bounds_ref, &bounds )) continue;
        if (proc_pidpath( pid, file, sizeof(file) ) <= 0) continue;
        if (strncmp( file, dir, dir_len ) || file[dir_len] != '/') continue;
        printf( "%d\t%dx%d\t%d,%d\t%d\t%s\n", pid, (int)bounds.size.width, (int)bounds.size.height,
                (int)bounds.origin.x, (int)bounds.origin.y, layer, file );
    }
    CFRelease( windows );
    return 0;
}
