#!/usr/bin/env bash
#
# shadowsocks-libev 一键安装脚本（修复版）
# 原始脚本来源: https://storage.googleapis.com/tiziblog/ss.sh (作者: 梯子博客)
# 本版本修复了原脚本导致「有时安装失败 / 装完服务起不来」的一系列问题，
# 详细对照见同目录《ss-脚本问题分析与修复报告.md》
#
# 用法: bash ss-fixed.sh [menu|install|update|uninstall|start|restart|stop|showInfo|showQR|showLog|check]
# 可选环境变量:
#   SS_VER=3.3.5          指定版本（默认自动取 GitHub 最新 release，失败回退 3.3.5）
#   SS_PORT=8388          非交互指定端口
#   SS_PASSWORD=xxx       非交互指定密码
#   SS_METHOD=aes-256-gcm 非交互指定加密方式
#   SS_MIRROR=https://ghfast.top/   强制指定 GitHub 加速前缀（可留空表示直连）
#

export LANG=C
export LC_ALL=C
umask 022

# ---------------------------------------------------------------- 基础变量
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

NAME="shadowsocks-libev"
PREFIX="/usr/local"
CONFIG_DIR="/etc/${NAME}"
CONFIG_FILE="${SS_CONF_PATH:-${CONFIG_DIR}/config.json}"
SERVICE_FILE="${SS_SERVICE_PATH:-/etc/systemd/system/${NAME}.service}"
LOG_FILE="${SS_LOG_FILE:-/var/log/${NAME}-install.log}"

PINNED_VER="3.3.5"                                # 最后一个 autotools 构建的稳定版本，作为兜底
REPO_SLUG="shadowsocks/shadowsocks-libev"          # GitHub 会 301 到 shadowsocks/shadowsocks-c
RELEASES_URL="https://github.com/${REPO_SLUG}/releases"
LATEST_API="https://api.github.com/repos/${REPO_SLUG}/releases/latest"
UA="ss-libev-installer/2.0"

# GitHub 加速镜像池（实测可用；失效的 gh.hijk.art / ghproxy.net 已移除）
# 空字符串代表直连 github.com
GH_MIRRORS=("${SS_MIRROR-}" "https://ghfast.top/" "https://gh-proxy.com/")

SS_BIN=""          # ss-server 绝对路径，安装后填充
IP=""
IPV6=0
PORT=""
PASSWORD=""
METHOD=""
NEW_VER=""
PM=""
INSTALL_BBR="false"
DL_USED=""

# ---------------------------------------------------------------- 输出函数
colorEcho() {
    local color="$1"
    shift
    printf '%b%s%b\n' "$color" "$*" "$PLAIN"
}
info() { colorEcho "$BLUE" " $*"; }
ok()   { colorEcho "$GREEN" " $*"; }
warn() { colorEcho "$YELLOW" " $*"; }
err()  { colorEcho "$RED" " $*"; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- 系统检查
checkSystem() {
    if [[ "${EUID}" -ne 0 ]]; then
        die " 请以 root 身份执行该脚本（sudo bash $0）"
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        die " 该系统没有 systemd，本脚本不支持"
    fi
    if command -v apt-get >/dev/null 2>&1; then
        PM="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
    else
        die " 不受支持的 Linux 系统（未找到 apt-get / dnf / yum）"
    fi
    case "$PM" in
        apt) export DEBIAN_FRONTEND=noninteractive ;;
    esac
    info " 系统: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}") / 包管理器: ${PM}"
}

pkg_refresh() {
    case "$PM" in
        apt) apt-get update -qq >"$LOG_FILE" 2>&1 ;;
        dnf) dnf makecache -q >"$LOG_FILE" 2>&1 ;;
        yum) yum makecache -q >"$LOG_FILE" 2>&1 ;;
    esac
    return 0
}

pkg_clean() {
    # 原脚本用 "apt clean all"，apt 不接受 all 参数，会报错
    case "$PM" in
        apt) apt-get clean >/dev/null 2>&1 ;;
        dnf|yum) yum clean all >/dev/null 2>&1 ;;
    esac
    return 0
}

_pkg_missing() {
    local p
    for p in "$@"; do
        case "$PM" in
            apt) dpkg -s "$p" >/dev/null 2>&1 || echo "$p" ;;
            *)   rpm -q "$p" >/dev/null 2>&1 || echo "$p" ;;
        esac
    done
}

pkg_install() {
    local -a missing
    mapfile -t missing < <(_pkg_missing "$@")
    [[ ${#missing[@]} -eq 0 ]] && return 0
    info " 安装依赖: ${missing[*]}"
    case "$PM" in
        apt) apt-get install -y --no-install-recommends "${missing[@]}" >>"$LOG_FILE" 2>&1 ;;
        dnf) dnf install -y "${missing[@]}" >>"$LOG_FILE" 2>&1 ;;
        yum) yum install -y "${missing[@]}" >>"$LOG_FILE" 2>&1 ;;
    esac
}

