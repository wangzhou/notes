ARM64休眠唤醒组件适配分析
==========================

-v0.1 2026.07.24 Sherlock init

简介：分析arm64平台做s2mem/s2disk时各组件(CPU core/timer/GICv3-ITS/mbigen/
SMMUv3/uncore PMU/MPAM/KVM)需要的适配工作，以及cpuhp与cpu_pm两条机制的分工。
基于主线7.2-rc4源码树/home/wz/linux逐项核对现有机制后给出缺口。作者:Sherlock


## 一、概述

主线7.2-rc4现状盘点：

| 组件 | 主线已有 | 需补的工作 | 优先级 |
|------|---------|-----------|--------|
| CPU core | cpu_suspend/resume、hotplug、MTE标签 | 基本无 | - |
| Timer | cpu_pm保存CNTKCTL、timekeeping syscore | 固件侧counter保活 | 低 |
| GICv3/v4 | cpu_pm保存CPU interface、ITS syscore | Distributor无保存恢复 | 高 |
| mbigen | 无任何PM机制 | per-pin缓存+syscore恢复 | 高 |
| SMMUv3 | 无任何PM回调 | 完整suspend/resume回调 | 最高 |
| Uncore PMU | 仅cpuhp亲和迁移 | suspend/resume回调 | 低 |
| MPAM | cpuhp掉电状态机+cpu_pm | 启动CPU可达MSC的恢复 | 高 |
| KVM | hyp_init_cpu_pm_notifier | pKVM例外、EL2扩展状态 | 中 |

## 二、通用机制：cpu_pm与cpuhp的分工

### 1. 挂起时启动CPU走cpu_pm syscore

kernel/cpu_pm.c:177-211注册syscore ops(core_initcall)：

```
syscore_suspend()
    \-> cpu_pm_suspend()      // kernel/cpu_pm.c:177
          +-> cpu_pm_enter()          // CPU_PM_ENTER
          \-> cpu_cluster_pm_enter()  // CPU_CLUSTER_PM_ENTER
syscore_resume()
    \-> cpu_pm_resume()
          +-> cpu_cluster_pm_exit()   // CPU_CLUSTER_PM_EXIT
          \-> cpu_pm_exit()           // CPU_PM_EXIT
```

GIC CPU interface、timer、MPAM CPU寄存器、KVM hyp都挂在这条通知链上。
s2idle和深睡idle复用同一套notifier：drivers/cpuidle/cpuidle-psci.c:75在
CPU_SUSPEND前调cpu_pm_enter。

### 2. 挂起时非启动CPU走cpuhp状态机

suspend_disable_secondary_cpus() → freeze_secondary_cpus()(kernel/cpu.c:1886)
把非启动CPU经cpuhp下线，CPUHP_AP_ONLINE_DYN的teardown/online回调逐个触发。
启动CPU从不经过cpuhp。

分工总结：

| 场景 | 启动CPU | 非启动CPU |
|------|--------|----------|
| s2idle | cpuidle路径cpu_pm notifier | 同左，每CPU独立 |
| s2mem/s2disk | syscore里的cpu_pm | cpuhp下线/上线 |

### 3. syscore执行顺序

register_syscore()是list_add_tail(drivers/base/syscore.c)，suspend逆序执行
(后注册先执行)，resume正序执行(先注册先执行)。ITS在init_IRQ阶段注册、mbigen
等平台设备在probe阶段注册，resume顺序ITS先恢复、依赖它的设备后恢复，天然
正确。新增syscore时按依赖关系选择注册时机即可。

## 三、CPU core

已有机制：
- cpu_suspend()(arch/arm64/kernel/suspend.c:97)经__cpu_suspend_enter保存
  callee-saved寄存器和EL1系统寄存器，唤醒时从cpu_resume物理入口恢复
- 非启动CPU走freeze_secondary_cpus()(kernel/cpu.c:1886) hotplug下线
- s2disk：swsusp_arch_suspend/resume(arch/arm64/kernel/hibernate.c:333/405)，
  MTE标签经swsusp_mte_save_tags/restore随镜像保存，dcache清到PoC

额外工作：无。进程上下文(SVE/SME)在task_struct里，天然随镜像保存。

## 四、Timer

已有机制：
- arch_timer_cpu_pm_notify(drivers/clocksource/arm_arch_timer.c:973)：
  CPU_PM_ENTER时保存CNTKCTL_EL1，EXIT时恢复
