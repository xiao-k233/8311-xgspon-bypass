#!/bin/sh
# shellcheck source=/dev/null
# shellcheck disable=SC3001
# VLAN修复脚本
# 主要功能：根据检测到的配置，使用omci配置VLAN和组播规则，从vlanexec.sh移植

# =====================================================
# 脚本全局配置
# =====================================================


# 添加锁文件，用于并发控制
LOCK_FILE="/var/lock/8311-fix-vlans.lock"

# OMCI相关命令
omci="/usr/bin/omci_pipe.sh"

# 全局变量
initflag=0
totalizerflag=0
stateflag=0
vlandebug=1
# =====================================================
# 并发控制函数
# =====================================================

# 获取锁，防止多个实例同时运行
acquire_lock() {
    # 创建锁文件，如果创建失败会返回非零值
    if [ -e "$LOCK_FILE" ]; then
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            logger -t "8311-fixvlan" -p daemon.info "脚本已在运行，进程ID: $pid"
            return 1
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    return 0
}

# 释放锁
release_lock() {
    if [ -e "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
    fi
}

# =====================================================
# 工具函数
# =====================================================

# 检查ONU状态是否为O5（正常运行状态）
check_onu_state() {
    # 使用与8311.lua相同的方式获取PLOAM状态
    ploamstate=$(pon psg | grep -o "current=[0-9]\+" | cut -d= -f2)
    
    # 检查是否为O5状态(50)
    # [50]	= "O5, Operation state",
    if [ "$ploamstate" != "50" ]; then
        return 1
    fi
    return 0
}



# 验证VLAN ID是否有效，更严格的VLAN ID检查
validate_vlan_id() {
    vlan_id=$1
    
    # 检查特殊值"u"（表示无标签）
    if [ "$vlan_id" = "u" ]; then
        return 0
    fi
    
    # 检查是否是合法的数字
    if ! echo "$vlan_id" | grep -qE '^[1-9][0-9]*$'; then
        logger -t "8311-fixvlan" -p daemon.info "无效的VLAN ID格式: $vlan_id - 必须是正整数"
        return 1
    fi
    
    # 检查范围是否在1-4094之间
    if [ "$vlan_id" -lt 1 ] || [ "$vlan_id" -gt 4094 ]; then
        logger -t "8311-fixvlan" -p daemon.info "VLAN ID超出范围: $vlan_id - 必须在1-4094之间"
        return 1
    fi
    
    return 0
}

# =====================================================
# OMCI配置函数
# =====================================================

# 重置参数
resetparameter() {
    initflag=0
    totalizerflag=0
    stateflag=0
    vlanflag=0
    uvlandata=`ls /tmp | grep uvlandata 2>/dev/null`
    if [ -n "$uvlandata" ]; then
        rm -f /tmp/uvlandata
    fi
    mvlandata=`ls /tmp | grep mvlandata 2>/dev/null`
    if [ -n "$mvlandata" ]; then
        rm -f /tmp/mvlandata
    fi
    mvlansourcedata=`ls /tmp | grep mvlansourcedata 2>/dev/null`
    if [ -n "$mvlansourcedata" ]; then
        rm -f /tmp/mvlansourcedata
    fi
    mibcounter=`ls /tmp | grep mibcounter 2>/dev/null`
    if [ -n "$mibcounter" ]; then
        rm -f /tmp/mibcounter
    fi
    tvlannum=`echo "$tvlan" | grep -o ":" | grep -c ":" 2>/dev/null || echo 0`
    tvlanseq=0
    for i in `seq 1 $tvlannum`
    do
        tvlanseqa=`expr $i \+ $tvlanseq`
        tvlanseq=$i
        tvlanseqb=`expr $i \+ $tvlanseq`
        vlantransdata=`ls /tmp | grep vlan$tvlanseqa 2>/dev/null || ls /tmp | grep vlan$tvlanseqb 2>/dev/null`
        if [ -n "$vlantransdata" ]; then
            rm -f /tmp/vlan$tvlanseqa
            rm -f /tmp/vlan$tvlanseqb
        fi
    done
}

# 确定OLT类型
olttype() {
    for i in `seq 1 30`
    do
        olt_type=`$omci meadg 131 0 1 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
        spanning_tree=`$omci meadg 45 1 1 | sed -n 's/\(attr\_data\=\)/\1/p' | sed s/[[:space:]]//g`
        if [ "$olt_type" != "20202020" ] && [ -n "$spanning_tree" ]; then
            break
        else
            logger -t "[vlanexec]" "olt type and spanning tree not detected, waiting ..."
            sleep 2
        fi
    done
    echo "olt type:$olt_type" > /tmp/collect
}

# ME47 PPTP UNI Bridge创建
me47pptpunibridge() {
    me47_instance_number=`$omci md | grep "Bridge port config data" | sed -n 's/\(0x\)/\1/p' | cut -f 3 -d '|' | cut -f 1 -d '(' | sed s/[[:space:]]//g`
    spanning_tree=`$omci meadg 45 1 1 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
    if [ -n "$vlandebug" ]; then
        logger -t "8311-fixvlan" -p daemon.info "me47_instance_number: `echo $me47_instance_number`"
    fi
    for i in `echo $me47_instance_number`
    do
        me47_tptype=`$omci meadg 47 $i 3 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
        me47_tpptr=`$omci meadg 47 $i 4 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
        if [ "$me47_tptype" == "01" ] && [ "$me47_tpptr" == "0101" ]; then
            if [ -n "$vlandebug" ]; then
                logger -t "8311-fixvlan" -p daemon.info "pptp uni bridge port: $i existed."
            fi
            pptp_uni_bridge=$i
            $omci meads 47 $i 3 1
            $omci meads 47 $i 4 01 01
            $omci meads 47 $i 7 $spanning_tree
            return
        fi
    done
    me47_tptype=`$omci meadg 47 1 3 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
    if [ -n "$me47_tptype" ]; then
        $omci med 47 1
    fi
    bridge_instance=`$omci md | grep "Bridge config data" | sed -n 's/\(0x\)/\1/p' | cut -f 3 -d '|' | cut -f 1 -d '(' | tail -n 1 | sed s/[[:space:]]//g`
    if [ -n "$vlandebug" ]; then
        logger -t "8311-fixvlan" -p daemon.info "no pptp uni bridge port, creating it and instance is fixed 1."
    fi
    $omci mec 47 1 $bridge_instance 1 1 257 0 1 ${spanning_tree:1:2} 1 1
    pptp_uni_bridge=1
}

# ME171 创建
me171create() {
    createflag=$1
    me171=`$omci md | grep "Extended VLAN conf data" | sed -n 's/\(0x\)/\1/p' | cut -f 3 -d '|' | cut -f 1 -d '(' | head -n 1 | sed s/[[:space:]]//g`
    me171_line=`$omci md | grep "Extended VLAN conf data" | wc -l`
    if [ $me171_line -gt 1 ]; then
        for i in `echo $me171`
        do
            Associated_ME_ptr=`$omci meadg 171 $i 7 | sed -n 's/\(attr\_data\=\)/\1/p' | sed s/[[:space:]]//g`
            if [ "$Associated_ME_ptr" = "0101" ]; then
                me171=$i
                if [ -n "$vlandebug" ]; then
                    logger -t "8311-fixvlan" -p daemon.info "me171 value: $me171"
                fi
                break
            fi
        done
    fi
    me47_instance=$pptp_uni_bridge
    case $createflag in
        0)  if [ -z "$me171" ] && [ -n "$vlandebug" ]; then
                logger -t "8311-fixvlan" -p daemon.info "me171 value should not be null."
            fi
        ;;
        1)  if [ -z "$me171" ]; then
                # 直接使用omci命令创建和配置ME171，而不是通过omci_simulate
                me171=$me47_instance
                bridge_instance_hex=`printf "%04x" $me47_instance`
                
                # 创建ME171实例
                $omci mec 171 $me171 $me47_instance 1 0 0 0 0 0 0
                
                # 配置VLAN标签处理方式
                $omci meads 171 $me171 3 81 00 81 00 00 00 00 00 00 00 00 00 00 00 00 00
                
                # 设置默认VLAN规则
                $omci meads 171 $me171 6 f8 00 00 00 f8 00 00 00 c0 0f 00 00 00 0f 00 00
                
                # 设置关联的ME指针
                $omci meads 171 $me171 7 01 01
                
                # 执行MIB计数器操作
                mecounter
                
                if [ -n "$vlandebug" ]; then
                    logger -t "8311-fixvlan" -p daemon.info "me171 value: $me47_instance, created with direct omci commands"
                fi
            fi
        ;;
        *)  if [ -n "$vlandebug" ]; then
                logger -t "8311-fixvlan" -p daemon.info "create me171 value error."
            fi
        ;;
    esac
}

