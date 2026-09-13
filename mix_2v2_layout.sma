#include <amxmodx>
#include <amxmisc>
#include <engine>
#include <fakemeta>
#include <reapi>

#include "accsys/accounts"
#include "accsys/hierarchy"
#include <mix_core>

/* =================================================================================
* 				[ Constants ]
* ================================================================================= */

new const PLUGIN_NAME[ ]				= "[ZG] AUTOMIX: 2v2 Layout";
new const PLUGIN_VERSION[ ]			= "3.3";
new const PLUGIN_AUTHOR[ ]				= "metita";

const MIX_STATUS_LIVE					= 4;
const MIX_STATUS_OVERTIME				= 5;

const TASK_LOAD_LAYOUT					= 7210;
const TASK_OPEN_EDITOR					= 7250;
const TASK_PLACE_PLAYER					= 7290;
const TASK_SHOW_BARRIERS				= 7330;

const Float:TASK_DELAY_LOAD_LAYOUT		= 0.5;
const Float:TASK_DELAY_OPEN_EDITOR		= 2.0;
const Float:TASK_DELAY_PLACE_PLAYER		= 0.15;
const Float:TASK_DELAY_SHOW_BARRIERS		= 0.55;

/* =================================================================================
* 				[ Enumerations ]
* ================================================================================= */

enum _:BombSites
{
	BOMBSITE_A,
	BOMBSITE_B
};

enum _:SpawnTeams
{
	SPAWN_TEAM_T,
	SPAWN_TEAM_CT
};

enum _:Spawn_Struct
{
	Spawn_Site,
	Spawn_Team,
	Float:Spawn_Origin[ 3 ],
	Float:Spawn_Angles[ 3 ]
};

enum _:Barrier_Struct
{
	Float:Barrier_FirstPoint[ 3 ],
	Float:Barrier_SecondPoint[ 3 ]
};

/* =================================================================================
* 				[ Constants - Names ]
* ================================================================================= */

new const g_szSiteNames[ ][ ]			= { "A", "B" };
new const g_szTeamNames[ ][ ]			= { "TT", "CT" };
new const g_szInfoTargetClassname[ ]		= "info_target";
new const g_szBarrierClassname[ ]		= "mix2v2_wall";

/* =================================================================================
* 				[ Global Variables ]
* ================================================================================= */

new Array:g_aSpawns;
new Array:g_aBarriers;

new g_iSpawnsCount;
new g_iBarriersCount;
new g_iActiveSite;

new g_szMapName[ 64 ];
new g_szMapConfigPath[ 192 ];

new g_pCvarLayoutEnabled;

new g_iLaserBeam;

new g_iSelectedSite[ MAX_PLAYERS + 1 ];
new bool:g_bBarrierFirstPointSet[ MAX_PLAYERS + 1 ];
new Float:g_flBarrierFirstPoint[ MAX_PLAYERS + 1 ][ 3 ];
new g_iPlayerPlacedRound[ MAX_PLAYERS + 1 ];
new g_iPlayerPlacedSpawn[ MAX_PLAYERS + 1 ];
new g_iLastAnnouncedRound;
new g_iLastWarningRound;
new bool:g_bWarnedSpawnTeam[ 2 ];

/* =================================================================================
* 				[ Plugin Events ]
* ================================================================================= */

public plugin_precache( )
{
	g_iLaserBeam = precache_model( "sprites/laserbeam.spr" );

	g_aSpawns = ArrayCreate( Spawn_Struct, 1 );
	g_aBarriers = ArrayCreate( Barrier_Struct, 1 );
}

public plugin_init( )
{
	register_plugin( PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR );

	register_clcmd( "mix2v2_spawns", "ClientCommand_Spawns" );
	register_clcmd( "mix2v2_menu", "ClientCommand_Spawns" );
	register_clcmd( "amx_mix2v2_menu", "ClientCommand_Spawns" );

	g_pCvarLayoutEnabled = register_cvar( "mix2v2_layout_enabled", "1" );

	RegisterHookChain( RG_CBasePlayer_Spawn, "OnPlayerSpawn_Post", true );
}

public plugin_cfg( )
{
	rh_get_mapname( g_szMapName, charsmax( g_szMapName ) );
	set_task( TASK_DELAY_LOAD_LAYOUT, "OnTaskLoadLayout", TASK_LOAD_LAYOUT );
}

public plugin_end( )
{
	if ( g_aSpawns )
	{
		ArrayDestroy( g_aSpawns );
	}

	if ( g_aBarriers )
	{
		RemoveBarrierEntities( );
		ArrayDestroy( g_aBarriers );
	}
}

public OnTaskLoadLayout( )
{
	LoadLayout( );
}

/* =================================================================================
* 				[ Client Events ]
* ================================================================================= */

public client_putinserver( iId )
{
	g_iSelectedSite[ iId ] = BOMBSITE_A;
	g_bBarrierFirstPointSet[ iId ] = false;
	g_iPlayerPlacedRound[ iId ] = 0;
	g_iPlayerPlacedSpawn[ iId ] = -1;

	/* También se abre automáticamente al terminar el login de AccSys. El
	 * comando mix2v2_spawns queda disponible para volver a abrirlo. */
	set_task( TASK_DELAY_OPEN_EDITOR, "OnTaskOpenEditor", TASK_OPEN_EDITOR + iId );
}

public OnTaskOpenEditor( const iTaskId )
{
	new iId = iTaskId - TASK_OPEN_EDITOR;

	if ( iId >= 1 && iId <= MAX_PLAYERS && CanUseEditor( iId ) )
	{
		ShowMainMenu( iId );
	}
}

public ClientCommand_Spawns( const iId )
{
	if ( !CanUseEditor( iId ) )
	{
		PrintEditorAccessError( iId );
		return PLUGIN_HANDLED;
	}

	ShowMainMenu( iId );
	return PLUGIN_HANDLED;
}

public Account_UserLogged( const iId, const iAccId, const iSessionId, const mariadb_result:hResult )
{
	if ( CanUseEditor( iId ) )
	{
		remove_task( TASK_OPEN_EDITOR + iId );
		ShowMainMenu( iId );
	}
}

public client_disconnected( iId )
{
	remove_task( TASK_OPEN_EDITOR + iId );
	remove_task( TASK_PLACE_PLAYER + iId );
	HideBarriers( iId );

	g_bBarrierFirstPointSet[ iId ] = false;
	g_iPlayerPlacedRound[ iId ] = 0;
	g_iPlayerPlacedSpawn[ iId ] = -1;
}

/* =================================================================================
* 				[ Player Spawn Layout ]
* ================================================================================= */

public OnPlayerSpawn_Post( const iId )
{
	if ( !is_user_alive( iId ) )
	{
		return;
	}

	remove_task( TASK_PLACE_PLAYER + iId );
	set_task( TASK_DELAY_PLACE_PLAYER, "OnTaskPlacePlayer", TASK_PLACE_PLAYER + iId );
}

