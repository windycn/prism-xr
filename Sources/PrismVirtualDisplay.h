#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface PrismVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithWidth:(NSUInteger)width
                               height:(NSUInteger)height
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                               number:(uint32_t)number
                                 name:(NSString *)name;
@end

NS_ASSUME_NONNULL_END
