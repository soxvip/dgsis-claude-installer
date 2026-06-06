# Guia Para IA Instaladora - DGSIS Claude Code

Use este arquivo quando uma IA ou tecnico for instalar o ambiente para um cliente.

## Objetivo

Deixar o cliente usando Claude Code (`claude`) com gateway DGSIS via proxy local.

Base URL padrao:

```text
https://gtw.dgsis.com.br/v1
```

Token: pedir sempre ao cliente. Cada cliente tem token individual. Nao invente, nao reutilize token de outro cliente, nao salve em chat publico.

O token precisa ter acesso remoto API liberado para `https://gtw.dgsis.com.br/v1`. Formato parecido com `sk-...-...-...` nao confirma permissao. Se o gateway responder `API key required for remote API access`, peça ao responsavel DGSIS para gerar/habilitar token de API remota para esse cliente.

## Perguntas Obrigatorias Ao Cliente

1. Qual sistema operacional? Windows ou macOS?
2. Cole seu token DGSIS individual.
3. A Base URL e `https://gtw.dgsis.com.br/v1`? Se nao, peça a Base URL correta.

## Instalacao Windows

Abra PowerShell normal. Se winget ou Node exigirem permissao, abrir PowerShell como Administrador.

Comando padrao:

```powershell
irm https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install.ps1 | iex
```

Se precisar informar Base URL diferente:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install.ps1))) -BaseUrl "https://gtw.dgsis.com.br/v1"
```

Durante a instalacao, quando pedir token, o cliente deve colar o token individual.

## Instalacao macOS

Abra Terminal.

Comando padrao:

```bash
curl -fsSL https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install-macos.sh | bash
```

Se precisar informar Base URL diferente:

```bash
curl -fsSL https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install-macos.sh | bash -s -- --base-url "https://gtw.dgsis.com.br/v1"
```

Durante a instalacao, quando pedir token, o cliente deve colar o token individual.
No macOS, o instalador usa Homebrew para instalar Node.js 20+ se Node estiver ausente ou antigo. Se Homebrew tambem nao existir, o instalador instala Homebrew antes.

## O Que A IA Deve Conferir

Depois da instalacao, rodar:

Windows PowerShell:

```powershell
Invoke-RestMethod http://127.0.0.1:8792/health
claude -p "Responda exatamente OK, sem mais nada."
```

macOS Terminal:

```bash
curl -fsSL http://127.0.0.1:8792/health
claude -p "Responda exatamente OK, sem mais nada."
```

Resultado esperado do Claude:

```text
OK
```

## Checklist De Validacao

- `node -v` mostra versao 20 ou superior.
- `claude --version` funciona.
- `http://127.0.0.1:8792/health` responde JSON com `ok: true`.
- `~/.claude/settings.json` aponta para `http://127.0.0.1:8792/v1`.
- `claude -p "Responda exatamente OK, sem mais nada."` responde `OK`.

## Modelos Que Devem Aparecer

```text
claude-opus-4-8
claude-opus-4.8
kr/claude-opus-4.8
claude-sonnet-4-6
claude-sonnet-4.6
kr/claude-sonnet-4.6
codex-5-5
codex-5.5
gpt-5-5
gpt-5.5
cx/gpt-5.5
```

`codex-5-5` e `gpt-5.5` sao aliases de modelo usados dentro do Claude Code. Este processo instala somente Claude Code.

## Se Der Erro

1. Confirmar token com cliente.
2. Se aparecer erro 401 com `remote API access`, nao tentar trocar modelo nem reinstalar Claude Code. O token esta sem permissao de API remota.
3. Rodar validação manual:

Windows:

```powershell
$token = Read-Host -AsSecureString "Token DGSIS"
```

macOS:

```bash
read -rsp "Token DGSIS: " TOKEN; echo
```

4. Conferir se porta `8792` esta livre ou se o proxy esta rodando.
5. Reexecutar instalador.

## Onde Ficam Arquivos

Windows:

```text
%LOCALAPPDATA%\DGSIS\claude-code-proxy
%USERPROFILE%\.claude\settings.json
```

macOS:

```text
~/.dgsis/claude-code-proxy
~/.claude/settings.json
~/Library/LaunchAgents/com.dgsis.claude-code-proxy.plist
```

## Regras Importantes Para IA Instaladora

- Sempre pedir token ao cliente.
- Nunca usar token de exemplo.
- Nunca postar token no chat final.
- Se Gemini aparecer como modelo, nao usar Gemini real. O proxy redireciona Gemini manual para `cx/gpt-5.5` por estabilidade.
- Este processo e somente para Claude Code (`claude`).
