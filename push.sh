#!/usr/bin/env bash
set -euo pipefail

# Unified push service installer/manager for Debian/Ubuntu VPS
# Supports exactly one active push backend at a time: gotify OR ntfy
# Unified root: /root/push
# - Docker Compose deployment
# - Nginx reverse proxy
# - Reuses DOMAIN from /root/.asset_manager_install.conf when present
# - Cert path style: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
# - Public firewall port auto-open where possible

PUSH_ROOT="/root/push"
STATE_FILE="${PUSH_ROOT}/push_install.conf"
ISM_STATE_FILE="/root/.asset_manager_install.conf"

SERVICE_TYPE=""          # gotify / ntfy
SERVICE_NAME="push"
CONTAINER_NAME="push"
DOMAIN=""
INTERNAL_PORT="8083"
PUBLIC_PORT="2085"
BASE_URL=""
ENABLE_AUTH="true"
ADMIN_USER="admin"
ADMIN_PASS=""
DEFAULT_TOPIC="traffic"
DEFAULT_PRIORITY="1"
DEFAULT_TAGS=""

COMPOSE_FILE="${PUSH_ROOT}/docker-compose.yml"
NGINX_SITE_FILE="/etc/nginx/sites-available/${SERVICE_NAME}_${PUBLIC_PORT}.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${SERVICE_NAME}_${PUBLIC_PORT}.conf"

# gotify paths
GOTIFY_DATA_DIR="${PUSH_ROOT}/gotify/data"

# ntfy paths
NTFY_CACHE_DIR="${PUSH_ROOT}/ntfy/cache"
NTFY_ETC_DIR="${PUSH_ROOT}/ntfy/etc"
NTFY_LIB_DIR="${PUSH_ROOT}/ntfy/lib"
NTFY_ATTACH_DIR="${NTFY_LIB_DIR}/attachments"
NTFY_SERVER_FILE="${NTFY_ETC_DIR}/server.yml"

NC='\033[0m'
BOLD='\033[1m'
GREEN='\033[92m'
YELLOW='\033[93m'
RED='\033[91m'
CYAN='\033[96m'
BLUE='\033[94m'
MAGENTA='\033[95m'
WHITE='\033[97m'

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
cyan() { printf '\033[36m%s\033[0m\n' "$*"; }

info() { cyan "[INFO] $*"; }
ok() { green "[OK] $*"; }
warn() { yellow "[WARN] $*"; }
err() { red "[ERR] $*"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 运行：sudo bash push.sh"
        exit 1
    fi
}

read_input() {
    local prompt="$1"
    local __var="$2"
    local value=""
    if [ -t 0 ] && [ -n "${BASH_VERSION:-}" ]; then
        read -e -r -p "$prompt" value
    else
        read -r -p "$prompt" value
    fi
    printf -v "$__var" '%s' "$value"
}

is_delete_input() {
    case "${1:-}" in
        DELETE|delete|Delete|DEL|del|删除|清空|移除) return 0 ;;
        *) return 1 ;;
    esac
}

apply_text_input() {
    local var_name="$1"
    local input_value="${2:-}"
    if is_delete_input "$input_value"; then
        printf -v "$var_name" '%s' ""
    elif [ -n "$input_value" ]; then
        printf -v "$var_name" '%s' "$input_value"
    fi
}

apply_defaultable_input() {
    local var_name="$1"
    local input_value="${2:-}"
    local default_value="$3"
    if is_delete_input "$input_value"; then
        printf -v "$var_name" '%s' "$default_value"
    elif [ -n "$input_value" ]; then
        printf -v "$var_name" '%s' "$input_value"
    fi
}

validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        err "端口无效：${port}，请输入 1-65535 之间的数字"
        return 1
    fi
}

validate_priority() {
    local priority="$1"
    if ! [[ "$priority" =~ ^[1-5]$ ]]; then
        err "优先级无效：${priority}，请输入 1-5"
        return 1
    fi
}

get_host_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

wait_for_port() {
    local port="$1"
    local tries="${2:-15}"
    local i
    for i in $(seq 1 "$tries"); do
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        return 1
    fi
}

load_ism_domain_once() {
    if [ -z "${DOMAIN:-}" ] && [ -f "$ISM_STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$ISM_STATE_FILE" || true
        : "${DOMAIN:=}"
    fi
}

set_defaults_for_service() {
    case "${SERVICE_TYPE:-}" in
        gotify)
            INTERNAL_PORT="${INTERNAL_PORT:-8082}"
            PUBLIC_PORT="${PUBLIC_PORT:-2084}"
            ADMIN_USER="${ADMIN_USER:-admin}"
            DEFAULT_PRIORITY="${DEFAULT_PRIORITY:-5}"
            ;;
        ntfy)
            INTERNAL_PORT="${INTERNAL_PORT:-8083}"
            PUBLIC_PORT="${PUBLIC_PORT:-2085}"
            ADMIN_USER="${ADMIN_USER:-admin}"
            DEFAULT_TOPIC="${DEFAULT_TOPIC:-traffic}"
            DEFAULT_PRIORITY="${DEFAULT_PRIORITY:-1}"
            ;;
        *)
            INTERNAL_PORT="${INTERNAL_PORT:-8083}"
            PUBLIC_PORT="${PUBLIC_PORT:-2085}"
            ADMIN_USER="${ADMIN_USER:-admin}"
            DEFAULT_TOPIC="${DEFAULT_TOPIC:-traffic}"
            DEFAULT_PRIORITY="${DEFAULT_PRIORITY:-1}"
            ;;
    esac
}

