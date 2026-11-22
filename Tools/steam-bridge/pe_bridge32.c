/*
 * GamePort Steam Bridge — 32-bit WoW64 Wine Builtin PE DLL (steamclient.dll)
 * License: PolyForm Noncommercial 1.0.0 (see LICENSE)
 *
 * Bridges 32-bit Windows Steam games (classic Call of Duty, Source/Portal 2,
 * Fallout New Vegas, etc.) across Wine's WoW64 unixlib boundary to 64-bit
 * macOS steamclient.dylib, marshaling 64-bit strings and callback payloads
 * into <4 GB 32-bit PE buffers and preserving exact MSVC __thiscall stack cleanup.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "bridge_protocol.h"

typedef LONG NTSTATUS;
typedef uint64_t unixlib_handle_t;
typedef NTSTATUS (WINAPI *wine_unix_call_dispatcher_t)(unixlib_handle_t handle, unsigned int code, void *args);

#define MEMORY_WINE_UNIX_FUNCS 1000

typedef NTSTATUS (NTAPI *fn_NtQueryVirtualMemory_t)(
    HANDLE ProcessHandle,
    PVOID BaseAddress,
    ULONG MemoryInformationClass,
    PVOID MemoryInformation,
    SIZE_T MemoryInformationLength,
    PSIZE_T ReturnLength
);

static unixlib_handle_t            g_unix_handle = 0;
static wine_unix_call_dispatcher_t *g_unix_dispatcher_ptr = NULL;
static CRITICAL_SECTION            g_proxy_lock;
static int                         g_lock_ready = 0;

/* 32-bit (<4GB) ring buffer for 64-bit C strings returned by native macOS steamclient.dylib */
#define GP_STR_RING_SLOTS 32
#define GP_STR_RING_SIZE  512
static char g_str_ring[GP_STR_RING_SLOTS][GP_STR_RING_SIZE];
static LONG g_str_ring_idx = 0;

/* 32-bit (<4GB) payload buffer for Steam_BGetCallback */
static uint8_t g_cb_payload[16384];

static char *alloc_str_slot(void) {
    LONG idx = InterlockedIncrement(&g_str_ring_idx);
    return g_str_ring[(unsigned long)idx % GP_STR_RING_SLOTS];
}

static NTSTATUS gp_unix_call(unsigned int op, void *args) {
    if (!g_unix_handle || !g_unix_dispatcher_ptr || !*g_unix_dispatcher_ptr) {
        return (NTSTATUS)0xC0000001L;
    }
    return (*g_unix_dispatcher_ptr)(g_unix_handle, op, args);
}

/* --------------------------------------------------------------------------
 * 32-bit Proxy Objects (live <4GB while holding full 64-bit native_obj)
 * -------------------------------------------------------------------------- */
#define GP_MAX_PROXIES 256

struct gp_proxy32 {
    void     **vtable;
    uint64_t   native_obj;
    int        kind;
    char       iface_name[GP_BRIDGE_MAX_IFACE_NAME];
};

static struct gp_proxy32 g_proxies[GP_MAX_PROXIES];
static int               g_proxy_count = 0;

static void *g_vt_client[GP_BRIDGE_VTABLE_SLOTS];
static void *g_vt_user[GP_BRIDGE_VTABLE_SLOTS];
static void *g_vt_apps[GP_BRIDGE_VTABLE_SLOTS];
static void *g_vt_utils[GP_BRIDGE_VTABLE_SLOTS];
static void *g_vt_friends[GP_BRIDGE_VTABLE_SLOTS];
static void *g_vt_generic[GP_BRIDGE_VTABLE_SLOTS];

