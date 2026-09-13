# Wingman 2v2 por mapa

`mix_2v2_layout.amxx` prepara el servidor 2v2 (`27031`) como Wingman: un
bombsite fijo, spawns agrupados por equipo y paredes de colision para cerrar el
resto del mapa. Se carga después de `mix_core.amxx` y `mix_web.amxx`.

## Qué hace

- Elige un único bombsite A o B para todo el mapa.
- Permite crear cualquier cantidad de spawns TT y CT para ese site.
- Asigna una posición libre a cada jugador durante el freeze.
- Crea paredes con colisión real para limitar las rutas al site. Mientras el
  menú de paredes está abierto, el administrador ve un contorno láser de cada
  caja para poder ubicarlas; al cerrar el menú ese contorno desaparece y en la
  partida la pared sigue siendo invisible.
- Solo actúa en `mix_web_mode 2v2`, LIVE/OVERTIME y durante freeze.
- Si falta un spawn o está bloqueado, conserva el spawn normal del mapa.

## Preparar un mapa

1. Cambiar mapa en `27031`.
2. Entrar con AccSys logueado y rango `RH`; el menú se abre automáticamente.
   También se puede abrir con `mix2v2_spawns` (aliases `mix2v2_menu` y
   `amx_mix2v2_menu`).
3. Elegir el bombsite activo A o B. La elección no cambia entre rondas.
4. Crear al menos 2 spawns TT y 2 CT dentro de la zona jugable.
5. Marcar una esquina inferior de la pared como punto 1. Luego marcar la
   esquina superior opuesta como punto 2; la pared se crea y guarda sola.
6. Validar y probar varias rondas.

Las modificaciones se guardan automáticamente en
`configs/mix_2v2/<mapa>.cfg`.

## Formato

```text
site A
spawn A TT X Y Z YAW
spawn A CT X Y Z YAW
wall2 X1 Y1 Z1 X2 Y2 Z2
```

Los dos puntos son esquinas opuestas del volumen. Sus diferencias en X/Y
definen el ancho y el grosor; la diferencia en Z define la altura. El plugin no
agrega tamaños, grosor ni altura por su cuenta: el contorno mostrado es la
colisión exacta que se guarda.

No se alternan sites, no se editan coordenadas a mano y no hay comandos de
edición separados: el comando solo abre el menú.