pkg_install_opt() {
    # 可选项（二维码等），失败不影响主流程
    pkg_install "$@" || warn " 可选依赖安装失败: $* （不影响使用）"
}

# ---------------------------------------------------------------- 公网 IP
get_ip() {
    local ep ip
    for ep in "https://ip.sb" "https://api.ipify.org" "https://ifconfig.me/ip"; do
        ip="$(curl -fsS -4 --connect-timeout 6 --max-time 12 "$ep" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$ip" ]]; then IP="$ip"; IPV6=0; return 0; fi
    done
    for ep in "https://ip.sb" "https://api64.ipify.org"; do
        ip="$(curl -fsS -6 --connect-timeout 6 --max-time 12 "$ep" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$ip" ]]; then IP="$ip"; IPV6=1; return 0; fi
    done
    # 外网接口不可用时取本机出口地址，避免生成残缺的 ss 链接
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    if [[ -n "$ip" ]]; then
        IP="$ip"; IPV6=0
        warn " 未能获取公网 IP，暂用本机地址 ${IP}（若在 NAT 后请自行替换为公网 IP）"
        return 0
    fi
    if [[ "${1-}" == "quiet" ]]; then
        return 1
    fi
    err " 无法获取服务器 IP，请手动输入"
    read -r -p " 服务器公网 IP: " IP
    [[ -n "$IP" ]] || die " IP 不能为空"
}

# ---------------------------------------------------------------- 状态探测
port_listening() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${p}$" && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$" && return 0
    fi
    return 1
}

config_port() {
    [[ -f "$CONFIG_FILE" ]] || { echo ""; return; }
    grep -E '"server_port"' "$CONFIG_FILE" | head -1 | cut -d: -f2 | tr -d "\",' "
}

status() {
    export PATH="${PREFIX}/bin:/usr/local/bin:${PATH}"
    if ! command -v ss-server >/dev/null 2>&1; then echo 0; return; fi
    [[ -f "$CONFIG_FILE" ]] || { echo 1; return; }
    local port
    port="$(config_port)"
    if [[ -z "$port" ]]; then echo 2; return; fi
    if systemctl is-active -q "${NAME}" 2>/dev/null && port_listening "$port"; then
        echo 3
    else
        echo 2
    fi
}

statusText() {
    case "$(status)" in
        2) printf '%b已安装%b %b未运行%b\n' "$GREEN" "$PLAIN" "$RED" "$PLAIN" ;;
        3) printf '%b已安装%b %b正在运行%b\n' "$GREEN" "$PLAIN" "$GREEN" "$PLAIN" ;;
        *) printf '%b未安装%b\n' "$RED" "$PLAIN" ;;
    esac
}

# ---------------------------------------------------------------- 交互输入
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

random_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16
}

ask_password() {
    if [[ -n "${SS_PASSWORD-}" ]]; then
        PASSWORD="$SS_PASSWORD"
        ok " 使用预设密码"
        return 0
    fi
    local input
    read -r -p " 请设置 SS 的密码（留空随机生成）: " input
    if [[ -z "$input" ]]; then
        PASSWORD="$(random_password)"
        [[ -n "$PASSWORD" ]] || die " 随机密码生成失败，请手动输入"
    else
        PASSWORD="$input"
    fi
    info " 密码: ${PASSWORD}"
}

ask_port() {
    if [[ -n "${SS_PORT-}" ]]; then
        PORT="$SS_PORT"
        [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1025 && PORT <= 65535 )) || die " SS_PORT=${PORT} 非法（1025-65535）"
        ok " 使用预设端口: ${PORT}"
        return 0
    fi
    local input
    while true; do
        read -r -p " 请设置 SS 的端口号[1025-65535]（留空随机）: " input
        if [[ -z "$input" ]]; then
            if command -v shuf >/dev/null 2>&1; then
                PORT="$(shuf -i 1025-65500 -n 1)"
            else
                PORT="$(( (RANDOM % 64475) + 1025 ))"
            fi
            info " 随机端口: ${PORT}"
            return 0
        fi
        if [[ ! "$input" =~ ^[0-9]+$ ]]; then
            err " 端口必须是数字，请重新输入"
            continue
        fi
        if [[ "$input" == 0* ]]; then
            err " 端口不能以 0 开头，请重新输入"
            continue
        fi
        if (( input >= 1025 && input <= 65535 )); then
            PORT="$input"
            info " 端口: ${PORT}"
            return 0
        fi
        err " 端口范围是 1025-65535，请重新输入"
    done
}

