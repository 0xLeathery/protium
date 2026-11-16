#include "unix_private.h"

#if 0
#pragma makedep unix
#endif

#include <unordered_map>

#ifdef __linux__
#include <X11/keysym.h>
#endif

#ifdef __linux__
static const uint32_t vk_to_xkeysym[0xFF] =
{
    0,            /* 0x0  Undefined */
    0,            /* VK_LBUTTON */
    0,            /* VK_RBUTTON */
    XK_Cancel,    /* VK_CANCEL */
    0,            /* VK_MBUTTON */
    0,            /* VK_XBUTTON1 */
    0,            /* VK_XBUTTON2 */
    0,            /* 0x07 Undefined */
    XK_BackSpace, /* VK_BACK */
    XK_Tab,       /* VK_TAB */
    0,            /* 0x0A-0x0B  Undefined */
    0,
    XK_Clear,  /* VK_CLEAR */
    XK_Return, /* VK_RETURN */
    0,         /* 0x0E-0x0F  Undefined */
    0,
    XK_Shift_L,     /* VK_SHIFT */
    XK_Control_L,   /* VK_CONTROL */
    XK_Alt_L,       /* VK_MENU */
    XK_Pause,       /* VK_PAUSE */
    XK_Caps_Lock,   /* VK_CAPITAL */
    0,              /* VK_KANA */
    0,              /* 0x16  Undefined */
    0,              /* VK_JUNJA */
    0,              /* VK_FINAL */
    0,              /* VK_HANJA */
    0,              /* 0x1A  Undefined */
    XK_Escape,      /* VK_ESCAPE */
    XK_Henkan_Mode, /* VK_CONVERT */
    XK_Muhenkan,    /* VK_NONCONVERT */
    0,              /* VK_ACCEPT */
    0,              /* VK_MODECHANGE */
    ' ',            /* VK_SPACE */
    XK_Prior,       /* VK_PRIOR */
    XK_Next,        /* VK_NEXT */
    XK_End,         /* VK_END */
    XK_Home,        /* VK_HOME */
    XK_Left,        /* VK_LEFT */
    XK_Up,          /* VK_UP */
    XK_Right,       /* VK_RIGHT */
    XK_Down,        /* VK_DOWN */
    XK_Select,      /* VK_SELECT */
    XK_Print,       /* VK_PRINT */
    XK_Execute,     /* VK_EXECUTE */
    XK_Print,       /* VK_SNAPSHOT */
    XK_Insert,      /* VK_INSERT */
    XK_Delete,      /* VK_DELETE */
    XK_Help,        /* VK_HELP */

    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    0,
    0,
    0,
    0,
    0,
    0,
    0, /* 0x3A-0x40  Undefined */
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',

    XK_Super_L,      /* VK_LWIN */
    XK_Super_R,      /* VK_RWIN */
    XK_Menu,         /* VK_APPS */
    0,               /* 0x5E  Unassigned */
    0,               /* VK_SLEEP */
    XK_KP_0,         /* VK_NUMPAD0 */
    XK_KP_1,         /* VK_NUMPAD1 */
    XK_KP_2,         /* VK_NUMPAD2 */
    XK_KP_3,         /* VK_NUMPAD3 */
    XK_KP_4,         /* VK_NUMPAD4 */
    XK_KP_5,         /* VK_NUMPAD5 */
    XK_KP_6,         /* VK_NUMPAD6 */
    XK_KP_7,         /* VK_NUMPAD7 */
    XK_KP_8,         /* VK_NUMPAD8 */
    XK_KP_9,         /* VK_NUMPAD9 */
    XK_KP_Multiply,  /* VK_MULTIPLY */
    XK_KP_Add,       /* VK_ADD */
    XK_KP_Separator, /* VK_SEPARATOR */
    XK_KP_Subtract,  /* VK_SUBTRACT */
    XK_KP_Decimal,   /* VK_DECIMAL */
    XK_KP_Divide,    /* VK_DIVIDE */
    XK_F1,           /* VK_F1 */
    XK_F2,           /* VK_F2 */
    XK_F3,           /* VK_F3 */
    XK_F4,           /* VK_F4 */
    XK_F5,           /* VK_F5 */
    XK_F6,           /* VK_F6 */
    XK_F7,           /* VK_F7 */
    XK_F8,           /* VK_F8 */
    XK_F9,           /* VK_F9 */
    XK_F10,          /* VK_F10 */
    XK_F11,          /* VK_F11 */
    XK_F12,          /* VK_F12 */
    XK_F13,          /* VK_F13 */
    XK_F14,          /* VK_F14 */
    XK_F15,          /* VK_F15 */
    XK_F16,          /* VK_F16 */
    XK_F17,          /* VK_F17 */
    XK_F18,          /* VK_F18 */
    XK_F19,          /* VK_F19 */
    XK_F20,          /* VK_F20 */
    XK_F21,          /* VK_F21 */
    XK_F22,          /* VK_F22 */
    XK_F23,          /* VK_F23 */
    XK_F24,          /* VK_F24 */
    0,               /* VK_NAVIGATION_VIEW */
    0,               /* VK_NAVIGATION_MENU */
    0,               /* VK_NAVIGATION_UP */
    0,               /* VK_NAVIGATION_DOWN */
    0,               /* VK_NAVIGATION_LEFT */
    0,               /* VK_NAVIGATION_RIGHT */
    0,               /* VK_NAVIGATION_ACCEPT */
    0,               /* VK_NAVIGATION_CANCEL */
    XK_Num_Lock,     /* VK_NUMLOCK */
    XK_Scroll_Lock,  /* VK_SCROLL */
    XK_KP_Equal,     /* VK_OEM_NEC_EQUAL */
    0,               /* VK_OEM_FJ_JISHO */
    0,               /* VK_OEM_FJ_MASSHOU */
    0,               /* VK_OEM_FJ_TOUROKU */
    0,               /* VK_OEM_FJ_LOYA */
    0,               /* VK_OEM_FJ_ROYA */
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,            /* 0x97-0x9F  Unassigned */
    XK_Shift_L,   /* VK_LSHIFT */
    XK_Shift_R,   /* VK_RSHIFT */
    XK_Control_L, /* VK_LCONTROL */
    XK_Control_R, /* VK_RCONTROL */
    XK_Alt_L,     /* VK_LMENU */
    XK_Alt_R,     /* VK_RMENU */

    /* below are OEM, browser keys, etc */
};

