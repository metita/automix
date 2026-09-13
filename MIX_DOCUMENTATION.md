# AUTOMIX 2V2 / 5V5 — flujo web

El servidor ejecuta exclusivamente partidas 2v2 o 5v5 armadas en
`zgaming.net/mix`. El modo pertenece a cada lobby: no se deduce por cantidad de
filas ni se fija globalmente dentro del core.
Dentro del juego no existen ready competitivo, selección de capitanes, picking,
auto-pick, cambio votado de jugadores ni votemap post-partida.

El calentamiento sigue abierto cuando no hay sala. Sirve solamente para jugar
mientras se espera; nunca puede iniciar un match.

## Plugins

| Archivo | Responsabilidad |
|---|---|
| `mix_core.sma` | Knife, elección de lado, LIVE, marcador, pausas, reconexión, suplentes, halftime, overtime y cierre |
| `mix_web.sma` | Reclamar/recuperar sala, roster, cupos protegidos, ELO, heartbeat y consultas de resultado |
| `mix_2v2_layout.sma` | Editor Wingman: un bombsite fijo, spawns TT/CT y paredes de bloqueo |
| `mix_addon_pickupwep.sma` | Recogida de armas con USE |

`mix_core.amxx` debe cargar antes de `mix_web.amxx`, y `mix_2v2_layout.amxx`
después de ambos. El layout no hace nada en `mix_web_mode 5v5`.

## Flujo

```text
Una de las dos colas completa 4 (2v2) o 10 (5v5)
  -> draft y veto en la web
  -> MixClaimLobbyV2
  -> servidor público + changelevel
  -> recuperar mode, team_size y roster por AccId
  -> validar exactamente 2+2 o 5+5
  -> esperar que todo el roster esté logueado y dentro de TT/CT
  -> mostrar equipos, ELO y puntos en juego
  -> knife y elección de lado
  -> LIVE
  -> halftime / overtime
  -> ronda decisiva
  -> congelar, anunciar y reportar resultado
  -> warmup y servidor disponible
```

## Entrada inicial

La espera comienza al cargar el roster después del cambio de mapa y dura cinco
minutos. Se anuncia al instante y cada 30 segundos.

Cuenta solamente un slot único del roster que cumpla todo:

- conexión activa;
- cuenta accsys logueada;
- AccId perteneciente al roster;
- equipo físico TT o CT.

Espectador, unassigned, cuenta sin login o una conexión duplicada no cuentan.
`connected_at` se informa recién después de un `JOIN_GAME` válido que dejó al
jugador del roster físicamente en TT o CT; iniciar sesión como espectador no
equivale a presentarse.
Si quedan slots pendientes al llegar a `00:00`, `mix_cancel` limpia el core y
`MixCancelNoShowLobbyV2` sanciona solamente a los ausentes y libera la sala en una
transacción. Las demás cancelaciones usan `MixCancelLobby` y no sancionan.

La espera sigue viva hasta que la partida llega a LIVE. Si alguien sale durante
la preparación, el knife o la elección de lado, el core vuelve a warmup y el
faltante tiene lo que quede del plazo, con un mínimo de 120 segundos. Al
vencer, el plugin envía los AccIds que no están en TT/CT: quien entró y salió
antes de LIVE cuenta como ausente aunque ya tuviera `connected_at`.

## Equipos y ELO

Al crear la sala se toman los cuatro jugadores con ELO más alto y se sortean
dos de ellos como capitanes. El orden del roster no decide la capitanía; el
servidor tampoco redistribuye a nadie después del draft. Cuando está unido el
roster completo muestra:

```text
[AUTOMIX] Equipo Lis: 1120 ELO (+28 si gana / -22 si pierde).
[AUTOMIX] Equipo Juanito: 1180 ELO (+22 si gana / -28 si pierde).
```

Los promedios salen de `zgaming_web.mix_elo` para el mismo `mode` del lobby,
usando 1000 para una cuenta sin fila. El ELO 2v2 y el ELO 5v5 no se mezclan. Los
puntos usan exactamente el cálculo del cierre web:

```text
esperado_A = 1 / (1 + 10 ^ ((promedio_B - promedio_A) / 400))
delta_A = round(50 * (resultado_A - esperado_A))
```

## Knife y LIVE

Al iniciar knife se limpian kills/deaths del scoreboard. Al pasar a LIVE se
vuelven a limpiar para que las bajas de cuchillo tampoco entren al marcador.
Durante LIVE se acumulan por AccId K/D/A, daño real aplicado, headshots y
rondas jugadas; al cerrar, la web calcula ADR, K/R y HS% sin aproximaciones. El
JSON recorre el tamaño real del roster: cuatro entradas en 2v2 y diez en 5v5.

