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

# ------------------------------------------------------------------------------
# 运行前置检查：必须有 root 权限 + 交互式终端
# 非交互执行（curl | bash、ssh host < script）会让所有 read 立即 EOF，
# 默认值接管后即时清理会自动执行，因此在此直接拦截。
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    printf "${RED}错误: 请以 root 权限运行（sudo bash <脚本>）${NC}\n"
    exit 1
fi

if [ ! -t 0 ]; then
    printf "${RED}错误: 本脚本需要交互式终端${NC}\n"
    printf "${YELLOW}提示: 请先下载到本地再执行，不要使用 curl | bash 或重定向输入${NC}\n"
    exit 1
fi

# ------------------------------------------------------------------------------
# 清理策略参数（通用版）
# ------------------------------------------------------------------------------
JOURNAL_MAX_SIZE="10M"
JOURNAL_MAX_TIME=""
CLEAN_PATH="/root/vps99clean-1g.sh"

# 统一清理：临时文件 + 后台进度条
# dash 的 EXIT trap 在 SIGINT 下不保证触发，所以额外接 INT/TERM
cleanup() {
    [ -n "${PROGRESS_PID:-}" ] && kill "$PROGRESS_PID" 2>/dev/null
    if [ -n "${DL_TMPD:-}" ] && [ "$DL_TMPD" != "/tmp" ]; then
        rm -rf "$DL_TMPD" 2>/dev/null
    fi
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
    # 键名里的 . 必须转义，否则会被 sed 当成"任意字符"匹配
    esc=$(printf '%s' "$key" | sed 's/\./\\./g')
    if grep -q "^${esc}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^${esc}[[:space:]]*=.*|${key}=${value}|" /etc/sysctl.conf
    else
        printf '%s=%s\n' "$key" "$value" >> /etc/sysctl.conf
    fi
}

# 等待 dpkg 锁，绝不 kill 正在运行的包管理器
# 旧实现用 pkill -9 强杀 dpkg/apt-get/apt，可能在无人值守升级窗口内
# 打断包数据库写入；cron 场景下每周重复，属于定时炸弹。
# 用子 shell 承载 fd 重定向：exec 重定向失败在某些 sh 下会直接终止脚本。
wait_dpkg_lock() {
    if command -v flock >/dev/null 2>&1; then
        (
            if flock -w 300 8 2>/dev/null; then
                DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold >/dev/null 2>&1
                exit 0
            fi
            exit 1
        ) 8>>/var/lib/dpkg/lock-frontend 2>/dev/null
        return $?
    fi
    # 无 flock 工具时：只清理确认无进程占用的残留锁
    if pgrep -x dpkg >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1; then
        return 1
    fi
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null
    return 0
}

fix_dpkg() {
    if wait_dpkg_lock; then
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold >/dev/null 2>&1
        return 0
    fi
    return 1
}

