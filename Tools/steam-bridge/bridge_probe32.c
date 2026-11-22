/*
 * GamePort Steam Bridge 32-bit WoW64 Probe (bridge_probe32.exe)
 * License: PolyForm Noncommercial 1.0.0 (see LICENSE)
 *
 * Verifies 32-bit i386 steamclient.dll -> Wine WoW64 unixlib -> 64-bit macOS
 * steamclient.so -> steamclient.dylib including <4GB string marshaling and
 * 32-bit MSVC __thiscall CSteamID sret.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#include "bridge_protocol.h"

typedef int   (__cdecl *fn_GPBridge_GetInfo_t)(struct gp_ping_args *out);
typedef void *(__cdecl *fn_CreateInterface_t)(const char *name, int *rc);

typedef int32_t     (__attribute__((thiscall)) *fn_CreateSteamPipe_t)(void *self);
typedef int32_t     (__attribute__((thiscall)) *fn_ConnectToGlobalUser_t)(void *self, int32_t pipe);
typedef void       *(__attribute__((thiscall)) *fn_GetISteamUser_t)(void *self, int32_t user, int32_t pipe, const char *ver);
typedef void       *(__attribute__((thiscall)) *fn_GetISteamApps_t)(void *self, int32_t user, int32_t pipe, const char *ver);
typedef bool        (__attribute__((thiscall)) *fn_BReleaseSteamPipe_t)(void *self, int32_t pipe);
typedef uint64_t   *(__attribute__((thiscall)) *fn_GetSteamID_msvc_t)(void *self, uint64_t *out_id);
typedef bool        (__attribute__((thiscall)) *fn_BLoggedOn_t)(void *self);
typedef bool        (__attribute__((thiscall)) *fn_BIsSubscribed_t)(void *self);
typedef const char *(__attribute__((thiscall)) *fn_GetCurrentGameLanguage_t)(void *self);

int main(void) {
    HMODULE mod = LoadLibraryA("steamclient.dll");
    if (!mod) {
        fprintf(stderr, "FAIL32: LoadLibraryA(steamclient.dll) error=%lu\n", GetLastError());
        return 2;
    }

    fn_GPBridge_GetInfo_t pInfo = (fn_GPBridge_GetInfo_t)GetProcAddress(mod, "GPBridge_GetInfo");
    fn_CreateInterface_t pCreate = (fn_CreateInterface_t)GetProcAddress(mod, "CreateInterface");
    if (!pInfo || !pCreate) {
        fprintf(stderr, "FAIL32: missing exports\n");
        return 3;
    }

    struct gp_ping_args info;
    if (!pInfo(&info)) {
        fprintf(stderr, "FAIL32: GPBridge_GetInfo unixlib call failed\n");
        return 4;
    }

    printf("arch=32 protocol=%u loaded=%u mock=%u exports=0x%x path=%s\n",
           info.protocol_version, info.loaded, info.mock_mode, info.exports_mask,
           info.dylib_path[0] ? info.dylib_path : "(none)");
    if (!info.loaded) {
        fprintf(stderr, "UNAVAILABLE32: %s\n", info.error_msg);
        return 5;
    }

    int rc = -1;
    void *client = pCreate("SteamClient020", &rc);
    if (!client) client = pCreate("SteamClient021", &rc);
    if (!client) client = pCreate("SteamClient017", &rc);
    if (!client) {
        fprintf(stderr, "FAIL32: CreateInterface(SteamClient) failed rc=%d\n", rc);
        return 6;
    }

    void **vt = *(void ***)client;
    int32_t pipe = ((fn_CreateSteamPipe_t)vt[0])(client);
    int32_t user = ((fn_ConnectToGlobalUser_t)vt[2])(client, pipe);
    void *steam_user = ((fn_GetISteamUser_t)vt[5])(client, user, pipe, "SteamUser021");
    void *steam_apps = ((fn_GetISteamApps_t)vt[15])(client, user, pipe, "STEAMAPPS_INTERFACE_VERSION008");

    uint64_t steam_id = 0;
    int logged_on = 0;
    if (steam_user) {
        void **uvt = *(void ***)steam_user;
        logged_on = ((fn_BLoggedOn_t)uvt[1])(steam_user) ? 1 : 0;
        ((fn_GetSteamID_msvc_t)uvt[2])(steam_user, &steam_id);
    }

    int subscribed = 0;
    const char *lang = "";
    if (steam_apps) {
        void **avt = *(void ***)steam_apps;
        subscribed = ((fn_BIsSubscribed_t)avt[0])(steam_apps) ? 1 : 0;
        const char *l = ((fn_GetCurrentGameLanguage_t)avt[4])(steam_apps);
        if (l) lang = l;
    }

    ((fn_BReleaseSteamPipe_t)vt[1])(client, pipe);

    printf("OK32: pipe=%d user=%d logged_on=%d steam_id=%llu subscribed=%d lang=%s\n",
           pipe, user, logged_on, (unsigned long long)steam_id, subscribed, lang);
    return 0;
}
