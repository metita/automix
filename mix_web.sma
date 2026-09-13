#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <json>

#include "accsys/accounts"
#include <mix_core>
#include "accsys/database"

#define PLUGIN_NAME     "[ZG] AUTOMIX: Web Bridge"
#define PLUGIN_VERSION  "1.1"
#define PLUGIN_AUTHOR   "metita"

#define TASK_CLAIM      8100

#define CLAIM_INTERVAL  5.0

#define MAX_LOBBY_MISSES 3

#define MAX_FINISH_RETRIES 5
#define FINISH_RETRY_DELAY 6.0
#define MAX_CONNECTED_RETRIES 3
#define MAX_REPLACE_RETRIES 3

/* Margen entre el fin de la partida y el reporte, para que los abandonos que
 * el core marca justo antes alcancen a escribirse. */
#define FINISH_SETTLE_DELAY 1.5
#define TASK_FINISH_RETRY  8300

/* Latido de la partida.
 *
 * Sin esto, si el servidor se muere con un mix en curso la sala queda 'live' y
 * la web no deja volver a la cola a los jugadores de ese roster hasta que la limpieza
 * por antiguedad la cierre, tres horas despues. Con el latido, la web ve que
 * nadie reporta y la cancela sola. */
#define TASK_HEARTBEAT  8400

#define HEARTBEAT_INTERVAL 20.0

#define TASK_JOIN_WAIT  8500
#define TASK_SLOT_GUARD 8600

#define JOIN_WAIT_SECONDS  300
#define JOIN_WAIT_STEP     30
#define JOIN_WAIT_INTERVAL 30.0

/* Si el core vuelve a warmup antes de LIVE (alguien salio en la preparacion o
 * el knife), el que falta recibe al menos este margen antes del no-show. */
#define JOIN_RETURN_GRACE  120

/* Estados de mix_web_match_status( ). Desde HALFTIME en adelante la partida ya
 * paso por LIVE: started_at existe y el no-show deja de aplicar. */
#define MIX_STATUS_IDLE     0
#define MIX_STATUS_HALFTIME 3

#define SLOT_GUARD_INTERVAL       1.0
#define LOGIN_GRACE_SECONDS       30
#define MAX_PLAYERS               32

#define MAX_STATS_ENTRY  160
#define MAX_STATS_LENGTH 1536

new const g_szPrefix[ ] = "AUTOMIX";

new const g_szQueryClaimLobby[ ]     = "CALL zgaming_web.MixClaimLobbyV2(?, ?)";
new const g_szQueryGetLobby[ ]       = "CALL zgaming_web.MixGetLobbyForServerV2(?, ?)";
new const g_szQueryFinishMatch[ ]    = "CALL zgaming_web.MixFinishMatch(?, ?, ?, ?)";
new const g_szQueryCancelLobby[ ]    = "CALL zgaming_web.MixCancelLobby(?)";
new const g_szQueryCancelNoShowLobby[ ] = "CALL zgaming_web.MixCancelNoShowLobbyV2(?, ?)";
new const g_szQueryUpdateScore[ ]    = "CALL zgaming_web.MixUpdateScore(?, ?, ?, ?)";
new const g_szQueryPlayerConnected[ ] = "CALL zgaming_web.MixPlayerConnected(?, ?)";
new const g_szQueryPlayerAbandoned[ ] = "CALL zgaming_web.MixPlayerAbandoned(?, ?)";
new const g_szQueryReplacePlayer[ ]   = "CALL zgaming_web.MixReplacePlayerWithStats(?, ?, ?, ?)";
new const g_szQueryHeartbeat[ ]       = "CALL zgaming_web.MixHeartbeat(?)";
new const g_szQueryTeamElo[ ]         = "SELECT p.lobby_id, COALESCE(AVG(CASE WHEN p.team = 'A' THEN COALESCE(e.elo, 1000) END), 1000), COALESCE(AVG(CASE WHEN p.team = 'B' THEN COALESCE(e.elo, 1000) END), 1000) FROM zgaming_web.mix_lobby_players p INNER JOIN zgaming_web.mix_lobbies l ON l.id = p.lobby_id LEFT JOIN zgaming_web.mix_elo e ON e.accid = p.accid AND e.mode = l.mode WHERE p.lobby_id = ? AND p.team IS NOT NULL GROUP BY p.lobby_id";

new AccSysDb:g_hDatabase = Invalid_AccSysDb;

new g_pCvarServerId;
new g_pCvarMode;

new g_iLobbyId;
new g_szLobbyMap[ 64 ];
new g_szLobbyMode[ 8 ];
new g_iLobbyTeamSize;

new bool:g_bChangingLevel;

new g_iLobbyMisses;

new g_iLobbyScoreA;
new g_iLobbyScoreB;
new g_iLobbyHalf;

new g_iJoinWaitRemaining;
new bool:g_bJoinWaitBusy;
new bool:g_bNoShowTimeout;
new g_szNoShowAbsent[ 128 ];

new g_iFinishLobby;
new g_iFinishScoreA;
new g_iFinishScoreB;
new g_iFinishTries;
new g_szFinishStats[ MAX_STATS_LENGTH ];

new g_iPendingAbandonQueries;
new g_iPendingReplaceQueries;
new g_iPendingConnectedQueries;

new g_iConnectionOrder[ MAX_PLAYERS + 1 ];
new g_iLoginDeadline[ MAX_PLAYERS + 1 ];
new g_iNextConnectionOrder;
new bool:g_bKickPending[ MAX_PLAYERS + 1 ];
new bool:g_bInvalidModeWarned;

public plugin_init( )
{
    register_plugin( PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR );

    g_pCvarServerId = create_cvar( "mix_web_server_id", "16", _, .has_min = true, .min_val = 1.0 );
    // Seguro por defecto durante el despliegue: la instancia histórica sigue
    // siendo 5v5. El servidor del puerto nuevo debe declarar 2v2 en server.cfg.
    g_pCvarMode = create_cvar( "mix_web_mode", "5v5" );
}

public plugin_cfg( )
{
    KeepServerPublic( );

    g_hDatabase = DB_FindDatabase( "main" );

    if ( g_hDatabase == Invalid_AccSysDb )
    {
        log_amx( "[%s] No se encontro la base de datos 'main'. El puente web queda desactivado.", g_szPrefix );

        return;
    }

    RecoverOwnLobby( );
}

