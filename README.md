# KopiaCtl

`KopiaCtl` 是 Debian/Ubuntu 服务器上的交互式 Kopia 管理工具。它支持原生安装和 Docker 部署，默认偏向资源较紧张服务器适用的原生模式；Cloudflare R2 是仓库配置菜单中的默认存储方案。Web UI 默认不启用。

## 能力

| 能力 | 说明 |
| --- | --- |
| 两种部署方式 | 可选择原生 Kopia 或 Docker 容器。切换时保留同一份 Kopia 仓库配置。 |
| Cloudflare R2 | 引导连接已有仓库，或在空 R2 Bucket 中创建新仓库。R2 密钥由 Kopia 的仓库配置保存，不写入 KopiaCtl 菜单配置。 |
| 快照与恢复 | 交互式创建快照、列出快照并恢复指定快照。Docker 模式会临时只读挂载备份路径。 |
| Web UI | 默认关闭；可单独启用、启动、停止并设置登录凭据。原生模式使用 systemd，Docker 模式使用 Compose profile。 |
| 日常维护 | 查看状态、仓库状态和日志，备份本地配置，更新或卸载管理器。 |

## 支持环境

| 项目 | 要求 |
| --- | --- |
| 系统 | 使用 systemd 的 Debian 或 Ubuntu（自动安装基于 apt）。 |
| 权限 | root，或具有 sudo 权限的交互式 SSH 终端。 |
| R2 | 一个已创建的 Bucket，以及具备该 Bucket 读写权限的 R2 Access Key。 |
| Docker 模式 | Docker Engine 与 Docker Compose v2；KopiaCtl 可协助从系统软件源安装。 |

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/xhpx7301/KopiaCtl/main/install.sh | bash
```

也可在源码目录运行：

```bash
chmod +x install.sh
./install.sh
```

安装器只写入 `kopiactl` 菜单入口。Kopia 或 Docker 会在你从菜单确认后安装。

## 使用方式

运行：

```bash
kopiactl
```

建议的首次操作顺序：选择安装方式（小型服务器选原生安装）→ 配置 Cloudflare R2 仓库 → 创建首个快照。Web UI 仅在确有浏览器管理需求时从菜单启用。

R2 配置时输入 Cloudflare Account ID、Bucket、Access Key ID 和 Secret Access Key。KopiaCtl 自动使用 `<Account ID>.r2.cloudflarestorage.com` 作为 S3 endpoint，使用 `region=auto`。连接已有仓库时还需要输入该 Kopia 仓库的加密密码；它不是 R2 Secret Access Key。创建新仓库时，菜单会要求设置并确认这个密码。

## 文件位置

| 内容 | 位置 |
| --- | --- |
| KopiaCtl 设置、Kopia 仓库配置与缓存 | `/opt/kopiactl/` |
| Docker Compose 配置 | `/opt/kopiactl/compose.yml` |
| 原生 Web UI systemd 服务 | `/etc/systemd/system/kopia-web-ui.service` |
| KopiaCtl 本地配置备份 | `/var/backups/kopiactl/` |
| 管理脚本 | `/usr/local/lib/kopiactl/kopiactl.sh` |
| 菜单命令 | `/usr/local/bin/kopiactl` |

本地 `repository.config` 是连接远端仓库所必需的敏感文件。应将 `/opt/kopiactl/` 纳入另一套服务器备份，但不要把它公开上传。完全卸载只清理本机数据，不会删除 R2 中的任何快照或对象。

## Web UI 安全

Web UI 默认关闭。启用后会监听 `0.0.0.0:51515`（可在菜单修改），使用你设置的用户名和密码登录。`--insecure` 表示 Kopia 本身不提供 HTTPS；请仅通过内网、VPN、防火墙白名单访问，或放在反向代理的 HTTPS 与额外认证之后。不要直接向公网开放该端口。

## 注意事项

- 小内存和小系统盘的服务器优先选原生安装，避免 Docker daemon、镜像与日志的额外占用。
- R2 Bucket 中已有 Kopia 仓库时选“连接已有仓库”；仅对空 Bucket 使用“创建新仓库”。
- Docker 模式创建快照时，KopiaCtl 只会将你输入的备份路径以只读方式挂入临时容器。
- 配置、缓存或 R2 仓库数据都不能替代定期验证恢复。首次部署后应恢复一个测试文件确认可用性。
