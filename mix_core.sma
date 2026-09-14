#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <fakemeta>
#include <hamsandwich>
#include <json>

#include <common>

#include "accsys/servercore"
#include "accsys/accounts"
#include "accsys/hierarchy"

/* =================================================================================
* 				[ Defines ]
* ================================================================================= */

#define MAX_PLAYERS				32
#define MAX_SUPPORTED_TEAM_SIZE	5
#define MAX_MIX_PLAYERS			( MAX_SUPPORTED_TEAM_SIZE * 2 )

/* =================================================================================
* 				[ CVars Enum ]
* ================================================================================= */

enum _:CVARS
{
    Float:CVAR_LIVE_COUNTDOWN_TIME,
    Float:CVAR_RECONNECT_TIME,
    Float:CVAR_PAUSE_DURATION,

    CVAR_ROUNDS_PER_HALF,
    CVAR_ROUNDS_OVERTIME,
    CVAR_FREEZETIME,
    CVAR_HALFTIME_BREAK,
    CVAR_OVERTIME_START_MONEY,
    CVAR_MAX_PAUSES_PER_TEAM,
    CVAR_MAX_RECONNECTS_PER_PLAYER
};

/* =================================================================================
* 				[ Enumerations ]
* ================================================================================= */

enum _:TASKS
{
    TASK_LIVE_COUNTDOWN		= 4000,
    TASK_WARMUP_RESPAWN		= 6000,
    TASK_WARMUP_START		= 6500,
    TASK_SIDE_COUNTDOWN		= 7000,
    TASK_SHOW_SIDE_MENU		= 7500,
    TASK_PAUSE_COUNTDOWN	= 8000,
    TASK_RECONNECT_TIMEOUT	= 9000,
    TASK_START_KNIFE		= 11000,
    TASK_WAIT_TEAM_ELO		= 12000,
    TASK_CHECK_FILL			= 15000,
    TASK_RESET_PHASE_FLAG	= 16000,
    TASK_SHOW_WELCOME		= 17000,
    TASK_MATCH_RESET			= 18000,
    TASK_APPLY_PAUSE		= 19000,
    TASK_SURRENDER_COUNTDOWN	= 21000,
    TASK_PHASE_BREAK			= 22000,
    TASK_SHOW_ROUND_DAMAGE	= 23000,
};

enum _:MIX_STATUS
{
    MIX_IDLE,
    MIX_PREPARING,
    MIX_KNIFE_ROUND,
    MIX_HALFTIME,
    MIX_LIVE,
    MIX_OVERTIME,
    MIX_PAUSED,
    MIX_FINISHED
};

enum _:MIX_TEAM
{
    MIX_TEAM_NONE = 0,
    MIX_TEAM_A,
    MIX_TEAM_B
};

enum _:PHASE_TRANSITION
{
    PHASE_TRANSITION_NONE,
    PHASE_TRANSITION_REGULATION_HALF,
    PHASE_TRANSITION_OVERTIME_START,
    PHASE_TRANSITION_OVERTIME_HALF
};

enum _:Player_Struct
{
    Player_AccId,
    Player_Name[ MAX_NAME_LENGTH ],
    Player_Title[ MAX_NAME_LENGTH ],
    Player_Team,
    bool:Player_IsCaptain,
    Player_Kills,
    Player_Deaths,
    Player_Assists,
    Player_Reconnects
};

enum _:Match_Struct
{
    Match_ScoreA,
    Match_ScoreB,
    Match_Round,
    Match_Half,
    Match_Overtime,
    bool:Match_TeamsSwapped
};

enum _:Disconnected_Struct
{
    Disconnected_AccId,
    Disconnected_Name[ MAX_NAME_LENGTH ],
    Disconnected_Team,
    Disconnected_Reconnects,
    Disconnected_Kills,
    Disconnected_Deaths,
    Disconnected_Assists,
    Disconnected_Frags,
    Disconnected_ScoreDeaths,
    Disconnected_Money,
    bool:Disconnected_MatchDecided,
    bool:Disconnected_HasWeapons,
    Disconnected_Weapons[ 32 ],
    Disconnected_WeaponClip[ 32 ],
    Disconnected_WeaponBpAmmo[ 32 ],
    Disconnected_WeaponCount,
    Disconnected_Armor,
    Disconnected_ArmorType,
    bool:Disconnected_HasDefuser,
    bool:Disconnected_IsCaptain
};

/* =================================================================================
* 				[ Global Variables ]
* ================================================================================= */

new g_iIsConnected;
new g_iIsReady;

new g_iMixStatus;

new g_iCaptainA;
new g_iCaptainB;

new g_iReadyCount;

new g_iWebRosterAccId[ MAX_MIX_PLAYERS ];
new g_iWebRosterTeam[ MAX_MIX_PLAYERS ];
new g_iWebRosterCount;
new g_iWebTeamSize;
new g_szWebMode[ 8 ];

new bool:g_bWebRosterVacant[ MAX_MIX_PLAYERS ];
new g_iWebRosterVacantMoney[ MAX_MIX_PLAYERS ];
/* Rondas que llevaba el slot cuando su dueño volvio tras abandonar, o -1. */
new g_iWebRosterReturnRounds[ MAX_MIX_PLAYERS ] = { -1, ... };

new g_iWebRosterKills[ MAX_MIX_PLAYERS ];
new g_iWebRosterDeaths[ MAX_MIX_PLAYERS ];
new g_iWebRosterAssists[ MAX_MIX_PLAYERS ];
new g_iWebRosterDamage[ MAX_MIX_PLAYERS ];
new g_iWebRosterHeadshots[ MAX_MIX_PLAYERS ];
new g_iWebRosterRounds[ MAX_MIX_PLAYERS ];

new Float:g_flWebTeamEloA = 1000.0;
new Float:g_flWebTeamEloB = 1000.0;
new bool:g_bWebTeamEloLoaded;

new g_iDamageDealt[ MAX_PLAYERS + 1 ][ MAX_PLAYERS + 1 ];

new g_iRoundDamage[ MAX_PLAYERS + 1 ][ MAX_PLAYERS + 1 ];


new bool:g_bKnifeDone;

new const g_szDamageSeparator[ ] = "**********************************************";
new g_iRoundHits[ MAX_PLAYERS + 1 ][ MAX_PLAYERS + 1 ];

new Float:g_flHealthBeforeHit[ MAX_PLAYERS + 1 ];

new g_iFwdWebMatchEnd = -1;
new g_iFwdWebRosterReject = -1;
new g_iFwdWebScore = -1;
new g_iFwdWebMatchCancel = -1;
new g_iFwdWebPlayerLeft = -1;
new g_iFwdWebPlayerReplaced = -1;
new g_iFwdWebPlayerJoined = -1;
new g_iFwdWebRound = -1;

/* Registro de la ronda para las estadisticas detalladas de la web.
 *
 * Se arma mientras se juega y se entrega entero cuando la ronda termina de
 * verdad (en el restart siguiente, o al cerrar la partida): asi entran tambien
 * las bajas de despues del final de ronda, que el marcador ya cuenta. Nada de
 * esto decide nada del partido; si se pierde, solo falta el detalle en la web. */
#define WEB_ROUND_MAX_KILLS 64
#define WEB_ROUND_DATA_LEN  4096

new g_iWebKillCount;
new g_iWebKillSecond[ WEB_ROUND_MAX_KILLS ];
new g_iWebKillAttacker[ WEB_ROUND_MAX_KILLS ];
new g_iWebKillVictim[ WEB_ROUND_MAX_KILLS ];
new g_iWebKillAssister[ WEB_ROUND_MAX_KILLS ];
new bool:g_bWebKillHeadshot[ WEB_ROUND_MAX_KILLS ];
new g_szWebKillWeapon[ WEB_ROUND_MAX_KILLS ][ 16 ];

new g_iWebRoundHeDamage[ MAX_PLAYERS + 1 ];
new g_iWebRoundFlashes[ MAX_PLAYERS + 1 ];
new g_iWebRoundPlants[ MAX_PLAYERS + 1 ];
new g_iWebRoundDefuses[ MAX_PLAYERS + 1 ];
new bool:g_bWebLastHitHe[ MAX_PLAYERS + 1 ];
/* El golpe que mató ya se sumó en OnPlayerKilled_Pre: el post de ese daño no lo repite. */
new bool:g_bFatalHitCounted[ MAX_PLAYERS + 1 ];

new Float:g_flWebRoundStart;
new g_iWebRoundMoneyA;
new g_iWebRoundMoneyB;

new bool:g_bWebRoundPending;
new g_iWebPendingRound;
new g_iWebPendingHalf;
new g_iWebPendingWinner;
new g_iWebPendingScoreA;
new g_iWebPendingScoreB;
new g_iWebPendingAliveA;
new g_iWebPendingAliveB;
new g_szWebPendingReason[ 16 ];
new g_szWebPendingSideA[ 4 ];
new g_szWebRoundData[ WEB_ROUND_DATA_LEN ];

new g_sPlayers[ MAX_PLAYERS + 1 ][ Player_Struct ];
new g_sMatch[ Match_Struct ];

new g_iKnifeWinner;

new g_iLiveCountdown;
new g_iSideCountdown;

new bool:g_bKnifeRoundActive;
new bool:g_bFirstRoundAfterPhase;

new g_iPausesUsed[ 3 ];
new bool:g_bAutoPauseUsed[ 3 ];
new g_iPauseCountdown;
new g_iStatusBeforePause;
new bool:g_bMatchPaused;
new bool:g_bPendingPause;
new g_iPendingPauseRequestor;
new g_iPauseTeam;

new Float:g_flFreezeTimeLeft;
new bool:g_bResumeFreezeTime;

new g_iSurrenderCountdown;
new g_iSurrenderCaptain;

new g_sDisconnected[ MAX_MIX_PLAYERS ][ Disconnected_Struct ];
new g_iDisconnectedCount;
new g_iReconnectCountdown;

new bool:g_bDisconnectDuringRound;

new g_iOvertimeScoreA;
new g_iOvertimeScoreB;

new g_szTeamNameA[ MAX_NAME_LENGTH ];
new g_szTeamNameB[ MAX_NAME_LENGTH ];

new g_szPrintPrefix[ 16 ];
new g_szMenuTitle[ 32 ];

new g_iReconnectMoney[ MAX_PLAYERS + 1 ];
new bool:g_bReconnectHasWeapons[ MAX_PLAYERS + 1 ];
new g_iReconnectArmor[ MAX_PLAYERS + 1 ];
new g_iReconnectArmorType[ MAX_PLAYERS + 1 ];
new g_iReconnectWeapons[ MAX_PLAYERS + 1 ][ 32 ];
new g_iReconnectWeaponClip[ MAX_PLAYERS + 1 ][ 32 ];
new g_iReconnectWeaponBpAmmo[ MAX_PLAYERS + 1 ][ 32 ];
new g_iReconnectWeaponCount[ MAX_PLAYERS + 1 ];
/* Kills y muertes del TAB para devolver al reconectar; -1 = no hay nada que restaurar. */
new g_iReconnectFrags[ MAX_PLAYERS + 1 ] = { -1, ... };
new g_iReconnectScoreDeaths[ MAX_PLAYERS + 1 ];
new bool:g_bReconnectHasDefuser[ MAX_PLAYERS + 1 ];

new Float:g_flSavedBuytime;
new g_iPauseMoney[ MAX_PLAYERS + 1 ];
new bool:g_bPauseMoneySaved[ MAX_PLAYERS + 1 ];

new g_iPhaseBreakCountdown;
new g_iPhaseTransition;
new bool:g_bInPhaseBreak;

new g_pCvar[ CVARS ];
new g_pCvarPointer[ CVARS ];

/* =================================================================================
* 				[ Plugin Init ]
* ================================================================================= */

public plugin_natives( )
{
    register_library( "mix_core" );

    register_native( "mix_web_clear_roster",  "_mix_web_clear_roster" );
    register_native( "mix_web_set_match_mode", "_mix_web_set_match_mode" );
    register_native( "mix_web_add_player",    "_mix_web_add_player" );
    register_native( "mix_web_is_active",     "_mix_web_is_active" );
    register_native( "mix_web_team_of",       "_mix_web_team_of" );
    register_native( "mix_web_busy",          "_mix_web_busy" );
    register_native( "mix_web_match_status",  "_mix_web_match_status" );
    register_native( "mix_web_round_number",  "_mix_web_round_number" );
    register_native( "mix_web_roster_count",  "_mix_web_roster_count" );
    register_native( "mix_web_vacancy_count", "_mix_web_vacancy_count" );
    register_native( "mix_web_joined_roster_count", "_mix_web_joined_roster_count" );
    register_native( "mix_web_roster_stats",  "_mix_web_roster_stats" );
    register_native( "mix_web_roster_advanced_stats", "_mix_web_roster_advanced_stats" );
    register_native( "mix_web_roster_returned", "_mix_web_roster_returned" );
    register_native( "mix_web_restore_score", "_mix_web_restore_score" );
    register_native( "mix_web_set_team_elo",  "_mix_web_set_team_elo" );
}

public plugin_init( )
{
    register_plugin( "[ZG] AUTOMIX: Core", "1.1", "metita" );

    register_dictionary( "mix_core.txt" );

    RegisterHam( Ham_Spawn, "player", "OnPlayerSpawn_Post", true );
    RegisterHam( Ham_Killed, "player", "OnPlayerKilled_Pre", false );
    RegisterHam( Ham_Killed, "player", "OnPlayerKilled_Post", true );
    RegisterHam( Ham_TakeDamage, "player", "OnPlayerTakeDamage_Post", true );
    RegisterHam( Ham_TakeDamage, "player", "OnPlayerTakeDamage_Pre", false );

    RegisterHookChain( RG_CBasePlayer_MakeBomber, "OnPlayerMakeBomber_Pre", false );
    RegisterHookChain( RG_CBasePlayer_DropPlayerItem, "OnDropPlayerItem_Pre", false );
    RegisterHookChain( RG_CBasePlayer_HasRestrictItem, "OnPlayerHasRestricItem_Pre", false );
    RegisterHookChain( RG_CBasePlayer_GetIntoGame, "OnPlayerGetIntoGame_Post", true );

    RegisterHookChain( RG_RoundEnd, "OnRoundEnd_Pre", false );

    RegisterHookChain( RG_CSGameRules_FPlayerCanRespawn, "OnFPlayerCanRespawn_Post", true );
    RegisterHookChain( RG_CSGameRules_RestartRound, "OnRestartRound_Pre", false );
    RegisterHookChain( RG_CSGameRules_RestartRound, "OnRestartRound_Post", true );
    RegisterHookChain( RG_CSGameRules_OnRoundFreezeEnd, "OnRoundFreezeEnd_Pre", false );
    RegisterHookChain( RG_CSGameRules_CheckWinConditions, "OnCheckWinConditions_Pre", false );

    RegisterHookChain( RG_ThrowFlashbang, "OnWebThrowFlashbang_Post", true );
    RegisterHookChain( RG_PlantBomb, "OnWebPlantBomb_Post", true );
    RegisterHookChain( RG_CGrenade_DefuseBombEnd, "OnWebDefuseBombEnd_Post", true );

    register_clcmd( "say",                  "ClientCommand_Say" );
    register_clcmd( "say_team",             "ClientCommand_SayTeam" );

    register_clcmd( "say .status",          "ClientCommand_Status" );

    register_clcmd( "say .pause",           "ClientCommand_Pause" );
    register_clcmd( "say .unpause",         "ClientCommand_Unpause" );
    
    register_clcmd( "say .score",           "ClientCommand_Score" );
    register_clcmd( "say .dmg",             "ClientCommand_Dmg" );
    register_clcmd( "say .cancel",          "ClientCommand_Cancel" );
    register_srvcmd( "mix_cancel",          "OnServerCommand_Cancel" );
    
    CreateModCvars( );
}

public Server_Instanced( const iInstanceId, const iMapId )
{
    if ( !iInstanceId )
    {
        return;
    }
    
    Server_GetGlobal( "server_tag", g_szPrintPrefix, charsmax( g_szPrintPrefix ) );

    copy( g_szMenuTitle, charsmax( g_szMenuTitle ), "#16 AUTOMIX" );

    g_iMixStatus = MIX_IDLE;

    ResetMixState( );
    StartWarmup( );
}

public plugin_cfg( )
{
    g_iFwdWebMatchEnd     = CreateMultiForward( "mix_web_match_ended", ET_IGNORE, FP_CELL, FP_CELL );
    g_iFwdWebRosterReject = CreateMultiForward( "mix_web_roster_reject", ET_IGNORE, FP_CELL, FP_CELL );
    g_iFwdWebPlayerLeft = CreateMultiForward( "mix_web_player_left", ET_IGNORE, FP_CELL );
    g_iFwdWebPlayerReplaced = CreateMultiForward( "mix_web_player_replaced", ET_IGNORE, FP_CELL, FP_CELL );
    g_iFwdWebPlayerJoined = CreateMultiForward( "mix_web_player_joined", ET_IGNORE, FP_CELL );
    g_iFwdWebScore        = CreateMultiForward( "mix_web_score_changed", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL );
    g_iFwdWebMatchCancel  = CreateMultiForward( "mix_web_match_cancelled", ET_IGNORE );
    g_iFwdWebRound        = CreateMultiForward( "mix_web_round_ended", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL, FP_STRING, FP_STRING, FP_CELL, FP_CELL, FP_STRING );

    set_cvar_num( "mp_give_c4_frags", 0 );
}

/* =================================================================================
* 				[ Web Match Modules ]
* ================================================================================= */

FindWebRosterSlot( const iAccId )
{
    if ( iAccId <= 0 )
    {
        return -1;
    }

    for ( new i = 0; i < g_iWebRosterCount; i++ )
    {
        if ( g_iWebRosterAccId[ i ] == iAccId )
        {
            return i;
        }
    }

    return -1;
}

bool:IsWebMatch( )
{
    return ( g_iWebRosterCount > 0 );
}

#define WEB_STAT_KILL    0
#define WEB_STAT_DEATH   1
#define WEB_STAT_ASSIST  2
#define WEB_STAT_HEADSHOT 3
#define WEB_STAT_ROUND    4

AddWebStat( const iId, const iStat )
{
    if ( !IsWebMatch( ) )
    {
        return;
    }

    new iSlot = FindWebRosterSlot( g_sPlayers[ iId ][ Player_AccId ] );

    if ( iSlot == -1 )
    {
        return;
    }

    switch ( iStat )
    {
        case WEB_STAT_KILL:   g_iWebRosterKills[ iSlot ]++;
        case WEB_STAT_DEATH:  g_iWebRosterDeaths[ iSlot ]++;
        case WEB_STAT_ASSIST: g_iWebRosterAssists[ iSlot ]++;
        case WEB_STAT_HEADSHOT: g_iWebRosterHeadshots[ iSlot ]++;
        case WEB_STAT_ROUND:    g_iWebRosterRounds[ iSlot ]++;
    }
}

AddWebDamage( const iId, const iDamage )
{
    if ( !IsWebMatch( ) || iDamage <= 0 )
    {
        return;
    }

    new iSlot = FindWebRosterSlot( g_sPlayers[ iId ][ Player_AccId ] );

    if ( iSlot != -1 )
    {
        g_iWebRosterDamage[ iSlot ] += iDamage;
    }
}

CountWebRoundParticipants( )
{
    if ( !IsWebMatch( ) )
    {
        return;
    }

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) || g_sPlayers[ iPlayer ][ Player_Team ] == MIX_TEAM_NONE )
        {
            continue;
        }

        AddWebStat( iPlayer, WEB_STAT_ROUND );
    }
}

AwardAssists( const iVictim, const iKiller )
{
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( iPlayer == iKiller || iPlayer == iVictim )
        {
            continue;
        }

        if ( g_iDamageDealt[ iVictim ][ iPlayer ] <= 0 )
        {
            continue;
        }

        g_sPlayers[ iPlayer ][ Player_Assists ]++;

        AddWebStat( iPlayer, WEB_STAT_ASSIST );
    }
}

ClearDamageOn( const iVictim )
{
    for ( new iPlayer = 0; iPlayer <= MaxClients; iPlayer++ )
    {
        g_iDamageDealt[ iVictim ][ iPlayer ] = 0;
    }
}

/* =================================================================================
* 				[ Web Round Log ]
* ================================================================================= */

bool:IsWebRoundLogging( )
{
    return IsWebMatch( ) && ( g_iMixStatus == MIX_LIVE || g_iMixStatus == MIX_OVERTIME );
}

ResetWebRoundLog( )
{
    g_iWebKillCount = 0;

    for ( new i = 0; i <= MAX_PLAYERS; i++ )
    {
        g_iWebRoundHeDamage[ i ] = 0;
        g_iWebRoundFlashes[ i ] = 0;
        g_iWebRoundPlants[ i ] = 0;
        g_iWebRoundDefuses[ i ] = 0;
        g_bWebLastHitHe[ i ] = false;
    }
}

LogWebKill( const iVictim, const iKiller )
{
    if ( !IsWebRoundLogging( ) || g_iWebKillCount >= WEB_ROUND_MAX_KILLS )
    {
        return;
    }

    new iKillerAccId = g_sPlayers[ iKiller ][ Player_AccId ];
    new iVictimAccId = g_sPlayers[ iVictim ][ Player_AccId ];

    if ( iKillerAccId <= 0 || iVictimAccId <= 0 )
    {
        return;
    }

    /* La asistencia que se muestra es la del que mas daño le hizo, fuera del
     * que lo mato. El marcador sigue sumando a todos los que dañaron. */
    new iAssister = 0;
    new iBestDamage = 0;

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( iPlayer == iKiller || iPlayer == iVictim || g_iDamageDealt[ iVictim ][ iPlayer ] <= iBestDamage )
        {
            continue;
        }

        iBestDamage = g_iDamageDealt[ iVictim ][ iPlayer ];
        iAssister = g_sPlayers[ iPlayer ][ Player_AccId ];
    }

    new iEntry = g_iWebKillCount++;

    g_iWebKillSecond[ iEntry ] = max( 0, floatround( get_gametime( ) - g_flWebRoundStart, floatround_floor ) );
    g_iWebKillAttacker[ iEntry ] = iKillerAccId;
    g_iWebKillVictim[ iEntry ] = iVictimAccId;
    g_iWebKillAssister[ iEntry ] = max( 0, iAssister );
    g_bWebKillHeadshot[ iEntry ] = ( get_member( iVictim, m_LastHitGroup ) == HIT_HEAD );

    if ( g_bWebLastHitHe[ iVictim ] )
    {
        copy( g_szWebKillWeapon[ iEntry ], charsmax( g_szWebKillWeapon[ ] ), "hegrenade" );
    }
    else
    {
        new iItem = get_member( iKiller, m_pActiveItem );
        new szClass[ 32 ];

        if ( iItem > 0 && is_entity( iItem ) )
        {
            get_entvar( iItem, var_classname, szClass, charsmax( szClass ) );
        }

        if ( equal( szClass, "weapon_", 7 ) )
        {
            copy( g_szWebKillWeapon[ iEntry ], charsmax( g_szWebKillWeapon[ ] ), szClass[ 7 ] );
        }
        else
        {
            copy( g_szWebKillWeapon[ iEntry ], charsmax( g_szWebKillWeapon[ ] ), "otro" );
        }
    }
}

/* Agrega texto al registro solo si entra completo: un JSON cortado a la mitad
 * se descartaria entero en la base. */
bool:AppendWebRoundData( &iLen, const szPart[ ] )
{
    new iPartLen = strlen( szPart );

    if ( iLen + iPartLen >= WEB_ROUND_DATA_LEN - 8 )
    {
        return false;
    }

    iLen += copy( g_szWebRoundData[ iLen ], WEB_ROUND_DATA_LEN - 1 - iLen, szPart );

    return true;
}

