//
//  AXLinphoneManager.m
//  AXLinphone
//
//  Created by Liu Chuanyong on 2022/10/14.
//

#import "AXLinphoneManager.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <sys/sysctl.h>
#import <asl.h>
#import <os/log.h>
#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVCaptureDevice.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include "linphone/linphonecore_utils.h"
#include "linphone/lpconfig.h"
#include "mediastreamer2/mscommon.h"
#import <UserNotifications/UserNotifications.h>

static LinphoneCore *theLinphoneCore = nil;
static AXLinphoneManager *theLinphoneManager = nil;

NSString *const LINPHONERC_APPLICATION_KEY = @"app";

NSString *const kLinphoneCoreUpdate = @"LinphoneCoreUpdate";
NSString *const kLinphoneMainViewChange = @"LinphoneMainViewChange";
NSString *const kLinphoneBluetoothAvailabilityUpdate = @"LinphoneBluetoothAvailabilityUpdate";

const int kLinphoneAudioVbrCodecDefaultBitrate = 36; /*you can override this from linphonerc or linphonerc-factory*/

extern void libmsamr_init(MSFactory *factory);
extern void libmsx264_init(MSFactory *factory);
extern void libmsopenh264_init(MSFactory *factory);
extern void libmssilk_init(MSFactory *factory);
extern void libmsbcg729_init(MSFactory *factory);
extern void libmswebrtc_init(MSFactory *factory);

#define FRONT_CAM_NAME                                                                                                 \
    "AV Capture: com.apple.avfoundation.avcapturedevice.built-in_video:1" /*"AV Capture: Front Camera"*/
#define BACK_CAM_NAME                                                                                                  \
    "AV Capture: com.apple.avfoundation.avcapturedevice.built-in_video:0" /*"AV Capture: Back Camera"*/

NSString *const kLinphoneOldChatDBFilename = @"chat_database.sqlite";
NSString *const kLinphoneInternalChatDBFilename = @"linphone_chats.db";

@implementation LinphoneCallAppData
- (id)init {
    if ((self = [super init])) {
        batteryWarningShown = FALSE;
        notification = nil;
        videoRequested = FALSE;
        userInfos = [[NSMutableDictionary alloc] init];
    }
    return self;
}

@end

@implementation AXLinphoneManager

@synthesize connectivity;

struct codec_name_pref_table {
    const char *name;
    int rate;
    const char *prefname;
};

struct codec_name_pref_table codec_pref_table[] = {{"speex", 8000, "speex_8k_preference"},
    {"speex", 16000, "speex_16k_preference"},
    {"silk", 24000, "silk_24k_preference"},
    {"silk", 16000, "silk_16k_preference"},
    {"amr", 8000, "amr_preference"},
    {"gsm", 8000, "gsm_preference"},
    {"ilbc", 8000, "ilbc_preference"},
    {"isac", 16000, "isac_preference"},
    {"pcmu", 8000, "pcmu_preference"},
    {"pcma", 8000, "pcma_preference"},
    {"g722", 8000, "g722_preference"},
    {"g729", 8000, "g729_preference"},
    {"mp4v-es", 90000, "mp4v-es_preference"},
    {"h264", 90000, "h264_preference"},
    {"vp8", 90000, "vp8_preference"},
    {"mpeg4-generic", 16000, "aaceld_16k_preference"},
    {"mpeg4-generic", 22050, "aaceld_22k_preference"},
    {"mpeg4-generic", 32000, "aaceld_32k_preference"},
    {"mpeg4-generic", 44100, "aaceld_44k_preference"},
    {"mpeg4-generic", 48000, "aaceld_48k_preference"},
    {"opus", 48000, "opus_preference"},
    {"BV16", 8000, "bv16_preference"},
    {NULL, 0, Nil}
};

+ (AXLinphoneManager *)instance {
    @synchronized(self) {
        if (theLinphoneManager == nil) {
            theLinphoneManager = [[AXLinphoneManager alloc] init];
        }
    }
    return theLinphoneManager;
}

#pragma mark - Lifecycle Functions

- (id)init {
    self = [super init];
    if (self) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(audioRouteChangeListenerCallback:)
                                                   name:AVAudioSessionRouteChangeNotification
                                                 object:nil];
        
        _sounds.vibrate = kSystemSoundID_Vibrate;
        
        _logs = [[NSMutableArray alloc] init];
        _database = NULL;
        _speakerEnabled = FALSE;
        _bluetoothEnabled = FALSE;
        _conf = FALSE;
        _fileTransferDelegates = [[NSMutableArray alloc] init];
        
        pushCallIDs = [[NSMutableArray alloc] init];
        [self renameDefaultSettings];
        [self overrideDefaultSettings];
        
        // set default values for first boot
        if ([self lpConfigStringForKey:@"debugenable_preference"] == nil) {
#ifdef DEBUG
            [self lpConfigSetInt:1 forKey:@"debugenable_preference"];
#else
            [self lpConfigSetInt:0 forKey:@"debugenable_preference"];
#endif
        }
        
        // by default if handle_content_encoding is not set, we use plain text for debug purposes only
        if ([self lpConfigStringForKey:@"handle_content_encoding" inSection:@"misc"] == nil) {
#ifdef DEBUG
            [self lpConfigSetString:@"none" forKey:@"handle_content_encoding" inSection:@"misc"];
#else
            [self lpConfigSetString:@"conflate" forKey:@"handle_content_encoding" inSection:@"misc"];
#endif
        }
        
        [self migrateFromUserPrefs];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma deploymate push "ignored-api-availability"
//静默推送
- (void)silentPushFailed:(NSTimer *)timer {
    if (_silentPushCompletion) {
        NSLog(@"silentPush failed, silentPushCompletion block: %p", _silentPushCompletion);
        _silentPushCompletion(UIBackgroundFetchResultNoData);
        _silentPushCompletion = nil;
    }
}
#pragma deploymate pop

#pragma mark - Migration
- (void)migrationAllPost {
    [self migrationLinphoneSettings];
    [self migratePushNotificationPerAccount];
}