refresh_paths() {
    COMPOSE_FILE="${PUSH_ROOT}/docker-compose.yml"
    NGINX_SITE_FILE="/etc/nginx/sites-available/${SERVICE_NAME}_${PUBLIC_PORT}.conf"
    NGINX_SITE_LINK="/etc/nginx/sites-enabled/${SERVICE_NAME}_${PUBLIC_PORT}.conf"
    GOTIFY_DATA_DIR="${PUSH_ROOT}/gotify/data"
    NTFY_CACHE_DIR="${PUSH_ROOT}/ntfy/cache"
    NTFY_ETC_DIR="${PUSH_ROOT}/ntfy/etc"
    NTFY_LIB_DIR="${PUSH_ROOT}/ntfy/lib"
    NTFY_ATTACH_DIR="${NTFY_LIB_DIR}/attachments"
    NTFY_SERVER_FILE="${NTFY_ETC_DIR}/server.yml"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE" || true
    else
        load_ism_domain_once
    fi
    : "${PUSH_ROOT:=/root/push}"
    : "${SERVICE_TYPE:=}"
    : "${SERVICE_NAME:=push}"
    : "${CONTAINER_NAME:=push}"
    : "${DOMAIN:=}"
    : "${INTERNAL_PORT:=8083}"
    : "${PUBLIC_PORT:=2085}"
    : "${BASE_URL:=}"
    : "${ENABLE_AUTH:=true}"
    : "${ADMIN_USER:=admin}"
    : "${ADMIN_PASS:=}"
    : "${DEFAULT_TOPIC:=traffic}"
    : "${DEFAULT_PRIORITY:=1}"
    : "${DEFAULT_TAGS:=}"
    set_defaults_for_service
    refresh_paths
}

save_state() {
    mkdir -p "$PUSH_ROOT"
    cat > "$STATE_FILE" <<EOF_STATE
PUSH_ROOT=${PUSH_ROOT@Q}
SERVICE_TYPE=${SERVICE_TYPE@Q}
SERVICE_NAME=${SERVICE_NAME@Q}
CONTAINER_NAME=${CONTAINER_NAME@Q}
DOMAIN=${DOMAIN@Q}
INTERNAL_PORT=${INTERNAL_PORT@Q}
PUBLIC_PORT=${PUBLIC_PORT@Q}
BASE_URL=${BASE_URL@Q}
ENABLE_AUTH=${ENABLE_AUTH@Q}
ADMIN_USER=${ADMIN_USER@Q}
ADMIN_PASS=${ADMIN_PASS@Q}
DEFAULT_TOPIC=${DEFAULT_TOPIC@Q}
DEFAULT_PRIORITY=${DEFAULT_PRIORITY@Q}
DEFAULT_TAGS=${DEFAULT_TAGS@Q}
EOF_STATE
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

refresh_base_url() {
    if [ -n "${DOMAIN:-}" ]; then
        if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
            BASE_URL="https://${DOMAIN}:${PUBLIC_PORT}"
        else
            BASE_URL="http://${DOMAIN}:${PUBLIC_PORT}"
        fi
    else
        local ip
        ip="$(get_host_ip || true)"
        BASE_URL="http://${ip:-服务器IP}:${PUBLIC_PORT}"
    fi
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    info "安装依赖：Docker / Docker Compose / Nginx / curl / ca-certificates"
    apt-get update
    apt-get install -y nginx curl ca-certificates gnupg lsb-release openssl

    if ! command -v docker >/dev/null 2>&1; then
        warn "未检测到 Docker，使用系统仓库安装 docker.io"
        apt-get install -y docker.io
    fi

    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        warn "未检测到 Docker Compose，尝试安装 docker-compose-plugin / docker-compose"
        apt-get install -y docker-compose-plugin || apt-get install -y docker-compose
    fi

    systemctl enable --now docker
    systemctl enable --now nginx
    ok "依赖安装完成"
}

open_firewall_port() {
    local port="$1"
    validate_port "$port" || return 1
    info "尝试自动放行防火墙端口：${port}/tcp"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || warn "ufw 放行 ${port}/tcp 失败，请手动检查"
        ok "ufw 已放行 ${port}/tcp"
        return 0
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || warn "firewalld 永久放行 ${port}/tcp 失败"
        firewall-cmd --reload >/dev/null 2>&1 || warn "firewalld reload 失败"
        ok "firewalld 已放行 ${port}/tcp"
        return 0
    fi

    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || warn "iptables 放行 ${port}/tcp 失败，请手动检查"
        fi
        ok "iptables 当前会话已放行 ${port}/tcp"
        return 0
    fi

    warn "未检测到 ufw/firewalld/iptables，若云厂商安全组或系统防火墙拦截，请手动放行 ${port}/tcp"
}

close_firewall_port() {
    local port="$1"
    validate_port "$port" || return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    fi
}

stop_existing_service() {
    load_state
    local cmd
    cmd="$(compose_cmd || true)"
    if [ -n "${cmd:-}" ] && [ -f "$COMPOSE_FILE" ]; then
        info "停止当前容器：${CONTAINER_NAME}"
        (cd "$PUSH_ROOT" && $cmd down) || true
    fi
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

select_service_type() {
    load_state
    echo "请选择推送服务（二选一，同一时间只运行一个）："
    echo "1) gotify"
    echo "2) ntfy"
    echo "当前：${SERVICE_TYPE:-未设置}"
    local choice
    read_input "选择 [1-2，回车保持当前]: " choice
    if [ -n "${choice:-}" ]; then
        case "$choice" in
            1|gotify|Gotify|GOTIFY) SERVICE_TYPE="gotify" ;;
            2|ntfy|Ntfy|NTFY) SERVICE_TYPE="ntfy" ;;
            *) warn "无效选择，保持当前：${SERVICE_TYPE:-未设置}" ;;
        esac
    fi
    if [ -z "${SERVICE_TYPE:-}" ]; then
        SERVICE_TYPE="ntfy"
        warn "未选择服务，默认使用 ntfy"
    fi

    # unified service/container/nginx prefix
    SERVICE_NAME="push"
    CONTAINER_NAME="push"
    case "$SERVICE_TYPE" in
        gotify)
            [ "${INTERNAL_PORT:-8083}" = "8083" ] && INTERNAL_PORT="8082"
            [ "${PUBLIC_PORT:-2085}" = "2085" ] && PUBLIC_PORT="2084"
            DEFAULT_PRIORITY="${DEFAULT_PRIORITY:-5}"
            ;;
        ntfy)
            [ "${INTERNAL_PORT:-8082}" = "8082" ] && INTERNAL_PORT="8083"
            [ "${PUBLIC_PORT:-2084}" = "2084" ] && PUBLIC_PORT="2085"
            DEFAULT_TOPIC="${DEFAULT_TOPIC:-traffic}"
            DEFAULT_PRIORITY="${DEFAULT_PRIORITY:-1}"
            ;;
    esac
    refresh_paths
}

