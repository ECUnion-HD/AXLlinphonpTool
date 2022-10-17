//
//  AXLinphoneManager.h
//  AXLinphone
//
//  Created by Liu Chuanyong on 2022/10/14.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SystemConfiguration/SCNetworkReachability.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreTelephony/CTCallCenter.h>
#import <sqlite3.h>
#include "linphone/linphonecore.h"
#include "bctoolbox/list.h"

NS_ASSUME_NONNULL_BEGIN

#define LINPHONE_LOGS_MAX_ENTRY 5000
#define LC ([AXLinphoneManager getLc])

extern NSString *const LINPHONERC_APPLICATION_KEY;

extern NSString *const kLinphoneCoreUpdate;
extern NSString *const kLinphoneMainViewChange;
extern NSString *const kLinphoneBluetoothAvailabilityUpdate;

typedef enum _NetworkType {
    network_none = 0,
    network_2g,
    network_3g,
    network_4g,
    network_lte,
    network_wifi
} NetworkType;

typedef enum _Connectivity {
    wifi,
    wwan,
    none
} Connectivity;

extern const int kLinphoneAudioVbrCodecDefaultBitrate;

/* Application specific call context */
typedef struct _CallContext {
    LinphoneCall* call;
    bool_t cameraIsEnabled;
} CallContext;

struct NetworkReachabilityContext {
    bool_t testWifi, testWWan;
    void (*networkStateChanged) (Connectivity newConnectivity);
};

@interface LinphoneCallAppData :NSObject {
    @public
    bool_t batteryWarningShown;
    UILocalNotification *notification;
    NSMutableDictionary *userInfos;
    bool_t videoRequested; /*set when user has requested for video*/
    NSTimer* timer;
};
@end

typedef struct _LinphoneManagerSounds {
    SystemSoundID vibrate;
} LinphoneManagerSounds;

@interface AXLinphoneManager : NSObject {
@protected
    SCNetworkReachabilityRef proxyReachability;

@private
    NSTimer* mIterateTimer;
    NSMutableArray*  pushCallIDs;
    Connectivity connectivity;
    UIBackgroundTaskIdentifier pausedCallBgTask;
    UIBackgroundTaskIdentifier incallBgTask;
    CTCallCenter* mCallCenter;
    NSDate *mLastKeepAliveDate;
@public
    CallContext currentCallContextBeforeGoingBackground;
}

+ (AXLinphoneManager *)instance;
+ (LinphoneCore *)getLc;

- (void)resetLinphoneCore;
- (void)startLinphoneCore;
- (void)destroyLinphoneCore;
- (BOOL)resignActive;
- (void)becomeActive;
- (BOOL)enterBackgroundMode;
- (void)addPushCallId:(NSString*) callid;
- (void)configurePushTokenForProxyConfig: (LinphoneProxyConfig*)cfg;
- (BOOL)popPushCallID:(NSString*) callId;
- (void)acceptCallForCallId:(NSString*)callid;
- (LinphoneCall *)callByCallId:(NSString *)call_id;
- (void)cancelLocalNotifTimerForCallId:(NSString*)callid;
+ (void)kickOffNetworkConnection;
- (void)setupNetworkReachabilityCallback;

- (void)refreshRegisters;
- (bool)allowSpeaker;

- (void)configureVbrCodecs;

+ (NSString*)bundleFile:(NSString*)file;
+ (NSString*)documentFile:(NSString*)file;
+ (NSString*)cacheDirectory;

- (void)acceptCall:(LinphoneCall *)call;
- (void)call:(const LinphoneAddress *)address;
- (BOOL)doCall:(const LinphoneAddress *)iaddr;

- (void)lpConfigSetString:(NSString*)value forKey:(NSString*)key;
- (void)lpConfigSetString:(NSString *)value forKey:(NSString *)key inSection:(NSString *)section;
- (NSString *)lpConfigStringForKey:(NSString *)key;
- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section;
- (NSString *)lpConfigStringForKey:(NSString *)key withDefault:(NSString *)value;
- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section withDefault:(NSString *)value;

- (void)lpConfigSetInt:(int)value forKey:(NSString *)key;
- (void)lpConfigSetInt:(int)value forKey:(NSString *)key inSection:(NSString *)section;
- (int)lpConfigIntForKey:(NSString *)key;
- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section;
- (int)lpConfigIntForKey:(NSString *)key withDefault:(int)value;
- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section withDefault:(int)value;

- (void)lpConfigSetBool:(BOOL)value forKey:(NSString*)key;
- (void)lpConfigSetBool:(BOOL)value forKey:(NSString *)key inSection:(NSString *)section;
- (BOOL)lpConfigBoolForKey:(NSString *)key;
- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section;
- (BOOL)lpConfigBoolForKey:(NSString *)key withDefault:(BOOL)value;
- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section withDefault:(BOOL)value;

- (void)silentPushFailed:(NSTimer*)timer;

- (void)removeAllAccounts;

+ (BOOL)isMyself:(const LinphoneAddress *)addr;
- (LinphoneAddress *)normalizeSipOrPhoneAddress:(NSString *)addr;

@property Connectivity connectivity;
@property (readonly) NetworkType network;
@property(strong, nonatomic) NSString *SSID;
@property (readonly) sqlite3* database;
@property(nonatomic, strong) NSData *pushNotificationToken;
@property (readonly) LinphoneManagerSounds sounds;
@property (readonly) NSMutableArray *logs;
@property (nonatomic, assign) BOOL speakerEnabled;
@property (nonatomic, assign) BOOL bluetoothAvailable;
@property (nonatomic, assign) BOOL bluetoothEnabled;
@property (readonly) NSString* contactSipField;
@property (readonly,copy) NSString* contactFilter;
@property (copy) void (^silentPushCompletion)(UIBackgroundFetchResult);
@property (readonly) BOOL wasRemoteProvisioned;
@property (readonly) LpConfig *configDb;

@property(strong, nonatomic) NSMutableArray *fileTransferDelegates;
@property BOOL nextCallIsTransfer;
@property BOOL conf;

@end

NS_ASSUME_NONNULL_END
