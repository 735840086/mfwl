#!/usr/bin/env bash
# =============================================================================
# MTProxy 一键部署 / 管理脚本（整合版）
#
# 定位：把 ellermister/mtproxy 的「Fake TLS」用法收敛成单文件脚本，
#       不依赖 web.sh / caddy / tproxy-server，只保留三种可用实现：
#         1) MTProxy   Telegram 官方 mtproto-proxy（仅 amd64）
#         2) mtg       9seconds 的 Go 实现（推荐，单文件静态二进制）
#         3) mtprotoproxy  alexbers 的 Python 实现（无可用二进制时的退路）
#
# 用法：
#   bash mtproxy.sh                 交互菜单
#   bash mtproxy.sh install         安装（交互填参数）
#   bash mtproxy.sh start|stop|restart
#   bash mtproxy.sh status          状态 + 一键链接
#   bash mtproxy.sh config          改配置
#   bash mtproxy.sh logs            看日志
#   bash mtproxy.sh check-tg        检测到 Telegram 的连通性
#   bash mtproxy.sh uninstall       卸载
#   bash mtproxy.sh doctor          环境诊断（目录/配置/systemd/日志）
#   bash mtproxy.sh selftest        本地自检（不联网、不改系统）
#
# 非交互安装：
#   bash mtproxy.sh install --port 8443 --admin-port 8888 \
#        --domain cloudflare.com --provider 2 --tag "" --secret ""
#   --no-systemd 强制用 nohup 后台方式；--force 跳过端口占用确认
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# 基础路径 / 全局变量
# ---------------------------------------------------------------------------
SELF_NAME=$(basename -- "$0")
SCRIPT_DIR=${MTPROXY_HOME:-$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd -P)}
# 脚本放在 / 或系统 bin 目录下时，BIN_DIR 会变成 /bin、配置写到 /config，
# systemd 的 ExecStart 也会拼出 //xxx 这种路径 —— 直接拦掉，要求独立目录
if [[ -z "${MTPROXY_HOME:-}" ]]; then
    case "$SCRIPT_DIR" in
        /|/bin|/sbin|/usr/bin|/usr/sbin|/etc|/usr|/usr/local/bin)
            printf '\033[31m[ERROR]\033[0m 脚本不能放在 %s 下运行（会把程序装进系统目录）。\n' "$SCRIPT_DIR" >&2
            printf '请放到独立目录，例如：\n  mkdir -p /root/mtproxy && cd /root/mtproxy\n  bash mtproxy-fixed.sh\n' >&2
            exit 1
            ;;
    esac
    if [[ ! -w "$SCRIPT_DIR" ]]; then
        printf '\033[31m[ERROR]\033[0m 目录不可写：%s（需要 root 或换目录）\n' "$SCRIPT_DIR" >&2
        exit 1
    fi
fi
BIN_DIR="$SCRIPT_DIR/bin"
RUN_DIR="$SCRIPT_DIR/runtime"
LOG_DIR="$RUN_DIR/log"
PID_FILE="$RUN_DIR/mtproxy.pid"
CONFIG_FILE="$SCRIPT_DIR/config"
IP_CACHE="$RUN_DIR/public_ip"
RUN_LOG="$LOG_DIR/run.log"
UNIT_PATH=/etc/systemd/system/mtproxy.service
UNIT_NAME=mtproxy.service

RELEASE_BASE="https://github.com/ellermister/mtproxy/releases/download/v0.04"
PY_PROXY_ZIP="https://github.com/alexbers/mtprotoproxy/archive/refs/heads/master.zip"

SECRET=""
PORT=""
ADMIN_PORT=""
DOMAIN=""
ADTAG=""
PROVIDER=""
PUBLIC_IP=""
PYTHON_BIN=""

FLAG_NO_SYSTEMD=0
FLAG_FORCE=0
FLAG_YES=0
FLAG_PORT=""
FLAG_ADMIN_PORT=""
FLAG_DOMAIN=""
FLAG_TAG=""
FLAG_SECRET=""
FLAG_PROVIDER=""

# 颜色（非 tty 时自动关闭）
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'; C_BOLD=$'\033[1m'; C_END=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_GRAY=""; C_BOLD=""; C_END=""
fi

line() { printf '%s\n' "========================================="; }
info() { printf '%s[INFO]%s %s\n' "$C_GREEN" "$C_END" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_END" "$*"; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_END" "$*" >&2; }
die()  { line >&2; err "$*"; line >&2; exit 1; }
subject()     { printf '\n%s> %s%s\n' "$C_GREEN" "$*" "$C_END"; }
# 交互取值时提示必须走 stderr，否则会被 $( ) 一起捕获进变量（原实现就踩了这个坑）
subject_e()   { subject "$@" >&2; }
warn_e()      { warn "$@" >&2; }
info_e()      { info "$@" >&2; }

# ---------------------------------------------------------------------------
# 环境与权限
# ---------------------------------------------------------------------------
ensure_dirs() {
    mkdir -p "$BIN_DIR" "$RUN_DIR/pid" "$LOG_DIR" 2>/dev/null || true
    # 运行目录里有 secret，日志里有 mtg 打印的完整配置，不能让同机其它用户读到
    chmod 700 "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true
    if [[ ! -f "$RUN_LOG" ]]; then : >"$RUN_LOG" 2>/dev/null || true; fi
    chmod 600 "$RUN_LOG" "$PID_FILE" 2>/dev/null || true
}

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "该操作需要 root 权限，请用 sudo 运行：sudo bash $SELF_NAME $*"
    fi
}

have_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

use_systemd() {
    (( FLAG_NO_SYSTEMD == 0 )) && have_systemd
}

# ---------------------------------------------------------------------------
# 包管理器
# ---------------------------------------------------------------------------
detect_pkg() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v apk >/dev/null 2>&1; then echo apk
    else echo none
    fi
}

pkg_install() {
    local pkg="$1"
    case "$(detect_pkg)" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$pkg" \
                >>"$RUN_LOG" 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" >>"$RUN_LOG" 2>&1
            ;;
        dnf) dnf install -y -q "$pkg" >>"$RUN_LOG" 2>&1 ;;
        yum) yum install -y -q "$pkg" >>"$RUN_LOG" 2>&1 ;;
        apk) apk add --no-cache "$pkg" >>"$RUN_LOG" 2>&1 ;;
        *)   return 1 ;;
    esac
}