prompt_common_config() {
    load_state
    select_service_type
    echo
    echo "统一 Push 基础配置："
    echo "工作目录：${PUSH_ROOT}"
    echo "服务类型：${SERVICE_TYPE}"
    echo "输入 DELETE / 删除 / 清空 可以清空文本项；端口/优先级会恢复默认。"
    echo

    local input_domain input_public_port input_internal_port input_user input_pass input_topic input_priority input_tags input_auth

    read_input "请输入域名 [${DOMAIN:-可留空用 IP}]: " input_domain
    apply_text_input DOMAIN "${input_domain:-}"

    if [ "$SERVICE_TYPE" = "gotify" ]; then
        read_input "请输入外部访问端口 [${PUBLIC_PORT}]，DELETE=恢复 2084: " input_public_port
        apply_defaultable_input PUBLIC_PORT "${input_public_port:-}" "2084"
        read_input "请输入本机内部端口 [${INTERNAL_PORT}]，DELETE=恢复 8082: " input_internal_port
        apply_defaultable_input INTERNAL_PORT "${input_internal_port:-}" "8082"
    else
        read_input "请输入外部访问端口 [${PUBLIC_PORT}]，DELETE=恢复 2085: " input_public_port
        apply_defaultable_input PUBLIC_PORT "${input_public_port:-}" "2085"
        read_input "请输入本机内部端口 [${INTERNAL_PORT}]，DELETE=恢复 8083: " input_internal_port
        apply_defaultable_input INTERNAL_PORT "${input_internal_port:-}" "8083"
    fi
    validate_port "$PUBLIC_PORT"
    validate_port "$INTERNAL_PORT"

    read_input "请输入管理员用户名 [${ADMIN_USER:-admin}]，DELETE=恢复 admin: " input_user
    apply_defaultable_input ADMIN_USER "${input_user:-}" "admin"

    read_input "请输入管理员密码 [${ADMIN_PASS:+已设置，回车保持}]，DELETE=重新生成: " input_pass
    if is_delete_input "${input_pass:-}"; then
        ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    elif [ -n "${input_pass:-}" ]; then
        ADMIN_PASS="$input_pass"
    elif [ -z "${ADMIN_PASS:-}" ]; then
        ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    fi

    if [ "$SERVICE_TYPE" = "ntfy" ]; then
        read_input "请输入默认 Topic [${DEFAULT_TOPIC:-traffic}]，DELETE=恢复 traffic: " input_topic
        apply_defaultable_input DEFAULT_TOPIC "${input_topic:-}" "traffic"
        read_input "请输入默认优先级 1-5 [${DEFAULT_PRIORITY:-1}]，DELETE=恢复 1: " input_priority
        apply_defaultable_input DEFAULT_PRIORITY "${input_priority:-}" "1"
        validate_priority "$DEFAULT_PRIORITY"
        read_input "请输入默认 Tags [${DEFAULT_TAGS:-空}]，DELETE=清空: " input_tags
        apply_text_input DEFAULT_TAGS "${input_tags:-}"
        read_input "是否开启登录认证？[${ENABLE_AUTH:-true}]，输入 false/0/否/DELETE=关闭: " input_auth
        if [ -n "${input_auth:-}" ]; then
            case "$input_auth" in
                true|TRUE|1|yes|YES|y|Y|是|开启) ENABLE_AUTH="true" ;;
                false|FALSE|0|no|NO|n|N|否|关闭|DELETE|delete|删除|清空) ENABLE_AUTH="false" ;;
                *) warn "认证输入无法识别，保持：${ENABLE_AUTH}" ;;
            esac
        fi
    else
        read_input "请输入默认优先级 1-10 [${DEFAULT_PRIORITY:-5}]，DELETE=恢复 5: " input_priority
        apply_defaultable_input DEFAULT_PRIORITY "${input_priority:-}" "5"
        if ! [[ "$DEFAULT_PRIORITY" =~ ^[0-9]+$ ]]; then
            DEFAULT_PRIORITY="5"
        fi
        ENABLE_AUTH="true"
    fi

    refresh_base_url
    save_state
    ok "配置已保存：${STATE_FILE}"
}

