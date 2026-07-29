//
//  KeyChain.m
//  Fire
//
//  Created by Colter Reed on Thu Jan 24 2002.
//  Copyright (c) 2002 Colter Reed. All rights reserved.
//  Released under GPL.  You know how to get a copy.
//

#import "KeyChain.h"
#import "Security/Security.h"

static KeyChain* defaultKeyChain = nil;

@interface KeyChain (KeyChainPrivate)

- (NSMutableDictionary *)_queryForService:(NSString *)service account:(NSString*)account;

@end

@implementation KeyChain

+ (KeyChain*) defaultKeyChain {
    if (defaultKeyChain == nil)
        defaultKeyChain = [[self alloc] init];
    return defaultKeyChain;
}

- (BOOL)setGenericPassword:(NSString*)password forService:(NSString *)service account:(NSString*)account
{
    OSStatus ret;

    if ([service length] == 0 || [account length] == 0) {
        return NO;
    }

    if (!password || [password length] == 0) {
        [self removeGenericPasswordForService:service account:account];
        return TRUE;
    }

    NSDictionary *query = [self _queryForService:service account:account];
    NSDictionary *attributesToUpdate =
        [NSDictionary dictionaryWithObject:[password dataUsingEncoding:NSUTF8StringEncoding]
                                    forKey:(id)kSecValueData];

    /* Update an existing item if there is one, mirroring what the old
     * SecKeychainItemModifyContent / SecKeychainAddGenericPassword pair did.
     * Doing it in this order avoids leaving a duplicate behind. */
    ret = SecItemUpdate((CFDictionaryRef)query, (CFDictionaryRef)attributesToUpdate);

    if (ret == errSecItemNotFound) {
        NSMutableDictionary *newItem = [[query mutableCopy] autorelease];
        [newItem addEntriesFromDictionary:attributesToUpdate];
        ret = SecItemAdd((CFDictionaryRef)newItem, NULL);
    }

    if (ret)
        NSLog(@"Couldn't save to keychain: %d", (int)ret);
    return ret == errSecSuccess;
}

- (NSString*)genericPasswordForService:(NSString *)service account:(NSString*)account
{
    if ([service length] == 0 || [account length] == 0) {
        return @"";
    }

    NSMutableDictionary *query = [self _queryForService:service account:account];
    [query setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnData];
    [query setObject:(id)kSecMatchLimitOne forKey:(id)kSecMatchLimit];

    CFDataRef passwordData = NULL;
    OSStatus ret = SecItemCopyMatching((CFDictionaryRef)query,
                                       (CFTypeRef *)&passwordData);

    if (ret != errSecSuccess || passwordData == NULL)
        return @"";

    /* SecItemCopyMatching hands back a retained copy, unlike the old API's
     * pointer into keychain-owned storage that SecKeychainItemFreeContent
     * released. */
    NSString *string = [[NSString alloc] initWithData:(NSData *)passwordData
                                             encoding:NSUTF8StringEncoding];
    CFRelease(passwordData);

    return string ? [string autorelease] : @"";
}

- (void)removeGenericPasswordForService:(NSString *)service account:(NSString*)account
{
    if ([service length] == 0 || [account length] == 0) {
        return;
    }

    OSStatus ret = SecItemDelete((CFDictionaryRef)[self _queryForService:service
                                                                 account:account]);

    /* Deleting something that is not there matches the old behaviour, which
     * simply skipped the delete when no item reference came back. */
    if (ret != errSecSuccess && ret != errSecItemNotFound)
        NSLog(@"Couldn't remove keychain item: %d", (int)ret);
}

@end

@implementation KeyChain (KeyChainPrivate)

/* The attributes identifying one of our passwords. These are the same service
 * and account that SecKeychainAddGenericPassword recorded, so items saved by
 * earlier versions are found unchanged. */
- (NSMutableDictionary *)_queryForService:(NSString *)service account:(NSString*)account
{
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:
                (id)kSecClassGenericPassword,   (id)kSecClass,
                service,                        (id)kSecAttrService,
                account,                        (id)kSecAttrAccount,
                nil];
}

@end
