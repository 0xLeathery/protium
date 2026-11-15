/*
 * Calls Vulkan from Windows code: vulkan-1.dll, which in Wine reaches the host's Vulkan loader
 * through winevulkan. Needs no Vulkan headers, the few declarations are here.
 *
 * Prints one line, e.g.
 *   vulkan: loader 1.4.363, instance 0, devices 1, first device "Apple M4 Pro" api 1.3.0
 * and exits 0 when the loader answers with a version. "instance" is the result of
 * vkCreateInstance(): 0 is success, -9 (VK_ERROR_INCOMPATIBLE_DRIVER) is what a loader without
 * any driver gives. The caller decides whether it wants a device.
 *
 * Built for aarch64, ARM64EC or x86_64; it only uses kernel32.
 */
#include <stdio.h>
#include <string.h>
#include <windows.h>

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

/* the start of VkPhysicalDeviceProperties; the rest is not read */
typedef struct
{
    unsigned int apiVersion;
    unsigned int driverVersion;
    unsigned int vendorID;
    unsigned int deviceID;
    int deviceType;
    char deviceName[256];
    unsigned char rest[1024];
} VkPhysicalDeviceProperties;

#define VERSION_MAJOR(v) (((v) >> 22) & 0x7f)
#define VERSION_MINOR(v) (((v) >> 12) & 0x3ff)
#define VERSION_PATCH(v) ((v) & 0xfff)

int main(void)
{
    HMODULE vulkan = LoadLibraryA( "vulkan-1.dll" );
    int (WINAPI *enumerate_version)( unsigned int * );
    int (WINAPI *create_instance)( const VkInstanceCreateInfo *, const void *, void ** );
    int (WINAPI *enumerate_devices)( void *, unsigned int *, void ** );
    void (WINAPI *get_properties)( void *, VkPhysicalDeviceProperties * );
    void (WINAPI *destroy_instance)( void *, const void * );
    VkApplicationInfo app = { 0 /* VK_STRUCTURE_TYPE_APPLICATION_INFO */ };
    VkInstanceCreateInfo info = { 1 /* VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO */ };
    static VkPhysicalDeviceProperties props;
    unsigned int version = 0, count = 0;
    void *instance = NULL, *devices[8] = { 0 };
    int res;

    if (!vulkan)
    {
        printf( "vulkan: no vulkan-1.dll, error %lu\n", GetLastError() );
        return 1;
    }
    enumerate_version = (void *)GetProcAddress( vulkan, "vkEnumerateInstanceVersion" );
    create_instance = (void *)GetProcAddress( vulkan, "vkCreateInstance" );
    enumerate_devices = (void *)GetProcAddress( vulkan, "vkEnumeratePhysicalDevices" );
    get_properties = (void *)GetProcAddress( vulkan, "vkGetPhysicalDeviceProperties" );
    destroy_instance = (void *)GetProcAddress( vulkan, "vkDestroyInstance" );
    if (!enumerate_version || !create_instance || !enumerate_devices || !get_properties || !destroy_instance)
    {
        printf( "vulkan: vulkan-1.dll lacks an entry point\n" );
        return 1;
    }
    if ((res = enumerate_version( &version )) || !version)
    {
        printf( "vulkan: vkEnumerateInstanceVersion failed, result %d\n", res );
        return 1;
    }

    app.pApplicationName = "vulkan_test";
    app.apiVersion = (1u << 22) | (1u << 12);  /* 1.1, which any loader of today takes */
    info.pApplicationInfo = &app;
    res = create_instance( &info, NULL, &instance );
    if (!res)
    {
        count = 8;
        if (enumerate_devices( instance, &count, devices ) < 0) count = 0;
        if (count) get_properties( devices[0], &props );
    }
    printf( "vulkan: loader %u.%u.%u, instance %d, devices %u", VERSION_MAJOR(version), VERSION_MINOR(version),
            VERSION_PATCH(version), res, count );
    if (count) printf( ", first device \"%s\" api %u.%u.%u", props.deviceName, VERSION_MAJOR(props.apiVersion),
                       VERSION_MINOR(props.apiVersion), VERSION_PATCH(props.apiVersion) );
    printf( "\n" );
    if (instance) destroy_instance( instance, NULL );
    return 0;
}
