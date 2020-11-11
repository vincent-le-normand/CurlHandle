//
//  CURLTransfer.m
//  CURLHandle
//
//  Created by Dan Wood <dwood@karelia.com> on Fri Jun 22 2001.
//  Copyright (c) 2013 Karelia Software. All rights reserved.
//

#import "CURLTransfer.h"
#import "CURLTransfer+MultiSupport.h"
#import "CURLTransfer+TestingSupport.h"

#import "CURLList.h"
#import "CURLTransferStack.h"
#import "CURLRequest.h"
#import "CURLResponse.h"

#import "CK2SSHCredential.h"

#include <SystemConfiguration/SystemConfiguration.h>

#pragma mark - Constants

NSString * const CURLcodeErrorDomain = @"se.haxx.curl.libcurl.CURLcode";
NSString * const CURLMcodeErrorDomain = @"se.haxx.curl.libcurl.CURLMcode";
NSString * const CURLSHcodeErrorDomain = @"se.haxx.curl.libcurl.CURLSHcode";

NSString *const kInfoNames[] =
{
    @"DEBUG",
    @"HEADER_IN",
    @"HEADER_OUT",
    @"DATA_IN",
    @"DATA_OUT",
    @"SSL_DATA_IN",
    @"SSL_DATA_OUT",
    @"END"
};

#if !defined (MAC_OS_X_VERSION_10_7)
#define MAC_OS_X_VERSION_10_7 (MAC_OS_X_VERSION_MAX_ALLOWED + 1)
#endif

#if !defined (__IPHONE_5_0)
#define __IPHONE_5_0 (__IPHONE_OS_VERSION_MAX_ALLOWED + 1)
#endif

#pragma mark - Globals

BOOL				sAllowsProxy = YES;		// by default, allow proxy to be used./
SCDynamicStoreRef	sSCDSRef = NULL;
NSString			*sProxyUserIDAndPassword = nil;

#pragma mark - Callback Prototypes

int curlSocketOptFunction(CURLTransfer *self, curl_socket_t curlfd, curlsocktype purpose);
static size_t curlBodyFunction(void *ptr, size_t size, size_t nmemb, CURLTransfer *self);
static size_t curlHeaderFunction(void *ptr, size_t size, size_t nmemb, CURLTransfer *self);
static size_t curlReadFunction(void *ptr, size_t size, size_t nmemb, CURLTransfer *transfer);
static int curlDebugFunction(CURL *mCURL, curl_infotype infoType, char *info, size_t infoLength, CURLTransfer *transfer);

static int curlKnownHostsFunction(CURL *easy,     /* easy handle */
                                  const struct curl_khkey *knownkey, /* known */
                                  const struct curl_khkey *foundkey, /* found */
                                  enum curl_khmatch, /* libcurl's view on the keys */
                                  CURLTransfer *self); /* custom pointer passed from app */

#pragma mark - Private API

@interface CURLTransfer()

- (size_t) curlReceiveDataFrom:(void *)inPtr size:(size_t)inSize number:(size_t)inNumber isHeader:(BOOL)header;
- (size_t) curlSendDataTo:(void *)inPtr size:(size_t)inSize number:(size_t)inNumber;

@property (strong, nonatomic) NSMutableArray* lists;
@property (strong, nonatomic, readonly) CURLTransferStack* stack;

@end


@implementation CURLTransfer

@synthesize originalRequest = _request;
@synthesize error = _error;
@synthesize lists = _lists;
@synthesize stack = _stack;


/*"	CURLTransfer is a wrapper around a CURL.
	This is in the public domain, but please report any improvements back to the author
	(dwood_karelia_com).
	Be sure to be familiar with CURL and how it works; see http://curl.haxx.se/

	The idea is to have it handle http and possibly other schemes too.  At this time
	we don't support writing data (via HTTP PUT) and special situations such as HTTPS and
	firewall proxies haven't been tried out yet.
	
	This class maintains only basic functionality, any "bells and whistles" should be
	defined in a category to keep this file as simple as possible.

	Each instance is created to be associated with a URL.  But we can change the URL and
	use the previous connection, as the CURL documentation says.

	%{#Note: Comments in methods with this formatting indicate quotes from the headers and
	documentation for #NSURLHandle and are provided to help prove "correctness."  Some
	come from an another document -- perhaps an earlier version of the documentation or release notes,
	but I can't find the original source. These are marked "(?source)"}

"*/

// -----------------------------------------------------------------------------
#pragma mark ----- ADDITIONAL CURLHANDLE INTERFACES
// -----------------------------------------------------------------------------

/*" Initialize CURLTransfer and the underlying CURL.  This can be invoked when the program is launched or before any loading is needed.
"*/

+ (void)initialize
{
	CURLcode rc = curl_global_init(CURL_GLOBAL_ALL);
	if (rc != CURLE_OK)
	{
		NSLog(@"Didn't curl_global_init, result = %d",rc);
	}
	
	// Now initialize System Config. I have no idea why this signature; it's just what was in tester app
	sSCDSRef = SCDynamicStoreCreate(NULL,CFSTR("XxXx"),NULL, NULL);
	if ( sSCDSRef == NULL )
	{
		NSLog(@"Didn't get SCDynamicStoreRef");
	}
}

/*"	Set a proxy user id and password, used by all CURLTransfer. This should be done before any transfers are made."*/

+ (void) setProxyUserIDAndPassword:(NSString *)inString
{
	[inString retain];
	[sProxyUserIDAndPassword release];
	sProxyUserIDAndPassword = inString;
}

