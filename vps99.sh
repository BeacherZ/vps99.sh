#!/bin/sh

# ==============================================================================
# --- 脚本名称：VPS 基础开荒脚本 (v9.9 Eternal Guard Edition)
# --- 适用系统：Debian 10+, Ubuntu 20+, Alpine Linux 3.15+
# ------------------------------------------------------------------------------
# 核心功能：
# 1. 网络：开启 BBR+FQ 拥塞控制与队列调度，提升网络吞吐并降低延迟。
# 2. 内存：zRAM 与物理 swap 双通道管理，zRAM 压缩优先、swap 物理磁盘兜底。
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
REBOOT_REASON=""

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
            journalctl --vacuum-size=100M
        else
            journalctl --vacuum-time=1s
            journalctl --vacuum-size=100M
        fi
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
    CRON_TIME=$(crontab -l 2>/dev/null | grep "vps99clean.sh" | awk '{
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

_hm_zram=$(awk 'NR>1 && $1 ~ /^\/dev\/zram/ {s+=$3} END{printf "%d", s/1024}' /proc/swaps 2>/dev/null)
_hm_zram=${_hm_zram:-0}
_hm_phy=$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ {s+=$3} END{printf "%d", s/1024}' /proc/swaps 2>/dev/null)
_hm_phy=${_hm_phy:-0}

if [ "$_hm_zram" -gt 0 ] && [ "$_hm_phy" -gt 0 ]; then
    printf " - 内存优化 : ${GREEN}zRAM ${_hm_zram}MB + 物理swap ${_hm_phy}MB${NC}\n"
elif [ "$_hm_zram" -gt 0 ]; then
    printf " - 内存优化 : ${GREEN}zRAM ${_hm_zram}MB (无物理swap)${NC}\n"
elif [ "$_hm_phy" -gt 0 ]; then
    printf " - 内存优化 : ${YELLOW}物理swap ${_hm_phy}MB (无 zRAM)${NC}\n"
else
    printf " - 内存优化 : ${YELLOW}未部署${NC}\n"
fi

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
printf " - 内存优化 : zRAM 与物理 swap 双通道管理，zRAM 压缩优先、swap 物理磁盘兜底\n"
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

# 4.2 zRAM + Swap 管理
total_mem=$(free -m | awk '/^Mem:/{print $2+0}')
root_avail=$(df -m / | awk 'NR==2{print $4+0}')
[ -z "$total_mem" ] && total_mem=0
[ -z "$root_avail" ] && root_avail=0

zram_mb=$(awk 'NR>1 && $1 ~ /^\/dev\/zram/ {s+=$3} END{printf "%d", s/1024}' /proc/swaps 2>/dev/null)
zram_mb=${zram_mb:-0}

phy_swap_mb=$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ {s+=$3} END{printf "%d", s/1024}' /proc/swaps 2>/dev/null)
phy_swap_mb=${phy_swap_mb:-0}

phy_swap_files=$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ && $1 !~ /^\/dev\// {print $1}' /proc/swaps 2>/dev/null | tr '\n' ' ')
phy_swap_parts=$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ && $1 ~ /^\/dev\// && $1 !~ /^\/dev\/mapper/ {print $1}' /proc/swaps 2>/dev/null | tr '\n' ' ')
phy_swap_lvs=$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ && $1 ~ /^\/dev\/mapper/ {print $1}' /proc/swaps 2>/dev/null | tr '\n' ' ')

cur_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)
cur_swappiness=${cur_swappiness:-0}

if [ "$total_mem" -le 1024 ]; then
    rec_zram=$total_mem
else
    rec_zram=$((total_mem * 50 / 100))
fi

if [ "$root_avail" -lt 5120 ]; then
    rec_phy=0
elif [ "$root_avail" -lt 20480 ]; then
    rec_phy=512
else
    rec_phy=1024
fi

if [ "$rec_phy" -gt 0 ]; then
    [ "$total_mem" -le 1024 ] && rec_swappiness=60 || rec_swappiness=30
else
    [ "$total_mem" -le 1024 ] && rec_swappiness=80 || rec_swappiness=60
fi

