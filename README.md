# DGSIS Claude Code Installer

Instalador para configurar Claude Code com o gateway DGSIS usando proxy local estavel.

O proxy expõe apenas modelos disponiveis no token e faz fallback seguro:

```text
claude-opus-4-8     -> kr/claude-opus-4.8
claude-sonnet-4-6   -> kr/claude-sonnet-4.6
codex-5-5 / gpt-5.5 -> cx/gpt-5.5
gemini manual       -> cx/gpt-5.5
```

Se o token nao tiver Sonnet, a instalacao continua com Opus/Codex disponiveis. Se um modelo nao existir no token, ele nao aparece como modelo validado.

Gemini real e Haiku ficam ocultos por padrao porque falharam testes de estabilidade/conformidade.
`codex-5-5` e `gpt-5.5` sao apenas aliases de modelo usados dentro do Claude Code. Este pacote instala somente Claude Code.

## Windows

Abra PowerShell e execute:

```powershell
powershell -NoExit -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-RestMethod 'https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install.ps1' | Invoke-Expression"
```

O script sempre pede o token DGSIS individual do cliente no terminal.
O token precisa estar habilitado para acesso remoto API. Formato parecido com `sk-...-...-...` nao basta se o gateway retornar `API key required for remote API access`.

## macOS

Abra Terminal e execute:

```bash
curl -fsSL https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install-macos.sh | bash
```

O script sempre pede o token DGSIS individual do cliente no terminal.
O token precisa estar habilitado para acesso remoto API. Formato parecido com `sk-...-...-...` nao basta se o gateway retornar `API key required for remote API access`.

## O Que O Instalador Faz

- Valida o token em `https://gtw.dgsis.com.br/v1/models`.
- Confirma acesso a pelo menos um modelo suportado, priorizando Claude e usando Codex como fallback.
- Instala Node.js 20+ se faltar.
- No macOS, instala Homebrew se faltar e usa Homebrew para instalar Node.js.
- Instala ou atualiza Claude Code CLI com `npm install -g @anthropic-ai/claude-code`.
- Instala proxy local em `127.0.0.1:8792`.
- Configura `~/.claude/settings.json`.
- Cria inicializacao automatica.
- Executa teste final com `claude -p`.

## Modelos Visiveis

Dependem do token. Estes sao exemplos quando todos existem:

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

Se aparecer aviso como `token sem acesso opcional a kr/claude-sonnet-4.6`, nao e erro. O instalador continua usando os modelos disponiveis.

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

## Erro 401 No Token

Se aparecer `Token DGSIS recusado pelo gateway (401)`, o instalador esta correto e o token tambem pode parecer correto. O problema e permissao no gateway DGSIS: gere ou habilite um token de API remota para este cliente em `https://gtw.dgsis.com.br/v1`.

## Logs No Windows

O instalador Windows grava log em:

```text
%TEMP%\dgsis-claude-installer\install-*.log
```

Se o PowerShell fechar depois de erro, rode novamente com o comando Windows acima. Ele usa `-NoExit`, entao a janela fica aberta mesmo quando falha antes do instalador iniciar.

## Seguranca

Nunca coloque token real em GitHub, README ou print publico. Cada cliente deve usar token individual para facilitar revogacao.

## Guias

- [AI-INSTALLER-GUIDE.md](AI-INSTALLER-GUIDE.md): prompt/instrucoes para uma IA instalar para o cliente.
