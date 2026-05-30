#!/usr/bin/env bash
# ==============================================================================
#  install.sh — Instalador de produção da Copa 2026 API
#  Node.js + Socket.IO  ·  Docker Swarm
#
#  Uso: sudo bash install.sh
#
#  COMPATÍVEL com servidores que já possuam outros stacks Docker Swarm —
#  nunca remove regras UFW existentes.
#
#  O QUE ESTE SCRIPT FAZ:
#
#  FASE 1  — Configuração interativa
#    - Modo: VPS+Cloudflare | VPS direto | Local (intranet)
#    - Chaves das APIs (football-data.org e api-football)
#    - ALLOWED_ORIGIN (front-end que terá acesso via WebSocket)
#    - Resumo e confirmação antes de tocar no sistema
#
#  FASE 2  — Pacotes do sistema (apenas o que estiver faltando)
#    curl, wget, openssl, jq, ufw, docker
#
#  FASE 3  — Docker Swarm (idempotente — ignorado se já ativo)
#
#  FASE 4  — Diretório /opt/copa-2026-api
#
#  FASE 5  — entrypoint.sh (mapeia /run/secrets/* para variáveis de ambiente)
#
#  FASE 6  — Docker Swarm secrets (prefixo copa2026_ — encriptados no Raft)
#    Montados nos containers via source/target aliasing.
#    entrypoint.sh mapeia os arquivos de /run/secrets/ para env vars Node.js.
#
#  FASE 7  — Stack file /opt/copa-2026-api/docker-compose.prod.yml
#
#  FASE 8  — Deploy do stack (docker stack deploy --prune)
#
#  FASE 9  — UFW firewall (ADIÇÃO de regras — nunca remove existentes)
#
#  FASE 10 — Scripts de manutenção em /opt/copa-2026-api/scripts/
#
#  FASE 11 — Cron jobs em /etc/cron.d/copa2026
#
#  FASE 12 — Aguardar serviços ficarem saudáveis
#
#  FASE 13 — Resumo completo
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ── Identidade do projeto ──────────────────────────────────────────────────────
readonly APP_NAME="copa-2026-api"
readonly APP_DIR="/opt/copa-2026-api"
readonly STACK_NAME="copa2026"
readonly APP_IMAGE="ghcr.io/allanbarcelos/copa-2026-api:latest"

# ── Cores ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Helpers ────────────────────────────────────────────────────────────────────
info()  { echo -e "${CYN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GRN}[OK]${NC}    $*"; }
warn()  { echo -e "${YLW}[AVISO]${NC} $*"; }
die()   { echo -e "${RED}[ERRO]${NC}  $*" >&2; exit 1; }
phase() { echo -e "\n${BLD}${CYN}━━━  $*  ━━━${NC}"; }
sep()   { echo -e "${DIM}──────────────────────────────────────────────────────${NC}"; }

ask() {
  local prompt="$1" default="${2:-}" var_name="$3" value
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "  ${BLD}${prompt}${NC} ${DIM}[${default}]${NC}: ")" value </dev/tty
    value="${value:-$default}"
  else
    while true; do
      read -rp "$(echo -e "  ${BLD}${prompt}${NC}: ")" value </dev/tty
      [[ -n "$value" ]] && break
      echo -e "  ${RED}Obrigatório — informe um valor.${NC}"
    done
  fi
  printf -v "$var_name" '%s' "$value"
}

ask_optional() {
  local prompt="$1" var_name="$2" value
  read -rp "$(echo -e "  ${BLD}${prompt}${NC} ${DIM}(opcional — Enter para pular)${NC}: ")" value </dev/tty
  printf -v "$var_name" '%s' "${value:-}"
}

ask_yn() {
  local prompt="$1" var_name="$2" default="${3:-n}" value hint
  [[ "$default" == "s" ]] && hint="S/n" || hint="s/N"
  read -rp "$(echo -e "  ${BLD}${prompt}${NC} ${DIM}[${hint}]${NC}: ")" value </dev/tty
  value="${value:-$default}"
  [[ "$value" =~ ^[SsYy]$ ]] && printf -v "$var_name" 'y' || printf -v "$var_name" 'n'
}

require_root() { [[ $EUID -eq 0 ]] || die "Execute como root: sudo bash install.sh"; }

detect_os() {
  [[ -f /etc/os-release ]] || die "Sistema operacional não identificado."
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) warn "Sistema '${ID:-desconhecido}' não testado — continuando mesmo assim." ;;
  esac
}

swarm_secret_exists() { docker secret inspect "$1" &>/dev/null; }

create_swarm_secret() {
  local name="$1" value="${2:-}"
  if swarm_secret_exists "$name"; then
    warn "Secret '${name}' já existe — ignorando"
  else
    printf '%s' "${value:- }" | docker secret create "$name" - >/dev/null
    ok "Secret criado: ${name}"
  fi
}

