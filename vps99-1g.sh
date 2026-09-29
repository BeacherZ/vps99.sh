#!/bin/sh

# ==============================================================================
# --- 脚本名称：VPS 基础开荒脚本 · 1G 硬盘版 (v9.9 Eternal Guard Edition)
# --- 适用系统：Debian 10+, Ubuntu 20+, Alpine Linux 3.15+
# ------------------------------------------------------------------------------
# 核心功能：
# 1. 网络：开启 BBR+FQ 拥塞控制与队列调度，提升网络吞吐并降低延迟。
# 2. 内存：部署 zRAM 压缩交换区，提升物理内存承载上限。
# 3. 容器：安装/更新/卸载 Docker Engine 与 Compose 插件。
# 4. 时区：设置系统时区为 Asia/Shanghai。
# 5. 守护：每周自动清理系统缓存、日志与容器垃圾，防止磁盘撑爆。
# 6. 清理：立即执行一次系统清理。
# ------------------------------------------------------------------------------
# 1G 硬盘专属版，与通用版 vps99.sh 的差异仅在清理模块：
# - journalctl：10M（通用版 7d + 100M）
# - 深度清理：doc/man/consolefonts/i18n/terminfo/locale/firmware/pycache
# - aliyun-assist：只保留最新版本，删旧版本目录
# - 子脚本：vps99clean-1g.sh（与通用版 vps99clean.sh 互不干扰）
# - 其他模块与通用版一致
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NEED_REBOOT=0
REBOOT_REASON=""

# 统一清理：临时文件 + 后台进度条
# dash 的 EXIT trap 在 SIGINT 下不保证触发，所以额外接 INT/TERM
cleanup() {
    [ -n "${PROGRESS_PID:-}" ] && kill "$PROGRESS_PID" 2>/dev/null
    rm -f /tmp/get-docker.sh 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

IS_PVE=0
if command -v pveversion >/dev/null 2>&1; then
    IS_PVE=1
fi

sysctl_set() {
    key="$1"
    value="$2"
    if grep -q "^${key}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^${key}[[:space:]]*=.*|${key}=${value}|" /etc/sysctl.conf
    else
        echo "${key}=${value}" >> /etc/sysctl.conf
    fi
}

fix_dpkg() {
    if [ "$IS_PVE" -eq 1 ]; then
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold 2>/dev/null
    else
        pkill -9 -x apt-get 2>/dev/null
        pkill -9 -x apt     2>/dev/null
        pkill -9 -x dpkg    2>/dev/null
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold 2>/dev/null
    fi
}

do_clean() {
    if command -v apt >/dev/null 2>&1; then
        fix_dpkg
        apt autoremove --purge -y
        apt clean -y
        apt autoclean -y
        journalctl --rotate
        journalctl --vacuum-size=10M
    elif command -v apk >/dev/null 2>&1; then
        apk cache clean
        find /var/log -mindepth 1 \
            -path "/var/log/cdt" -prune -o \
            -type f -exec truncate -s 0 {} + 2>/dev/null
        rm -rf /var/cache/apk/*
        rm -rf /tmp/*
    fi
    if command -v docker >/dev/null 2>&1; then
        docker image prune -a -f >/dev/null 2>&1
        find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
    fi

    # ---------- 1G 硬盘专属深度清理 ----------
    # 文档 / man / 本机终端字体
    rm -rf /usr/share/doc/* 2>/dev/null
    rm -rf /usr/share/man/* 2>/dev/null
    rm -rf /usr/share/consolefonts/* 2>/dev/null
    # i18n 字符集 + locale 文件（保留 UTF-8 / en / zh / i18n 命名）
    find /usr/share/i18n/charmaps -type f ! -name '*UTF-8*' -delete 2>/dev/null
    find /usr/share/i18n/locales -type f ! -name '*en*' ! -name '*zh*' ! -name 'i18n*' -delete 2>/dev/null
    # terminfo（保留常用终端类型）
    find /usr/share/terminfo -type f ! -name 'xterm*' ! -name 'linux' ! -name 'screen*' ! -name 'vt*' ! -name 'ansi' ! -name 'dumb' -delete 2>/dev/null
    # locale（保留 en / zh）
    ( cd /usr/share/locale 2>/dev/null && ls 2>/dev/null | grep -vE '^(en|zh|en_US|zh_CN|zh_TW|locale.alias)$' | xargs rm -rf 2>/dev/null )
    # 云 VPS 用不到的固件
    rm -rf /usr/lib/firmware/{netronome,sb16,ath10k,ath11k,iwlwifi,bnx2,bnx2x,brcm,mellanox,qcom,ti} 2>/dev/null
    # Python 编译缓存
    find /usr/lib/python3.13 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
    # aliyun-assist 旧版本目录（优先保留 symlink 指向的运行版本；symlink 失效时退回"版本号最大"）
    if [ -d /usr/local/share/aliyun-assist ]; then
        _aliyun_symlink="/usr/local/share/aliyun-assist/aliyun-service.symlink"
        _aliyun_keep=""
        if [ -L "$_aliyun_symlink" ]; then
            _aliyun_keep=$(basename "$(dirname "$(readlink "$_aliyun_symlink")")")
        fi
        if [ -z "$_aliyun_keep" ]; then
            _aliyun_keep=$(ls -1 /usr/local/share/aliyun-assist/ 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
        fi
        # 只有确认是版本号格式才进入删除循环（防止 symlink 内容异常时误删全部）
        if [ -n "$_aliyun_keep" ] && echo "$_aliyun_keep" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            for _v in /usr/local/share/aliyun-assist/[0-9]*/; do
                [ -d "$_v" ] || continue
                _vname=$(basename "$_v")
                [ "$_vname" = "$_aliyun_keep" ] && continue
                rm -rf "$_v" 2>/dev/null
            done
        fi
    fi
    # 旧日志（cdt 豁免）
    find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) ! -path '/var/log/cdt/*' -delete 2>/dev/null
}

