kexec快速调试内核
==================

-v0.1 2024.04.24 Sherlock init

简介：本文介绍使用kexec快速加载新内核以缩短内核开发调试循环，适用于内核开发、驱动调试等场景。

## 基本逻辑
```
普通启动: BIOS/UEFI POST → GRUB → 内核  (约60秒)
kexec启动: 正在运行的内核 → kexec → 新内核 (约5秒)
```
kexec 从正在运行的内核直接加载新内核，绕过 BIOS/UEFI 和 bootloader 阶段，大幅缩短调试循环时间。

## 基本操作

1. 编译内核RPM包，rpm -vih kernel_package 安装RPM包。

2. 加载新内核:
sudo kexec -l /boot/vmlinuz-新内核版本 --initrd=/boot/initramfs-新内核版本.img --append="root=/dev/xxx ro"

3. 执行快速重启:
sudo kexec -e

注意，把--append="xxx"换成--reuse-cmdline可以复用当前内核启动参数。如果没有initramfs
可以用"dracut --force initramfs-新内核版本.img 新内核版本"这样的命令生成下initramfs。
