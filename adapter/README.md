# DGSIS Claude Adapter

Adaptador local para usar uma API OpenAI-compatible no Claude Code.

Fluxo:

```text
Claude Code -> http://127.0.0.1:8791 -> API OpenAI-compatible
```

O instalador cria automaticamente:

```text
.env
data/adapter-api-key.txt
%USERPROFILE%\.claude\settings.json
```

## Rodar Manualmente

```powershell
npm start
```

## Health Check

```powershell
Invoke-RestMethod http://127.0.0.1:8791/health
```

## Observacao

Este adaptador converte a API Anthropic Messages usada pelo Claude Code para uma API OpenAI-compatible. Ele tambem converte chamadas de ferramenta para que o Claude Code consiga usar arquivos e terminal localmente.
