AUTOMIX WINGMAN 2v2 - un bombsite por mapa
============================================

El editor usa menu y AccSys. Al entrar al servidor 2v2 con una cuenta logueada
y rango RH, el menu se abre automaticamente. Tambien puedes abrirlo con:
  mix2v2_spawns
Aliases: mix2v2_menu, amx_mix2v2_menu

Flujo rapido para cada mapa:

1. Entra al mapa y abre el menu.
2. En "Bombsite activo", selecciona A o B. Esta eleccion queda fija
   para todo el mapa y para todas las rondas.
3. Entra a "Spawns del bombsite".
4. Parate donde quieres una salida TT y elige "Crear spawn TT donde estoy".
5. Repite las posiciones TT que necesites y crea las posiciones CT del mismo
   site. Se recomiendan al menos 2 TT y 2 CT.
6. Entra a "Paredes de bloqueo". Marca una esquina inferior como punto 1 y
   luego la esquina superior opuesta como punto 2. La pared se crea y guarda
   automaticamente con esas dimensiones exactas.
7. Usa "Validar configuracion" y prueba varias rondas.

Wingman no alterna A/B: el mapa tiene un solo bombsite activo. Las paredes son
cajas con colision real para cerrar el resto del mapa. Mientras el menu de
paredes esta abierto se muestran como contornos laser para ubicarlas; fuera del
editor siguen siendo invisibles. Si faltan spawns o alguno esta bloqueado, el
jugador conserva el spawn normal.

Las opciones de paredes son:
  - Marcar punto 1 en una esquina de la pared.
  - Marcar punto 2 en la esquina opuesta para crearla.
  - Cancelar el punto 1 para volver a empezar.
  - Borrar la pared donde estas apuntando.
  - Borrar todas las paredes del mapa.

La diferencia X/Y entre ambos puntos define ancho y grosor; la diferencia Z
define la altura. No existen tamaños predeterminados ni cvars de dimensiones.

El archivo se guarda en:
  addons/amxmodx/configs/mix_2v2/<mapa>.cfg

Formato generado automaticamente:
  site A
  spawn A TT X Y Z YAW
  spawn A CT X Y Z YAW
  wall2 X1 Y1 Z1 X2 Y2 Z2

El layout solo se aplica durante LIVE/OVERTIME del modo 2v2 y durante freeze.
No modifica knife, warmup, halftime, 5v5 ni reconexiones en plena ronda.