/*"	Set whether proxies are allowed or not.  Default value is YES.  If no, the proxy settings
	are ignored.
"*/
+ (void) setAllowsProxy:(BOOL) inBool
{
	sAllowsProxy = inBool;
}


/*"	Return the CURL object assocated with this, so categories can have other methods
	that do curl-specific stuff like #curl_easy_getinfo
"*/

- (CURL *) curlHandle
{
	return _handle;
}

+ (NSString *) curlVersion
{
	return [NSString stringWithCString: curl_version() encoding:NSASCIIStringEncoding];
}


// -----------------------------------------------------------------------------
#pragma mark Lifecycle
// -----------------------------------------------------------------------------

- (id)initWithRequest:(NSURLRequest *)request credential:(NSURLCredential *)credential delegate:(id <CURLTransferDelegate>)delegate delegateQueue:(NSOperationQueue *)queue stack:(CURLTransferStack *)stack {
    NSParameterAssert(request);
    NSParameterAssert(stack);
    
    if (self = [self init])
    {
        _state = CURLTransferStateSuspended;
        _delegate = [delegate retain];
        _stack = [stack retain];
        
        // Turn automatic redirects off by default, so can properly report them to delegate
        curl_easy_setopt([self curlHandle], CURLOPT_FOLLOWLOCATION, NO);
                
        CURLcode code = [self setupRequest:request credential:credential];
        if (code != CURLE_OK) {
            [self completeWithCode:code];
        }
    }
    
    return self;
}


- (void) dealloc
{
    [self cleanupIncludingHandle:YES];

    [_stack release];
    [_delegate release];
    [_request release];
    [_error release];
	[_headerBuffer release];
	[_proxies release];
    [_uploadStream release];

    CURLHandleLogDetail(@"dealloced");
    
	[super dealloc];
}

/*" %{Initializes a newly created URL transfer with the request.}

"*/

- (id)init
{
	if ((self = [super init]) != nil)
	{
		_handle = curl_easy_init();
		if (_handle)
		{
            _errorBuffer[0] = 0;	// initialize the error buffer to empty
            _headerBuffer = [[NSMutableData alloc] init];
        }
        else
        {
            [self dealloc];
			self = nil;
		}
	}

	return self;
}


#pragma mark - Setup

#define RETURN_IF_FAILED(value) if ((code = (value)) != CURLE_OK) return code;

- (CURLcode)setOption:(CURLoption)option data:(CURLoption)data function:(void*)function
{
    CURLcode code = curl_easy_setopt(_handle, option, function);
    if (code == CURLE_OK)
    {
        code = (curl_easy_setopt(_handle, data, self));
    }

    return code;
}

- (CURLcode)setOption:(CURLoption)option string:(NSString*)string
{
    CURLcode code = curl_easy_setopt(_handle, option, [string UTF8String]);

    return code;
}

- (CURLcode)setOption:(CURLoption)option number:(NSNumber*)number
{
    CURLcode code = CURLE_OK;
    if (number)
    {
        code = curl_easy_setopt(_handle, option, [number longValue]);
    }

    return code;
}

- (CURLcode)setOption:(CURLoption)option url:(NSURL*)url justPath:(BOOL)justPath
{
    NSString* string = justPath ? [url path] : [url absoluteString];
    CURLcode code = curl_easy_setopt(_handle, option, [string UTF8String]);

    return code;
}

- (CURLcode)setOption:(CURLoption)option withContentsOfArray:(NSArray*)array
{
    CURLcode result = CURLE_OK;
    if ([array count])
    {
        // make a curl list with the values in the array
        CURLList* values = [CURLList listWithArray:array];
        result = curl_easy_setopt(_handle, option, values.list);

        // hang on to the list until the handle is done
        if (!self.lists)
            self.lists = [NSMutableArray arrayWithObject:values];
        else
            [self.lists addObject:values];
    }

    return result;
}

- (CURLcode)setupProxyOptionsForRequest:(NSURLRequest *)request
{
    CURLcode code = CURLE_OK;

    NSString *proxyHost = nil;
    NSNumber *proxyPort = nil;
    NSString *scheme = [[[request URL] scheme] lowercaseString];

    // Allocate and keep the proxy dictionary
    if (nil == _proxies)
    {
        _proxies = (NSDictionary *) SCDynamicStoreCopyProxies(sSCDSRef);
    }


    if (_proxies
        && [scheme isEqualToString:@"http"]
        && [[_proxies objectForKey:(NSString *)kSCPropNetProxiesHTTPEnable] boolValue] )
    {
        proxyHost = (NSString *) [_proxies objectForKey:(NSString *)kSCPropNetProxiesHTTPProxy];
        proxyPort = (NSNumber *)[_proxies objectForKey:(NSString *)kSCPropNetProxiesHTTPPort];
    }
    if (_proxies
        && [scheme isEqualToString:@"https"]
        && [[_proxies objectForKey:(NSString *)kSCPropNetProxiesHTTPSEnable] boolValue] )
    {
        proxyHost = (NSString *) [_proxies objectForKey:(NSString *)kSCPropNetProxiesHTTPSProxy];
        proxyPort = (NSNumber *)[_proxies objectForKey:(NSString *)kSCPropNetProxiesHTTPSPort];
    }

    /*	Disable FTP proxy for now as it seems to be messing up for at least one Karelia customer
    if (_proxies
        && [scheme isEqualToString:@"ftp"]
        && [[_proxies objectForKey:(NSString *)kSCPropNetProxiesFTPEnable] boolValue] )
    {
        proxyHost = (NSString *) [_proxies objectForKey:(NSString *)kSCPropNetProxiesFTPProxy];
        proxyPort = (NSNumber *)[_proxies objectForKey:(NSString *)kSCPropNetProxiesFTPPort];
    }*/

    if (proxyHost && proxyPort)
    {
	    NSLog(@"CURLTransfer: Using proxy %@:%@", proxyHost, proxyPort);
	    
        RETURN_IF_FAILED([self setOption:CURLOPT_PROXY string:proxyHost]);
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_PROXYPORT, [proxyPort longValue]));

        // Now, provide a user/password if one is globally set.
        if (nil != sProxyUserIDAndPassword)
        {
            RETURN_IF_FAILED([self setOption:CURLOPT_PROXYUSERPWD string:sProxyUserIDAndPassword]);
        }
    }

    return code;
}

