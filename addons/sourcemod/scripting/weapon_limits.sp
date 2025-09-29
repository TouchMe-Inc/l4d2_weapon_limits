// Changelog:
//
// 2.0 (robex):
//     - Code rework, cleaned up old sourcemod functions
//     - Allow limiting individual melees, to limit them with l4d_wlimits_add
//       use names in MeleeWeaponNames array (l4d2util_constants.inc)
//

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <colors>
#define L4D2UTIL_STOCKS_ONLY 1
#include <l4d2util>


public Plugin myinfo =
{
    name        = "Weapon Limits",
    author      = "CanadaRox, Stabby, Forgetest, A1m`, robex",
    description = "Restrict weapons individually or together",
    version     = "2.2.3",
    url         = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};


#define GAMEDATA_FILE				"weapon_limits"
#define GAMEDATA_USE_AMMO			"CWeaponAmmoSpawn_Use"

#define SOUND_DENY					"player/suit_denydevice.wav"


enum struct LimitArrayEntry
{
    int LAE_iLimit;
    int LAE_iGiveAmmo;
    int LAE_WeaponArray[WEPID_SIZE / 32 + 1];
    int LAE_MeleeArray[WEPID_MELEES_SIZE / 32 + 1];
}

int
    g_iLastPrintTickCount[MAXPLAYERS + 1],
    g_iWeaponAlreadyGiven[MAXPLAYERS + 1][MAX_EDICTS];

Handle
    hSDKGiveDefaultAmmo;

ArrayList
    hLimitArray;

bool
    bIsLocked;

StringMap
    hMeleeWeaponNamesTrie = null;


public void OnPluginStart()
{
    LoadTranslations("weapon_limits.phrases");
    InitSDKCall();
    L4D2Weapons_Init();

    hLimitArray = new ArrayList(sizeof(LimitArrayEntry));

    hMeleeWeaponNamesTrie = new StringMap();

    for (int i = 0; i < WEPID_MELEES_SIZE; i++) {
        hMeleeWeaponNamesTrie.SetValue(MeleeWeaponNames[i], i);
    }

    RegServerCmd("l4d_wlimits_add", Cmd_AddLimit, "Add a weapon limit");
    RegServerCmd("l4d_wlimits_lock", Cmd_LockLimits, "Locks the limits to improve search speeds");
    RegServerCmd("l4d_wlimits_clear", Cmd_ClearLimits, "Clears all weapon limits (limits must be locked to be cleared)");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

void InitSDKCall()
{
    /* Preparing SDK Call */
    Handle hConf = LoadGameConfigFile(GAMEDATA_FILE);

    if (hConf == null) {
        SetFailState("Gamedata missing: %s", GAMEDATA_FILE);
    }

    StartPrepSDKCall(SDKCall_Entity);

    if (!PrepSDKCall_SetFromConf(hConf, SDKConf_Signature, GAMEDATA_USE_AMMO)) {
        SetFailState("Gamedata missing signature: %s", GAMEDATA_USE_AMMO);
    }

    // Client that used the ammo spawn
    PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
    hSDKGiveDefaultAmmo = EndPrepSDKCall();

    if (hSDKGiveDefaultAmmo == null) {
        SetFailState("Failed to finish SDKCall setup: %s", GAMEDATA_USE_AMMO);
    }

    delete hConf;
}

public void OnMapStart()
{
    PrecacheSound(SOUND_DENY);

    for (int i = 1; i <= MaxClients; ++i)
    {
        if (IsClientInGame(i)) OnClientPutInServer(i);
    }
}

void Event_RoundStart(Event hEvent, const char[] szEventName, bool bDontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++) {
        g_iLastPrintTickCount[i] = 0;
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_WeaponCanUse, Hook_WeaponCanUse);
}

public void OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_WeaponCanUse, Hook_WeaponCanUse);
}

