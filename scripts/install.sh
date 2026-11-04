#!/usr/bin/env bash
# =============================================================================
#  tailscale-oneclick-debian —— Debian 13 服务器初始化 + Tailscale 收口
#
#  一键完成：
#    1. 官方源安装 tailscale（trixie/bookworm 自动识别）
#    2. 加入你的 tailnet（authkey 免交互，或打印登录 URL 等人授权）
#    3. 创建运维账号 opsagent（非 root，只读日志权限）
#    4. 安装 sudo 白名单工具（ops-status / ops-restart / ops-journal）
#       —— 给的是"受限 root 能力"，不是 root shell
#    5. 开启审计：sudo 全量 I/O 日志 + auditd 记录 opsagent 执行
#    6. 第二阶段 --lockdown：确认 Tailscale SSH 可用后，把 sshd 收到
#       tailnet 内网地址并禁用 root/密码登录
#
#  用法：
#    bash install.sh                          # 阶段一：安全安装，不动现有 SSH
#    TS_AUTHKEY=tskey-auth-xxx bash install.sh
#    bash install.sh --authkey-file /root/ts.key --hostname web1
#    bash install.sh --dry-run                # 只打印计划，不改系统
#    bash install.sh --lockdown               # 阶段二：验证通过后收口
#    bash install.sh --unlock                 # 撤销收口，恢复原 sshd 监听
#
#  许可证：MIT
# =============================================================================
set -Eeuo pipefail

VERSION="1.0.0"
REPO_OWNER="JAX290"
REPO_NAME="tailscale-oneclick-debian"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/scripts/install.sh"

STATE_DIR="/etc/tailscale-oneclick"
STATE_FILE="${STATE_DIR}/state.env"
LOG_FILE="/var/log/tailscale-oneclick.log"
SUDOERS_FILE="/etc/sudoers.d/90-opsagent"
OPS_DIR="/etc/opsagent"
ALLOW_FILE="${OPS_DIR}/services.allow"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-0-tailscale-oneclick.conf"
# 注意文件名故意用 "00-0-"：sshd 对 scalar 选项是"先出现者生效"，
# 而 sshd_config 里的 Include 在文件开头，drop-in 按字典序加载。
# 云镜像常见 /etc/ssh/sshd_config.d/00-<厂商>.conf（例如 00-mofang.conf 里写着
# PermitRootLogin yes），用 "99-" 会被它压住；"00-0-" 排在所有 "00-<字母>" 之前，
# 才能保证我们的 PermitRootLogin no / PasswordAuthentication no 真正生效。
# 收口后脚本还会用 sshd -T 校验生效值，不达标就回滚，不会假装成功。
SSHD_BACKUP="${STATE_DIR}/sshd-dropin.bak"
AUDIT_RULE="/etc/audit/rules.d/40-opsagent.rules"

# ------------------------------- 默认参数 ------------------------------------
TS_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
TS_TAGS="${TS_TAGS:-tag:server}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_AUTHKEY_FILE=""
TS_SSH=1                      # 开启 Tailscale SSH
ACCEPT_DNS=0                  # 服务器默认不接管 DNS
SSH_USER="${SSH_USER:-opsagent}"
PUBKEY=""
DO_SUDO=1
DO_AUDIT=1
DRY_RUN=0
ASSUME_YES=0
NO_WAIT=0
FORCE=0
MODE="install"                # install | lockdown | unlock
SUITE=""

# ------------------------------- 输出工具 ------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[36m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_DIM=""; C_RST=""
fi

msg()  { printf '%s\n' "$*"; }
step() { printf '\n%s\n' "${C_BLU}${C_BLD}==> $*${C_RST}"; }
ok()   { printf '%s\n' "${C_GRN}  ✓ $*${C_RST}"; }
warn() { printf '%s\n' "${C_YEL}  ! $*${C_RST}" >&2; }
err()  { printf '%s\n' "${C_RED}  ✗ $*${C_RST}" >&2; }
dim()  { printf '%s\n' "${C_DIM}    $*${C_RST}"; }
die()  { err "$*"; printf '\n' >&2; err "排查：  tail -n 80 ${LOG_FILE}"; exit 1; }

on_error() {
    local line="${1:-?}"
    printf '\n' >&2
    err "脚本第 ${line} 行出错中断，系统可能处于半完成状态。"
    err "排查：  tail -n 80 ${LOG_FILE}"
    err "重跑是安全的：已完成的步骤会自动跳过。"
    exit 1
}
trap 'on_error $LINENO' ERR

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '    [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

# 写入 root 文件（自动创建父目录，原子替换）
write_root_file() {
    local path="$1" mode="$2" content="$3"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '    [dry-run] 写入 %s (mode %s, %s 字节)\n' "$path" "$mode" "${#content}"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "${path}.tmp.$$"
    chmod "$mode" "${path}.tmp.$$"
    chown root:root "${path}.tmp.$$"
    mv -f "${path}.tmp.$$" "$path"
}

