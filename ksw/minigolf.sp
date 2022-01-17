#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

#define BALL_MODEL "models/props/de_dust/hr_dust/dust_soccerball/dust_soccer_ball001.mdl"
#define EYE_HEIGHT 64
#define BALL_RADIUS 8

#define C_CIRCLE "⚫"

int colorsRGB[][] = {
	{ 236, 28, 90 }, // red
	{ 245, 128, 35 }, // orange
	{ 250, 232, 62 }, // yellow
	{ 190, 254, 143 }, // lime
	{ 82, 194, 65 }, // green
	{ 61, 129, 194 }, // blue
	{ 100, 75, 158 }, // purple
	{ 210, 44, 229 }, // orchid
	{ 255, 255, 255 } // white
};

char colorsChat[][4] = {
	"\x07", // red
	"\x10", // orange
	"\x09", // yellow
	"\x06", // lime
	"\x04", // green
	"\x0C", // blue
	"\x03", // purple
	"\x0E", // orchid
	"\x01" // white
};

bool g_mapStarted = false;

enum struct Position {
	float origin[3];
	float angles[3];
}

enum struct Course {
	int id;
	Position spawn;
	ArrayList goalEntRefs;

	// Init() by Minigolf
}

enum struct Player {
	int client;
	int ballEntRef;
	int ballColorIndex;
	int chatColorIndex;

	int totalThrows;
	StringMap courseThrows;
	bool completedActiveCourse;

	void Init(int client, int colorIndex) {
		this.client = client;
		this.ballEntRef = INVALID_ENT_REFERENCE;
		this.ballColorIndex = colorIndex;
		this.chatColorIndex = colorIndex;
		this.totalThrows = 0;
		this.completedActiveCourse = false;
		this.courseThrows = new StringMap();
	}

	void DeleteHandles() {
		if (this.courseThrows != INVALID_HANDLE) delete this.courseThrows;
	}
}

enum struct Minigolf {
	bool inProgress;
	bool isReset;
	int activeCourseIndex;
	int activePlayerIndex;
	Handle timerWaitForBallSleep;
	ArrayList resetEntRefs;
	ArrayList courses;
	ArrayList players;

	int GetPlayerIndexOfClient(int client) {
		return this.players.FindValue(client, Player::client);
	}

	void ClearEntities() {
		for (int playerIndex = 0; playerIndex < this.players.Length; playerIndex++) {
			KillPlayerBallEntity(playerIndex);
		}
	}

	void Reset() {
		if (this.courses.Length == 0) return;

		this.ClearEntities();
		this.inProgress = false;
		this.isReset = true;
		this.activeCourseIndex = 0;
		this.activePlayerIndex = 0;
		this.InitPlayers();

		this.SetActiveCourse(0);
	}

	bool Start() {
		if (!this.isReset || this.players.Length == 0) return false;

		this.inProgress = true;
		this.isReset = false;
		this.activeCourseIndex = 0;
		this.activePlayerIndex = 0;

		this.SetActivePlayer(0);

		return true;
	}

	void SetActivePlayer(int playerIndex) {
		this.activePlayerIndex = playerIndex;
		ChangeClientTeam(this.players.Get(playerIndex, Player::client), CS_TEAM_CT);
		PrintToChatAll(
			" %s%s %N \x01start turn",
			colorsChat[this.players.Get(playerIndex, Player::chatColorIndex)],
			C_CIRCLE,
			this.players.Get(playerIndex, Player::client)
		);
	}

	void NextPlayer() {
		int nextPlayerIndex = this.activePlayerIndex;
		bool playerCompletedCourse;
		int numCompletions = 0;

		do {
			nextPlayerIndex++;
			if (nextPlayerIndex == this.players.Length) nextPlayerIndex = 0;

			playerCompletedCourse = this.players.Get(nextPlayerIndex, Player::completedActiveCourse);
			if (playerCompletedCourse) numCompletions++;
		} while (playerCompletedCourse && numCompletions < this.players.Length);

		if (numCompletions == this.players.Length) return;

		this.SetActivePlayer(nextPlayerIndex);
	}