El ganador del knife elige quedarse o cambiar. Si alguien falta antes del
inicio, se vuelve a warmup conservando roster y lado ya elegido.

El knife dura 2 minutos. Si se agota el tiempo, gana el equipo con mayor HP
total restante; un empate exacto se decide 50/50.

## Cambio de lado

El descanso usa `mix_halftime_break`, mantiene los micrófonos cruzados abiertos
y termina con `5, 4, 3, 2, 1`.

```text
fin de ronda -> descanso -> swap -> único restart natural -> freezetime
```

El plugin posterga el restart que ya pertenece a la ronda terminada. Aplica el
swap justo antes de ese respawn y no llama otro restart. El marcador del TAB
sigue a los equipos web y la economía de la nueva mitad parte sin rachas de
derrota heredadas.

El inicio de overtime, su cambio de lado y un overtime nuevo usan la misma
transición. Cada mitad de overtime comienza con el dinero configurado y sin un
restart intermedio.

## Reconexión y suplentes

Durante knife/LIVE se conserva por AccId:

- equipo y capitanía;
- K/D/A interno;
- dinero, armas, cargadores y munición;
- armadura, casco y defuse kit;
- reconexiones usadas.

La pausa técnica automática dura `mix_pause_duration` (30 segundos por
defecto), pero el jugador conserva todo el plazo `mix_reconnect_time` (120
segundos por defecto). Al terminar la pausa se reanuda el mismo freezetime: no
hay respawn, restart ni segundo cobro de economía. El plazo restante continúa
mientras se juega.

Cuando vence el plazo, se informa el abandono a la web y el slot queda vacante.
Un espectador logueado puede tomarlo; `MixReplacePlayer` cambia el AccId del
roster sin cambiar el equipo. El suplente comienza sus estadísticas desde cero.
La guardia conserva como máximo un candidato autenticado por vacante y expulsa
al resto; al cubrirla elimina inmediatamente la ficha desconectada anterior.
El jugador cuyo plazo ya venció puede volver a unirse a su propio slot mientras
siga vacante (ningún suplente lo tomó). Solo cambia lo que ocurre dentro del
servidor: su fila SQL sigue marcada como abandono y la falta se registra igual.
En ELO, si su equipo pierde, pierde lo mismo que el equipo (mínimo 25). Si su
equipo gana y él jugó —sumó al menos una ronda desde que volvió y sigue en su
equipo al terminar—, el reporte lo marca con `"b":1` y `MixFinishMatch` le da
la mitad de la victoria en vez del castigo. Sin eso, pierde 25. Recupera el dinero que
tenía al salir y no obtiene otro plazo de reconexión: si vuelve a salir, el
slot se abre de inmediato. Si un suplente ya ocupó el slot, queda como
espectador.
Aunque en 2v2 se desconecte un equipo completo, primero se respetan los 120
segundos: la sala no se cancela por una pérdida temporal de conexiones.

## Fin inmediato

La ronda que entrega el punto ganador llama al cierre inmediatamente desde el
evento de fin de ronda. Los jugadores quedan congelados y sin daño durante dos
segundos:

```text
[AUTOMIX] Equipo Lis ganó 5-16 al equipo Juanito.
[AUTOMIX] Para jugar nuevamente, ingresa a zgaming.net/mix.
```

Si no hay consultas de abandono ni reemplazo pendientes, `MixFinishMatch` sale
inmediatamente. El margen de 1,5 segundos se conserva mientras cualquiera de
esas escrituras siga activa; el cierre mantiene sus cinco reintentos ante fallos
SQL y el reemplazo reintenta tres veces antes de rendirse.

## Comandos activos

| Comando | Uso |
|---|---|
| `.status` | Estado del servidor y jugadores del roster unidos |
| `.score` | Marcador |
| `.dmg` | Daño de la ronda |
| `.pause` / `.unpause` | Pausas durante LIVE |
| `.cancel` | Cancelación con permisos |
| `mix_cancel` | Cancelación por consola/RCON y timeout inicial |

## Cvars activas

| Cvar | Default |
|---|---:|
| `mix_live_countdown_time` | 5 |
| `mix_reconnect_time` | 120 |
| `mix_pause_duration` | 30 |
| `mix_rounds_per_half` | 15 |
| `mix_rounds_overtime` | 3 |
| `mix_freezetime` | 12 |
| `mix_halftime_break` | 15 |
| `mix_overtime_start_money` | 10000 |
| `mix_max_pauses_per_team` | 1 |
| `mix_max_reconnects_per_player` | 1 |
| `mix_web_server_id` | 16 |
| `mix_web_mode` | `5v5` |
| `mix2v2_layout_enabled` | 1 |

