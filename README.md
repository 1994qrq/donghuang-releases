# 东皇钟 · Linux 主机安全

[下载当前稳定版](https://github.com/1994qrq/donghuang-releases/releases/latest) · [实测系统和安装占用](COMPATIBILITY.md)

在 Linux 服务器的 SSH 终端安装。安装器识别发行版和 CPU，只下载对应的官方包。服务器不需要 GitHub 账号、Docker、Go 或 Node.js。

```bash
curl -fsSLo donghuang-install.sh https://raw.githubusercontent.com/1994qrq/donghuang-releases/main/install.sh && sudo bash donghuang-install.sh
```

请在自己的主目录运行；在 root 终端可省略 `sudo`。想先检查可用版本，在命令末尾加 `--check`。要指定首次端口，例如加 `--port 28083`。固定本版可用 `--version v0.1.67`。每个发布页也提供固定到 Git commit 的安装命令。安装器内置 P-256 公钥，核验签名后才使用程序包；公钥 SHA-256（DER SPKI）是 `9d6b42d855aa64bcc61d49c34dbe206ecc425472ceb868b6ac7074c9cd373a95`。签名公钥更换时需要重新获取官方入口，离线保存的旧入口不会自行获得吊销信息。

**先看本机能否安装：** 下载最新的 `donghuang-install.sh` 后运行 `bash donghuang-install.sh --doctor`。诊断本身不联网、不安装、不需要 `sudo`；会显示发行版、CPU、正在运行的 systemd 版本、包管理器以及当前能否满足基础依赖。退出码 0 表示基础条件齐全，2 表示平台不兼容，3 表示仍有依赖要补。`--check` 是检查签名发行版本，不代表本机已通过安装预检。

**CentOS Linux 7 不受支持。** 它通常运行 systemd 219，而主服务使用的 `StateDirectory=` 需要 systemd 235 或更新版本。安装 `dnf`、把 `yum` 链接成 `dnf` 或退出 Conda 都不能解决。建议新建 Rocky Linux 9 或 Ubuntu 24.04 主机，在迁移业务时再安装防护；装在另一台机器不能代替对原主机的保护。在受支持的现代 RPM 系统上，只有缺依赖时才需要 `dnf` 或 `yum`；安装器不会添加软件源或替换系统 Python。使用 `yum` 补依赖不代表可以用它执行自动软件包修复。

**第一次登录。** 安装成功会显示版本、回环地址、SSH 转发命令及完整管理密钥。把转发命令复制到**自己的电脑**运行，用平时 SSH 登录的账号和服务器地址，保持窗口打开；然后在自己电脑的浏览器打开输出的 `http://127.0.0.1:端口`。SSH 加密这段连接，不必开放新的公网端口。已在服务器设置 HTTPS 反代的用户也可以继续使用自己的域名。不要把管理密钥放在 URL 里。

登录后先看「总览」的采集状态，再到「资产漏洞 → 资产」确认监听服务。默认监测告警；不配置模型也能进行基础监测。首次资产和漏洞数据会在后台逐步出现。需要额外的系统审计集成时，可在完整发行包里执行 `sudo bash install.sh --enable-journal-audit`，该选项可能重启系统 journald。

**设置 AI。** 打开「AI 助手 → 模型」，添加或编辑当前模型。在「推理等级」可读取服务商声明的选项、手填或探测；选服务商默认就不发送等级。支持 OpenAI Chat、OpenAI Responses 和 Anthropic Messages。探测报告参数是否被接口接受，不据此断言模型一定使用了相应推理能力。

**管理 IP 白名单。** 在「防护 → IP 白名单」添加或移除服务器实际看到的管理来源。名单内的 IP 仍会留下能被传感器识别的探测告警，但东皇钟不会封这个 IP，也不会对它应用入站端口的来源限制和限速。云安全组和应用鉴权各自生效。到「专业视图 → 原始告警 → 查看」可看「发现时处置」。看到「未能定位目标服务」时，请核对日志与监听资产的映射；要核查服务本身的漏洞，请到「资产漏洞 → 漏洞」。

**日常管理。** 在服务器上运行 `sudo donghuang` 可见编号菜单，也可以直接执行：

| 命令 | 用途 |
|---|---|
| `sudo donghuang status` | 运行状态、实际版本、地址和 SSH 命令 |
| `sudo donghuang key` | 在交互终端显示完整管理密钥 |
| `sudo donghuang reset-key` | 生成新密钥并显示；验证旧密钥失效 |
| `sudo donghuang set-key` | 隐藏输入自选密钥（至少 32 个字符），再显示已生效的密钥 |
| `sudo donghuang port 28083` | 先检查占用，再修改并验证端口；失败恢复原配置 |
| `sudo donghuang update` | 下载并安装官方稳定版；同版本健康时不会重启 |

无人值守安装不会把密钥写进安装日志。忘记密钥时登录服务器，运行 `sudo donghuang key` 即可。已有 `DONGHUANG_HOST_TOKEN` 环境覆盖时，查看以运行中服务为准，更换要在原环境配置中完成。改端口或更换密钥会短暂重启主服务；已开启独立观察或正在执行处置时，管理命令会拒绝中断它。若使用反代，改端口还要同步反代的上游和 Host，菜单不会替你改网站配置。

**空间与更新。** 程序与管理命令在 `/usr/local/bin`，助手与版本在 `/usr/local/share/donghuang-host`，配置在 `/etc/donghuang`，主机私有数据在 `/var/lib/donghuang-host`。安装时只下载本机架构并清理临时目录。首次预检至少要求 `/var/tmp` 192 MiB、`/usr/local` 96 MiB、`/var/lib` 64 MiB 可用；升级还要按已有数据大小为备份预留空间。升级保留配置、密钥和处置记录，备份在 `/var/backups/donghuang/releases`。内存限制随主机容量选择，不需要额外的容器守护进程。

从 v0.1.66 的控制台起，打开「版本与更新」，确认后台升级后就可以关闭页面。已有 AI 会话、巡检、扫描和修复会先完成；面板显示等待原因，条件满足后自动备份、安装。排队时可取消，开始备份或结束已授权的观察后不可取消。未勾选提前结束时，会等待连续观察自然结束。预约只适用于确认的版本和安装包，24 小时仍未开始会过期，不会强制安装；结果和备份位置仍在同一面板中。

建议保留默认启用的 `donghuang-update-control.path` 和 `donghuang-update-control.timer`：任务完成时由路径事件唤醒助手，定时器每约 20 秒复查。手动停掉定时器后，连续操作可能错过一次唤醒而继续等待。

同版文件损坏可重跑已下载的安装器并加 `--repair`；不会重新生成管理员密钥。上一次升级的本机回滚入口为 `sudo donghuang-update --rollback`，回滚后仍检查服务状态。它不等于撤销业务系统上的处置。常规卸载：在解压的已验证发行包中执行 `sudo bash uninstall.sh`，默认保留配置和证据。

**回退前先看漏洞历史大小。** 从 v0.1.64 候选起，资源充足时单份漏洞历史可超过 48 MiB。v0.1.63 和更早的读取器不支持这样的历史；回滚会说明原因并保留当前版本。可用 `stat -c '%s 字节' /var/lib/donghuang-host/vulnerabilities/snapshot.json` 查看。需要恢复时，优先选支持当前历史的修正版；如必须回旧版，请先保全现有证据，在隔离环境验证升级前完整备份及业务记录后再安排恢复。不要删除快照凑到旧版上限。

**适用环境。** x86_64 与 ARM64、systemd、nftables、Python ≥ 3.10。面向 Ubuntu 22.04/24.04、Debian 12/13、Alibaba Cloud Linux 3 及可获得相应依赖的 Rocky/Alma/RHEL/Anolis 等系统。能安装与某发行版所有漏洞数据均已覆盖是两件事；实测平台以发布页逐项列出的记录为准。32 位、Alpine/OpenRC 和普通容器不在支持范围。
