#!/usr/bin/env bash
# =============================================================================
#  tailscale-oneclick-debian —— 卸载 / 回滚
#
#  默认行为（安全优先）：
#    - 撤销 --lockdown 对 sshd 的修改（恢复备份或删除 drop-in）
#    - 删除 sudo 白名单、运维账号、包装脚本、audit 规则
#    - 保留 tailscale 本身（用 --purge-tailscale 才卸载）
#
#  用法：
#    sudo bash uninstall.sh                 # 交互确认
#    sudo bash uninstall.sh -y              # 非交互
#    sudo bash uninstall.sh --keep-user     # 保留 opsagent 账号
#    sudo bash uninstall.sh --purge-tailscale
#    sudo bash uninstall.sh --dry-run
# =============================================================================
set -Eeuo pipefail

VERSION="1.0.0"
STATE_DIR="/etc/tailscale-oneclick"
STATE_FILE="${STATE_DIR}/state.env"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-tailscale-oneclick.conf"
SSHD_BACKUP="${STATE_DIR}/sshd-dropin.bak"
SUDOERS_FILE="/etc/sudoers.d/90-opsagent"
OPS_DIR="/etc/opsagent"
ALLOW_FILE="${OPS_DIR}/services.allow"
AUDIT_RULE="/etc/audit/rules.d/40-opsagent.rules"

OPS_USER="opsagent"
KEEP_USER=0
PURGE_TAILSCALE=0
ASSUME_YES=0
DRY_RUN=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_GRN=""; C_RED=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

step() { printf '\n%s\n' "${C_BLU}${C_BLD}==> $*${C_RST}"; }
ok()   { printf '  %s %s\n' "${C_GRN}✓${C_RST}" "$*"; }
warn() { printf '  %s %s\n' "${C_YEL}!${C_RST}" "$*" >&2; }
die()  { printf '  %s %s\n' "${C_RED}✗${C_RST}" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
tailscale-oneclick-debian 卸载 / 回滚

用法: bash uninstall.sh [选项]

默认行为:
  - 撤销 --lockdown 对 sshd 的修改（恢复备份或删除 drop-in）
  - 删除 sudo 白名单、包装脚本、audit 规则、状态文件
  - 默认删除 opsagent 账号（家目录保留）
  - 默认保留 tailscale 与 tailnet 登录

选项:
  -y, --yes            非交互确认
  --keep-user          保留 opsagent 账号
  --purge-tailscale    退出 tailnet 并卸载 tailscale 包（同时清理 apt 源）
  --dry-run            只打印计划，不改系统
  -h, --help           显示本帮助
  -V, --version        显示版本

示例:
  sudo bash uninstall.sh
  sudo bash uninstall.sh --dry-run
  sudo bash uninstall.sh --purge-tailscale -y
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)          ASSUME_YES=1; shift ;;
        --keep-user)       KEEP_USER=1; shift ;;
        --purge-tailscale) PURGE_TAILSCALE=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        -V|--version)      printf 'uninstall.sh %s\n' "$VERSION"; exit 0 ;;
        *)                 die "未知参数: $1（--help）" ;;
    esac
done

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '    [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

[[ -r "$STATE_FILE" ]] && { . "$STATE_FILE"; OPS_USER="${OPS_USER:-opsagent}"; }

step "卸载 tailscale-oneclick-debian"
printf '  将执行：\n'
printf '    - 撤销 sshd 收口（恢复备份/删除 %s）\n' "$SSHD_DROPIN"
printf '    - 删除 sudo 白名单 %s\n' "$SUDOERS_FILE"
printf '    - 删除包装脚本 ops-status / ops-restart / ops-journal\n'
printf '    - 删除 audit 规则 %s\n' "$AUDIT_RULE"
if [[ $KEEP_USER -eq 1 ]]; then
    printf '    - 保留运维账号 %s\n' "$OPS_USER"
else
    printf '    - 删除运维账号 %s（家目录保留）\n' "$OPS_USER"
fi
if [[ $PURGE_TAILSCALE -eq 1 ]]; then
    printf '    - 退出 tailnet 并卸载 tailscale 包\n'
else
    printf '    - 保留 tailscale 与 tailnet 登录\n'
fi
printf '\n'

