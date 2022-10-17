//
//  AXLinphoneConfig.m
//  AXLinphone
//
//  Created by Liu Chuanyong on 2022/10/14.
//

#import "AXLinphoneConfig.h"
#import "AXLinphoneManager.h"

static AXLinphoneConfig *linphoneCfg = nil;

@implementation AXLinphoneConfig

+ (AXLinphoneConfig *)instance
{
    @synchronized(self) {
        if (linphoneCfg == nil) {
            linphoneCfg = [[AXLinphoneConfig alloc] init];
        }
    }
    return linphoneCfg;
}

// MARK: - 注册
#pragma mark - 注册
- (void)registeByUserName:(NSString *)userName pwd:(NSString *)pwd domain:(NSString *)domain tramsport:(NSString *)transport{
    
    //设置超时
    linphone_core_set_inc_timeout(LC, 60);
    
    //创建配置表
    LinphoneProxyConfig *proxyCfg = linphone_core_create_proxy_config(LC);
   
    //初始化电话号码
    linphone_proxy_config_normalize_phone_number(proxyCfg,userName.UTF8String);

    // 创建地址
    NSString *address = [NSString stringWithFormat:@"sip:%@@%@",userName,domain];//如:sip:123456@sip.com
    LinphoneAddress *identify = linphone_address_new(address.UTF8String);

    linphone_address_set_username(identify, userName.UTF8String);
    linphone_address_set_port(identify, linphone_address_get_port(identify));
    linphone_address_set_domain(identify, linphone_address_get_domain(identify));
    linphone_proxy_config_set_identity_address(proxyCfg, identify);
    linphone_proxy_config_set_routes(proxyCfg, linphone_core_get_proxy_config_list(LC));
    
    // 设置一个SIP路线  外呼必经之路
    linphone_proxy_config_set_server_addr(
                                          proxyCfg,
                                          [NSString stringWithFormat:@"%s;transport=%s", domain.UTF8String, transport.lowercaseString.UTF8String]
                                          .UTF8String);
    
    linphone_proxy_config_enable_register(proxyCfg, TRUE);
    
    //注册
    linphone_proxy_config_enable_register(proxyCfg, 1);
        
    // 添加到配置表,添加到linphone_core
    linphone_core_add_proxy_config(LC, proxyCfg);
    
    // 设置成默认配置表
    linphone_core_set_default_proxy_config(LC, proxyCfg);
    // 设置音频编码格式
    [self synchronizeCodecs:linphone_core_get_audio_payload_types(LC)];
}
#pragma mark - 设置音频编码格式
- (void)synchronizeCodecs:(const MSList *)codecs {
    
    LinphonePayloadType *pt;
    const MSList *elem;
    
    for (elem = codecs; elem != NULL; elem = elem->next) {
        pt = (LinphonePayloadType *)elem->data;
        linphone_payload_type_enable(pt, YES);
    }
}

#pragma mark - 拨打电话
- (void)callPhoneWithPhoneNumber:(NSString *)phone
{
    LinphoneProxyConfig *cfg = linphone_core_get_default_proxy_config(LC);
    if (!cfg) {
        return;
    }
    LinphoneAddress *addr = [AXLinphoneManager.instance normalizeSipOrPhoneAddress:phone];
    linphone_core_enable_video_display(LC,NO);

    [AXLinphoneManager.instance call:addr];
    if (addr) {
        linphone_address_unref(addr);
    }
    
}

- (void)acceptCall
{
    LinphoneCall *call = linphone_core_get_current_call(LC);
    if (call) {
        [[AXLinphoneManager instance] acceptCall:call];
    }
}

#pragma mark - 清除配置表
- (void)clearProxyConfig {
    
    linphone_core_clear_proxy_config([AXLinphoneManager getLc]);
    linphone_core_clear_all_auth_info([AXLinphoneManager getLc]);
}

@end
