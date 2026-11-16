#import "PrismVirtualDisplay.h"
#import "CGVirtualDisplayPrivate.h"

@implementation PrismVirtualDisplay {
    CGVirtualDisplay *_display;
}

- (nullable instancetype)initWithWidth:(NSUInteger)width
                               height:(NSUInteger)height
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                               number:(uint32_t)number
                                 name:(NSString *)name {
    self = [super init];
    if (!self) return nil;
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!descriptorClass || !displayClass || !modeClass || !settingsClass) return nil;
    NSUInteger scale = hiDPI ? 2 : 1;
    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    [descriptor setDispatchQueue:dispatch_get_main_queue()];
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)(width * scale);
    descriptor.maxPixelsHigh = (unsigned int)(height * scale);
    descriptor.sizeInMillimeters = CGSizeMake(width * 0.2646, height * 0.2646);
    descriptor.vendorID = 0x5052;
    descriptor.productID = 0x5852;
    descriptor.serialNum = number;
    _display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!_display) return nil;
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width * scale
                                                       height:height * scale
                                                  refreshRate:refreshRate];
    if (hiDPI) {
        CGVirtualDisplayMode *logicalMode = [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
        settings.modes = @[logicalMode, mode];
    } else {
        settings.modes = @[mode];
    }
    if (![_display applySettings:settings] || _display.displayID == 0) return nil;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}
@end