- CLOCK_SOURCE_SUSPEND_NONSTOP(arm_arch_timer.c:943)仅当固件声明counter挂起时
  不停才置位，否则timekeeping syscore在唤醒后走clocksource重同步

额外工作：
1. 固件保证S3期间system counter继续计时，并通过ACPI GTDT/DT如实声明
2. VHE下CNTHCTL_EL2由KVM按vcpu管理，下次vcpu load自动恢复，无需处理
3. 定时唤醒走RTC alarm，固件保证RTC唤醒域供电

## 五、GICv3/v4

已有机制：
- gic_cpu_pm_notifier(drivers/irqchip/irq-gic-v3.c:1482)：CPU_PM_ENTER时关
  GRPEN1、置GICR_WAKER ProcessorSleep；EXIT时gic_enable_redist +
  gic_cpu_sys_reg_enable + gic_cpu_sys_reg_init重编程ICC_*_EL1
- IRQCHIP_MASK_ON_SUSPEND(irq-gic-v3.c:1525/1544)：suspend_device_irqs不会
  逐个mask SPI，靠CPU interface关闭阻断投递
- ITS：its_save_disable/its_restore_enable syscore ops(irq-gic-v3-its.c:
  5088-5094)：保存GITS_CTLR/CBASER/BASER缓存值后禁用，唤醒时重编程寄存器、
  CWRITER归零重同步CMD队列、重建collection

s2disk闭环点：its_restore_enable运行在被恢复的内核里(syscore_resume发生在
swsusp_arch_resume跳转之后，hibernate.c:373)，用的是镜像里的内存状态。

额外工作(高优先级)：
1. Distributor状态没有保存恢复。主线假设固件保留GICD状态或GIC不掉电。若平台
   S3电源域包含GICD，需增加gic_suspend/gic_resume syscore ops：遍历irq状态
   保存GICD_ISENABLER/ICFGR/IPRIORITYR/ITARGETSR等，唤醒后恢复，pending态处理
   要防误投递
2. 新增GICD syscore的注册顺序：GICD恢复要在CPU interface恢复(cpu_pm)之前，
   即注册晚于cpu_pm syscore
3. SPI唤醒源要求固件保留GIC供电并配置唤醒路径；GICR_WAKER errata机制已有
   (irq-gic-v3.c:373-387)

## 六、mbigen

定位：HiSilicon mbigen-v2(drivers/irqchip/irq-mbigen.c，372行)，wired-to-MSI
转换器，把设备线中断(level-high/edge-rising)转成写ITS GITS_TRANSLATER的MSI
(DOMAIN_BUS_WIRED_TO_MSI)。ACPI _HID为HISI0152。

寄存器模型(每node 0x1000偏移、128 pin/node，可用pin 64-1407)：
- VEC寄存器(0x200)：event ID存bits[21:12]，doorbell地址硬编码在硬件里，驱动
  只写event ID(irq-mbigen.c:164-166注释)
- TYPE寄存器(0x0)：per-pin触发类型level/edge
- CLEAR寄存器(0xa000)：EOI时清level状态(mbigen_eoi_irq)

现状：
- mask/unmask委托parent(ITS)：.irq_mask = irq_chip_mask_parent(:204-205)，
  mbigen自身无mask寄存器
- mbigen_write_msi_msg(:150)做read-modify-write写event ID，不缓存per-pin状态
- 无IRQCHIP_MASK_ON_SUSPEND → 挂起时pin经parent在ITS侧mask
- 无suspend/resume/cpu_pm/syscore回调

休眠唤醒影响：
1. ITS侧已闭环：its_restore_enable从缓存值重编程BASER，mbigen的device table
   条目在ITS内存表里(表在DDR，s2mem保留/s2disk随镜像)，MSI映射无需重新分配
2. mbigen自身寄存器是缺口：电源域掉电后VEC和TYPE全丢，唤醒后event ID错乱、
   触发类型错

需要的工作：
1. 驱动缓存per-pin状态(event ID + trigger type)，probe时register_syscore，
   resume时遍历pin全量重写VEC/TYPE
2. 注册顺序天然正确：mbigen在probe阶段注册，晚于ITS(init_IRQ阶段)，resume
   正序执行时ITS先恢复
3. s2disk同一套代码闭环：syscore_resume在被恢复内核里执行，用镜像里的缓存
4. 挂起方向无需处理：pin已在ITS侧mask；level pin的pending随电源域丢失，唤醒
   后由设备驱动重查
