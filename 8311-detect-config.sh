#!/bin/sh

# 检测来自OLT的Vlan配置
# 直接从fwenv中读取配置参数

# 初始化配置变量
DEBUG=0                # 调试模式开关
LOG_FILE=             # 日志文件路径
DEBUG_FILE=           # 调试日志文件路径
CONFIG_FILE=          # 配置文件路径
HASH_ONLY=0          # 是否仅生成状态哈希值

# 处理命令行参数
while [ $# -gt 0 ]; do
    case "$1" in
        --logfile|-l)
            LOG_FILE="$2"
            shift
        ;;
        --debug|-d)
            DEBUG=1
        ;;
        --debuglog|-D)
            DEBUG_FILE="$2"
            shift
        ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift
        ;;
        -H|--hash)
            HASH_ONLY=1
        ;;
        --help|-h)
            printf -- 'Usage: %s [options]\n\n' "$0"
            printf -- 'Options:\n'
            printf -- '-H --hash\t\t\tOnly generate state hash. Use to determine if the configuration should be re-detected.\n'
            printf -- '-l --logfile <filename>\t\tFile location to log output (will be overwritten).\n'
            printf -- '-D --debugfile <filename>\tFile location to output debug logging (will be appended to).\n'
            printf -- '-d --debug\t\t\tOutput debug information.\n'
            printf -- '-c --config <filename>\t\tWrite detected configuration to file\n'
            printf -- '-h --help\t\t\tThis help text\n'
            exit 0
        ;;
        *)
            printf "Invalid argument %s passed.  Try --help.\n" "$1"
            exit 1
        ;;
    esac
    shift
done

# 生成系统网络状态的哈希值
hash_state() {
    {
        ip li                  # 列出所有网络接口
        brctl show            # 显示网桥配置
    } | sha256sum | awk '{print $1}'
}

# 生成当前状态的哈希值
STATE_HASH=$(hash_state)
if [ "$HASH_ONLY" -eq 1 ]; then
    echo "$STATE_HASH"
    exit 0
fi

# 禁用配置时写入配置文件
disable_config() {
    echo "# Enable fix_vlans script?" > "$CONFIG_FILE"
    echo "FIX_ENABLED=0" >> "$CONFIG_FILE"

    echo "Config file written to '$CONFIG_FILE'" | logger -t "8311 detect vlan" -p daemon.info
}

# 将检测到的配置写入配置文件
write_config() {
    echo "# Unicast VLAN ID from ISP side" > "$CONFIG_FILE"
    echo "uvlan=$uvlan" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# Mullticast VLAN settings" >> "$CONFIG_FILE"
    echo "mvlansource=$mvlansource" >> "$CONFIG_FILE"
    echo "multicast_vlan=$multicast_vlan" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# VLAN conversion rules" >> "$CONFIG_FILE"
    echo "vlan_trans_rules=$vlan_trans_rules" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# IGMP version" >> "$CONFIG_FILE"
    echo "igmp_version=$igmp_version" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# Debug settings" >> "$CONFIG_FILE"
    echo "vlandebug=$vlandebug" >> "$CONFIG_FILE"
    echo "forceuvlan=$forceuvlan" >> "$CONFIG_FILE"
    echo "forcemerule=$forcemerule" >> "$CONFIG_FILE"
    echo "force_me309=$force_me309" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# State Hash" >> "$CONFIG_FILE"
    echo "STATE_HASH=$STATE_HASH" >> "$CONFIG_FILE"

    echo "Config file written to '$CONFIG_FILE'" | logger -t "8311 detect vlan" -p daemon.info
}

# 日志记录函数
log() {
    if [ -z "$LOG_FILE" ]; then
        tee -a /dev/console | logger -t "8311-dectvlan" -p daemon.info
    elif [ "$1" = "-create" ]; then
        tee -a /dev/console | logger -t "8311-dectvlan" -p daemon.info
    else
        tee -a /dev/console | logger -t "8311-dectvlan" -p daemon.info
    fi
}

# 调试信息记录函数
debug() {
    if [ "$DEBUG" -eq 1 ] && [ -n "$DEBUG_FILE" ]; then
        tee -a "$DEBUG_FILE" >&2
    elif [ -n "$DEBUG_FILE" ]; then
        cat >> "$DEBUG_FILE"
    elif [ "$DEBUG" -eq 1 ]; then
        cat >&2
    else
        cat > /dev/null
    fi
}

echo "=============" | debug
echo "State Hash: $STATE_HASH" | debug
echo | debug

# 检查是否禁用VLAN修复
FIX_ENABLED=$(fw_printenv -n 8311_iopmask 2>/dev/null)
if [ -n "$FIX_ENABLED" ] && [ "$FIX_ENABLED" -eq 0 ] 2>/dev/null; then
    [ -n "$CONFIG_FILE" ] && disable_config
    exit 0
fi

# 从fwenv中读取配置参数
uvlan=$(fw_printenv -n 8311_uvlan 2>/dev/null)
mvlansource=$(fw_printenv -n 8311_mvlansource 2>/dev/null)
multicast_vlan=$(fw_printenv -n 8311_multicast_vlan 2>/dev/null)
vlan_trans_rules=$(fw_printenv -n 8311_vlan_trans_rules 2>/dev/null)
igmp_version=$(fw_printenv -n 8311_igmp_version 2>/dev/null || echo "3")
vlandebug=$(fw_printenv -n 8311_vlandebug 2>/dev/null || echo "1")
forceuvlan=$(fw_printenv -n 8311_forceuvlan 2>/dev/null || echo "0")
forcemerule=$(fw_printenv -n 8311_forcemerule 2>/dev/null || echo "0")
force_me309=$(fw_printenv -n 8311_force_me309 2>/dev/null || echo "0")

# 输出检测到的配置
echo "Unicast VLAN: $uvlan" | log -create
echo "Multicast VLAN Source: $mvlansource" | log
echo "Multicast VLAN: $multicast_vlan" | log
echo "VLAN Trans Rules: $vlan_trans_rules" | log
echo "IGMP Version: $igmp_version" | log
echo "VLAN Debug: $vlandebug" | log
echo "Force UVLAN: $forceuvlan" | log
echo "Force ME Rule: $forcemerule" | log
echo "Force ME309: $force_me309" | log

[ -n "$CONFIG_FILE" ] && write_config
