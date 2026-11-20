// Helper Now Playing d'Island, chargé dans /usr/bin/perl (binaire signé Apple) par run.pl.
// MediaRemote refuse les processus non Apple depuis macOS 15.4 ; perl passe ce contrôle.
//
// Protocole (lignes de texte) :
//   stdout : un objet JSON par seconde avec l'état de lecture courant
//   stdin  : commandes « toggle », « play », « pause », « next », « prev », « seek <secondes> »
//   EOF sur stdin (l'app s'est arrêtée) -> le helper quitte.
//
// La pochette est écrite dans $ISLAND_ART_DIR et seul son chemin passe dans le JSON.
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static GetInfoFn getInfo;
static IsPlayingFn isPlaying;
static GetPIDFn getPID;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;

static dispatch_queue_t queue;
static int polling = 0;
static unsigned long long lastArtHash = 0;
static char lastArtPath[1024] = "";
static int artCounter = 0;

enum { CMD_PLAY = 0, CMD_PAUSE = 1, CMD_TOGGLE = 2, CMD_NEXT = 4, CMD_PREV = 5 };

// ---------- JSON

static void json_string(FILE *f, CFStringRef s) {
    if (!s || CFGetTypeID(s) != CFStringGetTypeID()) { fputs("null", f); return; }
    CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    char *buf = malloc(max);
    if (!buf || !CFStringGetCString(s, buf, max, kCFStringEncodingUTF8)) { free(buf); fputs("null", f); return; }
    fputc('"', f);
    for (unsigned char *p = (unsigned char *)buf; *p; p++) {
        switch (*p) {
            case '"': fputs("\\\"", f); break;
            case '\\': fputs("\\\\", f); break;
            case '\n': fputs("\\n", f); break;
            case '\r': fputs("\\r", f); break;
            case '\t': fputs("\\t", f); break;
            default:
                if (*p < 0x20) fprintf(f, "\\u%04x", *p);
                else fputc(*p, f);
        }
    }
    fputc('"', f);
    free(buf);
}

static CFTypeRef get(CFDictionaryRef d, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    return v;
}

static int get_double(CFDictionaryRef d, const char *key, double *out) {
    CFTypeRef v = get(d, key);
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) return CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, out);
    return 0;
}

// ---------- Pochette

static unsigned long long fnv1a(const UInt8 *p, CFIndex n) {
    unsigned long long h = 1469598103934665603ULL;
    for (CFIndex i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

static const char *store_artwork(CFDataRef data) {
    if (!data || CFGetTypeID(data) != CFDataGetTypeID()) return NULL;
    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex len = CFDataGetLength(data);
    unsigned long long h = fnv1a(bytes, len);
    if (h == lastArtHash && lastArtPath[0]) return lastArtPath;

    const char *dir = getenv("ISLAND_ART_DIR");
    if (!dir) dir = "/tmp";
    char path[1024];
    snprintf(path, sizeof path, "%s/artwork-%d.img", dir, artCounter++ % 4);
    FILE *f = fopen(path, "wb");
    if (!f) return NULL;
    fwrite(bytes, 1, len, f);
    fclose(f);
    lastArtHash = h;
    strncpy(lastArtPath, path, sizeof lastArtPath - 1);
    return lastArtPath;
}

// ---------- Émission

static void emit(CFDictionaryRef info, Boolean playing, int pid) {
    char *out = NULL;
    size_t outLen = 0;
    FILE *f = open_memstream(&out, &outLen);
    if (!f) return;

    if (!info || CFDictionaryGetCount(info) == 0) {
        fputs("{\"empty\":true}", f);
    } else {
        double v;
        fputs("{\"title\":", f);   json_string(f, get(info, "kMRMediaRemoteNowPlayingInfoTitle"));
        fputs(",\"artist\":", f);  json_string(f, get(info, "kMRMediaRemoteNowPlayingInfoArtist"));
        fputs(",\"album\":", f);   json_string(f, get(info, "kMRMediaRemoteNowPlayingInfoAlbum"));
        if (get_double(info, "kMRMediaRemoteNowPlayingInfoDuration", &v)) fprintf(f, ",\"duration\":%.3f", v);
        if (get_double(info, "kMRMediaRemoteNowPlayingInfoElapsedTime", &v)) fprintf(f, ",\"elapsed\":%.3f", v);
        if (get_double(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate", &v)) fprintf(f, ",\"rate\":%.3f", v);
        CFTypeRef ts = get(info, "kMRMediaRemoteNowPlayingInfoTimestamp");
        if (ts && CFGetTypeID(ts) == CFDateGetTypeID())
            fprintf(f, ",\"timestamp\":%.3f", CFDateGetAbsoluteTime((CFDateRef)ts) + kCFAbsoluteTimeIntervalSince1970);
        const char *art = store_artwork(get(info, "kMRMediaRemoteNowPlayingInfoArtworkData"));
        if (art) fprintf(f, ",\"artwork\":\"%s\"", art);
        fprintf(f, ",\"playing\":%s,\"pid\":%d}", playing ? "true" : "false", pid);
    }
    fclose(f);
    printf("%s\n", out);
    fflush(stdout);
    free(out);
}

static void poll_now(void) {
    if (polling) return;
    polling = 1;
    getInfo(queue, ^(CFDictionaryRef info) {
        if (info) CFRetain(info);
        isPlaying(queue, ^(Boolean playing) {
            void (^finish)(int) = ^(int pid) {
                emit(info, playing, pid);
                if (info) CFRelease(info);
                polling = 0;
            };
            if (getPID) getPID(queue, finish); else finish(0);
        });
    });
}

// ---------- Commandes

static void handle_command(char *line) {
    if (strncmp(line, "seek ", 5) == 0) {
        if (setElapsed) setElapsed(atof(line + 5));
    } else if (strcmp(line, "toggle") == 0) sendCommand(CMD_TOGGLE, NULL);
    else if (strcmp(line, "play") == 0) sendCommand(CMD_PLAY, NULL);
    else if (strcmp(line, "pause") == 0) sendCommand(CMD_PAUSE, NULL);
    else if (strcmp(line, "next") == 0) sendCommand(CMD_NEXT, NULL);
    else if (strcmp(line, "prev") == 0) sendCommand(CMD_PREV, NULL);
    else return;
    // Laisse le lecteur appliquer la commande avant de relire l'état.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), queue, ^{ poll_now(); });
}

// ---------- Point d'entrée (signature compatible XS : arguments ignorés)

void island_run(void *interp, void *cv) {
    (void)interp; (void)cv;
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) { printf("{\"error\":\"dlopen\"}\n"); fflush(stdout); exit(1); }
    getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    isPlaying = (IsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (GetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = (SendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    if (!getInfo || !isPlaying || !sendCommand) { printf("{\"error\":\"symbols\"}\n"); fflush(stdout); exit(1); }

    queue = dispatch_queue_create("island.nowplaying", DISPATCH_QUEUE_SERIAL);

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ poll_now(); });
    dispatch_resume(timer);

    static char pending[4096];
    static size_t pendingLen = 0;
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(input, ^{
        char buf[1024];
        ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
        if (n <= 0) exit(0); // l'app est partie
        for (ssize_t i = 0; i < n; i++) {
            if (buf[i] == '\n') {
                pending[pendingLen] = 0;
                handle_command(pending);
                pendingLen = 0;
            } else if (pendingLen < sizeof pending - 1) {
                pending[pendingLen++] = buf[i];
            }
        }
    });
    dispatch_resume(input);

    dispatch_main();
}
