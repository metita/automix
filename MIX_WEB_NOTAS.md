# Notas de implementación web-only 2v2 / 5v5

## Fuente de verdad

El roster se indexa por AccId. Modo, tamaño por equipo, equipo, capitán y mapa
vienen de la web. El juego nunca crea ni balancea equipos competitivos.

`g_iWebRosterCount > 0` significa que hay una sala asignada. Sin roster solo
existe calentamiento.

## Cambio de mapa y recuperación

`plugin_end` no cancela una sala: también corre durante el `changelevel` que
hace el propio puente. La sala sobrevive en MySQL y el mapa nuevo la recupera
con `MixGetLobbyForServerV2(server_id, 1)`.

La recuperación trae marcador, mitad, `mode` y `team_size`.
`mix_web_restore_score` recompone el estado interno y el scoreboard. Las
columnas de la primera fila son, en este orden: id, map, password, score A,
score B, half, mode, team_size.

El roster recuperado excluye filas con `abandoned_at`: cuando hubo suplente se
recuperan exactamente los cuatro o diez jugadores activos, no la fila histórica
del reemplazado más el suplente.

`MixClaimLobbyV2(server_id, allowed_mode)` recibe `all`, `5v5` o `2v2` desde
`mix_web_mode`. El procedimiento de recuperación no filtra por el valor actual:
una instancia siempre retoma la sala live que ya tiene asignada.

Producción usa dos instancias dedicadas: el servidor/puerto histórico configura
`mix_web_mode 5v5` y `23.26.135.117:27031` configura `mix_web_mode 2v2` con
`mix_web_server_id 18` (la fila `accsys.servers.id=18`). Cada instancia tiene
un `mix_web_server_id` distinto para su fila de `accsys.servers`. `all` queda
disponible para pruebas o contingencia, no como configuración normal. La web
obtiene el botón CONECTAR desde el `public_ip:server_port` de la fila que reclamó
la sala; no comparte una dirección global entre ambas modalidades.

La cola 2v2 queda cerrada temporalmente con `MIX_2V2_QUEUE_ENABLED=0` (o sin la
variable, que equivale a cerrado). Esto bloquea nuevos POST y partidas de prueba
2v2, pero mantiene visible el historial, permite abandonar una fila que ya
existiera y no borra la preparación del modo. Al terminar la configuración de
mapas se cambia a `1` y se reinicia la web.

## Roster y acceso

`SweepNonRosterPlayers` elimina del conteo a quien no pertenece a la sala y lo
manda a espectador si está en TT/CT. No toca a una conexión cuyo login todavía
no terminó.

La espera inicial cuenta por slot del roster, no por conexión, para impedir que
una cuenta duplicada cubra a otra ausente.

El servidor no usa password. Mientras una sala está activa, una guardia conserva
una sola HLTV y una conexión única por cada AccId del roster.
Los outsiders que no están en espectador, bots y cuentas duplicadas son expulsados
apenas se identifican. Los espectadores, incluso si no están en el roster, pueden
permanecer para mirar; el flujo de `JOIN_GAME` les impide ocupar TT/CT. Quien no
termina el login tiene 30 segundos mientras intenta ocupar un cupo. Durante ese
margen el último slot físico queda libre para HLTV.

`ApplyRoster` falla cerrado. Solo acepta `2v2 + team_size=2` o
`5v5 + team_size=5`, exige exactamente 2+2 o 5+5 AccId únicos y valida también
la cantidad cruda de filas. Así un duplicado, equipo desbalanceado o fila extra
no puede quedar ignorado silenciosamente. Los slots mínimos son roster + 1 para
HLTV.

El core usa capacidad máxima de diez, pero el tamaño efectivo queda configurado
por `mix_web_set_match_mode`. El arranque y los faltantes se cuentan recorriendo
slots únicos del roster; `g_iReadyCount` no es una condición de integridad.

## ELO previo

Al aplicar el roster, `mix_web` hace una sola lectura de los promedios de ambos
equipos. La consulta une `mix_lobbies.mode` con `mix_elo.mode`, además de incluir
el lobby id para descartar callbacks atrasados de una sala anterior.

El core recibe ambos promedios como Float. Así los puntos mostrados usan la
diferencia real de promedios; redondear antes podría cambiar el delta en un
punto respecto de `MixFinishMatch`.