bool:GetAllowedMode( szMode[ ], const iLength )
{
    get_pcvar_string( g_pCvarMode, szMode, iLength );
    trim( szMode );
    strtolower( szMode );

    return equal( szMode, "all" ) || equal( szMode, "5v5" ) || equal( szMode, "2v2" );
}

bool:IsLobbyModeValid( )
{
    return ( equali( g_szLobbyMode, "5v5" ) && g_iLobbyTeamSize == 5 )
        || ( equali( g_szLobbyMode, "2v2" ) && g_iLobbyTeamSize == 2 );
}

GetExpectedRosterSize( )
{
    return g_iLobbyTeamSize * 2;
}

/* =================================================================================
* 				[ Lobby Claim ]
* ================================================================================= */

RecoverOwnLobby( )
{
    DB_StmtBindInt( 0, get_pcvar_num( g_pCvarServerId ) );
    DB_StmtBindInt( 1, 1 );

    DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_RecoverLobby", "RecoverOwnLobby", g_szQueryGetLobby );
}

public Query_RecoverLobby( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( !bSuccess )
    {
        log_amx( "[%s] Fallo al recuperar la partida propia.", g_szPrefix );

        StartClaimLoop( );

        return;
    }

    if ( hQuery == invalid_mariadb_result || !mariadb_next_row( hQuery ) )
    {
        KeepServerPublic( );

        StartClaimLoop( );

        return;
    }

    ReadLobbyRow( hQuery );

    if ( !ApplyRoster( hQuery ) )
    {
        StartClaimLoop( );

        return;
    }

    /* Retomar donde iba. Solo si habia algo jugado: en una sala que nunca
     * arranco esto es 0-0 y el core ya esta en cero. */
    if ( g_iLobbyScoreA || g_iLobbyScoreB || g_iLobbyHalf > 1 )
    {
        log_amx( "[%s] Partida #%d recuperada: %d-%d, tiempo %d.", g_szPrefix, g_iLobbyId, g_iLobbyScoreA, g_iLobbyScoreB, g_iLobbyHalf );

        mix_web_restore_score( g_iLobbyScoreA, g_iLobbyScoreB, g_iLobbyHalf );
    }

    StartClaimLoop( );
}

StartClaimLoop( )
{
    if ( !task_exists( TASK_CLAIM ) )
    {
        set_task( CLAIM_INTERVAL, "OnTaskClaim", TASK_CLAIM, _, _, "b" );
    }
}

public OnTaskClaim( )
{
    if ( g_bChangingLevel )
    {
        return;
    }

    if ( g_iLobbyId )
    {
        VerifyOwnLobby( );

        return;
    }

    if ( mix_web_busy( ) )
    {
        return;
    }

    new szAllowedMode[ 8 ];

    if ( !GetAllowedMode( szAllowedMode, charsmax( szAllowedMode ) ) )
    {
        if ( !g_bInvalidModeWarned )
        {
            log_amx( "[%s] mix_web_mode invalido. Usa all, 5v5 o 2v2. No se reclamaran partidas.", g_szPrefix );
            g_bInvalidModeWarned = true;
        }

        return;
    }

    g_bInvalidModeWarned = false;

    DB_StmtBindInt( 0, get_pcvar_num( g_pCvarServerId ) );
    DB_StmtBindString( 1, szAllowedMode );

    DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_ClaimLobby", "OnTaskClaim", g_szQueryClaimLobby );
}

public Query_ClaimLobby( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( !bSuccess || hQuery == invalid_mariadb_result || !mariadb_next_row( hQuery ) )
    {
        return;
    }

    ReadLobbyRow( hQuery );

    log_amx( "[%s] Partida #%d tomada: modo %s, mapa %s.", g_szPrefix, g_iLobbyId, g_szLobbyMode, g_szLobbyMap );

    new szCurrentMap[ 64 ];
    get_mapname( szCurrentMap, charsmax( szCurrentMap ) );

    if ( !equali( szCurrentMap, g_szLobbyMap ) )
    {
        if ( !is_map_valid( g_szLobbyMap ) )
        {
            log_amx( "[%s] El mapa %s no existe en el servidor. Partida #%d cancelada.", g_szPrefix, g_szLobbyMap, g_iLobbyId );

            CancelLobby( );

            return;
        }

        g_bChangingLevel = true;

        KeepServerPublic( );

        server_cmd( "changelevel %s", g_szLobbyMap );

        return;
    }

    ApplyRoster( hQuery );
}

/* =================================================================================
* 				[ Lobby Watchdog ]
* ================================================================================= */

VerifyOwnLobby( )
{
    DB_StmtBindInt( 0, get_pcvar_num( g_pCvarServerId ) );
    DB_StmtBindInt( 1, 0 );

    DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_VerifyLobby", "VerifyOwnLobby", g_szQueryGetLobby );
}

public Query_VerifyLobby( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( !bSuccess )
    {
        return;
    }

    if ( hQuery != invalid_mariadb_result && mariadb_next_row( hQuery ) && mariadb_read_int( hQuery, 0 ) == g_iLobbyId )
    {
        g_iLobbyMisses = 0;

        return;
    }

    if ( ++g_iLobbyMisses < MAX_LOBBY_MISSES )
    {
        return;
    }

    log_amx( "[%s] La partida #%d ya no existe en la web. Servidor liberado.", g_szPrefix, g_iLobbyId );

    ReleaseLobby( );
}

ReadLobbyRow( mariadb_result:hQuery )
{
    g_iLobbyMisses = 0;

    g_iLobbyId = mariadb_read_int( hQuery, 0 );

    mariadb_read_string( hQuery, 1, g_szLobbyMap, charsmax( g_szLobbyMap ) );
    /* El marcador guardado. En una sala recien tomada viene en cero; si el
     * servidor se cayo y volvio, viene lo que se habia jugado, y es lo que
     * evita que la partida se reanude en 0-0. */
    g_iLobbyScoreA = mariadb_read_int( hQuery, 3 );
    g_iLobbyScoreB = mariadb_read_int( hQuery, 4 );
    g_iLobbyHalf   = mariadb_read_int( hQuery, 5 );
    mariadb_read_string( hQuery, 6, g_szLobbyMode, charsmax( g_szLobbyMode ) );
    g_iLobbyTeamSize = mariadb_read_int( hQuery, 7 );

    g_bChangingLevel = false;

    StartHeartbeat( );
}