public OnTaskPlacePlayer( const iTaskId )
{
	new iId = iTaskId - TASK_PLACE_PLAYER;
	new iRound;
	new TeamName:iTeam;
	new iSpawnTeam;
	new iSite;
	new iSpawn;
	new sSpawn[ Spawn_Struct ];
	new Float:flVelocity[ 3 ];

	if ( iId < 1 || iId > MAX_PLAYERS || !is_user_alive( iId ) )
	{
		return;
	}

	if ( !IsLayoutActive( ) || !Is2v2Server( ) )
	{
		return;
	}

	/* Solo se mueve durante el freeze de la ronda. Un jugador que reconecta
	 * durante LIVE conserva el spawn normal del mapa. */
	if ( !get_member_game( m_bFreezePeriod ) )
	{
		return;
	}

	iRound = mix_web_round_number( );
	if ( iRound <= 0 || g_iPlayerPlacedRound[ iId ] == iRound )
	{
		return;
	}

	iTeam = get_member( iId, m_iTeam );

	if ( iTeam == TEAM_TERRORIST )
	{
		iSpawnTeam = SPAWN_TEAM_T;
	}
	else if ( iTeam == TEAM_CT )
	{
		iSpawnTeam = SPAWN_TEAM_CT;
	}
	else
	{
		return;
	}

	iSite = GetActiveSite( );
	iSpawn = FindFreeSpawn( iRound, iSite, iSpawnTeam, iId );

	if ( iSpawn < 0 )
	{
		WarnMissingSpawns( iRound, iSite, iSpawnTeam );
		/* No hay teletransporte parcial: el jugador conserva el spawn normal
		 * si el administrador aun no ha creado suficientes posiciones. */
		g_iPlayerPlacedRound[ iId ] = iRound;
		return;
	}

	ArrayGetArray( g_aSpawns, iSpawn, sSpawn );

	flVelocity[ 0 ] = 0.0;
	flVelocity[ 1 ] = 0.0;
	flVelocity[ 2 ] = 0.0;

	if ( !IsHullVacant( sSpawn[ Spawn_Origin ], iId ) )
	{
		WarnBlockedSpawn( iRound, iSite, iSpawnTeam );
		g_iPlayerPlacedRound[ iId ] = iRound;
		return;
	}

	set_entvar( iId, var_origin, sSpawn[ Spawn_Origin ] );
	set_entvar( iId, var_angles, sSpawn[ Spawn_Angles ] );
	set_entvar( iId, var_v_angle, sSpawn[ Spawn_Angles ] );
	set_entvar( iId, var_velocity, flVelocity );

	g_iPlayerPlacedRound[ iId ] = iRound;
	g_iPlayerPlacedSpawn[ iId ] = iSpawn;

	if ( g_iLastAnnouncedRound != iRound )
	{
		g_iLastAnnouncedRound = iRound;
		client_print_color( 0, print_team_default, "^4[2v2]^1 Ronda^3 %d^1: se juega en^4 BOMBSITE %s^1.", iRound, g_szSiteNames[ iSite ] );
	}
}

bool:IsLayoutActive( )
{
	new iStatus = mix_web_match_status( );

	return get_pcvar_num( g_pCvarLayoutEnabled ) && ( iStatus == MIX_STATUS_LIVE || iStatus == MIX_STATUS_OVERTIME );
}

/* =================================================================================
* 				[ Layout Helpers ]
* ================================================================================= */

bool:Is2v2Server( )
{
	new szMode[ 16 ];
	get_cvar_string( "mix_web_mode", szMode, charsmax( szMode ) );
	return bool:equali( szMode, "2v2" );
}

bool:CanUseEditor( const iId )
{
	return iId >= 1 && iId <= MAX_PLAYERS && is_user_connected( iId ) && Account_IsUserLogged( iId ) && IsPlayerRank( iId, "rh" ) && Is2v2Server( );
}

PrintEditorAccessError( const iId )
{
	if ( !is_user_connected( iId ) )
	{
		return;
	}

	if ( !Account_IsUserLogged( iId ) )
	{
		client_print_color( iId, print_team_default, "^4[2v2]^1 Debes iniciar sesion con AccSys antes de abrir el editor." );
	}
	else if ( !IsPlayerRank( iId, "rh" ) )
	{
		client_print_color( iId, print_team_default, "^4[2v2]^1 No tienes permisos. El editor requiere rango^4 RH^1." );
	}
	else if ( !Is2v2Server( ) )
	{
		client_print_color( iId, print_team_default, "^4[2v2]^1 Este menu solo esta disponible en el servidor 2v2." );
	}
}

GetActiveSite( )
{
	/* Wingman usa un solo bombsite fijo durante todo el mapa. */
	return g_iActiveSite;
}

FindFreeSpawn( const iRound, const iSite, const iTeam, const iId )
{
	new sSpawn[ Spawn_Struct ];
	new iSpawnsCount = ArraySize( g_aSpawns );

	for ( new i = 0; i < iSpawnsCount; i++ )
	{
		ArrayGetArray( g_aSpawns, i, sSpawn );

		if ( sSpawn[ Spawn_Site ] != iSite || sSpawn[ Spawn_Team ] != iTeam )
		{
			continue;
		}

		if ( IsSpawnUsed( iRound, i, iId ) )
		{
			continue;
		}

		if ( IsHullVacant( sSpawn[ Spawn_Origin ], iId ) )
		{
			return i;
		}
	}

	return -1;
}

bool:IsSpawnUsed( const iRound, const iSpawn, const iIgnoreId )
{
	for ( new i = 1; i <= MAX_PLAYERS; i++ )
	{
		if ( i == iIgnoreId || g_iPlayerPlacedRound[ i ] != iRound )
		{
			continue;
		}

		if ( g_iPlayerPlacedSpawn[ i ] == iSpawn )
		{
			return true;
		}
	}

	return false;
}

WarnMissingSpawns( const iRound, const iSite, const iTeam )
{
	ResetRoundWarnings( iRound );

	if ( g_bWarnedSpawnTeam[ iTeam ] )
	{
		return;
	}

	g_bWarnedSpawnTeam[ iTeam ] = true;
	server_print( "[%s] No hay suficientes spawns para BOMBSITE %s / %s en %s.", PLUGIN_NAME, g_szSiteNames[ iSite ], g_szTeamNames[ iTeam ], g_szMapName );
}

WarnBlockedSpawn( const iRound, const iSite, const iTeam )
{
	ResetRoundWarnings( iRound );

	if ( g_bWarnedSpawnTeam[ iTeam ] )
	{
		return;
	}

	g_bWarnedSpawnTeam[ iTeam ] = true;
	server_print( "[%s] Los spawns de BOMBSITE %s / %s estan bloqueados; se conserva el spawn normal.", PLUGIN_NAME, g_szSiteNames[ iSite ], g_szTeamNames[ iTeam ] );
}