ensure_deps() {
    ensure_dirs
    local missing=() cmd
    for cmd in curl wget tar unzip ss; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) && return 0

    info "安装基础依赖：${missing[*]}"
    case "$(detect_pkg)" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -q >>"$RUN_LOG" 2>&1 || true
            pkg_install iproute2 || true
            command -v curl >/dev/null 2>&1 || pkg_install curl || true
            command -v wget >/dev/null 2>&1 || pkg_install wget || true
            command -v tar  >/dev/null 2>&1 || pkg_install tar  || true
            command -v unzip >/dev/null 2>&1 || pkg_install unzip || true
            ;;
        dnf|yum|apk)
            pkg_install iproute || true
            command -v curl >/dev/null 2>&1 || pkg_install curl || true
            command -v wget >/dev/null 2>&1 || pkg_install wget || true
            command -v unzip >/dev/null 2>&1 || pkg_install unzip || true
            ;;
    esac

    command -v curl >/dev/null 2>&1 || die "没有 curl，无法下载程序，请先手动安装 curl"
    command -v ss   >/dev/null 2>&1 || [[ -x /usr/sbin/ss ]] || warn "没有 ss（iproute2），端口检测将退化"
    return 0
}

# ---------------------------------------------------------------------------
# 网络 / IP / 架构
# ---------------------------------------------------------------------------
valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=. o
    for o in $1; do (( o >= 0 && o <= 255 )) || return 1; done
    return 0
}

fetch_public_ip() {
    local d ip
    d=$(mktemp -d) || return 1
    curl -4 -fsS --connect-timeout 5 --max-time 8 -A "mtproxy-manager/1.0" \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' >"$d/a" &
    curl -4 -fsS --connect-timeout 5 --max-time 8 -A "mtproxy-manager/1.0" \
        https://api.ip.sb/ip 2>/dev/null | tr -d ' \n\r' >"$d/b" &
    curl -4 -fsS --connect-timeout 5 --max-time 8 -A "mtproxy-manager/1.0" \
        https://ipinfo.io/ip 2>/dev/null | tr -d ' \n\r' >"$d/c" &
    wait

    for f in "$d"/a "$d"/b "$d"/c; do
        ip=$(head -c 64 "$f" 2>/dev/null | tr -d ' \n\r\t')
        valid_ipv4 "$ip" && printf '%s\n' "$ip"
    done | sort | uniq -c | sort -rn | awk 'NR==1{print $2}' >"$d/out"

    ip=$(tr -d ' \n\r' <"$d/out" 2>/dev/null || true)
    rm -rf "$d"
    if valid_ipv4 "$ip"; then
        printf '%s\n' "$ip"
        return 0
    fi
    return 1
}

get_public_ip() {
    local ip
    if [[ -n "$PUBLIC_IP" ]] && valid_ipv4 "$PUBLIC_IP"; then
        printf '%s\n' "$PUBLIC_IP"; return 0
    fi
    if [[ -s "$IP_CACHE" ]]; then
        ip=$(tr -d ' \n\r' <"$IP_CACHE")
        if valid_ipv4 "$ip"; then PUBLIC_IP="$ip"; printf '%s\n' "$ip"; return 0; fi
    fi
    ip=$(fetch_public_ip) || return 1
    PUBLIC_IP="$ip"
    ensure_dirs
    printf '%s\n' "$ip" >"$IP_CACHE" 2>/dev/null || true
    printf '%s\n' "$ip"
}

local_ipv4() {
    ss -4 -lnt 2>/dev/null | awk 'NR>1{print $4}' | sed 's/:[0-9]*$//' | grep -vE '^(127\.|0\.0\.0\.0|\*)$' | head -1 \
      || ip -4 addr show scope global 2>/dev/null | awk '/inet /{sub("/.*","",$2); print $2; exit}'
}

has_ipv6() { ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; }

# 发布包命名用的是 uname -m（x86_64-mtg / aarch64-mtg）
arch_uname() { uname -m; }

arch_tag() {
    case "$(uname -m)" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        i386|i686)     echo 386 ;;
        *)             echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# 端口 / 进程
# ---------------------------------------------------------------------------
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

port_pids() {
    local port="$1" pids=""
    pids=$(ss -lntp "sport = :$port" 2>/dev/null | awk 'NR>1{print $NF}' \
           | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' ')
    if [[ -z "$pids" ]] && command -v lsof >/dev/null 2>&1; then
        pids=$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null | tr '\n' ' ')
    fi
    printf '%s' "$pids"
}

pid_alive() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

pid_cmdline() { tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null || true; }

# 只杀「明显是本脚本拉起」的进程；其它占用者必须用户确认
kill_port_owner() {
    local port="$1" pids p cmd
    pids=$(port_pids "$port")
    [[ -z "$pids" ]] && return 0
    for p in $pids; do
        cmd=$(pid_cmdline "$p")
        case "$cmd" in
            *mtg*|*mtproto-proxy*|*mtprotoproxy*|*mtproxy*)
                info "结束占用端口 $port 的旧代理进程 (pid=$p)"
                kill -TERM "$p" 2>/dev/null || true
                sleep 1
                pid_alive "$p" && kill -KILL "$p" 2>/dev/null || true
                ;;
            *)
                if (( FLAG_FORCE == 1 )); then
                    warn "强制结束端口 $port 上的进程：pid=$p ($cmd)"
                    kill -KILL "$p" 2>/dev/null || true
                else
                    err "端口 $port 被其它程序占用：pid=$p ($cmd)"
                    err "换一个端口，或加 --force 强制结束（有误杀风险）"
                    return 1
                fi
                ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# 配置读写（不用 source，避免配置文件被塞入任意命令）