ask_method() {
    local methods=(
        aes-256-gcm aes-192-gcm aes-128-gcm
        aes-256-ctr aes-192-ctr aes-128-ctr
        aes-256-cfb aes-192-cfb aes-128-cfb
        camellia-128-cfb camellia-192-cfb camellia-256-cfb
        chacha20-ietf chacha20-ietf-poly1305 xchacha20-ietf-poly1305
    )
    if [[ -n "${SS_METHOD-}" ]]; then
        local m found=""
        for m in "${methods[@]}"; do
            [[ "$SS_METHOD" == "$m" ]] && found="yes"
        done
        [[ -n "$found" ]] || die " SS_METHOD=${SS_METHOD} 不在支持列表中"
        METHOD="$SS_METHOD"
        ok " 使用预设加密方式: ${METHOD}"
        return 0
    fi
    local i=1 m
    warn " 请选择加密方式:"
    for m in "${methods[@]}"; do
        printf '  %2d) %s\n' "$i" "$m"
        i=$((i + 1))
    done
    local answer
    read -r -p " 请选择（默认 aes-256-gcm）: " answer
    if [[ -z "$answer" ]]; then
        METHOD="aes-256-gcm"
    elif [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#methods[@]} )); then
        METHOD="${methods[$((answer - 1))]}"
    else
        warn " 无效选择，使用默认 aes-256-gcm"
        METHOD="aes-256-gcm"
    fi
    info " 加密方式: ${METHOD}"
}

getData() {
    echo
    get_ip
    ask_password
    ask_port
    ask_method
    echo
}

# ---------------------------------------------------------------- 版本/下载
normalize_version() {
    local v="$1"
    v="${v#v}"
    printf '%s' "$v"
}

resolve_version() {
    local eff tag api tag2
    if [[ -n "${SS_VER-}" ]]; then
        NEW_VER="$(normalize_version "$SS_VER")"
        info " 使用指定版本: v${NEW_VER}"
        return 0
    fi

    # 1) 不依赖 API：跟随 releases/latest 的最终跳转地址（不会被 API 限流，也不怕代理约不到 api.github.com）
    eff="$(curl -s -o /dev/null -w '%{url_effective}' -L --connect-timeout 8 --max-time 25 "${RELEASES_URL}/latest" 2>/dev/null)"
    tag="$(printf '%s' "$eff" | grep -oE 'tag/v?[0-9]+(\.[0-9]+)*' | tail -1 | sed 's#tag/v##; s#tag/##')"
    if [[ -n "$tag" ]]; then
        NEW_VER="$tag"
        info " 最新版本: v${NEW_VER}"
        return 0
    fi

    # 2) 官方 API 兜底（必须带 User-Agent，否则 GitHub 直接 403）
    api="$(curl -fsSL -H "User-Agent: ${UA}" --connect-timeout 8 --max-time 20 "$LATEST_API" 2>/dev/null)"
    tag2="$(printf '%s' "$api" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)"
    if [[ -n "$tag2" ]]; then
        NEW_VER="$(normalize_version "$tag2")"
        info " 最新版本(API): v${NEW_VER}"
        return 0
    fi

    NEW_VER="$PINNED_VER"
    warn " 无法读取最新版本，回退到已验证版本 v${NEW_VER}"
}

gh_download() {
    # $1: 仓库内相对路径  $2: 输出文件
    local relpath="$1" out="$2" m url
    for m in "${GH_MIRRORS[@]}"; do
        url="${m}https://github.com/${relpath}"
        info " 尝试下载: ${url}"
        if curl -fsSL --connect-timeout 10 --max-time 180 --retry 2 -o "$out" "$url" 2>>"$LOG_FILE" && [[ -s "$out" ]]; then
            DL_USED="${m:-github.com(直连)}"
            return 0
        fi
        rm -f "$out"
    done
    return 1
}

detect_build_system() {
    local dir="$1"
    if [[ -x "${dir}/configure" ]]; then
        echo "autotools"
    elif [[ -f "${dir}/CMakeLists.txt" ]]; then
        echo "cmake"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------- 依赖安装
install_deps_base() {
    pkg_refresh
    pkg_clean
    info " 安装基础依赖"
    case "$PM" in
        apt)
            pkg_install curl tar ca-certificates coreutils procps iproute2 \
                        gcc make autoconf automake libtool pkg-config gettext libssl-dev
            pkg_install_opt qrencode
            ;;
        dnf|yum)
            pkg_install curl tar ca-certificates coreutils procps-ng iproute \
                        gcc gcc-c++ make autoconf automake libtool pkgconfig gettext openssl-devel
            pkg_install_opt qrencode
            ;;
    esac
}

