/*
 * GamePort Steam Bridge — macOS x86_64 Wine UnixLib (steamclient64.so / steamclient.so)
 * License: PolyForm Noncommercial 1.0.0 (see LICENSE)
 *
 * Bridges Wine PE steamclient64.dll / steamclient.dll calls to the native macOS
 * gpsteambridge-host helper over a private AF_UNIX socketpair, keeping Valve's
 * native steamclient.dylib completely outside Wine's Win32 address space.
 */

#include "bridge_protocol.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

extern char **environ;

typedef uint32_t NTSTATUS;
#define STATUS_SUCCESS            ((NTSTATUS)0x00000000u)
#define STATUS_INVALID_PARAMETER  ((NTSTATUS)0xC000000Du)
#define STATUS_UNSUCCESSFUL       ((NTSTATUS)0xC0000001u)

typedef NTSTATUS (*unixlib_entry_t)(void *args);

/* Must stay byte-identical with host_daemon.c */
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

/* Global state */
static pthread_once_t  g_init_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_ipc_lock  = PTHREAD_MUTEX_INITIALIZER;
static int             g_sock_fd   = -1;
static int             g_mock_mode = 0;
static int             g_verbose   = 0;
static char            g_init_error[256];

/* Wine-address-space storage for marshaled callbacks and C strings (64-bit callers) */
static uint8_t g_cb_buf[GP_IPC_MAX_PAYLOAD];
#define GP_UNIX_STR_SLOTS 64
static char    g_unix_str_ring[GP_UNIX_STR_SLOTS][GP_IPC_MAX_STR];
static uint32_t g_unix_str_idx = 0;

static struct gp_ipc_request  g_req;
static struct gp_ipc_response g_resp;

#define GP_LOG(fmt, ...) \
    do { if (g_verbose) fprintf(stderr, "[gameport-steam-bridge] " fmt "\n", ##__VA_ARGS__); } while (0)

/* --------------------------------------------------------------------------
 * Deterministic Mock Mode (GP_STEAM_BRIDGE_MOCK=1) for CI / unit tests
 * -------------------------------------------------------------------------- */
struct mock_object { void **vtable; int tag; };
static uint64_t mock_zero(void *s) { (void)s; return 0; }
static uint64_t mock_one(void *s)  { (void)s; return 1; }
static uint64_t mock_pipe(void *s) { (void)s; return 101; }
static uint64_t mock_user(void *s, int32_t p) { (void)s; (void)p; return 202; }
static uint64_t mock_sid(void *s)  { (void)s; return 76561198000000001ULL; }
static uint64_t mock_lang(void *s) { (void)s; return (uint64_t)(uintptr_t)"english"; }

static void *g_mock_user_vt[GP_BRIDGE_VTABLE_SLOTS];
static void *g_mock_apps_vt[GP_BRIDGE_VTABLE_SLOTS];
static void *g_mock_client_vt[GP_BRIDGE_VTABLE_SLOTS];
static struct mock_object g_mock_user   = { g_mock_user_vt, 2 };
static struct mock_object g_mock_apps   = { g_mock_apps_vt, 4 };
static struct mock_object g_mock_client = { g_mock_client_vt, 1 };

static uint64_t mock_get_user(void *s, int32_t u, int32_t p, const char *v) { (void)s;(void)u;(void)p;(void)v; return (uint64_t)(uintptr_t)&g_mock_user; }
static uint64_t mock_get_apps(void *s, int32_t u, int32_t p, const char *v) { (void)s;(void)u;(void)p;(void)v; return (uint64_t)(uintptr_t)&g_mock_apps; }

static void init_mock(void) {
    for (int i = 0; i < GP_BRIDGE_VTABLE_SLOTS; i++) {
        g_mock_user_vt[i] = (void *)mock_zero;
        g_mock_apps_vt[i] = (void *)mock_zero;
        g_mock_client_vt[i] = (void *)mock_zero;
    }
    g_mock_user_vt[0] = (void *)mock_pipe;
    g_mock_user_vt[1] = (void *)mock_one;
    g_mock_user_vt[2] = (void *)mock_sid;
    g_mock_apps_vt[0] = (void *)mock_one;
    g_mock_apps_vt[4] = (void *)mock_lang;
    g_mock_client_vt[0]  = (void *)mock_pipe;
    g_mock_client_vt[1]  = (void *)mock_one;
    g_mock_client_vt[2]  = (void *)mock_user;
    g_mock_client_vt[5]  = (void *)mock_get_user;
    g_mock_client_vt[12] = (void *)mock_get_user;
    g_mock_client_vt[15] = (void *)mock_get_apps;
}

/* --------------------------------------------------------------------------
 * Socketpair + Host Daemon Helpers
 * -------------------------------------------------------------------------- */
static int read_exact(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, p + got, len - got);
        if (n == 0) return 0;
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        got += (size_t)n;
    }
    return 1;
}