mask() {
    local s="$1"
    if [[ ${#s} -le 12 ]]; then printf '***'; return 0; fi
    printf '%s…%s' "${s:0:10}" "${s: -4}"
}

confirm() {
    local prompt="$1"
    [[ $ASSUME_YES -eq 1 ]] && return 0
    [[ -t 0 ]] || die "$prompt —— 非交互环境请加 -y 明确确认。"
    local ans
    read -r -p "$prompt [y/N] " ans
    [[ $ans == y || $ans == Y || $ans == yes ]]
}

# ------------------------------- 参数解析 ------------------------------------
usage() {
    cat <<'EOF'
tailscale-oneclick-debian —— Debian 13 服务器初始化 + Tailscale 收口

用法: bash install.sh [选项]

模式:
  (默认)                 阶段一：装 tailscale、登录 tailnet、建 opsagent、
                         sudo 白名单、审计。不修改现有 sshd 配置。
  --lockdown             阶段二：确认 Tailscale SSH 从一个客户端可用之后，
                         把 sshd 只监听 tailnet 地址 + 禁 root/密码登录。
  --unlock               撤销 --lockdown 的 sshd 修改（安装本身不回滚）。

Tailscale:
  --authkey KEY          免交互登录用的 auth key（也可用环境变量 TS_AUTHKEY）
  --authkey-file FILE    从文件读取 auth key（推荐，避免落进 shell 历史）
  --hostname NAME        tailnet 里的设备名（默认短主机名）
  --tags TAG[,TAG]       设备标签（默认 tag:server；传空串 = 不加标签）
  --no-ssh               不开启 Tailscale SSH
  --accept-dns           允许 Tailscale 接管本机 DNS（默认不接管）
  --force                已登录也重新执行 tailscale up

运维账号:
  --user NAME            运维账号名（默认 opsagent）
  --pubkey KEY           给运维账号装 SSH 公钥，形如 "ssh-ed25519 AAAA..." 或 @文件路径
  --no-sudo              不安装 sudo 白名单 / 包装脚本
  --no-audit             不安装 auditd 规则

其他:
  --no-wait              交互登录只打印 URL，不等待授权完成
  --dry-run              只打印计划，不改系统（可在任意机器上跑）
  -y, --yes              非交互确认
  -h, --help             显示帮助
  -V, --version          显示版本

示例:
  TS_AUTHKEY=tskey-auth-xxxx bash install.sh
  bash install.sh --hostname web1 --authkey-file /root/ts.key
  bash install.sh --dry-run
  bash install.sh --lockdown
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --authkey)        TS_AUTHKEY="${2:?--authkey 需要参数}"; shift 2 ;;
        --authkey=*)      TS_AUTHKEY="${1#*=}"; shift ;;
        --authkey-file)   TS_AUTHKEY_FILE="${2:?--authkey-file 需要参数}"; shift 2 ;;
        --authkey-file=*) TS_AUTHKEY_FILE="${1#*=}"; shift ;;
        --hostname)       TS_HOSTNAME="${2:?--hostname 需要参数}"; shift 2 ;;
        --hostname=*)     TS_HOSTNAME="${1#*=}"; shift ;;
        --tags)           TS_TAGS="${2-}"; shift 2 ;;
        --tags=*)         TS_TAGS="${1#*=}"; shift ;;
        --user)           SSH_USER="${2:?--user 需要参数}"; shift 2 ;;
        --user=*)         SSH_USER="${1#*=}"; shift ;;
        --pubkey)         PUBKEY="${2:?--pubkey 需要参数}"; shift 2 ;;
        --pubkey=*)       PUBKEY="${1#*=}"; shift ;;
        --no-ssh)         TS_SSH=0; shift ;;
        --accept-dns)     ACCEPT_DNS=1; shift ;;
        --no-sudo)        DO_SUDO=0; shift ;;
        --no-audit)       DO_AUDIT=0; shift ;;
        --lockdown)       MODE="lockdown"; shift ;;
        --unlock)         MODE="unlock"; shift ;;
        --no-wait)        NO_WAIT=1; shift ;;
        --force)          FORCE=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        -V|--version)     printf '%s %s\n' "$REPO_NAME" "$VERSION"; exit 0 ;;
        *)                die "未知参数: $1（试 --help）" ;;
    esac
done

# 从文件读 authkey（避免命令行留痕）
if [[ -n "$TS_AUTHKEY_FILE" ]]; then
    [[ -r "$TS_AUTHKEY_FILE" ]] || die "读不到 authkey 文件: $TS_AUTHKEY_FILE"
    TS_AUTHKEY="$(tr -d '[:space:]' < "$TS_AUTHKEY_FILE")"
fi
if [[ -n "$PUBKEY" && "$PUBKEY" == @* ]]; then
    [[ -r "${PUBKEY#@}" ]] || die "读不到公钥文件: ${PUBKEY#@}"
    PUBKEY="$(tr -d '\r\n' < "${PUBKEY#@}")"
fi

# Tailscale 要求设备名是合法 DNS 标签：去掉非法字符，截断到 63 字符
TS_HOSTNAME="$(printf '%s' "$TS_HOSTNAME" | tr -cd 'A-Za-z0-9-' | cut -c1-63)"
[[ -n "$TS_HOSTNAME" ]] || die "--hostname 为空或只含非法字符（只允许字母/数字/连字符）"

# ------------------------------- 基础检查 ------------------------------------
require_root() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    [[ ${EUID} -eq 0 ]] || die "需要 root 权限：sudo bash install.sh ..."
}