remove_docker() {
    if [ "$OS" = "Alpine" ]; then
        rc-service docker stop >/dev/null 2>&1
        rc-update del docker default >/dev/null 2>&1
        apk del docker docker-cli-compose >/dev/null 2>&1
    else
        systemctl stop docker >/dev/null 2>&1
        apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
        rm -rf /var/lib/docker /var/lib/containerd >/dev/null 2>&1
    fi
}

check_docker_latest() {
    LATEST_DOCKER=$(curl -s --connect-timeout 3 --max-time 5 "https://api.github.com/repos/moby/moby/releases/latest" 2>/dev/null | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    LATEST_COMPOSE=$(curl -s --connect-timeout 3 --max-time 5 "https://api.github.com/repos/docker/compose/releases/latest" 2>/dev/null | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
}

progress_slow() {
    bar_width=30
    max_fill=27
    fill=0

    while [ "$fill" -le "$max_fill" ]; do
        empty=$((bar_width - fill))
        bar=""
        j=0
        while [ "$j" -lt "$fill" ]; do bar="${bar}#"; j=$((j + 1)); done
        j=0
        while [ "$j" -lt "$empty" ]; do bar="${bar}-"; j=$((j + 1)); done
        printf "\r  [%s]" "$bar"
        fill=$((fill + 1))
        sleep 1
    done

    while :; do sleep 1; done
}

progress_finish() {
    start_fill="$1"
    [ -z "$start_fill" ] && start_fill=0
    [ "$start_fill" -lt 0 ] && start_fill=0
    [ "$start_fill" -gt 30 ] && start_fill=30
    bar_width=30
    fill=$start_fill
    steps=$((bar_width - start_fill))
    [ "$steps" -le 0 ] && steps=1
    step_interval=$(awk "BEGIN{printf \"%.3f\", 1.0/$steps}" 2>/dev/null)
    [ -z "$step_interval" ] && step_interval="0.03"

    while [ "$fill" -le "$bar_width" ]; do
        empty=$((bar_width - fill))
        bar=""
        j=0
        while [ "$j" -lt "$fill" ]; do bar="${bar}#"; j=$((j + 1)); done
        j=0
        while [ "$j" -lt "$empty" ]; do bar="${bar}-"; j=$((j + 1)); done
        printf "\r  [%s]" "$bar"
        fill=$((fill + 1))
        sleep "$step_interval"
    done
    printf "\r  [%s]  完成！          \n" "$(printf '%*s' "$bar_width" '' | tr ' ' '#')"
}

if [ -f /etc/alpine-release ]; then
    OS="Alpine"
    OS_VER=$(cat /etc/alpine-release)
    INSTALL_CMD="apk add"
    OS_DISPLAY="Alpine ${OS_VER}"
elif [ -f /etc/debian_version ]; then
    OS="Debian"
    OS_VER=$(cat /etc/debian_version)
    INSTALL_CMD="apt-get install -y -qq"
    # 读取 os-release 区分 Debian / Ubuntu，仅取 ID + VERSION_ID
    if [ -f /etc/os-release ]; then
        OS_ID=$( . /etc/os-release 2>/dev/null && echo "$ID" )
        OS_VID=$( . /etc/os-release 2>/dev/null && echo "$VERSION_ID" )
        case "$OS_ID" in
            ubuntu) OS_DISPLAY="Ubuntu ${OS_VID}" ;;
            debian) OS_DISPLAY="Debian ${OS_VID}" ;;
            *)      OS_DISPLAY="${OS_ID} ${OS_VID}" ;;
        esac
    else
        OS_DISPLAY="Debian ${OS_VER}"
    fi