if [[ $ASSUME_YES -ne 1 && $DRY_RUN -ne 1 ]]; then
    [[ -t 0 ]] || die "非交互环境请加 -y"
    read -r -p "确认继续？[y/N] " ans
    [[ "$ans" == y || "$ans" == Y ]] || die "已取消"
fi

require_root() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    [[ ${EUID} -eq 0 ]] || die "需要 root：sudo bash uninstall.sh ..."
}
require_root

sshd_unit() {
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then printf 'ssh'; else printf 'sshd'; fi
}

# ------------------------------- 1. sshd 收口 --------------------------------
step "撤销 sshd 收口"
if [[ -f "$SSHD_BACKUP" ]]; then
    run cp -a "$SSHD_BACKUP" "$SSHD_DROPIN"
    ok "已恢复收口前的 drop-in"
elif [[ -f "$SSHD_DROPIN" ]]; then
    run rm -f "$SSHD_DROPIN"
    ok "已删除收口 drop-in"
else
    warn "没有收口痕迹，跳过"
fi
if [[ $DRY_RUN -eq 0 ]] && command -v sshd >/dev/null 2>&1; then
    if sshd -t; then
        systemctl reload "$(sshd_unit)" || systemctl restart "$(sshd_unit)"
        ok "sshd 已 reload"
    else
        warn "sshd 配置有错，未 reload：检查 /etc/ssh/sshd_config.d/ 后手动 systemctl reload ssh"
    fi
fi

# ------------------------------- 2. sudo 白名单 ------------------------------
step "移除 sudo 白名单"
run rm -f "$SUDOERS_FILE"
ok "已删除 $SUDOERS_FILE"

# ------------------------------- 3. 包装脚本 --------------------------------
step "移除包装脚本"
for f in /usr/local/sbin/ops-status /usr/local/sbin/ops-restart /usr/local/sbin/ops-journal; do
    if [[ -e "$f" ]]; then
        run rm -f "$f"
        ok "已删除 $f"
    fi
done
run rm -rf "$OPS_DIR"
ok "已删除 $OPS_DIR（含白名单文件）"

# ------------------------------- 4. 审计 ------------------------------------
step "移除 audit 规则"
if [[ -f "$AUDIT_RULE" ]]; then
    run rm -f "$AUDIT_RULE"
    if [[ $DRY_RUN -eq 0 ]] && command -v augenrules >/dev/null 2>&1; then
        augenrules --load >/dev/null 2>&1 && ok "audit 规则已重新加载" || warn "augenrules --load 失败，重启后生效"
    fi
else
    warn "没有 audit 规则，跳过"
fi

# ------------------------------- 5. 运维账号 --------------------------------
step "处理运维账号"
if [[ $KEEP_USER -eq 1 ]]; then
    warn "按 --keep-user 保留 $OPS_USER"
elif id -u "$OPS_USER" >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '    [dry-run] userdel %s\n' "$OPS_USER"
    else
        pkill -u "$OPS_USER" 2>/dev/null || true
        sleep 1
        userdel "$OPS_USER" 2>/dev/null && ok "已删除账号 $OPS_USER（家目录保留）" \
            || warn "userdel 失败，可能有进程占用；手动：pkill -u $OPS_USER && userdel $OPS_USER"
    fi
else
    warn "账号不存在，跳过"
fi

# ------------------------------- 6. tailscale -------------------------------
step "处理 tailscale"
if [[ $PURGE_TAILSCALE -eq 1 ]]; then
    if command -v tailscale >/dev/null 2>&1; then
        run tailscale logout || true
        ok "已退出 tailnet"
    fi
    if [[ $DRY_RUN -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq tailscale \
            && ok "已卸载 tailscale 包" || warn "apt purge 失败，手动处理"
        rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg
        ok "已删除 apt 源与 keyring"
    fi
else
    warn "保留 tailscale（要卸载加 --purge-tailscale）"
fi

# ------------------------------- 7. 状态文件 --------------------------------
step "清理状态文件"
run rm -rf "$STATE_DIR"
ok "已删除 $STATE_DIR"

printf '\n%s\n' "${C_GRN}${C_BLD}卸载完成${C_RST}"
printf '  注意：/var/log/sudo-io 和 %s 之外的历史日志未删除，按需自行清理。\n' "$STATE_DIR"