- (CURLcode)setupOptionsForCredential:(NSURLCredential*)credential
{
    CURLcode code;

    NSString *username = [credential user];
    NSString *password = [credential password];
    NSURL* privateKey = [credential ck2_privateKeyURL];

    RETURN_IF_FAILED([self setOption:CURLOPT_USERNAME string:username]);
    RETURN_IF_FAILED([self setOption:CURLOPT_SSH_PRIVATE_KEYFILE url:privateKey justPath:YES]);
    
    // libcurl treats empty string as signal to use no public key file
    // Passing nil instead sets it back to the default $HOME/.ssh/id_dsa.pub
    NSString *publicKey = [credential.ck2_publicKeyURL path];
    RETURN_IF_FAILED([self setOption:CURLOPT_SSH_PUBLIC_KEYFILE string:(publicKey ? publicKey : @"")]);
    
    if (privateKey)
    {
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_SSH_AUTH_TYPES, CURLSSH_AUTH_PUBLICKEY));
        RETURN_IF_FAILED([self setOption:CURLOPT_KEYPASSWD string:password]);
    }
    else if (credential.ck2_isPublicKeyCredential)
    {
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_SSH_AUTH_TYPES, (1<<4)));    // want to use CURLSSH_AUTH_AGENT, but can't get Xcode to recognise the header
    }
    else
    {
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_SSH_AUTH_TYPES, CURLSSH_AUTH_PASSWORD|CURLSSH_AUTH_KEYBOARD));
        RETURN_IF_FAILED([self setOption:CURLOPT_PASSWORD string:password]);
    }

    return code;
}

- (CURLcode)setupHeadersForRequest:(NSURLRequest*)request
{
    CURLcode code = CURLE_OK;

    NSDictionary* allFields = [request allHTTPHeaderFields];
    NSMutableArray* headers = [NSMutableArray arrayWithCapacity:[allFields count]];
    for (NSString *field in allFields)
    {
        NSString *value = [request valueForHTTPHeaderField:field];

        // Range requests are a special case that should inform Curl directly
        if ([field caseInsensitiveCompare:@"Range"] == NSOrderedSame)
        {
            NSRange bytesPrefixRange = [value rangeOfString:@"bytes=" options:NSAnchoredSearch];
            if (bytesPrefixRange.location != NSNotFound)
            {
                RETURN_IF_FAILED([self setOption:CURLOPT_RANGE string:[value substringFromIndex:bytesPrefixRange.length]]);
            }
        }

        // Accept-Encoding requests are also special
        else if ([field caseInsensitiveCompare:@"Accept-Encoding"] == NSOrderedSame)
        {
            RETURN_IF_FAILED([self setOption:CURLOPT_ENCODING string:value]);
        }

        else
        {
            NSString *pair = [NSString stringWithFormat:@"%@: %@", field, value];
            [headers addObject:pair];
        }
    }

    RETURN_IF_FAILED([self setOption:CURLOPT_HTTPHEADER withContentsOfArray:headers]);

    return code;
}

- (CURLcode)setupUploadForRequest:(NSURLRequest*)request
{
    CURLcode code = CURLE_OK;
    
    // Set the upload data
    NSData *uploadData = [request HTTPBody];
    if (uploadData)
    {
        _uploadStream = [[NSInputStream alloc] initWithData:uploadData];
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_INFILESIZE, [uploadData length]));
    }
    else
    {
        _uploadStream = [[request HTTPBodyStream] retain];
    }

    if (_uploadStream)
    {
        [_uploadStream open];
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_UPLOAD, 1L));
    }
    else
    {
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_UPLOAD, 0));
    }

    return code;
}

- (CURLcode)setupMethodForRequest:(NSURLRequest *)request
{
    CURLcode code = CURLE_OK;

    NSString *method = [request HTTPMethod];
    if ([method isEqualToString:@"GET"])
    {
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_HTTPGET, 1));
    }
    else if ([method isEqualToString:@"HEAD"])
    {
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_NOBODY, 1));
    }
    else if ([method isEqualToString:@"PUT"])
    {
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_UPLOAD, 1L));
    }
    else if ([method isEqualToString:@"POST"])
    {
        RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_POST, 1));
    }
    else
    {
        RETURN_IF_FAILED([self setOption:CURLOPT_CUSTOMREQUEST string:method]);
    }

    return code;
}

