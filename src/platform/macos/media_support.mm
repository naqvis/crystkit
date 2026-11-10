// CrystKit media device support for macOS.
//
// The webview C library does not enable navigator.mediaDevices — its
// pre-compiled webview.o was built without any media support. This
// extension swizzles WKWebView initWithFrame:configuration: at runtime
// to enable media devices BEFORE the configuration is copied internally.
//
// No modification to upstream webview.h is required.

#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Global permission callback — set by Crystal via crystkit_set_media_handler
static int (*s_media_handler)(const char *origin, const char *type) = NULL;

extern "C" void crystkit_set_media_handler(int (*handler)(const char *, const char *)) {
    s_media_handler = handler;
}

// --- Private API helpers (avoid compiler warnings for underscored selectors) -

static void prefs_set_media_devices_enabled(id prefs) {
    SEL sel = sel_registerName("_setMediaDevicesEnabled:");
    if ([prefs respondsToSelector:sel]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(prefs, sel, YES);
    }
}

static void prefs_set_media_capture_enabled(id prefs) {
    SEL sel = sel_registerName("_setMediaCaptureEnabled:");
    if ([prefs respondsToSelector:sel]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(prefs, sel, YES);
    }
}

// --- Swizzled initWithFrame:configuration: -----------------------------------
// Intercepts WKWebView creation to enable media devices BEFORE the config is
// copied during initWithFrame:configuration:.

static IMP s_original_init = NULL;

static void enable_media_prefs(WKWebViewConfiguration *config) {
    WKPreferences *prefs = [config preferences];
    prefs_set_media_devices_enabled(prefs);
    prefs_set_media_capture_enabled(prefs);
}

static id swizzled_initWithFrame(id self, SEL _cmd, CGRect frame, WKWebViewConfiguration *config) {
    enable_media_prefs(config);
    if (s_original_init) {
        return ((id (*)(id, SEL, CGRect, WKWebViewConfiguration *))s_original_init)(self, _cmd, frame, config);
    }
    return nil;
}

// --- CrystKitMediaDelegate --------------------------------------------------
// Custom WKUIDelegate that handles media/geo permission requests and forwards
// all other WKUIDelegate methods to the original delegate (set by webview.o).

@interface CrystKitMediaDelegate : NSObject <WKUIDelegate>
@property (nonatomic, assign) id<WKUIDelegate> originalDelegate;
@end

@implementation CrystKitMediaDelegate

- (void)webView:(WKWebView *)webView
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
    initiatedByFrame:(WKFrameInfo *)frame
    type:(WKMediaCaptureType)type
    decisionHandler:(void (^)(WKPermissionDecision))decisionHandler {

    NSString *originStr = [NSString stringWithFormat:@"%@://%@%@",
        [origin protocol], [origin host],
        [origin port] > 0 ? [NSString stringWithFormat:@":%ld", (long)[origin port]] : @""];

    NSString *permType = @"unknown";
    switch (type) {
        case WKMediaCaptureTypeCamera:      permType = @"camera"; break;
        case WKMediaCaptureTypeMicrophone:   permType = @"microphone"; break;
        default:
            if (type == 2) permType = @"screen_capture";
            break;
    }

    int decision = 1; // WKPermissionDecisionGrant
    if (s_media_handler) {
        decision = s_media_handler([originStr UTF8String], [permType UTF8String]);
    }
    decisionHandler((WKPermissionDecision)decision);
}

- (void)webView:(WKWebView *)webView
    requestGeolocationPermissionForOrigin:(WKSecurityOrigin *)origin
    initiatedByFrame:(WKFrameInfo *)frame
    decisionHandler:(void (^)(WKPermissionDecision))decisionHandler {

    NSString *originStr = [NSString stringWithFormat:@"%@://%@%@",
        [origin protocol], [origin host],
        [origin port] > 0 ? [NSString stringWithFormat:@":%ld", (long)[origin port]] : @""];

    int decision = 1; // WKPermissionDecisionGrant
    if (s_media_handler) {
        decision = s_media_handler([originStr UTF8String], "geolocation");
    }
    decisionHandler((WKPermissionDecision)decision);
}

// Forward all other WKUIDelegate methods to the original delegate
- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.originalDelegate respondsToSelector:aSelector]) {
        return self.originalDelegate;
    }
    return nil;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) {
        return YES;
    }
    return [self.originalDelegate respondsToSelector:aSelector];
}

@end

// --- Install the WKUIDelegate on an existing webview ------------------------

extern "C" void crystkit_install_media_delegate(void *wkWebView) {
    WKWebView *wv = (__bridge WKWebView *)wkWebView;

    CrystKitMediaDelegate *del = [[CrystKitMediaDelegate alloc] init];
    del.originalDelegate = [wv UIDelegate];
    [wv setUIDelegate:del];
}

// --- Public C API -----------------------------------------------------------

extern "C" void crystkit_enable_media_devices(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Swizzle initWithFrame:configuration: to enable media prefs BEFORE
        // the config is copied during WKWebView initialization.
        Method m = class_getInstanceMethod([WKWebView class], @selector(initWithFrame:configuration:));
        if (m) {
            s_original_init = method_getImplementation(m);
            method_setImplementation(m, (IMP)swizzled_initWithFrame);
        }
    });
}