	void SetActiveCourse(int courseIndex) {
		// unhook previous goals
		ArrayList goalEntRefs = this.courses.Get(this.activeCourseIndex, Course::goalEntRefs);
		for (int goalIndex = 0; goalIndex < goalEntRefs.Length; goalIndex++) {
			UnhookSingleEntityOutput(EntRefToEntIndex(goalEntRefs.Get(goalIndex)), "OnStartTouch", OnGoalTouch);
		}

		// hook new goals
		goalEntRefs = this.courses.Get(courseIndex, Course::goalEntRefs);
		for (int goalIndex = 0; goalIndex < goalEntRefs.Length; goalIndex++) {
			HookSingleEntityOutput(EntRefToEntIndex(goalEntRefs.Get(goalIndex)), "OnStartTouch", OnGoalTouch);
		}

		this.activeCourseIndex = courseIndex;

		Course activeCourse;
		this.courses.GetArray(this.activeCourseIndex, activeCourse);

		for (int playerIndex = 0; playerIndex < this.players.Length; playerIndex++) {
			this.players.Set(playerIndex, false, Player::completedActiveCourse);
			UpdatePlayerBallEntity(playerIndex, activeCourse.spawn.origin, activeCourse.spawn.angles, _, true);
		}
	}

	void NextCourse() {
		int nextCourseIndex = this.activeCourseIndex + 1;
		if (nextCourseIndex == this.courses.Length) {
			this.EndGame();
			return;
		}

		this.SetActiveCourse(nextCourseIndex);
		this.NextPlayer();
	}

	void EndGame() {
		ChangeClientTeam(this.players.Get(this.activePlayerIndex, Player::client), CS_TEAM_SPECTATOR);
		PrintScoreboard();
	}

	void Init() {
		this.courses = new ArrayList(sizeof(Course));
		this.players = new ArrayList(sizeof(Player));
	}

	void InitCourses() {
		this.courses.Clear();

		int ent = -1;
		char entName[256];
		// loop through all golf spawnpoints to find the number of courses
		int courseCount = 0;
		while ((ent = FindEntityByClassname(ent, "info_deathmatch_spawn")) != -1) {
			GetEntPropString(ent, Prop_Data, "m_iName", entName, sizeof(entName));

			if (ReplaceString(entName, sizeof(entName), "golf_spawn_", "") == 1) {
				Course course;

				course.id = StringToInt(entName);
				GetEntPropVector(ent, Prop_Send, "m_vecOrigin", course.spawn.origin);
				course.spawn.origin[2] += BALL_RADIUS;
				GetEntPropVector(ent, Prop_Send, "m_angRotation", course.spawn.angles);

				this.courses.PushArray(course);
				courseCount++;
			}
		}

		LogMessage("Loaded %i courses.", courseCount);

		this.courses.SortCustom(SortCourses);
		this.InitGoals();
	}

	void InitGoals() {
		ArrayList goalEntRefs;
		// delete all existing goal entity references
		for (int i = 0; i < this.courses.Length; i++) {
			goalEntRefs = this.courses.Get(i, Course::goalEntRefs);
			if (goalEntRefs != INVALID_HANDLE) delete goalEntRefs;
			goalEntRefs = new ArrayList();
			this.courses.Set(i, goalEntRefs, Course::goalEntRefs);
		}

		int ent = -1;
		char entName[256];
		// loop through all goals and assign them to their respective courses
		while ((ent = FindEntityByClassname(ent, "trigger_multiple")) != -1) {
			GetEntPropString(ent, Prop_Data, "m_iName", entName, sizeof(entName));

			if (ReplaceString(entName, sizeof(entName), "golf_goal_", "") == 1) {
				int courseIndex = this.courses.FindValue(StringToInt(entName), Course::id);

				goalEntRefs = this.courses.Get(courseIndex, Course::goalEntRefs);
				goalEntRefs.Push(EntIndexToEntRef(ent));
			}
		}
	}

	void InitResets() {
		if (this.resetEntRefs != INVALID_HANDLE) delete this.resetEntRefs;
		this.resetEntRefs = new ArrayList();

		int ent = -1;
		char entName[256];
		// loop through all goals and assign them to their respective courses
		while ((ent = FindEntityByClassname(ent, "trigger_multiple")) != -1) {
			GetEntPropString(ent, Prop_Data, "m_iName", entName, sizeof(entName));

			if (StrEqual(entName, "golf_reset")) {
				this.resetEntRefs.Push(EntIndexToEntRef(ent));
			}
		}

		// hook resets right away
		for (int resetIndex = 0; resetIndex < this.resetEntRefs.Length; resetIndex++) {
			HookSingleEntityOutput(EntRefToEntIndex(this.resetEntRefs.Get(resetIndex)), "OnStartTouch", OnResetTouch);
		}
	}

