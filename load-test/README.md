# Load test E2E con k6

Carga el flujo completo del sistema sobre los 4 microservicios (validate → extract → documents → summary).

## Correr

Requiere Docker Desktop con el stack levantado:

```powershell
docker compose -f docker-compose.yml up -d
./load-test/run.ps1            # resumen en la terminal
./load-test/run.ps1 -Dashboard # + dashboard en vivo http://127.0.0.1:5665
```

## Notas

- `run.ps1` usa `k6` (por defecto `C:\Program Files\k6\k6.exe`) e imprime el resumen estándar de k6 al terminar; con `-Dashboard` además abre el dashboard web en vivo.
- Con dashboard, k6 no termina mientras haya una pestaña abierta en `http://127.0.0.1:5665`: cerrarla para que salga.
- Perfil en `script.js`: 1 VU × 3 iteraciones, thresholds p95 por endpoint (validate < 500 ms, extract < 10 s, documents < 2 s, summary < 300 s, errores < 2 %). El resumen de documentos reales grandes (cientos de KB) ejecuta llama3.2 por CPU y puede tomar ~2-3 min; por eso el p95 del summary es 300 s.
- Sobrescribir URLs con env: `VALIDATION_URL`, `EXTRACTION_URL`, `PERSISTENCE_URL`, `SUMMARY_URL`.

## Flujo del summary (contrato async)

El paso de summary no bloquea en la inferencia: hace `POST /summary/{id}` y
después hace poll contra `GET /summary/{id}` cada 5 s hasta que responde `200`
con el texto (máximo ~300 s).

```text
POST /summary/{id}  →  202 (encola)          [timeout 300 s]
   └─ loop: sleep 5 s → GET /summary/{id}    →  202 / 409: sigue en curso
                                    └─        200: listo, hay texto
```

- El check "summary encola (202) o responde directo (200)" **acepta los dos
  contratos**: hoy summary es síncrono (responde `200` con el resultado en la
  misma llamada y no hay poll), y cuando pase a asíncrono el `POST` va a
  responder `202` y el resultado se busca por `GET`. Sirve antes y después del
  cambio, sin tocar el script de nuevo.
- **1ª corrida lenta** (~4-5 min en total): inferencia real de llama3.2 por CPU.
- **2ª corrida con los mismos PDFs instantánea**: el resultado cacheado en
  Redis se devuelve al toque (cache hit) y el poll termina a la primera.
- `thresholds` del tag `summary`: `p(95)<300000` — cubre el poll completo,
  inferencia real incluida.

## PDF del test

- `PDF_PATH`: un solo PDF (default `../scripts/test.pdf`, rutas relativas a `load-test/`).
- `PDF_FILES`: lista de PDFs separados por coma; en cada iteración rota entre ellos (`__ITER % n`). Ejemplo:

  ```powershell
  $env:PDF_FILES = "pdfs\Filosofia Lean.pdf,pdfs\Essential-Kanban-Condensed-Spanish.pdf,pdfs\scrum_manager_historias_usuario.pdf,pdfs\2020-Scrum-Guide-Spanish-Latin-South-American.pdf"
  ./load-test/run.ps1
  ```

  Con las 3 iteraciones del perfil se ejercitan 3 de los 4 archivos; ajustar `iterations` en `scenarios` de `script.js` para cubrirlos todos.
  La carpeta `load-test/pdfs/` está gitignoreada (no se commitea): es corpus local de pruebas.