#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A value the Swift target can only reach through the ObjC target's module.
@interface SpmObjcPluginValue : NSObject

/// The answer computed by the ObjC target.
+ (NSInteger)answer;

@end

NS_ASSUME_NONNULL_END
