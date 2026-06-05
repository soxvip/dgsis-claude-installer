# DGSIS Claude Code Installer

Instalador simples para configurar o Claude Code com a API DGSIS.

## Instalacao por Comando Unico

```powershell
irm https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install.ps1 | iex
```

O instalador vai pedir um JSON em uma unica linha:

```json
{"api":"https://gtw.dgsis.com.br/v1","token":"TOKEN_DO_CLIENTE"}
```

Tambem funciona se esse JSON ja estiver copiado na area de transferencia antes de rodar o comando.

## Instalacao Manual Pelo ZIP

1. Baixe o ZIP do repositorio.
2. Extraia a pasta.
3. Edite `client-config.example.json` com o token do cliente.
4. Rode:

```powershell
.\install.ps1 -ConfigPath .\client-config.example.json
```

## O Que O Instalador Faz

- Instala Node.js LTS se faltar.
- Instala ou atualiza Claude Code.
- Instala o adaptador em `%LOCALAPPDATA%\DGSIS\claude-adapter`.
- Configura `%USERPROFILE%\.claude\settings.json`.
- Remove `ANTHROPIC_AUTH_TOKEN` se existir.
- Cria inicio automatico no Windows.
- Testa `claude -p "Responda exatamente: OK"`.

## Modelos

Padrao:

```text
ag/claude-opus-4-6-thinking
```

Atalhos:

```powershell
claude --model opus
claude --model sonnet
claude --model haiku
```

Modelos diretos:

```powershell
claude --model "ag/claude-opus-4-6-thinking"
claude --model "ag/claude-sonnet-4-6"
claude --model "kr/claude-opus-4.8"
claude --model "kr/deepseek-3.2"
claude --model "kr/qwen3-coder-next"
```

## Seguranca

Nao coloque tokens reais no GitHub.

Use um token individual por cliente. Assim voce consegue revogar ou limitar um cliente sem afetar os outros.
