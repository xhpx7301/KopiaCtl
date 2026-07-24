#!/usr/bin/env bash

# KopiaCtl - interactive Kopia manager for Debian servers.
set -uo pipefail

readonly PROJECT_NAME="KopiaCtl"
readonly MANAGER_VERSION="1.0.17"
readonly MANAGER_SOURCE_URL="${KOPIACTL_SOURCE_URL:-https://raw.githubusercontent.com/xhpx7301/KopiaCtl/main/kopiactl.sh}"
readonly INSTALL_DIR="/opt/kopiactl"
readonly CONFIG_FILE="${INSTALL_DIR}/kopiactl.env"
readonly KOPIA_CONFIG_FILE="${INSTALL_DIR}/config/repository.config"
readonly CACHE_DIR="${INSTALL_DIR}/cache"
readonly COMPOSE_FILE="${INSTALL_DIR}/compose.yml"
readonly BACKUP_DIR="/var/backups/kopiactl"
readonly MANAGER_DIR="/usr/local/lib/kopiactl"
readonly MANAGER_SCRIPT="${MANAGER_DIR}/kopiactl.sh"
readonly MANAGER_COMMAND="/usr/local/bin/kopiactl"
readonly SERVICE_FILE="/etc/systemd/system/kopia-web-ui.service"
readonly KOPIA_IMAGE="kopia/kopia:latest"
readonly DEFAULT_WEB_UI_PORT="51515"

# Only retained for the lifetime of the interactive menu process.
REPOSITORY_PASSWORD=''
MANAGER_UPDATED=false
FULL_UNINSTALL_DONE=false

if [[ -t 1 ]]; then
  readonly RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
  readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

info() { printf '%s[信息]%s %s\n' "$BLUE" "$RESET" "$*"; }
success() { printf '%s[完成]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error() { printf '%s[错误]%s %s\n' "$RED" "$RESET" "$*" >&2; }
pause_menu() { printf '\n'; read -r -p '按回车键返回主菜单...' _ || true; }
confirm_action() { local answer; read -r -p "$1 [y/n，回车默认n]：" answer || return 1; [[ "$answer" =~ ^[Yy]$ ]]; }
timestamp() { date '+%Y%m%d-%H%M%S'; }
manager_source() { readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s\n' "${BASH_SOURCE[0]}"; }

secret_character_count() {
  local LC_ALL=C.UTF-8
  printf '%d' "${#1}"
}

read_secret_with_length() {
  local label="$1" character='' value='' length
  # read -n bypasses readline, so disable bracketed paste to avoid counting its control bytes.
  printf '\033[?2004l'
  printf '%s [已输入 0 位]：' "$label"
  while true; do
    IFS= read -r -s -n 1 character || { printf '\n'; return 1; }
    case "$character" in
      '') break ;;
      $'\177'|$'\b') [[ -z "$value" ]] || value="${value%?}" ;;
      *) value+="$character" ;;
    esac
    length="$(secret_character_count "$value")"
    printf '\r%s [已输入 %d 位]：' "$label" "$length"
  done
  printf '\n'
  REPLY="$value"
}

show_command_usage() {
  cat <<'USAGE'
KopiaCtl 是 Kopia 的交互式原生 / Docker 管理菜单。
用法：kopiactl [--install-manager] [--help]
  --install-manager      安装 kopiactl 命令入口，供安装器调用
  --help, -h             显示本帮助
USAGE
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] && return
  command -v sudo >/dev/null 2>&1 || { error '此菜单需要 root 权限，并且系统没有安装 sudo。'; exit 1; }
  exec sudo bash "$(manager_source)" "$@"
}

require_debian() {
  command -v apt-get >/dev/null 2>&1 || { error 'KopiaCtl 当前仅自动支持 Debian/Ubuntu 的 apt 系统。'; return 1; }
}

require_docker() {
  command -v docker >/dev/null 2>&1 || { error '未找到 Docker。请先在菜单中安装 Docker。'; return 1; }
  docker info >/dev/null 2>&1 || { error 'Docker 守护进程不可用。'; return 1; }
  docker compose version >/dev/null 2>&1 || { error '需要 Docker Compose v2（docker compose）。'; return 1; }
}

config_value() { [[ -f "$CONFIG_FILE" ]] && sed -n "s/^$1=//p" "$CONFIG_FILE" | tail -n 1 || true; }
current_mode() { local mode; mode="$(config_value INSTALL_MODE)"; [[ "$mode" == docker ]] && printf 'docker\n' || printf 'native\n'; }
web_ui_enabled() { [[ "$(config_value WEB_UI_ENABLED)" == true ]]; }
web_ui_port() { local port; port="$(config_value WEB_UI_PORT)"; printf '%s\n' "${port:-$DEFAULT_WEB_UI_PORT}"; }
web_ui_user() {
  local user password
  user="$(config_value WEB_UI_USERNAME)"
  password="$(config_value WEB_UI_PASSWORD)"
  [[ "$user" == admin && -z "$password" ]] && user=pingzi
  printf '%s\n' "${user:-pingzi}"
}

localize_mode() {
  case "$1" in
    native) printf '原生安装' ;;
    docker) printf 'Docker 容器' ;;
    *) printf '%s' "${1:-未知}" ;;
  esac
}

