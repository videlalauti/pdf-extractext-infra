# Plan de accion — Defensa PDF ExtractExt (2026-11-05)

**Objetivo:** demostracion funcional, arquitectura por capas defendible, resiliencia,
persistencia real, salud de servicios y seguridad. Cada miembro integrara **su
propia rama** mediante merge squash local + commit de SU autor y push a main.
Ninguna rama se integra automaticamente. El owner de GitHub debe respetar la
atribucion y la integracion del equipo.

## Orden y responsable

1. **Infra**, Videla. Rama `feat/demo-automation-and-proxy-resilience-20261105`.
   Preparar rutas/CB de Traefik, automatizacion Python y runbook. Es retrocompatible
   con los servicios: cambian URLs por variables de entorno del Compose.
2. **Validation**, Arcidiacono: separar controlador/aplicacion/dominio; demostrar
   validacion y errores reales.
3. **Persistence**, Martinez: separar aplicacion y repositorio, mostrar MongoDB
   en Compass y ciclo de vida/errores reales.
4. **Extraction**, Lasagno: delimitar caso de uso /upload, mantener consumidores
   compatibles con la entrada privada de Traefik; tests de fallos y duplicados.
5. **Summary**, Sabio: demostrar consumo Kafka/estado Redis, integracion Ollama,
   errores y health; clarificar las capas.
6. **Shared**, Videla: revisar importaciones/contratos/test; cambios coordinados
   mediante version publicada cuando se requiera (NO alterar version sin acuerdo).

## Issues propuestos para GitHub Projects

Las casillas sirven como criterios de aceptacion; crear cada issue en el
repositorio que figura en el encabezado.

### Infra — pdf-extractext-infra

**INF-01 [P0] Demo con un solo comando Python: start/stop/status**
- [ ] `python scripts/dev.py start` inicia stack sin escribir docker compose a mano.
- [ ] Gestiona la red `mired` y certificados faltantes; no imprime secretos.
- [ ] `stop` conserva volúmenes; `status` presenta estado de contenedores.
- [ ] Pruebas unitarias y uso documentado.
Estado: implementado en la rama Infra, pendiente de E2E en PC con Docker.

**INF-02 [P0] Compass bajo demanda y verificacion persistente de un PDF**
- [ ] `python scripts/dev.py compass-on` publica Mongo solo en 127.0.0.1:27017.
- [ ] Mongo conserva su red privada; la segunda red bridge es temporal.
- [ ] `upload --unique` llama /upload, recupera documento en Persistence y compara datos.
- [ ] `compass-off` cierra puerto y preserva documentos, probado en PC Windows.
Estado: implementado en rama; pendiente de prueba con Compass real.

**INF-03 [P0] Circuit Breaker de Traefik en HTTP interno y publico**
- [ ] Middleware por provider file aplicado a los cuatro routers externos.
- [ ] EntryPoint privado :8081 y routers internos para validation/persistence/ollama.
- [ ] Extraction/Summary envian dependencias HTTP por Traefik con StripPrefix.
- [ ] Desactivar `api.insecure`; comprobar dashboard y no publicar :8081.
- [ ] E2E y prueba de fallo/recuperacion documentados.
Estado: implementacion propuesta en rama, pendiente de validacion real.

**INF-04 [P1] Actualizar k6 para comprobar pipeline automatico**
- [ ] Usar `POST /upload` en vez de `POST /extract`.
- [ ] Comprobar Kafka -> Summary -> Redis sin disparar `POST /summary` preventivamente.
- [ ] Diferenciar fallos 202 pending/409 failed; evitar falsas validaciones de exito.

**INF-05 [BLOQUEADO: PROFESOR] Precisar necesidad de Consul y ACL tokens**
- [ ] Aclarar si requiere Consul Catalog, KV, ACL, service registration o todos.
- [ ] Determinar URL, alcance de permisos, tokens y UUID solicitados.
- [ ] Si es obligatorio, diseñar incorporación sin secretos en Git y con tests.
Estado: no se debe implementar a ciegas.

**INF-06 [P1] CI y guion de la defensa**
- [ ] Validacion `docker compose config --quiet`, unit tests scripts y E2E.
- [ ] Guion de Swagger, Compass, health, cierre y evidencia de eventos.
- [ ] Documentar limites: no se guarda binario PDF, Redis TTL, Kafka single broker.

### Validation — pdf-extractext-validation

**VAL-01 [P1] N capas: ruta HTTP, caso de uso y dominio**
- [ ] Logica de validacion separada del endpoint HTTP; usar PdfValidator de Shared.
- [ ] Mantener contrato `POST /validate` y status 400/413/415 existentes.
- [ ] Pruebas de archivo vacio, formato invalido, tamano maximo y validacion correcta.

**VAL-02 [P1] Liveness/readiness y configuracion por entorno**
- [ ] Aclarar `/health` como liveness; no declarar que verifica dependencias inexistentes.
- [ ] Tests de configuracion `MAX_PDF_SIZE_BYTES` y manejo de limites.
- [ ] Documentar el microservicio, capas, puertos y su rol en la llamada de Extraction.

### Persistence — pdf-extractext-persistence

**PER-01 [P1] N capas: servicio de aplicacion e interfaz repository**
- [ ] Separar rutas de la coordinacion de CRUD.
- [ ] Mantener pruebas/contratos: 201, 404, 409, update, delete.
- [ ] Mantener el acceso Mongo encapsulado y el indice unico de checksum.

