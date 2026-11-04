# 02 · 首次配置：tailnet ACL（最重要的一步）

> 这一步**只做一次**，属于整个 tailnet，不属于某台服务器。
> 不做这一步，前面所有"收口"都可能被默认策略绕过。

## 为什么必须做

Tailscale 新建 tailnet 的默认策略里，通常包含一条类似这样的规则：

```jsonc
"ssh": [
  {
    "action": "accept",
    "src": ["autogroup:member"],
    "dst": ["autogroup:self"],
    "users": ["autogroup:nonroot", "root"]   // ← 注意 root
  }
]
```

`autogroup:self` 表示"同一账号名下的设备"。也就是说：**你笔记本上登录 Tailscale 的账号，可以直接以
`root` 通过 Tailscale SSH 登录这台服务器**，绕开 sshd 的全部限制。

这不是漏洞，是便利的默认值。但对"AI 只能以 opsagent 身份干活"这个目标来说，必须改掉。

## 操作步骤

### 1. 打开 Access Controls

`https://login.tailscale.com/admin/acls`（或控制台 → Access controls → Edit policy file）

### 2. 先看 `ssh` 段

把 `users` 里带 `"root"` 的规则删掉或改写。**改完不要急着保存，先看第 3 步的完整模板**。

### 3. 粘贴本仓库的参考策略

完整文件：[`acl/policy.example.json`](../acl/policy.example.json)

```json
{
  "tagOwners": {
    "tag:server": ["autogroup:admin"],
    "tag:agent": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["tag:agent"], "dst": ["tag:server:22"] }
  ],
  "ssh": [
    {
      "action": "check",
      "src": ["tag:agent"],
      "dst": ["tag:server"],
      "users": ["opsagent"],
      "checkPeriod": "12h"
    }
  ]
}
```

逐条解释：

| 字段 | 作用 |
|---|---|
| `tagOwners` | 谁有资格给设备打这两个标签（管理员） |
| `acls` 第一条 | 只有 `tag:agent` 的设备能访问 `tag:server` 的 **22 端口**，其他端口一律不通 |
| `ssh` 规则 | 只有 `tag:agent` 能通过 Tailscale SSH 登录 `tag:server`，且**只能登录 `opsagent`** |
| `"action": "check"` | 每 12 小时强制重新走一次浏览器授权（人肉闸门，会话级授权） |
| `checkPeriod` | 配合 `check` 使用；想更严就调小（如 `1h`），想更省事就用 `accept` |

如果不想每 12 小时点一次，把 `"action": "check"` 改成 `"accept"` 并删掉 `checkPeriod`。

### 4. 给设备打标签

**服务器**：`install.sh` 默认已经带 `--advertise-tags=tag:server`。
**你的电脑（agent 端）**：需要打成 `tag:agent`，否则上面 `acls`/`ssh` 的 `src` 匹配不到。

Windows / macOS / Linux 都执行：

```bash
tailscale up --advertise-tags=tag:agent --reset
```

或者控制台 → Machines → 选中设备 → Edit tags → 加 `tag:agent`。

> 打标签后设备属于 tailnet 而不是某个用户，**不会因为账号变动掉线**；
> 同时该设备也不再继承"用户自己的设备"那套默认权限，权限完全由 ACL 决定（这正是我们要的）。

### 5. 保存并验证

保存后立刻验证，**不要等下次需要登录时才发现配错**：

```bash
# ① 应该成功：以 opsagent 登录
tailscale ssh opsagent@web1

# ② 应该被拒绝：从 agent 端以 root 登录
tailscale ssh root@web1
# 预期：Permission denied / 被 ACL 拒绝

# ③ 应该不通：从 agent 端访问服务器 80 端口
curl -m 3 http://web1
# 预期：超时（acls 只放行 22）
```

三条都符合预期，ACL 才算配好。

## 常见坑

| 现象 | 原因 |
|---|---|
| `tailscale ssh` 报 "no matching rule" | 设备没打 `tag:agent`，或 `src` 写成了 `autogroup:member` |
| 能登录但提示 unknown user | ACL 的 `users` 里写了服务器上不存在的账号 |
| 改了 ACL 后所有设备都连不上 | 删掉了默认的全通规则，但没加新的；控制台有 "Revert" 按钮 |
| `tagOwners` 报错 | 打标签的人不在 `tagOwners` 列表里；`autogroup:admin` 指管理员 |
| 生效有延迟 | 通常 < 1 分钟；`tailscale status` 刷新一下 netmap |

## 回滚

ACL 页面有历史版本和 **Revert**；也可以把改前的 JSON 存一份在本地。
本仓库不自动改 ACL，就是为了避免"脚本把所有人锁在门外"这种事。
