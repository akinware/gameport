// Invisible per-frame Metal present probe for GamePort Play sessions.
// Loaded via DYLD_INSERT_LIBRARIES only when compatibility sharing is enabled.
// Swizzles -[CAMetalLayer nextDrawable] and logs 1-second frame intervals ONLY for
// Windows game processes under steamapps\common\ (never Steam or Wine helpers).
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <crt_externs.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_BUCKET_FRAMES 240

static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static int g_state = 0; // 0 = unchecked, 1 = active game, -1 = ignored process
static int g_fd = -1;
static double g_ticks_to_ms = 0.0;
static uint64_t g_last_tick = 0;
static uint64_t g_window_start_tick = 0;
static uint32_t g_window_frames = 0;
static double g_intervals_ms[MAX_BUCKET_FRAMES];
static uint32_t g_interval_count = 0;
static IMP g_orig_nextDrawable = NULL;

static int detect_game_process(void) {
    int *argc_p = _NSGetArgc();
    char ***argv_p = _NSGetArgv();
    if (!argc_p || !argv_p || !*argv_p) return 0;
    int argc = *argc_p;
    char **argv = *argv_p;
    for (int i = 0; i < argc; i++) {
        if (!argv[i]) continue;
        if (strcasestr(argv[i], "\\steamapps\\common\\") != NULL ||
            strcasestr(argv[i], "/steamapps/common/") != NULL) {
            return 1;
        }
    }
    return 0;
}

static void flush_bucket_locked(uint64_t now_tick) {
    if (g_fd < 0 || g_window_frames == 0) return;
    double elapsed_s = (double)(now_tick - g_window_start_tick) * g_ticks_to_ms / 1000.0;
    if (elapsed_s <= 0.0) return;
    double uptime_s = (double)now_tick * g_ticks_to_ms / 1000.0;

    char buf[4096];
    int pos = snprintf(buf, sizeof(buf), "%.3f %d %u %.3f", uptime_s, (int)getpid(), g_window_frames, elapsed_s);
    for (uint32_t i = 0; i < g_interval_count && pos > 0 && (size_t)pos < sizeof(buf) - 16; i++) {
        pos += snprintf(buf + pos, sizeof(buf) - (size_t)pos, " %.2f", g_intervals_ms[i]);
    }
    if (pos > 0 && (size_t)pos < sizeof(buf) - 2) {
        buf[pos++] = '\n';
        ssize_t ignored = write(g_fd, buf, (size_t)pos);
        (void)ignored;
    }
    g_window_start_tick = now_tick;
    g_window_frames = 0;
    g_interval_count = 0;
}

static id gp_nextDrawable(id self, SEL _cmd) {
    typedef id (*NextDrawableFn)(id, SEL);
    id drawable = ((NextDrawableFn)g_orig_nextDrawable)(self, _cmd);
    if (!drawable) return nil;

    os_unfair_lock_lock(&g_lock);
    if (g_state == 0) {
        if (detect_game_process()) {
            const char *path = getenv("GAMEPORT_FPS_LOG");
            if (path && *path) {
                g_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
            }
            if (g_fd >= 0) {
                mach_timebase_info_data_t tb;
                mach_timebase_info(&tb);
                g_ticks_to_ms = (double)tb.numer / (double)tb.denom / 1e6;
                g_state = 1;
            } else {
                g_state = -1;
            }
        } else {
            g_state = -1;
        }
    }

    if (g_state == 1) {
        uint64_t now = mach_continuous_time();
        if (g_window_start_tick == 0) g_window_start_tick = now;
        if (g_last_tick != 0 && now > g_last_tick) {
            double dt_ms = (double)(now - g_last_tick) * g_ticks_to_ms;
            if (dt_ms > 0.1 && dt_ms < 10000.0 && g_interval_count < MAX_BUCKET_FRAMES) {
                g_intervals_ms[g_interval_count++] = dt_ms;
            }
        }
        g_last_tick = now;
        g_window_frames++;
        if ((double)(now - g_window_start_tick) * g_ticks_to_ms >= 1000.0) {
            flush_bucket_locked(now);
        }
    }
    os_unfair_lock_unlock(&g_lock);
    return drawable;
}

__attribute__((constructor))
static void gp_fps_probe_init(void) {
    const char *path = getenv("GAMEPORT_FPS_LOG");
    if (!path || !*path) return;
    Class cls = objc_getClass("CAMetalLayer");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName("nextDrawable"));
    if (!m) return;
    g_orig_nextDrawable = method_setImplementation(m, (IMP)gp_nextDrawable);
}
