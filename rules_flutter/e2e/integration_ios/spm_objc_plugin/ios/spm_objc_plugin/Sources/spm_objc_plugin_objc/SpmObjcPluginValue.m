#import "include/SpmObjcPluginValue.h"

#if !defined(SPM_LOCAL_C_DEFINE) || !defined(SPM_PLUGIN_DEFINE)
#error "spm_objc_plugin_objc needs both SPM_LOCAL_C_DEFINE and SPM_PLUGIN_DEFINE"
#endif

@implementation SpmObjcPluginValue

+ (NSInteger)answer {
  return 42 + SPM_LOCAL_C_DEFINE + SPM_PLUGIN_DEFINE;
}

@end