MarkWebRoundEnded( const iWinnerTeam, const ScenarioEventEndRound:iEvent )
{
    if ( !IsWebMatch( ) )
    {
        return;
    }

    g_bWebRoundPending = true;
    g_iWebPendingRound = g_sMatch[ Match_ScoreA ] + g_sMatch[ Match_ScoreB ];
    g_iWebPendingWinner = iWinnerTeam;
    g_iWebPendingScoreA = g_sMatch[ Match_ScoreA ];
    g_iWebPendingScoreB = g_sMatch[ Match_ScoreB ];
    g_iWebPendingHalf = ( g_sMatch[ Match_Overtime ] > 0 ) ? 2 + g_sMatch[ Match_Overtime ] : g_sMatch[ Match_Half ];

    switch ( iEvent )
    {
        case ROUND_TARGET_BOMB:    copy( g_szWebPendingReason, charsmax( g_szWebPendingReason ), "bomba" );
        case ROUND_BOMB_DEFUSED:   copy( g_szWebPendingReason, charsmax( g_szWebPendingReason ), "desactivacion" );
        case ROUND_TARGET_SAVED:   copy( g_szWebPendingReason, charsmax( g_szWebPendingReason ), "tiempo" );
        case ROUND_CTS_WIN, ROUND_TERRORISTS_WIN: copy( g_szWebPendingReason, charsmax( g_szWebPendingReason ), "eliminacion" );
        default:                   copy( g_szWebPendingReason, charsmax( g_szWebPendingReason ), "otro" );
    }

    copy( g_szWebPendingSideA, charsmax( g_szWebPendingSideA ),
        ( GetGameTeamForMixTeam( MIX_TEAM_A ) == TEAM_TERRORIST ) ? "T" : "CT" );

    g_iWebPendingAliveA = 0;
    g_iWebPendingAliveB = 0;

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) || !is_user_alive( iPlayer ) )
        {
            continue;
        }

        switch ( g_sPlayers[ iPlayer ][ Player_Team ] )
        {
            case MIX_TEAM_A: g_iWebPendingAliveA++;
            case MIX_TEAM_B: g_iWebPendingAliveB++;
        }
    }
}

FlushWebRound( )
{
    if ( !g_bWebRoundPending )
    {
        return;
    }

    g_bWebRoundPending = false;

    new iLen = 0;
    new szPart[ 96 ];

    formatex( szPart, charsmax( szPart ), "{^"ma^":%d,^"mb^":%d,^"va^":%d,^"vb^":%d,^"k^":[",
        g_iWebRoundMoneyA, g_iWebRoundMoneyB, g_iWebPendingAliveA, g_iWebPendingAliveB );
    AppendWebRoundData( iLen, szPart );

    for ( new i = 0; i < g_iWebKillCount; i++ )
    {
        formatex( szPart, charsmax( szPart ), "%s[%d,%d,%d,^"%s^",%d,%d]", i ? "," : "",
            g_iWebKillSecond[ i ], g_iWebKillAttacker[ i ], g_iWebKillVictim[ i ],
            g_szWebKillWeapon[ i ], g_bWebKillHeadshot[ i ] ? 1 : 0, g_iWebKillAssister[ i ] );

        if ( !AppendWebRoundData( iLen, szPart ) )
        {
            break;
        }
    }

    AppendWebRoundData( iLen, "],^"d^":[" );

    new bool:bFirst = true;

    for ( new iAttacker = 1; iAttacker <= MaxClients; iAttacker++ )
    {
        new iAttackerAccId = g_sPlayers[ iAttacker ][ Player_AccId ];

        if ( iAttackerAccId <= 0 )
        {
            continue;
        }

        for ( new iVictim = 1; iVictim <= MaxClients; iVictim++ )
        {
            new iVictimAccId = g_sPlayers[ iVictim ][ Player_AccId ];

            if ( iVictim == iAttacker || iVictimAccId <= 0 || g_iRoundDamage[ iAttacker ][ iVictim ] <= 0 )
            {
                continue;
            }

            formatex( szPart, charsmax( szPart ), "%s[%d,%d,%d]", bFirst ? "" : ",",
                iAttackerAccId, iVictimAccId, g_iRoundDamage[ iAttacker ][ iVictim ] );

            if ( AppendWebRoundData( iLen, szPart ) )
            {
                bFirst = false;
            }
        }
    }

    AppendWebRoundData( iLen, "],^"u^":[" );

    bFirst = true;

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        new iAccId = g_sPlayers[ iPlayer ][ Player_AccId ];

        if ( iAccId <= 0 || ( !g_iWebRoundHeDamage[ iPlayer ] && !g_iWebRoundFlashes[ iPlayer ]
            && !g_iWebRoundPlants[ iPlayer ] && !g_iWebRoundDefuses[ iPlayer ] ) )
        {
            continue;
        }

        formatex( szPart, charsmax( szPart ), "%s[%d,%d,%d,%d,%d]", bFirst ? "" : ",", iAccId,
            g_iWebRoundHeDamage[ iPlayer ], g_iWebRoundFlashes[ iPlayer ],
            g_iWebRoundPlants[ iPlayer ], g_iWebRoundDefuses[ iPlayer ] );

        if ( AppendWebRoundData( iLen, szPart ) )
        {
            bFirst = false;
        }
    }

    // Siempre queda lugar para el cierre: AppendWebRoundData reserva 8 celdas.
    copy( g_szWebRoundData[ iLen ], WEB_ROUND_DATA_LEN - 1 - iLen, "]}" );

    ResetWebRoundLog( );

    new iRet;
    ExecuteForward( g_iFwdWebRound, iRet, g_iWebPendingRound, g_iWebPendingHalf, g_iWebPendingWinner,
        g_szWebPendingReason, g_szWebPendingSideA, g_iWebPendingScoreA, g_iWebPendingScoreB, g_szWebRoundData );
}

public OnWebThrowFlashbang_Post( const iId, Float:vecStart[ 3 ], Float:vecVelocity[ 3 ], Float:flTime )
{
    if ( IsWebRoundLogging( ) && iId >= 1 && iId <= MaxClients )
    {
        g_iWebRoundFlashes[ iId ]++;
    }
}

public OnWebPlantBomb_Post( const iId, Float:vecStart[ 3 ], Float:vecVelocity[ 3 ] )
{
    if ( IsWebRoundLogging( ) && iId >= 1 && iId <= MaxClients )
    {
        g_iWebRoundPlants[ iId ]++;
    }
}

public OnWebDefuseBombEnd_Post( const iBomb, const iId, bool:bDefused )
{
    if ( bDefused && IsWebRoundLogging( ) && iId >= 1 && iId <= MaxClients )
    {
        g_iWebRoundDefuses[ iId ]++;
    }
}

NotifyWebScore( )
{
    if ( !IsWebMatch( ) )
    {
        return;
    }

    new iHalf = g_sMatch[ Match_Half ];

    if ( g_sMatch[ Match_Overtime ] > 0 )
    {
        iHalf = 2 + g_sMatch[ Match_Overtime ];
    }

    new iRet;
    ExecuteForward( g_iFwdWebScore, iRet, g_sMatch[ Match_ScoreA ], g_sMatch[ Match_ScoreB ], iHalf );
}

NotifyWebPlayerJoined( const iId )
{
    if ( !IsWebMatch( ) || g_sPlayers[ iId ][ Player_AccId ] <= 0
        || FindWebRosterSlot( g_sPlayers[ iId ][ Player_AccId ] ) == -1 )
    {
        return;
    }

    new TeamName:iGameTeam = get_member( iId, m_iTeam );

    if ( iGameTeam != TEAM_TERRORIST && iGameTeam != TEAM_CT )
    {
        return;
    }

    new iRet;
    ExecuteForward( g_iFwdWebPlayerJoined, iRet, g_sPlayers[ iId ][ Player_AccId ] );
}

/* =================================================================================
* 				[ Forwards ]
* ================================================================================= */

public client_putinserver( iId )
{
    remove_task( iId );

    SetPlayerBit( g_iIsConnected, iId );
    ClearPlayerBit( g_iIsReady, iId );
    
    ResetPlayerData( iId );
    g_iPauseMoney[ iId ] = 0;
    g_bPauseMoneySaved[ iId ] = false;
    g_iReconnectMoney[ iId ] = 0;
    g_iReconnectFrags[ iId ] = -1;
    g_bReconnectHasWeapons[ iId ] = false;
    g_iReconnectArmor[ iId ] = 0;
    g_iReconnectArmorType[ iId ] = 0;
    g_iReconnectWeaponCount[ iId ] = 0;
    g_bReconnectHasDefuser[ iId ] = false;
    
    get_user_name( iId, g_sPlayers[ iId ][ Player_Name ], charsmax( g_sPlayers[ ][ Player_Name ] ) );
}

public client_disconnected( iId )
{
    remove_task( iId );
    remove_task( TASK_SHOW_ROUND_DAMAGE + iId );

    ClearPlayerBit( g_iIsConnected, iId );
    
    if ( g_iMixStatus == MIX_IDLE )
    {
        if ( GetPlayerBit( g_iIsReady, iId ) )
        {
            ClearPlayerBit( g_iIsReady, iId );

            g_iReadyCount--;

            CheckReadyStatus( );
        }
    }
    else if ( g_iMixStatus == MIX_PREPARING )
    {
        HandleDisconnectBeforeKnife( iId );
    }
    else if ( g_iMixStatus == MIX_KNIFE_ROUND )
    {
        HandleDisconnectDuringKnife( iId );
    }
    else if ( g_iMixStatus == MIX_HALFTIME || g_iMixStatus == MIX_PAUSED || g_iMixStatus == MIX_LIVE || g_iMixStatus == MIX_OVERTIME )
    {
        HandleDisconnectDuringMatch( iId );
    }
    else
    {
        ResetPlayerData( iId );
    }
    
    g_sPlayers[ iId ][ Player_AccId ] = 0;
    g_sPlayers[ iId ][ Player_Name ][ 0 ] = EOS;
    g_sPlayers[ iId ][ Player_Title ][ 0 ] = EOS;
    g_iPauseMoney[ iId ] = 0;
    g_bPauseMoneySaved[ iId ] = false;
    g_iReconnectMoney[ iId ] = 0;
    g_iReconnectFrags[ iId ] = -1;
    g_bReconnectHasWeapons[ iId ] = false;
    g_iReconnectArmor[ iId ] = 0;
    g_iReconnectArmorType[ iId ] = 0;
    g_iReconnectWeaponCount[ iId ] = 0;
    g_bReconnectHasDefuser[ iId ] = false;
}

public Account_UserLogged( const iId, const iAccId, const iSessionId, const mariadb_result:hResult )
{
    g_sPlayers[ iId ][ Player_AccId ] = iAccId;

    get_user_name( iId, g_sPlayers[ iId ][ Player_Name ], charsmax( g_sPlayers[ ][ Player_Name ] ) );
    
    new bool:bTemp = true;
    Hierarchy_AccessTitle( get_user_flags( iId ), g_sPlayers[ iId ][ Player_Title ], charsmax( g_sPlayers[ ][ Player_Title ] ), bTemp );

    /* Un outsider solo puede quedarse cuando existe un abandono ya asentado
     * que abrió un slot. El dueño anterior puede recuperar ese mismo slot
     * mientras nadie lo haya tomado: el abandono ya quedó registrado en SQL y
     * no se deshace, solo vuelve a jugar. */
    new iRosterSlot = FindWebRosterSlot( iAccId );
    new bool:bMatchRunning = ( g_iMixStatus == MIX_KNIFE_ROUND || g_iMixStatus == MIX_HALFTIME || g_iMixStatus == MIX_PAUSED || g_iMixStatus == MIX_LIVE || g_iMixStatus == MIX_OVERTIME );

    if ( IsWebMatch( ) && bMatchRunning && iRosterSlot != -1 && g_bWebRosterVacant[ iRosterSlot ] )
    {
        RejoinAbandonedRosterSlot( iId, iRosterSlot );

        return;
    }

    if ( IsWebMatch( )
        && ( ( iRosterSlot != -1 && g_bWebRosterVacant[ iRosterSlot ] )
            || ( iRosterSlot == -1 && FindVacantRosterSlot( ) == -1 ) ) )
    {
        new iRet;
        ExecuteForward( g_iFwdWebRosterReject, iRet, iId, iAccId );

        return;
    }

    if ( bMatchRunning )
    {
        HandlePlayerReconnect( iId );
    }
    
}

public Account_UserPrivilegesChanged( const iId, const bOldFlags, &bNewFlags )
{
    new bool:bTemp = true;
    Hierarchy_AccessTitle( bNewFlags, g_sPlayers[ iId ][ Player_Title ], charsmax( g_sPlayers[ ][ Player_Title ] ), bTemp );
}

public Account_UserJoinGame( const iId, const JoinGame:iOption )
{
    if ( iOption != JOIN_GAME )
    {
        return PLUGIN_CONTINUE;
    }

    if ( !IsWebMatch( ) )
    {
        rg_join_team( iId, GetBalancedTeamForWarmup( ) );

        client_print_color( iId, print_team_default, "^4[%s]^1 Calentando. Las partidas se arman en^4 zgaming.net/mix^1.", g_szPrintPrefix );

        return PLUGIN_HANDLED;
    }

    /* Account_UserLogged() puede haber restaurado automaticamente a un
     * jugador que volvio al servidor. El menu de AccSys puede emitir despues
     * otro JOIN_GAME; no debemos volver a llamar rg_join_team(), porque ese
     * segundo ingreso puede respawnear y volver a inicializar su economia. */
    if ( g_iMixStatus >= MIX_KNIFE_ROUND && g_iMixStatus != MIX_FINISHED
        && g_sPlayers[ iId ][ Player_Team ] != MIX_TEAM_NONE
        && g_sPlayers[ iId ][ Player_AccId ] > 0
        && FindDisconnectedByAccId( g_sPlayers[ iId ][ Player_AccId ] ) == -1 )
    {
        new iCurrentRosterSlot = FindWebRosterSlot( g_sPlayers[ iId ][ Player_AccId ] );

        if ( iCurrentRosterSlot != -1
            && !g_bWebRosterVacant[ iCurrentRosterSlot ]
            && g_iWebRosterTeam[ iCurrentRosterSlot ] == g_sPlayers[ iId ][ Player_Team ]
            && get_member( iId, m_iTeam ) == GetGameTeamForMixTeam( g_sPlayers[ iId ][ Player_Team ] ) )
        {
            return PLUGIN_HANDLED;
        }
    }

    if ( g_iMixStatus == MIX_PREPARING && !GetPlayerBit( g_iIsReady, iId ) )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 La partida web se esta^4 preparando^1.", g_szPrintPrefix );

        return PLUGIN_HANDLED;
    }

    if ( g_iMixStatus == MIX_FINISHED )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 La partida ha^4 terminado^1.", g_szPrintPrefix );

        return PLUGIN_HANDLED;
    }

    if ( g_iMixStatus >= MIX_KNIFE_ROUND )
    {
        if ( HasDisconnectedPlayers( ) )
        {
            new iOwnRosterSlot = FindWebRosterSlot( g_sPlayers[ iId ][ Player_AccId ] );

            if ( g_sPlayers[ iId ][ Player_AccId ] != 0
                && iOwnRosterSlot != -1
                && !g_bWebRosterVacant[ iOwnRosterSlot ]
                && FindDisconnectedByAccId( g_sPlayers[ iId ][ Player_AccId ] ) != -1 )
            {
                HandlePlayerReconnect( iId );

                return PLUGIN_HANDLED;
            }

            if ( FindVacantRosterSlot( ) == -1 )
            {
                client_print_color( iId, print_team_default, "^4[%s]^1 Esperando reconexion de jugadores desconectados.", g_szPrintPrefix );

                return PLUGIN_HANDLED;
            }
        }

        new iRosterSlot = FindWebRosterSlot( g_sPlayers[ iId ][ Player_AccId ] );

        if ( iRosterSlot != -1 && g_bWebRosterVacant[ iRosterSlot ] )
        {
            RejoinAbandonedRosterSlot( iId, iRosterSlot );

            return PLUGIN_HANDLED;
        }

        if ( iRosterSlot == -1 )
        {
            iRosterSlot = FindVacantRosterSlot( );

            if ( iRosterSlot == -1 || !TakeVacantRosterSlot( iId, iRosterSlot ) )
            {
                client_print_color( iId, print_team_default, "^4[%s]^1 No estas en el^4 roster^1 de esta partida.", g_szPrintPrefix );

                rg_join_team( iId, TEAM_SPECTATOR );

                return PLUGIN_HANDLED;
            }
        }

        new iMixTeam = g_iWebRosterTeam[ iRosterSlot ];

        g_sPlayers[ iId ][ Player_Team ] = iMixTeam;

        if ( !GetPlayerBit( g_iIsReady, iId ) )
        {
            SetPlayerBit( g_iIsReady, iId );
            g_iReadyCount++;
        }

        new TeamName:iGameTeam = GetGameTeamForMixTeam( iMixTeam );
        rg_join_team( iId, iGameTeam );
        NotifyWebPlayerJoined( iId );

        client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 se unio a un slot vacio.", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ] );

        return PLUGIN_HANDLED;
    }

    new iRosterSlot = FindWebRosterSlot( g_sPlayers[ iId ][ Player_AccId ] );

    if ( iRosterSlot == -1 )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 No estas en el^4 roster^1 de esta partida.", g_szPrintPrefix );

        rg_join_team( iId, TEAM_SPECTATOR );

        return PLUGIN_HANDLED;
    }

    new iMixTeam = g_iWebRosterTeam[ iRosterSlot ];

    g_sPlayers[ iId ][ Player_Team ] = iMixTeam;

    rg_join_team( iId, ( iMixTeam == MIX_TEAM_A ) ? TEAM_TERRORIST : TEAM_CT );
    NotifyWebPlayerJoined( iId );

    if ( !GetPlayerBit( g_iIsReady, iId ) )
    {
        SetPlayerBit( g_iIsReady, iId );
        g_iReadyCount++;

        client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 se unio. [^4%d^1/^4%d^1]", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ], g_iReadyCount, g_iWebRosterCount );
    }

    /* La cuenta puede conservar ready si reconecto durante knife justo antes
     * de que el flujo vuelva a warmup. JOIN_GAME sigue siendo un punto valido
     * para reevaluar el roster completo aunque el bit ya estuviera puesto. */
    CheckReadyStatus( );

    return PLUGIN_HANDLED;
}

/**
* Pinta en gris "Ingresar al juego" cuando el jugador no puede usarlo.
*
* Es solo estetico: quien no esta en el roster igual queda en espectador si lo
* elige. accsys arma el menu y solo pasa su id, asi que se busca el item por
* nombre; el include documenta que se llama "Ingresar al Juego".
*/
public Account_UserShowMainMenu( const iId, const iMenuId, const MainMenu:iMenuType )
{
    if ( iMenuType != MAINMENU_JOIN || !IsWebMatch( ) )
    {
        return;
    }

    if ( FindWebRosterSlot( g_sPlayers[ iId ][ Player_AccId ] ) != -1 || FindVacantRosterSlot( ) != -1 )
    {
        return;
    }

    new iTotal = menu_items( iMenuId );

    for ( new i = 0; i < iTotal; i++ )
    {
        new szName[ 64 ], szInfo[ 32 ], iAccess, iCallback;

        menu_item_getinfo( iMenuId, i, iAccess, szInfo, charsmax( szInfo ), szName, charsmax( szName ), iCallback );

        if ( containi( szName, "juego" ) == -1 )
        {
            continue;
        }

        menu_item_setname( iMenuId, i, fmt( "\d%s", szName ) );

        break;
    }
}

public Account_UserGetNextMainMenu( const iId, const TeamName:iTeam, &MainMenu:iNextMenu )
{
    if ( iNextMenu == MAINMENU_NONE && iTeam == TEAM_SPECTATOR )
    {
        iNextMenu = MAINMENU_JOIN;
        
        return PLUGIN_HANDLED;
    }
    
    return PLUGIN_CONTINUE;
}

public Account_HandleJoinTeamMenu( const iId )
{
    new TeamName:iTeam = get_member( iId, m_iTeam );
    
    if ( iTeam == TEAM_TERRORIST || iTeam == TEAM_CT )
    {
        ShowMixMenu( iId );

        return PLUGIN_HANDLED;
    }
    
    return PLUGIN_CONTINUE;
}

public OnPlayerSpawn_Post( const iId )
{
    if ( !is_user_alive( iId ) )
    {
        return;
    }

    ClearDamageOn( iId );

    if ( g_iMixStatus == MIX_IDLE )
    {
        rg_add_account( iId, 16000, AS_SET );

        set_task( 1.0, "OnTaskShowWelcome", TASK_SHOW_WELCOME + iId );
    }

    if ( g_iMixStatus == MIX_KNIFE_ROUND )
    {
        StripToKnife( iId );
        rg_set_user_armor( iId, 0, ARMOR_NONE );
    }
    
    if ( ( g_iMixStatus == MIX_LIVE || g_iMixStatus == MIX_OVERTIME ) && ( g_sMatch[ Match_Round ] == 1 || g_bFirstRoundAfterPhase ) )
    {
        rg_remove_all_items( iId );
        rg_give_item( iId, "weapon_knife" );

        rg_add_account( iId, ( g_iMixStatus == MIX_OVERTIME ) ? g_pCvar[ CVAR_OVERTIME_START_MONEY ] : 800, AS_SET );
        rg_set_user_armor( iId, 0, ARMOR_NONE );
        
        new TeamName:iTeam = get_member( iId, m_iTeam );
        
        if ( iTeam == TEAM_TERRORIST )
        {
            rg_give_item( iId, "weapon_glock18" );
            rg_set_user_bpammo( iId, WEAPON_GLOCK18, 40 );
        }
        else if ( iTeam == TEAM_CT )
        {
            rg_give_item( iId, "weapon_usp" );
            rg_set_user_bpammo( iId, WEAPON_USP, 24 );
        }
    }
    
    if ( g_iMixStatus == MIX_FINISHED )
    {
        set_entvar( iId, var_takedamage, DAMAGE_NO );
    }
}

public OnPlayerTakeDamage_Pre( const iVictim, const iInflictor, const iAttacker, Float:flDamage, const iDamageBits )
{
    if ( iVictim >= 1 && iVictim <= MaxClients )
    {
        pev( iVictim, pev_health, g_flHealthBeforeHit[ iVictim ] );

        // Se marca antes del golpe: si mata, la baja se anota antes del post.
        g_bWebLastHitHe[ iVictim ] = ( iDamageBits & DMG_GRENADE ) != 0;
        g_bFatalHitCounted[ iVictim ] = false;
    }

    return HAM_IGNORED;
}

public OnPlayerTakeDamage_Post( const iVictim, const iInflictor, const iAttacker, Float:flDamage, const iDamageBits )
{
    if ( iVictim >= 1 && iVictim <= MaxClients && g_bFatalHitCounted[ iVictim ] )
    {
        g_bFatalHitCounted[ iVictim ] = false;

        return;
    }

    if ( g_iMixStatus != MIX_LIVE && g_iMixStatus != MIX_OVERTIME )
    {
        return;
    }

    if ( iAttacker < 1 || iAttacker > MaxClients || iAttacker == iVictim )
    {
        return;
    }

    new iTeamAtacante = g_sPlayers[ iAttacker ][ Player_Team ];
    new iTeamVictima  = g_sPlayers[ iVictim ][ Player_Team ];

    if ( iTeamAtacante != MIX_TEAM_NONE
        && iTeamVictima != MIX_TEAM_NONE
        && iTeamAtacante == iTeamVictima )
    {
        return;
    }

    g_iDamageDealt[ iVictim ][ iAttacker ] += floatround( flDamage );

    new Float:flAntes = g_flHealthBeforeHit[ iVictim ];
    new Float:flHealthNow = 0.0;

    if ( is_user_alive( iVictim ) )
    {
        pev( iVictim, pev_health, flHealthNow );
    }

    if ( flHealthNow < 0.0 )
    {
        flHealthNow = 0.0;
    }

    new iApplied = floatround( flAntes - flHealthNow );

    if ( iApplied < 0 )
    {
        iApplied = 0;
    }

    g_iRoundDamage[ iAttacker ][ iVictim ] += iApplied;
    g_iRoundHits[ iAttacker ][ iVictim ]++;

    if ( g_bWebLastHitHe[ iVictim ] )
    {
        g_iWebRoundHeDamage[ iAttacker ] += iApplied;
    }

    AddWebDamage( iAttacker, iApplied );
}