- (CURLcode)setupRequest:(NSURLRequest *)request credential:(NSURLCredential *)credential
{
    NSAssert(_executing == NO, @"CURLTransfer instances may not be accessed on multiple threads at once, or re-entrantly");
    _executing = YES;

    curl_easy_reset([self curlHandle]);

    _request = [request copy];    // assumes caller will have ensured _originalRequest is suitable for overwriting
    [_headerBuffer setLength:0];

    CURLcode code = CURLE_OK;

    // most crucially, the URL...
    RETURN_IF_FAILED([self setOption:CURLOPT_URL url:[request URL] justPath:NO]);

    // misc settings
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_ERRORBUFFER, &_errorBuffer));
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_FOLLOWLOCATION, YES));
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_FAILONERROR, YES));
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_VERBOSE, 1));
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_PRIVATE, self));       // store self in the private data, so that we can turn an easy handle back into a CURLTransfer object
    RETURN_IF_FAILED([self setOption:CURLOPT_SSH_KNOWNHOSTS url:[request curl_SSHKnownHostsFileURL] justPath:YES]);
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_FTP_CREATE_MISSING_DIRS, [request curl_createIntermediateDirectories] ? 2 : 0));
    RETURN_IF_FAILED([self setOption:CURLOPT_NEW_FILE_PERMS number:[request curl_newFilePermissions]]);
    RETURN_IF_FAILED([self setOption:CURLOPT_NEW_DIRECTORY_PERMS number:[request curl_newDirectoryPermissions]]);
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_USE_SSL, (long)[request curl_desiredSSLLevel]));
    //RETURN_IF_FAILED(curl_easy_setopt(_curl, CURLOPT_CERTINFO, 1L);    // isn't supported by Darwin-SSL backend yet
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_SSL_VERIFYPEER, (long)[request curl_shouldVerifySSLCertificate]));
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_SSL_VERIFYHOST, (long)(request.curl_shouldVerifySSLHost ? 2 : 0)));
    RETURN_IF_FAILED(curl_easy_setopt(_handle, CURLOPT_FTP_USE_EPSV, 0));     // Disable EPSV for FTP transfers. I've found that some servers claim to support EPSV but take a very long time to respond to it, if at all, often causing the overall connection to fail. Note IPv6 connections will ignore this and use EPSV anyway

    // functions
    RETURN_IF_FAILED([self setOption:CURLOPT_SOCKOPTFUNCTION data:CURLOPT_SOCKOPTDATA function:curlSocketOptFunction]);
    RETURN_IF_FAILED([self setOption:CURLOPT_WRITEFUNCTION data:CURLOPT_WRITEDATA function:curlBodyFunction]);
    RETURN_IF_FAILED([self setOption:CURLOPT_HEADERFUNCTION data:CURLOPT_HEADERDATA function:curlHeaderFunction]);
    RETURN_IF_FAILED([self setOption:CURLOPT_READFUNCTION data:CURLOPT_READDATA function:curlReadFunction]);
    RETURN_IF_FAILED([self setOption:CURLOPT_DEBUGFUNCTION data:CURLOPT_DEBUGDATA function:curlDebugFunction]);
    RETURN_IF_FAILED([self setOption:CURLOPT_SSH_KEYFUNCTION data:CURLOPT_SSH_KEYDATA function:curlKnownHostsFunction]);

    if (credential)
    {
        RETURN_IF_FAILED([self setupOptionsForCredential:credential]);
    }

    if (sAllowsProxy)	// normally this is YES.
    {
        RETURN_IF_FAILED([self setupProxyOptionsForRequest:request]);
    }

    RETURN_IF_FAILED([self setupMethodForRequest:request]);
    RETURN_IF_FAILED([self setupHeadersForRequest:request]);
    RETURN_IF_FAILED([self setupUploadForRequest:request]);
    RETURN_IF_FAILED([self setOption:CURLOPT_PREQUOTE withContentsOfArray:[request curl_preTransferCommands]]);
    RETURN_IF_FAILED([self setOption:CURLOPT_POSTQUOTE withContentsOfArray:[request curl_postTransferCommands]]);

    return CURLE_OK;
}

#pragma mark - Cleanup

- (void)cleanupIncludingHandle:(BOOL)cleanupHandleToo;
{
    CURLHandleLogDetail(@"cleanup");

    // curl_easy_cleanup() can sometimes call into our callback funcs - need to guard against this by setting _delegate to nil here
    // (the curl_easy_reset below should fix this anyway by unregistering the callbacks, but let's be paranoid...)
    [_delegate release]; _delegate = nil;

    if (_handle)
    {
        // NB this is a workaround to fix a bug where an easy handle that was attached to a multi
        // can get accessed when calling curl_multi_cleanup, even though the easy handle has been removed from the multi, and cleaned up itself!
        // see http://curl.haxx.se/mail/lib-2009-10/0222.html
        //
        // Additionally, it ought to be done anyway since we're clearing away the curl_slists that the handle currently references
        curl_easy_reset(_handle);
        
        if (cleanupHandleToo)
        {
            curl_easy_cleanup(_handle);
            _handle = NULL;
        }
    }
    
    if (_uploadStream)
    {
        [_uploadStream close];
    }

    [self.lists removeAllObjects];

    _executing = NO;
}

#pragma mark State

@synthesize state = _state;

/**
 The core of our state machine.
 
 @param state The state beign changed to. We ignore changes which have no effect, or which would
 send the overall state backwards.
 
 @param error Only to be supplied when changing to completed state. If already completed, this also
 goes ignored; we go by the error value passed in when first changed to completed state.
 
 It might seem weird to have possibility of completion happening more than once, but this can happen
 when reading body data fails. There'll be one completion event with the error from the stream, and
 then another error from libcurl that the transfer was aborted. Cancellation can also have a bit of
 a race condition where the transfer wants to cancel at the same time as it naturally finishes/fails.
 
 */
