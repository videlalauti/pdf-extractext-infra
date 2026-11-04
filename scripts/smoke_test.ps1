[CmdletBinding()]
param(
    [string]$ComposeFile = "docker-compose.yml",
    [string]$TestCasePdf = "scripts/test.pdf",
    # Por defecto se entra por Traefik (unico perimetro). Los servicios ya no
    # publican 8001-8004 en el host; si hace falta pegarlos directo, usar el
    # override de desarrollo y pasar estas URLs por parametro.
    [string]$ValidationUrl = "http://validation.pdf.localhost",
    [string]$ExtractionUrl = "http://extraction.pdf.localhost",
    [string]$PersistenceUrl = "http://persistence.pdf.localhost",
    [string]$SummaryUrl = "http://summary.pdf.localhost",
    [string]$ExternalNetwork = "mired",
    [int]$HealthTimeoutSeconds = 180,
    [int]$HealthRetrySeconds = 2,
    [switch]$CheckRecovery
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
    # En Windows, *.pdf.localhost no siempre se resuelve a IPv4.
    # Traefik escucha en 127.0.0.1; conservar Host mantiene el router correcto
    # sin tocar el archivo hosts ni requerir privilegios de administrador.
    $target = [uri]$Uri
    if ($target.Scheme -eq "http" -and
        $target.Host.EndsWith(".pdf.localhost", [System.StringComparison]::OrdinalIgnoreCase)) {
        $params.Uri = "http://127.0.0.1$($target.PathAndQuery)"
        $params.Headers = @{ Host = $target.Host }
        # PowerShell 7 puede respetar HTTP_PROXY aun para dominios .localhost.
        # NoProxy no existe en Windows PowerShell 5.1, por eso es condicional.
        if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("NoProxy")) {
            $params.NoProxy = $true
        }
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
    $lastError = $null
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
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds $HealthRetrySeconds
    }
    Fail "Timeout esperando health de $Name en $BaseUrl/health (limite $HealthTimeoutSeconds s). Ultimo error: $lastError"
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

function Wait-KafkaJob {
    param([string]$DocumentId, [int]$TimeoutSeconds = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $job = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $read = Invoke-DockerCapture -DockerArgs @(
            "exec", "redis", "redis-cli", "--raw", "GET", "summary:$DocumentId"
        )
        if ($read.ExitCode -ne 0) {
            Fail "No se pudo leer el estado en Redis (exit $($read.ExitCode))"
        }
        $rawJob = ($read.Output -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($rawJob)) {
            continue
        }
        try {
            $job = $rawJob | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Fail "Redis devolvió un estado inválido para el resumen"
        }
        if ($job.status -eq "done") {
            return $job
        }
        if ($job.status -eq "failed") {
            Fail "Summary falló al procesar el evento: $($job.reason)"
        }
    }
    Fail "Timeout: no se completó el job por Kafka en Redis ($TimeoutSeconds s)"
}

