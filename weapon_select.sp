#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <cstrike>

#define PATH_ITEMS_GAME "scripts/items/items_game.txt"
#define PREFAB_MAXLEN 64

ConVar mp_t_default_primary;
ConVar mp_ct_default_primary;
ConVar mp_t_default_secondary;
ConVar mp_ct_default_secondary;
ConVar mp_free_armor;

ConVar sm_weapon_rotation_primary;
ConVar sm_weapon_rotation_secondary;

ArrayList weapons;
ArrayList weaponClasses;

ArrayList randomPrimaryPool;
ArrayList randomSecondaryPool;

public Plugin myinfo =
{
	name = "Weapon Select",
	author = "murlis",
	description = "Allows players to select default weapons.",
	version = "1.0",
	url = "http://steamcommunity.com/id/muhlex"
};

public void OnPluginStart()
{
	KeyValues itemsGame = new KeyValues("items_game");
	if (!itemsGame.ImportFromFile(PATH_ITEMS_GAME))
		SetFailState("Unable to load item declaration file from path: %s", PATH_ITEMS_GAME);

	weapons = new ArrayList();
	// dont initialize 'weaponClasses' due to it being assigned a copy of an ArrayList generated in 'GetWeapons'
	randomPrimaryPool = new ArrayList(PREFAB_MAXLEN);
	randomSecondaryPool = new ArrayList(PREFAB_MAXLEN);

	int weaponCount = GetWeapons(itemsGame, weapons, weaponClasses);
	LogMessage("Loaded %i weapons.", weaponCount);
	delete itemsGame;

	mp_t_default_primary = FindConVar("mp_t_default_primary");
	mp_ct_default_primary = FindConVar("mp_ct_default_primary");
	mp_t_default_secondary = FindConVar("mp_t_default_secondary");
	mp_ct_default_secondary = FindConVar("mp_ct_default_secondary");
	mp_free_armor = FindConVar("mp_free_armor");

	sm_weapon_rotation_primary = CreateConVar("sm_weapon_rotation_primary", "", "Space delimited list of randomized default primaries.");
	sm_weapon_rotation_secondary = CreateConVar("sm_weapon_rotation_secondary", "", "Space delimited list of randomized default secondaries.");
	sm_weapon_rotation_primary.AddChangeHook(OnWeaponRotationChange);
	sm_weapon_rotation_secondary.AddChangeHook(OnWeaponRotationChange);
	BuildRandomWeaponPool(CS_SLOT_PRIMARY);
	BuildRandomWeaponPool(CS_SLOT_SECONDARY);

	RegAdminCmd("weapon", OnCommand_Weapon, ADMFLAG_GENERIC, "Changes default weapon for both teams");
	RegAdminCmd("wpn",    OnCommand_Weapon, ADMFLAG_GENERIC, "Changes default weapon for both teams");
	RegAdminCmd("armor",  OnCommand_Armor, ADMFLAG_GENERIC, "Changes starting armor for both teams");
	RegConsoleCmd("weapons", OnCommand_Weapons, "Displays all available weapons");

	HookEvent("round_end", OnRoundEnd);
}

public void OnWeaponRotationChange(ConVar convar, char[] oldValue, char[] newValue)
{
	int slot;
	if (convar == sm_weapon_rotation_primary) slot = CS_SLOT_PRIMARY;
	else slot = CS_SLOT_SECONDARY;
	BuildRandomWeaponPool(slot);
}

public Action OnRoundEnd(Event event, const char[] eventName, bool dontBroadcast)
{
	DrawRandomWeapons();
}

void BuildRandomWeaponPool(int slot)
{
	ArrayList randomPool;
	int weaponListLength = weapons.Length * (PREFAB_MAXLEN + 1);
	char[] weaponList = new char[weaponListLength];
	if (slot == CS_SLOT_PRIMARY)
	{
		randomPool = randomPrimaryPool;
		sm_weapon_rotation_primary.GetString(weaponList, weaponListLength);
	}
	else
	{
		randomPool = randomSecondaryPool;
		sm_weapon_rotation_secondary.GetString(weaponList, weaponListLength);
	}

	randomPool.Clear();

	TrimString(weaponList);
	if (StrEqual(weaponList, "")) return;

	char[][] weaponNames = new char[weapons.Length][PREFAB_MAXLEN];
	int weaponCount = ExplodeString(weaponList, " ", weaponNames, weapons.Length, PREFAB_MAXLEN);

	for (int i = 0; i < weaponCount; i++)
	{
		randomPool.PushString(weaponNames[i]);
	}

	DrawRandomWeapons();
}