# ── Guards ─────────────────────────────────────────────────────────────────────
require_root
detect_os

# ── Banner ─────────────────────────────────────────────────────────────────────
clear
echo -e "${RED}${BLD}"
cat <<'WARN'
 ╔══════════════════════════════════════════════════════════════════════════════╗
 ║  ATENÇÃO — LEIA ANTES DE EXECUTAR                                          ║
 ║                                                                            ║
 ║  Este script instala a Copa 2026 API em produção via Docker Swarm.         ║
 ║  Pode ser executado em um servidor que já possua outros stacks Swarm       ║
 ║  sem interferir neles (UFW é apenas complementado).                        ║
 ║                                                                            ║
 ║  Para remover a instalação use:  sudo bash uninstall.sh                    ║
 ╚══════════════════════════════════════════════════════════════════════════════╝
WARN
echo -e "${NC}"

read -rp "$(echo -e "  ${BLD}Confirmo que li o aviso acima${NC} ${DIM}[S/n]${NC}: ")" _WARN_OK </dev/tty
[[ "${_WARN_OK:-s}" =~ ^[SsYy]$ ]] || { echo "Instalação cancelada."; exit 0; }

echo -e "${CYN}${BLD}"
cat <<'LOGO'

   ██████╗ ██████╗ ██████╗  █████╗     ██████╗  ██████╗ ██████╗  ██████╗
  ██╔════╝██╔═══██╗██╔══██╗██╔══██╗    ╚════██╗██╔═══██╗╚════██╗██╔════╝
  ██║     ██║   ██║██████╔╝███████║     █████╔╝██║   ██║ █████╔╝███████╗
  ██║     ██║   ██║██╔═══╝ ██╔══██║    ██╔═══╝ ██║   ██║██╔═══╝ ██╔══██║
  ╚██████╗╚██████╔╝██║     ██║  ██║    ███████╗╚██████╔╝███████╗╚██████╔╝
   ╚═════╝ ╚═════╝ ╚═╝     ╚═╝  ╚═╝   ╚══════╝ ╚═════╝ ╚══════╝ ╚═════╝

              Copa 2026 API — Instalador de Produção  ·  Docker Swarm
LOGO
echo -e "${NC}"
sep

# ==============================================================================
# FASE 1 — CONFIGURAÇÃO
# ==============================================================================
phase "FASE 1 — Configuração"

echo ""

# ── Modo de instalação ─────────────────────────────────────────────────────────
echo -e "  ${BLD}Modo de instalação${NC}"
echo ""
echo -e "  ${BLD}1)${NC} ${CYN}VPS + Cloudflare${NC}  ${DIM}(recomendado)${NC}"
echo -e "     Cloudflare termina o HTTPS; servidor responde na porta configurada"
echo -e "     UFW bloqueia acesso direto — apenas IPs do Cloudflare são permitidos"
echo ""
echo -e "  ${BLD}2)${NC} ${CYN}VPS direto${NC}"
echo -e "     A API fica exposta diretamente na porta configurada (sem TLS no servidor)"
echo -e "     Use se já tiver um proxy reverso externo (nginx, Caddy, etc.)"
echo ""
echo -e "  ${BLD}3)${NC} ${CYN}Local (intranet)${NC}"
echo -e "     Porta exposta apenas localmente — rede interna"
echo ""

while true; do
  read -rp "$(echo -e "  ${BLD}Modo${NC} ${DIM}[1/2/3]${NC}: ")" _MODE_CHOICE </dev/tty
  _MODE_CHOICE="${_MODE_CHOICE:-1}"
  [[ "$_MODE_CHOICE" =~ ^[123]$ ]] && break
  echo -e "  ${RED}Digite 1, 2 ou 3.${NC}"
done

APP_PORT="3001"
DOMAIN=""