- (void)setState:(CURLTransferState)state error:(NSError *)error {
    
    if (state != CURLTransferStateCompleted) NSParameterAssert(!error);
    
    // Clients can cancel on any thread of their choosing, so we need a serialization mechanism.
    // The stack's queue might be tied up waiting on libcurl, and really we want state changes to be
    // synchronous, so let's go with a simple synchronization. Maybe longterm a spinlock or similar
    // is better
    @synchronized(self) {
        
        // Ignore attempts to send state backwards, or if already at thate state
        if (_state >= state) {
            return;
        }
        
        // Post KVO notifications around overall change
        if (error) [self willChangeValueForKey:@"error"];
        [self willChangeValueForKey:@"state"];
        {{
            _state = state;
            
            NSAssert(_error == nil, @"Error shouldn't have been filled in yet");
            _error = error;
            
            switch (state) {
                case CURLTransferStateSuspended:
                    [NSException raise:NSInvalidArgumentException format:@"We don't support suspending transfers at the moment"];
                    
                case CURLTransferStateRunning:
                    _state = CURLTransferStateRunning;
                    [_stack beginTransfer:self];
                    break;
                    
                case CURLTransferStateCanceling: {
                    
                    CURLHandleLog(@"cancelled");
                    
                    CURLTransferStack *stack = self.stack;
                    if (stack)
                    {
                        // Bounce over to doing suspension in background as libcurl sometimes blocks for a long time on that
                        [stack suspendTransfer:self completionHandler:^{
                            
                            // If the transfer happened to already complete at the same time, this
                            // second completion attempt will go cheerfully ignored.
                            [self completeWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
                        }];
                    }
                    else    // synchronous usage
                    {
                        _state = CURLTransferStateCanceling;
                    }
                    
                    break;
                }
                case CURLTransferStateCompleted: {
                    
                    [self notifyDelegateOfResponseIfNeeded];
                    
                    NSError *error = self.error;
                    if (error) {
                        CURLHandleLog(@"failed with error %@", error);
                    }
                    else {
                        CURLHandleLog(@"finished");
                    }
                    
                    // We run cleanup after delegate messages are all delivered if possible
                    if (![self tryToPerformSelectorOnDelegate:@selector(transfer:didCompleteWithError:) usingBlock:^{
                        
                        [self.delegate transfer:self didCompleteWithError:error];
                        [self cleanupIncludingHandle:(self.stack != nil)];
                    }])
                    {
                        [self cleanupIncludingHandle:(self.stack != nil)];
                    }
                    break;
                }
                default:
                    [NSException raise:NSInvalidArgumentException format:@"Unrecognised state: %@", @(state)];
            }
        }}
        [self didChangeValueForKey:@"state"];
        if (error) [self didChangeValueForKey:@"state"];
    }
}

- (void)cancel {
    [self setState:CURLTransferStateCanceling error:nil];
}

- (void)completeWithCode:(CURLcode)code;
{
    CURLHandleLog(@"completed with %@ code %d", isMultiCode ? @"multi" : @"easy", code);
    
    NSError *error = nil;
    if (code != CURLE_OK)
    {
        error = [self errorForURL:self.originalRequest.URL code:(CURLcode)code];
        NSAssert(error, @"Failed to created error");
    }
    
    [self completeWithError:error];
}

- (void)completeWithError:(NSError *)error {
    [self setState:CURLTransferStateCompleted error:error];
}

- (void)resume {
    [self setState:CURLTransferStateRunning error:nil];
}

#pragma mark Synchronous Loading

- (void)sendSynchronousRequest:(NSURLRequest *)request credential:(NSURLCredential *)credential delegate:(id <CURLTransferDelegate>)delegate;
{
    NSAssert(_delegate == nil, @"CURLTransfer can only service a single request at a time");
    _delegate = [delegate retain];
    
    _state = CURLTransferStateRunning;  // reset after previous transfer
    
    [_request release]; // -setupRequest: will fill it back in
    CURLcode result = [self setupRequest:request credential:credential];
    
    if (result == CURLE_OK)
    {
        result = curl_easy_perform(self.curlHandle);
    }
    
    [self completeWithCode:result];
}

#pragma mark Post-Request Info

- (NSString *)initialFTPPath;
{
    char *entryPath;
    if (curl_easy_getinfo(_handle, CURLINFO_FTP_ENTRY_PATH, &entryPath) != CURLE_OK) return nil;
    
    return (entryPath ? [NSString stringWithUTF8String:entryPath] : nil);
}

- (NSString *)primaryIPAddress;
{
    char *address;
    curl_easy_getinfo(self.curlHandle, CURLINFO_PRIMARY_IP, &address);
    
    return [NSString stringWithCString:address
                              encoding:NSUTF8StringEncoding];  // guessing here!
}

#pragma mark Error Construction

- (NSError*)errorForURL:(NSURL*)url code:(CURLcode)code
{
    NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                     url, NSURLErrorFailingURLErrorKey,
                                     [url absoluteString], NSURLErrorFailingURLStringErrorKey,
                                     [NSString stringWithUTF8String:_errorBuffer], NSLocalizedDescriptionKey,
                                     [NSString stringWithUTF8String:curl_easy_strerror(code)], NSLocalizedFailureReasonErrorKey,
                                     nil];
    
    long responseCode;
    if (curl_easy_getinfo(_handle, CURLINFO_RESPONSE_CODE, &responseCode) == CURLE_OK && responseCode)
    {
        [userInfo setObject:[NSNumber numberWithLong:responseCode] forKey:@(CURLINFO_RESPONSE_CODE).stringValue];
    }
    
    long osErrorNumber = 0;
    if (curl_easy_getinfo(_handle, CURLINFO_OS_ERRNO, &osErrorNumber) == CURLE_OK && osErrorNumber)
    {
        [userInfo setObject:[NSError errorWithDomain:NSPOSIXErrorDomain code:osErrorNumber userInfo:nil]
                     forKey:NSUnderlyingErrorKey];
    }
    
    NSError* result = [NSError errorWithDomain:CURLcodeErrorDomain code:code userInfo:userInfo];
    [userInfo release];
    
    
    if (code == CURLE_PEER_FAILED_VERIFICATION ||   // seen on 10.7
        code == CURLE_SSL_CACERT)                   // seen on 10.9
    {
        // Use Keith's patch to grab SecTrust. Have to hardcode the value for now
        // until I figure out the build search paths properly
        SecTrustRef trust;
        if (curl_easy_getinfo(_handle, /*CURLINFO_SSL_TRUST = */ 0x500000 + 43, &trust) == CURLE_OK && trust)
        {
            NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] initWithDictionary:result.userInfo];
            [userInfo setObject:result forKey:NSUnderlyingErrorKey];
            [userInfo setObject:(id)trust forKey:NSURLErrorFailingURLPeerTrustErrorKey];
            
            result = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorSecureConnectionFailed userInfo:userInfo];
            [userInfo release];
            return result;
        }
        
        struct curl_certinfo *certInfo = NULL;
        if (curl_easy_getinfo(_handle, CURLINFO_CERTINFO, &certInfo) == CURLE_OK)
        {
            // TODO: Extract something interesting from the certificate info. Unfortunately I seem to get back no info!
        }
    }
    
    
    // Try to generate a Cocoa-friendly error on top of the raw libCurl one
    switch (code)
    {
        case CURLE_UNSUPPORTED_PROTOCOL:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorUnsupportedURL underlyingError:result];
            break;
            
        case CURLE_URL_MALFORMAT:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL underlyingError:result];
            break;
            
        case CURLE_COULDNT_RESOLVE_HOST:
        case CURLE_FTP_CANT_GET_HOST:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotFindHost underlyingError:result];
            break;
            
        case CURLE_COULDNT_CONNECT:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost underlyingError:result];
            break;
            
        case CURLE_WRITE_ERROR:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotWriteToFile underlyingError:result];
            break;
            
            //case CURLE_FTP_ACCEPT_TIMEOUT:    seems to have been added in a newer version of Curl than ours
        case CURLE_OPERATION_TIMEDOUT:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut underlyingError:result];
            break;
            
        case CURLE_SSL_CONNECT_ERROR:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorSecureConnectionFailed underlyingError:result];
            break;
            
        case CURLE_TOO_MANY_REDIRECTS:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorHTTPTooManyRedirects underlyingError:result];
            break;
            
        case CURLE_BAD_CONTENT_ENCODING:
            result = [self errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError underlyingError:result];
            break;
            