StartHeartbeat( )
{
    if ( !task_exists( TASK_HEARTBEAT ) )
    {
        set_task( HEARTBEAT_INTERVAL, "OnTaskHeartbeat", TASK_HEARTBEAT, _, _, "b" );
    }
}

public OnTaskHeartbeat( )
{
    if ( !g_iLobbyId )
    {
        remove_task( TASK_HEARTBEAT );

        return;
    }

    DB_StmtBindInt( 0, g_iLobbyId );

    DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_Heartbeat", "OnTaskHeartbeat", g_szQueryHeartbeat );
}

public Query_Heartbeat( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    /* No hay nada que hacer con el resultado. Si un latido se pierde no pasa
     * nada: el margen de la web es de varios minutos, no de uno. */
}

/* =================================================================================
* 				[ Roster System ]
* ================================================================================= */

bool:ApplyRoster( mariadb_result:hQuery )
{
    if ( !g_iLobbyId )
    {
        return false;
    }

    if ( !IsLobbyModeValid( ) )
    {
        log_amx( "[%s] Partida #%d rechazo modo inconsistente: mode=%s, team_size=%d.",
            g_szPrefix, g_iLobbyId, g_szLobbyMode, g_iLobbyTeamSize );

        CancelLobby( );

        return false;
    }

    new iExpectedPlayers = GetExpectedRosterSize( );
    new iRequiredServerSlots = iExpectedPlayers + 1;

    if ( MaxClients < iRequiredServerSlots )
    {
        log_amx( "[%s] El servidor tiene %d slots y el modo %s necesita al menos %d (%d jugadores + HLTV). Partida #%d cancelada.",
            g_szPrefix, MaxClients, g_szLobbyMode, iRequiredServerSlots, iExpectedPlayers, g_iLobbyId );

        CancelLobby( );

        return false;
    }

    mix_web_clear_roster( );

    if ( !mix_web_set_match_mode( g_szLobbyMode, g_iLobbyTeamSize ) )
    {
        log_amx( "[%s] El core rechazo el modo %s (%dv%d) de la partida #%d.",
            g_szPrefix, g_szLobbyMode, g_iLobbyTeamSize, g_iLobbyTeamSize, g_iLobbyId );

        CancelLobby( );

        return false;
    }

    new iRows;
    new bool:bInvalidRoster;

    if ( mariadb_next_result_set( hQuery ) )
    {
        while ( mariadb_next_row( hQuery ) )
        {
            iRows++;

            new iAccId = mariadb_read_int( hQuery, 0 );
            new iTeam  = mariadb_read_int( hQuery, 1 );

            if ( !mix_web_add_player( iAccId, iTeam ) )
            {
                bInvalidRoster = true;
            }
        }
    }

    new iCount = mix_web_roster_count( );
    new iTeamA = CountRosterTeam( MIX_TEAM_A );
    new iTeamB = CountRosterTeam( MIX_TEAM_B );

    if ( bInvalidRoster || iRows != iExpectedPlayers || iCount != iExpectedPlayers
        || iTeamA != g_iLobbyTeamSize || iTeamB != g_iLobbyTeamSize )
    {
        log_amx( "[%s] Roster invalido en partida #%d (%s): filas=%d, unicos=%d, A=%d, B=%d; se requiere %d+%d. Cancelada.",
            g_szPrefix, g_iLobbyId, g_szLobbyMode, iRows, iCount, iTeamA, iTeamB, g_iLobbyTeamSize, g_iLobbyTeamSize );

        CancelLobby( );

        return false;
    }

    KeepServerPublic( );

    log_amx( "[%s] Roster de la partida #%d cargado: modo %s, %d jugadores.",
        g_szPrefix, g_iLobbyId, g_szLobbyMode, iCount );

    StartSlotGuard( );

    LoadTeamElo( );

    StartJoinWait( );

    return true;
}

CountRosterTeam( const iTeam )
{
    new iCount;

    for ( new iSlot = 0; iSlot < mix_web_roster_count( ); iSlot++ )
    {
        new iAccId, iKills, iDeaths, iAssists;

        if ( mix_web_roster_stats( iSlot, iAccId, iKills, iDeaths, iAssists )
            && mix_web_team_of( iAccId ) == iTeam )
        {
            iCount++;
        }
    }

    return iCount;
}

LoadTeamElo( )
{
    DB_StmtBindInt( 0, g_iLobbyId );

    DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_TeamElo", "LoadTeamElo", g_szQueryTeamElo );
}

public Query_TeamElo( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( !bSuccess || hQuery == invalid_mariadb_result || !mariadb_next_row( hQuery ) )
    {
        log_amx( "[%s] No se pudo cargar el ELO de la partida #%d. Se mostrara 1000 por equipo.", g_szPrefix, g_iLobbyId );

        mix_web_set_team_elo( 1000.0, 1000.0 );

        return;
    }

    if ( mariadb_read_int( hQuery, 0 ) != g_iLobbyId )
    {
        return;
    }

    mix_web_set_team_elo( mariadb_read_float( hQuery, 1 ), mariadb_read_float( hQuery, 2 ) );
}

StartJoinWait( )
{
    remove_task( TASK_JOIN_WAIT );

    g_iJoinWaitRemaining = JOIN_WAIT_SECONDS;
    g_bJoinWaitBusy = false;

    if ( !CheckJoinWait( ) )
    {
        return;
    }

    set_task( JOIN_WAIT_INTERVAL, "OnTaskJoinWait", TASK_JOIN_WAIT, _, _, "b" );
}

public OnTaskJoinWait( )
{
    g_iJoinWaitRemaining -= JOIN_WAIT_STEP;

    if ( g_iJoinWaitRemaining < 0 )
    {
        g_iJoinWaitRemaining = 0;
    }

    CheckJoinWait( );
}

/**
 * Cuenta solamente slots que el core ya validó: conexión única, cuenta
 * resuelta, AccId y equipo lógico del roster, JOIN_GAME completado y presencia
 * física en TT o CT.
 *
 * Estar en el servidor no alcanza. Espectador, unassigned y quien todavia no
 * termino el login siguen figurando como faltantes.
 */
GetJoinedRosterCount( )
{
    /* El core recorre slots, no conexiones. Así un AccId duplicado nunca tapa
     * al ausente y el timeout usa exactamente la misma verdad que el arranque. */
    return mix_web_joined_roster_count( );
}

