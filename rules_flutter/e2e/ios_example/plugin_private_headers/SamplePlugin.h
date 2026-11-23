#import <Foundation/Foundation.h>

@import Flutter;

#import "SampleManager.h"

@interface SamplePlugin : NSObject <FlutterPlugin>
@property(nonatomic, strong) SampleManager *manager;
@end