La preparación espera esa consulta antes de mostrar equipos e iniciar knife;
si falla, el callback libera la espera con el fallback 1000/1000.

## Knife y regreso a warmup

Si alguien desaparece antes de knife o durante la preparación, el roster no se
cancela: vuelve a warmup y espera al mismo AccId. Si el knife ya terminó, no se
repite; se conserva el lado elegido.

## Abandonos y suplentes

El timeout de reconexión llama `MixPlayerAbandoned` y abre el slot. El primero
que entra como suplente reemplaza el AccId mediante `MixReplacePlayer`, conserva
el equipo y comienza K/D/A, daño, headshots y rondas en cero. Antes de limpiar
el slot se persiste la línea parcial del jugador reemplazado.

La guardia admite exactamente un outsider autenticado por cada vacante y lo
mantiene en espectador hasta que toma el slot. Al entrar, se elimina la ficha
desconectada anterior y se cancela el timeout si ya no falta nadie. El callback
de reemplazo reenvía `MixPlayerConnected` para fijar el orden INSERT -> ingreso;
así el JOIN_GAME del suplente no puede adelantarse a su fila SQL.
Quien agotó su timeout no puede volver al slot abandonado: se expulsa para no
divergir entre el roster activo del core y `abandoned_at` en la base.

Cuando alguien ya agotó sus reconexiones, el slot se abre en el mismo momento de
su salida; no queda esperando un timeout que nunca se inició.

La pausa automática y el timeout de reconexión son independientes. Terminar los
30 segundos de pausa no cancela el plazo de 120 ni ejecuta `RestartRound`; el
mismo freezetime retoma su cuenta normal. Si la desconexión ocurre durante un
descanso, la pausa se aplica después del único restart de la fase nueva.

## Cambios de fase

Halftime y overtime reutilizan el `RestartRound` natural de la ronda anterior.
El delay de ese evento se extiende a `mix_halftime_break`; antes del respawn se
aplican estado, swap y marcador. No existen callbacks que disparen un segundo
restart. Los micrófonos cruzados permanecen abiertos durante todo el descanso.

## Resultado

K/D/A, daño aplicado, headshots y rondas jugadas viajan como JSON dentro de
`MixFinishMatch`. El bucle usa el roster real (cuatro o diez); el buffer de 1536
bytes conserva capacidad para diez entradas completas aun con el peor entero
Pawn. El lobby id mantiene la identidad de modo para estadísticas y ELO.

El resultado normal se envía inmediatamente. Si queda una consulta asíncrona de
abandono o reemplazo, espera hasta su callback para que el reparto de ELO use el
roster correcto. Un fallo del cierre reintenta cinco veces cada seis segundos.

`ReleaseLobby` mantiene el servidor público y limpia el roster enseguida; los datos del reporte quedan
copiados aparte para que los reintentos sobrevivan a esa limpieza.

## Heartbeat

Mientras `g_iLobbyId` exista, el puente llama `MixHeartbeat` cada 20 segundos.
Esto permite que la web cancele una sala cuyo servidor murió y libere a los
jugadores de ese roster.

## Presentación y no-show

`MixPlayerConnected` ya no se llama desde `Account_UserLogged`. El core emite
`mix_web_player_joined(accid)` solamente después de un `JOIN_GAME` válido que
dejó al jugador del roster en TT o CT. Esto evita que un login en spectator
borre falsamente un no-show.

Cada actualización de `connected_at` lleva lobby/AccId en su contexto, reintenta
tres veces y cuenta como pendiente. Si el reloj llega a cero, la cancelación
espera esos callbacks y reevalúa inmediatamente al terminar el último; nunca
sanciona a alguien cuyo JOIN_GAME ocurrió antes del deadline por una carrera.

Al vencer los cinco minutos, el bridge prende `g_bNoShowTimeout` antes de llamar
`mix_cancel`. El forward sincrónico selecciona `MixCancelNoShowLobby(lobby_id)`
en lugar de la cancelación normal. Ese procedimiento, bajo transacción, solo
actúa si la sala sigue live, no empezó y su deadline venció; identifica
`connected_at IS NULL`, registra las sanciones y cancela como una sola operación.
Las cancelaciones administrativas, de mapa, slots, modo o roster inválido siguen
usando `MixCancelLobby` y nunca aplican castigos de no-show.
