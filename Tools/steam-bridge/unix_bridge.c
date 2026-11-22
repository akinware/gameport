/*
 * GamePort Steam Bridge — macOS x86_64 Wine UnixLib (steamclient64.so)
 * License: PolyForm Noncommercial 1.0.0 (see LICENSE)
 *
 * Loaded inside Wine's Unix side when steamclient64.dll invokes NtQueryVirtualMemory
 * (MemoryWineUnixFuncs). Dynamically opens the user's untouched native macOS
 * steamclient.dylib and bridges C exports + C++ vtable calls across System V ABI.
 */

#include "bridge_protocol.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef uint32_t NTSTATUS;
#define STATUS_SUCCESS            ((NTSTATUS)0x00000000u)
#define STATUS_INVALID_PARAMETER  ((NTSTATUS)0xC000000Du)
#define STATUS_UNSUCCESSFUL       ((NTSTATUS)0xC0000001u)

typedef NTSTATUS (*unixlib_entry_t)(void *args);

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

/* Global bridge state initialized once per process */
static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
static void *g_dylib = NULL;
static int   g_mock_mode = 0;
static int   g_verbose = 0;
static uint32_t g_exports_mask = 0;
static char  g_dylib_path[GP_BRIDGE_MAX_PATH];
static char  g_error_msg[256];

static fn_CreateInterface_t               p_CreateInterface = NULL;
static fn_Steam_BGetCallback_t            p_Steam_BGetCallback = NULL;
static fn_Steam_FreeLastCallback_t        p_Steam_FreeLastCallback = NULL;
static fn_Steam_GetAPICallResult_t        p_Steam_GetAPICallResult = NULL;
static fn_Steam_ReleaseThreadLocalMemory_t p_Steam_ReleaseThreadLocalMemory = NULL;

