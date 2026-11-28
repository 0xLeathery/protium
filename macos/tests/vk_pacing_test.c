/*
 * How a Vulkan game's frames are paced, and what a swapchain made anew leaves behind:
 *
 *   vk_pacing_test.exe [key=value ...]
 *     images=2        the image count asked for (the driver's minimum is 3; DOOM 2016 asks for 2)
 *     mode=fifo       or immediate: VK_PRESENT_MODE_FIFO_KHR (V-Sync) or VK_PRESENT_MODE_IMMEDIATE_KHR
 *     size=1280x720   the window's client size; size=screen is a borderless window over the screen
 *     show=1          0: the window is never shown; 2: it is shown and then minimized
 *     loads=0,4,8     heavy blits a frame (the GPU's work), a step of the run for each
 *     secs=10         seconds a step
 *     cpu=0           ms of processor work a frame (a game's own)
 *     slow=0:0        N:ms: frame N of each step sleeps that many ms before it is drawn, and a line
 *                     "truth: frame N (HH:MM:SS.mmm): sleep, 150.2 ms" says so (the log's line for a
 *                     slow frame is held against it)
 *     serial=0        1: wait for each frame's GPU work before the next (its GPU time, unpaced)
 *     recreate=0      N: after the steps, make the swapchain anew N times, `frames` frames on each
 *     frames=1        frames drawn on each swapchain of "recreate"
 *     drop=0          1: "recreate" acquires an image of each swapchain and never presents it, as a
 *                     game does that is told "suboptimal" by the acquire and makes a new swapchain
 *     idle=1          0: the old swapchain is destroyed without waiting for the GPU first
 *     hold=0          seconds to wait before and after "recreate" (for a look at the process)
 *
 * For each step, one line: frames and rate, the frame time's median, 95% and worst, the mean
 * wait in vkAcquireNextImageKHR and time in vkQueuePresentKHR, the GPU's time for a frame (from
 * the end of the frame before, or the submit, to its fence) and the time from submit to fence,
 * and the commonest frame times. "MARK <name>" lines say where the run is, for a script that
 * measures the process from outside.
 *
 * The GPU's work is blits of a 4096x4096 image onto one a pixel smaller, with a filter: no shader
 * of the test's own is needed. The window's picture is one colour that changes every frame.
 *
 * Built for x86_64 with llvm-mingw and Khronos's headers (Mesa's include folder has them):
 *   x86_64-w64-mingw32-clang -O2 -Wall -I<mesa-src>/include vk_pacing_test.c -luser32
 *
 * Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.
 */
#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define BIG 4096
#define RING 8
#define MAX_FRAMES 200000

#define FUNCS(X) \
    X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceProperties) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkGetPhysicalDeviceMemoryProperties) X(vkCreateDevice) \
    X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkCreateWin32SurfaceKHR) X(vkDestroySurfaceKHR) \
    X(vkGetPhysicalDeviceSurfaceCapabilitiesKHR) X(vkGetPhysicalDeviceSurfaceFormatsKHR) \
    X(vkGetPhysicalDeviceSurfaceSupportKHR) X(vkCreateSwapchainKHR) X(vkDestroySwapchainKHR) \
    X(vkGetSwapchainImagesKHR) X(vkAcquireNextImageKHR) X(vkQueuePresentKHR) X(vkCreateCommandPool) \
    X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
    X(vkResetCommandBuffer) X(vkCmdPipelineBarrier) X(vkCmdBlitImage) X(vkCmdClearColorImage) \
    X(vkQueueSubmit) X(vkCreateSemaphore) X(vkDestroySemaphore) X(vkCreateFence) X(vkDestroyFence) \
    X(vkWaitForFences) X(vkResetFences) X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) \
    X(vkAllocateMemory) X(vkFreeMemory) X(vkBindImageMemory) X(vkDeviceWaitIdle)
#define DECLARE(f) static PFN_##f f;
FUNCS(DECLARE)
static PFN_vkCreateInstance vkCreateInstance;