function Wait-ContainerHealthy {
    param([string]$Name, [int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $health = Invoke-DockerCapture -DockerArgs @(
            "inspect", "--format", "{{.State.Health.Status}}", $Name
        )
        if ($health.ExitCode -eq 0 -and ($health.Output -join "").Trim() -eq "healthy") {
            return
        }
        Start-Sleep -Seconds 2
    }
    Fail "Timeout esperando contenedor $Name healthy ($TimeoutSeconds s)"
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
    # Compose puede dejar contenedores levantados incluso cuando up devuelve 1.
    # Registrar el intento antes de ejecutar permite limpiar también ese caso.
    $stackStarted = $true
    Invoke-Docker -DockerArgs @("compose", "-f", $composePath, "up", "-d")

    Wait-ServiceHealth -Name "validation-service" -BaseUrl $ValidationUrl
    Wait-ServiceHealth -Name "extraction-service" -BaseUrl $ExtractionUrl
    Wait-ServiceHealth -Name "persistence-service" -BaseUrl $PersistenceUrl
    Wait-ServiceHealth -Name "summary-service" -BaseUrl $SummaryUrl

    Ensure-OllamaModel

    # Cada ejecución usa un checksum único para evitar que un documento
    # previamente resumido en Redis haga pasar una prueba sin consumir Kafka.
    # Agregar un comentario después del EOF mantiene intactos los objetos PDF.
    $originalBytes = [System.IO.File]::ReadAllBytes($pdfPath)
    $markerBytes = [System.Text.Encoding]::ASCII.GetBytes(
        "`n% smoke-run:" + [guid]::NewGuid().ToString("N") + "`n"
    )
    $pdfBytes = New-Object byte[] ($originalBytes.Length + $markerBytes.Length)
    [System.Array]::Copy($originalBytes, 0, $pdfBytes, 0, $originalBytes.Length)
    [System.Array]::Copy($markerBytes, 0, $pdfBytes, $originalBytes.Length, $markerBytes.Length)
    $pdfName = Split-Path -Leaf $pdfPath

    Write-Step "Enviando PDF a /validate"
    $upload = New-MultipartBody -FileName $pdfName -FileBytes $pdfBytes
    $validation = Invoke-Api -Method POST -Uri "$ValidationUrl/validate" `
        -BytesBody $upload.Body -ContentType ("multipart/form-data; boundary=" + $upload.Boundary)
    if ($validation.valid -ne $true) {
        Fail "/validate reporto PDF invalido: $($validation.error)"
    }
    Write-Step "OK  /validate -> valid=$($validation.valid)"

    Write-Step "Enviando PDF a /upload (Validation -> Extraction -> Persistence -> Kafka)"
    $upload = New-MultipartBody -FileName $pdfName -FileBytes $pdfBytes
    $extraction = Invoke-Api -Method POST -Uri "$ExtractionUrl/upload" `
        -BytesBody $upload.Body -ContentType ("multipart/form-data; boundary=" + $upload.Boundary) `
        -TimeoutSec 60
    if ([string]::IsNullOrWhiteSpace($extraction.text)) {
        Fail "/upload devolvio texto vacio"
    }
    if ([string]::IsNullOrWhiteSpace($extraction.id)) {
        Fail "/upload no devolvio document id"
    }
    if ($extraction.summary_status -ne "queued") {
        Fail "/upload no pudo publicar el evento Kafka: summary_status=$($extraction.summary_status)"
    }
    Write-Step "OK  /upload -> id=$($extraction.id) summary_status=$($extraction.summary_status)"

    $documentId = $extraction.id

    Write-Step "Verificando documento en /documents/$documentId"
    $document = Invoke-Api -Method GET -Uri "$PersistenceUrl/documents/$documentId" -TimeoutSec 30
    if ($document.content -ne $extraction.text) {
        Fail "El contenido persistido no coincide con el texto extraido"
    }
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $expectedChecksum = [System.BitConverter]::ToString(
            $hasher.ComputeHash($pdfBytes)
        ).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
    }
    if ($document.checksum -ne $expectedChecksum) {
        Fail "El checksum no coincide (esperado $expectedChecksum, obtenido $($document.checksum))"
    }
    Write-Step "OK  /documents/$documentId -> content y checksum verificados"

    Write-Step "Esperando procesamiento Kafka en Redis (sin GET/POST /summary)"
    # GET podría iniciar el procesamiento y ocultar un fallo del consumer.
    $job = Wait-KafkaJob -DocumentId $documentId
    Write-Step "OK  Kafka -> Summary -> Redis: status=$($job.status)"

    # Leer el resultado desde la API únicamente después de demostrar que
    # el evento disparó el procesamiento (sin recuperación por GET).
    $summary = Invoke-Api -Method GET -Uri "$SummaryUrl/summary/$documentId" -TimeoutSec 30
    if ([string]::IsNullOrWhiteSpace($summary.summary)) {
        Fail "/summary devolvio un resumen vacio"
    }
    if ($summary.document_id -ne $documentId) {
        Fail "/summary devolvio document_id distinto al esperado"
    }
    Write-Step "OK  /summary -> document_id=$($summary.document_id) summary_len=$($summary.summary.Length)"

    if ($CheckRecovery) {
        Write-Step "Prueba de recuperación: reiniciando Redis y Kafka"
        Invoke-Docker -DockerArgs @("compose", "-f", $composePath, "restart", "redis", "kafka")
        Wait-ContainerHealthy -Name "redis"
        Wait-ContainerHealthy -Name "kafka"

        # Redis debe recuperar el job terminado desde su volumen AOF.
        $stored = Invoke-DockerCapture -DockerArgs @(
            "exec", "redis", "redis-cli", "--raw", "GET", "summary:$documentId"
        )
        if ($stored.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($stored.Output -join "").Trim())) {
            Fail "Redis perdió el job de resumen tras el reinicio"
        }
        # El estado es ASCII y se puede leer con redis-cli en cualquier
        # sistema. El texto del resumen puede contener acentos: Windows
        # PowerShell decodifica la salida nativa con otra página de códigos,
        # por lo que compararlo aquí daría un falso negativo.
        $restoredJob = ($stored.Output -join "`n") | ConvertFrom-Json
        if ($restoredJob.status -ne "done") {
            Fail "Redis no recuperó el estado terminal del job (estado=$($restoredJob.status))"
        }
        Write-Step "OK  Redis recupero el estado done desde AOF"

        # El volumen de Kafka debe conservar al menos el topic declarado.
        $topics = Invoke-DockerCapture -DockerArgs @(
            "exec", "kafka", "/opt/kafka/bin/kafka-topics.sh",
            "--bootstrap-server", "localhost:9092", "--list"
        )
        if ($topics.ExitCode -ne 0 -or "documents.extracted" -notin $topics.Output) {
            Fail "Kafka no recuperó documents.extracted tras el reinicio"
        }
        Write-Step "OK  Kafka recupero el topic documents.extracted"

        Wait-ServiceHealth -Name "summary-service" -BaseUrl $SummaryUrl

        # Verificar el contenido recuperado mediante HTTP JSON UTF-8, no por
        # stdout de docker exec: evita comparar cadenas con acentos corruptos
        # por la codificación de la consola de Windows.
        $restoredSummary = Invoke-Api -Method GET -Uri "$SummaryUrl/summary/$documentId" -TimeoutSec 30
        if ($restoredSummary.document_id -ne $documentId -or
            $restoredSummary.summary -cne $summary.summary) {
            Fail "El resumen recuperado por la API tras reiniciar Redis no coincide con el original"
        }
        Write-Step "OK  Redis recupero el contenido del resumen sin cambios"

        # Una segunda carga obliga a usar el broker y consumer recuperados.
        $secondMarker = [System.Text.Encoding]::ASCII.GetBytes(
            "`n% smoke-recovery:" + [guid]::NewGuid().ToString("N") + "`n"
        )
        $secondPdf = New-Object byte[] ($originalBytes.Length + $secondMarker.Length)
        [System.Array]::Copy($originalBytes, 0, $secondPdf, 0, $originalBytes.Length)
        [System.Array]::Copy($secondMarker, 0, $secondPdf, $originalBytes.Length, $secondMarker.Length)
        $secondUpload = New-MultipartBody -FileName $pdfName -FileBytes $secondPdf
        $secondExtraction = Invoke-Api -Method POST -Uri "$ExtractionUrl/upload" `
            -BytesBody $secondUpload.Body `
            -ContentType ("multipart/form-data; boundary=" + $secondUpload.Boundary) `
            -TimeoutSec 60
        if ([string]::IsNullOrWhiteSpace($secondExtraction.id) -or
            $secondExtraction.summary_status -ne "queued" -or
            $secondExtraction.id -eq $documentId) {
            Fail "Extraction no pudo publicar otro documento después de reiniciar Kafka"
        }
        $recoveredJob = Wait-KafkaJob -DocumentId $secondExtraction.id
        Write-Step "OK  Kafka y Summary procesaron otro documento tras el reinicio"
    }

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