	void InitPlayers() {
		Player player;

		// clear existing
		for (int i = 0; i < this.players.Length; i++) {
			this.players.GetArray(i, player);
			player.DeleteHandles();
		}
		this.players.Clear();

		// initialize new
		int playerIndex;
		for (int i = 1; i <= MaxClients; i++) {
			if (!IsClientInGame(i)) continue;

			ChangeClientTeam(i, CS_TEAM_SPECTATOR);

			player.Init(i, playerIndex % sizeof(colorsRGB));
			this.players.PushArray(player, sizeof(player));

			playerIndex++;
		}
	}
}

Minigolf game;

public Plugin myinfo = {
	name = "ksw_minigolf",
	author = "murlis",
	description = "",
	version = "1.0",
	url = "http://steamcommunity.com/id/muhlex"
};

public void OnPluginStart() {
	AddCommandListener(OnCommand_JoinTeam, "jointeam");
	HookEvent("round_start", OnRoundStart);
	HookEvent("player_team", OnPlayerTeam, EventHookMode_Pre);
	HookEvent("player_spawned", OnPlayerSpawn);
	HookEvent("grenade_thrown", OnGrenadeThrow);

	RegAdminCmd("golf_start", OnCommand_Start, ADMFLAG_GENERIC);
	RegAdminCmd("golf_reset", OnCommand_Reset, ADMFLAG_GENERIC);
	RegAdminCmd("golf_goto", OnCommand_Goto, ADMFLAG_GENERIC);
	RegAdminCmd("golf_end_turn", OnCommand_EndTurn, ADMFLAG_GENERIC);

	game.Init();
}

public void OnPluginEnd() {
	game.ClearEntities();
}

public void OnMapStart() {
	PrecacheModel(BALL_MODEL);
	g_mapStarted = false;

	game.InitCourses();
}

public void OnClientConnected(int client) {
	PrintToChatAll("%N joined the server.", client);
}

public void OnClientPostAdminCheck(int client) {
	CreateTimer(0.1, Timer_PlayerConnect, GetClientUserId(client));
}
Action Timer_PlayerConnect(Handle timer, int userID) {
	int client = GetClientOfUserId(userID);

	if (client == 0 || !IsClientInGame(client)) return;
	if (g_mapStarted) ChangeClientTeam(client, CS_TEAM_SPECTATOR);
	else {
		ChangeClientTeam(client, CS_TEAM_CT);
		g_mapStarted = true;
	}
}

public void OnClientDisconnect(int client) {
	PrintToChatAll("%N left the server.", client);

	int playerIndex = game.GetPlayerIndexOfClient(client);
	if (playerIndex == -1) return;

	if (game.inProgress && game.activePlayerIndex == playerIndex) {
		if (game.players.Length == 0) game.EndGame();
		else game.NextPlayer();
	}

	Player player;
	game.players.GetArray(playerIndex, player);
	player.DeleteHandles();
	game.players.Erase(playerIndex);
}

public Action OnCommand_Start(int client, int argCount) {
	game.Start();
}
public Action OnCommand_Reset(int client, int argCount) {
	ServerCommand("mp_restartgame 1");
}
public Action OnCommand_Goto(int client, int argCount) {
	PrintToServer("%i args", argCount);
	if (argCount < 1) return;
	char argBuffer[32];
	GetCmdArg(1, argBuffer, sizeof(argBuffer));
	int targetCourse = StringToInt(argBuffer);
	PrintToServer("Going to %i", targetCourse);
	game.SetActiveCourse(targetCourse);

	int activeClient = game.players.Get(game.activePlayerIndex, Player::client);
	if (activeClient != 0 && GetClientTeam(client) != CS_TEAM_SPECTATOR) {
		ChangeClientTeam(activeClient, CS_TEAM_SPECTATOR);
	}
	game.NextPlayer();
}
public Action OnCommand_EndTurn(int client, int argCount) {
	int activeClient = game.players.Get(game.activePlayerIndex, Player::client);
	if (activeClient != 0 && GetClientTeam(client) != CS_TEAM_SPECTATOR) {
		ChangeClientTeam(activeClient, CS_TEAM_SPECTATOR);
	}
	game.NextPlayer();
}

public Action OnCommand_JoinTeam(int client, const char[] command, int argCount) {
	// disallow players from switching teams
	return Plugin_Handled;
}

public Action OnRoundStart(Event event, const char[] eventName, bool dontBroadcast) {
	game.InitGoals();
	game.InitResets();
	game.Reset();
}

