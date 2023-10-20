# Bell XGS-PON Bypass

## detect-bell-config.sh
This is a helper script for fix-bell-vlans that will help detect the bell configuration.
```
Usage: ./detect-bell-config.sh [options]

Options:
-l --logfile <filename>         File location to log output (will be overwritten).
-D --debugfile <filename>       File location to output debug logging (will be appended to).
-d --debug                      Output debug information.
-c --config <filename>          Write detected configuration to file
-h --help                       This help text
```

## fix-bell-vlans.sh
This script will fix all the issues with multi-service vlans, and will use detect-bell-config.sh to detect the bell configuration.

You can remap the local VLANs used by setting fwenvs `bell_internet_vlan` and `bell_services_vlan`. For example, to change the Internet VLAN to 335, run the following twice:  
`fw_setenv bell_internet_vlan 335`
To make the Internet traffic untagged, set the `bell_internet_vlan` to 0. The Services VLAN must always be tagged.

This is best put on a crontab to ensure the settings are applied at all times, it can be run multiple times without erroring:  
`* * * * * /root/fix-bell-vlans.sh`