5. 平台依赖：若固件保证mbigen域不掉电(同GICD判断)，可不补

## 七、SMMUv3

现状：主线完全没有PM回调、cpu_pm、syscore。只有probe用的
arm_smmu_device_reset(arm-smmu-v3.c:4743)。

后果：
- s2mem：S3电源域包含SMMU时，唤醒后STRTAB_BASE/CMDQ/EVTQ/STE/CD缓存全丢，
  所有DMA设备挂
- s2disk：boot kernel重新编程了SMMU，跳转镜像后硬件是boot kernel配置，内存
  里是旧内核配置，不一致

需要的工作：
1. 实现arm_smmu_suspend/resume(dev_pm_ops)：suspend时排空CMDQ并置STALL/禁用；
   resume时从内存状态全量重编程(复用probe路径)：arm_smmu_device_reset →
   恢复GCR0/GCR1/STRTAB_BASE/队列基址/IRQ_CTRL → 遍历in-memory master状态重发
   STE/CD → CMD_SYNC。不能做增量恢复，s2disk场景下硬件配置是boot kernel留的
2. 挂起顺序不用额外处理：iommu core在attach时创建stateless device link
   (iommu_init_device → iommu_device_link，drivers/iommu/iommu.c:518)，SMMU
   有了PM回调后自动晚于DMA客户端suspend、早于它们resume
3. 平台SMMU支持context retention时可简化为增量路径，但s2disk无论如何都要全量
   重编程

## 八、Uncore PMU(DSU/CMN/hisilicon)

现状：arm_dsu_pmu.c、arm-cmn.c、drivers/perf/hisilicon/全部没有dev_pm_ops。
计数域掉电后counter配置和数值丢失，perf event静默失效。

已有cpuhp回调的作用(arm_dsu_pmu.c:802/820，arm-cmn.c:2021/2033)：挂起时非
启动CPU下线触发teardown，把perf事件经perf_pmu_migrate_context迁移到在线CPU
(最终都到启动CPU)，恢复时再迁回。这只是CPU亲和迁移，不保存恢复硬件寄存器，
不能替代suspend/resume回调。

需要的工作(低优先级)：
1. 增加suspend/resume回调：suspend停计数器并保存配置，resume恢复配置并重新
   enable事件
2. 接受丢失的方案：resume时重置counter并标记事件，避免读到垃圾值
3. MPAM的MBM监控计数器同理；resctrl的1s带宽反馈定时器挂起期间被冻结，唤醒后
   第一个周期依赖overflow检测兜底

## 九、MPAM

已有机制：
1. cpu_pm：mpam_pm_notifier(arch/arm64/kernel/mpam.c:20-41)在CPU_PM_EXIT时从
   per-cpu缓存恢复MPAM1_EL1(含MPAMEN)、MPAMSM_EL1(SME)、MPAM0_EL1
2. cpuhp掉电状态机(mpam_devices.c:1823/1882)：mpam_cpu_offline对每个该CPU可达
   的MSC减online_refs，最后一个可达CPU下线时把MSC写回reset态并标
   in_reset_state=false(驱动预期硬件会丢非零partid状态)；mpam_cpu_online在
   第一个CPU回来时调mpam_reprogram_msc()从内存全量重编程MSC

分工与缺口：
1. 挂起时所有非启动CPU下线，凡是不含启动CPU的MSC都会走一遍reset→reprogram，
   MSC状态已闭环，这部分不用额外做
2. 缺口在启动CPU：它不下线，其可达的MSC不触发任何回调。若平台挂起时这些MSC
   也掉电，唤醒后CPU侧MPAM0/1_EL1被cpu_pm恢复而MSC状态丢失，不一致。补法：
   把reset/reprogram逻辑挂到CPU_CLUSTER_PM notifier或syscore(复用
   mpam_reprogram_msc)；cpu_pm_resume先发CPU_CLUSTER_PM_EXIT再发CPU_PM_EXIT，
   挂cluster notifier的MSC恢复天然先于MPAM0/1_EL1恢复
3. MPAM虚拟化(MPAMHCR_EL2 trap、per-VM partid/pmg)主线未合并。若发行版内核
   携带，需在KVM hyp reinit路径补MPAMHCR_EL2恢复

## 十、虚拟化(KVM)

