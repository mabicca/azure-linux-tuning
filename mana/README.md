This script and systemd unit will monitor the Microsoft MANA driver on Linux and reload the driver if certain counters increase.

To install this, please use the provided files in this folder and go through these steps:

1. Create the provided az-manacheck.sh under /usr/bin

2. Set the proper permissions to the script
   $ sudo chmod +x /usr/bin/az-manacheck.sh

3. Create the provided systemd unit file under /etc/systemd/system

4. Enable the systemd unit
   $ sudo systemctl daemon-reload
   $ sudo systemctl enable az-mana.service

5. Start the systemd unit and check its status:
   $ sudo systemctl start az-mana.service
   $ sudo systemctl status az-mana.service

You should be able to monitor the file /var/log/az-mana.log for any changes or actions from the script. 4) Enable the systemd unit
$ sudo systemctl daemon-reload
$ sudo systemctl enable az-mana.service

5. Start the systemd unit and check its status:
   $ sudo systemctl start az-mana.service
   $ sudo systemctl status az-mana.service

You should be able to monitor the file /var/log/az-mana.log for any changes or actions from the script. 4) Enable the systemd unit
$ sudo systemctl daemon-reload
$ sudo systemctl enable az-mana.service

5. Start the systemd unit and check its status:
   $ sudo systemctl start az-mana.service
   $ sudo systemctl status az-mana.service

You should be able to monitor the file /var/log/az-mana.log for any changes or actions from the script. 4) Enable the systemd unit
$ sudo systemctl daemon-reload
$ sudo systemctl enable az-mana.service

5. Start the systemd unit and check its status:
   $ sudo systemctl start az-mana.service
   $ sudo systemctl status az-mana.service

You should be able to monitor the file /var/log/az-mana.log for any changes or actions from the script.
