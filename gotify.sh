#!/usr/bin/env bash
set -euo pipefail

# Gotify one-click installer/manager for Debian/Ubuntu VPS
# - Docker Compose deployment
# - Nginx reverse proxy
# - Reuses the same DOMAIN state and Let's Encrypt cert path style from ism.sh:
#   /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
#   /etc/letsencrypt/live/${DOMAIN}/privkey.pem

GOTIFY_ROOT="/root/gotify"
GOTIFY_DATA_DIR="${GOTIFY_ROOT}/data"
GOTIFY_COMPOSE_FILE="${GOTIFY_ROOT}/docker-compose.yml"
GOTIFY_STATE_FILE="/root/.gotify_install.conf"
ISM_STATE_FILE="/root/.asset_manager_install.conf"

SERVICE_NAME="gotify"
CONTAINER_NAME="gotify"
INTERNAL_PORT="8082"
PUBLIC_PORT="2084"
DOMAIN=""
GOTIFY_ADMIN_USER="admin"
GOTIFY_ADMIN_PASS=""
GOTIFY_BASE_URL=""

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
        err "请使用 root 运行：sudo bash gotify_install.sh"
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
    if [ -f "$GOTIFY_STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$GOTIFY_STATE_FILE"
    else
        load_ism_domain_once
    fi
    : "${GOTIFY_ROOT:=/root/gotify}"
    : "${GOTIFY_DATA_DIR:=${GOTIFY_ROOT}/data}"
    : "${GOTIFY_COMPOSE_FILE:=${GOTIFY_ROOT}/docker-compose.yml}"
    : "${INTERNAL_PORT:=8082}"
    : "${PUBLIC_PORT:=2084}"
    : "${DOMAIN:=}"
    : "${GOTIFY_ADMIN_USER:=admin}"
    : "${GOTIFY_ADMIN_PASS:=}"
    : "${GOTIFY_BASE_URL:=}"
    NGINX_SITE_FILE="/etc/nginx/sites-available/${SERVICE_NAME}_${PUBLIC_PORT}.conf"
    NGINX_SITE_LINK="/etc/nginx/sites-enabled/${SERVICE_NAME}_${PUBLIC_PORT}.conf"
}