# 清理模块扩展：1G 硬盘版深度清理
deep_clean() {
    # 文档 / man / 本机终端字体
    rm -rf /usr/share/doc/* 2>/dev/null
    rm -rf /usr/share/man/* 2>/dev/null
    rm -rf /usr/share/consolefonts/* 2>/dev/null

    # i18n 字符集 + locale 定义（保留 UTF-8 / en / zh / i18n 命名）
    find /usr/share/i18n/charmaps -type f ! -name '*UTF-8*' -delete 2>/dev/null
    find /usr/share/i18n/locales -type f ! -name '*en*' ! -name '*zh*' ! -name 'i18n*' -delete 2>/dev/null

    # terminfo（保留常用终端类型，含 tmux / screen 等复用库）
    find /usr/share/terminfo -type f \
        ! -name 'xterm*' ! -name 'linux' ! -name 'screen*' ! -name 'tmux*' \
        ! -name 'vt*' ! -name 'ansi' ! -name 'dumb' ! -name 'rxvt*' \
        ! -name 'alacritty*' ! -name 'foot*' ! -name 'putty*' -delete 2>/dev/null

    # locale 消息目录（保留 en / zh 全系 + 别名）
    if [ -d /usr/share/locale ]; then
        find /usr/share/locale -mindepth 1 -maxdepth 1 \
            ! -name 'en' ! -name 'en_*' ! -name 'zh' ! -name 'zh_*' \
            ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null
    fi

    # 云 VPS 用不到的无线 / 网卡固件
    # 注意：不能用 {a,b,c} 大括号展开，Debian/Ubuntu 的 /bin/sh 是 dash，不支持
    for _fw in netronome sb16 ath10k ath11k iwlwifi bnx2 bnx2x brcm mellanox qcom ti; do
        rm -rf "/usr/lib/firmware/$_fw" 2>/dev/null
    done

    # Python 编译缓存（不写死版本号）
    for _pydir in /usr/lib/python3* /usr/local/lib/python3*; do
        [ -d "$_pydir" ] || continue
        find "$_pydir" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
    done

    # aliyun-assist 旧版本目录（优先保留 symlink 指向的运行版本，失效时取最大版本号）
    if [ -d /usr/local/share/aliyun-assist ]; then
        _aliyun_symlink="/usr/local/share/aliyun-assist/aliyun-service.symlink"
        _aliyun_keep=""
        if [ -L "$_aliyun_symlink" ]; then
            _aliyun_keep=$(basename "$(dirname "$(readlink "$_aliyun_symlink")")" 2>/dev/null)
        fi
        if [ -z "$_aliyun_keep" ]; then
            _aliyun_keep=$(ls -1 /usr/local/share/aliyun-assist/ 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
                | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)
        fi
        # 只有确认是版本号格式才进入删除循环，防止 symlink 内容异常时误删全部
        if [ -n "$_aliyun_keep" ] && echo "$_aliyun_keep" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            for _v in /usr/local/share/aliyun-assist/[0-9]*/; do
                [ -d "$_v" ] || continue
                _vname=$(basename "$_v")
                [ "$_vname" = "$_aliyun_keep" ] && continue
                rm -rf "$_v" 2>/dev/null
            done
        fi
    fi

    # 旧日志（cdt 目录豁免）
    find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) ! -path '/var/log/cdt/*' -delete 2>/dev/null
}