MostrarDanoDe( const iPlayer )
{
    new bool:bPrinted = false;

    /* Dos pasadas: primero todo el daño hecho y después todo el recibido.
     * Agrupar por rival intercalaba ambos y la lista quedaba desordenada. */
    for ( new iPass = 0; iPass < 2; iPass++ )
    {
        new bool:bGivenPass = ( iPass == 0 );

        for ( new iOther = 1; iOther <= MaxClients; iOther++ )
        {
            if ( iOther == iPlayer || !GetPlayerBit( g_iIsConnected, iOther ) )
            {
                continue;
            }

            new iAttacker = bGivenPass ? iPlayer : iOther;
            new iVictim = bGivenPass ? iOther : iPlayer;
            new iDamage = g_iRoundDamage[ iAttacker ][ iVictim ];

            if ( iDamage <= 0 )
            {
                continue;
            }

            if ( !bPrinted )
            {
                client_print( iPlayer, print_console, "" );
                client_print( iPlayer, print_console, g_szDamageSeparator );

                client_print_color( iPlayer, print_team_default, "^4[%s]^1 %L^1:",
                    g_szPrintPrefix, iPlayer, "MIX_DMG_CHAT_TITLE" );

                bPrinted = true;
            }

            client_print( iPlayer, print_console, "%L", iPlayer, bGivenPass ? "MIX_DMG_GIVEN" : "MIX_DMG_TAKEN",
                g_sPlayers[ iOther ][ Player_Name ], iDamage, g_iRoundHits[ iAttacker ][ iVictim ] );

            client_print_color( iPlayer, print_team_default, "^4[%s]^1 %L",
                g_szPrintPrefix, iPlayer, bGivenPass ? "MIX_DMG_CHAT_GIVEN" : "MIX_DMG_CHAT_TAKEN",
                g_sPlayers[ iOther ][ Player_Name ], iDamage, g_iRoundHits[ iAttacker ][ iVictim ] );
        }
    }

    if ( bPrinted )
    {
        client_print( iPlayer, print_console, g_szDamageSeparator );

        return true;
    }

    client_print( iPlayer, print_console, "%L", iPlayer, "MIX_DMG_NONE" );
    client_print_color( iPlayer, print_team_default, "^4[%s]^1 %L",
        g_szPrintPrefix, iPlayer, "MIX_DMG_NONE" );

    return false;
}

public OnTaskShowRoundDamage( const iTask )
{
    new iPlayer = iTask - TASK_SHOW_ROUND_DAMAGE;

    if ( iPlayer < 1 || iPlayer > MaxClients
        || !GetPlayerBit( g_iIsConnected, iPlayer )
        || is_user_alive( iPlayer )
        || ( g_iMixStatus != MIX_LIVE && g_iMixStatus != MIX_OVERTIME ) )
    {
        return;
    }

    MostrarDanoDe( iPlayer );
}

ResetRoundDamage( )
{
    for ( new i = 0; i <= MaxClients; i++ )
    {
        if ( i > 0 )
        {
            remove_task( TASK_SHOW_ROUND_DAMAGE + i );
        }

        for ( new j = 0; j <= MaxClients; j++ )
        {
            g_iRoundDamage[ i ][ j ] = 0;
            g_iRoundHits[ i ][ j ] = 0;
        }
    }
}

/* La baja se cuenta en el PRE y no en el POST.
 *
 * Dentro de Killed el motor revisa si la ronda terminó: la última baja de la
 * partida (o del primer tiempo) dispara ahí mismo RoundEnd, FinishMatch y el
 * reporte a la web. Para cuando corría el POST el estado ya no era LIVE y esa
 * baja, su muerte, el headshot, la asistencia y el daño del golpe final se
 * perdían: el scoreboard marcaba 52 y la web 51. */
public OnPlayerKilled_Pre( const iVictim, const iAttacker, const iGib )
{
    if ( g_iMixStatus != MIX_LIVE && g_iMixStatus != MIX_OVERTIME )
    {
        return HAM_IGNORED;
    }

    if ( iVictim < 1 || iVictim > MaxClients )
    {
        return HAM_IGNORED;
    }

    if ( GetPlayerBit( g_iIsConnected, iVictim ) )
    {
        g_sPlayers[ iVictim ][ Player_Deaths ]++;
        AddWebStat( iVictim, WEB_STAT_DEATH );
    }

    if ( iAttacker >= 1 && iAttacker <= MaxClients
        && GetPlayerBit( g_iIsConnected, iAttacker )
        && iVictim != iAttacker
        && g_sPlayers[ iAttacker ][ Player_Team ] != MIX_TEAM_NONE
        && g_sPlayers[ iAttacker ][ Player_Team ] != g_sPlayers[ iVictim ][ Player_Team ] )
    {
        g_sPlayers[ iAttacker ][ Player_Kills ]++;

        AddWebStat( iAttacker, WEB_STAT_KILL );

        if ( get_member( iVictim, m_LastHitGroup ) == HIT_HEAD )
        {
            AddWebStat( iAttacker, WEB_STAT_HEADSHOT );
        }

        /* El golpe que lo mató: la vida que tenía antes es el daño aplicado.
         * Se suma acá porque el POST de ese daño llega recién después. */
        new iApplied = max( 0, floatround( g_flHealthBeforeHit[ iVictim ] ) );

        g_iDamageDealt[ iVictim ][ iAttacker ] += iApplied;
        g_iRoundDamage[ iAttacker ][ iVictim ] += iApplied;
        g_iRoundHits[ iAttacker ][ iVictim ]++;

        if ( g_bWebLastHitHe[ iVictim ] )
        {
            g_iWebRoundHeDamage[ iAttacker ] += iApplied;
        }

        AddWebDamage( iAttacker, iApplied );
        g_bFatalHitCounted[ iVictim ] = true;

        AwardAssists( iVictim, iAttacker );

        LogWebKill( iVictim, iAttacker );
    }

    return HAM_IGNORED;
}

public OnPlayerKilled_Post( const iVictim, const iAttacker, const iGib )
{
    if ( g_iMixStatus == MIX_LIVE || g_iMixStatus == MIX_OVERTIME )
    {
        remove_task( TASK_SHOW_ROUND_DAMAGE + iVictim );
        set_task( 0.1, "OnTaskShowRoundDamage", TASK_SHOW_ROUND_DAMAGE + iVictim );

        ClearDamageOn( iVictim );
    }

    if ( g_iMixStatus == MIX_KNIFE_ROUND && g_bKnifeRoundActive )
    {
        rg_check_win_conditions( );
    }
    
    if ( g_iMixStatus == MIX_LIVE || g_iMixStatus == MIX_OVERTIME )
    {
        rg_check_win_conditions( );
    }
}

public OnPlayerMakeBomber_Pre( const iId )
{
    /* MIX_PAUSED conserva el contexto LIVE/OT. Rechazar MakeBomber() durante
     * la pausa deja al motor sin poder reasignar la C4 cuando un jugador
     * reconecta o entra nuevamente a su equipo. */
    new iRealStatus = GetRealMixStatus( );

    if ( iRealStatus != MIX_LIVE && iRealStatus != MIX_OVERTIME )
    {
        SetHookChainReturn( ATYPE_BOOL, false );
        
        return HC_SUPERCEDE;
    }
    
    return HC_CONTINUE;
}

public OnDropPlayerItem_Pre( const iId, const szItemName[] )
{
    if ( g_iMixStatus == MIX_IDLE )
    {
        SetHookChainReturn( ATYPE_INTEGER, 0 );
        
        return HC_SUPERCEDE;
    }
    
    return HC_CONTINUE;
}

public OnRoundFreezeEnd_Pre( )
{
    /* El contador de pausa usa temporalmente el mismo reloj nativo. Si el
     * motor alcanza cero antes que el task de AMXX, su callback normal libera
     * velocidades y armas por un frame. Mantener la cadena supercedida deja
     * m_bFreezePeriod intacto hasta que UnpauseMatch() lo cierre una sola vez. */
    if ( g_bMatchPaused )
    {
        return HC_SUPERCEDE;
    }

    if ( IsWebRoundLogging( ) )
    {
        g_flWebRoundStart = get_gametime( );
        g_iWebRoundMoneyA = 0;
        g_iWebRoundMoneyB = 0;

        for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
        {
            if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
            {
                continue;
            }

            switch ( g_sPlayers[ iPlayer ][ Player_Team ] )
            {
                case MIX_TEAM_A: g_iWebRoundMoneyA += get_member( iPlayer, m_iAccount );
                case MIX_TEAM_B: g_iWebRoundMoneyB += get_member( iPlayer, m_iAccount );
            }
        }
    }

    return HC_CONTINUE;
}

public OnPlayerHasRestricItem_Pre( iId, ItemID:iItem, ItemRestType:iType )
{
    if ( iType == ITEM_TYPE_BUYING )
    {
        if ( iItem == ITEM_SHIELDGUN )
        {
            client_print( iId, print_center, "Shield can not be purchased with current map/game settings." );
            
            SetHookChainReturn( ATYPE_BOOL, true );
            
            return HC_SUPERCEDE;
        }
        
        if ( iItem == ITEM_NVG )
        {
            client_print( iId, print_center, "Nightvision can not be purchased with current map/game settings." );
            
            SetHookChainReturn( ATYPE_BOOL, true );
            
            return HC_SUPERCEDE;
        }
        
        if ( g_iMixStatus == MIX_IDLE )
        {
            if ( iItem == ITEM_FLASHBANG || iItem == ITEM_HEGRENADE || iItem == ITEM_SMOKEGRENADE )
            {
                SetHookChainReturn( ATYPE_BOOL, true );
                
                return HC_SUPERCEDE;
            }
        }
    }
   
    return HC_CONTINUE;
}

public OnPlayerGetIntoGame_Post( const iId )
{
    if ( g_iMixStatus == MIX_IDLE || g_iMixStatus == MIX_PREPARING )
    {
        SendRoundTime( iId, 0 );
    }
    
    return HC_CONTINUE;
}

public OnFPlayerCanRespawn_Post( const iId )
{
    if ( g_iMixStatus == MIX_IDLE )
    {
        return HC_CONTINUE;
    }
    
    new iRealStatus = GetRealMixStatus( );
    
    if ( iRealStatus == MIX_KNIFE_ROUND )
    {
        return HC_CONTINUE;
    }
    
    if ( iRealStatus == MIX_LIVE || iRealStatus == MIX_OVERTIME )
    {
        if ( g_sPlayers[ iId ][ Player_Team ] != MIX_TEAM_NONE )
        {
            new bool:bInFreezeTime = bool:( get_member_game( m_bFreezePeriod ) );
            
            if ( bInFreezeTime )
            {
                SetHookChainReturn( ATYPE_INTEGER, true );
                
                return HC_SUPERCEDE;
            }
        }
    }
    
    return HC_CONTINUE;
}

public OnCheckWinConditions_Pre( )
{
    if ( g_iMixStatus == MIX_IDLE || g_iMixStatus == MIX_PREPARING || g_iMixStatus == MIX_PAUSED )
    {
        return HC_SUPERCEDE;
    }
    
    if ( g_iMixStatus == MIX_KNIFE_ROUND )
    {
        if ( !g_bKnifeRoundActive )
        {
            return HC_SUPERCEDE;
        }
        
        new iAliveTT, iAliveCT, iDeadTT, iDeadCT;
        rg_initialize_player_counts( iAliveTT, iAliveCT, iDeadTT, iDeadCT );
        
        if ( iAliveTT == 0 && iAliveCT > 0 )
        {
            g_bKnifeRoundActive = false;
            HandleKnifeWinner( MIX_TEAM_B );
            return HC_SUPERCEDE;
        }
        else if ( iAliveCT == 0 && iAliveTT > 0 )
        {
            g_bKnifeRoundActive = false;
            HandleKnifeWinner( MIX_TEAM_A );
            return HC_SUPERCEDE;
        }
        
        return HC_SUPERCEDE;
    }
    
    return HC_CONTINUE;
}

public OnRoundEnd_Pre( const WinStatus:iStatus, const ScenarioEventEndRound:iEvent, const Float:flDelay )
{
    if ( g_iMixStatus == MIX_IDLE || g_iMixStatus == MIX_PREPARING || g_iMixStatus == MIX_PAUSED )
    {
        SetHookChainReturn( ATYPE_BOOL, false );

        return HC_SUPERCEDE;
    }
    
    new iRealStatusEarly = GetRealMixStatus( );
    
    if ( ( iRealStatusEarly == MIX_LIVE || iRealStatusEarly == MIX_OVERTIME ) && g_sMatch[ Match_Round ] == 0 )
    {
        SetHookChainReturn( ATYPE_BOOL, false );
        return HC_SUPERCEDE;
    }


    if ( g_iMixStatus == MIX_KNIFE_ROUND && !g_bKnifeRoundActive )
    {
        SetHookChainReturn( ATYPE_BOOL, false );
        return HC_SUPERCEDE;
    }
    
    if ( g_iMixStatus == MIX_KNIFE_ROUND && g_bKnifeRoundActive )
    {
        g_bKnifeRoundActive = false;
        
        new iHealthTT = 0, iHealthCT = 0;

        /* Al agotarse el knife decide el HP total restante, como FACEIT. La
         * cantidad de jugadores vivos no tiene prioridad sobre el dano hecho. */
        for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
        {
            if ( !GetPlayerBit( g_iIsConnected, iPlayer ) || !is_user_alive( iPlayer ) )
            {
                continue;
            }

            new TeamName:iTeam = get_member( iPlayer, m_iTeam );

            if ( iTeam == TEAM_TERRORIST )
            {
                iHealthTT += get_user_health( iPlayer );
            }
            else if ( iTeam == TEAM_CT )
            {
                iHealthCT += get_user_health( iPlayer );
            }
        }

        new iWinner;

        if ( iHealthTT > iHealthCT )
        {
            iWinner = MIX_TEAM_A;
        }
        else if ( iHealthCT > iHealthTT )
        {
            iWinner = MIX_TEAM_B;
        }
        else
        {
            iWinner = ( random( 2 ) == 0 ) ? MIX_TEAM_A : MIX_TEAM_B;
        }
        
        HandleKnifeWinner( iWinner );
        
        SetHookChainReturn( ATYPE_BOOL, false );
        
        return HC_SUPERCEDE;
    }
    
    if ( iEvent == ROUND_GAME_COMMENCE )
    {
        SetHookChainReturn( ATYPE_BOOL, false );

        return HC_SUPERCEDE;
    }
    
    new iRealStatus = GetRealMixStatus( );
    
    if ( iRealStatus == MIX_LIVE || iRealStatus == MIX_OVERTIME )
    {
        HandleMatchRoundEnd( iStatus, iEvent );

        /* La ronda decisiva ya la cierra FinishMatch en este mismo hook.
         * No dejamos que el motor programe su restart con el delay normal:
         * podria caer despues de haber vuelto al warmup y cortar la transicion. */
        if ( g_iMixStatus == MIX_FINISHED )
        {
            SetHookChainReturn( ATYPE_BOOL, false );

            return HC_SUPERCEDE;
        }

        /* En cambios de fase el mismo RoundEnd del motor conserva premios,
         * sonidos y marcador, pero su unico restart se posterga hasta que
         * termine el descanso. */
        if ( g_bInPhaseBreak )
        {
            SetHookChainArg( 3, ATYPE_FLOAT, float( g_pCvar[ CVAR_HALFTIME_BREAK ] ) );
        }

        return HC_CONTINUE;
    }
    
    return HC_CONTINUE;
}

public OnRestartRound_Pre( )
{
    /* Una pausa no puede abrir un RestartRound nativo: ese camino resetea
     * cuentas, armas, la bomba y los timestamps de freezetime. */
    if ( g_bMatchPaused )
    {
        return HC_SUPERCEDE;
    }

    FlushWebRound( );

    /* Este es el restart natural que ya habia programado la ronda terminada.
     * Se aplica el swap antes de que el motor respawnee; no se dispara un
     * segundo restart desde el plugin. */
    if ( g_bInPhaseBreak && !ApplyPhaseTransition( ) )
    {
        return HC_SUPERCEDE;
    }
    
    if ( g_iMixStatus == MIX_FINISHED )
    {
        return HC_SUPERCEDE;
    }

    new iRealStatus = GetRealMixStatus( );
    
    if ( iRealStatus == MIX_LIVE || iRealStatus == MIX_OVERTIME )
    {
        g_sMatch[ Match_Round ]++;
        CountWebRoundParticipants( );
        
        if ( g_bDisconnectDuringRound )
        {
            g_bDisconnectDuringRound = false;
            
            new iMissing = GetMissingPlayersCount( );
            
            if ( iMissing > 0 )
            {
                set_task( 0.1, "OnTaskCheckFillAfterRound", TASK_CHECK_FILL );
            }
        }
        
        if ( g_bPendingPause )
        {
            g_bPendingPause = false;
            
            set_task( 0.5, "OnTaskApplyPendingPause", TASK_APPLY_PAUSE );
        }
    }
    
    return HC_CONTINUE;
}

public OnRestartRound_Post( )
{
    ResetRoundDamage( );

    if ( g_iMixStatus == MIX_KNIFE_ROUND || g_iMixStatus == MIX_LIVE || g_iMixStatus == MIX_OVERTIME )
    {
        UpdateRoundTimer( g_pCvar[ CVAR_FREEZETIME ] );
    }

    if ( g_bFirstRoundAfterPhase )
    {
        /* Cada mitad/OT parte con economia limpia. El RestartRound ya proceso
         * el premio de la ronda anterior; ahora se borra la racha para que no
         * pase al otro lado ni a la fase siguiente. */
        set_member_game( m_iNumConsecutiveTerroristLoses, 0 );
        set_member_game( m_iNumConsecutiveCTLoses, 0 );
        set_member_game( m_iLoserBonus, rg_get_account_rules( RR_LOSER_BONUS_DEFAULT ) );

        set_task( 0.1, "OnTaskResetPhaseFlag", TASK_RESET_PHASE_FLAG );
    }
}

/* =================================================================================
* 				[ Client Commands ]
* ================================================================================= */

public ClientCommand_Status( iId )
{
    if ( !GetPlayerBit( g_iIsConnected, iId ) )
    {
        return PLUGIN_HANDLED;
    }
    
    new szStatus[ 64 ];
    
    switch ( g_iMixStatus )
    {
        case MIX_IDLE:
            copy( szStatus, charsmax( szStatus ), "Esperando jugadores" );
        case MIX_PREPARING:
            copy( szStatus, charsmax( szStatus ), "Preparando partida web" );
        case MIX_KNIFE_ROUND:
            copy( szStatus, charsmax( szStatus ), "Ronda de cuchillos" );
        case MIX_HALFTIME:
            copy( szStatus, charsmax( szStatus ), "Medio tiempo" );
        case MIX_LIVE:
            copy( szStatus, charsmax( szStatus ), "Partida en curso" );
        case MIX_OVERTIME:
            copy( szStatus, charsmax( szStatus ), "Overtime" );
        case MIX_PAUSED:
            copy( szStatus, charsmax( szStatus ), "Partida pausada" );
        case MIX_FINISHED:
            copy( szStatus, charsmax( szStatus ), "Partida terminada" );
    }
    
    client_print_color( iId, print_team_default, "^4[%s]^1 Estado: ^3%s", g_szPrintPrefix, szStatus );

    if ( IsWebMatch( ) )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 Modo: ^4%s", g_szPrintPrefix, g_szWebMode );
    }

    if ( g_iMixStatus == MIX_LIVE || g_iMixStatus == MIX_OVERTIME || g_iMixStatus == MIX_HALFTIME || g_iMixStatus == MIX_PAUSED )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 Marcador: ^4%d^1 - ^4%d", g_szPrintPrefix, g_sMatch[ Match_ScoreA ], g_sMatch[ Match_ScoreB ] );
    }
    else
    {
        if ( IsWebMatch( ) )
        {
            g_iReadyCount = CountJoinedWebRosterSlots( );
        }

        client_print_color( iId, print_team_default, "^4[%s]^1 Jugadores del roster unidos: ^4%d/%d", g_szPrintPrefix, g_iReadyCount, g_iWebRosterCount );
    }
    
    return PLUGIN_HANDLED;
}

public ClientCommand_Dmg( iId )
{
    if ( !GetPlayerBit( g_iIsConnected, iId ) )
    {
        return PLUGIN_HANDLED;
    }

    if ( g_iMixStatus != MIX_LIVE && g_iMixStatus != MIX_OVERTIME )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 No hay partida en curso.", g_szPrintPrefix );

        return PLUGIN_HANDLED;
    }

    if ( is_user_alive( iId ) )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 El daño se puede ver estando muerto.", g_szPrintPrefix );

        return PLUGIN_HANDLED;
    }

    MostrarDanoDe( iId );

    return PLUGIN_HANDLED;
}

public ClientCommand_Score( iId )
{
    if ( !GetPlayerBit( g_iIsConnected, iId ) )
    {
        return PLUGIN_HANDLED;
    }
    
    if ( g_iMixStatus != MIX_LIVE && g_iMixStatus != MIX_OVERTIME && g_iMixStatus != MIX_HALFTIME && g_iMixStatus != MIX_PAUSED )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 No hay partida en curso.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    client_print_color( iId, print_team_default, "^4[%s]^1 ========== MARCADOR ==========", g_szPrintPrefix );
    client_print_color( iId, print_team_default, "^4[%s]^1 Equipo^3 %s^1:^4 %d", g_szPrintPrefix, g_szTeamNameA, g_sMatch[ Match_ScoreA ] );
    client_print_color( iId, print_team_default, "^4[%s]^1 Equipo^3 %s^1:^4 %d", g_szPrintPrefix, g_szTeamNameB, g_sMatch[ Match_ScoreB ] );
    client_print_color( iId, print_team_default, "^4[%s]^1 Ronda:^4 %d^1 | Mitad:^4 %d", g_szPrintPrefix, g_sMatch[ Match_Round ], g_sMatch[ Match_Half ] );
    
    if ( g_iMixStatus == MIX_OVERTIME )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 Overtime:^4 %d^1 | OT Score:^4 %d^1 -^4 %d", g_szPrintPrefix, g_sMatch[ Match_Overtime ], g_iOvertimeScoreA, g_iOvertimeScoreB );
    }
    
    return PLUGIN_HANDLED;
}

public ClientCommand_Cancel( iId )
{
    if ( !GetPlayerBit( g_iIsConnected, iId ) )
    {
        return PLUGIN_HANDLED;
    }
    
    if ( !IsPlayerRank( iId, "director" ) )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 No tienes^4 permisos^1 para usar este comando.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    if ( g_iMixStatus == MIX_IDLE )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 No hay partida en curso.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 cancelo la partida.", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ] );
    
    CancelMix( );
    
    return PLUGIN_HANDLED;
}

/* =================================================================================
* 				[ Ready System ]
* ================================================================================= */

SweepNonRosterPlayers( )
{
    new iReady;

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }

        // Sin login resuelto no se puede afirmar que sea un colado: a quien
        // esta reconectando accsys todavia no lo tiene logueado, y borrarle el
        // equipo dejaba al mix contando un jugador de menos para siempre.
        // Entrar a un equipo sin cuenta no es posible: el forward de accsys que
        // maneja el join solo corre para usuarios autenticados.
        if ( !Account_IsUserLogged( iPlayer ) )
        {
            continue;
        }

        if ( FindWebRosterSlot( g_sPlayers[ iPlayer ][ Player_AccId ] ) != -1 )
        {
            if ( GetPlayerBit( g_iIsReady, iPlayer ) )
            {
                iReady++;
            }

            continue;
        }

        if ( GetPlayerBit( g_iIsReady, iPlayer ) )
        {
            ClearPlayerBit( g_iIsReady, iPlayer );

            if ( g_iReadyCount > 0 )
            {
                g_iReadyCount--;
            }
        }

        g_sPlayers[ iPlayer ][ Player_Team ] = MIX_TEAM_NONE;

        new TeamName:iTeam = get_member( iPlayer, m_iTeam );

        if ( iTeam != TEAM_TERRORIST && iTeam != TEAM_CT )
        {
            continue;
        }

        client_print_color( iPlayer, print_team_default, "^4[%s]^1 No estas en esta partida, pero puedes^4 mirarla^1 desde espectador.", g_szPrintPrefix );

        rg_join_team( iPlayer, TEAM_SPECTATOR );
    }

    return iReady;
}

CheckReadyStatus( )
{
    if ( g_iMixStatus != MIX_IDLE || !IsWebMatch( ) )
    {
        return;
    }

    SweepNonRosterPlayers( );

    /* Ready es informacion de presentacion. La condicion de arranque se
     * calcula por los slots unicos del roster, no por conexiones: dos clientes
     * con el mismo AccId nunca pueden esconder a otro jugador faltante. */
    g_iReadyCount = CountJoinedWebRosterSlots( );

    if ( g_iReadyCount == g_iWebRosterCount )
    {
        StartWebMatch( );
    }
}

/* =================================================================================
* 				[ Web Match Preparation ]
* ================================================================================= */

