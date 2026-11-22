/*
 * GamePort Steam Bridge — Windows x64 Wine Builtin PE DLL (steamclient64.dll)
 * License: PolyForm Noncommercial 1.0.0 (see LICENSE)
 *
 * Exports the standard Valve steamclient64.dll entry points loaded by games'
 * bundled steam_api64.dll and forwards them over Wine's unixlib boundary to
 * steamclient64.so -> native macOS steamclient.dylib.
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

/* Wine ntdll MemoryWineUnixFuncs info class */
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

static NTSTATUS gp_unix_call(unsigned int op, void *args) {
    if (!g_unix_handle || !g_unix_dispatcher_ptr || !*g_unix_dispatcher_ptr) {
        return (NTSTATUS)0xC0000001L; /* STATUS_UNSUCCESSFUL */
    }
    return (*g_unix_dispatcher_ptr)(g_unix_handle, op, args);
}

/* --------------------------------------------------------------------------
 * Proxy Object Table (caches native_obj -> Windows-ABI proxy vtable object)
 * -------------------------------------------------------------------------- */
#define GP_MAX_PROXIES 256

struct gp_proxy {
    void     **vtable;
    uint64_t   native_obj;
    int        kind;
    char       iface_name[GP_BRIDGE_MAX_IFACE_NAME];
};

static struct gp_proxy g_proxies[GP_MAX_PROXIES];
static int             g_proxy_count = 0;
static void           *g_proxy_vtable[GP_BRIDGE_VTABLE_SLOTS];

static int classify_interface(const char *name) {
    if (!name) return GP_IFACE_GENERIC;
    if (strncmp(name, "SteamClient", 11) == 0)  return GP_IFACE_STEAMCLIENT;
    if (strncmp(name, "SteamUser0", 10) == 0)   return GP_IFACE_STEAMUSER;
    if (strncmp(name, "SteamFriends", 12) == 0) return GP_IFACE_STEAMFRIENDS;
    if (strncmp(name, "STEAMAPPS_", 10) == 0 || strncmp(name, "SteamApps", 9) == 0)
        return GP_IFACE_STEAMAPPS;
    if (strncmp(name, "SteamUtils", 10) == 0)   return GP_IFACE_STEAMUTILS;
    if (strncmp(name, "STEAMHTMLSURFACE_", 17) == 0) return GP_IFACE_STEAMHTMLSURFACE;
    if (strncmp(name, "STEAMHTTP_", 10) == 0)   return GP_IFACE_STEAMHTTP;
    if (strncmp(name, "STEAMREMOTESTORAGE_", 19) == 0) return GP_IFACE_STEAMREMOTESTORAGE;
    if (strncmp(name, "STEAMINVENTORY_", 15) == 0) return GP_IFACE_STEAMINVENTORY;
    if (strncmp(name, "SteamController", 15) == 0) return GP_IFACE_STEAMCONTROLLER;
    if (strncmp(name, "SteamInput", 10) == 0) return GP_IFACE_STEAMINPUT;
    if (strncmp(name, "STEAMUSERSTATS_", 15) == 0) return GP_IFACE_STEAMUSERSTATS;
    if (strncmp(name, "SteamGameCoordinator", 20) == 0) return GP_IFACE_STEAMGC;
    if (strncmp(name, "SteamNetworkingUtils", 20) == 0) return GP_IFACE_STEAMNETUTILS;
    /* "SteamGameServer015" (not "SteamGameServerStats001") */
    if (strncmp(name, "SteamGameServer0", 16) == 0) return GP_IFACE_STEAMGAMESERVER;
    return GP_IFACE_GENERIC;
}