/**
 * AccIds del roster que no estan dentro de TT/CT al vencer la espera, en JSON.
 *
 * `connected_at` solo dice que alguien entro alguna vez. Quien entra y sale
 * antes de LIVE lo conserva, y la cancelacion atomica lo daba por presente: si
 * era el unico faltante la sala no se cancelaba en la web. Se manda la verdad
 * fisica del momento para que el SQL lo trate como no-show.
 */
BuildNoShowAbsentList( )
{
    new iLen = formatex( g_szNoShowAbsent, charsmax( g_szNoShowAbsent ), "[" );
    new bool:bFirst = true;

    for ( new iSlot = 0; iSlot < mix_web_roster_count( ); iSlot++ )
    {
        new iAccId, iKills, iDeaths, iAssists;

        if ( !mix_web_roster_stats( iSlot, iAccId, iKills, iDeaths, iAssists ) || iAccId <= 0 || IsRosterAccIdInGame( iAccId ) )
        {
            continue;
        }

        iLen += formatex( g_szNoShowAbsent[ iLen ], charsmax( g_szNoShowAbsent ) - iLen, "%s%d", bFirst ? "" : ",", iAccId );

        bFirst = false;
    }

    formatex( g_szNoShowAbsent[ iLen ], charsmax( g_szNoShowAbsent ) - iLen, "]" );
}

bool:IsRosterAccIdInGame( const iAccId )
{
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !is_user_connected( iPlayer ) || is_user_hltv( iPlayer ) || g_bKickPending[ iPlayer ]
            || !Account_IsUserLogged( iPlayer ) || Account_UserID( iPlayer ) != iAccId )
        {
            continue;
        }

        new TeamName:iTeam = get_member( iPlayer, m_iTeam );

        if ( iTeam == TEAM_TERRORIST || iTeam == TEAM_CT )
        {
            return true;
        }
    }

    return false;
}

/* =================================================================================
* 				[ Public Server Slot Guard ]
* ================================================================================= */

public client_putinserver( iId )
{
    g_iConnectionOrder[ iId ] = ++g_iNextConnectionOrder;
    g_iLoginDeadline[ iId ] = get_systime( ) + LOGIN_GRACE_SECONDS;
    g_bKickPending[ iId ] = false;

    if ( g_iLobbyId && mix_web_is_active( ) )
    {
        EnforceSlotGuard( );
    }
}

public client_disconnected( iId )
{
    g_iConnectionOrder[ iId ] = 0;
    g_iLoginDeadline[ iId ] = 0;
    g_bKickPending[ iId ] = false;
}

StartSlotGuard( )
{
    remove_task( TASK_SLOT_GUARD );

    new iNow = get_systime( );

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !is_user_connected( iPlayer ) )
        {
            continue;
        }

        if ( g_iConnectionOrder[ iPlayer ] <= 0 )
        {
            g_iConnectionOrder[ iPlayer ] = ++g_iNextConnectionOrder;
        }

        g_bKickPending[ iPlayer ] = false;

        if ( !is_user_hltv( iPlayer ) && !Account_IsUserLogged( iPlayer ) )
        {
            g_iLoginDeadline[ iPlayer ] = iNow + LOGIN_GRACE_SECONDS;
        }
    }

    EnforceSlotGuard( );

    set_task( SLOT_GUARD_INTERVAL, "OnTaskSlotGuard", TASK_SLOT_GUARD, _, _, "b" );
}

StopSlotGuard( )
{
    remove_task( TASK_SLOT_GUARD );

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        g_iLoginDeadline[ iPlayer ] = 0;
        g_bKickPending[ iPlayer ] = false;
    }
}

public OnTaskSlotGuard( )
{
    if ( !g_iLobbyId || !mix_web_is_active( ) )
    {
        StopSlotGuard( );

        return;
    }

    EnforceSlotGuard( );

    TrackJoinWaitPhase( );
}

/**
 * Detecta, con la resolucion de un segundo del guard, que el core volvio a
 * warmup antes de LIVE.
 *
 * El tick de la espera corre cada 30 s y una preparacion corta puede empezar y
 * terminar entre dos ticks. Sin esto, quien sale durante la preparacion dejaba
 * la sala esperando para siempre o, al reves, cancelada al instante.
 */
TrackJoinWaitPhase( )
{
    if ( !task_exists( TASK_JOIN_WAIT ) )
    {
        return;
    }

    if ( mix_web_busy( ) )
    {
        g_bJoinWaitBusy = true;

        return;
    }

    if ( !g_bJoinWaitBusy )
    {
        return;
    }

    g_bJoinWaitBusy = false;

    if ( g_iJoinWaitRemaining < JOIN_RETURN_GRACE )
    {
        g_iJoinWaitRemaining = JOIN_RETURN_GRACE;
    }

    CheckJoinWait( );
}

bool:IsRosterAccId( const iAccId )
{
    if ( iAccId <= 0 )
    {
        return false;
    }

    for ( new iSlot = 0; iSlot < mix_web_roster_count( ); iSlot++ )
    {
        new iRosterAccId, iKills, iDeaths, iAssists;

        if ( mix_web_roster_stats( iSlot, iRosterAccId, iKills, iDeaths, iAssists ) && iRosterAccId == iAccId )
        {
            return true;
        }
    }

    return false;
}

bool:IsSpectator( const iId )
{
    if ( !is_user_connected( iId ) )
    {
        return false;
    }

    new TeamName:iTeam = get_member( iId, m_iTeam );

    /* Mientras el menu de ingreso sigue abierto ReGameDLL lo reporta como
     * UNASSIGNED. Es el mismo estado no jugable que espectador para proteger
     * el roster: no se lo expulsa antes de que pueda elegir mirar el mix. */
    return iTeam == TEAM_UNASSIGNED || iTeam == TEAM_SPECTATOR;
}

MoveNonRosterToSpectator( const iId )
{
    if ( !is_user_connected( iId ) || IsSpectator( iId ) )
    {
        return;
    }

    new szName[ MAX_NAME_LENGTH ];
    get_user_name( iId, szName, charsmax( szName ) );

    rg_join_team( iId, TEAM_SPECTATOR );

    client_print_color( iId, print_team_default, "^4[%s]^1 No estas en el roster de este mix. Puedes quedarte como^4 espectador^1.", g_szPrefix );
    log_amx( "[%s] Ingreso bloqueado: %s (userid %d) enviado a espectador por no estar en el roster.", g_szPrefix, szName, get_user_userid( iId ) );
}

