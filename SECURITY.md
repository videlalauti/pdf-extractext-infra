# Seguridad del entorno de desarrollo

Este stack está preparado para demostraciones locales. Traefik publica 80/443
solo en `127.0.0.1` y los puertos del override de depuración también están
ligados al loopback. No debe exponerse a Internet sin autenticación,
autorización y certificados TLS válidos. Persistence expone operaciones CRUD:
el acceso por Traefik **no** representa una autorización.

## Escaneo de imágenes

El workflow `grype` bloquea vulnerabilidades `high` o `critical` en las
imágenes de Extraction, Validation, Persistence y Summary.

Al 4 de noviembre de 2026, el análisis de las cuatro imágenes muestra
hallazgos altos en bibliotecas de la imagen base Debian 13:

- `CVE-2026-85091` — `zlib1g`.
- `CVE-2026-118370` y `CVE-2026-117610` — `libexpat1`.

La vulnerabilidad de zlib continúa marcada como vulnerable para Debian
Trixie en el tracker oficial, aunque existe corrección en Debian unstable:
https://security-tracker.debian.org/tracker/CVE-2026-85091

No eliminar el control `--fail-on high` ni ignorar alertas globalmente para
hacer pasar el workflow. Las acciones recomendadas son actualizar a una
imagen base con paquetes corregidos y digest verificado cuando esté disponible,
reconstruir las cuatro imágenes, revisar los reportes JSON de Grype y volver
a ejecutar las pruebas. Evaluar por separado el impacto real de cada CVE en
la aplicación.

## Estado persistido

MongoDB guarda documentos; Kafka usa un volumen para el log y offsets; Redis
usa AOF y un volumen para los jobs y resultados temporales. Los volúmenes no
reemplazan backups ni alta disponibilidad. `docker compose down -v` elimina
volúmenes Docker y **puede borrar datos**.

El procesamiento de resúmenes sigue limitado a un único nodo de Kafka y una
única instancia de Summary. Antes de un despliegue de producción deben
revisarse el almacenamiento durable de jobs, idempotencia entre procesos,
autenticación y recuperación ante pérdida completa de un volumen.