- (void)migrationAllPre {
    // migrate xmlrpc URL if needed
    if ([self lpConfigBoolForKey:@"migration_xmlrpc"] == NO) {
        [self lpConfigSetString:@"https://subscribe.linphone.org:444/wizard.php"
                         forKey:@"xmlrpc_url"
                      inSection:@"assistant"];
        [self lpConfigSetString:@"sip:rls@sip.linphone.org" forKey:@"rls_uri" inSection:@"sip"];
        [self lpConfigSetBool:YES forKey:@"migration_xmlrpc"];
    }
    [self lpConfigSetBool:NO forKey:@"store_friends" inSection:@"misc"]; //so far, storing friends in files is not needed. may change in the future.
}
#pragma mark 检查是否转移图片
static int check_should_migrate_images(void *data, int argc, char **argv, char **cnames) {
    *((BOOL *)data) = TRUE;
    return 0;
}
#pragma mark 数据库移植
- (BOOL)migrateChatDBIfNeeded:(LinphoneCore *)lc {
    sqlite3 *newDb;
    char *errMsg;
    NSError *error;
    NSString *oldDbPath = [AXLinphoneManager documentFile:kLinphoneOldChatDBFilename];
    NSString *newDbPath = [AXLinphoneManager documentFile:kLinphoneInternalChatDBFilename];
    BOOL shouldMigrate = [[NSFileManager defaultManager] fileExistsAtPath:oldDbPath];
    BOOL shouldMigrateImages = FALSE;
    const LinphoneAddress *identity = NULL;
    BOOL migrated = FALSE;
    char *attach_stmt = NULL;
    LinphoneProxyConfig *default_proxy = linphone_core_get_default_proxy_config(lc);
    
    if (sqlite3_open([newDbPath UTF8String], &newDb) != SQLITE_OK) {
        NSLog(@"Can't open \"%@\" sqlite3 database.", newDbPath);
        return FALSE;
    }
    
    const char *check_appdata =
    "SELECT url,message FROM history WHERE url LIKE 'assets-library%' OR message LIKE 'assets-library%' LIMIT 1;";
    // will set "needToMigrateImages to TRUE if a result comes by
    sqlite3_exec(newDb, check_appdata, check_should_migrate_images, &shouldMigrateImages, NULL);
    if (!shouldMigrate && !shouldMigrateImages) {
        sqlite3_close(newDb);
        return FALSE;
    }
    
    NSLog(@"Starting migration procedure");
    
    if (shouldMigrate) {
        
        // attach old database to the new one:
        attach_stmt = sqlite3_mprintf("ATTACH DATABASE %Q AS oldchats", [oldDbPath UTF8String]);
        if (sqlite3_exec(newDb, attach_stmt, NULL, NULL, &errMsg) != SQLITE_OK) {
            NSLog(@"Can't attach old chat table, error[%s] ", errMsg);
            sqlite3_free(errMsg);
            goto exit_dbmigration;
        }
        
        // migrate old chats to the new db. The iOS stores timestamp in UTC already, so we can directly put it in the
        // 'utc' field and set 'time' to -1
        const char *migration_statement =
        "INSERT INTO history (localContact,remoteContact,direction,message,utc,read,status,time) "
        "SELECT localContact,remoteContact,direction,message,time,read,state,'-1' FROM oldchats.chat";
        
        if (sqlite3_exec(newDb, migration_statement, NULL, NULL, &errMsg) != SQLITE_OK) {
            NSLog(@"DB migration failed, error[%s] ", errMsg);
            sqlite3_free(errMsg);
            goto exit_dbmigration;
        }
        
        // invert direction of old messages, because iOS was storing the direction flag incorrectly
        const char *invert_direction = "UPDATE history SET direction = NOT direction";
        if (sqlite3_exec(newDb, invert_direction, NULL, NULL, &errMsg) != SQLITE_OK) {
            NSLog(@"Inverting direction failed, error[%s]", errMsg);
            sqlite3_free(errMsg);
            goto exit_dbmigration;
        }
        
        // replace empty from: or to: by the current identity.
        if (default_proxy) {
            identity = linphone_proxy_config_get_identity_address(default_proxy);
        }
        if (!identity) {
            identity = "sip:unknown@sip.linphone.org";
        }
        
        char *from_conversion =
        sqlite3_mprintf("UPDATE history SET localContact = %Q WHERE localContact = ''", identity);
        if (sqlite3_exec(newDb, from_conversion, NULL, NULL, &errMsg) != SQLITE_OK) {
            NSLog(@"FROM conversion failed, error[%s] ", errMsg);
            sqlite3_free(errMsg);
        }
        sqlite3_free(from_conversion);
        
        char *to_conversion =
        sqlite3_mprintf("UPDATE history SET remoteContact = %Q WHERE remoteContact = ''", identity);
        if (sqlite3_exec(newDb, to_conversion, NULL, NULL, &errMsg) != SQLITE_OK) {
            NSLog(@"DB migration failed, error[%s] ", errMsg);
            sqlite3_free(errMsg);
        }
        sqlite3_free(to_conversion);
    }
    
    // local image paths were stored in the 'message' field historically. They were
    // very temporarily stored in the 'url' field, and now we migrated them to a JSON-
    // encoded field. These are the migration steps to migrate them.
    
    // move already stored images from the messages to the appdata JSON field
    const char *assetslib_migration = "UPDATE history SET appdata='{\"localimage\":\"'||message||'\"}' , message='' "
    "WHERE message LIKE 'assets-library%'";
    if (sqlite3_exec(newDb, assetslib_migration, NULL, NULL, &errMsg) != SQLITE_OK) {
        NSLog(@"Assets-history migration for MESSAGE failed, error[%s] ", errMsg);
        sqlite3_free(errMsg);
    }
    
    // move already stored images from the url to the appdata JSON field
    const char *assetslib_migration_fromurl =
    "UPDATE history SET appdata='{\"localimage\":\"'||url||'\"}' , url='' WHERE url LIKE 'assets-library%'";
    if (sqlite3_exec(newDb, assetslib_migration_fromurl, NULL, NULL, &errMsg) != SQLITE_OK) {
        NSLog(@"Assets-history migration for URL failed, error[%s] ", errMsg);
        sqlite3_free(errMsg);
    }
    
    // We will lose received messages with remote url, they will be displayed in plain. We can't do much for them..
    migrated = TRUE;
    
exit_dbmigration:
    
    if (attach_stmt)
        sqlite3_free(attach_stmt);
    
    sqlite3_close(newDb);
    
    // in any case, we should remove the old chat db
    if (shouldMigrate && ![[NSFileManager defaultManager] removeItemAtPath:oldDbPath error:&error]) {
        NSLog(@"Could not remove old chat DB: %@", error);
    }
    
    NSLog(@"Message storage migration finished: success = %@", migrated ? @"TRUE" : @"FALSE");
    return migrated;
}
#pragma mark 转移linphone UserpRefs
- (void)migrateFromUserPrefs {
    static NSString *migration_flag = @"userpref_migration_done";
    
    if (_configDb == nil)
        return;
    
    if ([self lpConfigIntForKey:migration_flag withDefault:0]) {
        return;
    }
    
    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    NSArray *defaults_keys = [defaults allKeys];
    NSDictionary *values =
    @{ @"backgroundmode_preference" : @YES,
       @"debugenable_preference" : @NO,
       @"start_at_boot_preference" : @YES };
    BOOL shouldSync = FALSE;
    
    NSLog(@"%lu user prefs", (unsigned long)[defaults_keys count]);
    
    for (NSString *userpref in values) {
        if ([defaults_keys containsObject:userpref]) {
            NSLog(@"Migrating %@ from user preferences: %d", userpref, [[defaults objectForKey:userpref] boolValue]);
            [self lpConfigSetBool:[[defaults objectForKey:userpref] boolValue] forKey:userpref];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:userpref];
            shouldSync = TRUE;
        } else if ([self lpConfigStringForKey:userpref] == nil) {
            // no default value found in our linphonerc, we need to add them
            [self lpConfigSetBool:[[values objectForKey:userpref] boolValue] forKey:userpref];
        }
    }
    
    if (shouldSync) {
        NSLog(@"Synchronizing...");
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    // don't get back here in the future
    [self lpConfigSetBool:YES forKey:migration_flag];
}
#pragma mark 转移linphone设置
- (void)migrationLinphoneSettings {
    // we need to proceed to the migration *after* the chat database was opened, so that we know it is in consistent
    // state
    NSString *chatDBFileName = [AXLinphoneManager documentFile:kLinphoneInternalChatDBFilename];
    if ([self migrateChatDBIfNeeded:theLinphoneCore]) {
        // if a migration was performed, we should reinitialize the chat database
        linphone_core_set_chat_database_path(theLinphoneCore, [chatDBFileName UTF8String]);
    }
    
    /* AVPF migration */
    if ([self lpConfigBoolForKey:@"avpf_migration_done"] == FALSE) {
        const MSList *proxies = linphone_core_get_proxy_config_list(theLinphoneCore);
        while (proxies) {
            LinphoneProxyConfig *proxy = (LinphoneProxyConfig *)proxies->data;
            const char *addr = linphone_proxy_config_get_addr(proxy);
            // we want to enable AVPF for the proxies
            if (addr &&
                strstr(addr, [AXLinphoneManager.instance lpConfigStringForKey:@"domain_name"
                                                                  inSection:@"app"
                                                                withDefault:@"sip.linphone.org"]
                       .UTF8String) != 0) {
                    NSLog(@"Migrating proxy config to use AVPF");
                    linphone_proxy_config_set_avpf_mode(proxy, TRUE);
                }
            proxies = proxies->next;
        }
        [self lpConfigSetBool:TRUE forKey:@"avpf_migration_done"];
    }
    /* Quality Reporting migration */
    if ([self lpConfigBoolForKey:@"quality_report_migration_done"] == FALSE) {
        const MSList *proxies = linphone_core_get_proxy_config_list(theLinphoneCore);
        while (proxies) {
            LinphoneProxyConfig *proxy = (LinphoneProxyConfig *)proxies->data;
            const char *addr = linphone_proxy_config_get_addr(proxy);
            // we want to enable quality reporting for the proxies that are on linphone.org
            if (addr &&
                strstr(addr, [AXLinphoneManager.instance lpConfigStringForKey:@"domain_name"
                                                                  inSection:@"app"
                                                                withDefault:@"sip.linphone.org"]
                       .UTF8String) != 0) {
                    NSLog(@"Migrating proxy config to send quality report");
                    linphone_proxy_config_set_quality_reporting_collector(
                                                                          proxy, "sip:voip-metrics@sip.linphone.org;transport=tls");
                    linphone_proxy_config_set_quality_reporting_interval(proxy, 180);
                    linphone_proxy_config_enable_quality_reporting(proxy, TRUE);
                }
            proxies = proxies->next;
        }
        [self lpConfigSetBool:TRUE forKey:@"quality_report_migration_done"];
    }
    /* File transfer migration */
    if ([self lpConfigBoolForKey:@"file_transfer_migration_done"] == FALSE) {
        const char *newURL = "https://www.linphone.org:444/lft.php";
        NSLog(@"Migrating sharing server url from %s to %s", linphone_core_get_file_transfer_server(LC), newURL);
        linphone_core_set_file_transfer_server(LC, newURL);
        [self lpConfigSetBool:TRUE forKey:@"file_transfer_migration_done"];
    }
}
#pragma mark 转移推送通知当前用户
- (void)migratePushNotificationPerAccount {
    NSString *s = [self lpConfigStringForKey:@"pushnotification_preference"];
    if (s && s.boolValue) {
        NSLog(@"Migrating push notification per account, enabling for ALL");
        [self lpConfigSetBool:NO forKey:@"pushnotification_preference"];
        const MSList *proxies = linphone_core_get_proxy_config_list(LC);
        while (proxies) {
            linphone_proxy_config_set_ref_key(proxies->data, "push_notification");
            [self configurePushTokenForProxyConfig:proxies->data];
            proxies = proxies->next;
        }
    }
}
#pragma mark 转移向导到助手
static void migrateWizardToAssistant(const char *entry, void *user_data) {
    AXLinphoneManager *thiz = (__bridge AXLinphoneManager *)(user_data);
    NSString *key = [NSString stringWithUTF8String:entry];
    [thiz lpConfigSetString:[thiz lpConfigStringForKey:key inSection:@"wizard"] forKey:key inSection:@"assistant"];
}