bool:HasEarlierHltv( const iId )
{
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( iPlayer == iId || !is_user_connected( iPlayer ) || !is_user_hltv( iPlayer ) || g_bKickPending[ iPlayer ] )
        {
            continue;
        }

        if ( g_iConnectionOrder[ iPlayer ] < g_iConnectionOrder[ iId ] )
        {
            return true;
        }
    }

    return false;
}

bool:HasEarlierRosterConnection( const iId, const iAccId )
{
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( iPlayer == iId || !is_user_connected( iPlayer ) || is_user_hltv( iPlayer ) || is_user_bot( iPlayer ) || g_bKickPending[ iPlayer ] )
        {
            continue;
        }

        if ( !Account_IsUserLogged( iPlayer ) || Account_UserID( iPlayer ) != iAccId )
        {
            continue;
        }

        if ( g_iConnectionOrder[ iPlayer ] < g_iConnectionOrder[ iId ] )
        {
            return true;
        }
    }

    return false;
}

bool:IsValidRosterConnection( const iId )
{
    if ( !is_user_connected( iId ) || is_user_hltv( iId ) || is_user_bot( iId ) || g_bKickPending[ iId ] || !Account_IsUserLogged( iId ) )
    {
        return false;
    }

    new iAccId = Account_UserID( iId );

    return IsRosterAccId( iAccId ) && !HasEarlierRosterConnection( iId, iAccId );
}

bool:IsPendingHuman( const iId )
{
    return is_user_connected( iId )
        && !is_user_hltv( iId )
        && !is_user_bot( iId )
        && !g_bKickPending[ iId ]
        && !Account_IsUserLogged( iId );
}

CountEarlierPendingHumans( const iId )
{
    new iCount;

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( iPlayer != iId && IsPendingHuman( iPlayer ) && g_iConnectionOrder[ iPlayer ] < g_iConnectionOrder[ iId ] )
        {
            iCount++;
        }
    }

    return iCount;
}

bool:QueueMixKick( const iId, const szReason[ ] )
{
    if ( !is_user_connected( iId ) || g_bKickPending[ iId ] )
    {
        return false;
    }

    g_bKickPending[ iId ] = true;

    new szName[ MAX_NAME_LENGTH ];
    get_user_name( iId, szName, charsmax( szName ) );

    server_cmd( "kick #%d ^"%s^"", get_user_userid( iId ), szReason );
    log_amx( "[%s] Slot protegido: expulsado %s (userid %d): %s", g_szPrefix, szName, get_user_userid( iId ), szReason );

    return true;
}

EnforceSlotGuard( )
{
    if ( !g_iLobbyId || !mix_web_is_active( ) )
    {
        return;
    }

    new bool:bExecuteKicks;
    new iNow = get_systime( );

    /* Primero se eliminan conexiones que nunca pueden ocupar un cupo del mix:
     * HLTV duplicadas, bots, cuentas ajenas, duplicados y gente que no termino
     * el login dentro del margen. */
    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( !is_user_connected( iPlayer ) || g_bKickPending[ iPlayer ] )
        {
            continue;
        }

        if ( g_iConnectionOrder[ iPlayer ] <= 0 )
        {
            g_iConnectionOrder[ iPlayer ] = ++g_iNextConnectionOrder;
        }

        if ( is_user_hltv( iPlayer ) )
        {
            if ( HasEarlierHltv( iPlayer ) && QueueMixKick( iPlayer, "Solo se permite una HLTV durante el mix" ) )
            {
                bExecuteKicks = true;
            }

            continue;
        }

        if ( is_user_bot( iPlayer ) )
        {
            new szReason[ 96 ];
            formatex( szReason, charsmax( szReason ), "Servidor reservado para %d jugadores y una HLTV", GetExpectedRosterSize( ) );

            if ( QueueMixKick( iPlayer, szReason ) )
            {
                bExecuteKicks = true;
            }

            continue;
        }

        /* El servidor sigue siendo publico durante el mix: un espectador o
         * alguien aun en el menu de ingreso no ocupa un equipo y debe poder
         * quedarse para mirar la partida. Account_UserJoinGame ya le impide
         * entrar a TT/CT si no pertenece al roster. */
        if ( IsSpectator( iPlayer ) )
        {
            continue;
        }

        if ( Account_IsUserLogged( iPlayer ) )
        {
            new iAccId = Account_UserID( iPlayer );

            if ( !IsRosterAccId( iAccId ) )
            {
                /* Las cuentas ajenas pueden mirar. Si por cualquier carrera o
                 * comando aparecen en TT/CT, se las devuelve a espectador; no
                 * se expulsa a alguien por intentar Ingresar al juego. */
                MoveNonRosterToSpectator( iPlayer );
            }
            else if ( HasEarlierRosterConnection( iPlayer, iAccId ) )
            {
                if ( QueueMixKick( iPlayer, "Tu cuenta ya esta conectada en este mix" ) )
                {
                    bExecuteKicks = true;
                }
            }

            continue;
        }

        if ( g_iLoginDeadline[ iPlayer ] <= 0 )
        {
            g_iLoginDeadline[ iPlayer ] = iNow + LOGIN_GRACE_SECONDS;
        }
        else if ( iNow >= g_iLoginDeadline[ iPlayer ] )
        {
            if ( QueueMixKick( iPlayer, "Debes iniciar sesion para ocupar un cupo del mix" ) )
            {
                bExecuteKicks = true;
            }
        }
    }

    new iValidRoster;

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( IsValidRosterConnection( iPlayer ) )
        {
            iValidRoster++;
        }
    }

    /* Los pendientes todavía pueden ser jugadores reales del roster. Se les
     * da el margen de login, pero nunca se permite que ocupen el último slot
     * físico: queda reservado para que HLTV pueda conectar aun sin password. */
    new iPendingCapacity = ( MaxClients - 1 ) - iValidRoster;

    if ( iPendingCapacity < 0 )
    {
        iPendingCapacity = 0;
    }

    for ( new iPlayer = 1; iPlayer <= MaxClients; iPlayer++ )
    {
        if ( IsPendingHuman( iPlayer ) && CountEarlierPendingHumans( iPlayer ) >= iPendingCapacity )
        {
            if ( QueueMixKick( iPlayer, "El ultimo slot del servidor esta reservado para HLTV" ) )
            {
                bExecuteKicks = true;
            }
        }
    }

    if ( bExecuteKicks )
    {
        server_exec( );
    }
}