write_gotify_compose() {
    mkdir -p "$PUSH_ROOT" "$GOTIFY_DATA_DIR"
    cat > "$COMPOSE_FILE" <<EOF_COMPOSE
services:
  ${CONTAINER_NAME}:
    image: gotify/server:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${INTERNAL_PORT}:80"
    environment:
      - TZ=Asia/Shanghai
      - GOTIFY_DEFAULTUSER_NAME=${ADMIN_USER}
      - GOTIFY_DEFAULTUSER_PASS=${ADMIN_PASS}
      - GOTIFY_REGISTRATION=false
      - GOTIFY_SERVER_PORT=80
    volumes:
      - ./gotify/data:/app/data
EOF_COMPOSE
    ok "Gotify Docker Compose 已写入：${COMPOSE_FILE}"
}

write_ntfy_server_config() {
    mkdir -p "$NTFY_ETC_DIR" "$NTFY_CACHE_DIR" "$NTFY_LIB_DIR" "$NTFY_ATTACH_DIR"
    refresh_base_url
    if [ "${ENABLE_AUTH}" = "true" ]; then
        cat > "$NTFY_SERVER_FILE" <<EOF_SERVER_AUTH
base-url: "${BASE_URL}"
listen-http: ":80"
behind-proxy: true
cache-file: "/var/cache/ntfy/cache.db"
auth-file: "/var/lib/ntfy/auth.db"
auth-default-access: "deny-all"
enable-login: true
attachment-cache-dir: "/var/lib/ntfy/attachments"
attachment-total-size-limit: "1G"
attachment-file-size-limit: "20M"
attachment-expiry-duration: "24h"
EOF_SERVER_AUTH
    else
        cat > "$NTFY_SERVER_FILE" <<EOF_SERVER_OPEN
base-url: "${BASE_URL}"
listen-http: ":80"
behind-proxy: true
cache-file: "/var/cache/ntfy/cache.db"
auth-default-access: "read-write"
enable-login: false
attachment-cache-dir: "/var/lib/ntfy/attachments"
attachment-total-size-limit: "1G"
attachment-file-size-limit: "20M"
attachment-expiry-duration: "24h"
EOF_SERVER_OPEN
    fi
    ok "ntfy server.yml 已写入：${NTFY_SERVER_FILE}"
}

write_ntfy_compose() {
    mkdir -p "$PUSH_ROOT" "$NTFY_CACHE_DIR" "$NTFY_ETC_DIR" "$NTFY_LIB_DIR" "$NTFY_ATTACH_DIR"
    cat > "$COMPOSE_FILE" <<EOF_COMPOSE
services:
  ${CONTAINER_NAME}:
    image: binwiederhier/ntfy:latest
    container_name: ${CONTAINER_NAME}
    command:
      - serve
    restart: unless-stopped
    ports:
      - "127.0.0.1:${INTERNAL_PORT}:80"
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./ntfy/cache:/var/cache/ntfy
      - ./ntfy/etc:/etc/ntfy
      - ./ntfy/lib:/var/lib/ntfy
EOF_COMPOSE
    ok "ntfy Docker Compose 已写入：${COMPOSE_FILE}"
}

write_compose_for_service() {
    case "$SERVICE_TYPE" in
        gotify) write_gotify_compose ;;
        ntfy) write_ntfy_server_config; write_ntfy_compose ;;
        *) err "未设置服务类型"; return 1 ;;
    esac
}

start_container() {
    local cmd
    cmd="$(compose_cmd)"
    info "启动 ${SERVICE_TYPE} 容器：${CONTAINER_NAME}"
    (cd "$PUSH_ROOT" && $cmd up -d)
    if wait_for_port "$INTERNAL_PORT" 30; then
        ok "${SERVICE_TYPE} 已监听 127.0.0.1:${INTERNAL_PORT}"
    else
        warn "暂未检测到 ${INTERNAL_PORT} 端口监听，请执行：cd ${PUSH_ROOT} && ${cmd} logs --tail=100 ${CONTAINER_NAME}"
    fi
}

