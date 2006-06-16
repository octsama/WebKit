/*
 * Copyright (C) 2006 Apple Computer, Inc.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer. 
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution. 
 * 3.  Neither the name of Apple Computer, Inc. ("Apple") nor the names of
 *     its contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission. 
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "WebScriptDebugServer.h"
#import "WebScriptDebugServerPrivate.h"

NSString *WebScriptDebugServerProcessNameKey = @"WebScriptDebugServerProcessNameKey";
NSString *WebScriptDebugServerProcessIdentifierKey = @"WebScriptDebugServerProcessIdentifierKey";

NSString *WebScriptDebugServerQueryNotification = @"WebScriptDebugServerQueryNotification";
NSString *WebScriptDebugServerQueryReplyNotification = @"WebScriptDebugServerQueryReplyNotification";

NSString *WebScriptDebugServerDidLoadNotification = @"WebScriptDebugServerDidLoadNotification";
NSString *WebScriptDebugServerWillUnloadNotification = @"WebScriptDebugServerWillUnloadNotification";

@implementation WebScriptDebugServer

static WebScriptDebugServer *sharedServer = nil;

+ (WebScriptDebugServer *)sharedScriptDebugServer
{
    if (!sharedServer)
        sharedServer = [[WebScriptDebugServer alloc] init];
    return sharedServer;
}

- (id)init
{
    self = [super init];

    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    serverName = [[NSString alloc] initWithFormat:@"WebScriptDebugServer-%@-%d", [processInfo processName], [processInfo processIdentifier]];

    serverConnection = [[NSConnection alloc] init];
    if ([serverConnection registerName:serverName]) {
        [serverConnection setRootObject:self];
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:WebScriptDebugServerDidLoadNotification object:serverName];
    } else {
        [serverConnection release];
        serverConnection = nil;
    }

    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(serverQuery:) name:WebScriptDebugServerQueryNotification object:nil];

    listeners = [[NSMutableSet alloc] init];

    return self;
}

- (void)dealloc
{
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self name:WebScriptDebugServerQueryNotification object:nil];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:WebScriptDebugServerWillUnloadNotification object:serverName];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSConnectionDidDieNotification object:nil];
    [serverConnection invalidate];
    [serverConnection release];
    [serverName release];
    [listeners release];
    [super dealloc];
}

- (void)serverQuery:(NSNotification *)notification
{
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    NSDictionary *info = [[NSDictionary alloc] initWithObjectsAndKeys:[processInfo processName], WebScriptDebugServerProcessNameKey, [NSNumber numberWithInt:[processInfo processIdentifier]], WebScriptDebugServerProcessIdentifierKey, nil];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:WebScriptDebugServerQueryReplyNotification object:serverName userInfo:info];
    [info release];
}

- (void)listenerConnectionDidDie:(NSNotification *)notification
{
    NSConnection *connection = [notification object];
    NSMutableSet *listenersToRemove = [[NSMutableSet alloc] initWithCapacity:[listeners count]];
    NSEnumerator *enumerator = [listeners objectEnumerator];
    NSDistantObject *listener = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSConnectionDidDieNotification object:connection];

    while ((listener = [enumerator nextObject]))
        if ([[listener connectionForProxy] isEqualTo:connection])
            [listenersToRemove addObject:listener];

    [listeners minusSet:listenersToRemove];
    [listenersToRemove release];
}

- (oneway void)addListener:(id<WebScriptDebugListener>)listener
{
    if (![listener conformsToProtocol:@protocol(WebScriptDebugListener)])
        return;
    [listeners addObject:listener];
    if ([listener isKindOfClass:[NSDistantObject class]])
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(listenerConnectionDidDie:) name:NSConnectionDidDieNotification object:[(NSDistantObject *)listener connectionForProxy]];
}

- (oneway void)removeListener:(id<WebScriptDebugListener>)listener
{
    if ([listener isKindOfClass:[NSDistantObject class]])
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSConnectionDidDieNotification object:[(NSDistantObject *)listener connectionForProxy]];
    [listeners removeObject:listener];
}

- (void)webView:(WebView *)webView       didParseSource:(NSString *)source
                                                fromURL:(NSString *)url
                                               sourceId:(int)sid
                                            forWebFrame:(WebFrame *)webFrame
{
    if (![listeners count])
        return;

    NSEnumerator *enumerator = [listeners objectEnumerator];
    id listener = nil;

    while ((listener = [enumerator nextObject])) {
        @try {
            [listener webView:webView didParseSource:source fromURL:url sourceId:sid forWebFrame:webFrame];
        } @catch (NSException *exception) {
            // FIXME: should the listener be removed?
        }
    }
}

- (void)webView:(WebView *)webView    didEnterCallFrame:(WebScriptCallFrame *)frame
                                               sourceId:(int)sid
                                                   line:(int)lineno
                                            forWebFrame:(WebFrame *)webFrame
{
    if (![listeners count])
        return;

    NSEnumerator *enumerator = [listeners objectEnumerator];
    id listener = nil;

    while ((listener = [enumerator nextObject])) {
        @try {
            [listener webView:webView didEnterCallFrame:frame sourceId:sid line:lineno forWebFrame:webFrame];
        } @catch (NSException *exception) {
            // FIXME: should the listener be removed?
        }
    }
}

- (void)webView:(WebView *)webView willExecuteStatement:(WebScriptCallFrame *)frame
                                               sourceId:(int)sid
                                                   line:(int)lineno
                                            forWebFrame:(WebFrame *)webFrame
{
    if (![listeners count])
        return;

    NSEnumerator *enumerator = [listeners objectEnumerator];
    id listener = nil;

    while ((listener = [enumerator nextObject])) {
        @try {
            [listener webView:webView willExecuteStatement:frame sourceId:sid line:lineno forWebFrame:webFrame];
        } @catch (NSException *exception) {
            // FIXME: should the listener be removed?
        }
    }
}

- (void)webView:(WebView *)webView   willLeaveCallFrame:(WebScriptCallFrame *)frame
                                               sourceId:(int)sid
                                                   line:(int)lineno
                                            forWebFrame:(WebFrame *)webFrame
{
    if (![listeners count])
        return;

    NSEnumerator *enumerator = [listeners objectEnumerator];
    id listener = nil;

    while ((listener = [enumerator nextObject])) {
        @try {
            [listener webView:webView willLeaveCallFrame:frame sourceId:sid line:lineno forWebFrame:webFrame];
        } @catch (NSException *exception) {
            // FIXME: should the listener be removed?
        }
    }
}

@end