Action Cmd_AddLimit(int iArgs)
{
    if (bIsLocked) {
        PrintToServer("Limits have been locked !");

        return Plugin_Handled;
    }

    if (iArgs < 3) {
        PrintToServer("Usage: l4d_wlimits_add <limit> <ammo> <weapon1> <weapon2> ... <weaponN>\nAmmo: -1: Given for primary weapon spawns only, 0: no ammo given ever, else: ammo always given !");

        return Plugin_Handled;
    }

    char sTempBuff[ENTITY_MAX_NAME_LENGTH];
    GetCmdArg(1, sTempBuff, sizeof(sTempBuff));

    int wepid, meleeid;

    LimitArrayEntry newEntry;

    newEntry.LAE_iLimit = StringToInt(sTempBuff);
    GetCmdArg(2, sTempBuff, sizeof(sTempBuff));
    newEntry.LAE_iGiveAmmo = StringToInt(sTempBuff);

    for (int i = 3; i <= iArgs; ++i) {
        GetCmdArg(i, sTempBuff, sizeof(sTempBuff));

        wepid = WeaponNameToId(sTempBuff);

        // @Forgetest: Fix incorrectly counting generic melees with an entry of melee names only.
        if (wepid != WEPID_NONE) {
            AddBitMask(newEntry.LAE_WeaponArray, wepid);
        }

        // assume it's a melee
        if (wepid == WEPID_NONE && hMeleeWeaponNamesTrie.GetValue(sTempBuff, meleeid)) {
            AddBitMask(newEntry.LAE_MeleeArray, meleeid);
        }
    }

    hLimitArray.PushArray(newEntry, sizeof(newEntry));

    return Plugin_Handled;
}

Action Cmd_LockLimits(int iArgs)
{
    if (bIsLocked) {
        PrintToServer("Weapon limits already locked!");
    } else {
        bIsLocked = true;

        PrintToServer("Weapon limits locked!");
    }

    return Plugin_Handled;
}

Action Cmd_ClearLimits(int iArgs)
{
    if (!bIsLocked) {
        return Plugin_Handled;
    }

    bIsLocked = false;

    PrintToServer("Weapon limits cleared!");

    if (hLimitArray != null) {
        hLimitArray.Clear();
    }

    return Plugin_Handled;
}

Action Hook_WeaponCanUse(int client, int weapon)
{
    // TODO: There seems to be an issue that this hook will be constantly called
    //       when client with no weapon on equivalent slot just eyes or walks on it.
    //       If the weapon meets limit, client will have the warning spamming unexpectedly.

    if (GetClientTeam(client) != L4D2Team_Survivor || !bIsLocked) {
        return Plugin_Continue;
    }

    int wepid = IdentifyWeapon(weapon);
    bool is_melee = (wepid == WEPID_MELEE);
    int meleeid = 0;
    if (is_melee) {
        meleeid = IdentifyMeleeWeapon(weapon);
    }
    int wep_slot = GetSlotFromWeaponId(wepid);

    int player_weapon = GetPlayerWeaponSlot(client, wep_slot);
    int player_wepid = IdentifyWeapon(player_weapon);

    int iSize = hLimitArray.Length;

    LimitArrayEntry arrayEntry;

    for (int i = 0; i < iSize; i++) {
        hLimitArray.GetArray(i, arrayEntry, sizeof(arrayEntry));

        if (is_melee) {
            int specificMeleeCount = GetMeleeCount(arrayEntry.LAE_MeleeArray);
            int allMeleeCount = GetWeaponCount(arrayEntry.LAE_WeaponArray);

            int isSpecificMeleeLimited = IsWeaponLimited(arrayEntry.LAE_MeleeArray, meleeid);
            int isAllMeleeLimited = IsWeaponLimited(arrayEntry.LAE_WeaponArray, wepid);

            if (isSpecificMeleeLimited && specificMeleeCount >= arrayEntry.LAE_iLimit) {
                DenyWeapon(wep_slot, arrayEntry, weapon, client);
                return Plugin_Handled;
            }

            if (isAllMeleeLimited && allMeleeCount >= arrayEntry.LAE_iLimit) {
                // dont deny swapping melees when theres only a limit on global melees
                if (player_wepid != WEPID_MELEE) {
                    DenyWeapon(wep_slot, arrayEntry, weapon, client);
                    return Plugin_Handled;
                }
            }
        } else {
            // is weapon about to be picked up limited and over the limit?
            if (IsWeaponLimited(arrayEntry.LAE_WeaponArray, wepid) && GetWeaponCount(arrayEntry.LAE_WeaponArray) >= arrayEntry.LAE_iLimit) {
                // is currently held weapon limited?
                if (!player_wepid || wepid == player_wepid || !IsWeaponLimited(arrayEntry.LAE_WeaponArray, player_wepid)) {
                    DenyWeapon(wep_slot, arrayEntry, weapon, client);
                    return Plugin_Handled;
                }
            }
        }
    }

    return Plugin_Continue;
}

// Fixing an error when compiling in sourcemod 1.9
void AddBitMask(int[] iMask, int iWeaponId)
{
    iMask[iWeaponId / 32] |= (1 << (iWeaponId % 32));
}

