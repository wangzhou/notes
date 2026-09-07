MacBook M5 (Apple Silicon) 上使用 ARM 嵌套虚拟化实操
===

-v0.1 2026.09.07 Sherlock init

简介:给出在 Apple Silicon (M5) 上用 QEMU + Hypervisor.framework (HVF)
启用 ARM 嵌套虚拟化的完整落地步骤,覆盖硬件/软件前提、QEMU 编译参数、
启动脚本、嵌套虚拟化的启用机制(QEMU 侧源码路径)、一个会导致 EDK2 卡死
的已知问题及其两种解法,以及 guest 内验证方法。供后来者在 M 系列 Mac
上从零复现。

本机实测环境:MacBook Pro (Apple M5)、macOS 26.4、QEMU 11.1.50
(v11.1.0-1168)、guest 镜像 openEuler 24.03 LTS-SP2 aarch64。

机制原理类的问题(纯 FEAT_NV/NV2、KVM 内部实现)见
[[ARM64_KVM嵌套虚拟化FEAT_NV2_NV3分析]] 与
[[ARM64_pKVM实现原理与nVHE_VHE_hVHE区别]],本文只讲 macOS/HVF 这条链路。


## 一、为什么这条链路和 KVM/Linux 主机不同

x86/ARM Linux 主机上的嵌套虚拟化走的是 KVM(NV/NV2, v6.14 主线),
L0 是裸机内核、L1 通过 KVM 拿到虚拟 EL2。Apple Silicon 上完全不同:

| 项 | Linux 主机 (KVM) | macOS 主机 (HVF) |
|---|---|---|
| 底层 hypervisor | Linux KVM | Hypervisor.framework (HVF) |
| guest 拿到 EL2 的机制 | KVM_ARM_VCPU_HAS_EL2 | macOS 15+ 的 `hv_vm_config_set_el2_enabled()` |
| 嵌套实现模式 | VHE / hVHE | 仅 nVHE (macOS 26.3 实测, 用 VNCR) |
| 中断控制器 | 必须 in-kernel GICv3 | Apple 平台 vGIC (kernel-irqchip=on) |
| 触发 EL2 的 QEMU 开关 | `-machine virt,virtualization=on` | 同左 (同一个机器属性) |

所以 mac 上"嵌套虚拟化"的正确理解是:**QEMU 用 HVF 做 L0→L1,
让 L1 (openEuler) 拿到物理 EL2 的能力,从而 L1 里能跑自己的 KVM,
再起 L2**。链路是 HVF → L1/KVM → L2。


## 二、硬件与软件前提

| 项 | 要求 | 本机 |
|---|---|---|
| 芯片 | 支持嵌套虚拟化的 Apple Silicon (M3 及之后实测可靠, M5 明确支持) | Apple M5 |
| macOS | 15.0+ (EL2 API `hv_vm_config_get_el2_supported` 从 15.0 起) | 26.4 |
| QEMU | 含 HVF 嵌套虚拟化补丁的版本 (约 11.0+ 主线/厂商) | 11.1.50 |
| 固件 | aarch64 EDK2 (ArmVirtQemu 参考版) | /opt/homebrew/share/qemu/edk2-aarch64-code.fd |
| guest 镜像 | aarch64, 内核带 KVM 且能从 EL2 启动 | openEuler 24.03 SP2 |

macOS 版本判据:QEMU 源码里 `hvf_arm_el2_supported()` 用
`__builtin_available(macOS 15.0, *)` 才去调 `hv_vm_config_get_el2_supported`,
更早的系统直接返回 false。所以 macOS < 15 一律没戏,不是补丁能救的。

嵌套模式注意(补丁作者确认):macOS 26.3 里 Apple 的嵌套实现是 **nVHE only**
(但用 VNCR)。这意味着 L1 guest 内核以非 VHE 方式在 EL2 跑,和 x86 上常见的
VHE 默认不同,遇到 L1 内核 EL2 行为异常时先往这个方向想。


## 三、编译 QEMU

依赖(Homebrew):`ninja`、`pkg-config`、`glib`,固件 `qemu`(会装 edk2-aarch64-code.fd)。

```bash
cd ~/repos/qemu
./configure \
  --target-list=aarch64-softmmu,arm-softmmu \
  --enable-hvf \
  --enable-cocoa \
  --enable-virtfs \
  --disable-werror
make -j"$(sysctl -n hw.ncpu)"   # 或 ninja -C build
```