ResetRoundWarnings( const iRound )
{
	if ( g_iLastWarningRound == iRound )
	{
		return;
	}

	g_iLastWarningRound = iRound;
	g_bWarnedSpawnTeam[ SPAWN_TEAM_T ] = false;
	g_bWarnedSpawnTeam[ SPAWN_TEAM_CT ] = false;
}

bool:IsHullVacant( const Float:flOrigin[ 3 ], const iId )
{
	engfunc( EngFunc_TraceHull, flOrigin, flOrigin, DONT_IGNORE_MONSTERS, HULL_HUMAN, iId, 0 );
	return !get_tr2( 0, TR_StartSolid ) && !get_tr2( 0, TR_AllSolid );
}

/* =================================================================================
* 				[ Main Menu ]
* ================================================================================= */

ShowMainMenu( const iId )
{
	if ( !CanUseEditor( iId ) )
	{
		return PLUGIN_HANDLED;
	}

	HideBarriers( iId );

	new iTeamCounts[ 2 ];
	GetSiteTeamCounts( g_iActiveSite, iTeamCounts );

	new iMenu = menu_create( fmt( "\y[2v2] \wEditor de mapa^n\d%s | Site %s | TT %d · CT %d | %d paredes", g_szMapName, g_szSiteNames[ g_iActiveSite ], iTeamCounts[ SPAWN_TEAM_T ], iTeamCounts[ SPAWN_TEAM_CT ], g_iBarriersCount ), "OnMainMenuHandler" );

	menu_additem( iMenu, fmt( "Spawns del bombsite \y%s", g_szSiteNames[ g_iActiveSite ] ) );
	menu_additem( iMenu, fmt( "Bombsite activo: \y%s", g_szSiteNames[ g_iActiveSite ] ) );
	menu_additem( iMenu, "Paredes de bloqueo" );

	menu_addblank( iMenu, false );

	menu_additem( iMenu, "Validar configuracion" );
	menu_additem( iMenu, "\yGuardar configuracion" );

	menu_setprop( iMenu, MPROP_EXITNAME, "Salir" );
	menu_display( iId, iMenu );

	return PLUGIN_HANDLED;
}

public OnMainMenuHandler( const iId, const iMenu, const iItem )
{
	menu_destroy( iMenu );

	if ( iItem == MENU_EXIT || !CanUseEditor( iId ) )
	{
		return PLUGIN_HANDLED;
	}

	switch ( iItem )
	{
		case 0: ShowSiteMenu( iId, g_iActiveSite );
		case 1: ShowSiteSelectionMenu( iId );
		case 2: ShowBarrierMenu( iId );
		case 3:
		{
			ValidateLayout( iId );
			ShowMainMenu( iId );
		}
		case 4:
		{
			SaveLayout( );
			PrintEditor( iId, "Configuracion guardada correctamente." );
			ShowMainMenu( iId );
		}
	}

	return PLUGIN_HANDLED;
}

/* =================================================================================
* 				[ Site Selection Menu ]
* ================================================================================= */

ShowSiteSelectionMenu( const iId )
{
	if ( !CanUseEditor( iId ) )
	{
		return;
	}

	HideBarriers( iId );

	new iMenu = menu_create( "\y[2v2] \wBombsite activo", "OnSiteSelectionMenuHandler" );

	menu_additem( iMenu, "Bombsite \yA" );
	menu_additem( iMenu, "Bombsite \yB" );

	menu_setprop( iMenu, MPROP_EXITNAME, "Volver" );
	menu_display( iId, iMenu );
}

public OnSiteSelectionMenuHandler( const iId, const iMenu, const iItem )
{
	menu_destroy( iMenu );

	if ( !CanUseEditor( iId ) )
	{
		return PLUGIN_HANDLED;
	}

	if ( iItem == MENU_EXIT )
	{
		ShowMainMenu( iId );
		return PLUGIN_HANDLED;
	}

	if ( iItem == BOMBSITE_A || iItem == BOMBSITE_B )
	{
		g_iActiveSite = iItem;
		SaveLayout( );
		PrintEditor( iId, "Bombsite activo: %s.", g_szSiteNames[ g_iActiveSite ] );
	}

	ShowMainMenu( iId );
	return PLUGIN_HANDLED;
}

/* =================================================================================
* 				[ Spawns Menu ]
* ================================================================================= */

ShowSiteMenu( const iId, const iSite )
{
	if ( !CanUseEditor( iId ) )
	{
		return PLUGIN_HANDLED;
	}

	HideBarriers( iId );
	g_iSelectedSite[ iId ] = iSite;

	new iTeamCounts[ 2 ];
	GetSiteTeamCounts( iSite, iTeamCounts );

	new iMenu = menu_create( fmt( "\y[2v2] \wSpawns · Site %s^n\dTT %d · CT %d", g_szSiteNames[ iSite ], iTeamCounts[ SPAWN_TEAM_T ], iTeamCounts[ SPAWN_TEAM_CT ] ), "OnSiteMenuHandler" );

	menu_additem( iMenu, "Crear spawn \yTT\w donde estoy" );
	menu_additem( iMenu, "Crear spawn \yCT\w donde estoy" );

	menu_addblank( iMenu, false );

	menu_additem( iMenu, "Eliminar spawn apuntado" );
	menu_additem( iMenu, "\rEliminar todos los spawns" );

	menu_setprop( iMenu, MPROP_EXITNAME, "Volver" );
	menu_display( iId, iMenu );

	return PLUGIN_HANDLED;
}

public OnSiteMenuHandler( const iId, const iMenu, const iItem )
{
	menu_destroy( iMenu );

	if ( !CanUseEditor( iId ) )
	{
		return PLUGIN_HANDLED;
	}

	if ( iItem == MENU_EXIT )
	{
		ShowMainMenu( iId );
		return PLUGIN_HANDLED;
	}

	new iSite = g_iSelectedSite[ iId ];

	switch ( iItem )
	{
		case 0: CreateSpawn( iId, iSite, SPAWN_TEAM_T );
		case 1: CreateSpawn( iId, iSite, SPAWN_TEAM_CT );
		case 2: DeleteSpawnFromAim( iId, iSite );
		case 3:
		{
			ShowClearSiteMenu( iId, iSite );
			return PLUGIN_HANDLED;
		}
	}

	ShowSiteMenu( iId, iSite );
	return PLUGIN_HANDLED;
}

/* =================================================================================
* 				[ Barriers Menu ]
* ================================================================================= */

