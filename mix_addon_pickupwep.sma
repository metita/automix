#include <amxmodx>
#include <fakemeta>
#include <reapi>
#include <xs>

#include <common>

/* =================================================================================
* 				[ Defines ]
* ================================================================================= */

#define PICKUP_DISTANCE				96.0
#define C4_USE_PRIORITY_DISTANCE	64.0
#define PICKUP_COOLDOWN				0.3

/* =================================================================================
* 				[ Global Variables ]
* ================================================================================= */

new g_iIsConnected;
new Float:g_flLastPickup[ MAX_PLAYERS + 1 ];

/* =================================================================================
* 				[ Plugin Init ]
* ================================================================================= */

public plugin_init( )
{
	register_plugin( "[ZG] AUTOMIX: Pickup Weapon", "1.1", "metita" );
	
	RegisterHookChain( RG_CBasePlayer_PreThink, "OnPlayerPreThink_Post", true );
}

/* =================================================================================
* 				[ Forwards ]
* ================================================================================= */

public client_putinserver( iId )
{
	SetPlayerBit( g_iIsConnected, iId );
	
	g_flLastPickup[ iId ] = 0.0;
}

public client_disconnected( iId )
{
	ClearPlayerBit( g_iIsConnected, iId );
}

public OnPlayerPreThink_Post( const iId )
{
	if ( !GetPlayerBit( g_iIsConnected, iId ) )
	{
		return;
	}
	
	if ( !is_user_alive( iId ) )
	{
		return;
	}
	
	static iButton, iOldButton;
	
	iButton = get_entvar( iId, var_button );
	iOldButton = get_entvar( iId, var_oldbuttons );
	
	if ( !( iButton & IN_USE ) || ( iOldButton & IN_USE ) )
	{
		return;
	}

	if ( HasPlantedC4Priority( iId ) )
	{
		return;
	}
	
	TryPickupWeapon( iId );
}

/* =================================================================================
* 				[ Functions ]
* ================================================================================= */

TryPickupWeapon( const iId )
{
	new Float:flGameTime = get_gametime( );
	
	if ( flGameTime - g_flLastPickup[ iId ] < PICKUP_COOLDOWN )
	{
		return;
	}
	
	new Float:flStart[ 3 ], Float:flViewOfs[ 3 ];
	new Float:flAngles[ 3 ], Float:flForward[ 3 ];
	
	get_entvar( iId, var_origin, flStart );
	get_entvar( iId, var_view_ofs, flViewOfs );
	get_entvar( iId, var_v_angle, flAngles );
	
	xs_vec_add( flStart, flViewOfs, flStart );
	
	angle_vector( flAngles, ANGLEVECTOR_FORWARD, flForward );
	
	new bool:bUnlimitedDistance = bool:get_member_game( m_bFreezePeriod );
	new iWeaponEnt = FindBestWeapon( iId, flStart, flForward, bUnlimitedDistance );
	
	if ( !iWeaponEnt )
	{
		return;
	}
	
	new WeaponIdType:iWeaponId = GetWeaponIdFromEntity( iWeaponEnt );
	
	if ( iWeaponId == WEAPON_NONE )
	{
		return;
	}
	
	new InventorySlotType:iSlot = GetWeaponSlot( iWeaponId );
	new iSlotWeapon = get_member( iId, m_rgpPlayerItems, iSlot );
	new iDroppedBox = 0;

	if ( iSlotWeapon > 0 && pev_valid( iSlotWeapon ) )
	{
		new szWeaponName[ 32 ];
		
		rg_get_iteminfo( iSlotWeapon, ItemInfo_pszName, szWeaponName, charsmax( szWeaponName ) );
		iDroppedBox = rg_drop_item( iId, szWeaponName );
	}
	
	if ( pev_valid( iWeaponEnt ) )
	{
		dllfunc( DLLFunc_Touch, iWeaponEnt, iId );
	}
	
	new iNewSlotWeapon = get_member( iId, m_rgpPlayerItems, iSlot );

	if ( iNewSlotWeapon <= 0 || !pev_valid( iNewSlotWeapon ) )
	{
		if ( iDroppedBox > 0 && pev_valid( iDroppedBox ) )
		{
			dllfunc( DLLFunc_Touch, iDroppedBox, iId );
		}
	}
	
	g_flLastPickup[ iId ] = flGameTime;
}

