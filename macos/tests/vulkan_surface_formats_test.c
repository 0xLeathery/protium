/*
 * Lists the Vulkan surface formats of a window, the way a game sees them through vulkan-1.dll,
 * and checks what Wine does to the host driver's list on macOS:
 *   - VK_FORMAT_B8G8R8A8_UNORM in the sRGB colour space comes first (Red Dead Redemption 2 takes
 *     the first entry to be that one);
 *   - the HDR10, HLG and Dolby Vision colour spaces are there only when Windows' display API says
 *     the window's monitor is in HDR mode (DisplayConfigGetDeviceInfo, advanced colour enabled);
 *   - vkGetPhysicalDeviceSurfaceFormats2KHR gives the same list as the first call;
 *   - a short array gets VK_INCOMPLETE and the first entries.
 *
 * The window is never shown, so the test takes no focus. Prints the list, one line per check and
 * "surface formats: PASS" or "surface formats: FAIL", and exits 0 only on PASS.
 *
 * Needs no Vulkan headers, the few declarations are here. Built for x86_64 with
 *   x86_64-w64-mingw32-clang -O2 -Wall vulkan_surface_formats_test.c -luser32
 */
#include <stdio.h>
#include <string.h>
#include <windows.h>

typedef unsigned long long VkSurfaceKHR;

typedef struct
{
    int sType;
    const void *pNext;
    const char *pApplicationName;
    unsigned int applicationVersion;
    const char *pEngineName;
    unsigned int engineVersion;
    unsigned int apiVersion;
} VkApplicationInfo;