bool:CheckJoinWait( )
{
    /* Apenas el core sale del warmup, esta espera ya cumplio su objetivo. No
     * debe confundirse una desconexion durante knife/live con el ingreso
     * inicial de todos los jugadores del roster. */
    if ( !g_iLobbyId || !mix_web_is_active( ) )
    {
        remove_task( TASK_JOIN_WAIT );

        return false;
    }

    new iStatus = mix_web_match_status( );

    /* La partida ya llego a LIVE: started_at existe y desde aca manda la
     * reconexion del core, no el no-show. */
    if ( iStatus >= MIX_STATUS_HALFTIME )
    {
        remove_task( TASK_JOIN_WAIT );

        return false;
    }

    /* Preparacion o knife: el reloj sigue vivo pero en silencio. Antes se
     * borraba aca y, si alguien salia y el core volvia a warmup, ya no quedaba
     * ningun plazo: la sala esperaba hasta que alguien la cancelara a mano. */
    if ( iStatus != MIX_STATUS_IDLE )
    {
        return true;
    }

    new iTotal = mix_web_roster_count( );
    new iMissing = iTotal - GetJoinedRosterCount( );

    /* Estan todos: el core arranca solo. Se conserva el task por si alguien
     * sale antes de LIVE. */
    if ( iMissing <= 0 )
    {
        return true;
    }

    if ( g_iJoinWaitRemaining <= 0 )
    {
        /* JOIN_GAME ya ocurrió físicamente, pero su UPDATE corre async. No se
         * cancela ni sanciona hasta que esos callbacks terminen: de otro modo
         * el último jugador podía ser marcado no-show por una carrera de DB. */
        if ( g_iPendingConnectedQueries > 0 )
        {
            client_print_color( 0, print_team_default, "^4[%s]^1 Verificando los ultimos ingresos antes de cerrar la sala...", g_szPrefix );

            return true;
        }

        remove_task( TASK_JOIN_WAIT );

        client_print_color( 0, print_team_default, "^4[%s]^1 Se agotaron los^4 05:00^1 y faltan^4 %d jugador%s^1. Partida cancelada.",
            g_szPrefix, iMissing, ( iMissing == 1 ) ? "" : "es" );

        log_amx( "[%s] Partida #%d cancelada: faltan %d de %d jugadores despues de 5 minutos.",
            g_szPrefix, g_iLobbyId, iMissing, iTotal );

        /* Pasa por el core para limpiar tambien ready, equipos y warmup. El
         * forward mix_web_match_cancelled usa la cancelacion atomica de
         * no-show y libera la sala web. El flag se prende antes del comando
         * porque el forward se ejecuta sincronicamente dentro de mix_cancel. */
        g_bNoShowTimeout = true;

        BuildNoShowAbsentList( );

        server_cmd( "mix_cancel" );
        server_exec( );

        return false;
    }

    client_print_color( 0, print_team_default, "^4[%s]^1 Falta%s^4 %d jugador%s^1. Quedan^4 %02d:%02d^1 para entrar.",
        g_szPrefix,
        ( iMissing == 1 ) ? "" : "n",
        iMissing,
        ( iMissing == 1 ) ? "" : "es",
        g_iJoinWaitRemaining / 60,
        g_iJoinWaitRemaining % 60 );

    return true;
}

/* =================================================================================
* 				[ Forwards ]
* ================================================================================= */

public mix_web_roster_reject( const iId, const iAccId )
{
    if ( !is_user_connected( iId ) )
    {
        return;
    }

    MoveNonRosterToSpectator( iId );
}

public mix_web_score_changed( const iScoreA, const iScoreB, const iHalf )
{
    if ( !g_iLobbyId )
    {
        return;
    }

    DB_StmtBindInt( 0, g_iLobbyId );
    DB_StmtBindInt( 1, iScoreA );
    DB_StmtBindInt( 2, iScoreB );
    DB_StmtBindInt( 3, iHalf );

    DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_UpdateScore", "mix_web_score_changed", g_szQueryUpdateScore );
}

public Query_UpdateScore( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( !bSuccess )
    {
        log_amx( "[%s] Fallo al actualizar el marcador de la partida #%d.", g_szPrefix, g_iLobbyId );
    }
}

public mix_web_player_left( const iAccId )
{
    if ( !g_iLobbyId )
    {
        return;
    }

    log_amx( "[%s] accid %d abandono la partida #%d.", g_szPrefix, iAccId, g_iLobbyId );

    DB_StmtBindInt( 0, g_iLobbyId );
    DB_StmtBindInt( 1, iAccId );

    g_iPendingAbandonQueries++;

    DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_PlayerAbandoned", "mix_web_player_left", g_szQueryPlayerAbandoned );
}

public Query_PlayerAbandoned( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( g_iPendingAbandonQueries > 0 )
    {
        g_iPendingAbandonQueries--;
    }

    if ( !bSuccess )
    {
        log_amx( "[%s] Fallo al reportar un abandono.", g_szPrefix );
    }

    if ( g_iFinishLobby )
    {
        ScheduleFinishReport( );
    }
}

public mix_web_player_replaced( const iOldAccId, const iNewAccId )
{
    if ( !g_iLobbyId )
    {
        return;
    }

    log_amx( "[%s] accid %d entra de suplente por %d en la partida #%d.", g_szPrefix, iNewAccId, iOldAccId, g_iLobbyId );

    /* El core dispara este forward antes de limpiar el slot. Se copian ahora
     * las estadisticas parciales para que el abandono no desaparezca cuando
     * entra el suplente. */
    new szStats[ MAX_STATS_ENTRY ];
    copy( szStats, charsmax( szStats ), "[]" );

    for ( new i = 0; i < mix_web_roster_count( ); i++ )
    {
        new iAccId, iKills, iDeaths, iAssists;

        if ( !mix_web_roster_stats( i, iAccId, iKills, iDeaths, iAssists ) || iAccId != iOldAccId )
        {
            continue;
        }

        new iDamage, iHeadshots, iRounds;
        mix_web_roster_advanced_stats( i, iDamage, iHeadshots, iRounds );

        formatex( szStats, charsmax( szStats ),
            "[{^"a^":%d,^"k^":%d,^"d^":%d,^"s^":%d,^"m^":%d,^"h^":%d,^"r^":%d}]",
            iAccId, iKills, iDeaths, iAssists, iDamage, iHeadshots, iRounds );

        break;
    }

    SendPlayerReplacement( g_iLobbyId, iOldAccId, iNewAccId, szStats, 1 );
}