install_deps_autotools() {
    info " 安装 autotools 构建依赖（libev / libsodium / c-ares / mbedtls / pcre）"
    case "$PM" in
        apt)
            pkg_install libev-dev libsodium-dev libudns-dev libc-ares-dev libmbedtls-dev
            if ! pkg_install libpcre3-dev; then
                warn " 未找到 PCRE1 开发包（libpcre3-dev），v3.3.5 无法编译；可改用 SS_VER=3.3.6（CMake + PCRE2）"
            fi
            ;;
        dnf|yum)
            pkg_install libev-devel libsodium-devel udns-devel c-ares-devel mbedtls-devel pcre-devel
            ;;
    esac
}

install_deps_cmake() {
    info " 安装 CMake 构建依赖（libev / libsodium / c-ares / mbedtls / pcre2）"
    case "$PM" in
        apt) pkg_install cmake libev-dev libsodium-dev libc-ares-dev libmbedtls-dev libpcre2-dev ;;
        *)   pkg_install cmake libev-devel libsodium-devel c-ares-devel mbedtls-devel pcre2-devel ;;
    esac
}

# ---------------------------------------------------------------- 源码编译
_build() {
    local dir="$1" bs="$2" jobs
    jobs="$(nproc 2>/dev/null || echo 2)"
    [[ "$jobs" -gt 4 ]] && jobs=4

    case "$bs" in
        autotools)
            info " 构建方式: autotools (configure)"
            ( cd "$dir" && ./configure --prefix="$PREFIX" --disable-documentation ) >>"$LOG_FILE" 2>&1 || {
                err " configure 失败"; tail -n 20 "$LOG_FILE"; return 1; }
            ( cd "$dir" && make -j"$jobs" ) >>"$LOG_FILE" 2>&1 || {
                err " make 失败"; tail -n 20 "$LOG_FILE"; return 1; }
            ( cd "$dir" && make install ) >>"$LOG_FILE" 2>&1 || {
                err " make install 失败"; tail -n 20 "$LOG_FILE"; return 1; }
            ;;
        cmake)
            info " 构建方式: cmake"
            # WITH_STATIC=ON 需要 .a 静态库，多数发行版不提供，故关闭；EMBEDDED_SRC 打开以使用自带 libcork/libipset/libbloom
            ( cd "$dir" && cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -DWITH_STATIC=OFF -DWITH_EMBEDDED_SRC=ON . ) >>"$LOG_FILE" 2>&1 || {
                err " cmake 配置失败"; tail -n 20 "$LOG_FILE"; return 1; }
            ( cd "$dir" && make -j"$jobs" ) >>"$LOG_FILE" 2>&1 || {
                err " make 失败"; tail -n 20 "$LOG_FILE"; return 1; }
            ( cd "$dir" && make install ) >>"$LOG_FILE" 2>&1 || {
                err " make install 失败"; tail -n 20 "$LOG_FILE"; return 1; }
            ;;
        *)
            err " 源码包内既没有 configure 也没有 CMakeLists.txt，无法构建"
            return 1
            ;;
    esac
    return 0
}

install_from_source() {
    local ver="$1" work dir bs
    ver="$(normalize_version "$ver")"
    work="$(mktemp -d /tmp/ss-install.XXXXXX)" || { err " 创建临时目录失败"; return 1; }

    info " 下载源码包 v${ver}"
    if ! gh_download "${REPO_SLUG}/releases/download/v${ver}/shadowsocks-libev-${ver}.tar.gz" "${work}/pkg.tar.gz"; then
        err " v${ver} 源码包所有源下载失败"
        rm -rf "$work"
        return 1
    fi

    # 完整性校验：镜像返回错误页时 tar 会报错，原脚本缺这一步
    if ! tar tzf "${work}/pkg.tar.gz" >/dev/null 2>&1; then
        err " 源码包损坏（疑似镜像返回了错误页面），丢弃并从下一个源重试"
        rm -rf "$work"
        return 1
    fi
    tar xzf "${work}/pkg.tar.gz" -C "$work" || { rm -rf "$work"; return 1; }

    dir="${work}/shadowsocks-libev-${ver}"
    if [[ ! -d "$dir" ]]; then
        err " 解压后未找到 shadowsocks-libev-${ver} 目录"
        rm -rf "$work"
        return 1
    fi

    bs="$(detect_build_system "$dir")"
    info " 检测到构建系统: ${bs}（源码来源: ${DL_USED}）"
    case "$bs" in
        autotools) install_deps_autotools ;;
        cmake)     install_deps_cmake ;;
        *)         err " 未知构建系统"; rm -rf "$work"; return 1 ;;
    esac

    if ! _build "$dir" "$bs"; then
        rm -rf "$work"
        return 1
    fi

    hash -r
    export PATH="${PREFIX}/bin:/usr/local/bin:${PATH}"
    SS_BIN="$(command -v ss-server 2>/dev/null)"
    if [[ -z "$SS_BIN" ]]; then
        err " 编译完成但未找到 ss-server，判定安装失败"
        rm -rf "$work"
        return 1
    fi

    ok " 已安装: ${SS_BIN} ($("$SS_BIN" -h 2>&1 | grep -oE 'shadowsocks-libev[[:space:]]+[0-9.]+' | head -1))"
    rm -rf "$work"
    return 0
}

