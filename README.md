# PDF ExtractExt — Infraestructura

Stack Docker Compose de los 4 microservicios de extracción de PDFs, con Traefik
como punto de entrada local (TLS y ruteo por host, puertos 80/443 ligados a
127.0.0.1). Detrás: MongoDB, Redis con persistencia AOF y Kafka en modo
KRaft de un solo nodo con volumen para eventos y offsets, más Ollama para
generar resúmenes.

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
> volver a levantar. Para rotarla hay un script que hace las dos cosas y avisa
> del orden: `.\scripts\rotate_mongo_credentials.ps1` (y después
> `-ResetData` con el stack abajo).

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

## Modos de ejecución

Hay dos formas de correr el sistema y **no usan los mismos hosts**. Elegir mal
es la causa más común de "no conecta".

### Compose (recomendado)

Todo el stack en Docker, detrás de Traefik. Los servicios **no publican puertos**:
se entra solo por `http://<servicio>.pdf.localhost`. Es el modo que corren el
smoke test y el CI, y el que se parece al despliegue.

```powershell
docker network create mired
docker compose up --build -d
```

### Local con uvicorn (debug de un servicio)

Para correr **un** servicio en el host con recarga automática contra los backing
services de Docker:

```powershell
Copy-Item docker-compose.override.yml.example docker-compose.override.yml
docker compose up -d mongo redis kafka ollama
```

Ese override publica `8001`–`8004` (servicios), `27017` (Mongo), `6379` (Redis),
`9094` (Kafka) y `11434` (Ollama). `docker compose` lo carga solo; el archivo
versionado es el `.example` para que un clone no abra puertos sin querer.

Variables para el servicio que corrés a mano (desde la raíz de su repo):

| Servicio | Variables de entorno |
| --- | --- |
| `validation` | `PORT=8001` |
| `extraction` | `PORT=8002`, `PERSISTENCE_SERVICE_URL=http://localhost:8003`, `REDIS_URL=redis://localhost:6379`, `KAFKA_BOOTSTRAP_SERVERS=localhost:9094` |
| `persistence` | `PORT=8003`, `MONGODB_HOST=localhost`, `MONGODB_PORT=27017`, `MONGODB_DATABASE_NAME=pdf_extractext`, `MONGODB_AUTH_SOURCE=admin`, y `MONGODB_ROOT_USERNAME` / `MONGODB_ROOT_PASSWORD` con los valores del `.env` de este repo |
| `summary` | `PORT=8004`, `PERSISTENCE_SERVICE_URL=http://localhost:8003`, `REDIS_URL=redis://localhost:6379/0`, `KAFKA_BOOTSTRAP_SERVERS=localhost:9094`, `OLLAMA_URL=http://localhost:11434` |

> **Kafka:** el host usa `localhost:9094`, no `9092`. El broker anuncia
> `kafka:9092` para la red de Docker; publicar ese puerto no alcanza porque el
> cliente recibiría metadata con un nombre que el host no resuelve. El listener
> `EXTERNAL` en `9094` existe solo en el override.

> El override es **solo para desarrollo**. En producción no se usa: el único
> puerto abierto al host es el de Traefik (80/443).

## Probar cada servicio

El único punto de entrada es Traefik: los 4 servicios **no publican puertos** en
el host.

- http://validation.pdf.localhost/health
- http://extraction.pdf.localhost/health
- http://persistence.pdf.localhost/health
- http://summary.pdf.localhost/health
- https://traefik.localhost — dashboard

> Los puertos de **datos** (Mongo 27017, Ollama 11434, Redis 6379) están solo en
> la red interna de Docker: publicarlos saltearía el perímetro de Traefik. Para
> inspeccionarlos: `docker compose exec mongo mongosh`,
> `docker compose exec ollama ollama list` o `docker compose exec redis redis-cli ping`.

