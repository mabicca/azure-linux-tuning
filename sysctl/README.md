SYSCTL parameters might vary depending on the workload and desired outcome

The sysctl files provided here should work really well for most workloads, they can be applied by either adding those values directly under /etc/sysctl.conf or the recommended
way which is to use /etc/sysctl.d folder and just create the file in there.

To activate the changes you can still use sysctl -p /etc/sysctl.d/FILENAME

To revert changes, you can simply remove the file from /etc/sysctl.d and reboot the VM for its defaults ,if backups are needed, you can always rely on the sysctl -a output for that as well.