static OSStatus extracted(CFStringRef *newRoute, UInt32 *newRouteSize) {
    return AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, newRouteSize, newRoute);
}

- (OSStatus)extracted:(CFStringRef *)newRoute newRouteSize:(UInt32 *)newRouteSize {
    return extracted(newRoute, newRouteSize);
}

- (void)extracted:(NSDictionary *)dict {
    [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneBluetoothAvailabilityUpdate
                                                      object:self
                                                    userInfo:dict];
}

- (void)audioRouteChangeListenerCallback:(NSNotification *)notif
{
    // there is at least one bug when you disconnect an audio bluetooth headset
    // since we only get notification of route having changed, we cannot tell if that is due to:
    // -bluetooth headset disconnected or
    // -user wanted to use earpiece
    // the only thing we can assume is that when we lost a device, it must be a bluetooth one (strong hypothesis though)
    if ([[notif.userInfo valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue] ==
        AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        _bluetoothAvailable = NO;
    }
    
    CFStringRef newRoute = CFSTR("Unknown");
    UInt32 newRouteSize = sizeof(newRoute);
    
#warning deprecated
    OSStatus status = [self extracted:&newRoute newRouteSize:&newRouteSize];
    
    if (!status && newRouteSize > 0) {
        NSString *route = (__bridge NSString *)newRoute;
        NSLog(@"Current audio route is [%s]", [route UTF8String]);
        
        _speakerEnabled = [route isEqualToString:@"Speaker"] || [route isEqualToString:@"SpeakerAndMicrophone"];
        if ([route isEqualToString:@"HeadsetBT"] && !_speakerEnabled) {
            _bluetoothAvailable = TRUE;
            _bluetoothEnabled = TRUE;
        } else {
            _bluetoothEnabled = FALSE;
        }
        NSDictionary *dict = [NSDictionary
                              dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:_bluetoothAvailable], @"available", nil];
        [self extracted:dict];
        CFRelease(newRoute);
    }
}

#pragma mark - Audio route Functions

- (bool)allowSpeaker {
    bool allow = true;
    CFStringRef lNewRoute = CFSTR("Unknown");
    UInt32 lNewRouteSize = sizeof(lNewRoute);
    #warning deprecated
    OSStatus lStatus = AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &lNewRouteSize, &lNewRoute);
    if (!lStatus && lNewRouteSize > 0) {
        NSString *route = (__bridge NSString *)lNewRoute;
        allow = ![route containsString:@"Heads"] && ![route isEqualToString:@"Lineout"];
        CFRelease(lNewRoute);
    }
    return allow;
}

- (void)setSpeakerEnabled:(BOOL)enable {
    
    OSStatus ret;
    _speakerEnabled = enable;
    UInt32 override = kAudioSessionUnspecifiedError;
    
    if (!enable && _bluetoothAvailable) {
        UInt32 bluetoothInputOverride = _bluetoothEnabled;
        #warning deprecated
        ret = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput,
                                      sizeof(bluetoothInputOverride), &bluetoothInputOverride);
        // if setting bluetooth failed, it must be because the device is not available
        // anymore (disconnected), so deactivate bluetooth.
        if (ret != kAudioSessionNoError) {
            _bluetoothAvailable = _bluetoothEnabled = FALSE;
        }
    }
    
    if (override != kAudioSessionNoError) {
        if (enable && [self allowSpeaker]) {
            override = kAudioSessionOverrideAudioRoute_Speaker;
            #warning deprecated
            ret = AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute, sizeof(override), &override);
            _bluetoothEnabled = FALSE;
        } else {
            override = kAudioSessionOverrideAudioRoute_None;
            #warning deprecated
            ret = AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute, sizeof(override), &override);
        }
    }
    
//    if (ret != kAudioSessionNoError) {
//        NSLog(@"Failed to change audio route: err %d", ret);
//    }
}

- (void)setBluetoothEnabled:(BOOL)enable {
    if (_bluetoothAvailable) {
        // The change of route will be done in setSpeakerEnabled
        _bluetoothEnabled = enable;
        [self setSpeakerEnabled:!_bluetoothEnabled && _speakerEnabled];
    }
}

- (void)overrideDefaultSettings {
    
    NSString *factory = [AXLinphoneManager bundleFile:@"linphonerc-factory"];
    NSString *confiFileName = [AXLinphoneManager documentFile:@"linphonerc"];
    _configDb = linphone_config_new_with_factory([confiFileName UTF8String], [factory UTF8String]);
}

#pragma mark - Linphone Core Functions
+ (LinphoneCore *)getLc {
    if (theLinphoneCore == nil) {
        @throw([NSException exceptionWithName:@"LinphoneCoreException"
                                       reason:@"Linphone core not initialized yet"
                                     userInfo:nil]);
    }
    return theLinphoneCore;
}

#pragma mark Debug functions
+ (void)dumpLcConfig {
    if (theLinphoneCore) {
        LpConfig *conf = AXLinphoneManager.instance.configDb;
        char *config = linphone_config_dump(conf);
        NSLog(@"\n%s", config);
        ms_free(config);
    }
}

#pragma mark - Call State Functions
- (void)localNotifContinue:(NSTimer *)timer {
    UILocalNotification *notif = [timer userInfo];
    if (notif) {
        NSLog(@"cancelling/presenting local notif");
        [[UIApplication sharedApplication] cancelAllLocalNotifications];
        [[UIApplication sharedApplication] presentLocalNotificationNow:notif];
    }
}

- (void)userNotifContinue:(NSTimer *)timer {
    if (@available(iOS 10.0, *)) {
        UNNotificationContent *content = [timer userInfo];
        if (content && [UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
            NSLog(@"cancelling/presenting user notif");
            UNNotificationRequest *req =
            [UNNotificationRequest requestWithIdentifier:@"call_request" content:content trigger:NULL];
            [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req
                                                                   withCompletionHandler:^(NSError *_Nullable error) {
                                                                       // Enable or disable features based on authorization.
                                                                       if (error) {
                                                                           NSLog(@"Error while adding notification request :");
                                                                           NSLog(@"%@", error.description);
                                                                       }
                                                                   }];
        }
    } else {
        // Fallback on earlier versions
    }
   
}

- (void)configuringStateChangedNotificationHandler:(NSNotification *)notif {
    _wasRemoteProvisioned = ((LinphoneConfiguringState)[[[notif userInfo] valueForKey:@"state"] integerValue] ==
                             LinphoneConfiguringSuccessful);
    if (_wasRemoteProvisioned) {
        LinphoneProxyConfig *cfg = linphone_core_get_default_proxy_config(LC);
        if (cfg) {
            [self configurePushTokenForProxyConfig:cfg];
        }
    }
}

- (LinphoneAddress *)normalizeSipOrPhoneAddress:(NSString *)value {
    
    if (!value) {
        return NULL;
    }
    LinphoneProxyConfig *cfg = linphone_core_get_default_proxy_config(LC);
    const char * normvalue;
    if (linphone_proxy_config_normalize_phone_number(cfg, value.UTF8String)) {
        normvalue = linphone_proxy_config_normalize_phone_number(cfg, value.UTF8String);
    } else {
        normvalue = value.UTF8String;
    }
    LinphoneAddress *addr = linphone_proxy_config_normalize_sip_uri(cfg, normvalue);
    
    // first try to find a friend with the given address
    
    // since user wants to escape plus, we assume it expects to have phone numbers by default
    if (addr && cfg && (linphone_proxy_config_get_dial_escape_plus(cfg))) {
        linphone_address_set_username(addr, normvalue);
    } else {
        linphone_address_set_username(addr, value.UTF8String);
    }
    
    return addr;
}

#pragma mark - Network Functions

- (SCNetworkReachabilityRef)getProxyReachability {
    return proxyReachability;
}
+ (void)kickOffNetworkConnection {
    static BOOL in_progress = FALSE;
    if (in_progress) {
        NSLog(@"Connection kickoff already in progress");
        return;
    }
    in_progress = TRUE;
    /* start a new thread to avoid blocking the main ui in case of peer host failure */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        static int sleep_us = 10000;
        static int timeout_s = 5;
        BOOL timeout_reached = FALSE;
        int loop = 0;
        CFWriteStreamRef writeStream;
        CFStreamCreatePairWithSocketToHost(NULL, (CFStringRef) @"192.168.0.200" /*"linphone.org"*/, 15000, nil,
                                           &writeStream);
        BOOL res = CFWriteStreamOpen(writeStream);
        const char *buff = "hello";
        time_t start = time(NULL);
        time_t loop_time;
        
        if (res == FALSE) {
            NSLog(@"Could not open write stream, backing off");
            CFRelease(writeStream);
            in_progress = FALSE;
            return;
        }
        
        // check stream status and handle timeout
        CFStreamStatus status = CFWriteStreamGetStatus(writeStream);
        while (status != kCFStreamStatusOpen && status != kCFStreamStatusError) {
            usleep(sleep_us);
            status = CFWriteStreamGetStatus(writeStream);
            loop_time = time(NULL);
            if (loop_time - start >= timeout_s) {
                timeout_reached = TRUE;
                break;
            }
            loop++;
        }
        
        if (status == kCFStreamStatusOpen) {
            CFWriteStreamWrite(writeStream, (const UInt8 *)buff, strlen(buff));
        } else if (!timeout_reached) {
            CFErrorRef error = CFWriteStreamCopyError(writeStream);
            NSLog(@"CFStreamError: %@", error);
            CFRelease(error);
        } else if (timeout_reached) {
            NSLog(@"CFStream timeout reached");
        }
        CFWriteStreamClose(writeStream);
        CFRelease(writeStream);
        in_progress = FALSE;
    });
}

