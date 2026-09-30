[CmdletBinding()]
param(
    [string]$K6 = "C:\Program Files\k6\k6.exe",
    [string]$ScriptPath = "script.js",
    [switch]$Dashboard,
    [string]$Period = "1s"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$fullScript = $ScriptPath
if (-not [System.IO.Path]::IsPathRooted($fullScript)) {
    $fullScript = Join-Path $scriptDir $ScriptPath
}
if (-not (Test-Path -LiteralPath $K6)) {
    throw "No se encontro k6 en $K6. Ajusta -K6 o instalalo desde https://k6.io"
}
if (-not (Test-Path -LiteralPath $fullScript)) {
    throw "No se encontro el script de k6: $fullScript"
}

Write-Host "Corriendo el load test E2E con k6..."
Write-Host "Requiere el stack levantado: docker compose -f docker-compose.yml up -d"
if ($Dashboard) {
    Write-Host "Dashboard web habilitado: abre http://127.0.0.1:5665 (deja la pestana abierta durante el run; cerrarla para que k6 termine)"
    Write-Host "Periodo de agregacion del dashboard: $Period (por defecto k6 exige >30s de datos con 10s)"
}
Push-Location $scriptDir
try {
    # k6 escribe el resumen y console.log en stderr; con ErrorActionPreference
    # "Stop" eso se convierte en NativeCommandError y mata el proceso. Igual
    # que en el smoke, se corre con Stop temporal para juzgar por LASTEXITCODE.
    $previous = $ErrorActionPreference
    $previousDashboard = $env:K6_WEB_DASHBOARD
    $previousDashboardOpen = $env:K6_WEB_DASHBOARD_OPEN
    $previousDashboardPeriod = $env:K6_WEB_DASHBOARD_PERIOD
    $ErrorActionPreference = "Continue"
    try {
        if ($Dashboard) {
            $env:K6_WEB_DASHBOARD = "true"
            $env:K6_WEB_DASHBOARD_OPEN = "true"
            $env:K6_WEB_DASHBOARD_PERIOD = $Period
        }
        & $K6 run $fullScript 2>&1 | Tee-Object -FilePath "report.txt" | Out-Host
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:K6_WEB_DASHBOARD = $previousDashboard
        $env:K6_WEB_DASHBOARD_OPEN = $previousDashboardOpen
        $env:K6_WEB_DASHBOARD_PERIOD = $previousDashboardPeriod
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        Write-Host "[LOAD TEST] k6 salio con exit code $exitCode (algun threshold fallo)"
    }
}
finally {
    Pop-Location
}

$resultsPath = Join-Path $scriptDir "results.json"
if (Test-Path -LiteralPath $resultsPath) {
    $gzipPath = $resultsPath + ".gz"
    $inputStream = [System.IO.File]::OpenRead($resultsPath)
    $outputStream = [System.IO.File]::Create($gzipPath)
    $gzip = New-Object System.IO.Compression.GZipStream($outputStream, [System.IO.Compression.CompressionMode]::Compress)
    try {
        $inputStream.CopyTo($gzip)
    }
    finally {
        $gzip.Dispose()
        $outputStream.Dispose()
        $inputStream.Dispose()
    }
    Move-Item -Force $resultsPath (Join-Path $scriptDir "results.json.raw") -ErrorAction SilentlyContinue
    Write-Host "[LOAD TEST] Resultados en $gzipPath y reporte resumido en reporte.txt"
}
else {
    Write-Host "[LOAD TEST] No se encontro results.json (k6 no lo genero)"
}

exit $exitCode