ensure_ntfy_admin_user() {
    load_state
    [ "$SERVICE_TYPE" = "ntfy" ] || return 0
    [ "${ENABLE_AUTH}" = "true" ] || return 0
    [ -n "${ADMIN_USER:-}" ] && [ -n "${ADMIN_PASS:-}" ] || { warn "未设置管理员账号或密码，跳过用户创建"; return 0; }

    info "创建/更新 ntfy 管理员账号：${ADMIN_USER}"
    if docker exec -i "$CONTAINER_NAME" ntfy user add --role=admin "$ADMIN_USER" >/tmp/push_ntfy_user_add.out 2>&1 <<EOF_PASS
${ADMIN_PASS}
${ADMIN_PASS}
EOF_PASS
    then
        ok "管理员账号已创建：${ADMIN_USER}"
    else
        if grep -qiE "already exists|exists|duplicate" /tmp/push_ntfy_user_add.out 2>/dev/null; then
            if docker exec -i "$CONTAINER_NAME" ntfy user change-pass "$ADMIN_USER" >/tmp/push_ntfy_user_pass.out 2>&1 <<EOF_PASS2
${ADMIN_PASS}
${ADMIN_PASS}
EOF_PASS2
            then
                ok "管理员密码已更新：${ADMIN_USER}"
            else
                warn "账号已存在，但自动更新密码失败。可手动执行：docker exec -it ${CONTAINER_NAME} ntfy user change-pass ${ADMIN_USER}"
                cat /tmp/push_ntfy_user_pass.out 2>/dev/null || true
            fi
        else
            warn "自动创建管理员失败。可手动执行：docker exec -it ${CONTAINER_NAME} ntfy user add --role=admin ${ADMIN_USER}"
            cat /tmp/push_ntfy_user_add.out 2>/dev/null || true
        fi
    fi
}

write_nginx_http() {
    cat > "$NGINX_SITE_FILE" <<EOF_NGINX_HTTP
server {
    listen ${PUBLIC_PORT};
    server_name ${DOMAIN:-_};

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 60;
        proxy_send_timeout 300;
    }
}
EOF_NGINX_HTTP
}

write_nginx_https() {
    local cert_dir="/etc/letsencrypt/live/${DOMAIN}"
    cat > "$NGINX_SITE_FILE" <<EOF_NGINX_HTTPS
server {
    listen ${PUBLIC_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 60;
        proxy_send_timeout 300;
    }
}
EOF_NGINX_HTTPS
}

