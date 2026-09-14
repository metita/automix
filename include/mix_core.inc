#if defined _mix_core_included
	#endinput
#endif
#define _mix_core_included

#pragma reqlib mix_core

/**
* Equipos internos del mix.
*/
#define MIX_TEAM_NONE		0
#define MIX_TEAM_A			1
#define MIX_TEAM_B			2

/**
* Vacia el roster armado desde la web.
*
* Deja al servidor sin partida asignada: mix_core vuelve al warmup público
* mientras el bridge espera otra sala web.
*
* @noreturn
*/
native mix_web_clear_roster( );

/**
* Configura el modo de la sala antes de cargar sus jugadores.
*
* Solo acepta las combinaciones 5v5/5 y 2v2/2. El tamaño es por equipo y la
* capacidad máxima del core sigue siendo diez jugadores totales.
*
* @param szMode         "5v5" o "2v2".
* @param iTeamSize      Jugadores esperados por equipo.
*
* @return               true si el modo quedó configurado.
*/
native bool:mix_web_set_match_mode( const szMode[ ], const iTeamSize );

/**
* Agrega un jugador al roster armado desde la web.
*
* Es idempotente: repetir un AccId ya cargado no lo duplica ni falla, para que
* el roster se pueda reenviar tras un cambio de mapa.
*
* @param iAccId			Cuenta del jugador (accsys).
* @param iTeam			MIX_TEAM_A o MIX_TEAM_B.
*
* @return				1 si quedo cargado, 0 si el roster esta lleno o los
*						parametros son invalidos.
*/
native mix_web_add_player( const iAccId, const iTeam );

/**
* Indica si el servidor tiene una partida armada desde la web.
*
* @return				true si hay roster cargado.
*/
native bool:mix_web_is_active( );

/**
* Indica si hay algo en curso que un cambio de mapa arruinaria.
*
* Se consulta antes de tomar una partida nueva: reclamar una sala implica un
* changelevel, y eso borraria la partida que se este jugando.
*
* @return				true si el mix no esta en reposo.
*/
native bool:mix_web_busy( );

/** Estado interno actual del match (MIX_LIVE = 4, MIX_OVERTIME = 5). */
native mix_web_match_status( );

/** Numero de ronda actual; empieza en 1 cuando arranca el LIVE. */
native mix_web_round_number( );

/**
* Devuelve el equipo asignado a una cuenta dentro del roster.
*
* @param iAccId			Cuenta del jugador (accsys).
*
* @return				MIX_TEAM_A, MIX_TEAM_B o MIX_TEAM_NONE si no esta.
*/
native mix_web_team_of( const iAccId );

/**
* Cantidad de jugadores cargados en el roster.
*
* @return				Numero de slots ocupados.
*/
native mix_web_roster_count( );

/** Cantidad de slots abiertos que pueden tomar suplentes autenticados. */
native mix_web_vacancy_count( );

/** Cantidad de slots únicos que completaron JOIN_GAME y están en TT o CT. */
native mix_web_joined_roster_count( );

/**
 * Retoma el marcador de una partida que se corto.
 *
 * La usa el puente al recuperar una sala que quedo 'live' despues de que el
 * servidor se cayera: sin esto la partida se reanudaba en 0-0.
 */
native mix_web_restore_score( const iScoreA, const iScoreB, const iHalf );

/** Recibe los promedios ELO de los dos equipos de la sala. */
native mix_web_set_team_elo( const Float:flEloA, const Float:flEloB );

/**
* Exporta un slot del roster con sus estadisticas acumuladas.
*
* Las estadisticas se llevan por AccId y no por indice de jugador, asi que
* sobreviven a que alguien se desconecte y vuelva con otro slot.
*
* @param iIndex			Indice del slot, de 0 a mix_web_roster_count() - 1.
* @param iAccId			Recibe la cuenta del jugador.
* @param iKills			Recibe las bajas.
* @param iDeaths		Recibe las muertes.
* @param iAssists		Recibe las asistencias.
*
* @return				true si el indice es valido.
*/
native bool:mix_web_roster_stats( const iIndex, &iAccId, &iKills, &iDeaths, &iAssists );

