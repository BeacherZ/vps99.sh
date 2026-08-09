#!/bin/sh

# ==============================================================================
# --- 脚本名称：VPS 万能开荒脚本 (v9.9 Eternal Guard Edition)
# --- 更新日期：2026-08-08
# --- 适用系统：Debian 10+, Ubuntu 20+, Alpine Linux 3.15+
# ------------------------------------------------------------------------------
# 核心功能：
# 1. 网络：开启 BBR+FQ 拥塞控制与队列调度，提升网络吞吐并降低延迟。
# 2. 内存：部署 zRAM 压缩交换区，提升物理内存承载上限。
# 3. 容器：安装/更新/卸载 Docker Engine 与 Compose 插件。
# 4. 时区：设置系统时区为 Asia/Shanghai。
# 5. 守护：每周自动清理系统缓存、日志与容器垃圾，防止磁盘撑爆。
# 6. 清理：立即执行一次系统清理。
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NEED_REBOOT=0

IS_PVE=0
if command -v pveversion >/dev/null 2>&1; then
    IS_PVE=1
fi

sysctl_set() {
    key="$1"
    value="$2"
    if grep -q "^${key}\s*=" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^${key}\s*=.*|${key}=${value}|" /etc/sysctl.conf
    else
        echo "${key}=${value}" >> /etc/sysctl.conf
    fi
}

