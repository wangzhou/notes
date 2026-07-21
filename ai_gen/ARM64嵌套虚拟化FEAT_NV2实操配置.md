ARM64嵌套虚拟化(FEAT_NV2)实操配置
===

-v0.1 2026.07.21 Sherlock init

简介:给出在ARM64上跑硬件辅助嵌套虚拟化(FEAT_NV2)的完整落地配置,
覆盖L0裸机内核cmdline、在L0上用QEMU启动L1(如何给vCPU开虚拟EL2)、
L1内核cmdline及在L1里启动L2,并附硬件前提、验证方法与常见失败点。
机制原理见[[ARM64_KVM嵌套虚拟化FEAT_NV2_NV3分析]]。


## 三层角色与配置位置

嵌套要在一台机器上叠三层管理者,配置分三处:

| 层 | 是什么 | 物理EL | KVM术语 |
|---|---|---|---|
| L0 | 裸机host内核加KVM | EL2(真) | host |
| L1 | 第一层guest,自己也当hypervisor | 物理EL1 | vEL2 |
| L2 | L1里再起的guest | 物理EL1 | vEL1 |

配置顺序:先给L0内核开nested门控,再在L0上用QEMU启动L1并给vCPU请求
虚拟EL2,最后在L1内核里同样开nested并像普通KVM一样启动L2。


## 硬件与软件前提

主线KVM是FEAT_NV2 only,约v6.14合入mainline。软件全就绪也没用,物理
CPU必须真的实现FEAT_NV2,门控条件见分析文档,概括为:

- ID_AA64MMFR2_EL1.NV不低于0b0010(NV2),或ID_AA64MMFR4_EL1.NV_frac
  指示NV2_ONLY;
- 满足其一,cpufeature ARM64_HAS_NESTED_VIRT才置位,KVM才允许给vCPU
  置KVM_ARM_VCPU_HAS_EL2。

前提清单:

| 项 | 要求 |
|---|---|
| 物理CPU | 实现FEAT_NV2(如AmpereOne、Neoverse V2/N2及之后,以datasheet为准) |
| L0启动模式 | 必须VHE(裸机EL2且HCR_EL2.E2H=1),不能是pKVM/protected |
| L0内核 | CONFIG_KVM=y,且版本含NV2代码(mainline约v6.14起,或厂商回移) |
| 中断控制器 | 必须GICv3(NV的中断影子化只支持v3,GICv2不行) |
| QEMU | 能给vCPU请求EL2的版本,属性名随版本演进(见下) |

注意,纯FEAT_NV(NV=0b0001)而无NV2的硬件主线不支持,但实践中无此硬件。
本机(openEuler 6.6内核)大概率不含mainline的NV2代码,且无/dev/kvm,
不能作为L0,下面配方需在具备FEAT_NV2的裸金属上执行。


## 一、L0裸机host内核cmdline

NV2门控默认不开,必须显式打开内核参数:

```
kvm-arm.mode=nested
```

放进GRUB(/etc/default/grub的GRUB_CMDLINE_LINUX),或直接追加到cmdline。

要点:

- 必须VHE启动。绝大多数ARMv8.1+服务器固件默认进VHE。不要加
  kvm-arm.mode=nvhe(强制非VHE)或kvm-arm.mode=protected(pKVM),
  二者都使NV不可用,且protected与nested互斥;
- L0内核需含NV2支持,否则即使加了参数,cpufeature也不会因软件缺失
  而工作;
- 其余按需,如调试时nokaslr方便,不是必需。

改完重建grub并reboot:

```bash
# Debian/Ubuntu
update-grub
# openEuler/RHEL系
grub2-mkconfig -o /boot/grub2/grub.cfg
```

生效自检:

```bash
grep -o 'kvm-arm.mode=[a-z]*' /proc/cmdline   # 应输出 kvm-arm.mode=nested
ls /dev/kvm                                    # 必须存在
dmesg | grep -iE "kvm.*(VHE|nested)"           # 看VHE模式与nested是否可用
```


## 二、在L0上用QEMU启动L1

诀窍是给vCPU请求虚拟EL2,让QEMU通过KVM_ARM_VCPU_HAS_EL2向L0内核申请。
machine必须是virt且gic-version=3。对QEMU 8.2,推荐写法:

```bash
qemu-system-aarch64 \
  -machine virt,gic-version=3,accel=kvm \
  -cpu host,nested-virt=on \
  -smp 4 -m 8G \
  -kernel Image \
  -append "root=/dev/vda2 console=ttyAMA0 kvm-arm.mode=nested" \
  -drive if=none,file=l1.qcow2,id=hd0,format=qcow2 \
  -device virtio-blk-pci,drive=hd0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic
```