do_clean() {
    if command -v apt >/dev/null 2>&1; then
        # PVE 宿主机不动包管理器：autoremove 可能带走 proxmox 相关依赖，
        # 一旦误删宿主环境恢复成本极高。仅做缓存与日志。
        if [ "$IS_PVE" -eq 0 ]; then
            if fix_dpkg; then
                apt autoremove --purge -y
            fi
            apt clean -y
            apt autoclean -y
        fi
        if command -v journalctl >/dev/null 2>&1; then
            journalctl --rotate
            if [ "$IS_PVE" -eq 1 ] || [ -z "$JOURNAL_MAX_TIME" ]; then
                journalctl --vacuum-size="$JOURNAL_MAX_SIZE"
            else
                journalctl --vacuum-time="$JOURNAL_MAX_TIME"
                journalctl --vacuum-size="$JOURNAL_MAX_SIZE"
            fi
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

    deep_clean
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
    # docker/cli 与 docker-ce 发行包版本同步，比 moby/moby 源码 tag 更贴近实际包版本
    LATEST_DOCKER=$(curl -fsS --connect-timeout 3 --max-time 5 "https://api.github.com/repos/docker/cli/releases/latest" 2>/dev/null | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    LATEST_COMPOSE=$(curl -fsS --connect-timeout 3 --max-time 5 "https://api.github.com/repos/docker/compose/releases/latest" 2>/dev/null | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
}

# 版本比较：$1 是否比 $2 新
# busybox 的 sort 不支持 -V，这里用 awk 生成等长可排序键，任何环境都成立
ver_newer() {
    # 目标版本为空表示无参考值，不升级；
    # 基线为空（如 Docker 已装但 Compose 缺失）视为需要安装/更新
    [ -z "$1" ] && return 1
    [ "$1" = "$2" ] && return 1
    top=$(printf '%s\n%s\n' "$1" "$2" | awk -F. '{ printf "%06d%06d%06d %s\n", $1+0, $2+0, $3+0, $0 }' | sort | tail -1 | cut -d' ' -f2-)
    [ "$top" = "$1" ]
}

# 通过官方 get.docker.com 安装/更新
install_docker_official() {
    DL_TMPD=$(mktemp -d /tmp/vps99.XXXXXX 2>/dev/null)
    # mktemp 失败时退化为 /tmp，但只删文件、不删目录（避免误删整个 /tmp）
    [ -z "$DL_TMPD" ] && DL_TMPD="/tmp"
    DL_LOG="/var/log/vps99-docker-install.log"
    DL_SH="$DL_TMPD/vps99-get-docker.sh"

    if ! curl -fsSL --connect-timeout 5 --max-time 60 https://get.docker.com -o "$DL_SH" 2>/dev/null; then
        rm -f "$DL_SH" 2>/dev/null
        rmdir "$DL_TMPD" 2>/dev/null
        DL_TMPD=""
        return 1
    fi

    # 只清掉"卸载旧版本后等待用户确认"的那一行，不动其它 sleep
    sed -i 's/^[[:space:]]*sleep 20[[:space:]]*$/: sleep 0/' "$DL_SH" 2>/dev/null

    if sh "$DL_SH" >"$DL_LOG" 2>&1; then
        rm -f "$DL_SH" 2>/dev/null
        rmdir "$DL_TMPD" 2>/dev/null
        DL_TMPD=""
        return 0
    fi

    rm -f "$DL_SH" 2>/dev/null
    rmdir "$DL_TMPD" 2>/dev/null
    DL_TMPD=""
    return 2
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

printf " - 系统环境 : ${OS_DISPLAY}  »  ${_cpu_cores}核 %s / ${_mem_size}内存 / ${_disk_size}硬盘\n" "$_cpu_short"

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
[ "$CUR_TZ" = "Asia/Shanghai" ] && printf " - 系统时区 : ${GREEN}Asia/Shanghai${NC}\n" || printf " - 系统时区 : ${YELLOW}%s${NC}\n" "$CUR_TZ"
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
    read -r bbr_confirm
else
    printf "网络算法 : 是否开启 BBR+FQ? [y/N]: "
    read -r bbr_confirm
fi
bbr_confirm=${bbr_confirm:-"n"}

if [ "$bbr_confirm" = "y" ] || [ "$bbr_confirm" = "Y" ]; then
    # 先确认内核真的支持，否则写进配置重启也永远不会生效
    modprobe tcp_bbr >/dev/null 2>&1
    modprobe sch_fq >/dev/null 2>&1
    _cc_avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)

    if echo "$_cc_avail" | grep -qw "bbr"; then
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
            REBOOT_REASON="${REBOOT_REASON:+$REBOOT_REASON }BBR+FQ 未立即生效;"
        fi
    else
        printf "  ${RED}> 当前内核不支持 BBR（可用算法: %s），已跳过${NC}\n" "${_cc_avail:-未知}"
        printf "  ${YELLOW}> OpenVZ / LXC 等共享内核环境无法启用，配置写入也不会生效${NC}\n"
        REPORT_BBR="${RED}内核不支持 BBR${NC}"
    fi
fi

# 4.2 zRAM
if [ $HAS_ZRAM -eq 1 ]; then
    printf "内存优化 : zRAM 已存在，是否覆盖配置? [y/N]: "
    read -r zram_confirm
else
    printf "内存优化 : 是否部署 zRAM? [y/N]: "
    read -r zram_confirm
fi
zram_confirm=${zram_confirm:-"n"}

if [ "$zram_confirm" = "y" ] || [ "$zram_confirm" = "Y" ]; then
    total_mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    [ -z "$total_mem" ] && total_mem=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    [ -z "$total_mem" ] && total_mem=512
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

    ZRAM_OK=0
    if [ "$OS" = "Alpine" ]; then
        if apk add zram-init >/dev/null 2>&1; then
            printf 'load_modules="yes"\nnum_devices="1"\ntype0="swap"\nsize0="%s"\nalgo0="lz4"\n' "$zram_size" > /etc/conf.d/zram-init
            rc-update add zram-init default >/dev/null 2>&1
            rc-service zram-init start >/dev/null 2>&1 && ZRAM_OK=1
        fi
    else
        if DEBIAN_FRONTEND=noninteractive $INSTALL_CMD -o Dpkg::Options::="--force-confold" zram-tools >/dev/null 2>&1; then
            printf 'ALGO=lz4\nSIZE=%s\nPRIORITY=100\n' "$zram_size" > /etc/default/zramswap
            systemctl restart zramswap >/dev/null 2>&1 && ZRAM_OK=1
        fi
    fi

    if [ "$ZRAM_OK" -eq 1 ]; then
        printf "  ${GREEN}> zRAM 已部署 (${zram_size}MB / swappiness=${swap_p})${NC}\n"
        REPORT_ZRAM="${GREEN}已部署 (${zram_size}MB)${NC}"
        if [ "$HAS_ZRAM" -eq 0 ]; then
            NEED_REBOOT=1
            REBOOT_REASON="${REBOOT_REASON:+$REBOOT_REASON }zRAM 服务首次加载需重启;"
        fi
    else
        printf "  ${RED}> zRAM 部署失败（软件包安装或服务启动失败，请检查源与网络）${NC}\n"
        REPORT_ZRAM="${RED}部署失败${NC}"
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
    read -r docker_enter
else
    printf "容器部署 : 未安装，是否管理? [y/N]: "
    read -r docker_enter
fi
docker_enter=${docker_enter:-"n"}

if [ "$docker_enter" = "y" ] || [ "$docker_enter" = "Y" ]; then
    if [ $HAS_DOCKER -eq 1 ]; then
        NEED_DOCKER_UPDATE=0
        NEED_COMPOSE_UPDATE=0
        if [ -n "$LATEST_DOCKER" ] && ver_newer "$LATEST_DOCKER" "$DOCKER_VER"; then
            NEED_DOCKER_UPDATE=1
        fi
        if [ -n "$LATEST_COMPOSE" ] && ver_newer "$LATEST_COMPOSE" "$COMPOSE_VER"; then
            NEED_COMPOSE_UPDATE=1
        fi

        if [ $NEED_DOCKER_UPDATE -eq 1 ] || [ $NEED_COMPOSE_UPDATE -eq 1 ]; then
            printf "           1) 更新  2) 卸载  3) 跳过\n"
            printf "           请选择 [3]: "
            read -r docker_choice
            docker_choice=${docker_choice:-"3"}
        else
            printf "           1) 卸载  2) 跳过\n"
            printf "           请选择 [2]: "
            read -r docker_choice
            docker_choice=${docker_choice:-"2"}
            case "$docker_choice" in
                1) docker_choice="2" ;;
                *) docker_choice="3" ;;
            esac
        fi
    else
        printf "           1) 安装  2) 跳过\n"
        printf "           请选择 [2]: "
        read -r docker_choice
        docker_choice=${docker_choice:-"2"}
    fi

    case "$docker_choice" in
        1)
            printf "  正在安装/更新 Docker & Compose，请稍候...\n"
            start_ts=$(date +%s)
            progress_slow &
            PROGRESS_PID=$!

            if [ "$OS" = "Debian" ]; then
                fix_dpkg >/dev/null 2>&1
            fi
            if [ "$OS" = "Alpine" ]; then
                apk add docker docker-cli-compose >/dev/null 2>&1
                rc-update add docker default >/dev/null 2>&1
                rc-service docker start >/dev/null 2>&1
            else
                if [ $HAS_DOCKER -eq 0 ]; then
                    install_docker_official
                    case $? in
                        0) : ;;
                        1) printf "  ${RED}> 下载 Docker 安装脚本失败，请检查网络${NC}\n"
                           REPORT_DOCKER="${RED}安装失败（下载失败）${NC}" ;;
                        *) printf "  ${RED}> Docker 安装脚本执行失败${NC}\n"
                           printf "  ${YELLOW}> 详细日志: /var/log/vps99-docker-install.log${NC}\n"
                           REPORT_DOCKER="${RED}安装失败（脚本报错）${NC}" ;;
                    esac
                else
                    if [ "$NEED_DOCKER_UPDATE" -eq 0 ] && [ "$NEED_COMPOSE_UPDATE" -eq 1 ]; then
                        printf "  Docker 已是最新，仅更新 Compose...\n"
                        if apt-get update -qq >/dev/null 2>&1 && apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
                            :
                        else
                            printf "  ${RED}> Compose 更新失败，请检查网络与软件源${NC}\n"
                            REPORT_DOCKER="${RED}更新失败（Compose）${NC}"
                        fi
                    elif [ "$NEED_DOCKER_UPDATE" -eq 1 ] && [ "$NEED_COMPOSE_UPDATE" -eq 0 ]; then
                        printf "  Compose 已是最新，仅更新 Docker...\n"
                        install_docker_official
                        case $? in
                            0) : ;;
                            1) printf "  ${RED}> 下载 Docker 安装脚本失败，请检查网络${NC}\n"
                               REPORT_DOCKER="${RED}更新失败（下载失败）${NC}" ;;
                            *) printf "  ${RED}> Docker 安装脚本执行失败${NC}\n"
                               printf "  ${YELLOW}> 详细日志: /var/log/vps99-docker-install.log${NC}\n"
                               REPORT_DOCKER="${RED}更新失败（脚本报错）${NC}" ;;
                        esac
                    else
                        install_docker_official
                        case $? in
                            0) : ;;
                            1) printf "  ${RED}> 下载 Docker 安装脚本失败，请检查网络${NC}\n"
                               REPORT_DOCKER="${RED}更新失败（下载失败）${NC}" ;;
                            *) printf "  ${RED}> Docker 安装脚本执行失败${NC}\n"
                               printf "  ${YELLOW}> 详细日志: /var/log/vps99-docker-install.log${NC}\n"
                               REPORT_DOCKER="${RED}更新失败（脚本报错）${NC}" ;;
                        esac
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
    read -r tz_confirm
