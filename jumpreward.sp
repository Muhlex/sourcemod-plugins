#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

public Plugin myinfo =
{
	name = "Jump Reward",
	author = "murlis",
	description = "Highjump for killstreaks.",
	version = "1.0",
	url = "http://steamcommunity.com/id/muhlex"
};

#define PARTICLE_REWARD_ACTIVE "molotov_child_flame01b" // molotov_child_flame01a|b|c // https://i.imgur.com/CCZLGPn.png // train_steam_rising_noise // shacks_policelight_blue_core // bank_steam_noise // light_gaslamp_glow // office_fire // firework_crate_ground_glow_02 // https://i.imgur.com/QoBr1ag.png // rain_puddle_ripples // water_splash_02_continuous
#define PARTICLE_JUMP "extinguish_fire" // extinguish_fire // explosion_molotov_air_down // extinsguish_fire_blastout_01 // explosion_basic_water
#define SOUND_JUMP "ambient/creatures/dog_bark_close_04.wav"
#define SOUND_JUMP_STRONG "ambient/creatures/dog_bark_close_02.wav"

enum
{
	Type_Replace = 0,
	Type_MultiJump,
};

Handle hudSynchronizer[2];

bool pluginLoadedLate;

ConVar convarJumpReward;
ConVar convarJumpRewardType;
ConVar convarJumpRewardVertForce;
ConVar convarJumpRewardHorizForce;
ConVar convarJumpRewardMultiKillBonus;
ConVar convarJumpRewardStrongThreshold;
ConVar convarJumpRewardMultiJumpLimit;
ConVar convarJumpRewardInfinite;

int clientsJumpRewardCount[MAXPLAYERS + 1];
int clientsButtonsPressed[MAXPLAYERS + 1];
int clientsCurrentMultiJump[MAXPLAYERS + 1];
int clientsFireParticleRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errMaxlen)
{
	pluginLoadedLate = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	convarJumpReward = CreateConVar("sm_jumpreward_enable", "1", "Enable Jump Reward.");
	convarJumpRewardType = CreateConVar("sm_jumpreward_type", "1", "0: Replace regular jumps | 1: Multi jump mid-air");
	convarJumpRewardVertForce = CreateConVar("sm_jumpreward_vert_force", "520", "Force for vertical velocity on jump.");
	convarJumpRewardHorizForce = CreateConVar("sm_jumpreward_horiz_force", "200", "Force for horizontal velocity on jump.");
	convarJumpRewardMultiKillBonus = CreateConVar("sm_jumpreward_multi_kill_bonus", "0.2", "Jump force multiplier bonus per each additional kill after the first one.");
	convarJumpRewardStrongThreshold = CreateConVar("sm_jumpreward_strong_threshold", "800", "Force (horiz or vert or both) after which a jump is considered strong (different effects).");
	convarJumpRewardMultiJumpLimit = CreateConVar("sm_jumpreward_multi_jump_limit", "1", "How many jumps can be chained mid-air when multi jump is active.");
	convarJumpRewardInfinite = CreateConVar("sm_jumpreward_infinite", "0", "Make Jump Reward Infinite (no kill bonus is applied).");

	convarJumpRewardInfinite.AddChangeHook(OnConVarChangeInfinite);

	HookEvent("player_death", OnPlayerDeath);
	HookEvent("player_spawn", OnPlayerSpawn);
	HookEvent("player_jump", OnPlayerJump);

	for (int i = 0; i < sizeof hudSynchronizer; i++)
	{
		hudSynchronizer[i] = CreateHudSynchronizer();
	}

	if (pluginLoadedLate) HandlePluginLateLoad();
}

void HandlePluginLateLoad()
{
	// Process the clients already on the server
	for (int client = 1 ; client <= MaxClients ; client++)
	{
		// Check if the client is connected
		if (IsClientConnected(client))
		{
			// Call the client connected forward
			// OnClientConnected(client);

			// Check if the client is in game
			if (IsClientInGame(client))
			{
				// Call the client put in server forward
				OnClientPutInServer(client);
			}
		}
	}
}

public void OnConVarChangeInfinite(ConVar convar, char[] oldValue, char[] newValue)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client)) return;
		if (!IsPlayerAlive(client)) return;
		UpdateHUD(client);

		if (convar.BoolValue) AddJumpRewardParticle(client);
		else if (clientsJumpRewardCount[client] == 0) RemoveJumpRewardParticle(client);
	}
}

public void OnMapStart()
{
	PrecacheSound(SOUND_JUMP);
	PrecacheSound(SOUND_JUMP_STRONG);

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client)) return;
		UpdateJumpRewardCount(client, _, true);
	}
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PostThinkPost, OnClientPostThinkPost);
}

public void OnClientDisconnect(int client)
{
	UpdateJumpRewardCount(client, _, true); // resets particle
	clientsJumpRewardCount[client] = 0;
	clientsButtonsPressed[client] = 0;
	clientsCurrentMultiJump[client] = 0;
}

