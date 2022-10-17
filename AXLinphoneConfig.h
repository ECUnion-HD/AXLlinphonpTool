//
//  AXLinphoneConfig.h
//  AXLinphone
//
//  Created by Liu Chuanyong on 2022/10/14.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AXLinphoneConfig : NSObject

+ (AXLinphoneConfig *)instance;

- (void)registeByUserName:(NSString *)userName pwd:(NSString *)pwd domain:(NSString *)domain tramsport:(NSString *)transport;

- (void)callPhoneWithPhoneNumber:(NSString *)phone;

- (void)acceptCall;

@end

NS_ASSUME_NONNULL_END