# ME171规则检查
me171rulecheck() {
    me171_singtag="0xf80x000x000x000xe80x000x000x000x000x0f0x000x000x000x0f0x000x00"
    me171_doubletag="0xe80x000x000x000xe80x000x000x000x000x0f0x000x000x000x0f0x000x00"
    me171_singtagget=`$omci meg 171 $me171 | grep "0xf8 0x00 0x00 0x00 0xe8" | tail -n 1 | sed s/[[:space:]]//g`
    me171_doubletagget=`$omci meg 171 $me171 | grep "0xe8 0x00 0x00 0x00 0xe8" | tail -n 1 | sed s/[[:space:]]//g`
    $omci meg 171 $me171 | sed -n '/^ 5 RX frame VLAN table/,$p' | sed '/^ 6 Associated ME ptr/,$d' | grep '^   0x' | grep -v "0xf8 0x00 0x00 0x00 0xe8" | grep -v "0xe8 0x00 0x00 0x00 0xe8" | sed 's/^   //g' | sed 's/0x//g' > /tmp/me171_rule
    me171_rule_line=`$omci meg 171 1 | sed -n '/^ 5 RX frame VLAN table/,$p' | sed '/^ 6 Associated ME ptr/,$d' | grep '^   0x' | grep -v "0xf8 0x00 0x00 0x00 0xe8" | grep -v "0xf8 0x00 0x00 0x00 0xe8" | wc -l`
    if [ $me171_rule_line -ge 1 ] && [ -n "$vlandebug" ]; then
        for i in `seq 1 $me171_rule_line`
        do
            logger -t "8311-fixvlan" -p daemon.info "me171 rule: `cat /tmp/me171_rule | tail -n $i | head -n 1`"
        done
    fi
    if [ "$me171_singtagget" != "$me171_singtag" ] || [ "$me171_doubletagget" != "$me171_doubletag" ]; then
        if [ -n "$vlandebug" ]; then
            logger -t "8311-fixvlan" -p daemon.info "defualt rule not match, creating ..."
        fi
        $omci meads 171 $me171 6 f8 00 00 00 e8 00 00 00 00 0f 00 00 00 0f 00 00
        $omci meads 171 $me171 6 e8 00 00 00 e8 00 00 00 00 0f 00 00 00 0f 00 00
        if [ $me171_rule_line -ge 1 ]; then
            for i in `seq 1 $me171_rule_line`
            do
                $omci meads 171 $me171 6 `cat /tmp/me171_rule | tail -n $i | head -n 1`
            done
        fi
    fi
}