static int write_exact(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, p + sent, len - sent);
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; }
        sent += (size_t)n;
    }
    return 1;
}

/* Safely probe whether a Wine-side argument points to a printable ASCII C string */
static bool try_probe_wine_cstr(uint64_t addr, char *out, size_t cap) {
    if (addr < 0x10000ULL || cap < 2) return false;
    char tmp[GP_IPC_MAX_STR];
    size_t len = cap < sizeof(tmp) ? cap : sizeof(tmp);
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(
        mach_task_self(), (mach_vm_address_t)addr, (mach_vm_size_t)len,
        (mach_vm_address_t)tmp, &got
    );
    if (kr != KERN_SUCCESS || got == 0) {
        kr = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)addr, 32, (mach_vm_address_t)tmp, &got);
        if (kr != KERN_SUCCESS || got == 0) return false;
    }
    size_t n = 0;
    while (n < (size_t)got && tmp[n] != '\0') {
        unsigned char c = (unsigned char)tmp[n];
        if (c < 0x09 || (c > 0x0D && c < 0x20) || c == 0x7F) return false;
        n++;
    }
    if (n == 0 || n == (size_t)got) return false;
    memcpy(out, tmp, n);
    out[n] = '\0';
    return true;
}

static void locate_host_binary(char *out, size_t cap) {
    out[0] = '\0';
    const char *env_host = getenv("GAMEPORT_BRIDGE_HOST");
    if (env_host && *env_host && access(env_host, X_OK) == 0) {
        snprintf(out, cap, "%s", env_host);
        return;
    }
    Dl_info dli;
    if (dladdr((const void *)locate_host_binary, &dli) && dli.dli_fname) {
        char copy[GP_BRIDGE_MAX_PATH];
        snprintf(copy, sizeof(copy), "%s", dli.dli_fname);
        char *dir1 = dirname(copy); /* .../x86_64-unix */
        char copy2[GP_BRIDGE_MAX_PATH];
        snprintf(copy2, sizeof(copy2), "%s", dir1);
        char *dir2 = dirname(copy2); /* .../steam-bridge */
        snprintf(out, cap, "%s/gpsteambridge-host", dir2);
        if (access(out, X_OK) == 0) return;
        out[0] = '\0';
    }
}

static void gp_bridge_init_once(void) {
    const char *v = getenv("GP_STEAM_BRIDGE_LOG");
    g_verbose = (v && v[0] && v[0] != '0');

    const char *m = getenv("GP_STEAM_BRIDGE_MOCK");
    if (m && m[0] && m[0] != '0') {
        g_mock_mode = 1;
        init_mock();
        GP_LOG("initialized in MOCK mode");
        return;
    }

    char host_bin[GP_BRIDGE_MAX_PATH];
    locate_host_binary(host_bin, sizeof(host_bin));
    if (!host_bin[0]) {
        snprintf(g_init_error, sizeof(g_init_error), "gpsteambridge-host binary not found");
        GP_LOG("%s", g_init_error);
        return;
    }

    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
        snprintf(g_init_error, sizeof(g_init_error), "socketpair failed: %s", strerror(errno));
        return;
    }
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);

    char fd_str[32];
    snprintf(fd_str, sizeof(fd_str), "%d", fds[1]);
    char *argv[] = { host_bin, "--fd", fd_str, NULL };

    pid_t pid = 0;
    int rc = posix_spawn(&pid, host_bin, NULL, NULL, argv, environ);
    close(fds[1]);
    if (rc != 0) {
        close(fds[0]);
        snprintf(g_init_error, sizeof(g_init_error), "posix_spawn(%s) failed: %s", host_bin, strerror(rc));
        GP_LOG("%s", g_init_error);
        return;
    }

    g_sock_fd = fds[0];
    GP_LOG("spawned native host daemon pid=%d (%s)", (int)pid, host_bin);
}

static void ensure_init(void) {
    pthread_once(&g_init_once, gp_bridge_init_once);
}

static bool ipc_roundtrip_locked(void) {
    if (g_sock_fd < 0) return false;
    if (write_exact(g_sock_fd, &g_req, sizeof(g_req)) != 1) return false;
    if (read_exact(g_sock_fd, &g_resp, sizeof(g_resp)) != 1) return false;
    return true;
}

