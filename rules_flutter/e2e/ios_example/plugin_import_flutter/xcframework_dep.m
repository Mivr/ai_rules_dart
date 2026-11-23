#import "xcframework_dep.h"

@import TinyPluginKit;

@implementation XcframeworkImportPlugin
+ (int)answer {
  return tinykit_answer();
}
@end