configure_nginx() {
    load_state
    refresh_paths
    info "配置 Nginx 反向代理"
    rm -f /etc/nginx/sites-enabled/${SERVICE_NAME}_*.conf /etc/nginx/sites-available/${SERVICE_NAME}_*.conf 2>/dev/null || true
    if [ -n "${DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
        write_nginx_https
        BASE_URL="https://${DOMAIN}:${PUBLIC_PORT}"
        ok "检测到证书，已配置 ${BASE_URL}"
    else
        write_nginx_http
        if [ -n "${DOMAIN:-}" ]; then
            BASE_URL="http://${DOMAIN}:${PUBLIC_PORT}"
            warn "未找到 /etc/letsencrypt/live/${DOMAIN}/ 证书，已配置为 ${BASE_URL}"
        else
            local ip
            ip="$(get_host_ip || true)"
            BASE_URL="http://${ip:-服务器IP}:${PUBLIC_PORT}"
            warn "未填写域名，已配置为 ${BASE_URL}"
        fi
    fi

    ln -sf "$NGINX_SITE_FILE" "$NGINX_SITE_LINK"
    nginx -t
    systemctl restart nginx
    sleep 1
    open_firewall_port "$PUBLIC_PORT" || true
    save_state

    if [ "$SERVICE_TYPE" = "ntfy" ]; then
        write_ntfy_server_config
        local cmd
        cmd="$(compose_cmd || true)"
        if [ -n "${cmd:-}" ] && [ -f "$COMPOSE_FILE" ]; then
            (cd "$PUSH_ROOT" && $cmd restart "$CONTAINER_NAME") || true
        fi
    fi

    if wait_for_port "$PUBLIC_PORT" 10; then
        ok "Nginx 配置完成，已监听端口 ${PUBLIC_PORT}"
    else
        warn "Nginx 已重启，但暂未检测到 ${PUBLIC_PORT} 端口监听，请执行：systemctl status nginx --no-pager"
    fi
}

install_all() {
    load_state
    install_dependencies
    prompt_common_config
    stop_existing_service
    write_compose_for_service
    start_container
    ensure_ntfy_admin_user
    configure_nginx
    print_access_info
}

restart_service() {
    load_state
    local cmd
    cmd="$(compose_cmd)"
    info "重启 ${SERVICE_TYPE}"
    (cd "$PUSH_ROOT" && $cmd restart "$CONTAINER_NAME")
    systemctl restart nginx
    ok "${SERVICE_TYPE} 和 Nginx 已重启"
}

show_status() {
    load_state
    local cmd
    cmd="$(compose_cmd || true)"
    echo "Push 服务状态"
    echo "  服务类型：${SERVICE_TYPE:-未设置}"
    echo "  统一目录：${PUSH_ROOT}"
    echo "  Compose：${COMPOSE_FILE}"
    echo "  状态配置：${STATE_FILE}"
    echo "  域名：${DOMAIN:-未设置}"
    echo "  内部端口：127.0.0.1:${INTERNAL_PORT}"
    echo "  外部端口：${PUBLIC_PORT}"
    echo "  访问地址：${BASE_URL:-未生成}"
    echo "  管理员账号：${ADMIN_USER:-未设置}"
    if [ "$SERVICE_TYPE" = "ntfy" ]; then
        echo "  默认 Topic：${DEFAULT_TOPIC}"
        echo "  默认优先级：${DEFAULT_PRIORITY}"
        echo "  默认 Tags：${DEFAULT_TAGS:-未设置}"
        echo "  登录认证：${ENABLE_AUTH}"
        echo "  ntfy 配置：${NTFY_SERVER_FILE}"
        echo "  ntfy 数据目录：${NTFY_LIB_DIR}"
    elif [ "$SERVICE_TYPE" = "gotify" ]; then
        echo "  Gotify 数据目录：${GOTIFY_DATA_DIR}"
    fi
    echo "  Nginx 配置：${NGINX_SITE_FILE}"
    echo

    if [ -n "$cmd" ] && [ -f "$COMPOSE_FILE" ]; then
        (cd "$PUSH_ROOT" && $cmd ps) || true
    else
        warn "未检测到 Compose 文件或 Docker Compose"
    fi

    echo
    echo "端口监听："
    ss -lntp 2>/dev/null | grep -E ":(${INTERNAL_PORT}|${PUBLIC_PORT})\b" || true
}

print_access_info() {
    load_state
    local local_base_url
    local_base_url="http://127.0.0.1:${INTERNAL_PORT}"
    echo
    printf "${BOLD}${GREEN}Push 服务部署/配置完成${NC}\n"
    echo
    echo "====== 基本配置 ======"
    echo "服务类型：${SERVICE_TYPE}"
    echo "统一目录：${PUSH_ROOT}"
    echo "外部访问地址：${BASE_URL}"
    echo "本机推送地址：${local_base_url}"
    echo "管理员账号：${ADMIN_USER}"
    echo "管理员密码：${ADMIN_PASS}"
    echo
    echo "====== 端口配置 ======"
    echo "容器内部端口：80"
    echo "本机内部映射：127.0.0.1:${INTERNAL_PORT}"
    echo "Nginx 外部端口：${PUBLIC_PORT}"
    echo "防火墙放行端口：${PUBLIC_PORT}/tcp（脚本已尝试自动放行）"
    echo
    echo "====== 本地路径 ======"
    echo "状态配置：${STATE_FILE}"
    echo "Docker Compose：${COMPOSE_FILE}"
    echo "Nginx 反代配置：${NGINX_SITE_FILE}"
    if [ "$SERVICE_TYPE" = "gotify" ]; then
        echo "Gotify 数据目录：${GOTIFY_DATA_DIR}"
        echo
        echo "====== Gotify 配置片段 ======"
        cat <<EOF_GOTIFY_CFG
{
  "notice_type": "gotify",
  "gotify_url": "${local_base_url}/",
  "gotify_token": "你的 Application Token",
  "gotify_priority": ${DEFAULT_PRIORITY}
}
EOF_GOTIFY_CFG
        echo
        echo "提示：Gotify 需要登录 Web 后创建 Application，再复制 Application Token 给推送程序。"
    else
        echo "ntfy server.yml：${NTFY_SERVER_FILE}"
        echo "ntfy 缓存目录：${NTFY_CACHE_DIR}"
        echo "ntfy 数据目录：${NTFY_LIB_DIR}"
        echo "ntfy 附件目录：${NTFY_ATTACH_DIR}"
        echo
        echo "====== ntfy 配置片段：本机程序推荐 ======" 
        if [ "${ENABLE_AUTH}" = "true" ]; then
            cat <<EOF_NTFY_LOCAL_AUTH
{
  "notice_type": "ntfy",
  "ntfy_url": "${local_base_url}",
  "ntfy_topic": "${DEFAULT_TOPIC}",
  "ntfy_username": "${ADMIN_USER}",
  "ntfy_password": "${ADMIN_PASS}",
  "ntfy_priority": ${DEFAULT_PRIORITY},
  "ntfy_tags": "${DEFAULT_TAGS}"
}
EOF_NTFY_LOCAL_AUTH
        else
            cat <<EOF_NTFY_LOCAL_OPEN
{
  "notice_type": "ntfy",
  "ntfy_url": "${local_base_url}",
  "ntfy_topic": "${DEFAULT_TOPIC}",
  "ntfy_priority": ${DEFAULT_PRIORITY},
  "ntfy_tags": "${DEFAULT_TAGS}"
}
EOF_NTFY_LOCAL_OPEN
        fi
    fi
}

test_gotify_push() {
    load_state
    local app_token title message priority url
    read_input "请输入 Gotify Application Token: " app_token
    if [ -z "${app_token:-}" ]; then
        err "Application Token 不能为空"
        return 1
    fi
    read_input "请输入推送标题 [Push Gotify 测试]: " title
    title="${title:-Push Gotify 测试}"
    read_input "请输入优先级 [${DEFAULT_PRIORITY:-5}]: " priority
    priority="${priority:-${DEFAULT_PRIORITY:-5}}"
    read_input "请输入推送内容 [Gotify 测试成功]: " message
    message="${message:-Gotify 测试成功}"
    url="${BASE_URL%/}/message?token=${app_token}"
    info "发送测试推送到：${BASE_URL}"
    curl -fsS -X POST "$url" \
        -H "Content-Type: application/json" \
        --data-binary "{\"title\":\"${title}\",\"message\":\"${message}\",\"priority\":${priority},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}"
    echo
    ok "测试推送已发送"
}

test_ntfy_push() {
    load_state
    local topic message priority tags url auth_args=()
    read_input "请输入 ntfy Topic [${DEFAULT_TOPIC}]: " topic
    topic="${topic:-$DEFAULT_TOPIC}"
    if [ -z "${topic:-}" ]; then
        err "Topic 不能为空"
        return 1
    fi
    read_input "请输入优先级 1-5 [${DEFAULT_PRIORITY:-1}]: " priority
    priority="${priority:-${DEFAULT_PRIORITY:-1}}"
    validate_priority "$priority"
    read_input "请输入 Tags [${DEFAULT_TAGS:-空}]: " tags
    tags="${tags:-$DEFAULT_TAGS}"
    read_input "请输入推送内容 [ntfy 测试成功]: " message
    message="${message:-ntfy 测试成功}"

    if [ "${ENABLE_AUTH}" = "true" ]; then
        local input_user input_pass push_user push_pass
        read_input "请输入用户名 [${ADMIN_USER}]: " input_user
        push_user="${input_user:-$ADMIN_USER}"
        read_input "请输入密码 [回车使用保存密码]: " input_pass
        push_pass="${input_pass:-$ADMIN_PASS}"
        auth_args=(-u "${push_user}:${push_pass}")
    fi

    url="${BASE_URL%/}/${topic}"
    info "发送测试推送到：${url}"
    if [ -n "${tags:-}" ]; then
        curl -fsS -X POST "${auth_args[@]}" "$url" -H "Priority: ${priority}" -H "Tags: ${tags}" --data-binary "$message"
    else
        curl -fsS -X POST "${auth_args[@]}" "$url" -H "Priority: ${priority}" --data-binary "$message"
    fi
    echo
    ok "测试推送已发送"
}

test_push() {
    load_state
    case "$SERVICE_TYPE" in
        gotify) test_gotify_push ;;
        ntfy) test_ntfy_push ;;
        *) err "未设置服务类型，请先安装/配置"; return 1 ;;
    esac
}

