// A thin, Objective-C wrapper around CoreGraphics' private CGVirtualDisplay
// classes. This file and SKVirtualDisplay.m are the only places in ScaleKit
// that touch a private API. The classes are looked up at run time, so a macOS
// release that removes them makes `isSupported` return NO instead of crashing.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SKVirtualDisplay : NSObject

/// YES when every private class and selector ScaleKit needs is present.
@property(class, readonly) BOOL isSupported;

/// Creates a virtual display that offers one HiDPI mode of `pointWidth` ×
/// `pointHeight` points (backed by twice as many pixels) at `refreshRate` Hz.
/// The display exists until `invalidate` is called or this object is released;
/// macOS also removes it when the owning process exits for any reason.
- (nullable instancetype)initWithName:(NSString *)name
                           pointWidth:(uint32_t)pointWidth
                          pointHeight:(uint32_t)pointHeight
                          refreshRate:(double)refreshRate
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                         serialNumber:(uint32_t)serialNumber NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// The CoreGraphics display ID, or kCGNullDirectDisplay after `invalidate`.
@property(readonly) CGDirectDisplayID displayID;

/// Called on the main queue if macOS terminates the virtual display.
@property(nonatomic, copy, nullable) void (^terminationHandler)(void);

/// Removes the virtual display from the system.
- (void)invalidate;

@end

/// Vendor ID used for ScaleKit's virtual displays ("SK"), so they can be told apart from real monitors.
extern const uint32_t SKVirtualDisplayVendorID;

NS_ASSUME_NONNULL_END
