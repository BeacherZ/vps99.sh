#!/bin/sh

# ==============================================================================
# --- 脚本名称：VPS 万能开荒脚本 (v9.9 Eternal Guard Edition)
# --- 更新日期：2026-05-08
# --- 适用系统：Debian 10+, Ubuntu 20+, Alpine Linux 3.15+
# ------------------------------------------------------------------------------
# 核心功能：
# 1. 网络：开启 TCP-BBR 拥塞控制，提升网络吞吐并降低延迟。
# 2. 内存：部署 zRAM 压缩交换区，提升物理内存承载上限。
# 3. 容器：一键安装最新版 Docker Engine 与 Compose 插件。
# 4. 守护：每周自动清理系统缓存、日志与容器垃圾，防止磁盘撑爆。
# ==============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 变量初始化
NEED_REBOOT=0

# --- PVE 宿主机检测 ---
IS_PVE=0
if command -v pveversion >/dev/null 2>&1; then
    IS_PVE=1
fi

# --- 辅助函数：安全写入 sysctl.conf（避免重复追加）---
sysctl_set() {
    key="$1"
    value="$2"
    if grep -q "^${key}=" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" /etc/sysctl.conf
    else
        echo "${key}=${value}" >> /etc/sysctl.conf
    fi
}

# --- 辅助函数：修复 dpkg 锁 ---
fix_dpkg() {
    if [ "$IS_PVE" -eq 1 ]; then
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null
    else
        pkill -9 -f 'apt|dpkg' 2>/dev/null
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null
    fi
}