ShowBarrierMenu( const iId )
{
	if ( !CanUseEditor( iId ) )
	{
		return PLUGIN_HANDLED;
	}

	ShowBarriers( iId );

	new iMenu;

	if ( g_bBarrierFirstPointSet[ iId ] )
	{
		iMenu = menu_create( fmt( "\y[2v2] \wParedes de bloqueo^n\d%d configuradas · punto 1 marcado^n\wApunta a la \yesquina opuesta", g_iBarriersCount ), "OnBarrierMenuHandler" );
		menu_additem( iMenu, "Marcar \ypunto 2\w y crear pared" );
		menu_additem( iMenu, "Cancelar punto marcado" );
	}
	else
	{
		iMenu = menu_create( fmt( "\y[2v2] \wParedes de bloqueo^n\d%d configuradas · contorno visible^n\wApunta a una \yesquina\w de la pared", g_iBarriersCount ), "OnBarrierMenuHandler" );
		menu_additem( iMenu, "Marcar \ypunto 1" );
		menu_additem( iMenu, "\dPrimero marca el punto 1" );
	}

	menu_addblank( iMenu, false );

	menu_additem( iMenu, "Eliminar pared apuntada" );
	menu_additem( iMenu, "\rEliminar todas las paredes" );

	menu_setprop( iMenu, MPROP_EXITNAME, "Volver" );
	menu_display( iId, iMenu );

	return PLUGIN_HANDLED;
}

public OnBarrierMenuHandler( const iId, const iMenu, const iItem )
{
	menu_destroy( iMenu );

	if ( !CanUseEditor( iId ) )
	{
		HideBarriers( iId );
		return PLUGIN_HANDLED;
	}

	if ( iItem == MENU_EXIT )
	{
		HideBarriers( iId );
		ShowMainMenu( iId );
		return PLUGIN_HANDLED;
	}

	switch ( iItem )
	{
		case 0:
		{
			if ( g_bBarrierFirstPointSet[ iId ] )
			{
				CreateBarrierFromSecondPoint( iId );
			}
			else
			{
				MarkBarrierFirstPoint( iId );
			}
		}
		case 1:
		{
			if ( g_bBarrierFirstPointSet[ iId ] )
			{
				g_bBarrierFirstPointSet[ iId ] = false;
				PrintEditor( iId, "Punto 1 cancelado." );
			}
			else
			{
				PrintEditor( iId, "Primero debes marcar el punto 1." );
			}
		}
		case 2: DeleteBarrierFromAim( iId );
		case 3:
		{
			ShowClearBarriersMenu( iId );
			return PLUGIN_HANDLED;
		}
	}

	ShowBarrierMenu( iId );
	return PLUGIN_HANDLED;
}

ShowClearBarriersMenu( const iId )
{
	if ( !CanUseEditor( iId ) )
	{
		HideBarriers( iId );
		return;
	}

	new iMenu = menu_create( "\r[2v2] \w¿Eliminar todas las paredes?", "OnClearBarriersMenuHandler" );

	menu_additem( iMenu, "\rSi, eliminar todas" );

	menu_setprop( iMenu, MPROP_EXITNAME, "No, volver" );
	menu_display( iId, iMenu );
}

public OnClearBarriersMenuHandler( const iId, const iMenu, const iItem )
{
	menu_destroy( iMenu );

	if ( !CanUseEditor( iId ) )
	{
		HideBarriers( iId );
		return PLUGIN_HANDLED;
	}

	if ( iItem == 0 )
	{
		g_bBarrierFirstPointSet[ iId ] = false;
		RemoveBarrierEntities( );
		ArrayClear( g_aBarriers );
		g_iBarriersCount = 0;
		SaveLayout( );
		PrintEditor( iId, "Todas las paredes fueron eliminadas." );
	}

	ShowBarrierMenu( iId );
	return PLUGIN_HANDLED;
}

ShowClearSiteMenu( const iId, const iSite )
{
	if ( !CanUseEditor( iId ) )
	{
		return;
	}

	HideBarriers( iId );

	new iMenu = menu_create( fmt( "\r[2v2] \w¿Eliminar los spawns del site %s?", g_szSiteNames[ iSite ] ), "OnClearSiteMenuHandler" );

	menu_additem( iMenu, "\rSi, eliminar todos" );

	menu_setprop( iMenu, MPROP_EXITNAME, "No, volver" );
	menu_display( iId, iMenu );
}

public OnClearSiteMenuHandler( const iId, const iMenu, const iItem )
{
	menu_destroy( iMenu );

	if ( !CanUseEditor( iId ) )
	{
		return PLUGIN_HANDLED;
	}

	if ( iItem == 0 )
	{
		ClearSiteSpawns( g_iSelectedSite[ iId ] );
		SaveLayout( );
		PrintEditor( iId, "Spawns del bombsite %s eliminados.", g_szSiteNames[ g_iSelectedSite[ iId ] ] );
	}

	ShowSiteMenu( iId, g_iSelectedSite[ iId ] );
	return PLUGIN_HANDLED;
}

/* =================================================================================
* 				[ Barrier Visualization ]
* ================================================================================= */

ShowBarriers( const iId )
{
	if ( !is_user_connected( iId ) )
	{
		return;
	}

	remove_task( TASK_SHOW_BARRIERS + iId );
	set_task( TASK_DELAY_SHOW_BARRIERS, "OnTaskShowBarriers", TASK_SHOW_BARRIERS + iId,  .flags = "b" );

	DrawBarriers( iId );
}

HideBarriers( const iId )
{
	if ( iId < 1 || iId > MAX_PLAYERS )
	{
		return;
	}

	remove_task( TASK_SHOW_BARRIERS + iId );
	g_bBarrierFirstPointSet[ iId ] = false;
}

public OnTaskShowBarriers( const iTaskId )
{
	new iId = iTaskId - TASK_SHOW_BARRIERS;

	if ( iId < 1 || iId > MAX_PLAYERS || !is_user_connected( iId ) )
	{
		remove_task( iTaskId );
		return;
	}

	DrawBarriers( iId );
}

DrawBarriers( const iId )
{
	if ( !g_iLaserBeam || !is_user_connected( iId ) || ( g_iBarriersCount <= 0 && !g_bBarrierFirstPointSet[ iId ] ) )
	{
		return;
	}

	new sBarrier[ Barrier_Struct ];

	for ( new i = 0; i < g_iBarriersCount; i++ )
	{
		ArrayGetArray( g_aBarriers, i, sBarrier );
		DrawBarrierOutline( iId, sBarrier );
	}

	if ( g_bBarrierFirstPointSet[ iId ] )
	{
		DrawPendingBarrier( iId );
	}
}

DrawPendingBarrier( const iId )
{
	new Float:flSecondPoint[ 3 ];
	new sBarrier[ Barrier_Struct ];

	GetAimPoint( iId, flSecondPoint );
	BuildBarrierFromPoints( g_flBarrierFirstPoint[ iId ], flSecondPoint, sBarrier );
	DrawBarrierOutline( iId, sBarrier );
}

DrawBarrierOutline( const iId, const sBarrier[ Barrier_Struct ] )
{
	new Float:flMins[ 3 ];
	new Float:flMaxs[ 3 ];

	GetBarrierBounds( sBarrier, flMins, flMaxs );
	DrawBarrierBox( iId, flMins, flMaxs );
}

