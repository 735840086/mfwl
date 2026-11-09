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
#   SS_MODE=package      优先用发行版仓库（apt/yum 的 shadowsocks-libev）安装，不编译，适合小内存机器
#   SS_NO_SWAP=1         内存不足时不自动创建临时 Swap
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

# v3.3.6 在 .gitmodules 里记录的三个子模块 commit（用固定 commit 而不是 master，
# master 上的 libcork 缺少已提交的 config/version.h，会直接编译失败）
declare -A SUBMODULE_PIN_336=(
    [libcork]=074e074b26e9e372e90e6ade215217763c8644aa
    [libipset]=bc1qeleffvl3puy7nezjfwtndvd6uf0rytluy7s6g2
    [libbloom]=437e1add5a2b9a87797d8c648df7cf5f3ee155a8
)

# 一个 ref 只可能是 40 位 sha 或者分支名；任何其它形态（被篡改、粘贴串行、截断）
# 一律不采用，改为动态解析 —— 否则会拿一个乱码去拼 URL，必然 404
is_sha40() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

# 解析某版本 tag 下某个子模块目录对应的 commit：
# 内置表(已校验) → GitHub API → 仓库 tree 页面 → master
resolve_submodule_ref() {
    local name="$1" tag="$2" ref="${SUBMODULE_PIN_336[$1]-}" html=""
    # git tag 是 v3.3.6，API 的 ref 也必须带 v，否则 404 → 白白退回 master
    [[ "$tag" == v* ]] || tag="v${tag}"
    is_sha40 "$ref" || ref=""
    if [[ -z "$ref" ]]; then
        ref="$(curl -fsSL -H "User-Agent: ${UA}" --connect-timeout 8 --max-time 20 \
                "https://api.github.com/repos/shadowsocks/shadowsocks-c/contents/${name}?ref=${tag}" 2>/dev/null \
              | grep -oE '"sha": *"[0-9a-f]{40}"' | head -1 | grep -oE '[0-9a-f]{40}')"
    fi
    if ! is_sha40 "$ref"; then
        html="$(curl -fsSL -H "User-Agent: ${UA}" --connect-timeout 8 --max-time 20 \
                 "https://github.com/shadowsocks/shadowsocks-c/tree/${tag}/${name}" 2>/dev/null)"
        ref="$(printf '%s' "$html" | grep -oE "/shadowsocks/shadowsocks-c/tree/[0-9a-f]{40}/${name}" | head -1 | grep -oE '[0-9a-f]{40}')"
    fi
    is_sha40 "$ref" || ref="master"
    printf '%s\n' "$ref"
}

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

# 日志文件必须是可写的，否则所有 “2>>$LOG_FILE” 的重定向都会失败，
# 进而让 curl / apt 这些命令被连带判为失败（本次调试就踩到过）
log_ready() {
    local d
    if { : >>"$LOG_FILE"; } 2>/dev/null; then
        return 0
    fi
    d="$(dirname "$LOG_FILE")"
    mkdir -p "$d" 2>/dev/null
    if { : >>"$LOG_FILE"; } 2>/dev/null; then
        return 0
    fi
    LOG_FILE="/tmp/$(basename "$0" .sh).log"
    { : >>"$LOG_FILE"; } 2>/dev/null || true
    return 0
}

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
    log_ready
    local -a missing
    local rc=0
    mapfile -t missing < <(_pkg_missing "$@")
    [[ ${#missing[@]} -eq 0 ]] && return 0
    info " 安装依赖: ${missing[*]}"
    case "$PM" in
        apt) apt-get install -y --no-install-recommends "${missing[@]}" >>"$LOG_FILE" 2>&1 ;;
        dnf) dnf install -y "${missing[@]}" >>"$LOG_FILE" 2>&1 ;;
        yum) yum install -y "${missing[@]}" >>"$LOG_FILE" 2>&1 ;;
    esac || rc=$?
    if (( rc == 137 )); then
        err " 进程被 OOM Killer 杀死（内存不足），请先加 Swap 或加内存后重试"
        return 1
    fi
    return "$rc"
}

pkg_install_opt() {
    # 可选项（二维码等），失败不影响主流程
    pkg_install "$@" || warn " 可选依赖安装失败: $* （不影响使用）"
}

# ---------------------------------------------------------------- 内存/OOM
avail_mem_mb() {
    local kb
    kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
    [[ -n "$kb" ]] || kb="$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)"
    echo $(( ${kb:-0} / 1024 ))
}

