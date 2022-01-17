#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <smlib>

public Plugin myinfo =
{
	name = "Wichteln 2021",
	author = "murlis",
	description = ":)",
	version = "1.0",
	url = "http://steamcommunity.com/id/muhlex"
};

public void OnPluginStart()
{
	HookEvent("round_start", OnRoundStart);
	HookEvent("player_spawn", OnPlayerSpawn);
	HookEvent("weapon_fire", OnWeaponFire);
}

public Action OnRoundStart(Event event, const char[] eventName, bool dontBroadcast)
{
	int ent;
	while ((ent = FindEntityByClassname(ent, "prop_weapon_upgrade_chute")) != -1)
		if (IsValidEntity(ent)) RemoveEntity(ent);
	while ((ent = FindEntityByClassname(ent, "prop_weapon_upgrade_exojump")) != -1)
		if (IsValidEntity(ent)) RemoveEntity(ent);
}

public Action OnPlayerSpawn(Event event, const char[] eventName, bool dontBroadcast)
{
	int userID = event.GetInt("userid");
	int client = GetClientOfUserId(userID);

	if (!IsClientInGame(client)) return;
	if (Client_HasWeapon(client, "weapon_bumpmine")) return;

	GivePlayerItem(client, "weapon_bumpmine");
}

public Action OnWeaponFire(Event event, const char[] eventName, bool dontBroadcast)
{
	int userID = event.GetInt("userid");
	int client = GetClientOfUserId(userID);

	if (!IsClientInGame(client)) return;

	char weaponName[255];
	event.GetString("weapon", weaponName, sizeof(weaponName));

	if (!StrEqual(weaponName, "weapon_bumpmine")) return;

	int weaponEnt = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
	SetEntProp(weaponEnt, Prop_Data, "m_iClip1", 4);
}