# MIB计数器处理
mecounter() {
    current=`$omci meadg 2 0 1 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
    current_1=0x$current
    current_2=`printf "0x%x" $current_1`
    current_3=$(awk 'BEGIN{printf("%#x",'$current_2'-3)}')
    current_4=`printf "%x" $current_3`
    $omci meads 2 0 1 $current_4
    if [ -n "$vlandebug" ]; then
        logger -t "8311-fixvlan" -p daemon.info "meconunter: $current_4 ."
    fi
}

# ME309创建
me309create() {
    me309=`$omci md | grep 309 | sed -n 's/\(0x\)/\1/p' | cut -f 3 -d '|' | cut -f 1 -d '(' | head -n 1 | sed s/[[:space:]]//g`
    me309line=`$omci md | grep 309 | wc -l`
    if [ -z "$me309" ] || [ "$me309line" != "2" ] || [ "$force_me309" = "1" ]; then
        if [ -n "$vlandebug" ]; then
            logger -t "8311-fixvlan" -p daemon.info "creating me309 ..."
        fi
        me309=$pptp_uni_bridge
        $omci mec 309 $me309 $igmpversion 0 1 0 0 32
        $omci meads 309 $me309 10 02
        $omci meads 309 $me309 12 00 00 00 7d
        $omci meads 309 $me309 13 00 00 00 64
        $omci meads 309 $me309 15 01
        $omci mec 310 $me309 0 $me309 64 0 1
        $omci mec 311 $me309 0
        sleep 5
    else
        if [ -n "$vlandebug" ]; then
            logger -t "8311-fixvlan" -p daemon.info "me309 rule existed."
        fi
        $omci meads 309 $me309 1 0$igmpversion
    fi
}