ReturnWebMatchToWarmup( )
{
    remove_task( TASK_START_KNIFE );
    remove_task( TASK_LIVE_COUNTDOWN );

    /* Volver al calentamiento cancela la espera de reconexion.
     *
     * Las dos cosas resuelven el mismo problema —falta gente— pero por caminos
     * que no se cruzan: la reconexion devuelve al jugador a su equipo con su
     * dinero y sus armas, y el calentamiento rearma la partida entera desde el
     * roster de la web. Si el contador seguia vivo, el que volvia entraba por
     * el calentamiento, su ficha de desconectado quedaba huerfana, y al
     * cumplirse los 120 segundos el plugin lo daba por ausente estando dentro:
     * le quitaba la capitania, avisaba a la web de que se habia ido y abria el
     * menu de rendicion en medio de una partida completa.
     *
     * Va antes de tocar el estado: `HandlePlayerReconnect` mira `g_iMixStatus`
     * para decidir si actua, y en MIX_IDLE ya no actuaria. */
    remove_task( TASK_RECONNECT_TIMEOUT );
    ResetDisconnectedData( );

    g_iMixStatus = MIX_IDLE;

    if ( g_iCaptainA ) g_sPlayers[ g_iCaptainA ][ Player_IsCaptain ] = false;
    if ( g_iCaptainB ) g_sPlayers[ g_iCaptainB ][ Player_IsCaptain ] = false;

    g_iCaptainA = 0;
    g_iCaptainB = 0;

    new iMissing = GetMissingPlayersCount( );

    if ( iMissing > 0 )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Falta%s^4 %d jugador%s^1. La partida arranca cuando^4 vuelva%s^1.",
            g_szPrintPrefix,
            ( iMissing == 1 ) ? "" : "n",
            iMissing,
            ( iMissing == 1 ) ? "" : "es",
            ( iMissing == 1 ) ? "" : "n" );
    }
    else
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Todos los jugadores estan de vuelta. Retomando^4 partida^1.", g_szPrintPrefix );
    }

    StartWarmup( );

    /* Puede ocurrir que el ultimo jugador termine de reconectar en el borde
     * entre knife/eleccion de lado y este retorno. Si ya no falta nadie, no
     * debe quedar MIX_IDLE esperando otro JOIN_GAME para volver a arrancar. */
    if ( iMissing == 0 )
    {
        CheckReadyStatus( );
    }
}

/** Jugador conectado con esa cuenta, o 0 si no esta. */
FindPlayerByAccId( const iAccId )
{
    if ( iAccId <= 0 )
    {
        return 0;
    }

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( GetPlayerBit( g_iIsConnected, iPlayer ) && g_sPlayers[ iPlayer ][ Player_AccId ] == iAccId )
        {
            return iPlayer;
        }
    }

    return 0;
}

FindJoinedPlayerForWebSlot( const iSlot )
{
    if ( iSlot < 0 || iSlot >= g_iWebRosterCount )
    {
        return 0;
    }

    new iAccId = g_iWebRosterAccId[ iSlot ];
    new iExpectedTeam = g_iWebRosterTeam[ iSlot ];

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer )
            || !GetPlayerBit( g_iIsReady, iPlayer )
            || g_sPlayers[ iPlayer ][ Player_AccId ] != iAccId
            || g_sPlayers[ iPlayer ][ Player_Team ] != iExpectedTeam )
        {
            continue;
        }

        new TeamName:iGameTeam = get_member( iPlayer, m_iTeam );

        if ( iGameTeam == TEAM_TERRORIST || iGameTeam == TEAM_CT )
        {
            return iPlayer;
        }
    }

    return 0;
}

CountJoinedWebRosterSlots( )
{
    new iCount;

    for ( new iSlot = 0; iSlot < g_iWebRosterCount; iSlot++ )
    {
        if ( FindJoinedPlayerForWebSlot( iSlot ) )
        {
            iCount++;
        }
    }

    return iCount;
}

/**
* Capitan que eligio la web para ese equipo, si esta conectado.
*
* El roster llega ordenado con el capitan primero de cada lado, asi que basta
* con el primer slot del equipo.
*/
FindWebCaptain( const iTeam )
{
    for ( new i = 0; i < g_iWebRosterCount; i++ )
    {
        if ( g_iWebRosterTeam[ i ] == iTeam )
        {
            return FindPlayerByAccId( g_iWebRosterAccId[ i ] );
        }
    }

    return 0;
}

StartWebMatch( )
{
    g_iMixStatus = MIX_PREPARING;

    StopWarmup( );

    SweepNonRosterPlayers( );

    /* Los capitanes son los que eligio la web, no el primero que se conecto.
     *
     * Antes se tomaba el primer jugador de cada equipo recorriendo por indice, o
     * sea por orden de conexion: los nombres de equipo del juego no coincidian
     * con los de la pagina. */
    g_iCaptainA = FindWebCaptain( MIX_TEAM_A );
    g_iCaptainB = FindWebCaptain( MIX_TEAM_B );

    // Si el capitan de la web no esta conectado, manda el primero de su lado.
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }

        new iTeam = g_sPlayers[ iPlayer ][ Player_Team ];

        if ( iTeam == MIX_TEAM_A && !g_iCaptainA )
        {
            g_iCaptainA = iPlayer;
        }
        else if ( iTeam == MIX_TEAM_B && !g_iCaptainB )
        {
            g_iCaptainB = iPlayer;
        }
    }

    if ( !g_iCaptainA || !g_iCaptainB )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Roster^4 incompleto^1. Mix cancelado.", g_szPrintPrefix );

        CancelMix( );

        return;
    }

    g_sPlayers[ g_iCaptainA ][ Player_IsCaptain ] = true;
    g_sPlayers[ g_iCaptainB ][ Player_IsCaptain ] = true;

    copy( g_szTeamNameA, charsmax( g_szTeamNameA ), g_sPlayers[ g_iCaptainA ][ Player_Name ] );
    copy( g_szTeamNameB, charsmax( g_szTeamNameB ), g_sPlayers[ g_iCaptainB ][ Player_Name ] );

    client_print_color( 0, print_team_default, "^4[%s]^1 Modo^4 %s^1: equipos armados desde^4 zgaming.net^1.", g_szPrintPrefix, g_szWebMode );

    PrepareWebMatch( );
}

PrepareWebMatch( )
{
    new iMissing = GetMissingPlayersCount( );
    
    if ( iMissing > 0 )
    {
        ReturnWebMatchToWarmup( );

        return;
    }

    /* El roster y el ELO llegan en consultas separadas. No arrancar knife ni
     * mostrar 1000/1000 por una carrera si todo el roster entro muy rapido. */
    if ( !g_bWebTeamEloLoaded )
    {
        remove_task( TASK_WAIT_TEAM_ELO );
        set_task( 0.2, "OnTaskWaitTeamElo", TASK_WAIT_TEAM_ELO );

        return;
    }
    
    client_print_color( 0, print_team_default, "^4[%s]^1 ¡Equipos^4 completos^1!", g_szPrintPrefix );

    ShowTeams( );

    /* El cuchillo se juega una sola vez por partida.
     *
     * Si volvimos al calentamiento porque falto alguien, al completarse otra vez
     * hay que retomar donde se dejo: repetirlo tiraba a la basura el lado que el
     * ganador ya habia elegido. */
    if ( g_bKnifeDone )
    {
        ApplyTeamsAndStartMatch( );

        return;
    }

    set_task( 3.0, "OnTaskStartKnifeRound", TASK_START_KNIFE );
}

public OnTaskWaitTeamElo( )
{
    if ( g_iMixStatus == MIX_PREPARING )
    {
        PrepareWebMatch( );
    }
}

ShowTeams( )
{
    client_print_color( 0, print_team_default, "^4[%s]^1 ========== EQUIPOS FINALES ==========", g_szPrintPrefix );
    
    ShowTeamList( MIX_TEAM_A, g_iCaptainA );
    ShowTeamList( MIX_TEAM_B, g_iCaptainB );

    ShowWebElo( );
}

ShowTeamList( const iMixTeam, const iCaptain )
{
    new szTeam[ 256 ];
    formatex( szTeam, charsmax( szTeam ), "^4[%s]^1 Equipo^4 %s^1: ^4[C]^3 %s^1", g_szPrintPrefix, g_sPlayers[ iCaptain ][ Player_Name ], g_sPlayers[ iCaptain ][ Player_Name ] );
    
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( g_sPlayers[ iPlayer ][ Player_Team ] != iMixTeam )
        {
            continue;
        }
        
        if ( g_sPlayers[ iPlayer ][ Player_IsCaptain ] )
        {
            continue;
        }
        
        add( szTeam, charsmax( szTeam ), fmt( ", ^3%s^1", g_sPlayers[ iPlayer ][ Player_Name ] ) );
    }
    
    client_print_color( 0, print_team_default, szTeam );
}

ShowWebElo( )
{
    new Float:flExpectedA = 1.0 / ( 1.0 + floatpower( 10.0, ( g_flWebTeamEloB - g_flWebTeamEloA ) / 400.0 ) );

    new iGainA = floatround( 50.0 * ( 1.0 - flExpectedA ) );
    new iLossA = floatround( 50.0 * flExpectedA );

    if ( iGainA < 1 ) iGainA = 1;
    if ( iLossA < 1 ) iLossA = 1;

    client_print_color( 0, print_team_default,
        "^4[%s]^1 Equipo^3 %s^1: ^4%d ELO^1 (^4+%d^1 si gana /^3 -%d^1 si pierde).",
        g_szPrintPrefix, g_szTeamNameA, floatround( g_flWebTeamEloA ), iGainA, iLossA );

    client_print_color( 0, print_team_default,
        "^4[%s]^1 Equipo^3 %s^1: ^4%d ELO^1 (^4+%d^1 si gana /^3 -%d^1 si pierde).",
        g_szPrintPrefix, g_szTeamNameB, floatround( g_flWebTeamEloB ), iLossA, iGainA );
}

/* =================================================================================
* 				[ Knife Round ]
* ================================================================================= */

HandleKnifeWinner( const iWinnerTeam )
{
    g_iKnifeWinner = iWinnerTeam;
    
    new iWinnerCaptain = ( iWinnerTeam == MIX_TEAM_A ) ? g_iCaptainA : g_iCaptainB;
    
    client_print_color( 0, print_team_default, "^4[%s]^1 Equipo^3 %s^1 gano la ronda de cuchillos!", g_szPrintPrefix, g_sPlayers[ iWinnerCaptain ][ Player_Name ] );

    set_task( 2.0, "OnTaskShowSideMenu", TASK_SHOW_SIDE_MENU );
}

ShowSideMenu( const iCaptain )
{
    if ( !GetPlayerBit( g_iIsConnected, iCaptain ) )
    {
        return;
    }
    
    new bool:bWinnerIsTT = ( g_iKnifeWinner == MIX_TEAM_A );
    
    new iMenu = menu_create( fmt( "\yElige tu lado:" ), "OnSideMenuHandler" );

    menu_additem( iMenu, fmt( "Quedarse de:\y %s", bWinnerIsTT ? "terrorista" : "anti-terrorista" ), "1" );
    menu_additem( iMenu, fmt( "Cambiar al lado:\y %s^n", bWinnerIsTT ? "anti-terrorista" : "terrorista" ), "2" );

    menu_addtext2( iMenu, fmt( "\r[!]\w Tiempo restante:\y %d segundos", g_iSideCountdown ) );
    
    menu_setprop( iMenu, MPROP_EXIT, MEXIT_NEVER );

    menu_display( iCaptain, iMenu );
}

public OnSideMenuHandler( iId, iMenu, iItem )
{
    if ( iItem == MENU_EXIT )
    {
        menu_destroy( iMenu );

        return PLUGIN_HANDLED;
    }

    remove_task( TASK_SIDE_COUNTDOWN );
    
    new szData[ 8 ];

    menu_item_getinfo( iMenu, iItem, _, szData, charsmax( szData ) );
    menu_destroy( iMenu );
    
    new iSide = str_to_num( szData );
    
    SelectSide( iSide );
    
    return PLUGIN_HANDLED;
}

SelectSide( const iChoice )
{
    if ( !CheckTeamsValid( ) )
    {
        CancelMix( );
        
        return;
    }
    
    new bool:bSwitch = ( iChoice == 2 );
    new bool:bWinnerIsTT = ( g_iKnifeWinner == MIX_TEAM_A );
    
    if ( bSwitch )
    {
        bWinnerIsTT = !bWinnerIsTT;
    }
    
    new iWinnerCaptain = ( g_iKnifeWinner == MIX_TEAM_A ) ? g_iCaptainA : g_iCaptainB;
    
    new szSide[ 32 ];
    copy( szSide, charsmax( szSide ), bWinnerIsTT ? "Terrorista" : "Anti-terrorista" );

    if ( bSwitch )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Equipo^3 %s^1 eligio cambiarse al lado^4 %s^1.", g_szPrintPrefix, g_sPlayers[ iWinnerCaptain ][ Player_Name ], szSide );
    }
    else
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Equipo^3 %s^1 eligio quedarse en el equipo^4 %s^1.", g_szPrintPrefix, g_sPlayers[ iWinnerCaptain ][ Player_Name ], szSide );
    }

    if ( bSwitch )
    {
        g_sMatch[ Match_TeamsSwapped ] = true;
    }

    g_bKnifeDone = true;

    new iMissing = GetMissingPlayersCount( );
    
    if ( iMissing > 0 )
    {
        ReturnWebMatchToWarmup( );

        return;
    }

    ApplyTeamsAndStartMatch( );
}

GetDisconnectedTeam( )
{
    if ( g_iDisconnectedCount == 0 )
    {
        return MIX_TEAM_NONE;
    }
    
    return g_sDisconnected[ 0 ][ Disconnected_Team ];
}

ApplyForfeitScore( const iWinnerTeam )
{
    new iRoundsToWin = g_pCvar[ CVAR_ROUNDS_PER_HALF ] + 1;

    if ( iWinnerTeam == MIX_TEAM_A )
    {
        g_sMatch[ Match_ScoreA ] = iRoundsToWin;

        if ( g_sMatch[ Match_ScoreB ] >= iRoundsToWin )
        {
            g_sMatch[ Match_ScoreB ] = iRoundsToWin - 1;
        }
    }
    else
    {
        g_sMatch[ Match_ScoreB ] = iRoundsToWin;

        if ( g_sMatch[ Match_ScoreA ] >= iRoundsToWin )
        {
            g_sMatch[ Match_ScoreA ] = iRoundsToWin - 1;
        }
    }
}

ShowSurrenderMenu( )
{
    new iAffectedTeam = GetDisconnectedTeam( );

    if ( iAffectedTeam == MIX_TEAM_NONE )
    {
        // Si hay jugadores desconectados pero no se puede determinar el equipo,
        // limpiar los datos para evitar que el sistema quede bloqueado
        if ( HasDisconnectedPlayers( ) )
        {
            ResetDisconnectedData( );

            client_print_color( 0, print_team_default, "^4[%s]^1 Error en datos de reconexion. Slots^4 liberados^1.", g_szPrintPrefix );
        }

        return;
    }
    
    // El juego continua mientras el capitan decide, sin volver a crear otro
    // freezetime encima del que ya vencio.
    if ( g_bMatchPaused )
    {
        ResumeMatchForSurrender( );
    }
    
    TransferDisconnectedCaptaincy( );
    
    new iCaptain = ( iAffectedTeam == MIX_TEAM_A ) ? g_iCaptainA : g_iCaptainB;
    
    if ( !GetPlayerBit( g_iIsConnected, iCaptain ) )
    {
        for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
        {
            if ( GetPlayerBit( g_iIsConnected, iPlayer ) && g_sPlayers[ iPlayer ][ Player_Team ] == iAffectedTeam )
            {
                iCaptain = iPlayer;
                
                break;
            }
        }
    }
    
    if ( !GetPlayerBit( g_iIsConnected, iCaptain ) )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 No hay jugadores en el equipo afectado. Mix^4 cancelado^1.", g_szPrintPrefix );
        
        CancelMix( );
        
        return;
    }
    
    g_iSurrenderCaptain = iCaptain;
    g_iSurrenderCountdown = 10;
    
    client_print_color( 0, print_team_default, "^4[%s]^1 No se encontro reemplazo.^3 %s^1 tiene^4 10^1 segundos para decidir.", g_szPrintPrefix, g_sPlayers[ iCaptain ][ Player_Name ] );
    
    ShowSurrenderMenuDisplay( iCaptain );
    
    remove_task( TASK_SURRENDER_COUNTDOWN );
    set_task( 1.0, "OnTaskSurrenderCountdown", TASK_SURRENDER_COUNTDOWN, .flags = "b" );
}

ShowSurrenderMenuDisplay( const iCaptain )
{
    if ( !GetPlayerBit( g_iIsConnected, iCaptain ) )
    {
        return;
    }
    
    new iMenu = menu_create( fmt( "\y%s - DECISION\w (%d seg)", g_szMenuTitle, g_iSurrenderCountdown ), "OnSurrenderMenuHandler" );
    
    menu_additem( iMenu, "Continuar (puede entrar un espectador)", "1" );
    menu_additem( iMenu, "Rendirse (victoria para el otro equipo)", "2" );
    
    menu_setprop( iMenu, MPROP_EXIT, MEXIT_NEVER );

    menu_display( iCaptain, iMenu );
}

public OnTaskSurrenderCountdown( )
{
    g_iSurrenderCountdown--;
    
    if ( g_iSurrenderCountdown <= 0 )
    {
        remove_task( TASK_SURRENDER_COUNTDOWN );
        
        if ( GetPlayerBit( g_iIsConnected, g_iSurrenderCaptain ) )
        {
            show_menu( g_iSurrenderCaptain, 0, "" );
        }
        
        client_print_color( 0, print_team_default, "^4[%s]^1 Tiempo agotado. Continuando partida...", g_szPrintPrefix );
        
        g_iSurrenderCaptain = 0;
        
        ResetDisconnectedData( );
        
        return;
    }
    
    ShowSurrenderMenuDisplay( g_iSurrenderCaptain );
}

public OnSurrenderMenuHandler( iId, iMenu, iItem )
{
    remove_task( TASK_SURRENDER_COUNTDOWN );
    
    if ( iItem == MENU_EXIT )
    {
        menu_destroy( iMenu );
        
        g_iSurrenderCaptain = 0;
        
        return PLUGIN_HANDLED;
    }
    
    new szData[ 8 ];
    
    menu_item_getinfo( iMenu, iItem, _, szData, charsmax( szData ) );
    menu_destroy( iMenu );
    new iChoice = str_to_num( szData );
    
    g_iSurrenderCaptain = 0;
    
    if ( iChoice == 1 )
    {
        ResetDisconnectedData( );
        
        client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 decidio^4 continuar^1 jugando.", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ] );
    }
    else
    {
        new iAffectedTeam = GetDisconnectedTeam( );
        
        // Si ya no hay jugadores desconectados, no se puede rendir
        if ( iAffectedTeam == MIX_TEAM_NONE )
        {
            client_print_color( 0, print_team_default, "^4[%s]^1 Todos los jugadores reconectaron. Partida^4 continua^1.", g_szPrintPrefix );
            
            return PLUGIN_HANDLED;
        }
        
        new iWinnerTeam = ( iAffectedTeam == MIX_TEAM_A ) ? MIX_TEAM_B : MIX_TEAM_A;
        new iWinnerCaptain = ( iWinnerTeam == MIX_TEAM_A ) ? g_iCaptainA : g_iCaptainB;
        
        client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 decidio^4 rendirse^1.", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ] );
        client_print_color( 0, print_team_default, "^4[%s]^1 Equipo^3 %s^1 gana la partida por^4 rendicion^1.", g_szPrintPrefix, g_sPlayers[ iWinnerCaptain ][ Player_Name ] );

        ApplyForfeitScore( iWinnerTeam );

        ResetDisconnectedData( );

        FinishMatch( );
    }
    
    return PLUGIN_HANDLED;
}

ApplyTeamsAndStartMatch( )
{
    new iMissing = GetMissingPlayersCount( );
    
    if ( iMissing > 0 )
    {
        ReturnWebMatchToWarmup( );

        return;
    }
    
    g_iMixStatus = MIX_LIVE;
    
    g_sMatch[ Match_ScoreA ] = 0;
    g_sMatch[ Match_ScoreB ] = 0;
    g_sMatch[ Match_Round ] = 0;
    g_sMatch[ Match_Half ] = 1;
    g_sMatch[ Match_Overtime ] = 0;

    NotifyWebScore( );

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }

        new iTeam = g_sPlayers[ iPlayer ][ Player_Team ];
        
        if ( iTeam == MIX_TEAM_NONE )
        {
            rg_set_user_team( iPlayer, TEAM_SPECTATOR );
            
            continue;
        }
        
        if ( g_sMatch[ Match_TeamsSwapped ] )
        {
            iTeam = ( iTeam == MIX_TEAM_A ) ? MIX_TEAM_B : MIX_TEAM_A;
        }
        
        if ( iTeam == MIX_TEAM_A )
        {
            rg_set_user_team( iPlayer, TEAM_TERRORIST );
        }
        else
        {
            rg_set_user_team( iPlayer, TEAM_CT );
        }
        
        set_entvar( iPlayer, var_frags, 0.0 );
        set_member( iPlayer, m_iDeaths, 0 );
    }
    
    rg_update_teamscores( 0, 0, false );
    
    set_cvar_num( "sv_alltalk", 2 );
    set_cvar_float( "mp_roundtime", 1.75 );
    set_cvar_float( "mp_buytime", 0.25 );
    set_cvar_num( "mp_startmoney", 800 );
    set_cvar_num( "mp_free_armor", 0 );
    set_cvar_num( "mp_forcechasecam", 2 );

    g_iLiveCountdown = floatround( g_pCvar[ CVAR_LIVE_COUNTDOWN_TIME ] );
    
    client_print_color( 0, print_team_default, "^4[%s]^1 La partida esta por^4 comenzar^1.", g_szPrintPrefix );
    client_print_color( 0, print_team_default, "^4[%s]^1 Equipo^3 %s^1 vs Equipo^3 %s^1.", g_szPrintPrefix, g_szTeamNameA, g_szTeamNameB );
    
    set_task( 1.0, "OnTaskLiveCountdown", TASK_LIVE_COUNTDOWN, .flags = "a", .repeat = g_iLiveCountdown );
}

/* =================================================================================
* 				[ Match System ]
* ================================================================================= */

GetRealMixStatus( )
{
    if ( g_iMixStatus == MIX_PAUSED )
    {
        return g_iStatusBeforePause;
    }
    
    return g_iMixStatus;
}

HandleMatchRoundEnd( const WinStatus:iStatus, const ScenarioEventEndRound:iEvent )
{
    new iWinnerTeam = 0;
    
    switch ( iStatus )
    {
        case WINSTATUS_TERRORISTS:
            iWinnerTeam = g_sMatch[ Match_TeamsSwapped ] ? MIX_TEAM_B : MIX_TEAM_A;
        case WINSTATUS_CTS:
            iWinnerTeam = g_sMatch[ Match_TeamsSwapped ] ? MIX_TEAM_A : MIX_TEAM_B;
    }
    
    if ( iWinnerTeam == MIX_TEAM_NONE )
    {
        return;
    }

    new iRealStatus = GetRealMixStatus( );

    if ( iWinnerTeam == MIX_TEAM_A )
    {
        g_sMatch[ Match_ScoreA ]++;
        
        if ( iRealStatus == MIX_OVERTIME )
        {
            g_iOvertimeScoreA++;
        }
    }
    else
    {
        g_sMatch[ Match_ScoreB ]++;
        
        if ( iRealStatus == MIX_OVERTIME )
        {
            g_iOvertimeScoreB++;
        }
    }

    ShowScore( );

    NotifyWebScore( );
    MarkWebRoundEnded( iWinnerTeam, iEvent );

    new iTotalRounds = g_sMatch[ Match_ScoreA ] + g_sMatch[ Match_ScoreB ];

    if ( iRealStatus == MIX_LIVE && g_sMatch[ Match_Half ] == 1 && iTotalRounds >= g_pCvar[ CVAR_ROUNDS_PER_HALF ] )
    {
        StartPhaseBreak( PHASE_TRANSITION_REGULATION_HALF );

        return;
    }

    new iRoundsToWin = g_pCvar[ CVAR_ROUNDS_PER_HALF ] + 1;
    
    if ( iRealStatus == MIX_LIVE && ( g_sMatch[ Match_ScoreA ] >= iRoundsToWin || g_sMatch[ Match_ScoreB ] >= iRoundsToWin ) )
    {
        FinishMatch( );
        
        return;
    }

    if ( iRealStatus == MIX_LIVE && g_sMatch[ Match_ScoreA ] == g_pCvar[ CVAR_ROUNDS_PER_HALF ] && g_sMatch[ Match_ScoreB ] == g_pCvar[ CVAR_ROUNDS_PER_HALF ] )
    {
        StartPhaseBreak( PHASE_TRANSITION_OVERTIME_START );

        return;
    }

    if ( iRealStatus == MIX_OVERTIME )
    {
        new iOvertimeRounds = g_iOvertimeScoreA + g_iOvertimeScoreB;

        if ( iOvertimeRounds == g_pCvar[ CVAR_ROUNDS_OVERTIME ] && g_sMatch[ Match_Half ] == 1 )
        {
            StartPhaseBreak( PHASE_TRANSITION_OVERTIME_HALF );

            return;
        }

        new iOvertimeRoundsToWin = g_pCvar[ CVAR_ROUNDS_OVERTIME ] + 1;
        
        if ( g_iOvertimeScoreA >= iOvertimeRoundsToWin || g_iOvertimeScoreB >= iOvertimeRoundsToWin )
        {
            FinishMatch( );
            
            return;
        }

        if ( iOvertimeRounds >= g_pCvar[ CVAR_ROUNDS_OVERTIME ] * 2 )
        {
            if ( g_iOvertimeScoreA == g_iOvertimeScoreB )
            {
                StartPhaseBreak( PHASE_TRANSITION_OVERTIME_START );
                
                return;
            }
            else
            {
                FinishMatch( );
                
                return;
            }
        }
    }
}