localize_service_state() {
  case "$1" in
    active) printf '运行中' ;;
    inactive) printf '已停止' ;;
    failed) printf '启动失败' ;;
    '') printf '未创建' ;;
    *) printf '%s' "$1" ;;
  esac
}

write_config() {
  local mode="$1" enabled="${2:-false}" user="${3:-pingzi}" password="${4:-}" port="${5:-$DEFAULT_WEB_UI_PORT}"
  install -d -m 0750 "$INSTALL_DIR" "$(dirname "$KOPIA_CONFIG_FILE")" "$CACHE_DIR"
  cat >"$CONFIG_FILE" <<EOF
# 由 KopiaCtl 管理。R2 密钥仅保存在 Kopia 的 repository.config 中。
INSTALL_MODE=${mode}
WEB_UI_ENABLED=${enabled}
WEB_UI_USERNAME=${user}
WEB_UI_PASSWORD=${password}
WEB_UI_PORT=${port}
EOF
  chmod 0600 "$CONFIG_FILE"
}

ensure_config() {
  [[ -f "$CONFIG_FILE" ]] || write_config native false pingzi '' "$DEFAULT_WEB_UI_PORT"
}

install_manager_command() {
  local source_path
  source_path="$(manager_source)"
  install -d -m 0755 "$MANAGER_DIR"
  [[ "$source_path" == "$MANAGER_SCRIPT" ]] || install -m 0755 "$source_path" "$MANAGER_SCRIPT"
  cat >"$MANAGER_COMMAND" <<'WRAPPER'
#!/usr/bin/env bash
set -uo pipefail
readonly MANAGER_SCRIPT="/usr/local/lib/kopiactl/kopiactl.sh"
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  exec "$MANAGER_SCRIPT" "$@"
fi
command -v sudo >/dev/null 2>&1 || { printf 'kopiactl 需要 root 权限，但系统未安装 sudo。\n' >&2; exit 1; }
exec sudo "$MANAGER_SCRIPT" "$@"
WRAPPER
  chmod 0755 "$MANAGER_COMMAND"
}

cache_busted_github_raw_url() {
  local source_url="$1" separator
  case "$source_url" in
    https://raw.githubusercontent.com/*)
      [[ "$source_url" == *\?* ]] && separator='&' || separator='?'
      printf '%s%skopiactl_cache_bust=%s-%s-%s\n' "$source_url" "$separator" "$(date +%s)" "$$" "$RANDOM"
      ;;
    *) printf '%s\n' "$source_url" ;;
  esac
}