uint32_t manual_convert_nNativeKeyCode( uint32_t win_vk )
{
    if(win_vk < sizeof(vk_to_xkeysym) / sizeof(*vk_to_xkeysym))
        return vk_to_xkeysym[win_vk];
    return 0;
}
#elif defined(__APPLE__) && defined(__aarch64__)
#include <winuser.h>

/* Steam's HTML surface on macOS takes Mac virtual key codes (kVK_* from HIToolbox/Events.h).
 * kVK_ANSI_A is 0, so a key without a Mac equivalent gets 0xffff instead. */
uint32_t manual_convert_nNativeKeyCode( uint32_t win_vk )
{
    switch (win_vk)
    {
    case 'A': return 0x00; case 'S': return 0x01; case 'D': return 0x02; case 'F': return 0x03;
    case 'H': return 0x04; case 'G': return 0x05; case 'Z': return 0x06; case 'X': return 0x07;
    case 'C': return 0x08; case 'V': return 0x09; case 'B': return 0x0b; case 'Q': return 0x0c;
    case 'W': return 0x0d; case 'E': return 0x0e; case 'R': return 0x0f; case 'Y': return 0x10;
    case 'T': return 0x11; case '1': return 0x12; case '2': return 0x13; case '3': return 0x14;
    case '4': return 0x15; case '6': return 0x16; case '5': return 0x17; case '9': return 0x19;
    case '7': return 0x1a; case '8': return 0x1c; case '0': return 0x1d; case 'O': return 0x1f;
    case 'U': return 0x20; case 'I': return 0x22; case 'P': return 0x23; case 'L': return 0x25;
    case 'J': return 0x26; case 'K': return 0x28; case 'N': return 0x2d; case 'M': return 0x2e;
    case VK_OEM_PLUS: return 0x18;   case VK_OEM_MINUS: return 0x1b;  case VK_OEM_6: return 0x1e;
    case VK_OEM_4: return 0x21;      case VK_OEM_7: return 0x27;      case VK_OEM_1: return 0x29;
    case VK_OEM_5: return 0x2a;      case VK_OEM_COMMA: return 0x2b;  case VK_OEM_2: return 0x2c;
    case VK_OEM_PERIOD: return 0x2f; case VK_OEM_3: return 0x32;      case VK_OEM_102: return 0x0a;
    case VK_RETURN: return 0x24;     case VK_TAB: return 0x30;        case VK_SPACE: return 0x31;
    case VK_BACK: return 0x33;       case VK_ESCAPE: return 0x35;     case VK_LWIN: return 0x37;
    case VK_RWIN: return 0x36;       case VK_SHIFT: case VK_LSHIFT: return 0x38;
    case VK_RSHIFT: return 0x3c;     case VK_CAPITAL: return 0x39;    case VK_MENU: case VK_LMENU: return 0x3a;
    case VK_RMENU: return 0x3d;      case VK_CONTROL: case VK_LCONTROL: return 0x3b;
    case VK_RCONTROL: return 0x3e;   case VK_DECIMAL: return 0x41;    case VK_MULTIPLY: return 0x43;
    case VK_ADD: return 0x45;        case VK_CLEAR: case VK_NUMLOCK: return 0x47;
    case VK_DIVIDE: return 0x4b;     case VK_SUBTRACT: return 0x4e;   case VK_OEM_NEC_EQUAL: return 0x51;
    case VK_NUMPAD0: return 0x52;    case VK_NUMPAD1: return 0x53;    case VK_NUMPAD2: return 0x54;
    case VK_NUMPAD3: return 0x55;    case VK_NUMPAD4: return 0x56;    case VK_NUMPAD5: return 0x57;
    case VK_NUMPAD6: return 0x58;    case VK_NUMPAD7: return 0x59;    case VK_NUMPAD8: return 0x5b;
    case VK_NUMPAD9: return 0x5c;    case VK_F1: return 0x7a;         case VK_F2: return 0x78;
    case VK_F3: return 0x63;         case VK_F4: return 0x76;         case VK_F5: return 0x60;
    case VK_F6: return 0x61;         case VK_F7: return 0x62;         case VK_F8: return 0x64;
    case VK_F9: return 0x65;         case VK_F10: return 0x6d;        case VK_F11: return 0x67;
    case VK_F12: return 0x6f;        case VK_F13: return 0x69;        case VK_F14: return 0x6b;
    case VK_F15: return 0x71;        case VK_F16: return 0x6a;        case VK_F17: return 0x40;
    case VK_F18: return 0x4f;        case VK_F19: return 0x50;        case VK_F20: return 0x5a;
    case VK_HELP: case VK_INSERT: return 0x72;
    case VK_HOME: return 0x73;       case VK_PRIOR: return 0x74;      case VK_DELETE: return 0x75;
    case VK_END: return 0x77;        case VK_NEXT: return 0x79;       case VK_LEFT: return 0x7b;
    case VK_RIGHT: return 0x7c;      case VK_DOWN: return 0x7d;       case VK_UP: return 0x7e;
    case VK_VOLUME_UP: return 0x48;  case VK_VOLUME_DOWN: return 0x49; case VK_VOLUME_MUTE: return 0x4a;
    }
    return 0xffff;
}
#else
#error You must implement VK<->Native keysym conversion for this platform.
#endif