DrawBarrierBox( const iId, const Float:flMins[ 3 ], const Float:flMaxs[ 3 ] )
{
	DrawLaser( iId, flMins[ 0 ], flMins[ 1 ], flMins[ 2 ], flMins[ 0 ], flMaxs[ 1 ], flMins[ 2 ] );
	DrawLaser( iId, flMins[ 0 ], flMins[ 1 ], flMins[ 2 ], flMaxs[ 0 ], flMins[ 1 ], flMins[ 2 ] );
	DrawLaser( iId, flMaxs[ 0 ], flMaxs[ 1 ], flMins[ 2 ], flMaxs[ 0 ], flMins[ 1 ], flMins[ 2 ] );
	DrawLaser( iId, flMaxs[ 0 ], flMaxs[ 1 ], flMins[ 2 ], flMins[ 0 ], flMaxs[ 1 ], flMins[ 2 ] );
	DrawLaser( iId, flMins[ 0 ], flMins[ 1 ], flMaxs[ 2 ], flMins[ 0 ], flMaxs[ 1 ], flMaxs[ 2 ] );
	DrawLaser( iId, flMins[ 0 ], flMins[ 1 ], flMaxs[ 2 ], flMaxs[ 0 ], flMins[ 1 ], flMaxs[ 2 ] );
	DrawLaser( iId, flMaxs[ 0 ], flMaxs[ 1 ], flMaxs[ 2 ], flMaxs[ 0 ], flMins[ 1 ], flMaxs[ 2 ] );
	DrawLaser( iId, flMaxs[ 0 ], flMaxs[ 1 ], flMaxs[ 2 ], flMins[ 0 ], flMaxs[ 1 ], flMaxs[ 2 ] );
	DrawLaser( iId, flMins[ 0 ], flMins[ 1 ], flMins[ 2 ], flMins[ 0 ], flMins[ 1 ], flMaxs[ 2 ] );
	DrawLaser( iId, flMins[ 0 ], flMaxs[ 1 ], flMins[ 2 ], flMins[ 0 ], flMaxs[ 1 ], flMaxs[ 2 ] );
	DrawLaser( iId, flMaxs[ 0 ], flMins[ 1 ], flMins[ 2 ], flMaxs[ 0 ], flMins[ 1 ], flMaxs[ 2 ] );
	DrawLaser( iId, flMaxs[ 0 ], flMaxs[ 1 ], flMins[ 2 ], flMaxs[ 0 ], flMaxs[ 1 ], flMaxs[ 2 ] );
}

DrawLaser( const iId, Float:flStartX, Float:flStartY, Float:flStartZ, Float:flEndX, Float:flEndY, Float:flEndZ )
{
	message_begin( MSG_ONE_UNRELIABLE, SVC_TEMPENTITY,  .player = iId );
	write_byte( TE_BEAMPOINTS );
	write_coord_f( flStartX );
	write_coord_f( flStartY );
	write_coord_f( flStartZ );
	write_coord_f( flEndX );
	write_coord_f( flEndY );
	write_coord_f( flEndZ );
	write_short( g_iLaserBeam );
	write_byte( 0 );
	write_byte( 10 );
	write_byte( 9 );
	write_byte( 8 );
	write_byte( 0 );
	write_byte( 255 );
	write_byte( 80 );
	write_byte( 20 );
	write_byte( 220 );
	write_byte( 8 );
	message_end( );
}

/* =================================================================================
* 				[ Editor Actions ]
* ================================================================================= */

CreateSpawn( const iId, const iSite, const iTeam )
{
	if ( !CanUseEditor( iId ) )
	{
		return 0;
	}

	new sSpawn[ Spawn_Struct ];
	sSpawn[ Spawn_Site ] = iSite;
	sSpawn[ Spawn_Team ] = iTeam;

	get_entvar( iId, var_origin, sSpawn[ Spawn_Origin ] );
	get_entvar( iId, var_v_angle, sSpawn[ Spawn_Angles ] );
	sSpawn[ Spawn_Angles ][ 0 ] = 0.0;
	sSpawn[ Spawn_Angles ][ 2 ] = 0.0;

	ArrayPushArray( g_aSpawns, sSpawn );
	g_iSpawnsCount++;
	SaveLayout( );

	PrintEditor( iId, "Spawn %s de BOMBSITE %s creado. Total del site: %d.", g_szTeamNames[ iTeam ], g_szSiteNames[ iSite ], GetSiteSpawnsCount( iSite ) );
	return 1;
}

MarkBarrierFirstPoint( const iId )
{
	if ( !CanUseEditor( iId ) )
	{
		return 0;
	}

	GetAimPoint( iId, g_flBarrierFirstPoint[ iId ] );
	g_bBarrierFirstPointSet[ iId ] = true;

	PrintEditor( iId, "Punto 1 marcado. El punto 2 debe ser la esquina opuesta: define ancho, grosor y altura." );
	return 1;
}

CreateBarrierFromSecondPoint( const iId )
{
	if ( !CanUseEditor( iId ) || !g_bBarrierFirstPointSet[ iId ] )
	{
		return 0;
	}

	new Float:flSecondPoint[ 3 ];
	new sBarrier[ Barrier_Struct ];
	new Float:flSize[ 3 ];
	new iIndex;

	GetAimPoint( iId, flSecondPoint );

	for ( new i = 0; i < 3; i++ )
	{
		flSize[ i ] = floatabs( flSecondPoint[ i ] - g_flBarrierFirstPoint[ iId ][ i ] );
	}

	if ( flSize[ 0 ] < 1.0 || flSize[ 1 ] < 1.0 || flSize[ 2 ] < 1.0 )
	{
		PrintEditor( iId, "La esquina opuesta debe cambiar X, Y y Z para definir ancho, grosor y altura." );
		return 0;
	}

	BuildBarrierFromPoints( g_flBarrierFirstPoint[ iId ], flSecondPoint, sBarrier );

	ArrayPushArray( g_aBarriers, sBarrier );
	g_iBarriersCount++;

	iIndex = g_iBarriersCount - 1;
	CreateBarrierEntity( iIndex );

	g_bBarrierFirstPointSet[ iId ] = false;
	SaveLayout( );
	PrintEditor( iId, "Pared creada: %.0f x %.0f x %.0f unidades.", flSize[ 0 ], flSize[ 1 ], flSize[ 2 ] );
	return 1;
}

GetAimPoint( const iId, Float:flPoint[ 3 ] )
{
	new iAimOrigin[ 3 ];
	get_user_origin( iId, iAimOrigin, 3 );

	flPoint[ 0 ] = float( iAimOrigin[ 0 ] );
	flPoint[ 1 ] = float( iAimOrigin[ 1 ] );
	flPoint[ 2 ] = float( iAimOrigin[ 2 ] );
}

BuildBarrierFromPoints( const Float:flFirstPoint[ 3 ], const Float:flSecondPoint[ 3 ], sBarrier[ Barrier_Struct ] )
{
	for ( new i = 0; i < 3; i++ )
	{
		sBarrier[ Barrier_FirstPoint ][ i ] = flFirstPoint[ i ];
		sBarrier[ Barrier_SecondPoint ][ i ] = flSecondPoint[ i ];
	}
}