static int classify_interface(const char *name) {
    if (!name) return GP_IFACE_GENERIC;
    if (strncmp(name, "SteamClient", 11) == 0)  return GP_IFACE_STEAMCLIENT;
    if (strncmp(name, "SteamUser0", 10) == 0)   return GP_IFACE_STEAMUSER;
    if (strncmp(name, "SteamFriends", 12) == 0) return GP_IFACE_STEAMFRIENDS;
    if (strncmp(name, "STEAMAPPS_", 10) == 0 || strncmp(name, "SteamApps", 9) == 0)
        return GP_IFACE_STEAMAPPS;
    if (strncmp(name, "SteamUtils", 10) == 0)   return GP_IFACE_STEAMUTILS;
    return GP_IFACE_GENERIC;
}

static void **vtable_for_kind(int kind) {
    switch (kind) {
        case GP_IFACE_STEAMCLIENT:  return g_vt_client;
        case GP_IFACE_STEAMUSER:    return g_vt_user;
        case GP_IFACE_STEAMAPPS:    return g_vt_apps;
        case GP_IFACE_STEAMUTILS:   return g_vt_utils;
        case GP_IFACE_STEAMFRIENDS: return g_vt_friends;
        default:                    return g_vt_generic;
    }
}

static struct gp_proxy32 *wrap_native_object(uint64_t native_obj, const char *iface_name) {
    if (!native_obj) return NULL;
    int kind = classify_interface(iface_name);

    EnterCriticalSection(&g_proxy_lock);
    for (int i = 0; i < g_proxy_count; i++) {
        if (g_proxies[i].native_obj == native_obj) {
            if (g_proxies[i].kind == GP_IFACE_GENERIC && kind != GP_IFACE_GENERIC) {
                g_proxies[i].kind = kind;
                g_proxies[i].vtable = vtable_for_kind(kind);
            }
            struct gp_proxy32 *found = &g_proxies[i];
            LeaveCriticalSection(&g_proxy_lock);
            return found;
        }
    }
    if (g_proxy_count >= GP_MAX_PROXIES) {
        LeaveCriticalSection(&g_proxy_lock);
        return NULL;
    }
    struct gp_proxy32 *p = &g_proxies[g_proxy_count++];
    p->vtable = vtable_for_kind(kind);
    p->native_obj = native_obj;
    p->kind = kind;
    if (iface_name) {
        strncpy(p->iface_name, iface_name, sizeof(p->iface_name) - 1);
        p->iface_name[sizeof(p->iface_name) - 1] = '\0';
    } else {
        p->iface_name[0] = '\0';
    }
    LeaveCriticalSection(&g_proxy_lock);
    return p;
}

static uint64_t call_native_u64(struct gp_proxy32 *self, uint32_t slot, uint32_t flags,
                                uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    if (!self || !self->native_obj) return 0;
    struct gp_vtable_call_args req;
    memset(&req, 0, sizeof(req));
    req.native_obj = self->native_obj;
    req.slot = slot;
    req.flags = flags;
    req.args[0] = a0;
    req.args[1] = a1;
    req.args[2] = a2;
    req.args[3] = a3;
    if (flags & GP_CALL_FLAG_RET_CSTR) {
        char *buf = alloc_str_slot();
        buf[0] = '\0';
        req.str_buf_ptr = (uint64_t)(uintptr_t)buf;
        req.str_buf_cap = GP_STR_RING_SIZE;
    }
    if (gp_unix_call(GP_BRIDGE_OP_VTABLE_CALL, &req) != 0) return 0;
    return req.ret_u64;
}

/* --------------------------------------------------------------------------
 * Exact 32-bit MSVC __thiscall Virtual Method Thunks
 * -------------------------------------------------------------------------- */
static uint32_t __attribute__((thiscall)) tc_stub0(struct gp_proxy32 *self) {
    (void)self;
    return 0;
}

