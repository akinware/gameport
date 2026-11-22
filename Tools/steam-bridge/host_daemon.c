/*
 * GamePort Steam Bridge Host Daemon (gpsteambridge-host)
 * License: PolyForm Noncommercial 1.0.0 (see LICENSE)
 *
 * Native macOS helper process spawned over a private AF_UNIX socketpair by
 * steamclient64.so / steamclient.so inside Wine. Loads Valve's untouched native
 * macOS steamclient.dylib cleanly outside Wine's Win32 address space so AppKit /
 * CoreFoundation / Mach IPC never conflict with Wine's preloader.
 */

#include "bridge_protocol.h"

#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <setjmp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* Wire protocol shared between unix_bridge.c (client) and gpsteambridge-host (server) */
#define GP_IPC_MAX_STR      256
#define GP_IPC_MAX_PAYLOAD  524288

#pragma pack(push, 8)
struct gp_ipc_request {
    uint32_t op;
    uint32_t flags;
    uint32_t slot;
    int32_t  pipe;
    int32_t  expected_callback;
    int32_t  cub_buf;
    uint64_t native_obj;
    uint64_t api_call;
    uint64_t args[8];
    uint8_t  arg_is_str[8];
    uint8_t  out_arg_idx[3];   /* 1..8 = arg index + 1; 0 = unused */
    uint8_t  in_buf_arg_idx;   /* 1..8 = arg index + 1; 0 = unused */
    uint32_t out_arg_len[3];
    uint32_t in_buf_len;
    char     str_args[8][GP_IPC_MAX_STR];
    char     iface_name[GP_BRIDGE_MAX_IFACE_NAME];
    uint8_t  in_payload[GP_IPC_MAX_PAYLOAD];
};

struct gp_ipc_response {
    int32_t  status;
    int32_t  return_code;
    uint32_t loaded;
    uint32_t exports_mask;
    uint64_t ret_u64;
    double   ret_f64;
    int32_t  has_callback;
    int32_t  steam_user;
    int32_t  callback_id;
    int32_t  cub_param;
    int32_t  failed;
    int32_t  ok;
    uint32_t ret_is_str;
    uint32_t payload_len;
    uint32_t out_len[3];
    uint32_t reserved0;
    char     ret_str[GP_IPC_MAX_STR];
    char     dylib_path[GP_BRIDGE_MAX_PATH];
    char     error_msg[256];
    uint8_t  payload[GP_IPC_MAX_PAYLOAD];
};
#pragma pack(pop)

/* Native macOS steamclient.dylib C entry signatures */
typedef void *(*fn_CreateInterface_t)(const char *pName, int *pReturnCode);

#pragma pack(push, 4)
struct native_callback_msg {
    int32_t  m_hSteamUser;
    int32_t  m_iCallback;
    uint8_t *m_pubParam;
    int32_t  m_cubParam;
};
#pragma pack(pop)

typedef bool (*fn_Steam_BGetCallback_t)(int32_t hSteamPipe, struct native_callback_msg *pCallbackMsg);
typedef void (*fn_Steam_FreeLastCallback_t)(int32_t hSteamPipe);
typedef bool (*fn_Steam_GetAPICallResult_t)(int32_t hSteamPipe, uint64_t hSteamAPICall,
                                            void *pCallback, int32_t cubCallback,
                                            int32_t iCallbackExpected, bool *pbFailed);
typedef void (*fn_Steam_ReleaseThreadLocalMemory_t)(int32_t bThreadExit);

typedef uint64_t (*sysv_vfn_u64_t)(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
typedef double   (*sysv_vfn_f64_t)(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
typedef float    (*sysv_vfn_f32_t)(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

/* Fault recovery guard so an unmarshaled Wine pointer in an unlisted Steamworks slot
 * never kills the host daemon or crashes the game. */
static sigjmp_buf g_fault_jmp;
static volatile sig_atomic_t g_in_vtable_call = 0;

static void gp_fault_handler(int sig) {
    if (g_in_vtable_call) {
        g_in_vtable_call = 0;
        siglongjmp(g_fault_jmp, sig);
    }
    _exit(128 + sig);
}

static int read_exact(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, p + got, len - got);
        if (n == 0) return 0;
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        got += (size_t)n;
    }
    return 1;
}

static int write_exact(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, p + sent, len - sent);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return -1;
        }
        sent += (size_t)n;
    }
    return 1;
}

