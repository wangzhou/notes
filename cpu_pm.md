Linux中ARM核心模块休眠唤醒的基本逻辑
=====================================

- v0.1 2026.9.7 Sherlock init
- v0.2 2026.9.7 Sherlock 非启动核cpuhp逐项核对(注册点清单)

简介：分析Linux内核处理ARM几个核心模块休眠唤醒的处理逻辑。


基本逻辑
---------

在一个多核系统上，系统的休眠唤醒逻辑大概是(只看休眠，唤醒逻辑相反)如下的。

1. 用户态线程和内核线程冻结。
2. 外设休眠。
3. 非启动核下线，这里利用了cpuhp机制，对和下线核相关的软硬件实体做必要处理。
4. 启动核休眠。

下面展开看下具体逻辑。

todo: 整体代码逻辑。

进程冻结
---------

各种寄存器保存到内存。core核心寄存器保存和恢复?


设备休眠
---------

todo: 外设休眠唤醒。dev_pm_ops

todo: smmu休眠唤醒。注意，dev_pm_ops/cpuhp/syscore都有涉及。


非启动核以及相关核心模块休眠
-----------------------------

suspend_enter -> pm_sleep_disable_secondary_cpus -> freeze_secondary_cpus 
_cpu_down -> 各个模块的cpuhp回调：

core          没有自己的cpuhp注册——core是状态机的宿主。架构侧收尾在
              cpu_operations(注册psci.c:120, cpu_die=CPU_OFF在psci.c:68),
              骨架状态在kernel/cpu.c静态表。

timer         cpuhp有: arm_arch_timer.c:1063(arch_timer_starting_cpu/
              dying_cpu), 另有:776事件流状态。

gicv3         cpuhp有: irq-gic-v3.c:1416(gic_starting_cpu/NULL),
              另有:1412 BP_PREPARE_DYN上线预检。teardown为NULL靠掉电清理。

mpam          cpuhp有: mpam_devices.c:1932(ONLINE_DYN, online:reprogram_MSC/
              offline:reset)。

uncore pmu    cpuhp有: arm_dsu_pmu.c:846、arm-cmn.c:2682、hisilicon四家
              (hisi_pcie_pmu.c:981/sllc:558/ddrc:508/hns3:1647)。只迁移
              perf事件, 不保存计数器寄存器。

gic its       没有cpuhp——挂起恢复靠syscore(irq-gic-v3-its.c:5867,
              its_save_disable/its_restore_enable)。唯一cpuhp是EFI
              memreserve(:5798), 与休眠无关; 每CPU部分由gic_starting_cpu
              内的its_cpu_init重建。

smmuv3        无cpuhp, 无dev_pm_ops, 缺口。

kvm           cpuhp有: kvm_main.c:5697(generic的kvm_online_cpu/offline_cpu)。
              arm64侧不是空函数: cpu_hyp_init/uninit+vgic+timer
              (arm.c:2296/2316)。

fp/simd       cpuhp有: fpsimd.c:2089(fpsimd_cpu_dead), 只清per-CPU缓存指针。

mbigen        无cpuhp, 缺口。补法: per-pin缓存+register_syscore全量重写
              VEC/TYPE。

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
