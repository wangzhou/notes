Linux中ARM核心模块休眠唤醒的基本逻辑
=====================================

- v0.1 2026.9.7 Sherlock init
- v0.2 2026.9.7 Sherlock 非启动核cpuhp逐项核对(注册点清单)
- v0.3 2026.9.7 Sherlock 解答cpuhp相关问题(多定时器/uncore pmu/its投递/irq_remapping/mbigen)
- v0.4 2026.9.7 Sherlock 补全系统syscore与cpu_pm_notifier注册清单
- v0.5 2026.9.7 Sherlock 基本逻辑代码路径去注释

简介：分析Linux内核处理ARM几个核心模块休眠唤醒的处理逻辑。


基本逻辑
---------

在一个多核系统上，系统的休眠唤醒逻辑大概是：(只看休眠，唤醒逻辑相反)

1. 用户态线程和内核线程冻结。

2. 外设休眠。

3. 非启动核下线，这里利用了cpuhp机制，对和下线核相关的软硬件实体做必要处理。这里
   的逻辑是，对非启动核做下线处理，和这些核相关的软件或者硬件部件要做处理，比如
   把这个核上除idle的所有线程都迁移到其它核上。

4. 启动核休眠。

下面展开看下具体逻辑，以s2mem为例：
```
state_store() -> pm_suspend(state) -> enter_state(state)
    |
    +-> pm_sleep_fs_sync()  
    |
    +-> suspend_prepare(state)
    |   |
    |   +-> pm_prepare_console()
    |   +-> pm_notifier_call_chain_robust(PM_SUSPEND_PREPARE, PM_POST_SUSPEND)
    |   +-> filesystems_freeze(enable)
    |   \-> suspend_freeze_processes()     <-- 冻结线程
    |
    +-> suspend_devices_and_enter(state)
        |
        +-> platform_suspend_begin()
        +-> console_suspend_all()
        +-> dpm_suspend_start(PMSG_SUSPEND)
        |     \-> dpm_prepare + dpm_suspend     <-- 外设休眠
        |
        \-> suspend_enter(state, &wakeup)
            |
            +-> platform_suspend_prepare()
            +-> dpm_suspend_late(PMSG_SUSPEND)
            +-> platform_suspend_prepare_late()
            +-> dpm_suspend_noirq(PMSG_SUSPEND)
            |     +-> device_wakeup_arm_wake_irqs()
            |     +-> suspend_device_irqs()
            |     \-> dpm_noirq_suspend_devices()
            +-> platform_suspend_prepare_noirq()        <-- 关外设中断
            +-> pm_sleep_disable_secondary_cpus()
            |     \-> suspend_disable_secondary_cpus()
            |           \-> freeze_secondary_cpus()       <-- 非启动核cpuhp
            +-> arch_suspend_disable_irqs()
            |
            +-> syscore_suspend()                         <-- 启动核syscore休眠
            |     \-> syscore'suspend in syscore_list
            |
            \-> suspend_ops->enter(state)                 <-- 启动核休眠
                  \-> [arm64] psci_system_suspend_enter()
                        \-> cpu_suspend(0, psci_system_suspend)
                              \-> PSCI SYSTEM_SUSPEND call
```

进程冻结
---------

各种寄存器保存到内存。core核心寄存器保存和恢复?


设备休眠
---------

外设休眠唤醒，需要注册dev_pm_ops回调。

todo: smmu休眠唤醒。注意，dev_pm_ops/cpuhp/syscore都有涉及。


非启动核以及相关核心模块休眠
-----------------------------

suspend_enter -> pm_sleep_disable_secondary_cpus -> freeze_secondary_cpus 
_cpu_down -> 各个模块的cpuhp回调：

core          本来就是处理core。

timer         cpuhp有: arm_arch_timer.c arch_timer_dying_cpu。关timer中断。

gicv3         cpuhp有: irq-gic-v3.c gic_starting_cpu/NULL gic_check_rdist/NULL,
              上电enable gic和检测gicr，cpu offline没有动作。

