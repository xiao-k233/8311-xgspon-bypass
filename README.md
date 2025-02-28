# 8311 XGS-PON Bypass
8311社区固件负责处理vlan相关的脚本，相较于2.5g猫棒，新版的prx126方案的soc与linux集成度更高，改用tc处理
目前fork有如下区别
 - 换用在UNICAST_IFACE上处理，更适合中国运营商瞎几把改的体制
 - 更多更详细注释，便于社区贡献
 - 需要在hook脚本进行手动声明上网VLAN，因为我不会写luci XD
## 8311-detect-config.sh
This is a helper script for fix-bell-vlans that will help detect the ISP configuration.
```
Usage: ./8311-detect-config.sh [options]

Options:
-l --logfile <filename>         File location to log output (will be overwritten).
-D --debugfile <filename>       File location to output debug logging (will be appended to).
-d --debug                      Output debug information.
-c --config <filename>          Write detected configuration to file
-h --help                       This help text
```

## 8311-fix-vlans.sh
This script should fix all the issues with multi-service vlans, and will use 8311-detect-config.sh to detect the ISP configuration.

You can remap the local VLANs used by setting fwenvs `8311_internet_vlan` and `8311_services_vlan`.  
To change the Internet VLAN to 335 for example, run the following twice:  
`fw_setenv 8311_internet_vlan 335`  
To make the Internet traffic untagged, set `8311_internet_vlan` to 0. The Services VLAN must always be tagged.

This is best put on a crontab to ensure the settings are applied at all times, it can be run multiple times without erroring:  
`* * * * * /root/8311-fix-vlans.sh`  

To disable this script, set fwenv `8311_fix_vlans` to 0