ShowScore( )
{
    client_print_color( 0, print_team_default, "^4[%s]^1 Equipo^3 %s:^4 %d^1 -^4 %d^1 Equipo^3 %s^1.", g_szPrintPrefix, g_szTeamNameA, g_sMatch[ Match_ScoreA ], g_sMatch[ Match_ScoreB ], g_szTeamNameB );
}

/* =================================================================================
* 				[ Utility Functions ]
* ================================================================================= */

ResetMixState( )
{
    if ( g_bMatchPaused )
    {
        RestorePauseEconomy( );
    }

    for ( new i = 0; i < MAX_MIX_PLAYERS; i++ )
    {
        g_iWebRosterAccId[ i ] = 0;
        g_iWebRosterTeam[ i ] = MIX_TEAM_NONE;
        g_bWebRosterVacant[ i ] = false;
        g_iWebRosterVacantMoney[ i ] = 0;
        g_iWebRosterReturnRounds[ i ] = -1;
        g_iWebRosterKills[ i ] = 0;
        g_iWebRosterDeaths[ i ] = 0;
        g_iWebRosterAssists[ i ] = 0;
        g_iWebRosterDamage[ i ] = 0;
        g_iWebRosterHeadshots[ i ] = 0;
        g_iWebRosterRounds[ i ] = 0;
    }
    g_iWebRosterCount = 0;
    g_iWebTeamSize = 0;
    g_bWebRoundPending = false;
    ResetWebRoundLog( );
    g_szWebMode[ 0 ] = EOS;
    copy( g_szMenuTitle, charsmax( g_szMenuTitle ), "#16 AUTOMIX" );
    g_flWebTeamEloA = 1000.0;
    g_flWebTeamEloB = 1000.0;
    g_bWebTeamEloLoaded = false;

    g_bKnifeDone = false;

    g_iMixStatus = MIX_IDLE;

    g_iReadyCount = 0;
    
    g_iCaptainA = 0;
    g_iCaptainB = 0;

    g_iKnifeWinner = MIX_TEAM_NONE;
    g_bKnifeRoundActive = false;
    g_bFirstRoundAfterPhase = false;

    g_iIsReady = 0;
    
    g_iPausesUsed[ MIX_TEAM_A ] = 0;
    g_iPausesUsed[ MIX_TEAM_B ] = 0;
    g_bAutoPauseUsed[ MIX_TEAM_A ] = false;
    g_bAutoPauseUsed[ MIX_TEAM_B ] = false;
    g_iPauseCountdown = 0;
    g_iStatusBeforePause = 0;
    g_bMatchPaused = false;
    g_bPendingPause = false;
    g_iPendingPauseRequestor = 0;
    g_iPauseTeam = MIX_TEAM_NONE;

    /* Si el mix se termino con la partida pausada, el freezetime guardado murio
     * con el. Sin esto se lo quedaba puesto el mix siguiente. */
    g_bResumeFreezeTime = false;
    g_flFreezeTimeLeft = 0.0;
    g_iSurrenderCountdown = 0;
    g_iSurrenderCaptain = 0;
    g_iPhaseBreakCountdown = 0;
    g_iPhaseTransition = PHASE_TRANSITION_NONE;
    g_bInPhaseBreak = false;
    
    ResetDisconnectedData( );

    g_bDisconnectDuringRound = false;

    g_iOvertimeScoreA = 0;
    g_iOvertimeScoreB = 0;

    g_sMatch[ Match_ScoreA ] = 0;
    g_sMatch[ Match_ScoreB ] = 0;
    g_sMatch[ Match_Round ] = 0;
    g_sMatch[ Match_Half ] = 0;
    g_sMatch[ Match_Overtime ] = 0;
    g_sMatch[ Match_TeamsSwapped ] = false;

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        remove_task( iPlayer );
        ResetPlayerData( iPlayer );
        g_iPauseMoney[ iPlayer ] = 0;
        g_bPauseMoneySaved[ iPlayer ] = false;
        g_iReconnectMoney[ iPlayer ] = 0;
        g_iReconnectFrags[ iPlayer ] = -1;
        g_bReconnectHasWeapons[ iPlayer ] = false;
        g_iReconnectArmor[ iPlayer ] = 0;
        g_iReconnectArmorType[ iPlayer ] = 0;
        g_iReconnectWeaponCount[ iPlayer ] = 0;
        g_bReconnectHasDefuser[ iPlayer ] = false;
    }

    remove_task( TASK_LIVE_COUNTDOWN );
    remove_task( TASK_WARMUP_RESPAWN );
    remove_task( TASK_WARMUP_START );
    remove_task( TASK_SIDE_COUNTDOWN );
    remove_task( TASK_SHOW_SIDE_MENU );
    remove_task( TASK_PAUSE_COUNTDOWN );
    remove_task( TASK_RECONNECT_TIMEOUT );
    remove_task( TASK_START_KNIFE );
    remove_task( TASK_WAIT_TEAM_ELO );
    remove_task( TASK_CHECK_FILL );
    remove_task( TASK_RESET_PHASE_FLAG );
    remove_task( TASK_APPLY_PAUSE );
    remove_task( TASK_MATCH_RESET );
    remove_task( TASK_SURRENDER_COUNTDOWN );
    remove_task( TASK_PHASE_BREAK );
}

StartWarmup( )
{
    set_cvar_num( "sv_alltalk", 1 );
    set_cvar_num( "mp_freezetime", 0 );
    set_cvar_num( "mp_buytime", -1 );
    set_cvar_num( "mp_startmoney", 16000 );
    set_cvar_num( "mp_maxmoney", 16000 );
    set_cvar_num( "mp_free_armor", 1 );
    set_cvar_num( "mp_item_staytime", 0 );

    set_task( 0.5, "OnTaskWarmupStart", TASK_WARMUP_START );
}

StopWarmup( )
{
    remove_task( TASK_WARMUP_RESPAWN );
    remove_task( TASK_WARMUP_START );

    /* El warmup usa cero para que todos puedan moverse apenas respawnean. Al
     * preparar el knife/match se recupera el valor competitivo configurado. */
    set_cvar_num( "mp_freezetime", g_pCvar[ CVAR_FREEZETIME ] );
    set_cvar_float( "mp_buytime", 0.25 );
    set_cvar_num( "mp_startmoney", 800 );
    set_cvar_num( "mp_maxmoney", 16000 );
    set_cvar_num( "mp_free_armor", 0 );
    set_cvar_num( "mp_item_staytime", 300 );
}

ResetPlayerData( const iId )
{
    g_sPlayers[ iId ][ Player_Team ] = MIX_TEAM_NONE;

    g_sPlayers[ iId ][ Player_IsCaptain ] = false;

    g_sPlayers[ iId ][ Player_Kills ] = 0;
    g_sPlayers[ iId ][ Player_Deaths ] = 0;
    g_sPlayers[ iId ][ Player_Assists ] = 0;
    g_sPlayers[ iId ][ Player_Reconnects ] = 0;
}

ResetDisconnectedData( )
{
    for ( new i = 0; i < MAX_MIX_PLAYERS; i++ )
    {
        g_sDisconnected[ i ][ Disconnected_AccId ] = 0;
        g_sDisconnected[ i ][ Disconnected_Name ][ 0 ] = EOS;
        g_sDisconnected[ i ][ Disconnected_Team ] = MIX_TEAM_NONE;
        g_sDisconnected[ i ][ Disconnected_Reconnects ] = 0;
        g_sDisconnected[ i ][ Disconnected_Kills ] = 0;
        g_sDisconnected[ i ][ Disconnected_Deaths ] = 0;
        g_sDisconnected[ i ][ Disconnected_Assists ] = 0;
        g_sDisconnected[ i ][ Disconnected_Money ] = 0;
        g_sDisconnected[ i ][ Disconnected_HasWeapons ] = false;
        g_sDisconnected[ i ][ Disconnected_WeaponCount ] = 0;
        g_sDisconnected[ i ][ Disconnected_Armor ] = 0;
        g_sDisconnected[ i ][ Disconnected_ArmorType ] = 0;
        g_sDisconnected[ i ][ Disconnected_HasDefuser ] = false;
        g_sDisconnected[ i ][ Disconnected_IsCaptain ] = false;
    }
    
    g_iDisconnectedCount = 0;
    g_iReconnectCountdown = 0;
}

AddDisconnectedPlayer( const iId )
{
    if ( g_iDisconnectedCount >= MAX_MIX_PLAYERS )
    {
        return -1;
    }
    
    new iExisting = FindDisconnectedByAccId( g_sPlayers[ iId ][ Player_AccId ] );
    
    if ( iExisting != -1 )
    {
        return iExisting;
    }
    
    new iSlot = g_iDisconnectedCount;
    
    g_sDisconnected[ iSlot ][ Disconnected_AccId ] = g_sPlayers[ iId ][ Player_AccId ];
    g_sDisconnected[ iSlot ][ Disconnected_Team ] = g_sPlayers[ iId ][ Player_Team ];
    g_sDisconnected[ iSlot ][ Disconnected_Reconnects ] = g_sPlayers[ iId ][ Player_Reconnects ];
    g_sDisconnected[ iSlot ][ Disconnected_Kills ] = g_sPlayers[ iId ][ Player_Kills ];
    g_sDisconnected[ iSlot ][ Disconnected_Deaths ] = g_sPlayers[ iId ][ Player_Deaths ];
    g_sDisconnected[ iSlot ][ Disconnected_Assists ] = g_sPlayers[ iId ][ Player_Assists ];
    // El TAB vive en la entidad del jugador y se pierde al desconectarse.
    g_sDisconnected[ iSlot ][ Disconnected_Frags ] = floatround( Float:get_entvar( iId, var_frags ) );
    g_sDisconnected[ iSlot ][ Disconnected_ScoreDeaths ] = get_member( iId, m_iDeaths );
    g_sDisconnected[ iSlot ][ Disconnected_MatchDecided ] = MatchAlreadyDecided( );
    
    copy( g_sDisconnected[ iSlot ][ Disconnected_Name ], charsmax( g_sDisconnected[ ][ Disconnected_Name ] ), g_sPlayers[ iId ][ Player_Name ] );
    
    g_sDisconnected[ iSlot ][ Disconnected_Money ] = get_member( iId, m_iAccount );
    
    new bool:bInFreezeTime = bool:( get_member_game( m_bFreezePeriod ) );
    
    if ( bInFreezeTime && is_user_alive( iId ) )
    {
        g_sDisconnected[ iSlot ][ Disconnected_HasWeapons ] = true;
        g_sDisconnected[ iSlot ][ Disconnected_Armor ] = rg_get_user_armor( iId );
        g_sDisconnected[ iSlot ][ Disconnected_ArmorType ] = get_member( iId, m_iKevlar );
        g_sDisconnected[ iSlot ][ Disconnected_HasDefuser ] = bool:get_member( iId, m_bHasDefuser );
        
        SavePlayerWeapons( iId, iSlot );
    }
    else
    {
        g_sDisconnected[ iSlot ][ Disconnected_HasWeapons ] = false;
        g_sDisconnected[ iSlot ][ Disconnected_WeaponCount ] = 0;
        g_sDisconnected[ iSlot ][ Disconnected_Armor ] = 0;
        g_sDisconnected[ iSlot ][ Disconnected_ArmorType ] = 0;
        g_sDisconnected[ iSlot ][ Disconnected_HasDefuser ] = false;
    }
    
    g_sDisconnected[ iSlot ][ Disconnected_IsCaptain ] = g_sPlayers[ iId ][ Player_IsCaptain ];
    
    g_iDisconnectedCount++;
    
    return iSlot;
}

SavePlayerWeapons( const iId, const iSlot )
{
    new iWeaponCount = 0;
    new iWeapons[ 32 ];
    new iNum;
    
    get_user_weapons( iId, iWeapons, iNum );
    
    for ( new i = 0; i < iNum && iWeaponCount < 32; i++ )
    {
        new iWeaponId = iWeapons[ i ];
        
        if ( iWeaponId == CSW_KNIFE || iWeaponId == CSW_C4 )
        {
            continue;
        }
        
        g_sDisconnected[ iSlot ][ Disconnected_Weapons ][ iWeaponCount ] = iWeaponId;
        g_sDisconnected[ iSlot ][ Disconnected_WeaponClip ][ iWeaponCount ] = rg_get_user_ammo( iId, WeaponIdType:iWeaponId );
        g_sDisconnected[ iSlot ][ Disconnected_WeaponBpAmmo ][ iWeaponCount ] = rg_get_user_bpammo( iId, WeaponIdType:iWeaponId );
        iWeaponCount++;
    }
    
    g_sDisconnected[ iSlot ][ Disconnected_WeaponCount ] = iWeaponCount;
}

FindDisconnectedByAccId( const iAccId )
{
    for ( new i = 0; i < g_iDisconnectedCount; i++ )
    {
        if ( g_sDisconnected[ i ][ Disconnected_AccId ] == iAccId )
        {
            return i;
        }
    }
    
    return -1;
}

RemoveDisconnectedSlot( const iSlot )
{
    if ( iSlot < 0 || iSlot >= g_iDisconnectedCount )
    {
        return;
    }
    
    for ( new i = iSlot; i < g_iDisconnectedCount - 1; i++ )
    {
        g_sDisconnected[ i ][ Disconnected_AccId ] = g_sDisconnected[ i + 1 ][ Disconnected_AccId ];
        g_sDisconnected[ i ][ Disconnected_Team ] = g_sDisconnected[ i + 1 ][ Disconnected_Team ];
        g_sDisconnected[ i ][ Disconnected_Reconnects ] = g_sDisconnected[ i + 1 ][ Disconnected_Reconnects ];
        g_sDisconnected[ i ][ Disconnected_Kills ] = g_sDisconnected[ i + 1 ][ Disconnected_Kills ];
        g_sDisconnected[ i ][ Disconnected_Deaths ] = g_sDisconnected[ i + 1 ][ Disconnected_Deaths ];
        g_sDisconnected[ i ][ Disconnected_Assists ] = g_sDisconnected[ i + 1 ][ Disconnected_Assists ];
        g_sDisconnected[ i ][ Disconnected_Money ] = g_sDisconnected[ i + 1 ][ Disconnected_Money ];
        g_sDisconnected[ i ][ Disconnected_HasWeapons ] = g_sDisconnected[ i + 1 ][ Disconnected_HasWeapons ];
        g_sDisconnected[ i ][ Disconnected_WeaponCount ] = g_sDisconnected[ i + 1 ][ Disconnected_WeaponCount ];
        g_sDisconnected[ i ][ Disconnected_Armor ] = g_sDisconnected[ i + 1 ][ Disconnected_Armor ];
        g_sDisconnected[ i ][ Disconnected_ArmorType ] = g_sDisconnected[ i + 1 ][ Disconnected_ArmorType ];
        g_sDisconnected[ i ][ Disconnected_HasDefuser ] = g_sDisconnected[ i + 1 ][ Disconnected_HasDefuser ];
        g_sDisconnected[ i ][ Disconnected_IsCaptain ] = g_sDisconnected[ i + 1 ][ Disconnected_IsCaptain ];
        
        copy( g_sDisconnected[ i ][ Disconnected_Name ], charsmax( g_sDisconnected[ ][ Disconnected_Name ] ), g_sDisconnected[ i + 1 ][ Disconnected_Name ] );
        
        for ( new j = 0; j < g_sDisconnected[ i + 1 ][ Disconnected_WeaponCount ]; j++ )
        {
            g_sDisconnected[ i ][ Disconnected_Weapons ][ j ] = g_sDisconnected[ i + 1 ][ Disconnected_Weapons ][ j ];
            g_sDisconnected[ i ][ Disconnected_WeaponClip ][ j ] = g_sDisconnected[ i + 1 ][ Disconnected_WeaponClip ][ j ];
            g_sDisconnected[ i ][ Disconnected_WeaponBpAmmo ][ j ] = g_sDisconnected[ i + 1 ][ Disconnected_WeaponBpAmmo ][ j ];
        }
    }
    
    g_iDisconnectedCount--;
    
    new iLast = g_iDisconnectedCount;
    g_sDisconnected[ iLast ][ Disconnected_AccId ] = 0;
    g_sDisconnected[ iLast ][ Disconnected_Name ][ 0 ] = EOS;
    g_sDisconnected[ iLast ][ Disconnected_Team ] = MIX_TEAM_NONE;
    g_sDisconnected[ iLast ][ Disconnected_IsCaptain ] = false;
}

bool:HasDisconnectedPlayers( )
{
    return g_iDisconnectedCount > 0;
}

TeamName:GetBalancedTeamForWarmup( )
{
    new iTT = 0, iCT = 0;
    
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }
        
        new TeamName:iTeam = get_member( iPlayer, m_iTeam );
        
        if ( iTeam == TEAM_TERRORIST )
        {
            iTT++;
        }
        else if ( iTeam == TEAM_CT )
        {
            iCT++;
        }
    }
    
    if ( iTT <= iCT )
    {
        return TEAM_TERRORIST;
    }
    
    return TEAM_CT;
}

GetMissingPlayersCount( )
{
    if ( IsWebMatch( ) )
    {
        return g_iWebRosterCount - CountJoinedWebRosterSlots( );
    }

    /* Respaldo del flujo no web: conserva la capacidad maxima historica. */
    new iTeamA, iTeamB;

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }
        
        if ( g_sPlayers[ iPlayer ][ Player_Team ] == MIX_TEAM_A )
        {
            iTeamA++;
        }
        else if ( g_sPlayers[ iPlayer ][ Player_Team ] == MIX_TEAM_B )
        {
            iTeamB++;
        }
    }
    
    return ( MAX_SUPPORTED_TEAM_SIZE - iTeamA ) + ( MAX_SUPPORTED_TEAM_SIZE - iTeamB );
}

MovePlayersToTeams( const bool:bApplySwap )
{
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }
        
        new iTeam = g_sPlayers[ iPlayer ][ Player_Team ];
        
        if ( iTeam == MIX_TEAM_NONE )
        {
            rg_set_user_team( iPlayer, TEAM_SPECTATOR );
            
            continue;
        }
        
        if ( bApplySwap && g_sMatch[ Match_TeamsSwapped ] )
        {
            iTeam = ( iTeam == MIX_TEAM_A ) ? MIX_TEAM_B : MIX_TEAM_A;
        }
        
        if ( iTeam == MIX_TEAM_A )
        {
            rg_set_user_team( iPlayer, TEAM_TERRORIST );
        }
        else
        {
            rg_set_user_team( iPlayer, TEAM_CT );
        }
    }
}

StripToKnife( const iId )
{
    rg_remove_all_items( iId );
    rg_give_item( iId, "weapon_knife" );
}

public OnServerCommand_Cancel( )
{
    if ( g_iMixStatus == MIX_IDLE && !IsWebMatch( ) )
    {
        server_print( "[%s] No hay ninguna partida en curso.", g_szPrintPrefix );

        return PLUGIN_HANDLED;
    }

    server_print( "[%s] Cancelando la partida desde consola.", g_szPrintPrefix );

    CancelMix( );

    return PLUGIN_HANDLED;
}

CancelMix( )
{
    client_print_color( 0, print_team_default, "^4[%s]^1 El mix ha sido^4 cancelado^1.", g_szPrintPrefix );

    if ( IsWebMatch( ) )
    {
        new iRet;
        ExecuteForward( g_iFwdWebMatchCancel, iRet );
    }

    ResetMixState( );
    StartWarmup( );

    client_print_color( 0, print_team_default, "^4[%s]^1 Para jugar, ingresa a^4 zgaming.net/mix^1.", g_szPrintPrefix );
}

GetTeamPlayerCount( const iMixTeam )
{
    new iCount = 0;
    
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }
        
        if ( g_sPlayers[ iPlayer ][ Player_Team ] == iMixTeam )
        {
            iCount++;
        }
    }
    
    return iCount;
}

bool:IsTeamEmpty( const iMixTeam )
{
    return GetTeamPlayerCount( iMixTeam ) == 0;
}

bool:CheckTeamsValid( )
{
    if ( IsTeamEmpty( MIX_TEAM_A ) )
    {
        if ( HasDisconnectedPlayers( ) )
        {
            return true;
        }

        client_print_color( 0, print_team_default, "^4[%s]^1 El Equipo A quedo sin jugadores. MIX^4 cancelado^1.", g_szPrintPrefix );
        
        return false;
    }
    
    if ( IsTeamEmpty( MIX_TEAM_B ) )
    {
        if ( HasDisconnectedPlayers( ) )
        {
            return true;
        }

        client_print_color( 0, print_team_default, "^4[%s]^1 El Equipo B quedo sin jugadores. MIX^4 cancelado^1.", g_szPrintPrefix );
        
        return false;
    }
    
    return true;
}

GetCaptainForTeam( const iMixTeam )
{
    return ( iMixTeam == MIX_TEAM_A ) ? g_iCaptainA : g_iCaptainB;
}

TransferDisconnectedCaptaincy( )
{
    for ( new i = 0; i < g_iDisconnectedCount; i++ )
    {
        if ( !g_sDisconnected[ i ][ Disconnected_IsCaptain ] )
        {
            continue;
        }
        
        new iTeam = g_sDisconnected[ i ][ Disconnected_Team ];
        new iNewCaptain = 0;
        
        for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
        {
            if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
            {
                continue;
            }
            
            if ( g_sPlayers[ iPlayer ][ Player_Team ] == iTeam )
            {
                iNewCaptain = iPlayer;
                
                break;
            }
        }
        
        if ( iNewCaptain > 0 )
        {
            g_sPlayers[ iNewCaptain ][ Player_IsCaptain ] = true;
            
            if ( iTeam == MIX_TEAM_A )
            {
                g_iCaptainA = iNewCaptain;
            }
            else
            {
                g_iCaptainB = iNewCaptain;
            }
            
            client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 es el nuevo^4 capitan^1 del equipo^3 %s^1.", g_szPrintPrefix, g_sPlayers[ iNewCaptain ][ Player_Name ], g_sDisconnected[ i ][ Disconnected_Name ] );
            
            g_sDisconnected[ i ][ Disconnected_IsCaptain ] = false;
        }
    }
}

HandleDisconnectBeforeKnife( const iId )
{
    if ( GetPlayerBit( g_iIsReady, iId ) )
    {
        ClearPlayerBit( g_iIsReady, iId );

        g_iReadyCount--;
    }

    ResetPlayerData( iId );

    ReturnWebMatchToWarmup( );
}