save_state() {
    cat > "$GOTIFY_STATE_FILE" <<EOF_STATE
GOTIFY_ROOT=${GOTIFY_ROOT@Q}
GOTIFY_DATA_DIR=${GOTIFY_DATA_DIR@Q}
GOTIFY_COMPOSE_FILE=${GOTIFY_COMPOSE_FILE@Q}
INTERNAL_PORT=${INTERNAL_PORT@Q}
PUBLIC_PORT=${PUBLIC_PORT@Q}
DOMAIN=${DOMAIN@Q}
GOTIFY_ADMIN_USER=${GOTIFY_ADMIN_USER@Q}
GOTIFY_ADMIN_PASS=${GOTIFY_ADMIN_PASS@Q}
GOTIFY_BASE_URL=${GOTIFY_BASE_URL@Q}
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

prompt_basic_config() {
    load_state
    echo "Gotify 基础配置："
    echo "1) 会优先读取 ${ISM_STATE_FILE} 里的 DOMAIN，证书位置沿用 /etc/letsencrypt/live/域名/"
    echo "2) 默认容器内部映射端口：127.0.0.1:${INTERNAL_PORT}"
    echo "3) 默认外部 Nginx 端口：${PUBLIC_PORT}，避免占用你现有脚本的 2083"
    echo

    read -r -p "请输入 Gotify 域名 [${DOMAIN:-可留空用 IP}]: " input_domain
    if [ -n "${input_domain:-}" ]; then DOMAIN="$input_domain"; fi

    read -r -p "请输入外部访问端口 [${PUBLIC_PORT}]: " input_public_port
    if [ -n "${input_public_port:-}" ]; then PUBLIC_PORT="$input_public_port"; fi

    read -r -p "请输入本机内部端口 [${INTERNAL_PORT}]: " input_internal_port
    if [ -n "${input_internal_port:-}" ]; then INTERNAL_PORT="$input_internal_port"; fi

    read -r -p "请输入 Gotify 管理员用户名 [${GOTIFY_ADMIN_USER}]: " input_user
    if [ -n "${input_user:-}" ]; then GOTIFY_ADMIN_USER="$input_user"; fi

    read -r -s -p "请输入 Gotify 管理员密码 [留空则自动生成/保持现有]: " input_pass
    echo
    if [ -n "${input_pass:-}" ]; then
        GOTIFY_ADMIN_PASS="$input_pass"
    elif [ -z "${GOTIFY_ADMIN_PASS:-}" ]; then
        GOTIFY_ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    fi

    if [ -n "${DOMAIN:-}" ]; then
        GOTIFY_BASE_URL="https://${DOMAIN}:${PUBLIC_PORT}"
    else
        local ip
        ip="$(get_host_ip || true)"
        GOTIFY_BASE_URL="http://${ip:-服务器IP}:${PUBLIC_PORT}"
    fi

    save_state
    ok "配置已保存：${GOTIFY_STATE_FILE}"
}

write_compose() {
    mkdir -p "$GOTIFY_ROOT" "$GOTIFY_DATA_DIR"
    cat > "$GOTIFY_COMPOSE_FILE" <<EOF_COMPOSE
services:
  gotify:
    image: gotify/server:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${INTERNAL_PORT}:80"
    environment:
      - TZ=Asia/Shanghai
      - GOTIFY_DEFAULTUSER_NAME=${GOTIFY_ADMIN_USER}
      - GOTIFY_DEFAULTUSER_PASS=${GOTIFY_ADMIN_PASS}
      - GOTIFY_REGISTRATION=false
      - GOTIFY_SERVER_PORT=80
    volumes:
      - ./data:/app/data
EOF_COMPOSE
    ok "Docker Compose 已写入：${GOTIFY_COMPOSE_FILE}"
}

start_gotify() {
    local cmd
    cmd="$(compose_cmd)"
    info "启动 Gotify 容器"
    (cd "$GOTIFY_ROOT" && $cmd up -d)

    if wait_for_port "$INTERNAL_PORT" 30; then
        ok "Gotify 已监听 127.0.0.1:${INTERNAL_PORT}"
    else
        warn "暂未检测到 ${INTERNAL_PORT} 端口监听，请执行：cd ${GOTIFY_ROOT} && ${cmd} logs --tail=100 gotify"
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
    if [ -n "${DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
        write_nginx_https
        GOTIFY_BASE_URL="https://${DOMAIN}:${PUBLIC_PORT}"
        ok "检测到证书，已配置 ${GOTIFY_BASE_URL}"
    else
        write_nginx_http
        if [ -n "${DOMAIN:-}" ]; then
            GOTIFY_BASE_URL="http://${DOMAIN}:${PUBLIC_PORT}"
            warn "未找到 /etc/letsencrypt/live/${DOMAIN}/ 证书，已配置为 ${GOTIFY_BASE_URL}"
        else
            local ip
            ip="$(get_host_ip || true)"
            GOTIFY_BASE_URL="http://${ip:-服务器IP}:${PUBLIC_PORT}"
            warn "未填写域名，已配置为 ${GOTIFY_BASE_URL}"
        fi
    fi

    ln -sf "$NGINX_SITE_FILE" "$NGINX_SITE_LINK"
    nginx -t
    systemctl restart nginx
    sleep 1
    save_state

    if wait_for_port "$PUBLIC_PORT" 10; then
        ok "Nginx 配置完成，已监听端口 ${PUBLIC_PORT}"
    else
        warn "Nginx 已重启，但暂未检测到 ${PUBLIC_PORT} 端口监听，请执行：systemctl status nginx --no-pager"
    fi
}

install_gotify_all() {
    load_state
    install_dependencies
    prompt_basic_config
    write_compose
    start_gotify
    configure_nginx
    print_access_info
}

restart_gotify() {
    load_state
    local cmd
    cmd="$(compose_cmd)"
    info "重启 Gotify"
    (cd "$GOTIFY_ROOT" && $cmd restart gotify)
    systemctl restart nginx
    ok "Gotify 和 Nginx 已重启"
}

show_status() {
    load_state
    local cmd
    cmd="$(compose_cmd || true)"
    echo "Gotify 状态"
    echo "  安装目录：${GOTIFY_ROOT}"
    echo "  数据目录：${GOTIFY_DATA_DIR}"
    echo "  Compose：${GOTIFY_COMPOSE_FILE}"
    echo "  域名：${DOMAIN:-未设置}"
    echo "  内部端口：127.0.0.1:${INTERNAL_PORT}"
    echo "  外部端口：${PUBLIC_PORT}"
    echo "  访问地址：${GOTIFY_BASE_URL:-未生成}"
    echo "  Nginx 配置：${NGINX_SITE_FILE}"
    echo

    if [ -n "$cmd" ] && [ -f "$GOTIFY_COMPOSE_FILE" ]; then
        (cd "$GOTIFY_ROOT" && $cmd ps) || true
    else
        warn "未检测到 Compose 文件或 Docker Compose"
    fi

    echo
    echo "端口监听："
    ss -lntp 2>/dev/null | grep -E ":(${INTERNAL_PORT}|${PUBLIC_PORT})\b" || true
}

print_access_info() {
    load_state
    echo
    printf "${BOLD}${GREEN}Gotify 部署完成${NC}\n"
    echo "访问地址：${GOTIFY_BASE_URL}"
    echo "管理员账号：${GOTIFY_ADMIN_USER}"
    echo "管理员密码：${GOTIFY_ADMIN_PASS}"
    echo
    echo "下一步："
    echo "1) 浏览器打开 Gotify，进入 Apps / Applications"
    echo "2) 创建一个应用，例如 LET RSS"
    echo "3) 复制 Application Token"
    echo "4) 在 RSS 项目的 data/config.json 里填入："
    echo
    cat <<EOF_CFG
{
  "notice_type": "gotify",
  "gotify_url": "${GOTIFY_BASE_URL}/",
  "gotify_token": "你的 Application Token",
  "gotify_priority": 5
}
EOF_CFG
    echo
    echo "安卓端：安装 Gotify App，服务器地址填 ${GOTIFY_BASE_URL}，用上面的管理员账号登录。"
}

test_push() {
    load_state
    read -r -p "请输入 Gotify Application Token: " app_token
    if [ -z "${app_token:-}" ]; then
        err "Application Token 不能为空"
        return 1
    fi

    local url
    url="${GOTIFY_BASE_URL%/}/message?token=${app_token}"
    info "发送测试推送到：${GOTIFY_BASE_URL}"
    curl -fsS -X POST "$url" \
        -H "Content-Type: application/json" \
        -d '{"title":"LET RSS Gotify 测试","message":"**Gotify Markdown 测试成功**\n\n- 推送通道：gotify\n- 链接：https://gotify.net/","priority":5,"extras":{"client::display":{"contentType":"text/markdown"}}}'
    echo
    ok "测试推送已发送"
}


test_push_from_let_config() {
    local config_file
    config_file="/root/let/data/config.json"

    read -r -p "请输入 RSS 配置文件路径 [${config_file}]: " input_config_file
    if [ -n "${input_config_file:-}" ]; then
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
    print("[ERR] 推送函数返回 False，请检查 notice_type、URL、Token、网络和服务端日志")
    raise SystemExit(2)
PY_TEST_PUSH

    ok "已按 ${config_file} 执行测试推送"
}

reset_admin_by_reinit() {
    load_state
    warn "Gotify 账号密码只在首次初始化数据库时创建。"
    warn "该操作会停止容器，把当前数据目录备份，然后用当前用户名/新密码重新初始化。"
    warn "注意：旧的 Apps、Application Token、消息记录会留在备份目录，不会自动迁回。"
    echo
    read -r -p "请输入管理员用户名 [${GOTIFY_ADMIN_USER:-admin}]: " input_user
    if [ -n "${input_user:-}" ]; then GOTIFY_ADMIN_USER="$input_user"; fi
    read -r -s -p "请输入新的管理员密码 [留空自动生成]: " input_pass
    echo
    if [ -n "${input_pass:-}" ]; then
        GOTIFY_ADMIN_PASS="$input_pass"
    else
        GOTIFY_ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    fi

    read -r -p "输入 RESET 确认重置 Gotify 登录账号: " confirm_text
    if [ "${confirm_text:-}" != "RESET" ]; then
        warn "已取消重置"
        return 0
    fi

    local cmd ts backup_dir
    cmd="$(compose_cmd)"
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_dir="${GOTIFY_ROOT}/data.bak.${ts}"

    if [ -f "$GOTIFY_COMPOSE_FILE" ]; then
        (cd "$GOTIFY_ROOT" && $cmd down) || true
    fi

    if [ -d "$GOTIFY_DATA_DIR" ] && [ -n "$(find "$GOTIFY_DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]; then
        mv "$GOTIFY_DATA_DIR" "$backup_dir"
        ok "旧数据目录已备份：${backup_dir}"
    fi

    mkdir -p "$GOTIFY_DATA_DIR"
    save_state
    write_compose
    start_gotify
    configure_nginx

    ok "Gotify 登录账号已重新初始化"
    echo "访问地址：${GOTIFY_BASE_URL}"
    echo "管理员账号：${GOTIFY_ADMIN_USER}"
    echo "管理员密码：${GOTIFY_ADMIN_PASS}"
    echo "旧数据备份：${backup_dir}"
}

uninstall_gotify() {
    load_state
    warn "该操作会停止并删除 Gotify 容器、Nginx 反代配置。"
    warn "默认不会删除数据目录：${GOTIFY_DATA_DIR}"
    read -r -p "输入 YES 确认卸载 Gotify: " confirm_text
    if [ "${confirm_text:-}" != "YES" ]; then
        warn "已取消卸载"
        return 0
    fi

    local cmd
    cmd="$(compose_cmd || true)"
    if [ -n "${cmd:-}" ] && [ -f "$GOTIFY_COMPOSE_FILE" ]; then
        (cd "$GOTIFY_ROOT" && $cmd down) || true
    fi

    rm -f "$NGINX_SITE_LINK" "$NGINX_SITE_FILE"
    nginx -t && systemctl restart nginx || true

    read -r -p "是否同时删除 Gotify 数据目录 ${GOTIFY_ROOT} ? 输入 DELETE 确认删除: " delete_text
    if [ "${delete_text:-}" = "DELETE" ]; then
        rm -rf "$GOTIFY_ROOT"
        ok "Gotify 数据目录已删除"
    else
        warn "保留数据目录：${GOTIFY_ROOT}"
    fi

    rm -f "$GOTIFY_STATE_FILE"
    ok "Gotify 已卸载"
}

show_menu() {
    clear
    printf "\n"
    printf "${BOLD}${BLUE}=========================================================================${NC}\n"
    printf "${BOLD}${WHITE}                 Gotify 安装 / 反代 / 配置菜单                           ${NC}\n"
    printf "${BOLD}${BLUE}=========================================================================${NC}\n"
    printf "${BOLD}${GREEN} [1] 一键安装 / 重装 Gotify${NC}      ${WHITE}Docker 部署 + Nginx 反代 + 复用证书路径${NC}\n"
    printf "${BOLD}${CYAN}  [2] 仅重写 Nginx 反代${NC}          ${WHITE}修改域名/端口后单独刷新反代${NC}\n"
    printf "${BOLD}${CYAN}  [3] 重启 Gotify${NC}                ${WHITE}重启容器和 Nginx${NC}\n"
    printf "${BOLD}${YELLOW} [4] 查看状态${NC}                   ${WHITE}查看容器、端口、访问地址${NC}\n"
    printf "${BOLD}${YELLOW} [5] 测试推送${NC}                   ${WHITE}输入 Application Token 后发一条 Markdown 测试${NC}\n"
    printf "${BOLD}${GREEN} [6] 输出 RSS 配置片段${NC}          ${WHITE}复制到 data/config.json${NC}\n"
    printf "${BOLD}${YELLOW} [7] 读取 RSS 配置测试推送${NC}      ${WHITE}/root/let/data/config.json -> send.py${NC}\n"
    printf "${BOLD}${MAGENTA} [8] 重置登录账号${NC}              ${WHITE}备份旧数据并重新初始化管理员账号${NC}\n"
    printf "${BOLD}${RED}   [9] 卸载 Gotify${NC}               ${YELLOW}删除容器和反代，可选择保留数据${NC}\n"
    printf "${BOLD}${RED}   [0] 退出${NC}\n"
    printf "${BOLD}${BLUE}-------------------------------------------------------------------------${NC}\n"
    printf "${BOLD}${YELLOW} ★ 默认外部端口：${NC}${GREEN}${PUBLIC_PORT}${NC}${WHITE}，避免与你现有 asset_manager 的 2083 冲突${NC}\n"
    printf "${BOLD}${YELLOW} ★ 证书路径：${NC}${GREEN}/etc/letsencrypt/live/域名/fullchain.pem${NC}\n"
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
            1) install_gotify_all ;;
            2) prompt_basic_config; configure_nginx; print_access_info ;;
            3) restart_gotify ;;
            4) show_status ;;
            5) test_push ;;
            6) print_access_info ;;
            7) test_push_from_let_config ;;
            8) reset_admin_by_reinit ;;
            9) uninstall_gotify ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
        echo
        read -r -p "按回车继续..." _
    done
}

main "$@"