+ (NSString *)getCurrentWifiSSID {
#if TARGET_IPHONE_SIMULATOR
    return @"Sim_err_SSID_NotSupported";
#else
    NSString *data = nil;
    CFDictionaryRef dict = CNCopyCurrentNetworkInfo((CFStringRef) @"en0");
    if (dict) {
        NSLog(@"AP Wifi: %@", dict);
        data = [NSString stringWithString:(NSString *)CFDictionaryGetValue(dict, @"SSID")];
        CFRelease(dict);
    }
    return data;
#endif
}

static void showNetworkFlags(SCNetworkReachabilityFlags flags) {
    NSMutableString *log = [[NSMutableString alloc] initWithString:@"Network connection flags: "];
    if (flags == 0)
        [log appendString:@"no flags."];
    if (flags & kSCNetworkReachabilityFlagsTransientConnection)
        [log appendString:@"kSCNetworkReachabilityFlagsTransientConnection, "];
    if (flags & kSCNetworkReachabilityFlagsReachable)
        [log appendString:@"kSCNetworkReachabilityFlagsReachable, "];
    if (flags & kSCNetworkReachabilityFlagsConnectionRequired)
        [log appendString:@"kSCNetworkReachabilityFlagsConnectionRequired, "];
    if (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic)
        [log appendString:@"kSCNetworkReachabilityFlagsConnectionOnTraffic, "];
    if (flags & kSCNetworkReachabilityFlagsConnectionOnDemand)
        [log appendString:@"kSCNetworkReachabilityFlagsConnectionOnDemand, "];
    if (flags & kSCNetworkReachabilityFlagsIsLocalAddress)
        [log appendString:@"kSCNetworkReachabilityFlagsIsLocalAddress, "];
    if (flags & kSCNetworkReachabilityFlagsIsDirect)
        [log appendString:@"kSCNetworkReachabilityFlagsIsDirect, "];
    if (flags & kSCNetworkReachabilityFlagsIsWWAN)
        [log appendString:@"kSCNetworkReachabilityFlagsIsWWAN, "];
    NSLog(@"%@", log);
}

//This callback keeps tracks of wifi SSID changes.
static void networkReachabilityNotification(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                            const void *object, CFDictionaryRef userInfo) {
    AXLinphoneManager *mgr = AXLinphoneManager.instance;
    SCNetworkReachabilityFlags flags;
    
    // for an unknown reason, we are receiving multiple time the notification, so
    // we will skip each time the SSID did not change
    NSString *newSSID = [AXLinphoneManager getCurrentWifiSSID];
    if ([newSSID compare:mgr.SSID] == NSOrderedSame)
        return;
    
    
    if (newSSID != Nil && newSSID.length > 0 && mgr.SSID != Nil && newSSID.length > 0){
        if (SCNetworkReachabilityGetFlags([mgr getProxyReachability], &flags)) {
            NSLog(@"Wifi SSID changed, resesting transports.");
            mgr.connectivity=none; //this will trigger a connectivity change in networkReachabilityCallback.
            networkReachabilityCallBack([mgr getProxyReachability], flags, nil);
        }
    }
    mgr.SSID = newSSID;
    
    
}

void networkReachabilityCallBack(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *nilCtx) {
    showNetworkFlags(flags);
    AXLinphoneManager *lm = AXLinphoneManager.instance;
    SCNetworkReachabilityFlags networkDownFlags = kSCNetworkReachabilityFlagsConnectionRequired |
    kSCNetworkReachabilityFlagsConnectionOnTraffic |
    kSCNetworkReachabilityFlagsConnectionOnDemand;
    
    if (theLinphoneCore != nil) {
        LinphoneProxyConfig *proxy = linphone_core_get_default_proxy_config(theLinphoneCore);
        
        struct NetworkReachabilityContext *ctx = nilCtx ? ((struct NetworkReachabilityContext *)nilCtx) : 0;
        if ((flags == 0) || (flags & networkDownFlags)) {
            linphone_core_set_network_reachable(theLinphoneCore, false);
            lm.connectivity = none;
            [AXLinphoneManager kickOffNetworkConnection];
        } else {
            Connectivity newConnectivity;
            BOOL isWifiOnly = [lm lpConfigBoolForKey:@"wifi_only_preference" withDefault:FALSE];
            if (!ctx || ctx->testWWan)
                newConnectivity = flags & kSCNetworkReachabilityFlagsIsWWAN ? wwan : wifi;
            else
                newConnectivity = wifi;
            
            if (newConnectivity == wwan && proxy && isWifiOnly &&
                (lm.connectivity == newConnectivity || lm.connectivity == none)) {
                linphone_proxy_config_expires(proxy, 0);
            } else if (proxy) {
                NSInteger defaultExpire = [lm lpConfigIntForKey:@"default_expires"];
                if (defaultExpire >= 0)
                    linphone_proxy_config_expires(proxy, (int)defaultExpire);
                // else keep default value from linphonecore
            }
            
            if (lm.connectivity != newConnectivity) {
                // connectivity has changed
                linphone_core_set_network_reachable(theLinphoneCore, false);
                if (newConnectivity == wwan && proxy && isWifiOnly) {
                    linphone_proxy_config_expires(proxy, 0);
                }
                linphone_core_set_network_reachable(theLinphoneCore, true);
                linphone_core_iterate(theLinphoneCore);
                NSLog(@"Network connectivity changed to type [%s]", (newConnectivity == wifi ? "wifi" : "wwan"));
                lm.connectivity = newConnectivity;
            }
        }
        if (ctx && ctx->networkStateChanged) {
            (*ctx->networkStateChanged)(lm.connectivity);
        }
    }
}

#pragma mark - 设置网络状态回调
- (void)setupNetworkReachabilityCallback {
    SCNetworkReachabilityContext *ctx = NULL;
    // any internet cnx
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    if (proxyReachability) {
        NSLog(@"Cancelling old network reachability");
        SCNetworkReachabilityUnscheduleFromRunLoop(proxyReachability, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(proxyReachability);
        proxyReachability = nil;
    }
    
    // This notification is used to detect SSID change (switch of Wifi network). The ReachabilityCallback is
    // not triggered when switching between 2 private Wifi...
    // Since we cannot be sure we were already observer, remove ourself each time... to be improved
    _SSID = [AXLinphoneManager getCurrentWifiSSID];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)(self),
                                       CFSTR("com.apple.system.config.network_change"), NULL);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)(self),
                                    networkReachabilityNotification, CFSTR("com.apple.system.config.network_change"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    
    proxyReachability =
    SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
    
    if (!SCNetworkReachabilitySetCallback(proxyReachability, (SCNetworkReachabilityCallBack)networkReachabilityCallBack,
                                          ctx)) {
        NSLog(@"Cannot register reachability cb: %s", SCErrorString(SCError()));
        return;
    }
    if (!SCNetworkReachabilityScheduleWithRunLoop(proxyReachability, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode)) {
        NSLog(@"Cannot register schedule reachability cb: %s", SCErrorString(SCError()));
        return;
    }
    
    // this check is to know network connectivity right now without waiting for a change. Don'nt remove it unless you
    // have good reason. Jehan
    SCNetworkReachabilityFlags flags;
    if (SCNetworkReachabilityGetFlags(proxyReachability, &flags)) {
        networkReachabilityCallBack(proxyReachability, flags, nil);
    }
}

