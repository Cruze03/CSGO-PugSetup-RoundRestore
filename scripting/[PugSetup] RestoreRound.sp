#include <sourcemod>
#include <sdktools>
#include <multicolors>
#include <autoexecconfig>

#pragma semicolon 1
#pragma newdecls required

int iRound = 0;
bool g_bStop[MAXPLAYERS+1];
bool g_RepeatTimer = false;
bool g_Restored = false;

bool g_ctUnpaused = false;
bool g_tUnpaused = false;

ConVar gc_sChatTag, gc_fRepeat, gc_bDeleteFile;

char g_ssPrefix[128];

public Plugin myinfo =
{
    name = "[PugSetup] RestoreRound",
    author = "Cruze",
    description = "Player can type .stop command to restore last round. Admins can type .res to restore any round.",
    version = "1.1",
    url = "http://steamcommunity.com/profiles/76561198132924835"
};

public void OnPluginStart()
{
	HookEvent("round_start", Event_RoundStart);
	HookEvent("player_team", Event_Changeteam);
	HookUserMessage(GetUserMessageId("TextMsg"), Event_TextMsgHook);
	
	RegConsoleCmd("sm_unpause", Command_Unpause, "Requests an unpause");
	RegAdminCmd("sm_restoreround", Command_Restore, ADMFLAG_GENERIC, "Restores last rounds.");
	RegAdminCmd("sm_deleteallbackuprounds", Command_DeleteAllRounds, ADMFLAG_ROOT, "Deletes all backup rounds.");
	
	ServerCommand("mp_backup_restore_load_autopause 0");
	ServerCommand("mp_backup_round_auto 1");
	
	
	AutoExecConfig_SetFile("PugRestoreRound");
	AutoExecConfig_SetCreateFile(true);
	
	gc_sChatTag = AutoExecConfig_CreateConVar("sm_pug_rr_chattag", "[{lightgreen}PUG{default}]", "Chat tag for chat prints");
	gc_fRepeat = AutoExecConfig_CreateConVar("sm_pug_rr_repeat", "5.0", "Repeat message of \"round restore\" and \"unpause to resume match\" every x seconds. 0.0 to disable repeat.");
	gc_bDeleteFile = AutoExecConfig_CreateConVar("sm_pug_rr_delete_file", "0", "Delete backup files every map start/reload? WARNING: If enabled, you can loose backup files when server crashed. It's recommended to use sm_deleteallbackuprounds.");
	
	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
	
	LoadTranslations("PugRestoreRound.phrases");
}