/* ISteamClient core slots (SteamClient017..021) */
static int32_t __attribute__((thiscall)) tc_client_create_pipe(struct gp_proxy32 *self) {
    return (int32_t)call_native_u64(self, 0, 0, 0, 0, 0, 0);
}
static bool __attribute__((thiscall)) tc_client_release_pipe(struct gp_proxy32 *self, int32_t pipe) {
    return call_native_u64(self, 1, 0, (uint64_t)(int64_t)pipe, 0, 0, 0) != 0;
}
static int32_t __attribute__((thiscall)) tc_client_connect_global_user(struct gp_proxy32 *self, int32_t pipe) {
    return (int32_t)call_native_u64(self, 2, 0, (uint64_t)(int64_t)pipe, 0, 0, 0);
}
static int32_t __attribute__((thiscall)) tc_client_create_local_user(struct gp_proxy32 *self, int32_t *pipe, int32_t acct) {
    return (int32_t)call_native_u64(self, 3, 0, (uint64_t)(uintptr_t)pipe, (uint64_t)(int64_t)acct, 0, 0);
}
static void __attribute__((thiscall)) tc_client_release_user(struct gp_proxy32 *self, int32_t pipe, int32_t user) {
    call_native_u64(self, 4, 0, (uint64_t)(int64_t)pipe, (uint64_t)(int64_t)user, 0, 0);
}

#define DEFINE_CLIENT_IFACE_GETTER_3(NAME, SLOT)                                             \
    static void *__attribute__((thiscall)) NAME(                                             \
        struct gp_proxy32 *self, int32_t user, int32_t pipe, const char *ver                 \
    ) {                                                                                      \
        uint64_t raw = call_native_u64(self, SLOT, 0, (uint64_t)(int64_t)user,               \
                                       (uint64_t)(int64_t)pipe, (uint64_t)(uintptr_t)ver, 0);\
        return wrap_native_object(raw, ver);                                                 \
    }

#define DEFINE_CLIENT_IFACE_GETTER_2(NAME, SLOT)                                             \
    static void *__attribute__((thiscall)) NAME(                                             \
        struct gp_proxy32 *self, int32_t pipe, const char *ver                               \
    ) {                                                                                      \
        uint64_t raw = call_native_u64(self, SLOT, 0, (uint64_t)(int64_t)pipe,               \
                                       (uint64_t)(uintptr_t)ver, 0, 0);                      \
        return wrap_native_object(raw, ver);                                                 \
    }

DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_user,           5)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_gameserver,     6)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_friends,        8)
DEFINE_CLIENT_IFACE_GETTER_2(tc_client_get_utils,          9)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_matchmaking,    10)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_mm_servers,     11)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_generic,        12)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_user_stats,     13)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_gs_stats,       14)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_apps,           15)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_networking,     16)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_remote_storage, 17)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_screenshots,    18)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_http,           23)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_controller,     25)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_ugc,            26)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_inventory,      35)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_video,          36)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_parental,       37)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_input,          38)
DEFINE_CLIENT_IFACE_GETTER_3(tc_client_get_parties,        39)

static void __attribute__((thiscall)) tc_client_run_frame(struct gp_proxy32 *self) {
    call_native_u64(self, 20, 0, 0, 0, 0, 0);
}
static bool __attribute__((thiscall)) tc_client_shutdown_if_closed(struct gp_proxy32 *self) {
    return call_native_u64(self, 34, 0, 0, 0, 0, 0) != 0;
}

/* ISteamUser core slots */
static int32_t __attribute__((thiscall)) tc_user_get_hsteamuser(struct gp_proxy32 *self) {
    return (int32_t)call_native_u64(self, 0, 0, 0, 0, 0, 0);
}
static bool __attribute__((thiscall)) tc_user_b_logged_on(struct gp_proxy32 *self) {
    return call_native_u64(self, 1, 0, 0, 0, 0, 0) != 0;
}
/* 32-bit MSVC __thiscall CSteamID sret: hidden CSteamID *out is arg 0 on stack, returns out in EAX */
static uint64_t *__attribute__((thiscall)) tc_user_get_steam_id(struct gp_proxy32 *self, uint64_t *out_id) {
    uint64_t id = call_native_u64(self, 2, GP_CALL_FLAG_MSVC_SRET8, 0, 0, 0, 0);
    if (out_id) *out_id = id;
    return out_id;
}