detect_os() {
    [[ -r /etc/os-release ]] || {
        [[ $DRY_RUN -eq 1 ]] && { warn "非 Linux（无 /etc/os-release），仅做 dry-run 演示"; return 0; }
        die "找不到 /etc/os-release，本脚本只支持 Debian/Ubuntu"
    }
    # shellcheck disable=SC1091
    . /etc/os-release
    local id="${ID:-}" ver="${VERSION_ID:-}" codename="${VERSION_CODENAME:-}"
    case "${id}:${ver}" in
        debian:13) SUITE="trixie" ;;
        debian:12) SUITE="bookworm" ;;
        ubuntu:*)  SUITE="$codename" ;;
        *)
            [[ $DRY_RUN -eq 1 ]] && { warn "发行版 ${id} ${ver} 未测试（继续 dry-run）"; return 0; }
            die "只支持 Debian 12/13 和 Ubuntu（当前 ${id:-unknown} ${ver:-}）。Debian 13 用 trixie 源。"
            ;;
    esac
    [[ -n "$SUITE" ]] || die "无法确定 apt 源代号（codename 为空）"
}

require_systemd() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    [[ -d /run/systemd/system ]] || die "没有运行 systemd（容器/LXC？），本脚本要求 systemd 管理服务。"
}

# ------------------------------- 状态探测 ------------------------------------
ts_backend_state() {
    command -v tailscale >/dev/null 2>&1 || { printf 'Absent'; return 0; }
    tailscale status --json 2>/dev/null \
        | grep -oE '"BackendState": *"[^"]+"' \
        | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || printf 'Unknown'
}

ts_ipv4() {
    command -v tailscale >/dev/null 2>&1 || return 0
    # 注意：head 提前关闭管道会让 tailscale 收到 SIGPIPE，配合 pipefail 会把
    # 整个函数变成非 0 退出码；末尾的 || true 是必须的。
    tailscale ip -4 2>/dev/null | head -n1 || true
}

# 生成"去掉 --advertise-tags"的参数副本，结果放在全局 RETRY_ARGS
RETRY_ARGS=()
build_no_tag_args() {
    RETRY_ARGS=()
    local skip=0 a
    for a in "$@"; do
        if [[ $skip -eq 1 ]]; then skip=0; continue; fi
        if [[ $a == "--advertise-tags" ]]; then skip=1; continue; fi
        RETRY_ARGS+=("$a")
    done
}

# ------------------------------- 阶段一：安装 --------------------------------
preflight() {
    step "预检"
    if [[ $DRY_RUN -eq 1 ]]; then
        warn "dry-run 模式：只打印计划，不做任何修改"
    fi
    require_root
    require_systemd
    detect_os
    local arch
    arch="$(uname -m 2>/dev/null || echo unknown)"
    case "$arch" in
        x86_64|amd64|aarch64|arm64|armv7l|i686) ok "架构 $arch" ;;
        *) warn "架构 $arch 可能没有官方包，脚本继续但可能失败" ;;
    esac
    if [[ -z "$SUITE" ]]; then
        warn "跳过发行版检查（dry-run）"
    else
        ok "发行版识别：$SUITE"
    fi
    if [[ $DRY_RUN -eq 0 ]] && ! command -v curl >/dev/null 2>&1; then
        warn "缺少 curl，先安装基础依赖"
        env DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates \
            || die "安装 curl / ca-certificates 失败"
    fi
    if [[ -n "$TS_AUTHKEY" ]]; then
        ok "auth key：$(mask "$TS_AUTHKEY")"
    elif [[ "$(ts_backend_state)" == "Running" ]]; then
        ok "已登录 tailnet，不需要 auth key"
    else
        warn "没有 auth key，将走交互式登录（打印 URL 等你点授权）"
    fi
}

install_tailscale() {
    step "安装 Tailscale"
    if [[ $DRY_RUN -eq 0 ]] && command -v tailscale >/dev/null 2>&1; then
        ok "tailscale 已安装：$(tailscale version 2>/dev/null | head -n1 || true)"
    else
        dim "apt 源：https://pkgs.tailscale.com/stable/debian ${SUITE:-<suite>} main"
        if [[ $DRY_RUN -eq 0 ]]; then
            mkdir -p /usr/share/keyrings
            local tmp_gpg tmp_list
            tmp_gpg="$(mktemp)"; tmp_list="$(mktemp)"
            if ! curl -fsSL --max-time 60 \
                "https://pkgs.tailscale.com/stable/debian/${SUITE}.noarmor.gpg" -o "$tmp_gpg"; then
                rm -f "$tmp_gpg" "$tmp_list"
                die "下载 Tailscale 签名公钥失败（检查 DNS/网络/代理）"
            fi
            install -m 0644 "$tmp_gpg" /usr/share/keyrings/tailscale-archive-keyring.gpg
            if ! curl -fsSL --max-time 60 \
                "https://pkgs.tailscale.com/stable/debian/${SUITE}.tailscale-keyring.list" -o "$tmp_list"; then
                rm -f "$tmp_gpg" "$tmp_list"
                die "下载 Tailscale apt 源列表失败"
            fi
            install -m 0644 "$tmp_list" /etc/apt/sources.list.d/tailscale.list
            rm -f "$tmp_gpg" "$tmp_list"
            ok "已写入 apt 源与 keyring"
        else
            dim "[dry-run] curl 公钥 → /usr/share/keyrings/tailscale-archive-keyring.gpg"
            dim "[dry-run] curl 源列表 → /etc/apt/sources.list.d/tailscale.list"
        fi
        run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale
        ok "tailscale 安装完成"
    fi
    run systemctl enable --now tailscaled
    if [[ $DRY_RUN -eq 0 ]]; then
        local i
        for i in $(seq 1 30); do
            if tailscale status >/dev/null 2>&1; then break; fi
            sleep 1
        done
        ok "tailscaled 运行中（$(systemctl is-active tailscaled 2>/dev/null || echo unknown)）"
    fi
}

