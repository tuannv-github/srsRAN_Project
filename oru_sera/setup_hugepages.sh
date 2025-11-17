sudo ./dpdk-hugepages.py -p 1G --setup 2G

cat /proc/meminfo | grep -i huge

# sudo mkdir -p /mnt/huge