# ME规则设置
meruleset() {
    hw="48575443"
    alcl="414c434c"
    zte="5a544547"
    other="20202020"
    if [ "$olt_type" == "20202020" ]; then
        olt_type=`$omci meadg 131 0 1 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
        sed -i '/.*olt\ type*/c\olt\ type:'$olt_type'' /tmp/collect
    fi
    if [ -n "$vlandebug" ]; then
        logger -t "8311-fixvlan" -p daemon.info "olt type:$olt_type"
    fi
    
    # 如果启用了强制设置ME规则选项
    if [ "$forcemerule" = "1" ]; then
        if [ -n "$vlandebug" ]; then
            logger -t "8311-fixvlan" -p daemon.info "强制设置ME规则..."
        fi
        me47pptpunibridge
        me171create 1
        me171rulecheck
        return
    fi
    
    if [ "$olt_type" == "$hw" ]; then
        me47pptpunibridge
        me171create 0
        me171rulecheck
    elif [ "$olt_type" == "$alcl" ]; then
        tptypealcl
        me171create 1
    elif [ "$olt_type" == "$zte" ]; then
        me47pptpunibridge
        me171create 1
    else
        me47pptpunibridge
        me171create 1
    fi
}

# ACLTP类型设置
tptypealcl() {
    me47_instance_number=`$omci md | grep "Bridge port config data" | sed -n 's/\(0x\)/\1/p' | cut -f 3 -d '|' | cut -f 1 -d '(' | sed s/[[:space:]]//g`
    spanning_tree=`$omci meadg 45 1 1 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
    for i in `echo $me47_instance_number`
    do
        me47_tptype=`$omci meadg 47 $i 3 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
        me47_tpptr=`$omci meadg 47 $i 4 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | sed s/[[:space:]]//g`
        if [ "$me47_tptype" == "01" ] && [ "$me47_tpptr" == "0101" ]; then
            if [ -n "$vlandebug" ]; then
                logger -t "8311-fixvlan" -p daemon.info "pptp uni bridge port: $i existed."
            fi
            $omci meads 47 $i 3 1
            $omci meads 47 $i 4 01 01
            $omci meads 47 $i 7 $spanning_tree
            pptp_uni_bridge=$i
            return
        elif [ "$me47_tptype" == "0b" ]; then
            $omci meads 47 $i 3 1
            $omci meads 47 $i 4 01 01
            $omci meads 47 $i 7 $spanning_tree
            pptp_uni_bridge=$i
            return
        fi
    done
}

