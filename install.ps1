param(
  [string]$Token = "",
  [string]$BaseUrl = "https://gtw.dgsis.com.br/v1",
  [int]$Port = 8792,
  [switch]$SkipDependencyInstall,
  [switch]$NoAutoStart,
  [switch]$NoPause,
  [switch]$ExitOnComplete,
  [switch]$ValidateOnly,
  [switch]$SelfTestOnly
)

$ErrorActionPreference = "Stop"
$RepositoryRawBaseUrl = "https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main"
$LocalAppDataRoot = if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){ Join-Path $env:USERPROFILE "AppData\Local" } else { $env:LOCALAPPDATA }
$InstallDir = Join-Path $LocalAppDataRoot "DGSIS\claude-code-proxy"
$TaskName = "DGSIS Claude Code Proxy"
$DefaultModel = "claude-opus-4-8"
$AvailableModelIds = @()
$SupportedModelPriority = @(
  @{ id='kr/claude-opus-4.8'; alias='claude-opus-4-8' },
  @{ id='kr/claude-opus-4.8-thinking'; alias='claude-opus-4-8-thinking' },
  @{ id='kr/claude-opus-4.7'; alias='claude-opus-4-7' },
  @{ id='kr/claude-opus-4.7-thinking'; alias='claude-opus-4-7-thinking' },
  @{ id='kr/claude-opus-4.6'; alias='claude-opus-4-6' },
  @{ id='kr/claude-opus-4.6-thinking'; alias='claude-opus-4-6-thinking' },
  @{ id='kr/claude-opus-4.5'; alias='claude-opus-4-5' },
  @{ id='kr/claude-sonnet-4.6'; alias='claude-sonnet-4-6' },
  @{ id='kr/claude-sonnet-4.5'; alias='claude-sonnet-4-5' },
  @{ id='kr/claude-sonnet-4'; alias='claude-sonnet-4' },
  @{ id='cx/gpt-5.5'; alias='codex-5-5' }
)
$TempRoot = if([string]::IsNullOrWhiteSpace($env:TEMP)){ [IO.Path]::GetTempPath() } else { $env:TEMP }
$LogDir = Join-Path $TempRoot "dgsis-claude-installer"
$LogPath = Join-Path $LogDir ("install-" + (Get-Date -Format yyyyMMdd-HHmmss) + ".log")
$LogShown = $false
$TranscriptStarted = $false