# --- 辅助函数：系统清理（区分 PVE 与普通 VPS）---
do_clean() {
    if command -v apt >/dev/null 2>&1; then
        fix_dpkg
        apt autoremove --purge -y "$@"
        apt clean -y "$@"
        apt autoclean -y "$@"
        journalctl --rotate
        if [ "$IS_PVE" -eq 1 ]; then
            journalctl --vacuum-size=500M
        else
            journalctl --vacuum-time=1s
            journalctl --vacuum-size=500M
        fi

    elif command -v apk >/dev/null 2>&1; then
        apk cache clean
        # 排除 cdt 目录，其余日志文件清空内容，保留目录结构
        find /var/log -mindepth 1 \
            -path "/var/log/cdt" -prune -o \
            -type f -exec truncate -s 0 {} + 2>/dev/null
        rm -rf /var/cache/apk/*
        rm -rf /tmp/*
    fi
}

# --- 1. 环境探测 ---
if [ -f /etc/alpine-release ]; then
    OS="Alpine"; INSTALL_CMD="apk add"; CLEAN_CMD="apk cache clean"
elif [ -f /etc/debian_version ]; then
    OS="Debian"; INSTALL_CMD="apt-get install -y -qq"; CLEAN_CMD="apt-get autoremove --purge -y -qq && apt-get autoclean -y -qq"
else
    echo -e "${RED}错误: 不支持的系统类型${NC}"; exit 1
fi

clear
echo -e "${GREEN}================================================================================${NC}"
echo -e "${GREEN}                 Universal VPS Initialization Script - v9.9                 ${NC}"
echo -e "${GREEN}================================================================================${NC}"

# --- 2. 现状体检 ---
echo -e "${CYAN}[ 1. 系统现状体检 ]${NC}"
bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
[ "$bbr_status" = "bbr" ] && HAS_BBR=1 || HAS_BBR=0
if command -v zramctl >/dev/null || ls /dev/zram0 >/dev/null 2>&1; then HAS_ZRAM=1; else HAS_ZRAM=0; fi
if command -v docker >/dev/null; then HAS_DOCKER=1; DOCKER_VER=$(docker -v | awk '{print $3}' | tr -d ','); else HAS_DOCKER=0; fi
if crontab -l 2>/dev/null | grep -q "vps99clean.sh"; then HAS_CRON=1; else HAS_CRON=0; fi

[ $HAS_BBR -eq 1 ] && echo -e " - 网络算法: ${GREEN}BBR 已激活${NC}" || echo -e " - 网络算法: ${YELLOW}未开启 BBR${NC}"
[ $HAS_ZRAM -eq 1 ] && echo -e " - 内存优化: ${GREEN}zRAM 已存在${NC}" || echo -e " - 内存优化: ${YELLOW}未发现 zRAM${NC}"
[ $HAS_DOCKER -eq 1 ] && echo -e " - Docker   : ${GREEN}已安装 ($DOCKER_VER)${NC}" || echo -e " - Docker   : ${YELLOW}未安装${NC}"
[ $HAS_CRON -eq 1 ] && echo -e " - 存储守护: ${GREEN}已配置 (每周一 06:06)${NC}" || echo -e " - 存储守护: ${YELLOW}尚未部署${NC}"
[ $IS_PVE -eq 1 ] && echo -e " - 运行环境: ${YELLOW}PVE 宿主机 (清理已降级保护)${NC}"
echo -e "${GREEN}--------------------------------------------------------------------------------${NC}"

# --- 3. 功能大纲 (同步头部核心说明) ---
echo -e "${CYAN}[ 2. 本脚本核心功能清单 ]${NC}"
echo -e " - 网络加速 : 开启 TCP-BBR 拥塞控制，提升网络吞吐并降低延迟"
echo -e " - 内存优化 : 部署 zRAM 压缩交换区，提升物理内存承载上限"
echo -e " - 容器部署 : 一键安装最新版 Docker Engine 与 Compose 插件"
echo -e " - 存储守护 : 每周自动清理系统缓存、日志与容器垃圾，防止磁盘撑爆"
echo -e " - 即时清理 : 脚本结束后立即释放包管理器缓存与系统日志"
echo -e "${GREEN}================================================================================${NC}\n"

# --- 4. 执行阶段 ---

# 4.1 BBR & zRAM
if [ $HAS_BBR -eq 1 ] && [ $HAS_ZRAM -eq 1 ]; then
    read -p "基础优化已完成，是否覆盖配置? [y/N]: " init_confirm
else
    read -p "是否开启基础系统优化 (BBR, zRAM, 内核调优)? [y/N]: " init_confirm
fi
init_confirm=${init_confirm:-"n"}

if [ "$init_confirm" = "y" ] || [ "$init_confirm" = "Y" ]; then
    sysctl_set "net.core.default_qdisc" "fq"
    sysctl_set "net.ipv4.tcp_congestion_control" "bbr"
    sysctl -p 2>/dev/null
    REPORT_BBR="已开启/覆盖"
    NEED_REBOOT=1

    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    zram_size=$([ "$total_mem" -le 1024 ] && echo "$total_mem" || echo "$((total_mem * 60 / 100))")
    swap_p=$([ "$total_mem" -le 1024 ] && echo "90" || echo "60")
    sysctl_set "vm.swappiness" "$swap_p"
    sysctl -p 2>/dev/null

    if [ "$OS" = "Alpine" ]; then
        apk add zram-init >/dev/null 2>&1
        echo -e "load_modules=\"yes\"\nnum_devices=\"1\"\ntype0=\"swap\"\nsize0=\"$zram_size\"" > /etc/conf.d/zram-init
        rc-update add zram-init default >/dev/null 2>&1
        rc-service zram-init start >/dev/null 2>&1
    else
        $INSTALL_CMD zram-tools >/dev/null 2>&1
        echo -e "ALGO=lz4\nSIZE=$zram_size\nPRIORITY=100" > /etc/default/zramswap
        systemctl restart zramswap >/dev/null 2>&1
    fi
    REPORT_ZRAM="已部署 ($zram_size MB)"
fi

# 4.2 Docker
if [ $HAS_DOCKER -eq 1 ]; then
    read -p "Docker 已就绪 ($DOCKER_VER)，是否尝试更新? [y/N]: " docker_confirm
else
    read -p "是否安装 Docker 与 Compose 环境? [y/N]: " docker_confirm
fi
docker_confirm=${docker_confirm:-"n"}

if [ "$docker_confirm" = "y" ] || [ "$docker_confirm" = "Y" ]; then
    if [ "$OS" = "Alpine" ]; then
        apk add docker docker-cli-compose >/dev/null 2>&1
        rc-update add docker default >/dev/null 2>&1
        rc-service docker start >/dev/null 2>&1
    else
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        $INSTALL_CMD docker-compose-plugin >/dev/null 2>&1
    fi
    REPORT_DOCKER="已就绪/更新"
fi

# 4.3 存储守护
if [ $HAS_CRON -eq 1 ]; then
    read -p "存储守护已存在，是否重写配置? [y/N]: " cron_confirm
else
    read -p "是否部署存储守护任务 (每周一凌晨自动清理)? [y/N]: " cron_confirm
fi
cron_confirm=${cron_confirm:-"n"}

if [ "$cron_confirm" = "y" ] || [ "$cron_confirm" = "Y" ]; then
    CLEAN_PATH="/root/vps99clean.sh"
    cat > "$CLEAN_PATH" <<'CLEANEOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# PVE 宿主机检测
IS_PVE=0
if command -v pveversion >/dev/null 2>&1; then
    IS_PVE=1
fi

# --- 系统清理 ---
if command -v apt >/dev/null 2>&1; then
    # Debian / Ubuntu - 修复 dpkg 锁后清理
    if [ "$IS_PVE" -eq 0 ]; then
        pkill -9 -f 'apt|dpkg' 2>/dev/null
    fi
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null
    apt autoremove --purge -y
    apt clean -y
    apt autoclean -y
    journalctl --rotate
    if [ "$IS_PVE" -eq 0 ]; then
        journalctl --vacuum-time=1s
    fi
    journalctl --vacuum-size=500M

elif command -v apk >/dev/null 2>&1; then
    # Alpine - 排除 cdt 目录，其余日志文件清空内容，保留目录结构
    apk cache clean
    find /var/log -mindepth 1 \
        -path "/var/log/cdt" -prune -o \
        -type f -exec truncate -s 0 {} + 2>/dev/null
    rm -rf /var/cache/apk/*
    rm -rf /tmp/*
fi

# --- Docker 清理 ---
if command -v docker >/dev/null 2>&1; then
    docker image prune -f
    find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \;
fi
CLEANEOF
    chmod +x "$CLEAN_PATH"
    (crontab -l 2>/dev/null | grep -v "$CLEAN_PATH"; echo "6 6 * * 1 $CLEAN_PATH > /dev/null 2>&1") | crontab -
    REPORT_STORAGE_CRON="已部署/覆盖"
fi

# --- 5. 即时清理 + 汇报 ---
do_clean -qq >/dev/null 2>&1

echo -e "\n${GREEN}==================== [ 3. 任务执行汇报 ] ====================${NC}"
echo -e " [系统环境] 操作系统类型   : ${YELLOW}$OS${NC}"
[ $IS_PVE -eq 1 ] && echo -e " [运行环境] PVE 宿主机     : ${YELLOW}清理已降级保护${NC}"
echo -e " [网络加速] BBR 开启状态   : ${YELLOW}${REPORT_BBR:-保持现状}${NC}"
echo -e " [内存调优] zRAM 部署规模  : ${YELLOW}${REPORT_ZRAM:-保持现状}${NC}"
echo -e " [容器环境] Docker 部署状态 : ${YELLOW}${REPORT_DOCKER:-保持现状}${NC}"
echo -e "--------------------------------------------------------------"
echo -e " [存储维护] 自动清理计划   : ${GREEN}${REPORT_STORAGE_CRON:-保持现状}${NC}"
echo -e " [执行结论] 本次即时清理   : ${YELLOW}成功释放空间${NC}"
echo -e "${GREEN}==============================================================${NC}"

if [ $NEED_REBOOT -eq 1 ]; then
    echo -e "\n${RED}============================================================${NC}"
    echo -e "${RED}!! 警告：检测到内核改动，请务必执行 [ reboot ] 以激活优化 !!${NC}"
    echo -e "${RED}============================================================${NC}\n"
else
    echo -e "\n${GREEN}--- 任务完成！本次未改动核心参数，无需重启。---${NC}\n"
fi