void DrawRandomWeapons()
{
	int weaponIndex;
	char weaponName[PREFAB_MAXLEN];
	if (randomPrimaryPool.Length > 0)
	{
		weaponIndex = GetRandomInt(0, randomPrimaryPool.Length - 1);
		randomPrimaryPool.GetString(weaponIndex, weaponName, sizeof(weaponName));
		mp_t_default_primary.SetString(weaponName);
		mp_ct_default_primary.SetString(weaponName);
	}
	if (randomSecondaryPool.Length > 0)
	{
		weaponIndex = GetRandomInt(0, randomSecondaryPool.Length - 1);
		randomSecondaryPool.GetString(weaponIndex, weaponName, sizeof(weaponName));
		mp_t_default_secondary.SetString(weaponName);
		mp_ct_default_secondary.SetString(weaponName);
	}
}

public Action OnCommand_Weapon(int client, int argCount)
{
	if (argCount < 1)
	{
		ReplyToCommand(client, " \x03[Weapon Select] \x01Usage: weapon <name> [name] ... | none primary|secondary");
		return Plugin_Handled;
	}

	char[][] args = new char[argCount][PREFAB_MAXLEN];
	for (int i = 0; i < argCount; i++) GetCmdArg(i + 1, args[i], PREFAB_MAXLEN);

	if (StrEqual(args[0], "none", false))
	{
		if (argCount >= 2 && StrEqual(args[1], "primary"))
		{
			sm_weapon_rotation_primary.SetString("");
			mp_t_default_primary.SetString("");
			mp_ct_default_primary.SetString("");
			LogAction(client, -1, "\"%L\" removed default primary weapon", client);
			PrintToChatAll(" %N \x03removed the \x0Eprimary \x03weapon", client);
		}
		else if (argCount >= 2 && StrEqual(args[1], "secondary"))
		{
			sm_weapon_rotation_secondary.SetString("");
			mp_t_default_secondary.SetString("");
			mp_ct_default_secondary.SetString("");
			LogAction(client, -1, "\"%L\" removed default secondary weapon", client);
			PrintToChatAll(" %N \x03removed the \x0Esecondary \x03weapon", client);
		}
		else ReplyToCommand(client, " \x03[Weapon Select] \x01Usage: weapon none primary|secondary");

		return Plugin_Handled;
	}

	// search for the (partial) specified weapon names
	ArrayList slotWeaponNames[2];
	for (int i = 0; i < sizeof(slotWeaponNames); i++) slotWeaponNames[i] = new ArrayList(PREFAB_MAXLEN);
	StringMap weaponProps;
	char weaponName[PREFAB_MAXLEN];
	int weaponSlot;

	for (int i = 0; i < argCount; i++)
	{
		bool weaponValid = false;
		for (int j = 0; j < weapons.Length; j++)
		{
			weaponProps = weapons.Get(j);
			weaponProps.GetString("name", weaponName, sizeof(weaponName));
			if (StrContains(weaponName, args[i]) > -1)
			{
				weaponProps.GetValue("slot", weaponSlot);
				slotWeaponNames[weaponSlot].PushString(weaponName);
				weaponValid = true;
				break;
			}
		}

		if (!weaponValid)
		{
			ReplyToCommand(client, " \x03[Weapon Select] \x01Invalid weapon: %s", args[i]);
			for (int slot = 0; slot < sizeof(slotWeaponNames); slot++) delete slotWeaponNames[slot];
			return Plugin_Handled;
		}
	}

	for (int slot = 0; slot < sizeof(slotWeaponNames); slot++)
	{
		if (slotWeaponNames[slot].Length == 0) continue;

		char slotDisplayName[16], weaponDisplayName[48];
		slotDisplayName = (slot == CS_SLOT_PRIMARY) ? "primary" : "secondary";

		if (slotWeaponNames[slot].Length == 1)
		{
			slotWeaponNames[slot].GetString(0, weaponName, sizeof(weaponName));
			if (slot == CS_SLOT_PRIMARY)
			{
				sm_weapon_rotation_primary.SetString("");
				mp_t_default_primary.SetString(weaponName);
				mp_ct_default_primary.SetString(weaponName);
			}
			else if (slot == CS_SLOT_SECONDARY)
			{
				sm_weapon_rotation_secondary.SetString("");
				mp_t_default_secondary.SetString(weaponName);
				mp_ct_default_secondary.SetString(weaponName);
			}

			WeaponNameToDisplayName(weaponName, weaponDisplayName, sizeof(weaponDisplayName));

			LogAction(client, -1, "\"%L\" changed default %s weapon to %s", client, slotDisplayName, weaponName);
			PrintToChatAll(" %N \x03changed the \x0E%s \x03weapon to \x01%s", client, slotDisplayName, weaponDisplayName);

			continue;
		}

		if (slotWeaponNames[slot].Length >= 2)
		{
			int convarArgStringLength = slotWeaponNames[slot].Length * (PREFAB_MAXLEN + 1);
			char[] convarArgString = new char[convarArgStringLength];

			// convert the ArrayList to static array to use ImplodeStrings on it
			char[][] weaponNamesStatic = new char[slotWeaponNames[slot].Length][PREFAB_MAXLEN];

			char[][] weaponDisplayNames = new char[slotWeaponNames[slot].Length][sizeof(weaponDisplayName)];
			int weaponDisplayListLength = slotWeaponNames[slot].Length * (sizeof(weaponDisplayName) + 2);
			char[] weaponDisplayList = new char[weaponDisplayListLength];

			for (int i = 0; i < slotWeaponNames[slot].Length; i++)
			{
				slotWeaponNames[slot].GetString(i, weaponName, sizeof(weaponName));
				strcopy(weaponNamesStatic[i], PREFAB_MAXLEN, weaponName);

				WeaponNameToDisplayName(weaponName, weaponDisplayName, sizeof(weaponDisplayName));
				strcopy(weaponDisplayNames[i], sizeof(weaponDisplayName), weaponDisplayName);
			}
			ImplodeStrings(weaponNamesStatic, slotWeaponNames[slot].Length, " ", convarArgString, convarArgStringLength);
			ImplodeStrings(weaponDisplayNames, slotWeaponNames[slot].Length, ", ", weaponDisplayList, weaponDisplayListLength);
			ConVar rotation = (slot == CS_SLOT_PRIMARY) ? sm_weapon_rotation_primary : sm_weapon_rotation_secondary;
			rotation.SetString(convarArgString);

			LogAction(client, -1, "\"%L\" changed %s weapon rotation to %s", client, slotDisplayName, convarArgString);
			PrintToChatAll(" %N \x03changed the \x0E%s \x03weapon \x0Erotation \x03to \x01%s", client, slotDisplayName, weaponDisplayList);
		}
	}

	for (int slot = 0; slot < sizeof(slotWeaponNames); slot++) delete slotWeaponNames[slot];
	return Plugin_Handled;
}