# ---------------------------------------------------------------------------
cfg_get() {
    local key="$1" file="${2:-$CONFIG_FILE}" raw
    [[ -f "$file" ]] || return 1
    raw=$(grep -m1 -E "^[[:space:]]*${key}=" "$file" 2>/dev/null) || return 1
    raw=${raw#*=}
    raw=${raw%\"}
    raw=${raw#\"}
    printf '%s\n' "$raw"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    SECRET=$(cfg_get secret || true)
    PORT=$(cfg_get port || true)
    ADMIN_PORT=$(cfg_get statport || true)
    DOMAIN=$(cfg_get domain || true)
    ADTAG=$(cfg_get adtag || true)
    PROVIDER=$(cfg_get provider || true)
    [[ "$PROVIDER" =~ ^[123]$ ]] || PROVIDER=2
    [[ "$PORT" =~ ^[0-9]+$ ]] || PORT=""
    [[ "$ADMIN_PORT" =~ ^[0-9]+$ ]] || ADMIN_PORT=""
    return 0
}

save_config() {
    ensure_dirs
    umask 077
    cat >"$CONFIG_FILE" <<EOF
#!/bin/bash
# MTProxy 配置（${SELF_NAME} 生成）
proxy_mode="tls"
secret="${SECRET}"
port=${PORT}
statport=${ADMIN_PORT}
domain="${DOMAIN}"
adtag="${ADTAG}"
provider=${PROVIDER}
EOF
    chmod 600 "$CONFIG_FILE"
}

gen_secret() {
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

str_to_hex() {
    printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

client_secret() {
    # Fake TLS 客户端密钥：ee + secret + hex(domain)
    printf 'ee%s%s' "$SECRET" "$(str_to_hex "$DOMAIN")"
}

provider_name() {
    case "$1" in
        1) echo "MTProxy 官方版" ;;
        2) echo "mtg (9seconds)" ;;
        3) echo "mtprotoproxy (alexbers)" ;;
        *) echo "未知" ;;
    esac
}

provider_available() {
    # 官方版只有 amd64 二进制
    [[ "$1" == "1" ]] && [[ "$(arch_tag)" != "amd64" ]] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# 下载
# ---------------------------------------------------------------------------
download() {
    local url="$1" dest="$2" tmp="$2.part"
    ensure_dirs
    rm -f "$tmp"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 \
             -A "mtproxy-manager/1.0" -o "$tmp" "$url" >>"$RUN_LOG" 2>&1 || {
            rm -f "$tmp"; err "下载失败: $url"; return 1; }
    else
        wget -q --tries=3 --timeout=15 -O "$tmp" "$url" >>"$RUN_LOG" 2>&1 || {
            rm -f "$tmp"; err "下载失败: $url"; return 1; }
    fi
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"; err "下载内容为空: $url"; return 1
    fi
    mv -f "$tmp" "$dest"
    return 0
}

# ---------------------------------------------------------------------------
# 安装各实现
# ---------------------------------------------------------------------------
install_mtg() {
    local dest="$BIN_DIR/mtg" url
    url="$RELEASE_BASE/$(arch_uname)-mtg"
    info "下载 mtg：$url"
    download "$url" "$dest" || return 1
    chmod +x "$dest"
    if ! "$dest" --version >/dev/null 2>&1 && ! "$dest" -h >/dev/null 2>&1; then
        warn "mtg 无法执行，可能是架构不匹配或缺少运行库"
        return 1
    fi
    local ver
    ver=$("$dest" --version 2>/dev/null | head -1 || true)
    if [[ -n "$ver" ]]; then info "mtg 就绪：$ver"; else info "mtg 就绪"; fi
    return 0
}

install_official() {
    local dest="$BIN_DIR/mtproto-proxy"
    [[ "$(arch_tag)" == "amd64" ]] || { err "官方 MTProxy 只提供 amd64 二进制"; return 1; }
    info "下载 mtproto-proxy：$RELEASE_BASE/mtproto-proxy"
    download "$RELEASE_BASE/mtproto-proxy" "$dest" || return 1
    chmod +x "$dest"
    # 官方二进制不带参数运行时退出码为 2，属正常
    "$dest" >/dev/null 2>&1
    local rc=$?
    if (( rc != 0 && rc != 2 )); then
        err "mtproto-proxy 无法运行（退出码 $rc）"
        return 1
    fi
    info "mtproto-proxy 就绪"
    return 0
}

install_python_proxy() {
    local zip="$RUN_DIR/mtprotoproxy.zip" dir="$RUN_DIR/mtprotoproxy" py
    py=$(command -v python3 || command -v python2 || true)
    [[ -n "$py" ]] || { err "Python 实现需要 python3，请先安装"; return 1; }
    PYTHON_BIN="$py"
    info "下载 mtprotoproxy 源码"
    download "$PY_PROXY_ZIP" "$zip" || return 1
    rm -rf "$dir"; mkdir -p "$dir"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$zip" -d "$dir" >>"$RUN_LOG" 2>&1 || { err "解压失败"; return 1; }
    else
        "$py" -c "import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$zip" "$dir" \
            >>"$RUN_LOG" 2>&1 || { err "解压失败（缺 unzip 且 python 解压出错）"; return 1; }
    fi
    local src
    src=$(find "$dir" -maxdepth 1 -type d -name 'mtprotoproxy-*' | head -1)
    [[ -n "$src" ]] || { err "压缩包结构异常"; return 1; }
    rm -rf "$BIN_DIR/mtprotoproxy"; mkdir -p "$BIN_DIR/mtprotoproxy"
    cp -a "$src"/. "$BIN_DIR/mtprotoproxy"/ || { err "复制失败"; return 1; }
    rm -rf "$dir" "$zip"
    [[ -f "$BIN_DIR/mtprotoproxy/mtprotoproxy.py" ]] || { err "缺少 mtprotoproxy.py"; return 1; }
    info "mtprotoproxy 就绪"
    return 0
}

do_install_provider() {
    case "$PROVIDER" in
        1) install_official ;;
        2) install_mtg ;;
        3) install_python_proxy ;;
        *) err "未知实现：$PROVIDER"; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 运行命令（统一入口，前台 exec，供 systemd / nohup 复用）
# ---------------------------------------------------------------------------
build_run_cmd() {
    RUN_CMD=()
    case "$PROVIDER" in
        2)
            local cs localip
            cs=$(client_secret)
            [[ -x "$BIN_DIR/mtg" ]] || return 1
            localip=$(local_ipv4)
            RUN_CMD=("$BIN_DIR/mtg" run "$cs")
            # 没有 TAG 时不要塞空参数，mtg 会把空串当成一个 tag
            [[ -n "$ADTAG" ]] && RUN_CMD+=("$ADTAG")
            RUN_CMD+=(--bind "0.0.0.0:$PORT")
            RUN_CMD+=(--multiplex-per-connection 500)
            RUN_CMD+=(--prefer-ip=ipv4)
            [[ -n "$localip" ]] && RUN_CMD+=(-t "$localip:$ADMIN_PORT")
            ;;
        3)
            local py
            py=${PYTHON_BIN:-$(command -v python3 || command -v python2 || true)}
            [[ -n "$py" ]] || return 1
            ensure_dirs
            cat >"$RUN_DIR/config.py" <<EOF
