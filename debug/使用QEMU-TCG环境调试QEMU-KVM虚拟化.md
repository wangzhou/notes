使用QEMU TCG环境调试QEMU/KVM虚拟化
===================================

-v0.1 2026.05.20 Sherlock init

简介：记录用双层QEMU TCG嵌套虚拟化搭建ARM64 KVM调试环境的步骤。

## 基本逻辑

调试虚拟化时往往需要要实际物理环境上进行，调试速度比较慢，而且不直观。可以采用
虚拟环境调试虚拟化，逻辑也比较简单，就是第一层QEMU(L1)启动VHE的模拟，这样第二层
QEMU(L2)就可以使用KVM。基本逻辑示意图如下：
```
    +---------------+
    |               | <--- arm构架qemu kvm
    |  L2 QEMU      |
    |               |
    +---------------+ <--- kvm加速
    +---------------+
    |               | <--- arm构架qemu tcg (模拟VHE)
    |  L1 QEMU      |
    |               |
    +---------------+
    +----------------------------------------------+
    |                                              |
    |  Host physical machine (ARM or X86)          |
    |                                              |
    +----------------------------------------------+
```
具体调试的时候，我们可能要反复的重新编译，L1 kernel(host内核)，L2 QEMU，这里L2
QEMU的编译可能会比较麻烦。为此，可以L1直接使用标准发行版的文件系统，一般发行版
网站都会自带qcow2版本的系统，L1系统可以直接使用，物理机系统可以和L1系统搞的一样，
这样直接在物理机里编译好的QEMU二进制可以直接放到L1启动里使用。

## 启动L1系统

```bash
qemu-system-aarch64 \
  -machine virt,gic-version=3,acpi=on,virtualization=true \
  -cpu max \
  -accel tcg \
  -kernel /home/wz/linux/arch/arm64/boot/Image \
  -append "... default_hugepagesz=64K ..." \
  -m 6G \
  -smp 4 \
  -drive file=./openEuler-24.03-LTS-SP2-aarch64_src.qcow2,if=virtio \
  -nographic \
  -device virtio-9p-pci,fsdev=p9fs,mount_tag=hostshare \
  -fsdev local,id=p9fs,path=./share,security_model=mapped
```
这里关键的点有：

- 配置VHE的模拟：virtualization=true
- 配置标准发行版作为文件系统
- 配置自定义内核作为模拟系统的host内核
- 可以通过9P文件系统向模拟系统传东西

## 启动L2系统

```bash
qemu-system-aarch64 \
    -m 256 \
    -smp 2 \
    -cpu max \
    -machine virt,gic-version=3 \
    -kernel ./Image \
    -initrd ./rootfs.cpio.gz \
    -append "console=ttyAMA0 root=/dev/ram init=/init" \
    -mem-path=/dev/hugepages \
    -nographic \
    -monitor telnet:127.0.0.1:4444,server,nowait
```
因为L1系统是qcow2，所以反复启动L1系统，信息是不会丢失的。其中Image、rootfs.cpio.gz
都可以通过9P文件系统从host物理机传到L1系统。

## 调试热迁移

对于调试虚机热迁移，我们需要两个L2 QEMU系统可以通过网络进行通行。大概的逻辑如下
图所示：
```
    +---------------+          +---------------+
    |               |          |               | <--- arm构架qemu kvm
    |  L2 QEMU      |          |  L2 QEMU      |
    |               |          |               |
    +---------------+          +---------------+ <--- kvm加速
    +---------------+          +---------------+
    |               |          |               | <--- arm构架qemu tcg (模拟VHE)
    |  L1 QEMU  net |<-------->| net  L1 QEMU  |
    |               |          |               |
    +---------------+          +---------------+
    +----------------------------------------------+
    |                                              |
    |  Host physical machine (ARM or X86)          |
    |                                              |
    +----------------------------------------------+
```

我是使用bridge的方式建立两个L1 QEMU的网络连接：

