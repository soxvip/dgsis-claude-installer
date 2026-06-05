param(
  [string]$ConfigPath = "",
  [string]$ConfigJson = "",
  [switch]$SkipDependencyInstall,
  [switch]$NoAutoStart
)

$ErrorActionPreference = "Stop"

$RepositoryZipUrl = "https://github.com/soxvip/dgsis-claude-installer/archive/refs/heads/main.zip"
$InstallRoot = Join-Path $env:LOCALAPPDATA "DGSIS"
$InstallDir = Join-Path $InstallRoot "claude-adapter"
$Port = 8791
$TaskName = "DGSIS Claude Adapter"

function Write-Step($Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-Command($Name) {
  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Refresh-Path {
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machinePath;$userPath"
}

function Convert-ClientConfig($Text) {
  if (-not $Text -or -not $Text.Trim()) {
    throw "Configuracao vazia. Informe JSON com api e token."
  }

  try {
    $json = $Text | ConvertFrom-Json
    $api = Get-FirstPropertyValue $json @("api", "base_url", "baseUrl", "url")
    $token = Get-FirstPropertyValue $json @("token", "api_key", "apiKey", "key")
    if ($api -and $token) {
      return [pscustomobject]@{ Api = $api.Trim().TrimEnd("/"); Token = $token.Trim() }
    }
  } catch {
    # Se nao for JSON, tenta formato "API: ..." e "Token: ...".
  }

  $apiMatch = [regex]::Match($Text, "(?im)^\s*API\s*:\s*(\S+)\s*$")
  $tokenMatch = [regex]::Match($Text, "(?im)^\s*Token\s*:\s*(\S+)\s*$")
  if ($apiMatch.Success -and $tokenMatch.Success) {
    return [pscustomobject]@{
      Api = $apiMatch.Groups[1].Value.Trim().TrimEnd("/")
      Token = $tokenMatch.Groups[1].Value.Trim()
    }
  }

  throw "Configuracao invalida. Use JSON: { `"api`": `"https://.../v1`", `"token`": `"sk-...`" }"
}

function Get-FirstPropertyValue($Object, [string[]]$Names) {
  foreach ($name in $Names) {
    if ($Object.PSObject.Properties.Name -contains $name) {
      $value = [string]$Object.$name
      if ($value -and $value.Trim()) {
        return $value
      }
    }
  }
  return ""
}

function Get-ClientConfig {
  if ($ConfigPath) {
    return Convert-ClientConfig (Get-Content -LiteralPath $ConfigPath -Raw)
  }

  if ($ConfigJson) {
    return Convert-ClientConfig $ConfigJson
  }

  try {
    $clipboard = Get-Clipboard -Raw -ErrorAction SilentlyContinue
    if ($clipboard -and ($clipboard -match '"api"|API\s*:') -and ($clipboard -match '"token"|Token\s*:')) {
      Write-Host "Configuracao encontrada na area de transferencia." -ForegroundColor Green
      return Convert-ClientConfig $clipboard
    }
  } catch {
    # Get-Clipboard pode nao existir em ambientes antigos.
  }

  Write-Host "Cole o JSON com api e token em uma unica linha." -ForegroundColor Yellow
  Write-Host 'Exemplo: {"api":"https://gtw.dgsis.com.br/v1","token":"sk-..."}'
  $typed = Read-Host "JSON"
  return Convert-ClientConfig $typed
}

function Assert-ClientConfig($ClientConfig) {
  if (-not $ClientConfig.Api.StartsWith("http://") -and -not $ClientConfig.Api.StartsWith("https://")) {
    throw "API invalida. Use uma URL completa, por exemplo https://gtw.dgsis.com.br/v1"
  }
  if ($ClientConfig.Token.Length -lt 10) {
    throw "Token invalido ou muito curto."
  }
}

function Install-Dependencies {
  if ($SkipDependencyInstall) {
    return
  }

  Write-Step "Verificando Node.js"
  if (-not (Test-Command "node")) {
    if (-not (Test-Command "winget")) {
      throw "Node.js nao encontrado e winget nao esta disponivel. Instale Node.js LTS manualmente e rode novamente."
    }
    Write-Host "Instalando Node.js LTS..."
    & winget install --id OpenJS.NodeJS.LTS -e --silent --accept-package-agreements --accept-source-agreements
    Refresh-Path
  }

  if (-not (Test-Command "node")) {
    throw "Node.js ainda nao foi encontrado no PATH. Feche e abra o PowerShell, depois rode novamente."
  }

  Write-Step "Instalando ou atualizando Claude Code"
  if (-not (Test-Command "npm")) {
    Refresh-Path
  }
  if (-not (Test-Command "npm")) {
    throw "npm nao encontrado. Reinstale Node.js LTS."
  }
  & npm install -g "@anthropic-ai/claude-code"
  Refresh-Path
}

function Get-PackageRoot {
  if ($PSScriptRoot -and $PSScriptRoot.Trim()) {
    $localAdapter = Join-Path $PSScriptRoot "adapter"
    if (Test-Path -LiteralPath (Join-Path $localAdapter "package.json")) {
      return $PSScriptRoot
    }
  }

  Write-Step "Baixando pacote do GitHub"
  if ($RepositoryZipUrl -match "SEU_USUARIO") {
    throw "Configure RepositoryZipUrl em install.ps1 com o usuario real do GitHub antes de usar o comando remoto."
  }

  $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("dgsis-claude-installer-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
  $zipPath = Join-Path $tempDir "repo.zip"
  Invoke-WebRequest -Uri $RepositoryZipUrl -OutFile $zipPath
  Expand-Archive -LiteralPath $zipPath -DestinationPath $tempDir -Force
  $root = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
  if (-not $root -or -not (Test-Path (Join-Path $root.FullName "adapter\package.json"))) {
    throw "Pacote baixado nao contem adapter/package.json."
  }
  return $root.FullName
}

function New-AdapterApiKey {
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
  } finally {
    $rng.Dispose()
  }
  $raw = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
  return "abca_$raw"
}

function Install-AdapterFiles($PackageRoot) {
  Write-Step "Instalando adaptador local"
  $sourceAdapter = Join-Path $PackageRoot "adapter"
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "data") | Out-Null

  foreach ($file in @("package.json", "README.md", ".gitignore", ".env.example")) {
    $source = Join-Path $sourceAdapter $file
    if (Test-Path $source) {
      Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDir $file) -Force
    }
  }

  $destSrc = Join-Path $InstallDir "src"
  if (Test-Path $destSrc) {
    Remove-Item -LiteralPath $destSrc -Recurse -Force
  }
  Copy-Item -LiteralPath (Join-Path $sourceAdapter "src") -Destination $destSrc -Recurse -Force
}

function Write-AdapterEnv($ClientConfig) {
  $envPath = Join-Path $InstallDir ".env"
  $content = @"
HOST=127.0.0.1
PORT=$Port
UPSTREAM_BASE_URL=$($ClientConfig.Api)
UPSTREAM_API_KEY=$($ClientConfig.Token)
DEFAULT_MODEL=ag/claude-opus-4-6-thinking
OPUS_MODEL=ag/claude-opus-4-6-thinking
SONNET_MODEL=ag/claude-sonnet-4-6
HAIKU_MODEL=ag/claude-sonnet-4-6
REQUEST_TIMEOUT_SECONDS=300
"@
  Set-Content -LiteralPath $envPath -Value $content -Encoding UTF8
}

function Ensure-AdapterKey {
  $keyPath = Join-Path $InstallDir "data\adapter-api-key.txt"
  if (Test-Path $keyPath) {
    $existing = (Get-Content -LiteralPath $keyPath -Raw).Trim()
    if ($existing) {
      return $existing
    }
  }
  $key = New-AdapterApiKey
  Set-Content -LiteralPath $keyPath -Value $key -Encoding UTF8
  return $key
}

function Configure-ClaudeCode($AdapterKey) {
  Write-Step "Configurando Claude Code"
  $claudeDir = Join-Path $env:USERPROFILE ".claude"
  New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
  $settingsPath = Join-Path $claudeDir "settings.json"
  $backupDir = Join-Path $claudeDir "backups"
  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

  $settings = [pscustomobject]@{}
  if (Test-Path $settingsPath) {
    try {
      $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
      $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
      Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $backupDir "settings.before-dgsis-$stamp.json") -Force
    } catch {
      $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
      Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $backupDir "settings.invalid-before-dgsis-$stamp.json") -Force
      $settings = [pscustomobject]@{}
    }
  }

  if (-not ($settings.PSObject.Properties.Name -contains "env") -or -not $settings.env) {
    $settings | Add-Member -MemberType NoteProperty -Name env -Value ([pscustomobject]@{}) -Force
  }
  $settings.env | Add-Member -MemberType NoteProperty -Name ANTHROPIC_API_KEY -Value $AdapterKey -Force
  $settings.env | Add-Member -MemberType NoteProperty -Name ANTHROPIC_BASE_URL -Value "http://127.0.0.1:$Port" -Force
  if ($settings.env.PSObject.Properties.Name -contains "ANTHROPIC_AUTH_TOKEN") {
    $settings.env.PSObject.Properties.Remove("ANTHROPIC_AUTH_TOKEN")
  }

  $settings | Add-Member -MemberType NoteProperty -Name model -Value "ag/claude-opus-4-6-thinking" -Force
  $settings | Add-Member -MemberType NoteProperty -Name syntaxHighlightingDisabled -Value $true -Force
  $settings | Add-Member -MemberType NoteProperty -Name autoUpdatesChannel -Value "latest" -Force
  $settings | Add-Member -MemberType NoteProperty -Name skipDangerousModePermissionPrompt -Value $false -Force
  $settings | Add-Member -MemberType NoteProperty -Name theme -Value "dark" -Force
  $settings | Add-Member -MemberType NoteProperty -Name effortLevel -Value "xhigh" -Force

  $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

function Write-StartScript {
  $startPath = Join-Path $InstallDir "start-adapter.ps1"
  $escapedInstallDir = $InstallDir.Replace("'", "''")
  $content = @"
`$ErrorActionPreference = "Stop"
Set-Location -LiteralPath '$escapedInstallDir'
& node src/server.js
"@
  Set-Content -LiteralPath $startPath -Value $content -Encoding UTF8
  return $startPath
}

function Stop-AdapterOnPort {
  try {
    $listeners = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Listen" }
    foreach ($listener in $listeners) {
      Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
  } catch {
    # Se Get-NetTCPConnection falhar, a proxima inicializacao ainda pode funcionar.
  }
}

function Configure-Autostart($StartScript) {
  if ($NoAutoStart) {
    return
  }

  Write-Step "Configurando inicio automatico"
  $argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartScript`""
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Description "Inicia o adaptador local DGSIS Claude Code" -Force | Out-Null
}

function Start-AdapterNow($StartScript) {
  Write-Step "Iniciando adaptador"
  Stop-AdapterOnPort
  Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $StartScript) -WindowStyle Hidden | Out-Null
}

function Wait-Health {
  $healthUrl = "http://127.0.0.1:$Port/health"
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3
      if ($health.ok -eq $true) {
        return $health
      }
    } catch {
      Start-Sleep -Seconds 1
    }
  }
  throw "Adaptador nao respondeu em $healthUrl."
}

function Test-ClaudeCode {
  if (-not (Test-Command "claude")) {
    Refresh-Path
  }
  if (-not (Test-Command "claude")) {
    throw "Claude Code nao encontrado no PATH apos instalacao."
  }
  $output = & claude -p "Responda exatamente: OK" 2>&1
  $text = ($output -join "`n").Trim()
  if ($LASTEXITCODE -ne 0 -or $text -ne "OK") {
    throw "Teste do Claude Code falhou: $text"
  }
}

try {
  Write-Host "DGSIS Claude Code Installer" -ForegroundColor Green
  $clientConfig = Get-ClientConfig
  Assert-ClientConfig $clientConfig

  Install-Dependencies
  $packageRoot = Get-PackageRoot
  Install-AdapterFiles $packageRoot
  Write-AdapterEnv $clientConfig
  $adapterKey = Ensure-AdapterKey
  Configure-ClaudeCode $adapterKey
  $startScript = Write-StartScript
  Configure-Autostart $startScript
  Start-AdapterNow $startScript
  $health = Wait-Health
  Test-ClaudeCode

  Write-Host ""
  Write-Host "Instalacao concluida." -ForegroundColor Green
  Write-Host "Adaptador: http://127.0.0.1:$Port"
  Write-Host "Modelo padrao: $($health.defaultModel)"
  Write-Host "Para abrir: claude"
  Write-Host ""
} catch {
  Write-Host ""
  Write-Host "Falha na instalacao: $($_.Exception.Message)" -ForegroundColor Red
  throw
}
