# VPS 万能开荒脚本 v9.9 使用手册

--- 脚本名称：VPS 万能开荒脚本 (v9.9 Eternal Guard Edition)

--- 更新日期：2026-05-08

--- 适用系统：Debian 10+, Ubuntu 20+, Alpine Linux 3.15+

 核心功能：
 1. 网络：开启 TCP-BBR 拥塞控制，提升网络吞吐并降低延迟。
 2. 内存：部署 zRAM 压缩交换区，提升物理内存承载上限。
 3. 容器：一键安装最新版 Docker Engine 与 Compose 插件。
 4. 守护：每周自动清理系统缓存、日志与容器垃圾，防止磁盘撑爆。

🚀 一键执行命令

在终端复制并粘贴以下代码，即可自动下载并启动交互菜单：
```
bash <(curl -fsSL https://gd.bzgogo.workers.dev/SH/vps99.sh)
```

```
bash <(curl -fsSL -H "Authorization: token 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" https://raw.githubusercontent.com/BeacherZ/vps99.sh/main/vps99.sh)
```
## 1. 脚本功能模块清单
本脚本采用模块化设计，运行后可自由选择执行以下任务：

[系统环境探测]
- 全自动识别：Debian / Ubuntu / Alpine Linux
- 自动配置对应的包管理器（apt/apk）
- 自动检测 PVE 宿主机环境，清理策略降级保护

[内核级网络优化]
- 激活 BBR 拥塞控制算法
- 配置 FQ 队列调度，显著提升跨境链路速度

[内存性能优化]
- zRAM 压缩分区：根据内存容量动态计算挂载大小
- 小内存优化：<1G 内存机器采用 1:1 覆盖并提高 Swap 优先级

[生产环境部署]
- 一键安装最新版 Docker Engine
- 一键安装 Docker Compose V2 插件

[存储空间守护]
- 任务时间：每周一 06:06 自动运行
- 清理脚本：/root/vps99clean.sh
- Debian/Ubuntu：清理 apt 缓存、修复 dpkg 锁、轮转并限制 journal 日志
- Alpine：清空日志文件内容（保留目录结构）、清理 apk 缓存和临时文件
- Docker：清理虚悬镜像、截断容器日志
- PVE 保护：跳过杀进程、保留日志历史，只限制日志总大小

[即时清理]
- 脚本运行结束后自动执行一次系统清理，无需手动触发

## 2. 运维常用管理命令
目的                    对应指令
检查定时清理计划        crontab -l
手动立即执行清理        /root/vps99clean.sh
查看内存压缩状态        zramctl
查看网络算法状态        sysctl net.ipv4.tcp_congestion_control
检测是否为 PVE 环境    command -v pveversion

## 3. 关键注意事项

重启生效：若选择了基础优化（BBR、zRAM），脚本跑完后请输入 reboot 重启，
让 BBR 内核模块生效并重新对齐 zRAM 的内存分配。若全部跳过则无需重启。

安全清理：存储守护使用 truncate 方式清空日志文件内容，保留文件和目录结构，
不会导致 nginx、xray 等服务因找不到日志目录而崩溃。

PVE 兼容：脚本自动检测 PVE 宿主机环境，跳过杀进程和清空日志历史等危险操作，
只做安全的缓存清理和日志限大小，不影响宿主机稳定性。

默认保守：所有功能模块默认选择 N（不执行），需手动输入 y 确认才会执行。
即时清理为唯一自动执行项，每次运行脚本都会清理一次系统缓存。

长期守护：部署定时任务后，只要不重装系统，清理脚本会持续每周自动运行。
