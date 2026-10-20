#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientStrFn)(id);

static id Key(NSDictionary *d, NSString *suffix) { return d[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:suffix]]; }

// Prints one JSON line describing the system's now-playing item. Called from /usr/bin/perl (an Apple platform
// binary, which is what macOS 15.4+ requires for MediaRemote to answer).
void equ_nowplaying(void) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        GetInfoFn getInfo = h ? (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo") : NULL;
        if (!getInfo) { puts("{\"error\":\"MediaRemote unavailable\"}"); fflush(stdout); return; }
        __block NSDictionary *info = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_queue_t q = dispatch_queue_create("equ.np", DISPATCH_QUEUE_SERIAL);
        getInfo(q, ^(NSDictionary *d) { info = d; dispatch_semaphore_signal(sem); });
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC)) != 0) { puts("{\"error\":\"timeout\"}"); fflush(stdout); return; }
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSString *title = Key(info, @"Title"), *artist = Key(info, @"Artist"), *album = Key(info, @"Album");
        if (title) out[@"title"] = title;
        if (artist) out[@"artist"] = artist;
        if (album) out[@"album"] = album;
        NSNumber *rate = Key(info, @"PlaybackRate");
        if (rate) out[@"rate"] = rate;
        NSData *art = Key(info, @"ArtworkData");
        if ([art isKindOfClass:[NSData class]] && art.length < 3000000) out[@"artwork"] = [art base64EncodedStringWithOptions:0];
        GetClientFn getClient = (GetClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
        ClientStrFn clientName = (ClientStrFn)dlsym(h, "MRNowPlayingClientGetDisplayName");
        ClientStrFn clientBundle = (ClientStrFn)dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
        if (getClient) {
            __block id client = nil;
            dispatch_semaphore_t s2 = dispatch_semaphore_create(0);
            getClient(q, ^(id c) { client = c; dispatch_semaphore_signal(s2); });
            if (dispatch_semaphore_wait(s2, dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC)) == 0 && client) {
                NSString *n = clientName ? clientName(client) : nil, *b = clientBundle ? clientBundle(client) : nil;
                if (n) out[@"app"] = n;
                if (b) out[@"bundle"] = b;
            }
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        printf("%s\n", [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
        fflush(stdout);
    }
}