static const char *probe_steam_version_string(uint64_t candidate) {
    if (candidate < 0x10000ULL) return NULL;
    MEMORY_BASIC_INFORMATION mbi;
    if (VirtualQuery((LPCVOID)(uintptr_t)candidate, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    DWORD prot = mbi.Protect & 0xFF;
    if (prot == PAGE_NOACCESS || prot == PAGE_EXECUTE) return NULL;
    const char *s = (const char *)(uintptr_t)candidate;
    if (strncmp(s, "Steam", 5) == 0 || strncmp(s, "STEAM", 5) == 0 || strncmp(s, "Client", 6) == 0) {
        return s;
    }
    return NULL;
}

/* True when [addr, addr+len) is committed, writable memory in this (game) process. */
static bool gp_is_writable(uint64_t addr, size_t len) {
    if (addr < 0x10000ULL) return false;
    MEMORY_BASIC_INFORMATION mbi;
    if (VirtualQuery((LPCVOID)(uintptr_t)addr, &mbi, sizeof(mbi)) == 0) return false;
    if (mbi.State != MEM_COMMIT) return false;
    DWORD prot = mbi.Protect & 0xFF;
    if (!(prot & (PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) return false;
    if (mbi.Protect & PAGE_GUARD) return false;
    uint64_t end = (uint64_t)(uintptr_t)mbi.BaseAddress + mbi.RegionSize;
    return addr + len <= end;
}

static struct gp_proxy *wrap_native_object(uint64_t native_obj, const char *iface_name) {
    if (!native_obj) return NULL;
    int kind = classify_interface(iface_name);

    EnterCriticalSection(&g_proxy_lock);
    for (int i = 0; i < g_proxy_count; i++) {
        if (g_proxies[i].native_obj == native_obj) {
            if (g_proxies[i].kind == GP_IFACE_GENERIC && kind != GP_IFACE_GENERIC) {
                g_proxies[i].kind = kind;
            }
            struct gp_proxy *found = &g_proxies[i];
            LeaveCriticalSection(&g_proxy_lock);
            return found;
        }
    }
    if (g_proxy_count >= GP_MAX_PROXIES) {
        LeaveCriticalSection(&g_proxy_lock);
        return NULL;
    }
    struct gp_proxy *p = &g_proxies[g_proxy_count++];
    p->vtable = g_proxy_vtable;
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

/* --------------------------------------------------------------------------
 * Windows x64 ABI -> Wine UnixLib -> macOS SysV ABI Virtual Method Dispatcher
 * -------------------------------------------------------------------------- */
static uint64_t gp_dispatch_slot(
    struct gp_proxy *self,
    uint32_t slot,
    uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
    uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7
) {
    if (!self || !self->native_obj) return 0;

    /* ISteamHTMLSurface has a virtual destructor at slot 0:
     * MSVC puts 1 destructor slot in the vtable (Init is slot 1), while macOS
     * Itanium C++ ABI puts 2 destructor slots (D1 + D0, so Init is slot 2). */
    if (self->kind == GP_IFACE_STEAMHTMLSURFACE) {
        if (slot == 0) return 0;
        slot += 1;
    }

    struct gp_vtable_call_args call;
    memset(&call, 0, sizeof(call));
    call.native_obj = self->native_obj;
    call.slot = slot;

    /* MSVC x64 CSteamID sret adaptation:
     * On Windows MSVC x64, non-trivial CSteamID returns pass a hidden pointer in RDX (a0).
     * On macOS SysV x86_64, CSteamID is returned directly in RAX with no hidden pointer.
     */
    bool is_msvc_sret8 = false;
    if (self->kind == GP_IFACE_STEAMUSER && slot == 2) {
        /* ISteamUser::GetSteamID() */
        is_msvc_sret8 = (a0 >= 0x10000ULL);
    } else if (self->kind == GP_IFACE_STEAMFRIENDS && (slot == 4 || slot == 19)) {
        /* ISteamFriends017::GetFriendByIndex (4) / GetClanByIndex (19).
         * Slot 8 is GetFriendGamePlayed(CSteamID, FriendGameInfo_t *): its first argument is a
         * SteamID value, not a return pointer (see the out-struct marshaling below). */
        is_msvc_sret8 = (a0 >= 0x10000ULL);
    } else if (self->kind == GP_IFACE_STEAMGAMESERVER && (slot == 10 || slot == 39)) {
        /* ISteamGameServer015::GetSteamID (10) / CreateUnauthenticatedUserConnection (39) */
        is_msvc_sret8 = (a0 >= 0x10000ULL);
    }

    /* Never write a return value through something that is not writable memory in this process. */
    if (is_msvc_sret8 && !gp_is_writable(a0, sizeof(uint64_t))) {
        is_msvc_sret8 = false;
    }

    if (is_msvc_sret8) {
        call.flags = GP_CALL_FLAG_MSVC_SRET8;
        call.args[0] = a1;
        call.args[1] = a2;
        call.args[2] = a3;
        call.args[3] = a4;
        call.args[4] = a5;
        call.args[5] = a6;
        call.args[6] = a7;
        call.args[7] = 0;
        if (gp_unix_call(GP_BRIDGE_OP_VTABLE_CALL, &call) != 0) return 0;
        *(uint64_t *)(uintptr_t)a0 = call.ret_u64;
        return a0;
    }

    call.args[0] = a0;
    call.args[1] = a1;
    call.args[2] = a2;
    call.args[3] = a3;
    call.args[4] = a4;
    call.args[5] = a5;
    call.args[6] = a6;
    call.args[7] = a7;

    /* Do not pass Windows x64 function pointers into native macOS Steam callbacks/hooks. */
    if ((self->kind == GP_IFACE_STEAMCLIENT && slot == 22) ||
        (self->kind == GP_IFACE_STEAMUTILS && slot == 16) ||
        (self->kind == GP_IFACE_STEAMNETUTILS && slot == 13)) {
        return 0;
    }

    /* Known C-string-returning methods (marshaled cleanly across the host daemon socket) */
    if ((self->kind == GP_IFACE_STEAMAPPS && (slot == 4 || slot == 5)) ||
        (self->kind == GP_IFACE_STEAMFRIENDS && slot == 0) ||
        (self->kind == GP_IFACE_STEAMUTILS && slot == 4)) {
        call.flags |= GP_CALL_FLAG_RET_CSTR;
    }

    if (self->kind == GP_IFACE_STEAMCLIENT && slot >= 5 && slot <= 45) {
        call.flags |= GP_CALL_FLAG_NO_AUTO_CSTR;
    }

    /* Out-pointer / buffer marshaling across host daemon socket (out_arg_idx uses 1..8, 0=unused) */
    if (self->kind == GP_IFACE_STEAMCLIENT) {
        if (slot == 3) {
            /* CreateLocalUser(HSteamPipe *phSteamPipe, EAccountType): used by SteamGameServer_Init
             * (listen servers, e.g. TF2 training / offline practice). The pipe is written back;
             * 0 going in asks Steam for a new pipe, which is what the game passes. */
            if (a0 >= 0x10000ULL) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = 4; }
        } else if (slot == 7) {
            /* SetLocalIPBinding(const SteamIPAddress_t &unIP, uint16 usPort):
             * 16-byte IPv6 + 4-byte ESteamIPType = 20 bytes, read from the game's memory. */
            if (a0 >= 0x10000ULL) { call.in_buf_arg_idx = 1; call.in_buf_len = 20; }
        }
    } else if (self->kind == GP_IFACE_STEAMGAMESERVER) {
        /* ISteamGameServer015 — used by listen servers (TF2 training, offline practice, local servers). */
        if (slot == 25) {
            /* GetAuthSessionTicket(void *pTicket, int cbMaxTicket, uint32 *pcbTicket, const SteamNetworkingIdentity *pSnid) */
            if (a0 >= 0x10000ULL && a1 > 0 && a1 <= 16384) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = (uint32_t)a1; }
            if (a2 >= 0x10000ULL) { call.out_arg_idx[1] = 3; call.out_arg_len[1] = 4; }
            if (a3 >= 0x10000ULL) { call.in_buf_arg_idx = 4; call.in_buf_len = 136; }
        } else if (slot == 26 || slot == 34) {
            /* BeginAuthSession(const void *pAuthTicket, int cbAuthTicket, CSteamID) /
             * HandleIncomingPacket(const void *pData, int cbData, uint32 srcIP, uint16 srcPort) */
            if (a0 >= 0x10000ULL && a1 > 0) { call.in_buf_arg_idx = 1; call.in_buf_len = (uint32_t)a1; }
        } else if (slot == 33) {
            /* SteamIPAddress_t GetPublicIP(): 20-byte struct returned through a hidden pointer (a0). */
            if (gp_is_writable(a0, 20)) {
                call.flags |= GP_CALL_FLAG_RET_BLOB20;
                call.out_arg_idx[0] = 1; call.out_arg_len[0] = 20;
                if (gp_unix_call(GP_BRIDGE_OP_VTABLE_CALL, &call) != 0) memset((void *)(uintptr_t)a0, 0, 20);
                return a0;
            }
            return 0;
        } else if (slot == 35) {
            /* GetNextOutgoingPacket(void *pOut, int cbMaxOut, uint32 *pNetAdr, uint16 *pPort) */
            if (a0 >= 0x10000ULL && a1 > 0) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = (uint32_t)a1; }
            if (a2 >= 0x10000ULL) { call.out_arg_idx[1] = 3; call.out_arg_len[1] = 4; }
            if (a3 >= 0x10000ULL) { call.out_arg_idx[2] = 4; call.out_arg_len[2] = 2; }
        } else if (slot == 38) {
            /* SendUserConnectAndAuthenticate_DEPRECATED(uint32 ip, const void *pvAuthBlob, uint32 cub, CSteamID *pSteamIDUser) */
            if (a1 >= 0x10000ULL && a2 > 0) { call.in_buf_arg_idx = 2; call.in_buf_len = (uint32_t)a2; }
            if (a3 >= 0x10000ULL) { call.out_arg_idx[0] = 4; call.out_arg_len[0] = 8; }
        }
    } else if (self->kind == GP_IFACE_STEAMHTTP) {
        if (slot == 5 || slot == 6) {
            /* SendHTTPRequest / SendHTTPRequestAndStreamResponse(hReq, SteamAPICall_t *pCallHandle) */
            if (a1 >= 0x10000ULL) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = 8; }
        } else if (slot == 9) {
            /* GetHTTPResponseHeaderSize(hReq, name, uint32 *outSize) */
            if (a2 >= 0x10000ULL) { call.out_arg_idx[0] = 3; call.out_arg_len[0] = 4; }
        } else if (slot == 10) {
            /* GetHTTPResponseHeaderValue(hReq, name, uint8 *buf, uint32 bufSize) */
            if (a2 >= 0x10000ULL && a3 > 0) { call.out_arg_idx[0] = 3; call.out_arg_len[0] = (uint32_t)a3; }
        } else if (slot == 11 || slot == 15) {
            /* GetHTTPResponseBodySize / GetHTTPDownloadProgressPct(hReq, uint32/float *out) */
            if (a1 >= 0x10000ULL) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = 4; }
        } else if (slot == 12) {
            /* GetHTTPResponseBodyData(hReq, uint8 *buf, uint32 bufSize) */
            if (a1 >= 0x10000ULL && a2 > 0) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = (uint32_t)a2; }
        } else if (slot == 13) {
            /* GetHTTPStreamingResponseBodyData(hReq, offset, uint8 *buf, uint32 bufSize) */
            if (a2 >= 0x10000ULL && a3 > 0) { call.out_arg_idx[0] = 3; call.out_arg_len[0] = (uint32_t)a3; }
        }
    } else if (self->kind == GP_IFACE_STEAMUTILS) {
        if (slot == 5) {
            /* GetImageSize(iImage, uint32 *pnWidth, uint32 *pnHeight) */
            if (a1 >= 0x10000ULL) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = 4; }
            if (a2 >= 0x10000ULL) { call.out_arg_idx[1] = 3; call.out_arg_len[1] = 4; }
        } else if (slot == 6) {
            /* GetImageRGBA(iImage, uint8 *pubDest, int nDestBufferSize) */
            if (a1 >= 0x10000ULL && a2 > 0) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = (uint32_t)a2; }
        } else if (slot == 11) {
            /* IsAPICallCompleted(hSteamAPICall, bool *pbFailed) */
            if (a1 >= 0x10000ULL) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = 1; }
        } else if (slot == 22) {
            /* GetEnteredGamepadTextInput(char *pchText, uint32 cchText) */
            if (a0 >= 0x10000ULL && a1 > 0 && a1 <= 65536) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = (uint32_t)a1; }
        } else if (slot == 32) {
            /* FilterText(ETextFilteringContext, CSteamID source, const char *pchIn, char *pchOut, uint32 cbOut) */
            if (a1 == 0) {
                /* No source user (server/system text): native Steam crashes on this, and there is
                 * nothing to filter, so hand the text back unchanged. */
                if (!gp_is_writable(a3, 1) || a4 == 0) return 0;
                const char *in = (a2 >= 0x10000ULL) ? (const char *)(uintptr_t)a2 : "";
                size_t n = strnlen(in, (size_t)a4 - 1);
                memcpy((void *)(uintptr_t)a3, in, n);
                ((char *)(uintptr_t)a3)[n] = '\0';
                return (uint64_t)n;
            }
            if (a3 >= 0x10000ULL && a4 > 0 && a4 <= 65536) { call.out_arg_idx[0] = 4; call.out_arg_len[0] = (uint32_t)a4; }
        } else if (slot == 13) {
            /* GetAPICallResult(hSteamAPICall, void *pCallback, int cubCallback, int expected, bool *pbFailed) */
            if (a1 >= 0x10000ULL && a2 > 0) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = (uint32_t)a2; }
            if (a4 >= 0x10000ULL) { call.out_arg_idx[1] = 5; call.out_arg_len[1] = 1; }
        }
    } else if (self->kind == GP_IFACE_STEAMUSER) {
        /* ISteamUser023 slots (Steamworks SDK order). */
        if (slot == 3) {
            /* InitiateGameConnection_DEPRECATED(void *pAuthBlob, int cbMaxAuthBlob, CSteamID, uint32 ip, uint16 port, bool) */
            if (a0 >= 0x10000ULL && a1 > 0 && a1 <= 16384) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = (uint32_t)a1; }
        } else if (slot == 6) {
            /* GetUserDataFolder(char *pchBuffer, int cubBuffer) */
            if (a0 >= 0x10000ULL && a1 > 0 && a1 <= 4096) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = (uint32_t)a1; }
        } else if (slot == 9) {
            /* GetAvailableVoice(uint32 *pcbCompressed, uint32 *pcbUncompressed_Deprecated, uint32 rate) */
            if (a0 >= 0x10000ULL) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = 4; }
            if (a1 >= 0x10000ULL) { call.out_arg_idx[1] = 2; call.out_arg_len[1] = 4; }
        } else if (slot == 10) {
            /* GetVoice(bool bWantCompressed, void *pDest, uint32 cbDest, uint32 *nBytesWritten, ...deprecated) */
            if (a1 >= 0x10000ULL && a2 > 0) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = (uint32_t)a2; }
            if (a3 >= 0x10000ULL) { call.out_arg_idx[1] = 4; call.out_arg_len[1] = 4; }
        } else if (slot == 11) {
            /* DecompressVoice(const void *pCompressed, uint32 cbCompressed, void *pDest, uint32 cbDest, uint32 *nBytesWritten, uint32 rate) */
            if (a0 >= 0x10000ULL && a1 > 0) { call.in_buf_arg_idx = 1; call.in_buf_len = (uint32_t)a1; }
            if (a2 >= 0x10000ULL && a3 > 0) { call.out_arg_idx[0] = 3; call.out_arg_len[0] = (uint32_t)a3; }
            if (a4 >= 0x10000ULL) { call.out_arg_idx[1] = 5; call.out_arg_len[1] = 4; }
        } else if (slot == 13) {
            /* GetAuthSessionTicket(void *pTicket, int cbMaxTicket, uint32 *pcbTicket, const SteamNetworkingIdentity *pSnid) */
            if (a0 >= 0x10000ULL && a1 > 0 && a1 <= 16384) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = (uint32_t)a1; }
            if (a2 >= 0x10000ULL) { call.out_arg_idx[1] = 3; call.out_arg_len[1] = 4; }
            if (a3 >= 0x10000ULL) { call.in_buf_arg_idx = 4; call.in_buf_len = 136; }
        } else if (slot == 15) {
            /* BeginAuthSession(const void *pAuthTicket, int cbAuthTicket, CSteamID) */
            if (a0 >= 0x10000ULL && a1 > 0) { call.in_buf_arg_idx = 1; call.in_buf_len = (uint32_t)a1; }
        } else if (slot == 21) {
            /* RequestEncryptedAppTicket(void *pDataToInclude, int cbDataToInclude) */
            if (a0 >= 0x10000ULL && a1 > 0) { call.in_buf_arg_idx = 1; call.in_buf_len = (uint32_t)a1; }
        } else if (slot == 22) {
            /* GetEncryptedAppTicket(void *pTicket, int cbMaxTicket, uint32 *pcbTicket) */
            if (a0 >= 0x10000ULL && a1 > 0 && a1 <= 16384) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = (uint32_t)a1; }
            if (a2 >= 0x10000ULL) { call.out_arg_idx[1] = 3; call.out_arg_len[1] = 4; }
        }
    } else if (self->kind == GP_IFACE_STEAMFRIENDS) {
        if (slot == 8) {
            /* GetFriendGamePlayed(CSteamID steamIDFriend, FriendGameInfo_t *pFriendGameInfo):
             * CGameID(8) + IP(4) + game port(2) + query port(2) + lobby CSteamID(8) = 24 bytes,
             * identical layout on Windows x64 and macOS x86_64. */
            if (a1 >= 0x10000ULL) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = 24; }
        }
    } else if (self->kind == GP_IFACE_STEAMAPPS) {
        if (slot == 18) {
            /* GetAppInstallDir(appID, char *pchFolder, uint32 cchFolderBufferSize) */
            if (a1 >= 0x10000ULL && a2 > 0) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = (uint32_t)a2; }
        }
    } else if (self->kind == GP_IFACE_STEAMREMOTESTORAGE) {
        if (slot == 0) {
            /* FileWrite(pchFile, const void *pvData, int32 cubData) */
            if (a1 >= 0x10000ULL && a2 > 0) { call.in_buf_arg_idx = 2; call.in_buf_len = (uint32_t)a2; }
        } else if (slot == 1) {
            /* FileRead(pchFile, void *pvData, int32 cubDataToRead) */
            if (a1 >= 0x10000ULL && a2 > 0) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = (uint32_t)a2; }
        } else if (slot == 16) {
            /* GetQuota(uint64 *pnTotalBytes, uint64 *puAvailableBytes) */
            if (a0 >= 0x10000ULL) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = 8; }
            if (a1 >= 0x10000ULL) { call.out_arg_idx[1] = 2; call.out_arg_len[1] = 8; }
        }
    } else if (self->kind == GP_IFACE_STEAMINVENTORY) {
        if (slot == 0 || slot == 7 || slot == 8 || slot == 10) {
            /* Methods taking SteamInventoryResult_t *pResultHandle as arg 0 */
            if (a0 >= 0x10000ULL) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = 4; }
        }
    } else if (self->kind == GP_IFACE_STEAMCONTROLLER || self->kind == GP_IFACE_STEAMINPUT) {
        if (slot == 3) {
            /* GetConnectedControllers(ControllerHandle_t *handlesOut) — 16 * 8 = 128 bytes */
            if (a0 >= 0x10000ULL) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = 128; }
        }
    } else if (self->kind == GP_IFACE_STEAMUSERSTATS) {
        if (slot == 1 || slot == 2) {
            /* GetStat(const char *pchName, int32/float *pData) */
            if (a1 >= 0x10000ULL) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = 4; }
        } else if (slot == 6) {
            /* GetAchievement(const char *pchName, bool *pbAchieved) */
            if (a1 >= 0x10000ULL) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = 1; }
        } else if (slot == 9) {
            /* GetAchievementAndUnlockTime(pchName, bool *pbAchieved, uint32 *punUnlockTime) */
            if (a1 >= 0x10000ULL) { call.out_arg_idx[0] = 2; call.out_arg_len[0] = 1; }
            if (a2 >= 0x10000ULL) { call.out_arg_idx[1] = 3; call.out_arg_len[1] = 4; }
        }
    } else if (self->kind == GP_IFACE_STEAMGC) {
        if (slot == 0) {
            /* SendMessage(uint32 unMsgType, const void *pubData, uint32 cubData) */
            if (a1 >= 0x10000ULL && a2 > 0) { call.in_buf_arg_idx = 2; call.in_buf_len = (uint32_t)a2; }
        } else if (slot == 1) {
            /* IsMessageAvailable(uint32 *pcubMsgSize) */
            if (a0 >= 0x10000ULL) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = 4; }
        } else if (slot == 2) {
            /* RetrieveMessage(uint32 *punMsgType, void *pubDest, uint32 cubDest, uint32 *pcubMsgSize) */
            if (a0 >= 0x10000ULL) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = 4; }
            if (a1 >= 0x10000ULL && a2 > 0) { call.out_arg_idx[1] = 2; call.out_arg_len[1] = (uint32_t)a2; }
            if (a3 >= 0x10000ULL) { call.out_arg_idx[2] = 4; call.out_arg_len[2] = 4; }
        }
    } else if (self->kind == GP_IFACE_STEAMNETUTILS) {
        if (slot == 1) {
            /* GetRelayNetworkStatus(SteamRelayNetworkStatus_t *pDetails) */
            if (a0 >= 0x10000ULL) { call.out_arg_idx[0] = 1; call.out_arg_len[0] = 280; }
        }
    }

    if (gp_unix_call(GP_BRIDGE_OP_VTABLE_CALL, &call) != 0) {
        return 0;
    }

    /* If ISteamClient returned a sub-interface pointer (identified by version string arg),
     * wrap it in a proxy object so calls to the sub-interface are ABI-translated too. */
    if (self->kind == GP_IFACE_STEAMCLIENT && call.ret_u64 != 0 && slot >= 5 && slot <= 45) {
        const char *ver = probe_steam_version_string(a2);
        if (!ver) ver = probe_steam_version_string(a1);
        if (ver) {
            struct gp_proxy *child = wrap_native_object(call.ret_u64, ver);
            return (uint64_t)(uintptr_t)child;
        }
    }

    /* Any other method that hands back a steamclient object (e.g.
     * ISteamNetworkingSockets::CreateFakeUDPPort): the game must only ever see a proxy, never a
     * pointer into the native host process. */
    if (call.ret_is_obj && call.ret_u64) {
        struct gp_proxy *child = wrap_native_object(call.ret_u64, NULL);
        return (uint64_t)(uintptr_t)child;
    }

    return call.ret_u64;
}