else
    printf "${RED}错误: 不支持的系统类型${NC}\n"
    exit 1
fi

clear
printf "${GREEN}================================================================================${NC}\n"
printf "${GREEN}           Universal VPS Initialization Script - v9.9 - 1G 硬盘版           ${NC}\n"
printf "${GREEN}================================================================================${NC}\n"

printf "${CYAN}[ 1. 系统现状体检 ]${NC}\n"

# 采集硬件摘要
_cpu_raw=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //')
[ -z "$_cpu_raw" ] && _cpu_raw=$(grep -m1 'Hardware' /proc/cpuinfo 2>/dev/null | sed 's/.*: //')
[ -z "$_cpu_raw" ] && _cpu_raw=$(grep -m1 'Processor' /proc/cpuinfo 2>/dev/null | sed 's/.*: //')
[ -z "$_cpu_raw" ] && _cpu_raw=$(grep -m1 'cpu model' /proc/cpuinfo 2>/dev/null | sed 's/.*: //')

if [ -z "$_cpu_raw" ]; then
    _cpu_short="Unknown CPU"
else
    _cpu_short=$(echo "$_cpu_raw" | sed \
        -e 's/(R)//g' \
        -e 's/(TM)//g' \
        -e 's/(r)//g' \
        -e 's/(tm)//g' \
        -e 's/ @.*//g' \
        -e 's/ CPU//g' \
        -e 's/ Processor//g' \
        -e 's/ [0-9]*-Core//g' \
        -e 's/  */ /g' \
        -e 's/^ //; s/ $//')
fi

_cpu_cores=$(nproc 2>/dev/null)
[ -z "$_cpu_cores" ] && _cpu_cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
[ -z "$_cpu_cores" ] && _cpu_cores="?"

_mem_size=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' | sed 's/i$//')
[ -z "$_mem_size" ] && _mem_size="?"

_disk_size=$(df -h / 2>/dev/null | awk 'NR==2{print $2}')
[ -z "$_disk_size" ] && _disk_size="?"

printf " - 系统环境 : ${OS_DISPLAY}  »  ${_cpu_cores}核 ${_cpu_short} / ${_mem_size}内存 / ${_disk_size}硬盘\n"

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

if crontab -l 2>/dev/null | grep -q "vps99clean-1g.sh"; then
    HAS_CRON=1
    CRON_TIME=$(crontab -l 2>/dev/null | grep "vps99clean-1g.sh" | awk '{
        min=$1; hour=$2; dow=$5
        if (dow == "0") day="日"
        else if (dow == "1") day="一"
        else if (dow == "2") day="二"
        else if (dow == "3") day="三"
        else if (dow == "4") day="四"
        else if (dow == "5") day="五"
        else if (dow == "6") day="六"
        else day="*"
        printf "每周%s %02d:%02d", day, hour+0, min+0
    }')
    if [ -z "$CRON_TIME" ]; then
        CRON_TIME="已配置"
    fi
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
[ $HAS_CRON -eq 1 ] && printf " - 存储守护 : ${GREEN}已配置 (${CRON_TIME})${NC}\n" || printf " - 存储守护 : ${YELLOW}未部署${NC}\n"
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
    printf "网络算法 : ${BBR_LABEL}，是否覆盖配置? [y/N]: "
    read bbr_confirm
else
    printf "网络算法 : 是否开启 BBR+FQ? [y/N]: "
    read bbr_confirm
fi
bbr_confirm=${bbr_confirm:-"n"}