SendPlayerReplacement(
    const iLobbyId,
    const iOldAccId,
    const iNewAccId,
    const szStats[ ],
    const iTry
)
{
    new JSON:jContext = json_init_object( );

    json_object_set_number( jContext, "lobby", iLobbyId );
    json_object_set_number( jContext, "old", iOldAccId );
    json_object_set_number( jContext, "new", iNewAccId );
    json_object_set_number( jContext, "try", iTry );
    json_object_set_string( jContext, "stats", szStats );

    DB_StmtBindInt( 0, iLobbyId );
    DB_StmtBindInt( 1, iOldAccId );
    DB_StmtBindInt( 2, iNewAccId );
    DB_StmtBindString( 3, szStats );

    g_iPendingReplaceQueries++;

    DB_ThreadStmt( g_hDatabase, jContext, "Query_ReplacePlayer", "SendPlayerReplacement", g_szQueryReplacePlayer );
}

public Query_ReplacePlayer( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( g_iPendingReplaceQueries > 0 )
    {
        g_iPendingReplaceQueries--;
    }

    new iLobbyId = json_object_get_number( jObject, "lobby" );
    new iOldAccId = json_object_get_number( jObject, "old" );
    new iNewAccId = json_object_get_number( jObject, "new" );
    new iTry = json_object_get_number( jObject, "try" );

    if ( !bSuccess )
    {
        if ( iTry < MAX_REPLACE_RETRIES && ( g_iLobbyId == iLobbyId || g_iFinishLobby == iLobbyId ) )
        {
            new szStats[ MAX_STATS_ENTRY ];
            json_object_get_string( jObject, "stats", szStats, charsmax( szStats ) );

            log_amx( "[%s] Fallo al registrar suplente %d por %d en #%d; reintento %d/%d.",
                g_szPrefix, iNewAccId, iOldAccId, iLobbyId, iTry + 1, MAX_REPLACE_RETRIES );

            SendPlayerReplacement( iLobbyId, iOldAccId, iNewAccId, szStats, iTry + 1 );

            return;
        }

        log_amx( "[%s] No se pudo registrar al suplente %d por %d en la partida #%d.",
            g_szPrefix, iNewAccId, iOldAccId, iLobbyId );
    }
    else if ( g_iLobbyId == iLobbyId )
    {
        /* Garantiza el orden Replace -> Connected. El forward JOIN_GAME puede
         * haber llegado antes de que el INSERT del suplente existiera. */
        SendPlayerConnected( iLobbyId, iNewAccId, 1 );
    }

    if ( g_iFinishLobby )
    {
        ScheduleFinishReport( );
    }
}

public mix_web_match_cancelled( )
{
    if ( !g_iLobbyId )
    {
        return;
    }

    if ( g_bNoShowTimeout )
    {
        log_amx( "[%s] Partida #%d vencida por no-show; cancelacion atomica solicitada.", g_szPrefix, g_iLobbyId );
    }
    else
    {
        log_amx( "[%s] Partida #%d cancelada en el servidor.", g_szPrefix, g_iLobbyId );
    }

    CancelLobby( );
}

public mix_web_match_ended( const iScoreA, const iScoreB )
{
    if ( !g_iLobbyId )
    {
        return;
    }

    g_iFinishLobby = g_iLobbyId;
    g_iFinishScoreA = iScoreA;
    g_iFinishScoreB = iScoreB;
    g_iFinishTries = 0;

    BuildStatsPayload( );

    log_amx( "[%s] Partida #%d terminada: %d - %d.", g_szPrefix, g_iLobbyId, iScoreA, iScoreB );

    /* Los callbacks de abandono/reemplazo deben asentarse antes que el cierre
     * porque definen el roster exacto que recibe estadísticas y ELO. */
    ScheduleFinishReport( );

    ReleaseLobby( );
}

BuildStatsPayload( )
{
    new iTotal = mix_web_roster_count( );
    new iLen = 0;
    new bool:bFirst = true;

    iLen += formatex( g_szFinishStats[ iLen ], charsmax( g_szFinishStats ) - iLen, "[" );

    for ( new i = 0; i < iTotal; i++ )
    {
        new iAccId, iKills, iDeaths, iAssists;

        if ( !mix_web_roster_stats( i, iAccId, iKills, iDeaths, iAssists ) )
        {
            continue;
        }

        new iDamage, iHeadshots, iRounds;
        mix_web_roster_advanced_stats( i, iDamage, iHeadshots, iRounds );

        new szEntry[ MAX_STATS_ENTRY ];

        /* "b": abandono, volvio y jugo. MixFinishMatch le da la mitad de la
         * victoria en vez del castigo; sin la marca sigue el castigo normal. */
        new iEntry = formatex( szEntry, charsmax( szEntry ),
            "%s{^"a^":%d,^"k^":%d,^"d^":%d,^"s^":%d,^"m^":%d,^"h^":%d,^"r^":%d,^"b^":%d}",
            bFirst ? "" : ",", iAccId, iKills, iDeaths, iAssists, iDamage, iHeadshots, iRounds,
            mix_web_roster_returned( i ) ? 1 : 0 );

        if ( iLen + iEntry > charsmax( g_szFinishStats ) - 1 )
        {
            log_amx( "[%s] El reporte de la partida #%d no entra en el buffer: quedaron %d jugadores afuera.",
                g_szPrefix, g_iFinishLobby, iTotal - i );

            break;
        }

        iLen += formatex( g_szFinishStats[ iLen ], charsmax( g_szFinishStats ) - iLen, "%s", szEntry );

        bFirst = false;
    }

    formatex( g_szFinishStats[ iLen ], charsmax( g_szFinishStats ) - iLen, "]" );
}