reset_admin_user() {
    load_state
    local input_user input_pass confirm_text
    read_input "请输入管理员用户名 [${ADMIN_USER:-admin}]，DELETE=恢复 admin: " input_user
    apply_defaultable_input ADMIN_USER "${input_user:-}" "admin"
    read_input "请输入新密码 [回车自动生成，DELETE=重新生成]: " input_pass
    if [ -n "${input_pass:-}" ] && ! is_delete_input "$input_pass"; then
        ADMIN_PASS="$input_pass"
    else
        ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    fi
    read_input "输入 RESET 确认设置/重置登录账号: " confirm_text
    if [ "${confirm_text:-}" != "RESET" ]; then
        warn "已取消"
        return 0
    fi
    save_state

    if [ "$SERVICE_TYPE" = "ntfy" ]; then
        ENABLE_AUTH="true"
        save_state
        write_ntfy_server_config
        write_compose_for_service
        start_container
        ensure_ntfy_admin_user
        restart_service
    elif [ "$SERVICE_TYPE" = "gotify" ]; then
        warn "Gotify 默认账号密码只在首次初始化数据库时创建。"
        warn "如果需要强制重置，会备份旧数据并重新初始化，旧 Apps/Token 不会自动迁回。"
        read_input "输入 RESET_DATA 确认重置 Gotify 数据库登录账号: " confirm_text
        if [ "${confirm_text:-}" != "RESET_DATA" ]; then
            warn "已保存新配置，但未重置 Gotify 数据库。"
            return 0
        fi
        local cmd ts backup_dir
        cmd="$(compose_cmd)"
        ts="$(date +%Y%m%d_%H%M%S)"
        backup_dir="${GOTIFY_DATA_DIR}.bak.${ts}"
        [ -f "$COMPOSE_FILE" ] && (cd "$PUSH_ROOT" && $cmd down) || true
        if [ -d "$GOTIFY_DATA_DIR" ] && [ -n "$(find "$GOTIFY_DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]; then
            mv "$GOTIFY_DATA_DIR" "$backup_dir"
            ok "旧数据目录已备份：${backup_dir}"
        fi
        mkdir -p "$GOTIFY_DATA_DIR"
        write_compose_for_service
        start_container
        configure_nginx
    else
        err "未设置服务类型"
    fi
    ok "登录账号已设置"
    echo "访问地址：${BASE_URL}"
    echo "管理员账号：${ADMIN_USER}"
    echo "管理员密码：${ADMIN_PASS}"
}