GetBarrierBounds( const sBarrier[ Barrier_Struct ], Float:flMins[ 3 ], Float:flMaxs[ 3 ] )
{
	for ( new i = 0; i < 3; i++ )
	{
		flMins[ i ] = floatmin( sBarrier[ Barrier_FirstPoint ][ i ], sBarrier[ Barrier_SecondPoint ][ i ] );
		flMaxs[ i ] = floatmax( sBarrier[ Barrier_FirstPoint ][ i ], sBarrier[ Barrier_SecondPoint ][ i ] );
	}
}

DeleteBarrierFromAim( const iId )
{
	if ( g_iBarriersCount <= 0 )
	{
		PrintEditor( iId, "No hay paredes configuradas." );
		return 0;
	}

	new iAimOrigin[ 3 ];
	new Float:flPoint[ 3 ];
	new iClosest;

	get_user_origin( iId, iAimOrigin, 3 );

	flPoint[ 0 ] = float( iAimOrigin[ 0 ] );
	flPoint[ 1 ] = float( iAimOrigin[ 1 ] );
	flPoint[ 2 ] = float( iAimOrigin[ 2 ] );

	iClosest = FindClosestBarrier( flPoint );
	if ( iClosest < 0 )
	{
		PrintEditor( iId, "No hay una pared cercana en el punto apuntado." );
		return 0;
	}

	DeleteBarrier( iClosest );
	SaveLayout( );
	PrintEditor( iId, "Pared eliminada. Quedan %d.", g_iBarriersCount );
	return 1;
}

DeleteSpawnFromAim( const iId, const iSite )
{
	if ( g_iSpawnsCount <= 0 )
	{
		PrintEditor( iId, "No hay spawns configurados." );
		return 0;
	}

	new iAimOrigin[ 3 ];
	new Float:flPoint[ 3 ];
	new iClosest;
	new sSpawn[ Spawn_Struct ];

	get_user_origin( iId, iAimOrigin, 3 );

	flPoint[ 0 ] = float( iAimOrigin[ 0 ] );
	flPoint[ 1 ] = float( iAimOrigin[ 1 ] );
	flPoint[ 2 ] = float( iAimOrigin[ 2 ] );

	iClosest = FindClosestSpawn( flPoint, iSite );
	if ( iClosest < 0 )
	{
		PrintEditor( iId, "No hay un spawn cercano en este site." );
		return 0;
	}

	ArrayGetArray( g_aSpawns, iClosest, sSpawn );
	ArrayDeleteItem( g_aSpawns, iClosest );
	g_iSpawnsCount--;
	SaveLayout( );

	PrintEditor( iId, "Spawn %s de BOMBSITE %s eliminado. Quedan %d.", g_szTeamNames[ sSpawn[ Spawn_Team ] ], g_szSiteNames[ sSpawn[ Spawn_Site ] ], GetSiteSpawnsCount( sSpawn[ Spawn_Site ] ) );
	return 1;
}

FindClosestSpawn( const Float:flPoint[ 3 ], const iSite )
{
	new iClosest = -1;
	new Float:flClosestDistance = 128.0;
	new Float:flDistance;
	new sSpawn[ Spawn_Struct ];

	for ( new i = 0; i < ArraySize( g_aSpawns ); i++ )
	{
		ArrayGetArray( g_aSpawns, i, sSpawn );

		if ( iSite >= 0 && sSpawn[ Spawn_Site ] != iSite )
		{
			continue;
		}

		flDistance = get_distance_f( flPoint, sSpawn[ Spawn_Origin ] );
		if ( flDistance < flClosestDistance )
		{
			flClosestDistance = flDistance;
			iClosest = i;
		}
	}

	return iClosest;
}

ClearSiteSpawns( const iSite )
{
	new sSpawn[ Spawn_Struct ];

	for ( new i = ArraySize( g_aSpawns ) - 1; i >= 0; i-- )
	{
		ArrayGetArray( g_aSpawns, i, sSpawn );

		if ( sSpawn[ Spawn_Site ] == iSite )
		{
			ArrayDeleteItem( g_aSpawns, i );
			g_iSpawnsCount--;
		}
	}
}

GetSiteSpawnsCount( const iSite )
{
	new iSpawnsCount;
	new sSpawn[ Spawn_Struct ];

	for ( new i = 0; i < ArraySize( g_aSpawns ); i++ )
	{
		ArrayGetArray( g_aSpawns, i, sSpawn );
		if ( sSpawn[ Spawn_Site ] == iSite )
		{
			iSpawnsCount++;
		}
	}

	return iSpawnsCount;
}

GetSiteTeamCounts( const iSite, iTeamCounts[ 2 ] )
{
	new sSpawn[ Spawn_Struct ];

	iTeamCounts[ SPAWN_TEAM_T ] = 0;
	iTeamCounts[ SPAWN_TEAM_CT ] = 0;

	for ( new i = 0; i < ArraySize( g_aSpawns ); i++ )
	{
		ArrayGetArray( g_aSpawns, i, sSpawn );
		if ( sSpawn[ Spawn_Site ] == iSite && sSpawn[ Spawn_Team ] >= 0 && sSpawn[ Spawn_Team ] < 2 )
		{
			iTeamCounts[ sSpawn[ Spawn_Team ] ]++;
		}
	}
}

/* =================================================================================
* 				[ Layout Validation ]
* ================================================================================= */

ValidateLayout( const iId )
{
	new iTeamCounts[ 2 ];
	new sSpawn[ Spawn_Struct ];
	new iBlocked;

	GetSiteTeamCounts( g_iActiveSite, iTeamCounts );

	PrintEditor( iId, "BOMBSITE %s: TT %d / CT %d. Paredes: %d.", g_szSiteNames[ g_iActiveSite ], iTeamCounts[ SPAWN_TEAM_T ], iTeamCounts[ SPAWN_TEAM_CT ], g_iBarriersCount );

	if ( iTeamCounts[ SPAWN_TEAM_T ] < 2 || iTeamCounts[ SPAWN_TEAM_CT ] < 2 )
	{
		PrintEditor( iId, "Aviso: para Wingman se recomiendan al menos 2 TT y 2 CT en este site." );
	}

	for ( new i = 0; i < ArraySize( g_aSpawns ); i++ )
	{
		ArrayGetArray( g_aSpawns, i, sSpawn );
		if ( sSpawn[ Spawn_Site ] != g_iActiveSite )
		{
			continue;
		}

		if ( !IsHullVacant( sSpawn[ Spawn_Origin ], 0 ) )
		{
			iBlocked++;
		}
	}

	if ( iBlocked > 0 )
	{
		PrintEditor( iId, "Aviso: %d spawn(s) estan dentro de una pared o bloqueados.", iBlocked );
	}
	else
	{
		PrintEditor( iId, "Validacion correcta: no se detectaron spawns bloqueados." );
	}

	if ( g_iBarriersCount <= 0 )
	{
		PrintEditor( iId, "Aviso: no hay paredes; el resto del mapa sigue abierto." );
	}
}