# =====================================================
# VLAN配置函数
# =====================================================

# 单播VLAN设置
uvlanset() {
    if [ -z "$uvlan" ]; then
        if [ -n "$vlandebug" ]; then
            logger -t "8311-fixvlan" -p daemon.info "no uvlan configed."
        fi
        $omci meads 171 $me171 6 f8 00 00 00 f8 00 00 00 c0 0f 00 00 00 0f 00 00
        return
    fi
    
    # 验证单播VLAN ID
    if [ "$uvlan" != "u" ] && ! validate_vlan_id "$uvlan"; then
        logger -t "8311-fixvlan" -p daemon.info "uvlan $uvlan 配置错误，使用默认配置"
        $omci meads 171 $me171 6 f8 00 00 00 f8 00 00 00 c0 0f 00 00 00 0f 00 00
        return
    fi
    
    if [ "$uvlan" == "u" ]; then
        logger -t "8311-fixvlan" -p daemon.info "untagged configed."
        match171="f8 00 00 00 f8 00 00 00 00 0f 00 00 00 0f 00 00"
    else
        tmp171=`expr $uvlan \* 8 + 4`
        a171=`printf "%04x" $tmp171`
        b171=`echo $a171 | sed 's/../& /g'`
        match171="f8 00 00 00 f8 00 00 00 00 0f 80 00 00 00 $b171"
    fi
    word_171=`echo $match171 | sed s/[[:space:]]//g | sed -r 's/(..)/0x\1/g' | sed -r 's/(....)/ \1/g'`
    flag171=`$omci meg 171 $me171 | grep "$word_171"`
    if [ -n "$flag171" ] && [ "$forceuvlan" != "1" ]; then
        if [ -n "$vlandebug" ]; then
            logger -t "8311-fixvlan" -p daemon.info "uvlan rule match."
        fi
    else
        if [ -n "$vlandebug" ]; then
            if [ "$forceuvlan" = "1" ]; then
                logger -t "8311-fixvlan" -p daemon.info "强制设置uvlan ..."
            else
                logger -t "8311-fixvlan" -p daemon.info "uvlan configuring ..."
            fi
        fi
        $omci meads 171 $me171 6 $match171
    fi
}

# 多播VLAN设置
mvlanset() {
    if [ -z "$mvlan" ]; then
        if [ -n "$vlandebug" ]; then
            logger -t "8311-fixvlan" -p daemon.info "no mvlan configed."
        fi
        return
    fi
    
    # 验证多播VLAN ID
    if ! validate_vlan_id "$mvlan"; then
        logger -t "8311-fixvlan" -p daemon.info "mvlan $mvlan 配置错误"
        return
    fi
    
    me309create
    
    a309=`printf "%04x" $mvlan`
    b309=`echo $a309 | sed 's/../& /g'`
    match309="04 $b309"
    flag309=`$omci meadg 309 $me309 16 2>&- | cut -f 3 -d '='`
    if [ "$flag309" == "$match309" ]; then
        if [ -n "$vlandebug" ]; then
            logger -t "8311-fixvlan" -p daemon.info "mvlan rule match."
        fi
    else
        if [ -n "$vlandebug" ]; then
            logger -t "8311-fixvlan" -p daemon.info "mvlan configuring."
        fi
        $omci meads 309 $me309 16 $match309
    fi
    
    # 验证多播VLAN转换ID
    if [ -n "$mtvlan" ]; then
        if ! validate_vlan_id "$mtvlan"; then
            logger -t "8311-fixvlan" -p daemon.info "mtvlan $mtvlan 配置错误"
            return
        fi
        
        sa309=`printf "%04x" $mtvlan`
        sb309=`echo $sa309 | sed 's/../& /g'`
        muti_gem_tp_instance=`$omci md | grep "Multicast GEM TP" | sed -n 's/\(0x\)/\1/p' | cut -f 3 -d '|' | cut -f 1 -d '(' | sed s/[[:space:]]//g`
        if [ -n "$muti_gem_tp_instance" ]; then
            gpnctp_ptr=`$omci meadg 281 $muti_gem_tp_instance 1 | sed -n 's/\(attr\_data\=\)/\1/p' | cut -f 3 -d '=' | cut -f 1 -d '(' | sed s/[[:space:]]//g`
            muti_port=`$omci meadg 268 0x$gpnctp_ptr 1 | cut -f 3 -d '='`
            if [ -n "$vlandebug" ]; then
                logger -t "8311-fixvlan" -p daemon.info "got muticast gem tp, muticast port: $muti_port, configuring ..."
            fi
            $omci meads 309 $me309 7 40 00 $muti_port $sb309 00 00 00 00 e0 00 01 00 ef ff ff ff 00 00 00 00 00 00
        fi
    elif [ -n "$vlandebug" ]; then
        logger -t "8311-fixvlan" -p daemon.info "no mtvlan configed."
    fi
}