bool:HasPlantedC4Priority( const iId )
{
	if ( get_member( iId, m_iTeam ) != TEAM_CT || !rg_is_bomb_planted( ) )
	{
		return false;
	}

	new Float:flPlayerOrigin[ 3 ], Float:flBombOrigin[ 3 ];

	get_entvar( iId, var_origin, flPlayerOrigin );

	new iEnt = -1;

	while ( ( iEnt = rg_find_ent_by_class( iEnt, "grenade" ) ) > 0 )
	{
		if ( !pev_valid( iEnt ) || !get_member( iEnt, m_Grenade_bIsC4 ) )
		{
			continue;
		}

		get_entvar( iEnt, var_origin, flBombOrigin );

		if ( get_distance_f( flPlayerOrigin, flBombOrigin ) <= C4_USE_PRIORITY_DISTANCE )
		{
			return true;
		}
	}

	return false;
}

FindBestWeapon( const iId, const Float:flStart[ 3 ], const Float:flForward[ 3 ], const bool:bUnlimitedDistance )
{
	new Float:flOrigin[ 3 ], Float:flPlayerOrigin[ 3 ];
	new Float:flBestScore = 0.0;
	new iBestEnt = 0;
	
	get_entvar( iId, var_origin, flPlayerOrigin );
	
	new iEnt = -1;
	
	while ( ( iEnt = rg_find_ent_by_class( iEnt, "weaponbox" ) ) > 0 )
	{
		if ( !pev_valid( iEnt ) )
		{
			continue;
		}
		
		get_entvar( iEnt, var_origin, flOrigin );
		
		new Float:flDist = get_distance_f( flPlayerOrigin, flOrigin );
		
		if ( !bUnlimitedDistance && flDist > PICKUP_DISTANCE )
		{
			continue;
		}
		
		if ( !IsVisible( iId, flOrigin ) )
		{
			continue;
		}
		
		new Float:flScore = GetAimScore( flStart, flForward, flOrigin, flDist, bUnlimitedDistance );
		
		if ( flScore > flBestScore )
		{
			flBestScore = flScore;
			iBestEnt = iEnt;
		}
	}
	
	iEnt = -1;
	
	while ( ( iEnt = rg_find_ent_by_class( iEnt, "armoury_entity" ) ) > 0 )
	{
		if ( !pev_valid( iEnt ) )
		{
			continue;
		}

		if ( get_entvar( iEnt, var_effects ) & EF_NODRAW )
		{
			continue;
		}
		
		get_entvar( iEnt, var_origin, flOrigin );
		
		new Float:flDist = get_distance_f( flPlayerOrigin, flOrigin );
		
		if ( !bUnlimitedDistance && flDist > PICKUP_DISTANCE )
		{
			continue;
		}
		
		if ( !IsVisible( iId, flOrigin ) )
		{
			continue;
		}
		
		new Float:flScore = GetAimScore( flStart, flForward, flOrigin, flDist, bUnlimitedDistance );
		
		if ( flScore > flBestScore )
		{
			flBestScore = flScore;
			iBestEnt = iEnt;
		}
	}
	
	return iBestEnt;
}

/* =================================================================================
* 				[ Vectors ]
* ================================================================================= */

Float:GetAimScore( const Float:flStart[ 3 ], const Float:flForward[ 3 ], const Float:flTarget[ 3 ], const Float:flDist, const bool:bUnlimitedDistance )
{
	new Float:flDir[ 3 ];
	
	xs_vec_sub( flTarget, flStart, flDir );
	xs_vec_normalize( flDir, flDir );
	
	new Float:flDot = xs_vec_dot( flForward, flDir );

	if ( flDot < 0.7 )
	{
		return 0.0;
	}
	
	new Float:flDistScore;
	new Float:flScore;

	if ( bUnlimitedDistance )
	{
		flDistScore = PICKUP_DISTANCE / ( PICKUP_DISTANCE + flDist );
		flScore = ( flDot * 0.85 ) + ( flDistScore * 0.15 );
	}
	else
	{
		flDistScore = 1.0 - ( flDist / PICKUP_DISTANCE );
		flScore = ( flDot * 0.7 ) + ( flDistScore * 0.3 );
	}
	
	return flScore;
}

bool:IsVisible( const iId, const Float:flTarget[ 3 ] )
{
	new Float:flStart[ 3 ], Float:flViewOfs[ 3 ];
	
	get_entvar( iId, var_origin, flStart );
	get_entvar( iId, var_view_ofs, flViewOfs );
	
	xs_vec_add( flStart, flViewOfs, flStart );
	
	new iTrace = create_tr2( );
	
	engfunc( EngFunc_TraceLine, flStart, flTarget, IGNORE_MONSTERS, iId, iTrace );
	
	new Float:flFraction;
	
	get_tr2( iTrace, TR_flFraction, flFraction );
	
	free_tr2( iTrace );
	
	return ( flFraction >= 0.95 );
}