**PER-02 [P0] Evidencia Compass de escritura verdadera**
- [ ] Subir PDF via /upload, recuperar su id en /documents y buscarlo en Compass.
- [ ] Mostrar `pdf_extractext.documents`, campos y `getIndexes()`.
- [ ] Registrar capturas no sensibles; no confundir texto extraido con binario PDF.

**PER-03 [P1] Errores de base de datos y cierre**
- [ ] Health 503 cuando Mongo no responde, no 200 falso.
- [ ] Verificar reconexion/cierre del cliente Motor al detener el contenedor.
- [ ] Pruebas de unicidad SHA-256 frente a concurrencia.

**PER-04 [BLOQUEADO: PROFESOR] ¿Se exige guardar el PDF binario?**
- [ ] Aclarar texto+checksum vs guardar binario/GridFS.
- [ ] Si exigen el original, diseñar esquema y descarga con migracion y límites.

### Extraction — pdf-extractext-extraction

**EXT-01 [P1] Casos de uso separados de la capa HTTP**
- [ ] Mover flujo de `_run_extraction` fuera de `routes.py`.
- [ ] Mantener endpoints `/upload` y `/extract`, checksum, deduplicacion y caché.
- [ ] Tests unitarios de orquestacion y contrato HTTP.

**EXT-02 [P0] Contrato HTTP a Validation/Persistence via Traefik**
- [ ] Mantener URLs configurables y verificar prefijos internos.
- [ ] Probar 502/503 al caer Persistence y 400/413/415 si Validation rechaza PDF.
- [ ] Distinguir breaker Python de Shared del breaker de proxy Traefik.

**EXT-03 [P1] Publicacion Kafka durable / fallo parcial**
- [ ] Verificar evento `documents.extracted` solo tras persistir.
- [ ] Si falla publicacion, devolver `summary_status=unavailable` sin falsear persistencia.
- [ ] Probar reintentos y replay, sin vender como garantia exactly-once.

### Summary — pdf-extractext-summary

**SUM-01 [P1] Separacion de capas y test de contratos**
- [ ] Documentar rutas, SummaryService, consumer Kafka, cache Redis y adaptador LLM.
- [ ] Tests para estados `queued`, `processing`, `done`, `failed`.
- [ ] Confirmar distincion HTTP 202/200/409/404/503.

**SUM-02 [P0] Resumen asíncrono observable desde Swagger**
- [ ] Subir documento nuevo, verificar consumer Kafka y estado `done` en Redis.
- [ ] Probar que no se necesita POST /summary para activar consumer.
- [ ] Repetir flujo tras reiniciar Redis/Kafka, sin duplicados indebidos.

**SUM-03 [P1] Resiliencia de Ollama y errores terminales**
- [ ] Verificar timeout del LLM, reintentos y fallos con estado persistido.
- [ ] Comprobar /health frente a Redis/Kafka/Ollama caidos.
- [ ] Confirmar ruta interna Traefik /ollama.

### Shared — pdf-extractext-shared (biblioteca, no microservicio)

**SH-01 [P1] Contratos compartidos y cobertura**
- [ ] Conservar dominio libre de HTTP (validacion, extractor).
- [ ] Reutilizar resiliencia/logging sin mezclar capas.
- [ ] Testear Circuit Breaker Python como defensa adicional local.

**SH-02 [P2] Higiene de versionado**
- [ ] Auditar dependencias transitivas vs runtime.
- [ ] Versionar cambio de API solo si afecta consumidores.
- [ ] Publicar tag nuevo de Shared y actualizar requisitos de servicios solo
      cuando realmente cambie el paquete.

### Interservicios — discusión con el profesor antes de implementar

**ARCH-01 [BLOQUEADO: PROFESOR] Patrón Saga**
- [ ] Confirmar si se exige coreografía/orquestación, definición de transacción global.
- [ ] Decidir si una falla al resumir debe compensar lo almacenado en Mongo.
- [ ] No afirmar que Kafka + REST por sí solo equivale a Saga.

**ARCH-02 [BLOQUEADO: PROFESOR] Significado de orquestador**
- [ ] Distinguir Docker Compose (infraestructura) de coordinador de Saga.
- [ ] Documentar si el docente pide componente de workflow distinto.

## Contrato para integración a main por autor

En CADA repositorio, el integrante asignado revisa la rama y desde SU equipo,
con Git y nombre/mail correctos, integra los archivos como un unico commit:
```powershell
git checkout main
git pull origin main
git fetch origin
git merge --squash origin/<rama>
git commit -m "feat(servicio): describe los cambios"
git push origin main
```

`merge --squash` crea cambios preparados pero NO crea commit por sí mismo.
Quien ejecuta `git commit` firma la autoría del commit integrado; no borra
la autoría histórica de los commits de la rama. Revisar `git status`, `git
diff --cached`, `git log -1` y CI antes del push. No copiar placeholders
literalmente: cambiar `<rama>` y `servicio` por valores correctos.

## Riesgos y criterios de finalización

- No hacer `docker compose down -v` ni borrar `mongodb/data/`.
- Testear `start → upload → Compass Documents/Schema/Indexes → compass-off → stop`.
- Comprobar Traefik sin provider errors y respuesta de /health de cada servicio.
- Repetir `smoke_test.ps1 -CheckRecovery` sobre los `main` integrados.
- No dar por probado E2E por haber pasado solo tests unitarios.
- No añadir Consul o Saga hasta confirmar su semántica.