/* ISteamApps core slots */
static bool __attribute__((thiscall)) tc_apps_b_is_subscribed(struct gp_proxy32 *self) {
    return call_native_u64(self, 0, 0, 0, 0, 0, 0) != 0;
}
static bool __attribute__((thiscall)) tc_apps_b_is_low_violence(struct gp_proxy32 *self) {
    return call_native_u64(self, 1, 0, 0, 0, 0, 0) != 0;
}
static bool __attribute__((thiscall)) tc_apps_b_is_cybercafe(struct gp_proxy32 *self) {
    return call_native_u64(self, 2, 0, 0, 0, 0, 0) != 0;
}
static bool __attribute__((thiscall)) tc_apps_b_is_vac_banned(struct gp_proxy32 *self) {
    return call_native_u64(self, 3, 0, 0, 0, 0, 0) != 0;
}
static const char *__attribute__((thiscall)) tc_apps_get_lang(struct gp_proxy32 *self) {
    return (const char *)(uintptr_t)call_native_u64(self, 6, GP_CALL_FLAG_RET_CSTR, 0, 0, 0, 0);
}
static const char *__attribute__((thiscall)) tc_apps_get_avail_langs(struct gp_proxy32 *self) {
    return (const char *)(uintptr_t)call_native_u64(self, 7, GP_CALL_FLAG_RET_CSTR, 0, 0, 0, 0);
}
static bool __attribute__((thiscall)) tc_apps_b_is_subscribed_app(struct gp_proxy32 *self, uint32_t app_id) {
    return call_native_u64(self, 8, 0, app_id, 0, 0, 0) != 0;
}
static bool __attribute__((thiscall)) tc_apps_b_is_dlc_installed(struct gp_proxy32 *self, uint32_t app_id) {
    return call_native_u64(self, 9, 0, app_id, 0, 0, 0) != 0;
}

/* ISteamUtils core slots */
static uint32_t __attribute__((thiscall)) tc_utils_seconds_active(struct gp_proxy32 *self) {
    return (uint32_t)call_native_u64(self, 0, 0, 0, 0, 0, 0);
}
static const char *__attribute__((thiscall)) tc_utils_ip_country(struct gp_proxy32 *self) {
    return (const char *)(uintptr_t)call_native_u64(self, 2, GP_CALL_FLAG_RET_CSTR, 0, 0, 0, 0);
}
static uint32_t __attribute__((thiscall)) tc_utils_get_appid(struct gp_proxy32 *self) {
    return (uint32_t)call_native_u64(self, 9, 0, 0, 0, 0, 0);
}

/* ISteamFriends core slots */
static const char *__attribute__((thiscall)) tc_friends_persona_name(struct gp_proxy32 *self) {
    return (const char *)(uintptr_t)call_native_u64(self, 0, GP_CALL_FLAG_RET_CSTR, 0, 0, 0, 0);
}