已有机制：hyp_init_cpu_pm_notifier(arch/arm64/kvm/arm.c:2326)：CPU_PM_ENTER时
cpu_hyp_reset()关闭hyp，CPU_PM_EXIT时cpu_hyp_reinit()重建EL2向量表并重打
spectre缓解(仅当kvm_hyp_initialized置位)。

关键结论：guest的全部状态都在内存里(vcpu寄存器、vGIC、stage-2页表、vtimer)，
s2mem/s2disk天然保存guest，恢复后guest无感(仅时间跳变)。非启动CPU的EL2状态由
hotplug路径处理，随freeze_secondary_cpus自然覆盖。

额外工作：
1. 核对cpu_hyp_reinit是否覆盖平台的额外EL2状态(MPAMHCR_EL2、ZCR_EL2、GICv4
   VLPI配置)，不够就在notifier里补
2. pKVM是例外：notifier对protected KVM明确跳过(arm.c:2363)。pKVM的hyp上下文
   不在内核内存镜像里，s2mem需要hyp侧配合，s2disk基本不可行。启用pKVM时这是
   最大限制
3. GICv4 ITS直通：ITS状态已由its_restore_enable恢复，vgic侧resume后重刷，
   需验证doorbell与vcpu运行顺序

## 十一、s2idle/s2mem/s2disk差异与固件要求

| 场景 | 组件状态 | 适配量 |
|------|---------|--------|
| s2idle | CPU走cpuidle深睡，cpu_pm覆盖CPU interface类寄存器；uncore/MSC/SMMU域一般不掉电 | 接近零改动 |
| s2mem | 整机PSCI SYSTEM_SUSPEND掉电，哪些域掉电由固件决定 | 取决于固件电源域划分 |
| s2disk | 恢复后硬件是boot kernel编程的，必须全量重编程而非增量 | ITS已闭环；SMMU/GICD/mbigen/MSC需重写型回调 |

固件侧要求：
1. System counter保活(或固件保存恢复)+如实声明GTDT
2. 唤醒源供电域：PMIC/GPIO/RTC唤醒、GIC唤醒路径
3. S3电源域策略明确：GICD、mbigen、SMMU、MSC、uncore是否掉电，这决定内核要
   做多少保存恢复
4. PSCI SYSTEM_SUSPEND入口+cpu_resume地址传递(主线psci.c:535已实现)

## 十二、建议落地顺序

1. 先上s2idle：几乎零改动，验证cpu_pm notifier链和驱动基本挂起行为
2. 与固件确认S3电源域划分，确定GICD/mbigen/SMMU/MSC是否掉电
3. SMMUv3 PM回调(最大工作量，s2mem/s2disk都必须)
4. GIC distributor保存恢复(如果掉电)
5. mbigen per-pin缓存+syscore恢复(如果掉电)
6. MPAM启动CPU可达MSC的cluster/syscore恢复
7. Uncore PMU回调(可最后，先接受事件丢失)
8. 评估pKVM/MPAM虚拟化等扩展场景

## 十三、参考文件

| 文件 | 内容 |
|------|------|
| kernel/cpu_pm.c | cpu_pm syscore ops，CPU_PM通知链 |
| kernel/cpu.c | freeze_secondary_cpus，非启动CPU下线 |
| arch/arm64/kernel/suspend.c | cpu_suspend/cpu_resume |
| arch/arm64/kernel/hibernate.c | swsusp_arch_suspend/resume，MTE标签 |
| drivers/clocksource/arm_arch_timer.c | arch_timer cpu_pm，NONSTOP判定 |
| drivers/irqchip/irq-gic-v3.c | GIC CPU interface cpu_pm |
| drivers/irqchip/irq-gic-v3-its.c | its_save_disable/its_restore_enable syscore |
| drivers/irqchip/irq-mbigen.c | mbigen-v2驱动，无PM机制 |
| drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c | SMMUv3驱动，无PM回调 |
| drivers/iommu/iommu.c | iommu_device_link，SMMU与客户端顺序 |
| drivers/perf/arm_dsu_pmu.c | DSU PMU cpuhp迁移 |
| drivers/perf/arm-cmn.c | CMN DTC cpuhp迁移 |
| drivers/resctrl/mpam_devices.c | MPAM cpuhp掉电状态机、MSC编程 |
| arch/arm64/kernel/mpam.c | MPAM0/1_EL1 cpu_pm恢复 |
| arch/arm64/kvm/arm.c | hyp_init_cpu_pm_notifier |
| drivers/cpuidle/cpuidle-psci.c | s2idle路径的cpu_pm |
