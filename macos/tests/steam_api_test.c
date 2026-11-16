/*
 * Reach Steam through a game's own steam_api64.dll, as the game would.
 *
 *   steam_api_test.exe <path to steam_api64.dll> <app id>
 *
 * Loads the DLL, calls SteamAPI_InitFlat with SteamAppId set to the app id, and prints one line:
 *
 *   steam api: init 0, running 1, logged on 1, steamid ...1234, subscribed 1
 *
 * Under Proton the DLL loads Valve's Windows steamclient64.dll, whose exports ntdll points at
 * lsteamclient, which passes the calls to the native Steam client. Only the last four digits
 * of the SteamID are printed. The flat API names are those of Steamworks SDK 1.5x-1.6x
 * (SteamUser_v023, SteamApps_v008).
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (__cdecl *init_flat_fn)(char *err);
typedef BOOL (__cdecl *bool_fn)(void);
typedef void (__cdecl *void_fn)(void);
typedef void *(__cdecl *iface_fn)(void);
typedef BOOL (__cdecl *iface_bool_fn)(void *);
typedef unsigned long long (__cdecl *iface_u64_fn)(void *);
typedef BOOL (__cdecl *subscribed_app_fn)(void *, unsigned int);

#define LOAD(type, name) type name = (type)GetProcAddress(dll, #name); \
    if (!name) { printf("steam api: %s not exported\n", #name); return 2; }

int main(int argc, char **argv)
{
    char err[1024] = "", env[64];
    unsigned int appid;
    HMODULE dll;
    int init, i;

    if (argc != 3) { printf("usage: steam_api_test.exe <steam_api64.dll> <app id>\n"); return 2; }
    appid = strtoul(argv[2], NULL, 10);
    snprintf(env, sizeof(env), "%u", appid);
    SetEnvironmentVariableA("SteamAppId", env);
    SetEnvironmentVariableA("SteamGameId", env);

    if (!(dll = LoadLibraryA(argv[1]))) { printf("steam api: cannot load %s (%lu)\n", argv[1], GetLastError()); return 2; }
    {
        LOAD(init_flat_fn, SteamAPI_InitFlat)
        LOAD(bool_fn, SteamAPI_IsSteamRunning)
        LOAD(void_fn, SteamAPI_RunCallbacks)
        LOAD(void_fn, SteamAPI_Shutdown)
        LOAD(iface_fn, SteamAPI_SteamUser_v023)
        LOAD(iface_fn, SteamAPI_SteamApps_v008)
        LOAD(iface_bool_fn, SteamAPI_ISteamUser_BLoggedOn)
        LOAD(iface_u64_fn, SteamAPI_ISteamUser_GetSteamID)
        LOAD(subscribed_app_fn, SteamAPI_ISteamApps_BIsSubscribedApp)
        void *user, *apps;
        unsigned long long id;

        init = SteamAPI_InitFlat(err);
        if (init)
        {
            printf("steam api: init %d (%s), running %d\n", init, err, SteamAPI_IsSteamRunning());
            return 1;
        }
        for (i = 0; i < 10; i++) { SteamAPI_RunCallbacks(); Sleep(100); }
        user = SteamAPI_SteamUser_v023();
        apps = SteamAPI_SteamApps_v008();
        id = user ? SteamAPI_ISteamUser_GetSteamID(user) : 0;
        printf("steam api: init 0, running %d, logged on %d, steamid ...%04llu, subscribed %d\n",
               SteamAPI_IsSteamRunning(), user ? SteamAPI_ISteamUser_BLoggedOn(user) : -1,
               id % 10000, apps ? SteamAPI_ISteamApps_BIsSubscribedApp(apps, appid) : -1);
        fflush(stdout);
        SteamAPI_Shutdown();
    }
    return 0;
}
