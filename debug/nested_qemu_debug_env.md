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
./qemu-system-aarch64 \
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
因为L1系统是qcow2，所以反复启动L1系统，信息是不会丢失的。

## 调试热迁移