#if MAC_OS_X_VERSION_10_5 <= MAC_OS_X_VERSION_MAX_ALLOWED || __IPHONE_2_0 <= __IPHONE_OS_VERSION_MAX_ALLOWED
        case CURLE_FILESIZE_EXCEEDED:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorDataLengthExceedsMaximum underlyingError:result];
            break;
#endif
            
#if MAC_OS_X_VERSION_10_7 <= MAC_OS_X_VERSION_MAX_ALLOWED
        case CURLE_SEND_FAIL_REWIND:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorRequestBodyStreamExhausted underlyingError:result];
            break;
#endif
            
        case CURLE_LOGIN_DENIED:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorUserAuthenticationRequired underlyingError:result];
            break;
            
        case CURLE_REMOTE_DISK_FULL:
            result = [self errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError underlyingError:result];
            break;
            
#if MAC_OS_X_VERSION_10_7 <= MAC_OS_X_VERSION_MAX_ALLOWED || __IPHONE_5_0 <= __IPHONE_OS_VERSION_MAX_ALLOWED
        case CURLE_REMOTE_FILE_EXISTS:
            result = [self errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError underlyingError:result];
            break;
#endif
            
        case CURLE_REMOTE_FILE_NOT_FOUND:
            result = [self errorWithDomain:NSURLErrorDomain code:NSURLErrorResourceUnavailable underlyingError:result];
            break;
            
        /*
         CURLE_REMOTE_ACCESS_DENIED would seem to translate to NSURLErrorNoPermissionsToReadFile quite
         well. However, in practice it also happens when an FTP server rejected a CWD command because
         the directory doesn't exist. Seems best to leave it alone
         */
            
        default:
            break;
    }
    
    return result;
}

- (NSError *)errorWithDomain:(NSString *)domain code:(NSInteger)code underlyingError:(NSError *)underlyingError;
{
    NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] initWithDictionary:[underlyingError userInfo]];
    [userInfo setObject:underlyingError forKey:NSUnderlyingErrorKey];
    
    NSError *result = [NSError errorWithDomain:domain code:code userInfo:userInfo];
    [userInfo release];
    return result;
}

#pragma mark - Multi Support

+ (CURLTransferStack*)standaloneMultiForTestPurposes
{
    CURLTransferStack* multi = [[[CURLTransferStack alloc] init] autorelease];
    return multi;
}

+ (void)cleanupStandaloneMulti:(CURLTransferStack*)multi
{
    [multi finishTransfersAndInvalidate];
}

