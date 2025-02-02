#!/bin/sh

# 配置VLAN修复脚本
# 主要功能：根据检测到的配置，修改VLAN标签，实现单播和多播流量的正确转发

# 配置检测脚本的路径，当配置文件不存在时需要使用
DETECT_CONFIG="/root/8311-detect-config.sh"

# 配置文件路径，如果不存在会自动生成
CONFIG_FILE="/tmp/8311-config.sh"

####################################################
# 导入VLAN库函数
. /root/8311-vlans-lib.sh
omci="/usr/bin/omci_pipe.sh"

### 基础配置
# 单播和多播接口定义
UNICAST_IFACE=eth0_0          # 单播流量接口
MULTICAST_IFACE=eth0_0_2      # 多播流量接口

# 设置配置文件的默认路径
CONFIG_FILE=${CONFIG_FILE:-"/tmp/8311-config.sh"}
DETECT_CONFIG=${DETECT_CONFIG:-"/root/8311-detect-config.sh"}


# 检查配置检测脚本是否存在
if [ ! -x "$DETECT_CONFIG" ]; then
    echo "Required detection script '$DETECT_CONFIG' missing." 2> >(logger -t "8311 vlanfix" -p daemon.err)
    exit 1
fi

# 读取配置文件（如果存在）
STATE_HASH=                # 状态哈希值，用于检测配置是否变化
FIX_ENABLED=              # VLAN修复功能开关
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
if [ -n "$FIX_ENABLED" ] && [ "$FIX_ENABLED" -eq 0 ] 2>/dev/null; then
	exit 69               # 如果VLAN修复被禁用，退出脚本
fi

# 获取当前系统状态的哈希值
NEW_STATE_HASH=$("$DETECT_CONFIG" -H)

# 检查是否需要重新生成配置
CONFIG_RESET=0
if [ ! -f "$CONFIG_FILE" ] || [ "$NEW_STATE_HASH" != "$STATE_HASH" ]; then
    echo "Config file '$CONFIG_FILE' does not exist or state changed, detecting configuration..."

    # 运行检测脚本生成新的配置
    "$DETECT_CONFIG" -c "$CONFIG_FILE" 2> >(logger -t "8311 vlanfix" -p daemon.err)
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Unable to detect configuration." 2> >(logger -t "8311 vlanfix" -p daemon.err)
        exit 1
    fi

    CONFIG_RESET=1    # 标记配置已重置
fi

# 加载配置文件
. "$CONFIG_FILE"

# 再次检查VLAN修复是否被禁用
if [ -n "$FIX_ENABLED" ] && [ "$FIX_ENABLED" -eq 0 ] 2>/dev/null; then
    exit 69
fi

# 验证必要的配置变量是否存在
if [ -z "$INTERNET_VLAN" ] || [ -z "$INTERNET_PMAP" ] || [ -z "$UNICAST_VLAN" ]; then
    echo "Required variables INTERNET_VLAN, INTERNET_PMAP, and UNICAST_VLAN are not properly set." 2> >(logger -t "8311 vlanfix" -p daemon.err)
    exit 1
fi


### 下行流量处理（从OLT到用户）
# 配置Internet PMAP的下行规则
internet_pmap_ds_rules() {
    if [ "$INTERNET_VLAN" -ne 0 ]; then
        # Tag模式，修改VLAN ID
        tc_flower_add dev $INTERNET_PMAP ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $INTERNET_VLAN protocol 802.1Q pass
    else
        # 对于不带标签的流量，移除VLAN标签
        tc_flower_add dev $INTERNET_PMAP ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan pop pass
    fi
}

# 配置Services PMAP的下行规则
services_pmap_ds_rules() {
    # 修改VLAN ID为服务VLAN
    tc_flower_add dev $SERVICES_PMAP ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $SERVICES_VLAN protocol 802.1Q pass
}