public Action OnPlayerTeam(Event event, const char[] eventName, bool dontBroadcast) {
	if (
		dontBroadcast
		|| event.GetBool("disconnect")
		|| event.GetBool("silent")
	) return Plugin_Continue;

	event.SetBool("silent", true);
	return Plugin_Changed;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2]) {
	// prevent crouching
	buttons &= ~IN_DUCK;
	return Plugin_Changed;
}

public Action OnPlayerSpawn(Event event, const char[] eventName, bool dontBroadcast) {
	if (!game.inProgress) return;
	RequestFrame(OnAfterPlayerSpawn, event.GetInt("userid"));
}
void OnAfterPlayerSpawn(int userID) {
	int client = GetClientOfUserId(userID);
	if (client == 0 || !IsClientInGame(client)) return;

	SetEntityMoveType(client, MOVETYPE_NONE);
	SetEntityRenderMode(client, RENDER_NONE);

	// teleport to ball
	int playerIndex = game.GetPlayerIndexOfClient(client);
	int ballEnt = EntRefToEntIndex(game.players.Get(playerIndex, Player::ballEntRef));
	float ballOrigin[3];
	GetEntPropVector(ballEnt, Prop_Send, "m_vecOrigin", ballOrigin);

	ballOrigin[2] -= EYE_HEIGHT - (BALL_RADIUS * 3);

	TeleportEntity(client, ballOrigin, NULL_VECTOR, NULL_VECTOR);
	ArrayList goalEntRefs = game.courses.Get(game.activeCourseIndex, Course::goalEntRefs);
	ClientLookAtEnt(client, goalEntRefs.Get(0));

	GivePlayerItem(client, "weapon_decoy");
}

public Action OnGrenadeThrow(Event event, const char[] eventName, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsClientInGame(client)) return;
	char weaponName[64];
	event.GetString("weapon", weaponName, sizeof(weaponName));
	if (!StrEqual(weaponName, "decoy")) return;

	int decoyEnt = FindEntityByClassname(-1, "decoy_projectile");

	float ballOrigin[3], ballVelocity[3], clientEyesOrigin[3];
	GetEntPropVector(decoyEnt, Prop_Send, "m_vecOrigin", ballOrigin);
	GetEntPropVector(decoyEnt, Prop_Send, "m_vecVelocity", ballVelocity);
	AcceptEntityInput(decoyEnt, "Kill");

	GetClientEyePosition(client, clientEyesOrigin);
	ScaleVector(ballVelocity, 1.0);
	int playerIndex = game.GetPlayerIndexOfClient(client);
	UpdatePlayerBallEntity(playerIndex, clientEyesOrigin, _, ballVelocity);
	ChangeClientTeam(client, CS_TEAM_SPECTATOR);

	// update total throws
	int totalThrows = game.players.Get(playerIndex, Player::totalThrows);
	game.players.Set(playerIndex, ++totalThrows, Player::totalThrows);

	// update course throws
	StringMap courseThrows = game.players.Get(playerIndex, Player::courseThrows);
	char activeCourseIndexString[4];
	int activeCourseThrows;
	IntToString(game.activeCourseIndex, activeCourseIndexString, sizeof(activeCourseIndexString));
	if (!courseThrows.GetValue(activeCourseIndexString, activeCourseThrows)) activeCourseThrows = 0;
	courseThrows.SetValue(activeCourseIndexString, ++activeCourseThrows);

	PrintScoreboard(game.activeCourseIndex);

	game.timerWaitForBallSleep = CreateTimer(0.1, Timer_WaitForBallSleep, GetClientUserId(client), TIMER_REPEAT);
}

public Action Timer_WaitForBallSleep(Handle timer, int client) {
	client = GetClientOfUserId(client);
	if (client == 0 || !IsClientInGame(client)) return Plugin_Stop;

	int playerIndex = game.GetPlayerIndexOfClient(client);
	int ballEnt = EntRefToEntIndex(game.players.Get(playerIndex, Player::ballEntRef));
	bool isAwake = view_as<bool>(GetEntProp(ballEnt, Prop_Data, "m_bAwake"));
	if (isAwake) return Plugin_Continue;

	// ball is asleep -> turn is over
	game.NextPlayer();
	return Plugin_Stop;
}