PORT = $PORT
USERS = {
    "tg":  "$SECRET",
}
MODES = {
    "classic": False,
    "secure": False,
    "tls": True
}
TLS_DOMAIN = "$DOMAIN"
AD_TAG = "$ADTAG"
EOF
            RUN_CMD=("$py" "$BIN_DIR/mtprotoproxy/mtprotoproxy.py" "$RUN_DIR/config.py")
            ;;
        1)
            [[ -x "$BIN_DIR/mtproto-proxy" ]] || return 1
            ensure_dirs
            if [[ ! -s "$RUN_DIR/proxy-multi.conf" ]]; then
                curl -fsS --connect-timeout 8 --max-time 20 \
                    https://core.telegram.org/getProxyConfig -o "$RUN_DIR/proxy-multi.conf" 2>>"$RUN_LOG" \
                    || warn "拉取 proxy-multi.conf 失败，官方版可能无法启动"
            fi
            if [[ ! -s "$RUN_DIR/proxy-secret" ]]; then
                curl -fsS --connect-timeout 8 --max-time 20 \
                    https://core.telegram.org/getProxySecret -o "$RUN_DIR/proxy-secret" 2>>"$RUN_LOG" \
                    || warn "拉取 proxy-secret 失败，官方版可能无法启动"
            fi
            RUN_CMD=("$BIN_DIR/mtproto-proxy" -p "$ADMIN_PORT" -H "$PORT" -S "$SECRET"
                     --aes-pwd "$RUN_DIR/proxy-secret" "$RUN_DIR/proxy-multi.conf"
                     -M "$(nproc 2>/dev/null || echo 2)")
            [[ -n "$ADTAG" ]] && RUN_CMD+=(-P "$ADTAG")
            [[ -n "$DOMAIN" ]] && RUN_CMD+=(--domain "$DOMAIN")
            local nat_ip
            nat_ip=$(local_ipv4)
            if [[ -n "$nat_ip" && -n "$PUBLIC_IP" && "$nat_ip" != "$PUBLIC_IP" ]]; then
                RUN_CMD+=(--nat-info "$nat_ip:$PUBLIC_IP")
            fi
            # 没有 IPv6 时不要传 --ipv6，否则部分系统直接起不来
            has_ipv6 && RUN_CMD+=(--ipv6)
            id nobody >/dev/null 2>&1 && RUN_CMD+=(-u nobody)
            ;;
        *) return 1 ;;
    esac
    return 0
}