# 删除VLAN转换规则
deletetrans() {
    filter_inner_1=`expr $1 \* 8`
    filter_inner_2=`printf "%04x" $filter_inner_1`
    patten="0"
    filter_inner_3="8$filter_inner_2$patten"
    word2=`echo $filter_inner_3 | sed 's/../& /g'`
    wordset="f8 00 00 00 $word2 00 ff ff ff ff ff ff ff ff"
    logger -t "[vlanexec]" "Deleting vlantrans rule $1"
    $omci meads 171 $me171 6 $wordset
}

# VLAN转换规则设置
vlantransset() {
    tvlannum=`echo "$tvlan" | grep -o ":" | grep -c ":" 2>/dev/null || echo 0`
    for i in `seq 1 $tvlannum`
    do
        vlana=`echo $tvlan | cut -f $i -d ',' | cut -f 1 -d ':' | cut -f 1 -d '@'`
        vlanb=`echo $tvlan | cut -f $i -d ',' | cut -f 2 -d ':' | cut -f 1 -d '@'`
        prioritya=`echo $tvlan | cut -f $i -d ',' | cut -f 1 -d ':' | grep '@'  | cut -f 2 -d "@"`
        priorityb=`echo $tvlan | cut -f $i -d ',' | cut -f 2 -d ':' | grep '@'  | cut -f 2 -d "@"`
        
        # 验证VLAN转换规则
        if [ -z "$vlana" ] || [ -z "$vlanb" ]; then
            logger -t "8311-fixvlan" -p daemon.info "vlantrans$i 格式错误：源或目标VLAN为空"
            continue
        fi
        
        # 验证源VLAN ID
        if ! validate_vlan_id "$vlana"; then
            logger -t "8311-fixvlan" -p daemon.info "vlantrans$i 源VLAN ID无效: $vlana"
            continue
        fi
        
        # 验证目标VLAN ID（可以是"u"或有效的VLAN ID）
        if [ "$vlanb" != "u" ] && ! validate_vlan_id "$vlanb"; then
            logger -t "8311-fixvlan" -p daemon.info "vlantrans$i 目标VLAN ID无效: $vlanb"
            continue
        fi
        
        # 验证优先级
        if [ -n "$prioritya" ] && ([ "$prioritya" -lt 0 ] || [ "$prioritya" -gt 7 ]); then
            logger -t "8311-fixvlan" -p daemon.info "vlantrans$i 源优先级无效: $prioritya (应为0-7)"
            continue
        fi
        
        if [ -n "$priorityb" ] && ([ "$priorityb" -lt 0 ] || [ "$priorityb" -gt 7 ]); then
            logger -t "8311-fixvlan" -p daemon.info "vlantrans$i 目标优先级无效: $priorityb (应为0-7)"
            continue
        fi
        
        if [ -z "$prioritya" ]; then
            prioritya=8
        fi
        if [ -z "$priorityb" ]; then
            priorityb=8
        fi
        
        filter_inner_1=`expr $vlana \* 8`
        filter_inner_2=`printf "%04x" $filter_inner_1`
        patten="0"
        filter_inner_3="$prioritya$filter_inner_2$patten"
        word2=`echo $filter_inner_3 | sed 's/../& /g'`
        treate_inner_1=`expr $vlanb \* 8`
        treate_inner_2=`printf "%04x" $treate_inner_1`
        treate_inner_3=`echo $treate_inner_2 | sed 's/../& /g'`
        word4="00 0$priorityb $treate_inner_3"
        if [ "$vlanb" == "u" ]; then
            word4="0x00 0x0f 0x00 0x00"
        fi
        wordset="f8 00 00 00 $word2 00 40 0f 00 00 $word4"
        word_c=`echo $wordset | sed s/[[:space:]]//g | sed -r 's/(..)/0x\1/g' | sed -r 's/(....)/ \1/g'`
        wordget=`$omci meg 171 $me171 | grep "$word_c"`
        if [ -n "$wordget" ]; then
            if [ -n "$vlandebug" ]; then
                logger -t "8311-fixvlan" -p daemon.info "vlantrans$i $vlana:$vlanb rule match."
            fi
        else
            if [ -n "$vlandebug" ]; then
                logger -t "8311-fixvlan" -p daemon.info "vlantrans$i $vlana:$vlanb configuring ..."
            fi
            $omci meads 171 $me171 6 $wordset
        fi
    done
}

