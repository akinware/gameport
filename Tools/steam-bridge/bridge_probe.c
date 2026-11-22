/*
 * GamePort Steam Bridge Probe (bridge_probe.exe)
 * License: PolyForm Noncommercial 1.0.0 (see LICENSE)
 *
 * Runs inside Wine to verify the full PE <-> Wine UnixLib <-> macOS SysV ABI
 * round-trip through steamclient64.dll -> steamclient64.so -> steamclient.dylib.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "bridge_protocol.h"

typedef int   (__cdecl *fn_GPBridge_GetInfo_t)(struct gp_ping_args *out);
typedef void *(__cdecl *fn_CreateInterface_t)(const char *name, int *rc);

typedef int32_t  (WINAPI *fn_CreateSteamPipe_t)(void *self);
typedef int32_t  (WINAPI *fn_ConnectToGlobalUser_t)(void *self, int32_t pipe);
typedef void    *(WINAPI *fn_GetISteamUser_t)(void *self, int32_t user, int32_t pipe, const char *ver);
typedef void    *(WINAPI *fn_GetISteamApps_t)(void *self, int32_t user, int32_t pipe, const char *ver);
typedef int32_t  (WINAPI *fn_BReleaseSteamPipe_t)(void *self, int32_t pipe);
typedef uint64_t *(WINAPI *fn_GetSteamID_msvc_t)(void *self, uint64_t *out_id);
typedef int32_t  (WINAPI *fn_BLoggedOn_t)(void *self);
typedef int32_t  (WINAPI *fn_BIsSubscribed_t)(void *self);
typedef const char *(WINAPI *fn_GetCurrentGameLanguage_t)(void *self);

int main(void) {
    HMODULE mod = LoadLibraryA("steamclient64.dll");
    if (!mod) {
        fprintf(stderr, "FAIL: LoadLibraryA(steamclient64.dll) error=%lu\n", GetLastError());
        return 2;
    }

    fn_GPBridge_GetInfo_t pInfo = (fn_GPBridge_GetInfo_t)GetProcAddress(mod, "GPBridge_GetInfo");
    fn_CreateInterface_t pCreate = (fn_CreateInterface_t)GetProcAddress(mod, "CreateInterface");
    if (!pInfo || !pCreate) {
        fprintf(stderr, "FAIL: missing exports (pInfo=%p, pCreate=%p)\n", (void *)pInfo, (void *)pCreate);
        return 3;
    }

    struct gp_ping_args info;
    if (!pInfo(&info)) {
        fprintf(stderr, "FAIL: GPBridge_GetInfo unixlib call failed\n");
        return 4;
    }

    printf("protocol=%u loaded=%u mock=%u exports=0x%x path=%s\n",
           info.protocol_version, info.loaded, info.mock_mode, info.exports_mask,
           info.dylib_path[0] ? info.dylib_path : "(none)");
    if (!info.loaded) {
        fprintf(stderr, "UNAVAILABLE: %s\n", info.error_msg);
        return 5;
    }

    int rc = -1;
    void *client = pCreate("SteamClient020", &rc);
    if (!client) {
        client = pCreate("SteamClient021", &rc);
    }
    if (!client) {
        client = pCreate("SteamClient017", &rc);
    }
    if (!client) {
        fprintf(stderr, "FAIL: CreateInterface(SteamClient) failed rc=%d\n", rc);
        return 6;
    }

    void **vt = *(void ***)client;
    int32_t pipe = ((fn_CreateSteamPipe_t)vt[0])(client);
    int32_t user = ((fn_ConnectToGlobalUser_t)vt[2])(client, pipe);
    void *steam_user = ((fn_GetISteamUser_t)vt[5])(client, user, pipe, "SteamUser021");
    void *steam_apps = ((fn_GetISteamApps_t)vt[15])(client, user, pipe, "STEAMAPPS_INTERFACE_VERSION008");

    uint64_t steam_id = 0;
    int32_t logged_on = 0;
    if (steam_user) {
        void **uvt = *(void ***)steam_user;
        logged_on = ((fn_BLoggedOn_t)uvt[1])(steam_user);
        ((fn_GetSteamID_msvc_t)uvt[2])(steam_user, &steam_id);
    }

    int32_t subscribed = 0;
    const char *lang = "";
    if (steam_apps) {
        void **avt = *(void ***)steam_apps;
        subscribed = ((fn_BIsSubscribed_t)avt[0])(steam_apps);
        const char *l = ((fn_GetCurrentGameLanguage_t)avt[4])(steam_apps);
        if (l) lang = l;
    }

    ((fn_BReleaseSteamPipe_t)vt[1])(client, pipe);

    printf("OK: pipe=%d user=%d logged_on=%d steam_id=%llu subscribed=%d lang=%s\n",
           pipe, user, logged_on, (unsigned long long)steam_id, subscribed, lang);
    return 0;
}