/* Safely probe whether a native pointer in our process holds a readable printable C string */
static bool try_read_cstr(uint64_t addr, char *out, size_t cap, bool allow_empty) {
    if (addr < 0x100000ULL || cap < 2) return false;
    char tmp[GP_IPC_MAX_STR];
    size_t probe_len = cap < sizeof(tmp) ? cap : sizeof(tmp);
    mach_vm_size_t out_size = 0;
    kern_return_t kr = mach_vm_read_overwrite(
        mach_task_self(), (mach_vm_address_t)addr, (mach_vm_size_t)probe_len,
        (mach_vm_address_t)tmp, &out_size
    );
    if (kr != KERN_SUCCESS || out_size == 0) {
        /* Try smaller 32-byte read in case string sits near page end */
        kr = mach_vm_read_overwrite(
            mach_task_self(), (mach_vm_address_t)addr, 32,
            (mach_vm_address_t)tmp, &out_size
        );
        if (kr != KERN_SUCCESS || out_size == 0) return false;
    }
    size_t n = 0;
    while (n < (size_t)out_size && tmp[n] != '\0') {
        unsigned char c = (unsigned char)tmp[n];
        if (c < 0x09 || (c > 0x0D && c < 0x20) || c == 0x7F) return false;
        n++;
    }
    if (n == (size_t)out_size) return false; /* no NUL terminator */
    if (n == 0 && !allow_empty) return false;
    memcpy(out, tmp, n);
    out[n] = '\0';
    return true;
}