apply_runtime_prefs() {
    # 已登录时不能再用 tailscale up 改 hostname/tags（会要求重新授权），
    # 但 SSH 与 DNS 偏好可以即时设置，而且幂等。
    local accept_bool="false"
    [[ $ACCEPT_DNS -eq 1 ]] && accept_bool="true"
    local -a set_args=("--accept-dns=${accept_bool}")
    if [[ $TS_SSH -eq 1 ]]; then
        set_args+=("--ssh=true")
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        dim "[dry-run] tailscale set ${set_args[*]}"
        return 0
    fi

    local out rc=0
    out="$(tailscale set "${set_args[@]}" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        if grep -q 'lose-ssh' <<< "$out"; then
            # tailscale 的保护：从 tailnet 内开启 Tailscale SSH 会重定向 22 端口，
            # 当前这条 SSH 会话会被切断。不替用户做这个决定。
            if [[ "${SSH_CONNECTION:-}" == 100.* ]]; then
                warn "当前 SSH 会话来自 tailnet，开启 Tailscale SSH 会重定向 22 端口并切断本会话"
                warn "已跳过运行偏好同步。请改用公网 IP 登录后重跑，或在云控制台执行："
                warn "  tailscale set --ssh --accept-risk=lose-ssh"
                return 0
            fi
            warn "tailscale 要求确认 lose-ssh 风险，重试并接受（本会话来自非 tailnet，安全）"
            if tailscale set --accept-risk=lose-ssh "${set_args[@]}" >/dev/null 2>&1; then
                ok "已同步运行偏好：${set_args[*]}（accept-risk=lose-ssh）"
            else
                warn "仍失败，手动执行：tailscale set --accept-risk=lose-ssh ${set_args[*]}"
                return 0
            fi
        else
            warn "tailscale set 失败：${out}"
            warn "必要时手动：tailscale up --ssh --accept-dns=${accept_bool}"
            return 0
        fi
    else
        ok "已同步运行偏好：${set_args[*]}"
    fi

    if tailscale debug prefs 2>/dev/null | grep -qE '"RunSSH": *true'; then
        ok "Tailscale SSH 已启用（RunSSH=true）"
    elif [[ $TS_SSH -eq 1 ]]; then
        warn "RunSSH 仍为 false，检查：tailscale debug prefs | grep RunSSH"
    fi
}

join_tailnet() {
    step "加入 tailnet"
    local state; state="$(ts_backend_state)"
    if [[ "$state" == "Running" && $FORCE -eq 0 ]]; then
        ok "已登录 tailnet，跳过登录"
        local actual
        actual="$(tailscale status 2>/dev/null | head -n1 | awk '{print $2}' || true)"
        if [[ -n "$actual" ]]; then
            TS_HOSTNAME="$actual"
        fi
        dim "当前设备名：$(tailscale status 2>/dev/null | head -n1 || true)"
        apply_runtime_prefs
        return 0
    fi

    local -a up_args=("--hostname" "$TS_HOSTNAME")
    if [[ $ACCEPT_DNS -eq 1 ]]; then
        up_args+=("--accept-dns=true")
    else
        up_args+=("--accept-dns=false")
    fi
    if [[ -n "$TS_TAGS" ]]; then
        up_args+=("--advertise-tags" "$TS_TAGS")
    fi
    if [[ $TS_SSH -eq 1 ]]; then
        up_args+=("--ssh")
        # 从 tailnet 内执行 up 时，tailscale 会要求确认 lose-ssh 风险；
        # 老版本没有这个 flag，先探测再用。
        if tailscale up --help 2>/dev/null | grep -q 'accept-risk'; then
            up_args+=("--accept-risk=lose-ssh")
        fi
    fi
    if [[ $FORCE -eq 1 ]]; then
        up_args+=("--force-reauth")
    fi

    # 没有配置 tagOwners 的 tailnet 会拒绝 --advertise-tags，所以失败时自动降级为
    # "无标签加入"，并提示怎么补。否则新用户第一次跑就会卡在 tag 错误上。
    local up_ok=0
    if [[ -n "$TS_AUTHKEY" ]]; then
        up_args+=("--auth-key" "$TS_AUTHKEY")
        if [[ $DRY_RUN -eq 1 ]]; then
            dim "[dry-run] tailscale up --hostname ${TS_HOSTNAME} --accept-dns=${ACCEPT_DNS} --advertise-tags ${TS_TAGS} --auth-key $(mask "$TS_AUTHKEY")"
            up_ok=1
        elif tailscale up "${up_args[@]}"; then
            up_ok=1
            ok "已用 auth key 登录"
        fi
    else
        dim "执行：tailscale up ${up_args[*]}（会打印授权 URL）"
        if [[ $DRY_RUN -eq 1 ]]; then
            dim "[dry-run] 前台执行并打印 https://login.tailscale.com/... 授权链接"
            up_ok=1
        elif interactive_login "${up_args[@]}"; then
            up_ok=1
        fi
    fi

    if [[ $up_ok -eq 0 && $DRY_RUN -eq 0 ]]; then
        if [[ -n "$TS_TAGS" ]]; then
            warn "带标签加入失败。常见原因：ACL 里没定义 tagOwners，或当前账号不是 tag owner"
            warn "自动重试：去掉 --advertise-tags 再加入（之后配好 tagOwners 可用 --force 重登加标签）"
            build_no_tag_args "${up_args[@]}"
            if [[ -n "$TS_AUTHKEY" ]]; then
                if tailscale up "${RETRY_ARGS[@]}"; then up_ok=1; ok "已用 auth key 登录（无标签）"; fi
            else
                if interactive_login "${RETRY_ARGS[@]}"; then up_ok=1; fi
            fi
            if [[ $up_ok -eq 1 ]]; then
                warn "已加入 tailnet，但设备没有标签；ACL 里按 tag 授权的规则不会命中"
                warn "配好 tagOwners 后：bash install.sh --force --tags ${TS_TAGS}"
            fi
        fi
        [[ $up_ok -eq 1 ]] || die "tailscale up 失败（auth key 过期/已被使用，或网络问题；见上方输出）"
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        local i ts4=""
        for i in $(seq 1 60); do
            ts4="$(ts_ipv4 || true)"
            [[ -n "$ts4" ]] && break
            sleep 1
        done
        [[ -n "$ts4" ]] || die "tailscale 已启动但没有拿到 100.x 地址，检查：tailscale status"
        ok "tailnet IP：$ts4"
    fi
}

