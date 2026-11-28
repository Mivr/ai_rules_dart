// Spike T17a (S9): the start of an app that is nothing but the pods of the fourteen-plugin closure
// (apple_model_m14.json: Firestore's C++, Stripe), for the second job of the macOS workflow. This
// workspace has no Flutter app of that closure, so the app proves that all 55 pods link into one
// binary and that it starts: it prints which plugin classes the binary holds. Not generated.
#import <UIKit/UIKit.h>

@interface RDFDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation RDFDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  // The classes the generated registrant of the fourteen-plugin app registers.
  NSArray<NSString *> *plugins = @[
    @"FLTFirebaseFirestorePlugin",
    @"FLTFirebaseAuthPlugin",
    @"FLTFirebaseCorePlugin",
    @"FLTFirebaseMessagingPlugin",
    @"InAppWebViewFlutterPlugin",
    @"FGMGoogleMapsPlugin",
    @"GoogleMlKitCommonsPlugin",
    @"GoogleSignInPlugin",
    @"ImagePickerPlugin",
    @"FPPPackageInfoPlusPlugin",
    @"PermissionHandlerPlugin",
    @"SentryFlutterPlugin",
    @"StripeIosPlugin",
    @"URLLauncherPlugin",
    @"WebViewFlutterPlugin",
  ];
  NSUInteger present = 0;
  for (NSString *name in plugins) {
    BOOL found = NSClassFromString(name) != nil;
    present += found ? 1 : 0;
    NSLog(@"rdf-s9 class %@ %@", name, found ? @"present" : @"MISSING");
  }
  NSLog(@"rdf-s9 classes %lu of %lu", (unsigned long)present, (unsigned long)plugins.count);
  NSLog(@"rdf-s9 done");
  return YES;
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([RDFDelegate class]));
  }
}