要点:
- `--enable-hvf` 是核心,少了它 `-accel hvf` 不可用,嵌套虚拟化自然没有。
- 产物在 `build/qemu-system-aarch64`。
- 确认版本:`build/qemu-system-aarch64 --version`。


## 四、启用嵌套虚拟化的机制 (QEMU 侧)

开关就是机器属性 `virtualization`,`-machine virt,virtualization=on`。源码链路:

1. `hw/arm/virt.c:4222` 注册布尔属性 `virtualization`,读写回调
   `virt_get_virt` / `virt_set_virt`。
2. `virt_set_virt` (hw/arm/virt.c:3286) 在设置时调用
   `hvf_nested_virt_enable(value)`,把 `hvf_nested_virt` 置位 —— 因为 HVF 初始化
   早于属性解析完成,必须提前记录。
3. `hw/arm/virt.c:4365` 默认 `vms->virt = false` —— **默认关闭**,
   不加 `virtualization=on` 就不会有 EL2。
4. `target/arm/hvf/hvf.c` 的 `hvf_arch_vm_create()` 在 `hvf_nested_virt_enabled()`
   为真时:
   - 先 `hv_vm_config_get_el2_supported()` 探测主机是否支持 EL2 (macOS 15+);
   - 再 `hv_vm_config_set_el2_enabled(config, true)` 真正打开 EL2。
5. 同时给 guest CPU 置 `ARM_FEATURE_EL2` (`hvf.c:1167` 附近),并把 EL2 相关
   系统寄存器纳入同步列表 (`hvf_sreg_list` 里 `.el2 = true` 的那些)。

两个连带约束(源码里有,踩坑高发):

- **必须 kernel-irqchip=on**。virt 机型 11.1 起对 HVF 默认 `kernel-irqchip=on`
  (见 `hw/arm/virt.c:4109` 的 `get_kernel_irqchip_default`),所以通常不用显式写;
  但如果用 `-machine virt-11.0` 之类的旧版本型号,默认会变 off,嵌套就起不来。
  补丁作者明说:nested virt requires kernel-irqchip=on (因为没实现 EL2 物理定时器模拟)。
- **SME 与嵌套互斥**。`hvf.c:1228` 在开 nested 时把 `ID_AA64PFR1.SME` 清 0
  (Apple 侧嵌套虚拟化暂不实现 SME)。所以 guest 里看到 SME 不可用是预期行为,不是 bug。


## 五、启动脚本

`~/repos/scripts/run_qemu_qcow2_debug.sh`,关键两处是 `virtualization=on`
和 workaround `-boot menu=on,splash-time=0`:

```bash
#!/bin/bash

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

SSH 进去:`ssh -p 2222 root@127.0.0.1` (脚本里已 hostfwd)。


## 六、已知问题:EDK2 卡死,无任何输出

### 现象

只加 `virtualization=on`、不加 workaround 时,QEMU 能启动、EDK2 固件能打印
版本横幅,但随后卡死,输出停在:

```
Image type X64 can't be loaded on AARCH64 UEFI system.
```

之后没有 `BdsDxe:` 那两行、没有 GRUB、没有内核启动日志 —— 表现为"挂住"。
对比不带 `virtualization=on` 时,同一位置之后会正常出现
`BdsDxe: loading Boot0001 ...` → GRUB → 内核 → `oe login:`。

### 根因

来源:QEMU HVF 嵌套虚拟化补丁集 `[v13,00/17] HVF: Add support for platform
vGIC and nested virtualisation`(Mohamed Mediouni, 2026-03-06)的 Known issues:

> when nested virt is enabled, no UI response within EDK2 and a permanent wait.
> Workaround: `-boot menu=on,splash-time=0`. Apple Feedback Assistant item: FB21649319

机制:Apple 平台 vGIC 下,虚拟定时器(virtual timer)中断在 guest 处于 EL2 时
不投递回 guest;而参考版 ArmVirtQemu EDK2 在 EL2 下仍用虚拟定时器,于是卡在
等待 timer 处永久等待。所以问题不在 QEMU/脚本/M5 支持,而在 **EDK2 固件用错了
定时器**。

### 解法 A:启动参数 workaround (快速,已实测)

在启动脚本加:

```
-boot menu=on,splash-time=0
```

实测:加完后 guest 完整启动到 `oe login:`。代价:SDEI NMI watchdog 会报
`Bind interrupt failed. Firmware may not support SDEI !`(不带 nested 时是
`Disable SDEI NMI Watchdog in VM`),这印证了 EL2 下中断投递异常,但 SDEI 只是
watchdog,不影响启动。此法是绕过,不是根治。

### 解法 B:重编 EDK2 用物理定时器 (根治)

补丁作者给出的 EDK2 修复,把 `ArmGenericTimerCounterLib` 从虚拟计数器库换成
物理计数器库:

```diff
--- a/ArmVirtPkg/ArmVirt.dsc.inc
+++ b/ArmVirtPkg/ArmVirt.dsc.inc
@@
-  ArmGenericTimerCounterLib|ArmPkg/Library/ArmGenericTimerVirtCounterLib/ArmGenericTimerVirtCounterLib.inf
+  ArmGenericTimerCounterLib|ArmPkg/Library/ArmGenericTimerPhyCounterLib/ArmGenericTimerPhyCounterLib.inf
```

编译出新的 `edk2-aarch64-code.fd`,用 `-bios` 指向它。这样 EL2 下走物理定时器,
不依赖 vGIC 投递虚拟定时器中断,嵌套虚拟化才算完整可用(否则即使过了 EDK2,
后续仍可能有定时器相关隐患)。


## 七、guest 内验证嵌套虚拟化是否真正可用

能进 guest 只说明 L1 起来了。要确认嵌套虚拟化(L1 里跑 KVM)真能用,SSH 进
guest 后检查:

```bash
# 1. KVM 设备节点是否存在 (最直接的判据)
ls -l /dev/kvm

