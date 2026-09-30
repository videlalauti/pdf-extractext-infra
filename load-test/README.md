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
- Perfil en `script.js`: 1 VU × 3 iteraciones, thresholds p95 por endpoint (validate < 500 ms, extract < 10 s, documents < 2 s, summary < 120 s, errores < 2 %).
- Sobrescribir URLs con env: `VALIDATION_URL`, `EXTRACTION_URL`, `PERSISTENCE_URL`, `SUMMARY_URL`. PDF con `PDF_PATH` (default `../scripts/test.pdf`).