static VkInstance instance;
static VkPhysicalDevice gpu;
static VkDevice device;
static VkQueue queue;
static uint32_t queue_family;
static VkSurfaceKHR surface;
static VkSwapchainKHR swapchain;
static VkImage swap_images[8];
static uint32_t swap_count;
static VkExtent2D extent;
static VkFormat swap_format;
static VkCommandPool pool;
static VkImage big[2];
static VkDeviceMemory big_memory[2];
static HWND window;

static int opt_images = 2, opt_fifo = 1, opt_show = 1, opt_secs = 10, opt_cpu, opt_serial, opt_recreate, opt_frames = 1, opt_hold;
static int opt_slow_frame, opt_slow_ms;
static int opt_drop, opt_idle = 1;
static int opt_width = 1280, opt_height = 720, opt_screen;
static int loads[16], load_count;

/* a frame's slot: its command buffer, semaphores and fence, and what the fence waiter measures */
static struct slot
{
    VkCommandBuffer cmd;
    VkSemaphore acquired, drawn;
    VkFence fence;
    LONGLONG submitted, done;   /* QueryPerformanceCounter values; done is written by the waiter */
    volatile LONG pending;      /* 1 from the submit until the waiter has seen the fence */
} slots[RING];
static HANDLE waiter_wake;
static volatile LONG waiter_next, waiter_stop;
static LONGLONG frequency;

static double ms( LONGLONG ticks ) { return ticks * 1000.0 / frequency; }
static LONGLONG now(void) { LARGE_INTEGER t; QueryPerformanceCounter( &t ); return t.QuadPart; }

static void fail( const char *what, int res )
{
    printf( "vk pacing test: %s failed, result %d\n", what, res );
    fflush( stdout );
    ExitProcess( 1 );
}

/* waits for the fences in the order of their submits, and notes when each was signalled */
static DWORD WINAPI waiter( void *arg )
{
    while (!waiter_stop)
    {
        struct slot *slot = &slots[waiter_next % RING];
        if (!slot->pending)
        {
            WaitForSingleObject( waiter_wake, 50 );
            continue;
        }
        vkWaitForFences( device, 1, &slot->fence, VK_TRUE, ~0ull );
        slot->done = now();
        InterlockedIncrement( &waiter_next );
        InterlockedExchange( &slot->pending, 0 );
    }
    return 0;
}

static LRESULT CALLBACK window_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static void pump(void)
{
    MSG msg;
    while (PeekMessageA( &msg, NULL, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
}

static void barrier( VkCommandBuffer cmd, VkImage image, VkImageLayout from, VkImageLayout to )
{
    VkImageMemoryBarrier b = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    b.oldLayout = from;
    b.newLayout = to;
    b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    b.subresourceRange.levelCount = b.subresourceRange.layerCount = 1;
    b.srcAccessMask = b.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT;
    vkCmdPipelineBarrier( cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &b );
}

static void create_swapchain(void)
{
    VkSwapchainCreateInfoKHR info = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    VkSurfaceCapabilitiesKHR caps;
    VkSwapchainKHR old = swapchain;
    static int said;
    int res;

    if ((res = vkGetPhysicalDeviceSurfaceCapabilitiesKHR( gpu, surface, &caps ))) fail( "vkGetPhysicalDeviceSurfaceCapabilitiesKHR", res );
    extent = caps.currentExtent;
    if (extent.width == 0xffffffff || !extent.width || !extent.height)
    {
        extent.width = opt_width;
        extent.height = opt_height;
    }
    if (!said++)
        printf( "surface: images %u to %u, extent now %ux%u (asking %ux%u), usage %#x\n", caps.minImageCount, caps.maxImageCount,
                caps.currentExtent.width, caps.currentExtent.height, extent.width, extent.height, caps.supportedUsageFlags );
    if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT)) fail( "swapchain images as a transfer destination", 0 );
    info.surface = surface;
    info.minImageCount = opt_images;
    info.imageFormat = swap_format;
    info.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    info.imageExtent = extent;
    info.imageArrayLayers = 1;
    info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    info.presentMode = opt_fifo ? VK_PRESENT_MODE_FIFO_KHR : VK_PRESENT_MODE_IMMEDIATE_KHR;
    info.clipped = VK_TRUE;
    info.oldSwapchain = old;
    if ((res = vkCreateSwapchainKHR( device, &info, NULL, &swapchain ))) fail( "vkCreateSwapchainKHR", res );
    if (old)
    {
        if (opt_idle) vkDeviceWaitIdle( device );
        vkDestroySwapchainKHR( device, old, NULL );
    }
    swap_count = 8;
    if ((res = vkGetSwapchainImagesKHR( device, swapchain, &swap_count, swap_images )) < 0) fail( "vkGetSwapchainImagesKHR", res );
}