uninstall_push() {
    load_state
    warn "该操作会停止并删除当前 Push 容器、Nginx 反代配置。"
    warn "默认不会删除统一目录：${PUSH_ROOT}"
    local confirm_text delete_text close_text cmd
    read_input "输入 YES 确认卸载当前 Push 服务: " confirm_text
    if [ "${confirm_text:-}" != "YES" ]; then
        warn "已取消卸载"
        return 0
    fi
    cmd="$(compose_cmd || true)"
    if [ -n "${cmd:-}" ] && [ -f "$COMPOSE_FILE" ]; then
        (cd "$PUSH_ROOT" && $cmd down) || true
    fi
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -f "$NGINX_SITE_LINK" "$NGINX_SITE_FILE"
    nginx -t && systemctl restart nginx || true
    read_input "是否删除统一目录 ${PUSH_ROOT} ? 输入 DELETE 确认删除: " delete_text
    if [ "${delete_text:-}" = "DELETE" ]; then
        rm -rf "$PUSH_ROOT"
        ok "统一目录已删除：${PUSH_ROOT}"
    else
        warn "保留统一目录：${PUSH_ROOT}"
    fi
    read_input "是否移除防火墙端口 ${PUBLIC_PORT}/tcp ? 输入 CLOSE 确认移除: " close_text
    if [ "${close_text:-}" = "CLOSE" ]; then
        close_firewall_port "$PUBLIC_PORT"
        ok "已尝试移除防火墙端口 ${PUBLIC_PORT}/tcp"
    fi
    ok "Push 服务已卸载"
}

switch_service() {
    load_state
    local old_type="$SERVICE_TYPE"
    select_service_type
    if [ "${SERVICE_TYPE:-}" = "${old_type:-}" ]; then
        warn "服务类型未改变：${SERVICE_TYPE}"
    else
        warn "将从 ${old_type:-未设置} 切换到 ${SERVICE_TYPE}；同一时间只运行一个服务。"
    fi
    save_state
    prompt_common_config
    stop_existing_service
    write_compose_for_service
    start_container
    ensure_ntfy_admin_user
    configure_nginx
    print_access_info
}

show_menu() {
    load_state
    clear
    printf "\n"
    printf "${BOLD}${BLUE}=========================================================================${NC}\n"
    printf "${BOLD}${WHITE}                 Push 统一安装 / 反代 / 配置菜单                         ${NC}\n"
    printf "${BOLD}${BLUE}=========================================================================${NC}\n"
    printf "${BOLD}${GREEN} [1] 一键安装 / 重装 Push${NC}       ${WHITE}二选一：Gotify 或 ntfy，统一 /root/push${NC}\n"
    printf "${BOLD}${CYAN}  [2] 切换推送服务${NC}              ${WHITE}gotify <-> ntfy，仅保留一个运行${NC}\n"
    printf "${BOLD}${CYAN}  [3] 仅重写 Nginx 反代${NC}         ${WHITE}修改域名/端口后刷新反代${NC}\n"
    printf "${BOLD}${CYAN}  [4] 重启当前服务${NC}              ${WHITE}重启容器和 Nginx${NC}\n"
    printf "${BOLD}${YELLOW} [5] 查看状态${NC}                  ${WHITE}查看容器、端口、访问地址、配置路径${NC}\n"
    printf "${BOLD}${YELLOW} [6] 测试推送${NC}                  ${WHITE}按当前服务发送测试推送${NC}\n"
    printf "${BOLD}${GREEN} [7] 输出配置片段${NC}              ${WHITE}输出当前服务的本机推荐配置${NC}\n"
    printf "${BOLD}${MAGENTA} [8] 设置/重置登录账号${NC}        ${WHITE}ntfy 直接更新；Gotify 可选择重置数据库${NC}\n"
    printf "${BOLD}${RED}   [9] 卸载当前 Push 服务${NC}       ${YELLOW}删除容器和反代，可选择保留数据${NC}\n"
    printf "${BOLD}${RED}   [0] 退出${NC}\n"
    printf "${BOLD}${BLUE}-------------------------------------------------------------------------${NC}\n"
    printf "${BOLD}${YELLOW} 当前服务：${NC}${GREEN}${SERVICE_TYPE:-未设置}${NC}${WHITE}    统一目录：${PUSH_ROOT}${NC}\n"
    printf "${BOLD}${YELLOW} 当前外部端口：${NC}${GREEN}${PUBLIC_PORT}${NC}${WHITE}    当前内部端口：127.0.0.1:${INTERNAL_PORT}${NC}\n"
    printf "${BOLD}${YELLOW} 证书路径：${NC}${GREEN}/etc/letsencrypt/live/域名/fullchain.pem${NC}\n"
    printf "${BOLD}${BLUE}=========================================================================${NC}\n"
    printf "\n"
}

main() {
    require_root
    load_state
    while true; do
        show_menu
        local choice
        read_input "请输入菜单编号: " choice
        echo
        case "${choice:-}" in
            1) install_all ;;
            2) switch_service ;;
            3) prompt_common_config; configure_nginx; print_access_info ;;
            4) restart_service ;;
            5) show_status ;;
            6) test_push ;;
            7) print_access_info ;;
            8) reset_admin_user ;;
            9) uninstall_push ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
        echo
        local _pause
        read_input "按回车继续..." _pause
    done
}

main "$@"