else
    printf "系统时区 : 是否设置为 Asia/Shanghai? [y/N]: "
    read -r tz_confirm
fi
tz_confirm=${tz_confirm:-"n"}

if [ "$tz_confirm" = "y" ] || [ "$tz_confirm" = "Y" ]; then
    TZ_OK=0
    if [ "$OS" = "Alpine" ]; then
        apk add tzdata >/dev/null 2>&1
        if cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null; then
            printf 'Asia/Shanghai\n' > /etc/timezone
            TZ_OK=1
        fi
    else
        if ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null; then
            printf 'Asia/Shanghai\n' > /etc/timezone
            TZ_OK=1
        fi
    fi

    if [ "$TZ_OK" -eq 1 ]; then
        printf "  ${GREEN}> 时区已设置为 Asia/Shanghai${NC}\n"
        REPORT_TZ="${GREEN}Asia/Shanghai${NC}"
    else
        printf "  ${RED}> 时区设置失败（时区数据缺失或权限不足）${NC}\n"
        REPORT_TZ="${RED}设置失败${NC}"
    fi
fi

# 4.5 存储守护
if [ $HAS_CRON -eq 1 ]; then
    printf "存储守护 : 已存在，是否重写配置? [y/N]: "
    read -r cron_confirm
else
    printf "存储守护 : 是否部署定时清理 (每周一 06:06)? [y/N]: "
    read -r cron_confirm
