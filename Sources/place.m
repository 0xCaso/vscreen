// libvscreen_place.dylib: injected by `vscreen launch` (DYLD_INSERT_LIBRARIES).
// Inside the app it (1) puts every window on the display VSCREEN_DISPLAY before it is
// ordered on screen, and (2) turns app activation into a no-op, so the app never comes
// to the front on the user's screens. Needs no Accessibility permission.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static CGDirectDisplayID gTarget = 0;

static NSScreen *targetScreen(void) {
    for (NSScreen *s in NSScreen.screens) {
        if ([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == gTarget) return s;
    }
    return nil;
}

static void place(NSWindow *w) {
    NSScreen *s = targetScreen();
    if (!s || w.screen == s) return;
    NSRect sf = s.frame, f = w.frame;
    f.size.width = MIN(f.size.width, sf.size.width);
    f.size.height = MIN(f.size.height, sf.size.height);
    f.origin.x = sf.origin.x + 40;
    f.origin.y = NSMaxY(sf) - 40 - f.size.height;
    [w setFrame:f display:NO];
}

static void swizzle(Class c, SEL sel, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (m) *orig = method_setImplementation(m, repl);
}

static IMP oOrderWindow, oOrderFrontRegardless, oMakeKeyAndOrderFront, oActivateIgnoring, oActivate;

static void hOrderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode mode, NSInteger rel) {
    if (mode != NSWindowOut) place(self);
    ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))oOrderWindow)(self, _cmd, mode, rel);
}
static void hOrderFrontRegardless(NSWindow *self, SEL _cmd) {
    place(self);
    ((void (*)(id, SEL))oOrderFrontRegardless)(self, _cmd);
}
static void hMakeKeyAndOrderFront(NSWindow *self, SEL _cmd, id sender) {
    place(self);
    ((void (*)(id, SEL, id))oMakeKeyAndOrderFront)(self, _cmd, sender);
}
static void hActivateIgnoring(NSApplication *self, SEL _cmd, BOOL flag) {}
static void hActivate(NSApplication *self, SEL _cmd) {}
static IMP oRunningActivate;
static BOOL hRunningActivate(NSRunningApplication *self, SEL _cmd, NSApplicationActivationOptions o) {
    if (self.processIdentifier == getpid()) return NO;
    return ((BOOL (*)(id, SEL, NSApplicationActivationOptions))oRunningActivate)(self, _cmd, o);
}

__attribute__((constructor)) static void vscreenPlaceInit(void) {
    const char *d = getenv("VSCREEN_DISPLAY");
    if (!d) return;
    gTarget = (CGDirectDisplayID)strtoul(d, NULL, 10);
    // Do not leak the injection into child processes.
    unsetenv("DYLD_INSERT_LIBRARIES");
    Class W = [NSWindow class], A = [NSApplication class];
    swizzle(W, @selector(orderWindow:relativeTo:), (IMP)hOrderWindow, &oOrderWindow);
    swizzle(W, @selector(orderFrontRegardless), (IMP)hOrderFrontRegardless, &oOrderFrontRegardless);
    swizzle(W, @selector(makeKeyAndOrderFront:), (IMP)hMakeKeyAndOrderFront, &oMakeKeyAndOrderFront);
    swizzle(A, @selector(activateIgnoringOtherApps:), (IMP)hActivateIgnoring, &oActivateIgnoring);
    swizzle(A, @selector(activate), (IMP)hActivate, &oActivate);
    swizzle([NSRunningApplication class], @selector(activateWithOptions:), (IMP)hRunningActivate, &oRunningActivate);
    // Safety net for windows ordered through paths not hooked above.
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            for (NSWindow *w in NSApp.windows) if (w.isVisible) place(w);
        }];
    });
}