case "$_MODE_CHOICE" in
  1)
    INSTALL_MODE="vps_cloudflare"
    echo ""
    ask "Porta da aplicação (Cloudflare → este servidor)" "3001" APP_PORT
    [[ "$APP_PORT" =~ ^[0-9]+$ && "$APP_PORT" -ge 1 && "$APP_PORT" -le 65535 ]] \
      || die "Porta inválida: ${APP_PORT}"
    echo ""
    ask_optional "Domínio Cloudflare (ex: api.copa2026.com.br)" DOMAIN
    echo ""
    echo -e "  ${YLW}Lembre-se de criar uma Origin Rule no Cloudflare:${NC}"
    echo -e "  ${YLW}  Hostname = seu domínio  →  Destination port = ${APP_PORT}${NC}"
    echo -e "  ${YLW}  Ative também 'WebSockets' nas configurações da zona.${NC}"
    ;;
  2)
    INSTALL_MODE="vps_direct"
    echo ""
    ask "Porta da aplicação" "3001" APP_PORT
    [[ "$APP_PORT" =~ ^[0-9]+$ && "$APP_PORT" -ge 1 && "$APP_PORT" -le 65535 ]] \
      || die "Porta inválida: ${APP_PORT}"
    ;;
  3)
    INSTALL_MODE="local"
    echo ""
    ask "Porta da aplicação" "3001" APP_PORT
    [[ "$APP_PORT" =~ ^[0-9]+$ && "$APP_PORT" -ge 1 && "$APP_PORT" -le 65535 ]] \
      || die "Porta inválida: ${APP_PORT}"
    info "Modo: servidor local (intranet)"
    ;;
esac

# ── Chaves das APIs ─────────────────────────────────────────────────────────────
echo ""
sep
echo -e "  ${BLD}Chaves das APIs de futebol${NC}"
sep
echo ""

echo -e "  ${BLD}football-data.org${NC}  ${RED}(obrigatória)${NC}"
echo -e "  ${DIM}Usada para buscar partidas da Copa do Mundo em tempo real.${NC}"
echo -e "  ${DIM}Obtenha em: https://www.football-data.org/client/register${NC}"
echo ""
ask "FOOTBALL_DATA_API_KEY" "" FOOTBALL_DATA_KEY
ok "Chave football-data.org configurada."

echo ""
sep
echo -e "  ${BLD}api-football (RapidAPI)${NC}  ${DIM}(opcional)${NC}"
echo -e "  ${DIM}Usada para buscar previsões de partidas. Se não informada, as previsões${NC}"
echo -e "  ${DIM}ficam desativadas. Obtenha em: https://rapidapi.com/api-sports/api/api-football${NC}"
echo ""
ask_optional "API_FOOTBALL_KEY" API_FOOTBALL_KEY
if [[ -n "$API_FOOTBALL_KEY" ]]; then
  ok "Chave api-football configurada."
else
  info "api-football não configurada — previsões desativadas."
fi

# ── ALLOWED_ORIGIN ─────────────────────────────────────────────────────────────
echo ""
sep
echo -e "  ${BLD}CORS — Origem permitida (ALLOWED_ORIGIN)${NC}"
sep
echo -e "  ${DIM}URL do front-end que terá acesso à API via WebSocket/Socket.IO.${NC}"
echo -e "  ${DIM}Exemplo: https://copa2026.com.br${NC}"
echo ""
ask "ALLOWED_ORIGIN" "http://localhost:5174" ALLOWED_ORIGIN

# ── GHCR ───────────────────────────────────────────────────────────────────────
echo ""
sep
echo -e "  ${BLD}GitHub Container Registry${NC}"
sep
echo -e "  ${DIM}Credenciais para baixar a imagem ${APP_IMAGE}${NC}"
echo -e "  ${DIM}Gere um PAT em: GitHub → Settings → Developer Settings → Personal access tokens${NC}"
echo -e "  ${DIM}Escopo mínimo necessário: read:packages${NC}"
echo ""
ask "Usuário GitHub" "" GHCR_USER
ask "GitHub PAT (Personal Access Token)" "" GHCR_PAT
ok "Credenciais GHCR configuradas."

# ── Resumo + confirmação ───────────────────────────────────────────────────────
echo ""
sep
echo -e "  ${BLD}Resumo — o que será instalado${NC}"
sep
echo -e "  Projeto    : ${CYN}${APP_NAME}${NC}  →  ${CYN}${APP_DIR}${NC}"
echo -e "  Stack      : ${CYN}${STACK_NAME}${NC}"
echo -e "  Imagem     : ${CYN}${APP_IMAGE}${NC}"
case "$INSTALL_MODE" in
  vps_cloudflare)
    echo -e "  Modo       : ${CYN}VPS + Cloudflare${NC}  (porta ${APP_PORT})"
    [[ -n "$DOMAIN" ]] && echo -e "  Domínio    : ${CYN}${DOMAIN}${NC}"
    ;;
  vps_direct)
    echo -e "  Modo       : ${CYN}VPS direto${NC}  (porta ${APP_PORT})"
    ;;
  local)
    echo -e "  Modo       : ${CYN}Local / intranet${NC}  (porta ${APP_PORT})"
    ;;
esac
echo -e "  football-data.org : ${CYN}configurada${NC}"
if [[ -n "$API_FOOTBALL_KEY" ]]; then
  echo -e "  api-football      : ${CYN}configurada${NC}"
else
  echo -e "  api-football      : ${DIM}desativada${NC}"