/* =================================================================================
* 				[ Weapon Helpers ]
* ================================================================================= */

WeaponIdType:GetWeaponIdFromEntity( const iEnt )
{
	new szClassname[ 32 ];
	
	get_entvar( iEnt, var_classname, szClassname, charsmax( szClassname ) );
	
	if ( equal( szClassname, "weaponbox" ) )
	{
		return rg_get_weaponbox_id( iEnt );
	}
	
	if ( equal( szClassname, "armoury_entity" ) )
	{
		new ArmouryItemPack:iItem = get_member( iEnt, m_Armoury_iItem );
		
		return GetWeaponIdFromArmoury( iItem );
	}
	
	return WEAPON_NONE;
}

WeaponIdType:GetWeaponIdFromArmoury( const ArmouryItemPack:iItem )
{
	switch ( iItem )
	{
		case ARMOURY_MP5NAVY:		return WEAPON_MP5N;
		case ARMOURY_TMP:			return WEAPON_TMP;
		case ARMOURY_P90:			return WEAPON_P90;
		case ARMOURY_MAC10:			return WEAPON_MAC10;
		case ARMOURY_AK47:			return WEAPON_AK47;
		case ARMOURY_SG552:			return WEAPON_SG552;
		case ARMOURY_M4A1:			return WEAPON_M4A1;
		case ARMOURY_AUG:			return WEAPON_AUG;
		case ARMOURY_SCOUT:			return WEAPON_SCOUT;
		case ARMOURY_G3SG1:			return WEAPON_G3SG1;
		case ARMOURY_AWP:			return WEAPON_AWP;
		case ARMOURY_M3:			return WEAPON_M3;
		case ARMOURY_XM1014:		return WEAPON_XM1014;
		case ARMOURY_M249:			return WEAPON_M249;
		case ARMOURY_FLASHBANG:		return WEAPON_FLASHBANG;
		case ARMOURY_HEGRENADE:		return WEAPON_HEGRENADE;
		case ARMOURY_KEVLAR:		return WEAPON_NONE;
		case ARMOURY_ASSAULT:		return WEAPON_NONE;
		case ARMOURY_SMOKEGRENADE:	return WEAPON_SMOKEGRENADE;
		case ARMOURY_GLOCK18:		return WEAPON_GLOCK18;
		case ARMOURY_USP:			return WEAPON_USP;
		case ARMOURY_ELITE:			return WEAPON_ELITE;
		case ARMOURY_FIVESEVEN:		return WEAPON_FIVESEVEN;
		case ARMOURY_P228:			return WEAPON_P228;
		case ARMOURY_DEAGLE:		return WEAPON_DEAGLE;
		case ARMOURY_SG550:			return WEAPON_SG550;
		case ARMOURY_GALIL:			return WEAPON_GALIL;
		case ARMOURY_FAMAS:			return WEAPON_FAMAS;
		case ARMOURY_UMP45:			return WEAPON_UMP45;
	}
	
	return WEAPON_NONE;
}

InventorySlotType:GetWeaponSlot( const WeaponIdType:iWeaponId )
{
	switch ( iWeaponId )
	{
		case WEAPON_AK47, WEAPON_AUG, WEAPON_AWP, WEAPON_FAMAS, WEAPON_G3SG1,
			 WEAPON_GALIL, WEAPON_M249, WEAPON_M3, WEAPON_M4A1, WEAPON_MAC10,
			 WEAPON_MP5N, WEAPON_P90, WEAPON_SCOUT, WEAPON_SG550, WEAPON_SG552,
			 WEAPON_TMP, WEAPON_UMP45, WEAPON_XM1014:
		{
			return PRIMARY_WEAPON_SLOT;
		}
		
		case WEAPON_DEAGLE, WEAPON_ELITE, WEAPON_FIVESEVEN, WEAPON_GLOCK18,
			 WEAPON_P228, WEAPON_USP:
		{
			return PISTOL_SLOT;
		}
		
		case WEAPON_HEGRENADE, WEAPON_FLASHBANG, WEAPON_SMOKEGRENADE:
		{
			return GRENADE_SLOT;
		}
		
		case WEAPON_KNIFE:
		{
			return KNIFE_SLOT;
		}
		
		case WEAPON_C4:
		{
			return C4_SLOT;
		}
	}
	
	return NONE_SLOT;
}