zram_diff=$((zram_mb - rec_zram))
[ "$zram_diff" -lt 0 ] && zram_diff=$((0 - zram_diff))
if [ "$zram_diff" -le 32 ]; then
    zram_state="${GREEN}已符合${NC}"; zram_ok=1
else
    zram_state="${YELLOW}需调整${NC}"; zram_ok=0
fi

phy_ok=0
if [ "$rec_phy" -eq 0 ] && [ "$phy_swap_mb" -eq 0 ]; then
    rec_phy_disp="不创建"
    phy_state="${GREEN}已符合${NC}"; phy_ok=1
elif [ "$rec_phy" -gt 0 ]; then
    rec_phy_disp="${rec_phy} MB"
    phy_diff=$((phy_swap_mb - rec_phy))
    [ "$phy_diff" -lt 0 ] && phy_diff=$((0 - phy_diff))
    if [ "$phy_diff" -le 32 ]; then
        phy_state="${GREEN}已符合${NC}"; phy_ok=1
    else
        phy_state="${YELLOW}需调整${NC}"; phy_ok=0
    fi
else
    rec_phy_disp="不创建"
    phy_state="${YELLOW}需调整${NC}"; phy_ok=0
fi

swp_diff=$((cur_swappiness - rec_swappiness))
[ "$swp_diff" -lt 0 ] && swp_diff=$((0 - swp_diff))
if [ "$swp_diff" -le 5 ]; then
    swp_state="${GREEN}已符合${NC}"; swp_ok=1
else
    swp_state="${YELLOW}需调整${NC}"; swp_ok=0
fi

printf "${CYAN}[ 内存优化 - zRAM 与 Swap 管理 ]${NC}\n"
printf " - 物理内存    : %s MB\n" "$total_mem"
printf " - 磁盘可用    : %s MB\n" "$root_avail"

printf " - 物理swap类型: "
if [ -z "$phy_swap_files$phy_swap_parts$phy_swap_lvs" ]; then
    printf "无\n"
else
    [ -n "$phy_swap_files" ] && printf "文件(%s) " "$phy_swap_files"
    [ -n "$phy_swap_parts" ] && printf "分区(%s) " "$phy_swap_parts"
    [ -n "$phy_swap_lvs" ] && printf "LVM(%s) " "$phy_swap_lvs"
    printf "\n"
fi

printf "\n ${CYAN}推荐对比${NC}\n"
printf "   项目            当前           推荐           状态\n"
printf "   zRAM            %-14s %-14s %b\n" "${zram_mb} MB" "${rec_zram} MB" "$zram_state"
printf "   物理swap        %-14s %-14s %b\n" "${phy_swap_mb} MB" "$rec_phy_disp" "$phy_state"
printf "   swappiness      %-14s %-14s %b\n" "$cur_swappiness" "$rec_swappiness" "$swp_state"
printf "\n"

if [ "$zram_ok" -eq 1 ] && [ "$phy_ok" -eq 1 ] && [ "$swp_ok" -eq 1 ]; then
    printf " ${GREEN}当前配置已符合推荐，无需调整${NC}\n"
else
    printf " ${YELLOW}当前配置与推荐存在差异，可进入下方调整${NC}\n"
fi

if [ "$zram_ok" -eq 1 ] && [ "$phy_ok" -eq 1 ] && [ "$swp_ok" -eq 1 ]; then
    printf " ${CYAN}提示：直接回车 = 跳过内存优化，保持现状${NC}\n"
else
    printf " ${CYAN}提示：推荐配置与当前有差异，进入可直接调整；回车 = 跳过${NC}\n"
fi
read -p "  是否进入内存优化管理? [y/N]: " mem_enter
mem_enter=${mem_enter:-"n"}