PrintEditor( const iId, const szFormat[ ], any:... )
{
	new szMessage[ 192 ];
	vformat( szMessage, charsmax( szMessage ), szFormat, 3 );
	client_print_color( iId, print_team_default, "^4[2v2]^1 %s", szMessage );
}

/* =================================================================================
* 				[ File Management ]
* ================================================================================= */

LoadLayout( )
{
	new szConfigsDir[ 128 ];
	new szLine[ 256 ];
	new szCommand[ 24 ];
	new szArg1[ 24 ], szArg2[ 24 ], szArg3[ 24 ], szArg4[ 24 ], szArg5[ 24 ], szArg6[ 24 ];
	new iFile;
	new iSite;
	new iTeam;
	new sSpawn[ Spawn_Struct ];
	new sBarrier[ Barrier_Struct ];
	new Float:flOrigin[ 3 ];
	new Float:flHalfSize[ 3 ];

	ArrayClear( g_aSpawns );
	g_iSpawnsCount = 0;
	RemoveBarrierEntities( );
	ArrayClear( g_aBarriers );
	g_iBarriersCount = 0;
	g_iActiveSite = BOMBSITE_A;

	get_configsdir( szConfigsDir, charsmax( szConfigsDir ) );
	formatex( g_szMapConfigPath, charsmax( g_szMapConfigPath ), "%s/mix_2v2/%s.cfg", szConfigsDir, g_szMapName );

	iFile = fopen( g_szMapConfigPath, "rt" );
	if ( !iFile )
	{
		server_print( "[%s] Sin configuracion para %s: %s", PLUGIN_NAME, g_szMapName, g_szMapConfigPath );
		return;
	}

	while ( !feof( iFile ) )
	{
		fgets( iFile, szLine, charsmax( szLine ) );
		trim( szLine );

		if ( !szLine[ 0 ] || szLine[ 0 ] == ';' || szLine[ 0 ] == '#' )
		{
			continue;
		}

		szCommand[ 0 ] = EOS;
		szArg1[ 0 ] = EOS;
		szArg2[ 0 ] = EOS;
		szArg3[ 0 ] = EOS;
		szArg4[ 0 ] = EOS;
		szArg5[ 0 ] = EOS;
		szArg6[ 0 ] = EOS;

		parse( szLine, szCommand, charsmax( szCommand ), szArg1, charsmax( szArg1 ), szArg2, charsmax( szArg2 ), szArg3, charsmax( szArg3 ), szArg4, charsmax( szArg4 ), szArg5, charsmax( szArg5 ), szArg6, charsmax( szArg6 ) );

		if ( equali( szCommand, "site" ) )
		{
			iSite = ParseSite( szArg1 );
			if ( iSite >= 0 )
			{
				g_iActiveSite = iSite;
			}
			continue;
		}

		if ( equali( szCommand, "spawn" ) )
		{
			iSite = ParseSite( szArg1 );
			iTeam = ParseTeam( szArg2 );

			if ( iSite < 0 || iTeam < 0 )
			{
				continue;
			}

			sSpawn[ Spawn_Site ] = iSite;
			sSpawn[ Spawn_Team ] = iTeam;
			sSpawn[ Spawn_Origin ][ 0 ] = str_to_float( szArg3 );
			sSpawn[ Spawn_Origin ][ 1 ] = str_to_float( szArg4 );
			sSpawn[ Spawn_Origin ][ 2 ] = str_to_float( szArg5 );
			sSpawn[ Spawn_Angles ][ 0 ] = 0.0;
			sSpawn[ Spawn_Angles ][ 1 ] = str_to_float( szArg6 );
			sSpawn[ Spawn_Angles ][ 2 ] = 0.0;

			ArrayPushArray( g_aSpawns, sSpawn );
			g_iSpawnsCount++;
			continue;
		}

		if ( equali( szCommand, "wall2" ) )
		{
			sBarrier[ Barrier_FirstPoint ][ 0 ] = str_to_float( szArg1 );
			sBarrier[ Barrier_FirstPoint ][ 1 ] = str_to_float( szArg2 );
			sBarrier[ Barrier_FirstPoint ][ 2 ] = str_to_float( szArg3 );
			sBarrier[ Barrier_SecondPoint ][ 0 ] = str_to_float( szArg4 );
			sBarrier[ Barrier_SecondPoint ][ 1 ] = str_to_float( szArg5 );
			sBarrier[ Barrier_SecondPoint ][ 2 ] = str_to_float( szArg6 );
			ArrayPushArray( g_aBarriers, sBarrier );
			g_iBarriersCount++;
			continue;
		}

		if ( equali( szCommand, "barrier" ) || equali( szCommand, "wall" ) )
		{
			flOrigin[ 0 ] = str_to_float( szArg1 );
			flOrigin[ 1 ] = str_to_float( szArg2 );
			flOrigin[ 2 ] = str_to_float( szArg3 );
			flHalfSize[ 0 ] = floatabs( str_to_float( szArg4 ) );
			flHalfSize[ 1 ] = floatabs( str_to_float( szArg5 ) );
			flHalfSize[ 2 ] = floatabs( str_to_float( szArg6 ) );

			if ( flHalfSize[ 0 ] >= flHalfSize[ 1 ] )
			{
				sBarrier[ Barrier_FirstPoint ][ 0 ] = flOrigin[ 0 ] - flHalfSize[ 0 ];
				sBarrier[ Barrier_FirstPoint ][ 1 ] = flOrigin[ 1 ];
				sBarrier[ Barrier_SecondPoint ][ 0 ] = flOrigin[ 0 ] + flHalfSize[ 0 ];
				sBarrier[ Barrier_SecondPoint ][ 1 ] = flOrigin[ 1 ];
			}
			else
			{
				sBarrier[ Barrier_FirstPoint ][ 0 ] = flOrigin[ 0 ];
				sBarrier[ Barrier_FirstPoint ][ 1 ] = flOrigin[ 1 ] - flHalfSize[ 1 ];
				sBarrier[ Barrier_SecondPoint ][ 0 ] = flOrigin[ 0 ];
				sBarrier[ Barrier_SecondPoint ][ 1 ] = flOrigin[ 1 ] + flHalfSize[ 1 ];
			}

			sBarrier[ Barrier_FirstPoint ][ 2 ] = flOrigin[ 2 ] - flHalfSize[ 2 ];
			sBarrier[ Barrier_SecondPoint ][ 2 ] = flOrigin[ 2 ] - flHalfSize[ 2 ];
			ArrayPushArray( g_aBarriers, sBarrier );
			g_iBarriersCount++;
		}
	}

	fclose( iFile );

	RebuildBarrierEntities( );

	server_print( "[%s] %s: site=%s, %d spawns, %d paredes cargadas.", PLUGIN_NAME, g_szMapName, g_szSiteNames[ g_iActiveSite ], g_iSpawnsCount, g_iBarriersCount );
}

