# Azure Linux Tuning
This repository contains documentation, files and examples about tuning Linux on Azure Cloud.

It covers common kernel parameters that can be applied using sysctl as well as UDEV rules that can add persistency to network devices.

Most of the examples listed here will have related documentation as comments to make it easier for further research and they are also mostly platform agnostic in terms of the Linux distribution being utilized.

Feel free to send suggestions and I hope you have a good time tuning! :)

# References

https://fasterdata.es.net/host-tuning/linux/
https://github.com/leandromoreira/linux-network-performance-parameters
https://blog.cloudflare.com/author/marek-majkowski/
https://blog.packagecloud.io/illustrated-guide-monitoring-tuning-linux-networking-stack-receiving-data/
https://oxnz.github.io/2016/05/03/performance-tuning-networking/

# Azure
https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-filesystem-cache
https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-mount-options
https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-concurrency-session-slots
https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-nfs-read-ahead
https://learn.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-smb-performance

# Hyper-V
https://www.kernel.org/doc/html/latest/networking/device_drivers/ethernet/microsoft/netvsc.html
