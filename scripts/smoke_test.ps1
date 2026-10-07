[CmdletBinding()]
param(
    [string]$ComposeFile = "docker-compose.yml",
    [string]$TestCasePdf = "scripts/test.pdf",
    [string]$ValidationUrl = "http://localhost:8001",
    [string]$ExtractionUrl = "http://localhost:8002",
    [string]$PersistenceUrl = "http://localhost:8003",
    [string]$SummaryUrl = "http://localhost:8004",
    [string]$ExternalNetwork = "mired",
    [int]$HealthTimeoutSeconds = 180,
    [int]$HealthRetrySeconds = 2
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$composePath = $ComposeFile
if (-not [System.IO.Path]::IsPathRooted($composePath)) {
    $composePath = Join-Path $repoRoot $ComposeFile
}
$pdfPath = $TestCasePdf
if (-not [System.IO.Path]::IsPathRooted($pdfPath)) {
    $pdfPath = Join-Path $repoRoot $TestCasePdf
}

function Write-Step {
    param([string]$Message)
    Write-Host ("[SMOKE] " + $Message)
}

function Fail {
    param([string]$Message)
    # throw y no exit: asi el try/finally de abajo siempre corre la limpieza
    # (bajar el stack) en vez de dejar el runner con contenedores prendidos.
    throw $Message
}

function Invoke-ApiResponse {
    param(
        [string]$Method,
        [string]$Uri,
        [byte[]]$BytesBody = $null,
        [string]$ContentType = $null,
        [int]$TimeoutSec = 60
    )
    $params = @{
        Method = $Method
        Uri = $Uri
        UseBasicParsing = $true
        TimeoutSec = $TimeoutSec
    }
    if ($BytesBody -ne $null) {
        $params.Body = $BytesBody
        $params.ContentType = $ContentType
    }
    try {
        $response = Invoke-WebRequest @params
    }
    catch {
        # 4xx/5xx se devuelven como status para que el llamador decida (el poll
        # de /summary tolera "todavia en curso"). El resto (timeout, DNS,
        # connection refused) se re-lanza con el endpoint en el mensaje: sin
        # eso el catch global muestra el error crudo de WinHTTP.
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode -ge 400) {
            return @{ StatusCode = $statusCode; Body = $null }
        }
        throw "$Method $Uri fallo: $($_.Exception.Message)"
    }
    $body = $null
    if ($response.Content) {
        $body = $response.Content | ConvertFrom-Json
    }
    return @{ StatusCode = [int]$response.StatusCode; Body = $body }
}

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Uri,
        [byte[]]$BytesBody = $null,
        [string]$ContentType = $null,
        [int]$TimeoutSec = 60
    )
    $result = Invoke-ApiResponse -Method $Method -Uri $Uri -BytesBody $BytesBody `
        -ContentType $ContentType -TimeoutSec $TimeoutSec
    if ($result.StatusCode -ge 400) {
        throw "$Method $Uri respondio $($result.StatusCode)"
    }
    return $result.Body
}

function New-MultipartBody {
    param([string]$FileName, [byte[]]$FileBytes)
    $boundary = "----SmokeTest" + [guid]::NewGuid().ToString("N")
    $newline = "`r`n"
    $head = "--$boundary$newline" +
            "Content-Disposition: form-data; name=`"file`"; filename=`"$FileName`"$newline" +
            "Content-Type: application/pdf$newline$newline"
    $tail = $newline + "--$boundary--$newline"
    $headBytes = [System.Text.Encoding]::UTF8.GetBytes($head)
    $tailBytes = [System.Text.Encoding]::UTF8.GetBytes($tail)
    $total = $headBytes.Length + $FileBytes.Length + $tailBytes.Length
    $body = New-Object byte[] $total
    [System.Array]::Copy($headBytes, 0, $body, 0, $headBytes.Length)
    [System.Array]::Copy($FileBytes, 0, $body, $headBytes.Length, $FileBytes.Length)
    [System.Array]::Copy($tailBytes, 0, $body, $headBytes.Length + $FileBytes.Length, $tailBytes.Length)
    return @{ Boundary = $boundary; Body = $body }
}

function Invoke-Docker {
    param([string[]]$DockerArgs)
    # docker escribe el progreso de compose en stderr. Con ErrorActionPreference
    # "Stop" PowerShell lo convierte en NativeCommandError y aborta el script
    # aunque el comando haya salido con 0. El exito se judgea por LASTEXITCODE.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker @DockerArgs 2>&1 | ForEach-Object { Write-Host $_ }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        Fail "Fallo: docker $($DockerArgs -join ' ') (exit $exitCode)"
    }
}

