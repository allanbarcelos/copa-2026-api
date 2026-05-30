#!/usr/bin/env bash
# ==============================================================================
#  uninstall.sh — Remove a Copa 2026 API do Docker Swarm
#
#  Uso: sudo bash uninstall.sh
#
#  Remove APENAS os recursos desta aplicação:
#    - Stack copa2026 (serviço copa2026_api)
#    - Docker Swarm secrets com prefixo copa2026_
#    - Diretório /opt/copa-2026-api
#    - Regras UFW com comentário copa2026
#    - Cron job /etc/cron.d/copa2026
#
#  NÃO remove: Docker, Docker Swarm, UFW, outros stacks ou regras existentes.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

readonly STACK_NAME="copa2026"
readonly APP_DIR="/opt/copa-2026-api"
readonly SECRETS_PREFIX="copa2026_"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${CYN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GRN}[OK]${NC}    $*"; }
warn()  { echo -e "${YLW}[AVISO]${NC} $*"; }
die()   { echo -e "${RED}[ERRO]${NC}  $*" >&2; exit 1; }
phase() { echo -e "\n${BLD}${CYN}━━━  $*  ━━━${NC}"; }
sep()   { echo -e "${DIM}──────────────────────────────────────────────────────${NC}"; }

require_root() { [[ $EUID -eq 0 ]] || die "Execute como root: sudo bash uninstall.sh"; }
require_root

# ── Banner ─────────────────────────────────────────────────────────────────────
clear
echo -e "${RED}${BLD}"
cat <<'WARN'
 ╔══════════════════════════════════════════════════════════════════════════════╗
 ║  ATENÇÃO — DESINSTALAÇÃO DA COPA 2026 API                                  ║
 ║                                                                            ║
 ║  Esta operação é irreversível. Serão removidos:                            ║
 ║    • Stack Docker Swarm: copa2026                                          ║
 ║    • Secrets Swarm com prefixo copa2026_                                   ║
 ║    • Diretório /opt/copa-2026-api (logs incluídos)                         ║
 ║    • Regras UFW relacionadas à aplicação                                   ║
 ║    • Cron job /etc/cron.d/copa2026                                         ║
 ║                                                                            ║
 ║  Docker, Docker Swarm e outros stacks NÃO serão afetados.                 ║
 ╚══════════════════════════════════════════════════════════════════════════════╝
WARN
echo -e "${NC}"

read -rp "$(echo -e "  ${BLD}Confirma a desinstalação?${NC} ${DIM}[s/N]${NC}: ")" _CONFIRM </dev/tty
[[ "${_CONFIRM:-n}" =~ ^[SsYy]$ ]] || { echo "Cancelado."; exit 0; }

# ==============================================================================
# STACK
# ==============================================================================
phase "Removendo stack Docker Swarm"

if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -q "^${STACK_NAME}$"; then
  docker stack rm "$STACK_NAME"
  info "Aguardando containers encerrarem..."
  local_timeout=30
  elapsed=0
  while docker stack ps "$STACK_NAME" &>/dev/null && [[ $elapsed -lt $local_timeout ]]; do
    sleep 2
    elapsed=$((elapsed + 2))
  done
  ok "Stack '${STACK_NAME}' removido"
else
  info "Stack '${STACK_NAME}' não encontrado — ignorando"
fi

# ==============================================================================
# SECRETS
# ==============================================================================
phase "Removendo Docker Swarm secrets"

mapfile -t _secrets < <(docker secret ls --format '{{.Name}}' 2>/dev/null | grep "^${SECRETS_PREFIX}" || true)

if [[ ${#_secrets[@]} -eq 0 ]]; then
  info "Nenhum secret com prefixo '${SECRETS_PREFIX}' encontrado"
else
  for secret in "${_secrets[@]}"; do
    docker secret rm "$secret" >/dev/null && ok "Secret removido: ${secret}" || warn "Falha ao remover: ${secret}"
  done
fi

# ==============================================================================
# DIRETÓRIO
# ==============================================================================
phase "Removendo diretório da aplicação"

if [[ -d "$APP_DIR" ]]; then
  rm -rf "$APP_DIR"
  ok "Diretório removido: ${APP_DIR}"
else
  info "Diretório '${APP_DIR}' não encontrado — ignorando"
fi

# ==============================================================================
# UFW
# ==============================================================================
phase "Removendo regras UFW"

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  for _comment in "copa2026-api" "Cloudflare-copa2026" "Block-direct-copa2026"; do
    while ufw status numbered 2>/dev/null | grep -q "${_comment}"; do
      _num=$(ufw status numbered | grep "${_comment}" | head -1 | awk -F'[][]' '{print $2}')
      [[ -n "$_num" ]] && ufw --force delete "$_num" >/dev/null 2>&1 || break
    done
  done
  ufw reload >/dev/null
  ok "Regras UFW da aplicação removidas"
else
  info "UFW inativo ou não instalado — ignorando"
fi

# ==============================================================================
# CRON
# ==============================================================================
phase "Removendo cron job"

if [[ -f "/etc/cron.d/copa2026" ]]; then
  rm -f "/etc/cron.d/copa2026"
  ok "Cron removido: /etc/cron.d/copa2026"
else
  info "Cron '/etc/cron.d/copa2026' não encontrado — ignorando"
fi

# ==============================================================================
# IMAGENS DOCKER (opcional)
# ==============================================================================
phase "Imagens Docker"

_images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep "copa-2026-api" || true)

if [[ -n "$_images" ]]; then
  echo ""
  echo -e "  Imagens encontradas localmente:"
  echo "$_images" | sed 's/^/    /'
  echo ""
  read -rp "$(echo -e "  ${BLD}Remover imagens locais?${NC} ${DIM}[s/N]${NC}: ")" _RM_IMAGES </dev/tty
  if [[ "${_RM_IMAGES:-n}" =~ ^[SsYy]$ ]]; then
    echo "$_images" | xargs docker rmi -f >/dev/null 2>&1 && ok "Imagens removidas" || warn "Algumas imagens não puderam ser removidas"
  else
    info "Imagens mantidas"
  fi
else
  info "Nenhuma imagem local da aplicação encontrada"
fi

# ==============================================================================
# RESUMO
# ==============================================================================
echo ""
sep
echo -e "${GRN}${BLD}  Copa 2026 API desinstalada com sucesso.${NC}"
sep
echo -e "  ${DIM}Stack removido    : ${STACK_NAME}${NC}"
echo -e "  ${DIM}Secrets removidos : prefixo ${SECRETS_PREFIX}${NC}"
echo -e "  ${DIM}Diretório         : ${APP_DIR}${NC}"
echo -e "  ${DIM}Cron              : /etc/cron.d/copa2026${NC}"
echo ""