> Para pegarle directo a un servicio (sin Traefik) hace falta el override de
> desarrollo: ver [Modos de ejecución](#modos-de-ejecución).

## Flujo de eventos

El camino real de un PDF, sin atajos:

1. `validation` valida el PDF.
2. `extraction` extrae el texto, lo persiste en `persistence` y **publica el
   evento `documents.extracted`** en Kafka (schema v1: `document_id`,
   `checksum`, `request_id`).
3. `summary` **consume** ese evento (`group_id=summary-service`,
   `auto_offset_reset=earliest`) y genera el resumen con Ollama. El resultado se
   guarda en Redis con TTL de 7 días; los estados no terminales usan 1 h.

La publicación es **fail-open**: si Kafka está caído, `extraction` reintenta 3
veces y responde igual, con `summary_status: "unavailable"` en vez de un 5xx (el
documento ya quedó persistido). El cliente puede pedir el resumen explícito con
`POST /summary/{id}`.

### Contrato de summary

| Llamada | Resultado |
| --- | --- |
| `POST /summary/{document_id}` | `200` con el resumen si ya existe; `202 {"status":"queued"}` si recién se encola |
| `GET /summary/{document_id}` | `200` con el resumen cuando está listo; `202 {"status":"queued"}` mientras corre; `404` si nunca se pidió |

El `POST` también agenda el trabajo en background: el evento de Kafka es el
camino normal, pero un evento perdido no deja al pedido explícito en `queued`
para siempre. La inferencia de Ollama puede tardar minutos: `202` no es un
error, es "seguí consultando con `GET`".

## Smoke test

```powershell
.\scripts\smoke_test.ps1
```

Levanta el stack, espera el health de los cuatro servicios y recorre
el flujo con `scripts/test.pdf`. Agrega un comentario único al PDF para que
cada corrida tenga su propio checksum, lo valida y lo envía a `POST /upload`.
Comprueba persistencia y publicación (`summary_status=queued`), y consulta
cada 5 segundos el estado del job en Redis hasta `done` (máx. 300 s).
**Recién después llama a `GET /summary`** para comprobar el resultado.
Así, el GET no puede esconder un fallo del consumer de Kafka al reencolar un
trabajo faltante. El archivo `scripts/test.pdf` original no se modifica.

Al terminar **baja el stack**, haya pasado o fallado: si algo falla, vuelca los
últimos logs de los contenedores antes de limpiar. Para quedarte con el stack
prendido, levantalo a mano con `docker compose up -d` y usá el script solo
como verificación en un entorno desechable.

El workflow `smoke.yml` ejecuta el test en `main` y en los PRs.
En el PR de integración `fix/durable-stack-and-e2e-20261104`, clona las
ramas de corrección de los otros cuatro microservicios en lugar de `main`,
para verificar la migración completa sin fusionar código.

> **En Windows**, `*.pdf.localhost` puede no resolverse correctamente
> desde PowerShell. El smoke usa `127.0.0.1` con la cabecera HTTP `Host`
> original, de modo que Traefik reconoce cada servicio sin modificar
> `C:\Windows\System32\drivers\etc\hosts` ni pedir permisos de administrador.
> Para acceder con otras herramientas que no permiten elegir esa cabecera,
> puede seguir siendo necesario configurar la resolución de nombres.

> **Kafka y el smoke test:** `kafka-init` crea `documents.extracted`.
> El smoke espera `done` en Redis sin llamar a `GET/POST /summary`, por lo
> que verifica el procesamiento disparado por el evento Kafka. No reemplaza
> pruebas específicas de reinicio o pérdida de broker/volumen.

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

**Kafka va en `mired`** (extraction y summary le hablan por `kafka:9092`), también
sin puerto publicado al host. Corre en modo **KRaft single node**: broker y
controller en el mismo proceso, sin ZooKeeper. El topic `documents.extracted`
(particiones=1, replication=1) lo crea el one-shot `kafka-init` tras el health
del broker, con `auto.create.topics.enable=false`: los topics se declaran
explícitos. El volumen `kafka-data` conserva eventos y offsets entre
recreaciones ordinarias, pero un único broker no es alta disponibilidad.

Para inspeccionar topics: `docker compose exec kafka /opt/kafka/bin/kafka-topics.sh
--bootstrap-server localhost:9092 --list`.

## Recursos y logs

Cada servicio tiene `deploy.resources.limits` de memoria y CPU, para que un
servicio que se coma la RAM no tumbe al resto. Ollama se lleva 6G porque cargar
un modelo en RAM son gigas; el resto va entre 256M y 2G.

Redis acota en dos niveles: el contenedor a **256 MB / 0.5 CPU** y
`--maxmemory 128mb --maxmemory-policy noeviction`. Usa AOF (`appendfsync
everysec`) y el volumen `redis-data`, conservado por `docker compose down`
sin `-v`. Los trabajos tienen TTL según su estado, por lo que ni el volumen
ni AOF reemplazan almacenamiento durable de largo plazo.

Los logs usan el driver `json-file` con rotación de 10 MB × 3 por servicio (ancla
`x-logging` en los tres compose). Traefik además tiene `accessLog` en JSON, con
`RequestHost`, `RequestPath`, status y duración por petición.

## Estructura

```
docker-compose.yml            # los 4 servicios + ollama; incluye traefik/, mongodb/, redis/ y kafka/
docker-compose.override.yml.example  # puertos para debug local (copiar a docker-compose.override.yml)
traefik/docker-compose.yml    # edge proxy (80/443), pineado por digest
traefik/config/               # configuración estática, access log y dashboard
traefik/certs/                # GITIGNORED: se regenera con el script
mongodb/docker-compose.yml    # mongo, solo en la red interna de datos
mongodb/.env-example          # plantilla de credenciales
mongodb/data/                 # GITIGNORED: datos de mongo
redis/docker-compose.yml      # redis con AOF y volumen, sin puerto publicado
kafka/docker-compose.yml      # Kafka KRaft single-node con volumen + kafka-init
scripts/generate_certs.ps1    # regenera el par TLS
scripts/rotate_mongo_credentials.ps1  # rota la password de Mongo del .env local
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
- El healthcheck de `/health` vive en el **Dockerfile** de cada servicio, no en
  el compose. Compose hereda el de la imagen y lo usa para
  `condition: service_healthy` y para `docker compose ps`: una sola fuente de
  verdad por servicio.
- La llave TLS que estuvo commiteada en el historial fue purgada; si clonaste
  este repo antes, borrá el directorio local y cloná de nuevo.
