#!/usr/bin/env bash
set -euo pipefail

TOKEN=""
BASE_URL="https://gtw.dgsis.com.br/v1"
PORT="8792"
SKIP_DEPS=0
NO_AUTOSTART=0
SELF_TEST_ONLY=0
REPO_ZIP_URL="https://github.com/soxvip/dgsis-claude-installer/archive/refs/heads/main.zip"
INSTALL_DIR="$HOME/.dgsis/claude-code-proxy"
DEFAULT_MODEL="claude-opus-4-8"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --no-autostart) NO_AUTOSTART=1; shift ;;
    --self-test-only) SELF_TEST_ONLY=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

step(){ printf '\n==> %s\n' "$1" >&2; }
ok(){ printf 'OK: %s\n' "$1" >&2; }
fail(){ printf '\nFalha na instalacao: %s\n' "$1" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1; }
node_major(){ need node || { echo 0; return; }; node -v | sed 's/^v//' | cut -d. -f1; }

get_token(){
  if [ -n "$TOKEN" ]; then normalize_token "$TOKEN"; return; fi
  printf 'Cole o token DGSIS deste cliente: ' >&2
  stty -echo 2>/dev/null || true
  IFS= read -r t
  stty echo 2>/dev/null || true
  printf '\n' >&2
  t="$(normalize_token "$t")"
  [ "${#t}" -ge 10 ] || fail "Token vazio ou curto demais."
  printf '%s' "$t"
}

normalize_token(){
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

validate_base_url(){
  BASE_URL="${BASE_URL%/}"
  case "$BASE_URL" in http://*|https://*) ;; *) fail "Base URL invalida: $BASE_URL" ;; esac
}

validate_token(){
  local t="$1"
  step "Validando token e modelos DGSIS"
  local tmp
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $t" "$BASE_URL/models" || true)"
  if [ "$code" = "401" ]; then
    fail "Token DGSIS recusado pelo gateway (401). Mesmo com formato valido tipo sk-...-...-..., ele precisa estar habilitado para acesso remoto API em $BASE_URL. Gere/habilite token de API remota para este cliente."
  fi
  [ "$code" = "200" ] || fail "Falha ao validar token em $BASE_URL/models. HTTP $code."
  for m in 'kr/claude-opus-4.8' 'kr/claude-sonnet-4.6' 'cx/gpt-5.5'; do
    grep -q "\"$m\"" "$tmp" || fail "Token sem acesso a $m"
  done
  rm -f "$tmp"
  ok "token valido"
}

install_deps(){
  [ "$SKIP_DEPS" -eq 0 ] || return
  step "Verificando Node.js 20+"
  if [ "$(node_major)" -lt 20 ]; then
    if ! need brew; then
      if [ "$(uname -s)" != "Darwin" ]; then fail "Instale Node.js 20+ e rode novamente."; fi
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
      if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
    fi
    brew install node
  fi
  [ "$(node_major)" -ge 20 ] || fail "Node.js 20+ nao encontrado."
  ok "$(node -v)"
  step "Instalando Claude Code CLI"
  need npm || fail "npm nao encontrado."
  npm install -g @anthropic-ai/claude-code
  need claude || fail "claude nao encontrado apos npm install."
  ok "$(claude --version)"
}

package_root(){
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || pwd)"
  if [ -f "$here/adapter/src/server.js" ]; then printf '%s' "$here"; return; fi
  step "Baixando pacote do GitHub"
  local tmp zip
  tmp="$(mktemp -d)"; zip="$tmp/repo.zip"
  curl -fsSL "$REPO_ZIP_URL" -o "$zip"
  unzip -q "$zip" -d "$tmp"
  find "$tmp" -maxdepth 2 -path '*/adapter/src/server.js' -print -quit | sed 's#/adapter/src/server.js##'
}

install_proxy(){
  local root="$1" t="$2"
  step "Instalando proxy local"
  mkdir -p "$INSTALL_DIR/src"
  cp "$root/adapter/package.json" "$INSTALL_DIR/package.json"
  cp "$root/adapter/src/server.js" "$INSTALL_DIR/src/server.js"
  cat >"$INSTALL_DIR/.env" <<EOF
PORT=$PORT
UPSTREAM_BASE_URL=$BASE_URL
UPSTREAM_API_KEY=$t
EOF
  chmod 600 "$INSTALL_DIR/.env"
}

