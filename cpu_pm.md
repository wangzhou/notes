Linux中ARM核心模块休眠唤醒的基本逻辑
=====================================

- v0.1 2026.9.7 Sherlock init

简介：分析Linux内核处理ARM几个核心模块休眠唤醒的处理逻辑。


基本逻辑
---------

todo

进程冻结
---------

各种寄存器保存到内存。core核心寄存器保存和恢复?


设备休眠
---------

todo: 外设休眠唤醒。

todo: smmu休眠。dev_pm_ops


非启动核以及相关核心模块休眠
-----------------------------

suspend_enter -> pm_sleep_disable_secondary_cpus -> freeze_secondary_cpus
非启动core suspend: 
_cpu_down -> 各个模块的cpuhp回调:

core          回调在哪里？
timer         只控制开关，不保存其它寄存器。counter如果停，会用RTC补回来。
gicv3         cpuhp下线 
mpam          cpuhp
uncore pmu    cpuhp
gic its       cpuhp
smmuv3        都没有(smmuv2有dev_pm_ops)  #
kvm           cpuhp, arm64空函数          #
fp/simd       cpuhp(fpsimd_cpu_dead, arch/arm64/kernel/fpsimd.c)  #

mbigen？      要怎么搞？

cpuhp的语义是？


启动核以及相关核心模块休眠
-----------------------------

启动core suspend:
suspend_enter ->
  -> syscore_suspend

    -> syscore->ops->suspend    // syscore_list, 通过register_syscore注册。

       注册的模块有：its_syscore, cpu_pm_syscore, timekeeping_syscore, kvm_syscore
       等等，见笔记

       处理全局模块suspend和最后一个core suspend。

  -> suspend_ops->enter  psci_system_suspend_enter -> cpu_suspend

     注意，suspend_ops全系统一个！

syscore是否需要注册：

core             单独处理
timer            timekeeping_syscore
gicv3            ?
mpam             ?
uncore pmu       ?
gic its          its_syscore
smmuv3           - 
kvm              kvm_syscore
fp/simd          单独处理？ 
mbigen           ?

cpu_pm
-------

kernel/cpu_pm.c

注册入口，以及注册模块： cpu_pm_register_notifier
gicv3,                          yes
arch_timer,                     yes
arm_pmu, 为啥arm_pmu_v3没有?    no
mpam                            no
kvm                             yes  callback hyp_init_cpu_pm_notifier
fpsimd                          yes

调用入口：cpu_pm_enter/exit <- cpu_pm_suspend/resume <- cpu_pm_syscore.ops->suspend
          







kvm_disable_virtualization_cpu -> kvm_arch_disable_virtualization_cpu
