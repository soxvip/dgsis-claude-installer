# Guia VS Code + Codex

Use este guia quando o cliente quiser usar Codex no VS Code alem do Claude Code DGSIS.

Importante: o token DGSIS e obrigatorio para o instalador DGSIS/Claude Code. O Codex IDE Extension oficial da OpenAI normalmente pede login ChatGPT ou API key OpenAI. Um token DGSIS nao substitui login OpenAI no Codex Extension.

## Perguntar Ao Cliente

1. Qual sistema operacional? Windows ou macOS?
2. O cliente quer apenas Claude Code DGSIS ou tambem Codex no VS Code?
3. Pedir token DGSIS individual para configurar o proxy DGSIS.
4. Para Codex Extension, confirmar se o cliente tem ChatGPT/OpenAI login ou API key OpenAI.

## Instalar VS Code No Windows

PowerShell:

```powershell
if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
  winget install --id Microsoft.VisualStudioCode -e --accept-package-agreements --accept-source-agreements
}
```

Fechar e abrir PowerShell depois se `code` nao aparecer no PATH.

## Instalar VS Code No macOS

Terminal:

```bash
if ! command -v code >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
    [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"
  fi
  brew install --cask visual-studio-code
fi
```

Se o comando `code` nao existir apos abrir o VS Code, no VS Code pressione `Cmd+Shift+P` e rode `Shell Command: Install 'code' command in PATH`.

## Instalar Codex Extension

Windows ou macOS:

```bash
code --install-extension OpenAI.chatgpt
```

Se o comando falhar, abrir VS Code, ir em Extensions e procurar:

```text
Codex - OpenAI's coding agent
```

Extension ID:

```text
OpenAI.chatgpt
```

## Instalar Codex CLI Oficial Opcional

Windows:

```powershell
irm https://chatgpt.com/codex/install.ps1 | iex
codex
```

macOS:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex
```

O Codex CLI e o Codex IDE Extension compartilham configuracao/autenticacao local.

## Configurar DGSIS Antes Do VS Code

Rode o instalador principal primeiro:

Windows:

```powershell
irm https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install.ps1 | iex
```

macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install.sh | bash
```

Sempre pedir token DGSIS individual durante essa etapa.

## Validar Tudo

Terminal:

```bash
claude -p "Responda exatamente OK, sem mais nada."
```

Esperado:

```text
OK
```

VS Code:

1. Abrir VS Code.
2. Abrir Codex no painel lateral.
3. Fazer login quando a extensao pedir.
4. Testar pergunta curta: `Responda exatamente OK`.

## Observacoes Para IA Instaladora

- Nao confundir `claude` com `codex`.
- O ambiente DGSIS testado neste repositorio usa Claude Code com proxy local.
- Codex VS Code oficial e produto OpenAI; pode exigir ChatGPT/API key OpenAI.
- Sempre pedir token DGSIS para instalar o proxy DGSIS.
- Se o cliente nao tiver login OpenAI, concluir apenas a instalacao DGSIS/Claude Code e explicar que Codex Extension precisa auth OpenAI.