SendFinishReport( )
{
    if ( !g_iFinishLobby )
    {
        return;
    }

    DB_StmtBindInt( 0, g_iFinishLobby );
    DB_StmtBindInt( 1, g_iFinishScoreA );
    DB_StmtBindInt( 2, g_iFinishScoreB );
    DB_StmtBindString( 3, g_szFinishStats );

    DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_FinishMatch", "SendFinishReport", g_szQueryFinishMatch );
}

ScheduleFinishReport( )
{
    if ( !g_iFinishLobby )
    {
        return;
    }

    remove_task( TASK_FINISH_RETRY );

    /* Tanto el abandono como el reemplazo cambian qué filas participan del
     * resultado. MixFinishMatch solo puede correr después de ambos tipos de
     * callback; de lo contrario un suplente podía quedar fuera del ELO. */
    if ( g_iPendingAbandonQueries > 0 || g_iPendingReplaceQueries > 0 )
    {
        set_task( FINISH_SETTLE_DELAY, "OnTaskRetryFinish", TASK_FINISH_RETRY );

        return;
    }

    SendFinishReport( );
}

public OnTaskRetryFinish( )
{
    ScheduleFinishReport( );
}

public Query_FinishMatch( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( bSuccess )
    {
        g_iFinishLobby = 0;

        return;
    }

    if ( ++g_iFinishTries >= MAX_FINISH_RETRIES )
    {
        log_amx( "[%s] No se pudo asentar el resultado de la partida #%d (%d - %d) tras %d intentos.",
            g_szPrefix, g_iFinishLobby, g_iFinishScoreA, g_iFinishScoreB, g_iFinishTries );

        g_iFinishLobby = 0;

        return;
    }

    log_amx( "[%s] Fallo al reportar el resultado de la #%d, reintento %d.",
        g_szPrefix, g_iFinishLobby, g_iFinishTries );

    set_task( FINISH_RETRY_DELAY, "OnTaskRetryFinish", TASK_FINISH_RETRY );
}

public Account_UserLogged( const iId, const iAccId, const iSessionId, const mariadb_result:hResult )
{
    if ( !g_iLobbyId || !mix_web_is_active( ) )
    {
        return;
    }

    g_iLoginDeadline[ iId ] = 0;

    EnforceSlotGuard( );

    if ( g_bKickPending[ iId ] )
    {
        return;
    }
}

public mix_web_player_joined( const iAccId )
{
    if ( !g_iLobbyId || !mix_web_is_active( ) || !IsRosterAccId( iAccId ) )
    {
        return;
    }

    SendPlayerConnected( g_iLobbyId, iAccId, 1 );
}

SendPlayerConnected( const iLobbyId, const iAccId, const iTry )
{
    new JSON:jContext = json_init_object( );

    json_object_set_number( jContext, "lobby", iLobbyId );
    json_object_set_number( jContext, "accid", iAccId );
    json_object_set_number( jContext, "try", iTry );

    DB_StmtBindInt( 0, iLobbyId );
    DB_StmtBindInt( 1, iAccId );

    g_iPendingConnectedQueries++;

    DB_ThreadStmt( g_hDatabase, jContext, "Query_PlayerConnected", "SendPlayerConnected", g_szQueryPlayerConnected );
}

public Query_PlayerConnected( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( g_iPendingConnectedQueries > 0 )
    {
        g_iPendingConnectedQueries--;
    }

    new iLobbyId = json_object_get_number( jObject, "lobby" );
    new iAccId = json_object_get_number( jObject, "accid" );
    new iTry = json_object_get_number( jObject, "try" );

    if ( !bSuccess )
    {
        if ( iTry < MAX_CONNECTED_RETRIES && g_iLobbyId == iLobbyId && IsRosterAccId( iAccId ) )
        {
            log_amx( "[%s] Fallo al confirmar ingreso de accid %d en #%d; reintento %d/%d.",
                g_szPrefix, iAccId, iLobbyId, iTry + 1, MAX_CONNECTED_RETRIES );

            SendPlayerConnected( iLobbyId, iAccId, iTry + 1 );

            return;
        }

        log_amx( "[%s] No se pudo confirmar el ingreso de accid %d en la partida #%d.", g_szPrefix, iAccId, iLobbyId );
    }

    /* Si el reloj físico ya llegó a cero, el último callback decide enseguida
     * con la verdad asentada; no se espera otro tick de treinta segundos. */
    if ( g_iPendingConnectedQueries == 0 && g_iLobbyId == iLobbyId && g_iJoinWaitRemaining <= 0 )
    {
        CheckJoinWait( );
    }
}

/* =================================================================================
* 				[ Lobby Release ]
* ================================================================================= */

CancelLobby( )
{
    if ( !g_iLobbyId )
    {
        return;
    }

    DB_StmtBindInt( 0, g_iLobbyId );

    if ( g_bNoShowTimeout )
    {
        DB_StmtBindString( 1, g_szNoShowAbsent );

        DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_CancelNoShowLobby", "CancelLobby", g_szQueryCancelNoShowLobby );
    }
    else
    {
        DB_ThreadStmt( g_hDatabase, Invalid_JSON, "Query_CancelLobby", "CancelLobby", g_szQueryCancelLobby );
    }

    ReleaseLobby( );
}

public Query_CancelLobby( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( !bSuccess )
    {
        log_amx( "[%s] Fallo al cancelar la sala.", g_szPrefix );
    }
}

public Query_CancelNoShowLobby( bool:bSuccess, mariadb_result:hQuery, JSON:jObject )
{
    if ( !bSuccess )
    {
        log_amx( "[%s] Fallo la cancelacion atomica por no-show.", g_szPrefix );
    }
}

ReleaseLobby( )
{
    remove_task( TASK_JOIN_WAIT );

    g_iJoinWaitRemaining = 0;
    g_bJoinWaitBusy = false;
    g_bNoShowTimeout = false;
    g_szNoShowAbsent[ 0 ] = EOS;
    g_iLobbyId = 0;
    g_iLobbyMisses = 0;
    g_szLobbyMap[ 0 ] = EOS;
    g_szLobbyMode[ 0 ] = EOS;
    g_iLobbyTeamSize = 0;
    g_bChangingLevel = false;

    StopSlotGuard( );

    mix_web_clear_roster( );

    KeepServerPublic( );

    StartClaimLoop( );
}

KeepServerPublic( )
{
    server_cmd( "sv_password ^"^"" );
    server_exec( );
}