if [ "$bbr_confirm" = "y" ] || [ "$bbr_confirm" = "Y" ]; then
    sysctl_set "net.core.default_qdisc" "fq"
    sysctl_set "net.ipv4.tcp_congestion_control" "bbr"
    sysctl -p >/dev/null 2>&1

    now_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    now_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)

    if [ "$now_cc" = "bbr" ] && [ "$now_qdisc" = "fq" ]; then
        printf "  ${GREEN}> BBR+FQ 已配置并立即生效，无需重启${NC}\n"
        REPORT_BBR="${GREEN}BBR+FQ 已开启${NC}"
    else
        printf "  ${YELLOW}> BBR+FQ 已写入配置，但未立即生效，重启后激活${NC}\n"
        REPORT_BBR="${GREEN}BBR+FQ 已配置（待重启）${NC}"
        NEED_REBOOT=1
        REBOOT_REASON="BBR+FQ 未立即生效"
    fi
fi

# 4.2 zRAM
if [ $HAS_ZRAM -eq 1 ]; then
    printf "内存优化 : zRAM 已存在，是否覆盖配置? [y/N]: "
    read zram_confirm
else
    printf "内存优化 : 是否部署 zRAM? [y/N]: "
    read zram_confirm
fi
zram_confirm=${zram_confirm:-"n"}

if [ "$zram_confirm" = "y" ] || [ "$zram_confirm" = "Y" ]; then
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    zram_size=$([ "$total_mem" -le 1024 ] && echo "$total_mem" || echo "$((total_mem * 60 / 100))")

    phys_swap=$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ {s+=$3} END{printf "%d", s/1024}' /proc/swaps 2>/dev/null)
    phys_swap=${phys_swap:-0}
    if [ "$phys_swap" -gt 0 ]; then
        swap_p=60
    else
        swap_p=$([ "$total_mem" -le 1024 ] && echo "80" || echo "60")
    fi

    sysctl_set "vm.swappiness" "$swap_p"
    sysctl -p >/dev/null 2>&1

    if [ "$OS" = "Alpine" ]; then
        apk add zram-init >/dev/null 2>&1
        printf "load_modules=\"yes\"\nnum_devices=\"1\"\ntype0=\"swap\"\nsize0=\"%s\"\nalgo0=\"lz4\"\n" "$zram_size" > /etc/conf.d/zram-init
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
    REBOOT_REASON="${REBOOT_REASON} zRAM 服务首次加载需重启;"
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
        DOCKER_STATUS="${YELLOW}查询超时，跳过更新检查${NC}"
    fi

    if [ -n "$LATEST_COMPOSE" ]; then
        if [ "$COMPOSE_VER" = "$LATEST_COMPOSE" ]; then
            COMPOSE_STATUS="${GREEN}已是最新${NC}"
        else
            COMPOSE_STATUS="${YELLOW}可更新至 ${LATEST_COMPOSE}${NC}"
        fi
    else
        COMPOSE_STATUS="${YELLOW}查询超时，跳过更新检查${NC}"
    fi

    printf "容器部署 : Docker ${DOCKER_VER} (${DOCKER_STATUS}) / Compose ${COMPOSE_VER} (${COMPOSE_STATUS})\n"
    printf "           是否管理? [y/N]: "
    read docker_enter
else
    printf "容器部署 : 未安装，是否管理? [y/N]: "
    read docker_enter
fi
docker_enter=${docker_enter:-"n"}