install_ss() {
    echo
    info " 安装 SS..."
    : >"$LOG_FILE"

    resolve_version
    install_deps_base

    if install_from_source "$NEW_VER"; then
        :
    elif [[ "$NEW_VER" != "$PINNED_VER" ]]; then
        warn " v${NEW_VER} 构建失败，自动回退到已验证版本 v${PINNED_VER}"
        install_from_source "$PINNED_VER" || die " SS 安装失败，完整日志: ${LOG_FILE}"
    else
        die " SS 安装失败，完整日志: ${LOG_FILE}"
    fi

    write_service
    ok " SS 安装完成"
}

# ---------------------------------------------------------------- 服务与配置
write_service() {
    export PATH="${PREFIX}/bin:/usr/local/bin:${PATH}"
    SS_BIN="$(command -v ss-server 2>/dev/null)"
    [[ -n "$SS_BIN" ]] || SS_BIN="${PREFIX}/bin/ss-server"

    # 注意：ss-server 的 -f 表示「自行 daemonize」，与 Type=simple 冲突（原脚本的核心 bug）。
    # 这里改为前台运行 + Type=simple，由 systemd 托管生命周期。
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=shadowsocks-libev server
Documentation=https://github.com/${REPO_SLUG}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=32768
ExecStart=${SS_BIN} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${NAME}" >/dev/null 2>&1
}

write_config() {
    mkdir -p "$CONFIG_DIR"
    local server_addr="0.0.0.0"
    [[ "$IPV6" -eq 1 ]] && server_addr="::"
    local pw_json method_json
    pw_json="$(json_escape "$PASSWORD")"
    method_json="$(json_escape "$METHOD")"

    cat >"$CONFIG_FILE" <<EOF
{
    "server": "${server_addr}",
    "server_port": ${PORT},
    "local_port": 1080,
    "password": "${pw_json}",
    "timeout": 600,
    "method": "${method_json}",
    "nameserver": "8.8.8.8",
    "mode": "tcp_and_udp",
    "fast_open": false
}
EOF
    chmod 700 "$CONFIG_DIR"
    chmod 600 "$CONFIG_FILE"   # 配置里有密码，原脚本留了默认权限
}

# ---------------------------------------------------------------- BBR
set_sysctl_bbr() {
    local f="/etc/sysctl.d/99-${NAME}.conf"
    cat >"$f" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    # 清理原脚本在 /etc/sysctl.conf 里重复追加的同名键，避免每次运行堆积
    if [[ -f /etc/sysctl.conf ]]; then
        cp -f /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null
        sed -i -e '/^net\.core\.default_qdisc=/d' -e '/^net\.ipv4\.tcp_congestion_control=/d' /etc/sysctl.conf
    fi
    sysctl --system >>"$LOG_FILE" 2>&1 || sysctl -p >>"$LOG_FILE" 2>&1
}