if [ "$mem_enter" = "y" ] || [ "$mem_enter" = "Y" ]; then
    # ---------- zRAM ----------
    if [ "$HAS_ZRAM" -eq 1 ]; then
        read -p "zRAM 当前 ${zram_mb}MB，是否调整/重建? [y/N]: " zram_confirm
    else
        read -p "zRAM 未部署，是否部署? [y/N]: " zram_confirm
    fi
    zram_confirm=${zram_confirm:-"n"}

    zram_new_size=""
    if [ "$zram_confirm" = "y" ] || [ "$zram_confirm" = "Y" ]; then
        printf "  说明：直接回车 = 使用推荐值 %s MB；输入 0 = 保持现状不改\n" "$rec_zram"
        read -p "  请输入 zRAM 大小(MB) [${rec_zram}]: " zram_new_size

        if [ -z "$zram_new_size" ]; then
            zram_new_size=$rec_zram
        fi

        if [ "$zram_new_size" = "0" ]; then
            printf "  ${YELLOW}> 已选择保持现状，跳过 zRAM 调整${NC}\n"
            zram_new_size=""
        elif ! echo "$zram_new_size" | grep -qE '^[0-9]+$'; then
            printf "  ${RED}> 输入无效：请输入纯数字（单位 MB），已跳过 zRAM 调整${NC}\n"
            zram_new_size=""
        elif [ "$zram_new_size" -lt 64 ]; then
            printf "  ${RED}> 输入过小：zRAM 至少 64 MB，已跳过 zRAM 调整${NC}\n"
            zram_new_size=""
        fi
    fi

    if [ -n "$zram_new_size" ]; then
        if [ "$OS" = "Alpine" ]; then
            apk add zram-init >/dev/null 2>&1
            printf "load_modules=\"yes\"\nnum_devices=\"1\"\ntype0=\"swap\"\nsize0=\"%s\"\nalgo0=\"lz4\"\n" "$zram_new_size" > /etc/conf.d/zram-init
            rc-update add zram-init default >/dev/null 2>&1
            rc-service zram-init restart >/dev/null 2>&1 || rc-service zram-init start >/dev/null 2>&1
        else
            DEBIAN_FRONTEND=noninteractive $INSTALL_CMD -o Dpkg::Options::="--force-confold" zram-tools >/dev/null 2>&1
            printf "ALGO=lz4\nSIZE=%s\nPRIORITY=32767\n" "$zram_new_size" > /etc/default/zramswap
            systemctl restart zramswap >/dev/null 2>&1
        fi

        sleep 1
        new_zram=$(awk 'NR>1 && $1 ~ /^\/dev\/zram/ {s+=$3} END{printf "%d", s/1024}' /proc/swaps 2>/dev/null)
        new_zram=${new_zram:-0}
        if [ "$new_zram" -gt 0 ]; then
            printf "  ${GREEN}> zRAM 已配置并生效 (${zram_new_size}MB, lz4, priority=32767)${NC}\n"
            REPORT_ZRAM="${GREEN}已配置 (${zram_new_size}MB)${NC}"
        else
            printf "  ${YELLOW}> zRAM 已写入配置，重启后激活 (${zram_new_size}MB, lz4, priority=32767)${NC}\n"
            REPORT_ZRAM="${GREEN}已配置（待重启）(${zram_new_size}MB)${NC}"
            NEED_REBOOT=1
            REBOOT_REASON="${REBOOT_REASON} zRAM 未立即生效;"
        fi
        zram_mb=$zram_new_size
    fi

    # ---------- 物理 Swap ----------
    if [ "$phy_swap_mb" -gt 0 ] || [ -n "$phy_swap_files" ] || [ -n "$phy_swap_parts" ] || [ -n "$phy_swap_lvs" ]; then
        printf "${CYAN}[ 物理 Swap 处理 ]${NC}\n"
        [ -n "$phy_swap_files" ] && printf "  文件: %s\n" "$phy_swap_files"
        [ -n "$phy_swap_parts" ] && printf "  ${YELLOW}分区: %s (脚本不自动调整，请手动处理)${NC}\n" "$phy_swap_parts"
        [ -n "$phy_swap_lvs" ] && printf "  ${YELLOW}LVM: %s (脚本不自动调整，请手动处理)${NC}\n" "$phy_swap_lvs"

        if [ -n "$phy_swap_files" ]; then
            printf "  1) 调整/重建 swapfile  2) 删除 swapfile  3) 跳过\n"
            read -p "  请选择 [3]: " phy_choice
            phy_choice=${phy_choice:-"3"}
        else
            phy_choice="3"
        fi
    else
        if [ "$rec_phy" -eq 0 ]; then
            printf " ${YELLOW}磁盘可用仅 %sMB，不建议创建物理 swap${NC}\n" "$root_avail"
            read -p "物理 swap: 是否仍要创建? [y/N]: " phy_create
        else
            read -p "物理 swap: 未配置，是否创建 swapfile (${rec_phy}MB)? [y/N]: " phy_create
        fi
        phy_create=${phy_create:-"n"}
        if [ "$phy_create" = "y" ] || [ "$phy_create" = "Y" ]; then
            phy_choice="1"
        else
            phy_choice="3"
        fi
    fi

    case "$phy_choice" in
        1)
            if [ "$rec_phy" -gt 0 ]; then
                default_phy=$rec_phy
            else
                default_phy=512
            fi
            printf "  说明：直接回车 = 使用推荐值 %s MB；输入 0 = 取消本次创建\n" "$default_phy"
            read -p "  请输入 swapfile 大小(MB) [${default_phy}]: " phy_size

            if [ -z "$phy_size" ]; then
                phy_size=$default_phy
            fi

            if [ "$phy_size" = "0" ]; then
                printf "  ${YELLOW}> 已取消本次 swapfile 创建${NC}\n"
            elif ! echo "$phy_size" | grep -qE '^[0-9]+$'; then
                printf "  ${RED}> 输入无效：请输入纯数字（单位 MB），已取消本次创建${NC}\n"
            elif [ "$phy_size" -lt 128 ]; then
                printf "  ${RED}> 输入过小：swapfile 至少 128 MB，已取消本次创建${NC}\n"
            elif [ "$phy_size" -gt $((root_avail - 200)) ]; then
                printf "  ${RED}> 超过磁盘空间：最多 %s MB（需留 200MB 给系统），已取消本次创建${NC}\n" "$((root_avail - 200))"
            else
                SWAPFILE="/swapfile"

                ok=1
                for f in $phy_swap_files; do
                    [ -f "$f" ] || continue
                    used_mb=$(awk -v f="$f" '$1==f {printf "%d", $4/1024}' /proc/swaps)
                    mem_free=$(free -m | awk '/^Mem:/{print $4+0}')
                    if [ "${used_mb:-0}" -gt "${mem_free:-0}" ]; then
                        printf "  ${RED}> %s 已用 %sMB，可用内存 %sMB，无法安全关闭${NC}\n" "$f" "$used_mb" "$mem_free"
                        ok=0
                        break
                    fi
                    swapoff "$f" 2>/dev/null
                    if [ "$f" != "$SWAPFILE" ]; then
                        rm -f "$f"
                        sed -i "\|^${f}|d" /etc/fstab 2>/dev/null
                    fi
                done

                if [ "$ok" -eq 1 ]; then
                    rm -f "$SWAPFILE"
                    created=0
                    if command -v fallocate >/dev/null 2>&1; then
                        fallocate -l "${phy_size}M" "$SWAPFILE" 2>/dev/null && created=1
                    fi
                    if [ "$created" -eq 0 ]; then
                        dd if=/dev/zero of="$SWAPFILE" bs=1M count="$phy_size" 2>/dev/null && created=1
                    fi

                    if [ "$created" -eq 1 ]; then
                        chmod 600 "$SWAPFILE"
                        if mkswap "$SWAPFILE" >/dev/null 2>&1 && swapon -p 100 "$SWAPFILE" 2>/dev/null; then
                            [ -f /etc/fstab ] && cp /etc/fstab /etc/fstab.bak 2>/dev/null
                            if grep -q "^${SWAPFILE}" /etc/fstab 2>/dev/null; then
                                sed -i "s|^${SWAPFILE}.*|${SWAPFILE} none swap sw,pri=100 0 0|" /etc/fstab
                            else
                                echo "${SWAPFILE} none swap sw,pri=100 0 0" >> /etc/fstab
                            fi
                            printf "  ${GREEN}> swapfile 已创建并生效 (${phy_size}MB, priority=100)${NC}\n"
                            REPORT_PHY="${GREEN}${phy_size}MB swapfile${NC}"
                        else
                            printf "  ${RED}> mkswap/swapon 失败${NC}\n"
                            rm -f "$SWAPFILE"
                        fi
                    else
                        printf "  ${RED}> 创建文件失败${NC}\n"
                    fi
                fi
            fi
            ;;
        2)
            for f in $phy_swap_files; do
                [ -f "$f" ] || continue
                used_mb=$(awk -v f="$f" '$1==f {printf "%d", $4/1024}' /proc/swaps)
                mem_free=$(free -m | awk '/^Mem:/{print $4+0}')
                if [ "${used_mb:-0}" -gt "${mem_free:-0}" ]; then
                    printf "  ${RED}> %s 已用 %sMB，可用内存 %sMB，无法安全关闭${NC}\n" "$f" "$used_mb" "$mem_free"
                    continue
                fi
                swapoff "$f" 2>/dev/null
                rm -f "$f"
                sed -i "\|^${f}|d" /etc/fstab 2>/dev/null
                printf "  ${GREEN}> 已删除 %s${NC}\n" "$f"
                REPORT_PHY="${GREEN}已删除 swapfile${NC}"
            done
            ;;
        *)
            ;;
    esac

    # ---------- swappiness 调整（始终显示） ----------
    printf "${CYAN}[ swappiness 调整 ]${NC}\n"
    printf "  当前值: %s，推荐值: %s\n" "$cur_swappiness" "$rec_swappiness"
    printf "  说明：直接回车 = 使用推荐值 %s；输入 0 = 保持当前值 %s\n" "$rec_swappiness" "$cur_swappiness"
    read -p "  请输入 swappiness (0-100) [${rec_swappiness}]: " swp_new

    if [ -z "$swp_new" ]; then
        swp_new=$rec_swappiness
    fi

    if [ "$swp_new" = "0" ]; then
        printf "  ${YELLOW}> 已选择保持当前值 %s，跳过 swappiness 调整${NC}\n" "$cur_swappiness"
    elif ! echo "$swp_new" | grep -qE '^[0-9]+$'; then
        printf "  ${RED}> 输入无效：请输入 0-100 的整数，已跳过${NC}\n"
    elif [ "$swp_new" -gt 100 ]; then
        printf "  ${RED}> 输入过大：swappiness 最大 100，已跳过${NC}\n"
    elif [ "$swp_new" = "$cur_swappiness" ]; then
        printf "  ${YELLOW}> 与当前值相同，无需修改${NC}\n"
    else
        sysctl_set "vm.swappiness" "$swp_new"
        sysctl -p >/dev/null 2>&1
        printf "  ${GREEN}> swappiness 已从 %s 改为 %s${NC}\n" "$cur_swappiness" "$swp_new"
        REPORT_SWP="${GREEN}已设为 ${swp_new}${NC}"
    fi

    # ---------- swappiness 被动统一设置 ----------
    if [ -n "$REPORT_ZRAM" ] || [ -n "$REPORT_PHY" ]; then
        if [ -z "$REPORT_SWP" ]; then
            cur_phy=$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ {s+=$3} END{printf "%d", s/1024}' /proc/swaps 2>/dev/null)
            cur_phy=${cur_phy:-0}
            if [ "$cur_phy" -gt 0 ]; then
                [ "$total_mem" -le 1024 ] && FINAL_SWAPPINESS=60 || FINAL_SWAPPINESS=30
            else
                [ "$total_mem" -le 1024 ] && FINAL_SWAPPINESS=80 || FINAL_SWAPPINESS=60
            fi
            sysctl_set "vm.swappiness" "$FINAL_SWAPPINESS"
            sysctl -p >/dev/null 2>&1
            printf "  ${GREEN}> swappiness 已随配置自动设为 %s${NC}\n" "$FINAL_SWAPPINESS"
        fi
    fi
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
        NEED_DOCKER_UPDATE=0
        NEED_COMPOSE_UPDATE=0
        if [ -n "$LATEST_DOCKER" ] && [ "$DOCKER_VER" != "$LATEST_DOCKER" ]; then
            NEED_DOCKER_UPDATE=1
        fi
        if [ -n "$LATEST_COMPOSE" ] && [ "$COMPOSE_VER" != "$LATEST_COMPOSE" ]; then
            NEED_COMPOSE_UPDATE=1
        fi

        if [ $NEED_DOCKER_UPDATE -eq 1 ] || [ $NEED_COMPOSE_UPDATE -eq 1 ]; then
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
                    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
                    sed -i 's/sleep 20/sleep 0/' /tmp/get-docker.sh
                    sh /tmp/get-docker.sh >/dev/null 2>&1
                    rm -f /tmp/get-docker.sh
                else
                    if [ "$NEED_DOCKER_UPDATE" -eq 0 ] && [ "$NEED_COMPOSE_UPDATE" -eq 1 ]; then
                        printf "  Docker 已是最新，仅更新 Compose...\n"
                        apt-get update -qq >/dev/null 2>&1
                        apt-get install -y docker-compose-plugin >/dev/null 2>&1
                    elif [ "$NEED_DOCKER_UPDATE" -eq 1 ] && [ "$NEED_COMPOSE_UPDATE" -eq 0 ]; then
                        printf "  Compose 已是最新，仅更新 Docker...\n"
                        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
                        sed -i 's/sleep 20/sleep 0/' /tmp/get-docker.sh
                        sh /tmp/get-docker.sh >/dev/null 2>&1
                        rm -f /tmp/get-docker.sh
                    else
                        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
                        sed -i 's/sleep 20/sleep 0/' /tmp/get-docker.sh
                        sh /tmp/get-docker.sh >/dev/null 2>&1
                        rm -f /tmp/get-docker.sh
                    fi
                fi
            fi

            elapsed=$(( $(date +%s) - start_ts ))
            cur_fill=$((elapsed * 27 / 30))
            [ "$cur_fill" -gt 27 ] && cur_fill=27
            [ "$cur_fill" -lt 0 ] && cur_fill=0

            kill "$PROGRESS_PID" 2>/dev/null
            wait "$PROGRESS_PID" 2>/dev/null
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
                progress_finish "$cur_fill"
                hash -r 2>/dev/null
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
    journalctl --vacuum-size=100M
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

