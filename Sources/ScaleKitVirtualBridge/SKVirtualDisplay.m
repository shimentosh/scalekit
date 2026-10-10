#import "SKVirtualDisplay.h"

// Private interfaces, matching the selectors CoreGraphics exposes at run time
// (verified on macOS 27.0 with the Objective-C runtime). They are only used
// on instances created through NSClassFromString, never by class symbol, so
// nothing links against a private symbol.

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

const uint32_t SKVirtualDisplayVendorID = 0x534B;

@implementation SKVirtualDisplay {
    id _display;
}

+ (BOOL)isSupported {
    Class display = NSClassFromString(@"CGVirtualDisplay");
    Class descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settings = NSClassFromString(@"CGVirtualDisplaySettings");
    Class mode = NSClassFromString(@"CGVirtualDisplayMode");
    return display && descriptor && settings && mode
        && [display instancesRespondToSelector:@selector(initWithDescriptor:)]
        && [display instancesRespondToSelector:@selector(applySettings:)]
        && [display instancesRespondToSelector:@selector(displayID)]
        && [descriptor instancesRespondToSelector:@selector(setTerminationHandler:)]
        && [descriptor instancesRespondToSelector:@selector(setMaxPixelsWide:)]
        && [settings instancesRespondToSelector:@selector(setHiDPI:)]
        && [settings instancesRespondToSelector:@selector(setModes:)]
        && [mode instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)];
}

- (nullable instancetype)initWithName:(NSString *)name
                           pointWidth:(uint32_t)pointWidth
                          pointHeight:(uint32_t)pointHeight
                          refreshRate:(double)refreshRate
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                         serialNumber:(uint32_t)serialNumber {
    if (!SKVirtualDisplay.isSupported || pointWidth == 0 || pointHeight == 0) return nil;
    self = [super init];
    if (!self) return nil;

    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    descriptor.maxPixelsWide = pointWidth * 2;
    descriptor.maxPixelsHigh = pointHeight * 2;
    descriptor.sizeInMillimeters = sizeInMillimeters;
    descriptor.vendorID = SKVirtualDisplayVendorID;
    descriptor.productID = 0x0002;
    descriptor.serialNum = serialNumber;
    __weak SKVirtualDisplay *weakSelf = self;
    descriptor.terminationHandler = ^(id unused1, id unused2) {
        SKVirtualDisplay *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_display = nil;
        if (strongSelf.terminationHandler) strongSelf.terminationHandler();
    };

    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == kCGNullDirectDisplay) return nil;

    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = 1;
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:pointWidth height:pointHeight refreshRate:refreshRate]];
    if (![display applySettings:settings]) return nil;

    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    CGVirtualDisplay *display = _display;
    return display ? display.displayID : kCGNullDirectDisplay;
}

- (void)invalidate {
    _display = nil;
}

- (void)dealloc {
    _display = nil;
}

@end
