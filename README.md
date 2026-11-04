# Debian 13 服务器一键初始化 + Tailscale 收口

> **换一台服务器，跑一条命令**：装好 Tailscale 拉进你的私有网络，建一个"能干活但作不了恶"的运维账号，
> 把 root 操作收进白名单，顺便把审计打开。
>
> 不给 root 密码、不对公网开 SSH、不让 AI 拿到 root shell —— 但该做的事都能做。

---

## 这个仓库解决什么问题

你（或者你的 AI 助手）需要在服务器上做运维，但直接把 root 交出去风险太大：

| 风险 | 后果 |
|---|---|
| 提示注入（AI 读了恶意网页/日志/issue） | 拿到 root 的 AI 会把整台机器连同数据交出去 |
| AI 失误（删错目录、改错配置） | root 下没有"撤销" |
| 密码/密钥外泄 | 一旦写进聊天、脚本、日志，无法知道有没有被抄走 |
| 事后无法追溯 | 不知道谁在什么时候执行了什么 |

所以本仓库的思路是 **"最小权限 + 可审计 + 可回滚"**：

```
你的电脑 ──(Tailscale 私有网络)──> 服务器:22 (只监听 tailnet 内网 IP)
                                        │
                                        ├─ opsagent 账号（非 root，不在 sudo 组）
                                        │     └─ sudo 只能执行 3 个白名单脚本
                                        │           ├─ ops-status   （只读诊断）
                                        │           ├─ ops-restart  （只重启白名单里的服务）
                                        │           └─ ops-journal  （只看指定服务的日志）
                                        │
                                        └─ sudo 全量 I/O 日志 + auditd 记录
```

AI 能做的：看状态、看日志、重启你允许的服务。
AI 做不到的：`sudo -i`、装软件、改系统配置、读 `/etc/shadow`、横向移动。

---

## 它做了什么

| 你原本要做的 | 脚本做了什么 |
|---|---|
| 配 Tailscale apt 源、装包 | 自动识别 Debian 13（trixie）/ 12（bookworm），用官方源安装 |
| `tailscale up` 点授权 | 支持 authkey 免交互；没有 key 就打印授权链接等你点 |
| 建运维账号、配日志权限 | 创建 `opsagent`（非 root，只加 `adm`/`systemd-journal`） |
| 手工写 sudo 白名单（最容易写出洞的一步） | 装 3 个 root 拥有的包装脚本，sudoers 只放行它们，先校验后原子替换 |
| 防 sudo 逃逸 | 包装脚本内部校验参数格式 + 服务名必须在 `/etc/opsagent/services.allow` 白名单里 |
| 审计 | `sudo` 的 `log_input/log_output` 全量记录 + auditd 记录 `opsagent` 的 execve |
| 把 SSH 收进内网 | 第二阶段 `--lockdown`：sshd 只绑 `100.x` 和 `127.0.0.1`，禁 root/密码登录 |
| 改坏了怎么救 | `--unlock` 恢复 sshd，`uninstall.sh` 完整卸载；全过程有备份 |

---

## 30 秒开始

**前提**：Debian 13（trixie）/ Debian 12 / Ubuntu，systemd，root，能访问外网。
你已经有一个 Tailscale 账号（免费版够用）。

```bash
# 在服务器上（root）
bash <(curl -Ls https://raw.githubusercontent.com/JAX290/tailscale-oneclick-debian/main/scripts/install.sh)
```

脚本会打印一条 `https://login.tailscale.com/...` 链接，**在浏览器打开并授权**即可。
想全程无交互就先生成 auth key（见下）：

```bash
TS_AUTHKEY=tskey-auth-xxxxxxxx bash <(curl -Ls https://raw.githubusercontent.com/JAX290/tailscale-oneclick-debian/main/scripts/install.sh)
```

> 国内网络拉不动 raw.githubusercontent.com 时，可以 `git clone` 后执行本地脚本，逻辑完全一致。

---

## 换服务器的标准流程（三阶段，别跳步）

### 阶段一：安装（安全，不动现有 SSH）

```bash
bash install.sh --hostname web1
```

这一步**不会**碰 sshd，所以你现有的 root 登录方式不受影响，随时可以重跑（幂等）。

### 阶段二：验证

```bash
# 1) 服务器上自检
bash verify.sh

# 2) 你自己的电脑上（装好 Tailscale 并登录同一账号）
tailscale ssh opsagent@web1
sudo ops-status        # 只读诊断，应能看到完整状态
```

**先做这一件**：把 tailnet ACL 收紧，否则默认策略可能允许你的设备以 `root` 登录（详见
[docs/02-首次配置-ACL.md](docs/02-首次配置-ACL.md)）。参考策略：[acl/policy.example.json](acl/policy.example.json)。

### 阶段三：收口（确认第二阶段成功后再做）

```bash
bash install.sh --lockdown
```

把 sshd 从 `0.0.0.0:22` 收到 `100.x:22`，禁用 root 和密码登录。
已有连接不会断，但**下次重连必须走 Tailscale**。改坏了用 `--unlock`，或从云厂商 Web Console 进。

---

## 常用命令

