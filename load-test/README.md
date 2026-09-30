# Load test E2E con k6

Prueba de carga del flujo completo del sistema sobre el stack real.

## Qué cubre

Cada iteración de un virtual user recorre la cadena end-to-end:

1. `POST /validate` en validation-service (multipart con `test.pdf`).
2. `POST /extract` en extraction-service (extrae texto y persiste vía `DocumentRepository`).
3. `GET /documents/{id}` en persistence-service (recupera el documento).
4. `POST /summary/{document_id}` en summary-service (inferencia real con llama3.2 vía Ollama).

## Requisitos

- Docker Desktop corriendo y el stack levantado:

  ```powershell
  docker compose -f docker-compose.yml up -d
  ```

- [k6](https://k6.io) v2.x disponible (por defecto `C:\Program Files\k6\k6.exe`).

## Ejecución

```powershell
./load-test/run.ps1
```

Se pueden sobreescribir las URLs de los servicios con variables de entorno:

```powershell
$env:VALIDATION_URL = "http://localhost:8001"
$env:EXTRACTION_URL = "http://localhost:8002"
$env:PERSISTENCE_URL = "http://localhost:8003"
$env:SUMMARY_URL = "http://localhost:8004"
./load-test/run.ps1
```

### Dashboard web en vivo

k6 trae un dashboard web integrado para ver el run en tiempo real. Para
activarlo, pasar el switch `-Dashboard` al script:

```powershell
./load-test/run.ps1 -Dashboard
```

Abre el navegador automáticamente en `http://127.0.0.1:5665`; equivale a:

```powershell
$env:K6_WEB_DASHBOARD = "true"
$env:K6_WEB_DASHBOARD_OPEN = "true"   # opcional: auto-abrir el navegador
& "C:\Program Files\k6\k6.exe" run load-test/script.js
```

> Nota: **mientras haya una pestaña del dashboard abierta, k6 no termina** el
> proceso (te deja descargar el reporte HTML desde el botón *Report*). Cerrá la
> pestaña cuando termines de mirarlo; el proceso sale solo.
>
> En entornos no interactivos (CI) el dashboard no se debe servir: se puede
> exportar el reporte HTML sin levantar el servidor y terminar enseguida con
> `K6_WEB_DASHBOARD_PORT=-1`:
>
> ```powershell
> $env:K6_WEB_DASHBOARD = "true"
> $env:K6_WEB_DASHBOARD_PORT = "-1"
> $env:K6_WEB_DASHBOARD_EXPORT = "dashboard-report.html"
> & "C:\Program Files\k6\k6.exe" run load-test/script.js
> ```

## Perfil de carga

`script.js` usa un solo escenario `per-vu-iterations` con 1 VU y 3 iteraciones.
Es intencionalmente liviano en volumen: el paso `/summary` ejecuta inferencia
real de `llama3.2` por CPU, que demora del orden de decenas de segundos por
llamada. El objetivo es validar el flujo E2E bajo carga sostenida y medir
latencias por endpoint, no saturar a Ollama.

## Thresholds

| Endpoint   | Threshold (p95) | Sentido                                  |
| ---------- | --------------- | ---------------------------------------- |
| validate   | < 500 ms        | validación en memoria, debe ser rápida   |
| extract    | < 10 s          | extracción de texto + persistencia       |
| documents  | < 2 s           | lookup por id en Mongo                   |
| summary    | < 120 s         | inferencia LLM local (CPU)               |
| global     | errores < 2%    | no se toleran fallos en la cadena        |

## Artefactos generados

- `reporte.txt`: resumen legible del run (checks, latencias p95 por endpoint).
- `results.json.gz`: detalle completo de métricas por endpoint en JSON (comprimido).
- `report.txt` y `results.json.raw`: byproducts del run local (consola con ANSI y JSON
  sin comprimir) que no se commitean.

## Interpretación rápida

Un run exitoso muestra los 4 checks en verde y `✓` en todos los thresholds del
resumen. El `http_req_duration{name:*}` por endpoint permite comparar dónde se
gasta el tiempo: los servicios sin I/O (validate) deben rondar el milisegundo y
summary domina el total por la inferencia.

## Reproducir con otro PDF

```powershell
$env:PDF_PATH = "..\scripts\test.pdf"  # relativo al script.js
```