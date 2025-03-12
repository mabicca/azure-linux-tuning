Azure UDEV rules

#These are a set of UDEV rules, that will do the following:

- Tune up the ring buffer settings for the Synthetic Adapter (hv_netvsc)

- Tune up the ring buffer settings for the Mellanox (mlx) Accelerated Networking adapters
  [ACCELERATED Networking Reference](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-how-it-works)

- Tune up the ring buffer settings for the MANA (mana) Accelerated Networking adapters (IN TEST)
  [MANA Reference](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-overview)

- Tune UDP hashing for the hv_netvsc
  [NETVSC Reference](https://www.kernel.org/doc/html/latest/networking/device_drivers/ethernet/microsoft/netvsc.html)

- Add the NOQUEUE flag for Accelerated Networking to improve latency

#To use the UDEV rules:

- Download the file 99-azure-network-tuned.rules file

- Make sure it is copied under /etc/udev/rules.d

- The permissions for the file should be standard, owned by root:root and set to 0644

- If the path is correct for the tools and the permissions correct, reboot the VM for the changes to get applied properly.

#Notes about the implementation

The path to the tools used in these rules for ethtool might be different on older distributions, for example, on Ubuntu 18.04 the path to ethool is /sbin and not /usr/sbin.