if [ "$docker_enter" = "y" ] || [ "$docker_enter" = "Y" ]; then
    if [ $HAS_DOCKER -eq 1 ]; then
        NEED_DOCKER_UPDATE=0
        NEED_COMPOSE_UPDATE=0
        if [ -n "$LATEST_DOCKER" ]; then
            _newer_d=$(printf '%s\n%s\n' "$DOCKER_VER" "$LATEST_DOCKER" | sort -V 2>/dev/null | tail -1)
            if [ "$_newer_d" = "$LATEST_DOCKER" ] && [ "$DOCKER_VER" != "$LATEST_DOCKER" ]; then
                NEED_DOCKER_UPDATE=1
            fi
        fi
        if [ -n "$LATEST_COMPOSE" ]; then
            _newer_c=$(printf '%s\n%s\n' "$COMPOSE_VER" "$LATEST_COMPOSE" | sort -V 2>/dev/null | tail -1)
            if [ "$_newer_c" = "$LATEST_COMPOSE" ] && [ "$COMPOSE_VER" != "$LATEST_COMPOSE" ]; then
                NEED_COMPOSE_UPDATE=1
            fi
        fi

        if [ $NEED_DOCKER_UPDATE -eq 1 ] || [ $NEED_COMPOSE_UPDATE -eq 1 ]; then
            printf "           1) 更新  2) 卸载  3) 跳过\n"
            printf "           请选择 [3]: "
            read docker_choice
            docker_choice=${docker_choice:-"3"}
        else
            printf "           1) 卸载  2) 跳过\n"
            printf "           请选择 [2]: "
            read docker_choice
            docker_choice=${docker_choice:-"2"}
            case "$docker_choice" in
                1) docker_choice="2" ;;
                *) docker_choice="3" ;;
            esac
        fi
    else
        printf "           1) 安装  2) 跳过\n"
        printf "           请选择 [2]: "
        read docker_choice
        docker_choice=${docker_choice:-"2"}
    fi

    case "$docker_choice" in
        1)
            printf "  正在安装/更新 Docker & Compose，请稍候...\n"
            start_ts=$(date +%s)
            progress_slow &
            PROGRESS_PID=$!

            if [ "$OS" = "Debian" ]; then
                fix_dpkg
            fi
            if [ "$OS" = "Alpine" ]; then
                apk add docker docker-cli-compose >/dev/null 2>&1
                rc-update add docker default >/dev/null 2>&1
                rc-service docker start >/dev/null 2>&1
            else
                if [ $HAS_DOCKER -eq 0 ]; then
                    if curl -fsSL --connect-timeout 5 --max-time 60 https://get.docker.com -o /tmp/get-docker.sh; then
                        sed -i 's/sleep 20/sleep 0/' /tmp/get-docker.sh
                        sh /tmp/get-docker.sh >/dev/null 2>&1
                        rm -f /tmp/get-docker.sh
                    else
                        printf "  ${RED}> 下载 Docker 安装脚本失败，请检查网络${NC}\n"
                        REPORT_DOCKER="${RED}安装失败（下载失败）${NC}"
                    fi
                else
                    if [ "$NEED_DOCKER_UPDATE" -eq 0 ] && [ "$NEED_COMPOSE_UPDATE" -eq 1 ]; then
                        printf "  Docker 已是最新，仅更新 Compose...\n"
                        apt-get update -qq >/dev/null 2>&1
                        apt-get install -y docker-compose-plugin >/dev/null 2>&1
                    elif [ "$NEED_DOCKER_UPDATE" -eq 1 ] && [ "$NEED_COMPOSE_UPDATE" -eq 0 ]; then
                        printf "  Compose 已是最新，仅更新 Docker...\n"
                        if curl -fsSL --connect-timeout 5 --max-time 60 https://get.docker.com -o /tmp/get-docker.sh; then
                            sed -i 's/sleep 20/sleep 0/' /tmp/get-docker.sh
                            sh /tmp/get-docker.sh >/dev/null 2>&1
                            rm -f /tmp/get-docker.sh
                        else
                            printf "  ${RED}> 下载 Docker 安装脚本失败，请检查网络${NC}\n"
                            REPORT_DOCKER="${RED}更新失败（下载失败）${NC}"
                        fi
                    else
                        if curl -fsSL --connect-timeout 5 --max-time 60 https://get.docker.com -o /tmp/get-docker.sh; then
                            sed -i 's/sleep 20/sleep 0/' /tmp/get-docker.sh
                            sh /tmp/get-docker.sh >/dev/null 2>&1
                            rm -f /tmp/get-docker.sh
                        else
                            printf "  ${RED}> 下载 Docker 安装脚本失败，请检查网络${NC}\n"
                            REPORT_DOCKER="${RED}更新失败（下载失败）${NC}"
                        fi
                    fi
                fi
            fi

            elapsed=$(( $(date +%s) - start_ts ))
            cur_fill=$((elapsed * 27 / 30))
            [ "$cur_fill" -gt 27 ] && cur_fill=27
            [ "$cur_fill" -lt 0 ] && cur_fill=0
            kill "$PROGRESS_PID" 2>/dev/null
            wait "$PROGRESS_PID" 2>/dev/null
            PROGRESS_PID=""
            progress_finish "$cur_fill"

            if command -v docker >/dev/null 2>&1; then
                NEW_DOCKER_VER=$(docker -v | awk '{print $3}' | tr -d ',')
                NEW_COMPOSE_VER=$(docker compose version 2>/dev/null | awk '{print $NF}' | tr -d 'v')
                
                if [ $HAS_DOCKER -eq 0 ]; then
                    printf "  ${GREEN}> Docker ${NEW_DOCKER_VER} / Compose ${NEW_COMPOSE_VER} 安装成功${NC}\n"
                    REPORT_DOCKER="${GREEN}Docker ${NEW_DOCKER_VER} / Compose ${NEW_COMPOSE_VER}${NC}"
                else
                    DOCKER_UPDATED=0
                    COMPOSE_UPDATED=0
                    [ "$NEW_DOCKER_VER" != "$DOCKER_VER" ] && DOCKER_UPDATED=1
                    [ "$NEW_COMPOSE_VER" != "$COMPOSE_VER" ] && COMPOSE_UPDATED=1

                    if [ $DOCKER_UPDATED -eq 1 ] || [ $COMPOSE_UPDATED -eq 1 ]; then
                        printf "  ${GREEN}> Docker ${NEW_DOCKER_VER} / Compose ${NEW_COMPOSE_VER} 更新成功${NC}\n"
                        REPORT_DOCKER="${GREEN}Docker ${NEW_DOCKER_VER} / Compose ${NEW_COMPOSE_VER}${NC}"
                    else
                        printf "  ${RED}> 更新失败，版本未变 (Docker ${NEW_DOCKER_VER} / Compose ${NEW_COMPOSE_VER})${NC}\n"
                        REPORT_DOCKER="${RED}更新失败 (${NEW_DOCKER_VER} / ${NEW_COMPOSE_VER})${NC}"
                    fi
                fi
            else
                printf "  ${RED}> 安装失败，请检查网络${NC}\n"
                REPORT_DOCKER="${RED}安装失败${NC}"
            fi
            ;;
        2)
            if [ $HAS_DOCKER -eq 1 ]; then
                printf "  正在卸载 Docker & Compose，请稍候...\n"
                start_ts=$(date +%s)
                progress_slow &
                PROGRESS_PID=$!
                remove_docker
                elapsed=$(( $(date +%s) - start_ts ))
                cur_fill=$((elapsed * 27 / 30))
                [ "$cur_fill" -gt 27 ] && cur_fill=27
                [ "$cur_fill" -lt 0 ] && cur_fill=0
                kill "$PROGRESS_PID" 2>/dev/null
                wait "$PROGRESS_PID" 2>/dev/null
                PROGRESS_PID=""
                progress_finish "$cur_fill"
                if type hash >/dev/null 2>&1; then
                    hash -r 2>/dev/null
                fi
                if ! command -v docker >/dev/null 2>&1; then
                    printf "  ${GREEN}> Docker & Compose 卸载成功${NC}\n"
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
    printf "系统时区 : 已是 Asia/Shanghai，是否重新设置? [y/N]: "
    read tz_confirm
