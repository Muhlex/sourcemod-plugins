#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

ConVar convarRespawnEnable;
ConVar convarRandomspawn;

ConVar mp_respawn_on_death_t;
ConVar mp_respawn_on_death_ct;
ConVar mp_randomspawn;

int respawnsPerTeam[4];
int respawningPerTeam[4];

public Plugin myinfo =
{
	name = "Imbalance Respawn",
	author = "murlis",
	description = "Respawn players as often per round as they are player's down.",
	version = "1.0",
	url = "http://steamcommunity.com/id/muhlex"
};

public void OnPluginStart()
{
	convarRespawnEnable = CreateConVar("sm_imbalance_respawn_enable", "1", "Enable Respawn on team imbalance.");
	convarRespawnEnable.AddChangeHook(OnRespawnEnableChange);
	convarRandomspawn = CreateConVar("sm_imbalance_respawn_randomspawn", "0", "Use mp_randomspawn when respawning.");
	mp_respawn_on_death_t = FindConVar("mp_respawn_on_death_t");
	mp_respawn_on_death_ct = FindConVar("mp_respawn_on_death_ct");
	mp_randomspawn = FindConVar("mp_randomspawn");

	if (convarRespawnEnable.BoolValue)
		HookEvents();
}

public void OnRespawnEnableChange(ConVar convar, char[] oldValue, char[] newValue)
{
	convar.BoolValue ? HookEvents() : UnhookEvents();
}

void HookEvents()
{
	HookEvent("round_freeze_end", OnRoundFreezeEnd);
	HookEvent("player_death", OnPlayerDeath);
	HookEvent("player_spawn", OnPlayerSpawn);
}
void UnhookEvents()
{
	UnhookEvent("round_freeze_end", OnRoundFreezeEnd);
	UnhookEvent("player_death", OnPlayerDeath);
	UnhookEvent("player_spawn", OnPlayerSpawn);

	mp_respawn_on_death_t.BoolValue = false;
	mp_respawn_on_death_ct.BoolValue = false;
	mp_randomspawn.BoolValue = false;
}

public Action OnRoundFreezeEnd(Event event, const char[] eventName, bool dontBroadcast)
{
	int tPlayerCount = GetTeamClientCount(CS_TEAM_T);
	int ctPlayerCount = GetTeamClientCount(CS_TEAM_CT);
	int lives = tPlayerCount > ctPlayerCount ? tPlayerCount : ctPlayerCount;
	respawnsPerTeam[CS_TEAM_T] = lives - tPlayerCount;
	respawnsPerTeam[CS_TEAM_CT] = lives - ctPlayerCount;

	mp_respawn_on_death_t.BoolValue = false;
	mp_respawn_on_death_ct.BoolValue = false;
	if (convarRandomspawn.BoolValue) mp_randomspawn.BoolValue = false;
}

public Action OnPlayerDeath(Event event, const char[] eventName, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int team = GetClientTeam(client);

	if (respawnsPerTeam[team] < 1) return;

	respawningPerTeam[team]++;

	if (team == CS_TEAM_T) mp_respawn_on_death_t.BoolValue = true;
	else if (team == CS_TEAM_CT) mp_respawn_on_death_ct.BoolValue = true;

	if (convarRandomspawn.BoolValue) mp_randomspawn.BoolValue = true;
}

public Action OnPlayerSpawn(Event event, const char[] eventName, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsPlayerAlive(client)) return; // event is fired when late-joining, even when not spawning
	int team = GetClientTeam(client);

	if (respawningPerTeam[team] <= 0) return;

	PrintCenterTextAll("%N respawned due to team imbalance.", client);
	respawnsPerTeam[team]--;
	respawningPerTeam[team]--;

	if (respawningPerTeam[team] > 0) return;

	if (team == CS_TEAM_T) mp_respawn_on_death_t.BoolValue = false;
	else if (team == CS_TEAM_CT) mp_respawn_on_death_ct.BoolValue = false;

	if (convarRandomspawn.BoolValue) mp_randomspawn.BoolValue = false;
}