#pragma mark Utilities

- (BOOL)hasCompleted
{
    return _executing == NO;
}

+ (NSString*)nameForType:(curl_infotype)type
{
    return kInfoNames[type];
}

- (NSString*)description
{
    return [NSString stringWithFormat:@"<EASY %p (%p)>", self, self.curlHandle];
}

#pragma mark Delegate

@synthesize delegate = _delegate;

/* Runs the block on our delegate queue.
 * If the delegate doesn't respond, the block is not run/enqueued
 */
- (BOOL)tryToPerformSelectorOnDelegate:(SEL)selector usingBlock:(void (^)(void))block;
{
    if ([self.delegate respondsToSelector:selector])
    {
        if (self.stack.delegateQueue)
        {
            [self.stack.delegateQueue addOperationWithBlock:block];
        }
        else
        {
            block();
        }
        
        return YES;
    }
    else
    {
        return NO;
    }
}

- (void)notifyDelegateOfResponseIfNeeded;
{
    // If a response has been buffered, send that off
    if ([_headerBuffer length])
    {
        NSString *headerString = [[NSString alloc] initWithData:_headerBuffer encoding:NSASCIIStringEncoding];
        [_headerBuffer setLength:0];

        long code;
        if (curl_easy_getinfo(_handle, CURLINFO_RESPONSE_CODE, &code) == CURLE_OK)
        {
            char *urlBuffer;
            if (curl_easy_getinfo(_handle, CURLINFO_EFFECTIVE_URL, &urlBuffer) == CURLE_OK)
            {
                NSString *urlString = [[NSString alloc] initWithUTF8String:urlBuffer];
                if (urlString)
                {
                    NSURL *url = [[NSURL alloc] initWithString:urlString];
                    if (url)
                    {
                        NSURLResponse *response = [CURLResponse responseWithURL:url statusCode:code headerString:headerString];
                        
                        [self tryToPerformSelectorOnDelegate:@selector(transfer:didReceiveResponse:) usingBlock:^{
                            [self.delegate transfer:self didReceiveResponse:response];
                        }];

                        [url release];
                    }

                    [urlString release];
                }

            }
        }
        [headerString release];
    }
}

#pragma mark - Callback Methods

/*"	Continue the writing callback in Objective C; now we have our instance variables.
 "*/

- (size_t) curlReceiveDataFrom:(void *)inPtr size:(size_t)inSize number:(size_t)inNumber isHeader:(BOOL)header;
{
	size_t written = inSize*inNumber;
    CURLHandleLog(@"write %ld at %p", written, inPtr);

	if (self.state < CURLTransferStateCanceling || self.stack)
	{
        NSData *data = [NSData dataWithBytes:inPtr length:written];

		if (header)
		{
            // Delegate might not care about the response
            if ([self.delegate respondsToSelector:@selector(transfer:didReceiveResponse:)])
            {
                [_headerBuffer appendData:data];
            }
		}
		else
		{
            // Once the body starts arriving, we know we have the full header, so can report that
            [self notifyDelegateOfResponseIfNeeded];

            // Report regular body data
            [self tryToPerformSelectorOnDelegate:@selector(transfer:didReceiveData:) usingBlock:^{
                [self.delegate transfer:self didReceiveData:data];
            }];
		}
	}
    else
    {
        // we've been cancelled while running synchronously (or something else is badly wrong)
		written = -1;
	}

	return written;
}

- (size_t) curlSendDataTo:(void *)inPtr size:(size_t)inSize number:(size_t)inNumber;
{
    NSInteger result;

    if (self.state < CURLTransferStateCanceling || self.stack)
    {
        result = [_uploadStream read:inPtr maxLength:inSize * inNumber];
        if (result < 0)
        {
            NSError *error = [_uploadStream streamError];
            [self completeWithError:error];
            
            // Report error to transcript too. This may be unnecessary now; I'm just maintaining the
            // existing setup until I have reason to change it (e.g. turns out there's dupes appearing)
            [self tryToPerformSelectorOnDelegate:@selector(transfer:didReceiveDebugInformation:ofType:) usingBlock:^{
                
               [self.delegate transfer:self
           didReceiveDebugInformation:[NSString stringWithFormat:@"Read failed: %@", [error debugDescription]]
                               ofType:CURLINFO_HEADER_IN];
            }];

            return CURL_READFUNC_ABORT;
        }

        if (result >= 0) [self tryToPerformSelectorOnDelegate:@selector(transfer:willSendBodyDataOfLength:) usingBlock:^{
            
            CURLHandleLog(@"sending %ld bytes (max %ld) from %p", (size_t)result, inSize*inNumber, inPtr);
            [self.delegate transfer:self willSendBodyDataOfLength:result];
            if (_uploadStream.streamStatus == NSStreamStatusAtEnd)
            {
                [self.delegate transfer:self willSendBodyDataOfLength:0];
            }
        }];
    }
    else
    {
        // we've been cancelled while running synchronously (or something else is badly wrong)
        result = CURL_READFUNC_ABORT;
    }

    return result;
}

- (enum curl_khstat)didFindHostFingerprint:(const struct curl_khkey *)foundKey knownFingerprint:(const struct curl_khkey *)knownkey match:(enum curl_khmatch)match;
{
    __block enum curl_khstat result;
    
    if ([self tryToPerformSelectorOnDelegate:@selector(transfer:didFindHostFingerprint:knownFingerprint:match:) usingBlock:^{
        
        result = [self.delegate transfer:self didFindHostFingerprint:foundKey knownFingerprint:knownkey match:match];
    }])
    {
        [self.stack.delegateQueue waitUntilAllOperationsAreFinished]; // ideally ought to wait till just the op finishes
        return result;
    }
    else
    {
        return (match == CURLKHMATCH_OK ? CURLKHSTAT_FINE : CURLKHSTAT_REJECT);
    }
}