# systemd / nohup 都执行的入口
do_run_foreground() {
    load_config || { err "配置不存在，请先 install"; return 1; }
    get_public_ip >/dev/null 2>&1 || warn "取不到公网 IP，官方版的 nat 参数会被跳过"
    build_run_cmd || { err "缺少运行文件，请先 install"; return 1; }
    exec "${RUN_CMD[@]}"
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
unit_exists() { [[ -f "$UNIT_PATH" ]]; }

systemd_install() {
    have_systemd || return 1
    cat >"$UNIT_PATH" <<EOF
[Unit]
Description=MTProxy ($(provider_name "$PROVIDER")) Fake TLS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=/bin/bash "${SCRIPT_DIR}/${SELF_NAME}" __run
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >>"$RUN_LOG" 2>&1
    systemctl enable "$UNIT_NAME" >>"$RUN_LOG" 2>&1
    return 0
}

systemd_diag() {
    # 启动失败时把真正的原因打出来，而不是只丢一句「未处于 active」
    command -v systemctl >/dev/null 2>&1 || return 0
    printf '\n%s--- systemctl status ---%s\n' "$C_GRAY" "$C_END" >&2
    systemctl status "$UNIT_NAME" --no-pager -l 2>&1 | tail -n 15 >&2
    printf '%s--- journal (最近 20 行) ---%s\n' "$C_GRAY" "$C_END" >&2
    journalctl -u "$UNIT_NAME" -n 20 --no-pager 2>&1 | tail -n 20 >&2
    printf '%s--- unit 文件 ---%s\n' "$C_GRAY" "$C_END" >&2
    sed -n '1,20p' "$UNIT_PATH" >&2 2>/dev/null || true
}

systemd_remove() {
    have_systemd || return 0
    systemctl stop "$UNIT_NAME" >>"$RUN_LOG" 2>&1 || true
    systemctl disable "$UNIT_NAME" >>"$RUN_LOG" 2>&1 || true
    rm -f "$UNIT_PATH"
    systemctl daemon-reload >>"$RUN_LOG" 2>&1 || true
}

# ---------------------------------------------------------------------------
# 启停
# ---------------------------------------------------------------------------
# nohup 后台方式（无 systemd，或 systemd 起不来时的降级路径）
start_nohup() {
    if is_running; then
        warn "已经在运行（pid $(cat "$PID_FILE" 2>/dev/null)），如需重载配置请 restart"
        return 0
    fi
    kill_port_owner "$PORT" || return 1
    kill_port_owner "$ADMIN_PORT" || return 1
    get_public_ip >/dev/null 2>&1 || warn "取不到公网 IP"
    load_config
    build_run_cmd || { err "缺少运行文件，请先 install"; return 1; }
    ensure_dirs
    nohup "${RUN_CMD[@]}" >>"$RUN_LOG" 2>&1 &
    echo $! >"$PID_FILE"
    sleep 2
    if is_running; then
        info "已启动（pid $(cat "$PID_FILE")，nohup 方式，重启机器后需手动 start）"
        print_link
        return 0
    fi
    err "启动失败，最近日志："
    tail -n 20 "$RUN_LOG" >&2
    rm -f "$PID_FILE"
    return 1
}

start_mtp() {
    need_root start
    ensure_deps
    load_config || die "配置不存在，请先运行：bash $SELF_NAME install"

    if use_systemd; then
        systemd_install || { warn "写入 systemd 单元失败，改用 nohup"; start_nohup; return $?; }
        # 先清掉可能残留的 nohup 进程，避免两个实例抢端口
        stop_mtp_quiet
        if systemctl start "$UNIT_NAME" >>"$RUN_LOG" 2>&1; then
            # Type=simple 下 active 会很快出现，但给 4 秒兜住启动竞态
            for _ in 1 2 3 4; do
                systemctl is-active --quiet "$UNIT_NAME" && break
                sleep 1
            done
            if systemctl is-active --quiet "$UNIT_NAME"; then
                info "已通过 systemd 启动（开机自启已开启）"
                print_link
                return 0
            fi
            err "systemd 报了成功，但服务随后退出（多半是配置/端口/二进制问题）"
        else
            err "systemd 启动命令返回失败"
        fi

        systemd_diag
        warn "systemd 托管失败，已自动降级为 nohup 前台进程（不会开机自启）"
        # 单元留着会一直失败重启，先停掉再降级
        systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
        start_nohup
        return $?
    fi

    start_nohup
}
stop_mtp_quiet() {
    if unit_exists && have_systemd; then
        systemctl stop "$UNIT_NAME" >>"$RUN_LOG" 2>&1 || true
    fi
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid=$(cat "$PID_FILE")
        if pid_alive "$pid"; then
            kill -TERM "$pid" 2>/dev/null || true
            for _ in 1 2 3 4 5; do
                pid_alive "$pid" || break
                sleep 1
            done
            pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

stop_mtp() {
    need_root stop
    local was=0
    is_running && was=1
    stop_mtp_quiet
    if (( was == 0 )); then
        warn "当前没有运行中的实例"
    else
        info "已停止"
    fi
    return 0
}

restart_mtp() {
    need_root restart
    stop_mtp_quiet
    start_mtp
}

is_running() {
    if unit_exists && have_systemd && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
        return 0
    fi
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid=$(cat "$PID_FILE" 2>/dev/null)
        pid_alive "$pid" && return 0
    fi
    # systemd 外的残留实例
    [[ -n "${PORT:-}" && -n "$(port_pids "$PORT" 2>/dev/null)" ]] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# 展示
# ---------------------------------------------------------------------------
print_link() {
    local cs ip
    load_config || return 0
    cs=$(client_secret)
    ip=$(get_public_ip 2>/dev/null || echo "服务器IP")
    echo
    printf '  实现      : %s\n' "$(provider_name "$PROVIDER")"
    printf '  服务器    : %s\n' "$ip"
    printf '  端口      : %s\n' "$PORT"
    printf '  伪装域名  : %s\n' "$DOMAIN"
    printf '  Secret    : %s\n' "$cs"
    printf '  一键链接  : %shttps://t.me/proxy?server=%s&port=%s&secret=%s%s\n' \
        "$C_CYAN" "$ip" "$PORT" "$cs" "$C_END"
    printf '  简化链接  : %stg://proxy?server=%s&port=%s&secret=%s%s\n' \
        "$C_CYAN" "$ip" "$PORT" "$cs" "$C_END"
    echo
}

status_mtp() {
    load_config || { err "未安装（缺少 $CONFIG_FILE）"; return 1; }
    if is_running; then
        printf '  运行状态  : %s运行中%s\n' "$C_GREEN" "$C_END"
    else
        printf '  运行状态  : %s已停止%s\n' "$C_YELLOW" "$C_END"
    fi
    if use_systemd && unit_exists; then
        printf '  托管方式  : systemd (%s)\n' "$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || echo unknown)"
    else
        printf '  托管方式  : nohup + pid 文件\n'
    fi
    print_link
}

# ---------------------------------------------------------------------------
# 交互输入
# ---------------------------------------------------------------------------
ask_port() {
    local title="$1" def="$2" other="${3:-}" val
    while true; do
        subject_e "$title（1-65535，默认 $def）"
        read -r -p "> " val
        val=${val:-$def}
        if ! valid_port "$val"; then
            warn_e "端口不合法：$val（必须是 1-65535 的整数）"
            continue
        fi
        if [[ -n "$other" && "$val" == "$other" ]]; then
            warn_e "不能与另一个端口相同（$other）"
            continue
        fi
        echo "$val"; return 0
    done
}

ask_domain() {
    local def="${1:-cloudflare.com}" val code
    while true; do
        subject_e "伪装域名（用于 Fake TLS，默认 $def）"
        read -r -p "> " val
        val=${val:-$def}
        val=${val#http://}; val=${val#https://}; val=${val%%/*}
        if [[ ! "$val" =~ ^[A-Za-z0-9._-]+$ ]]; then
            warn_e "域名格式不正确：$val"
            continue
        fi
        code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "https://$val" 2>/dev/null || echo 000)
        if [[ "$code" == "000" ]]; then
            code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://$val" 2>/dev/null || echo 000)
        fi
        case "$code" in
            2*|3*|403|404|000)
                info_e "域名 $val 可用（HTTP $code）"
                echo "$val"; return 0
                ;;
            *) warn_e "域名 $val 访问异常（HTTP $code），换个域名或重试" ;;
        esac
    done
}

ask_tag() {
    local val
    while true; do
        subject_e "推广 TAG（@MTProxybot 申请，32 位 hex；留空跳过）"
        read -r -p "> " val
        val=$(printf '%s' "$val" | tr -d ' \t')
        if [[ -z "$val" ]]; then echo ""; return 0; fi
        if [[ "$val" =~ ^[0-9a-fA-F]{32}$ ]]; then
            echo "${val,,}"; return 0
        fi
        warn_e "TAG 必须是 32 位十六进制字符"
    done
}

ask_provider() {
    local def="$1" val arch
    arch=$(arch_tag)
    while true; do
        subject_e "选择实现"
        if [[ "$arch" == "amd64" ]]; then
            printf '  %s1.%s MTProxy 官方版（仅 amd64，问题较多）\n' "$C_CYAN" "$C_END"
        else
            printf '  %s1.%s MTProxy 官方版 %s[当前架构不支持]%s\n' "$C_GRAY" "$C_END" "$C_YELLOW" "$C_END"
        fi
        printf '  %s2.%s mtg（Go，单文件，推荐）\n' "$C_CYAN" "$C_END"
        printf '  %s3.%s mtprotoproxy（Python，需要 python3）\n' "$C_CYAN" "$C_END"
        read -r -p "(默认 $def): " val
        val=${val:-$def}
        if [[ "$val" =~ ^[123]$ ]]; then
            if [[ "$val" == "1" && "$arch" != "amd64" ]]; then
                warn_e "当前架构 $(uname -m) 没有官方版二进制"
                continue
            fi
            echo "$val"; return 0
        fi
        warn_e "请输入 1 / 2 / 3"
    done
}

# ---------------------------------------------------------------------------
# 安装主流程
# ---------------------------------------------------------------------------
do_config_new() {
    local p a d t prov
    subject "开始配置（回车使用默认值）"
    p=$(ask_port "客户端连接端口" "443")
    a=$(ask_port "管理/统计端口（仅本地）" "8888" "$p")
    d=$(ask_domain "cloudflare.com")
    t=$(ask_tag)
    prov=$(ask_provider "2")

    PORT="$p"; ADMIN_PORT="$a"; DOMAIN="$d"; ADTAG="$t"; PROVIDER="$prov"
    SECRET=$(gen_secret)
    save_config
    info "配置已写入 $CONFIG_FILE（权限 600）"
}

install_mtp() {
    need_root install
    ensure_deps
    ensure_dirs

    local arch
    arch=$(arch_tag)
    [[ -n "$arch" ]] || die "不支持的架构：$(uname -m)"

    local have_config=0
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config
        have_config=1
    fi

    # 纯参数安装：端口/管理端口/域名/实现都给全了，就不走交互
    local noninteractive=1
    for v in "$FLAG_PORT" "$FLAG_ADMIN_PORT" "$FLAG_DOMAIN" "$FLAG_PROVIDER"; do
        [[ -n "$v" ]] || noninteractive=0
    done

    if (( have_config == 1 )) && (( FLAG_YES == 0 )) && (( noninteractive == 0 )); then
        warn "检测到已有配置：端口 $PORT / 域名 $DOMAIN / 实现 $(provider_name "$PROVIDER")"
        local ans
        read -r -p "沿用现有配置？[Y/n] " ans
        if [[ "${ans:-y}" == "n" ]]; then
            do_config_new
        fi
    elif (( have_config == 0 )) && (( noninteractive == 0 )); then
        do_config_new
    fi

    load_config 2>/dev/null || true

    # 命令行参数覆盖配置文件
    [[ -n "$FLAG_PORT" ]]       && PORT="$FLAG_PORT"
    [[ -n "$FLAG_ADMIN_PORT" ]] && ADMIN_PORT="$FLAG_ADMIN_PORT"
    [[ -n "$FLAG_DOMAIN" ]]     && DOMAIN="$FLAG_DOMAIN"
    [[ -n "$FLAG_TAG" ]]        && ADTAG="$FLAG_TAG"
    [[ -n "$FLAG_SECRET" ]]     && SECRET="$FLAG_SECRET"
    [[ -n "$FLAG_PROVIDER" ]]   && PROVIDER="$FLAG_PROVIDER"

    # 兜底与校验
    valid_port "${PORT:-}" || PORT=443
    valid_port "${ADMIN_PORT:-}" || ADMIN_PORT=8888
    [[ -n "${DOMAIN:-}" ]] || DOMAIN=cloudflare.com
    [[ "${PROVIDER:-}" =~ ^[123]$ ]] || PROVIDER=2
    if [[ -n "$ADMIN_PORT" && "$ADMIN_PORT" == "$PORT" ]]; then
        die "客户端端口与管理端口不能相同（$PORT）"
    fi
    [[ -n "${SECRET:-}" ]] || SECRET=$(gen_secret)
    if [[ ! "$SECRET" =~ ^[0-9a-f]{32}$ ]]; then
        die "secret 必须是 32 位十六进制"
    fi
    save_config
    [[ -n "$PUBLIC_IP" ]] || get_public_ip >/dev/null 2>&1 || warn "取不到公网 IP，稍后展示链接时会重试"

    # 端口占用检查（安装阶段就暴露，避免装完起不来）
    if [[ -n "${PORT:-}" && -n "$(port_pids "$PORT")" ]]; then
        warn "端口 $PORT 已被占用，启动前会尝试清理"
    fi

    do_install_provider || die "安装 $(provider_name "$PROVIDER") 失败"

    if use_systemd; then
        systemd_install && info "已写入 systemd 单元：$UNIT_PATH"
    else
        warn "系统没有 systemd，将使用 nohup 后台方式（开机不会自启）"
    fi

    info "安装完成，正在启动"
    start_mtp
}

# ---------------------------------------------------------------------------
# 配置修改
# ---------------------------------------------------------------------------
config_edit() {
    load_config || die "还没安装，先执行 install"
    local opt
    while true; do
        subject "修改配置（当前：端口 $PORT / 管理 $ADMIN_PORT / 域名 $DOMAIN / 实现 $(provider_name "$PROVIDER")）"
        cat <<EOF
  1) 客户端端口
  2) 管理端口
  3) 伪装域名
  4) 重新生成密钥
  5) 推广 TAG
  6) 更换实现
  0) 返回