ParseSite( const szValue[ ] )
{
	if ( equali( szValue, "a" ) )
	{
		return BOMBSITE_A;
	}

	if ( equali( szValue, "b" ) )
	{
		return BOMBSITE_B;
	}

	return -1;
}

ParseTeam( const szValue[ ] )
{
	if ( equali( szValue, "t" ) || equali( szValue, "tt" ) || equali( szValue, "terrorist" ) )
	{
		return SPAWN_TEAM_T;
	}

	if ( equali( szValue, "ct" ) || equali( szValue, "counter" ) )
	{
		return SPAWN_TEAM_CT;
	}

	return -1;
}

SaveLayout( )
{
	new iFile;
	new sSpawn[ Spawn_Struct ];
	new sBarrier[ Barrier_Struct ];

	if ( !g_szMapConfigPath[ 0 ] )
	{
		return;
	}

	iFile = fopen( g_szMapConfigPath, "wt" );
	if ( !iFile )
	{
		server_print( "[%s] No se pudo guardar %s.", PLUGIN_NAME, g_szMapConfigPath );
		return;
	}

	fprintf( iFile, "; AUTOMIX WINGMAN 2v2 para %s^n", g_szMapName );
	fprintf( iFile, "; site <A|B>^n" );
	fprintf( iFile, "; spawn <A|B> <TT|CT> X Y Z YAW^n" );
	fprintf( iFile, "; wall2 X1 Y1 Z1 X2 Y2 Z2^n^n" );
	fprintf( iFile, "site %s^n^n", g_szSiteNames[ g_iActiveSite ] );

	for ( new i = 0; i < ArraySize( g_aSpawns ); i++ )
	{
		ArrayGetArray( g_aSpawns, i, sSpawn );

		fprintf( iFile, "spawn %s %s %f %f %f %f^n", g_szSiteNames[ sSpawn[ Spawn_Site ] ], g_szTeamNames[ sSpawn[ Spawn_Team ] ], sSpawn[ Spawn_Origin ][ 0 ], sSpawn[ Spawn_Origin ][ 1 ], sSpawn[ Spawn_Origin ][ 2 ], sSpawn[ Spawn_Angles ][ 1 ] );
	}

	fprintf( iFile, "^n; PAREDES DE BLOQUEO^n" );

	for ( new i = 0; i < ArraySize( g_aBarriers ); i++ )
	{
		ArrayGetArray( g_aBarriers, i, sBarrier );
		fprintf( iFile, "wall2 %f %f %f %f %f %f^n", sBarrier[ Barrier_FirstPoint ][ 0 ], sBarrier[ Barrier_FirstPoint ][ 1 ], sBarrier[ Barrier_FirstPoint ][ 2 ], sBarrier[ Barrier_SecondPoint ][ 0 ], sBarrier[ Barrier_SecondPoint ][ 1 ], sBarrier[ Barrier_SecondPoint ][ 2 ] );
	}

	fclose( iFile );
}

/* =================================================================================
* 				[ Barrier Entities ]
* ================================================================================= */

CreateBarrierEntity( const iIndex )
{
	new sBarrier[ Barrier_Struct ];
	new Float:flOrigin[ 3 ];
	new Float:flHalfSize[ 3 ];
	new iEntity = create_entity( g_szInfoTargetClassname );
	new Float:flMins[ 3 ];
	new Float:flMaxs[ 3 ];
	new Float:flBoundsMins[ 3 ];
	new Float:flBoundsMaxs[ 3 ];

	ArrayGetArray( g_aBarriers, iIndex, sBarrier );
	GetBarrierBounds( sBarrier, flBoundsMins, flBoundsMaxs );

	if ( !is_valid_ent( iEntity ) )
	{
		server_print( "[%s] No se pudo crear una pared.", PLUGIN_NAME );
		return 0;
	}

	for ( new i = 0; i < 3; i++ )
	{
		flOrigin[ i ] = ( flBoundsMins[ i ] + flBoundsMaxs[ i ] ) * 0.5;
		flHalfSize[ i ] = ( flBoundsMaxs[ i ] - flBoundsMins[ i ] ) * 0.5;
		flMins[ i ] = -flHalfSize[ i ];
		flMaxs[ i ] = flHalfSize[ i ];
	}

	entity_set_string( iEntity, EV_SZ_classname, g_szBarrierClassname );
	entity_set_int( iEntity, EV_INT_solid, SOLID_BBOX );
	entity_set_int( iEntity, EV_INT_movetype, MOVETYPE_NONE );
	entity_set_int( iEntity, EV_INT_effects, EF_NODRAW );
	entity_set_size( iEntity, flMins, flMaxs );
	entity_set_origin( iEntity, flOrigin );

	return iEntity;
}

RebuildBarrierEntities( )
{
	RemoveBarrierEntities( );

	for ( new i = 0; i < ArraySize( g_aBarriers ); i++ )
	{
		CreateBarrierEntity( i );
	}
}

RemoveBarrierEntities( )
{
	new iEntity;

	while ( ( iEntity = find_ent_by_class( -1, g_szBarrierClassname ) ) > 0 )
	{
		remove_entity( iEntity );
	}
}

DeleteBarrier( const iIndex )
{
	if ( iIndex < 0 || iIndex >= ArraySize( g_aBarriers ) )
	{
		return;
	}

	ArrayDeleteItem( g_aBarriers, iIndex );
	g_iBarriersCount--;
	RebuildBarrierEntities( );
}

FindClosestBarrier( const Float:flPoint[ 3 ] )
{
	new iClosest = -1;
	new Float:flClosestDistance = 160.0;
	new Float:flDistance;
	new sBarrier[ Barrier_Struct ];

	for ( new i = 0; i < ArraySize( g_aBarriers ); i++ )
	{
		ArrayGetArray( g_aBarriers, i, sBarrier );

		flDistance = GetDistanceToBarrier( flPoint, sBarrier );
		if ( flDistance < flClosestDistance )
		{
			flClosestDistance = flDistance;
			iClosest = i;
		}
	}

	return iClosest;
}

Float:GetDistanceToBarrier( const Float:flPoint[ 3 ], const sBarrier[ Barrier_Struct ] )
{
	new Float:flMins[ 3 ];
	new Float:flMaxs[ 3 ];
	new Float:flAxisDistance;
	new Float:flDistanceSquared;

	GetBarrierBounds( sBarrier, flMins, flMaxs );

	for ( new i = 0; i < 3; i++ )
	{
		if ( flPoint[ i ] < flMins[ i ] )
		{
			flAxisDistance = flMins[ i ] - flPoint[ i ];
		}
		else if ( flPoint[ i ] > flMaxs[ i ] )
		{
			flAxisDistance = flPoint[ i ] - flMaxs[ i ];
		}
		else
		{
			flAxisDistance = 0.0;
		}

		flDistanceSquared += flAxisDistance * flAxisDistance;
	}

	return floatsqroot( flDistanceSquared );
}
