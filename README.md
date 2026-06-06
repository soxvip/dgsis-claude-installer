# DGSIS Claude Code Installer

Instalador para configurar Claude Code com o gateway DGSIS usando proxy local estavel.

O proxy expõe apenas modelos validados e faz fallback seguro:

```text
claude-opus-4-8     -> kr/claude-opus-4.8
claude-sonnet-4-6   -> kr/claude-sonnet-4.6
codex-5-5 / gpt-5.5 -> cx/gpt-5.5
gemini manual       -> cx/gpt-5.5
```

Gemini real e Haiku ficam ocultos por padrao porque falharam testes de estabilidade/conformidade.
`codex-5-5` e `gpt-5.5` sao apenas aliases de modelo usados dentro do Claude Code. Este pacote instala somente Claude Code.

## Windows

Abra PowerShell e execute:

```powershell
irm https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install.ps1 | iex
```

O script sempre pede o token DGSIS individual do cliente no terminal.

## macOS

Abra Terminal e execute:

```bash
curl -fsSL https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install.sh | bash
```

O script sempre pede o token DGSIS individual do cliente no terminal.

## O Que O Instalador Faz

- Valida o token em `https://gtw.dgsis.com.br/v1/models`.
- Confirma acesso a `kr/claude-opus-4.8`, `kr/claude-sonnet-4.6` e `cx/gpt-5.5`.
- Instala Node.js 20+ se faltar.
- Instala ou atualiza Claude Code CLI com `npm install -g @anthropic-ai/claude-code`.
- Instala proxy local em `127.0.0.1:8792`.
- Configura `~/.claude/settings.json`.
- Cria inicializacao automatica.
- Executa teste final com `claude -p`.

## Modelos Visiveis

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

## Comandos Uteis

Teste rapido:

```bash
claude -p "Responda exatamente OK, sem mais nada."
```

Abrir Claude Code:

```bash
claude
```

Health do proxy:

```bash
curl http://127.0.0.1:8792/health
```

## Reexecutar

Pode rodar de novo para trocar token, atualizar proxy ou corrigir configuracao. Backups de `settings.json` ficam em `~/.claude/backups`.

## Seguranca

Nunca coloque token real em GitHub, README ou print publico. Cada cliente deve usar token individual para facilitar revogacao.

## Guias

- [AI-INSTALLER-GUIDE.md](AI-INSTALLER-GUIDE.md): prompt/instrucoes para uma IA instalar para o cliente.
