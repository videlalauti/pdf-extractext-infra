# PDF ExtractExt — Infraestructura

Stack Docker Compose de los 4 microservicios de extracción de PDFs, con Traefik
como edge, MongoDB para persistencia, Redis como caché (efímero, sin volumen) y
Ollama para resúmenes.

## Requisitos

- Docker y Docker Compose.
- Tener clonados los 4 repos de servicios como carpetas hermanas de este repo:

```
../pdf-extractext-validation
../pdf-extractext-extraction
../pdf-extractext-persistence
../pdf-extractext-summary
```

## Configuración

### 1. Credenciales de MongoDB

Mongo **no tiene password por defecto**. El stack falla explícito si faltan las
variables, así que el primer paso es crearlas:

```powershell
Copy-Item mongodb/.env-example .env
```

Abrí `.env` y reemplazá los dos placeholders por valores reales:

```text
MONGODB_ROOT_USERNAME=extractext_dev
MONGODB_ROOT_PASSWORD=<algo largo y aleatorio>
```

`.env` vive en la raíz del repo y está en `.gitignore`: nunca se commitea. Las
mismas dos variables alimentan a `mongo` (como `MONGO_INITDB_ROOT_*`) y a
`persistence-service` (como `MONGODB_ROOT_*`), así que no hay dos juegos de
credenciales que puedan desincronizarse.

> Ojo: Mongo solo aplica `MONGO_INITDB_ROOT_*` la **primera** vez que crea el
> volumen. Si cambiaste la password después, hay que borrar `mongodb/data/` y
> volver a levantar.

### 2. Certificados TLS de Traefik

El par autofirmado no está en el repo (es un secreto). Generalo con:

```powershell
.\scripts\generate_certs.ps1
```

Crea `traefik/certs/cert.pem` y `traefik/certs/key.pem` para `*.pdf.localhost`,
válidos 825 días. Son autofirmados: el browser va a avisar, se acepta y sigue.
Para regenerarlos (vencieron o se perdieron) se corre el mismo comando.

## Arranque

```powershell
docker network create mired
docker compose up --build -d
docker compose ps
```

Traefik levanta los servicios en cuanto cada contenedor está sano; la primera
vez tarda porque hay que construir las 4 imágenes y descargar Mongo y Ollama.

## Probar cada servicio

Por Traefik (recomendado):

- http://validation.pdf.localhost/health
- http://extraction.pdf.localhost/health
- http://persistence.pdf.localhost/health
- http://summary.pdf.localhost/health
- https://traefik.localhost — dashboard

O directo por puerto, sin pasar por Traefik:

- http://localhost:8001/health
- http://localhost:8002/health
- http://localhost:8003/health
- http://localhost:8004/health

> Los puertos de **datos** (Mongo 27017, Ollama 11434, Redis 6379) están solo en
> la red interna de Docker: publicarlos saltearía el perímetro de Traefik. Para
> inspeccionarlos: `docker compose exec mongo mongosh`,
> `docker compose exec ollama ollama list` o `docker compose exec redis redis-cli ping`.

## Smoke test

```powershell
.\scripts\smoke_test.ps1
```

Levanta el stack, espera el health de los 4 servicios y recorre el flujo completo
con `scripts/test.pdf`: valida, extrae, verifica el documento persistido por id
y por checksum, y genera el resumen. El resumen tolera los dos contratos: si
`POST /summary` responde `200` usa el resultado directo; si responde `202`
(encola) hace poll a `GET /summary` cada 5 s hasta el `200` (máx 300 s). Sale
con código 0 si todo pasó.

Al terminar **baja el stack**, haya pasado o fallado: si algo falla, vuelca los
últimos logs de los contenedores antes de limpiar. Para quedarte con el stack
prendido, levantalo a mano con `docker compose up -d` y usá el script solo
como verificación en un entorno desechable.

Es el mismo test que corre el workflow `smoke.yml` en cada push a `main`.

## Comandos útiles

```bash
docker compose logs -f <servicio>
docker compose config          # ver el compose resuelto
docker compose down
docker compose down -v         # borra también el volumen de ollama
```

## Redes

Dos redes, con propósitos distintos:

- **`mired`** (externa, hay que crearla): transporte entre servicios y Traefik.
- **`mongo_net_interna`** (la crea Compose, `internal: true`): los datos. No tiene
  salida a internet y **mongo no está en `mired`**, así que nada alcanzable desde
  la red de servicios puede tocar la base. `persistence-service` es el único
  puente entre las dos.

Para entrar a mongo hay que hacerlo desde un contenedor que esté en la red de
datos: `docker compose exec persistence-service ...`, o
`docker compose run --rm --network pdf-extractext-infra_mongo_net_interna mongo mongosh`.

**Redis no sigue ese patrón**: está en `mired` (los servicios lo necesitan para
la caché) pero **sin puerto publicado al host**, igual que mongo. Se llega solo
por dentro (`redis:6379`) o por `docker compose exec redis redis-cli ping`.

## Recursos y logs

Cada servicio tiene `deploy.resources.limits` de memoria y CPU, para que un
servicio que se coma la RAM no tumbe al resto. Ollama se lleva 6G porque cargar
un modelo en RAM son gigas; el resto va entre 256M y 2G.

Redis acota en dos niveles: el contenedor a **256 MB / 0.5 CPU** (bulkhead, como
el resto) y adentro `--maxmemory 128mb --maxmemory-policy noeviction`. Es
**efímero**: no tiene volumen, así que cada `down` lo deja vacío (la caché se
reconstruye sola; si un dataset no entra en 128 MB, Redis falla explícito en
los logs en vez de descartar entradas en silencio).

Los logs usan el driver `json-file` con rotación de 10 MB × 3 por servicio (ancla
`x-logging` en los tres compose). Traefik además tiene `accessLog` en JSON, con
`RequestHost`, `RequestPath`, status y duración por petición.

## Estructura

```
docker-compose.yml            # los 4 servicios + ollama; incluye traefik/, mongodb/ y redis/
traefik/docker-compose.yml    # edge proxy (80/443), pineado por digest
traefik/config/               # configuración estática, access log y dashboard
traefik/certs/                # GITIGNORED: se regenera con el script
mongodb/docker-compose.yml    # mongo, solo en la red interna de datos
mongodb/.env-example          # plantilla de credenciales
mongodb/data/                 # GITIGNORED: datos de mongo
redis/docker-compose.yml      # redis (caché), efimero y sin puerto publicado
scripts/generate_certs.ps1    # regenera el par TLS
scripts/smoke_test.ps1        # smoke test E2E
.github/workflows/compose.yml # valida el compose
.github/workflows/smoke.yml   # corre el smoke E2E en cada push a main
```

El dominio compartido entre servicios ya no vive acá: se instala desde
[`pdf-extractext-shared`](https://github.com/videlalauti/pdf-extractext-shared).

## Notas

- `OLLAMA_CONTEXT_LENGTH` se puede sobreescribir por entorno; el default es
  `32768`, pensado para PDFs largos.
- La red `mired` es externa: hay que crearla antes del primer `up`.
- Los healthcheck de `/health` están en el compose, no en el Dockerfile de cada
  servicio. Son provisorios: hacen falta para que `condition: service_healthy`
  funcione, y se pueden borrar cuando cada servicio traiga el suyo.
- La llave TLS que estuvo commiteada en el historial fue purgada; si clonaste
  este repo antes, borrá el directorio local y cloná de nuevo.
