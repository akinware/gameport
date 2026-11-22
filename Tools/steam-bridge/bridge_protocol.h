/*
 * GamePort Steam Bridge — Shared Wine PE <-> macOS UnixLib ABI Protocol
 * License: PolyForm Noncommercial 1.0.0 (see LICENSE)
 *
 * Clean-room bridge that forwards Windows Steamworks calls (steamclient64.dll)
 * across Wine's unixlib boundary directly to the user's untouched native macOS
 * Steam client (steamclient.dylib), without patching Steam.app or running
 * Windows Steam in the background.
 */

#ifndef GAMEPORT_STEAM_BRIDGE_PROTOCOL_H
#define GAMEPORT_STEAM_BRIDGE_PROTOCOL_H

#include <stdint.h>

#define GP_BRIDGE_PROTOCOL_VERSION 1
#define GP_BRIDGE_MAX_PATH         1024
#define GP_BRIDGE_MAX_IFACE_NAME   128
#define GP_BRIDGE_VTABLE_SLOTS     128

/* Wine UnixLib opcodes dispatched via __wine_unix_call_dispatcher */
enum gp_bridge_op {
    GP_BRIDGE_OP_PING               = 0,
    GP_BRIDGE_OP_CREATE_INTERFACE   = 1,
    GP_BRIDGE_OP_VTABLE_CALL        = 2,
    GP_BRIDGE_OP_GET_CALLBACK       = 3,
    GP_BRIDGE_OP_FREE_CALLBACK      = 4,
    GP_BRIDGE_OP_GET_APICALL_RESULT = 5,
    GP_BRIDGE_OP_RELEASE_TLS        = 6,
    GP_BRIDGE_OP_COUNT              = 7
};

/* Call flags for GP_BRIDGE_OP_VTABLE_CALL */
enum gp_call_flags {
    GP_CALL_FLAG_NONE        = 0,
    /* Native SysV method returns an 8-byte CSteamID in RAX, while MSVC x64
     * expects it written through a hidden out-pointer in RDX (arg 0). */
    GP_CALL_FLAG_MSVC_SRET8  = (1u << 0),
    /* Method returns a float/double in XMM0. */
    GP_CALL_FLAG_RET_FLOAT   = (1u << 1),
    GP_CALL_FLAG_RET_DOUBLE  = (1u << 2),
    /* WoW64 / Host IPC: native method returns a `const char *`; copy into Wine buffer. */
    GP_CALL_FLAG_RET_CSTR    = (1u << 3),
    /* Suppress automatic C-string probing on return value (e.g. ISteamClient sub-interface getters). */
    GP_CALL_FLAG_NO_AUTO_CSTR = (1u << 4),
    /* Method returns a 20-byte struct by value (SteamIPAddress_t). MSVC passes the hidden return
     * buffer after `this` (arg 0, marshaled as out-arg 1). The native ABI differs (SysV x86_64: RDI
     * before `this`; arm64: x8), so the host calls through a typed struct-returning pointer and
     * copies the result into the out-arg buffer. */
    GP_CALL_FLAG_RET_BLOB20 = (1u << 5)
};

/* Known proxy interface families for ABI adjustments & sub-interface wrapping */
enum gp_iface_kind {
    GP_IFACE_GENERIC          = 0,
    GP_IFACE_STEAMCLIENT      = 1,
    GP_IFACE_STEAMUSER        = 2,
    GP_IFACE_STEAMFRIENDS     = 3,
    GP_IFACE_STEAMAPPS        = 4,
    GP_IFACE_STEAMUTILS       = 5,
    GP_IFACE_STEAMHTMLSURFACE = 6,
    GP_IFACE_STEAMHTTP        = 7,
    GP_IFACE_STEAMREMOTESTORAGE = 8,
    GP_IFACE_STEAMINVENTORY   = 9,
    GP_IFACE_STEAMCONTROLLER  = 10,
    GP_IFACE_STEAMINPUT       = 11,
    GP_IFACE_STEAMUSERSTATS   = 12,
    GP_IFACE_STEAMGC          = 13,
    GP_IFACE_STEAMNETUTILS    = 14,
    GP_IFACE_STEAMGAMESERVER  = 15,
    GP_IFACE_STEAMGAMESERVERSTATS = 16
};

