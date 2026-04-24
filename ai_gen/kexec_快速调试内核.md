kexec快速调试内核
==================

-v0.1 2024.04.24 Sherlock init
-v0.2 2024.04.24 Sherlock 按照skill刷新格式

简介：本文介绍使用kexec快速加载新内核以缩短内核开发调试循环，适用于内核开发、驱动调试等场景。

---

## 原理

```
普通启动: BIOS/UEFI POST → GRUB → 内核  (约60秒)
kexec启动: 正在运行的内核 → kexec → 新内核 (约5秒)
```

kexec 从正在运行的内核直接加载新内核，绕过 BIOS/UEFI 和 bootloader 阶段，大幅缩短调试循环时间。

---

## 基本操作

```bash
# 1. 加载新内核
sudo kexec -l /boot/vmlinuz-新内核版本 \
  --initrd=/boot/initrd-新内核版本.img \
  --append="root=/dev/xxx ro"

# 2. 执行快速重启
sudo kexec -e
# 或通过 systemd 优雅重启
sudo systemctl kexec
```

---

## 内核开发循环

```bash
# 编译内核后，一条命令加载并重启
sudo kexec -l /boot/vmlinuz-$(make kernelversion) \
  --initrd=/boot/initrd-$(make kernelversion).img \
  --append="$(cat /proc/cmdline)" && sudo systemctl kexec
```

---

## 查看启动来源

```bash
# 检查是否通过 kexec 启动
dmesg | grep -i kexec
cat /proc/cmdline | grep -i kexec
```

---

## 常用参数

| 参数 | 说明 |
|------|------|
| `-l` | 加载内核到内存 |
| `-e` | 立即执行跳转 |
| `--initrd` | 指定 initramfs |
| `--append` | 内核命令行参数 |
| `--reuse-cmdline` | 复用当前内核参数 |

---

## 注意事项

- 需要内核开启 `CONFIG_KEXEC=y`
- 必须安装 `kexec-tools` 包
- 如需 crash dump 调试，需配置 `crashkernel=` 参数预留内存

---

## 参考文件

- 内核配置: `kernel/Kconfig` (CONFIG_KEXEC)
- 工具包: `kexec-tools`
- man page: `kexec(8)`

---

*文件位置: /home/wz/notes/ai_gen/kexec_快速调试内核.md*