public Action OnCommand_Armor(int client, int args)
{
	char arg[2];
	int armorValue;
	GetCmdArg(1, arg, sizeof(arg));
	armorValue = StringToInt(arg);

	if (args < 1 || armorValue < 0 || armorValue > 2 || (armorValue == 0 && !StrEqual(arg, "0")))
	{
		ReplyToCommand(client, " \x03[Weapon Select] \x01Usage: armor <0 / 1 / 2>");
		return Plugin_Handled;
	}

	char displayArmorValue[32];
	switch (armorValue)
	{
		case 0:
			displayArmorValue = "no armor";
		case 1:
			displayArmorValue = "Kevlar only";
		case 2:
			displayArmorValue = "Kevlar & Helmet";
	}

	mp_free_armor.IntValue = armorValue;
	LogAction(client, -1, "\"%L\" changed armor to %s", client, displayArmorValue);
	if (armorValue == 0) PrintToChatAll(" %N \x03disabled \x0Earmor", client);
	else PrintToChatAll(" %N \x03changed \x0Earmor \x03to \x01%s", client, displayArmorValue);

	return Plugin_Handled;
}

public Action OnCommand_Weapons(int client, int args)
{
	ReplyToCommand(client, " \x03[Weapon Select] \x0EAVAILABLE WEAPONS:");

	for (int i = 0; i < weaponClasses.Length; i++)
	{
		char className[PREFAB_MAXLEN], weaponList[8192];
		weaponClasses.GetString(i, className, sizeof(className));
		ArrayList classWeaponNames = GetWeaponNamesByProp("class", className);
		StrToUppercase(className);

		ReplyToCommand(client, " \x03%s", className);
		for (int j = 0; j < classWeaponNames.Length; j++)
		{
			char weaponName[PREFAB_MAXLEN], weaponDisplayName[48];
			classWeaponNames.GetString(j, weaponName, sizeof(weaponName));
			WeaponNameToDisplayName(weaponName, weaponDisplayName, sizeof(weaponDisplayName));
			Format(weaponList, sizeof(weaponList), j == 0 ? "%s%s" : "%s %s", weaponList, weaponDisplayName);
		}
		ReplyToCommand(client, "%s", weaponList);
		delete classWeaponNames;
	}
}

