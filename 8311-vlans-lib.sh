#!/bin/sh

# 查找tc命令的完整路径
TC=$(PATH=/usr/sbin:/sbin /usr/bin/which tc)
omci="/usr/bin/omci_pipe.sh"
# tc命令包装函数，用于执行tc命令
tc() {
    $TC "$@"
}

# 从tc命令参数中提取关键信息，构建tc flower选择器
tc_flower_selector() {
    # 提取设备名称（例如：eth0, pmapper1等）
    dev=$(echo "$@" | grep -oE "dev \S+" | head -n1 | cut -d" " -f2)
    # 提取流量方向（egress出站或ingress入站）
    direction=$(echo "$@" | grep -oE  "egress|ingress" | head -n1)
    # 提取handle值（用于标识规则）
    handle=$(echo "$@" | grep -oE "handle \S+" | head -n1 | cut -d" " -f2)
    # 提取协议类型（例如：802.1Q, all等）
    protocol=$(echo "$@" | grep -oE "protocol \S+" | head -n1 | cut -d" " -f2)
    # 提取优先级值
    pref=$(echo "$@" | grep -oE "pref \S+" | head -n1 | cut -d" " -f2)

    # 如果是-devdironly参数，只返回设备和方向信息
    if [ "$1" = "-devdironly" ]; then
        echo "dev $dev $direction"
    else
        # 否则返回完整的flower选择器
        echo "dev $dev $direction handle $handle pref $pref protocol $protocol flower"
    fi
}

# 检查tc规则是否存在
tc_exists() {
   tc filter get "$@" &>/dev/null
}

# 获取tc flower规则
tc_flower_get() {
    tc filter get $(tc_flower_selector "$@")
}

# 检查tc flower规则是否存在
tc_flower_exists() {
    tc_flower_get "$@" &>/dev/null
}

# 删除指定的tc flower规则
tc_flower_del() {
    local selector=$(tc_flower_selector "$@")
    echo del $selector

    # 如果规则存在则删除
    tc_exists "$selector" &&
    tc filter del $selector
}

# 添加tc flower规则
# 如果规则不存在才添加，避免重复规则
tc_flower_add() {
    echo add $@

    tc_flower_exists "$@" ||
    tc filter add "$@"
}

# 替换tc flower规则
# 先尝试删除已存在的规则（忽略错误），然后添加新规则
tc_flower_replace() {
    echo replace $@

    tc filter del $(tc_flower_selector "$@") 2>/dev/null
    tc filter add "$@"
}

# 清除指定设备和方向的所有tc flower规则
tc_flower_clear() {
   local selector=$(tc_flower_selector -devdironly "$@")
   echo del $selector

   tc filter del $selector
}
