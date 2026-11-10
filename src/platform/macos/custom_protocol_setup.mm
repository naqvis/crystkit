// CrystKit custom URL scheme handler setup for macOS.
//
// Registers a WKURLSchemeHandler on the WKWebViewConfiguration BEFORE the
// WKWebView is created by swizzling initWithFrame:configuration:. Without
// this, setURLSchemeHandler:forURLScheme: on a post-creation configuration
// has no effect (the configuration is copied at init time).
//
// This file is compiled separately and linked into the final binary.
// No modification to upstream webview.h is required.

#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// --- Resolver callback -----------------------------------------------------
// Crystal sets this via crystkit_set_url_resolver(). The handler calls it
// when WKWebView requests a custom scheme URL.

static void (*s_resolver)(const char *url, const char **out_body, int *out_len, const char **out_mime) = NULL;

extern "C" void crystkit_set_url_resolver(void (*resolver)(const char *, const char **, int *, const char **)) {
    s_resolver = resolver;
}

// --- Scheme name -----------------------------------------------------------

static const char *s_scheme = NULL;

extern "C" void crystkit_set_scheme(const char *scheme) {
    s_scheme = scheme;
}

// --- ObjC class ------------------------------------------------------------
// Implements WKURLSchemeHandler protocol at runtime.

@interface CrystKitSchemeHandler : NSObject <WKURLSchemeHandler>
@end

@implementation CrystKitSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    if (!s_resolver) {
        NSError *err = [NSError errorWithDomain:@"CrystKit" code:500
            userInfo:@{NSLocalizedDescriptionKey: @"No resolver registered"}];
        [task didFailWithError:err];
        return;
    }

    NSURLRequest *req = [task request];
    NSString *urlStr = [[req URL] absoluteString];

    const char *body = NULL;
    int bodyLen = 0;
    const char *mime = NULL;

    s_resolver([urlStr UTF8String], &body, &bodyLen, &mime);

    if (body && bodyLen > 0) {
        NSString *mimeType = mime ? [NSString stringWithUTF8String:mime] : @"application/octet-stream";
        NSData *data = [NSData dataWithBytes:body length:bodyLen];
        NSString *contentLength = [NSString stringWithFormat:@"%d", bodyLen];
        NSDictionary *headers = @{@"Content-Type": mimeType, @"Content-Length": contentLength};

        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
            initWithURL:[req URL]
            statusCode:200
            HTTPVersion:nil
            headerFields:headers];

        [task didReceiveResponse:response];
        [task didReceiveData:data];
        [task didFinish];
    } else {
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
            initWithURL:[req URL]
            statusCode:404
            HTTPVersion:nil
            headerFields:nil];

        [task didReceiveResponse:response];
        [task didFinish];
    }
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    // No-op: CrystKit doesn't support cancellation
}

@end

// --- Method Swizzling -------------------------------------------------------
// Swizzles WKWebView's initWithFrame:configuration: so we can inject the
// URL scheme handler before the configuration is copied internally.

static IMP s_original_init = NULL;
static bool s_installed = false;

static id swizzled_initWithFrame(id self, SEL _cmd, CGRect frame, WKWebViewConfiguration *config) {
    if (s_scheme && s_resolver && !s_installed) {
        CrystKitSchemeHandler *handler = [[CrystKitSchemeHandler alloc] init];
        [config setURLSchemeHandler:handler forURLScheme:[NSString stringWithUTF8String:s_scheme]];
        s_installed = true;
    }

    if (s_original_init) {
        return ((id (*)(id, SEL, CGRect, WKWebViewConfiguration *))s_original_init)(self, _cmd, frame, config);
    }
    return nil;
}

// --- Public C API ----------------------------------------------------------

extern "C" void crystkit_install_scheme_handler(const char *scheme) {
    s_scheme = scheme;
    s_installed = false;

    if (!s_original_init) {
        Method m = class_getInstanceMethod([WKWebView class], @selector(initWithFrame:configuration:));
        if (m) {
            s_original_init = method_getImplementation(m);
            method_setImplementation(m, (IMP)swizzled_initWithFrame);
        }
    }
}