function Wait-ServiceHealth {
    param([string]$Name, [string]$BaseUrl)
    Write-Step "Esperando health de $Name en $BaseUrl/health ..."
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $health = Invoke-Api -Method GET -Uri "$BaseUrl/health" -TimeoutSec 5
            if ($health -and $health.status -eq "healthy") {
                Write-Step "OK  $Name /health -> status=$($health.status) service=$($health.service)"
                return
            }
        }
        catch {
        }
        Start-Sleep -Seconds $HealthRetrySeconds
    }
    Fail "Timeout esperando health de $Name en $BaseUrl/health (limite $HealthTimeoutSeconds s)"
}

function Invoke-DockerCapture {
    param([string[]]$DockerArgs)
    # Igual que Invoke-Docker: docker escribe en stderr y con ErrorActionPreference
    # "Stop" eso abortaria el script. Aqui ademas capturamos la salida para inspeccionarla.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & docker @DockerArgs 2>&1 | ForEach-Object { "$_" }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return @{ Output = $output; ExitCode = $exitCode }
}

function Ensure-OllamaModel {
    param([string]$Model = $(if ($env:OLLAMA_MODEL) { $env:OLLAMA_MODEL } else { "llama3.2" }))
    # En CI el volumen de ollama nace vacio y el primer POST /summary falla con 503
    # (ollama responde 404 model not found). En local ya suele estar descargado.
    # Este paso descarga el modelo con el que trabaja el summary-service para que
    # el E2E sea determinista en frio y caliente.
    Write-Step "Verificando modelo de Ollama '$Model'"
    $check = Invoke-DockerCapture -DockerArgs @("exec", "ollama", "ollama", "list")
    $isPresent = $check.ExitCode -eq 0 -and (($check.Output -join "`n") -match [regex]::Escape($Model))
    if (-not $isPresent) {
        Write-Step "Modelo '$Model' no disponible; descargandolo (solo la primera corrida en frio)"
        $pull = Invoke-DockerCapture -DockerArgs @("exec", "ollama", "ollama", "pull", $Model)
        $pull.Output | ForEach-Object { Write-Host $_ }
        if ($pull.ExitCode -ne 0) {
            Fail "No se pudo descargar el modelo '$Model' (exit $($pull.ExitCode))"
        }
        $check = Invoke-DockerCapture -DockerArgs @("exec", "ollama", "ollama", "list")
        if ($check.ExitCode -ne 0 -or (($check.Output -join "`n") -notmatch [regex]::Escape($Model))) {
            Fail "El modelo '$Model' no aparece en 'ollama list' tras la descarga"
        }
    }
    Write-Step "OK  modelo de Ollama '$Model' disponible"
}

if (-not (Test-Path -LiteralPath $composePath)) {
    Fail "No se encontro el archivo compose: $composePath"
}
if (-not (Test-Path -LiteralPath $pdfPath)) {
    Fail "No se encontro el PDF de prueba: $pdfPath"
}

# Si el smoke falla a mitad de camino no puede quedar el stack prendido: en CI
# el runner se descarta, pero en local te deja puertos ocupados y volumenes
# corryptos. Todo el cuerpo va en try y la limpieza en finally.
$exitCode = 0
$networkCreated = $false
$stackStarted = $false

