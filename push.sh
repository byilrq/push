#!/usr/bin/env bash
set -euo pipefail

# ntfy one-click installer/manager for Debian/Ubuntu VPS
# - Docker Compose deployment
# - Nginx reverse proxy
# - Reuses the same DOMAIN state and Let's Encrypt cert path style from ism.sh:
#   /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
#   /etc/letsencrypt/live/${DOMAIN}/privkey.pem
#
# Usage:
#   bash ntfy.sh

NTFY_ROOT="/root/ntfy"
NTFY_CACHE_DIR="${NTFY_ROOT}/cache"
NTFY_ETC_DIR="${NTFY_ROOT}/etc"
NTFY_LIB_DIR="${NTFY_ROOT}/lib"
NTFY_ATTACH_DIR="${NTFY_LIB_DIR}/attachments"
NTFY_COMPOSE_FILE="${NTFY_ROOT}/docker-compose.yml"
NTFY_SERVER_FILE="${NTFY_ETC_DIR}/server.yml"
NTFY_STATE_FILE="/root/.ntfy_install.conf"
ISM_STATE_FILE="/root/.asset_manager_install.conf"

SERVICE_NAME="ntfy"
CONTAINER_NAME="ntfy"
INTERNAL_PORT="8083"
PUBLIC_PORT="2085"
DOMAIN=""
NTFY_BASE_URL=""
NTFY_ENABLE_AUTH="true"
NTFY_ADMIN_USER="admin"
NTFY_ADMIN_PASS=""
NTFY_DEFAULT_TOPIC="let-rss"
NTFY_DEFAULT_PRIORITY="4"
NTFY_DEFAULT_TAGS="rss,white_check_mark"

NGINX_SITE_FILE="/etc/nginx/sites-available/${SERVICE_NAME}_${PUBLIC_PORT}.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${SERVICE_NAME}_${PUBLIC_PORT}.conf"

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
        err "请使用 root 运行：sudo bash ntfy.sh"
        exit 1
    fi
}

load_ism_domain_once() {
    if [ -z "${DOMAIN:-}" ] && [ -f "$ISM_STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$ISM_STATE_FILE" || true
        : "${DOMAIN:=}"
    fi
}

load_state() {
    if [ -f "$NTFY_STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$NTFY_STATE_FILE"
    else
        load_ism_domain_once
    fi
    : "${NTFY_ROOT:=/root/ntfy}"
    : "${NTFY_CACHE_DIR:=${NTFY_ROOT}/cache}"
    : "${NTFY_ETC_DIR:=${NTFY_ROOT}/etc}"
    : "${NTFY_LIB_DIR:=${NTFY_ROOT}/lib}"
    : "${NTFY_ATTACH_DIR:=${NTFY_LIB_DIR}/attachments}"
    : "${NTFY_COMPOSE_FILE:=${NTFY_ROOT}/docker-compose.yml}"
    : "${NTFY_SERVER_FILE:=${NTFY_ETC_DIR}/server.yml}"
    : "${INTERNAL_PORT:=8083}"
    : "${PUBLIC_PORT:=2085}"
    : "${DOMAIN:=}"
    : "${NTFY_BASE_URL:=}"
    : "${NTFY_ENABLE_AUTH:=true}"
    : "${NTFY_ADMIN_USER:=admin}"
    : "${NTFY_ADMIN_PASS:=}"
    : "${NTFY_DEFAULT_TOPIC:=let-rss}"
    : "${NTFY_DEFAULT_PRIORITY:=4}"
    : "${NTFY_DEFAULT_TAGS:=rss,white_check_mark}"
    NGINX_SITE_FILE="/etc/nginx/sites-available/${SERVICE_NAME}_${PUBLIC_PORT}.conf"
    NGINX_SITE_LINK="/etc/nginx/sites-enabled/${SERVICE_NAME}_${PUBLIC_PORT}.conf"
}

save_state() {
    cat > "$NTFY_STATE_FILE" <<EOF_STATE
NTFY_ROOT=${NTFY_ROOT@Q}
NTFY_CACHE_DIR=${NTFY_CACHE_DIR@Q}
NTFY_ETC_DIR=${NTFY_ETC_DIR@Q}
NTFY_LIB_DIR=${NTFY_LIB_DIR@Q}
NTFY_ATTACH_DIR=${NTFY_ATTACH_DIR@Q}
NTFY_COMPOSE_FILE=${NTFY_COMPOSE_FILE@Q}
NTFY_SERVER_FILE=${NTFY_SERVER_FILE@Q}
INTERNAL_PORT=${INTERNAL_PORT@Q}
PUBLIC_PORT=${PUBLIC_PORT@Q}
DOMAIN=${DOMAIN@Q}
NTFY_BASE_URL=${NTFY_BASE_URL@Q}
NTFY_ENABLE_AUTH=${NTFY_ENABLE_AUTH@Q}
NTFY_ADMIN_USER=${NTFY_ADMIN_USER@Q}
NTFY_ADMIN_PASS=${NTFY_ADMIN_PASS@Q}
NTFY_DEFAULT_TOPIC=${NTFY_DEFAULT_TOPIC@Q}
NTFY_DEFAULT_PRIORITY=${NTFY_DEFAULT_PRIORITY@Q}
NTFY_DEFAULT_TAGS=${NTFY_DEFAULT_TAGS@Q}
EOF_STATE
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

normalize_bool() {
    local v="${1:-}"
    case "$v" in
        y|Y|yes|YES|Yes|true|TRUE|1|开启|是) echo "true" ;;
        n|N|no|NO|No|false|FALSE|0|关闭|否|DELETE|delete|删除|清空) echo "false" ;;
        *) echo "$v" ;;
    esac
}