fi
cron_confirm=${cron_confirm:-"n"}

if [ "$cron_confirm" = "y" ] || [ "$cron_confirm" = "Y" ]; then
    if ! command -v crontab >/dev/null 2>&1; then
        printf "  ${RED}> 未找到 crontab 命令，无法部署定时任务${NC}\n"
        if [ "$OS" = "Alpine" ]; then
            printf "  ${YELLOW}> Alpine 请先执行: apk add cronie && rc-update add crond default && rc-service crond start${NC}\n"
        else
            printf "  ${YELLOW}> 请先安装 cron 服务（如 apt install cron）${NC}\n"
        fi
        REPORT_CRON="${RED}未部署（缺少 crontab）${NC}"
    else
        cat > "$CLEAN_PATH" <<'CLEANEOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

JOURNAL_MAX_SIZE="@JOURNAL_MAX_SIZE@"
JOURNAL_MAX_TIME="@JOURNAL_MAX_TIME@"

IS_PVE=0
if command -v pveversion >/dev/null 2>&1; then
    IS_PVE=1
fi

# 等待 dpkg 锁，绝不 kill 正在运行的包管理器
wait_dpkg_lock() {
    if command -v flock >/dev/null 2>&1; then
        (
            if flock -w 300 8 2>/dev/null; then
                DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold >/dev/null 2>&1
                exit 0
            fi
            exit 1
        ) 8>>/var/lib/dpkg/lock-frontend 2>/dev/null
        return $?
    fi
    if pgrep -x dpkg >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1; then
        return 1
    fi
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null
    return 0
}