# =====================================================
# 主程序
# =====================================================

# 获取锁，防止多个实例同时运行
if ! acquire_lock; then
    logger -t "8311-fixvlan" -p daemon.info "另一个脚本实例正在运行，退出"
    exit 2
fi

# 退出时释放锁
trap release_lock EXIT INT TERM


# ========================================
# 干掉dect，直接读取vlan
# ========================================

uvlan=$(fw_printenv -n 8311_uvlan 2>/dev/null)
mvlansource=$(fw_printenv -n 8311_mvlansource 2>/dev/null)
multicast_vlan=$(fw_printenv -n 8311_multicast_vlan 2>/dev/null)
vlan_trans_rules=$(fw_printenv -n 8311_vlan_trans_rules 2>/dev/null)
igmp_version=$(fw_printenv -n 8311_igmp_version 2>/dev/null || echo "3")
vlandebug=$(fw_printenv -n 8311_vlandebug 2>/dev/null || echo "1")
forceuvlan=$(fw_printenv -n 8311_forceuvlan 2>/dev/null || echo "0")
forcemerule=$(fw_printenv -n 8311_forcemerule 2>/dev/null || echo "0")
force_me309=$(fw_printenv -n 8311_force_me309 2>/dev/null || echo "0")

# 将配置变量映射到vlanexec.sh使用的变量名
uvlan=${uvlan:-}
mvlan=${multicast_vlan:-}
mtvlan=${mvlansource:-}
tvlan=${vlan_trans_rules:-}
igmpversion=${igmp_version:-3}

# 其他配置变量
force_me309=${force_me309:-0}
vlandebug=${vlandebug:-1}
forceuvlan=${forceuvlan:-0}
forcemerule=${forcemerule:-0}

# 验证ONU状态，如果不是O5状态则退出
if ! check_onu_state; then
    logger -t "8311-fixvlan" -p daemon.info "Exiting: ONU not in O5 state"
    exit 0
fi

# 初始化并配置VLAN规则
logger -t "8311-fixvlan" -p daemon.info "Starting VLAN configuration..."

# 重置参数
resetparameter

# 确定OLT类型并进行配置
olttype
meruleset
uvlanset
mvlanset
vlantransset

logger -t "8311-fixvlan" -p daemon.info "VLAN configuration completed"
exit 0
