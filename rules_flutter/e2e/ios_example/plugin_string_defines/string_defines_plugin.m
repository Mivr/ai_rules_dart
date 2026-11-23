#import <Foundation/Foundation.h>

// Each macro arrives as a C string literal through `plugin_defines`; a
// dropped quote or a leaked backslash fails this file under Clang.
NSString *plugin_string_defines_library_name(void) {
    NSString *a = @LIBRARY_NAME;
    return a;
}

NSString *plugin_string_defines_escaped_name(void) {
    NSString *b = @ESCAPED_NAME;
    return b;
}

NSString *plugin_string_defines_greeting(void) {
    NSString *c = @GREETING;
    return c;
}