public void OnGoalTouch(const char[] output, int caller, int activator, float delay) {
	int playerIndex = game.players.FindValue(EntIndexToEntRef(activator), Player::ballEntRef);
	if (playerIndex == -1) return;

	game.players.Set(playerIndex, true, Player::completedActiveCourse);
	if (game.timerWaitForBallSleep != INVALID_HANDLE) KillTimer(game.timerWaitForBallSleep);
	KillPlayerBallEntity(playerIndex);

	PrintToChatAll(
		" %s%s %N finished course %i!",
		colorsChat[game.players.Get(playerIndex, Player::chatColorIndex)],
		C_CIRCLE,
		game.players.Get(playerIndex, Player::client),
		game.activeCourseIndex + 1
	);

	int numCompletions = 0;

	for (int i = 0; i < game.players.Length; i++) {
		if (game.players.Get(i, Player::completedActiveCourse)) numCompletions++;
	}

	if (numCompletions == game.players.Length) {
		char playerCircles[MAXPLAYERS * sizeof(colorsChat[]) + 1];
		GetPlayerCircles(playerCircles, sizeof(playerCircles));
		PrintToChatAll(" %s \x01Course %i complete!", playerCircles, game.activeCourseIndex + 1);
		game.NextCourse();
		return;
	}
	if (playerIndex == game.activePlayerIndex) game.NextPlayer();
}

public void OnResetTouch(const char[] output, int caller, int activator, float delay) {
	int playerIndex = game.players.FindValue(EntIndexToEntRef(activator), Player::ballEntRef);
	if (playerIndex == -1) return;

	Course activeCourse;
	game.courses.GetArray(game.activeCourseIndex, activeCourse);

	if (game.timerWaitForBallSleep != INVALID_HANDLE) KillTimer(game.timerWaitForBallSleep);
	UpdatePlayerBallEntity(playerIndex, activeCourse.spawn.origin, activeCourse.spawn.angles, _, true);
	if (playerIndex == game.activePlayerIndex) game.NextPlayer();
}

void SetPlayerColorOnEntity(int entity, int playerIndex, int alpha = 255) {
	int colorIndex = game.players.Get(playerIndex, Player::ballColorIndex);

	if (alpha != 255) SetEntityRenderMode(entity, RENDER_TRANSCOLOR);

	SetEntityRenderColor(
		entity,
		colorsRGB[colorIndex][0],
		colorsRGB[colorIndex][1],
		colorsRGB[colorIndex][2],
		alpha
	);
}

void KillPlayerBallEntity(int playerIndex) {
	int ballEnt = EntRefToEntIndex(game.players.Get(playerIndex, Player::ballEntRef));
	if (ballEnt != INVALID_ENT_REFERENCE) AcceptEntityInput(ballEnt, "Kill");
}

void UpdatePlayerBallEntity(int playerIndex, const float origin[3] = NULL_VECTOR, const float angles[3] = NULL_VECTOR, const float velocity[3] = NULL_VECTOR, bool spawnprotected = false) {
	KillPlayerBallEntity(playerIndex);

	int ballEnt = CreateEntityByName("prop_physics_override");
	DispatchKeyValue(ballEnt, "model", BALL_MODEL);
	DispatchKeyValue(ballEnt, "overridescript", "mass,100,inertia,1.0,damping,0.0,rotdamping,8.0,drag,0.0"); // nothing: "mass,1,inertia,1.0,damping,0.0,rotdamping,0.0,drag,0.0"
	SetPlayerColorOnEntity(ballEnt, playerIndex);
	if (spawnprotected) SetPlayerColorOnEntity(ballEnt, playerIndex, 150); // set alpha to protected ball

	DispatchSpawn(ballEnt);
	if (spawnprotected) SetEntityMoveType(ballEnt, MOVETYPE_NONE); // freeze protected ball
	TeleportEntity(ballEnt, origin, angles, velocity);

	game.players.Set(playerIndex, EntIndexToEntRef(ballEnt), Player::ballEntRef);
}

void ClientLookAtEnt(int client, int entity) {
	float eyesOrigin[3], entityOrigin[3], originDifference[3], angles[3];
	GetClientEyePosition(client, eyesOrigin);
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", entityOrigin);
	MakeVectorFromPoints(eyesOrigin, entityOrigin, originDifference);
	GetVectorAngles(originDifference, angles);
	TeleportEntity(client, NULL_VECTOR, angles, NULL_VECTOR);
}

void GetPlayerCircles(char[] output, int outputSize) {
	for (int i = 0; i < game.players.Length; i++) {
		Format(output, outputSize, "%s %s%s",
			output,
			colorsChat[game.players.Get(i, Player::chatColorIndex)],
			C_CIRCLE
		);
	}
}

