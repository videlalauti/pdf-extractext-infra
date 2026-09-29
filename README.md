# PDF ExtractExt — Infraestructura

Stack Docker Compose de los 4 microservicios de extracción de PDFs, con Traefik
como edge, MongoDB para persistencia y Ollama para resúmenes.

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

> Los puertos de **datos** (Mongo 27017, Ollama 11434) están solo en la red
> interna de Docker: publicarlos saltearía el perímetro de Traefik. Para
> inspeccionarlos: `docker compose exec mongo mongosh` o
> `docker compose exec ollama ollama list`.

## Smoke test

```powershell
.\scripts\smoke_test.ps1
```

Levanta el stack, espera el health de los 4 servicios y recorre el flujo completo
con `scripts/test.pdf`: valida, extrae, verifica el documento persistido por id
y por checksum, y genera el resumen. Sale con código 0 si todo pasó.

## Comandos útiles

```bash
docker compose logs -f <servicio>
docker compose config          # ver el compose resuelto
docker compose down
docker compose down -v         # borra también el volumen de ollama
```

## Estructura

```
docker-compose.yml            # los 4 servicios + ollama; incluye traefik/ y mongodb/
traefik/docker-compose.yml    # edge proxy (80/443)
traefik/config/               # configuración estática y dashboard
traefik/certs/                # GITIGNORED: se regenera con el script
mongodb/docker-compose.yml    # mongo, solo red interna
mongodb/.env-example          # plantilla de credenciales
mongodb/data/                 # GITIGNORED: datos de mongo
scripts/generate_certs.ps1    # regenera el par TLS
scripts/smoke_test.ps1        # smoke test E2E
```

El dominio compartido entre servicios ya no vive acá: se instala desde
[`pdf-extractext-shared`](https://github.com/videlalauti/pdf-extractext-shared).

## Notas

- `OLLAMA_CONTEXT_LENGTH` se puede sobreescribir por entorno; el default es
  `32768`, pensado para PDFs largos.
- La red `mired` es externa: hay que crearla antes del primer `up`.
- La llave TLS que estuvo commiteada en el historial fue purgada; si clonaste
  este repo antes, borrá el directorio local y cloná de nuevo.