- (NetworkType)network {
    if ([[[UIDevice currentDevice] systemVersion] floatValue] < 7) {
        UIApplication *app = [UIApplication sharedApplication];
        NSArray *subviews = [[[app valueForKey:@"statusBar"] valueForKey:@"foregroundView"] subviews];
        NSNumber *dataNetworkItemView = nil;
        
        for (id subview in subviews) {
            if ([subview isKindOfClass:[NSClassFromString(@"UIStatusBarDataNetworkItemView") class]]) {
                dataNetworkItemView = subview;
                break;
            }
        }
        
        NSNumber *number = (NSNumber *)[dataNetworkItemView valueForKey:@"dataNetworkType"];
        return [number intValue];
    } else {
#pragma deploymate push "ignored-api-availability"
        CTTelephonyNetworkInfo *info = [[CTTelephonyNetworkInfo alloc] init];
        NSString *currentRadio = info.currentRadioAccessTechnology;
        if ([currentRadio isEqualToString:CTRadioAccessTechnologyEdge]) {
            return network_2g;
        } else if ([currentRadio isEqualToString:CTRadioAccessTechnologyLTE]) {
            return network_4g;
        }
#pragma deploymate pop
        return network_3g;
    }
}

#pragma mark -

- (void)audioSessionInterrupted:(NSNotification *)notification {
    int interruptionType = [notification.userInfo[AVAudioSessionInterruptionTypeKey] intValue];
    if (interruptionType == AVAudioSessionInterruptionTypeBegan) {
        [self beginInterruption];
    } else if (interruptionType == AVAudioSessionInterruptionTypeEnded) {
        [self endInterruption];
    }
}

static BOOL libStarted = FALSE;

// scheduling loop
- (void)iterate {
    linphone_core_iterate(theLinphoneCore);
}

- (void)startLinphoneCore {
    
    if (libStarted) {
        NSLog(@"Liblinphone is already initialized!");
        return;
    }
    
    libStarted = TRUE;
    
    connectivity = none;
    signal(SIGPIPE, SIG_IGN);
    
    // create linphone core
    [self createLinphoneCore];

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    BOOL bAudioInputAvailable = audioSession.inputAvailable;
    NSError *err;
    
    if (![audioSession setActive:NO error:&err] && err) {
        NSLog(@"audioSession setActive failed: %@", [err description]);
    }
    if (!bAudioInputAvailable) {
        UIAlertController *errView = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"No microphone", nil)
                                                                         message:NSLocalizedString(@"You need to plug a microphone to your device to use the application.", nil)
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction * action) {}];
        
        [errView addAction:defaultAction];
    }
    
    // Disable notify policy
    LinphoneImNotifPolicy *im_notif_policy;
    im_notif_policy = linphone_core_get_im_notif_policy(theLinphoneCore);
    if (im_notif_policy != NULL) {
        linphone_im_notif_policy_clear(im_notif_policy);
        linphone_im_notif_policy_set_send_is_composing(im_notif_policy, TRUE);
        linphone_im_notif_policy_set_recv_is_composing(im_notif_policy, TRUE);
    }
    
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        [self enterBackgroundMode];
    }
}

- (BOOL)enterBackgroundMode {
    
    LinphoneProxyConfig *proxyCfg = linphone_core_get_default_proxy_config(theLinphoneCore);
    BOOL shouldEnterBgMode = FALSE;
    
    // disable presence
    [self enableProxyPublish:NO];
    
    // handle proxy config if any
    if (proxyCfg) {
        const char *refkey = proxyCfg ? linphone_proxy_config_get_ref_key(proxyCfg) : NULL;
        BOOL pushNotifEnabled = (refkey && strcmp(refkey, "push_notification") == 0);
        if ([AXLinphoneManager.instance lpConfigBoolForKey:@"backgroundmode_preference"] || pushNotifEnabled) {
            if (floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
                // For registration register
                [self refreshRegisters];
            }
        }
        
        if ([AXLinphoneManager.instance lpConfigBoolForKey:@"backgroundmode_preference"]) {
            // register keepalive
            if ([[UIApplication sharedApplication]
                 setKeepAliveTimeout:600
                 handler:^{
                     NSLog(@"keepalive handler");
                self->mLastKeepAliveDate = [NSDate date];
                     if (theLinphoneCore == nil) {
                         NSLog(@"It seems that Linphone BG mode was deactivated, just skipping");
                         return;
                     }
//                     [_iapManager check];
                     if (floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
                         // For registration register
                         [self refreshRegisters];
                     }
                     linphone_core_iterate(theLinphoneCore);
                 }]) {
                     
                     NSLog(@"keepalive handler succesfully registered");
                 } else {
                     NSLog(@"keepalive handler cannot be registered");
                 }
            shouldEnterBgMode = TRUE;
        }
    }
    
    LinphoneCall *currentCall = linphone_core_get_current_call(theLinphoneCore);
    const bctbx_list_t *callList = linphone_core_get_calls(theLinphoneCore);
    if (!currentCall // no active call
        && callList  // at least one call in a non active state
        && bctbx_list_find_custom(callList, (bctbx_compare_func)comp_call_state_paused, NULL)) {
        [self startCallPausedLongRunningTask];
    }
    if (callList) {
        /*if at least one call exist, enter normal bg mode */
        shouldEnterBgMode = TRUE;
    }
    /*stop the video preview*/
    if (theLinphoneCore) {
        linphone_core_enable_video_preview(theLinphoneCore, FALSE);
        linphone_core_iterate(theLinphoneCore);
    }
    linphone_core_stop_dtmf_stream(theLinphoneCore);
    
    NSLog(@"Entering [%s] bg mode", shouldEnterBgMode ? "normal" : "lite");
    
    if (!shouldEnterBgMode && floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
        const char *refkey = proxyCfg ? linphone_proxy_config_get_ref_key(proxyCfg) : NULL;
        BOOL pushNotifEnabled = (refkey && strcmp(refkey, "push_notification") == 0);
        if (pushNotifEnabled) {
            NSLog(@"Keeping lc core to handle push");
            /*destroy voip socket if any and reset connectivity mode*/
            connectivity = none;
            linphone_core_set_network_reachable(theLinphoneCore, FALSE);
            return YES;
        }
        return NO;
        
    } else
        return YES;
}

- (void)refreshRegisters {
    
    if (connectivity == none) {
        // don't trust ios when he says there is no network. Create a new reachability context, the previous one might
        // be mis-functionning.
        NSLog(@"None connectivity");
        [self setupNetworkReachabilityCallback];
    }
    NSLog(@"Network reachability callback setup");
    if (theLinphoneCore) {
        linphone_core_refresh_registers(theLinphoneCore); // just to make sure REGISTRATION is up to date
    }
}