update_manager() {
  local temp_file source_url new_version
  temp_file="$(mktemp)" || return 1
  source_url="$(cache_busted_github_raw_url "$MANAGER_SOURCE_URL")"
  info '正在下载 KopiaCtl 管理菜单更新...'
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 -H 'Cache-Control: no-cache' "$source_url" -o "$temp_file" || { rm -f "$temp_file"; error '下载失败。'; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$temp_file" --header='Cache-Control: no-cache' "$source_url" || { rm -f "$temp_file"; error '下载失败。'; return 1; }
  else
    rm -f "$temp_file"; error '需要 curl 或 wget 才能更新。'; return 1
  fi
  if ! grep -Fq 'readonly PROJECT_NAME="KopiaCtl"' "$temp_file" || ! bash -n "$temp_file"; then
    rm -f "$temp_file"; error '下载的脚本校验失败。'; return 1
  fi
  new_version="$(sed -n 's/^readonly MANAGER_VERSION="\([^"]*\)"$/\1/p' "$temp_file" | head -n 1)"
  install -d -m 0750 "$BACKUP_DIR"
  [[ ! -f "$MANAGER_SCRIPT" ]] || cp -a "$MANAGER_SCRIPT" "${BACKUP_DIR}/kopiactl-before-update.$(timestamp).bak"
  install -m 0755 "$temp_file" "$MANAGER_SCRIPT"
  rm -f "$temp_file"
  MANAGER_UPDATED=true
  success "KopiaCtl 已更新：${MANAGER_VERSION} -> ${new_version:-未知版本}。"
  info '按回车键后将自动重新载入新版菜单。'
}

install_native_kopia() {
  require_debian || return 1
  if command -v kopia >/dev/null 2>&1; then
    success "Kopia 已安装：$(kopia --version 2>/dev/null | head -n 1)"
    return 0
  fi
  warn '将添加 Kopia 官方 APT 软件源并安装 Kopia。'
  confirm_action '确认继续安装原生 Kopia？' || { info '已取消。'; return 0; }
  apt-get update || return 1
  apt-get install -y ca-certificates curl gnupg || { error '安装前置依赖失败。'; return 1; }
  curl -fsSL --proto '=https' --tlsv1.2 https://kopia.io/signing-key | gpg --dearmor --yes -o /usr/share/keyrings/kopia-keyring.gpg || { error '下载或导入 Kopia 签名密钥失败。'; return 1; }
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main' > /etc/apt/sources.list.d/kopia.list
  apt-get update && apt-get install -y kopia || { error 'Kopia 安装失败。'; return 1; }
  success "Kopia 已安装：$(kopia --version 2>/dev/null | head -n 1)"
}

install_docker() {
  require_debian || return 1
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    success 'Docker Engine 与 Compose 已安装。'
    return 0
  fi
  warn '将从 Debian 软件源安装 Docker Engine 与 Docker Compose 插件。'
  confirm_action '确认继续安装 Docker？' || { info '已取消。'; return 0; }
  apt-get update || return 1
  if ! apt-get install -y docker.io docker-compose-plugin; then
    apt-get install -y docker.io docker-compose-v2 || { error 'Docker 或 Compose 安装失败。'; return 1; }
  fi
  systemctl enable --now docker || { error 'Docker 服务启动失败。'; return 1; }
  require_docker && success 'Docker Engine 与 Compose 已就绪。'
}

install_docker_kopia() {
  install_docker || return 1
  require_docker || return 1
  if docker image inspect "$KOPIA_IMAGE" >/dev/null 2>&1; then
    success "Kopia Docker 镜像已安装：${KOPIA_IMAGE}"
  else
    info "正在下载 Kopia Docker 镜像：${KOPIA_IMAGE}"
    docker pull "$KOPIA_IMAGE" || { error 'Kopia Docker 镜像下载失败。'; return 1; }
    success "Kopia Docker 镜像已安装：${KOPIA_IMAGE}"
  fi
  write_compose_file
}

write_compose_file() {
  install -d -m 0750 "$INSTALL_DIR" "$(dirname "$KOPIA_CONFIG_FILE")" "$CACHE_DIR"
  cat >"$COMPOSE_FILE" <<EOF
# 由 KopiaCtl 管理。默认未启用 Web UI；使用 docker compose --profile web 启动。
services:
  kopia-web-ui:
    image: ${KOPIA_IMAGE}
    container_name: kopia-web-ui
    restart: unless-stopped
    profiles: ["web"]
    ports:
      - "\${WEB_UI_PORT}:\${WEB_UI_PORT}"
    command:
      - server
      - start
      - --insecure
      - --address=0.0.0.0:\${WEB_UI_PORT}
      - --server-username=\${WEB_UI_USERNAME}
      - --server-password=\${WEB_UI_PASSWORD}
      - --config-file=/app/config/repository.config
    volumes:
      - ./config:/app/config
      - ./cache:/app/cache
EOF
  chmod 0640 "$COMPOSE_FILE"
}

configure_mode() {
  local selected="$1" current enabled user password port
  current="$(current_mode)"
  enabled="$(web_ui_enabled && printf true || printf false)"
  user="$(web_ui_user)"
  password="$(config_value WEB_UI_PASSWORD)"
  port="$(web_ui_port)"
  [[ "$selected" == native || "$selected" == docker ]] || { error '无效的安装方式。'; return 1; }
  if [[ "$selected" != "$current" && "$enabled" == true ]]; then
    warn '切换安装方式会停止当前 Web UI；Kopia 仓库配置与缓存会保留。'
    confirm_action "确认从 $(localize_mode "$current") 切换到 $(localize_mode "$selected")？" || { info '已取消。'; return 0; }
  fi
  case "$selected" in
    native) install_native_kopia || return 1 ;;
    docker) install_docker_kopia || return 1 ;;
  esac
  if [[ "$selected" != "$current" && "$enabled" == true ]]; then
    stop_web_ui
    enabled=false
  fi
  ensure_config
  write_config "$selected" "$enabled" "$user" "$password" "$port"
  if [[ "$enabled" == true ]]; then
    success "Kopia 已按 $(localize_mode "$selected") 就绪。Web UI 保持启用状态。"
  else
    success "Kopia 已按 $(localize_mode "$selected") 就绪。Web UI 保持默认关闭。"
  fi
}

choose_install_mode() {
  local selected
  printf '\n当前配置方式：%s\n' "$(localize_mode "$(current_mode)")"
  printf '  1. 安装原生 Kopia（默认，适合资源紧张的服务器）\n'
  printf '  2. 安装 Docker Kopia（安装 Docker 并下载 Kopia 镜像）\n'
  printf '  0. 返回\n'
  read -r -p '请选择 [0-2]：' selected
  case "$selected" in
    1) configure_mode native ;;
    2) configure_mode docker ;;
    0) return 0 ;;
    *) error '无效选项。'; return 1 ;;
  esac
}

native_kopia() {
  command -v kopia >/dev/null 2>&1 || { error '未安装原生 Kopia。'; return 1; }
  kopia --config-file="$KOPIA_CONFIG_FILE" "$@"
}

docker_kopia() {
  local -a password_env=()
  require_docker || return 1
  install -d -m 0750 "$(dirname "$KOPIA_CONFIG_FILE")" "$CACHE_DIR"
  [[ -z "${KOPIA_PASSWORD:-}" ]] || password_env=(-e KOPIA_PASSWORD)
  docker run --rm \
    "${password_env[@]}" \
    -v "$(dirname "$KOPIA_CONFIG_FILE"):/app/config" \
    -v "$CACHE_DIR:/app/cache" \
    "$KOPIA_IMAGE" --config-file=/app/config/repository.config "$@"
}

run_kopia() {
  case "$(current_mode)" in
    native) native_kopia "$@" ;;
    docker) docker_kopia "$@" ;;
  esac
}

run_kopia_with_repository_password() {
  local repository_password="$1"
  shift
  KOPIA_PASSWORD="$repository_password" run_kopia "$@"
}

ensure_repository_password() {
  [[ -n "$REPOSITORY_PASSWORD" ]] && return 0
  read_secret_with_length '请输入 Kopia 仓库密码（不是 R2 Secret Access Key）' || return 1
  REPOSITORY_PASSWORD="$REPLY"
  [[ -n "$REPOSITORY_PASSWORD" ]] || { error 'Kopia 仓库密码不能为空。'; return 1; }
}

