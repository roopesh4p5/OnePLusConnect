#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "CGVirtualDisplayShim.h"

// Private CoreGraphics interfaces (as documented by open-source virtual display projects).
// They are never referenced as class symbols; instances are obtained via NSClassFromString.
@class CGVirtualDisplay;

@interface CGVirtualDisplayMode : NSObject
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) BOOL hiDPI;
@property (nonatomic, strong) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic, copy) void (^terminationHandler)(id sender, CGVirtualDisplay *display);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) uint32_t vendorID;
@property (nonatomic, readonly) uint32_t productID;
@property (nonatomic, readonly) uint32_t serialNum;
@property (nonatomic, readonly) NSString *name;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static Class OPCClass(const char *name) {
    return NSClassFromString([NSString stringWithUTF8String:name]);
}

bool OPCVirtualDisplayIsAvailable(void) {
    return OPCClass("CGVirtualDisplay") != nil
        && OPCClass("CGVirtualDisplayDescriptor") != nil
        && OPCClass("CGVirtualDisplaySettings") != nil
        && OPCClass("CGVirtualDisplayMode") != nil;
}

static CGVirtualDisplaySettings *OPCMakeSettings(const uint32_t *ws, const uint32_t *hs, const double *rates, int count, bool hiDPI) {
    Class settingsClass = OPCClass("CGVirtualDisplaySettings");
    Class modeClass = OPCClass("CGVirtualDisplayMode");
    if (!settingsClass || !modeClass) return nil;

    NSMutableArray *modes = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; i++) {
        CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:ws[i] height:hs[i] refreshRate:rates[i]];
        if (mode) [modes addObject:mode];
    }
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    if ([settings respondsToSelector:@selector(setHiDPI:)]) settings.hiDPI = hiDPI ? YES : NO;
    if ([settings respondsToSelector:@selector(setModes:)]) settings.modes = modes;
    return settings;
}

OPCVirtualDisplayHandle OPCVirtualDisplayCreate(const char *name,
                                                uint32_t maxWidth,
                                                uint32_t maxHeight,
                                                double widthMillimeters,
                                                double heightMillimeters,
                                                uint32_t serialNumber,
                                                const uint32_t *modeWidths,
                                                const uint32_t *modeHeights,
                                                const double *modeRefreshRates,
                                                int modeCount,
                                                bool hiDPI,
                                                const char **errorOut) {
    @autoreleasepool {
        if (!OPCVirtualDisplayIsAvailable()) {
            if (errorOut) *errorOut = "CGVirtualDisplay private API is not available on this macOS build";
            return NULL;
        }
        Class descriptorClass = OPCClass("CGVirtualDisplayDescriptor");
        Class displayClass = OPCClass("CGVirtualDisplay");

        CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
        if (!descriptor) {
            if (errorOut) *errorOut = "Could not allocate CGVirtualDisplayDescriptor";
            return NULL;
        }
        if ([descriptor respondsToSelector:@selector(setName:)]) descriptor.name = [NSString stringWithUTF8String:name ?: "One+Connect"];
        if ([descriptor respondsToSelector:@selector(setMaxPixelsWide:)]) descriptor.maxPixelsWide = maxWidth;
        if ([descriptor respondsToSelector:@selector(setMaxPixelsHigh:)]) descriptor.maxPixelsHigh = maxHeight;
        if ([descriptor respondsToSelector:@selector(setSizeInMillimeters:)]) descriptor.sizeInMillimeters = CGSizeMake(widthMillimeters, heightMillimeters);
        if ([descriptor respondsToSelector:@selector(setProductID:)]) descriptor.productID = 0x1A2B;
        if ([descriptor respondsToSelector:@selector(setVendorID:)]) descriptor.vendorID = 0x3D4E;
        if ([descriptor respondsToSelector:@selector(setSerialNum:)]) descriptor.serialNum = serialNumber;
        if ([descriptor respondsToSelector:@selector(setRedPrimary:)]) descriptor.redPrimary = CGPointMake(0.680, 0.320);
        if ([descriptor respondsToSelector:@selector(setGreenPrimary:)]) descriptor.greenPrimary = CGPointMake(0.265, 0.690);
        if ([descriptor respondsToSelector:@selector(setBluePrimary:)]) descriptor.bluePrimary = CGPointMake(0.150, 0.060);
        if ([descriptor respondsToSelector:@selector(setWhitePoint:)]) descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        if ([descriptor respondsToSelector:@selector(setDispatchQueue:)]) [descriptor setDispatchQueue:dispatch_get_main_queue()];
        if ([descriptor respondsToSelector:@selector(setTerminationHandler:)]) {
            descriptor.terminationHandler = ^(id sender, CGVirtualDisplay *display) {
                NSLog(@"[CGVirtualDisplayShim] virtual display terminated by the system");
            };
        }

        CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
        if (!display) {
            if (errorOut) *errorOut = "CGVirtualDisplay initWithDescriptor: returned nil";
            return NULL;
        }

        CGVirtualDisplaySettings *settings = OPCMakeSettings(modeWidths, modeHeights, modeRefreshRates, modeCount, hiDPI);
        if (!settings || ![display applySettings:settings]) {
            if (errorOut) *errorOut = "CGVirtualDisplay applySettings: failed";
            return NULL;
        }
        return (__bridge_retained void *)display;
    }
}

uint32_t OPCVirtualDisplayGetID(OPCVirtualDisplayHandle handle) {
    if (!handle) return 0;
    CGVirtualDisplay *display = (__bridge CGVirtualDisplay *)handle;
    if ([display respondsToSelector:@selector(displayID)]) return display.displayID;
    return 0;
}

bool OPCVirtualDisplayApplyModes(OPCVirtualDisplayHandle handle,
                                 const uint32_t *modeWidths,
                                 const uint32_t *modeHeights,
                                 const double *modeRefreshRates,
                                 int modeCount,
                                 bool hiDPI) {
    if (!handle) return false;
    @autoreleasepool {
        CGVirtualDisplay *display = (__bridge CGVirtualDisplay *)handle;
        CGVirtualDisplaySettings *settings = OPCMakeSettings(modeWidths, modeHeights, modeRefreshRates, modeCount, hiDPI);
        return settings && [display applySettings:settings];
    }
}

void OPCVirtualDisplayDestroy(OPCVirtualDisplayHandle handle) {
    if (!handle) return;
    CGVirtualDisplay *display = (__bridge_transfer CGVirtualDisplay *)handle;
    display = nil; // releasing the object tears the display down
}