interactive_login() {
    local -a up_args=("$@")
    local tmp rc
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    printf '\n'
    printf '%s\n' "${C_BLD}  下一步：屏幕会打印一条 https://login.tailscale.com/... 链接${C_RST}"
    printf '%s\n' "${C_BLD}  在浏览器打开它、登录并点授权（链接一次性、有时效，别外传）${C_RST}"
    printf '\n'

    if [[ $NO_WAIT -eq 1 ]]; then
        setsid tailscale up "${up_args[@]}" >"$tmp" 2>&1 </dev/null &
        sleep 5
        grep -oE 'https://login\.tailscale\.com/[A-Za-z0-9/_-]+' "$tmp" | head -n1 || true
        ok "已在后台发起登录，稍后用 tailscale status 查看结果"
        return 0
    fi

    set +e
    timeout 600 tailscale up "${up_args[@]}" 2>&1 | tee "$tmp"
    rc="${PIPESTATUS[0]}"
    set -e

    if [[ "$rc" -eq 124 ]]; then
        warn "等待授权超时（10 分钟）；重跑脚本即可，已完成的步骤会跳过"
        return 124
    fi
    if [[ "$rc" -ne 0 ]]; then
        cat "$tmp" >&2 || true
        return "$rc"
    fi
    if ! grep -q 'login\.tailscale\.com' "$tmp"; then
        warn "没有在输出里识别到授权链接，但命令返回成功；用 tailscale status 确认一下"
    fi
    ok "授权完成"
    return 0
}

create_ops_user() {
    step "创建运维账号：${SSH_USER}"
    if id -u "$SSH_USER" >/dev/null 2>&1; then
        ok "账号已存在，跳过"
    else
        run useradd -m -s /bin/bash "$SSH_USER"
        ok "已创建（无 sudo 组权限，root 能力只能通过白名单工具获得）"
    fi

    # 只读日志权限：adm / systemd-journal
    local g
    for g in adm systemd-journal; do
        if getent group "$g" >/dev/null 2>&1; then
            run usermod -aG "$g" "$SSH_USER"
            ok "已加入 ${g} 组（可读日志，但仍无 root）"
        fi
    done

    if [[ -n "$PUBKEY" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            dim "[dry-run] 写入 /home/${SSH_USER}/.ssh/authorized_keys（restrict,pty）"
        else
            local home dir
            home="$(getent passwd "$SSH_USER" | cut -d: -f6)"
            dir="${home}/.ssh"
            install -d -m 0700 -o "$SSH_USER" -g "$(id -gn "$SSH_USER")" "$dir"
            touch "${dir}/authorized_keys"
            if ! grep -qF -- "$PUBKEY" "${dir}/authorized_keys"; then
                printf 'restrict,pty %s\n' "$PUBKEY" >> "${dir}/authorized_keys"
            fi
            chmod 0600 "${dir}/authorized_keys"
            chown "$SSH_USER":"$(id -gn "$SSH_USER")" "${dir}/authorized_keys"
            ok "已安装备用公钥（可走 sshd，也可走 Tailscale SSH 之外的兜底通道）"
        fi
    fi
}

install_ops_tools() {
    [[ $DO_SUDO -eq 1 ]] || { warn "跳过 sudo 白名单（--no-sudo）"; return 0; }
    step "安装 sudo 白名单工具"

    local ops_status ops_restart ops_journal
    ops_status="$(cat <<'EOS'
#!/usr/bin/env bash
# 只读诊断：状态/磁盘/内存/端口/失败服务/近期错误日志
# 由 tailscale-oneclick-debian 安装；不要给非白名单用户执行权限。
set -u
export LC_ALL=C
echo "===== 主机 ====="
hostname; uptime
echo
echo "===== 系统 ====="
. /etc/os-release 2>/dev/null || true
printf '发行版 : %s\n' "${PRETTY_NAME:-unknown}"
printf '内核   : %s\n' "$(uname -r)"
echo
echo "===== 磁盘 ====="
df -h -x tmpfs -x devtmpfs 2>/dev/null || df -h
echo
echo "===== 内存 ====="
free -h
echo
echo "===== CPU TOP 8 ====="
ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 9 || true
echo
echo "===== 监听端口 ====="
ss -lntup 2>/dev/null || true
echo
echo "===== 失败的服务单元 ====="
systemctl --failed --no-pager 2>/dev/null || true
echo
echo "===== 近期错误日志（40 行） ====="
journalctl -p 3 -n 40 --no-pager 2>/dev/null || true
echo
echo "===== Tailscale ====="
tailscale status 2>/dev/null || echo "tailscale 不可用"
tailscale ip -4 2>/dev/null || true
EOS
)"

    ops_restart="$(cat <<'EOS'
#!/usr/bin/env bash
# 重启 /etc/opsagent/services.allow 白名单内的 systemd 单元
# 用法: ops-restart <unit>
set -euo pipefail
ALLOW="/etc/opsagent/services.allow"

if [[ $# -ne 1 ]]; then
    echo "用法: ops-restart <unit>   （白名单文件：${ALLOW}）" >&2
    exit 2
fi
unit="$1"
if [[ ! "$unit" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,63}$ ]] || [[ "$unit" == *..* ]]; then
    echo "非法单元名: ${unit}" >&2
    exit 2
fi
if [[ ! -r "$ALLOW" ]]; then
    echo "白名单不存在: ${ALLOW}" >&2
    exit 3
fi
allowed="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOW" | grep -v '^$' || true)"
if ! grep -qxF -- "$unit" <<< "$allowed"; then
    echo "不在白名单: ${unit}" >&2
    echo "（由 root 编辑 ${ALLOW} 添加，一行一个单元名）" >&2
    exit 3
fi
systemctl restart -- "$unit"
if systemctl is-active --quiet -- "$unit"; then
    echo "OK: ${unit} 已重启"
else
    echo "警告: ${unit} 未处于 active 状态" >&2
    systemctl status --no-pager -- "$unit" | head -n 20 >&2 || true
    exit 4
fi
EOS
)"

    ops_journal="$(cat <<'EOS'
#!/usr/bin/env bash
# 查看指定 unit 的 journal（只读）
# 用法: ops-journal <unit> [行数，默认 80，最多 500]
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "用法: ops-journal <unit> [行数]" >&2
    exit 2
fi
unit="$1"
lines="${2:-80}"
if [[ ! "$unit" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,63}$ ]] || [[ "$unit" == *..* ]]; then
    echo "非法单元名: ${unit}" >&2
    exit 2