fi
echo -e "  ALLOWED_ORIGIN    : ${CYN}${ALLOWED_ORIGIN}${NC}"
sep
echo ""
read -rp "$(echo -e "  ${BLD}Prosseguir com a instalação?${NC} ${DIM}[S/n]${NC}: ")" _CONFIRM </dev/tty
[[ "${_CONFIRM:-s}" =~ ^[SsYy]$ ]] || { echo "Abortado."; exit 0; }

# ==============================================================================
# FASE 2 — PACOTES DO SISTEMA
# ==============================================================================
phase "FASE 2 — Pacotes do sistema"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

install_pkg() {
  local pkg="$1"
  if dpkg -s "$pkg" &>/dev/null 2>&1; then
    info "${pkg} já instalado"
  else
    info "Instalando ${pkg}..."
    apt-get install -y -qq "$pkg" >/dev/null
    ok "${pkg} instalado"
  fi
}

for pkg in \
  curl wget ca-certificates gnupg2 lsb-release \
  openssl jq \
  ufw \
  apt-transport-https; do
  install_pkg "$pkg"
done

if command -v docker &>/dev/null; then
  info "Docker já instalado: $(docker --version)"
else
  info "Instalando Docker (script oficial)..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable --now docker >/dev/null 2>&1
  ok "Docker instalado: $(docker --version)"
fi

ok "Todos os pacotes prontos"

# ==============================================================================
# FASE 3 — DOCKER SWARM
# ==============================================================================
phase "FASE 3 — Docker Swarm"

if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "^active$"; then
  info "Swarm já ativo (node: $(docker info --format '{{.Swarm.NodeID}}'))"
else
  _HOST_IP=$(hostname -I | awk '{print $1}')
  info "Inicializando Docker Swarm em ${_HOST_IP}..."
  docker swarm init --advertise-addr "$_HOST_IP" >/dev/null
  ok "Swarm inicializado"
fi

# ==============================================================================
# FASE 4 — DIRETÓRIO DA APLICAÇÃO
# ==============================================================================
phase "FASE 4 — Diretório da aplicação"

[[ -d "$APP_DIR" ]] && info "Diretório ${APP_DIR} já existe — reutilizando"

mkdir -p "${APP_DIR}"/{logs,scripts}
chmod 750 "${APP_DIR}"

ok "Diretório: ${APP_DIR}"

# ==============================================================================
# FASE 5 — ENTRYPOINT (mapeia secrets para env vars)
# ==============================================================================
phase "FASE 5 — Entrypoint"

ENTRYPOINT_FILE="${APP_DIR}/scripts/entrypoint.sh"

cat > "$ENTRYPOINT_FILE" <<'ENTRYPOINT'
#!/bin/sh
# entrypoint.sh — Copa 2026 API
# Mapeia arquivos de /run/secrets/ para variáveis de ambiente do Node.js
set -e

_secret() {
  local file="/run/secrets/$1"
  [ -f "$file" ] && cat "$file" || true
}

_val=$(_secret football_data_key)
[ -n "$_val" ] && export FOOTBALL_DATA_API_KEY="$_val"

_val=$(_secret api_football_key)
[ -n "$_val" ] && export API_FOOTBALL_KEY="$_val"

_val=$(_secret allowed_origin)
[ -n "$_val" ] && export ALLOWED_ORIGIN="$_val"

_val=$(_secret port)
[ -n "$_val" ] && export PORT="$_val"

exec node src/index.js
ENTRYPOINT

chmod 750 "$ENTRYPOINT_FILE"
ok "Entrypoint: ${ENTRYPOINT_FILE}"

# ==============================================================================
# FASE 6 — DOCKER SWARM SECRETS
# ==============================================================================
phase "FASE 6 — Docker Swarm secrets"

create_swarm_secret "copa2026_football_data_key" "$FOOTBALL_DATA_KEY"
create_swarm_secret "copa2026_api_football_key"  "$API_FOOTBALL_KEY"
create_swarm_secret "copa2026_allowed_origin"    "$ALLOWED_ORIGIN"
create_swarm_secret "copa2026_port"              "$APP_PORT"

# ==============================================================================
# FASE 7 — STACK FILE
# ==============================================================================
phase "FASE 7 — Arquivo de stack"

STACK_FILE="${APP_DIR}/docker-compose.prod.yml"

cat > "$STACK_FILE" <<STACK
# =============================================================================
# Docker Swarm Stack — Copa 2026 API
# Gerado: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
#
# Secrets prefixados com copa2026_ para coexistir com outros stacks.
# O entrypoint.sh mapeia /run/secrets/* para variáveis de ambiente Node.js.
# =============================================================================
version: "3.8"