#define GP_LOG(fmt, ...) \
    do { if (g_verbose) fprintf(stderr, "[gameport-steam-bridge] " fmt "\n", ##__VA_ARGS__); } while (0)

/* --------------------------------------------------------------------------
 * Deterministic Mock SteamClient (activated ONLY via GP_STEAM_BRIDGE_MOCK=1)
 * Used by automated CI/unit smoke tests when native Steam.app isn't running.
 * -------------------------------------------------------------------------- */
struct mock_object {
    void **vtable;
    int    tag;
};

static uint64_t mock_return_zero(void *self) { (void)self; return 0; }
static uint64_t mock_return_one(void *self)  { (void)self; return 1; }
static uint64_t mock_create_pipe(void *self) { (void)self; return 101; }
static uint64_t mock_connect_user(void *self, int32_t pipe) { (void)self; (void)pipe; return 202; }
static uint64_t mock_get_steam_id(void *self) { (void)self; return 76561198000000001ULL; }
static uint64_t mock_get_app_lang(void *self) { (void)self; return (uint64_t)(uintptr_t)"english"; }

static void *g_mock_user_vtable[GP_BRIDGE_VTABLE_SLOTS];
static void *g_mock_apps_vtable[GP_BRIDGE_VTABLE_SLOTS];
static void *g_mock_client_vtable[GP_BRIDGE_VTABLE_SLOTS];
static struct mock_object g_mock_user   = { g_mock_user_vtable,   2 };
static struct mock_object g_mock_apps   = { g_mock_apps_vtable,   4 };
static struct mock_object g_mock_client = { g_mock_client_vtable, 1 };

static uint64_t mock_get_isteam_user(void *self, int32_t user, int32_t pipe, const char *ver) {
    (void)self; (void)user; (void)pipe; (void)ver;
    return (uint64_t)(uintptr_t)&g_mock_user;
}

static uint64_t mock_get_isteam_apps(void *self, int32_t user, int32_t pipe, const char *ver) {
    (void)self; (void)user; (void)pipe; (void)ver;
    return (uint64_t)(uintptr_t)&g_mock_apps;
}

static void init_mock_vtables(void) {
    for (int i = 0; i < GP_BRIDGE_VTABLE_SLOTS; i++) {
        g_mock_user_vtable[i]   = (void *)mock_return_zero;
        g_mock_apps_vtable[i]   = (void *)mock_return_zero;
        g_mock_client_vtable[i] = (void *)mock_return_zero;
    }
    /* ISteamUser standard layout */
    g_mock_user_vtable[0] = (void *)mock_create_pipe;   /* GetHSteamUser */
    g_mock_user_vtable[1] = (void *)mock_return_one;    /* BLoggedOn */
    g_mock_user_vtable[2] = (void *)mock_get_steam_id;  /* GetSteamID -> CSteamID */

    /* ISteamApps standard layout */
    g_mock_apps_vtable[0] = (void *)mock_return_one;    /* BIsSubscribed */
    g_mock_apps_vtable[6] = (void *)mock_get_app_lang;  /* GetCurrentGameLanguage */

    /* ISteamClient020 standard layout */
    g_mock_client_vtable[0]  = (void *)mock_create_pipe;     /* CreateSteamPipe */
    g_mock_client_vtable[1]  = (void *)mock_return_one;      /* BReleaseSteamPipe */
    g_mock_client_vtable[2]  = (void *)mock_connect_user;    /* ConnectToGlobalUser */
    g_mock_client_vtable[5]  = (void *)mock_get_isteam_user; /* GetISteamUser */
    g_mock_client_vtable[15] = (void *)mock_get_isteam_apps; /* GetISteamApps */
    g_mock_client_vtable[12] = (void *)mock_get_isteam_user; /* GetISteamGenericInterface */
}

static void *mock_create_interface(const char *name, int *rc) {
    if (name && strncmp(name, "SteamClient", 11) == 0) {
        if (rc) *rc = 0;
        return &g_mock_client;
    }
    if (rc) *rc = 1;
    return NULL;
}

static bool mock_get_callback(int32_t pipe, struct native_callback_msg *msg) {
    (void)pipe;
    if (msg) memset(msg, 0, sizeof(*msg));
    return false;
}

static void mock_free_callback(int32_t pipe) { (void)pipe; }

static bool mock_get_apicall_result(int32_t pipe, uint64_t call, void *buf, int32_t cub,
                                    int32_t expected, bool *failed) {
    (void)pipe; (void)call; (void)buf; (void)cub; (void)expected;
    if (failed) *failed = false;
    return false;
}

static void mock_release_tls(int32_t all_threads) { (void)all_threads; }

/* --------------------------------------------------------------------------
 * Initialization: discover and dlopen native macOS steamclient.dylib
 * -------------------------------------------------------------------------- */
static void try_open_dylib(const char *path) {
    if (!path || !*path || g_dylib) return;
    if (access(path, R_OK) != 0) return;

    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        const char *err = dlerror();
        snprintf(g_error_msg, sizeof(g_error_msg), "dlopen(%s): %s", path, err ? err : "unknown error");
        GP_LOG("%s", g_error_msg);
        return;
    }
    g_dylib = h;
    snprintf(g_dylib_path, sizeof(g_dylib_path), "%s", path);
    g_error_msg[0] = '\0';
    GP_LOG("loaded native steamclient.dylib from %s", g_dylib_path);
}

static void gp_bridge_init_once(void) {
    const char *v = getenv("GP_STEAM_BRIDGE_LOG");
    g_verbose = (v && v[0] && v[0] != '0');

    const char *m = getenv("GP_STEAM_BRIDGE_MOCK");
    if (m && m[0] && m[0] != '0') {
        g_mock_mode = 1;
        init_mock_vtables();
        p_CreateInterface = mock_create_interface;
        p_Steam_BGetCallback = mock_get_callback;
        p_Steam_FreeLastCallback = mock_free_callback;
        p_Steam_GetAPICallResult = mock_get_apicall_result;
        p_Steam_ReleaseThreadLocalMemory = mock_release_tls;
        g_exports_mask = GP_EXP_CREATE_INTERFACE | GP_EXP_GET_CALLBACK |
                         GP_EXP_FREE_CALLBACK | GP_EXP_GET_APICALL_RESULT | GP_EXP_RELEASE_TLS;
        snprintf(g_dylib_path, sizeof(g_dylib_path), "mock://steamclient.dylib");
        GP_LOG("initialized in MOCK mode");
        return;
    }

    const char *explicit_path = getenv("GAMEPORT_MAC_STEAMCLIENT");
    if (explicit_path && *explicit_path) {
        try_open_dylib(explicit_path);
    }
    if (!g_dylib) {
        const char *home = getenv("HOME");
        if (home && *home) {
            char buf[GP_BRIDGE_MAX_PATH];
            snprintf(buf, sizeof(buf),
                     "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib",
                     home);
            try_open_dylib(buf);
        }
    }
    if (!g_dylib) {
        try_open_dylib("/Applications/Steam.app/Contents/MacOS/steamclient.dylib");
    }

    if (!g_dylib) {
        if (!g_error_msg[0]) {
            snprintf(g_error_msg, sizeof(g_error_msg),
                     "native macOS steamclient.dylib not found (install and run Steam.app)");
        }
        GP_LOG("%s", g_error_msg);
        return;
    }

    p_CreateInterface = (fn_CreateInterface_t)dlsym(g_dylib, "CreateInterface");
    p_Steam_BGetCallback = (fn_Steam_BGetCallback_t)dlsym(g_dylib, "Steam_BGetCallback");
    p_Steam_FreeLastCallback = (fn_Steam_FreeLastCallback_t)dlsym(g_dylib, "Steam_FreeLastCallback");
    p_Steam_GetAPICallResult = (fn_Steam_GetAPICallResult_t)dlsym(g_dylib, "Steam_GetAPICallResult");
    p_Steam_ReleaseThreadLocalMemory = (fn_Steam_ReleaseThreadLocalMemory_t)dlsym(g_dylib, "Steam_ReleaseThreadLocalMemory");

    if (p_CreateInterface)                g_exports_mask |= GP_EXP_CREATE_INTERFACE;
    if (p_Steam_BGetCallback)             g_exports_mask |= GP_EXP_GET_CALLBACK;
    if (p_Steam_FreeLastCallback)         g_exports_mask |= GP_EXP_FREE_CALLBACK;
    if (p_Steam_GetAPICallResult)         g_exports_mask |= GP_EXP_GET_APICALL_RESULT;
    if (p_Steam_ReleaseThreadLocalMemory) g_exports_mask |= GP_EXP_RELEASE_TLS;

    GP_LOG("exports_mask=0x%x", g_exports_mask);
}

static void ensure_init(void) {
    pthread_once(&g_init_once, gp_bridge_init_once);
}

/* --------------------------------------------------------------------------
 * Wine UnixLib Handlers
 * -------------------------------------------------------------------------- */
static NTSTATUS gp_unix_ping(void *raw) {
    struct gp_ping_args *p = (struct gp_ping_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    p->protocol_version = GP_BRIDGE_PROTOCOL_VERSION;
    p->loaded = (g_dylib != NULL || g_mock_mode) ? 1u : 0u;
    p->mock_mode = (uint32_t)g_mock_mode;
    p->exports_mask = g_exports_mask;
    snprintf(p->dylib_path, sizeof(p->dylib_path), "%s", g_dylib_path);
    snprintf(p->error_msg, sizeof(p->error_msg), "%s", g_error_msg);
    return STATUS_SUCCESS;
}

static NTSTATUS gp_unix_create_interface(void *raw) {
    struct gp_create_interface_args *p = (struct gp_create_interface_args *)raw;
    if (!p || !p->name_ptr) return STATUS_INVALID_PARAMETER;
    ensure_init();
    if (!p_CreateInterface) {
        p->native_obj = 0;
        p->return_code = 1;
        return STATUS_UNSUCCESSFUL;
    }
    const char *name = (const char *)(uintptr_t)p->name_ptr;
    int rc = 0;
    void *obj = p_CreateInterface(name, &rc);
    p->native_obj = (uint64_t)(uintptr_t)obj;
    p->return_code = rc;
    GP_LOG("CreateInterface(\"%s\") -> %p (rc=%d)", name, obj, rc);
    return STATUS_SUCCESS;
}

typedef uint64_t (*sysv_vfn_u64_t)(void *this_ptr,
                                   uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                                   uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7);
typedef double   (*sysv_vfn_f64_t)(void *this_ptr,
                                   uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                                   uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7);
typedef float    (*sysv_vfn_f32_t)(void *this_ptr,
                                   uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                                   uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7);

static NTSTATUS gp_unix_vtable_call(void *raw) {
    struct gp_vtable_call_args *p = (struct gp_vtable_call_args *)raw;
    if (!p || !p->native_obj || p->slot >= GP_BRIDGE_VTABLE_SLOTS) {
        return STATUS_INVALID_PARAMETER;
    }
    void *obj = (void *)(uintptr_t)p->native_obj;
    void **vtable = *(void ***)obj;
    if (!vtable || !vtable[p->slot]) {
        p->ret_u64 = 0;
        p->ret_f64 = 0.0;
        return STATUS_UNSUCCESSFUL;
    }

    GP_LOG("vtable_call(obj=%p, slot=%u, flags=0x%x)", obj, p->slot, p->flags);

    if (p->flags & GP_CALL_FLAG_RET_DOUBLE) {
        sysv_vfn_f64_t fn = (sysv_vfn_f64_t)vtable[p->slot];
        p->ret_f64 = fn(obj, p->args[0], p->args[1], p->args[2], p->args[3],
                        p->args[4], p->args[5], p->args[6], p->args[7]);
        p->ret_u64 = 0;
    } else if (p->flags & GP_CALL_FLAG_RET_FLOAT) {
        sysv_vfn_f32_t fn = (sysv_vfn_f32_t)vtable[p->slot];
        float r = fn(obj, p->args[0], p->args[1], p->args[2], p->args[3],
                     p->args[4], p->args[5], p->args[6], p->args[7]);
        p->ret_f64 = (double)r;
        uint32_t bits = 0;
        memcpy(&bits, &r, sizeof(bits));
        p->ret_u64 = bits;
    } else {
        sysv_vfn_u64_t fn = (sysv_vfn_u64_t)vtable[p->slot];
        p->ret_u64 = fn(obj, p->args[0], p->args[1], p->args[2], p->args[3],
                        p->args[4], p->args[5], p->args[6], p->args[7]);
        p->ret_f64 = 0.0;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS gp_unix_get_callback(void *raw) {
    struct gp_get_callback_args *p = (struct gp_get_callback_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    if (!p_Steam_BGetCallback) {
        p->has_callback = 0;
        return STATUS_UNSUCCESSFUL;
    }
    struct native_callback_msg msg;
    memset(&msg, 0, sizeof(msg));
    bool ok = p_Steam_BGetCallback(p->pipe, &msg);
    p->has_callback = ok ? 1 : 0;
    if (ok) {
        p->steam_user  = msg.m_hSteamUser;
        p->callback_id = msg.m_iCallback;
        p->pub_param   = (uint64_t)(uintptr_t)msg.m_pubParam;
        p->cub_param   = msg.m_cubParam;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS gp_unix_free_callback(void *raw) {
    struct gp_free_callback_args *p = (struct gp_free_callback_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    if (p_Steam_FreeLastCallback) {
        p_Steam_FreeLastCallback(p->pipe);
    }
    return STATUS_SUCCESS;
}

static NTSTATUS gp_unix_get_apicall_result(void *raw) {
    struct gp_get_apicall_result_args *p = (struct gp_get_apicall_result_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    if (!p_Steam_GetAPICallResult) {
        p->ok = 0;
        p->failed = 1;
        return STATUS_UNSUCCESSFUL;
    }
    bool failed = false;
    bool ok = p_Steam_GetAPICallResult(p->pipe, p->api_call,
                                       (void *)(uintptr_t)p->buf_ptr, p->cub_buf,
                                       p->expected_callback, &failed);
    p->ok = ok ? 1 : 0;
    p->failed = failed ? 1 : 0;
    return STATUS_SUCCESS;
}

static NTSTATUS gp_unix_release_tls(void *raw) {
    struct gp_release_tls_args *p = (struct gp_release_tls_args *)raw;
    if (!p) return STATUS_INVALID_PARAMETER;
    ensure_init();
    if (p_Steam_ReleaseThreadLocalMemory) {
        p_Steam_ReleaseThreadLocalMemory(p->all_threads);
    }
    return STATUS_SUCCESS;
}

/* Exported Wine UnixLib tables (matched by Wine 9/10/11 & CrossOver 25/26+) */
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