#pragma pack(push, 8)

struct gp_ping_args {
    uint32_t protocol_version;   /* out */
    uint32_t loaded;             /* out: 1 if steamclient.dylib (or mock) is ready */
    uint32_t mock_mode;          /* out: 1 if running in GP_STEAM_BRIDGE_MOCK=1 */
    uint32_t exports_mask;       /* out: bitmask of resolved Steam exports */
    char     dylib_path[GP_BRIDGE_MAX_PATH]; /* out */
    char     error_msg[256];     /* out */
};

/* Bitmask values for gp_ping_args.exports_mask */
#define GP_EXP_CREATE_INTERFACE   (1u << 0)
#define GP_EXP_GET_CALLBACK       (1u << 1)
#define GP_EXP_FREE_CALLBACK      (1u << 2)
#define GP_EXP_GET_APICALL_RESULT (1u << 3)
#define GP_EXP_RELEASE_TLS        (1u << 4)

struct gp_create_interface_args {
    uint64_t name_ptr;           /* in: const char * */
    uint64_t native_obj;         /* out: void * returned by native CreateInterface */
    int32_t  return_code;        /* out: *pReturnCode */
    int32_t  reserved;
};

struct gp_vtable_call_args {
    uint64_t native_obj;         /* in: native macOS C++ object pointer */
    uint32_t slot;               /* in: virtual table slot index (0..127) */
    uint32_t flags;              /* in: enum gp_call_flags */
    uint64_t args[8];            /* in: integer/pointer arguments after `this` */
    double   fargs[4];           /* in: floating-point arguments (future use) */
    uint64_t str_buf_ptr;        /* in (optional): PE buffer for GP_CALL_FLAG_RET_CSTR */
    uint32_t str_buf_cap;        /* in (optional): capacity of str_buf_ptr */
    uint8_t  out_arg_idx[3];     /* in: arg index+1 (1..8) of out-pointer to copy back, 0 = unused */
    uint8_t  in_buf_arg_idx;     /* in: arg index+1 (1..8) of binary input buffer, 0 = unused */
    uint32_t out_arg_len[3];     /* in: byte size for out_arg_idx[0..2] */
    uint32_t in_buf_len;         /* in: byte size for in_buf_arg_idx */
    uint64_t ret_u64;            /* out: RAX return value */
    double   ret_f64;            /* out: XMM0 return value */
    uint32_t ret_is_obj;         /* out: ret_u64 is a native C++ object (vtable inside steamclient) */
    uint32_t reserved;
};

struct gp_get_callback_args {
    int32_t  pipe;               /* in: HSteamPipe */
    int32_t  has_callback;       /* out: bool (0/1) */
    int32_t  steam_user;         /* out: CallbackMsg_t.m_hSteamUser */
    int32_t  callback_id;        /* out: CallbackMsg_t.m_iCallback */
    uint64_t pub_param;          /* out: CallbackMsg_t.m_pubParam */
    int32_t  cub_param;          /* out: CallbackMsg_t.m_cubParam */
    uint32_t copy_buf_cap;       /* in (optional): WoW64 32-bit copy buffer size */
    uint64_t copy_buf_ptr;       /* in (optional): WoW64 32-bit buffer to copy payload into */
};

struct gp_free_callback_args {
    int32_t  pipe;               /* in: HSteamPipe */
    int32_t  reserved;
};

struct gp_get_apicall_result_args {
    int32_t  pipe;               /* in: HSteamPipe */
    int32_t  expected_callback;  /* in: int iCallbackExpected */
    uint64_t api_call;           /* in: SteamAPICall_t */
    uint64_t buf_ptr;            /* in: void *pCallback */
    int32_t  cub_buf;            /* in: int cubCallback */
    int32_t  failed;             /* out: bool *pbFailed */
    int32_t  ok;                 /* out: bool return */
    int32_t  reserved;
};

struct gp_release_tls_args {
    int32_t  all_threads;        /* in */
    int32_t  reserved;
};

#pragma pack(pop)

#endif /* GAMEPORT_STEAM_BRIDGE_PROTOCOL_H */