static void init_vtables(void) {
    for (int i = 0; i < GP_BRIDGE_VTABLE_SLOTS; i++) {
        g_vt_client[i]  = (void *)tc_stub0;
        g_vt_user[i]    = (void *)tc_stub0;
        g_vt_apps[i]    = (void *)tc_stub0;
        g_vt_utils[i]   = (void *)tc_stub0;
        g_vt_friends[i] = (void *)tc_stub0;
        g_vt_generic[i] = (void *)tc_stub0;
    }

    g_vt_client[0]  = (void *)tc_client_create_pipe;
    g_vt_client[1]  = (void *)tc_client_release_pipe;
    g_vt_client[2]  = (void *)tc_client_connect_global_user;
    g_vt_client[3]  = (void *)tc_client_create_local_user;
    g_vt_client[4]  = (void *)tc_client_release_user;
    g_vt_client[5]  = (void *)tc_client_get_user;
    g_vt_client[6]  = (void *)tc_client_get_gameserver;
    g_vt_client[8]  = (void *)tc_client_get_friends;
    g_vt_client[9]  = (void *)tc_client_get_utils;
    g_vt_client[10] = (void *)tc_client_get_matchmaking;
    g_vt_client[11] = (void *)tc_client_get_mm_servers;
    g_vt_client[12] = (void *)tc_client_get_generic;
    g_vt_client[13] = (void *)tc_client_get_user_stats;
    g_vt_client[14] = (void *)tc_client_get_gs_stats;
    g_vt_client[15] = (void *)tc_client_get_apps;
    g_vt_client[16] = (void *)tc_client_get_networking;
    g_vt_client[17] = (void *)tc_client_get_remote_storage;
    g_vt_client[18] = (void *)tc_client_get_screenshots;
    g_vt_client[20] = (void *)tc_client_run_frame;
    g_vt_client[23] = (void *)tc_client_get_http;
    g_vt_client[25] = (void *)tc_client_get_controller;
    g_vt_client[26] = (void *)tc_client_get_ugc;
    g_vt_client[34] = (void *)tc_client_shutdown_if_closed;
    g_vt_client[35] = (void *)tc_client_get_inventory;
    g_vt_client[36] = (void *)tc_client_get_video;
    g_vt_client[37] = (void *)tc_client_get_parental;
    g_vt_client[38] = (void *)tc_client_get_input;
    g_vt_client[39] = (void *)tc_client_get_parties;

    g_vt_user[0] = (void *)tc_user_get_hsteamuser;
    g_vt_user[1] = (void *)tc_user_b_logged_on;
    g_vt_user[2] = (void *)tc_user_get_steam_id;

    g_vt_apps[0] = (void *)tc_apps_b_is_subscribed;
    g_vt_apps[1] = (void *)tc_apps_b_is_low_violence;
    g_vt_apps[2] = (void *)tc_apps_b_is_cybercafe;
    g_vt_apps[3] = (void *)tc_apps_b_is_vac_banned;
    g_vt_apps[6] = (void *)tc_apps_get_lang;
    g_vt_apps[7] = (void *)tc_apps_get_avail_langs;
    g_vt_apps[8] = (void *)tc_apps_b_is_subscribed_app;
    g_vt_apps[9] = (void *)tc_apps_b_is_dlc_installed;

    g_vt_utils[0] = (void *)tc_utils_seconds_active;
    g_vt_utils[2] = (void *)tc_utils_ip_country;
    g_vt_utils[9] = (void *)tc_utils_get_appid;

    g_vt_friends[0] = (void *)tc_friends_persona_name;
}

/* --------------------------------------------------------------------------
 * Standard Valve 32-bit steamclient.dll C Exports
 * -------------------------------------------------------------------------- */
#pragma pack(push, 4)
struct win32_callback_msg {
    int32_t  m_hSteamUser;
    int32_t  m_iCallback;
    uint8_t *m_pubParam;
    int32_t  m_cubParam;
};
#pragma pack(pop)

__declspec(dllexport)
void *__cdecl CreateInterface(const char *pName, int *pReturnCode) {
    if (!pName) {
        if (pReturnCode) *pReturnCode = 1;
        return NULL;
    }
    struct gp_create_interface_args req;
    memset(&req, 0, sizeof(req));
    req.name_ptr = (uint64_t)(uintptr_t)pName;
    if (gp_unix_call(GP_BRIDGE_OP_CREATE_INTERFACE, &req) != 0 || req.native_obj == 0) {
        if (pReturnCode) *pReturnCode = req.return_code ? req.return_code : 1;
        return NULL;
    }
    if (pReturnCode) *pReturnCode = req.return_code;
    return wrap_native_object(req.native_obj, pName);
}

__declspec(dllexport)
bool __cdecl Steam_BGetCallback(int32_t hSteamPipe, struct win32_callback_msg *pCallbackMsg) {
    struct gp_get_callback_args req;
    memset(&req, 0, sizeof(req));
    req.pipe = hSteamPipe;
    req.copy_buf_ptr = (uint64_t)(uintptr_t)g_cb_payload;
    req.copy_buf_cap = sizeof(g_cb_payload);
    if (gp_unix_call(GP_BRIDGE_OP_GET_CALLBACK, &req) != 0 || !req.has_callback) {
        return false;
    }
    if (pCallbackMsg) {
        pCallbackMsg->m_hSteamUser = req.steam_user;
        pCallbackMsg->m_iCallback  = req.callback_id;
        pCallbackMsg->m_pubParam   = (uint8_t *)(uintptr_t)req.pub_param;
        pCallbackMsg->m_cubParam   = req.cub_param;
    }
    return true;
}