# 2. 内核是否初始化了 KVM / 跑在 EL2
dmesg | grep -i kvm

# 3. CPU 是否暴露虚拟化扩展 (ARM 上不像 x86 有 vmx/svm 字样,看 FEAT 位)
grep -i virt /proc/cpuinfo
lscpu | grep -iE 'virtualiz|hypervisor'
```

判读:
- `/dev/kvm` 存在 + `dmesg` 里有 KVM 初始化(如 "Hyp mode" / "EL2"),说明 L1 已在
  EL2 跑 KVM,可以在 L1 里正常起 L2。
- 若 `/dev/kvm` 不存在,先查 L1 内核是否编了 `CONFIG_KVM=y`(openEuler 默认通常
  有),以及 QEMU 侧是否真的开了 `virtualization=on`(漏了这步 EL2 就没了)。
- 若要在 L1 里**再**起能嵌套的 L2(三层嵌套),L1 内核还需 `kvm-arm.mode=nested`
  门控,这是 L1 内核侧的事,和本文 HVF→L1 这层无关。


## 八、常见失败点速查

| 症状 | 原因 | 处理 |
|---|---|---|
| `Nested virtualization not supported on this system.` | macOS < 15 或芯片不支持 EL2 | 升系统/换机器 |
| `Failed to enable nested virtualization.` | `hv_vm_config_set_el2_enabled` 失败 | 同上,或 kernel-irqchip 状态异常 |
| 卡在 `Image type X64 can't be loaded` 无输出 | EDK2 用虚拟定时器(第六节) | 加 `-boot menu=on,splash-time=0` 或重编 EDK2 |
| guest 里无 /dev/kvm | L1 内核没编 KVM,或漏了 `virtualization=on` | 查 L1 内核 config + 启动脚本 |
| 用旧 virt 型号起不来 | `virt-11.0` 及更早默认 kernel-irqchip=off | 显式 `kernel-irqchip=on` 或用默认 `virt` |
| guest 里看不到 SME | Apple 嵌套暂不支持 SME(QEMU 主动清 0) | 预期行为,非 bug |


## 九、参考

- 补丁系列 `[v13,00/17] HVF: Add support for platform vGIC and nested virtualisation`
  (Mohamed Mediouni, 2026-03-06, Message-ID `20260306075756.88922-1-mohamed@unpredictable.fr`,
  分支 github.com/mediouni-m/qemu `hvf-irqchip-and-nested`)。本文第六节的根因与
  EDK2 diff 均出自其 cover letter。
- Apple Feedback Assistant: FB21649319 (EL2 下虚拟定时器中断不投递)。
- QEMU 源码关键路径:`hw/arm/virt.c`(`virtualization` 属性)、`target/arm/hvf/hvf.c`
  (`hvf_arch_vm_create` 的 EL2 使能)。
