param(
  [string]$Token = "",
  [string]$BaseUrl = "https://gtw.dgsis.com.br/v1",
  [int]$Port = 8792,
  [switch]$SkipDependencyInstall,
  [switch]$SkipClaudeDesktop,
  [switch]$SkipAntigravity,
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
function UserPathContains($path){ return (([Environment]::GetEnvironmentVariable('Path','User') -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $path.TrimEnd('\')) }).Count -gt 0 }
function AddUserPath($path){
  if(-not (Test-Path -LiteralPath $path)){ return }
  if(UserPathContains $path){ return }
  $current = [Environment]::GetEnvironmentVariable('Path','User')
  $next = if([string]::IsNullOrWhiteSpace($current)){ $path }else{ "$current;$path" }
  [Environment]::SetEnvironmentVariable('Path',$next,'User')
  RefreshPath
}
function BroadcastEnvironmentChange {
  try {
    Add-Type -ErrorAction SilentlyContinue -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class NativeEnv { [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult); }' | Out-Null
    $result = [UIntPtr]::Zero
    [void][NativeEnv]::SendMessageTimeout([IntPtr]0xffff,0x1A,[UIntPtr]::Zero,'Environment',2,5000,[ref]$result)
  } catch {}
}
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

function ValidateWindows {
  Step "Validando Windows"
  $caption = 'Windows'
  $version = [Environment]::OSVersion.Version
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $caption = $os.Caption
    $version = [Version]$os.Version
  } catch {
    Write-Host "Aviso: WMI/CIM indisponivel para detectar edicao do Windows; usando versao do sistema." -ForegroundColor Yellow
  }
  if($version.Major -lt 10){ throw "Windows nao suportado: $caption $version. Use Windows 10 1809+ ou Windows 11." }
  if($version.Major -eq 10 -and $version.Build -lt 17763){ throw "Windows 10 antigo demais: build $($version.Build). Use Windows 10 1809+ ou Windows 11." }
  Ok "$caption build $($version.Build)"
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

function WingetAvailable { return Has winget }
function WingetInstalled($id){
  if(-not (WingetAvailable)){ return $false }
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & winget list --id $id -e --accept-source-agreements | Out-Null; return $LASTEXITCODE -eq 0 } catch { return $false } finally { $ErrorActionPreference = $old }
}
function InstallWingetPackage($id,$name){
  if(-not (WingetAvailable)){ throw "winget nao encontrado. Instale App Installer pela Microsoft Store ou instale $name manualmente." }
  & winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
  if($LASTEXITCODE -ne 0){ throw "Falha ao instalar $name via winget. Codigo $LASTEXITCODE." }
}
function EnsureNode {
  Step "Verificando Node.js 20+"
  if((NodeMajor) -lt 20){ InstallWingetPackage 'OpenJS.NodeJS.LTS' 'Node.js LTS'; RefreshPath }
  if((NodeMajor) -lt 20){ throw "Node.js 20+ nao encontrado apos instalacao." }
  Ok (& node -v)
}
function EnsureClaudeCodeCli {
  Step "Verificando Claude Code CLI"
  RefreshPath
  if(Has claude){ Ok "claude existente: $(& claude --version)"; return }
  EnsureNode
  if(-not (Has npm)){ RefreshPath }
  if(-not (Has npm)){ throw "npm nao encontrado apos instalar Node.js." }
  & npm install -g "@anthropic-ai/claude-code"
  if($LASTEXITCODE -ne 0){ throw "Falha ao instalar Claude Code CLI via npm. Codigo $LASTEXITCODE." }
  RefreshPath
  if(-not (Has claude)){ throw "claude nao encontrado apos npm install." }
  Ok "claude instalado: $(& claude --version)"
}
function ClaudeDesktopInstalled {
  if(WingetInstalled 'Anthropic.Claude'){ return $true }
  $paths = @(
    (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\Claude.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'),
    (Join-Path $env:ProgramFiles 'Claude\Claude.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Claude\Claude.exe')
  )
  return @($paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) }).Count -gt 0
}
function EnsureClaudeDesktop {
  if($SkipClaudeDesktop){ return }
  Step "Verificando Claude Desktop"
  if(ClaudeDesktopInstalled){ Ok "Claude Desktop existente"; return }
  InstallWingetPackage 'Anthropic.Claude' 'Claude Desktop'
  Ok "Claude Desktop instalado"
}
function AntigravityInstalled {
  if(Has antigravity -or Has agy){ return $true }
  if(WingetInstalled 'Google.Antigravity'){ return $true }
  $paths = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity'),
    (Join-Path $env:LOCALAPPDATA 'Google\Antigravity'),
    (Join-Path $env:ProgramFiles 'Google\Antigravity'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Antigravity')
  )
  return @($paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) }).Count -gt 0
}
function EnsureAntigravity {
  if($SkipAntigravity){ return }
  Step "Verificando Antigravity"
  if(AntigravityInstalled){ Ok "Antigravity existente"; return }
  InstallWingetPackage 'Google.Antigravity' 'Google Antigravity'
  RefreshPath
  Ok "Antigravity instalado"
}
function EnsureWindowsApps {
  if($SkipDependencyInstall){ return }
  EnsureNode
  EnsureClaudeCodeCli
  EnsureClaudeDesktop
  EnsureAntigravity
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

function ConfigureUserEnvironment {
  Step "Configurando ambiente Windows para Claude CLI, Desktop e Antigravity"
  $envs = @{
    ANTHROPIC_BASE_URL = "http://127.0.0.1:$Port/v1"
    ANTHROPIC_AUTH_TOKEN = 'dgsis-local-proxy'
    ANTHROPIC_MODEL = $DefaultModel
    CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = 'true'
  }
  foreach($name in $envs.Keys){
    [Environment]::SetEnvironmentVariable($name, [string]$envs[$name], 'User')
    Set-Item -Path "Env:$name" -Value ([string]$envs[$name])
  }
  $appDataRoot = if([string]::IsNullOrWhiteSpace($env:APPDATA)){ Join-Path $env:USERPROFILE 'AppData\Roaming' } else { $env:APPDATA }
  AddUserPath (Join-Path $appDataRoot 'npm')
  BroadcastEnvironmentChange
  Ok "variaveis de usuario atualizadas"
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
  ValidateWindows
  ValidateBaseUrl
  $clientToken = if($SelfTestOnly){ '' }else{ GetToken }
  if(-not $SelfTestOnly){ ValidateToken $clientToken }
  if($ValidateOnly){ Finish 0; return }
  EnsureWindowsApps
  if(-not $SelfTestOnly){
    $root=PackageRoot
    InstallProxy $root $clientToken
    ConfigureClaude
    ConfigureUserEnvironment
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
  Write-Host "Desktop/Antigravity: feche e abra novamente para herdar variaveis do Windows."
  Finish 0
} catch {
  Write-Host ""
  Write-Host "Falha na instalacao: $($_.Exception.Message)" -ForegroundColor Red
  ShowLog
  PauseOnInteractiveFailure
  Finish 1
}