EOF
        read -r -p "> " opt
        case "$opt" in
            1) PORT=$(ask_port "新的客户端端口" "$PORT") ;;
            2) ADMIN_PORT=$(ask_port "新的管理端口" "$ADMIN_PORT" "$PORT") ;;
            3) DOMAIN=$(ask_domain "$DOMAIN") ;;
            4) SECRET=$(gen_secret); info "已生成新密钥" ;;
            5) ADTAG=$(ask_tag) ;;
            6) PROVIDER=$(ask_provider "$PROVIDER"); do_install_provider || { warn "该实现安装失败，保留原实现"; continue; } ;;
            0) return 0 ;;
            *) warn "输入 0-6" ; continue ;;
        esac
        save_config
        info "已保存：$(provider_name "$PROVIDER") / 端口 $PORT / 域名 $DOMAIN"
        read -r -p "立即重启生效？[Y/n] " ans
        if [[ "${ans:-y}" != "n" ]]; then restart_mtp; fi
    done
}

# ---------------------------------------------------------------------------
# 日志 / 防火墙 / 连通性
# ---------------------------------------------------------------------------
show_logs() {
    local n="${1:-40}"
    if use_systemd && unit_exists; then
        journalctl -u "$UNIT_NAME" -n "$n" --no-pager 2>/dev/null || tail -n "$n" "$RUN_LOG"
    elif [[ -f "$RUN_LOG" ]]; then
        tail -n "$n" "$RUN_LOG"
    else
        warn "还没有日志文件：$RUN_LOG"
    fi
}