/* Generate 128 compact Windows x64 ABI vtable thunks */
#define GP_DEFINE_THUNK(N)                                                   \
    static uint64_t WINAPI gp_vtable_thunk_##N(                              \
        struct gp_proxy *self,                                               \
        uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,                  \
        uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7                   \
    ) {                                                                      \
        return gp_dispatch_slot(self, N, a0, a1, a2, a3, a4, a5, a6, a7);    \
    }

#define GP_THUNK_ROW(a, b, c, d, e, f, g, h) \
    GP_DEFINE_THUNK(a) GP_DEFINE_THUNK(b) GP_DEFINE_THUNK(c) GP_DEFINE_THUNK(d) \
    GP_DEFINE_THUNK(e) GP_DEFINE_THUNK(f) GP_DEFINE_THUNK(g) GP_DEFINE_THUNK(h)

GP_THUNK_ROW(0, 1, 2, 3, 4, 5, 6, 7)
GP_THUNK_ROW(8, 9, 10, 11, 12, 13, 14, 15)
GP_THUNK_ROW(16, 17, 18, 19, 20, 21, 22, 23)
GP_THUNK_ROW(24, 25, 26, 27, 28, 29, 30, 31)
GP_THUNK_ROW(32, 33, 34, 35, 36, 37, 38, 39)
GP_THUNK_ROW(40, 41, 42, 43, 44, 45, 46, 47)
GP_THUNK_ROW(48, 49, 50, 51, 52, 53, 54, 55)
GP_THUNK_ROW(56, 57, 58, 59, 60, 61, 62, 63)
GP_THUNK_ROW(64, 65, 66, 67, 68, 69, 70, 71)
GP_THUNK_ROW(72, 73, 74, 75, 76, 77, 78, 79)
GP_THUNK_ROW(80, 81, 82, 83, 84, 85, 86, 87)
GP_THUNK_ROW(88, 89, 90, 91, 92, 93, 94, 95)
GP_THUNK_ROW(96, 97, 98, 99, 100, 101, 102, 103)
GP_THUNK_ROW(104, 105, 106, 107, 108, 109, 110, 111)
GP_THUNK_ROW(112, 113, 114, 115, 116, 117, 118, 119)
GP_THUNK_ROW(120, 121, 122, 123, 124, 125, 126, 127)

