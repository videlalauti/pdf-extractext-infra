[CmdletBinding()]
param(
    [string]$CertsDir = "traefik/certs",
    [string]$Domains = "*.pdf.localhost,pdf.localhost",
    [int]$Days = 825
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$certsPath = $CertsDir
if (-not [System.IO.Path]::IsPathRooted($certsPath)) {
    $certsPath = Join-Path $repoRoot $CertsDir
}

function Write-Step {
    param([string]$Message)
    Write-Host ("[CERTS] " + $Message)
}

function Fail {
    param([string]$Message)
    Write-Host ("[ERROR] " + $Message) -ForegroundColor Red
    exit 1
}

function Resolve-Openssl {
    $onPath = Get-Command openssl -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $withGit = Join-Path $env:ProgramFiles "Git\usr\bin\openssl.exe"
    if (Test-Path -LiteralPath $withGit) { return $withGit }
    Fail "openssl no encontrado. Instalalo (Git for Windows lo trae) o agregalo al PATH."
}

$openssl = Resolve-Openssl
Write-Step "Usando $openssl"

if (-not (Test-Path -LiteralPath $certsPath)) {
    New-Item -ItemType Directory -Path $certsPath -Force | Out-Null
}

$keyPath = Join-Path $certsPath "key.pem"
$certPath = Join-Path $certsPath "cert.pem"

$domainList = $Domains -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if (-not $domainList -or $domainList.Count -eq 0) {
    Fail "-Domains quedo vacio"
}

# El primer dominio no puede ser un wildcard: CN no lo acepta, solo el SAN.
$commonName = $domainList[0]
$san = ($domainList | ForEach-Object { "DNS:$_" }) -join ","

Write-Step "Generando par TLS autofirmado para $san (valido $Days dias)"
Write-Step "CN/Certificate/key en $certsPath (gitignored: nunca se commitean)"

$configPath = Join-Path $env:TEMP ("extractext-openssl-" + [guid]::NewGuid().ToString("N") + ".cnf")
try {
    @"
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $commonName

[ext]
subjectAltName = $san
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
"@ | Set-Content -LiteralPath $configPath -Encoding utf8

    # openssl escribe el progreso de la clave en stderr; con ErrorActionPreference
    # "Stop" PowerShell lo tomaria por fallo. El exito se judgea por LASTEXITCODE.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $openssl req -x509 -nodes `
            -newkey rsa:2048 `
            -sha256 `
            -days $Days `
            -keyout $keyPath `
            -out $certPath `
            -config $configPath *>&1 | Out-Null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($exitCode -ne 0) {
        Fail "openssl req fallo con exit $exitCode"
    }
}
finally {
    Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $keyPath) -or -not (Test-Path -LiteralPath $certPath)) {
    Fail "No se generaron cert.pem y key.pem"
}

# Si el par no cierra, Traefik levanta pero sin TLS y el fallo aparece en el log.
$previous = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $certModulus = (& $openssl x509 -in $certPath -noout -modulus) | Out-String
    $keyModulus = (& $openssl rsa -in $keyPath -noout -modulus *>&1) | Out-String
    $subject = (& $openssl x509 -in $certPath -noout -subject -dates -ext subjectAltName) | Out-String
}
finally {
    $ErrorActionPreference = $previous
}

if ($certModulus.Trim() -ne $keyModulus.Trim()) {
    Fail "cert.pem y key.pem no coinciden"
}

Write-Step "OK  par coherente"
Write-Step $subject.TrimEnd()
Write-Step "Archivos generados. No hace falta instalarlos: son autofirmados de desarrollo."
exit 0