如何请求虚拟EL2,属性名随QEMU版本演进,二选一:

1. -cpu host,nested-virt=on:较新QEMU/主线暴露的显式属性。若该版本不认,
   会报Property 'host-arm-cpu.nested-virt' not found,则改用下法;
2. -machine virt,virtualization=on加-cpu host:注意virtualization=on本是
   给TCG仿真EL2用的开关,在accel=kvm下真正起作用的是L0内核对vCPU的
   KVM_ARM_VCPU_HAS_EL2支持加-cpu host透传NV2能力。

先在L0探测属性名是否存在:

```bash
qemu-system-aarch64 -machine virt,accel=kvm -cpu host,nested-virt=on \
  -smp 1 -m 512 -nographic -kernel /dev/null 2>&1 | head
```

必须满足:

- machine是virt且gic-version=3;
- 用-cpu host透传真实CPU的NV2能力(-cpu max在KVM下也行,host最稳);
- accel=kvm(TCG纯软件仿真也能跑NV但极慢,仅用于无硬件时验证逻辑)。

注意,能否给vCPU EL2最终由L0内核决定,QEMU只是转发这个请求。


## 三、L1内核cmdline与启动L2

L1是普通ARM64 Linux guest,但它自己要当hypervisor。

L1内核cmdline(上面-append里已带):

```
kvm-arm.mode=nested
```

- 若L1只跑L2、不再往下嵌L3,kvm-arm.mode=nested不是强制的,但带上无害,
  为将来多层留余地;
- 关键是L1内核也要含NV2支持,且L1启动后/dev/kvm存在,这证明L0成功给了
  它vEL2。

进L1后自检:

```bash
ls /dev/kvm                          # 必须存在
dmesg | grep -iE "VHE|kvm"           # L1应报自己在VHE(其实是vEL2)
```

在L1里启动L2,和普通KVM一样,L2通常不用再开EL2:

```bash
qemu-system-aarch64 \
  -machine virt,gic-version=3,accel=kvm \
  -cpu host \
  -smp 2 -m 4G \
  -kernel Image \
  -append "root=/dev/vda2 console=ttyAMA0" \
  -drive if=none,file=l2.qcow2,id=hd0,format=qcow2 \
  -device virtio-blk-pci,drive=hd0 \
  -nographic
```


## 验证链路是否真的嵌套成功

判据自上而下:

1. L1内/dev/kvm存在,说明L0成功提供vEL2,否则是EL2请求没生效或硬件
   无NV2;
2. L2能启动并进用户态,说明影子S2、vEL2异常注入、ERET同步点全部工作;
3. 在L0上观察陷出,ERET/TLBI/AT会是主要陷出源(NV2把寄存器访问变访存,
   只在ERET集中同步,见分析文档小结):

```bash
perf kvm stat live
# 或读 /sys/kernel/debug/kvm/*/  (需debugfs)
```


## 常见失败点对照

| 现象 | 原因 |
|---|---|
| L0 /dev/kvm不存在 | 非VHE启动/CONFIG_KVM未开/固件没进EL2 |
| L1起不来,QEMU报EL2相关错 | L0内核无NV2支持(内核太老)或硬件无FEAT_NV2 |
| nested-virt属性不存在 | QEMU版本属性名不符,改用virtualization=on路线 |
| L1内/dev/kvm不存在 | vCPU没拿到vEL2,第二步EL2请求没成功 |
| L2起不来但L1有/dev/kvm | GICv2(需v3)/内核NV代码bug/内存不足 |
| 极慢 | 用了TCG,或ERET/TLBI陷出风暴(NV固有开销) |


## 小结

三处配置的一句话概括:

- L0内核:kvm-arm.mode=nested(前提是VHE启动、内核含NV2支持、硬件有
  FEAT_NV2);
- L1 QEMU(在L0跑):-machine virt,gic-version=3,accel=kvm加
  -cpu host,nested-virt=on(属性名按QEMU版本调整);
- L1内核:kvm-arm.mode=nested,进去后/dev/kvm在即成功,再用普通
  -cpu host起L2。


## 参考文件

- kvm-arm.mode内核参数说明(Documentation/admin-guide/kernel-parameters):
  https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- KVM嵌套虚拟化补丁系列(FEAT_NV2 only,v11):
  https://lore.kernel.org/kvm/3b51d760-fd32-41b7-b142-5974fdf3e90e@os.amperecomputing.com/T/
- Arm AArch64虚拟化指南,Nested virtualization:
  https://developer.arm.com/documentation/102142/latest/Nested-virtualization
- QEMU arm CPU features文档:
  https://www.qemu.org/docs/master/system/arm/cpu-features.html

相关笔记:

- [[ARM64_KVM嵌套虚拟化FEAT_NV2_NV3分析]]