static void init_proxy_vtable(void) {
#define GP_SET_SLOT(N) g_proxy_vtable[N] = (void *)gp_vtable_thunk_##N;
#define GP_SET_ROW(a, b, c, d, e, f, g, h) \
    GP_SET_SLOT(a) GP_SET_SLOT(b) GP_SET_SLOT(c) GP_SET_SLOT(d) \
    GP_SET_SLOT(e) GP_SET_SLOT(f) GP_SET_SLOT(g) GP_SET_SLOT(h)
    GP_SET_ROW(0, 1, 2, 3, 4, 5, 6, 7)
    GP_SET_ROW(8, 9, 10, 11, 12, 13, 14, 15)
    GP_SET_ROW(16, 17, 18, 19, 20, 21, 22, 23)
    GP_SET_ROW(24, 25, 26, 27, 28, 29, 30, 31)
    GP_SET_ROW(32, 33, 34, 35, 36, 37, 38, 39)
    GP_SET_ROW(40, 41, 42, 43, 44, 45, 46, 47)
    GP_SET_ROW(48, 49, 50, 51, 52, 53, 54, 55)
    GP_SET_ROW(56, 57, 58, 59, 60, 61, 62, 63)
    GP_SET_ROW(64, 65, 66, 67, 68, 69, 70, 71)
    GP_SET_ROW(72, 73, 74, 75, 76, 77, 78, 79)
    GP_SET_ROW(80, 81, 82, 83, 84, 85, 86, 87)
    GP_SET_ROW(88, 89, 90, 91, 92, 93, 94, 95)
    GP_SET_ROW(96, 97, 98, 99, 100, 101, 102, 103)
    GP_SET_ROW(104, 105, 106, 107, 108, 109, 110, 111)
    GP_SET_ROW(112, 113, 114, 115, 116, 117, 118, 119)
    GP_SET_ROW(120, 121, 122, 123, 124, 125, 126, 127)
#undef GP_SET_ROW
#undef GP_SET_SLOT
}