El editor Wingman 2v2 usa AccSys: se abre solo para una cuenta logueada con
rango `RH` al entrar al servidor. También se puede abrir con `mix2v2_spawns`
(aliases `mix2v2_menu` y `amx_mix2v2_menu`). El comando únicamente abre el
menú; ahí se fija un único bombsite, se crean spawns TT/CT y se colocan paredes
de bloqueo.

`mix_web_mode` controla qué lobby nuevo puede reclamar la instancia:

- `all`: acepta 2v2 y 5v5;
- `2v2`: acepta solamente 2v2;
- `5v5`: acepta solamente 5v5.

Una sala `live` que ya pertenece al `mix_web_server_id` siempre se recupera,
aunque el filtro haya cambiado, para no dejar una partida huérfana. No existe
`mix_team_size`: el tamaño confiable llega en la fila del lobby y debe coincidir
con su modo. Un 2v2 requiere al menos 5 slots físicos (4 + HLTV); un 5v5, 11.

### Dos servidores y dos puertos

El despliegue normal es dedicado: cada instancia tiene su propia fila en
`accsys.servers`, su propio `server_id` y su propio `server_port`. No se debe
dejar `all` en producción cuando hay un servidor por modalidad.

Servidor 5v5 actual (`server.cfg`):

```cfg
mix_web_server_id "16"
mix_web_mode "5v5"
```

Servidor 2v2 nuevo (`server.cfg`; reemplazar los valores por la fila/puerto
reales creados para esa instancia; en la instalación actual son `18` y
`27031`):

```cfg
mix_web_server_id "18"
mix_web_mode "2v2"
```

La instancia 2v2 instalada escucha en `23.26.135.117:27031` y corresponde a
la fila `accsys.servers.id=18`. El `#17` del hostname es solo la etiqueta
visible del servidor; no sustituye al `server_id` usado por el bridge.

`MixClaimLobbyV2` filtra antes de reclamar, de modo que el puerto 5v5 nunca
toma un roster 2v2 y el puerto 2v2 nunca toma uno 5v5. Al reclamar, la sala
guarda ese `server_id`; la web resuelve `public_ip:server_port` desde
`accsys.servers`, así el botón CONECTAR apunta al puerto correcto.

## Compilación

El include del bridge está en `include/mix_core.inc`. Además hacen falta los
includes de AccSys (`accsys/accounts`, `accsys/database`), ReAPI y JSON.
Validación AMXX 1.10 desde PowerShell:

```powershell
& 'E:\AMXX\Compilador\amxxpc.exe' 'mix_core.sma' '-iinclude' '-iE:\AMXX\Includes' '-omix_core.amxx'
& 'E:\AMXX\Compilador\amxxpc.exe' 'mix_web.sma'  '-iinclude' '-iE:\AMXX\Includes' '-omix_web.amxx'
```

Los `.amxx` no se versionan.

`mix_core.amxx` debe seguir cargando antes de `mix_web.amxx` porque el bridge
consume sus natives.

## Despliegue coordinado

Toda la base del mix (tablas `mix_*` y procedimientos `Mix*` de
`zgaming_web`) vive en un único archivo, `sql/schema.sql`, al día con
producción. Es idempotente: crea las tablas que falten sin borrar datos y
reemplaza los procedimientos. No hay migraciones sueltas: cualquier cambio de
base se hace en ese archivo.

```bash
mariadb < sql/schema.sql
```

El orden seguro es:

1. aplicar `sql/schema.sql`;
2. actualizar DiscordBot, que ya agrupa cola y avisos por modalidad;
3. registrar/verificar en `accsys.servers` la instancia 2v2 con su otro puerto;
4. configurar el servidor actual como `5v5` y el nuevo como `2v2`, cada uno con
   su `mix_web_server_id`;
5. cargar `mix_core.amxx` y luego `mix_web.amxx` en ambas instancias;
6. desplegar la web, que recién entonces permite crear filas y salas 2v2.

El schema conserva `MixClaimLobby`, `MixGetLobbyForServer` y
`MixCancelNoShowLobby` como bridge legacy (el claim legacy es exclusivamente
5v5). Por eso la base puede actualizarse primero sin que un plugin antiguo tome
por error un roster de cuatro. El bridge nuevo requiere `MixClaimLobbyV2`,
`MixGetLobbyForServerV2` y `MixCancelNoShowLobbyV2` antes de cargar
`mix_web.amxx`.

El pool de mapas es compartido por ahora y las dos últimas repeticiones se
evitan por modalidad. El plugin 2v2 fija un solo bombsite por mapa y permite cerrar las
rutas restantes con paredes de colision (visibles como contorno laser solo dentro del editor); no modifica la bomba. La API ya recibe el modo, así que se puede
separar el pool cuando existan assets específicos sin volver a cambiar el
contrato.
ELO, ranking, últimas 30 partidas y estadísticas sí quedan separados desde el
primer día.