fix_dpkg() {
    if [ "$IS_PVE" -eq 1 ]; then
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold 2>/dev/null
    else
        pkill -9 -f 'apt|dpkg' 2>/dev/null
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold 2>/dev/null
    fi
}

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
        find /var/log -mindepth 1 \
            -path "/var/log/cdt" -prune -o \
            -type f -exec truncate -s 0 {} + 2>/dev/null
        rm -rf /var/cache/apk/*
        rm -rf /tmp/*
    fi
}

remove_docker() {
    if [ "$OS" = "Alpine" ]; then
        rc-service docker stop 2>/dev/null
        rc-update del docker default 2>/dev/null
        apk del docker docker-cli-compose 2>/dev/null
    else
        systemctl stop docker 2>/dev/null
        apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin 2>/dev/null
        apt-get autoremove -y 2>/dev/null
        rm -rf /var/lib/docker /var/lib/containerd
    fi
}

check_docker_latest() {
    LATEST_DOCKER=$(curl -s --connect-timeout 3 --max-time 5 "https://api.github.com/repos/moby/moby/releases/latest" 2>/dev/null | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    LATEST_COMPOSE=$(curl -s --connect-timeout 3 --max-time 5 "https://api.github.com/repos/docker/compose/releases/latest" 2>/dev/null | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
}

if [ -f /etc/alpine-release ]; then
    OS="Alpine"
    OS_VER=$(cat /etc/alpine-release)
    INSTALL_CMD="apk add"
elif [ -f /etc/debian_version ]; then
    OS="Debian"
    OS_VER=$(cat /etc/debian_version)
    INSTALL_CMD="apt-get install -y -qq"
else
    printf "${RED}错误: 不支持的系统类型${NC}\n"
    exit 1
fi

clear
printf "${GREEN}================================================================================${NC}\n"
printf "${GREEN}                 Universal VPS Initialization Script - v9.9                 ${NC}\n"
printf "${GREEN}================================================================================${NC}\n"

printf "${CYAN}[ 1. 系统现状体检 ]${NC}\n"
printf " - 系统环境 : ${OS} ${OS_VER}\n"

bbr_status=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "")
fq_status=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "")

if [ "$bbr_status" = "bbr" ]; then
    HAS_BBR=1
    if [ "$fq_status" = "fq" ]; then
        BBR_LABEL="BBR+FQ 已激活"
    elif [ -z "$fq_status" ]; then
        BBR_LABEL="BBR 已激活 (FQ 继承宿主机)"
    else
        BBR_LABEL="BBR 已激活 (FQ: ${fq_status})"
    fi
else
    HAS_BBR=0
    BBR_LABEL="未开启"
fi

if command -v zramctl >/dev/null || ls /dev/zram0 >/dev/null 2>&1; then
    HAS_ZRAM=1
else
    HAS_ZRAM=0
fi

if command -v docker >/dev/null 2>&1; then
    HAS_DOCKER=1
    DOCKER_VER=$(docker -v | awk '{print $3}' | tr -d ',')
    COMPOSE_VER=$(docker compose version 2>/dev/null | awk '{print $NF}' | tr -d 'v')
else
    HAS_DOCKER=0
fi

CUR_TZ=$(cat /etc/timezone 2>/dev/null)
if [ -z "$CUR_TZ" ]; then
    CUR_TZ=$(timedatectl show -p Timezone --value 2>/dev/null)
fi
if [ -z "$CUR_TZ" ]; then
    CUR_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
fi
if [ -z "$CUR_TZ" ]; then
    CUR_TZ="未知"
fi

if crontab -l 2>/dev/null | grep -q "vps99clean.sh"; then
    HAS_CRON=1
else
    HAS_CRON=0
fi

[ $HAS_BBR -eq 1 ] && printf " - 网络算法 : ${GREEN}${BBR_LABEL}${NC}\n" || printf " - 网络算法 : ${YELLOW}未开启${NC}\n"
[ $HAS_ZRAM -eq 1 ] && printf " - 内存优化 : ${GREEN}zRAM 已存在${NC}\n" || printf " - 内存优化 : ${YELLOW}未部署${NC}\n"
if [ $HAS_DOCKER -eq 1 ]; then
    printf " - 容器部署 : ${GREEN}Docker ${DOCKER_VER} / Compose ${COMPOSE_VER}${NC}\n"
else
    printf " - 容器部署 : ${YELLOW}未安装${NC}\n"
fi
[ "$CUR_TZ" = "Asia/Shanghai" ] && printf " - 系统时区 : ${GREEN}Asia/Shanghai${NC}\n" || printf " - 系统时区 : ${YELLOW}${CUR_TZ}${NC}\n"
[ $HAS_CRON -eq 1 ] && printf " - 存储守护 : ${GREEN}已配置 (每周一 06:06)${NC}\n" || printf " - 存储守护 : ${YELLOW}未部署${NC}\n"
[ $IS_PVE -eq 1 ] && printf " - 运行环境 : ${YELLOW}PVE 宿主机 (清理已降级保护)${NC}\n"
printf "${GREEN}--------------------------------------------------------------------------------${NC}\n"

printf "${CYAN}[ 2. 本脚本核心功能清单 ]${NC}\n"
printf " - 网络算法 : 开启 BBR+FQ 拥塞控制与队列调度，提升网络吞吐并降低延迟\n"
printf " - 内存优化 : 部署 zRAM 压缩交换区，提升物理内存承载上限\n"
printf " - 容器部署 : 安装/更新/卸载 Docker Engine 与 Compose 插件\n"
printf " - 系统时区 : 设置系统时区为 Asia/Shanghai\n"
printf " - 存储守护 : 每周自动清理系统缓存、日志与容器垃圾，防止磁盘撑爆\n"
printf " - 即时清理 : 立即执行一次系统清理\n"
printf "${GREEN}================================================================================${NC}\n\n"

# 4.1 BBR+FQ
if [ $HAS_BBR -eq 1 ]; then
    read -p "网络算法 : ${BBR_LABEL}，是否覆盖配置? [y/N]: " bbr_confirm
else
    read -p "网络算法 : 是否开启 BBR+FQ? [y/N]: " bbr_confirm
fi
bbr_confirm=${bbr_confirm:-"n"}

if [ "$bbr_confirm" = "y" ] || [ "$bbr_confirm" = "Y" ]; then
    sysctl_set "net.core.default_qdisc" "fq"
    sysctl_set "net.ipv4.tcp_congestion_control" "bbr"
    sysctl -p >/dev/null 2>&1
    printf "  ${GREEN}> BBR+FQ 已配置，重启后生效${NC}\n"
    REPORT_BBR="${GREEN}BBR+FQ 已开启${NC}"
    NEED_REBOOT=1
fi

# 4.2 zRAM
if [ $HAS_ZRAM -eq 1 ]; then
    read -p "内存优化 : zRAM 已存在，是否覆盖配置? [y/N]: " zram_confirm
else
    read -p "内存优化 : 是否部署 zRAM? [y/N]: " zram_confirm
fi
zram_confirm=${zram_confirm:-"n"}

if [ "$zram_confirm" = "y" ] || [ "$zram_confirm" = "Y" ]; then
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    zram_size=$([ "$total_mem" -le 1024 ] && echo "$total_mem" || echo "$((total_mem * 60 / 100))")
    swap_p=$([ "$total_mem" -le 1024 ] && echo "90" || echo "60")
    sysctl_set "vm.swappiness" "$swap_p"
    sysctl -p >/dev/null 2>&1

    if [ "$OS" = "Alpine" ]; then
        apk add zram-init >/dev/null 2>&1
        printf "load_modules=\"yes\"\nnum_devices=\"1\"\ntype0=\"swap\"\nsize0=\"%s\"\n" "$zram_size" > /etc/conf.d/zram-init
        rc-update add zram-init default >/dev/null 2>&1
        rc-service zram-init start >/dev/null 2>&1
    else
        DEBIAN_FRONTEND=noninteractive $INSTALL_CMD -o Dpkg::Options::="--force-confold" zram-tools >/dev/null 2>&1
        printf "ALGO=lz4\nSIZE=%s\nPRIORITY=100\n" "$zram_size" > /etc/default/zramswap
        systemctl restart zramswap >/dev/null 2>&1
    fi
    printf "  ${GREEN}> zRAM 已部署 (${zram_size}MB / swappiness=${swap_p})${NC}\n"
    REPORT_ZRAM="${GREEN}已部署 (${zram_size}MB)${NC}"
    NEED_REBOOT=1
fi

# 4.3 Docker
if [ $HAS_DOCKER -eq 1 ]; then
    printf "容器部署 : 正在查询最新版本...\r"
    check_docker_latest

    if [ -n "$LATEST_DOCKER" ]; then
        if [ "$DOCKER_VER" = "$LATEST_DOCKER" ]; then
            DOCKER_STATUS="${GREEN}已是最新${NC}"
        else
            DOCKER_STATUS="${YELLOW}可更新至 ${LATEST_DOCKER}${NC}"
        fi
    else
        DOCKER_STATUS="${YELLOW}查询失败${NC}"
    fi

    if [ -n "$LATEST_COMPOSE" ]; then
        if [ "$COMPOSE_VER" = "$LATEST_COMPOSE" ]; then
            COMPOSE_STATUS="${GREEN}已是最新${NC}"
        else
            COMPOSE_STATUS="${YELLOW}可更新至 ${LATEST_COMPOSE}${NC}"
        fi
    else
        COMPOSE_STATUS="${YELLOW}查询失败${NC}"
    fi

    printf "容器部署 : Docker ${DOCKER_VER} (${DOCKER_STATUS}) / Compose ${COMPOSE_VER} (${COMPOSE_STATUS})\n"
    read -p "           是否管理? [y/N]: " docker_enter
else
    read -p "容器部署 : 未安装，是否管理? [y/N]: " docker_enter
fi
docker_enter=${docker_enter:-"n"}

if [ "$docker_enter" = "y" ] || [ "$docker_enter" = "Y" ]; then
    if [ $HAS_DOCKER -eq 1 ]; then
        NEED_UPDATE=0
        if [ -n "$LATEST_DOCKER" ] && [ "$DOCKER_VER" != "$LATEST_DOCKER" ]; then
            NEED_UPDATE=1
        fi
        if [ -n "$LATEST_COMPOSE" ] && [ "$COMPOSE_VER" != "$LATEST_COMPOSE" ]; then
            NEED_UPDATE=1
        fi

        if [ $NEED_UPDATE -eq 1 ]; then
            printf "           1) 更新  2) 卸载  3) 跳过\n"
            read -p "           请选择 [3]: " docker_choice
            docker_choice=${docker_choice:-"3"}
        else
            printf "           1) 卸载  2) 跳过\n"
            read -p "           请选择 [2]: " docker_choice
            docker_choice=${docker_choice:-"2"}
            case "$docker_choice" in
                1) docker_choice="2" ;;
                *) docker_choice="3" ;;
            esac
        fi
    else
        printf "           1) 安装  2) 跳过\n"
        read -p "           请选择 [2]: " docker_choice
        docker_choice=${docker_choice:-"2"}
    fi

    case "$docker_choice" in
        1)
            printf "  正在安装/更新 Docker，请稍候...\n"
            if [ "$OS" = "Debian" ]; then
                fix_dpkg
            fi
            if [ "$OS" = "Alpine" ]; then
                apk add docker docker-cli-compose
                rc-update add docker default
                rc-service docker start
            else
                curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
                sed -i 's/sleep 20/sleep 0/' /tmp/get-docker.sh
                sh /tmp/get-docker.sh
                rm -f /tmp/get-docker.sh
                DEBIAN_FRONTEND=noninteractive $INSTALL_CMD -o Dpkg::Options::="--force-confold" docker-compose-plugin
            fi

            if command -v docker >/dev/null 2>&1; then
                NEW_DOCKER_VER=$(docker -v | awk '{print $3}' | tr -d ',')
                NEW_COMPOSE_VER=$(docker compose version 2>/dev/null | awk '{print $NF}' | tr -d 'v')
                printf "  ${GREEN}> Docker ${NEW_DOCKER_VER} / Compose ${NEW_COMPOSE_VER} 就绪${NC}\n"
                REPORT_DOCKER="${GREEN}Docker ${NEW_DOCKER_VER} / Compose ${NEW_COMPOSE_VER}${NC}"
            else
                printf "  ${RED}> 安装失败，请检查网络${NC}\n"
                REPORT_DOCKER="${RED}安装失败${NC}"
            fi
            ;;
        2)
            if [ $HAS_DOCKER -eq 1 ]; then
                printf "  正在卸载 Docker...\n"
                remove_docker
                hash -r 2>/dev/null
                if ! command -v docker >/dev/null 2>&1; then
                    printf "  ${GREEN}> Docker 已卸载${NC}\n"
                    REPORT_DOCKER="${GREEN}已卸载${NC}"
                else
                    printf "  ${RED}> 卸载失败${NC}\n"
                    REPORT_DOCKER="${RED}卸载失败${NC}"
                fi
            fi
            ;;
        *)
            ;;
    esac
fi

if [ -z "$REPORT_DOCKER" ] && [ $HAS_DOCKER -eq 1 ]; then
    REPORT_DOCKER="${YELLOW}Docker ${DOCKER_VER} / Compose ${COMPOSE_VER}${NC}"
fi

# 4.4 时区设置
if [ "$CUR_TZ" = "Asia/Shanghai" ]; then
    read -p "系统时区 : 已是 Asia/Shanghai，是否重新设置? [y/N]: " tz_confirm
else
    read -p "系统时区 : 是否设置为 Asia/Shanghai? [y/N]: " tz_confirm
fi
tz_confirm=${tz_confirm:-"n"}

if [ "$tz_confirm" = "y" ] || [ "$tz_confirm" = "Y" ]; then
    if [ "$OS" = "Alpine" ]; then
        apk add tzdata >/dev/null 2>&1
        cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
    else
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
    fi
    printf "  ${GREEN}> 时区已设置为 Asia/Shanghai${NC}\n"
    REPORT_TZ="${GREEN}Asia/Shanghai${NC}"
fi

# 4.5 存储守护
if [ $HAS_CRON -eq 1 ]; then
    read -p "存储守护 : 已存在，是否重写配置? [y/N]: " cron_confirm
else
    read -p "存储守护 : 是否部署定时清理 (每周一 06:06)? [y/N]: " cron_confirm
fi
cron_confirm=${cron_confirm:-"n"}

if [ "$cron_confirm" = "y" ] || [ "$cron_confirm" = "Y" ]; then
    CLEAN_PATH="/root/vps99clean.sh"
    cat > "$CLEAN_PATH" <<'CLEANEOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

IS_PVE=0
if command -v pveversion >/dev/null 2>&1; then
    IS_PVE=1
fi

if command -v apt >/dev/null 2>&1; then
    if [ "$IS_PVE" -eq 0 ]; then
        pkill -9 -f 'apt|dpkg' 2>/dev/null
    fi
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold 2>/dev/null
    apt autoremove --purge -y
    apt clean -y
    apt autoclean -y
    journalctl --rotate
    if [ "$IS_PVE" -eq 0 ]; then
        journalctl --vacuum-time=1s
    fi
    journalctl --vacuum-size=500M
elif command -v apk >/dev/null 2>&1; then
    apk cache clean
    find /var/log -mindepth 1 \
        -path "/var/log/cdt" -prune -o \
        -type f -exec truncate -s 0 {} + 2>/dev/null
    rm -rf /var/cache/apk/*
    rm -rf /tmp/*
fi

if command -v docker >/dev/null 2>&1; then
    docker image prune -f
    find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \;
fi
CLEANEOF
    chmod +x "$CLEAN_PATH"
    (crontab -l 2>/dev/null | grep -v "$CLEAN_PATH"; echo "6 6 * * 1 $CLEAN_PATH > /dev/null 2>&1") | crontab -
    printf "  ${GREEN}> 存储守护已部署 (每周一 06:06)${NC}\n"
    REPORT_CRON="${GREEN}已部署 (每周一 06:06)${NC}"
fi

# 4.6 即时清理
read -p "即时清理 : 是否立即执行一次系统清理? [Y/n]: " clean_confirm
clean_confirm=${clean_confirm:-"y"}

if [ "$clean_confirm" = "y" ] || [ "$clean_confirm" = "Y" ]; then
    printf "  正在执行系统清理，请稍候...\n"
    do_clean >/dev/null 2>&1
    printf "  ${GREEN}> 清理完成${NC}\n"
    REPORT_CLEAN="${GREEN}已执行${NC}"
fi

printf "\n${GREEN}==================== [ 3. 任务执行汇报 ] ====================${NC}\n"
printf " [系统环境] 操作系统 : ${OS} ${OS_VER}\n"
[ $IS_PVE -eq 1 ] && printf " [运行环境] PVE 宿主 : ${YELLOW}清理已降级保护${NC}\n"
printf " [网络算法] BBR+FQ   : ${REPORT_BBR:-${YELLOW}保持现状${NC}}\n"
printf " [内存优化] zRAM     : ${REPORT_ZRAM:-${YELLOW}保持现状${NC}}\n"
printf " [容器部署] Docker   : ${REPORT_DOCKER:-${YELLOW}未安装${NC}}\n"
printf " [系统时区] 时区     : ${REPORT_TZ:-${YELLOW}保持现状${NC}}\n"
printf " [存储守护] 定时清理 : ${REPORT_CRON:-${YELLOW}保持现状${NC}}\n"
printf " [即时清理] 本次清理 : ${REPORT_CLEAN:-${YELLOW}未执行${NC}}\n"
printf "${GREEN}==============================================================${NC}\n"

if [ $NEED_REBOOT -eq 1 ]; then
    printf "\n${RED}============================================================${NC}\n"
    printf "${RED}!! 警告：检测到内核改动，请务必执行 [ reboot ] 以激活优化 !!${NC}\n"
    printf "${RED}============================================================${NC}\n\n"
else
    printf "\n${GREEN}--- 任务完成！本次未改动核心参数，无需重启。---${NC}\n\n"
fi