/* --------------------------------------------------------------------------
 * Standard Valve steamclient64.dll C Exports
 * -------------------------------------------------------------------------- */
#pragma pack(push, 4)
struct win_callback_msg {
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
bool __cdecl Steam_BGetCallback(int32_t hSteamPipe, struct win_callback_msg *pCallbackMsg) {
    struct gp_get_callback_args req;
    memset(&req, 0, sizeof(req));
    req.pipe = hSteamPipe;
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

/* Breakpad no-op stubs expected by older steam_api64.dll builds */
__declspec(dllexport) void __cdecl Breakpad_SteamSetSteamID(uint64_t ulSteamID) { (void)ulSteamID; }
__declspec(dllexport) void __cdecl Breakpad_SteamMiniDumpInit(uint32_t a, const char *b, const char *c) { (void)a; (void)b; (void)c; }
__declspec(dllexport) void __cdecl Breakpad_SteamWriteMiniDumpSetComment(const char *msg) { (void)msg; }
__declspec(dllexport) void __cdecl Breakpad_SteamWriteMiniDumpUsingExceptionInfoWithBuildId(int a, int b) { (void)a; (void)b; }

/* GamePort diagnostic export used by bridge_probe.exe */
__declspec(dllexport)
int __cdecl GPBridge_GetInfo(struct gp_ping_args *out_info) {
    if (!out_info) return 0;
    memset(out_info, 0, sizeof(*out_info));
    return gp_unix_call(GP_BRIDGE_OP_PING, out_info) == 0 ? 1 : 0;
}

/* --------------------------------------------------------------------------
 * DLL Entry Point — Attach Wine UnixLib
 * -------------------------------------------------------------------------- */
BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    (void)lpvReserved;
    if (fdwReason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hinstDLL);
        InitializeCriticalSection(&g_proxy_lock);
        g_lock_ready = 1;
        init_proxy_vtable();

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