HandleDisconnectDuringKnife( const iId )
{
    if ( g_sPlayers[ iId ][ Player_Team ] == MIX_TEAM_NONE )
    {
        ResetPlayerData( iId );
        
        return;
    }
    
    new szPlayerName[ MAX_NAME_LENGTH ];
    copy( szPlayerName, charsmax( szPlayerName ), g_sPlayers[ iId ][ Player_Name ] );

    AddDisconnectedPlayer( iId );
    
    g_sPlayers[ iId ][ Player_Team ] = MIX_TEAM_NONE;
    g_sPlayers[ iId ][ Player_IsCaptain ] = false;

    if ( GetPlayerBit( g_iIsReady, iId ) )
    {
        ClearPlayerBit( g_iIsReady, iId );
        g_iReadyCount--;
    }
    
    client_print_color( 0, print_team_default, "^4[%s]^1 El jugador^3 %s^1 abandono durante la ronda de cuchillos.", g_szPrintPrefix, szPlayerName );
    
    ResetPlayerData( iId );

    /* En 2v2 dos caídas dejan momentáneamente un equipo sin conexiones. Eso
     * no invalida el roster: primero se respeta la misma ventana de reconexión
     * de 120 s y recién su vencimiento abre los slots/surrender. */
    client_print_color( 0, print_team_default, "^4[%s]^1 Se esperara reconexion o se buscara^4 reemplazo^1 al terminar la ronda.", g_szPrintPrefix );
    
    StartReconnectTimeout( );
}

HandleDisconnectDuringMatch( const iId )
{
    if ( g_sPlayers[ iId ][ Player_Team ] == MIX_TEAM_NONE )
    {
        ResetPlayerData( iId );
        
        return;
    }
    
    if ( g_bPendingPause && g_iPendingPauseRequestor == iId )
    {
        g_bPendingPause = false;
        g_iPendingPauseRequestor = 0;
    }
    
    if ( is_user_alive( iId ) && rg_has_item_by_name( iId, "weapon_c4" ) )
    {
        rg_drop_item( iId, "weapon_c4" );
    }
    
    new szPlayerName[ MAX_NAME_LENGTH ];
    copy( szPlayerName, charsmax( szPlayerName ), g_sPlayers[ iId ][ Player_Name ] );
    
    new iPlayerReconnects = g_sPlayers[ iId ][ Player_Reconnects ];
    new iPlayerAccId = g_sPlayers[ iId ][ Player_AccId ];
    new iPlayerTeam = g_sPlayers[ iId ][ Player_Team ];
    
    AddDisconnectedPlayer( iId );
    
    g_sPlayers[ iId ][ Player_Team ] = MIX_TEAM_NONE;
    g_sPlayers[ iId ][ Player_IsCaptain ] = false;

    if ( GetPlayerBit( g_iIsReady, iId ) )
    {
        ClearPlayerBit( g_iIsReady, iId );
        g_iReadyCount--;
    }
    
    ResetPlayerData( iId );

    new bool:bCanReconnect = ( iPlayerReconnects < g_pCvar[ CVAR_MAX_RECONNECTS_PER_PLAYER ] );
    
    if ( !bCanReconnect )
    {
        client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 se desconecto (sin reconexiones). Slot^4 disponible^1 para espectadores.", g_szPrintPrefix, szPlayerName );
        
        new iSlot = FindDisconnectedByAccId( iPlayerAccId );
        
        if ( iSlot != -1 )
        {
            OpenWebRosterSlot( iPlayerAccId, g_sDisconnected[ iSlot ][ Disconnected_MatchDecided ] );

            RemoveDisconnectedSlot( iSlot );
        }
        
        return;
    }
    
    client_print_color( 0, print_team_default, "^4[%s]^1 El jugador^3 %s^1 se desconecto.", g_szPrintPrefix, szPlayerName );

    /* Durante halftime/OT no se toca la transicion. El unico restart arma la
     * fase nueva y, si corresponde, la pausa cae sobre ese mismo freezetime. */
    if ( g_bInPhaseBreak )
    {
        StartReconnectTimeout( );

        if ( !g_bAutoPauseUsed[ iPlayerTeam ] )
        {
            g_bAutoPauseUsed[ iPlayerTeam ] = true;
            g_bDisconnectDuringRound = true;

            client_print_color( 0, print_team_default, "^4[%s]^1 La fase nueva quedara^4 pausada^1 durante su freezetime.", g_szPrintPrefix );
        }
        else
        {
            client_print_color( 0, print_team_default, "^4[%s]^1 El equipo ya uso su pausa automatica. La fase comenzara normalmente.", g_szPrintPrefix );
        }

        return;
    }
    
    if ( g_bMatchPaused )
    {
        g_bAutoPauseUsed[ iPlayerTeam ] = true;
        
        StartReconnectTimeout( );
        
        return;
    }
    
    // Solo pausar automaticamente si el equipo no ha usado su pausa automatica
    new bool:bCanAutoPause = !g_bAutoPauseUsed[ iPlayerTeam ];

    new bool:bInFreezeTime = bool:( get_member_game( m_bFreezePeriod ) );
    
    if ( bInFreezeTime && bCanAutoPause )
    {
        g_bAutoPauseUsed[ iPlayerTeam ] = true;
        
        PauseMatch( 0, true );
        
        StartReconnectTimeout( );
    }
    else if ( bCanAutoPause )
    {
        g_bDisconnectDuringRound = true;
        g_bAutoPauseUsed[ iPlayerTeam ] = true;
        
        client_print_color( 0, print_team_default, "^4[%s]^1 La ronda continua. Se^4 pausara^1 en la siguiente ronda.", g_szPrintPrefix );
    }
    else
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 El equipo ya uso su pausa automatica. La partida continua.", g_szPrintPrefix );
        
        StartReconnectTimeout( );
    }
}

StartReconnectTimeout( )
{
    if ( task_exists( TASK_RECONNECT_TIMEOUT ) )
    {
        return;
    }
    
    g_iReconnectCountdown = floatround( g_pCvar[ CVAR_RECONNECT_TIME ] );
    
    set_task( 1.0, "OnTaskReconnectCountdown", TASK_RECONNECT_TIMEOUT, .flags = "a", .repeat = g_iReconnectCountdown );
    
    client_print_color( 0, print_team_default, "^4[%s]^1 Los jugadores desconectados tienen^4 %d^1 segundos para reconectar.", g_szPrintPrefix, g_iReconnectCountdown );
}

HandlePlayerReconnect( const iId, const bool:bAfterAbandon = false )
{
    new iSlot = FindDisconnectedByAccId( g_sPlayers[ iId ][ Player_AccId ] );
    
    if ( iSlot == -1 )
    {
        return false;
    }
    
    g_sPlayers[ iId ][ Player_Reconnects ] = g_sDisconnected[ iSlot ][ Disconnected_Reconnects ] + 1;
    g_sPlayers[ iId ][ Player_Kills ] = g_sDisconnected[ iSlot ][ Disconnected_Kills ];
    g_sPlayers[ iId ][ Player_Deaths ] = g_sDisconnected[ iSlot ][ Disconnected_Deaths ];
    g_sPlayers[ iId ][ Player_Assists ] = g_sDisconnected[ iSlot ][ Disconnected_Assists ];
    
    g_sPlayers[ iId ][ Player_Team ] = g_sDisconnected[ iSlot ][ Disconnected_Team ];
    g_sPlayers[ iId ][ Player_IsCaptain ] = g_sDisconnected[ iSlot ][ Disconnected_IsCaptain ];
    
    if ( g_sDisconnected[ iSlot ][ Disconnected_IsCaptain ] )
    {
        if ( g_sDisconnected[ iSlot ][ Disconnected_Team ] == MIX_TEAM_A )
        {
            g_iCaptainA = iId;
        }
        else
        {
            g_iCaptainB = iId;
        }
    }
    
    SetPlayerBit( g_iIsReady, iId );
    g_iReadyCount++;
    
    new iSavedMoney = g_sDisconnected[ iSlot ][ Disconnected_Money ];
    new bool:bHasWeapons = g_sDisconnected[ iSlot ][ Disconnected_HasWeapons ];
    new iSavedArmor = g_sDisconnected[ iSlot ][ Disconnected_Armor ];
    new iSavedArmorType = g_sDisconnected[ iSlot ][ Disconnected_ArmorType ];
    new bool:bHasDefuser = g_sDisconnected[ iSlot ][ Disconnected_HasDefuser ];
    new iWeaponCount = g_sDisconnected[ iSlot ][ Disconnected_WeaponCount ];
    new iWeapons[ 32 ], iWeaponClip[ 32 ], iWeaponBpAmmo[ 32 ];
    
    for ( new i = 0; i < iWeaponCount; i++ )
    {
        iWeapons[ i ] = g_sDisconnected[ iSlot ][ Disconnected_Weapons ][ i ];
        iWeaponClip[ i ] = g_sDisconnected[ iSlot ][ Disconnected_WeaponClip ][ i ];
        iWeaponBpAmmo[ i ] = g_sDisconnected[ iSlot ][ Disconnected_WeaponBpAmmo ][ i ];
    }

    new TeamName:iGameTeam = GetGameTeamForMixTeam( g_sDisconnected[ iSlot ][ Disconnected_Team ] );
    rg_join_team( iId, iGameTeam );

    g_iReconnectFrags[ iId ] = g_sDisconnected[ iSlot ][ Disconnected_Frags ];
    g_iReconnectScoreDeaths[ iId ] = g_sDisconnected[ iSlot ][ Disconnected_ScoreDeaths ];
    RestoreScoreboard( iId );
    /* El join nativo puede aplicar temporalmente mp_startmoney antes de que
     * corra el restore diferido. Restaurar aqui evita que el jugador reaparezca
     * con el dinero del warmup, y el task de abajo vuelve a blindar el equipo
     * contra cualquier callback de spawn posterior. */
    rg_add_account( iId, iSavedMoney, AS_SET );
    NotifyWebPlayerJoined( iId );
    
    if ( !bAfterAbandon )
    {
        new iReconnectsLeft = g_pCvar[ CVAR_MAX_RECONNECTS_PER_PLAYER ] - g_sPlayers[ iId ][ Player_Reconnects ];

        client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 ha^4 reconectado^1. Reconexiones restantes:^4 %d", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ], iReconnectsLeft );
    }
    
    RemoveDisconnectedSlot( iSlot );
    
    set_task( 0.5, "OnTaskRestorePlayerEquipment", iId );
    
    SetPlayerReconnectData( iId, iSavedMoney, bHasWeapons, iSavedArmor, iSavedArmorType, bHasDefuser, iWeapons, iWeaponClip, iWeaponBpAmmo, iWeaponCount );
    
    if ( !HasDisconnectedPlayers( ) )
    {
        remove_task( TASK_RECONNECT_TIMEOUT );
        
        // Cerrar menu de rendicion si esta activo
        if ( g_iSurrenderCaptain > 0 )
        {
            remove_task( TASK_SURRENDER_COUNTDOWN );
            
            if ( GetPlayerBit( g_iIsConnected, g_iSurrenderCaptain ) )
            {
                show_menu( g_iSurrenderCaptain, 0, "" );
            }
            
            g_iSurrenderCaptain = 0;
            
            client_print_color( 0, print_team_default, "^4[%s]^1 Todos los jugadores reconectaron. Partida^4 continua^1.", g_szPrintPrefix );
        }
        else if ( g_bMatchPaused )
        {
            UnpauseMatch( 0 );
        }
    }
    
    return true;
}

TeamName:GetGameTeamForMixTeam( const iMixTeam )
{
    new iTeam = iMixTeam;
    
    if ( g_sMatch[ Match_TeamsSwapped ] )
    {
        iTeam = ( iTeam == MIX_TEAM_A ) ? MIX_TEAM_B : MIX_TEAM_A;
    }
    
    return ( iTeam == MIX_TEAM_A ) ? TEAM_TERRORIST : TEAM_CT;
}

SetPlayerReconnectData( const iId, const iMoney, const bool:bHasWeapons, const iArmor, const iArmorType, const bool:bHasDefuser, const iWeapons[ 32 ], const iWeaponClip[ 32 ], const iWeaponBpAmmo[ 32 ], const iWeaponCount )
{
    g_iReconnectMoney[ iId ] = iMoney;
    g_bReconnectHasWeapons[ iId ] = bHasWeapons;
    g_iReconnectArmor[ iId ] = iArmor;
    g_iReconnectArmorType[ iId ] = iArmorType;
    g_bReconnectHasDefuser[ iId ] = bHasDefuser;
    g_iReconnectWeaponCount[ iId ] = iWeaponCount;
    
    for ( new i = 0; i < iWeaponCount; i++ )
    {
        g_iReconnectWeapons[ iId ][ i ] = iWeapons[ i ];
        g_iReconnectWeaponClip[ iId ][ i ] = iWeaponClip[ i ];
        g_iReconnectWeaponBpAmmo[ iId ][ i ] = iWeaponBpAmmo[ i ];
    }
}

/* Vuelve a poner kills y muertes en el TAB y se lo avisa a todos. Sin esto el
 * que reconectaba aparecía en 0 aunque sus números siguieran contando para la web. */
RestoreScoreboard( const iId )
{
    if ( g_iReconnectFrags[ iId ] < 0 || !GetPlayerBit( g_iIsConnected, iId ) )
    {
        return;
    }

    set_entvar( iId, var_frags, float( g_iReconnectFrags[ iId ] ) );
    set_member( iId, m_iDeaths, g_iReconnectScoreDeaths[ iId ] );

    // AddPoints con 0 no cambia nada y manda el ScoreInfo actualizado a todos.
    ExecuteHamB( Ham_AddPoints, iId, 0, true );
}

public OnTaskRestorePlayerEquipment( iId )
{
    if ( !GetPlayerBit( g_iIsConnected, iId ) )
    {
        return;
    }

    // El join y el spawn pueden pisar el TAB: se reafirma antes de soltar los datos.
    RestoreScoreboard( iId );

    rg_add_account( iId, g_iReconnectMoney[ iId ], AS_SET );
    
    if ( g_bReconnectHasWeapons[ iId ] && is_user_alive( iId ) )
    {
        rg_remove_all_items( iId );
        rg_give_item( iId, "weapon_knife" );
        
        for ( new i = 0; i < g_iReconnectWeaponCount[ iId ]; i++ )
        {
            new iWeaponId = g_iReconnectWeapons[ iId ][ i ];
            new szWeaponName[ 32 ];
            
            rg_get_weapon_info( WeaponIdType:iWeaponId, WI_NAME, szWeaponName, charsmax( szWeaponName ) );
            
            if ( szWeaponName[ 0 ] != EOS )
            {
                rg_give_item( iId, szWeaponName );
                rg_set_user_ammo( iId, WeaponIdType:iWeaponId, g_iReconnectWeaponClip[ iId ][ i ] );
                rg_set_user_bpammo( iId, WeaponIdType:iWeaponId, g_iReconnectWeaponBpAmmo[ iId ][ i ] );
            }
        }
        
        if ( g_iReconnectArmorType[ iId ] > 0 )
        {
            rg_set_user_armor( iId, g_iReconnectArmor[ iId ], ArmorType:g_iReconnectArmorType[ iId ] );
        }
        
        if ( g_bReconnectHasDefuser[ iId ] )
        {
            set_member( iId, m_bHasDefuser, true );
        }
    }
    
    new iRoundTime = get_member_game( m_iRoundTimeSecs );
    SendRoundTime( iId, iRoundTime );
    
    g_iReconnectMoney[ iId ] = 0;
    g_iReconnectFrags[ iId ] = -1;
    g_bReconnectHasWeapons[ iId ] = false;
    g_iReconnectArmor[ iId ] = 0;
    g_iReconnectArmorType[ iId ] = 0;
    g_iReconnectWeaponCount[ iId ] = 0;
    g_bReconnectHasDefuser[ iId ] = false;
}

/* =================================================================================
* 				[ Pause System ]
* ================================================================================= */

public ClientCommand_Pause( iId )
{
    if ( !GetPlayerBit( g_iIsConnected, iId ) )
    {
        return PLUGIN_HANDLED;
    }
    
    if ( g_iMixStatus != MIX_LIVE && g_iMixStatus != MIX_OVERTIME )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 Solo puedes pausar durante una^4 partida en curso^1.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    if ( g_bMatchPaused )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 La partida ya esta^4 pausada^1.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    new iPlayerTeam = g_sPlayers[ iId ][ Player_Team ];
    
    if ( iPlayerTeam == MIX_TEAM_NONE )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 Solo los jugadores pueden pausar.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    if ( g_iPausesUsed[ iPlayerTeam ] >= g_pCvar[ CVAR_MAX_PAUSES_PER_TEAM ] )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 Tu equipo ya uso todas sus^4 pausas^1 (%d/%d).", g_szPrintPrefix, g_iPausesUsed[ iPlayerTeam ], g_pCvar[ CVAR_MAX_PAUSES_PER_TEAM ] );
        
        return PLUGIN_HANDLED;
    }
    
    if ( g_bPendingPause )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 Ya hay una pausa^4 pendiente^1.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    new bool:bInFreezeTime = bool:( get_member_game( m_bFreezePeriod ) );
    
    if ( !bInFreezeTime )
    {
        g_bPendingPause = true;
        g_iPendingPauseRequestor = iId;
        g_iPausesUsed[ iPlayerTeam ]++;
        g_iPauseTeam = iPlayerTeam;
        
        client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 solicito pausa. Se aplicara en el^4 siguiente freezetime^1.", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ] );
        
        return PLUGIN_HANDLED;
    }
    
    g_iPausesUsed[ iPlayerTeam ]++;
    g_iPauseTeam = iPlayerTeam;
    
    PauseMatch( iId, false );
    
    return PLUGIN_HANDLED;
}

public ClientCommand_Unpause( iId )
{
    if ( !GetPlayerBit( g_iIsConnected, iId ) )
    {
        return PLUGIN_HANDLED;
    }
    
    if ( !g_bMatchPaused )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 La partida no esta^4 pausada^1.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    new iPlayerTeam = g_sPlayers[ iId ][ Player_Team ];
    
    if ( iPlayerTeam == MIX_TEAM_NONE )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 Solo los jugadores pueden despausar.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    if ( HasDisconnectedPlayers( ) )
    {
        new iDisconnectedTeam = GetDisconnectedTeam( );
        new iTeamCaptain = GetCaptainForTeam( iDisconnectedTeam );
        
        if ( iId != iTeamCaptain )
        {
            client_print_color( iId, print_team_default, "^4[%s]^1 Solo el^4 capitan^1 del equipo con jugador desconectado puede despausar.", g_szPrintPrefix );
            
            return PLUGIN_HANDLED;
        }
    }
    else if ( g_iPauseTeam != MIX_TEAM_NONE && iPlayerTeam != g_iPauseTeam )
    {
        client_print_color( iId, print_team_default, "^4[%s]^1 Solo el equipo que pauso puede^4 despausar^1.", g_szPrintPrefix );
        
        return PLUGIN_HANDLED;
    }
    
    UnpauseMatch( iId );
    
    return PLUGIN_HANDLED;
}

UpdateRoundTimer( const iTime )
{
    new Float:flGametime = get_gametime( );
    
    set_member_game( m_iRoundTimeSecs, iTime );
    /* ReGameDLL mantiene dos relojes: el visible/freezetime y el reloj real
     * que usan sus stocks de tiempo restante. Dejarlos distintos durante una
     * pausa hace que cada ruta vea una ronda diferente. */
    set_member_game( m_fRoundStartTime, flGametime );
    set_member_game( m_fRoundStartTimeReal, flGametime );
    
    SendRoundTime( 0, iTime );
}

/**
* Aplica a cada jugador el congelamiento que corresponde al estado actual.
*
* Poner `m_bFreezePeriod` no congela a nadie por si solo. En CS la quietud del
* freezetime no es la bandera FL_FROZEN: es la velocidad maxima, que fija
* `CBasePlayer::ResetMaxSpeed` leyendo si estamos en freezetime. Se ve en el
* propio ReGameDLL: al terminar el freezetime, `OnRoundFreezeEnd` no limpia
* ningun flag, recorre a los jugadores y les llama `ResetMaxSpeed()`. Si eso
* los suelta, es porque eso mismo es lo que los tiene quietos.
*
* Como esa funcion solo corre cuando algo la dispara —cambiar de arma, morir,
* spawnear—, pausar sin llamarla dejaba pegado al que justo hiciera algo y
* suelto al que no tocara nada. De ahi el "a unos nos dejo pegados y a otro lo
* dejo moverse".
*
* Sirve para las dos puntas: con la bandera puesta congela, y con la bandera
* quitada devuelve la velocidad que toque segun el arma que lleve encima.
*/
ApplyFreezeStateToAll( )
{
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }

        // Los muertos y los espectadores no tienen velocidad que fijar, y
        // ReGameDLL ya los saltea en su propio recorrido del fin de freezetime.
        if ( !is_user_alive( iPlayer ) )
        {
            continue;
        }

        rg_reset_maxspeed( iPlayer );
    }
}

SavePauseEconomy( )
{
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }

        g_iPauseMoney[ iPlayer ] = get_member( iPlayer, m_iAccount );
        g_bPauseMoneySaved[ iPlayer ] = true;
    }
}

RestorePauseEconomy( )
{
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( g_bPauseMoneySaved[ iPlayer ] && GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            rg_add_account( iPlayer, g_iPauseMoney[ iPlayer ], AS_SET );
        }

        g_iPauseMoney[ iPlayer ] = 0;
        g_bPauseMoneySaved[ iPlayer ] = false;
    }
}

PauseMatch( const iRequestor, const bool:bAutomatic )
{
    if ( g_bMatchPaused )
    {
        return;
    }

    SavePauseEconomy( );

    g_bMatchPaused = true;
    g_iStatusBeforePause = g_iMixStatus;
    g_iMixStatus = MIX_PAUSED;
    g_iPauseCountdown = floatround( g_pCvar[ CVAR_PAUSE_DURATION ] );

    /* Guardar lo que le quedaba al freezetime antes de pisarlo con la cuenta
     * atras de la pausa. La guarda por si algun dia se llama con la ronda ya
     * corriendo: ahi no hay freezetime que devolver. */
    g_bResumeFreezeTime = bool:get_member_game( m_bFreezePeriod );

    if ( g_bResumeFreezeTime )
    {
        g_flFreezeTimeLeft = float( get_member_game( m_iRoundTimeSecs ) )
            - get_gametime( )
            + Float:get_member_game( m_fRoundStartTime );

        if ( g_flFreezeTimeLeft < 0.0 )
        {
            g_flFreezeTimeLeft = 0.0;
        }
    }

    set_member_game( m_bFreezePeriod, true );

    // Despues de la bandera, nunca antes: ResetMaxSpeed la lee para decidir.
    ApplyFreezeStateToAll( );
    g_flSavedBuytime = get_cvar_float( "mp_buytime" );
    set_cvar_num( "mp_buytime", -1 );
    
    UpdateRoundTimer( g_iPauseCountdown );
    
    if ( bAutomatic )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Partida^4 pausada automaticamente^1.", g_szPrintPrefix );
    }
    else
    {
        new iPausesLeft = g_pCvar[ CVAR_MAX_PAUSES_PER_TEAM ] - g_iPausesUsed[ g_sPlayers[ iRequestor ][ Player_Team ] ];
        
        client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 pauso la partida. Pausas restantes:^4 %d^1.", g_szPrintPrefix, g_sPlayers[ iRequestor ][ Player_Name ], iPausesLeft );
    }
    
    remove_task( TASK_PAUSE_COUNTDOWN );
    set_task( 1.0, "OnTaskPauseCountdown", TASK_PAUSE_COUNTDOWN, .flags = "b" );
}

UnpauseMatch( const iRequestor )
{
    remove_task( TASK_PAUSE_COUNTDOWN );
    
    g_bMatchPaused = false;
    g_iMixStatus = g_iStatusBeforePause;
    g_iPauseTeam = MIX_TEAM_NONE;
    
    if ( iRequestor > 0 )
    {
        client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 reanudo la partida.", g_szPrintPrefix, g_sPlayers[ iRequestor ][ Player_Name ] );
    }
    else
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Partida^4 reanudada^1.", g_szPrintPrefix );
    }
    
    set_cvar_float( "mp_buytime", g_flSavedBuytime );
    RestorePauseEconomy( );

    /* La ronda ya fue creada por el restart natural. Reanudar significa soltar
     * ese mismo freezetime, no respawnear otra vez ni recalcular economia. */
    new iFreeze = g_pCvar[ CVAR_FREEZETIME ];

    if ( g_bResumeFreezeTime )
    {
        /* La pausa cayo dentro del freezetime: se devuelve lo que quedaba, no
         * uno nuevo. Si no, cada pausa alargaba la previa de la ronda y daba la
         * sensacion de que la ronda volvia a empezar. */
        g_bResumeFreezeTime = false;

        iFreeze = floatround( g_flFreezeTimeLeft, floatround_ceil );

        /* Nunca cero: hace falta un tramo de freezetime para que el motor lo
         * cierre y suelte a todo el roster a la vez. */
        if ( iFreeze < 1 )
        {
            iFreeze = 1;
        }
    }

    set_member_game( m_bFreezePeriod, true );
    set_member_game( m_iIntroRoundTime, iFreeze );
    UpdateRoundTimer( iFreeze );

    /* Reanudar deja unos segundos de freezetime de cortesia, y esos segundos
     * tienen que valer para todo el roster. Sin esto quedaban quietos solo los que ya
     * lo estaban, y el resto arrancaba antes: peor que la pausa despareja,
     * porque es ventaja justo al volver el juego.
     *
     * A todos los suelta despues el motor a la vez, cuando el freezetime
     * expira y `OnRoundFreezeEnd` les llama `ResetMaxSpeed()` a todos. */
    ApplyFreezeStateToAll( );
}