typedef std::unordered_map< uint64_t, char * > glyph_cache;
static glyph_cache input_cache, input_cache_svg, input_cache_png, xbox_cache, controller_cache;

static const char *glyph_cache_lookup( glyph_cache &cache, const char *str, uint16_t origin,
                                       uint32_t flags, uint16_t size )
{
    uint64_t key = (uint64_t)flags << 32 | (uint64_t)size << 16 | origin;

    if (cache.find( key ) == cache.end())
    {
        char *dos_path = (char *)malloc( PATH_MAX );
        steamclient_unix_path_to_dos_path( 1, str, dos_path, PATH_MAX, 0 );
        cache[key] = dos_path;
    }

    return cache[key];
}

template< typename Iface, typename Params >
static NTSTATUS ISteamController_GetGlyphForActionOrigin( Iface *iface, Params *params, bool wow64 )
{
    if (!(params->_ret = iface->GetGlyphForActionOrigin( params->eOrigin ))) return 0;
    params->_ret = glyph_cache_lookup( controller_cache, params->_ret, params->eOrigin, 0, 0 );
    return 0;
}

template< typename Iface, typename Params >
static NTSTATUS ISteamController_GetGlyphForXboxOrigin( Iface *iface, Params *params, bool wow64 )
{
    if (!(params->_ret = iface->GetGlyphForXboxOrigin( params->eOrigin ))) return 0;
    params->_ret = glyph_cache_lookup( xbox_cache, params->_ret, params->eOrigin, 0, 0 );
    return 0;
}