swap_total_mb() {
    local kb
    kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
    echo $(( ${kb:-0} / 1024 ))
}

swap_free_mb() {
    local kb
    kb="$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)"
    echo $(( ${kb:-0} / 1024 ))
}

# 建了 Swap 之后 MemAvailable 不会变大，判断要按「可用内存 + 空闲 Swap」算
effective_mem_mb() {
    echo $(( $(avail_mem_mb) + $(swap_free_mb) ))
}

ensure_memory() {
    # 512MB 小机器上 apt / 编译都可能被 OOM Killer 直接 SIGKILL（截断日志、报错却查不出原因）
    local avail swap ans size eff
    avail="$(avail_mem_mb)"
    swap="$(swap_total_mb)"
    eff="$(effective_mem_mb)"
    info " 可用内存 ${avail} MB，Swap ${swap} MB（合计可用 ${eff} MB）"

    if (( eff >= 600 )); then return 0; fi
    if (( swap >= 512 )); then
        warn " 内存偏紧（${avail} MB），已有 Swap ${swap} MB，继续（编译会较慢）"
        return 0
    fi
    warn " 内存不足（${avail} MB 且无 Swap）：apt / make 很可能被 OOM Killer 杀掉"
    if [[ "${SS_NO_SWAP:-0}" == "1" ]]; then
        warn " 已按 SS_NO_SWAP=1 跳过 Swap 创建，安装可能失败"
        return 0
    fi

    read -r -p " 是否创建 1GB 临时 Swap 供本次安装使用？(y/n，默认 y) " ans
    [[ -z "$ans" ]] && ans="y"
    if [[ "${ans,,}" != "y" ]]; then
        warn " 已跳过 Swap；若安装失败，请先加内存或改用 SS_MODE=package"
        return 0
    fi

    size=1024
    if [[ -f /swapfile ]]; then
        swapon /swapfile >>"$LOG_FILE" 2>&1 && info " 已启用现有 /swapfile" || warn " 现有 /swapfile 启用失败"
    else
        info " 创建 /swapfile (${size} MB)..."
        if fallocate -l "${size}M" /swapfile 2>/dev/null || \
           dd if=/dev/zero of=/swapfile bs=1M count=$size status=none 2>/dev/null; then
            chmod 600 /swapfile
            if mkswap /swapfile >>"$LOG_FILE" 2>&1 && swapon /swapfile >>"$LOG_FILE" 2>&1; then
                ok " Swap 已启用（重启后失效；长期使用请自行写入 /etc/fstab）"
            else
                warn " Swap 启用失败，已删除临时文件"
                rm -f /swapfile
            fi
        else
            warn " Swap 文件创建失败（磁盘空间不足？）"
        fi
    fi
    info " 当前可用内存 $(avail_mem_mb) MB，Swap $(swap_total_mb) MB（合计 $(effective_mem_mb) MB）"
    return 0
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
    log_ready
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

# v3.3.6 改用 CMake，但 GitHub 的 release 源码包不含子模块，
# libcork / libipset / libbloom 三个目录是空的，直接 cmake 会报：
#   CMake Error at CMakeLists.txt:175 (add_library): No SOURCES given to target: bloom
# libcork 的 config/version.h 由 autotools 的 configure 从 version.h.in 生成，
# 某些 commit（如 master）里没有提交生成结果，会报 `libcork/config/version.h: No such file`
ensure_libcork_version_h() {
    local cork="$1" inc="$1/include/libcork/config"
    local ver="" maj="" min="" pat=""
    [[ -f "$inc/version.h" ]] && return 0
    [[ -f "$inc/version.h.in" ]] || return 0
    [[ -s "$cork/RELEASE-VERSION" ]] && ver="$(tr -d '[:space:]' < "$cork/RELEASE-VERSION")"
    ver="${ver#v}"
    if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"; pat="${BASH_REMATCH[3]}"
    else
        ver="0.15.0"; maj=0; min=15; pat=0
    fi
    sed -e "s/@VERSION_MAJOR@/${maj}/" -e "s/@VERSION_MINOR@/${min}/" \
        -e "s/@VERSION_PATCH@/${pat}/" -e "s/@VERSION@/${ver}/" \
        -e "s/@GIT_SHA1@/unknown/" "$inc/version.h.in" > "$inc/version.h" 2>>"$LOG_FILE" \
        && info " 生成 libcork/config/version.h（${ver}）" \
        || { err " 生成 libcork/config/version.h 失败"; return 1; }
    return 0
}

# 兜底：v3.3.5 的 release 包里子模块是「已填充」的（dist 归档），
# 万一固定 commit 拉不到，可以直接借用它的三个子模块目录
submodules_from_335() {
    local dir="$1" refdir="$1/../.ss335-$$" f
    info " 改从 v3.3.5 归档借用子模块源码"
    mkdir -p "$refdir"
    if ! gh_download "shadowsocks/shadowsocks-libev/releases/download/v3.3.5/shadowsocks-libev-3.3.5.tar.gz" "${refdir}/v335.tar.gz"; then
        err " v3.3.5 归档下载失败，无法借用子模块"
        rm -rf "$refdir"; return 1
    fi
    tar xzf "${refdir}/v335.tar.gz" --strip-components=1 -C "$refdir" 2>>"$LOG_FILE" || {
        err " v3.3.5 归档解压失败"; rm -rf "$refdir"; return 1; }
    for f in libcork libipset libbloom; do
        if find "${refdir}/${f}" -type f 2>/dev/null | grep -q .; then
            rm -rf "${dir:?}/${f}"
            mkdir -p "${dir}/${f}"
            cp -a "${refdir}/${f}/." "${dir}/${f}/" 2>>"$LOG_FILE" \
                && info " 已从 v3.3.5 借用 ${f}" \
                || { err " 借用 ${f} 失败"; rm -rf "$refdir"; return 1; }
        fi
    done
    ensure_libcork_version_h "${dir}/libcork" || true
    # v3.3.5 的 libcork 没有 core/version.c（3.3.6 的 CMake 会编译它），就地补一个
    if [[ ! -f "${dir}/libcork/src/libcork/core/version.c" ]]; then
        cat > "${dir}/libcork/src/libcork/core/version.c" <<'VERSIONC'
/* v3.3.5 归档未带此文件，按 3.3.6 的定义补齐 */
#include "libcork/config.h"
#include "libcork/core/api.h"

const char *
cork_version_string(void)
{
    return CORK_CONFIG_VERSION_STRING;
}

const char *
cork_revision_string(void)
{
    return CORK_CONFIG_REVISION;
}
VERSIONC
        info " 补写 libcork/core/version.c"
    fi
    rm -rf "$refdir"
    return 0
}

prepare_submodules() {
    log_ready
    local dir="$1" ver="${2-}" spec name repo dest ref alt
    # 目录名:仓库名 —— 注意 libipset 目录对应的仓库叫 ipset
    for spec in "libcork:libcork" "libipset:ipset" "libbloom:libbloom"; do
        name="${spec%%:*}"
        repo="${spec##*:}"
        dest="${dir}/${name}"
        if find "$dest" -type f 2>/dev/null | grep -q .; then
            continue
        fi
        # 按 tag 记录的真实 commit 取件；内置表里任何非法值都不会被使用
        ref="$(resolve_submodule_ref "$name" "${ver:-3.3.6}")"
        info " 补齐子模块 ${name}（release 包内为空目录，来源 shadowsocks/${repo}@${ref:0:8}）"
        mkdir -p "$dest"
        if gh_download "shadowsocks/${repo}/archive/${ref}.tar.gz" "${dir}/.${name}.tar.gz"; then
            :
        else
            # 仓库名可能不同（libipset → ipset 之外的历史命名），再试一次别名
            alt="${name}"
            if gh_download "shadowsocks/${alt}/archive/${ref}.tar.gz" "${dir}/.${name}.tar.gz"; then
                :
            elif [[ "$ref" != "master" ]] && gh_download "shadowsocks/${repo}/archive/refs/heads/master.tar.gz" "${dir}/.${name}.tar.gz"; then
                info " 固定 commit 取不到，退回 master"
            else
                warn " 子模块 ${name} 下载失败，改用 v3.3.5 归档兜底"
                submodules_from_335 "$dir" || return 1
                break
            fi
        fi
        if ! tar xzf "${dir}/.${name}.tar.gz" --strip-components=1 -C "$dest" 2>>"$LOG_FILE"; then
            err " 子模块 ${name} 解压失败"
            return 1
        fi
        rm -f "${dir}/.${name}.tar.gz"
        [[ "$name" == "libcork" ]] && { ensure_libcork_version_h "$dest" || return 1; }
    done
    local f ok=1
    for f in "libcork/src/libcork/core/allocator.c" \
             "libipset/src/libipset/general.c" \
             "libbloom/bloom.c"; do
        [[ -f "${dir}/${f}" ]] || { err " 子模块缺少关键文件: ${f}"; ok=0; }
    done
    [[ "$ok" -eq 1 ]] && ok " 子模块已就绪"
    return $(( ok == 1 ? 0 : 1 ))
}
# ---------------------------------------------------------------- 依赖安装
install_deps_base() {
    pkg_refresh
    pkg_clean
    info " 安装基础依赖"
    case "$PM" in
        apt)
            pkg_install curl tar ca-certificates coreutils procps iproute2 \
                        gcc make autoconf automake libtool pkg-config gettext libssl-dev || return 1
            pkg_install_opt qrencode
            ;;
        dnf|yum)
            pkg_install curl tar ca-certificates coreutils procps-ng iproute \
                        gcc gcc-c++ make autoconf automake libtool pkgconfig gettext openssl-devel || return 1
            pkg_install_opt qrencode
            ;;
    esac
    local c
    for c in gcc make tar curl; do
        command -v "$c" >/dev/null 2>&1 || { err " 基础工具缺失: $c（依赖安装可能被 OOM 打断）"; return 1; }
    done
    return 0
}