ResumeMatchForSurrender( )
{
    remove_task( TASK_PAUSE_COUNTDOWN );

    g_bMatchPaused = false;
    g_iMixStatus = g_iStatusBeforePause;
    g_iPauseTeam = MIX_TEAM_NONE;
    g_bResumeFreezeTime = false;
    g_flFreezeTimeLeft = 0.0;

    set_cvar_float( "mp_buytime", g_flSavedBuytime );
    RestorePauseEconomy( );

    /* El timeout ya resolvio la espera: se libera el freeze actual una sola
     * vez y la ronda continua desde ese momento. No se llama RestartRound() ni
     * se deja que OnRoundFreezeEnd() vuelva a encender otro freezetime. */
    set_member_game( m_bFreezePeriod, false );

    new iRoundTime = get_member_game( m_iRoundTime );

    if ( iRoundTime < 1 )
    {
        iRoundTime = 1;
    }

    UpdateRoundTimer( iRoundTime );

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) || !is_user_alive( iPlayer ) )
        {
            continue;
        }

        rg_reset_maxspeed( iPlayer );
        set_member( iPlayer, m_bCanShoot, true );
    }
}

public OnTaskPauseCountdown( )
{
    g_iPauseCountdown--;
    
    UpdateRoundTimer( g_iPauseCountdown );
    
    if ( g_iPauseCountdown <= 0 )
    {
        remove_task( TASK_PAUSE_COUNTDOWN );
        
        /* La pausa tecnica dura 30 s, pero el plazo de reconexion conserva sus
         * 120 s. Se sigue con el roster incompleto mientras el contador corre. */
        if ( HasDisconnectedPlayers( ) )
        {
            client_print_color( 0, print_team_default, "^4[%s]^1 Pausa tecnica finalizada. La partida continua mientras corre el plazo de reconexion.", g_szPrintPrefix );

            UnpauseMatch( 0 );
        }
        else
        {
            client_print_color( 0, print_team_default, "^4[%s]^1 Tiempo de pausa agotado. Reanudando partida.", g_szPrintPrefix );
            
            UnpauseMatch( 0 );
        }
        
        return;
    }
    
    if ( g_iPauseCountdown % 30 == 0 )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Pausa activa. Tiempo restante:^4 %d^1 segundos.", g_szPrintPrefix, g_iPauseCountdown );
    }
}

public OnTaskApplyPendingPause( )
{
    if ( g_bMatchPaused )
    {
        g_iPendingPauseRequestor = 0;

        return;
    }

    if ( !GetPlayerBit( g_iIsConnected, g_iPendingPauseRequestor ) )
    {
        g_iPendingPauseRequestor = 0;
        
        return;
    }
    
    PauseMatch( g_iPendingPauseRequestor, false );
    
    g_iPendingPauseRequestor = 0;
}

/* =================================================================================
* 				[ Tasks ]
* ================================================================================= */

public OnTaskShowWelcome( iId )
{
    if ( !GetPlayerBit( g_iIsConnected, iId ) )
    {
        return;
    }

    client_print_color( iId, print_team_default, "^4[%s]^1 Estado: ^3.status", g_szPrintPrefix );
}

public OnTaskCheckFillAfterRound( )
{
    /* Solo se pausa si hay alguien a quien esperar de verdad.
     *
     * GetMissingPlayersCount mide "al equipo le falta gente", y eso sigue
     * siendo cierto para siempre despues de un abandono: si alguien se fue en
     * la ronda 3, vencio su plazo y el capitan decidio seguir con uno menos,
     * queda corto hasta el final.
     *
     * Sin esta guarda, cada fin de ronda y sobre todo el cambio de mitad
     * volvian a pausar la partida y a abrir otros 120 segundos de espera por
     * alguien que se fue hace veinte minutos y cuyo caso ya se resolvio.
     *
     * HasDisconnectedPlayers mide lo que corresponde: si hay alguien pendiente
     * de volver. */
    if ( !HasDisconnectedPlayers( ) )
    {
        return;
    }

    if ( GetMissingPlayersCount( ) == 0 )
    {
        return;
    }

    if ( !g_bMatchPaused )
    {
        PauseMatch( 0, true );

        StartReconnectTimeout( );
    }
}

public OnTaskResetPhaseFlag( )
{
    g_bFirstRoundAfterPhase = false;
}

public OnTaskStartKnifeRound( )
{
    if ( !CheckTeamsValid( ) )
    {
        ReturnWebMatchToWarmup( );

        return;
    }
    
    g_iMixStatus = MIX_KNIFE_ROUND;
    g_bKnifeRoundActive = true;
    
    MovePlayersToTeams( false );

    /* El calentamiento no puede ensuciar el scoreboard del knife. Antes se
     * limpiaba recien al pasar a LIVE, asi que el cuchillo mostraba las
     * kills/deaths acumuladas durante la espera. */
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }

        set_entvar( iPlayer, var_frags, 0.0 );
        set_member( iPlayer, m_iDeaths, 0 );
    }
    
    set_cvar_float( "mp_roundtime", 2.0 );
    set_cvar_num( "mp_buytime", 0 );
    
    client_print_color( 0, print_team_default, "^4[%s]^1 *** KNIFE ROUND ***", g_szPrintPrefix );
    client_print_color( 0, print_team_default, "^4[%s]^1 Equipo^4 %s^1 vs Equipo^4 %s^1.", g_szPrintPrefix, g_sPlayers[ g_iCaptainA ][ Player_Name ], g_sPlayers[ g_iCaptainB ][ Player_Name ] );
    
    rg_restart_round( );
}

public OnTaskShowSideMenu( )
{
    if ( !CheckTeamsValid( ) )
    {
        CancelMix( );
        
        return;
    }

    new iCaptain = GetCaptainForTeam( g_iKnifeWinner );

    if ( !GetPlayerBit( g_iIsConnected, iCaptain ) )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 El capitan no esta disponible. Seleccion^4 automatica^1.", g_szPrintPrefix );
        
        SelectSide( random( 2 ) + 1 );
        
        return;
    }

    g_iSideCountdown = 15;
    
    ShowSideMenu( iCaptain );
    
    set_task( 1.0, "OnTaskSideCountdown", TASK_SIDE_COUNTDOWN, .flags = "a", .repeat = g_iSideCountdown );
    
    client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 esta eligiendo lado...", g_szPrintPrefix, g_sPlayers[ iCaptain ][ Player_Name ] );
}

public OnTaskSideCountdown( )
{
    g_iSideCountdown--;

    if ( !CheckTeamsValid( ) )
    {
        remove_task( TASK_SIDE_COUNTDOWN );
        
        CancelMix( );
        
        return;
    }
    
    new iWinnerCaptain = GetCaptainForTeam( g_iKnifeWinner );
    
    if ( g_iSideCountdown <= 0 )
    {
        remove_task( TASK_SIDE_COUNTDOWN );
        
        client_print_color( 0, print_team_default, "^4[%s]^1 Tiempo agotado. Seleccion^4 automatica^1.", g_szPrintPrefix );
        
        if ( GetPlayerBit( g_iIsConnected, iWinnerCaptain ) )
        {
            show_menu( iWinnerCaptain, 0, "" );
        }

        SelectSide( random( 2 ) + 1 );

        return;
    }

    if ( !GetPlayerBit( g_iIsConnected, iWinnerCaptain ) )
    {
        return;
    }

    ShowSideMenu( iWinnerCaptain );
}

public OnTaskLiveCountdown( )
{
    g_iLiveCountdown--;
    
    if ( GetMissingPlayersCount( ) > 0 )
    {
        remove_task( TASK_LIVE_COUNTDOWN );
        
        client_print_color( 0, print_team_default, "^4[%s]^1 Jugador desconectado durante countdown. Esperando...", g_szPrintPrefix );
        
        StartReconnectTimeout( );
        
        return;
    }
    
    if ( g_iLiveCountdown > 0 )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 La partida comienza en ^4%d", g_szPrintPrefix, g_iLiveCountdown );
    }
    else
    {
        remove_task( TASK_LIVE_COUNTDOWN );
        
        client_print_color( 0, print_team_default, "^4[%s]^1 *** LIVE LIVE LIVE ***", g_szPrintPrefix );
        client_print_color( 0, print_team_default, "^4[%s]^1 *** LIVE LIVE LIVE ***", g_szPrintPrefix );
        client_print_color( 0, print_team_default, "^4[%s]^1 *** LIVE LIVE LIVE ***", g_szPrintPrefix );
        
        rg_restart_round( );
    }
}

StartPhaseBreak( const iTransition )
{
    if ( iTransition <= PHASE_TRANSITION_NONE || iTransition > PHASE_TRANSITION_OVERTIME_HALF || g_bInPhaseBreak )
    {
        return;
    }

    g_iPhaseTransition = iTransition;
    g_iPhaseBreakCountdown = g_pCvar[ CVAR_HALFTIME_BREAK ];
    g_bInPhaseBreak = true;
    g_iMixStatus = MIX_HALFTIME;

    // Igual que CS2: durante todo el descanso ambos equipos pueden hablar.
    set_cvar_num( "sv_alltalk", 1 );

    switch ( iTransition )
    {
        case PHASE_TRANSITION_REGULATION_HALF:
        {
            client_print_color( 0, print_team_default, "^4[%s]^1 ========== MEDIO TIEMPO ==========", g_szPrintPrefix );
            client_print_color( 0, print_team_default, "^4[%s]^1 Cambio de lado en^4 %d^1 segundos. Microfonos^4 habilitados^1.", g_szPrintPrefix, g_iPhaseBreakCountdown );
        }
        case PHASE_TRANSITION_OVERTIME_START:
        {
            client_print_color( 0, print_team_default, "^4[%s]^1 ========== DESCANSO ==========", g_szPrintPrefix );
            client_print_color( 0, print_team_default, "^4[%s]^1 Overtime^4 %d^1 comienza en^4 %d^1 segundos. Microfonos^4 habilitados^1.",
                g_szPrintPrefix, g_sMatch[ Match_Overtime ] + 1, g_iPhaseBreakCountdown );
        }
        case PHASE_TRANSITION_OVERTIME_HALF:
        {
            client_print_color( 0, print_team_default, "^4[%s]^1 ========== DESCANSO OVERTIME ==========", g_szPrintPrefix );
            client_print_color( 0, print_team_default, "^4[%s]^1 Cambio de lado en^4 %d^1 segundos. Microfonos^4 habilitados^1.", g_szPrintPrefix, g_iPhaseBreakCountdown );
        }
    }

    ShowScore( );

    remove_task( TASK_PHASE_BREAK );
    set_task( 1.0, "OnTaskPhaseBreak", TASK_PHASE_BREAK, .flags = "b" );
}

public OnTaskPhaseBreak( )
{
    g_iPhaseBreakCountdown--;

    if ( g_iPhaseBreakCountdown <= 0 )
    {
        /* El motor ejecuta ahora su unico RestartRound. La transicion real se
         * aplica en OnRestartRound_Pre, justo antes del respawn. */
        remove_task( TASK_PHASE_BREAK );

        return;
    }

    if ( g_iPhaseBreakCountdown != 10 && g_iPhaseBreakCountdown > 5 )
    {
        return;
    }

    if ( g_iPhaseTransition == PHASE_TRANSITION_OVERTIME_START )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Overtime^4 %d^1 comienza en^4 %d^1 segundos.",
            g_szPrintPrefix, g_sMatch[ Match_Overtime ] + 1, g_iPhaseBreakCountdown );
    }
    else
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Cambio de lado en^4 %d^1 segundos.", g_szPrintPrefix, g_iPhaseBreakCountdown );
    }
}

bool:ApplyPhaseTransition( )
{
    remove_task( TASK_PHASE_BREAK );

    if ( !CheckTeamsValid( ) )
    {
        g_bInPhaseBreak = false;
        g_iPhaseTransition = PHASE_TRANSITION_NONE;

        CancelMix( );

        return false;
    }

    new iTransition = g_iPhaseTransition;

    g_bInPhaseBreak = false;
    g_iPhaseTransition = PHASE_TRANSITION_NONE;
    g_iPhaseBreakCountdown = 0;

    // Se cierran los microfonos cruzados exactamente cuando empieza la fase.
    set_cvar_num( "sv_alltalk", 2 );

    switch ( iTransition )
    {
        case PHASE_TRANSITION_REGULATION_HALF:
        {
            new bool:bRegulationSwapped = g_sMatch[ Match_TeamsSwapped ];

            g_iMixStatus = MIX_LIVE;
            g_sMatch[ Match_Half ] = 2;
            g_sMatch[ Match_TeamsSwapped ] = !bRegulationSwapped;
            g_bFirstRoundAfterPhase = true;

            rg_swap_all_players( );

            client_print_color( 0, print_team_default, "^4[%s]^1 Lados intercambiados. Segunda mitad^4 LIVE^1.", g_szPrintPrefix );
        }
        case PHASE_TRANSITION_OVERTIME_START:
        {
            g_iMixStatus = MIX_OVERTIME;
            g_sMatch[ Match_Overtime ]++;
            g_sMatch[ Match_Half ] = 1;
            g_iOvertimeScoreA = 0;
            g_iOvertimeScoreB = 0;
            g_bFirstRoundAfterPhase = true;

            client_print_color( 0, print_team_default, "^4[%s]^1 ========== OVERTIME %d ==========", g_szPrintPrefix, g_sMatch[ Match_Overtime ] );
            client_print_color( 0, print_team_default, "^4[%s]^1 Dinero inicial:^4 $%d^1 | Formato:^4 MR%d^1.",
                g_szPrintPrefix, g_pCvar[ CVAR_OVERTIME_START_MONEY ], g_pCvar[ CVAR_ROUNDS_OVERTIME ] );
        }
        case PHASE_TRANSITION_OVERTIME_HALF:
        {
            new bool:bOvertimeSwapped = g_sMatch[ Match_TeamsSwapped ];

            g_iMixStatus = MIX_OVERTIME;
            g_sMatch[ Match_Half ] = 2;
            g_sMatch[ Match_TeamsSwapped ] = !bOvertimeSwapped;
            g_bFirstRoundAfterPhase = true;

            rg_swap_all_players( );

            client_print_color( 0, print_team_default, "^4[%s]^1 Lados intercambiados. Segunda mitad de overtime^4 LIVE^1. Dinero:^4 $%d^1.",
                g_szPrintPrefix, g_pCvar[ CVAR_OVERTIME_START_MONEY ] );
        }
    }

    /* El score del TAB sigue al equipo web despues del swap, no a la columna
     * fisica que ocupaba antes. A esta altura el motor ya sumo la ultima ronda. */
    SyncTeamScores( );
    NotifyWebScore( );

    return true;
}

/**
* Anota como abandono a quien no estaba cuando termino la partida.
*
* `NotifyWebPlayersLeft` solo corre cuando vence la cuenta de reconexion, asi
* que quien se iba faltando poco nunca quedaba marcado: seguia en el roster y
* cobraba el ELO del ganador como si hubiera jugado los treinta rounds. Paso en
* la partida 8.
*
* Repetir el aviso no hace dano: MixPlayerAbandoned solo escribe si
* abandoned_at seguia en NULL, asi que a quien ya se le conto no se le cuenta
* de nuevo ni se le aplica dos veces el castigo.
*/
NotifyWebAbsentAtEnd( )
{
    if ( !IsWebMatch( ) )
    {
        return;
    }

    for ( new i = 0; i < g_iWebRosterCount; i++ )
    {
        new iAccId = g_iWebRosterAccId[ i ];

        if ( iAccId <= 0 || FindPlayerByAccId( iAccId ) )
        {
            continue;
        }

        /* Irse con la partida ya sentenciada no es abandonar.
         *
         * Es el caso comun: quedan cuatro muertos y uno solo contra cinco, ya
         * no hay vuelta, y la gente se sale. Esos se llevan la derrota como el
         * resto del equipo, sin castigo encima. El dato se anoto cuando se
         * fueron, porque aca el marcador siempre esta sentenciado. */
        new iSlot = FindDisconnectedByAccId( iAccId );

        if ( iSlot != -1 && g_sDisconnected[ iSlot ][ Disconnected_MatchDecided ] )
        {
            continue;
        }

        new iRet;
        ExecuteForward( g_iFwdWebPlayerLeft, iRet, iAccId );
    }
}

FinishMatch( )
{
    if ( g_iMixStatus == MIX_FINISHED )
    {
        return;
    }

    FlushWebRound( );

    g_iMixStatus = MIX_FINISHED;

    /* Dejar el TAB en el resultado de verdad.
     *
     * La ronda que decide la partida se cuenta en el mod y no en el motor: en
     * `OnRoundEnd_Pre` se supercede el RoundEnd para que no programe su restart
     * con el delay normal, y de paso se pierde el `m_iNumTerroristWins++` que
     * vive ahi. El anuncio y la web decian 16, y el scoreboard se quedaba en 15
     * —siempre uno menos, y siempre al ganador—.
     *
     * Va antes de todo lo demas para que el marcador ya este bien cuando salga
     * el mensaje del ganador. */
    SyncTeamScores( );

    // Antes del reporte: el ELO se reparte ahi, y quien no esta no cobra.
    NotifyWebAbsentAtEnd( );

    new iRet;
    ExecuteForward( g_iFwdWebMatchEnd, iRet, g_sMatch[ Match_ScoreA ], g_sMatch[ Match_ScoreB ] );

    set_cvar_num( "sv_alltalk", 1 );

    new szWinnerTeam[ MAX_NAME_LENGTH ], szLoserTeam[ MAX_NAME_LENGTH ];

    if ( g_sMatch[ Match_ScoreA ] > g_sMatch[ Match_ScoreB ] )
    {
        copy( szWinnerTeam, charsmax( szWinnerTeam ), g_szTeamNameA );
        copy( szLoserTeam, charsmax( szLoserTeam ), g_szTeamNameB );
    }
    else
    {
        copy( szWinnerTeam, charsmax( szWinnerTeam ), g_szTeamNameB );
        copy( szLoserTeam, charsmax( szLoserTeam ), g_szTeamNameA );
    }

    client_print_color( 0, print_team_default, "^4[%s]^1 Equipo^3 %s^1 ganó^4 %d-%d^1 al equipo^3 %s^1.",
        g_szPrintPrefix, szWinnerTeam, g_sMatch[ Match_ScoreA ], g_sMatch[ Match_ScoreB ], szLoserTeam );
    client_print_color( 0, print_team_default, "^4[%s]^1 Para jugar nuevamente, ingresa a^4 zgaming.net/mix^1.", g_szPrintPrefix );
    
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            set_entvar( iPlayer, var_takedamage, DAMAGE_NO );
            set_entvar( iPlayer, var_flags, get_entvar( iPlayer, var_flags ) | FL_FROZEN );
        }
    }

    remove_task( TASK_MATCH_RESET );
    set_task( 2.0, "OnTaskWebMatchReset", TASK_MATCH_RESET );
}

public OnTaskWebMatchReset( )
{
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }

        set_entvar( iPlayer, var_flags, get_entvar( iPlayer, var_flags ) & ~FL_FROZEN );
        set_entvar( iPlayer, var_takedamage, DAMAGE_AIM );
    }

    ResetMixState( );

    StartWarmup( );
}

public OnTaskWarmupStart( )
{
    rg_restart_round( );
    
    set_task( 2.0, "OnTaskWarmupRespawn", TASK_WARMUP_RESPAWN, .flags = "b" );
    
    client_print_color( 0, print_team_default, "^4[%s]^1 Calentamiento activo.^4 Unete al juego^1 para^4 participar del match^1.", g_szPrintPrefix );
}

public OnTaskWarmupRespawn( )
{
    if ( g_iMixStatus != MIX_IDLE )
    {
        remove_task( TASK_WARMUP_RESPAWN );

        return;
    }
    
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }
        
        if ( !is_user_alive( iPlayer ) )
        {
            new TeamName:iTeam = get_member( iPlayer, m_iTeam );
            
            if ( iTeam == TEAM_TERRORIST || iTeam == TEAM_CT )
            {
                rg_round_respawn( iPlayer );
            }
        }
    }
}

/**
* Si el resultado ya no estaba en discusion.
*
* Se considera sentenciada cuando el que va ganando esta en punto de partido:
* le queda una ronda y al otro no le alcanza el tiempo para dar vuelta nada.
* Irse ahi es salirse de una partida terminada, no dejar tirado a nadie.
*/
bool:MatchAlreadyDecided( )
{
    if ( g_iMixStatus == MIX_OVERTIME )
    {
        new iFaltan = g_pCvar[ CVAR_ROUNDS_OVERTIME ] + 1;

        return ( g_iOvertimeScoreA >= iFaltan - 1 || g_iOvertimeScoreB >= iFaltan - 1 );
    }

    if ( g_iMixStatus != MIX_LIVE )
    {
        return false;
    }

    new iFaltan = g_pCvar[ CVAR_ROUNDS_PER_HALF ] + 1;

    return ( g_sMatch[ Match_ScoreA ] >= iFaltan - 1 || g_sMatch[ Match_ScoreB ] >= iFaltan - 1 );
}

NotifyWebPlayersLeft( )
{
    if ( !IsWebMatch( ) )
    {
        return;
    }

    for ( new i = 0; i < MAX_MIX_PLAYERS; i++ )
    {
        new iAccId = g_sDisconnected[ i ][ Disconnected_AccId ];

        if ( iAccId <= 0 || FindWebRosterSlot( iAccId ) == -1 )
        {
            continue;
        }

        OpenWebRosterSlot( iAccId, g_sDisconnected[ i ][ Disconnected_MatchDecided ] );
    }
}

OpenWebRosterSlot( const iAccId, const bool:bMatchDecided )
{
    new iRosterSlot = FindWebRosterSlot( iAccId );

    /* Si el resultado ya estaba sentenciado, salir no es abandono y no tiene
     * sentido abrir un reemplazo para una partida que esta terminando. */
    if ( iRosterSlot == -1 || g_bWebRosterVacant[ iRosterSlot ] || bMatchDecided )
    {
        return;
    }

    new iRet;
    ExecuteForward( g_iFwdWebPlayerLeft, iRet, iAccId );

    g_bWebRosterVacant[ iRosterSlot ] = true;

    /* La ficha de desconexión se descarta cuando el capitán decide seguir,
     * pero el dueño todavía puede volver a este slot: su dinero queda aquí. */
    new iDisconnectedSlot = FindDisconnectedByAccId( iAccId );
    g_iWebRosterVacantMoney[ iRosterSlot ] = ( iDisconnectedSlot != -1 ) ? g_sDisconnected[ iDisconnectedSlot ][ Disconnected_Money ] : 0;

    client_print_color( 0, print_team_default, "^4[%s]^1 Queda un^4 lugar libre^1. Cualquier espectador puede entrar.", g_szPrintPrefix );
}

