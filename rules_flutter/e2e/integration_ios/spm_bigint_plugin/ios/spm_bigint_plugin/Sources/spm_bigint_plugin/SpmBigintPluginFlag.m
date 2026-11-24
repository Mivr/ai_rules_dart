#import "SpmBigintPluginFlag.h"

#if !PLUGIN_FLAG
#error "PLUGIN_FLAG did not reach the plugin's Objective-C compile"
#endif

NSString *SpmBigintPluginFlag(void) {
  return @"PLUGIN_FLAG";
}