install_deps_autotools() {
    info " 安装 autotools 构建依赖（libev / libsodium / c-ares / mbedtls / pcre）"
    case "$PM" in
        apt)
            pkg_install libev-dev libsodium-dev libudns-dev libc-ares-dev libmbedtls-dev || return 1
            if ! pkg_install libpcre3-dev; then
                warn " 未找到 PCRE1 开发包（libpcre3-dev），v3.3.5 无法编译；可改用 SS_VER=3.3.6（CMake + PCRE2）"
            fi
            ;;
        dnf|yum)
            pkg_install libev-devel libsodium-devel udns-devel c-ares-devel mbedtls-devel pcre-devel || return 1
            ;;
    esac
    return 0
}

install_deps_cmake() {
    info " 安装 CMake 构建依赖（libev / libsodium / c-ares / mbedtls / pcre2 / glib）"
    case "$PM" in
        apt) pkg_install cmake libev-dev libsodium-dev libc-ares-dev libmbedtls-dev libpcre2-dev libglib2.0-dev || return 1 ;;
        *)   pkg_install cmake libev-devel libsodium-devel c-ares-devel mbedtls-devel pcre2-devel glib2-devel || return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------- 源码编译
_build() {
    log_ready
    local dir="$1" bs="$2" jobs avail
    jobs="$(nproc 2>/dev/null || echo 2)"
    avail="$(effective_mem_mb)"
    # 小内存机器并行编译容易 OOM，按可用内存收敛并发
    if (( avail < 1024 )); then
        jobs=1
    elif (( avail < 2048 )); then
        jobs=2
    elif (( jobs > 4 )); then
        jobs=4
    fi
    info " 编译并发: -j${jobs}（可用内存+Swap ${avail} MB）"
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
    log_ready
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
        autotools)
            install_deps_autotools || { rm -rf "$work"; return 1; }
            ;;
        cmake)
            install_deps_cmake || { rm -rf "$work"; return 1; }
            prepare_submodules "$dir" "$ver" || {
                err " 子模块补齐失败，v${ver} 无法用 CMake 构建"
                rm -rf "$work"
                return 1
            }
            ;;
        *)
            err " 未知构建系统"
            rm -rf "$work"
            return 1
            ;;
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

install_from_package() {
    info " 使用发行版仓库安装（SS_MODE=package）"
    pkg_install shadowsocks-libev || return 1
    hash -r
    export PATH="/usr/bin:/usr/local/bin:${PATH}"
    SS_BIN="$(command -v ss-server 2>/dev/null)"
    [[ -n "$SS_BIN" ]] || { err " 仓库安装完成但未找到 ss-server"; return 1; }
    ok " 已安装: ${SS_BIN}（仓库版本，无需编译）"
    return 0
}

install_ss() {
    echo
    info " 安装 SS..."
    : >"$LOG_FILE"

    if [[ "${SS_MODE:-source}" == "package" ]]; then
        install_from_package || die " 仓库安装失败（可去掉 SS_MODE=package 改用源码编译）"
        write_service
        ok " SS 安装完成"
        return 0
    fi

    resolve_version
    ensure_memory
    install_deps_base || die " 基础依赖安装失败（若日志里出现 Killed，即为内存不足），完整日志: ${LOG_FILE}"

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