services:

  # ── Copa 2026 API ────────────────────────────────────────────────────────────
  api:
    image: ${APP_IMAGE}
    entrypoint: ["/entrypoint.sh"]
    ports:
      - "${APP_PORT}:${APP_PORT}"
    volumes:
      - ${APP_DIR}/scripts/entrypoint.sh:/entrypoint.sh:ro
      - ${APP_DIR}/logs:/app/logs
    secrets:
      - source: copa2026_football_data_key
        target: football_data_key
      - source: copa2026_api_football_key
        target: api_football_key
      - source: copa2026_allowed_origin
        target: allowed_origin
      - source: copa2026_port
        target: port
    networks:
      - copa2026_net
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:${APP_PORT}/health >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    deploy:
      restart_policy:
        condition: on-failure
        delay: 10s
        max_attempts: 5
      update_config:
        order: start-first
        failure_action: rollback

networks:
  copa2026_net:
    driver: overlay
    attachable: false

secrets:
  copa2026_football_data_key:
    external: true
  copa2026_api_football_key:
    external: true
  copa2026_allowed_origin:
    external: true
  copa2026_port:
    external: true
STACK

chmod 600 "$STACK_FILE"
ok "Stack file: ${STACK_FILE}"

# ==============================================================================
# FASE 8 — DEPLOY DO STACK
# ==============================================================================
phase "FASE 8 — Deploy do stack"

info "Autenticando no GitHub Container Registry (ghcr.io)..."
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
ok "Login no ghcr.io realizado."

info "Baixando imagem ${APP_IMAGE}..."
docker pull "$APP_IMAGE"

info "Fazendo deploy do stack '${STACK_NAME}'..."
docker stack deploy \
  --compose-file "$STACK_FILE" \
  --resolve-image always \
  --prune \
  "$STACK_NAME"

ok "Stack deployado"

# ==============================================================================
# FASE 9 — UFW FIREWALL
# ==============================================================================
phase "FASE 9 — Firewall (UFW)"

UFW_WAS_ACTIVE="n"
ufw status | grep -q "Status: active" && UFW_WAS_ACTIVE="y"

if [[ "$UFW_WAS_ACTIVE" == "n" ]]; then
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
fi

if ! ufw status | grep -qE "^22/tcp|^OpenSSH"; then
  ufw allow 22/tcp comment "SSH" >/dev/null
  ok "UFW: SSH permitido"
else
  info "UFW: regra SSH já presente"
fi