template< typename Iface, typename Params >
static NTSTATUS ISteamInput_GetGlyphForActionOrigin( Iface *iface, Params *params, bool wow64 )
{
    if (!(params->_ret = iface->GetGlyphForActionOrigin( params->eOrigin ))) return 0;
    params->_ret = glyph_cache_lookup( input_cache, params->_ret, params->eOrigin, 0, 0 );
    return 0;
}

template< typename Iface, typename Params >
static NTSTATUS ISteamInput_GetGlyphForXboxOrigin( Iface *iface, Params *params, bool wow64 )
{
    if (!(params->_ret = iface->GetGlyphForXboxOrigin( params->eOrigin ))) return 0;
    params->_ret = glyph_cache_lookup( xbox_cache, params->_ret, params->eOrigin, 0, 0 );
    return 0;
}

static void (W_CDECL *w_EnableActionEventCallbacks_152)( SteamInputActionEvent_t * );
static void U_CDECL u_SteamInputActionEventCallbackPointer_152( SteamInputActionEvent_t *dat )
{
    if (w_EnableActionEventCallbacks_152) queue_cdecl_func_callback( (w_cdecl_func)w_EnableActionEventCallbacks_152, dat, sizeof(*dat) );
}

template< typename Iface, typename Params >
NTSTATUS ISteamInput_EnableActionEventCallbacks( Iface *iface, Params *params, bool wow64 )
{
    w_EnableActionEventCallbacks_152 = params->pCallback;
    iface->EnableActionEventCallbacks( params->pCallback ? &u_SteamInputActionEventCallbackPointer_152 : NULL );
    return 0;
}

template< typename Iface, typename Params >
static NTSTATUS ISteamInput_GetGlyphPNGForActionOrigin( Iface *iface, Params *params, bool wow64 )
{
    if (!(params->_ret = iface->GetGlyphPNGForActionOrigin( params->eOrigin, params->eSize, params->unFlags ))) return 0;
    params->_ret = glyph_cache_lookup( input_cache_png, params->_ret, params->eOrigin, params->unFlags, params->eSize );
    return 0;
}

template< typename Iface, typename Params >
static NTSTATUS ISteamInput_GetGlyphSVGForActionOrigin( Iface *iface, Params *params, bool wow64 )
{
    if (!(params->_ret = iface->GetGlyphSVGForActionOrigin( params->eOrigin, params->unFlags ))) return 0;
    params->_ret = glyph_cache_lookup( input_cache_svg, params->_ret, params->eOrigin, params->unFlags, 0 );
    return 0;
}

template< typename Iface, typename Params >
static NTSTATUS ISteamInput_GetGlyphForActionOrigin_Legacy( Iface *iface, Params *params, bool wow64 )
{
    if (!(params->_ret = iface->GetGlyphForActionOrigin_Legacy( params->eOrigin ))) return 0;
    params->_ret = glyph_cache_lookup( input_cache, params->_ret, params->eOrigin, 0, 0 );
    return 0;
}

LSTEAMCLIENT_UNIX_IMPL( ISteamController, SteamController005, GetGlyphForActionOrigin );

LSTEAMCLIENT_UNIX_IMPL( ISteamController, SteamController006, GetGlyphForActionOrigin );

LSTEAMCLIENT_UNIX_IMPL( ISteamController, SteamController007, GetGlyphForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamController, SteamController007, GetGlyphForXboxOrigin );

LSTEAMCLIENT_UNIX_IMPL( ISteamController, SteamController008, GetGlyphForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamController, SteamController008, GetGlyphForXboxOrigin );

LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput001, GetGlyphForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput001, GetGlyphForXboxOrigin );

LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput002, GetGlyphForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput002, GetGlyphForXboxOrigin );

LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput005, EnableActionEventCallbacks );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput005, GetGlyphPNGForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput005, GetGlyphSVGForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput005, GetGlyphForActionOrigin_Legacy );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput005, GetGlyphForXboxOrigin );

LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput006, EnableActionEventCallbacks );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput006, GetGlyphPNGForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput006, GetGlyphSVGForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput006, GetGlyphForActionOrigin_Legacy );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput006, GetGlyphForXboxOrigin );

LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput007, EnableActionEventCallbacks );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput007, GetGlyphPNGForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput007, GetGlyphSVGForActionOrigin );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput007, GetGlyphForActionOrigin_Legacy );
LSTEAMCLIENT_UNIX_IMPL( ISteamInput, SteamInput007, GetGlyphForXboxOrigin );