# ---------- 汇总内存优化结果到一行 ----------
if [ -n "$REPORT_ZRAM" ] || [ -n "$REPORT_PHY" ] || [ -n "$REPORT_SWP" ]; then
    _mem_parts=""
    [ -n "$REPORT_ZRAM" ] && _mem_parts="zRAM ${REPORT_ZRAM}"
    if [ -n "$REPORT_PHY" ]; then
        [ -n "$_mem_parts" ] && _mem_parts="${_mem_parts} / "
        _mem_parts="${_mem_parts}物理swap ${REPORT_PHY}"
    fi
    if [ -n "$REPORT_SWP" ]; then
        [ -n "$_mem_parts" ] && _mem_parts="${_mem_parts} / "
        _mem_parts="${_mem_parts}swappiness ${REPORT_SWP}"
    fi
    REPORT_MEM="$_mem_parts"
else
    REPORT_MEM=""
fi

printf "\n${GREEN}==================== [ 3. 任务执行汇报 ] ====================${NC}\n"
printf " [系统环境] 操作系统 : ${OS} ${OS_VER}\n"
[ $IS_PVE -eq 1 ] && printf " [运行环境] PVE 宿主 : ${YELLOW}清理已降级保护${NC}\n"
printf " [网络算法] BBR+FQ   : ${REPORT_BBR:-${YELLOW}保持现状${NC}}\n"
printf " [内存优化] 内存配置 : ${REPORT_MEM:-${YELLOW}保持现状${NC}}\n"
printf " [容器部署] Docker   : ${REPORT_DOCKER:-${YELLOW}未安装${NC}}\n"
printf " [系统时区] 时区     : ${REPORT_TZ:-${YELLOW}保持现状${NC}}\n"
printf " [存储守护] 定时清理 : ${REPORT_CRON:-${YELLOW}保持现状${NC}}\n"
printf " [即时清理] 本次清理 : ${REPORT_CLEAN:-${YELLOW}未执行${NC}}\n"
printf "${GREEN}==============================================================${NC}\n"

if [ $NEED_REBOOT -eq 1 ]; then
    printf "\n${RED}============================================================${NC}\n"
    printf "${RED}!! 警告：检测到需要重启才能生效的改动，请执行 [ reboot ] !!${NC}\n"
    [ -n "$REBOOT_REASON" ] && printf "${RED}   原因：${REBOOT_REASON}${NC}\n"
    printf "${RED}============================================================${NC}\n\n"
else
    printf "\n${GREEN}--- 任务完成！本次改动均已生效，无需重启。---${NC}\n\n"
fi