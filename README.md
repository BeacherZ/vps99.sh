# VPS 万能开荒脚本 (v9.9 Eternal Guard Edition)

 --- 更新日期：2026-08-08
 
 --- 适用系统：Debian 10+, Ubuntu 20+, Alpine Linux 3.15+
 
 核心功能：
 1. 网络：开启 BBR+FQ 拥塞控制与队列调度，提升网络吞吐并降低延迟。
 2. 内存：部署 zRAM 压缩交换区，提升物理内存承载上限。
 3. 容器：安装/更新/卸载 Docker Engine 与 Compose 插件。
 4. 时区：设置系统时区为 Asia/Shanghai。
 5. 守护：每周自动清理系统缓存、日志与容器垃圾，防止磁盘撑爆。
 6. 清理：立即执行一次系统清理。
 
🚀 一键执行命令

在终端复制并粘贴以下代码，即可自动下载并启动交互菜单：
```
bash <(curl -fsSL https://gd.bzgogo.workers.dev/SH/vps99.sh)
```

```
bash <(curl -fsSL -H "Authorization: token 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" https://raw.githubusercontent.com/BeacherZ/vps99.sh/main/vps99.sh)
```
## 脚本功能模块清单
本脚本采用模块化设计，运行后可自由选择执行以下任务：

[系统环境探测]
- 自动识别 Debian / Ubuntu / Alpine Linux 并显示版本号
- 自动检测 PVE 宿主机环境，清理策略降级保护
- 自动检测各功能模块当前状态（绿色=已就绪，黄色=未配置）

[网络算法 - BBR+FQ]
- 默认 N，需手动确认
- 同时配置 BBR 拥塞控制 + FQ 队列调度
- 使用 sysctl_set 函数安全写入，避免重复追加，兼容配置文件空格格式
- 需重启生效

[内存优化 - zRAM]
- 默认 N，需手动确认
- 内存 <=1GB：zRAM 按 1:1 分配，swappiness=90（激进使用，防 OOM）
- 内存 >1GB：zRAM 按 60% 分配，swappiness=60（适度使用）
- 压缩算法 lz4，优先级 100（高于磁盘 swap）
- 安装时使用 --force-confold 避免 dpkg 配置文件冲突卡住
- 需重启生效

[容器部署 - Docker]
- 默认 N，选 y 进入二级管理菜单
- 自动查询 GitHub API 获取 Docker 和 Compose 最新版本（超时 5 秒）
- 已安装时显示版本对比：已是最新 / 可更新至 x.x.x
- 已是最新：菜单只显示 1) 卸载 2) 跳过
- 有可用更新：菜单显示 1) 更新 2) 卸载 3) 跳过
- 未安装：菜单显示 1) 安装 2) 跳过
- 安装/更新自动跳过 Docker 官方脚本 20 秒等待
- 安装前自动修复 dpkg 锁状态
- 安装后验证并显示实际版本，失败时明确提示
- 卸载包含清理 /var/lib/docker 和 /var/lib/containerd

[系统时区]
- 默认 N，需手动确认
- 检测当前时区，已是 Asia/Shanghai 则提示无需操作
- Alpine 自动安装 tzdata 包

[存储守护 - 定时清理]
- 默认 N，需手动确认
- 部署 /root/vps99clean.sh 定时任务脚本，每周一 06:06 自动执行
- Debian/Ubuntu：修复 dpkg 锁 + apt autoremove/clean/autoclean + journalctl 轮转限大小
- Alpine：清空 /var/log 下文件内容（排除 /var/log/cdt），清理 apk 缓存和临时文件
- Docker：清理所有未使用的镜像、截断容器日志
- PVE 保护：跳过 pkill apt/dpkg，跳过 journalctl --vacuum-time=1s，只限制日志 500M
- 使用 --force-confold 确保 cron 无人值守执行不卡住

[即时清理]
- 默认 Y（唯一默认执行的选项）
- 执行与定时清理相同的清理逻辑
- 显示执行进度提示

## 运维常用管理命令
- 目的                    对应指令
- 检查定时清理计划        crontab -l
- 手动执行清理            /root/vps99clean.sh
- 查看内存压缩状态        zramctl
- 查看 BBR 状态           sysctl net.ipv4.tcp_congestion_control
- 查看 FQ 状态            sysctl net.core.default_qdisc
- 检测是否为 PVE          command -v pveversion
- 查看 Docker 版本        docker -v && docker compose version
- 查看系统时区            cat /etc/timezone

## 关键注意事项

重启生效：选择了 BBR+FQ 或 zRAM 后，脚本会明确提示需要 reboot。
若全部跳过则无需重启。

安全清理：Alpine 系统使用 truncate 清空日志文件内容，保留文件和目录结构，
不会导致 nginx、xray 等服务因找不到日志目录而崩溃。
排除 /var/log/cdt 目录不做任何操作。

PVE 兼容：脚本通过 command -v pveversion 自动检测 PVE 宿主机，
跳过 pkill apt/dpkg 和 journalctl --vacuum-time=1s，
只做安全的缓存清理和日志限大小（500M），不影响宿主机稳定性。

默认保守：除即时清理默认 Y 外，所有功能模块默认 N。
每个选项执行后立即显示绿色结果反馈。

颜色策略：绿色 = 已就绪/操作成功，黄色 = 未配置/未操作/跳过，红色 = 操作失败。

长期守护：部署定时任务后，只要不重装系统，清理脚本持续每周自动运行。
定时任务脚本内部也有 PVE 检测，放到任何机器上都能自动适配。