mpam          cpuhp有: mpam_devices.c mpam_cpu_online/offline，逻辑有点绕?

uncore pmu    cpuhp有: 各个hisi uncore pmu hisi_ucore_pmu_offline_cpu, 需要做
              perf_pmu_migrate_context，什么语义？


gic its       没有cpuhp。后面syscore处理。

smmuv3        iommu/irq_remapping.c里有cpuhp，x86 CONFIG_IRQ_REMAP 功能，smmuv3
              不用考虑?

kvm           cpuhp有: kvm_main.c kvm_online_cpu/offline_cpu, ARM64回调为
              kvm_arch_disable_virtualization_cpu，只是关了vtime host中断以及
              kvm_vgic_global_state.maint_irq。

fp/simd       cpuhp有: fpsimd.c fpsimd_cpu_dead, 只清per-CPU缓存指针。

mbigen        和ITS一样，需要增加syscore。

启动核以及相关核心模块休眠
---------------------------

```
suspend_enter

  -> syscore_suspend

       // 处理全局模块suspend和最后一个core suspend。相关回调通过register_syscore
       // 注册，所有注册syscore下面整理。cpu_pm_syscore单独又包含一个子系统。
    -> syscore->ops->suspend    

     // 注意，suspend_ops全系统一个，处理最后一个core最后suspend。
  -> suspend_ops->enter 这里的回调是：psci_system_suspend_enter -> cpu_suspend
```

关键syscore注册梳理(以ARM平台为基础)：

[...]
cpu_pm_syscore        自己构成一个子系统，后文分析。

timekeeping_syscore   kernel/time/timekeeping.c  tick/clocksource/clockevents统一
                      关停与重同步

irq_pm_syscore        kernel/irq/pm.c  IRQF_EARLY_RESUME中断线在syscore阶段先恢复
                      (挂起方向无动作)

its_syscore           drivers/irqchip/irq-gic-v3-its.c ITS寄存器保存/恢复+CMD队列
                      重同步，多个ITS依次遍历操作。

kvm_syscore           virt/kvm/kvm_main.c 内部调用kvm_arch_disable_virtualization_cpu，
                      和如上cpuhp有什么区别？

fw_syscore            drivers/base/firmware_loader/main.c  firmware cache挂起处理?

mbigen_syscore        todo

smmuv3                todo

从硬件模块的角度再梳理一遍：

core             cpu_pm
fp/simd          cpu_pm
gicv3            cpu_pm
mpam             cpu_pm ?
core pmu         cpu_pm

timer            timekeeping_syscore
uncore pmu       ?
gic its          its_syscore
kvm              kvm_syscore

mbigen           todo
smmuv3           todo

cpu_pm
-------

实现在kernel/cpu_pm.c，注册入口是：cpu_pm_register_notifier。
调用入口：cpu_pm_enter/exit <- cpu_pm_suspend/resume <- cpu_pm_syscore.ops->suspend

ARM64 cpu_pm梳理：

gicv3        drivers/irqchip/irq-gic-v3.c:1503
             ENTER关GRPEN1+GICR睡/EXIT唤醒+重写ICC_*_EL1

arch_timer   drivers/clocksource/arm_arch_timer.c:995
             CNTKCTL_EL1保存到saved_cntkctl/EXIT写回+事件流mask更新

arm_pmu      drivers/perf/arm_pmu.c:821
             ENTER stop+保存PMU寄存器/EXIT恢复+start

mpam         arch/arm64/kernel/mpam.c:58
             仅EXIT: 从per-cpu缓存重写MPAM0/1_EL1+MPAMSM_EL1

kvm hyp      arch/arm64/kvm/arm.c:2366
             ENTER cpu_hyp_reset/EXIT cpu_hyp_reinit(pKVM显式跳过)

fpsimd       arch/arm64/kernel/fpsimd.c:2073
             ENTER保存+flush当前CPU的FP/SVE/SME到task_struct

sdei         drivers/firmware/arm_sdei.c:995
             SDEI固件接口PM处理(检测到SDEI才注册)