installBBR() {
    local avail kernel
    avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    if grep -qw bbr <<<"$avail"; then
        info " 内核已支持 BBR，写入 sysctl 配置"
        set_sysctl_bbr
        if [[ "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
            ok " BBR 已启用"
        else
            warn " BBR 配置已写入但未即时生效（部分系统需重启内核）"
        fi
        INSTALL_BBR="false"
        return 0
    fi

    kernel="$(uname -r | cut -d. -f1-2)"
    warn " 当前内核 ${kernel} 不支持 BBR（需 >= 4.9）"
    if [[ "$(hostnamectl 2>/dev/null | grep -ic openvz)" != "0" ]]; then
        warn " OpenVZ 机器不支持自行更换内核，跳过"
        INSTALL_BBR="false"
        return 0
    fi

    local answer
    read -r -p " 是否尝试升级内核以启用 BBR？(y/n，默认 n): " answer
    [[ -z "$answer" ]] && answer="n"
    if [[ "${answer,,}" != "y" ]]; then
        info " 跳过 BBR 内核升级"
        INSTALL_BBR="false"
        return 0
    fi

    case "$PM" in
        apt)
            # 原脚本硬编码 linux-generic-hwe-16.04，在新系统上包不存在必然失败
            local vid hwe
            vid="$(. /etc/os-release && echo "${VERSION_ID:-}")"
            hwe="linux-generic-hwe-${vid}"
            if apt-cache show "$hwe" >/dev/null 2>&1; then
                pkg_install "$hwe" && INSTALL_BBR="true"
            elif apt-cache show linux-generic >/dev/null 2>&1; then
                pkg_install linux-generic && INSTALL_BBR="true"
            else
                warn " 未找到可用的 HWE 内核包，跳过"
                INSTALL_BBR="false"
            fi
            ;;
        dnf|yum)
            local elv elrepo_rpm
            elv="$(rpm -E '%{rhel}' 2>/dev/null)"
            [[ -z "$elv" ]] && elv="$(. /etc/os-release && echo "${VERSION_ID%%.*}")"
            if [[ "$elv" =~ ^[0-9]+$ ]] && (( elv >= 7 )); then
                elrepo_rpm="https://www.elrepo.org/elrepo-release-${elv}.el${elv}.elrepo.noarch.rpm"
                rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org >>"$LOG_FILE" 2>&1
                if rpm -Uvh "$elrepo_rpm" >>"$LOG_FILE" 2>&1; then
                    if [[ "$PM" == "dnf" ]]; then
                        dnf install -y --enablerepo=elrepo-kernel kernel-ml >>"$LOG_FILE" 2>&1
                    else
                        yum install -y --enablerepo=elrepo-kernel kernel-ml >>"$LOG_FILE" 2>&1
                    fi
                    if [[ $? -eq 0 ]]; then
                        grub2-set-default 0 >/dev/null 2>&1
                        INSTALL_BBR="true"
                    else
                        warn " 新内核安装失败，跳过 BBR"
                        INSTALL_BBR="false"
                    fi
                else
                    warn " elrepo 源安装失败，跳过内核升级"
                    INSTALL_BBR="false"
                fi
            else
                warn " 无法识别 el 版本（${elv}），跳过内核升级"
                INSTALL_BBR="false"
            fi
            ;;
    esac

    if [[ "$INSTALL_BBR" == "true" ]]; then
        set_sysctl_bbr
        local f="/etc/modules-load.d/${NAME}.conf"
        grep -qx tcp_bbr "$f" 2>/dev/null || echo "tcp_bbr" >>"$f"
        ok " 新内核已安装，需重启生效"
    fi
}

bbrReboot() {
    [[ "$INSTALL_BBR" == "true" ]] || return 0
    echo
    warn " 内核已更换，30 秒后自动重启（Ctrl+C 可取消，之后手动执行 reboot）"
    sleep 30
    reboot
}

# ---------------------------------------------------------------- 防火墙
open_port_firewalld() {
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1
    firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
}

open_port_iptables() {
    iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT
    iptables -C INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "${PORT}" -j ACCEPT
    # 原脚本不持久化，重启后规则丢失
    if [[ -d /etc/iptables ]]; then
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
        iptables-save >/etc/iptables/rules.v4 2>/dev/null
    elif command -v service >/dev/null 2>&1 && [[ -f /etc/sysconfig/iptables ]]; then
        iptables-save >/etc/sysconfig/iptables 2>/dev/null
    fi
}

setFirewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow "${PORT}/tcp" >/dev/null 2>&1
        ufw allow "${PORT}/udp" >/dev/null 2>&1
        ok " 已放行 ufw 端口 ${PORT}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active -q firewalld 2>/dev/null; then
        open_port_firewalld
        ok " 已放行 firewalld 端口 ${PORT}"
    elif command -v iptables >/dev/null 2>&1 && iptables -nL >/dev/null 2>&1; then
        open_port_iptables
        ok " 已放行 iptables 端口 ${PORT}"
    elif command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        warn " 检测到 nftables，请自行放行 ${PORT}/tcp 与 ${PORT}/udp"
    else
        info " 未检测到启用的防火墙，跳过放行"
    fi
}

# ---------------------------------------------------------------- 展示
ss_link() {
    local port password method b64
    port="$(config_port)"
    password="$(grep -E '"password"' "$CONFIG_FILE" | head -1 | cut -d: -f2 | tr -d "\",' ")"
    method="$(grep -E '"method"' "$CONFIG_FILE" | head -1 | cut -d: -f2 | tr -d "\",' ")"
    # SIP002 标准：ss://base64(method:password)@host:port#tag
    b64="$(printf '%s:%s' "$method" "$password" | base64 2>/dev/null | tr -d '\n')"
    if [[ "$IPV6" -eq 1 || "$IP" == *:* ]]; then
        printf 'ss://%s@[%s]:%s#%s' "$b64" "$IP" "$port" "$NAME"
    else
        printf 'ss://%s@%s:%s#%s' "$b64" "$IP" "$port" "$NAME"
    fi
}

