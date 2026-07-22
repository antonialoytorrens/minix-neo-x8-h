#!/bin/bash
# Run ON THE DEVICE ITSELF (console/SSH into the MINIX box), not on the host.
# nmcli talks to the live NetworkManager instance controlling the actual
# wifi hardware - the host's nmcli (if any) is a different machine entirely
# and has no effect on the device's connections.
#
# Forces wifi.powersave=2 (disabled) directly on each saved connection
# profile. This wins over the /etc/NetworkManager/conf.d/wifi-powersave.conf
# global default regardless of what's currently set per-connection, which is
# why `nmcli device show wlan0` reported "Power save: on" even with that
# conf.d file in place.
set -e

for name in hmtb14 "OnePlus 6_4528" TP-Link_434E trespams; do
  echo "=== $name ==="
  sudo nmcli connection modify "$name" wifi.powersave 2
done

echo ""
echo "=== reconnecting wlan0 to apply ==="
sudo nmcli device disconnect wlan0 || true
sleep 2
sudo nmcli device connect wlan0 || true
sleep 5

echo ""
echo "=== verify ==="
nmcli -f GENERAL.STATE,IP4.GATEWAY,IP4.DNS device show wlan0
iw dev wlan0 get power_save

echo ""
echo "=== test ==="
curl -v --max-time 10 google.com