```bash
# 部署后自检（需要 root 才看得全）
sudo bash verify.sh

# 看服务器整体状态（AI 日常最常用）
ssh opsagent@web1 sudo ops-status

# 重启一个服务（先由 root 加进白名单）
echo myapp.service | sudo tee -a /etc/opsagent/services.allow
ssh opsagent@web1 sudo ops-restart myapp.service

# 看某个服务最近 200 行日志
ssh opsagent@web1 sudo ops-journal myapp.service 200

# 撤销 sshd 收口
sudo bash install.sh --unlock

# 完整卸载（默认保留 tailscale 与 tailnet 登录）
sudo bash uninstall.sh
```

---

## 参数

| 参数 | 说明 |
|---|---|
| `--authkey KEY` / `--authkey-file FILE` | 免交互登录；推荐用文件，避免 key 落进 shell 历史 |
| `--hostname NAME` | tailnet 里的设备名（建议每台机器唯一） |
| `--tags TAG[,TAG]` | 设备标签，默认 `tag:server`（ACL 靠它授权） |
| `--no-ssh` | 不在本机开启 Tailscale SSH |
| `--accept-dns` | 允许 Tailscale 接管本机 DNS（默认**不**接管，避免服务器 DNS 依赖 tailnet） |
| `--user NAME` | 运维账号名，默认 `opsagent` |
| `--pubkey KEY` / `--pubkey @FILE` | 给运维账号装 SSH 公钥（传统 sshd 兜底通道） |
| `--no-sudo` / `--no-audit` | 跳过对应的安全组件（不建议） |
| `--lockdown` / `--unlock` | 阶段三收口 / 撤销收口 |
| `--force` | 已登录也重新 `tailscale up` |
| `--dry-run` | 只打印计划，不改系统（可在任意机器上跑） |
| `-y, --yes` | 非交互确认 |

环境变量：`TS_AUTHKEY`、`TS_TAGS`、`SSH_USER`。

---

## 安全边界（请认真看）

**能做的**：只读诊断、看日志、重启白名单内的服务、升级 tailscale 之外的日常观察。

**不能做的**（这是设计目标，不是缺陷）：

- 拿不到 root shell，`sudo -i` / `sudo su` 会被拒绝
- 不能装包、改 `/etc`、改防火墙、改 sshd、动 sudoers
- 不能读 root 私有文件（`/etc/shadow`、私钥等）
- 不能在服务器之间横向移动（每台服务器的 key 独立）

**已知限制**：

1. **sudo 白名单工具本身是特权代码**，改动它等于扩权 —— 所以这些脚本是 `root:root 0755`，`opsagent` 不可写；升级脚本请以 root 手动做。
2. **Tailscale SSH 的权限完全由 tailnet ACL 决定**。默认策略里有一条允许 `root` 的 ssh 规则，**必须删掉**，否则前面所有收口都白做。
3. **本仓库不管理 ACL**。ACL 属于整个 tailnet、只配一次，用 [acl/policy.example.json](acl/policy.example.json) 手动粘贴。
4. **AI 侧的审批闸门**：本机（Windows）上的 AI 每次联网执行命令都要人工批准一次 —— 别关掉这个批准。
5. **日志可能含一次性授权 URL**：`/var/log/tailscale-oneclick.log` 里可能出现 `login.tailscale.com` 链接，属正常，按需轮转。

---

## 目录结构

```
.
├── scripts/
│   ├── install.sh      # 一键安装 / --lockdown / --unlock
│   ├── verify.sh       # 部署后自检（有失败项返回 1）
│   └── uninstall.sh    # 卸载与回滚
├── acl/
│   └── policy.example.json   # tailnet ACL 参考（含 tag 与 ssh 规则）
├── docs/
│   ├── 01-安全模型.md
│   ├── 02-首次配置-ACL.md
│   ├── 03-验证与收口.md
│   ├── 04-本机接入.md
│   ├── 05-回滚与救援.md
│   └── 06-FAQ.md
└── .github/workflows/check.yml   # CI：bash -n + shellcheck + dry-run
```

---

## 回滚

| 想撤销 | 命令 |
|---|---|
| 撤销 sshd 收口 | `sudo bash install.sh --unlock` |
| 保留 Tailscale 只删本脚本的东西 | `sudo bash uninstall.sh` |
| 全删（含 tailscale 包、退出 tailnet） | `sudo bash uninstall.sh --purge-tailscale` |
| 只回滚一半（保留 opsagent） | `sudo bash uninstall.sh --keep-user` |

所有脚本都支持 `--dry-run`，先看计划再动手。**务必保留云厂商 Web Console 入口**。

---

## 更多文档

- [为什么这样设计（威胁模型）](docs/01-安全模型.md)
- [首次配置：tailnet ACL](docs/02-首次配置-ACL.md)
- [验证与收口](docs/03-验证与收口.md)
- [本机（Windows/macOS）接入](docs/04-本机接入.md)
- [回滚与救援](docs/05-回滚与救援.md)
- [FAQ](docs/06-FAQ.md)

---

## 许可

MIT。脚本按"尽力而为"提供，**先在测试机上跑一遍**再上生产。
