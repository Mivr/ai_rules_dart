#import <Foundation/Foundation.h>

#import "SampleCodec.h"
#import "SampleStrategy.h"

@interface SampleManager : NSObject
@property(nonatomic, strong) SampleStrategy *strategy;
@end
