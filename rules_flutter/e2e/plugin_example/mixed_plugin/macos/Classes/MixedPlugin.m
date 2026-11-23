#import "MixedPlugin.h"

// The Swift half's generated interface: the ObjC half compiles after it.
#import "mixed_plugin-Swift.h"

NSString *MixedPluginGreeting(void) {
  MixedPlugin *plugin = [[MixedPlugin alloc] init];
  return [plugin greeting];
}