fi
if [[ ! "$lines" =~ ^[0-9]+$ ]] || (( lines < 1 || lines > 500 )); then
    echo "行数必须是 1..500 的整数" >&2
    exit 2
fi
journalctl -u "$unit" -n "$lines" --no-pager -o short-iso
EOS
)"

    write_root_file /usr/local/sbin/ops-status  0755 "$ops_status"
    write_root_file /usr/local/sbin/ops-restart 0755 "$ops_restart"
    write_root_file /usr/local/sbin/ops-journal 0755 "$ops_journal"
    ok "已安装 ops-status / ops-restart / ops-journal"

    if [[ ! -f "$ALLOW_FILE" ]]; then
        write_root_file "$ALLOW_FILE" 0644 "$(cat <<'EOS'
# 允许 opsagent 通过 ops-restart 重启的 systemd 单元，一行一个。
# 由 root 维护；opsagent 不能写这个文件。
# 示例：
# nginx.service
# myapp.service
EOS
)"
    fi
    ok "白名单：${ALLOW_FILE}（默认为空，ops-restart 会拒绝一切）"

    local sudoers
    sudoers="$(cat <<EOS
# 由 tailscale-oneclick-debian 生成
# opsagent 只能执行这三个包装脚本，不能执行任意命令
Defaults:${SSH_USER} log_input, log_output, iolog_dir=/var/log/sudo-io
Cmnd_Alias OPS_TOOLS = /usr/local/sbin/ops-status, /usr/local/sbin/ops-restart *, /usr/local/sbin/ops-journal *
${SSH_USER} ALL=(root) NOPASSWD: OPS_TOOLS
EOS
)"
    if [[ $DRY_RUN -eq 1 ]]; then
        dim "[dry-run] 写入 ${SUDOERS_FILE}（先校验后原子替换）"
        dim "[dry-run] visudo -cf <临时文件> && mv 到 ${SUDOERS_FILE}"
    else
        # 先写到被 sudo 忽略的临时名（含 '.'），校验通过再原子替换，
        # 避免一个语法错误的 sudoers 文件把整台机器的 sudo 搞坏。
        mkdir -p /etc/sudoers.d
        local tmpf="/etc/sudoers.d/.90-opsagent.tmp"
        printf '%s\n' "$sudoers" > "$tmpf"
        chmod 0440 "$tmpf"
        chown root:root "$tmpf"
        if ! visudo -cf "$tmpf" >/dev/null; then
            rm -f "$tmpf"
            die "sudoers 语法校验失败，未安装（现有 sudo 配置未被触碰）"
        fi
        mv -f "$tmpf" "$SUDOERS_FILE"
        install -d -m 0700 -o root -g root /var/log/sudo-io
        ok "sudo 白名单已生效，完整 I/O 日志：/var/log/sudo-io"
    fi

    warn "注意：运维账号没有 shell 级的 root 能力，root 操作只能通过这三个工具"
}