try {
    Write-Step "Verificando red externa '$ExternalNetwork'"
    & docker network inspect $ExternalNetwork *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Step "Red '$ExternalNetwork' no existe; creandola"
        Invoke-Docker -DockerArgs @("network", "create", $ExternalNetwork)
        $networkCreated = $true
    }

    Write-Step "Levantando el stack con $composePath"
    Invoke-Docker -DockerArgs @("compose", "-f", $composePath, "up", "-d")
    $stackStarted = $true

    Wait-ServiceHealth -Name "validation-service" -BaseUrl $ValidationUrl
    Wait-ServiceHealth -Name "extraction-service" -BaseUrl $ExtractionUrl
    Wait-ServiceHealth -Name "persistence-service" -BaseUrl $PersistenceUrl
    Wait-ServiceHealth -Name "summary-service" -BaseUrl $SummaryUrl

    Ensure-OllamaModel

    $pdfBytes = [System.IO.File]::ReadAllBytes($pdfPath)
    $pdfName = Split-Path -Leaf $pdfPath

    Write-Step "Enviando PDF a /validate"
    $upload = New-MultipartBody -FileName $pdfName -FileBytes $pdfBytes
    $validation = Invoke-Api -Method POST -Uri "$ValidationUrl/validate" `
        -BytesBody $upload.Body -ContentType ("multipart/form-data; boundary=" + $upload.Boundary)
    if ($validation.valid -ne $true) {
        Fail "/validate reporto PDF invalido: $($validation.error)"
    }
    Write-Step "OK  /validate -> valid=$($validation.valid)"

    Write-Step "Enviando PDF a /extract"
    $upload = New-MultipartBody -FileName $pdfName -FileBytes $pdfBytes
    $extraction = Invoke-Api -Method POST -Uri "$ExtractionUrl/extract" `
        -BytesBody $upload.Body -ContentType ("multipart/form-data; boundary=" + $upload.Boundary) `
        -TimeoutSec 60
    if ([string]::IsNullOrWhiteSpace($extraction.text)) {
        Fail "/extract devolvio texto vacio"
    }
    if ([string]::IsNullOrWhiteSpace($extraction.id)) {
        Fail "/extract no devolvio document id"
    }
    Write-Step "OK  /extract -> id=$($extraction.id) text_len=$($extraction.text.Length)"

    $documentId = $extraction.id

    Write-Step "Verificando documento en /documents/$documentId"
    $document = Invoke-Api -Method GET -Uri "$PersistenceUrl/documents/$documentId" -TimeoutSec 30
    if ($document.content -ne $extraction.text) {
        Fail "El contenido persistido no coincide con el texto extraido"
    }
    $expectedChecksum = (Get-FileHash -LiteralPath $pdfPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($document.checksum -ne $expectedChecksum) {
        Fail "El checksum no coincide (esperado $expectedChecksum, obtenido $($document.checksum))"
    }
    Write-Step "OK  /documents/$documentId -> content y checksum verificados"

    Write-Step "Pidiendo resumen en /summary/$documentId"
    $summaryCall = Invoke-ApiResponse -Method POST -Uri "$SummaryUrl/summary/$documentId" -TimeoutSec 300
    $summary = $null
    if ($summaryCall.StatusCode -eq 200) {
        # Contrato sincronico: el resultado viene en la misma respuesta.
        $summary = $summaryCall.Body
    }
    elseif ($summaryCall.StatusCode -eq 202) {
        # Contrato async: el POST solo encola y el resultado se consulta con GET
        # hasta que responde 200 (la inferencia real por CPU puede tardar ~4 min).
        Write-Step "Resumen encolado (202); esperando el resultado por GET (max 300 s)"
        $deadline = (Get-Date).AddSeconds(300)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $poll = Invoke-ApiResponse -Method GET -Uri "$SummaryUrl/summary/$documentId" -TimeoutSec 30
            if ($poll.StatusCode -eq 200) {
                $summary = $poll.Body
                break
            }
            if ($poll.StatusCode -ne 202 -and $poll.StatusCode -ne 409) {
                Fail "/summary (GET) respondio $($poll.StatusCode)"
            }
        }
        if ($null -eq $summary) {
            Fail "Timeout esperando el resultado del resumen (300 s)"
        }
    }
    else {
        Fail "/summary (POST) respondio $($summaryCall.StatusCode)"
    }
    if ([string]::IsNullOrWhiteSpace($summary.summary)) {
        Fail "/summary devolvio un resumen vacio"
    }
    if ($summary.document_id -ne $documentId) {
        Fail "/summary devolvio document_id distinto al esperado"
    }
    Write-Step "OK  /summary -> document_id=$($summary.document_id) summary_len=$($summary.summary.Length)"

    Write-Step "SMOKE TEST COMPLETO"
}
catch {
    Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red
    Write-Step "Dejando logs de los contenedores para diagnosticar:"
    try {
        Invoke-Docker -DockerArgs @("compose", "-f", $composePath, "logs", "--tail", "15")
    }
    catch {
    }
    $exitCode = 1
}
finally {
    if ($stackStarted) {
        Write-Step "Bajando el stack"
        try {
            Invoke-Docker -DockerArgs @("compose", "-f", $composePath, "down", "--remove-orphans")
        }
        catch {
            Write-Host ("[WARN] fallo el down: " + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    # Solo se borra la red si la creo este script. Si ya existia, la puede estar
    # usando otro stack y arrancarle la red de abajo seria un efecto colateral.
    if ($networkCreated) {
        Write-Step "Eliminando la red externa '$ExternalNetwork'"
        try {
            Invoke-Docker -DockerArgs @("network", "rm", $ExternalNetwork)
        }
        catch {
            Write-Host ("[WARN] no se pudo eliminar la red: " + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

exit $exitCode