- (void)becomeActive {
    // enable presence
    if (floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max || self.connectivity == none) {
        [self refreshRegisters];
    }
    if (pausedCallBgTask) {
        [[UIApplication sharedApplication] endBackgroundTask:pausedCallBgTask];
        pausedCallBgTask = 0;
    }
    if (incallBgTask) {
        [[UIApplication sharedApplication] endBackgroundTask:incallBgTask];
        incallBgTask = 0;
    }
    
    /*IOS specific*/
    linphone_core_start_dtmf_stream(theLinphoneCore);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL granted){
                             }];
    
    /*start the video preview in case we are in the main view*/
    if (linphone_core_video_display_enabled(theLinphoneCore) && [self lpConfigBoolForKey:@"preview_preference"]) {
        linphone_core_enable_video_preview(theLinphoneCore, TRUE);
    }
    /*check last keepalive handler date*/
    if (mLastKeepAliveDate != Nil) {
        NSDate *current = [NSDate date];
        if ([current timeIntervalSinceDate:mLastKeepAliveDate] > 700) {
            NSString *datestr = [mLastKeepAliveDate description];
            NSLog(@"keepalive handler was called for the last time at %@", datestr);
        }
    }
    
    [self enableProxyPublish:YES];
}
- (void)createLinphoneCore {
    
    [self migrationAllPre];
    if (theLinphoneCore != nil) {
        NSLog(@"linphonecore is already created");
        return;
    }
//    [Log enableLogs:[self lpConfigIntForKey:@"debugenable_preference"]];
    //日志输出相关
    [self enableLogs:LinphoneLogLevelDebug];
    connectivity = none;
    
    // Set audio assets
    NSString *ring =
    ([AXLinphoneManager bundleFile:[self lpConfigStringForKey:@"local_ring" inSection:@"sound"].lastPathComponent]
     ?: [AXLinphoneManager bundleFile:@"notes_of_the_optimistic.caf"])
    .lastPathComponent;
    NSString *ringback =
    ([AXLinphoneManager bundleFile:[self lpConfigStringForKey:@"remote_ring" inSection:@"sound"].lastPathComponent]
     ?: [AXLinphoneManager bundleFile:@"ringback.wav"])
    .lastPathComponent;
    
    NSString *hold =
    ([AXLinphoneManager bundleFile:[self lpConfigStringForKey:@"hold_music" inSection:@"sound"].lastPathComponent]
     ?: [AXLinphoneManager bundleFile:@"hold.mkv"])
    .lastPathComponent;
    [self lpConfigSetString:[AXLinphoneManager bundleFile:ring] forKey:@"local_ring" inSection:@"sound"];
    [self lpConfigSetString:[AXLinphoneManager bundleFile:ringback] forKey:@"remote_ring" inSection:@"sound"];
    [self lpConfigSetString:[AXLinphoneManager bundleFile:hold] forKey:@"hold_music" inSection:@"sound"];
    theLinphoneCore = linphone_factory_create_core_with_config_3(linphone_factory_get(), _configDb, NULL);
    NSLog(@"Create linphonecore %p", theLinphoneCore);
    linphone_core_start(theLinphoneCore);
    // Load plugins if available in the linphone SDK - otherwise these calls will do nothing
    MSFactory *f = linphone_core_get_ms_factory(theLinphoneCore);
    libmssilk_init(f);
    libmsamr_init(f);
    libmsx264_init(f);
    libmsopenh264_init(f);
//    libmsbcg729_init(f);
    libmswebrtc_init(f);
    linphone_core_reload_ms_plugins(theLinphoneCore, NULL);
    [self migrationAllPost];
    //设置CA证书
    /* set the CA file no matter what, since the remote provisioning could be hitting an HTTPS server */
    linphone_core_set_root_ca(theLinphoneCore, [AXLinphoneManager bundleFile:@"rootca.pem"].UTF8String);
    linphone_core_set_user_certificates_path(theLinphoneCore, [AXLinphoneManager cacheDirectory].UTF8String);
    
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(audioSessionInterrupted:)
                                               name:AVAudioSessionInterruptionNotification
                                             object:nil];
    
    /*call iterate once immediately in order to initiate background connections with sip server or remote provisioning
     * grab, if any */
    linphone_core_iterate(theLinphoneCore);
    // start scheduler
    mIterateTimer =
    [NSTimer scheduledTimerWithTimeInterval:0.02 target:self selector:@selector(iterate) userInfo:nil repeats:YES];
}

- (void)resetLinphoneCore {
    [self destroyLinphoneCore];
    [self createLinphoneCore];
    // reset network state to trigger a new network connectivity assessment
    linphone_core_set_network_reachable(theLinphoneCore, FALSE);
}

static int comp_call_id(const LinphoneCall *call, const char *callid) {
    if (linphone_call_log_get_call_id(linphone_call_get_call_log(call)) == nil) {
        ms_error("no callid for call [%p]", call);
        return 1;
    }
    return strcmp(linphone_call_log_get_call_id(linphone_call_get_call_log(call)), callid);
}

- (LinphoneCall *)callByCallId:(NSString *)call_id {
    const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
    if (!calls) {
        return NULL;
    }
    bctbx_list_t *call_tmp = bctbx_list_find_custom(calls, (bctbx_compare_func)comp_call_id, [call_id UTF8String]);
    if (!call_tmp) {
        return NULL;
    }
    LinphoneCall *call = (LinphoneCall *)call_tmp->data;
    return call;
}
- (void)cancelLocalNotifTimerForCallId:(NSString *)callid {
    // first, make sure this callid is not already involved in a call
    const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
    bctbx_list_t *call = bctbx_list_find_custom(calls, (bctbx_compare_func)comp_call_id, [callid UTF8String]);
    if (call != NULL) {
        LinphoneCallAppData *data =
        (__bridge LinphoneCallAppData *)(linphone_call_get_user_data((LinphoneCall *)call->data));
        if (data->timer)
            [data->timer invalidate];
        data->timer = nil;
        return;
    }
}
#pragma mark - LOG
- (void)enableLogs:(LinphoneLogLevel)level
{
    static BOOL stderrInUse = NO;
    if (!stderrInUse) {
        asl_add_log_file(NULL, STDERR_FILENO);
        stderrInUse = YES;
    }
    if (level == 5) {
        linphone_logging_service_set_log_level(linphone_logging_service_get(), LinphoneLogLevelFatal);
    } else {
        linphone_logging_service_set_log_level(linphone_logging_service_get(), level);
    }
}
- (void)acceptCallForCallId:(NSString *)callid {
    // first, make sure this callid is not already involved in a call
    const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
    bctbx_list_t *call = bctbx_list_find_custom(calls, (bctbx_compare_func)comp_call_id, [callid UTF8String]);
    if (call != NULL) {
        [self acceptCall:(LinphoneCall *)call->data];
        return;
    };
}
- (void)addPushCallId:(NSString *)callid {
    // first, make sure this callid is not already involved in a call
    const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
    if (bctbx_list_find_custom(calls, (bctbx_compare_func)comp_call_id, [callid UTF8String])) {
        NSLog(@"Call id [%@] already handled", callid);
        return;
    };
    if ([pushCallIDs count] > 10 /*max number of pending notif*/)
        [pushCallIDs removeObjectAtIndex:0];
    
    [pushCallIDs addObject:callid];
}

- (BOOL)popPushCallID:(NSString *)callId {
    for (NSString *pendingNotif in pushCallIDs) {
        if ([pendingNotif compare:callId] == NSOrderedSame) {
            [pushCallIDs removeObject:pendingNotif];
            return TRUE;
        }
    }
    return FALSE;
}

- (BOOL)resignActive {
    linphone_core_stop_dtmf_stream(theLinphoneCore);
    
    return YES;
}
#pragma mark - Call Functions
- (void)acceptCall:(LinphoneCall *)call
{
    LinphoneCallParams *lcallParams = linphone_core_create_call_params(theLinphoneCore, call);
    if (!lcallParams) {
        NSLog(@"Could not create call parameters for %p, call has probably already ended.", call);
        return;
    }
    
    if ([self lpConfigBoolForKey:@"edge_opt_preference"]) {
        bool low_bandwidth = self.network == network_2g;
        if (low_bandwidth) {
            NSLog(@"Low bandwidth mode");
        }
        linphone_call_params_enable_low_bandwidth(lcallParams, low_bandwidth);
    }
    linphone_call_params_enable_video(lcallParams, NO);
    
    linphone_call_accept_with_params(call, lcallParams);
}

- (void)call:(const LinphoneAddress *)iaddr {
        
    // First verify that network is available, abort otherwise.
    if (!linphone_core_is_network_reachable(theLinphoneCore)) {
        NSLog(@"Network Error", nil);
        return;
    }
    
    // Then check that no GSM calls are in progress, abort otherwise.
    CTCallCenter *callCenter = [[CTCallCenter alloc] init];
    if ([callCenter currentCalls] != nil && floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
        
        NSLog(@"GSM call in progress, cancelling outgoing SIP call request");
      
        return;
    }
    
    // Then check that the supplied address is valid
    if (!iaddr) {
       
        NSLog(@"Invalid SIP address");

        return;
    }
    
    if (linphone_core_get_calls_nb(theLinphoneCore) < 1 &&
        floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_9_x_Max ){
        [self doCall:iaddr];
    } else {
        [self doCall:iaddr];
    }
}