install_audit() {
    [[ $DO_AUDIT -eq 1 ]] || { warn "跳过 auditd 规则（--no-audit）"; return 0; }
    step "开启审计"
    if [[ $DRY_RUN -eq 1 ]]; then
        dim "[dry-run] apt-get install -y auditd；写入 ${AUDIT_RULE}；augenrules --load"
        return 0
    fi
    if ! command -v auditctl >/dev/null 2>&1; then
        if ! env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq auditd; then
            warn "auditd 安装失败（容器环境常见），跳过审计规则"
            return 0
        fi
    fi
    local ouid
    ouid="$(id -u "$SSH_USER" 2>/dev/null || echo '')"
    if [[ -z "$ouid" ]]; then
        warn "账号不存在，跳过 audit 规则"
        return 0
    fi
    write_root_file "$AUDIT_RULE" 0640 "$(cat <<EOS
## 由 tailscale-oneclick-debian 生成：记录 ${SSH_USER} 直接执行的进程
## sudo 子进程以 root 运行，由 sudo 的 log_output/iolog 记录
-a always,exit -F arch=b64 -S execve -F uid=${ouid} -k opsagent-exec
EOS
)"
    if augenrules --load >/dev/null 2>&1; then
        ok "auditd 规则已加载（auditctl -l | grep opsagent-exec 可查）"
    else
        warn "augenrules --load 失败，重启后生效或手动检查 /etc/audit/rules.d/"
    fi
    run systemctl enable --now auditd
}

# ------------------------------- 阶段二：收口 --------------------------------
sshd_unit() {
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then printf 'ssh'; else printf 'sshd'; fi
}

lockdown() {
    require_root
    step "收口 sshd（只监听 tailnet）"

    command -v sshd >/dev/null 2>&1 || die "没有 sshd（没装 openssh-server？），收口没有意义"
    # lockdown 模式不经过 join_tailnet，这里补一次真实设备名（提示信息里要用）
    local actual
    actual="$(tailscale status 2>/dev/null | head -n1 | awk '{print $2}' || true)"
    [[ -n "$actual" ]] && TS_HOSTNAME="$actual"
    [[ "$(ts_backend_state)" == "Running" ]] || die "Tailscale 未登录，先跑阶段一完成 tailscale up"
    local ts4; ts4="$(ts_ipv4 || true)"
    [[ "$ts4" == 100.* ]] || die "拿不到 tailnet IPv4（当前：'${ts4:-空}'），先确认 tailscale status"

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        local remote_ip="${SSH_CONNECTION%% *}"
        if [[ "$remote_ip" != 100.* ]]; then
            warn "你当前这条 SSH 连接来自公网地址 ${remote_ip}，不是 tailnet。"
            warn "收口后这条会话不会断，但下次重连必须走 Tailscale；"
            warn "请先确认：另一个客户端能 tailscale ssh ${SSH_USER}@${TS_HOSTNAME} 成功。"
            confirm "确认已经验证过 Tailscale SSH 可用，继续？" || die "已取消（未做任何修改）"
        else
            ok "当前连接来自 tailnet（${remote_ip}），安全"
        fi
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        dim "[dry-run] 备份并写入 ${SSHD_DROPIN}"
        dim "[dry-run] ListenAddress ${ts4} / 127.0.0.1"
        dim "[dry-run] PermitRootLogin no; PasswordAuthentication no; KbdInteractiveAuthentication no"
        dim "[dry-run] sshd -t && systemctl reload $(sshd_unit)"
        return 0
    fi

    mkdir -p "$STATE_DIR"
    # 只备份"别人的"配置；如果已经是我们自己写的 drop-in（重复执行 --lockdown），
    # 绝不能把它当成原始配置备份，否则 --unlock 会恢复成收口状态。
    if [[ -f "$SSHD_DROPIN" && ! -f "$SSHD_BACKUP" ]] && \
       ! grep -q "Managed by ${REPO_NAME}" "$SSHD_DROPIN" 2>/dev/null; then
        cp -a "$SSHD_DROPIN" "$SSHD_BACKUP"
    fi

    write_root_file "$SSHD_DROPIN" 0644 "$(cat <<EOS
# Managed by ${REPO_NAME} (--lockdown)
# 撤销：bash install.sh --unlock
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
ListenAddress ${ts4}
ListenAddress 127.0.0.1
EOS
)"

    if ! sshd -t 2>/tmp/sshd-test.err; then
        cat /tmp/sshd-test.err >&2 || true
        rm -f "$SSHD_DROPIN"
        if [[ -f "$SSHD_BACKUP" ]]; then cp -a "$SSHD_BACKUP" "$SSHD_DROPIN"; fi
        die "sshd 配置校验失败，已回滚本次修改"
    fi
    ok "sshd 配置校验通过"

    local unit; unit="$(sshd_unit)"
    systemctl reload "$unit" || systemctl restart "$unit"
    sleep 1

    # 校验"生效值"而不是"我们写了什么"：云镜像常在 00-<厂商>.conf 里
    # 写死 PermitRootLogin yes，靠文件名顺序压制会让收口静默失效。
    local eff
    eff="$(sshd -T 2>/dev/null || true)"
    if ! grep -qiE '^permitrootlogin no$' <<< "$eff" || \
       ! grep -qiE '^passwordauthentication no$' <<< "$eff"; then
        warn "收口未完全生效：有更靠前的 sshd 配置覆盖了我们的设置"
        grep -rnE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication)' \
            /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || true
        rm -f "$SSHD_DROPIN"
        if [[ -f "$SSHD_BACKUP" ]]; then cp -a "$SSHD_BACKUP" "$SSHD_DROPIN"; fi
        systemctl reload "$unit" >/dev/null 2>&1 || true
        save_state "0"
        die "已回滚 sshd 修改。请先处理上面列出的配置（去掉其中的 PermitRootLogin yes / PasswordAuthentication yes），再重跑 --lockdown"
    fi
    ok "生效配置已确认：PermitRootLogin=no, PasswordAuthentication=no"

    if ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qx "${ts4}:22"; then
        ok "sshd 已在 ${ts4}:22 监听"
    else
        warn "sshd 没有按预期监听 ${ts4}:22，检查：ss -ltn | grep :22"
    fi
    if ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE '^(\*|0\.0\.0\.0|\[::\]):22$'; then
        warn "仍有监听在通配地址 :22 的进程（别的 sshd 实例或 socket 激活），检查：ss -ltnp | grep :22"
    fi

    save_state "1"
    ok "收口完成：公网 22 已不再暴露，root/密码登录已禁用"
    dim "撤销：bash install.sh --unlock"
    dim "救援通道：云厂商 Web Console / VNC"
}