__declspec(dllexport)
void __cdecl Steam_FreeLastCallback(int32_t hSteamPipe) {
    struct gp_free_callback_args req;
    memset(&req, 0, sizeof(req));
    req.pipe = hSteamPipe;
    gp_unix_call(GP_BRIDGE_OP_FREE_CALLBACK, &req);
}

__declspec(dllexport)
bool __cdecl Steam_GetAPICallResult(
    int32_t hSteamPipe, uint64_t hSteamAPICall,
    void *pCallback, int32_t cubCallback,
    int32_t iCallbackExpected, bool *pbFailed
) {
    struct gp_get_apicall_result_args req;
    memset(&req, 0, sizeof(req));
    req.pipe = hSteamPipe;
    req.api_call = hSteamAPICall;
    req.buf_ptr = (uint64_t)(uintptr_t)pCallback;
    req.cub_buf = cubCallback;
    req.expected_callback = iCallbackExpected;
    if (gp_unix_call(GP_BRIDGE_OP_GET_APICALL_RESULT, &req) != 0) {
        if (pbFailed) *pbFailed = true;
        return false;
    }
    if (pbFailed) *pbFailed = (req.failed != 0);
    return req.ok != 0;
}

__declspec(dllexport)
void __cdecl Steam_ReleaseThreadLocalMemory(int32_t bThreadExit) {
    struct gp_release_tls_args req;
    memset(&req, 0, sizeof(req));
    req.all_threads = bThreadExit;
    gp_unix_call(GP_BRIDGE_OP_RELEASE_TLS, &req);
}

__declspec(dllexport) void __cdecl Breakpad_SteamSetSteamID(uint64_t ulSteamID) { (void)ulSteamID; }
__declspec(dllexport) void __cdecl Breakpad_SteamMiniDumpInit(uint32_t a, const char *b, const char *c) { (void)a; (void)b; (void)c; }
__declspec(dllexport) void __cdecl Breakpad_SteamWriteMiniDumpSetComment(const char *msg) { (void)msg; }
__declspec(dllexport) void __cdecl Breakpad_SteamWriteMiniDumpUsingExceptionInfoWithBuildId(int a, int b) { (void)a; (void)b; }

__declspec(dllexport)
int __cdecl GPBridge_GetInfo(struct gp_ping_args *out_info) {
    if (!out_info) return 0;
    memset(out_info, 0, sizeof(*out_info));
    return gp_unix_call(GP_BRIDGE_OP_PING, out_info) == 0 ? 1 : 0;
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    (void)lpvReserved;
    if (fdwReason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hinstDLL);
        InitializeCriticalSection(&g_proxy_lock);
        g_lock_ready = 1;
        init_vtables();

        HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
        if (ntdll) {
            fn_NtQueryVirtualMemory_t pNtQVM =
                (fn_NtQueryVirtualMemory_t)GetProcAddress(ntdll, "NtQueryVirtualMemory");
            g_unix_dispatcher_ptr =
                (wine_unix_call_dispatcher_t *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher");
            if (pNtQVM && g_unix_dispatcher_ptr) {
                unixlib_handle_t handle = 0;
                NTSTATUS st = pNtQVM(GetCurrentProcess(), hinstDLL,
                                     MEMORY_WINE_UNIX_FUNCS,
                                     &handle, sizeof(handle), NULL);
                if (st == 0) {
                    g_unix_handle = handle;
                }
            }
        }
    } else if (fdwReason == DLL_PROCESS_DETACH) {
        if (g_lock_ready) {
            DeleteCriticalSection(&g_proxy_lock);
            g_lock_ready = 0;
        }
    }
    return TRUE;
}