@end

#pragma mark - Callback Functions

// We always log out the debug info in DEBUG builds. We also send everything to the delegate.
// In release builds, we just send header related stuff to the delegate.

#if defined(DEBUG) || defined(_DEBUG)
#define LOG_DEBUG 1
#else
#define LOG_DEBUG 0
#endif

int curlDebugFunction(CURL *curl, curl_infotype infoType, char *info, size_t infoLength, CURLTransfer *self)
{
    BOOL delegateResponds = [self.delegate respondsToSelector:@selector(transfer:didReceiveDebugInformation:ofType:)];
    if (delegateResponds || LOG_DEBUG)
    {
        BOOL shouldProcess = LOG_DEBUG || (infoType == CURLINFO_HEADER_IN) || (infoType == CURLINFO_HEADER_OUT);
        if (shouldProcess)
        {
            // the length we're passed seems to be unreliable; we use strnlen to ensure that we never go past the infoLength we were given,
            // but often it seems that the string is *much* shorter
            // Going to start trusting infoLength again after Daniel's patch. Also because strnlen() isn't actually available on 10.6
            //NSUInteger actualLength = strnlen(info, infoLength);

            NSString *string = [[NSString alloc] initWithBytes:info length:infoLength encoding:NSUTF8StringEncoding];
            if (!string)
            {
                // FTP servers are fairly free to use whatever encoding they like. We've run into one that appears to be Hungarian; as far as I can tell ISO Latin 2 is the best compromise for that
                string = [[NSString alloc] initWithBytes:info length:infoLength encoding:NSISOLatin2StringEncoding];
            }

            if (!string)
            {
                // I don't yet know what causes this, but it does happen from time to time. If so, insist that something useful go in the log
                if (infoLength == 0)
                {
                    string = [@"<NULL> debug info" retain];
                }
                else if (infoLength < 100000)
                {
                    string = [[NSString alloc] initWithFormat:@"Invalid debug info: %@", [NSData dataWithBytes:info length:infoLength]];
                }
                else
                {
                    string = [[NSString alloc] initWithFormat:@"Invalid debug info - info length seems to be too big: %ld", infoLength];
                }
            }

            CURLHandleLogDetail(@"%@ - %@", [self.class nameForType:infoType], string);

            [self tryToPerformSelectorOnDelegate:@selector(transfer:didReceiveDebugInformation:ofType:) usingBlock:^{
                
                [self.delegate transfer:self didReceiveDebugInformation:string ofType:infoType];
            }];

            [string release];
        }
    }

    return 0;
}

int curlSocketOptFunction(CURLTransfer *self, curl_socket_t curlfd, curlsocktype purpose)
{
    if (purpose == CURLSOCKTYPE_IPCXN)
    {
        // FTP control connections should be kept alive. However, I'm fairly sure this is unlikely to have a real effect in practice since OS X's default time before it starts sending keep alive packets is 2 hours :(
        // TODO: Looks like we could adopt CURLOPT_TCP_KEEPINTVL instead
        if ([self.originalRequest.URL.scheme isEqualToString:@"ftp"])
        {
            int keepAlive = 1;
            socklen_t keepAliveLen = sizeof(keepAlive);
            int result = setsockopt(curlfd, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, keepAliveLen);

            if (result)
            {
                CURLHandleLog(@"Unable to set FTP control connection keepalive with error:%i", result);
                return 1;
            }
        }
    }

    return 0;
}

/*"	Callback from reading a chunk of data.  Since we pass "self" in as the "data pointer",
 we can use that to get back into Objective C and do the work with the class.
 "*/

size_t curlBodyFunction(void *ptr, size_t size, size_t nmemb, CURLTransfer *self)
{
	return [self curlReceiveDataFrom:ptr size:size number:nmemb isHeader:NO];
}

/*"	Callback from reading a chunk of data.  Since we pass "self" in as the "data pointer",
 we can use that to get back into Objective C and do the work with the class.
 "*/

size_t curlHeaderFunction(void *ptr, size_t size, size_t nmemb, CURLTransfer *self)
{
	return [self curlReceiveDataFrom:ptr size:size number:nmemb isHeader:YES];
}

/*"	Callback to provide a chunk of data for sending.  Since we pass "self" in as the "data pointer",
 we can use that to get back into Objective C and do the work with the class.
 "*/

size_t curlReadFunction( void *ptr, size_t size, size_t nmemb, CURLTransfer *self)
{
    return [self curlSendDataTo:ptr size:size number:nmemb];
}

int curlKnownHostsFunction(CURL *easy,     /* easy handle */
                           const struct curl_khkey *knownkey, /* known */
                           const struct curl_khkey *foundkey, /* found */
                           enum curl_khmatch match, /* libcurl's view on the keys */
                           CURLTransfer *self) /* custom pointer passed from app */
{
    return [self didFindHostFingerprint:foundkey knownFingerprint:knownkey match:match];
}

@implementation NSError(CURLHandle)

- (NSUInteger)curlResponseCode
{
    NSInteger result = [[[self userInfo] objectForKey:@(CURLINFO_RESPONSE_CODE).stringValue] integerValue];

    return result;
}


@end
