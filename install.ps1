param(
  [string]$Token = "",
  [string]$BaseUrl = "https://gtw.dgsis.com.br/v1",
  [int]$Port = 8792,
  [switch]$SkipDependencyInstall,
  [switch]$NoAutoStart,
  [switch]$InstallCodexCli,
  [switch]$SelfTestOnly
)

$ErrorActionPreference = "Stop"
$RepositoryZipUrl = "https://github.com/soxvip/dgsis-claude-installer/archive/refs/heads/main.zip"
$InstallDir = Join-Path $env:LOCALAPPDATA "DGSIS\claude-code-proxy"
$TaskName = "DGSIS Claude Code Proxy"
$DefaultModel = "claude-opus-4-8"

function Step($m){ Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "OK: $m" -ForegroundColor Green }
function Has($c){ return $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }
function RefreshPath { $env:Path = ([Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")) }
function Plain($s){ $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); try{[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)} }
function NodeMajor { if(-not (Has node)){0}else{ [int]((& node -v).Trim().TrimStart('v').Split('.')[0]) } }

function GetToken {
  if($Token.Trim()){ return $Token.Trim() }
  $t = Plain (Read-Host -AsSecureString -Prompt "Cole o token DGSIS deste cliente")
  if(-not $t -or $t.Trim().Length -lt 10){ throw "Token vazio ou curto demais." }
  return $t.Trim()
}

function ValidateBaseUrl {
  $script:BaseUrl = $BaseUrl.TrimEnd('/')
  if(-not ($script:BaseUrl.StartsWith('https://') -or $script:BaseUrl.StartsWith('http://'))){ throw "BaseUrl invalida: $BaseUrl" }
}

function ValidateToken($t){
  Step "Validando token e modelos DGSIS"
  $r = Invoke-RestMethod -Uri "$BaseUrl/models" -Headers @{Authorization="Bearer $t"} -TimeoutSec 30
  $ids = @($r.data | ForEach-Object { $_.id })
  foreach($m in @('kr/claude-opus-4.8','kr/claude-sonnet-4.6','cx/gpt-5.5')){ if($ids -notcontains $m){ throw "Token sem acesso a $m" } }
  Ok "token valido"
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
  if($InstallCodexCli){ Step "Instalando OpenAI Codex CLI opcional"; Invoke-Expression (Invoke-RestMethod -Uri "https://chatgpt.com/codex/install.ps1" -TimeoutSec 60); RefreshPath }
}

function PackageRoot {
  if($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'adapter\src\server.js'))){ return $PSScriptRoot }
  Step "Baixando pacote do GitHub"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dgsis-claude-"+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'repo.zip'
  Invoke-WebRequest -Uri $RepositoryZipUrl -OutFile $zip -TimeoutSec 60
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
  $root = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
  if(-not $root -or -not (Test-Path (Join-Path $root.FullName 'adapter\src\server.js'))){ throw "Pacote invalido." }
  return $root.FullName
}

function InstallProxy($root,$t){
  Step "Instalando proxy local"
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'src') | Out-Null
  Copy-Item -LiteralPath (Join-Path $root 'adapter\package.json') -Destination (Join-Path $InstallDir 'package.json') -Force
  Copy-Item -LiteralPath (Join-Path $root 'adapter\src\server.js') -Destination (Join-Path $InstallDir 'src\server.js') -Force
  Set-Content -LiteralPath (Join-Path $InstallDir '.env') -Encoding UTF8 -Value "PORT=$Port`nUPSTREAM_BASE_URL=$BaseUrl`nUPSTREAM_API_KEY=$t`n"
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
  Write-Host "DGSIS Claude Code Installer" -ForegroundColor Green
  ValidateBaseUrl
  $clientToken = if($SelfTestOnly){ '' }else{ GetToken }
  if(-not $SelfTestOnly){ ValidateToken $clientToken }
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
} catch {
  Write-Host ""
  Write-Host "Falha na instalacao: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
