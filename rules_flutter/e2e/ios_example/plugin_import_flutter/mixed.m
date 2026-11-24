#import "mixed.h"

@import Flutter;

#import "plugin_import_mixed-Swift.h"

@implementation MixedImportPlugin
+ (NSString *)greeting {
  return [MixedImportSwift greeting];
}
@end