ensure_installed() {
    [[ "$(status)" -ge 2 ]] && return 0
    err " SS 未安装，请先安装"
    return 1
}

refresh_ip() {
    [[ -n "$IP" ]] && return 0
    get_ip >/dev/null 2>&1 || true
    return 0
}

showInfo() {
    ensure_installed || return 1
    refresh_ip
    local port password method
    port="$(config_port)"
    password="$(grep -E '"password"' "$CONFIG_FILE" | head -1 | cut -d: -f2 | tr -d "\",' ")"
    method="$(grep -E '"method"' "$CONFIG_FILE" | head -1 | cut -d: -f2 | tr -d "\",' ")"

    local state_txt
    if [[ "$(status)" -eq 3 ]]; then
        state_txt="${GREEN}正在运行${PLAIN}"
    else
        state_txt="${RED}已停止${PLAIN}"
    fi

    echo "============================================"
    printf ' %b运行状态%b: %b\n' "$BLUE" "$PLAIN" "$state_txt"
    printf ' %b配置文件%b: %s\n' "$BLUE" "$PLAIN" "$CONFIG_FILE"
    echo
    printf ' %b配置信息%b\n' "$RED" "$PLAIN"
    printf '  %bIP%b: %s\n' "$BLUE" "$PLAIN" "$IP"
    printf '  %b端口%b: %s\n' "$BLUE" "$PLAIN" "$port"
    printf '  %b密码%b: %s\n' "$BLUE" "$PLAIN" "$password"
    printf '  %b加密%b: %s\n' "$BLUE" "$PLAIN" "$method"
    echo
    printf ' %bss 链接%b: %s\n' "$BLUE" "$PLAIN" "$(ss_link)"
}

showQR() {
    ensure_installed || return 1
    refresh_ip
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -o - -t utf8 "$(ss_link)"
    else
        warn " 未安装 qrencode，仅输出链接:"
        ss_link
        echo
    fi
}

showLog() {
    ensure_installed || return 1
    journalctl -xen --no-pager -u "${NAME}"
}

# ---------------------------------------------------------------- 生命周期
start() {
    ensure_installed || return 1
    systemctl restart "${NAME}" >/dev/null 2>&1
    sleep 2
    local port
    port="$(config_port)"
    if [[ "$(systemctl is-active "${NAME}" 2>/dev/null)" == "active" ]] && port_listening "$port"; then
        ok " SS 启动成功（端口 ${port}）"
    else
        err " SS 启动失败，请检查端口占用与日志（journalctl -u ${NAME}）"
        return 1
    fi
}

stop() {
    ensure_installed || return 1
    systemctl stop "${NAME}"
    ok " SS 已停止"
}

restart() {
    ensure_installed || return 1
    start
}

reconfig() {
    ensure_installed || return 1
    getData
    write_config
    write_service
    restart
    setFirewall
    showInfo
}

update() {
    ensure_installed || return 1
    install_ss
    restart
    showInfo
}

uninstall() {
    ensure_installed || return 1
    local answer
    read -r -p " 确定卸载 SS 吗？(y/n) " answer
    [[ -z "$answer" ]] && answer="n"
    [[ "${answer,,}" == "y" ]] || return 0

    systemctl stop "${NAME}" >/dev/null 2>&1
    systemctl disable "${NAME}" >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    rm -f "${PREFIX}/bin/ss-server" "${PREFIX}/bin/ss-local" "${PREFIX}/bin/ss-redir" \
          "${PREFIX}/bin/ss-tunnel" "${PREFIX}/bin/ss-manager" "${PREFIX}/bin/ss-nat" 2>/dev/null
    rm -f "${PREFIX}"/lib/libshadowsocks-libev* "${PREFIX}"/lib64/libshadowsocks-libev* 2>/dev/null
    rm -rf "${PREFIX}/include/shadowsocks" "${PREFIX}"/share/doc/shadowsocks-libev* 2>/dev/null
    rm -f "${PREFIX}"/share/man/man1/ss-*.gz "${PREFIX}"/share/man/man8/shadowsocks-libev* 2>/dev/null

    read -r -p " 是否一并删除配置目录 ${CONFIG_DIR}？(y/n) " answer
    [[ "${answer,,}" == "y" ]] && rm -rf "$CONFIG_DIR"

    ok " SS 卸载完成"
}

