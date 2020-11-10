#include <sourcemod>
#include <sdktools>
#include <multicolors>
#include <autoexecconfig>
#undef REQUIRE_PLUGIN
#include <pugsetup>
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required

//#define DEBUG

#define MAXROUNDS 150 //including overtime :s
#define MAXTEAMPLAYERS 5

int iRound = 0;
bool g_bStop[MAXPLAYERS+1];
bool g_RepeatTimer = false;
bool g_Restored = false;

bool g_ctUnpaused = false;
bool g_tUnpaused = false;

bool g_CompletedStopVotes[4] = false;

ConVar gc_sChatTag, gc_fRepeat, gc_bDeleteFile, gc_bLostPlayerOnly, gc_bStopVoting, gc_fStopVotingPercentage;

char g_ssPrefix[128];

char g_BackupPrefix[PLATFORM_MAX_PATH], g_BackupPrefixPattern[PLATFORM_MAX_PATH];
int g_iBackupPrefixLen;
int g_iTime;
char g_sTime[32];

bool g_RestoreRoundAtRoundStart;
int g_Round = -1;
int g_Type = -1;

bool g_RoundEnd;

bool g_Pug;

public Plugin myinfo =
{
    name = "[PugSetup] RestoreRound",
    author = "Cruze",
    description = "Player can type .stop command to restore last round. Admins can type .res to restore any round.",
    version = "1.0-beta",
    url = "http://steamcommunity.com/profiles/76561198132924835"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("PugSetup_GetGameState");
	return APLRes_Success;
}

public void OnPluginStart()
{
	HookEvent("round_start", Event_RoundStart);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("player_team", Event_Changeteam);
	HookUserMessage(GetUserMessageId("TextMsg"), Event_TextMsgHook);
	AddCommandListener(Event_UnpauseMatchCvar, "mp_unpause_match");

	RegConsoleCmd("sm_unpause", Command_Unpause, "Requests an unpause");
	RegAdminCmd("sm_restoreround", Command_Restore, ADMFLAG_GENERIC, "Restores last rounds.");
	RegAdminCmd("sm_deleteallbackuprounds", Command_DeleteAllRounds, ADMFLAG_ROOT, "Deletes all backup rounds.");

	AutoExecConfig_SetFile("RestoreRound");
	AutoExecConfig_SetCreateFile(true);

	gc_sChatTag = AutoExecConfig_CreateConVar("sm_pug_rr_chattag", "[{lightgreen}PUG{default}]", "Chat tag for chat prints");
	gc_fRepeat = AutoExecConfig_CreateConVar("sm_pug_rr_repeat", "5.0", "Repeat message of \"round restore\" and \"unpause to resume match\" every x seconds. 0.0 to disable repeat.");
	gc_bDeleteFile = AutoExecConfig_CreateConVar("sm_pug_rr_delete_file", "0", "Delete backup files every map start/reload? WARNING: If enabled, you can lose backup files when server crashed. It's recommended to use sm_deleteallbackuprounds instead.");
	gc_bLostPlayerOnly = AutoExecConfig_CreateConVar("sm_pug_rr_lost_player_only", "0", ".stop can only be usable if team has lost its player?");
	gc_bStopVoting = AutoExecConfig_CreateConVar("sm_pug_rr_team_voting", "0", "Restore previous round only possible if percentage of players in a team votes by typing .stop");
	gc_fStopVotingPercentage = AutoExecConfig_CreateConVar("sm_pug_rr_team_voting_percentage", "60", "Percentage of voting for a team for a succesful vote. [Dependency: sm_pug_rr_team_voting 1]");

	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();

	LoadTranslations("RestoreRound.phrases");
}

public void OnAllPluginsLoaded()
{
	g_Pug = LibraryExists("pugsetup");
}