/** Exporta daño, headshots y rondas de un slot del roster. */
native bool:mix_web_roster_advanced_stats( const iIndex, &iDamage, &iHeadshots, &iRounds );

/**
* Si el dueño del slot abandono, volvio y jugo la partida: sumo al menos una
* ronda desde que volvio y sigue dentro de su equipo.
*
* @param iIndex			Slot del roster.
*
* @return				true si volvio y jugo.
*/
native bool:mix_web_roster_returned( const iIndex );

/**
* Se llama al terminar la partida, con el marcador final.
*
* @param iScoreA		Rondas ganadas por el equipo A.
* @param iScoreB		Rondas ganadas por el equipo B.
*
* @noreturn
*/
forward mix_web_match_ended( const iScoreA, const iScoreB );

/**
* Se llama cuando el mix se cancela dentro del juego.
*
* @noreturn
*/
forward mix_web_match_cancelled( );

/**
* Se llama cuando se loguea alguien que no esta en el roster.
*
* @param iId			Indice del jugador.
* @param iAccId			Cuenta del jugador (accsys).
*
* @noreturn
*/
forward mix_web_roster_reject( const iId, const iAccId );

/**
* Se llama cuando un jugador del roster se fue y no volvio a tiempo.
*
* El servidor solo avisa quien fue: la sancion la decide la web, que es donde
* vive la escalera de castigos.
*
* @param iAccId			Cuenta del jugador (accsys).
*
* @noreturn
*/
forward mix_web_player_left( const iAccId );

/**
* Se llama cuando un espectador toma el lugar de alguien que abandono.
*
* El suplente hereda el equipo, no las estadisticas: las del que se fue ya se
* reportaron con su abandono.
*
* @param iOldAccId		Cuenta del que abandono.
* @param iNewAccId		Cuenta del suplente.
*
* @noreturn
*/
forward mix_web_player_replaced( const iOldAccId, const iNewAccId );

/**
* Se llama cuando un jugador del roster completó JOIN_GAME y quedó físicamente
* en TT o CT. Login por sí solo no cuenta como haberse presentado.
*/
forward mix_web_player_joined( const iAccId );

/**
* Se llama al ponerse LIVE y despues en cada ronda, con el marcador del momento.
*
* El aviso inicial llega en 0 - 0: es lo que marca la hora de arranque real de
* la partida.
*
* @param iScoreA		Rondas ganadas por el equipo A.
* @param iScoreB		Rondas ganadas por el equipo B.
* @param iHalf			1 = primer tiempo, 2 = segundo, 3+ = overtime.
*
* @noreturn
*/
forward mix_web_score_changed( const iScoreA, const iScoreB, const iHalf );

/**
* Se llama cuando termina de verdad una ronda LIVE, con su registro completo.
*
* Llega en el restart de la ronda siguiente (o al cerrar la partida), para que
* entren las bajas de despues del final de ronda. Solo informa: no cambia nada
* del partido.
*
* @param iRound         Numero de ronda: la suma del marcador al terminarla.
* @param iHalf          1 = primer tiempo, 2 = segundo, 3+ = overtime.
* @param iWinner        MIX_TEAM_A o MIX_TEAM_B.
* @param szReason       "eliminacion", "bomba", "desactivacion", "tiempo" u "otro".
* @param szSideA        Lado del equipo A en esa ronda: "T" o "CT".
* @param iScoreA        Marcador del equipo A despues de la ronda.
* @param iScoreB        Marcador del equipo B despues de la ronda.
* @param szData         JSON con plata al empezar (ma, mb), vivos al final (va, vb),
*                       bajas k[[segundo, atacante, victima, arma, hs, asistente]],
*                       daño d[[atacante, victima, daño]] y utilidad
*                       u[[cuenta, daño HE, flashes, plantas, desactivaciones]].
*
* @noreturn
*/
forward mix_web_round_ended( const iRound, const iHalf, const iWinner, const szReason[ ], const szSideA[ ], const iScoreA, const iScoreB, const szData[ ] );