1. 创建bridge和tap设备(这一步需要root) 
```
#!/bin/bash
#
# host: bridge br0 (192.168.100.1)
#          │              │
#          │ tap0         │ tap1
#          ▼              ▼
#     src 外层 VM    dst 外层 VM
#    (192.168.100.10)  (192.168.100.20)
#          │              │
#     ─ ─ ─│─ ─ ─ ─   ─ ─ │─ ─ ─ ─
#          ▼              ▼
#     内层 QEMU ←──热迁移──→ 内层 QEMU
#
# 本脚本需要 root 权限执行，用于创建 bridge 和 tap 设备

set -e

BRIDGE=br0
BRIDGE_IP=192.168.100.1
TAP0=tap0
TAP1=tap1

# 清理已存在的设备（忽略错误）
ip link del "$TAP0" 2>/dev/null || true
ip link del "$TAP1" 2>/dev/null || true
ip link del "$BRIDGE" 2>/dev/null || true

# 创建 bridge
ip link add "$BRIDGE" type bridge
ip addr add "${BRIDGE_IP}/24" dev "$BRIDGE"
ip link set "$BRIDGE" up

# 创建 tap 设备并接入 bridge
ip tuntap add "$TAP0" mode tap
ip tuntap add "$TAP1" mode tap

ip link set "$TAP0" master "$BRIDGE"
ip link set "$TAP1" master "$BRIDGE"

ip link set "$TAP0" up
ip link set "$TAP1" up

echo "Bridge and tap devices created:"
ip link show "$BRIDGE"
ip link show "$TAP0"
ip link show "$TAP1"
echo ""
echo "Bridge IP: ${BRIDGE_IP}/24"
echo ""
echo "Guest network config (configure inside each VM):"
echo "  src VM: ip addr add 192.168.100.10/24 dev eth0 && ip link set eth0 up"
echo "  dst VM: ip addr add 192.168.100.20/24 dev eth0 && ip link set eth0 up"
echo ""
echo "Default gateway (optional): ip route add default via ${BRIDGE_IP}"
```

2. 启动迁出端和迁入端L1启动(模拟host)
```
#!/bin/bash

qemu-system-aarch64 \
  -machine virt,gic-version=3,acpi=on,virtualization=true \
  -cpu max \
  -accel tcg \
  -kernel /home/wz/linux/arch/arm64/boot/Image \
  -append "root=/dev/vda2 rw console=ttyAMA0 default_hugepagesz=64K selinux" \
  -m 6G \
  -smp 4 \
  -drive file=./openEuler-24.03-LTS-SP2-aarch64_src.qcow2,format=qcow2,if=virtio \
  -nographic \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:01 \
  -device virtio-9p-pci,fsdev=p9fs,mount_tag=hostshare,bus=pcie.0 \
  -fsdev local,id=p9fs,path=./share,security_model=mapped \
```
这里需要注意的点有：

- 启动迁出端和迁入端的mac地址要配置的不同
- 按照当前配置网络后，host物理机上可以直接ssh接入L1 QEMU系统，方便进行调试。

3. L2 QEMU启动

迁出端：
```
./qemu-system-aarch64 \
	-enable-kvm \
	-m 256 \
	-smp 4 \
	-cpu host \
	-machine virt,gic-version=3 \
	-L /usr/share/qemu \
	-append "console=ttyAMA0 root=/dev/ram init=/init" \
	-nographic \
	-kernel ./Image \
	-initrd ./rootfs_mini.cpio.gz \
	-mem-path /dev/hugepages \
	-monitor telnet:127.0.0.1:4444,server,nowait
```
注意，这里配置monitor可以通过telnet接入，方便通过telnet接入monitor，下发热迁移命令。

迁入端：
```
./qemu-system-aarch64 \
	-enable-kvm \
	-m 256 \
	-smp 4 \
	-cpu host \
	-machine virt,gic-version=3 \
	-L /usr/share/qemu \
	-append "console=ttyAMA0 root=/dev/ram init=/init" \
	-nographic \
	-kernel ./Image \
	-initrd ./rootfs.cpio.gz \
	-mem-patch /dev/hugepages \
	-incoming tcp:192.168.100.20:6666
```