struct stats
{
    int frames, suboptimal, out_of_date, not_ready;
    double acquire_ms, present_ms, gpu_ms, latency_ms;
    int gpu_frames;
    float *times;       /* ms of each frame */
};

static int compare_floats( const void *a, const void *b )
{
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

/* one frame: `load` heavy blits and the window's colour; returns 0 when the swapchain has to be made anew.
 * *counter counts the frames that were submitted: each takes the next slot. */
static int draw_frame( int *counter, int load, struct stats *stats )
{
    static LONGLONG last_done;
    int number = *counter;
    struct slot *slot = &slots[number % RING];
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    VkPresentInfoKHR present = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkClearColorValue colour = {{(number % 120) / 120.0f, 0.2f, 0.6f, 1.0f}};
    VkImageBlit blit = {{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{0, 0, 0}, {BIG, BIG, 1}},
                        {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{0, 0, 0}, {BIG - 1, BIG - 1, 1}}};
    LONGLONG start, t;
    uint32_t index = 0;
    int res, i, again = 1;

    /* the slot's last frame, RING frames ago, has to be over, and its numbers taken */
    while (slot->pending) Sleep( 0 );
    if (slot->done)
    {
        LONGLONG from = slot->submitted > last_done ? slot->submitted : last_done;
        stats->gpu_ms += ms( slot->done - from );
        stats->latency_ms += ms( slot->done - slot->submitted );
        stats->gpu_frames++;
        last_done = slot->done;
        slot->done = 0;
    }
    if (opt_cpu)
    {
        start = now();
        while (ms( now() - start ) < opt_cpu) ;
    }
    if (opt_slow_ms && *counter == opt_slow_frame)
    {
        SYSTEMTIME st;

        start = now();
        Sleep( opt_slow_ms );
        GetLocalTime( &st );
        printf( "truth: frame %d (%02u:%02u:%02u.%03u): sleep, %.1f ms\n", *counter, st.wHour, st.wMinute, st.wSecond,
                st.wMilliseconds, ms( now() - start ) );
        fflush( stdout );
    }

    start = now();
    res = vkAcquireNextImageKHR( device, swapchain, 2000000000ull, slot->acquired, VK_NULL_HANDLE, &index );
    stats->acquire_ms += ms( now() - start );
    if (res == VK_ERROR_OUT_OF_DATE_KHR) { stats->out_of_date++; return 0; }
    if (res == VK_TIMEOUT || res == VK_NOT_READY) { stats->not_ready++; return 1; }
    if (res == VK_SUBOPTIMAL_KHR) { stats->suboptimal++; again = 0; }
    else if (res) fail( "vkAcquireNextImageKHR", res );

    vkResetFences( device, 1, &slot->fence );
    vkResetCommandBuffer( slot->cmd, 0 );
    vkBeginCommandBuffer( slot->cmd, &begin );
    for (i = 0; i < load; i++)
        vkCmdBlitImage( slot->cmd, big[i & 1], VK_IMAGE_LAYOUT_GENERAL, big[!(i & 1)], VK_IMAGE_LAYOUT_GENERAL, 1, &blit, VK_FILTER_LINEAR );
    barrier( slot->cmd, swap_images[index], VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL );
    vkCmdClearColorImage( slot->cmd, swap_images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &colour, 1, &range );
    barrier( slot->cmd, swap_images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR );
    vkEndCommandBuffer( slot->cmd );

    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &slot->acquired;
    submit.pWaitDstStageMask = &stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &slot->cmd;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &slot->drawn;
    slot->submitted = now();
    if ((res = vkQueueSubmit( queue, 1, &submit, slot->fence ))) fail( "vkQueueSubmit", res );
    (*counter)++;
    InterlockedExchange( &slot->pending, 1 );
    SetEvent( waiter_wake );
    if (opt_serial) while (slot->pending) Sleep( 0 );

    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &slot->drawn;
    present.swapchainCount = 1;
    present.pSwapchains = &swapchain;
    present.pImageIndices = &index;
    t = now();
    res = vkQueuePresentKHR( queue, &present );
    stats->present_ms += ms( now() - t );
    if (res == VK_ERROR_OUT_OF_DATE_KHR) { stats->out_of_date++; again = 0; }
    else if (res == VK_SUBOPTIMAL_KHR) { stats->suboptimal++; again = 0; }
    else if (res) fail( "vkQueuePresentKHR", res );
    stats->frames++;
    return again;
}

static void run_step( int load, int *number )
{
    static float times[MAX_FRAMES];
    struct stats stats = {0};
    LONGLONG start = now(), last = start, t;
    double seconds;
    int i, n = 0, shown;

    while (ms( (t = now()) - start ) < opt_secs * 1000.0 && n < MAX_FRAMES)
    {
        pump();
        if (!draw_frame( number, load, &stats ) && (stats.out_of_date || stats.suboptimal > 200))
        {
            /* out of date, or suboptimal without end: a new swapchain, as a game makes one */
            create_swapchain();
        }
        t = now();
        times[n++] = ms( t - last );
        last = t;
    }
    seconds = ms( now() - start ) / 1000.0;
    if (!n) { printf( "step load %d: no frames\n", load ); return; }
    qsort( times, n, sizeof(*times), compare_floats );
    printf( "step load %d: %d frames in %.1f s (%.1f fps), frame ms median %.1f, 95%% %.1f, worst %.1f; acquire %.2f ms, present %.2f ms; "
            "gpu %.2f ms a frame, submit to done %.2f ms; suboptimal %d, out of date %d, not ready %d; frame times:",
            load, stats.frames, seconds, stats.frames / seconds, times[n / 2], times[n * 95 / 100], times[n - 1],
            stats.acquire_ms / n, stats.present_ms / n, stats.gpu_frames ? stats.gpu_ms / stats.gpu_frames : 0.0,
            stats.gpu_frames ? stats.latency_ms / stats.gpu_frames : 0.0, stats.suboptimal, stats.out_of_date, stats.not_ready );
    /* the commonest frame times, to a tenth of a ms of the nearest 120th of a second */
    for (shown = 0, i = 1; i <= 24 && shown < 6; i++)
    {
        double step = 1000.0 / 120.0 * i;
        int count = 0, k;
        for (k = 0; k < n; k++) if (times[k] > step - 4.16 && times[k] <= step + 4.16) count++;
        if (count * 50 >= n) { printf( " %.1f ms x %d", step, count ); shown++; }
    }
    printf( "\n" );
    fflush( stdout );
}

static void hold( const char *name )
{
    LONGLONG start = now();
    printf( "MARK %s\n", name );
    fflush( stdout );
    while (ms( now() - start ) < opt_hold * 1000.0) { pump(); Sleep( 50 ); }
}

int main( int argc, char **argv )
{
    HMODULE vulkan = LoadLibraryA( "vulkan-1.dll" );
    PFN_vkGetInstanceProcAddr get_proc = NULL;
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    VkInstanceCreateInfo instance_info = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    VkDeviceCreateInfo device_info = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    VkDeviceQueueCreateInfo queue_info = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    VkWin32SurfaceCreateInfoKHR surface_info = {VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
    VkCommandPoolCreateInfo pool_info = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    VkCommandBufferAllocateInfo cmd_info = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    VkSemaphoreCreateInfo semaphore_info = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkFenceCreateInfo fence_info = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    const char *instance_extensions[] = {"VK_KHR_surface", "VK_KHR_win32_surface"};
    const char *device_extensions[] = {"VK_KHR_swapchain"};
    static VkQueueFamilyProperties families[16];
    static VkSurfaceFormatKHR formats[64];
    static VkPhysicalDeviceProperties props;
    VkPhysicalDeviceMemoryProperties memory;
    VkPhysicalDevice gpus[8];
    WNDCLASSA wc = {0};
    LARGE_INTEGER freq;
    uint32_t count, i;
    VkBool32 supported = 0;
    float priority = 1.0f;
    RECT rect;
    HANDLE thread;
    DWORD style;
    int res, a, number = 0;

    for (a = 1; a < argc; a++)
    {
        const char *v = strchr( argv[a], '=' );
        if (!v++) continue;
        if (!strncmp( argv[a], "images=", 7 )) opt_images = atoi( v );
        else if (!strncmp( argv[a], "mode=", 5 )) opt_fifo = strcmp( v, "immediate" ) != 0;
        else if (!strncmp( argv[a], "show=", 5 )) opt_show = atoi( v );
        else if (!strncmp( argv[a], "secs=", 5 )) opt_secs = atoi( v );
        else if (!strncmp( argv[a], "cpu=", 4 )) opt_cpu = atoi( v );
        else if (!strncmp( argv[a], "slow=", 5 )) sscanf( v, "%d:%d", &opt_slow_frame, &opt_slow_ms );
        else if (!strncmp( argv[a], "serial=", 7 )) opt_serial = atoi( v );
        else if (!strncmp( argv[a], "recreate=", 9 )) opt_recreate = atoi( v );
        else if (!strncmp( argv[a], "frames=", 7 )) opt_frames = atoi( v );
        else if (!strncmp( argv[a], "hold=", 5 )) opt_hold = atoi( v );
        else if (!strncmp( argv[a], "drop=", 5 )) opt_drop = atoi( v );
        else if (!strncmp( argv[a], "idle=", 5 )) opt_idle = atoi( v );
        else if (!strncmp( argv[a], "size=", 5 ))
        {
            if (!strcmp( v, "screen" )) opt_screen = 1;
            else sscanf( v, "%dx%d", &opt_width, &opt_height );
        }
        else if (!strncmp( argv[a], "loads=", 6 ))
        {
            for (load_count = 0; load_count < 16 && *v; load_count++)
            {
                loads[load_count] = strtol( v, (char **)&v, 10 );
                if (*v == ',') v++;
            }
        }
    }
    QueryPerformanceFrequency( &freq );
    frequency = freq.QuadPart;

    if (!vulkan || !(get_proc = (void *)GetProcAddress( vulkan, "vkGetInstanceProcAddr" ))) fail( "loading vulkan-1.dll", GetLastError() );
    vkCreateInstance = (void *)get_proc( NULL, "vkCreateInstance" );
    app.pApplicationName = "vk_pacing_test";
    app.apiVersion = VK_API_VERSION_1_1;
    instance_info.pApplicationInfo = &app;
    instance_info.enabledExtensionCount = 2;
    instance_info.ppEnabledExtensionNames = instance_extensions;
    if ((res = vkCreateInstance( &instance_info, NULL, &instance ))) fail( "vkCreateInstance", res );
#define LOAD(f) if (!(f = (void *)get_proc( instance, #f ))) fail( #f, 0 );
    FUNCS(LOAD)

    count = 8;
    if ((res = vkEnumeratePhysicalDevices( instance, &count, gpus )) < 0 || !count) fail( "vkEnumeratePhysicalDevices", res );
    gpu = gpus[0];
    vkGetPhysicalDeviceProperties( gpu, &props );

    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleA( NULL );
    wc.lpszClassName = "vk_pacing_test";
    RegisterClassA( &wc );
    if (opt_screen)
    {
        opt_width = GetSystemMetrics( SM_CXSCREEN );
        opt_height = GetSystemMetrics( SM_CYSCREEN );
        style = WS_POPUP;
        SetRect( &rect, 0, 0, opt_width, opt_height );
    }
    else
    {
        style = WS_OVERLAPPEDWINDOW;
        SetRect( &rect, 100, 100, 100 + opt_width, 100 + opt_height );
        AdjustWindowRect( &rect, style, FALSE );
    }
    window = CreateWindowExA( 0, "vk_pacing_test", "vk pacing test", style, rect.left, rect.top, rect.right - rect.left,
                              rect.bottom - rect.top, NULL, NULL, wc.hInstance, NULL );
    if (!window) fail( "CreateWindowEx", GetLastError() );
    if (opt_show) ShowWindow( window, SW_SHOW );
    pump();

    surface_info.hinstance = wc.hInstance;
    surface_info.hwnd = window;
    if ((res = vkCreateWin32SurfaceKHR( instance, &surface_info, NULL, &surface ))) fail( "vkCreateWin32SurfaceKHR", res );
    count = 16;
    vkGetPhysicalDeviceQueueFamilyProperties( gpu, &count, families );
    for (queue_family = 0; queue_family < count; queue_family++)
    {
        vkGetPhysicalDeviceSurfaceSupportKHR( gpu, queue_family, surface, &supported );
        if (supported && (families[queue_family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) break;
    }
    if (queue_family == count) fail( "finding a queue that presents", 0 );
    queue_info.queueFamilyIndex = queue_family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &priority;
    device_info.queueCreateInfoCount = 1;
    device_info.pQueueCreateInfos = &queue_info;
    device_info.enabledExtensionCount = 1;
    device_info.ppEnabledExtensionNames = device_extensions;
    if ((res = vkCreateDevice( gpu, &device_info, NULL, &device ))) fail( "vkCreateDevice", res );
    vkGetDeviceQueue( device, queue_family, 0, &queue );

    count = 64;
    if ((res = vkGetPhysicalDeviceSurfaceFormatsKHR( gpu, surface, &count, formats )) < 0 || !count) fail( "vkGetPhysicalDeviceSurfaceFormatsKHR", res );
    swap_format = formats[0].format;
    for (i = 0; i < count; i++) if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) swap_format = formats[i].format;
    printf( "vk pacing test: \"%s\", %s, %d images asked, %s, window %dx%d %s, cpu %d ms, %d s a step\n", props.deviceName,
            opt_fifo ? "FIFO" : "IMMEDIATE", opt_images, opt_serial ? "serial" : "free", opt_width, opt_height,
            opt_show == 2 ? "minimized" : opt_show ? "shown" : "never shown", opt_cpu, opt_secs );

    /* the two big images the heavy blits go between */
    vkGetPhysicalDeviceMemoryProperties( gpu, &memory );
    for (i = 0; i < 2; i++)
    {
        VkImageCreateInfo image_info = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        VkMemoryAllocateInfo alloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        VkMemoryRequirements req;
        uint32_t type;

        image_info.imageType = VK_IMAGE_TYPE_2D;
        image_info.format = VK_FORMAT_R8G8B8A8_UNORM;
        image_info.extent.width = image_info.extent.height = BIG;
        image_info.extent.depth = 1;
        image_info.mipLevels = image_info.arrayLayers = 1;
        image_info.samples = VK_SAMPLE_COUNT_1_BIT;
        image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
        image_info.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        if ((res = vkCreateImage( device, &image_info, NULL, &big[i] ))) fail( "vkCreateImage", res );
        vkGetImageMemoryRequirements( device, big[i], &req );
        for (type = 0; type < memory.memoryTypeCount; type++)
            if ((req.memoryTypeBits & (1u << type)) && (memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) break;
        if (type == memory.memoryTypeCount) fail( "finding memory for an image", 0 );
        alloc.allocationSize = req.size;
        alloc.memoryTypeIndex = type;
        if ((res = vkAllocateMemory( device, &alloc, NULL, &big_memory[i] ))) fail( "vkAllocateMemory", res );
        if ((res = vkBindImageMemory( device, big[i], big_memory[i], 0 ))) fail( "vkBindImageMemory", res );
    }

    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = queue_family;
    if ((res = vkCreateCommandPool( device, &pool_info, NULL, &pool ))) fail( "vkCreateCommandPool", res );
    cmd_info.commandPool = pool;
    cmd_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cmd_info.commandBufferCount = 1;
    fence_info.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    for (i = 0; i < RING; i++)
    {
        if ((res = vkAllocateCommandBuffers( device, &cmd_info, &slots[i].cmd ))) fail( "vkAllocateCommandBuffers", res );
        vkCreateSemaphore( device, &semaphore_info, NULL, &slots[i].acquired );
        vkCreateSemaphore( device, &semaphore_info, NULL, &slots[i].drawn );
        vkCreateFence( device, &fence_info, NULL, &slots[i].fence );
    }
    {
        /* both big images to the layout the blits use, once */
        VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
        VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        VkClearColorValue grey = {{0.5f, 0.5f, 0.5f, 1.0f}};
        VkCommandBuffer cmd = slots[0].cmd;

        vkBeginCommandBuffer( cmd, &begin );
        for (i = 0; i < 2; i++)
        {
            barrier( cmd, big[i], VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL );
            vkCmdClearColorImage( cmd, big[i], VK_IMAGE_LAYOUT_GENERAL, &grey, 1, &range );
        }
        vkEndCommandBuffer( cmd );
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        vkQueueSubmit( queue, 1, &submit, VK_NULL_HANDLE );
        vkDeviceWaitIdle( device );
    }

    create_swapchain();
    printf( "swapchain: %u images of %ux%u, format %d\n", swap_count, extent.width, extent.height, swap_format );
    fflush( stdout );
    if (opt_show == 2)
    {
        ShowWindow( window, SW_MINIMIZE );
        pump();
    }

    waiter_wake = CreateEventA( NULL, FALSE, FALSE, NULL );
    thread = CreateThread( NULL, 0, waiter, NULL, 0, NULL );

    if (!load_count && !opt_recreate) loads[load_count++] = 0;
    for (a = 0; a < load_count; a++) run_step( loads[a], &number );

    if (opt_recreate)
    {
        struct stats stats = {0};
        VkSemaphore dropped = VK_NULL_HANDLE;
        int r, f, acquired = 0;

        hold( "before" );
        for (r = 0; r < opt_recreate; r++)
        {
            create_swapchain();
            if (dropped) vkDestroySemaphore( device, dropped, NULL );
            dropped = VK_NULL_HANDLE;
            if (opt_drop)
            {
                uint32_t index;

                pump();
                vkCreateSemaphore( device, &semaphore_info, NULL, &dropped );
                res = vkAcquireNextImageKHR( device, swapchain, 2000000000ull, dropped, VK_NULL_HANDLE, &index );
                if (res == VK_SUCCESS || res == VK_SUBOPTIMAL_KHR) acquired++;
                else stats.not_ready++;
                continue;
            }
            for (f = 0; f < opt_frames; f++)
            {
                pump();
                draw_frame( &number, 0, &stats );
            }
        }
        if (opt_drop) printf( "recreate: %d images acquired and never presented\n", acquired );
        for (f = 0; f < RING; f++) while (slots[f].pending) Sleep( 1 );
        vkDeviceWaitIdle( device );
        printf( "recreate: %d swapchains made, %d frames; suboptimal %d, out of date %d, not ready %d\n", opt_recreate, stats.frames,
                stats.suboptimal, stats.out_of_date, stats.not_ready );
        hold( "after" );
    }

    for (i = 0; i < RING; i++) while (slots[i].pending) Sleep( 1 );
    InterlockedExchange( &waiter_stop, 1 );
    SetEvent( waiter_wake );
    WaitForSingleObject( thread, 2000 );
    vkDeviceWaitIdle( device );
    vkDestroySwapchainKHR( device, swapchain, NULL );
    if (opt_recreate && opt_hold) hold( "destroyed" );
    for (i = 0; i < RING; i++)
    {
        vkDestroySemaphore( device, slots[i].acquired, NULL );
        vkDestroySemaphore( device, slots[i].drawn, NULL );
        vkDestroyFence( device, slots[i].fence, NULL );
    }
    vkDestroyCommandPool( device, pool, NULL );
    for (i = 0; i < 2; i++)
    {
        vkDestroyImage( device, big[i], NULL );
        vkFreeMemory( device, big_memory[i], NULL );
    }
    vkDestroyDevice( device, NULL );
    vkDestroySurfaceKHR( instance, surface, NULL );
    vkDestroyInstance( instance, NULL );
    DestroyWindow( window );
    printf( "vk pacing test: done\n" );
    return 0;
}