# ---------------------------------------------------------------- 自检
check() {
    echo
    info " 软件源连通性与版本自检"
    local eff api
    printf ' %-46s' "GitHub releases/latest"
    eff="$(curl -s -o /dev/null -w '%{url_effective}' -L --connect-timeout 8 --max-time 20 "${RELEASES_URL}/latest" 2>/dev/null)"
    if [[ -n "$eff" && "$eff" == *"/tag/"* ]]; then
        ok "$(printf '%s' "$eff" | grep -oE 'tag/v?[0-9.]+')"
    else
        err "不可达"
    fi

    printf ' %-46s' "GitHub API (latest)"
    api="$(curl -fsSL -H "User-Agent: ${UA}" --connect-timeout 8 --max-time 20 "$LATEST_API" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)"
    if [[ -n "$api" ]]; then ok "$api"; else warn "不可用（将走 releases 页面解析或固定版本）"; fi

    local m
    for m in "${GH_MIRRORS[@]}"; do
        printf ' %-46s' "源码镜像 ${m:-github.com 直连}"
        if curl -fsSL -o /dev/null --connect-timeout 8 --max-time 60 \
            "${m}https://github.com/${REPO_SLUG}/releases/download/v${PINNED_VER}/shadowsocks-libev-${PINNED_VER}.tar.gz" 2>/dev/null; then
            ok "可用"
        else
            err "不可用"
        fi
    done

    printf ' %-46s' "本机公网 IP"
    get_ip quiet >/dev/null 2>&1 && ok "${IP}" || err "获取失败"

    printf ' %-46s' "systemd"
    systemctl is-system-running >/dev/null 2>&1 && ok "正常" || warn "$(systemctl is-system-running 2>&1)"
    echo
}

# ---------------------------------------------------------------- 菜单
menu() {
    clear
    echo "#############################################################"
    printf '#              %bShadowsocks/SS 一键安装脚本%b                #\n' "$RED" "$PLAIN"
    printf '# %b修复版%b（原脚本来源: tizi.blog）                          #\n' "$GREEN" "$PLAIN"
    echo "#############################################################"
    echo
    printf '  %b1.%b  安装 SS\n' "$GREEN" "$PLAIN"
    printf '  %b2.%b  更新 SS\n' "$GREEN" "$PLAIN"
    printf '  %b3.  %b卸载 SS%b\n' "$GREEN" "$RED" "$PLAIN"
    echo " -------------"
    printf '  %b4.%b  启动 SS\n' "$GREEN" "$PLAIN"
    printf '  %b5.%b  重启 SS\n' "$GREEN" "$PLAIN"
    printf '  %b6.%b  停止 SS\n' "$GREEN" "$PLAIN"
    echo " -------------"
    printf '  %b7.%b  查看配置\n' "$GREEN" "$PLAIN"
    printf '  %b8.%b  查看二维码\n' "$GREEN" "$PLAIN"
    printf '  %b9.  %b修改配置%b\n' "$GREEN" "$RED" "$PLAIN"
    printf '  %b10.%b 查看日志\n' "$GREEN" "$PLAIN"
    printf '  %b11.%b 软件源自检\n' "$GREEN" "$PLAIN"
    echo " -------------"
    printf '  %b0.%b  退出\n' "$GREEN" "$PLAIN"
    echo
    printf ' 当前状态: '
    statusText
    echo
    local answer
    read -r -p " 请选择操作[0-11]: " answer
    case "$answer" in
        0) exit 0 ;;
        1) install ;;
        2) update ;;
        3) uninstall ;;
        4) start ;;
        5) restart ;;
        6) stop ;;
        7) showInfo ;;
        8) showQR ;;
        9) reconfig ;;
        10) showLog ;;
        11) check ;;
        *) warn " 请选择正确的操作"; return 1 ;;
    esac
}

install() {
    getData
    preinstall_compat
    install_ss
    write_config
    installBBR
    setFirewall
    start
    showInfo
    bbrReboot
}

# 兼容原脚本的 preinstall 语义（SELinux / 基础工具）
preinstall_compat() {
    if [[ -s /etc/selinux/config ]] && grep -q 'SELINUX=enforcing' /etc/selinux/config 2>/dev/null; then
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
        setenforce 0 >/dev/null 2>&1
        info " SELinux 已调整为 permissive"
    fi
}

main() {
    local action="${1:-menu}"
    case "$action" in
        check)
            # 只读自检，不需要 root
            check
            ;;
        menu|install|update|uninstall|start|restart|stop|showInfo|showQR|showLog)
            checkSystem
            "$action"
            ;;
        *)
            err " 参数错误"
            echo " 用法: $(basename "$0") [menu|install|update|uninstall|start|restart|stop|showInfo|showQR|showLog|check]"
            exit 1
            ;;
    esac
}

# 被 source 引入时不执行主流程（便于单元测试）；
# 注意 bash -c "$(curl ...)" 与 curl | bash 下 BASH_SOURCE 为空，必须照常执行主流程，
# 否则会出现「命令返回 0 但什么都没发生」的静默失败
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    :
else
    main "$@"
fi