function Step($m){ Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "OK: $m" -ForegroundColor Green }
function Has($c){ return $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }
function RefreshPath { $env:Path = ([Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")) }
function Plain($s){ $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); try{[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)} }
function NodeMajor { if(-not (Has node)){0}else{ [int]((& node -v).Trim().TrimStart('v').Split('.')[0]) } }
function StartLog {
  try {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Start-Transcript -Path $LogPath -Append -ErrorAction SilentlyContinue | Out-Null
    $script:TranscriptStarted = $true
  } catch {}
}
function ShowLog { if(-not $script:LogShown){ Write-Host "Log: $LogPath"; $script:LogShown = $true } }
function Finish($code){
  ShowLog
  if($script:TranscriptStarted){ try { Stop-Transcript | Out-Null } catch {} }
  if($ExitOnComplete){ exit $code }
  $global:LASTEXITCODE = $code
}
function PauseOnInteractiveFailure {
  if($NoPause -or $Token.Trim()){ return }
  try { [void](Read-Host -Prompt "Pressione Enter para fechar") } catch {}
}

function GetToken {
  $t = if($Token.Trim()){ NormalizeToken $Token }else{ NormalizeToken (Plain (Read-Host -AsSecureString -Prompt "Cole o token DGSIS deste cliente")) }
  if(-not $t -or $t.Length -lt 10){ throw "Token vazio ou curto demais." }
  if(-not $t.StartsWith('sk-')){ throw "Token DGSIS invalido: precisa comecar com sk-." }
  return $t
}

function NormalizeToken($value) {
  return ([string]$value).Trim().Trim('"').Trim("'").Trim()
}

function ValidateBaseUrl {
  $script:BaseUrl = $BaseUrl.TrimEnd('/')
  if(-not ($script:BaseUrl.StartsWith('https://') -or $script:BaseUrl.StartsWith('http://'))){ throw "BaseUrl invalida: $BaseUrl" }
}

function GetHttpErrorStatus($err) {
  try {
    if($err.Exception.Response -and $null -ne $err.Exception.Response.StatusCode){ return [int]$err.Exception.Response.StatusCode }
  } catch {}
  return 0
}

function GetHttpErrorBody($err) {
  $resp = $err.Exception.Response
  if(-not $resp){ return "" }
  try {
    if($resp.Content){ return [string]$resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
  } catch {}
  try {
    $stream = $resp.GetResponseStream()
    if($stream){
      $reader = New-Object System.IO.StreamReader($stream)
      try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
  } catch {}
  return ""
}

function ValidateToken($t){
  Step "Validando token e modelos DGSIS"
  $status = 0
  $body = ""
  try {
    $resp = Invoke-WebRequest -Uri "$BaseUrl/models" -Headers @{Authorization="Bearer $t"} -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
    $status = [int]$resp.StatusCode
    $body = [string]$resp.Content
  } catch {
    $status = GetHttpErrorStatus $_
    $body = GetHttpErrorBody $_
    if(-not $status){ throw "Falha ao validar token em $BaseUrl/models: $($_.Exception.Message)" }
  }
  if($status -eq 401){
    throw "Token DGSIS recusado pelo gateway (401). Mesmo com formato valido tipo sk-...-...-..., ele precisa estar habilitado para acesso remoto API em $BaseUrl. Gere/habilite token de API remota para este cliente."
  }
  if($status -ne 200){ throw "Falha ao validar token em $BaseUrl/models. HTTP $status." }
  $r = $body | ConvertFrom-Json
  $ids = @($r.data | ForEach-Object { $_.id })
  $script:AvailableModelIds = @($ids | Where-Object { $_ })
  $supported = @($SupportedModelPriority | Where-Object { $ids -contains $_.id })
  if($supported.Count -lt 1){
    throw "Token valido, mas sem acesso a nenhum modelo suportado pelo instalador. Precisa ter pelo menos um destes: $((@($SupportedModelPriority | ForEach-Object { $_.id })) -join ', ')"
  }
  $script:DefaultModel = $supported[0].alias
  $missingImportant = @('kr/claude-opus-4.8','kr/claude-sonnet-4.6','cx/gpt-5.5') | Where-Object { $ids -notcontains $_ }
  if($missingImportant.Count -gt 0){ Write-Host "Aviso: token sem acesso opcional a $($missingImportant -join ', '). Instalacao continua com fallback." -ForegroundColor Yellow }
  Ok "token valido; modelo padrao: $DefaultModel"
}

function InstallDeps {
  if($SkipDependencyInstall){ return }
  Step "Verificando Node.js 20+"
  if((NodeMajor) -lt 20){
    if(-not (Has winget)){ throw "Instale Node.js LTS ou habilite winget." }
    & winget install --id OpenJS.NodeJS.LTS -e --silent --accept-package-agreements --accept-source-agreements
    RefreshPath
  }
  if((NodeMajor) -lt 20){ throw "Node.js 20+ nao encontrado apos instalacao." }
  Ok (& node -v)
  Step "Instalando Claude Code CLI"
  if(-not (Has npm)){ RefreshPath }
  if(-not (Has npm)){ throw "npm nao encontrado." }
  & npm install -g "@anthropic-ai/claude-code"
  RefreshPath
  if(-not (Has claude)){ throw "claude nao encontrado apos npm install." }
  Ok (& claude --version)
}

function PackageRoot {
  if($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'adapter\src\server.js'))){ return $PSScriptRoot }
  Step "Baixando pacote do GitHub"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dgsis-claude-"+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'adapter\src') | Out-Null
  Invoke-WebRequest -Uri "$RepositoryRawBaseUrl/adapter/package.json" -OutFile (Join-Path $tmp 'adapter\package.json') -UseBasicParsing -TimeoutSec 60
  Invoke-WebRequest -Uri "$RepositoryRawBaseUrl/adapter/src/server.js" -OutFile (Join-Path $tmp 'adapter\src\server.js') -UseBasicParsing -TimeoutSec 60
  if(-not (Test-Path (Join-Path $tmp 'adapter\src\server.js'))){ throw "Pacote invalido." }
  return $tmp
}

function InstallProxy($root,$t){
  Step "Instalando proxy local"
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'src') | Out-Null
  Copy-Item -LiteralPath (Join-Path $root 'adapter\package.json') -Destination (Join-Path $InstallDir 'package.json') -Force
  Copy-Item -LiteralPath (Join-Path $root 'adapter\src\server.js') -Destination (Join-Path $InstallDir 'src\server.js') -Force
  Set-Content -LiteralPath (Join-Path $InstallDir '.env') -Encoding UTF8 -Value "PORT=$Port`nUPSTREAM_BASE_URL=$BaseUrl`nUPSTREAM_API_KEY=$t`nAVAILABLE_MODELS=$($AvailableModelIds -join ',')`n"
}

function ConfigureClaude {
  Step "Configurando Claude Code"
  $dir = Join-Path $env:USERPROFILE '.claude'; $backup = Join-Path $dir 'backups'; New-Item -ItemType Directory -Force -Path $backup | Out-Null
  $path = Join-Path $dir 'settings.json'; $s = [pscustomobject]@{}
  if(Test-Path $path){ try{ $s = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json; Copy-Item -LiteralPath $path -Destination (Join-Path $backup ("settings.before-dgsis-"+(Get-Date -Format yyyyMMdd-HHmmss)+".json")) -Force }catch{} }
  if(-not ($s.PSObject.Properties.Name -contains 'env') -or -not $s.env){ $s | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force }
  $s.env.PSObject.Properties.Remove('ANTHROPIC_API_KEY')
  $s.env | Add-Member -Force -NotePropertyName ANTHROPIC_BASE_URL -NotePropertyValue "http://127.0.0.1:$Port/v1"
  $s.env | Add-Member -Force -NotePropertyName ANTHROPIC_AUTH_TOKEN -NotePropertyValue 'dgsis-local-proxy'
  $s.env | Add-Member -Force -NotePropertyName ANTHROPIC_MODEL -NotePropertyValue $DefaultModel
  $s.env | Add-Member -Force -NotePropertyName CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY -NotePropertyValue 'true'
  $s | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $path -Encoding UTF8
  Ok "settings.json atualizado"
}

function StopProxy { try{ Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }; Start-Sleep -Seconds 1 }catch{} }
function StartProxy { Step "Iniciando proxy"; StopProxy; Start-Process -FilePath (Get-Command node).Source -ArgumentList @('src/server.js') -WorkingDirectory $InstallDir -WindowStyle Hidden | Out-Null }