- (BOOL)doCall:(const LinphoneAddress *)iaddr {
    
    LinphoneAddress *addr = linphone_address_clone(iaddr);
    // Finally we can make the call
    LinphoneCallParams *lcallParams = linphone_core_create_call_params(theLinphoneCore, NULL);
    if ([self lpConfigBoolForKey:@"edge_opt_preference"] && (self.network == network_2g)) {
        NSLog(@"Enabling low bandwidth mode");
        linphone_call_params_enable_low_bandwidth(lcallParams, YES);
    }
    if ([AXLinphoneManager.instance lpConfigBoolForKey:@"override_domain_with_default_one"]) {
        linphone_address_set_domain(
                                    addr, [[AXLinphoneManager.instance lpConfigStringForKey:@"domain" inSection:@"assistant"] UTF8String]);
    }
    
    LinphoneCall *call;
    if (AXLinphoneManager.instance.nextCallIsTransfer) {
        char *caddr = linphone_address_as_string(addr);
        call = linphone_core_get_current_call(theLinphoneCore);
        linphone_call_transfer(call, caddr);
        AXLinphoneManager.instance.nextCallIsTransfer = NO;
        ms_free(caddr);
    } else {
        call = linphone_core_invite_address_with_params(theLinphoneCore, addr, lcallParams);
        if (call) {
            
            // The LinphoneCallAppData object should be set on call creation with callback
            // - (void)onCall:StateChanged:withMessage:. If not, we are in big trouble and expect it to crash
            // We are NOT responsible for creating the AppData.
            LinphoneCallAppData *data = (__bridge LinphoneCallAppData *)linphone_call_get_user_data(call);
            
            if (data == nil) {
                NSLog(@"New call instanciated but app data was not set. Expect it to crash.");
                /* will be used later to notify user if video was not activated because of the linphone core*/
            } else {
                data->videoRequested = linphone_call_params_video_enabled(lcallParams);
//                linphone_core_invite(LC, linphone_address_as_string(iaddr));
                
            }
        }
    }
    linphone_address_unref(addr);
    linphone_call_params_unref(lcallParams);
    
    return TRUE;
}

#pragma mark - Property Functions

- (void)setPushNotificationToken:(NSData *)apushNotificationToken {
    if (apushNotificationToken == _pushNotificationToken) {
        return;
    }
    _pushNotificationToken = apushNotificationToken;
    
    @try {
        const MSList *proxies = linphone_core_get_proxy_config_list(LC);
        while (proxies) {
            [self configurePushTokenForProxyConfig:proxies->data];
            proxies = proxies->next;
        }
    } @catch (NSException* e) {
        NSLog(@"%s: linphone core not ready yet, ignoring push token", __FUNCTION__);
    }
}

- (void)configurePushTokenForProxyConfig:(LinphoneProxyConfig *)proxyCfg {
    linphone_proxy_config_edit(proxyCfg);
    
    NSData *tokenData = _pushNotificationToken;
    const char *refkey = linphone_proxy_config_get_ref_key(proxyCfg);
    BOOL pushNotifEnabled = (refkey && strcmp(refkey, "push_notification") == 0);
    if (tokenData != nil && pushNotifEnabled) {
        const unsigned char *tokenBuffer = [tokenData bytes];
        NSMutableString *tokenString = [NSMutableString stringWithCapacity:[tokenData length] * 2];
        for (int i = 0; i < [tokenData length]; ++i) {
            [tokenString appendFormat:@"%02X", (unsigned int)tokenBuffer[i]];
        }
        // NSLocalizedString(@"IC_MSG", nil); // Fake for genstrings
        // NSLocalizedString(@"IM_MSG", nil); // Fake for genstrings
        // NSLocalizedString(@"IM_FULLMSG", nil); // Fake for genstrings
#ifdef DEBUG
#define APPMODE_SUFFIX @"dev"
#else
#define APPMODE_SUFFIX @"prod"
#endif
        NSString *ring =
        ([AXLinphoneManager bundleFile:[self lpConfigStringForKey:@"local_ring" inSection:@"sound"].lastPathComponent]
         ?: [AXLinphoneManager bundleFile:@"notes_of_the_optimistic.caf"])
        .lastPathComponent;
        NSString * notif_type;
        if (floor(NSFoundationVersionNumber) >= NSFoundationVersionNumber_iOS_8_0) {
            //IOS 8 and more
            notif_type = @".voip";
        } else {
            // IOS 7 and below
            notif_type = @"";
        }
        NSString *timeout;
        if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_9_x_Max) {
            timeout = @";pn-timeout=0";
        } else {
            timeout = @"";
        }
        
        NSString *silent;
        if (floor(NSFoundationVersionNumber) >= NSFoundationVersionNumber_iOS_8_0) {
            silent = @";pn-silent=1";
        } else {
            silent = @"";
        }
        
        NSString *params = [NSString
                            stringWithFormat:@"app-id=%@%@.%@;pn-type=apple;pn-tok=%@;pn-msg-str=IM_MSG;pn-call-str=IC_MSG;pn-"
                            @"call-snd=%@;pn-msg-snd=msg.caf%@%@",
                            [[NSBundle mainBundle] bundleIdentifier], notif_type, APPMODE_SUFFIX, tokenString, ring, timeout, silent];
        
//        NSLog(@"Proxy config %s configured for push notifications with contact: %@",
//             linphone_proxy_config_get_identity_address(proxyCfg), params);
        linphone_proxy_config_set_contact_uri_parameters(proxyCfg, [params UTF8String]);
        linphone_proxy_config_set_contact_parameters(proxyCfg, NULL);
    } else {
//        NSLog(@"Proxy config %s NOT configured for push notifications", linphone_proxy_config_get_identity_address(proxyCfg));
        // no push token:
        linphone_proxy_config_set_contact_uri_parameters(proxyCfg, NULL);
        linphone_proxy_config_set_contact_parameters(proxyCfg, NULL);
    }
    
    linphone_proxy_config_done(proxyCfg);
}

#pragma mark - Misc Functions

+ (NSString *)bundleFile:(NSString *)file {
    return [[NSBundle mainBundle] pathForResource:[file stringByDeletingPathExtension] ofType:[file pathExtension]];
}

+ (NSString *)documentFile:(NSString *)file {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsPath = [paths objectAtIndex:0];
    return [documentsPath stringByAppendingPathComponent:file];
}

+ (NSString *)cacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachePath = [paths objectAtIndex:0];
    BOOL isDir = NO;
    NSError *error;
    // cache directory must be created if not existing
    if (![[NSFileManager defaultManager] fileExistsAtPath:cachePath isDirectory:&isDir] && isDir == NO) {
        [[NSFileManager defaultManager] createDirectoryAtPath:cachePath
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:&error];
    }
    return cachePath;
}

- (void)configureVbrCodecs {
    LinphonePayloadType *pt;
    int bitrate = linphone_config_get_int(_configDb, "audio", "codec_bitrate_limit", kLinphoneAudioVbrCodecDefaultBitrate);
    const MSList *audio_codecs = linphone_core_get_audio_payload_types(theLinphoneCore);
    const MSList *codec = audio_codecs;
    while (codec) {
        pt = codec->data;
        if (linphone_payload_type_is_vbr(pt)) {
            linphone_payload_type_set_normal_bitrate(pt, bitrate);
        }
        codec = codec->next;
    }
}

#pragma mark - LPConfig Functions

- (void)lpConfigSetString:(NSString *)value forKey:(NSString *)key {
    [self lpConfigSetString:value forKey:key inSection:LINPHONERC_APPLICATION_KEY];
}
- (void)lpConfigSetString:(NSString *)value forKey:(NSString *)key inSection:(NSString *)section {
    if (!key)
        return;
    linphone_config_set_string(_configDb, [section UTF8String], [key UTF8String], value ? [value UTF8String] : NULL);
}
- (NSString *)lpConfigStringForKey:(NSString *)key {
    return [self lpConfigStringForKey:key withDefault:@""];
}
- (NSString *)lpConfigStringForKey:(NSString *)key withDefault:(NSString *)defaultValue {
    return [self lpConfigStringForKey:key inSection:LINPHONERC_APPLICATION_KEY withDefault:defaultValue];
}
- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section {
    return [self lpConfigStringForKey:key inSection:section withDefault:@""];
}
- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section withDefault:(NSString *)defaultValue {
    if (!key)
        return defaultValue;
    const char *value = linphone_config_get_string(_configDb, [section UTF8String], [key UTF8String], NULL);
    return value ? [NSString stringWithUTF8String:value] : defaultValue;
}

- (void)lpConfigSetInt:(int)value forKey:(NSString *)key {
    [self lpConfigSetInt:value forKey:key inSection:LINPHONERC_APPLICATION_KEY];
}
- (void)lpConfigSetInt:(int)value forKey:(NSString *)key inSection:(NSString *)section {
    if (!key)
        return;
    linphone_config_set_int(_configDb, [section UTF8String], [key UTF8String], (int)value);
}
- (int)lpConfigIntForKey:(NSString *)key {
    return [self lpConfigIntForKey:key withDefault:-1];
}
- (int)lpConfigIntForKey:(NSString *)key withDefault:(int)defaultValue {
    return [self lpConfigIntForKey:key inSection:LINPHONERC_APPLICATION_KEY withDefault:defaultValue];
}
- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section {
    return [self lpConfigIntForKey:key inSection:section withDefault:-1];
}
- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section withDefault:(int)defaultValue {
    if (!key)
        return defaultValue;
    return linphone_config_get_int(_configDb, [section UTF8String], [key UTF8String], (int)defaultValue);
}