if command -v apt >/dev/null 2>&1; then
    if [ "$IS_PVE" -eq 0 ]; then
        if wait_dpkg_lock; then
            DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold >/dev/null 2>&1
            apt autoremove --purge -y >/dev/null 2>&1
        fi
        apt clean -y >/dev/null 2>&1
        apt autoclean -y >/dev/null 2>&1
    fi
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --rotate >/dev/null 2>&1
        if [ "$IS_PVE" -eq 1 ] || [ -z "$JOURNAL_MAX_TIME" ]; then
            journalctl --vacuum-size="$JOURNAL_MAX_SIZE" >/dev/null 2>&1
        else
            journalctl --vacuum-time="$JOURNAL_MAX_TIME" >/dev/null 2>&1
            journalctl --vacuum-size="$JOURNAL_MAX_SIZE" >/dev/null 2>&1
        fi
    fi
elif command -v apk >/dev/null 2>&1; then
    apk cache clean >/dev/null 2>&1
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

# 清理模块扩展：1G 硬盘版深度清理
deep_clean() {
    # 文档 / man / 本机终端字体
    rm -rf /usr/share/doc/* 2>/dev/null
    rm -rf /usr/share/man/* 2>/dev/null
    rm -rf /usr/share/consolefonts/* 2>/dev/null

    # i18n 字符集 + locale 定义（保留 UTF-8 / en / zh / i18n 命名）
    find /usr/share/i18n/charmaps -type f ! -name '*UTF-8*' -delete 2>/dev/null
    find /usr/share/i18n/locales -type f ! -name '*en*' ! -name '*zh*' ! -name 'i18n*' -delete 2>/dev/null

    # terminfo（保留常用终端类型，含 tmux / screen 等复用库）
    find /usr/share/terminfo -type f \
        ! -name 'xterm*' ! -name 'linux' ! -name 'screen*' ! -name 'tmux*' \
        ! -name 'vt*' ! -name 'ansi' ! -name 'dumb' ! -name 'rxvt*' \
        ! -name 'alacritty*' ! -name 'foot*' ! -name 'putty*' -delete 2>/dev/null

    # locale 消息目录（保留 en / zh 全系 + 别名）
    if [ -d /usr/share/locale ]; then
        find /usr/share/locale -mindepth 1 -maxdepth 1 \
            ! -name 'en' ! -name 'en_*' ! -name 'zh' ! -name 'zh_*' \
            ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null
    fi

    # 云 VPS 用不到的无线 / 网卡固件
    # 注意：不能用 {a,b,c} 大括号展开，Debian/Ubuntu 的 /bin/sh 是 dash，不支持
    for _fw in netronome sb16 ath10k ath11k iwlwifi bnx2 bnx2x brcm mellanox qcom ti; do
        rm -rf "/usr/lib/firmware/$_fw" 2>/dev/null
    done

    # Python 编译缓存（不写死版本号）
    for _pydir in /usr/lib/python3* /usr/local/lib/python3*; do
        [ -d "$_pydir" ] || continue
        find "$_pydir" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
    done

    # aliyun-assist 旧版本目录（优先保留 symlink 指向的运行版本，失效时取最大版本号）
    if [ -d /usr/local/share/aliyun-assist ]; then
        _aliyun_symlink="/usr/local/share/aliyun-assist/aliyun-service.symlink"
        _aliyun_keep=""
        if [ -L "$_aliyun_symlink" ]; then
            _aliyun_keep=$(basename "$(dirname "$(readlink "$_aliyun_symlink")")" 2>/dev/null)
        fi
        if [ -z "$_aliyun_keep" ]; then
            _aliyun_keep=$(ls -1 /usr/local/share/aliyun-assist/ 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
                | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)
        fi
        # 只有确认是版本号格式才进入删除循环，防止 symlink 内容异常时误删全部
        if [ -n "$_aliyun_keep" ] && echo "$_aliyun_keep" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            for _v in /usr/local/share/aliyun-assist/[0-9]*/; do
                [ -d "$_v" ] || continue
                _vname=$(basename "$_v")
                [ "$_vname" = "$_aliyun_keep" ] && continue
                rm -rf "$_v" 2>/dev/null
            done
        fi
    fi

    # 旧日志（cdt 目录豁免）
    find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) ! -path '/var/log/cdt/*' -delete 2>/dev/null
}

