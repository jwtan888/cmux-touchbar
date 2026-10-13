#import <AppKit/AppKit.h>
BOOL ShowAgentBar(NSTouchBar *bar);
void HideAgentBar(NSTouchBar *bar);
BOOL InstallSystemTrayItem(NSCustomTouchBarItem *item);
BOOL SetSystemTrayPresence(NSString *identifier, BOOL present);
