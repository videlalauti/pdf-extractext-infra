# PDF ExtractExt — Infraestructura

## Requisitos

- Tener Docker y Docker Compose instalados.
- Tener clonados los 4 repos de servicios como carpetas hermanas de este repo:

```
../pdf-extractext-validation
../pdf-extractext-extraction
../pdf-extractext-persistence
../pdf-extractext-summary
```

## Comandos

### 1. Crear la red

```bash
docker network create mired
```

### 2. Levantar los servicios

```bash
docker compose up --build -d
```

### 3. Ver el estado

```bash
docker compose ps
```

## Probar cada servicio (health)

- http://validation.pdf.localhost/health
- http://extraction.pdf.localhost/health
- http://persistence.pdf.localhost/health
- http://summary.pdf.localhost/health

## Comandos útiles

```bash
docker compose logs -f <servicio>
docker compose down
```