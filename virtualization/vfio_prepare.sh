#!/bin/bash

mkdir /lib/modules/`uname -r`
touch /lib/modules/`uname -r`/modules.order
touch /lib/modules/`uname -r`/modules.builtin
depmod /mdio.ko /ixgbe* /vfio* /irqbypass.ko

modprobe ixgbe
modprobe ixgbevf

echo 1 > /sys/devices/pci0002:80/0002:80:00.0/0002:81:00.0/sriov_numvfs

modprobe -v vfio-pci disable_idle_d3=1
modprobe -r vfio_iommu_type1
modprobe -v vfio_iommu_type1 allow_unsafe_interrupts=1

ifconfig eth26 up

echo vfio-pci > /sys/bus/pci/devices/0002:81:10.0/driver_override
echo 0002:81:10.0 > /sys/bus/pci/drivers/ixgbevf/unbind
echo 0002:81:10.0 > /sys/bus/pci/drivers_probe

