/*
 * Print the path that each process was started with next to the file it runs, for the processes
 * whose file is below DIR:
 *
 *   proc_exec_path DIR        ->  PID <tab> path of the exec <tab> file
 *
 * The path of the exec is the first string of KERN_PROCARGS2. It is what
 * _NSGetExecutablePath() returns and what the main bundle is found from: a loader started through
 * a link next to wine.app runs the same file as one started by its path inside the bundle, but
 * has no bundle. ps is no help here, Wine replaces the arguments it prints.
 *
 * Build: clang -O1 -Wall -o proc_exec_path proc_exec_path.c
 */

#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

int main( int argc, char *argv[] )
{
    static pid_t pids[16384];
    char file[PROC_PIDPATHINFO_MAXSIZE], dir[PROC_PIDPATHINFO_MAXSIZE];
    int i, count, argmax, mib_max[2] = { CTL_KERN, KERN_ARGMAX };
    size_t size = sizeof(argmax), dir_len;
    char *args;

    if (argc != 2 || !realpath( argv[1], dir ))
    {
        fprintf( stderr, "usage: %s DIR\n", argv[0] );
        return 2;
    }
    dir_len = strlen( dir );
    if (sysctl( mib_max, 2, &argmax, &size, NULL, 0 ) || !(args = malloc( argmax + 1 )))
    {
        perror( "kern.argmax" );
        return 2;
    }

    count = proc_listallpids( pids, sizeof(pids) );
    for (i = 0; i < count; i++)
    {
        int mib[3] = { CTL_KERN, KERN_PROCARGS2, pids[i] };

        if (proc_pidpath( pids[i], file, sizeof(file) ) <= 0) continue;
        if (strncmp( file, dir, dir_len ) || file[dir_len] != '/') continue;
        size = argmax;
        if (sysctl( mib, 3, args, &size, NULL, 0 ) || size <= sizeof(int)) continue;  /* it exited */
        args[size] = 0;
        printf( "%d\t%s\t%s\n", (int)pids[i], args + sizeof(int), file );
    }
    return 0;
}