run_kopia_authenticated() {
  ensure_repository_password || return 1
  if ! run_kopia_with_repository_password "$REPOSITORY_PASSWORD" "$@"; then
    REPOSITORY_PASSWORD=''
    error '无法打开 Kopia 仓库。请检查仓库密码后重试。'
    return 1
  fi
}

check_r2_endpoint() {
  local endpoint="$1" http_code
  if ! command -v curl >/dev/null 2>&1; then
    warn '未找到 curl，跳过 R2 网络预检。'
    return 0
  fi
  info "正在检查 R2 endpoint 网络（最长 15 秒）：${endpoint}"
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "https://${endpoint}" 2>/dev/null || true)"
  case "$http_code" in
    ''|000)
      error '无法在 15 秒内连接 R2 endpoint。请检查服务器 DNS、IPv6/IPv4 路由、防火墙和 TCP 443 出站访问。'
      return 1
      ;;
    *)
      success "R2 endpoint 可达（HTTP ${http_code}；403 或 400 对未签名探测请求属正常现象）。"
      ;;
  esac
}

run_with_progress() {
  local description="$1" pid elapsed=0 result
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s[处理中]%s %s（已等待 %d 秒，Ctrl+C 可取消）' "$BLUE" "$RESET" "$description" "$elapsed"
    sleep 1
    ((elapsed++))
  done
  wait "$pid"; result=$?
  printf '\r%*s\r' 100 ''
  return "$result"
}

configure_r2_repository() {
  local action account_id bucket access_key secret_key endpoint repository_password password_confirm
  printf '\n%sCloudflare R2 仓库配置%s\n' "$BOLD" "$RESET"
  printf '  1. 连接已有 R2 仓库（默认）\n'
  printf '  2. 在空 R2 Bucket 中创建新仓库\n'
  printf '  0. 返回\n'
  read -r -p '请选择 [0-2，默认1]：' action
  action="${action:-1}"
  case "$action" in 1|2) ;; 0) return 0 ;; *) error '无效选项。'; return 1 ;; esac
  read -r -p 'Cloudflare Account ID：' account_id
  read -r -p 'R2 Bucket 名称：' bucket
  read -r -p 'R2 Access Key ID：' access_key
  read_secret_with_length 'R2 Secret Access Key' || return 1
  secret_key="$REPLY"
  [[ -n "$account_id" && -n "$bucket" && -n "$access_key" && -n "$secret_key" ]] || { error 'Account ID、Bucket 与 R2 密钥均不能为空。'; return 1; }
  endpoint="${account_id}.r2.cloudflarestorage.com"
  check_r2_endpoint "$endpoint" || return 1
  if [[ "$action" == 2 ]]; then
    warn '创建操作会在指定 Bucket 写入新的 Kopia 仓库数据。Bucket 必须为空。'
    confirm_action "确认在 R2 Bucket ${bucket} 创建仓库？" || { info '已取消。'; return 0; }
    read_secret_with_length '请设置新的 Kopia 仓库密码（与 R2 Secret Access Key 不同）' || return 1
    repository_password="$REPLY"
    read_secret_with_length '再次输入 Kopia 仓库密码' || return 1
    password_confirm="$REPLY"
    [[ -n "$repository_password" && "$repository_password" == "$password_confirm" ]] || { error '仓库密码不能为空，且两次输入必须一致。'; return 1; }
    run_with_progress '正在创建 Kopia 仓库并连接 Cloudflare R2' run_kopia_with_repository_password "$repository_password" repository create s3 --bucket="$bucket" --endpoint="$endpoint" --region=auto --access-key="$access_key" --secret-access-key="$secret_key" || return 1
  else
    read_secret_with_length '请输入已有 Kopia 仓库密码（不是 R2 Secret Access Key）' || return 1
    repository_password="$REPLY"
    [[ -n "$repository_password" ]] || { error 'Kopia 仓库密码不能为空。'; return 1; }
    run_with_progress '正在验证仓库密码并连接 Cloudflare R2' run_kopia_with_repository_password "$repository_password" repository connect s3 --bucket="$bucket" --endpoint="$endpoint" --region=auto --access-key="$access_key" --secret-access-key="$secret_key" || return 1
  fi
  REPOSITORY_PASSWORD="$repository_password"
  success "Cloudflare R2 仓库已配置：${bucket}。R2 密钥已由 Kopia 加密保存；本次菜单会话无需再次输入仓库密码。"
}

