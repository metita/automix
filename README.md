# Automix

Plugins AMX Mod X del mix competitivo de ZGaming (2v2 y 5v5). Las partidas se
arman en `zgaming.net/mix` y el servidor ejecuta knife, LIVE, halftime,
overtime, reconexiones, suplentes y el reporte de resultado y ELO.

## Contenido

| Ruta | Qué es |
|---|---|
| `mix_core.sma` | Flujo de la partida: knife, lados, LIVE, pausas, reconexión, suplentes, cierre |
| `mix_web.sma` | Bridge con la web: reclamar sala, roster, cupos protegidos, heartbeat, resultado |
| `mix_2v2_layout.sma` | Editor Wingman 2v2: bombsite fijo, spawns y paredes |
| `mix_addon_pickupwep.sma` | Recoger armas con USE |
| `include/mix_core.inc` | Natives y forwards entre core y bridge |
| `data/lang/mix_core.txt` | Diccionario |
| `configs/mix_2v2/` | Notas del layout 2v2 |
| `sql/schema.sql` | Schema único de la base del mix (`zgaming_web`), al día con producción |
| `MIX_DOCUMENTATION.md` | Documentación completa del flujo |

## Compilar

AMX Mod X 1.10. Requiere además los includes de AccSys, ReAPI y JSON.

```powershell
amxxpc.exe mix_core.sma -iinclude -i<includes> -omix_core.amxx
amxxpc.exe mix_web.sma  -iinclude -i<includes> -omix_web.amxx
```

Los `.amxx` no se versionan. `mix_core.amxx` debe cargar antes que
`mix_web.amxx` en `plugins.ini`.

## Base de datos

`sql/schema.sql` es idempotente: crea las tablas `mix_*` que falten sin borrar
datos y reemplaza los procedimientos `Mix*`. Depende de `accsys.accounts` y
`accsys.servers`. No hay migraciones sueltas: todo cambio de base va en ese
archivo.

```bash
mariadb < sql/schema.sql
```