/* --------------------------------------------------------------------------
 * Wine UnixLib Entry Points
 * -------------------------------------------------------------------------- */
static NTSTATUS gp_unix_ping(void *raw) {
    struct gp_ping_args *p = (struct gp_ping_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    p->protocol_version = GP_BRIDGE_PROTOCOL_VERSION;
    if (g_mock_mode) {
        p->loaded = 1;
        p->mock_mode = 1;
        p->exports_mask = GP_EXP_CREATE_INTERFACE | GP_EXP_GET_CALLBACK |
                          GP_EXP_FREE_CALLBACK | GP_EXP_GET_APICALL_RESULT | GP_EXP_RELEASE_TLS;
        snprintf(p->dylib_path, sizeof(p->dylib_path), "mock://steamclient.dylib");
        p->error_msg[0] = '\0';
        return STATUS_SUCCESS;
    }

    pthread_mutex_lock(&g_ipc_lock);
    memset(&g_req, 0, sizeof(g_req));
    g_req.op = GP_BRIDGE_OP_PING;
    bool ok = ipc_roundtrip_locked();
    if (ok) {
        p->loaded = g_resp.loaded;
        p->mock_mode = 0;
        p->exports_mask = g_resp.exports_mask;
        snprintf(p->dylib_path, sizeof(p->dylib_path), "%s", g_resp.dylib_path);
        snprintf(p->error_msg, sizeof(p->error_msg), "%s", g_resp.error_msg);
    } else {
        p->loaded = 0;
        p->mock_mode = 0;
        snprintf(p->error_msg, sizeof(p->error_msg), "%s",
                 g_init_error[0] ? g_init_error : "IPC connection to gpsteambridge-host failed");
    }
    pthread_mutex_unlock(&g_ipc_lock);
    return STATUS_SUCCESS;
}

static NTSTATUS gp_unix_create_interface(void *raw) {
    struct gp_create_interface_args *p = (struct gp_create_interface_args *)raw;
    if (!p || !p->name_ptr) return STATUS_INVALID_PARAMETER;
    ensure_init();
    const char *name = (const char *)(uintptr_t)p->name_ptr;

    if (g_mock_mode) {
        if (strncmp(name, "SteamClient", 11) == 0) {
            p->native_obj = (uint64_t)(uintptr_t)&g_mock_client;
            p->return_code = 0;
            GP_LOG("CreateInterface(\"%s\") -> %p (rc=0)", name, &g_mock_client);
            return STATUS_SUCCESS;
        }
        p->native_obj = 0;
        p->return_code = 1;
        return STATUS_SUCCESS;
    }

    pthread_mutex_lock(&g_ipc_lock);
    memset(&g_req, 0, sizeof(g_req));
    g_req.op = GP_BRIDGE_OP_CREATE_INTERFACE;
    snprintf(g_req.iface_name, sizeof(g_req.iface_name), "%s", name);
    bool ok = ipc_roundtrip_locked();
    if (ok && g_resp.status == 0) {
        p->native_obj = g_resp.ret_u64;
        p->return_code = g_resp.return_code;
    } else {
        p->native_obj = 0;
        p->return_code = 1;
    }
    pthread_mutex_unlock(&g_ipc_lock);
    GP_LOG("CreateInterface(\"%s\") -> 0x%llx (rc=%d)", name, (unsigned long long)p->native_obj, p->return_code);
    return ok ? STATUS_SUCCESS : STATUS_UNSUCCESSFUL;
}

typedef uint64_t (*sysv_vfn_u64_t)(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

static NTSTATUS gp_unix_vtable_call(void *raw) {
    struct gp_vtable_call_args *p = (struct gp_vtable_call_args *)raw;
    if (!p || !p->native_obj || p->slot >= GP_BRIDGE_VTABLE_SLOTS) return STATUS_INVALID_PARAMETER;
    ensure_init();

    if (g_mock_mode) {
        void *obj = (void *)(uintptr_t)p->native_obj;
        void **vt = *(void ***)obj;
        GP_LOG("vtable_call(obj=%p, slot=%u, flags=0x%x)", obj, p->slot, p->flags);
        p->ret_u64 = ((sysv_vfn_u64_t)vt[p->slot])(obj, p->args[0], p->args[1], p->args[2], p->args[3],
                                                   p->args[4], p->args[5], p->args[6], p->args[7]);
        p->ret_f64 = 0.0;
        if ((p->flags & GP_CALL_FLAG_RET_CSTR) && p->str_buf_ptr && p->str_buf_cap > 0) {
            char *dst = (char *)(uintptr_t)p->str_buf_ptr;
            const char *src = (const char *)(uintptr_t)p->ret_u64;
            if (src) {
                snprintf(dst, p->str_buf_cap, "%s", src);
                p->ret_u64 = p->str_buf_ptr;
            } else {
                dst[0] = '\0';
                p->ret_u64 = 0;
            }
        }
        return STATUS_SUCCESS;
    }

    pthread_mutex_lock(&g_ipc_lock);
    memset(&g_req, 0, sizeof(g_req));
    g_req.op = GP_BRIDGE_OP_VTABLE_CALL;
    g_req.native_obj = p->native_obj;
    g_req.slot = p->slot;
    g_req.flags = p->flags;
    for (int k = 0; k < 3; k++) {
        g_req.out_arg_idx[k] = p->out_arg_idx[k];
        g_req.out_arg_len[k] = p->out_arg_len[k];
    }
    g_req.in_buf_arg_idx = p->in_buf_arg_idx;
    g_req.in_buf_len = 0;

    if (p->in_buf_arg_idx >= 1 && p->in_buf_arg_idx <= 8 && p->in_buf_len > 0) {
        uint64_t src_addr = p->args[p->in_buf_arg_idx - 1];
        uint32_t n = p->in_buf_len > GP_IPC_MAX_PAYLOAD ? GP_IPC_MAX_PAYLOAD : p->in_buf_len;
        mach_vm_size_t got = 0;
        if (src_addr >= 0x10000ULL &&
            mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)src_addr, n,
                                   (mach_vm_address_t)g_req.in_payload, &got) == KERN_SUCCESS) {
            g_req.in_buf_len = (uint32_t)got;
        }
    }

    for (int i = 0; i < 8; i++) {
        g_req.args[i] = p->args[i];
        bool is_special = ((i + 1) == p->out_arg_idx[0]) ||
                          ((i + 1) == p->out_arg_idx[1]) ||
                          ((i + 1) == p->out_arg_idx[2]) ||
                          ((i + 1) == p->in_buf_arg_idx);
        if (!is_special && try_probe_wine_cstr(p->args[i], g_req.str_args[i], GP_IPC_MAX_STR)) {
            g_req.arg_is_str[i] = 1;
        }
    }
    bool ok = ipc_roundtrip_locked();
    if (ok && g_resp.status == 0) {
        p->ret_u64 = g_resp.ret_u64;
        p->ret_f64 = g_resp.ret_f64;
        uint32_t off = 0;
        for (int k = 0; k < 3; k++) {
            uint8_t idx = p->out_arg_idx[k];
            uint32_t n = g_resp.out_len[k];
            if (idx >= 1 && idx <= 8 && n > 0 && off + n <= GP_IPC_MAX_PAYLOAD) {
                uint64_t dst_addr = p->args[idx - 1];
                if (dst_addr >= 0x10000ULL) {
                    memcpy((void *)(uintptr_t)dst_addr, g_resp.payload + off, n);
                }
                off += n;
            }
        }
        if (g_resp.ret_is_str) {
            if (p->str_buf_ptr && p->str_buf_cap > 0) {
                snprintf((char *)(uintptr_t)p->str_buf_ptr, p->str_buf_cap, "%s", g_resp.ret_str);
                p->ret_u64 = p->str_buf_ptr;
            } else {
                char *slot_buf = g_unix_str_ring[(g_unix_str_idx++) % GP_UNIX_STR_SLOTS];
                snprintf(slot_buf, GP_IPC_MAX_STR, "%s", g_resp.ret_str);
                p->ret_u64 = (uint64_t)(uintptr_t)slot_buf;
            }
        }
    } else {
        p->ret_u64 = 0;
        p->ret_f64 = 0.0;
    }
    pthread_mutex_unlock(&g_ipc_lock);
    return (ok && g_resp.status == 0) ? STATUS_SUCCESS : STATUS_UNSUCCESSFUL;
}