/**
* Mete a un espectador en un slot que quedo libre.
*
* El slot conserva el equipo: el suplente juega donde jugaba el que se fue. Las
* estadisticas arrancan de cero porque las del otro ya se reportaron con su
* abandono.
*/
bool:TakeVacantRosterSlot( const iId, const iSlot )
{
    new iAccId = g_sPlayers[ iId ][ Player_AccId ];

    if ( iAccId <= 0 || iSlot < 0 || iSlot >= g_iWebRosterCount )
    {
        return false;
    }

    new iOldAccId = g_iWebRosterAccId[ iSlot ];

    /* El puente lee y persiste las estadisticas parciales del que sale dentro
     * de este forward. Por eso corre antes de reemplazar y limpiar el slot. */
    new iRet;
    ExecuteForward( g_iFwdWebPlayerReplaced, iRet, iOldAccId, iAccId );

    g_iWebRosterAccId[ iSlot ] = iAccId;
    g_bWebRosterVacant[ iSlot ] = false;
    g_iWebRosterReturnRounds[ iSlot ] = -1;
    g_iWebRosterKills[ iSlot ] = 0;
    g_iWebRosterDeaths[ iSlot ] = 0;
    g_iWebRosterAssists[ iSlot ] = 0;
    g_iWebRosterDamage[ iSlot ] = 0;
    g_iWebRosterHeadshots[ iSlot ] = 0;
    g_iWebRosterRounds[ iSlot ] = 0;

    /* El suplente ya cubrió la ausencia. Dejar la ficha vieja hacía que el
     * capitán todavía pudiera rendirse durante unos segundos por un jugador
     * que ya no faltaba y mantenía vivo el timeout de reconexión. */
    new iDisconnectedSlot = FindDisconnectedByAccId( iOldAccId );

    if ( iDisconnectedSlot != -1 )
    {
        RemoveDisconnectedSlot( iDisconnectedSlot );
    }

    if ( !HasDisconnectedPlayers( ) )
    {
        remove_task( TASK_RECONNECT_TIMEOUT );
    }

    client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 entra como^4 suplente^1.", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ] );

    return true;
}

/**
* Devuelve su slot a quien abandono, si ningun suplente lo tomo.
*
* Solo cambia lo que pasa dentro del servidor. El abandono ya se informo a la
* web y no se deshace: abandoned_at sigue marcado, la sancion se cobra igual y
* el cierre lo deja fuera del ELO aunque su equipo gane. Tampoco recupera un
* plazo de reconexion: si vuelve a salir, el slot se abre de inmediato.
*/
bool:RejoinAbandonedRosterSlot( const iId, const iRosterSlot )
{
    new iAccId = g_sPlayers[ iId ][ Player_AccId ];

    if ( iAccId <= 0 || iRosterSlot < 0 || iRosterSlot >= g_iWebRosterCount
        || !g_bWebRosterVacant[ iRosterSlot ] || g_iWebRosterAccId[ iRosterSlot ] != iAccId )
    {
        return false;
    }

    g_bWebRosterVacant[ iRosterSlot ] = false;

    /* Punto de partida para saber si despues jugo: la web solo le da la mitad
     * de la victoria si suma rondas desde aca y sigue dentro al terminar. */
    g_iWebRosterReturnRounds[ iRosterSlot ] = g_iWebRosterRounds[ iRosterSlot ];

    new iSavedMoney = g_iWebRosterVacantMoney[ iRosterSlot ];
    g_iWebRosterVacantMoney[ iRosterSlot ] = 0;

    client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 volvio a la partida. Su^4 abandono^1 sigue registrado.", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ] );

    /* Si la ficha de desconexion sigue viva (el capitan todavia no decidio),
     * se restaura todo como en una reconexion normal y se cierra el menu de
     * rendicion cuando ya no falta nadie. */
    if ( !HandlePlayerReconnect( iId, true ) )
    {
        new iMixTeam = g_iWebRosterTeam[ iRosterSlot ];

        g_sPlayers[ iId ][ Player_Team ] = iMixTeam;
        g_sPlayers[ iId ][ Player_IsCaptain ] = false;

        if ( !GetPlayerBit( g_iIsReady, iId ) )
        {
            SetPlayerBit( g_iIsReady, iId );
            g_iReadyCount++;
        }

        rg_join_team( iId, GetGameTeamForMixTeam( iMixTeam ) );
        rg_add_account( iId, iSavedMoney, AS_SET );
        NotifyWebPlayerJoined( iId );

        g_sPlayers[ iId ][ Player_Kills ] = g_iWebRosterKills[ iRosterSlot ];
        g_sPlayers[ iId ][ Player_Deaths ] = g_iWebRosterDeaths[ iRosterSlot ];
        g_sPlayers[ iId ][ Player_Assists ] = g_iWebRosterAssists[ iRosterSlot ];

        g_iReconnectFrags[ iId ] = g_iWebRosterKills[ iRosterSlot ];
        g_iReconnectScoreDeaths[ iId ] = g_iWebRosterDeaths[ iRosterSlot ];
        RestoreScoreboard( iId );

        new iNoWeapons[ 32 ];
        SetPlayerReconnectData( iId, iSavedMoney, false, 0, 0, false, iNoWeapons, iNoWeapons, iNoWeapons, 0 );

        set_task( 0.5, "OnTaskRestorePlayerEquipment", iId );
    }

    if ( g_sPlayers[ iId ][ Player_Reconnects ] < g_pCvar[ CVAR_MAX_RECONNECTS_PER_PLAYER ] )
    {
        g_sPlayers[ iId ][ Player_Reconnects ] = g_pCvar[ CVAR_MAX_RECONNECTS_PER_PLAYER ];
    }

    return true;
}

/**
* Si el dueño del slot abandono, volvio y jugo la partida.
*
* Jugar significa sumar al menos una ronda desde que volvio y seguir dentro de
* su equipo al terminar. Si volvio a irse, el slot queda vacante o sin jugador
* y no cuenta.
*/
bool:WebRosterSlotReturnedAndPlayed( const iSlot )
{
    if ( iSlot < 0 || iSlot >= g_iWebRosterCount
        || g_iWebRosterReturnRounds[ iSlot ] < 0
        || g_bWebRosterVacant[ iSlot ] )
    {
        return false;
    }

    return ( g_iWebRosterRounds[ iSlot ] > g_iWebRosterReturnRounds[ iSlot ] )
        && FindJoinedPlayerForWebSlot( iSlot ) != 0;
}

/**
* Primer slot del roster que quedo libre por abandono, o -1 si no hay.
*/
FindVacantRosterSlot( )
{
    for ( new i = 0; i < g_iWebRosterCount; i++ )
    {
        if ( g_bWebRosterVacant[ i ] )
        {
            return i;
        }
    }

    return -1;
}

public OnTaskReconnectCountdown( )
{
    g_iReconnectCountdown--;

    if ( g_iReconnectCountdown <= 0 )
    {
        remove_task( TASK_RECONNECT_TIMEOUT );

        client_print_color( 0, print_team_default, "^4[%s]^1 Jugadores desconectados no reconectaron a tiempo.", g_szPrintPrefix );

        NotifyWebPlayersLeft( );

        ShowSurrenderMenu( );

        return;
    }

    if ( g_iReconnectCountdown % 15 == 0 )
    {
        client_print_color( 0, print_team_default, "^4[%s]^1 Esperando reconexion. Tiempo restante:^4 %d^1 segundos.", g_szPrintPrefix, g_iReconnectCountdown );
    }
}

/* =================================================================================
* 				[ Mix Menu ]
* ================================================================================= */

ShowMixMenu( const iId )
{
    new iMenu = menu_create( fmt( "\y%s", g_szMenuTitle ), "OnMixMenuHandler" );
    
    menu_additem( iMenu, "Ir a Espectador", "1" );
    
    menu_setprop( iMenu, MPROP_EXITNAME, "Cerrar" );

    menu_display( iId, iMenu );
}

public OnMixMenuHandler( iId, iMenu, iItem )
{
    if ( iItem == MENU_EXIT )
    {
        menu_destroy( iMenu );
        
        return PLUGIN_HANDLED;
    }
    
    new szData[ 8 ];

    menu_item_getinfo( iMenu, iItem, _, szData, charsmax( szData ) );
    menu_destroy( iMenu );
    
    new iChoice = str_to_num( szData );
    
    switch ( iChoice )
    {
        case 1:
        {
            if ( g_iMixStatus != MIX_IDLE )
            {
                client_print_color( iId, print_team_default, "^4[%s]^1 No puedes^4 cambiar de equipo^1 durante la partida.", g_szPrintPrefix );

                return PLUGIN_HANDLED;
            }
            
            if ( GetPlayerBit( g_iIsReady, iId ) )
            {
                ClearPlayerBit( g_iIsReady, iId );
                g_iReadyCount--;

                if ( IsWebMatch( ) )
                {
                    client_print_color( 0, print_team_default, "^4[%s]^3 %s^1 salio. [^4%d^1/^4%d^1]", g_szPrintPrefix, g_sPlayers[ iId ][ Player_Name ], g_iReadyCount, g_iWebRosterCount );
                }
            }

            g_sPlayers[ iId ][ Player_Team ] = MIX_TEAM_NONE;

            rg_join_team( iId, TEAM_SPECTATOR );

            client_print_color( iId, print_team_default, "^4[%s]^1 Eres^4 espectador^1.", g_szPrintPrefix );
        }
    }
    
    return PLUGIN_HANDLED;
}

/* =================================================================================
* 				[ Chat System ]
* ================================================================================= */

public ClientCommand_Say( iId )
{
    new szData[ 192 ];
    read_args( szData, charsmax( szData ) );
    remove_quotes( szData );
    trim( szData );
    
    replace_all( szData, charsmax( szData ), "%", "" );
    replace_all( szData, charsmax( szData ), "#", "" );
    replace_all( szData, charsmax( szData ), "\", "" );
    
    if ( !Account_IsUserLogged( iId ) || IsSpaceOrEmpty( szData ) || IsTryingToColor( szData ) || ( szData[ 0 ] == '.' ) || ( szData[ 0 ] == '!' ) || ( szData[ 0 ] == '/' ) || ( szData[ 0 ] == '.' ) )
    {
        return PLUGIN_HANDLED_MAIN;
    }
    
    new TeamName:iTeam = get_member( iId, m_iTeam );
    new bool:bAlive = bool:is_user_alive( iId );
    new iFlags = get_user_flags( iId );
    new bool:bHasRank = bool:( iFlags && IsPlayerRank( iId, "gold" ) );
    new bool:bIsLive = ( g_iMixStatus == MIX_LIVE || g_iMixStatus == MIX_OVERTIME );
    
    new szStatus[ 16 ];
    new szColor[ 4 ];
    
    if ( !bAlive && iTeam != TEAM_SPECTATOR )
    {
        copy( szStatus, charsmax( szStatus ), "*MUERTO* " );
    }
    else
    {
        szStatus[ 0 ] = EOS;
    }
    
    copy( szColor, charsmax( szColor ), bHasRank ? "^4" : "^1" );

    new szMessage[ 192 ];

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }

        if ( bIsLive )
        {
            new TeamName:iTargetTeam = get_member( iPlayer, m_iTeam );
            new bool:bTargetAlive = bool:is_user_alive( iPlayer );

            if ( iTeam == TEAM_SPECTATOR )
            {
                if ( iTargetTeam != TEAM_SPECTATOR )
                {
                    continue;
                }
            }
            else if ( !bAlive )
            {
                if ( iTargetTeam != TEAM_SPECTATOR && bTargetAlive )
                {
                    continue;
                }
            }
            else
            {
                if ( iTargetTeam != TEAM_TERRORIST && iTargetTeam != TEAM_CT )
                {
                    continue;
                }
            }
        }

        if ( bHasRank )
        {
            formatex( szMessage, charsmax( szMessage ), "^1(#%d) %s^4(%L) ^3%n^1 : %s%s", Account_UserID( iId ), szStatus, iPlayer, g_sPlayers[ iId ][ Player_Title ], iId, szColor, szData );
        }
        else
        {
            formatex( szMessage, charsmax( szMessage ), "^1(#%d) %s^3%n^1 : %s%s", Account_UserID( iId ), szStatus, iId, szColor, szData );
        }

        client_print_color( iPlayer, iId, szMessage );
    }

    if ( bHasRank )
    {
        server_print( "(#%d) %s(%L) %n : %s", Account_UserID( iId ), szStatus, LANG_SERVER, g_sPlayers[ iId ][ Player_Title ], iId, szData );
    }
    else
    {
        server_print( "(#%d) %s%n : %s", Account_UserID( iId ), szStatus, iId, szData );
    }

    return PLUGIN_HANDLED_MAIN;
}

public ClientCommand_SayTeam( iId )
{
    new szData[ 192 ];
    read_args( szData, charsmax( szData ) );
    remove_quotes( szData );
    trim( szData );

    replace_all( szData, charsmax( szData ), "%", "" );
    replace_all( szData, charsmax( szData ), "#", "" );
    replace_all( szData, charsmax( szData ), "\", "" );
    
    if ( !Account_IsUserLogged( iId ) || IsSpaceOrEmpty( szData ) || IsTryingToColor( szData ) || ( szData[ 0 ] == '.' ) || ( szData[ 0 ] == '!' ) || ( szData[ 0 ] == '/' ) )
    {
        return PLUGIN_HANDLED_MAIN;
    }

    new TeamName:iTeam = get_member( iId, m_iTeam );
    new bool:bAlive = bool:is_user_alive( iId );
    new iFlags = get_user_flags( iId );
    new bool:bHasRank = bool:( iFlags && IsPlayerRank( iId, "gold" ) );

    new szPrefix[ 32 ];

    if ( !bAlive && iTeam != TEAM_SPECTATOR )
    {
        copy( szPrefix, charsmax( szPrefix ), "*MUERTO* (Equipo) " );
    }
    else
    {
        copy( szPrefix, charsmax( szPrefix ), "(Equipo) " );
    }

    new szColor[ 4 ];
    copy( szColor, charsmax( szColor ), bHasRank ? "^4" : "^1" );

    new szMessage[ 192 ];

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !GetPlayerBit( g_iIsConnected, iPlayer ) )
        {
            continue;
        }

        new TeamName:iTargetTeam = get_member( iPlayer, m_iTeam );

        if ( iTargetTeam != iTeam )
        {
            continue;
        }

        if ( bHasRank )
        {
            formatex( szMessage, charsmax( szMessage ), "^1(#%d) %s^4(%L) ^3%n^1 : %s%s", Account_UserID( iId ), szPrefix, iPlayer, g_sPlayers[ iId ][ Player_Title ], iId, szColor, szData );
        }
        else
        {
            formatex( szMessage, charsmax( szMessage ), "^1(#%d) %s^3%n^1 : %s%s", Account_UserID( iId ), szPrefix, iId, szColor, szData );
        }

        client_print_color( iPlayer, iId, szMessage );
    }

    if ( bHasRank )
    {
        server_print( "(#%d) %s(%L) %n : %s", Account_UserID( iId ), szPrefix, LANG_SERVER, g_sPlayers[ iId ][ Player_Title ], iId, szData );
    }
    else
    {
        server_print( "(#%d) %s%n : %s", Account_UserID( iId ), szPrefix, iId, szData );
    }

    return PLUGIN_HANDLED_MAIN;
}

/* =================================================================================
* 				[ CVars ]
* ================================================================================= */

CreateModCvars( )
{
    bind_pcvar_float( create_cvar( "mix_live_countdown_time", "5.0", _, .has_min = true, .min_val = 3.0 ), g_pCvar[ CVAR_LIVE_COUNTDOWN_TIME ] );
    bind_pcvar_float( create_cvar( "mix_reconnect_time", "120.0", _, .has_min = true, .min_val = 30.0 ), g_pCvar[ CVAR_RECONNECT_TIME ] );
    bind_pcvar_float( create_cvar( "mix_pause_duration", "30.0", _, .has_min = true, .min_val = 15.0 ), g_pCvar[ CVAR_PAUSE_DURATION ] );

    g_pCvarPointer[ CVAR_ROUNDS_PER_HALF ] = create_cvar( "mix_rounds_per_half", "15", _, .has_min = true, .min_val = 1.0 );
    bind_pcvar_num( g_pCvarPointer[ CVAR_ROUNDS_PER_HALF ], g_pCvar[ CVAR_ROUNDS_PER_HALF ] );

    g_pCvarPointer[ CVAR_ROUNDS_OVERTIME ] = create_cvar( "mix_rounds_overtime", "3", _, .has_min = true, .min_val = 1.0 );
    bind_pcvar_num( g_pCvarPointer[ CVAR_ROUNDS_OVERTIME ], g_pCvar[ CVAR_ROUNDS_OVERTIME ] );

    bind_pcvar_num( create_cvar( "mix_freezetime", "12", _, .has_min = true, .min_val = 0.0 ), g_pCvar[ CVAR_FREEZETIME ] );
    bind_pcvar_num( create_cvar( "mix_halftime_break", "15", _, .has_min = true, .min_val = 5.0 ), g_pCvar[ CVAR_HALFTIME_BREAK ] );
    bind_pcvar_num( create_cvar( "mix_overtime_start_money", "10000", _, .has_min = true, .min_val = 800.0 ), g_pCvar[ CVAR_OVERTIME_START_MONEY ] );
    bind_pcvar_num( create_cvar( "mix_max_pauses_per_team", "1", _, .has_min = true, .min_val = 0.0 ), g_pCvar[ CVAR_MAX_PAUSES_PER_TEAM ] );
    bind_pcvar_num( create_cvar( "mix_max_reconnects_per_player", "1", _, .has_min = true, .min_val = 0.0 ), g_pCvar[ CVAR_MAX_RECONNECTS_PER_PLAYER ] );
}

/* =================================================================================
* 				[ Natives ]
* ================================================================================= */

public _mix_web_clear_roster( iPlugin, iParams )
{
    g_iWebRosterCount = 0;
    g_iWebTeamSize = 0;
    g_bWebRoundPending = false;
    ResetWebRoundLog( );
    g_szWebMode[ 0 ] = EOS;
    copy( g_szMenuTitle, charsmax( g_szMenuTitle ), "#16 AUTOMIX" );
    g_flWebTeamEloA = 1000.0;
    g_flWebTeamEloB = 1000.0;
    g_bWebTeamEloLoaded = false;

    for ( new i = 0; i < MAX_MIX_PLAYERS; i++ )
    {
        g_iWebRosterAccId[ i ] = 0;
        g_iWebRosterTeam[ i ] = MIX_TEAM_NONE;
        g_bWebRosterVacant[ i ] = false;
        g_iWebRosterVacantMoney[ i ] = 0;
        g_iWebRosterReturnRounds[ i ] = -1;
        g_iWebRosterKills[ i ] = 0;
        g_iWebRosterDeaths[ i ] = 0;
        g_iWebRosterAssists[ i ] = 0;
        g_iWebRosterDamage[ i ] = 0;
        g_iWebRosterHeadshots[ i ] = 0;
        g_iWebRosterRounds[ i ] = 0;
    }
}

public bool:_mix_web_set_match_mode( iPlugin, iParams )
{
    new szMode[ 8 ];
    get_string( 1, szMode, charsmax( szMode ) );

    new iTeamSize = get_param( 2 );

    if ( !( equali( szMode, "5v5" ) && iTeamSize == 5 )
        && !( equali( szMode, "2v2" ) && iTeamSize == 2 ) )
    {
        return false;
    }

    strtolower( szMode );
    copy( g_szWebMode, charsmax( g_szWebMode ), szMode );
    g_iWebTeamSize = iTeamSize;

    formatex( g_szMenuTitle, charsmax( g_szMenuTitle ), "#16 AUTOMIX %dV%d", iTeamSize, iTeamSize );

    return true;
}

GetWebRosterTeamCount( const iTeam )
{
    new iCount;

    for ( new i = 0; i < g_iWebRosterCount; i++ )
    {
        if ( g_iWebRosterTeam[ i ] == iTeam )
        {
            iCount++;
        }
    }

    return iCount;
}

public _mix_web_add_player( iPlugin, iParams )
{
    if ( g_iWebTeamSize <= 0 || g_iWebRosterCount >= g_iWebTeamSize * 2
        || g_iWebRosterCount >= MAX_MIX_PLAYERS )
    {
        return 0;
    }

    new iAccId = get_param( 1 );
    new iTeam  = get_param( 2 );

    if ( iAccId <= 0 || ( iTeam != MIX_TEAM_A && iTeam != MIX_TEAM_B ) )
    {
        return 0;
    }

    new iExisting = FindWebRosterSlot( iAccId );

    if ( iExisting != -1 )
    {
        return ( g_iWebRosterTeam[ iExisting ] == iTeam );
    }

    if ( GetWebRosterTeamCount( iTeam ) >= g_iWebTeamSize )
    {
        return 0;
    }

    g_iWebRosterAccId[ g_iWebRosterCount ] = iAccId;
    g_iWebRosterTeam[ g_iWebRosterCount ] = iTeam;
    g_iWebRosterCount++;

    return 1;
}

public _mix_web_set_team_elo( iPlugin, iParams )
{
    new Float:flEloA = get_param_f( 1 );
    new Float:flEloB = get_param_f( 2 );

    g_flWebTeamEloA = ( flEloA > 0.0 ) ? flEloA : 1000.0;
    g_flWebTeamEloB = ( flEloB > 0.0 ) ? flEloB : 1000.0;
    g_bWebTeamEloLoaded = true;
}

public _mix_web_restore_score( iPlugin, iParams )
{
    new iScoreA = get_param( 1 );
    new iScoreB = get_param( 2 );
    new iHalf   = get_param( 3 );

    if ( iScoreA < 0 || iScoreB < 0 )
    {
        return 0;
    }

    g_sMatch[ Match_ScoreA ] = iScoreA;
    g_sMatch[ Match_ScoreB ] = iScoreB;

    if ( iHalf >= 3 )
    {
        g_sMatch[ Match_Half ] = 2;
        g_sMatch[ Match_Overtime ] = iHalf - 2;
    }
    else
    {
        g_sMatch[ Match_Half ] = ( iHalf < 1 ) ? 1 : iHalf;
        g_sMatch[ Match_Overtime ] = 0;
    }

    g_sMatch[ Match_TeamsSwapped ] = ( g_sMatch[ Match_Half ] == 2 );

    SyncTeamScores( );

    return 1;
}

SyncTeamScores( )
{
    new iObjetivoTR, iObjetivoCT;

    if ( !g_sMatch[ Match_TeamsSwapped ] )
    {
        iObjetivoTR = g_sMatch[ Match_ScoreA ];
        iObjetivoCT = g_sMatch[ Match_ScoreB ];
    }
    else
    {
        iObjetivoTR = g_sMatch[ Match_ScoreB ];
        iObjetivoCT = g_sMatch[ Match_ScoreA ];
    }

    rg_update_teamscores( iObjetivoCT, iObjetivoTR, false );
}

public bool:_mix_web_is_active( iPlugin, iParams )
{
    return IsWebMatch( );
}

public bool:_mix_web_busy( iPlugin, iParams )
{
    return ( g_iMixStatus != MIX_IDLE );
}

public _mix_web_match_status( iPlugin, iParams )
{
    return g_iMixStatus;
}

public _mix_web_round_number( iPlugin, iParams )
{
    return g_sMatch[ Match_Round ];
}

public _mix_web_team_of( iPlugin, iParams )
{
    new iSlot = FindWebRosterSlot( get_param( 1 ) );

    return ( iSlot == -1 ) ? MIX_TEAM_NONE : g_iWebRosterTeam[ iSlot ];
}

public _mix_web_roster_count( iPlugin, iParams )
{
    return g_iWebRosterCount;
}

public _mix_web_vacancy_count( iPlugin, iParams )
{
    new iCount;

    for ( new i = 0; i < g_iWebRosterCount; i++ )
    {
        if ( g_bWebRosterVacant[ i ] )
        {
            iCount++;
        }
    }

    return iCount;
}

public _mix_web_joined_roster_count( iPlugin, iParams )
{
    return IsWebMatch( ) ? CountJoinedWebRosterSlots( ) : 0;
}

public _mix_web_roster_stats( iPlugin, iParams )
{
    new iIndex = get_param( 1 );

    if ( iIndex < 0 || iIndex >= g_iWebRosterCount )
    {
        return 0;
    }

    set_param_byref( 2, g_iWebRosterAccId[ iIndex ] );
    set_param_byref( 3, g_iWebRosterKills[ iIndex ] );
    set_param_byref( 4, g_iWebRosterDeaths[ iIndex ] );
    set_param_byref( 5, g_iWebRosterAssists[ iIndex ] );

    return 1;
}

public bool:_mix_web_roster_returned( iPlugin, iParams )
{
    return WebRosterSlotReturnedAndPlayed( get_param( 1 ) );
}

public _mix_web_roster_advanced_stats( iPlugin, iParams )
{
    new iIndex = get_param( 1 );

    if ( iIndex < 0 || iIndex >= g_iWebRosterCount )
    {
        return 0;
    }

    set_param_byref( 2, g_iWebRosterDamage[ iIndex ] );
    set_param_byref( 3, g_iWebRosterHeadshots[ iIndex ] );
    set_param_byref( 4, g_iWebRosterRounds[ iIndex ] );

    return 1;
}
