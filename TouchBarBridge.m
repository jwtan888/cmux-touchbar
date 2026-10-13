#import "TouchBarBridge.h"
#import <dlfcn.h>
@interface NSTouchBarItem (SystemTray)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
@end
@interface NSTouchBar (AgentPresentation)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)bar systemTrayItemIdentifier:(NSString *)identifier;
+ (void)presentSystemModalFunctionBar:(NSTouchBar *)bar systemTrayItemIdentifier:(NSString *)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)bar;
@end
BOOL ShowAgentBar(NSTouchBar *bar) {
    if ([NSTouchBar respondsToSelector:@selector(presentSystemModalFunctionBar:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalFunctionBar:bar systemTrayItemIdentifier:@"cmux-helper"];
        return YES;
    }
    if ([NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalTouchBar:bar systemTrayItemIdentifier:@"cmux-helper"];
        return YES;
    }
    return NO;
}
void HideAgentBar(NSTouchBar *bar) {
    if ([NSTouchBar respondsToSelector:@selector(dismissSystemModalTouchBar:)]) [NSTouchBar dismissSystemModalTouchBar:bar];
}
BOOL InstallSystemTrayItem(NSCustomTouchBarItem *item) {
    if (![NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)]) return NO;
    [NSTouchBarItem addSystemTrayItem:item];
    return YES;
}
BOOL SetSystemTrayPresence(NSString *identifier, BOOL present) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (!handle) return NO;
    typedef void (*PresenceFn)(NSString *, BOOL);
    PresenceFn fn = (PresenceFn)dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier");
    if (!fn) return NO;
    fn(identifier, present);
    return YES;
}