public Action Event_RoundStart(Event ev, const char[] name, bool dbc)
{
	if(GameRules_GetProp("m_bWarmupPeriod") != 1)
	{
		iRound++;
		for(int client = 0; client < MaxClients; client++)
		{
			g_bStop[client] = false;
		}
		g_RepeatTimer = false;
	}
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
	
	ServerCommand("mp_backup_restore_load_autopause 0");
	ServerCommand("mp_backup_round_auto 1");
	g_ctUnpaused = false;
	g_tUnpaused = false;
	g_Restored = false;
	g_RepeatTimer = false;
	iRound = 0;
	for(int client = 0; client < MaxClients; client++)
	{
		g_bStop[client] = false;
	}
	if(gc_bDeleteFile.BoolValue)
	{
		char filepath[PLATFORM_MAX_PATH];
		for(int i = 1; i <= 30; i++)
		{
			if(i < 10)
			{
				Format(filepath, sizeof(filepath), "backup_round0%d.txt", i);
			}
			else
			{
				Format(filepath, sizeof(filepath), "backup_round%d.txt", i);
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
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if(!client)
	{
		return Plugin_Continue;
	}
	if(strcmp(command, "say") != 0)
	{
		return Plugin_Continue;
	}
	if(sArgs[0] != '.')
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
	else if(strcmp(sArgs, ".rest", false) == 0 || strcmp(sArgs, ".restore", false) == 0)
	{
		Command_Restore(client, 0);
	}
	return Plugin_Continue;
}

public void DoStopThings(int client)
{
	if(GameRules_GetProp("m_bWarmupPeriod") == 1)
	{
		CPrintToChat(client, "%s %T", g_ssPrefix, "CannotUseRightNow", client);
		return;
	}
	if(g_bStop[client])
	{
		CPrintToChat(client, "%s %T", g_ssPrefix, "UsedCommand", client);
		return;
	}
	if(TeamUsedStop(client))
	{
		CPrintToChat(client, "%s %T", g_ssPrefix, "TeamUsedCommand", client);
		return;
	}
	if(!UsedStop())
	{
		char teamname[32], oppteamname[32];
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
			CreateDataTimer(7.0, Timer_RepeatMSG, data, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
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

public void RestoreRound(int round)
{
	g_RepeatTimer = false;
	for(int i = 0; i < MaxClients; i++)
	{
		g_bStop[i] = false;
	}
	iRound = round;

	char roundName[64];
	char prefix1[16] = "backup_round0";
	char prefix2[16] = "backup_round";
	char end[8] = ".txt";

	if(round < 10)
	{
		Format(roundName, sizeof(roundName), "%s%d%s", prefix1, round, end);
	}
	else
	{
		Format(roundName, sizeof(roundName), "%s%d%s", prefix2, round, end);
	}

	ServerCommand("mp_backup_restore_load_file %s", roundName);
	ServerCommand("mp_pause_match");
	CPrintToChatAll("%s %T", g_ssPrefix, "RoundRestored", LANG_SERVER);

	char sMessage[128];
	Format(sMessage, sizeof(sMessage), "%s %T", g_ssPrefix, "UnpauseInst", LANG_SERVER);
	CPrintToChatAll(sMessage);

	if(gc_fRepeat.FloatValue)
	{
		DataPack data = new DataPack();
		CreateDataTimer(5.0, Timer_RepeatMSG2, data, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
		data.WriteString(sMessage);
	}

	g_Restored = true;
	g_ctUnpaused = false;
	g_tUnpaused = false;
}

public Action Timer_RepeatMSG2(Handle tmr, DataPack pack)
{
	if(!(GameRules_GetProp("m_bMatchWaitingForResume") != 0))
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
	RestoreMenu(client);
	return Plugin_Handled;
}

public void RestoreMenu(int client)
{
	char info[5], display[16], curr[16], filepath[PLATFORM_MAX_PATH];
	Menu menu = new Menu(Handle_RestoreMenu);
	menu.SetTitle("Round to restore:");
	for(int i = 1; i <= 30; i++)
	{
		if(i < 10)
		{
			Format(filepath, sizeof(filepath), "backup_round0%d.txt", i);
		}
		else
		{
			Format(filepath, sizeof(filepath), "backup_round%d.txt", i);
		}
		if(!FileExists(filepath))
		{
			continue;
		}
		IntToString(i, info, sizeof(info));
		Format(curr, sizeof(curr), "%T", "CurrentShort", client);
		Format(display, sizeof(display), "%T %d%s", "Round", client, i, i == iRound ? curr:"");
		menu.AddItem(info, display);
	}
	menu.ExitButton = true;
	if(menu.ItemCount < 1)
	{
		CPrintToChat(client, "%s %T", "NoBackupRounds", client);
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
			RestoreRound(StringToInt(info)-1);
		}
	}
}

public Action Command_DeleteAllRounds(int client, int args)
{
	char filepath[PLATFORM_MAX_PATH];
	for(int i = 1; i <= 30; i++)
	{
		if(i < 10)
		{
			Format(filepath, sizeof(filepath), "backup_round0%d.txt", i);
		}
		else
		{
			Format(filepath, sizeof(filepath), "backup_round%d.txt", i);
		}
		if(FileExists(filepath))
		{
			DeleteFile(filepath);
		}
	}
	CPrintToChat(client, "%s %T", g_ssPrefix, "DeletedBackup", client);
	return Plugin_Handled;
}

public Action Command_Unpause(int client, int args)
{
	if (!(GameRules_GetProp("m_bMatchWaitingForResume") != 0) || !client || !g_Restored)
	{
		return Plugin_Handled;
	}

	int team = GetClientTeam(client);
	
	if(team == 2 && g_tUnpaused || team == 3 && g_ctUnpaused )
	{
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
		CPrintToChatAll("%s %T", g_ssPrefix, "TUnpause", LANG_SERVER);
	}
	else if (!g_tUnpaused && g_ctUnpaused)
	{
		CPrintToChatAll("%s %T", g_ssPrefix, "CTUnpause", LANG_SERVER);
	}
	return Plugin_Handled;
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