else
    printf "系统时区 : 是否设置为 Asia/Shanghai? [y/N]: "
    read tz_confirm
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
    printf "存储守护 : 已存在，是否重写配置? [y/N]: "
    read cron_confirm
else
    printf "存储守护 : 是否部署定时清理 (每周一 06:06)? [y/N]: "
    read cron_confirm
fi
cron_confirm=${cron_confirm:-"n"}

if [ "$cron_confirm" = "y" ] || [ "$cron_confirm" = "Y" ]; then
    CLEAN_PATH="/root/vps99clean-1g.sh"
    cat > "$CLEAN_PATH" <<'CLEANEOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

IS_PVE=0
if command -v pveversion >/dev/null 2>&1; then
    IS_PVE=1
fi

if command -v apt >/dev/null 2>&1; then
    if [ "$IS_PVE" -eq 0 ]; then
        pkill -9 -x apt-get 2>/dev/null
        pkill -9 -x apt     2>/dev/null
        pkill -9 -x dpkg    2>/dev/null
    fi
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold 2>/dev/null
    apt autoremove --purge -y
    apt clean -y
    apt autoclean -y
    journalctl --rotate
    journalctl --vacuum-size=10M
elif command -v apk >/dev/null 2>&1; then
    apk cache clean
    find /var/log -mindepth 1 \
        -path "/var/log/cdt" -prune -o \
        -type f -exec truncate -s 0 {} + 2>/dev/null
    rm -rf /var/cache/apk/*
    rm -rf /tmp/*
fi

if command -v docker >/dev/null 2>&1; then
    docker image prune -a -f
    find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \;
fi

# ---------- 1G 硬盘专属深度清理 ----------
# 文档 / man / 本机终端字体
rm -rf /usr/share/doc/* 2>/dev/null
rm -rf /usr/share/man/* 2>/dev/null
rm -rf /usr/share/consolefonts/* 2>/dev/null
# i18n 字符集 + locale 文件（保留 UTF-8 / en / zh / i18n 命名）
find /usr/share/i18n/charmaps -type f ! -name '*UTF-8*' -delete 2>/dev/null
find /usr/share/i18n/locales -type f ! -name '*en*' ! -name '*zh*' ! -name 'i18n*' -delete 2>/dev/null
# terminfo（保留常用终端类型）
find /usr/share/terminfo -type f ! -name 'xterm*' ! -name 'linux' ! -name 'screen*' ! -name 'vt*' ! -name 'ansi' ! -name 'dumb' -delete 2>/dev/null
# locale（保留 en / zh）
( cd /usr/share/locale 2>/dev/null && ls 2>/dev/null | grep -vE '^(en|zh|en_US|zh_CN|zh_TW|locale.alias)$' | xargs rm -rf 2>/dev/null )
# 云 VPS 用不到的固件
rm -rf /usr/lib/firmware/{netronome,sb16,ath10k,ath11k,iwlwifi,bnx2,bnx2x,brcm,mellanox,qcom,ti} 2>/dev/null
# Python 编译缓存
find /usr/lib/python3.13 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
# aliyun-assist 旧版本目录（优先保留 symlink 指向的运行版本；symlink 失效时退回"版本号最大"）
if [ -d /usr/local/share/aliyun-assist ]; then
    _aliyun_symlink="/usr/local/share/aliyun-assist/aliyun-service.symlink"
    _aliyun_keep=""
    if [ -L "$_aliyun_symlink" ]; then
        _aliyun_keep=$(basename "$(dirname "$(readlink "$_aliyun_symlink")")")
    fi
    if [ -z "$_aliyun_keep" ]; then
        _aliyun_keep=$(ls -1 /usr/local/share/aliyun-assist/ 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    fi
    # 只有确认是版本号格式才进入删除循环（防止 symlink 内容异常时误删全部）
    if [ -n "$_aliyun_keep" ] && echo "$_aliyun_keep" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        for _v in /usr/local/share/aliyun-assist/[0-9]*/; do
            [ -d "$_v" ] || continue
            _vname=$(basename "$_v")
            [ "$_vname" = "$_aliyun_keep" ] && continue
            rm -rf "$_v" 2>/dev/null
        done
    fi