firewall_open() {
    local port="$1" did=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1 && { info "ufw 已放行 $port/tcp"; did=1; }
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1 \
            && firewall-cmd --reload >/dev/null 2>&1 && { info "firewalld 已放行 $port/tcp"; did=1; }
    fi
    if [[ "$did" == "0" ]] && command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 \
                && { info "iptables 已放行 $port/tcp（重启后失效，建议配合 iptables-persistent）"; did=1; }
        else
            did=1
        fi
    fi
    (( did == 0 )) && warn "没有可用的防火墙工具，或未启用防火墙，跳过"
    return 0
}

check_tg() {
    local url="https://core.telegram.org/getProxyConfig" cfg targets total ok=0 bad=0 target code
    cfg=$(mktemp); targets=$(mktemp)
    info "获取 Telegram 代理配置：$url"
    curl -fsSL --noproxy '*' --connect-timeout 5 --max-time 15 "$url" -o "$cfg" 2>/dev/null || {
        rm -f "$cfg" "$targets"; die "拉取失败，检查服务器到 Telegram 的网络"; }

    awk '/^proxy_for[[:space:]]/ {
        t=$NF; gsub(/;/, "", t);
        if (t ~ /^[0-9.]+:[0-9]+$/) print t
    }' "$cfg" | sort -u >"$targets"
    total=$(wc -l <"$targets" | tr -d ' ')
    rm -f "$cfg"
    if [[ "$total" -eq 0 ]]; then rm -f "$targets"; die "配置里没有可用的 IP:PORT"; fi

    info "共 $total 个目标，逐个测试 TCP 连通性（单次 3s）"
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        curl -s --noproxy '*' --connect-timeout 3 --max-time 3 -o /dev/null "http://$target" 2>/dev/null
        code=$?
        if [[ "$code" -eq 0 || "$code" -eq 52 ]]; then
            printf '  %s[OK]%s   %s\n' "$C_GREEN" "$C_END" "$target"; ok=$((ok+1))
        else
            printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_END" "$target"; bad=$((bad+1))
        fi
    done <"$targets"
    rm -f "$targets"
    info "结果：成功 $ok / 失败 $bad"
    (( ok > 0 )) && return 0
    return 1
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
uninstall() {
    need_root uninstall
    local ans
    echo
    warn "将停止服务并删除：$BIN_DIR、$RUN_DIR、$CONFIG_FILE、systemd 单元"
    read -r -p "确认卸载？[y/N] " ans
    [[ "${ans:-n}" == "y" ]] || { info "已取消"; return 0; }

    stop_mtp_quiet
    systemd_remove
    rm -rf "$BIN_DIR" "$RUN_DIR" "$CONFIG_FILE"
    info "已卸载（防火墙规则如需撤销请手动删除）"
    read -r -p "是否删除脚本所在目录（含本脚本）？[y/N] " ans
    if [[ "${ans:-n}" == "y" ]]; then
        cd /
        rm -rf "$SCRIPT_DIR"
        info "目录已删除：$SCRIPT_DIR"
    else
        info "保留目录：$SCRIPT_DIR"
    fi
}

