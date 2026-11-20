// Spike B — même appel MediaRemote, mais chargé dans /usr/bin/perl (binaire signé Apple).
// C'est l'idée du contournement communautaire : MediaRemote vérifie l'identité du processus
// appelant, et perl est un processus Apple. Perl charge cette dylib via DynaLoader (run.pl).
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));

static void print_string(const char *label, CFDictionaryRef d, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    char buf[512] = "?";
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)v, buf, sizeof buf, kCFStringEncodingUTF8);
    }
    printf("%s%s", label, buf);
    CFRelease(k);
}

// Signature compatible XS (pTHX_ CV*) ; on ignore les arguments.
void island_run(void *interp, void *cv) {
    (void)interp; (void)cv;
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) { printf("[perl] dlopen a échoué\n"); return; }
    GetInfoFn getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    if (!getInfo) { printf("[perl] symbole introuvable\n"); return; }

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    getInfo(dispatch_get_global_queue(0, 0), ^(CFDictionaryRef d) {
        if (!d || CFDictionaryGetCount(d) == 0) {
            printf("[perl] info: VIDE (bloqué ou rien en lecture)\n");
        } else {
            print_string("[perl] info: ", d, "kMRMediaRemoteNowPlayingInfoTitle");
            print_string(" — ", d, "kMRMediaRemoteNowPlayingInfoArtist");
            CFStringRef ak = CFSTR("kMRMediaRemoteNowPlayingInfoArtworkData");
            printf(" | pochette: %s | %ld clés\n",
                   CFDictionaryGetValue(d, ak) ? "oui" : "non", (long)CFDictionaryGetCount(d));
            if (getenv("ISLAND_KEYS")) {
                CFIndex n = CFDictionaryGetCount(d);
                const void *keys[64];
                if (n > 64) n = 64;
                CFDictionaryGetKeysAndValues(d, keys, NULL);
                for (CFIndex i = 0; i < n; i++) {
                    char kb[256];
                    CFStringGetCString((CFStringRef)keys[i], kb, sizeof kb, kCFStringEncodingUTF8);
                    printf("  - %s\n", kb);
                }
            }
        }
        fflush(stdout);
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
}
