//
//  NSURLRequest+CURLHandle.m
//
//  Created by Dan Wood <dwood@karelia.com> on Fri Jun 22 2001.
//  This is in the public domain, but please report any improvements back to the author.

#import "NSURLRequest+CURLHandle.h"

@implementation NSURLRequest (CURLOptionsFTP)

- (curl_usessl)curl_desiredSSLLevel;
{
    return (curl_usessl)[[NSURLProtocol propertyForKey:@"curl_desiredSSLLevel" inRequest:self] longValue];
}

- (BOOL)curl_shouldVerifySSLCertificate;
{
    NSNumber *result = [NSURLProtocol propertyForKey:@"curl_shouldVerifySSLCertificate" inRequest:self];
    return (result ? [result boolValue] : YES);
}

- (NSArray *)curl_postTransferCommands;
{
    return [NSURLProtocol propertyForKey:@"curl_postTransferCommands" inRequest:self];
}

- (NSUInteger)curl_createIntermediateDirectories;
{
    return [[NSURLProtocol propertyForKey:@"curl_createIntermediateDirectories" inRequest:self] unsignedIntegerValue];
}

@end

@implementation NSMutableURLRequest (CURLOptionsFTP)

- (void)curl_setDesiredSSLLevel:(curl_usessl)level;
{
    [NSURLProtocol setProperty:[NSNumber numberWithLong:level] forKey:@"curl_desiredSSLLevel" inRequest:self];
}

- (void)curl_setShouldVerifySSLCertificate:(BOOL)verify;
{
    [NSURLProtocol setProperty:[NSNumber numberWithBool:verify] forKey:@"curl_shouldVerifySSLCertificate" inRequest:self];
}

- (void)curl_setPostTransferCommands:(NSArray *)commands;
{
    if (commands)
    {
        commands = [commands copy];
        [NSURLProtocol setProperty:commands forKey:@"curl_postTransferCommands" inRequest:self];
        [commands release];
    }
    else
    {
        [NSURLProtocol removePropertyForKey:@"curl_postTransferCommands" inRequest:self];
    }
}

- (void)curl_setCreateIntermediateDirectories:(NSUInteger)value;
{
    [NSURLProtocol setProperty:[NSNumber numberWithUnsignedInteger:value] forKey:@"curl_createIntermediateDirectories" inRequest:self];
}

@end