fi
# 旧日志（cdt 豁免）
find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) ! -path '/var/log/cdt/*' -delete 2>/dev/null
CLEANEOF
    chmod +x "$CLEAN_PATH"
    (crontab -l 2>/dev/null | grep -v "$CLEAN_PATH"; echo "6 6 * * 1 $CLEAN_PATH > /dev/null 2>&1") | crontab -
    printf "  ${GREEN}> 存储守护已部署 (每周一 06:06)${NC}\n"
    REPORT_CRON="${GREEN}已部署 (每周一 06:06)${NC}"
fi

# 4.6 即时清理
printf "即时清理 : 是否立即执行一次系统清理? [Y/n]: "
read clean_confirm
clean_confirm=${clean_confirm:-"y"}

if [ "$clean_confirm" = "y" ] || [ "$clean_confirm" = "Y" ]; then
    printf "  正在执行系统清理，请稍候...\n"
    do_clean >/dev/null 2>&1
    printf "  ${GREEN}> 清理完成${NC}\n"
    REPORT_CLEAN="${GREEN}已执行${NC}"
fi

printf "\n${GREEN}==================== [ 3. 任务执行汇报 ] ====================${NC}\n"
printf " [系统环境] 操作系统 : ${OS_DISPLAY}\n"
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
    [ -n "$REBOOT_REASON" ] && printf "${RED}   原因：${REBOOT_REASON}${NC}\n"
    printf "${RED}============================================================${NC}\n\n"
else
    printf "\n${GREEN}--- 任务完成！本次未改动核心参数，无需重启。---${NC}\n\n"
fi