public void OnLibraryAdded(const char[] name)
{
	if(strcmp(name, "pugsetup") == 0)
	{
		g_Pug = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(strcmp(name, "pugsetup") == 0)
	{
		g_Pug = false;
	}
}

public Action Event_UnpauseMatchCvar(int client, const char[] command, int argc)
{
	if(!(GameRules_GetProp("m_bMatchWaitingForResume") != 0))
	{
		return;
	}
	for(int i = 0; i < MaxClients; i++)
	{
		g_bStop[i] = false;
	}
	g_RepeatTimer = false;
	g_Restored = false;
	g_ctUnpaused = true;
	g_tUnpaused = true;
	g_CompletedStopVotes[2] = false;
	g_CompletedStopVotes[3] = false;
}

public Action Event_RoundStart(Event ev, const char[] name, bool dbc)
{
	g_RoundEnd = false;
	if(GameRules_GetProp("m_bWarmupPeriod") != 1)
	{
		if(g_RestoreRoundAtRoundStart)
		{
			RestoreRound(g_Round, g_Type);
			g_Round = -1;
			g_Type = -1;
			g_RestoreRoundAtRoundStart = false;
		}
		iRound++;
		#if defined DEBUG
		PrintToChatAll("[DEBUG] Round: %d", iRound);
		#endif
	}
	if(!(GameRules_GetProp("m_bMatchWaitingForResume") != 0))
	{
		return;
	}
	for(int client = 0; client < MaxClients; client++)
	{
		g_bStop[client] = false;
	}
	g_RepeatTimer = false;
	g_Restored = false;
	g_ctUnpaused = true;
	g_tUnpaused = true;
	g_CompletedStopVotes[2] = false;
	g_CompletedStopVotes[3] = false;
}

public Action Event_RoundEnd(Event ev, const char[] name, bool dbc)
{
	g_RoundEnd = true;
}

public Action Event_Changeteam(Event ev, const char[] name, bool dbc)
{
	int client = GetClientOfUserId(ev.GetInt("userid"));
	
	if(!client)
	{
		return;
	}
	
	g_bStop[client] = false;
}

public Action Event_TextMsgHook(UserMsg umId, Handle hMsg, const int[] iPlayers, int iPlayersNum, bool bReliable, bool bInit)
{
    //Thank you SM9(); for this!!

	char szName[40]; PbReadString(hMsg, "params", szName, sizeof(szName), 0);
	char szValue[40]; PbReadString(hMsg, "params", szValue, sizeof(szValue), 1);
    
	if (StrEqual(szName, "#SFUI_Notice_Game_will_restart_in", false)) 
	{
		CreateTimer(StringToFloat(szValue), Timer_GameRestarted);
	}
	return Plugin_Continue;
}

public Action Timer_GameRestarted(Handle hTimer)
{
	iRound = 1;
}

public void OnMapStart()
{
	gc_sChatTag.GetString(g_ssPrefix, sizeof(g_ssPrefix));

	FindConVar("mp_backup_round_file").GetString(g_BackupPrefix, sizeof(g_BackupPrefix));
	g_iBackupPrefixLen = strlen(g_BackupPrefix);
	FindConVar("mp_backup_round_file_pattern").GetString(g_BackupPrefixPattern, sizeof(g_BackupPrefixPattern));

	if(StrContains(g_BackupPrefixPattern, "round", false) == -1)
	{
		SetFailState("Using %round% is compulsory in \"mp_backup_round_file_pattern\" as plugin uses that as Primary key");
	}
	
	if(StrContains(g_BackupPrefixPattern, "%time%", false) != -1)
	{
		char sBuffer[10][32];
		int count;
		if(StrContains(g_BackupPrefixPattern, "_") != -1)
		{
			count = ExplodeString(g_BackupPrefixPattern, "_", sBuffer, 10, 32);
		}
		if(StrContains(g_BackupPrefixPattern, "-") != -1)
		{
			count = ExplodeString(g_BackupPrefixPattern, "_", sBuffer, 10, 32);
		}
		
		for(int i = 0; i < count; i++)
		{
			if(StrContains(sBuffer[i], "%time%", false) != -1)
			{
				g_iTime = i;
				break;
			}
		}
		
		FormatTime(g_sTime, sizeof(g_sTime), "%H%M%S");
	}

	ServerCommand("mp_backup_round_auto 1");

	for(int client = 0; client < MaxClients; client++)
	{
		g_bStop[client] = false;
	}
	g_RepeatTimer = false;
	g_Restored = false;
	g_ctUnpaused = true;
	g_tUnpaused = true;
	iRound = 0;
	g_CompletedStopVotes[2] = false;
	g_CompletedStopVotes[3] = false;
	g_RestoreRoundAtRoundStart = false;
	g_Round = -1;
	g_Type = -1;
	if(gc_bDeleteFile.BoolValue)
	{
		char filepath[PLATFORM_MAX_PATH];
		char num[5];
		for(int i = 0; i <= MAXROUNDS; i++)
		{
			Format(filepath, sizeof(filepath), "%s", g_BackupPrefixPattern);
			ReplaceString(filepath, sizeof(filepath), "%prefix%", g_BackupPrefix);
			if(i < 10)
			{
				Format(num, sizeof(num), "0%d", i);
				ReplaceString(filepath, sizeof(filepath), "%round%", num);
			}
			else
			{
				Format(num, sizeof(num), "%d", i);
				ReplaceString(filepath, sizeof(filepath), "%round%", num);
			}
			if(FileExists(filepath))
			{
				DeleteFile(filepath);
			}
		}
	}
}

public void OnClientPutInServer(int client)
{
	g_bStop[client] = false;
}

public void OnClientDisconnect(int client)
{
	OnClientPutInServer(client);
	if(!gc_bStopVoting.BoolValue)
	{
		return;
	}
	CheckStopProgress();
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if(!client)
	{
		return Plugin_Continue;
	}
	if(strcmp(command, "say") != 0 && strcmp(command, "say_team") != 0)
	{
		return Plugin_Continue;
	}
	if(sArgs[0] != '.')
	{
		return Plugin_Continue;
	}
	if(strcmp(sArgs, ".rest", false) == 0 || strcmp(sArgs, ".restore", false) == 0)
	{
		Command_Restore(client, 0);
	}
	if(strcmp(command, "say_team") == 0)
	{
		return Plugin_Continue;
	}
	if(GetClientTeam(client) != 2 && GetClientTeam(client) != 3)
	{
		return Plugin_Continue;
	}
	if(strcmp(sArgs, ".stop", false) == 0)
	{
		DoStopThings(client);
	}
	else if(strcmp(sArgs, ".unpause", false) == 0)
	{
		Command_Unpause(client, 0);
	}
	return Plugin_Continue;
}

public void DoStopThings(int client)
{
	if(GameRules_GetProp("m_bWarmupPeriod") == 1 || g_RoundEnd || (g_Pug && PugSetup_GetGameState() != GameState_Live))
	{
		if(client)
		{
			CPrintToChat(client, "%s %T", g_ssPrefix, "CannotUseRightNow", client);
		}
		return;
	}
	if(g_bStop[client])
	{
		if(client)
		{
			CPrintToChat(client, "%s %T", g_ssPrefix, "UsedCommand", client);
		}
		return;
	}
	if(!gc_bStopVoting.BoolValue)
	{
		if(TeamUsedStop(client))
		{
			CPrintToChat(client, "%s %T", g_ssPrefix, "TeamUsedCommand", client);
			return;
		}
		if(!UsedStop())
		{
			if(gc_bLostPlayerOnly.BoolValue && GetTeamPlayerCount(GetClientTeam(client)) == MAXTEAMPLAYERS)
			{
				CPrintToChat(client, "%s %T", g_ssPrefix, "NoDisconnect", client);
				return;
			}
			
			char teamname[64], oppteamname[64];
			if(GetClientTeam(client) == 2)
			{
				Format(teamname, sizeof(teamname), "%T", "T", client);
				Format(oppteamname, sizeof(oppteamname), "%T", "CT", client);
			}
			else if(GetClientTeam(client) == 3)
			{
				Format(teamname, sizeof(teamname), "%T", "CT", client);
				Format(oppteamname, sizeof(oppteamname), "%T", "T", client);
			}
			char sMessage[256];
			Format(sMessage, sizeof(sMessage), "%s %T", g_ssPrefix, "StopRequest", LANG_SERVER, teamname, oppteamname);
			CPrintToChatAll(sMessage);
			if(gc_fRepeat.FloatValue)
			{
				DataPack data = new DataPack();
				CreateDataTimer(gc_fRepeat.FloatValue, Timer_RepeatMSG, data, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
				data.WriteString(sMessage);
			}
			g_RepeatTimer = true;
			g_bStop[client] = true;
		}
		else
		{
			RestoreRound(iRound-1);
		}
	}
	else
	{
		CheckStopProgress(client);
	}
}

stock void CheckStopProgress(int client = 0)
{
	int team = GetClientTeam(client);
	int oppteam;
	if(team == 2)
	{
		oppteam = 3;
	}
	else if(team == 3)
	{
		oppteam = 2;
	}
	if(!UsedStop() && client)
	{
		if(gc_bLostPlayerOnly.BoolValue && GetTeamPlayerCount(team) == MAXTEAMPLAYERS)
		{
			CPrintToChat(client, "%s %T", g_ssPrefix, "NoDisconnect", client);
			return;
		}
	}
	if(g_CompletedStopVotes[team] || (GetTeamStopCount(team) == GetTotalTeamStopNeeded(team) && GetTeamStopCount(oppteam) != GetTotalTeamStopNeeded(oppteam)))
	{
		if(client)
		{
			CPrintToChat(client, "%s %T", g_ssPrefix, "WaitingForOpponent", client, GetTeamStopCount(oppteam), GetTotalTeamStopNeeded(oppteam));
		}
		return;
	}
	if(GetTeamStopCount(team) != GetTotalTeamStopNeeded(team) && GetTeamStopCount(oppteam) != GetTotalTeamStopNeeded(oppteam))
	{
		if(client)
		{
			CPrintToChat(client, "%s %T", g_ssPrefix, "LetOppFinish", client, GetTeamStopCount(oppteam), GetTotalTeamStopNeeded(oppteam));
		}
		return;
	}
	if(GetTeamStopVotesNeeded(team) > 0)
	{
		if(client)
		{
			g_bStop[client] = true;
			char teamname[64];
			if(team == 2)
			{
				Format(teamname, sizeof(teamname), "%T", "T", LANG_SERVER);
			}
			else if(team == 3)
			{
				Format(teamname, sizeof(teamname), "%T", "CT", LANG_SERVER);
			}
			CPrintToChatAll("%s %T", g_ssPrefix, "StopVotes", LANG_SERVER, client, teamname, teamname, GetTeamStopCount(team), GetTotalTeamStopNeeded(team));
		}
	}
	else
	{
		if(g_CompletedStopVotes[oppteam])
		{
			RestoreRound(iRound-1);
			return;
		}
		for(int i = 0; i < MaxClients; i++)
		{
			g_bStop[i] = false;
		}
		g_CompletedStopVotes[team] = true;
		char teamname[64], oppteamname[64];
		if(team == 2)
		{
			Format(teamname, sizeof(teamname), "%T", "T", LANG_SERVER);
			Format(oppteamname, sizeof(oppteamname), "%T", "CT", LANG_SERVER);
		}
		else if(team == 3)
		{
			Format(teamname, sizeof(teamname), "%T", "CT", LANG_SERVER);
			Format(oppteamname, sizeof(oppteamname), "%T", "T", LANG_SERVER);
		}
		CPrintToChatAll("%s %T", g_ssPrefix, "WaitingForOpponentAll", LANG_SERVER, teamname, oppteamname);
	}
}

public Action Timer_RepeatMSG(Handle tmr, DataPack pack)
{
	if(!g_RepeatTimer)
	{
		return Plugin_Stop;
	}
	pack.Reset();
	char sMessage[256];
	pack.ReadString(sMessage, sizeof(sMessage));
	CPrintToChatAll(sMessage);
	return Plugin_Continue;
}

stock void RestoreRound(int round, int type = 0, int client = 0)
{
	if(g_RoundEnd || (g_Pug && PugSetup_GetGameState() != GameState_Live))
	{
		char sMessage[256];
		Format(sMessage, sizeof(sMessage), "%s %T", g_ssPrefix, "RoundRestoredAtRoundStart", LANG_SERVER);
		CPrintToChatAll(sMessage);
		g_RestoreRoundAtRoundStart = true;
		g_Round = round;
		g_Type = type;
		return;
	}
	if(round == -1 || type == -1)
	{
		return;
	}
	if(GameRules_GetProp("m_bMatchWaitingForResume") != 0)
	{
		if(client)
		{
			char sMessage[256];
			Format(sMessage, sizeof(sMessage), "%s %T", g_ssPrefix, "UnpauseFirst", client);
			CPrintToChat(client, sMessage);
		}
		return;
	}
	char filepath[PLATFORM_MAX_PATH], filepath2[PLATFORM_MAX_PATH], RoundName[10][PLATFORM_MAX_PATH], num[5];
	Handle folder = OpenDirectory("/");
	char map[64];
	GetCurrentMap(map, sizeof(map));
	IntToString(round, num, sizeof(num));
	char sDate[32];
	FormatTime(sDate, sizeof(sDate), "%Y%m%d");
	
	int count=0;
	
	g_RepeatTimer = false;
	for(int i = 0; i < MaxClients; i++)
	{
		g_bStop[i] = false;
	}

	if(type == 1)
	{
		iRound = round;
	}
	else
	{
		iRound -= 1;
	}

	while(ReadDirEntry(folder, filepath, sizeof(filepath)))
	{
		if(StrContains(filepath, ".txt", false) == -1)
		{
			continue;
		}
		if(StrContains(filepath, "round", false) == -1)
		{
			continue;
		}
		if(StrContains(g_BackupPrefixPattern, "%map%", false) != -1 && StrContains(filepath, map) == -1)
		{
			continue;
		}
		if(StrContains(g_BackupPrefixPattern, "%date%", false) != -1 && StrContains(filepath, sDate) == -1)
		{
			continue;
		}
		if(StrContains(g_BackupPrefixPattern, "%time%", false) != -1)
		{
			char sBuffer[10][32];
			
			if(StrContains(filepath[g_iBackupPrefixLen], "_") != -1)
			{
				ExplodeString(filepath[g_iBackupPrefixLen], "_", sBuffer, 10, 32);
			}
			if(StrContains(filepath[g_iBackupPrefixLen], "-") != -1)
			{
				ExplodeString(filepath[g_iBackupPrefixLen], "_", sBuffer, 10, 32);
			}
			if(StringToInt(sBuffer[g_iTime]) < StringToInt(g_sTime))
			{
				continue;
			}
		}
		
		strcopy(filepath2, sizeof(filepath2), filepath[g_iBackupPrefixLen]);
		int start = StrContains(filepath2, "round", false);
		if(filepath2[start+5] == '_' && IsCharNumeric(filepath2[start+6]))
		{
			if(round < 10)
			{
				if(filepath2[start+6] == '0' && filepath2[start+7] == num[0])
				{
					strcopy(RoundName[count], PLATFORM_MAX_PATH, filepath);
					#if defined DEBUG
					LogMessage("Filepath %s | Filepath %s", RoundName[count], filepath);
					#endif
				}
			}
			else if(round >= 10 && round < 99)
			{
				if(filepath2[start+6] == num[0] && filepath2[start+7] == num[1])
				{
					strcopy(RoundName[count], PLATFORM_MAX_PATH, filepath);
					#if defined DEBUG
					LogMessage("Filepath %s | Filepath %s", RoundName[count], filepath);
					#endif
				}
			}
			else
			{
				if(filepath2[start+6] == num[0] && filepath2[start+7] == num[1] && filepath2[start+8] == num[2])
				{
					strcopy(RoundName[count], PLATFORM_MAX_PATH, filepath);
					#if defined DEBUG
					LogMessage("Filepath %s | Filepath %s", RoundName[count], filepath);
					#endif
				}
			}
			count++;
		}
		else if(IsCharNumeric(filepath2[start+5]))
		{
			if(round < 10)
			{
				if(filepath2[start+5] == '0' && filepath2[start+6] == num[0])
				{
					strcopy(RoundName[count], PLATFORM_MAX_PATH, filepath);
					#if defined DEBUG
					LogMessage("Filepath %s | Filepath %s", RoundName[count], filepath);
					#endif
				}
			}
			else if(round >= 10 && round < 99)
			{
				if(filepath2[start+5] == num[0] && filepath2[start+6] == num[1])
				{
					strcopy(RoundName[count], PLATFORM_MAX_PATH, filepath);
					#if defined DEBUG
					LogMessage("Filepath %s | Filepath %s", RoundName[count], filepath);
					#endif
				}
			}
			else
			{
				if(filepath2[start+5] == num[0] && filepath2[start+6] == num[1] && filepath2[start+7] == num[2])
				{
					strcopy(RoundName[count], PLATFORM_MAX_PATH, filepath);
					#if defined DEBUG
					LogMessage("Filepath %s | Filepath %s", RoundName[count], filepath);
					#endif
				}
			}
			count++;
		}
		else
		{
			LogError("lol what");
		}
	}
	delete folder;
	
	if(RoundName[1][0]) //Should only happen when using %time%
	{
		char sBuffer[10][32];
		char high[PLATFORM_MAX_PATH];
		strcopy(high, sizeof(high), RoundName[0]);
		for(int i = 0; i < sizeof(RoundName); i++)
		{
			if(StrContains(RoundName[i][g_iBackupPrefixLen], "_") != -1)
			{
				ExplodeString(RoundName[i][g_iBackupPrefixLen], "_", sBuffer, 10, 32);
			}
			if(StrContains(RoundName[i][g_iBackupPrefixLen], "-") != -1)
			{
				ExplodeString(RoundName[i][g_iBackupPrefixLen], "_", sBuffer, 10, 32);
			}
			#if defined DEBUG
			LogMessage("New Loop: %s", RoundName[i][g_iBackupPrefixLen]);
			#endif
			if(StringToInt(sBuffer[g_iTime]) > StringToInt(high))
			{
				strcopy(high, sizeof(high), RoundName[i]);
			}
		}
		strcopy(RoundName[0], PLATFORM_MAX_PATH, high);
	}
	
	if(RoundName[0][0] == '\0')
	{
		for(int i = 0; i < sizeof(RoundName); i++)
		{
			if(RoundName[i][0]=='\0')
			{
				continue;
			}
			if(!FileExists(RoundName[i]))
			{
				continue;
			}
			strcopy(RoundName[0], PLATFORM_MAX_PATH, RoundName[i]);
			break;
		}
	}
	
	//ServerCommand("mp_pause_match");
	ServerCommand("sm_rcon mp_backup_round_auto 0");
	ServerCommand("mp_backup_restore_load_file %s", RoundName[0]);

	#if defined DEBUG
	PrintToChatAll("[DEBUG] File: %s", RoundName[0]);
	#endif
	CPrintToChatAll("%s %T", g_ssPrefix, "RoundRestored", LANG_SERVER);

	char sMessage[256];
	Format(sMessage, sizeof(sMessage), "%s %T", g_ssPrefix, "UnpauseInst", LANG_SERVER);
	CPrintToChatAll(sMessage);

	if(gc_fRepeat.FloatValue)
	{
		DataPack data = new DataPack();
		CreateDataTimer(gc_fRepeat.FloatValue, Timer_RepeatMSG2, data, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
		data.WriteString(sMessage);
	}
	DataPack data = new DataPack();
	CreateDataTimer(1.0, Timer_Delay, data, TIMER_FLAG_NO_MAPCHANGE);
	data.WriteCell(round);
	data.WriteString(RoundName[0]);
}

public Action Timer_Delay(Handle tmr, DataPack data)
{
	data.Reset();
	char RoundName[PLATFORM_MAX_PATH];
	int round = data.ReadCell();
	data.ReadString(RoundName, sizeof(RoundName));
	
	if(round > 0)
	{
		ServerCommand("sm_rcon mp_backup_round_file_last \"%s\"", RoundName);
	}
	else
	{
		ServerCommand("sm_rcon mp_backup_round_file_last \"\"");
	}
	
	ServerCommand("sm_rcon mp_backup_round_auto 1");
	
	g_Restored = true;
	g_ctUnpaused = false;
	g_tUnpaused = false;
	g_CompletedStopVotes[2] = false;
	g_CompletedStopVotes[3] = false;
	/*
	char num[5], num2[5];
	IntToString(round, num, sizeof(num));
	IntToString(round+1, num2, sizeof(num2));
	char PrevRound[PLATFORM_MAX_PATH];
	strcopy(PrevRound, sizeof(PrevRound), RoundName);
		char tmp[PLATFORM_MAX_PATH];
		strcopy(tmp, sizeof(tmp), PrevRound[g_iBackupPrefixLen]);
		int start = StrContains(tmp, "round", false);
		#if defined DEBUG
		PrintToChatAll("[DEBUG] PreviousRound: %s | PreviousRound without backup: %s | Start: %d | 5: %c | 6: %c | 7: %c | 8: %c", PrevRound, PrevRound[g_iBackupPrefixLen], g_iBackupPrefixLen+start, PrevRound[g_iBackupPrefixLen+start+5], PrevRound[g_iBackupPrefixLen+start+6], PrevRound[g_iBackupPrefixLen+start+7], PrevRound[g_iBackupPrefixLen+start+8]);
		#endif
		if(PrevRound[g_iBackupPrefixLen+start+5] == '_' && IsCharNumeric(PrevRound[g_iBackupPrefixLen+start+6]))
		{
			if(round < 10)
			{
				if(round == 9)
				{
					if(PrevRound[g_iBackupPrefixLen+start+6] == '0' && PrevRound[g_iBackupPrefixLen+start+7] == num[0])
					{
						PrevRound[g_iBackupPrefixLen+start+6] = num2[0];
						PrevRound[g_iBackupPrefixLen+start+7] = num2[1];
					}
				}
				else
				{
					if(PrevRound[g_iBackupPrefixLen+start+6] == '0' && PrevRound[g_iBackupPrefixLen+start+7] == num[0])
					{
						PrevRound[g_iBackupPrefixLen+start+7] = num2[0];
					}
				}
			}
			else if(round >= 10 && round < 99)
			{
				if(PrevRound[g_iBackupPrefixLen+start+6] == num[0] && PrevRound[g_iBackupPrefixLen+start+7] == num[1])
				{
					PrevRound[g_iBackupPrefixLen+start+6] = num2[0];
					PrevRound[g_iBackupPrefixLen+start+7] = num2[1];
				}
			}
			else
			{
				if(PrevRound[g_iBackupPrefixLen+start+6] == num[0] && PrevRound[g_iBackupPrefixLen+start+7] == num[1] && PrevRound[g_iBackupPrefixLen+start+8] == num[2])
				{
					PrevRound[g_iBackupPrefixLen+start+6] = num2[0];
					PrevRound[g_iBackupPrefixLen+start+7] = num2[1];
					PrevRound[g_iBackupPrefixLen+start+8] = num2[2];
				}
			}
		}
		else if(IsCharNumeric(PrevRound[g_iBackupPrefixLen+start+5]))
		{
			if(round < 10)
			{
				if(round == 9)
				{
					if(PrevRound[g_iBackupPrefixLen+start+5] == '0' && PrevRound[g_iBackupPrefixLen+start+6] == num[0])
					{
						PrevRound[g_iBackupPrefixLen+start+5] = num2[0];
						PrevRound[g_iBackupPrefixLen+start+6] = num2[1];
					}
				}
				else
				{
					if(PrevRound[g_iBackupPrefixLen+start+5] == '0' && PrevRound[g_iBackupPrefixLen+start+6] == num[0])
					{
						PrevRound[g_iBackupPrefixLen+start+6] = num2[0];
					}
				}
			}
			else if(round >= 10 && round < 99)
			{
				if(PrevRound[g_iBackupPrefixLen+start+5] == num[0] && PrevRound[g_iBackupPrefixLen+start+6] == num[1])
				{
					PrevRound[g_iBackupPrefixLen+start+5] = num2[0];
					PrevRound[g_iBackupPrefixLen+start+6] = num2[1];
				}
			}
			else
			{
				PrevRound[g_iBackupPrefixLen+start+5] = num2[0];
				PrevRound[g_iBackupPrefixLen+start+6] = num2[1];
				PrevRound[g_iBackupPrefixLen+start+6] = num2[2];
			}
		}
		ServerCommand("sm_rcon mp_backup_round_file_last \"%s\"", PrevRound);
		#if defined DEBUG
		PrintToChatAll("[DEBUG] mp_backup_round_file_last \"%s\"", PrevRound);
		#endif
	*/
}

public Action Timer_RepeatMSG2(Handle tmr, DataPack pack)
{
	if(g_ctUnpaused || g_tUnpaused)
	{
		return Plugin_Stop;
	}
	char sMessage[256];

	pack.Reset();
	pack.ReadString(sMessage, sizeof(sMessage));
	CPrintToChatAll(sMessage);
	return Plugin_Continue;
}

public Action Command_Restore(int client, int args)
{
	if(!client)
	{
		return Plugin_Handled;
	}
	if(g_RoundEnd || (g_Pug && PugSetup_GetGameState() != GameState_Live))
	{
		CPrintToChat(client, "%s %T", g_ssPrefix, "CannotUseRightNow", client);
		return Plugin_Handled;
	}
	RestoreMenu(client);
	return Plugin_Handled;
}

public void RestoreMenu(int client)
{
	char filepath[PLATFORM_MAX_PATH], filepath2[PLATFORM_MAX_PATH], display[MAXROUNDS+1][16], curr[16], num[MAXROUNDS+1][5];
	Handle folder = OpenDirectory("/");
	char map[64];
	GetCurrentMap(map, sizeof(map));
	char sDate[32];
	FormatTime(sDate, sizeof(sDate), "%Y%m%d");
	int i=0;
	
	Menu menu = new Menu(Handle_RestoreMenu);
	menu.SetTitle("Round to restore:");
	while(ReadDirEntry(folder, filepath, sizeof(filepath)))
	{
		if(StrContains(filepath, ".txt", false) == -1)
		{
			continue;
		}
		if(StrContains(filepath, "round", false) == -1)
		{
			continue;
		}
		if(StrContains(g_BackupPrefixPattern, "%map%", false) != -1 && StrContains(filepath, map) == -1)
		{
			continue;
		}
		if(StrContains(g_BackupPrefixPattern, "%date%", false) != -1 && StrContains(filepath, sDate) == -1)
		{
			continue;
		}
		if(StrContains(g_BackupPrefixPattern, "%time%", false) != -1)
		{
			char sBuffer[10][32];
			
			if(StrContains(filepath[g_iBackupPrefixLen], "_") != -1)
			{
				ExplodeString(filepath[g_iBackupPrefixLen], "_", sBuffer, 10, 32);
			}
			if(StrContains(filepath[g_iBackupPrefixLen], "-") != -1)
			{
				ExplodeString(filepath[g_iBackupPrefixLen], "_", sBuffer, 10, 32);
			}
			if(StringToInt(sBuffer[g_iTime]) < StringToInt(g_sTime))
			{
				continue;
			}
		}
		strcopy(filepath2, sizeof(filepath2), filepath[g_iBackupPrefixLen]);
		int start = StrContains(filepath2, "round", false);
		#if defined DEBUG
		LogMessage("Filepath %s | BackupPrefixLen: %d | Start: %d | %c%c%c%c", filepath2, g_iBackupPrefixLen, start, filepath2[start+5], filepath2[start+6], filepath2[start+7], filepath2[start+8]);
		#endif
		if(filepath2[start+5] == '_' && IsCharNumeric(filepath2[start+6]))
		{
			if(filepath2[start+6] == '0')
			{
				Format(num[i], 5, "%c", filepath2[start+7]);
			}
			else
			{
				if(IsCharNumeric(filepath[start+8]))
				{
					Format(num[i], 5, "%c%c%c", filepath2[start+6], filepath2[start+7], filepath2[start+8]);
				}
				else
				{
					Format(num[i], 5, "%c%c", filepath2[start+6], filepath2[start+7]);
				}
			}
			Format(curr, sizeof(curr), "%T", "CurrentShort", client);
			Format(display[i++], 16, "%T %d%s", "Round", client, StringToInt(num[i])+1, StringToInt(num[i])+1 == iRound ? curr:"");
		}
		else if(IsCharNumeric(filepath2[start+5]))
		{
			if(filepath2[start+5] == '0')
			{
				Format(num[i], 5, "%c", filepath2[start+6]);
			}
			else
			{
				if(IsCharNumeric(filepath2[start+7]))
				{
					Format(num[i], 5, "%c%c%c", filepath2[start+5], filepath2[start+6], filepath2[start+7]);
				}
				else
				{
					Format(num[i], 5, "%c%c", filepath2[start+5], filepath2[start+6]);
				}
			}
			Format(curr, sizeof(curr), "%T", "CurrentShort", client);
			Format(display[i++], 16, "%T %d%s", "Round", client, StringToInt(num[i])+1, StringToInt(num[i])+1 == iRound ? curr:"");
		}
		else
		{
			LogError("lol what");
			continue;
		}
	}
	delete folder;
	
	for(int x = 0, y = 0; x < sizeof(display); x++, y++)
	{
		if(y+1 >= sizeof(display) || x+1 >= sizeof(display))
		{
			break;
		}
		if(strcmp(display[y], display[y+1]) != 0)
		{
			menu.AddItem(num[x], display[x]);
			continue;
		}
		x-=2;
	}
	
	
	menu.ExitButton = true;
	if(menu.ItemCount < 1)
	{
		CPrintToChat(client, "%s %T", g_ssPrefix, "NoBackupRounds", client);
	}
	else
	{
		menu.Display(client, 30);
	}
}

public int Handle_RestoreMenu(Menu menu, MenuAction action, int client, int item)
{
	switch(action)
	{
		case MenuAction_End:
		{
			delete menu;
		}
		case MenuAction_Select:
		{
			char info[32];
			menu.GetItem(item, info, sizeof(info));
			RestoreRound(StringToInt(info), 1, client);
			#if defined DEBUG
			LogMessage("%N selected %s", client, info);
			#endif
		}
	}
}

public Action Command_DeleteAllRounds(int client, int args)
{
	char filepath[PLATFORM_MAX_PATH];
	Handle folder = OpenDirectory("/");
	char map[64];
	GetCurrentMap(map, sizeof(map));
	char sDate[32];
	FormatTime(sDate, sizeof(sDate), "%Y%m%d");
	while(ReadDirEntry(folder, filepath, sizeof(filepath)))
	{
		if(StrContains(filepath, ".txt", false) == -1)
		{
			continue;
		}
		if(StrContains(filepath, "round", false) == -1)
		{
			continue;
		}
		if(StrContains(g_BackupPrefixPattern, "%map%", false) != -1 && StrContains(filepath, map) == -1)
		{
			continue;
		}
		if(StrContains(g_BackupPrefixPattern, "%date%", false) != -1 && StrContains(filepath, sDate) == -1)
		{
			continue;
		}
		if(StrContains(g_BackupPrefixPattern, "%time%", false) != -1)
		{
			char sBuffer[10][32];
			
			if(StrContains(filepath[g_iBackupPrefixLen], "_") != -1)
			{
				ExplodeString(filepath[g_iBackupPrefixLen], "_", sBuffer, 10, 32);
			}
			if(StrContains(filepath[g_iBackupPrefixLen], "-") != -1)
			{
				ExplodeString(filepath[g_iBackupPrefixLen], "_", sBuffer, 10, 32);
			}
			if(StringToInt(sBuffer[g_iTime]) < StringToInt(g_sTime))
			{
				#if defined DEBUG
				LogMessage("Filename: %s | sBuffer: %s | g_iTime: %d | g_sTime: %s", filepath, sBuffer[g_iTime], g_iTime, g_sTime);
				LogMessage("OldFile: %s", filepath);
				#endif
				continue;
			}
		}
		#if defined DEBUG
		LogMessage("NewFile: %s", filepath);
		#endif
		//DeleteFile(filepath);
	}
	delete folder;

	if(client)
	{
		CPrintToChat(client, "%s %T", g_ssPrefix, "DeletedBackup", client);
	}
	else
	{
		PrintToServer("%s %T", g_ssPrefix, "DeletedBackup", LANG_SERVER);
	}
	return Plugin_Handled;
}

public Action Command_Unpause(int client, int args)
{
	if (!(GameRules_GetProp("m_bMatchWaitingForResume") != 0) || !client || !g_Restored)
	{
		#if defined DEBUG
		LogMessage("Restored: %d | TUnpaused: %d | CTUnpaused: %d", g_Restored, g_tUnpaused, g_ctUnpaused);
		#endif
		return Plugin_Handled;
	}

	int team = GetClientTeam(client);
	
	if(team == 2 && g_tUnpaused || team == 3 && g_ctUnpaused )
	{
		CPrintToChat(client, "%s %T", g_ssPrefix, "TeamUsedCommand");
		return Plugin_Handled;
	}
	
	if (team == 2)
	{
		g_tUnpaused = true;
	}
	else if (team == 3)
	{
		g_ctUnpaused = true;
	}
	LogMessage("%L requested a unpause", client);

	if (g_tUnpaused && g_ctUnpaused)
	{
		ServerCommand("mp_unpause_match");
		LogMessage("Unpausing the game", client);
		g_Restored = false;
	}
	else if (g_tUnpaused && !g_ctUnpaused)
	{
		char sMessage[256];
		Format(sMessage, sizeof(sMessage), "%s %T", g_ssPrefix, "TUnpause", LANG_SERVER);
		CPrintToChatAll(sMessage);
		DataPack data = new DataPack();
		CreateDataTimer(gc_fRepeat.FloatValue, Timer_RepeatMSG3, data, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
		data.WriteString(sMessage);
	}
	else if (!g_tUnpaused && g_ctUnpaused)
	{
		char sMessage[256];
		Format(sMessage, sizeof(sMessage), "%s %T", g_ssPrefix, "CTUnpause", LANG_SERVER);
		CPrintToChatAll(sMessage);
		DataPack data = new DataPack();
		CreateDataTimer(gc_fRepeat.FloatValue, Timer_RepeatMSG3, data, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
		data.WriteString(sMessage);
	}
	return Plugin_Handled;
}

public Action Timer_RepeatMSG3(Handle tmr, DataPack pack)
{
	if(!g_Restored)
	{
		return Plugin_Stop;
	}
	char sMessage[256];

	pack.Reset();
	pack.ReadString(sMessage, sizeof(sMessage));
	CPrintToChatAll(sMessage);
	return Plugin_Continue;
}

stock int GetTeamStopVotesNeeded(int team)
{
	int total;
	int count;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i) && GetClientTeam(i) == team)
		{
			total++;
			if(g_bStop[i])
			{
				count++;
			}
		}
	}
	
	int Needed = RoundToFloor(total*(gc_fStopVotingPercentage.FloatValue / 100));

	if(Needed < 1)
	{
		Needed = 1;
	}
	
	return Needed - count;
}

stock int GetTeamStopCount(int team)
{
	int count;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i) && GetClientTeam(i) == team)
		{
			if(g_bStop[i])
			{
				count++;
			}
		}
	}
	return count;
}

stock int GetTotalTeamStopNeeded(int team)
{
	int total;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i) && GetClientTeam(i) == team)
		{
			total++;
		}
	}
	
	int Needed = RoundToFloor(total*(gc_fStopVotingPercentage.FloatValue / 100));
	
	if(Needed < 1)
	{
		Needed = 1;
	}
	return Needed;
}

stock int GetTeamPlayerCount(int team)
{
	int count;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsClientSourceTV(i) && !IsFakeClient(i) && GetClientTeam(i) == team)
		{
			count++;
		}
	}
	return count;
}

stock bool TeamUsedStop(int client)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == GetClientTeam(client) && g_bStop[i])
		{
			return true;
		}
	}
	return false;
}

stock bool UsedStop()
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && g_bStop[i])
		{
			return true;
		}
	}
	return false;
}