public void OnClientPostThinkPost(int client)
{
	if (clientsCurrentMultiJump[client] == 0) return;

	bool landed = GetEntityFlags(client) & FL_ONGROUND || GetEntityMoveType(client) == MOVETYPE_LADDER;
	if (landed) clientsCurrentMultiJump[client] = 0;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (
		convarJumpRewardType.IntValue == Type_MultiJump
		&& clientsCurrentMultiJump[client] < convarJumpRewardMultiJumpLimit.IntValue
		&& clientsButtonsPressed[client] & IN_JUMP == 0
		&& buttons & IN_JUMP
		&& GetEntityFlags(client) & FL_ONGROUND == 0
		&& GetEntityMoveType(client) != MOVETYPE_LADDER
	) TryPerformJump(client);

	clientsButtonsPressed[client] = buttons;
}

public Action OnPlayerDeath(Event event, const char[] eventName, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	// return on invalid client indexes
	if (!IsClientInGame(client)) return;

	UpdateJumpRewardCount(client, _, true);

	// return on suicide or if rewards are deactivated by convar
	if (client == attacker || attacker == 0 || !convarJumpReward.BoolValue) return;

	UpdateJumpRewardCount(attacker, 1);
}

public Action OnPlayerSpawn(Event event, const char[] eventName, bool dontBroadcast)
{
	int userID = event.GetInt("userid");
	int client = GetClientOfUserId(userID);

	if (!IsClientInGame(client)) return;

	if (clientsJumpRewardCount[client] >= 1 || convarJumpRewardInfinite.BoolValue) AddJumpRewardParticle(client);

	CreateTimer(0.4, OnAfterSpawn, userID);
}

public Action OnAfterSpawn(Handle timer, int userID)
{
	int client = GetClientOfUserId(userID);
	if (client == 0) return;
	if (!IsClientInGame(client)) return;
	UpdateHUD(client);
}

public Action OnPlayerJump(Event event, const char[] eventName, bool dontBroadcast)
{
	RequestFrame(OnJumpFrame, event.GetInt("userid"));
}

void OnJumpFrame(int userID)
{
	if (convarJumpRewardType.IntValue != Type_Replace) return;

	TryPerformJump(GetClientOfUserId(userID));
}

void TryPerformJump(int client)
{
	if (
		!IsClientInGame(client)
		|| (!convarJumpRewardInfinite.BoolValue && clientsJumpRewardCount[client] == 0)
	) return;

	float clientPos[3], clientVelocity[3], clientDir[3];
	GetClientAbsOrigin(client, clientPos);
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", clientVelocity);
	NormalizeVector(clientVelocity, clientDir);

	float mult = convarJumpRewardInfinite.BoolValue
		? 1.0
		: 1.0 + (clientsJumpRewardCount[client] - 1) * convarJumpRewardMultiKillBonus.FloatValue;

	float vertForce = convarJumpRewardVertForce.FloatValue * mult;
	float horizForce = convarJumpRewardHorizForce.FloatValue * mult;

	for (int i = 0; i < 2; i++) clientVelocity[i] += clientDir[i] * horizForce;
	clientVelocity[2] *= 0.5;
	clientVelocity[2] += vertForce;
	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, clientVelocity);

	if (convarJumpRewardType.IntValue == Type_MultiJump) clientsCurrentMultiJump[client]++;

	float jumpParticlePos[3], jumpParticleAngles[3];
	jumpParticleAngles = clientVelocity;
	NegateVector(jumpParticleAngles);
	GetVectorAngles(jumpParticleAngles, jumpParticleAngles);
	jumpParticlePos = clientPos;
	jumpParticlePos[2] += 24;
	DispatchTEParticle(PARTICLE_JUMP, jumpParticlePos, _, jumpParticleAngles);
	TE_SendToAll();

	char soundBuffer[128] = SOUND_JUMP;
	float threshold = convarJumpRewardStrongThreshold.FloatValue;
	if (horizForce >= threshold - 0.0001 || vertForce >= threshold - 0.0001) soundBuffer = SOUND_JUMP_STRONG;
	SoundPlayWorldAll(client, soundBuffer, 1.0, 92, _, clientPos);

	if (!convarJumpRewardInfinite.BoolValue) UpdateJumpRewardCount(client, -1);
}

void UpdateJumpRewardCount(int client, int summand = 0, bool reset = false)
{
	if (reset)
	{
		clientsJumpRewardCount[client] = 0;
		RemoveJumpRewardParticle(client);
		UpdateHUD(client);
		return;
	}

	int prevJumpRewardCount = clientsJumpRewardCount[client];

	clientsJumpRewardCount[client] += summand;
	if (clientsJumpRewardCount[client] == 0) RemoveJumpRewardParticle(client);

	if (prevJumpRewardCount == 0 && (clientsJumpRewardCount[client] >= 1 || convarJumpRewardInfinite.BoolValue)) AddJumpRewardParticle(client);

	UpdateHUD(client);
}

