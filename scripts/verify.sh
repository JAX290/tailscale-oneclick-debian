#!/usr/bin/env bash
# =============================================================================
#  tailscale-oneclick-debian —— 部署后自检
#
#  用法：
#    sudo bash verify.sh          # 推荐（能检查 sshd 生效配置、sudo -l）
#    bash verify.sh               # 非 root 也能跑，部分检查会跳过
#    bash verify.sh --quiet       # 只输出失败项和总结
#
#  退出码：0 = 全部通过（可能有警告）；1 = 有失败项
# =============================================================================
set -uo pipefail

VERSION="1.0.0"
STATE_FILE="/etc/tailscale-oneclick/state.env"
OPS_USER="opsagent"
SUDOERS_FILE="/etc/sudoers.d/90-opsagent"
ALLOW_FILE="/etc/opsagent/services.allow"
QUIET=0

for arg in "$@"; do
    case "$arg" in
        --quiet|-q) QUIET=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -V|--version) printf 'verify.sh %s\n' "$VERSION"; exit 0 ;;
        *) printf '未知参数: %s（--help）\n' "$arg" >&2; exit 2 ;;
    esac
done

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_GRN=""; C_RED=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

PASS=0; FAIL=0; SKIP=0

section() { [[ $QUIET -eq 1 ]] && return 0; printf '\n%s\n' "${C_BLU}${C_BLD}== $* ==${C_RST}"; }
ok()   { PASS=$((PASS + 1)); [[ $QUIET -eq 1 ]] || printf '  %s %s\n' "${C_GRN}✓${C_RST}" "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  %s %s\n' "${C_RED}✗${C_RST}" "$*"; }
warn() { SKIP=$((SKIP + 1)); [[ $QUIET -eq 1 ]] || printf '  %s %s\n' "${C_YEL}!${C_RST}" "$*"; }
info() { [[ $QUIET -eq 1 ]] || printf '    %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

[[ -r "$STATE_FILE" ]] && { . "$STATE_FILE"; OPS_USER="${OPS_USER:-opsagent}"; }

printf '%s\n' "${C_BLD}tailscale-oneclick-debian 自检 v${VERSION}${C_RST}"
printf '  主机 %s · 时间 %s\n' "$(hostname 2>/dev/null)" "$(date -Is 2>/dev/null)"

# ------------------------------- 系统 ----------------------------------------
section "系统"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ok "发行版：${PRETTY_NAME:-$ID $VERSION_ID}"
else
    warn "读不到 /etc/os-release"
fi
ok "内核：$(uname -r)"

# ------------------------------- Tailscale -----------------------------------
section "Tailscale"
if ! have tailscale; then
    bad "没有安装 tailscale"
else
    ok "已安装：$(tailscale version 2>/dev/null | head -n1)"
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
        ok "tailscaled 运行中"
    else
        bad "tailscaled 未运行（systemctl status tailscaled）"
    fi

    state="$(tailscale status --json 2>/dev/null | grep -oE '"BackendState": *"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
    if [[ "$state" == "Running" ]]; then
        ok "已登录 tailnet（BackendState=Running）"
    else
        bad "未登录 tailnet（BackendState=${state:-未知}）"
    fi

    ts4="$(tailscale ip -4 2>/dev/null | head -n1)"
    if [[ "$ts4" == 100.* ]]; then
        ok "tailnet IPv4：$ts4"
    else
        bad "没有拿到 100.x 地址"
    fi

    peers="$(tailscale status 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
    info "对端设备数：${peers:-0}（至少要有 1 台你自己的设备才能远程登录）"

    if have timeout; then
        prefs="$(timeout 5 tailscale debug prefs 2>/dev/null || true)"
    else
        prefs="$(tailscale debug prefs 2>/dev/null || true)"
    fi
    if [[ -n "$prefs" ]]; then
        if grep -qE '"RunSSH": *true' <<< "$prefs"; then
            ok "Tailscale SSH 已启用（RunSSH=true）"
        else
            warn "Tailscale SSH 未启用：这台机器只能走 sshd（或重跑 install.sh 不带 --no-ssh）"
        fi
    else
        warn "无法读取 tailscale prefs（版本较旧？），跳过 RunSSH 检查"
    fi
fi

# ------------------------------- 运维账号 ------------------------------------
section "运维账号"
if id -u "$OPS_USER" >/dev/null 2>&1; then
    ok "账号存在：$OPS_USER（uid $(id -u "$OPS_USER")）"
    shell="$(getent passwd "$OPS_USER" | cut -d: -f7)"
    if [[ "$shell" == */nologin || "$shell" == */false ]]; then
        bad "登录 shell 是 $shell，无法登录"
    else
        ok "登录 shell：$shell"
    fi
    groups="$(id -nG "$OPS_USER" 2>/dev/null)"
    for g in adm systemd-journal; do
        if getent group "$g" >/dev/null 2>&1; then
            if grep -qw "$g" <<< "$groups"; then
                ok "在 $g 组（只读日志）"
            else
                warn "不在 $g 组，看不全日志（可选：usermod -aG $g $OPS_USER）"
            fi
        fi
    done
    if grep -qwE 'sudo|wheel' <<< "$groups"; then
        bad "在 sudo/wheel 组里！这等于给了完整 root 能力，和设计目标冲突"
    else
        ok "不在 sudo/wheel 组（root 能力只能走白名单工具）"
    fi
else
    bad "账号不存在：$OPS_USER"
fi

# ------------------------------- sudo 白名单 ---------------------------------
section "sudo 白名单"
if [[ -f "$SUDOERS_FILE" ]]; then
    perms="$(stat -c '%a %U:%G' "$SUDOERS_FILE" 2>/dev/null)"
    if [[ "$perms" == "440 root:root" ]]; then
        ok "sudoers 权限正确（$perms）"
    else
        bad "sudoers 权限异常：$perms（应为 440 root:root）"
    fi
    if [[ ${EUID} -eq 0 ]] && have visudo; then
        if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
            ok "sudoers 语法正确"
        else
            bad "sudoers 语法有错（visudo -cf $SUDOERS_FILE 看详情）"
        fi
    fi
    for tool in ops-status ops-restart ops-journal; do
        p="/usr/local/sbin/$tool"
        if [[ -x "$p" ]]; then
            owner="$(stat -c '%U:%G %a' "$p" 2>/dev/null)"
            if [[ "$owner" == "root:root 755" ]]; then
                ok "$tool 就位（$owner）"
            else
                bad "$tool 权限异常：$owner（应为 root:root 755，且 opsagent 不可写）"
            fi
        else
            bad "缺少 $p"
        fi
    done
    if [[ ${EUID} -eq 0 ]] && have sudo; then
        if sudo -l -U "$OPS_USER" 2>/dev/null | grep -q 'ops-status'; then
            ok "sudo -l -U $OPS_USER 能看到白名单命令"
        else
            bad "sudo -l -U $OPS_USER 里没有 ops-status，白名单未生效"
        fi
    else
        warn "非 root，跳过 sudo -l 检查"
    fi
else
    bad "没有安装 sudo 白名单：$SUDOERS_FILE"
fi

if [[ -f "$ALLOW_FILE" ]]; then
    n="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOW_FILE" | grep -cv '^$' || true)"
    ok "ops-restart 白名单：$ALLOW_FILE（${n:-0} 条）"
    if [[ "${n:-0}" -eq 0 ]]; then
        info "白名单为空 → ops-restart 会拒绝所有请求（这是安全的默认值）"
    fi
else
    warn "白名单文件不存在：$ALLOW_FILE"
fi

# ------------------------------- 审计 ----------------------------------------
section "审计"
if systemctl is-active --quiet auditd 2>/dev/null; then
    ok "auditd 运行中"
    if [[ ${EUID} -eq 0 ]] && have auditctl; then
        if auditctl -l 2>/dev/null | grep -q 'opsagent-exec'; then
            ok "opsagent 执行审计规则已加载"
        else
            warn "没看到 opsagent-exec 规则（可能被其它规则文件覆盖）"
        fi
    else
        warn "非 root，跳过 auditctl 检查"
    fi
else
    warn "auditd 未运行（可选组件；sudo 的 I/O 日志仍在）"
fi
if [[ -d /var/log/sudo-io ]]; then
    ok "sudo I/O 日志目录：/var/log/sudo-io"
else
    warn "没有 /var/log/sudo-io（sudo log_output 可能未启用）"
fi

# ------------------------------- SSH 暴露面 ----------------------------------
section "SSH 暴露面"
if have sshd && [[ ${EUID} -eq 0 ]]; then
    eff="$(sshd -T 2>/dev/null || true)"
    if [[ -n "$eff" ]]; then
        prl="$(grep -i '^permitrootlogin ' <<< "$eff" | awk '{print $2}')"
        pwa="$(grep -i '^passwordauthentication ' <<< "$eff" | awk '{print $2}')"
        [[ "$prl" == "no" ]] && ok "PermitRootLogin no" || warn "PermitRootLogin=${prl:-未知}（收口后应为 no）"
        [[ "$pwa" == "no" ]] && ok "PasswordAuthentication no" || warn "PasswordAuthentication=${pwa:-未知}（收口后应为 no）"
    else
        warn "sshd -T 无输出，无法检查生效配置"
    fi
elif ! have sshd; then
    warn "没有 sshd（只用 Tailscale SSH 的模式）"
else
    warn "非 root，跳过 sshd 生效配置检查"
fi

section "22 端口监听"
if have ss; then
    addrs="$(ss -ltn 2>/dev/null | awk 'NR>1 && $4 ~ /:22$/ {print $4}' | sort -u)"
    if [[ -z "$addrs" ]]; then
        warn "没有监听 22 端口（纯 Tailscale SSH 模式属于正常）"
    else
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            case "$a" in
                100.*|127.0.0.1:22|\[::1\]:22) ok "监听 ${a}（仅内网，安全）" ;;
                *) bad "监听 ${a}（公网暴露！跑 install.sh --lockdown 收口）" ;;
            esac
        done <<< "$addrs"
    fi
else
    warn "没有 ss 命令，跳过"
fi

# ------------------------------- 总结 ----------------------------------------
printf '\n%s\n' "${C_BLD}== 总结 ==${C_RST}"
printf '  通过 %d · 失败 %d · 提示 %d\n' "$PASS" "$FAIL" "$SKIP"
if [[ $FAIL -gt 0 ]]; then
    printf '%s\n' "${C_RED}  有失败项，按上面提示处理。日志：/var/log/tailscale-oneclick.log${C_RST}"
    exit 1
fi
printf '%s\n' "${C_GRN}  没有失败项。${C_RST}"
printf '  %s\n' "提醒：本机无法验证 tailnet ACL —— 请确认 ACL 里 ssh 规则只允许 ${OPS_USER}，并且默认那条允许 root 的规则已删除。"
exit 0