create_snapshot() {
  local path mode
  read -r -p '请输入要备份的绝对路径：' path
  [[ "$path" == /* && -e "$path" ]] || { error '请输入存在的 Linux 绝对路径。'; return 1; }
  ensure_repository_password || return 1
  mode="$(current_mode)"
  if [[ "$mode" == docker ]]; then
    require_docker || return 1
    if ! KOPIA_PASSWORD="$REPOSITORY_PASSWORD" docker run --rm -e KOPIA_PASSWORD \
      -v "$(dirname "$KOPIA_CONFIG_FILE"):/app/config" \
      -v "$CACHE_DIR:/app/cache" \
      -v "${path}:${path}:ro" \
      "$KOPIA_IMAGE" --config-file=/app/config/repository.config snapshot create "$path"; then
      REPOSITORY_PASSWORD=''
      error '无法创建快照。若提示无法打开仓库，请检查仓库密码后重试。'
      return 1
    fi
  else
    run_kopia_authenticated snapshot create "$path"
  fi
}

list_snapshots() { run_kopia_authenticated snapshot list; }

restore_snapshot() {
  local snapshot_id destination mode
  printf '\n%s可恢复快照%s\n' "$BOLD" "$RESET"
  list_snapshots || return 1
  printf '\n'
  read -r -p '请输入上方列表中的快照 ID [输入0返回]：' snapshot_id
  [[ "$snapshot_id" == 0 ]] && { info '已取消恢复。'; return 0; }
  read -r -p '请输入恢复目标的绝对路径（目录会被创建）：' destination
  [[ "$snapshot_id" =~ ^[A-Za-z0-9._:-]+$ && "$destination" == /* ]] || { error '快照 ID 或恢复路径无效。'; return 1; }
  confirm_action "确认将快照 ${snapshot_id} 恢复到 ${destination}？" || { info '已取消。'; return 0; }
  install -d -m 0750 "$destination" || return 1
  ensure_repository_password || return 1
  mode="$(current_mode)"
  if [[ "$mode" == docker ]]; then
    require_docker || return 1
    if ! KOPIA_PASSWORD="$REPOSITORY_PASSWORD" docker run --rm -e KOPIA_PASSWORD \
      -v "$(dirname "$KOPIA_CONFIG_FILE"):/app/config" \
      -v "$CACHE_DIR:/app/cache" \
      -v "${destination}:${destination}" \
      "$KOPIA_IMAGE" --config-file=/app/config/repository.config snapshot restore "$snapshot_id" "$destination"; then
      REPOSITORY_PASSWORD=''
      error '无法恢复快照。若提示无法打开仓库，请检查仓库密码后重试。'
      return 1
    fi
  else
    run_kopia_authenticated snapshot restore "$snapshot_id" "$destination"
  fi
}

write_native_service() {
  local binary password port user service_password service_user
  binary="$(command -v kopia)" || { error '未安装原生 Kopia。'; return 1; }
  password="$(config_value WEB_UI_PASSWORD)"
  port="$(web_ui_port)"
  user="$(web_ui_user)"
  [[ -n "$password" ]] || { error 'Web UI 密码未设置。'; return 1; }
  service_password="${password//%/%%}"
  service_user="${user//%/%%}"
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Kopia Web UI Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=KOPIA_CONFIG_PATH=${KOPIA_CONFIG_FILE}
ExecStart=${binary} server start --insecure --address=0.0.0.0:${port} --server-username=${service_user} --server-password=${service_password} --config-file=${KOPIA_CONFIG_FILE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chmod 0600 "$SERVICE_FILE"
  systemctl daemon-reload
}

valid_web_ui_value() { [[ "$1" =~ ^[A-Za-z0-9@%+=_,.!:-]+$ ]]; }

generate_web_ui_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16 && return 0
  fi
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

configure_web_ui_credentials() {
  local enabled="${1:-true}" user password confirm port default_user default_port password_mode
  default_user="$(web_ui_user)"
  default_port="$(web_ui_port)"
  read -r -p "Web UI 用户名 [${default_user}]：" user
  user="${user:-$default_user}"
  read -r -p "监听端口 [${default_port}]：" port
  port="${port:-$default_port}"
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -le 65535 ]] || { error '端口必须在 1-65535 之间。'; return 1; }
  printf '\nWeb UI 密码方式：\n'
  printf '  1. 生成随机密码（默认，32 位十六进制）\n'
  printf '  2. 自定义密码（至少 12 位，建议 16 位以上）\n'
  read -r -p '请选择 [1-2，默认1]：' password_mode
  password_mode="${password_mode:-1}"
  case "$password_mode" in
    1)
      password="$(generate_web_ui_password)" || { error '生成随机密码失败。'; return 1; }
      [[ ${#password} -eq 32 ]] || { error '生成的随机密码长度异常。'; return 1; }
      printf '\n%s请保存随机 Web UI 密码：%s%s\n' "$YELLOW" "$password" "$RESET"
      ;;
    2)
      read_secret_with_length '设置 Web UI 密码（至少 12 位，仅允许字母、数字和 @%+=_,.!:-）' || return 1
      password="$REPLY"
      read_secret_with_length '再次输入 Web UI 密码' || return 1
      confirm="$REPLY"
      if [[ "$password" != "$confirm" || ${#password} -lt 12 ]] || ! valid_web_ui_value "$password"; then
        error '密码不匹配、长度不足或包含不支持的字符。'
        return 1
      fi
      ;;
    *) error '无效选项。'; return 1 ;;
  esac
  valid_web_ui_value "$user" || { error '用户名包含不支持的字符。'; return 1; }
  write_config "$(current_mode)" "$enabled" "$user" "$password" "$port"
}

start_web_ui() {
  local existing_password
  ensure_config
  if ! web_ui_enabled; then
    existing_password="$(config_value WEB_UI_PASSWORD)"
    if [[ -n "$existing_password" ]]; then
      info '将使用已保存的登录凭据启用 Web UI。'
      write_config "$(current_mode)" true "$(web_ui_user)" "$existing_password" "$(web_ui_port)"
    else
      info 'Web UI 当前未配置，先设置登录凭据。'
      configure_web_ui_credentials true || return 1
    fi
  fi
  case "$(current_mode)" in
    native)
      install_native_kopia || return 1
      write_native_service || return 1
      systemctl enable --now kopia-web-ui.service || { error 'Web UI 启动失败。请查看日志。'; return 1; }
      ;;
    docker)
      install_docker_kopia || return 1
      (cd "$INSTALL_DIR" && docker compose --profile web up -d) || { error 'Web UI 容器启动失败。'; return 1; }
      ;;
  esac
  success "Kopia Web UI 已启动：http://服务器IP:$(web_ui_port)"
}

stop_web_ui() {
  case "$(current_mode)" in
    native)
      systemctl disable --now kopia-web-ui.service 2>/dev/null || true
      ;;
    docker)
      [[ ! -f "$COMPOSE_FILE" ]] || (cd "$INSTALL_DIR" && docker compose --profile web stop 2>/dev/null || true)
      ;;
  esac
  ensure_config
  write_config "$(current_mode)" false "$(web_ui_user)" "$(config_value WEB_UI_PASSWORD)" "$(web_ui_port)"
  success 'Kopia Web UI 已停止，并设为默认不启用。'
}

web_ui_menu() {
  local selected
  printf '\n当前 Web UI：%s\n' "$(web_ui_enabled && printf '已启用' || printf '未启用')"
  printf '  1. 启用 Web UI\n'
  printf '  2. 停用 Web UI\n'
  printf '  3. 查看 Web UI 状态\n'
  printf '  4. 查看 Web UI 登录凭据\n'
  printf '  5. 修改 Web UI 登录凭据\n'
  printf '  0. 返回\n'
  read -r -p '请选择 [0-5，直接回车返回]：' selected
  case "$selected" in
    ''|0) return 0 ;;
    1) start_web_ui ;;
    2) stop_web_ui ;;
    3) show_web_ui_status ;;
    4) show_web_ui_credentials ;;
    5) modify_web_ui_credentials ;;
    *) error '无效选项。'; pause_menu; return 1 ;;
  esac
  pause_menu
}

show_web_ui_credentials() {
  local password
  ensure_config
  password="$(config_value WEB_UI_PASSWORD)"
  [[ -n "$password" ]] || { warn '尚未设置 Web UI 登录凭据。请先选择“启用并启动 Web UI”。'; return 0; }
  printf '\n%sWeb UI 登录凭据%s\n' "$BOLD" "$RESET"
  printf '登录地址：http://服务器IP:%s\n用户名：%s\n密码：已设置（默认不显示）\n' "$(web_ui_port)" "$(web_ui_user)"
  confirm_action '确认在当前终端显示明文密码？' || return 0
  printf '用户名：%s\n密码：%s\n' "$(web_ui_user)" "$password"
}

modify_web_ui_credentials() {
  local was_enabled
  ensure_config
  was_enabled=false
  web_ui_enabled && was_enabled=true
  configure_web_ui_credentials "$was_enabled" || return 1
  if [[ "$was_enabled" == true ]]; then
    info '正在应用新的 Web UI 登录凭据...'
    case "$(current_mode)" in
      native)
        write_native_service || return 1
        if systemctl is-active --quiet kopia-web-ui.service; then
          systemctl restart kopia-web-ui.service || { error 'Web UI 重启失败。'; return 1; }
        else
          systemctl enable --now kopia-web-ui.service || { error 'Web UI 启动失败。'; return 1; }
        fi
        ;;
      docker)
        require_docker || return 1
        [[ -f "$COMPOSE_FILE" ]] || write_compose_file
        (cd "$INSTALL_DIR" && docker compose --profile web up -d --force-recreate) || { error 'Web UI 容器重建失败。'; return 1; }
        ;;
    esac
    success 'Web UI 登录凭据已修改并生效。'
  else
    success 'Web UI 登录凭据已保存；Web UI 仍保持未启用。'
  fi
}

show_web_ui_status() {
  local state
  case "$(current_mode)" in
    native)
      state="$(systemctl is-active kopia-web-ui.service 2>/dev/null || true)"
      printf 'Web UI：%s\n端口：%s\n' "$(localize_service_state "$state")" "$(web_ui_port)"
      ;;
    docker)
      state="$(docker inspect --format '{{.State.Status}}' kopia-web-ui 2>/dev/null || true)"
      printf 'Web UI 容器：%s\n端口：%s\n' "$(localize_service_state "$state")" "$(web_ui_port)"
      ;;
  esac
}

show_logs() {
  case "$(current_mode)" in
    native) journalctl -u kopia-web-ui.service -n 160 --no-pager 2>&1 || true ;;
    docker) require_docker && docker logs --tail 160 kopia-web-ui 2>&1 || true ;;
  esac
}

show_status() {
  printf '\n%sKopia 状态%s\n' "$BOLD" "$RESET"
  printf 'Kopia：%s\nDocker：%s\nWeb UI：%s\n' \
    "$(kopia_runtime_status)" "$(docker_runtime_status)" "$(web_ui_runtime_status)"
  printf '仓库：%s\n配置方式：%s\n配置目录：%s\n' \
    "$(repository_config_status)" "${BLUE}$(localize_mode "$(current_mode)")${RESET}" "$INSTALL_DIR"
}

show_repository_status() { run_kopia_authenticated repository status; }

backup_local_config() {
  local archive item
  local -a backup_items=()
  install -d -m 0750 "$BACKUP_DIR"
  archive="${BACKUP_DIR}/kopiactl-config.$(timestamp).tar.gz"
  confirm_action "确认创建本地 Kopia 配置备份 ${archive}？" || { info '已取消。'; return 0; }
  for item in config cache kopiactl.env compose.yml; do
    [[ -e "${INSTALL_DIR}/${item}" ]] && backup_items+=("$item")
  done
  (( ${#backup_items[@]} > 0 )) || { error '没有可备份的本地 Kopia 配置。'; return 1; }
  tar -C "$INSTALL_DIR" -czf "$archive" "${backup_items[@]}" || { rm -f "$archive"; error '本地配置备份失败。'; return 1; }
  chmod 0600 "$archive"
  success "本地配置备份完成：${archive}"
}

remove_kopia_runtime() {
  case "$(current_mode)" in
    native)
      if ! command -v kopia >/dev/null 2>&1; then
        warn '原生 Kopia 当前未安装。'
        return 0
      fi
      stop_web_ui
      rm -f "$SERVICE_FILE"
      systemctl daemon-reload
      if command -v dpkg-query >/dev/null 2>&1 \
          && [[ "$(dpkg-query -W -f='${db:Status-Status}' kopia 2>/dev/null || true)" == installed ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y kopia || { error 'Kopia 软件包卸载失败。'; return 1; }
      else
        error '未检测到由 APT 安装的 Kopia；为避免误删手动安装的二进制，未执行删除。'
        return 1
      fi
      ;;
    docker)
      stop_web_ui
      if command -v docker >/dev/null 2>&1; then
        docker rm -f kopia-web-ui 2>/dev/null || true
        docker image rm "$KOPIA_IMAGE" 2>/dev/null || true
      else
        warn 'Docker 当前未安装；没有可移除的 Kopia 容器或镜像。'
      fi
      ;;
  esac
}

uninstall_kopia() {
  local mode
  mode="$(current_mode)"
  warn "将卸载 $(localize_mode "$mode") 的 Kopia 运行时，但保留 /opt/kopiactl 中的仓库配置和 KopiaCtl。"
  warn 'Cloudflare R2 中的仓库与快照不会被删除。'
  confirm_action '确认卸载 Kopia？' || { info '已取消。'; return 0; }
  remove_kopia_runtime || return 1
  success 'Kopia 已卸载；仓库配置与 KopiaCtl 管理菜单仍保留。'
}

remove_manager_files() {
  rm -f "$MANAGER_COMMAND" "$MANAGER_SCRIPT"
  rmdir "$MANAGER_DIR" 2>/dev/null || true
}

uninstall_manager() {
  warn '这将删除 kopiactl 命令和管理脚本，但不会修改 Kopia、仓库配置或远端快照。'
  confirm_action '确认卸载 KopiaCtl 管理菜单？' || { info '已取消。'; return 0; }
  remove_manager_files
  success 'KopiaCtl 管理菜单已卸载；Kopia 与仓库配置保持不变。'
}

uninstall_everything() {
  warn '这将卸载 Kopia 与 KopiaCtl，并停止 Web UI。'
  warn "这还将永久删除 ${INSTALL_DIR} 与 ${BACKUP_DIR} 中的本地配置、缓存和备份。"
  warn 'Cloudflare R2 中的仓库与快照不会被删除。'
  confirm_action '确认完全卸载 Kopia 和 KopiaCtl？此操作不可恢复。' || { info '已取消。'; return 0; }
  remove_kopia_runtime || return 1
  rm -f /etc/apt/sources.list.d/kopia.list /usr/share/keyrings/kopia-keyring.gpg "$SERVICE_FILE"
  systemctl daemon-reload
  remove_manager_files
  rm -rf -- "$INSTALL_DIR" "$BACKUP_DIR"
  FULL_UNINSTALL_DONE=true
  success 'Kopia、KopiaCtl、本地配置和备份均已删除；R2 远端快照未受影响。'
}

uninstall_menu() {
  local choice
  printf '\n%s请选择卸载内容%s\n' "$BOLD" "$RESET"
  printf '  1. 卸载 Kopia（保留配置、仓库和 KopiaCtl）\n'
  printf '  2. 卸载 KopiaCtl 管理菜单（保留 Kopia 与配置）\n'
  printf '  3. 完全卸载 Kopia 和 KopiaCtl（删除本地配置和备份，不删除远端 R2 快照）\n'
  printf '  0. 返回\n'
  read -r -p '请选择 [0-3]：' choice
  case "$choice" in
    1) uninstall_kopia ;;
    2) uninstall_manager ;;
    3) uninstall_everything ;;
    0) return 0 ;;
    *) error '无效选项。'; return 1 ;;
  esac
}

docker_runtime_status() {
  if ! command -v docker >/dev/null 2>&1; then
    printf '%sDocker 未安装%s' "$RED" "$RESET"
  elif docker info >/dev/null 2>&1; then
    printf '%sDocker 已就绪%s' "$GREEN" "$RESET"
  else
    printf '%sDocker 服务不可用%s' "$RED" "$RESET"
  fi
}

docker_kopia_image_status() {
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s未安装（Docker 未安装）%s' "$RED" "$RESET"
  elif ! docker info >/dev/null 2>&1; then
    printf '%s未安装（Docker 服务不可用）%s' "$RED" "$RESET"
  elif docker image inspect "$KOPIA_IMAGE" >/dev/null 2>&1; then
    printf '%sDocker 镜像已安装%s' "$GREEN" "$RESET"
  else
    printf '%sDocker 已就绪，镜像未下载%s' "$YELLOW" "$RESET"
  fi
}

kopia_runtime_status() {
  case "$(current_mode)" in
    native)
      if command -v kopia >/dev/null 2>&1; then
        printf '%s原生已安装%s' "$GREEN" "$RESET"
      else
        printf '%s未安装%s' "$RED" "$RESET"
      fi
      ;;
    docker) printf '%s' "$(docker_kopia_image_status)" ;;
  esac
}

web_ui_runtime_status() {
  local state
  if ! web_ui_enabled; then
    printf '%s未启用%s' "$YELLOW" "$RESET"
    return
  fi
  case "$(current_mode)" in
    native)
      state="$(systemctl is-active kopia-web-ui.service 2>/dev/null || true)"
      case "$state" in
        active) printf '%s运行中%s' "$GREEN" "$RESET" ;;
        failed) printf '%s启动失败%s' "$RED" "$RESET" ;;
        *) printf '%s已启用，未运行%s' "$YELLOW" "$RESET" ;;
      esac
      ;;
    docker)
      state="$(docker inspect --format '{{.State.Status}}' kopia-web-ui 2>/dev/null || true)"
      case "$state" in
        running) printf '%s运行中%s' "$GREEN" "$RESET" ;;
        exited|dead) printf '%s异常停止%s' "$RED" "$RESET" ;;
        *) printf '%s已启用，未运行%s' "$YELLOW" "$RESET" ;;
      esac
      ;;
  esac
}

repository_config_status() {
  if [[ -f "$KOPIA_CONFIG_FILE" ]]; then
    printf '%s已配置%s' "$GREEN" "$RESET"
  else
    printf '%s未配置%s' "$YELLOW" "$RESET"
  fi
}

status_line() {
  printf 'Kopia：%s | Web UI：%s\n' "$(kopia_runtime_status)" "$(web_ui_runtime_status)"
  printf 'Docker：%s | 配置方式：%s\n' \
    "$(docker_runtime_status)" "${BLUE}$(localize_mode "$(current_mode)")${RESET}"
  printf '仓库：%s\n' "$(repository_config_status)"
  printf 'KopiaCtl 版本：%s\n' "$MANAGER_VERSION"
}

draw_menu() {
  clear 2>/dev/null || true
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '%s          KopiaCtl · Kopia 管理菜单%s\n' "$BOLD" "$RESET"
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  status_line
  printf '%s--------------------------------------------%s\n' "$BLUE" "$RESET"
  printf '  1. 更新 KopiaCtl 管理菜单\n'
  printf '  2. 查看运行状态\n'
  printf '  3. 安装 Kopia（原生 / Docker）\n'
  printf '  4. 配置 Cloudflare R2 仓库\n'
  printf '  5. 查看仓库状态\n'
  printf '  6. 创建快照备份\n'
  printf '  7. 查看快照列表\n'
  printf '  8. 查询快照并恢复\n'
  printf '  9. Web UI 管理\n'
  printf ' 10. 查看 Web UI 日志\n'
  printf ' 11. 备份本地 Kopia 配置\n'
  printf ' 12. 卸载 Kopia 或 KopiaCtl\n'
  printf '  0. 退出\n'
  printf '%s============================================%s\n' "$BLUE" "$RESET"
  printf '提示：默认原生安装、Cloudflare R2 仓库、Web UI 关闭。\n'
  printf '提示：退出后可在终端输入 kopiactl 再次打开本菜单。\n'
}

main_menu() {
  local choice
  ensure_config
  while true; do
    draw_menu
    read -r -p '请选择 [0-12]：' choice || exit 0
    printf '\n'
    case "$choice" in
      1)
        update_manager
        pause_menu
        [[ "$MANAGER_UPDATED" != true ]] || exec "$MANAGER_SCRIPT"
        ;;
      2) show_status; pause_menu ;;
      3) choose_install_mode; pause_menu ;;
      4) configure_r2_repository; pause_menu ;;
      5) show_repository_status; pause_menu ;;
      6) create_snapshot; pause_menu ;;
      7) list_snapshots; pause_menu ;;
      8) restore_snapshot; pause_menu ;;
      9) web_ui_menu ;;
      10) show_logs; pause_menu ;;
      11) backup_local_config; pause_menu ;;
      12)
        uninstall_menu
        if [[ "$FULL_UNINSTALL_DONE" == true ]]; then
          printf '\n'
          read -r -p '完全卸载已完成，按回车键退出...' _ || true
          exit 0
        fi
        pause_menu
        ;;
      0) exit 0 ;;
      *) warn '无效选项。'; pause_menu ;;
    esac
  done
}

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then show_command_usage; exit 0; fi
if [[ $# -eq 1 && "$1" == --install-manager ]]; then require_root "$@"; install_manager_command; success 'KopiaCtl 管理菜单已安装。'; main_menu; exit 0; fi
[[ $# -eq 0 ]] || { show_command_usage; exit 2; }
require_root "$@"
main_menu