int GetWeapons(const KeyValues kv, const ArrayList resWeapons, ArrayList &resWeaponClasses)
{
	if (!kv.JumpToKey("prefabs"))
		SetFailState("Unable to find section 'prefabs' in %s", PATH_ITEMS_GAME);

	if (!kv.GotoFirstSubKey())
		SetFailState("Section 'prefabs' in %s appears to be empty.", PATH_ITEMS_GAME);

	char prefab[PREFAB_MAXLEN], parentPrefab[PREFAB_MAXLEN];
	int weaponCount = 0;

	ArrayList weaponPrimaryPrefabs = new ArrayList(PREFAB_MAXLEN);

	// first, figure out which primary weapon prefab parents (e.g. rifle, smg, ....) exist
	do
	{
		kv.GetSectionName(prefab, sizeof(prefab));
		if (!kv.JumpToKey("prefab")) continue;
		kv.GetString(NULL_STRING, parentPrefab, sizeof(parentPrefab));

		if (StrEqual(parentPrefab, "primary")) weaponPrimaryPrefabs.PushString(prefab);

		kv.GoBack();

	} while (kv.GotoNextKey());

	resWeaponClasses = weaponPrimaryPrefabs.Clone();
	resWeaponClasses.PushString("secondary");

	kv.GoBack();
	kv.GotoFirstSubKey();

	// iterate again and fetch primaries & secondaries this time
	do
	{
		kv.GetSectionName(prefab, sizeof(prefab));
		if (!kv.JumpToKey("prefab")) continue;
		kv.GetString(NULL_STRING, parentPrefab, sizeof(parentPrefab));

		int weaponSlot = -1;
		if (weaponPrimaryPrefabs.FindString(parentPrefab) > -1) weaponSlot = CS_SLOT_PRIMARY;
		if (StrEqual(parentPrefab, "secondary")) weaponSlot = CS_SLOT_SECONDARY;

		if (weaponSlot > -1) // it's actually a weapon
		{
			char weaponName[PREFAB_MAXLEN];
			weaponName = prefab;
			ReplaceString(weaponName, sizeof(weaponName), "_prefab", "");

			StringMap weaponProps = new StringMap();
			weaponProps.SetString("name", weaponName);
			weaponProps.SetValue("slot", weaponSlot);
			weaponProps.SetString("class", parentPrefab);
			PrintToServer("%s: %s", weaponName, parentPrefab);
			resWeapons.Push(weaponProps);
			weaponCount++;
		}

		kv.GoBack();

	} while (kv.GotoNextKey());

	delete weaponPrimaryPrefabs;
	return weaponCount;
}

ArrayList GetWeaponNamesByProp(const char[] prop, const char[] value)
{
	ArrayList result = new ArrayList(PREFAB_MAXLEN);
	StringMap weaponProps;
	for (int i = 0; i < weapons.Length; i++)
	{
		weaponProps = weapons.Get(i);
		char currValue[PREFAB_MAXLEN], weaponName[PREFAB_MAXLEN];
		weaponProps.GetString(prop, currValue, sizeof(currValue));
		weaponProps.GetString("name", weaponName, sizeof(weaponName));

		if (StrEqual(currValue, value)) result.PushString(weaponName);
	}
	return result;
}

void StrToUppercase(char [] string)
{
	for (int i = 0; i < strlen(string); i++) string[i] = CharToUpper(string[i]);
}

void WeaponNameToDisplayName(const char[] weaponName, char[] displayName, int displayNameLength)
{
	strcopy(displayName, displayNameLength, weaponName);
	ReplaceString(displayName, displayNameLength, "weapon_", "");
	StrToUppercase(displayName);
}

stock void LogArrayListStrings(const ArrayList arr)
{
	for (int i = 0; i < arr.Length; i++)
	{
		char[] buffer = new char[arr.BlockSize];
		arr.GetString(i, buffer, arr.BlockSize);
		PrintToServer(buffer);
	}
}
