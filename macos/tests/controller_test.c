/*
 * Lists the game controllers a game would see, through XInput and DirectInput:
 *
 *   controller_test.exe
 *
 * Prints one line per controller and a summary, e.g.
 *   controller: xinput 0, buttons 0000
 *   controller: dinput "Xbox Wireless Controller", 16 buttons, 6 axes
 *   controller: 1 xinput, 1 dinput
 * and exits 0 when at least one controller was found, 2 when none is connected. No window is
 * shown.
 *
 * Built for x86_64 with the mingw compiler: -lxinput -ldinput8 -ldxguid -luuid -lole32.
 */
#define COBJMACROS
#define DIRECTINPUT_VERSION 0x0800
#include <windows.h>
#include <xinput.h>
#include <dinput.h>
#include <stdio.h>

static IDirectInput8A *dinput;
static int dinput_count;

static BOOL CALLBACK enum_device( const DIDEVICEINSTANCEA *instance, void *context )
{
    IDirectInputDevice8A *device;
    DIDEVCAPS caps = { sizeof(caps) };

    if (SUCCEEDED(IDirectInput8_CreateDevice( dinput, &instance->guidInstance, &device, NULL )))
    {
        IDirectInputDevice8_GetCapabilities( device, &caps );
        IDirectInputDevice8_Release( device );
    }
    printf( "controller: dinput \"%s\", %lu buttons, %lu axes\n", instance->tszProductName, caps.dwButtons, caps.dwAxes );
    dinput_count++;
    return DIENUM_CONTINUE;
}

int main( void )
{
    int xinput_count = 0, i;
    XINPUT_STATE state;
    HRESULT hr;

    for (i = 0; i < XUSER_MAX_COUNT; i++)
    {
        if (XInputGetState( i, &state ) != ERROR_SUCCESS) continue;
        printf( "controller: xinput %d, buttons %04x\n", i, state.Gamepad.wButtons );
        xinput_count++;
    }
    if (SUCCEEDED(hr = DirectInput8Create( GetModuleHandleA( NULL ), DIRECTINPUT_VERSION, &IID_IDirectInput8A,
                                           (void **)&dinput, NULL )))
        IDirectInput8_EnumDevices( dinput, DI8DEVCLASS_GAMECTRL, enum_device, NULL, DIEDFL_ATTACHEDONLY );
    else
        printf( "controller: DirectInput8Create %#lx\n", hr );

    printf( "controller: %d xinput, %d dinput\n", xinput_count, dinput_count );
    return xinput_count || dinput_count ? 0 : 2;
}