function Autostart {
  if($NoAutoStart){ return }
  Step "Configurando inicio automatico"
  $node = (Get-Command node).Source
  try{
    Register-ScheduledTask -TaskName $TaskName -Action (New-ScheduledTaskAction -Execute $node -Argument 'src/server.js' -WorkingDirectory $InstallDir) -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Description 'Inicia proxy DGSIS Claude Code' -Force | Out-Null
    Ok "tarefa agendada criada"
  } catch {
    $startup=[Environment]::GetFolderPath('Startup'); New-Item -ItemType Directory -Force -Path $startup | Out-Null
    $vbs=Join-Path $startup 'DGSIS Claude Code Proxy.vbs'
    Set-Content -LiteralPath $vbs -Encoding ASCII -Value "Set shell = CreateObject(""WScript.Shell"")`r`nshell.CurrentDirectory = ""$InstallDir""`r`nshell.Run """"$node"" src/server.js"", 0, False`r`n"
    Ok "launcher Startup criado"
  }
}

function WaitHealth {
  for($i=0;$i -lt 30;$i++){
    try{ $h=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3; if($h.ok){ return } }
    catch{ Start-Sleep -Seconds 1 }
  }
  throw "Proxy nao respondeu."
}

function FinalTest {
  Step "Testando Claude Code"
  $o=& claude -p 'Responda exatamente INSTALL_OK, sem mais nada.' 2>&1
  $txt=($o -join "`n").Trim()
  if($LASTEXITCODE -ne 0 -or $txt -ne 'INSTALL_OK'){ throw "Teste falhou: $txt" }
  Ok "claude respondeu INSTALL_OK"
}

try{
  StartLog
  Write-Host "DGSIS Claude Code Installer" -ForegroundColor Green
  ValidateBaseUrl
  $clientToken = if($SelfTestOnly){ '' }else{ GetToken }
  if(-not $SelfTestOnly){ ValidateToken $clientToken }
  if($ValidateOnly){ Finish 0; return }
  InstallDeps
  if(-not $SelfTestOnly){
    $root=PackageRoot
    InstallProxy $root $clientToken
    ConfigureClaude
    Autostart
    StartProxy
  }
  WaitHealth
  FinalTest
  Write-Host ""
  Write-Host "Instalacao concluida." -ForegroundColor Green
  Write-Host "Proxy: http://127.0.0.1:$Port/v1"
  Write-Host "Modelo: $DefaultModel"
  Write-Host "Abrir: claude"
  Finish 0
} catch {
  Write-Host ""
  Write-Host "Falha na instalacao: $($_.Exception.Message)" -ForegroundColor Red
  ShowLog
  PauseOnInteractiveFailure
  Finish 1
}
