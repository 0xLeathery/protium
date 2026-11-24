/*
 * Makes a HiDPI display that exists only in software, for trying what Protium does on a Retina
 * screen on a Mac that has none:
 *
 *   virtual_display [--pixels WxH] [--main] [--seconds N]
 *
 * The display has WxH pixels (default 3840x2160) and, being HiDPI, half as many points each way,
 * as a 4K monitor has at macOS's default setting. It prints
 *   display <id> <W>x<H> pixels <w>x<h> points
 * and stays until it gets a line on standard input, SIGTERM, or N seconds have passed; the
 * display goes with the process. --main makes it the main display for that time (the menu bar
 * moves to it) and puts the arrangement back afterwards: Wine's Mac driver decides by the main
 * display. Windows put on it are seen with screencapture -D or CGDisplayCreateImage.
 *
 * CGVirtualDisplay is in CoreGraphics without a public header; the declarations below are what
 * this tool uses of it. It changes the arrangement of screens, so run it only while nobody is
 * using the Mac.
 *
 * clang -fobjc-arc -framework Foundation -framework CoreGraphics -o virtual_display virtual_display.m
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)rate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID, productID, serialNum;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static int make_main(CGDirectDisplayID display, CGDirectDisplayID *was_main)
{
    CGDisplayConfigRef config;
    CGDirectDisplayID main_id = CGMainDisplayID();
    CGRect bounds = CGDisplayBounds(display);

    *was_main = main_id;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return 0;
    /* the main display is the one at the origin; the old one goes to its right */
    CGConfigureDisplayOrigin(config, display, 0, 0);
    CGConfigureDisplayOrigin(config, main_id, (int32_t)bounds.size.width, 0);
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
}

static void restore_main(CGDirectDisplayID was_main)
{
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return;
    CGConfigureDisplayOrigin(config, was_main, 0, 0);
    CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
}

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        unsigned int width = 3840, height = 2160, seconds = 0;
        BOOL want_main = NO;
        CGDirectDisplayID was_main = 0;
        int i;

        for (i = 1; i < argc; i++)
        {
            if (!strcmp(argv[i], "--main")) want_main = YES;
            else if (!strcmp(argv[i], "--pixels") && i + 1 < argc && sscanf(argv[i + 1], "%ux%u", &width, &height) == 2) i++;
            else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = (unsigned int)atoi(argv[++i]);
            else
            {
                fprintf(stderr, "usage: virtual_display [--pixels WxH] [--main] [--seconds N]\n");
                return 2;
            }
        }
        if (!NSClassFromString(@"CGVirtualDisplay"))
        {
            fprintf(stderr, "virtual_display: this macOS has no CGVirtualDisplay\n");
            return 1;
        }

        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.name = @"Protium test display";
        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        /* a size that gives about 163 pixels an inch, as a 27-inch 4K monitor has */
        descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 163.0, height * 25.4 / 163.0);
        descriptor.vendorID = 0x5052;
        descriptor.productID = 0x0001;
        descriptor.serialNum = 1;
        descriptor.queue = dispatch_get_main_queue();

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = 1;
        settings.modes = @[ [[CGVirtualDisplayMode alloc] initWithWidth:width / 2 height:height / 2 refreshRate:60] ];
        if (!display || ![display applySettings:settings])
        {
            fprintf(stderr, "virtual_display: macOS did not make the display\n");
            return 1;
        }
        [NSThread sleepForTimeInterval:1.0];     /* the display takes a moment to join the others */

        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display.displayID);
        if (want_main && !make_main(display.displayID, &was_main))
            fprintf(stderr, "virtual_display: could not make it the main display\n");
        printf("display %u %zux%zu pixels %zux%zu points\n", display.displayID,
               mode ? CGDisplayModeGetPixelWidth(mode) : 0, mode ? CGDisplayModeGetPixelHeight(mode) : 0,
               mode ? CGDisplayModeGetWidth(mode) : 0, mode ? CGDisplayModeGetHeight(mode) : 0);
        fflush(stdout);
        if (mode) CGDisplayModeRelease(mode);

        dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        signal(SIGTERM, SIG_IGN);
        dispatch_source_set_event_handler(term, ^{ CFRunLoopStop(CFRunLoopGetMain()); });
        dispatch_resume(term);
        dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(input, ^{ CFRunLoopStop(CFRunLoopGetMain()); });
        dispatch_resume(input);
        if (seconds)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC), dispatch_get_main_queue(),
                           ^{ CFRunLoopStop(CFRunLoopGetMain()); });
        CFRunLoopRun();

        if (was_main) restore_main(was_main);
        display = nil;
    }
    return 0;
}