void UpdateHUD(int client)
{
	if (!IsClientInGame(client)) return;

	float displayTime = 9999999999.0;
	float fadeInTime = 0.5;
	if (!IsPlayerAlive(client)) {
		displayTime = 0.5;
		fadeInTime = 0.0;
	}

	int clientJumpRewardCount = clientsJumpRewardCount[client];
	if (convarJumpRewardInfinite.BoolValue) clientJumpRewardCount = 1;

	int dynamicColor = 255 - clientJumpRewardCount * 85;
	if (dynamicColor < 0) dynamicColor = 0;
	SetHudTextParams(-1.0, 0.76, displayTime, 255, dynamicColor, dynamicColor, 255, 0, 0.0, fadeInTime, 0.5);
	ShowSyncHudText(client, hudSynchronizer[0], "⬆");
	SetHudTextParams(-1.0, 0.82, displayTime, 255, 255, 255, 255, 0, 0.0, fadeInTime, 0.5);
	if (convarJumpRewardInfinite.BoolValue)
		ShowSyncHudText(client, hudSynchronizer[1], "∞");
	else
		ShowSyncHudText(client, hudSynchronizer[1], "%i", clientJumpRewardCount);
}

void DispatchTEParticle(const char[] effectName, const float originPos[3], const float targetPos[3] = NULL_VECTOR, const float angle[3] = NULL_VECTOR)
{
	TE_Start("EffectDispatch");
	TE_WriteFloatArray("m_vOrigin.x", originPos, 3);
	TE_WriteFloatArray("m_vStart.x", targetPos, 3);
	TE_WriteVector("m_vAngles", angle);
	TE_WriteNum("m_nHitBox", GetParticleEffectIndex(effectName));
	TE_WriteNum("m_iEffectName", GetEffectIndex("ParticleEffect"));
	TE_WriteNum("m_fFlags", 0);
}

int GetParticleEffectIndex(const char[] effectName)
{
	static int tableRef = INVALID_STRING_TABLE;
	if (tableRef == INVALID_STRING_TABLE) tableRef = FindStringTable("ParticleEffectNames");
	int index = FindStringIndex(tableRef, effectName);
	if (index != INVALID_STRING_INDEX) return index;
	return 0;
}

int GetEffectIndex(const char[] effectName)
{
	static int tableRef = INVALID_STRING_TABLE;
	if (tableRef == INVALID_STRING_TABLE) tableRef = FindStringTable("EffectDispatch");
	int index = FindStringIndex(tableRef, effectName);
	if (index != INVALID_STRING_INDEX) return index;
	return 0;
}

void AddJumpRewardParticle(int client)
{
	if (!IsClientInGame(client)) return;

	int particle = EntRefToEntIndex(clientsFireParticleRef[client]);
	if (particle != INVALID_ENT_REFERENCE) return;

	float clientPos[3];
	GetClientAbsOrigin(client, clientPos);
	clientPos[2] += -16;

	particle = CreateEntityByName("info_particle_system");
	DispatchKeyValue(particle, "start_active", "0");
	DispatchKeyValue(particle, "effect_name", PARTICLE_REWARD_ACTIVE);
	DispatchSpawn(particle);
	TeleportEntity(particle, clientPos, NULL_VECTOR, NULL_VECTOR);

	// Make Player Parent of the Particle
	SetVariantString("!activator");
	AcceptEntityInput(particle, "SetParent", client, particle, 0);

	ActivateEntity(particle);
	AcceptEntityInput(particle, "start");

	clientsFireParticleRef[client] = EntIndexToEntRef(particle);
}

void RemoveJumpRewardParticle(int client)
{
	int particle = EntRefToEntIndex(clientsFireParticleRef[client]);

	if (particle != INVALID_ENT_REFERENCE)
	{
		AcceptEntityInput(particle, "stop");
		AcceptEntityInput(particle, "kill");
		particle = INVALID_ENT_REFERENCE;
	}
}

void SoundPlayWorldAll(int iEmitFromEntity, const char[] szSound, float fVolume, int iLevel, int iPitch = SNDPITCH_NORMAL, const float vOrigin[3])
{
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientInGame(iClient)) return;

		if (iClient == iEmitFromEntity)
			EmitSoundToClient(iClient, szSound, SOUND_FROM_PLAYER, SNDCHAN_AUTO, iLevel, SND_NOFLAGS, fVolume, iPitch, -1, NULL_VECTOR, NULL_VECTOR, false, 0.0);
		else
			EmitSoundToClient(iClient, szSound, SOUND_FROM_WORLD, SNDCHAN_AUTO, iLevel, SND_NOFLAGS, fVolume, iPitch, -1, vOrigin, NULL_VECTOR, false, 0.0);
	}
}