# ---------------------------------------------------------------------------
# 自检（不联网、不动系统）
# ---------------------------------------------------------------------------
selftest() {
    local fails=0 tmp
    tmp=$(mktemp -d)
    t() { if eval "$2"; then printf '  [PASS] %s\n' "$1"; else printf '  [FAIL] %s\n' "$1"; fails=$((fails+1)); fi; }

    echo "== 参数校验 =="
    t "合法端口 443"            'valid_port 443'
    t "非法端口 0"              '! valid_port 0'
    t "非法端口 70000"          '! valid_port 70000'
    t "非法端口 08x"            '! valid_port 08x'

    echo "== IPv4 校验 =="
    t "1.2.3.4 合法"            'valid_ipv4 1.2.3.4'
    t "256.1.1.1 非法"          '! valid_ipv4 256.1.1.1'
    t "abc 非法"                '! valid_ipv4 abc'

    echo "== 域名转 hex / 客户端密钥 =="
    DOMAIN="cloudflare.com"; SECRET="00112233445566778899aabbccddeeff"
    local hexv
    hexv=$(str_to_hex "$DOMAIN")
    if [[ ${#hexv} -eq $(( ${#DOMAIN} * 2 )) ]]; then printf '  [PASS] hex 长度 = 域名长度*2\n'; else printf '  [FAIL] hex 长度\n'; fails=$((fails+1)); fi
    if [[ "$hexv" =~ ^[0-9a-f]+$ ]]; then printf '  [PASS] hex 只含 0-9a-f\n'; else printf '  [FAIL] hex 字符集\n'; fails=$((fails+1)); fi
    cs=$(client_secret)
    t "客户端密钥 ee 前缀"       '[[ "$cs" == ee* ]]'
    t "客户端密钥长度正确"       '[[ ${#cs} -eq $(( 2 + 32 + ${#DOMAIN} * 2 )) ]]'

    echo "== 配置读写（不 source，防注入） =="
    CONFIG_FILE="$tmp/config"
    PORT=8443; ADMIN_PORT=8888; DOMAIN="cloudflare.com"; ADTAG=""; PROVIDER=2
    SECRET="00112233445566778899aabbccddeeff"
    save_config
    t "配置文件权限 600"         '[[ $(stat -c %a "$CONFIG_FILE") == 600 ]]'
    PORT=""; ADMIN_PORT=""; DOMAIN=""; SECRET=""; PROVIDER=""
    load_config
    t "端口回读正确"             '[[ "$PORT" == 8443 ]]'
    t "管理端口回读正确"         '[[ "$ADMIN_PORT" == 8888 ]]'
    t "域名回读正确"             '[[ "$DOMAIN" == "cloudflare.com" ]]'
    t "实现回读正确"             '[[ "$PROVIDER" == 2 ]]'
    cat >"$CONFIG_FILE" <<EOF
secret="x"; port=443; domain="a.com"; provider=2
; rm -rf /tmp/should_not_exist
\$(touch /tmp/should_not_exist)
EOF
    SECRET=""; load_config || true
    t "恶意配置不会被执行"        '[[ ! -e /tmp/should_not_exist ]]'

    echo "== 架构映射 =="
    t "当前架构有映射值"          '[[ -n "$(arch_tag)" ]]'

    rm -rf "$tmp"
    echo
    if (( fails == 0 )); then echo "自检全部通过"; return 0; fi
    echo "$fails 项失败"; return 1
}

# ---------------------------------------------------------------------------
# 环境诊断（出问题时一条命令看全）
# ---------------------------------------------------------------------------
doctor() {
    line
    printf '  %s环境诊断%s\n' "$C_BOLD" "$C_END"
    line
    printf '脚本目录   : %s\n' "$SCRIPT_DIR"
    printf '配置       : %s\n' "$CONFIG_FILE"
    [[ -f "$CONFIG_FILE" ]] && printf '配置权限   : %s\n' "$(stat -c %a "$CONFIG_FILE" 2>/dev/null || echo '?')"
    printf 'bin 目录   : %s\n' "$BIN_DIR"
    if [[ -d "$BIN_DIR" ]]; then
        printf 'bin 内容   : %s\n' "$(ls -1 "$BIN_DIR" 2>/dev/null | tr '\n' ' ')"
    fi
    printf '运行目录   : %s\n' "$RUN_DIR"
    if load_config 2>/dev/null; then
        printf '当前配置   : 端口 %s / 管理 %s / 域名 %s / 实现 %s\n' \
            "$PORT" "$ADMIN_PORT" "$DOMAIN" "$(provider_name "$PROVIDER")"
        printf '端口监听   : %s\n' "$(port_pids "$PORT" | tr -d '\n' | sed 's/^/pid /')"
        printf '管理端口   : %s\n' "$(port_pids "$ADMIN_PORT" 2>/dev/null | tr -d '\n' | sed 's/^/pid /')"
    else
        printf '当前配置   : %s未安装%s\n' "$C_YELLOW" "$C_END"
    fi
    if have_systemd; then
        printf 'systemd    : 单元%s存在%s，状态 %s\n' \
            "$([[ -f "$UNIT_PATH" ]] && echo '' || echo '不')" '' \
            "$(systemctl is-active "$UNIT_NAME" 2>/dev/null || echo '未启动')"
    else
        printf 'systemd    : 本机没有 systemd（使用 nohup）\n'
    fi
    printf '公网 IP    : %s（缓存 %s）\n' "${PUBLIC_IP:-未知}" "$IP_CACHE"
    echo
    if [[ -f "$UNIT_PATH" ]]; then
        systemd_diag
    fi
    if [[ -f "$RUN_LOG" ]]; then
        printf '%s--- %s 最后 15 行 ---%s\n' "$C_GRAY" "$RUN_LOG" "$C_END"
        tail -n 15 "$RUN_LOG" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# 菜单
menu() {
    local opt
    banner() {
        line
        printf '  %sMTProxy 管理脚本%s\n' "$C_BOLD" "$C_END"
        if load_config 2>/dev/null; then
            if is_running; then
                printf '  状态：%s运行中%s  端口 %s  实现 %s\n' "$C_GREEN" "$C_END" "$PORT" "$(provider_name "$PROVIDER")"
            else
                printf '  状态：%s已停止%s  端口 %s  实现 %s\n' "$C_YELLOW" "$C_END" "$PORT" "$(provider_name "$PROVIDER")"
            fi
        else
            printf '  状态：%s未安装%s\n' "$C_GRAY" "$C_END"
        fi
        line
    }

    while true; do
        banner
        cat <<EOF
  1) 安装 / 重装
  2) 启动
  3) 停止
  4) 重启
  5) 状态与一键链接
  6) 修改配置
  7) 查看日志
  8) 防火墙放行端口
  9) 检查 Telegram 连通性
 10) 卸载
  0) 退出
EOF
        read -r -p "> " opt
        case "$opt" in
            1) install_mtp ;;
            2) start_mtp ;;
            3) stop_mtp ;;
            4) restart_mtp ;;
            5) status_mtp ;;
            6) config_edit ;;
            7) show_logs 40 ;;
            8)
                if load_config 2>/dev/null; then
                    firewall_open "$PORT"
                    read -r -p "是否同时放行管理端口 $ADMIN_PORT（只建议本机用，默认否）？[y/N] " a
                    [[ "${a:-n}" == "y" ]] && firewall_open "$ADMIN_PORT"
                else
                    warn "还没安装"
                fi
                ;;
            9) check_tg ;;
            10) uninstall ;;
            0) exit 0 ;;
            *) warn "请输入 0-10" ;;
        esac
        echo
        read -r -p "按回车返回菜单..." _ || true
    done
}

# ---------------------------------------------------------------------------
# 参数解析 / 入口
# ---------------------------------------------------------------------------
usage() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
}

parse_install_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)        FLAG_PORT="${2:-}"; shift 2 ;;
            --admin-port)  FLAG_ADMIN_PORT="${2:-}"; shift 2 ;;
            --domain)      FLAG_DOMAIN="${2:-}"; shift 2 ;;
            --tag)         FLAG_TAG="${2:-}"; shift 2 ;;
            --secret)      FLAG_SECRET="${2:-}"; shift 2 ;;
            --provider)    FLAG_PROVIDER="${2:-}"; shift 2 ;;
            --no-systemd)  FLAG_NO_SYSTEMD=1; shift ;;
            --force)       FLAG_FORCE=1; shift ;;
            --yes)         FLAG_YES=1; shift ;;
            *) shift ;;
        esac
    done
}

main() {
    local cmd="${1:-menu}"
    shift $(( $# > 0 ? 1 : 0 )) || true
    parse_install_flags "$@"

    ensure_dirs

    case "$cmd" in
        menu)        menu ;;
        install)     install_mtp ;;
        start)       start_mtp ;;
        stop)        stop_mtp ;;
        restart)     restart_mtp ;;
        status)      status_mtp ;;
        link)        load_config && print_link ;;
        config)      config_edit ;;
        logs)        show_logs "${1:-40}" ;;
        firewall)    load_config && firewall_open "$PORT" ;;
        check-tg|check_tg|tgcheck) check_tg ;;
        uninstall)   uninstall ;;
        __run)       do_run_foreground ;;
        selftest)    selftest ;;
        doctor|diag) doctor ;;
        debug)
            load_config || die "还没安装"
            build_run_cmd || die "缺少运行文件"
            info "前台调试运行，Ctrl+C 退出"
            echo "+ ${RUN_CMD[*]}"
            "${RUN_CMD[@]}"
            ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
