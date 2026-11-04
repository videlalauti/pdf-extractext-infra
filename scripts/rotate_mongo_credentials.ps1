# Rota la password de MongoDB del `.env` local de infra.
#
# Para que sirve: el `.env` esta gitignoreado, pero si la password se filtro por
# otro canal (screenshot, chat, un backup) hay que asumirla comprometida. Este
# script genera una nueva y la deja en el `.env`, y recuerda el paso que casi
# siempre se olvida: Mongo aplica `MONGO_INITDB_ROOT_*` UNA sola vez, cuando el
# directorio de datos esta vacio. Rotar el `.env` sin reinicializar el volumen
# deja al stack sin poder autenticarse.
#
# Uso:
#   ./scripts/rotate_mongo_credentials.ps1
#   ./scripts/rotate_mongo_credentials.ps1 -ResetData   # ademas borra mongodb/data
#
# -ResetData BORRA los datos locales de Mongo (documentos persistidos). Antes de
# borrar exige que el stack este abajo; no toca ningun otro servicio.
#
# El script nunca imprime la password vieja ni la nueva en claro, y falla si
# detecta que `.env` esta trackeado por git.

[CmdletBinding()]
param(
    # Raiz del repo de infra: por defecto, el padre de scripts/.
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    # Longitud de la password generada.
    [int]$Length = 32,
    # Borra mongodb/data despues de rotar (requiere el stack detenido).
    [switch]$ResetData
)

$ErrorActionPreference = "Stop"

$envFile = Join-Path $RepoRoot ".env"
$dataDir = Join-Path $RepoRoot "mongodb\data"

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "No existe $envFile. Crealo primero: Copy-Item mongodb/.env-example .env"
}

# Si .env estuviera trackeado (por ejemplo, se agrego con `git add -f`), rotar
# no sirve de nada: la password nueva tambien quedaria en el historial.
$tracked = (& git -C $RepoRoot ls-files -- .env) -join ""
if ($tracked) {
    throw ".env esta trackeado por git. Sacalo del indice antes de rotar: git rm --cached .env"
}

# Alfabeto sin caracteres que haya que URL-encodear ni escapar en PowerShell:
# la password viaja en una URL de Mongo y en `--eval` de mongosh.
$alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
$bytes = [byte[]]::new($Length)
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$newPassword = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })

# Se preserva todo el resto del archivo: comentarios, orden y otras variables.
$lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $envFile)
$found = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*MONGODB_ROOT_PASSWORD\s*=') {
        $lines[$i] = "MONGODB_ROOT_PASSWORD=$newPassword"
        $found = $true
    }
}
if (-not $found) {
    $lines.Add("MONGODB_ROOT_PASSWORD=$newPassword")
}

# Escritura atomica: si el proceso se corta a mitad, no queda un .env truncado.
# Se usa .NET directo porque -Encoding utf8NoBOM solo existe en PowerShell 7+.
$tmp = "$envFile.tmp"
[System.IO.File]::WriteAllLines($tmp, $lines, [System.Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tmp -Destination $envFile -Force

Write-Host "Password de MongoDB rotada en $envFile"

if (-not (Test-Path -LiteralPath $dataDir)) {
    Write-Host "mongodb\data no existe: el proximo 'docker compose up' inicializa Mongo con la password nueva."
    exit 0
}

if (-not $ResetData) {
    Write-Warning @"
mongodb\data ya esta inicializado: Mongo conserva la password VIEJA hasta que el
directorio de datos este vacio. Para aplicar la nueva (esto BORRA los datos
locales de Mongo):

  docker compose down
  ./scripts/rotate_mongo_credentials.ps1 -ResetData   # o borrar mongodb\data a mano
  docker compose up -d --build

Verificar despues:
  docker compose exec mongo mongosh --quiet --eval 'db.adminCommand({ ping: 1 })'
"@
    exit 0
}

# Borrar el directorio con el stack arriba deja a Mongo escribiendo sobre
# archivos que ya no existen: se exige bajarlo antes.
$running = & docker compose --project-directory $RepoRoot ps --quiet mongo 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "No se pudo consultar el estado de docker compose. Esta Docker Desktop corriendo?"
}
if ($running) {
    throw "mongo sigue corriendo. Bajalo antes de borrar los datos: docker compose down"
}

Remove-Item -LiteralPath $dataDir -Recurse -Force
Write-Host "mongodb\data eliminado. El proximo 'docker compose up -d --build' inicializa Mongo con la password nueva."