int IsWeaponLimited(const int[] mask, int wepid)
{
    return (mask[wepid / 32] & (1 << (wepid % 32)));
}

void DenyWeapon(int wep_slot, LimitArrayEntry arrayEntry, int weapon, int client)
{
    if ((wep_slot == 0 && arrayEntry.LAE_iGiveAmmo == -1) || arrayEntry.LAE_iGiveAmmo != 0) {
        GiveDefaultAmmo(client);
    }

    // Notify the client only when they are attempting to pick this up
    // in which way spamming gets avoided due to auto-pick-up checking left since Counter:Strike.

    //g_iWeaponAlreadyGiven - if the weapon is given by another plugin, the player will not press the use key
    //g_iLastPrintTickCount - sometimes there is a double seal in one frame because the player touches the weapon and presses a use key
    int iWeaponRef = EntIndexToEntRef(weapon);
    int iLastTick = GetGameTickCount();
    int iButtonPressed = GetEntProp(client, Prop_Data, "m_afButtonPressed");

    if ((g_iWeaponAlreadyGiven[client][weapon] != iWeaponRef || iButtonPressed & IN_USE)
        && g_iLastPrintTickCount[client] != iLastTick
    ) {
        CPrintToChat(client, "%T%T", "TAG", client, "DENY", client, arrayEntry.LAE_iLimit);
        EmitSoundToClient(client, SOUND_DENY);

        g_iWeaponAlreadyGiven[client][weapon] = iWeaponRef;
        g_iLastPrintTickCount[client] = iLastTick;
    }
}

int GetWeaponCount(const int[] mask)
{
    int count, wepid;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != L4D2Team_Survivor || !IsPlayerAlive(i)) {
            continue;
        }

        for (int j = 0; j < L4D2WeaponSlot_Size; ++j) {
            wepid = IdentifyWeapon(GetPlayerWeaponSlot(i, j));

            if (IsWeaponLimited(mask, wepid)) {
                count++;
            }
        }

        // @Forgetest
        // Lucky that "incap" prop is reset before function "OnRevive" restores secondary
        // so no concern about player failing to get their secondary back
        if (IsIncapacitated(i) || IsHangingFromLedge(i)) {
            wepid = IdentifyWeapon(GetPlayerSecondaryWeaponRestore(i));

            if (IsWeaponLimited(mask, wepid)) {
                count++;
            }
        }
    }

    return count;
}

int GetMeleeCount(const int[] mask)
{
    int count, meleeid;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != L4D2Team_Survivor || !IsPlayerAlive(i)) {
            continue;
        }

        meleeid = IdentifyMeleeWeapon(GetPlayerWeaponSlot(i, L4D2WeaponSlot_Secondary));
        if (meleeid != WEPID_MELEE_NONE) {
            if (IsWeaponLimited(mask, meleeid)) {
                count++;
            }
        }

        // @Forgetest
        // Lucky that "incap" prop is reset before function "OnRevive" restores secondary
        // so no concern about player failing to get their secondary back
        if (IsIncapacitated(i) || IsHangingFromLedge(i)) {
            meleeid = IdentifyMeleeWeapon(GetPlayerSecondaryWeaponRestore(i));

            if (meleeid != WEPID_MELEE_NONE) {
                if (IsWeaponLimited(mask, meleeid)) {
                    count++;
                }
            }
        }
    }

    return count;
}

void GiveDefaultAmmo(int client)
{
    // @Forgetest NOTE:
    // Previously the plugin seems to cache an index of one ammo pile in current map, and is supposed to use it here.
    // For some reason, the caching never runs, and the code is completely wrong either.
    // Therefore, it has been consistently using an SDKCall like below ('0' should've been the index of ammo pile).
    // However, since it actually has worked without error and crash for a long time, I would decide to leave it still.
    // If your server suffers from this, please try making use of the functions commented below.

    SDKCall(hSDKGiveDefaultAmmo, 0, client);
}

int GetPlayerSecondaryWeaponRestore(int client)
{
    static int s_iOffs_m_hSecondaryWeaponRestore = -1;
    if (s_iOffs_m_hSecondaryWeaponRestore == -1)
        s_iOffs_m_hSecondaryWeaponRestore = FindSendPropInfo("CTerrorPlayer", "m_iVersusTeam") - 20;

    return GetEntDataEnt2(client, s_iOffs_m_hSecondaryWeaponRestore);
}