unlock() {
    require_root
    step "撤销 sshd 收口"
    command -v sshd >/dev/null 2>&1 || die "没有 sshd，无需撤销"
    if [[ $DRY_RUN -eq 1 ]]; then
        dim "[dry-run] 删除 ${SSHD_DROPIN}（若有备份则恢复备份）并 reload sshd"
        return 0
    fi
    local unit; unit="$(sshd_unit)"
    if [[ -f "$SSHD_BACKUP" ]] && ! grep -q "Managed by ${REPO_NAME}" "$SSHD_BACKUP" 2>/dev/null; then
        cp -a "$SSHD_BACKUP" "$SSHD_DROPIN"
        ok "已恢复收口前的 drop-in 备份"
    elif [[ -f "$SSHD_DROPIN" ]]; then
        rm -f "$SSHD_DROPIN"
        ok "已删除 ${SSHD_DROPIN}"
    else
        warn "没有找到收口痕迹，跳过"
    fi
    if sshd -t; then
        systemctl reload "$unit" || systemctl restart "$unit"
        ok "sshd 已 reload（恢复 0.0.0.0:22 监听）"
    else
        die "恢复后的 sshd 配置仍然有错，检查 /etc/ssh/sshd_config.d/"
    fi
    save_state "0"
    warn "注意：--lockdown 只会被撤销；Tailscale/运维账号/白名单仍在，按需卸载请用 uninstall.sh"
}

# ------------------------------- 状态与总结 ----------------------------------
save_state() {
    local lockdown_flag="${1:-0}"
    [[ $DRY_RUN -eq 1 ]] && return 0
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOS
TOOL_VERSION=${VERSION}
REPO=${REPO_URL}
CREATED_AT=$(date -Is)
TS_HOSTNAME=${TS_HOSTNAME}
TS_TAGS=${TS_TAGS}
TS_SSH=${TS_SSH}
ACCEPT_DNS=${ACCEPT_DNS}
OPS_USER=${SSH_USER}
LOCKDOWN=${lockdown_flag}
SSHD_DROPIN=${SSHD_DROPIN}
OPS_ALLOW_FILE=${ALLOW_FILE}
EOS
    chmod 0600 "$STATE_FILE"
}

summary() {
    step "完成"
    local ts4; ts4="$(ts_ipv4 || true)"
    printf '%s\n' "${C_BLD}${C_GRN}  ┌──────────────────────────────────────────────────────┐${C_RST}"
    printf '%s\n' "${C_BLD}${C_GRN}  │  服务器已就绪                                       │${C_RST}"
    printf '%s\n' "${C_BLD}${C_GRN}  └──────────────────────────────────────────────────────┘${C_RST}"
    printf '\n'
    printf '  设备名         : %s\n' "${TS_HOSTNAME}"
    printf '  tailnet IP     : %s\n' "${ts4:-<未就绪>}"
    printf '  运维账号       : %s（无 root shell）\n' "${SSH_USER}"
    printf '  root 能力      : sudo ops-status / ops-restart / ops-journal\n'
    printf '  审计           : sudo I/O 在 /var/log/sudo-io；auditd 关键字 opsagent-exec\n'
    printf '  安装日志       : %s\n' "${LOG_FILE}"
    printf '\n'
    printf '%s\n' "${C_BLD}  接下来（按顺序）${C_RST}"
    printf '  1) 在你的电脑上装 Tailscale 并登录同一账号，然后测试：\n'
    printf '       %s\n' "tailscale ssh ${SSH_USER}@${TS_HOSTNAME}"
    printf '  2) 收紧 tailnet ACL（默认策略可能允许 root 走 Tailscale SSH！）\n'
    printf '       %s\n' "${REPO_URL}/blob/main/acl/policy.example.json"
    printf '  3) 测试第二台客户端也能登录后，再跑收口：\n'
    printf '       %s\n' "bash <(curl -Ls ${RAW_URL}) --lockdown"
    printf '  4) 日常只读诊断：\n'
    printf '       %s\n' "ssh ${SSH_USER}@${TS_HOSTNAME} sudo ops-status"
    printf '\n'
    printf '%s\n' "${C_YEL}  保存好你的云厂商 Web Console 入口 —— 那是改坏 sshd 后的救援通道${C_RST}"
    printf '\n'
}

main() {
    if [[ $DRY_RUN -eq 0 && -w /var/log ]]; then
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi
    printf '%s\n' "${C_DIM}${REPO_NAME} v${VERSION}  ·  $(date -Is)  ·  mode=${MODE}${C_RST}"

    case "$MODE" in
        lockdown) lockdown; return 0 ;;
        unlock)   unlock;   return 0 ;;
    esac

    preflight
    install_tailscale
    join_tailnet
    create_ops_user
    install_ops_tools
    install_audit
    save_state "0"
    summary
}

main "$@"