deep_clean
CLEANEOF
        sed -i "s|@JOURNAL_MAX_SIZE@|${JOURNAL_MAX_SIZE}|g; s|@JOURNAL_MAX_TIME@|${JOURNAL_MAX_TIME}|g" "$CLEAN_PATH"
        chmod +x "$CLEAN_PATH"
        if (crontab -l 2>/dev/null | grep -v "$CLEAN_PATH"; printf '6 6 * * 1 %s > /dev/null 2>&1\n' "$CLEAN_PATH") | crontab - 2>/dev/null; then
            if crontab -l 2>/dev/null | grep -q "$CLEAN_PATH"; then
                printf "  ${GREEN}> 存储守护已部署 (每周一 06:06)${NC}\n"
                REPORT_CRON="${GREEN}已部署 (每周一 06:06)${NC}"
            else
                printf "  ${RED}> 写入 crontab 后回读校验失败${NC}\n"
                REPORT_CRON="${RED}部署失败${NC}"
            fi
        else
            printf "  ${RED}> 写入 crontab 失败（cron 服务可能未安装）${NC}\n"
            REPORT_CRON="${RED}部署失败${NC}"
        fi

        if [ "$OS" = "Alpine" ]; then
            pgrep -x crond >/dev/null 2>&1 || printf "  ${YELLOW}> 注意: crond 未运行，任务不会触发（rc-service crond start）${NC}\n"
        else
            if ! systemctl is-active --quiet cron 2>/dev/null && ! systemctl is-active --quiet crond 2>/dev/null; then
                printf "  ${YELLOW}> 注意: cron 服务未运行，任务不会触发（systemctl enable --now cron）${NC}\n"
            fi
        fi
    fi
fi

# 4.6 即时清理
printf "即时清理 : 是否立即执行一次系统清理? [Y/n]: "
read -r clean_confirm
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