configure_claude(){
  step "Configurando Claude Code"
  mkdir -p "$HOME/.claude/backups"
  [ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$HOME/.claude/backups/settings.before-dgsis-$(date +%Y%m%d-%H%M%S).json" || true
  ANTHROPIC_BASE_URL_VALUE="http://127.0.0.1:$PORT/v1" ANTHROPIC_MODEL_VALUE="$DEFAULT_MODEL" node <<'NODE'
const fs = require('fs');
const path = require('path');
const p = path.join(process.env.HOME, '.claude', 'settings.json');
let s = {};
try { s = JSON.parse(fs.readFileSync(p, 'utf8')); } catch {}
s.env = s.env && typeof s.env === 'object' ? s.env : {};
delete s.env.ANTHROPIC_API_KEY;
s.env.ANTHROPIC_BASE_URL = process.env.ANTHROPIC_BASE_URL_VALUE;
s.env.ANTHROPIC_AUTH_TOKEN = 'dgsis-local-proxy';
s.env.ANTHROPIC_MODEL = process.env.ANTHROPIC_MODEL_VALUE;
s.env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = 'true';
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify(s, null, 2));
NODE
  ok "settings.json atualizado"
}

stop_proxy(){ pids="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"; [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true; }
start_proxy(){ step "Iniciando proxy"; stop_proxy; (cd "$INSTALL_DIR" && nohup node src/server.js >proxy.log 2>proxy.err.log &); }

autostart(){
  [ "$NO_AUTOSTART" -eq 0 ] || return
  step "Configurando inicio automatico"
  if [ "$(uname -s)" = "Darwin" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    cat >"$HOME/Library/LaunchAgents/com.dgsis.claude-code-proxy.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.dgsis.claude-code-proxy</string><key>ProgramArguments</key><array><string>$(command -v node)</string><string>$INSTALL_DIR/src/server.js</string></array><key>WorkingDirectory</key><string>$INSTALL_DIR</string><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>StandardOutPath</key><string>$INSTALL_DIR/proxy.log</string><key>StandardErrorPath</key><string>$INSTALL_DIR/proxy.err.log</string></dict></plist>
EOF
    launchctl unload "$HOME/Library/LaunchAgents/com.dgsis.claude-code-proxy.plist" >/dev/null 2>&1 || true
    launchctl load "$HOME/Library/LaunchAgents/com.dgsis.claude-code-proxy.plist" >/dev/null 2>&1 || true
  elif need systemctl; then
    mkdir -p "$HOME/.config/systemd/user"
    cat >"$HOME/.config/systemd/user/dgsis-claude-code-proxy.service" <<EOF
[Unit]
Description=DGSIS Claude Code Proxy
[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=$(command -v node) $INSTALL_DIR/src/server.js
Restart=always
[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload || true
    systemctl --user enable --now dgsis-claude-code-proxy.service || true
  fi
}

health_ok(){ curl -fsSL "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }
wait_health(){ for i in $(seq 1 30); do health_ok && return; sleep 1; done; fail "Proxy nao respondeu."; }
final_test(){ step "Testando Claude Code"; out="$(claude -p 'Responda exatamente INSTALL_OK, sem mais nada.' 2>&1 | tr -d '\r')"; [ "$out" = "INSTALL_OK" ] || fail "Teste falhou: $out"; ok "claude respondeu INSTALL_OK"; }

validate_base_url
CLIENT_TOKEN=""
if [ "$SELF_TEST_ONLY" -eq 0 ]; then CLIENT_TOKEN="$(get_token)"; validate_token "$CLIENT_TOKEN"; fi
install_deps
if [ "$SELF_TEST_ONLY" -eq 0 ]; then ROOT="$(package_root)"; install_proxy "$ROOT" "$CLIENT_TOKEN"; configure_claude; stop_proxy; autostart; health_ok || start_proxy; fi
wait_health
final_test
printf '\nInstalacao concluida.\nProxy: http://127.0.0.1:%s/v1\nModelo: %s\nAbrir: claude\n' "$PORT" "$DEFAULT_MODEL"
