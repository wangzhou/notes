- v0.1 2026.09.07 Sherlock init

简介：本文记录在MacBook(M5)上使用ARM嵌套虚拟化的步骤。


基本逻辑
---------

Apple从M2芯片开始就支持了ARM的嵌套虚拟化特性，本文记录在M5芯片上使用嵌套虚拟化的
步骤。

测试的基本环境是：host就用本机的macOS 26.4；第一层虚机(L1)使用主线QEMU(11.1.50)，
最新主线QEMU在HVF(类似Linux KVM，苹果的内核虚拟机)中支持了ARM版本的嵌套虚拟化，
支持的补丁可以参考[这里](https://patchwork.ozlabs.org/project/qemu-devel/cover/20260306075756.88922-1-mohamed@unpredictable.fr/); L1的文件系统使用openEuler的qcow2文件系统，也可以使用其它
发行版的qcow2文件系统。

使能嵌套虚拟化后，L1虚机直接就是一个基于EL2带/dev/kvm的完整系统，在L1系统里可以
方便的验证需要KVM的测试场景，比如可以直接在L1测试验证AI沙箱场景，会方便很多。

具体命令和注意事项直接如下。
                  
编译QEMU以及L1启动命令
-----------------------

编译命令：
```
// QEMU源码目录
./configure \
  --target-list=aarch64-softmmu,arm-softmmu \
  --enable-hvf \
  --enable-virtfs \
  --disable-werror
make -j10
```

L1启动命令：
```
~/repos/qemu/build/qemu-system-aarch64 \
  -machine virt,gic-version=3,virtualization=on \
  -cpu host \
  -accel hvf \
  -boot menu=on,splash-time=0 \
  -m 16G \
  -smp 10 \
  -drive file=~/ISO/openEuler-24.03-LTS-SP2-aarch64.qcow2,format=qcow2,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::4000-:4000,hostfwd=udp::123-:123 \
  -device virtio-net-pci,netdev=net0 \
  -nographic \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -fsdev local,id=fsdev0,path=/Users/sherlock,security_model=none \
  -device virtio-9p-pci,fsdev=fsdev0,mount_tag=hostshare \
  -rtc clock=host
```
注意，需要增加：-boot menu=on,splash-time=0，否则QEMU启动卡在BIOS阶段无法进入guest
内核。

进入L1系统后，可以看见/dev/kvm，并且可以继续启动L2虚机。