static NTSTATUS gp_unix_get_callback(void *raw) {
    struct gp_get_callback_args *p = (struct gp_get_callback_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    if (g_mock_mode) {
        p->has_callback = 0;
        return STATUS_SUCCESS;
    }

    pthread_mutex_lock(&g_ipc_lock);
    memset(&g_req, 0, sizeof(g_req));
    g_req.op = GP_BRIDGE_OP_GET_CALLBACK;
    g_req.pipe = p->pipe;
    bool ok = ipc_roundtrip_locked();
    if (ok && g_resp.status == 0 && g_resp.has_callback) {
        p->has_callback = 1;
        p->steam_user = g_resp.steam_user;
        p->callback_id = g_resp.callback_id;
        p->cub_param = g_resp.cub_param;
        if (g_resp.payload_len > 0) {
            if (p->copy_buf_ptr && p->copy_buf_cap > 0) {
                size_t n = g_resp.payload_len < p->copy_buf_cap ? g_resp.payload_len : p->copy_buf_cap;
                memcpy((void *)(uintptr_t)p->copy_buf_ptr, g_resp.payload, n);
                p->pub_param = p->copy_buf_ptr;
            } else {
                memcpy(g_cb_buf, g_resp.payload, g_resp.payload_len);
                p->pub_param = (uint64_t)(uintptr_t)g_cb_buf;
            }
        } else {
            p->pub_param = 0;
        }
    } else {
        p->has_callback = 0;
    }
    pthread_mutex_unlock(&g_ipc_lock);
    return ok ? STATUS_SUCCESS : STATUS_UNSUCCESSFUL;
}

static NTSTATUS gp_unix_free_callback(void *raw) {
    struct gp_free_callback_args *p = (struct gp_free_callback_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    if (g_mock_mode) return STATUS_SUCCESS;
    pthread_mutex_lock(&g_ipc_lock);
    memset(&g_req, 0, sizeof(g_req));
    g_req.op = GP_BRIDGE_OP_FREE_CALLBACK;
    g_req.pipe = p->pipe;
    ipc_roundtrip_locked();
    pthread_mutex_unlock(&g_ipc_lock);
    return STATUS_SUCCESS;
}

static NTSTATUS gp_unix_get_apicall_result(void *raw) {
    struct gp_get_apicall_result_args *p = (struct gp_get_apicall_result_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    if (g_mock_mode) {
        p->ok = 0;
        p->failed = 0;
        return STATUS_SUCCESS;
    }
    pthread_mutex_lock(&g_ipc_lock);
    memset(&g_req, 0, sizeof(g_req));
    g_req.op = GP_BRIDGE_OP_GET_APICALL_RESULT;
    g_req.pipe = p->pipe;
    g_req.api_call = p->api_call;
    g_req.cub_buf = p->cub_buf;
    g_req.expected_callback = p->expected_callback;
    bool ok = ipc_roundtrip_locked();
    if (ok && g_resp.status == 0) {
        p->ok = g_resp.ok;
        p->failed = g_resp.failed;
        if (g_resp.ok && g_resp.payload_len > 0 && p->buf_ptr) {
            size_t n = g_resp.payload_len;
            if ((int32_t)n > p->cub_buf) n = (size_t)p->cub_buf;
            memcpy((void *)(uintptr_t)p->buf_ptr, g_resp.payload, n);
        }
    } else {
        p->ok = 0;
        p->failed = 1;
    }
    pthread_mutex_unlock(&g_ipc_lock);
    return ok ? STATUS_SUCCESS : STATUS_UNSUCCESSFUL;
}

static NTSTATUS gp_unix_release_tls(void *raw) {
    struct gp_release_tls_args *p = (struct gp_release_tls_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    if (g_mock_mode) return STATUS_SUCCESS;
    pthread_mutex_lock(&g_ipc_lock);
    memset(&g_req, 0, sizeof(g_req));
    g_req.op = GP_BRIDGE_OP_RELEASE_TLS;
    g_req.expected_callback = p->all_threads;
    ipc_roundtrip_locked();
    pthread_mutex_unlock(&g_ipc_lock);
    return STATUS_SUCCESS;
}

__attribute__((visibility("default")))
const unixlib_entry_t __wine_unix_call_funcs[GP_BRIDGE_OP_COUNT] = {
    gp_unix_ping,
    gp_unix_create_interface,
    gp_unix_vtable_call,
    gp_unix_get_callback,
    gp_unix_free_callback,
    gp_unix_get_apicall_result,
    gp_unix_release_tls
};

__attribute__((visibility("default")))
const unixlib_entry_t __wine_unix_call_wow64_funcs[GP_BRIDGE_OP_COUNT] = {
    gp_unix_ping,
    gp_unix_create_interface,
    gp_unix_vtable_call,
    gp_unix_get_callback,
    gp_unix_free_callback,
    gp_unix_get_apicall_result,
    gp_unix_release_tls
};
