# 06 · FAQ

## 部署相关

**Q：auth key 怎么生成？用哪种类型？**

控制台 → Settings → Keys → Generate auth key：

- **Reusable**：不勾。一次性 key 泄露影响面最小；每台服务器生成一个。
- **Ephemeral**：不勾。ephemeral 节点下线后自动从 tailnet 删除，服务器不适合。
- **Pre-approved**：勾上，省去控制台逐台批准。
- **Tags**：填 `tag:server`。**key 带 tag 时，设备才能被 ACL 的 `tag:server` 规则匹配**。
- **Expiry**：设 1 天足够（只用来首次登录），比默认 90 天安全。

带 tag 的 key 例子：

```bash
TS_AUTHKEY=tskey-auth-xxxx bash install.sh --hostname web1
```

**Q：没有 auth key，交互式登录可以吗？**

可以。脚本会打印 `https://login.tailscale.com/...`，浏览器点授权即可。注意链接是一次性的、有时效的，
不要发到聊天/工单里。

**Q：为什么要支持 `--authkey-file`？**

`TS_AUTHKEY=xxx bash install.sh` 会把 key 写进 shell 历史、`ps` 输出、CI 日志。
用文件（`chmod 600`）更稳妥。

**Q：脚本能重复跑吗？**

能，幂等：已安装的跳过，已登录的跳过，已存在的账号/文件不覆盖（sudoers 与 sshd drop-in 是重新写入并校验）。

**Q：支持 Debian 12 / Ubuntu 吗？**

支持。Debian 12 用 `bookworm` 源，Ubuntu 用其 codename。Debian 13（trixie）是主要目标。

**Q：Docker / LXC 里能用吗？**

需要 systemd，且容器要有 `NET_ADMIN` / `/dev/net/tun`。大多数 LXC 默认不行；VPS 上的 KVM 虚机最稳。

## Tailscale 相关

**Q：为什么 `--accept-dns` 默认关闭？**

服务器的 DNS 不应该依赖 tailnet 才能解析。MagicDNS 主要给"从你电脑访问服务器"用，
服务器自己走公网 DNS 更稳。要用远端 DNS（如 Pi-hole）再开。

**Q：key expiry 是什么？服务器会不会某天突然掉线？**

设备节点 key 默认 180 天过期。**服务器请在控制台设备页关掉 key expiry**（Disable key expiry），
否则半年后某天你会发现 SSH 连不上。

**Q：默认策略真的允许 root 走 Tailscale SSH 吗？**

新 tailnet 的默认策略通常包含 `autogroup:member → autogroup:self`、`users` 含 `root` 的 ssh 规则。
**部署后第一件事就是去控制台确认并删掉**，见 [02-首次配置-ACL.md](02-首次配置-ACL.md)。

**Q：`tailscale ssh` 和普通 `ssh` 有什么区别？**

Tailscale SSH 由 `tailscaled` 在 tailnet 接口上接管 22 端口，不经过 sshd、不用 authorized_keys，
权限由 ACL 决定，并且可以配置周期性重新授权（`action: check`）。普通 `ssh` 连 tailnet IP 时，
如果 22 端口被 tailscaled 接管，也会走 Tailscale SSH。

**Q：能不能不用 Tailscale，只用 sshd 绑内网？**

可以，但那就回到"自己管密钥 + 自己管防火墙"的老路。本脚本的 `--lockdown` 依赖 tailnet IP；
如果你有 WireGuard/ZeroTier，把 `ListenAddress` 改成对应网段地址即可，其余逻辑通用。

## 权限与安全

**Q：`NOPASSWD` 是不是很危险？**

单看 `NOPASSWD: ALL` 是灾难。这里 `NOPASSWD` 只作用于三个包装脚本，脚本内部再做参数校验和
服务名白名单，风险面是"脚本能做的事"。每新增一个 `ops-*` 工具，都要按同样的标准审查：
**参数能否逃逸？是否会解释执行输入？**

**Q：怎么让 AI 重启一个服务？**

```bash
# root 手动加白名单（只做一次）
echo myapp.service >> /etc/opsagent/services.allow

# 之后 AI 可以：
ssh opsagent@web1 sudo ops-restart myapp.service
```

不在白名单里的服务会被拒绝，并提示由 root 编辑白名单。

**Q：AI 能不能自己改白名单？**

不能。`/etc/opsagent/services.allow` 是 `root:root 0644`，`opsagent` 不可写；
sudoers 也只放行三个脚本。要加白名单必须 root 手动做。

**Q：审计日志在哪？**

- `sudo` 全量 I/O：`/var/log/sudo-io/`（`log_input, log_output`）
- opsagent 进程执行：`ausearch -k opsagent-exec`
- 安装日志：`/var/log/tailscale-oneclick.log`

**Q：会不会把我锁在门外？**

阶段一不动 sshd，所以不会。阶段三 `--lockdown` 会，但：

- 有 `sshd -t` 校验 + 失败自动回滚
- 有 `--unlock` 一键恢复
- 有 `/etc/tailscale-oneclick/sshd-dropin.bak` 备份
- 还有云厂商 Web Console

**Q：怎么升级这个脚本？**

```bash
cd /root/tailscale-oneclick-debian && git pull
sudo bash install.sh        # 幂等，会把 sudoers/包装脚本更新到最新版
sudo bash verify.sh
```

或者重新 `curl` 一遍最新版。

**Q：要不要给服务器打 `tag:server`？**

要。ACL 的 `dst` 用 `tag:server` 匹配，不打标签 ACL 规则命中不了。
`install.sh` 默认 `--advertise-tags=tag:server`，前提是 auth key 也带这个 tag（或交互登录用户是 tagOwner）。

## 排错

**Q：`tailscale up` 报 "auth key is invalid"？**

key 过期、已被使用（非 reusable）、或 tailnet 不匹配。重新生成一个。

**Q：`sshd -t` 报 "no hostkeys available"？**

机器上没生成 host key：`ssh-keygen -A`。

**Q：脚本输出中文/边框乱码？**

非 UTF-8 终端导致。设置 `LANG=zh_CN.UTF-8`，或 `NO_COLOR=1` 关掉颜色。

**Q：哪里看详细过程？**

`tail -n 200 /var/log/tailscale-oneclick.log`（脚本所有输出都会 tee 到那里）。