# 配置多播接口的下行规则
multicast_iface_ds_rules() {
    # 修改VLAN ID与Serivices PMAP相同和优先级
    tc_flower_add dev $MULTICAST_IFACE egress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $SERVICES_VLAN priority 5 protocol 802.1Q pass
    mvlanset
}
me309create() {
	me309=`$omci md | grep 309 | sed -n 's/\(0x\)/\1/p' | cut -f 3 -d '|' | cut -f 1 -d '(' | head -n 1 | sed s/[[:space:]]//g`
	me309line=`$omci md | grep 309 | wc -l`
	if [ -z "$me309" ] ||  [ "$me309line" != "2" ]; then
		logger -t "[vlan]" "creating me309 ..."
		igmpversion=3
		me309=1
		$omci mec 309 $me309 3 0 1 0 0 32
		$omci meads 309 $me309 10 02
		$omci meads 309 $me309 12 00 00 00 7d
		$omci meads 309 $me309 13 00 00 00 64
		$omci meads 309 $me309 15 01
		$omci mec 310 $me309 0 $me309 64 0 1
		$omci mec 311 $me309 0
		sleep 5
	else
		logger -t "[vlan]" "me309 existed."
		$omci meads 309 $me309 1 0$igmpversion
	fi
}
mvlanset() {
    $me309=1
	if [ "$SERVICES_VLAN" -gt 4094 ] || [ "`echo $SERVICES_VLAN | grep -c '^[1-9][0-9]*$'`" == "0" ]; then
		
			logger -t "[vlan]" "services vlan $SERVICES_VLAN configuration error."
		return
	else
		me309create
	fi
	a309=`printf "%04x" $SERVICES_VLAN`
	b309=`echo $a309 | sed 's/../& /g'`
	match309="04 $b309"
	flag309=`$omci meadg 309 $me309 16 2>&- | cut -f 3 -d '='`
	if [ "$flag309" == "$match309" ]; then
		logger -t "[vlan]" "services vlan rule match."
	else
		logger -t "[vlan]" "services vlan configuring."
		$omci meads 309 $me309 16 $match309
	fi
	if [ -z "$MULTICAST_VLAN" ]; then
		logger -t "[vlan]" "no multicast vlan configed."
		return
	else
		if [ "$MULTICAST_VLAN" -gt 4094 ] || [ "`echo $MULTICAST_VLAN | grep -c '^[1-9][0-9]*$'`" == "0" ]; then
			logger -t "[vlan]" "multicast vlan $MULTICAST_VLAN configuration error."
			return
		fi
	fi
	sa309=`printf "%04x" $MULTICAST_VLAN`
	sb309=`echo $sa309 | sed 's/../& /g'`
	muti_gem_tp_instance=`$omci md | grep "Multicast GEM TP" | sed -n 's/\(0x\)/\1/p' | cut -f 3 -d '|' | cut -f 1 -d '(' | sed s/[[:space:]]//g`
	if [ -n "$muti_gem_tp_instance" ]; then
		gpnctp_ptr=`$omci meadg 281 $muti_gem_tp_instance 1 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | cut -f 1 -d '(' | sed s/[[:space:]]//g`
		muti_port=`$omci meadg 268 0x$gpnctp_ptr 1 | cut -f 3 -d '='`
		logger -t "[vlan]" "got muticast gem tp, muticast port: $muti_port, configuring ..."
		$omci meads 309 $me309 7 40 00 $muti_port $sb309 00 00 00 00 e0 00 01 00 ef ff ff ff 00 00 00 00 00 00
	fi
}

## 应用下行规则
# 配置Internet流量
[ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $INTERNET_PMAP ingress
internet_pmap_ds_rules || { tc_flower_clear dev $INTERNET_PMAP ingress; internet_pmap_ds_rules; }

# 配置服务流量（如果存在Services PMAP）
if [ -n "$SERVICES_PMAP" ]; then
    [ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $SERVICES_PMAP ingress
    services_pmap_ds_rules || { tc_flower_clear dev $SERVICES_PMAP ingress; services_pmap_ds_rules; }
fi

# 配置多播流量（如果存在Services PMAP和多播GEM端口）
if [ -n "$SERVICES_PMAP" ] && [ -n "$MULTICAST_GEM" ] ; then
	[ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $MULTICAST_IFACE egress
    multicast_iface_ds_rules || { tc_flower_clear dev $MULTICAST_IFACE egress; multicast_iface_ds_rules; }
fi


### 上行流量处理（从用户到OLT）
# 配置Internet PMAP的上行规则
internet_pmap_us_rules() {
    if [ "$INTERNET_VLAN" -ne 0 ]; then
        # 对于Tag模式
        # 1. 将Internet VLAN修改为单播VLAN
        tc_flower_add dev $INTERNET_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower vlan_id $INTERNET_VLAN skip_sw action vlan modify id $UNICAST_VLAN protocol 802.1Q pass &&
        # 2. 丢弃其他带VLAN标签的流量
        tc_flower_add dev $INTERNET_PMAP egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw action drop &&
        # 3. 丢弃所有其他流量
        tc_flower_add dev $INTERNET_PMAP egress handle 0x3 protocol all pref 3 flower skip_sw action drop
    else
        # 对于Untag模式
        # 1. 丢弃带VLAN标签的流量
        tc_flower_add dev $INTERNET_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action drop &&
        # 2. 为其他流量添加单播VLAN标签
        tc_flower_add dev $INTERNET_PMAP egress handle 0x2 protocol all pref 2 flower skip_sw action vlan push id $UNICAST_VLAN priority 0 protocol 802.1Q pass
    fi
}

# 配置Services PMAP的上行规则
services_pmap_us_rules() {
    # 如果DEFAULT_SERVICES_VLAN为空，使用UNICAST_VLAN的值
    [ -z "$DEFAULT_SERVICES_VLAN" ] && DEFAULT_SERVICES_VLAN=$UNICAST_VLAN

    # 1. 将本地服务VLAN修改为服务VLAN
    tc_flower_add dev $SERVICES_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower vlan_id $SERVICES_VLAN skip_sw action vlan modify id $DEFAULT_SERVICES_VLAN protocol 802.1Q pass &&
    # 2. 丢弃其他带VLAN标签的流量
    tc_flower_add dev $SERVICES_PMAP egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw action drop &&
    # 3. 丢弃所有其他流量
    tc_flower_add dev $SERVICES_PMAP egress handle 0x3 protocol all pref 3 flower skip_sw action drop
}


# 应用上行规则
# 配置Internet流量
[ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $INTERNET_PMAP egress
internet_pmap_us_rules || { tc_flower_clear dev $INTERNET_PMAP egress; internet_pmap_us_rules; }

# 配置服务流量（如果存在Services PMAP）
if [ -n "$SERVICES_PMAP" ]; then
    [ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $SERVICES_PMAP egress
    services_pmap_us_rules || { tc_flower_clear dev $SERVICES_PMAP egress; services_pmap_us_rules; }
fi

# 清理单播接口的规则
tc_flower_clear dev $UNICAST_IFACE egress
tc_flower_clear dev $UNICAST_IFACE ingress