is_delete_input() {
    case "${1:-}" in
        DELETE|delete|Delete|删除|清空|移除) return 0 ;;
        *) return 1 ;;
    esac
}

apply_text_input() {
    # 用法：apply_text_input 变量名 输入值
    # 留空=保持；输入 DELETE/删除/清空=清空该配置；其它内容=设置新值
    local var_name="$1"
    local input_value="${2:-}"
    if is_delete_input "$input_value"; then
        printf -v "$var_name" '%s' ""
    elif [ -n "$input_value" ]; then
        printf -v "$var_name" '%s' "$input_value"
    fi
}

apply_port_input() {
    # 端口不能真正清空；输入 DELETE/删除/清空=恢复默认端口
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

open_firewall_port() {
    local port="$1"
    validate_port "$port" || return 1

    info "尝试自动放行防火墙端口：${port}/tcp"

    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qi "Status: active"; then
            ufw allow "${port}/tcp" >/dev/null 2>&1 || warn "ufw 放行 ${port}/tcp 失败，请手动检查"
            ok "ufw 已放行 ${port}/tcp"
            return 0
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || warn "firewalld 永久放行 ${port}/tcp 失败"
            firewall-cmd --reload >/dev/null 2>&1 || warn "firewalld reload 失败"
            ok "firewalld 已放行 ${port}/tcp"
            return 0
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || warn "iptables 放行 ${port}/tcp 失败，请手动检查"
        fi
        ok "iptables 当前会话已放行 ${port}/tcp（如需持久化，请确认系统已安装 iptables-persistent）"
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

refresh_base_url() {
    if [ -n "${DOMAIN:-}" ]; then
        if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
            NTFY_BASE_URL="https://${DOMAIN}:${PUBLIC_PORT}"
        else
            NTFY_BASE_URL="http://${DOMAIN}:${PUBLIC_PORT}"
        fi
    else
        local ip
        ip="$(get_host_ip || true)"
        NTFY_BASE_URL="http://${ip:-服务器IP}:${PUBLIC_PORT}"
    fi
}

prompt_basic_config() {
    load_state
    echo "ntfy 基础配置："
    echo "1) 会优先读取 ${ISM_STATE_FILE} 里的 DOMAIN，证书位置沿用 /etc/letsencrypt/live/域名/"
    echo "2) 默认容器内部映射端口：127.0.0.1:${INTERNAL_PORT}"
    echo "3) 默认外部 Nginx 端口：${PUBLIC_PORT}，避免占用你现有脚本的 2083/2084"
    echo "4) ntfy 的 topic 相当于频道名，客户端订阅同一个 topic 才能收到推送"
    echo "5) 输入 DELETE / 删除 / 清空 可清空文本配置；端口输入 DELETE 会恢复默认端口"
    echo

    read -r -p "请输入 ntfy 域名 [${DOMAIN:-可留空用 IP}]: " input_domain
    apply_text_input DOMAIN "${input_domain:-}"

    read -r -p "请输入外部访问端口 [${PUBLIC_PORT}]，DELETE=恢复 2085: " input_public_port
    apply_port_input PUBLIC_PORT "${input_public_port:-}" "2085"
    validate_port "$PUBLIC_PORT"

    read -r -p "请输入本机内部端口 [${INTERNAL_PORT}]，DELETE=恢复 8083: " input_internal_port
    apply_port_input INTERNAL_PORT "${input_internal_port:-}" "8083"
    validate_port "$INTERNAL_PORT"

    read -r -p "请输入默认推送 Topic [${NTFY_DEFAULT_TOPIC}]，DELETE=清空后恢复 let-rss: " input_topic
    apply_text_input NTFY_DEFAULT_TOPIC "${input_topic:-}"
    if [ -z "${NTFY_DEFAULT_TOPIC:-}" ]; then NTFY_DEFAULT_TOPIC="let-rss"; fi

    read -r -p "请输入默认推送优先级 1-5 [${NTFY_DEFAULT_PRIORITY}]，DELETE=恢复 4: " input_priority
    if is_delete_input "${input_priority:-}"; then
        NTFY_DEFAULT_PRIORITY="4"
    elif [ -n "${input_priority:-}" ]; then
        NTFY_DEFAULT_PRIORITY="$input_priority"
    fi

    read -r -p "请输入默认 Tags，逗号分隔 [${NTFY_DEFAULT_TAGS}]，DELETE=清空: " input_tags
    apply_text_input NTFY_DEFAULT_TAGS "${input_tags:-}"

    read -r -p "是否开启登录认证/默认拒绝匿名访问？[${NTFY_ENABLE_AUTH}]，DELETE=关闭认证: " input_auth
    if [ -n "${input_auth:-}" ]; then
        NTFY_ENABLE_AUTH="$(normalize_bool "$input_auth")"
    else
        NTFY_ENABLE_AUTH="${NTFY_ENABLE_AUTH:-true}"
    fi

    if [ "${NTFY_ENABLE_AUTH}" = "true" ]; then
        read -r -p "请输入 ntfy 管理员用户名 [${NTFY_ADMIN_USER}]，DELETE=恢复 admin: " input_user
        if is_delete_input "${input_user:-}"; then
            NTFY_ADMIN_USER="admin"
        elif [ -n "${input_user:-}" ]; then
            NTFY_ADMIN_USER="$input_user"
        fi

        read -r -p "请输入 ntfy 管理员密码 [留空保持/自动生成，DELETE=重新生成]: " input_pass
        if is_delete_input "${input_pass:-}"; then
            NTFY_ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
        elif [ -n "${input_pass:-}" ]; then
            NTFY_ADMIN_PASS="$input_pass"
        elif [ -z "${NTFY_ADMIN_PASS:-}" ]; then
            NTFY_ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
        fi
    else
        NTFY_ADMIN_USER="${NTFY_ADMIN_USER:-admin}"
        NTFY_ADMIN_PASS=""
    fi

    refresh_base_url
    save_state
    ok "配置已保存：${NTFY_STATE_FILE}"
}
write_server_config() {
    mkdir -p "$NTFY_ETC_DIR" "$NTFY_CACHE_DIR" "$NTFY_LIB_DIR" "$NTFY_ATTACH_DIR"
    refresh_base_url

    if [ "${NTFY_ENABLE_AUTH}" = "true" ]; then
        cat > "$NTFY_SERVER_FILE" <<EOF_SERVER_AUTH
base-url: "${NTFY_BASE_URL}"
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
base-url: "${NTFY_BASE_URL}"
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

write_compose() {
    mkdir -p "$NTFY_ROOT" "$NTFY_CACHE_DIR" "$NTFY_ETC_DIR" "$NTFY_LIB_DIR" "$NTFY_ATTACH_DIR"
    cat > "$NTFY_COMPOSE_FILE" <<EOF_COMPOSE
services:
  ntfy:
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
      - ./cache:/var/cache/ntfy
      - ./etc:/etc/ntfy
      - ./lib:/var/lib/ntfy
EOF_COMPOSE
    ok "Docker Compose 已写入：${NTFY_COMPOSE_FILE}"
}

start_ntfy() {
    local cmd
    cmd="$(compose_cmd)"
    info "启动 ntfy 容器"
    (cd "$NTFY_ROOT" && $cmd up -d)

    if wait_for_port "$INTERNAL_PORT" 30; then
        ok "ntfy 已监听 127.0.0.1:${INTERNAL_PORT}"
    else
        warn "暂未检测到 ${INTERNAL_PORT} 端口监听，请执行：cd ${NTFY_ROOT} && ${cmd} logs --tail=100 ntfy"
    fi
}

ensure_admin_user() {
    load_state
    if [ "${NTFY_ENABLE_AUTH}" != "true" ]; then
        return 0
    fi

    if [ -z "${NTFY_ADMIN_USER:-}" ] || [ -z "${NTFY_ADMIN_PASS:-}" ]; then
        warn "未设置管理员账号或密码，跳过用户创建"
        return 0
    fi

    info "创建/更新 ntfy 管理员账号：${NTFY_ADMIN_USER}"
    # ntfy user add 是交互式密码输入；这里通过 printf 喂两次密码。
    if docker exec -i "$CONTAINER_NAME" ntfy user add --role=admin "$NTFY_ADMIN_USER" >/tmp/ntfy_user_add.out 2>&1 <<EOF_PASS
${NTFY_ADMIN_PASS}
${NTFY_ADMIN_PASS}
EOF_PASS
    then
        ok "管理员账号已创建：${NTFY_ADMIN_USER}"
    else
        if grep -qiE "already exists|exists|duplicate" /tmp/ntfy_user_add.out 2>/dev/null; then
            if docker exec -i "$CONTAINER_NAME" ntfy user change-pass "$NTFY_ADMIN_USER" >/tmp/ntfy_user_pass.out 2>&1 <<EOF_PASS2
${NTFY_ADMIN_PASS}
${NTFY_ADMIN_PASS}
EOF_PASS2
            then
                ok "管理员密码已更新：${NTFY_ADMIN_USER}"
            else
                warn "账号已存在，但自动更新密码失败。你可以手动执行：docker exec -it ${CONTAINER_NAME} ntfy user change-pass ${NTFY_ADMIN_USER}"
                cat /tmp/ntfy_user_pass.out 2>/dev/null || true
            fi
        else
            warn "自动创建管理员失败。你可以手动执行：docker exec -it ${CONTAINER_NAME} ntfy user add --role=admin ${NTFY_ADMIN_USER}"
            cat /tmp/ntfy_user_add.out 2>/dev/null || true
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
    NGINX_SITE_FILE="/etc/nginx/sites-available/${SERVICE_NAME}_${PUBLIC_PORT}.conf"
    NGINX_SITE_LINK="/etc/nginx/sites-enabled/${SERVICE_NAME}_${PUBLIC_PORT}.conf"

    info "配置 Nginx 反向代理"
    rm -f /etc/nginx/sites-enabled/${SERVICE_NAME}_*.conf /etc/nginx/sites-available/${SERVICE_NAME}_*.conf 2>/dev/null || true
    if [ -n "${DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
        write_nginx_https
        NTFY_BASE_URL="https://${DOMAIN}:${PUBLIC_PORT}"
        ok "检测到证书，已配置 ${NTFY_BASE_URL}"
    else
        write_nginx_http
        if [ -n "${DOMAIN:-}" ]; then
            NTFY_BASE_URL="http://${DOMAIN}:${PUBLIC_PORT}"
            warn "未找到 /etc/letsencrypt/live/${DOMAIN}/ 证书，已配置为 ${NTFY_BASE_URL}"
        else
            local ip
            ip="$(get_host_ip || true)"
            NTFY_BASE_URL="http://${ip:-服务器IP}:${PUBLIC_PORT}"
            warn "未填写域名，已配置为 ${NTFY_BASE_URL}"
        fi
    fi

    ln -sf "$NGINX_SITE_FILE" "$NGINX_SITE_LINK"
    nginx -t
    systemctl restart nginx
    sleep 1
    open_firewall_port "$PUBLIC_PORT" || true
    save_state
    write_server_config

    # base-url 变化后让 ntfy 读取最新 server.yml
    if [ -f "$NTFY_COMPOSE_FILE" ]; then
        local cmd
        cmd="$(compose_cmd || true)"
        if [ -n "${cmd:-}" ]; then
            (cd "$NTFY_ROOT" && $cmd restart ntfy) || true
        fi
    fi

    if wait_for_port "$PUBLIC_PORT" 10; then
        ok "Nginx 配置完成，已监听端口 ${PUBLIC_PORT}"
    else
        warn "Nginx 已重启，但暂未检测到 ${PUBLIC_PORT} 端口监听，请执行：systemctl status nginx --no-pager"
    fi
}

install_ntfy_all() {
    load_state
    install_dependencies
    prompt_basic_config
    write_server_config
    write_compose
    start_ntfy
    ensure_admin_user
    configure_nginx
    print_access_info
}

restart_ntfy() {
    load_state
    local cmd
    cmd="$(compose_cmd)"
    info "重启 ntfy"
    (cd "$NTFY_ROOT" && $cmd restart ntfy)
    systemctl restart nginx
    ok "ntfy 和 Nginx 已重启"
}

show_status() {
    load_state
    local cmd
    cmd="$(compose_cmd || true)"
    echo "ntfy 状态"
    echo "  安装目录：${NTFY_ROOT}"
    echo "  缓存目录：${NTFY_CACHE_DIR}"
    echo "  配置目录：${NTFY_ETC_DIR}"
    echo "  数据目录：${NTFY_LIB_DIR}"
    echo "  Compose：${NTFY_COMPOSE_FILE}"
    echo "  状态配置：${NTFY_STATE_FILE}"
    echo "  server.yml：${NTFY_SERVER_FILE}"
    echo "  域名：${DOMAIN:-未设置}"
    echo "  内部端口：127.0.0.1:${INTERNAL_PORT}"
    echo "  外部端口：${PUBLIC_PORT}"
    echo "  访问地址：${NTFY_BASE_URL:-未生成}"
    echo "  默认 Topic：${NTFY_DEFAULT_TOPIC}"
    echo "  登录认证：${NTFY_ENABLE_AUTH}"
    echo "  管理员账号：${NTFY_ADMIN_USER:-未设置}"
    echo "  Nginx 配置：${NGINX_SITE_FILE}"
    echo

    if [ -n "$cmd" ] && [ -f "$NTFY_COMPOSE_FILE" ]; then
        (cd "$NTFY_ROOT" && $cmd ps) || true
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
    printf "${BOLD}${GREEN}ntfy 部署/配置完成${NC}\n"
    echo
    echo "====== 访问配置 ======"
    echo "外部访问地址：${NTFY_BASE_URL}"
    echo "本机推送地址：${local_base_url}"
    echo "默认 Topic：${NTFY_DEFAULT_TOPIC}"
    echo "默认优先级：${NTFY_DEFAULT_PRIORITY}"
    echo "默认 Tags：${NTFY_DEFAULT_TAGS:-未设置}"
    echo "登录认证：${NTFY_ENABLE_AUTH}"
    if [ "${NTFY_ENABLE_AUTH}" = "true" ]; then
        echo "管理员账号：${NTFY_ADMIN_USER}"
        echo "管理员密码：${NTFY_ADMIN_PASS}"
    else
        echo "认证状态：未开启，任何知道 Topic 的人都可发布/订阅"
    fi
    echo
    echo "====== 端口配置 ======"
    echo "容器内部端口：80"
    echo "本机内部映射：127.0.0.1:${INTERNAL_PORT}"
    echo "Nginx 外部端口：${PUBLIC_PORT}"
    echo "防火墙放行端口：${PUBLIC_PORT}/tcp（脚本已尝试自动放行）"
    echo
    echo "====== 本地配置路径 ======"
    echo "脚本状态配置：${NTFY_STATE_FILE}"
    echo "ntfy 服务配置：${NTFY_SERVER_FILE}"
    echo "Docker Compose：${NTFY_COMPOSE_FILE}"
    echo "Nginx 反代配置：${NGINX_SITE_FILE}"
    echo "ntfy 缓存目录：${NTFY_CACHE_DIR}"
    echo "ntfy 数据目录：${NTFY_LIB_DIR}"
    echo "附件目录：${NTFY_ATTACH_DIR}"
    echo
    echo "====== RSS 配置片段：外部/手机/其它服务器使用 ======" 

    if [ "${NTFY_ENABLE_AUTH}" = "true" ]; then
        cat <<EOF_CFG_AUTH
{
  "notice_type": "ntfy",
  "ntfy_url": "${NTFY_BASE_URL}",
  "ntfy_topic": "${NTFY_DEFAULT_TOPIC}",
  "ntfy_username": "${NTFY_ADMIN_USER}",
  "ntfy_password": "${NTFY_ADMIN_PASS}",
  "ntfy_priority": ${NTFY_DEFAULT_PRIORITY},
  "ntfy_tags": "${NTFY_DEFAULT_TAGS}"
}
EOF_CFG_AUTH
    else
        cat <<EOF_CFG_OPEN
{
  "notice_type": "ntfy",
  "ntfy_url": "${NTFY_BASE_URL}",
  "ntfy_topic": "${NTFY_DEFAULT_TOPIC}",
  "ntfy_priority": ${NTFY_DEFAULT_PRIORITY},
  "ntfy_tags": "${NTFY_DEFAULT_TAGS}"
}
EOF_CFG_OPEN
    fi

    echo
    echo "====== RSS 配置片段：同一台 VPS 本机程序推荐使用 ======" 
    if [ "${NTFY_ENABLE_AUTH}" = "true" ]; then
        cat <<EOF_CFG_LOCAL_AUTH
{
  "notice_type": "ntfy",
  "ntfy_url": "${local_base_url}",
  "ntfy_topic": "${NTFY_DEFAULT_TOPIC}",
  "ntfy_username": "${NTFY_ADMIN_USER}",
  "ntfy_password": "${NTFY_ADMIN_PASS}",
  "ntfy_priority": ${NTFY_DEFAULT_PRIORITY},
  "ntfy_tags": "${NTFY_DEFAULT_TAGS}"
}
EOF_CFG_LOCAL_AUTH
    else
        cat <<EOF_CFG_LOCAL_OPEN
{
  "notice_type": "ntfy",
  "ntfy_url": "${local_base_url}",
  "ntfy_topic": "${NTFY_DEFAULT_TOPIC}",
  "ntfy_priority": ${NTFY_DEFAULT_PRIORITY},
  "ntfy_tags": "${NTFY_DEFAULT_TAGS}"
}
EOF_CFG_LOCAL_OPEN
    fi

    echo
    echo "curl 示例："
    if [ "${NTFY_ENABLE_AUTH}" = "true" ]; then
        echo "curl -u '${NTFY_ADMIN_USER}:你的密码' -H 'Title: 测试' -H 'Priority: ${NTFY_DEFAULT_PRIORITY}' -H 'Tags: ${NTFY_DEFAULT_TAGS}' -d 'hello ntfy' '${local_base_url}/${NTFY_DEFAULT_TOPIC}'"
    else
        echo "curl -H 'Title: 测试' -H 'Priority: ${NTFY_DEFAULT_PRIORITY}' -H 'Tags: ${NTFY_DEFAULT_TAGS}' -d 'hello ntfy' '${local_base_url}/${NTFY_DEFAULT_TOPIC}'"
    fi
    echo
    echo "提示：同一台 VPS 上的程序建议用 ${local_base_url}；手机、浏览器和其它服务器用 ${NTFY_BASE_URL}。"
}
test_push() {
    load_state
    local topic title message priority tags auth_args=()

    read -r -p "请输入 ntfy Topic [${NTFY_DEFAULT_TOPIC}]，DELETE=使用默认 Topic: " topic
    if is_delete_input "${topic:-}"; then
        topic="$NTFY_DEFAULT_TOPIC"
    else
        topic="${topic:-$NTFY_DEFAULT_TOPIC}"
    fi
    if [ -z "${topic:-}" ]; then
        err "Topic 不能为空"
        return 1
    fi

    read -r -p "请输入推送标题 [LET RSS ntfy 测试]，DELETE=使用默认标题: " title
    if is_delete_input "${title:-}" || [ -z "${title:-}" ]; then
        title="LET RSS ntfy 测试"
    fi

    read -r -p "请输入优先级 1-5 [${NTFY_DEFAULT_PRIORITY}]，DELETE=使用默认优先级: " priority
    if is_delete_input "${priority:-}" || [ -z "${priority:-}" ]; then
        priority="$NTFY_DEFAULT_PRIORITY"
    fi

    read -r -p "请输入 Tags，逗号分隔 [${NTFY_DEFAULT_TAGS}]，DELETE=不带 Tags: " tags
    if is_delete_input "${tags:-}"; then
        tags=""
    else
        tags="${tags:-$NTFY_DEFAULT_TAGS}"
    fi

    read -r -p "请输入推送内容 [ntfy Markdown 测试成功]，DELETE=使用默认内容: " message
    if is_delete_input "${message:-}" || [ -z "${message:-}" ]; then
        message="ntfy Markdown 测试成功\n\n- 推送通道：ntfy\n- Topic：${topic}\n- 链接：https://ntfy.sh/"
    fi

    if [ "${NTFY_ENABLE_AUTH}" = "true" ]; then
        read -r -p "请输入用户名 [${NTFY_ADMIN_USER}]，DELETE=使用默认管理员: " input_user
        local push_user push_pass
        if is_delete_input "${input_user:-}" || [ -z "${input_user:-}" ]; then
            push_user="$NTFY_ADMIN_USER"
        else
            push_user="$input_user"
        fi
        read -r -p "请输入密码 [留空使用脚本保存的管理员密码，DELETE=使用保存密码]: " input_pass
        if is_delete_input "${input_pass:-}" || [ -z "${input_pass:-}" ]; then
            push_pass="$NTFY_ADMIN_PASS"
        else
            push_pass="$input_pass"
        fi
        auth_args=(-u "${push_user}:${push_pass}")
    fi

    local url
    url="${NTFY_BASE_URL%/}/${topic}"
    info "发送测试推送到：${url}"
    curl -fsS -X POST "${auth_args[@]}" "$url" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -H "Markdown: yes" \
        --data-binary "$message"
    echo
    ok "测试推送已发送"
}

test_push_from_let_config() {
    local config_file
    config_file="/root/let/data/config.json"

    read -r -p "请输入 RSS 配置文件路径 [${config_file}]，DELETE=恢复默认: " input_config_file
    if is_delete_input "${input_config_file:-}"; then
        config_file="/root/let/data/config.json"
    elif [ -n "${input_config_file:-}" ]; then
        config_file="$input_config_file"
    fi

    if [ ! -f "$config_file" ]; then
        err "未找到配置文件：${config_file}"
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        err "未检测到 python3，无法读取 JSON 配置"
        return 1
    fi

    info "读取配置文件并调用 RSS 项目的 send.py 测试推送：${config_file}"
    python3 - "$config_file" <<'PY_TEST_PUSH'
import json
import sys
from pathlib import Path
from datetime import datetime

config_path = Path(sys.argv[1]).expanduser().resolve()
project_root = config_path.parent.parent
sys.path.insert(0, str(project_root))

try:
    with config_path.open('r', encoding='utf-8') as f:
        raw = json.load(f)
    config = raw.get('config', raw)
except Exception as e:
    print(f"[ERR] 读取配置失败：{e}")
    raise SystemExit(1)

notice_type = config.get('notice_type', 'telegram')

try:
    from send import NotificationSender
except Exception as e:
    print(f"[ERR] 无法导入 {project_root}/send.py：{e}")
    print("[TIP] 请确认该配置文件位于项目 data/config.json，且项目根目录存在 send.py")
    raise SystemExit(1)

message = (
    "LET RSS 配置文件测试推送\n\n"
    f"推送通道：{notice_type}\n"
    f"配置文件：{config_path}\n"
    f"测试时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n"
    "如果你收到这条消息，说明当前 data/config.json 的推送配置可用。"
)

try:
    ok = NotificationSender(config).send_message(message)
except Exception as e:
    print(f"[ERR] 调用 NotificationSender 失败：{e}")
    raise SystemExit(1)

print(f"send_result={ok}")
if not ok:
    print("[ERR] 推送函数返回 False，请检查 notice_type、URL、Topic、用户名/密码、网络和服务端日志")
    raise SystemExit(2)
PY_TEST_PUSH

    ok "已按 ${config_file} 执行测试推送"
}

reset_admin_user() {
    load_state
    warn "该操作会创建或更新 ntfy 管理员账号密码，不会删除消息缓存或现有 topic。"
    echo
    NTFY_ENABLE_AUTH="true"
    read -r -p "请输入管理员用户名 [${NTFY_ADMIN_USER:-admin}]，DELETE=恢复 admin: " input_user
    if is_delete_input "${input_user:-}"; then
        NTFY_ADMIN_USER="admin"
    elif [ -n "${input_user:-}" ]; then
        NTFY_ADMIN_USER="$input_user"
    fi
    read -r -p "请输入新的管理员密码 [留空自动生成，DELETE=重新生成]: " input_pass
    if [ -n "${input_pass:-}" ]; then
        if is_delete_input "$input_pass"; then
            NTFY_ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
        else
            NTFY_ADMIN_PASS="$input_pass"
        fi
    else
        NTFY_ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    fi

    read -r -p "输入 RESET 确认重置/更新 ntfy 登录账号: " confirm_text
    if [ "${confirm_text:-}" != "RESET" ]; then
        warn "已取消重置"
        return 0
    fi

    save_state
    write_server_config
    write_compose
    start_ntfy
    ensure_admin_user
    restart_ntfy

    ok "ntfy 登录账号已设置"
    echo "访问地址：${NTFY_BASE_URL}"
    echo "管理员账号：${NTFY_ADMIN_USER}"
    echo "管理员密码：${NTFY_ADMIN_PASS}"
}

uninstall_ntfy() {
    load_state
    warn "该操作会停止并删除 ntfy 容器、Nginx 反代配置。"
    warn "默认不会删除数据目录：${NTFY_ROOT}"
    read -r -p "输入 YES 确认卸载 ntfy: " confirm_text
    if [ "${confirm_text:-}" != "YES" ]; then
        warn "已取消卸载"
        return 0
    fi

    local cmd
    cmd="$(compose_cmd || true)"
    if [ -n "${cmd:-}" ] && [ -f "$NTFY_COMPOSE_FILE" ]; then
        (cd "$NTFY_ROOT" && $cmd down) || true
    fi

    rm -f "$NGINX_SITE_LINK" "$NGINX_SITE_FILE"
    nginx -t && systemctl restart nginx || true

    read -r -p "是否同时删除 ntfy 数据目录 ${NTFY_ROOT} ? 输入 DELETE 确认删除: " delete_text
    if [ "${delete_text:-}" = "DELETE" ]; then
        rm -rf "$NTFY_ROOT"
        ok "ntfy 数据目录已删除"
    else
        warn "保留数据目录：${NTFY_ROOT}"
    fi

    read -r -p "是否同时移除防火墙端口 ${PUBLIC_PORT}/tcp ? 输入 CLOSE 确认移除: " close_text
    if [ "${close_text:-}" = "CLOSE" ]; then
        close_firewall_port "$PUBLIC_PORT"
        ok "已尝试移除防火墙端口 ${PUBLIC_PORT}/tcp"
    fi

    rm -f "$NTFY_STATE_FILE"
    ok "ntfy 已卸载"
}

show_menu() {
    clear
    printf "\n"
    printf "${BOLD}${BLUE}=========================================================================${NC}\n"
    printf "${BOLD}${WHITE}                   ntfy 安装 / 反代 / 配置菜单                           ${NC}\n"
    printf "${BOLD}${BLUE}=========================================================================${NC}\n"
    printf "${BOLD}${GREEN} [1] 一键安装 / 重装 ntfy${NC}        ${WHITE}Docker 部署 + Nginx 反代 + 复用证书路径${NC}\n"
    printf "${BOLD}${CYAN}  [2] 仅重写 Nginx 反代${NC}          ${WHITE}修改域名/端口后单独刷新反代${NC}\n"
    printf "${BOLD}${CYAN}  [3] 重启 ntfy${NC}                  ${WHITE}重启容器和 Nginx${NC}\n"
    printf "${BOLD}${YELLOW} [4] 查看状态${NC}                   ${WHITE}查看容器、端口、访问地址、Topic${NC}\n"
    printf "${BOLD}${YELLOW} [5] 测试推送${NC}                   ${WHITE}输入 Topic 后发一条 Markdown 测试${NC}\n"
    printf "${BOLD}${GREEN} [6] 输出 RSS 配置片段${NC}          ${WHITE}复制到 data/config.json${NC}\n"
    printf "${BOLD}${YELLOW} [7] 读取 RSS 配置测试推送${NC}      ${WHITE}/root/let/data/config.json -> send.py${NC}\n"
    printf "${BOLD}${MAGENTA} [8] 设置/重置登录账号${NC}         ${WHITE}创建或更新 ntfy 管理员账号${NC}\n"
    printf "${BOLD}${RED}   [9] 卸载 ntfy${NC}                 ${YELLOW}删除容器和反代，可选择保留数据${NC}\n"
    printf "${BOLD}${RED}   [0] 退出${NC}\n"
    printf "${BOLD}${BLUE}-------------------------------------------------------------------------${NC}\n"
    printf "${BOLD}${YELLOW} ★ 默认外部端口：${NC}${GREEN}${PUBLIC_PORT}${NC}${WHITE}，避免与你现有 asset_manager / gotify 端口冲突${NC}\n"
    printf "${BOLD}${YELLOW} ★ 证书路径：${NC}${GREEN}/etc/letsencrypt/live/域名/fullchain.pem${NC}\n"
    printf "${BOLD}${YELLOW} ★ 默认 Topic：${NC}${GREEN}${NTFY_DEFAULT_TOPIC}${NC}${WHITE}，客户端订阅同名 Topic 接收消息${NC}\n"
    printf "${BOLD}${YELLOW} ★ 输入提示：${NC}${GREEN}DELETE/删除/清空${NC}${WHITE} 可清空配置，端口会恢复默认值${NC}\n"
    printf "${BOLD}${BLUE}=========================================================================${NC}\n"
    printf "\n"
}

main() {
    require_root
    load_state
    while true; do
        show_menu
        read -r -p "请输入菜单编号: " choice
        echo
        case "${choice:-}" in
            1) install_ntfy_all ;;
            2) prompt_basic_config; configure_nginx; print_access_info ;;
            3) restart_ntfy ;;
            4) show_status ;;
            5) test_push ;;
            6) print_access_info ;;
            7) test_push_from_let_config ;;
            8) reset_admin_user ;;
            9) uninstall_ntfy ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
        echo
        read -r -p "按回车继续..." _
    done
}

main "$@"