int main(int argc, char **argv) {
    int fd = -1;
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--fd") == 0) {
            fd = atoi(argv[i + 1]);
        }
    }
    if (fd < 0) {
        fprintf(stderr, "Usage: gpsteambridge-host --fd <socket_fd>\n");
        return 2;
    }

    int verbose = 0;
    const char *v = getenv("GP_STEAM_BRIDGE_LOG");
    if (v && v[0] && v[0] != '0') verbose = 1;

    /* Detach stdout so steamclient.dylib chatter never pollutes the Wine app's stdout */
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) {
        dup2(devnull, STDOUT_FILENO);
        if (!verbose) dup2(devnull, STDERR_FILENO);
        close(devnull);
    }

    /* Ensure HOME points to the user's real macOS home so steamclient.dylib locates Steam IPC */
    const char *real_home = getenv("GAMEPORT_REAL_HOME");
    if (real_home && *real_home) {
        setenv("HOME", real_home, 1);
    }

    char dylib_path[GP_BRIDGE_MAX_PATH] = {0};
    char error_msg[256] = {0};
    void *dylib = NULL;

    const char *candidates[3] = { getenv("GAMEPORT_MAC_STEAMCLIENT"), NULL, "/Applications/Steam.app/Contents/MacOS/steamclient.dylib" };
    char home_candidate[GP_BRIDGE_MAX_PATH] = {0};
    const char *home = getenv("HOME");
    if (home && *home) {
        snprintf(home_candidate, sizeof(home_candidate),
                 "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib",
                 home);
        candidates[1] = home_candidate;
    }

    for (int i = 0; i < 3 && !dylib; i++) {
        if (!candidates[i] || !*candidates[i]) continue;
        if (access(candidates[i], R_OK) != 0) continue;
        void *h = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (h) {
            dylib = h;
            snprintf(dylib_path, sizeof(dylib_path), "%s", candidates[i]);
            error_msg[0] = '\0';
            if (verbose) fprintf(stderr, "[gpsteambridge-host] loaded %s\n", dylib_path);
        } else {
            const char *e = dlerror();
            snprintf(error_msg, sizeof(error_msg), "dlopen(%s): %s", candidates[i], e ? e : "unknown");
        }
    }
    if (!dylib && !error_msg[0]) {
        snprintf(error_msg, sizeof(error_msg), "native macOS steamclient.dylib not found");
    }

    fn_CreateInterface_t               p_CreateInterface = dylib ? (fn_CreateInterface_t)dlsym(dylib, "CreateInterface") : NULL;
    fn_Steam_BGetCallback_t            p_GetCallback     = dylib ? (fn_Steam_BGetCallback_t)dlsym(dylib, "Steam_BGetCallback") : NULL;
    fn_Steam_FreeLastCallback_t        p_FreeCallback    = dylib ? (fn_Steam_FreeLastCallback_t)dlsym(dylib, "Steam_FreeLastCallback") : NULL;
    fn_Steam_GetAPICallResult_t        p_GetAPICall      = dylib ? (fn_Steam_GetAPICallResult_t)dlsym(dylib, "Steam_GetAPICallResult") : NULL;
    fn_Steam_ReleaseThreadLocalMemory_t p_ReleaseTLS     = dylib ? (fn_Steam_ReleaseThreadLocalMemory_t)dlsym(dylib, "Steam_ReleaseThreadLocalMemory") : NULL;

    uint32_t exports_mask = 0;
    if (p_CreateInterface) exports_mask |= GP_EXP_CREATE_INTERFACE;
    if (p_GetCallback)     exports_mask |= GP_EXP_GET_CALLBACK;
    if (p_FreeCallback)    exports_mask |= GP_EXP_FREE_CALLBACK;
    if (p_GetAPICall)      exports_mask |= GP_EXP_GET_APICALL_RESULT;
    if (p_ReleaseTLS)      exports_mask |= GP_EXP_RELEASE_TLS;

    /* Install SIGSEGV/SIGBUS recovery guard for vtable dispatch */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = gp_fault_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);

    struct gp_ipc_request *req = calloc(1, sizeof(*req));
    struct gp_ipc_response *resp = calloc(1, sizeof(*resp));
    if (!req || !resp) return 1;

    while (read_exact(fd, req, sizeof(*req)) == 1) {
        memset(resp, 0, sizeof(*resp));
        resp->loaded = dylib ? 1u : 0u;
        resp->exports_mask = exports_mask;

        switch (req->op) {
            case GP_BRIDGE_OP_PING:
                resp->status = 0;
                snprintf(resp->dylib_path, sizeof(resp->dylib_path), "%s", dylib_path);
                snprintf(resp->error_msg, sizeof(resp->error_msg), "%s", error_msg);
                break;

            case GP_BRIDGE_OP_CREATE_INTERFACE:
                if (!p_CreateInterface) {
                    resp->status = -1;
                    resp->return_code = 1;
                } else {
                    int rc = 0;
                    void *obj = p_CreateInterface(req->iface_name, &rc);
                    resp->status = 0;
                    resp->ret_u64 = (uint64_t)(uintptr_t)obj;
                    resp->return_code = rc;
                    if (verbose) fprintf(stderr, "[gpsteambridge-host] CreateInterface(\"%s\") -> %p (rc=%d)\n", req->iface_name, obj, rc);
                }
                break;

            case GP_BRIDGE_OP_VTABLE_CALL: {
                if (!req->native_obj || req->slot >= GP_BRIDGE_VTABLE_SLOTS) {
                    resp->status = -1;
                    break;
                }
                void *obj = (void *)(uintptr_t)req->native_obj;
                void **vt = *(void ***)obj;
                if (!vt || !vt[req->slot]) {
                    resp->status = -1;
                    break;
                }
                uint64_t a[8];
                for (int i = 0; i < 8; i++) {
                    a[i] = req->arg_is_str[i] ? (uint64_t)(uintptr_t)req->str_args[i] : req->args[i];
                }
                if (req->in_buf_arg_idx >= 1 && req->in_buf_arg_idx <= 8 && req->in_buf_len > 0) {
                    a[req->in_buf_arg_idx - 1] = (uint64_t)(uintptr_t)req->in_payload;
                }
                uint32_t out_off = 0;
                for (int k = 0; k < 3; k++) {
                    uint8_t idx = req->out_arg_idx[k];
                    uint32_t n = req->out_arg_len[k];
                    if (idx >= 1 && idx <= 8 && n > 0) {
                        if (out_off + n > GP_IPC_MAX_PAYLOAD) {
                            n = GP_IPC_MAX_PAYLOAD > out_off ? (GP_IPC_MAX_PAYLOAD - out_off) : 0;
                        }
                        if (n > 0) {
                            memset(resp->payload + out_off, 0, n);
                            a[idx - 1] = (uint64_t)(uintptr_t)(resp->payload + out_off);
                            resp->out_len[k] = n;
                            out_off += n;
                        }
                    }
                }
                if (verbose) {
                    fprintf(stderr, "[gpsteambridge-host] vtable_call(obj=%p, slot=%u, flags=0x%x, a0=0x%llx%s%s, a1=0x%llx%s%s, a2=0x%llx%s%s)\n",
                            obj, req->slot, req->flags,
                            (unsigned long long)req->args[0], req->arg_is_str[0] ? "=\"" : "", req->arg_is_str[0] ? req->str_args[0] : "",
                            (unsigned long long)req->args[1], req->arg_is_str[1] ? "=\"" : "", req->arg_is_str[1] ? req->str_args[1] : "",
                            (unsigned long long)req->args[2], req->arg_is_str[2] ? "=\"" : "", req->arg_is_str[2] ? req->str_args[2] : "");
                    fflush(stderr);
                }
                int fault_sig = sigsetjmp(g_fault_jmp, 1);
                if (fault_sig != 0) {
                    if (verbose) {
                        fprintf(stderr, "[gpsteambridge-host] RECOVERED signal=%d in obj=%p slot=%u (returning 0)\n",
                                fault_sig, obj, req->slot);
                        fflush(stderr);
                    }
                    resp->ret_u64 = 0;
                    resp->ret_f64 = 0.0;
                    resp->ret_is_str = 0;
                    resp->out_len[0] = 0;
                    resp->out_len[1] = 0;
                    resp->out_len[2] = 0;
                    resp->status = 0;
                    break;
                }
                g_in_vtable_call = 1;
                if (req->flags & GP_CALL_FLAG_RET_DOUBLE) {
                    resp->ret_f64 = ((sysv_vfn_f64_t)vt[req->slot])(obj, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
                } else if (req->flags & GP_CALL_FLAG_RET_FLOAT) {
                    float f = ((sysv_vfn_f32_t)vt[req->slot])(obj, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
                    resp->ret_f64 = (double)f;
                    uint32_t bits = 0;
                    memcpy(&bits, &f, sizeof(bits));
                    resp->ret_u64 = bits;
                } else {
                    resp->ret_u64 = ((sysv_vfn_u64_t)vt[req->slot])(obj, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
                    if (resp->ret_u64) {
                        bool explicit_cstr = (req->flags & GP_CALL_FLAG_RET_CSTR) != 0;
                        bool auto_cstr = (req->flags & GP_CALL_FLAG_NO_AUTO_CSTR) == 0 && resp->ret_u64 >= 0x100000000ULL;
                        if (explicit_cstr || auto_cstr) {
                            if (try_read_cstr(resp->ret_u64, resp->ret_str, sizeof(resp->ret_str), explicit_cstr)) {
                                resp->ret_is_str = 1;
                            }
                        }
                    }
                }
                g_in_vtable_call = 0;
                if (verbose) {
                    if (resp->ret_is_str) {
                        fprintf(stderr, "[gpsteambridge-host]   -> str=\"%s\"\n", resp->ret_str);
                    } else {
                        fprintf(stderr, "[gpsteambridge-host]   -> 0x%llx\n", (unsigned long long)resp->ret_u64);
                    }
                    fflush(stderr);
                }
                resp->status = 0;
                break;
            }

            case GP_BRIDGE_OP_GET_CALLBACK:
                if (!p_GetCallback) {
                    resp->status = -1;
                } else {
                    struct native_callback_msg msg;
                    memset(&msg, 0, sizeof(msg));
                    bool ok = p_GetCallback(req->pipe, &msg);
                    resp->status = 0;
                    resp->has_callback = ok ? 1 : 0;
                    if (ok) {
                        resp->steam_user = msg.m_hSteamUser;
                        resp->callback_id = msg.m_iCallback;
                        resp->cub_param = msg.m_cubParam;
                        if (msg.m_pubParam && msg.m_cubParam > 0) {
                            uint32_t n = (uint32_t)msg.m_cubParam;
                            if (n > GP_IPC_MAX_PAYLOAD) n = GP_IPC_MAX_PAYLOAD;
                            memcpy(resp->payload, msg.m_pubParam, n);
                            resp->payload_len = n;
                        }
                    }
                }
                break;

            case GP_BRIDGE_OP_FREE_CALLBACK:
                if (p_FreeCallback) p_FreeCallback(req->pipe);
                resp->status = 0;
                break;

            case GP_BRIDGE_OP_GET_APICALL_RESULT:
                if (!p_GetAPICall) {
                    resp->status = -1;
                    resp->failed = 1;
                } else {
                    bool failed = false;
                    int32_t cub = req->cub_buf;
                    if (cub < 0) cub = 0;
                    if (cub > GP_IPC_MAX_PAYLOAD) cub = GP_IPC_MAX_PAYLOAD;
                    bool ok = p_GetAPICall(req->pipe, req->api_call, resp->payload, cub, req->expected_callback, &failed);
                    resp->status = 0;
                    resp->ok = ok ? 1 : 0;
                    resp->failed = failed ? 1 : 0;
                    resp->payload_len = ok ? (uint32_t)cub : 0;
                }
                break;

            case GP_BRIDGE_OP_RELEASE_TLS:
                if (p_ReleaseTLS) p_ReleaseTLS(req->expected_callback);
                resp->status = 0;
                break;

            default:
                resp->status = -1;
                break;
        }

        if (write_exact(fd, resp, sizeof(*resp)) != 1) break;
    }

    free(req);
    free(resp);
    close(fd);
    return 0;
}