typedef struct
{
    int sType;
    const void *pNext;
    unsigned int flags;
    const VkApplicationInfo *pApplicationInfo;
    unsigned int enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    unsigned int enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef struct
{
    int sType;
    const void *pNext;
    unsigned int flags;
    HINSTANCE hinstance;
    HWND hwnd;
} VkWin32SurfaceCreateInfoKHR;

typedef struct
{
    int format;
    int colorSpace;
} VkSurfaceFormatKHR;

typedef struct
{
    int sType;
    const void *pNext;
    VkSurfaceKHR surface;
} VkPhysicalDeviceSurfaceInfo2KHR;

typedef struct
{
    int sType;
    void *pNext;
    VkSurfaceFormatKHR surfaceFormat;
} VkSurfaceFormat2KHR;

#define VK_INCOMPLETE 5
#define STYPE_APPLICATION_INFO 0
#define STYPE_INSTANCE_CREATE_INFO 1
#define STYPE_WIN32_SURFACE_CREATE_INFO 1000009000
#define STYPE_PHYSICAL_DEVICE_SURFACE_INFO_2 1000119000
#define STYPE_SURFACE_FORMAT_2 1000119002
#define FORMAT_B8G8R8A8_UNORM 44
#define COLOR_SPACE_SRGB_NONLINEAR 0
#define COLOR_SPACE_HDR10_ST2084 1000104008
#define COLOR_SPACE_DOLBYVISION 1000104009
#define COLOR_SPACE_HDR10_HLG 1000104010

#define MAX_FORMATS 512

static int failures;

static void check( int ok, const char *what )
{
    printf( "%s: %s\n", ok ? "ok" : "FAILED", what );
    if (!ok) failures++;
}

static int is_hdr( int color_space )
{
    return color_space == COLOR_SPACE_HDR10_ST2084 || color_space == COLOR_SPACE_HDR10_HLG ||
           color_space == COLOR_SPACE_DOLBYVISION;
}

/* what Windows' display API says of the monitor the window is on: 1 HDR, 0 not, -1 unknown */
static int monitor_hdr( HWND hwnd )
{
    static DISPLAYCONFIG_PATH_INFO paths[16];
    static DISPLAYCONFIG_MODE_INFO modes[32];
    UINT32 path_count = 16, mode_count = 32, i;
    MONITORINFOEXW info = { .cbSize = sizeof(info) };
    HMONITOR monitor = MonitorFromWindow( hwnd, MONITOR_DEFAULTTONEAREST );

    if (!GetMonitorInfoW( monitor, (MONITORINFO *)&info )) return -1;
    if (QueryDisplayConfig( QDC_ONLY_ACTIVE_PATHS, &path_count, paths, &mode_count, modes, NULL )) return -1;
    for (i = 0; i < path_count; i++)
    {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source = { { DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(source) } };
        DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO color = { { DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO, sizeof(color) } };

        source.header.adapterId = paths[i].sourceInfo.adapterId;
        source.header.id = paths[i].sourceInfo.id;
        if (DisplayConfigGetDeviceInfo( &source.header )) continue;
        if (wcscmp( source.viewGdiDeviceName, info.szDevice )) continue;
        color.header.adapterId = paths[i].targetInfo.adapterId;
        color.header.id = paths[i].targetInfo.id;
        if (DisplayConfigGetDeviceInfo( &color.header )) return -1;
        return color.advancedColorEnabled ? 1 : 0;
    }
    return -1;
}

int main(void)
{
    static const char *extensions[] = { "VK_KHR_surface", "VK_KHR_win32_surface", "VK_KHR_get_surface_capabilities2",
                                         "VK_EXT_swapchain_colorspace" };
    static VkSurfaceFormatKHR formats[MAX_FORMATS];
    static VkSurfaceFormat2KHR formats2[MAX_FORMATS];
    HMODULE vulkan = LoadLibraryA( "vulkan-1.dll" );
    int (WINAPI *create_instance)( const VkInstanceCreateInfo *, const void *, void ** );
    int (WINAPI *enumerate_devices)( void *, unsigned int *, void ** );
    void *(WINAPI *get_instance_proc)( void *, const char * );
    int (WINAPI *create_surface)( void *, const VkWin32SurfaceCreateInfoKHR *, const void *, VkSurfaceKHR * );
    int (WINAPI *get_formats)( void *, VkSurfaceKHR, unsigned int *, VkSurfaceFormatKHR * );
    int (WINAPI *get_formats2)( void *, const VkPhysicalDeviceSurfaceInfo2KHR *, unsigned int *, VkSurfaceFormat2KHR * );
    void (WINAPI *destroy_surface)( void *, VkSurfaceKHR, const void * );
    void (WINAPI *destroy_instance)( void *, const void * );
    VkApplicationInfo app = { STYPE_APPLICATION_INFO };
    VkInstanceCreateInfo info = { STYPE_INSTANCE_CREATE_INFO };
    VkWin32SurfaceCreateInfoKHR surface_info = { STYPE_WIN32_SURFACE_CREATE_INFO };
    VkPhysicalDeviceSurfaceInfo2KHR surface_info2 = { STYPE_PHYSICAL_DEVICE_SURFACE_INFO_2 };
    unsigned int count, count2, short_count, n_hdr = 0, i, device_count = 1, same;
    void *instance = NULL, *device = NULL;
    VkSurfaceKHR surface = 0;
    VkSurfaceFormatKHR first = { 0 };
    char what[256];
    int res, hdr;
    HWND hwnd;

    if (!vulkan)
    {
        printf( "surface formats: no vulkan-1.dll, error %lu\nsurface formats: FAIL\n", GetLastError() );
        return 1;
    }
    create_instance = (void *)GetProcAddress( vulkan, "vkCreateInstance" );
    enumerate_devices = (void *)GetProcAddress( vulkan, "vkEnumeratePhysicalDevices" );
    get_instance_proc = (void *)GetProcAddress( vulkan, "vkGetInstanceProcAddr" );
    destroy_instance = (void *)GetProcAddress( vulkan, "vkDestroyInstance" );
    if (!create_instance || !enumerate_devices || !get_instance_proc || !destroy_instance)
    {
        printf( "surface formats: vulkan-1.dll lacks an entry point\nsurface formats: FAIL\n" );
        return 1;
    }

    app.pApplicationName = "vulkan_surface_formats_test";
    app.apiVersion = (1u << 22) | (1u << 12);
    info.pApplicationInfo = &app;
    info.enabledExtensionCount = ARRAYSIZE(extensions);
    info.ppEnabledExtensionNames = extensions;
    if ((res = create_instance( &info, NULL, &instance )))
    {
        printf( "surface formats: vkCreateInstance failed, result %d\nsurface formats: FAIL\n", res );
        return 1;
    }
    if (enumerate_devices( instance, &device_count, &device ) < 0 || !device)
    {
        printf( "surface formats: no physical device\nsurface formats: FAIL\n" );
        return 1;
    }
    create_surface = get_instance_proc( instance, "vkCreateWin32SurfaceKHR" );
    get_formats = get_instance_proc( instance, "vkGetPhysicalDeviceSurfaceFormatsKHR" );
    get_formats2 = get_instance_proc( instance, "vkGetPhysicalDeviceSurfaceFormats2KHR" );
    destroy_surface = get_instance_proc( instance, "vkDestroySurfaceKHR" );
    if (!create_surface || !get_formats || !get_formats2 || !destroy_surface)
    {
        printf( "surface formats: an instance function is missing\nsurface formats: FAIL\n" );
        return 1;
    }

    /* never shown: no focus taken */
    hwnd = CreateWindowExA( 0, "static", "vulkan_surface_formats_test", WS_POPUP, 0, 0, 640, 360,
                            NULL, NULL, GetModuleHandleA( NULL ), NULL );
    surface_info.hinstance = GetModuleHandleA( NULL );
    surface_info.hwnd = hwnd;
    if (!hwnd || (res = create_surface( instance, &surface_info, NULL, &surface )))
    {
        printf( "surface formats: no window or no surface (result %d)\nsurface formats: FAIL\n", hwnd ? res : -1 );
        return 1;
    }

    hdr = monitor_hdr( hwnd );
    printf( "monitor HDR (advanced colour enabled): %s\n", hdr < 0 ? "unknown" : hdr ? "yes" : "no" );

    count = 0;
    res = get_formats( device, surface, &count, NULL );
    check( !res && count > 0 && count <= MAX_FORMATS, "vkGetPhysicalDeviceSurfaceFormatsKHR gives a count" );
    if (count > MAX_FORMATS) count = MAX_FORMATS;
    res = get_formats( device, surface, &count, formats );
    check( !res, "vkGetPhysicalDeviceSurfaceFormatsKHR fills the list" );
    printf( "formats (%u):", count );
    for (i = 0; i < count; i++)
    {
        printf( " %d/%d", formats[i].format, formats[i].colorSpace );
        if (is_hdr( formats[i].colorSpace )) n_hdr++;
    }
    printf( "\n" );
    if (count) first = formats[0];

    snprintf( what, sizeof(what), "the first entry is B8G8R8A8_UNORM in the sRGB colour space (it is %d/%d)",
              first.format, first.colorSpace );
    check( first.format == FORMAT_B8G8R8A8_UNORM && first.colorSpace == COLOR_SPACE_SRGB_NONLINEAR, what );

    check( hdr >= 0, "Windows' display API answers for the window's monitor" );
    snprintf( what, sizeof(what), "%u entries in an HDR colour space, %s", n_hdr,
              hdr > 0 ? "some wanted: the monitor is in HDR mode" : "none wanted: the monitor is not in HDR mode" );
    check( hdr > 0 ? n_hdr > 0 : n_hdr == 0, what );

    count2 = 0;
    surface_info2.surface = surface;
    res = get_formats2( device, &surface_info2, &count2, NULL );
    snprintf( what, sizeof(what), "vkGetPhysicalDeviceSurfaceFormats2KHR gives the same count (%u, result %d)", count2, res );
    check( !res && count2 == count, what );
    if (count2 > MAX_FORMATS) count2 = MAX_FORMATS;
    for (i = 0; i < count2; i++) formats2[i].sType = STYPE_SURFACE_FORMAT_2;
    res = get_formats2( device, &surface_info2, &count2, formats2 );
    same = !res && count2 == count;
    for (i = 0; same && i < count; i++)
        same = formats2[i].surfaceFormat.format == formats[i].format &&
               formats2[i].surfaceFormat.colorSpace == formats[i].colorSpace;
    check( same, "vkGetPhysicalDeviceSurfaceFormats2KHR gives the same list in the same order" );

    short_count = 1;
    memset( formats, 0xcc, sizeof(formats) );
    res = get_formats( device, surface, &short_count, formats );
    snprintf( what, sizeof(what), "an array of one gets VK_INCOMPLETE and the first entry (result %d, count %u, %d/%d)",
              res, short_count, formats[0].format, formats[0].colorSpace );
    check( count > 1 && res == VK_INCOMPLETE && short_count == 1 && formats[0].format == first.format &&
           formats[0].colorSpace == first.colorSpace && formats[1].format == (int)0xcccccccc, what );

    short_count = 1;
    memset( formats2, 0, sizeof(formats2) );
    for (i = 0; i < 2; i++) formats2[i].sType = STYPE_SURFACE_FORMAT_2;
    res = get_formats2( device, &surface_info2, &short_count, formats2 );
    snprintf( what, sizeof(what), "the same with vkGetPhysicalDeviceSurfaceFormats2KHR (result %d, count %u)", res, short_count );
    check( res == VK_INCOMPLETE && short_count == 1 && formats2[0].surfaceFormat.format == first.format &&
           formats2[0].surfaceFormat.colorSpace == first.colorSpace && !formats2[1].surfaceFormat.format, what );

    destroy_surface( instance, surface, NULL );
    DestroyWindow( hwnd );
    destroy_instance( instance, NULL );
    printf( "surface formats: %s\n", failures ? "FAIL" : "PASS" );
    return failures ? 1 : 0;
}