void GetPlacementDigit(int digit, char[] placementDigit, int charLen) {
	char digits[][] = {
		"⒈", "⒉", "⒊", "⒋", "⒌", "⒍", "⒎", "⒏", "⒐", "⒑",
		"⒒", "⒓", "⒔", "⒕", "⒖", "⒗", "⒘", "⒙", "⒚", "⒛"
	};
	strcopy(placementDigit, charLen, digits[digit - 1]);
}

void GetFixedWidthDigit(int digit, char[] fixedDigit, int len) {
	char digits[][] = {
		"０", "１", "２", "３", "４", "５", "６", "７", "８", "９",
	};
	strcopy(fixedDigit, len, digits[digit]);
}

void GetFixedWidthNumber(int number, char[] output, int len) {
	char lastDigitFixed[4];
	do {
		int lastDigit = number % 10;
		GetFixedWidthDigit(lastDigit, lastDigitFixed, sizeof(lastDigitFixed));
		Format(output, len, "%s%s", lastDigitFixed, output);
		number /= 10;
	} while (number > 0);
}

int StrLenMB(const char[] string) {
	int len = strlen(string);
	int count;
	for (int i = 0; i < len; i++) count += ((string[i] & 0xc0) != 0x80) ? 1 : 0;
	return count;
}

void PadString(char[] string, int len, int num, char[] padChar) {
	int diff = num - StrLenMB(string);
	if (diff < 1) return;
	for (int i = 0; i < diff; i++) {
		Format(string, len, "%s%s", padChar, string);
	}
}

void PrintScoreboard(int courseIndex = -1) {
	ArrayList sortedPlayers = game.players.Clone();
	sortedPlayers.SortCustom(SortPlayersByScore);

	PrintToChatAll(" ");
	if (courseIndex == -1) PrintToChatAll(" \x08⸻ \x01Final Score \x08⸻");

	for (int i = 0; i < sortedPlayers.Length; i++) {

		char fixedCourseThrows[16], fixedTotalThrows[4 * 8], placementDigit[4];
		if (courseIndex > -1) {
			StringMap playerCourseThrows = sortedPlayers.Get(i, Player::courseThrows);
			char courseIndexString[4];
			int courseThrows;
			IntToString(courseIndex, courseIndexString, sizeof(courseIndexString));
			if (!playerCourseThrows.GetValue(courseIndexString, courseThrows)) courseThrows = 0;

			GetFixedWidthNumber(courseThrows, fixedCourseThrows, sizeof(fixedCourseThrows));
			PadString(fixedCourseThrows, sizeof(fixedCourseThrows), 2, "　");
		}


		GetFixedWidthNumber(sortedPlayers.Get(i, Player::totalThrows), fixedTotalThrows, sizeof(fixedTotalThrows));
		PadString(fixedTotalThrows, sizeof(fixedTotalThrows), 3, "　");
		GetPlacementDigit(i + 1, placementDigit, sizeof(placementDigit));

		int chatColorIndex = sortedPlayers.Get(i, Player::chatColorIndex);

		if (courseIndex > -1) {
			PrintToChatAll(
				"%s  %s%s   \x08|   \x01⚐ %s   \x08|   \x01⚑ %s   \x08|   \x08%N",
				placementDigit,
				colorsChat[chatColorIndex],
				C_CIRCLE,
				fixedCourseThrows,
				fixedTotalThrows,
				sortedPlayers.Get(i, Player::client)
			);
		} else {
			PrintToChatAll(
				"%s  %s%s   \x08|   \x01⚑ %s   \x08|   \x08%N",
				placementDigit,
				colorsChat[chatColorIndex],
				C_CIRCLE,
				fixedTotalThrows,
				sortedPlayers.Get(i, Player::client)
			);
		}
	}

	PrintToChatAll(" ");
}

int SortCourses(int index1, int index2, Handle array, Handle handle) {
	if (view_as<ArrayList>(array).Get(index1, Course::id) < view_as<ArrayList>(array).Get(index2, Course::id)) return -1;
	else return 1;
}

int SortPlayersByScore(int index1, int index2, Handle array, Handle handle) {
	if (view_as<ArrayList>(array).Get(index1, Player::totalThrows) < view_as<ArrayList>(array).Get(index2, Player::totalThrows)) return -1;
	else return 1;
}