- (void)lpConfigSetBool:(BOOL)value forKey:(NSString *)key {
    [self lpConfigSetBool:value forKey:key inSection:LINPHONERC_APPLICATION_KEY];
}
- (void)lpConfigSetBool:(BOOL)value forKey:(NSString *)key inSection:(NSString *)section {
    [self lpConfigSetInt:(int)(value == TRUE) forKey:key inSection:section];
}
- (BOOL)lpConfigBoolForKey:(NSString *)key {
    return [self lpConfigBoolForKey:key withDefault:FALSE];
}
- (BOOL)lpConfigBoolForKey:(NSString *)key withDefault:(BOOL)defaultValue {
    return [self lpConfigBoolForKey:key inSection:LINPHONERC_APPLICATION_KEY withDefault:defaultValue];
}
- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section {
    return [self lpConfigBoolForKey:key inSection:section withDefault:FALSE];
}
- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section withDefault:(BOOL)defaultValue {
    if (!key)
        return defaultValue;
    int val = [self lpConfigIntForKey:key inSection:section withDefault:-1];
    return (val != -1) ? (val == 1) : defaultValue;
}


#pragma mark - GSM management

- (void)removeCTCallCenterCb {
    if (mCallCenter != nil) {
        NSLog(@"Removing CT call center listener [%p]", mCallCenter);
        mCallCenter.callEventHandler = NULL;
    }
    mCallCenter = nil;
}


static int comp_call_state_paused(const LinphoneCall *call, const void *param) {
    return linphone_call_get_state(call) != LinphoneCallPaused;
}

- (void)destroyLinphoneCore {
    [mIterateTimer invalidate];
    // just in case
    [self removeCTCallCenterCb];
    
    if (theLinphoneCore != nil) { // just in case application terminate before linphone core initialization
        
        linphone_core_unref(theLinphoneCore);
        NSLog(@"Destroy linphonecore %p", theLinphoneCore);
        theLinphoneCore = nil;
        
        // Post event
        NSDictionary *dict =
        [NSDictionary dictionaryWithObject:[NSValue valueWithPointer:theLinphoneCore] forKey:@"core"];
        [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneCoreUpdate
                                                          object:AXLinphoneManager.instance
                                                        userInfo:dict];
        
        SCNetworkReachabilityUnscheduleFromRunLoop(proxyReachability, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        if (proxyReachability)
            CFRelease(proxyReachability);
        proxyReachability = nil;
    }
    libStarted = FALSE;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark -

- (void)removeAllAccounts {
    linphone_core_clear_proxy_config(LC);
    linphone_core_clear_all_auth_info(LC);
}

+ (BOOL)isMyself:(const LinphoneAddress *)addr {
    if (!addr)
        return NO;
    
    const MSList *it = linphone_core_get_proxy_config_list(LC);
    while (it) {
        if (linphone_address_weak_equal(addr, linphone_proxy_config_get_identity_address(it->data))) {
            return YES;
        }
        it = it->next;
    }
    return NO;
}
//通话被打断
- (void)beginInterruption {
    LinphoneCall *c = linphone_core_get_current_call(theLinphoneCore);
    NSLog(@"Sound interruption detected!");
    if (c && linphone_call_get_state(c) == LinphoneCallStreamsRunning) {
        linphone_call_pause(c);
    }
}
//被截断状态结束
- (void)endInterruption {
    NSLog(@"Sound interruption ended!");
}
- (void)enableProxyPublish:(BOOL)enabled {
    if (linphone_core_get_global_state(LC) != LinphoneGlobalOn || !linphone_core_get_default_friend_list(LC)) {
        NSLog(@"Not changing presence configuration because linphone core not ready yet");
        return;
    }
    
    if ([self lpConfigBoolForKey:@"publish_presence"]) {
        // set present to "tv", because "available" does not work yet
        if (enabled) {
            linphone_core_set_presence_model(
                                             LC, linphone_core_create_presence_model_with_activity(LC, LinphonePresenceActivityTV, NULL));
        }
        
        const MSList *proxies = linphone_core_get_proxy_config_list(LC);
        while (proxies) {
            LinphoneProxyConfig *cfg = proxies->data;
            linphone_proxy_config_edit(cfg);
            linphone_proxy_config_enable_publish(cfg, enabled);
            linphone_proxy_config_done(cfg);
            proxies = proxies->next;
        }
        // force registration update first, then update friend list subscription
        linphone_core_iterate(theLinphoneCore);
    }
    
    linphone_friend_list_enable_subscriptions(linphone_core_get_default_friend_list(LC),
                                              enabled &&
                                              [AXLinphoneManager.instance lpConfigBoolForKey:@"use_rls_presence"]);
}



- (void)setupGSMInteraction {
    
    [self removeCTCallCenterCb];
    mCallCenter = [[CTCallCenter alloc] init];
    NSLog(@"Adding CT call center listener [%p]", mCallCenter);
    __block __weak AXLinphoneManager *weakSelf = self;
    __block __weak CTCallCenter *weakCCenter = mCallCenter;
    mCallCenter.callEventHandler = ^(CTCall *call) {
        // post on main thread
        [weakSelf performSelectorOnMainThread:@selector(handleGSMCallInteration:)
                                   withObject:weakCCenter
                                waitUntilDone:YES];
    };
}

- (NSString *)contactFilter {
    NSString *filter = @"*";
    if ([self lpConfigBoolForKey:@"contact_filter_on_default_domain"]) {
        LinphoneProxyConfig *proxy_cfg = linphone_core_get_default_proxy_config(theLinphoneCore);
        if (proxy_cfg && linphone_proxy_config_get_addr(proxy_cfg)) {
            return [NSString stringWithCString:linphone_proxy_config_get_domain(proxy_cfg)
                                      encoding:[NSString defaultCStringEncoding]];
        }
    }
    return filter;
}
#pragma mark- 被电话中断了

- (void)handleGSMCallInteration:(id)cCenter {
    if (floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
        CTCallCenter *ct = (CTCallCenter *)cCenter;
        // pause current call, if any
        LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
        if ([ct currentCalls] != nil) {
            if (call) {
                NSLog(@"Pausing SIP call because GSM call");
                linphone_call_pause(call);
                [self startCallPausedLongRunningTask];
            } else if (linphone_core_is_in_conference(theLinphoneCore)) {
                NSLog(@"Leaving conference call because GSM call");
                linphone_core_leave_conference(theLinphoneCore);
                [self startCallPausedLongRunningTask];
            }
        } // else nop, keep call in paused state
    }
}
- (void)startCallPausedLongRunningTask {
    
    pausedCallBgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        NSLog(@"Call cannot be paused any more, too late");
        [[UIApplication sharedApplication] endBackgroundTask:self->pausedCallBgTask];
    }];
    NSLog(@"Long running task started, remaining [%g s] because at least one call is paused",
         [[UIApplication sharedApplication] backgroundTimeRemaining]);
}
#pragma mark - GSM management
- (void)renameDefaultSettings {
    // rename .linphonerc to linphonerc to ease debugging: when downloading
    // containers from MacOSX, Finder do not display hidden files leading
    // to useless painful operations to display the .linphonerc file
    NSString *src = [AXLinphoneManager documentFile:@".linphonerc"];
    NSString *dst = [AXLinphoneManager documentFile:@"linphonerc"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *fileError = nil;
    if ([fileManager fileExistsAtPath:src]) {
        if ([fileManager fileExistsAtPath:dst]) {
            [fileManager removeItemAtPath:src error:&fileError];
            NSLog(@"%@ already exists, simply removing %@ %@", dst, src,
                 fileError ? fileError.localizedDescription : @"successfully");
        } else {
            [fileManager moveItemAtPath:src toPath:dst error:&fileError];
            NSLog(@"%@ moving to %@ %@", dst, src, fileError ? fileError.localizedDescription : @"successfully");
        }
    }
}

// ugly hack to export symbol from liblinphone so that they are available for the linphoneTests target
// linphoneTests target do not link with liblinphone but instead dynamically link with ourself which is
// statically linked with liblinphone, so we must have exported required symbols from the library to
// have them available in linphoneTests
// DO NOT INVOKE THIS METHOD

- (void)exportSymbolsForUITests {
    linphone_address_set_header(NULL, NULL, NULL);
}

@end



#pragma mark - -------categary
@implementation NSString (md5)

- (BOOL)containsSubstring:(NSString *)str {
    if (UIDevice.currentDevice.systemVersion.doubleValue >= 8.0) {
#pragma deploymate push "ignored-api-availability"
        return [self containsString:str];
#pragma deploymate pop
    }
    return ([self rangeOfString:str].location != NSNotFound);
}
@end