case "$INSTALL_MODE" in
  vps_direct|local)
    if ! ufw status | grep -q "^${APP_PORT}/tcp"; then
      ufw allow "${APP_PORT}/tcp" comment "copa2026-api" >/dev/null
      ok "UFW: porta ${APP_PORT} permitida"
    else
      info "UFW: porta ${APP_PORT} já aberta"
    fi
    ;;

  vps_cloudflare)
    info "Buscando IPs atuais do Cloudflare..."
    CF_IPV4=""
    CF_IPV6=""
    CF_IPV4=$(curl -s --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
    CF_IPV6=$(curl -s --max-time 15 https://www.cloudflare.com/ips-v6 2>/dev/null || true)

    if [[ -z "$CF_IPV4" ]]; then
      warn "Não foi possível buscar IPs do Cloudflare — usando lista embutida"
      CF_IPV4="173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22"
      CF_IPV6="2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
    fi

    printf '%s\n' "$CF_IPV4" > "${APP_DIR}/cloudflare-ips-v4.txt"
    printf '%s\n' "$CF_IPV6" > "${APP_DIR}/cloudflare-ips-v6.txt"

    while ufw status numbered 2>/dev/null | grep -q "Cloudflare-copa2026"; do
      _num=$(ufw status numbered | grep "Cloudflare-copa2026" | head -1 | awk -F'[][]' '{print $2}')
      [[ -n "$_num" ]] && ufw --force delete "$_num" >/dev/null 2>&1 || break
    done

    info "Adicionando regras UFW para IPs Cloudflare (porta ${APP_PORT})..."
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      ufw allow from "$ip" to any port "$APP_PORT" proto tcp \
        comment "Cloudflare-copa2026" >/dev/null 2>&1 || true
    done <<< "$CF_IPV4"
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      ufw allow from "$ip" to any port "$APP_PORT" proto tcp \
        comment "Cloudflare-copa2026" >/dev/null 2>&1 || true
    done <<< "$CF_IPV6"

    if ! ufw status | grep -qE "DENY.*${APP_PORT}"; then
      ufw deny "${APP_PORT}/tcp" comment "Block-direct-copa2026" >/dev/null
    fi
    ok "UFW: porta ${APP_PORT} restrita apenas a IPs do Cloudflare"
    ;;
esac

if [[ "$UFW_WAS_ACTIVE" == "n" ]]; then
  ufw --force enable >/dev/null
  ok "UFW habilitado"
fi
ufw reload >/dev/null
ok "UFW configurado"

# ==============================================================================
# FASE 10 — SCRIPTS DE MANUTENÇÃO
# ==============================================================================
phase "FASE 10 — Scripts de manutenção"

SCRIPTS_DIR="${APP_DIR}/scripts"

# ── update-image.sh ────────────────────────────────────────────────────────────
cat > "${SCRIPTS_DIR}/update-image.sh" <<UPDSCRIPT
#!/usr/bin/env bash
# Atualização de imagem da copa2026-api — executa diariamente via cron
set -euo pipefail

LOG="${APP_DIR}/logs/update-image.log"
ts()  { date -u '+[%Y-%m-%d %H:%M:%S UTC]'; }
log() { echo "\$(ts) \$*" | tee -a "\$LOG"; }
exec 1>>"\$LOG" 2>&1

log "=== Atualização iniciada ==="
docker pull ${APP_IMAGE} && log "Pulled ${APP_IMAGE}" || log "AVISO: pull falhou"
docker service update \\
  --image ${APP_IMAGE} \\
  --update-order start-first \\
  ${STACK_NAME}_api \\
  && log "${STACK_NAME}_api atualizado" \\
  || log "AVISO: atualização falhou"
docker image prune -f --filter "dangling=true" >/dev/null
log "=== Concluído ==="
UPDSCRIPT
chmod 750 "${SCRIPTS_DIR}/update-image.sh"
ok "Script: update-image.sh"

# ── update-cloudflare-ips.sh (modo Cloudflare) ────────────────────────────────
if [[ "$INSTALL_MODE" == "vps_cloudflare" ]]; then
  cat > "${SCRIPTS_DIR}/update-cloudflare-ips.sh" <<CFSCRIPT
#!/usr/bin/env bash
# Atualiza IPs do Cloudflare no UFW — copa2026
set -euo pipefail

APP_PORT="${APP_PORT}"
APP_DIR="${APP_DIR}"
LOG="\${APP_DIR}/logs/cf-ip-update.log"
ts()  { date -u '+[%Y-%m-%d %H:%M:%S UTC]'; }
log() { echo "\$(ts) \$*" | tee -a "\$LOG"; }
exec 1>>"\$LOG" 2>&1
log "=== Atualização IPs Cloudflare ==="

CF_IPV4=\$(curl -s --max-time 15 https://www.cloudflare.com/ips-v4 || true)
CF_IPV6=\$(curl -s --max-time 15 https://www.cloudflare.com/ips-v6 || true)
[[ -z "\$CF_IPV4" ]] && { log "ERRO: fetch falhou"; exit 1; }

while ufw status numbered 2>/dev/null | grep -q "Cloudflare-copa2026"; do
  num=\$(ufw status numbered | grep "Cloudflare-copa2026" | head -1 | awk -F'[][]' '{print \$2}')
  [[ -n "\$num" ]] && ufw --force delete "\$num" >/dev/null 2>&1 || break
done

while IFS= read -r ip; do [[ -z "\$ip" ]] && continue
  ufw allow from "\$ip" to any port "\$APP_PORT" proto tcp comment "Cloudflare-copa2026" >/dev/null 2>&1 || true
done <<< "\$CF_IPV4"
while IFS= read -r ip; do [[ -z "\$ip" ]] && continue
  ufw allow from "\$ip" to any port "\$APP_PORT" proto tcp comment "Cloudflare-copa2026" >/dev/null 2>&1 || true
done <<< "\$CF_IPV6"

printf '%s\n' "\$CF_IPV4" > "\${APP_DIR}/cloudflare-ips-v4.txt"
printf '%s\n' "\$CF_IPV6" > "\${APP_DIR}/cloudflare-ips-v6.txt"

ufw reload >/dev/null
log "=== Concluído ==="
CFSCRIPT
  chmod 750 "${SCRIPTS_DIR}/update-cloudflare-ips.sh"
  ok "Script: update-cloudflare-ips.sh"
fi

# ==============================================================================
# FASE 11 — CRON JOBS
# ==============================================================================
phase "FASE 11 — Cron jobs"

{
  echo "# Cron jobs — copa2026"
  echo "# Gerado: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo "CRON_TZ=America/Sao_Paulo"
  echo ""
  echo "# Atualização de imagem — diariamente às 04:00"
  echo "0 4 * * * root ${SCRIPTS_DIR}/update-image.sh"
  echo ""
  if [[ "$INSTALL_MODE" == "vps_cloudflare" ]]; then
    echo "# Atualizar IPs Cloudflare — todo dia 1 às 03:00"
    echo "0 3 1 * * root ${SCRIPTS_DIR}/update-cloudflare-ips.sh"
    echo ""
  fi
} > "/etc/cron.d/copa2026"

chmod 644 "/etc/cron.d/copa2026"
ok "Cron: /etc/cron.d/copa2026"

# ==============================================================================
# FASE 12 — AGUARDAR SERVIÇOS
# ==============================================================================
phase "FASE 12 — Aguardando serviços"

_svc_tasks() {
  local svc="$1"
  echo -e "  ${DIM}Tasks:${NC}"
  docker service ps "$svc" --no-trunc \
    --format "    {{printf \"%-42s\" .Name}}  {{printf \"%-22s\" .CurrentState}}  {{.Error}}" \
    2>/dev/null | head -8 || echo "    (sem tasks ainda)"
}

_svc_logs() {
  local svc="$1" n="${2:-10}"
  local out
  out=$(docker service logs --tail "$n" --no-task-ids --timestamps "$svc" 2>/dev/null || true)
  if [[ -n "$out" ]]; then
    echo -e "  ${DIM}Logs (últimas ${n} linhas):${NC}"
    echo "$out" | sed 's/^/    /'
  else
    echo -e "  ${DIM}Logs: (nenhum ainda)${NC}"
  fi
}

wait_for_svc() {
  local svc="$1" max="${2:-120}" tick=8 elapsed=0 running

  echo ""
  echo -e "${BLD}${CYN}▶  ${svc}${NC}  ${DIM}(timeout: ${max}s)${NC}"
  sep

  while [[ $elapsed -lt $max ]]; do
    running=$(docker service ps \
      --filter desired-state=running \
      --format "{{.CurrentState}}" \
      "$svc" 2>/dev/null | grep -c "^Running" || true)

    echo -e "  ${DIM}[${elapsed}s]${NC}"
    _svc_tasks "$svc"
    echo ""
    _svc_logs "$svc"

    if [[ "$running" -ge 1 ]]; then
      echo ""
      ok "${svc}  ✓  em execução"
      sep
      return 0
    fi

    echo ""
    echo -e "  ${YLW}Aguardando... próxima verificação em ${tick}s${NC}"
    echo ""
    sleep "$tick"
    elapsed=$((elapsed + tick))
  done

  echo ""
  echo -e "  ${RED}[TIMEOUT após ${max}s]${NC}"
  echo ""
  docker service ps "$svc" --no-trunc \
    --format "    {{printf \"%-42s\" .Name}}  {{printf \"%-22s\" .CurrentState}}  {{.Error}}" \
    2>/dev/null || true
  echo ""
  _svc_logs "$svc" 30
  echo ""
  warn "${svc} expirou — pode ainda estar convergindo. Verifique com:"
  echo "  docker service logs -f ${svc}"
  sep
  return 1
}

info "Estado imediatamente após o deploy:"
echo ""
docker stack ps "$STACK_NAME" \
  --format "  {{printf \"%-42s\" .Name}}  {{printf \"%-22s\" .CurrentState}}  {{.Error}}" \
  2>/dev/null || true
echo ""

_WAIT_FAILED=0
wait_for_svc "${STACK_NAME}_api" 120 || _WAIT_FAILED=1

echo ""
info "Estado final do stack:"
echo ""
docker stack services "$STACK_NAME" 2>/dev/null || true
echo ""

if [[ $_WAIT_FAILED -eq 0 ]]; then
  ok "Serviço em execução"
else
  warn "O serviço não atingiu Running. O stack está deployado e pode ainda estar"
  warn "convergindo. Verifique com:"
  echo "  docker stack services ${STACK_NAME}"
  echo "  docker stack ps ${STACK_NAME} --no-trunc"
fi

# ==============================================================================
# FASE 13 — RESUMO COMPLETO
# ==============================================================================
phase "FASE 13 — Resumo e credenciais"

clear
echo ""
echo -e "${BLD}${GRN}"
cat <<'DONE'
 ╔══════════════════════════════════════════════════════════════════════════════╗
 ║          INSTALAÇÃO DA COPA 2026 API CONCLUÍDA                             ║
 ╚══════════════════════════════════════════════════════════════════════════════╝
DONE
echo -e "${NC}"

sep
echo -e "  ${BLD}${CYN}APLICAÇÃO${NC}"
sep
echo -e "  Stack      : ${BLD}${STACK_NAME}${NC}"
echo -e "  Diretório  : ${BLD}${APP_DIR}${NC}"
echo -e "  Imagem     : ${BLD}${APP_IMAGE}${NC}"
echo -e "  Stack file : ${BLD}${STACK_FILE}${NC}"
echo ""
case "$INSTALL_MODE" in
  vps_cloudflare)
    echo -e "  Modo       : ${BLD}VPS + Cloudflare${NC}"
    echo -e "  Porta exp. : ${BLD}${APP_PORT}${NC}"
    if [[ -n "$DOMAIN" ]]; then
      echo -e "  URL        : ${BLD}${CYN}https://${DOMAIN}${NC}  ${DIM}(via Cloudflare)${NC}"
    else
      _srv_ip_final=$(hostname -I | awk '{print $1}')
      echo -e "  URL        : ${BLD}${CYN}http://${_srv_ip_final}:${APP_PORT}${NC}"
    fi
    ;;
  vps_direct)
    _srv_ip_final=$(hostname -I | awk '{print $1}')
    echo -e "  Modo       : ${BLD}VPS direto${NC}"
    echo -e "  URL        : ${BLD}${CYN}http://${_srv_ip_final}:${APP_PORT}${NC}"
    ;;
  local)
    _lip_final=$(hostname -I | awk '{print $1}')
    echo -e "  Modo       : ${BLD}Local / intranet${NC}"
    echo -e "  URL        : ${BLD}${CYN}http://${_lip_final}:${APP_PORT}${NC}"
    ;;
esac

echo ""
sep
echo -e "  ${BLD}${CYN}DOCKER SWARM SECRETS${NC}  ${DIM}(prefixo copa2026_ — encriptados no Raft)${NC}"
sep
echo -e "  ${DIM}copa2026_football_data_key  →  /run/secrets/football_data_key  →  FOOTBALL_DATA_API_KEY${NC}"
echo -e "  ${DIM}copa2026_api_football_key   →  /run/secrets/api_football_key   →  API_FOOTBALL_KEY${NC}"
echo -e "  ${DIM}copa2026_allowed_origin     →  /run/secrets/allowed_origin     →  ALLOWED_ORIGIN${NC}"
echo -e "  ${DIM}copa2026_port               →  /run/secrets/port               →  PORT${NC}"

echo ""
sep
echo -e "  ${BLD}${CYN}CONFIGURAÇÃO ATIVA${NC}"
sep
echo -e "  FOOTBALL_DATA_API_KEY : ${BLD}${RED}${FOOTBALL_DATA_KEY}${NC}"
if [[ -n "$API_FOOTBALL_KEY" ]]; then
  echo -e "  API_FOOTBALL_KEY      : ${BLD}${RED}${API_FOOTBALL_KEY}${NC}"
else
  echo -e "  API_FOOTBALL_KEY      : ${DIM}não configurada (previsões desativadas)${NC}"
fi
echo -e "  ALLOWED_ORIGIN        : ${BLD}${ALLOWED_ORIGIN}${NC}"
echo -e "  PORT                  : ${BLD}${APP_PORT}${NC}"

echo ""
sep
echo -e "  ${BLD}${CYN}JOBS AGENDADOS${NC}  ${DIM}(/etc/cron.d/copa2026)${NC}"
sep
echo -e "  Atualização imagem : ${BLD}Diariamente às 04:00 (Horário de Brasília)${NC}"
[[ "$INSTALL_MODE" == "vps_cloudflare" ]] && \
  echo -e "  IPs Cloudflare     : ${BLD}Todo dia 1 do mês às 03:00${NC}"

echo ""
sep
echo -e "  ${BLD}${CYN}COMANDOS ÚTEIS${NC}"
sep
echo -e "  Status do serviço   : ${BLD}docker stack services ${STACK_NAME}${NC}"
echo -e "  Logs da aplicação   : ${BLD}docker service logs -f ${STACK_NAME}_api${NC}"
echo -e "  Reiniciar           : ${BLD}docker service update --force ${STACK_NAME}_api${NC}"
echo -e "  Atualizar agora     : ${BLD}${SCRIPTS_DIR}/update-image.sh${NC}"
echo -e "  Health check        : ${BLD}curl http://localhost:${APP_PORT}/health${NC}"
echo -e "  Desinstalar         : ${BLD}sudo bash uninstall.sh${NC}"
echo ""

sep
echo -e "${YLW}${BLD}  ╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${YLW}${BLD}  ║  IMPORTANTE: Anote as chaves de API acima em local seguro. ║${NC}"
echo -e "${YLW}${BLD}  ║  Elas NÃO estão salvas em nenhum arquivo do servidor.       ║${NC}"
echo -e "${YLW}${BLD}  ╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "$INSTALL_MODE" == "vps_cloudflare" ]]; then
  echo -e "${YLW}  CLOUDFLARE: Ative 'WebSockets' nas configurações da zona."
  echo -e "  Crie uma Origin Rule apontando seu domínio para a porta ${APP_PORT}."
  echo -e "  Acesso direto (sem Cloudflare) está bloqueado por UFW.${NC}"
  echo ""
fi

sep
echo ""
