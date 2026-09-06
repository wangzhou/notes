Linux中ARM核心模块休眠唤醒的基本逻辑
=====================================

- v0.1 2026.9.7 Sherlock init
- v0.2 2026.9.7 Sherlock 非启动核cpuhp逐项核对(注册点清单)
- v0.3 2026.9.7 Sherlock 解答cpuhp相关问题(多定时器/uncore pmu/its投递/irq_remapping/mbigen)
- v0.4 2026.9.7 Sherlock 补全系统syscore与cpu_pm_notifier注册清单

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

              如果一个core上挂了多个定时器，core下线时怎么处理？

              答: 不逐个处理, 由clockevent框架统一收口。tick:dying状态
              的teardown是tick_cpu_dying(tick-common.c:394, 注册在
              kernel/cpu.c:2167), 三步:
              1. tick_do_timer_cpu交接: 下线核若是timekeeper/do_timer
                 核, 移交给任一在线核
              2. tick_sched_timer_dying: 阻止该核重新接管tick计时职责
              3. tick_offline_cpu(clockevents.c:674): 广播设备重新指
                 派、per-CPU的tick设备逐个tick_shutdown(经
                 set_state_shutdown清CNTP_CTL.ENABLE)、cpumask只剩该核
                 的detached设备摘链表
              一个核上挂多少个clockevent设备(per-CPU tick/广播/alarm
              等)都会被这个遍历覆盖, 驱动侧arch_timer_dying_cpu只负责
              禁PPI。

gicv3         cpuhp有: irq-gic-v3.c:1416(gic_starting_cpu/NULL),
              另有:1412 BP_PREPARE_DYN上线预检。teardown为NULL靠掉电清理。

mpam          cpuhp有: mpam_devices.c:1932(ONLINE_DYN, online:reprogram_MSC/
              offline:reset)。

uncore pmu    cpuhp有: arm_dsu_pmu.c:846、arm-cmn.c:2682、hisilicon四家
              (hisi_pcie_pmu.c:981/sllc:558/ddrc:508/hns3:1647)。只迁移
              perf事件, 不保存计数器寄存器。

              uncore PMU为什么需要cpuhp，和core没有关系啊？

              答: uncore硬件跟core确实没有寄存器归属关系(DSU是簇级
              shared、CMN是SoC级), 挂cpuhp是因为perf事件在软件上绑定
              CPU: event->cpu决定谁读计数器MMIO、溢出中断送到谁、采样
              在哪个CPU上跑。CPU下线时这些事件必须挪窝, 否则悬空(读不
              到计数、收不到中断)。dsu_pmu_cpu_teardown
              (arm_dsu_pmu.c:820): 把下线核从active_cpu清除, 选同簇仍
              在线且能访问该DSU的核, perf_pmu_migrate_context迁走事件
              (:836); 簇内全下线则保持IRQ禁用等核回来。
              所以uncore的cpuhp是"事件亲和迁移", 不是"寄存器保存"——
              寄存器掉电恢复仍是缺口, 不能指望cpuhp。

gic its       没有cpuhp——挂起恢复靠syscore(irq-gic-v3-its.c:5867,
              its_save_disable/its_restore_enable)。唯一cpuhp是EFI
              memreserve(:5798), 与休眠无关; 每CPU部分由gic_starting_cpu
              内的its_cpu_init重建。

              如果core下线了，gic ite继续给这个core报中断怎么处理？为什么its
              不需要cpuhp?

              答: 不丢, 只是推迟投递。
              1. 挂起时suspend_device_irqs先行(GICv3设置了
                 IRQCHIP_MASK_ON_SUSPEND, irq-gic-v3.c:1525/1544), 非
                 唤醒irq在源端(ITS/GICD)已mask——死核之前已经没有新的
                 投递给它。
              2. 唤醒irq保持armed: LPI的pending状态存在ITS的DDR表里
                 (pending table是内存), 不是易失寄存器。核下线期间中断
                 在ITS里pending住, 等核回来。
              3. 唤醒顺序: its_restore_enable从内存表重编程ITS(含
                 pending) -> CPU online重建GICR -> 投递恢复, 全程无丢
                 失。
              (arm64下线不调irq_migrate_all_off_this_cpu主动迁中断,
              靠源端mask+内存驻留pending兜底, 和arm32设计不同。)
              不用cpuhp的原因: ITS没有随CPU下线失效的易失per-CPU状态。
              per-CPU成分(collection/GICR_PROPBASER/PENDBASER)由GIC的
              cpuhp回调(gic_starting_cpu -> its_cpu_init)搭车重建; 表
              与pending都在DDR, 与CPU个数无关; 全局挂起/唤醒归syscore。
              唯一cpuhp(EFI memreserve, :5798)是内存预留登记, 与投递无
              关。

smmuv3        iommu/irq_remapping.c里有cpuhp，完成什么功能？

              答: 那个cpuhp归x86的中断重映射层(CONFIG_IRQ_REMAP,
              VT-d/AMD), arm64/SMMUv3不编译这部分——SMMUv3没有中断重
              映射机制。注册点在irq_remap_enable_fault_handling()
              (irq_remapping.c:157), 状态CPUHP_AP_ONLINE_DYN
              "dmar:enable_fault_handling", startup = remap_ops->
              enable_faulting, teardown=NULL。功能: 每个CPU上线时使能
              该CPU的remap错误(fault)上报通道; 下线无需清理, fault上
              报随CPU掉电自然停。和SMMUv3的休眠缺口没有关系。

kvm           cpuhp有: kvm_main.c:5697(generic的kvm_online_cpu/offline_cpu)。
              arm64侧不是空函数: cpu_hyp_init/uninit+vgic+timer
              (arm.c:2296/2316)。

fp/simd       cpuhp有: fpsimd.c:2089(fpsimd_cpu_dead), 只清per-CPU缓存指针。

mbigen        需要cpuhp么？

              答: 不需要。cpuhp只适合per-CPU状态随CPU上下线走的生命周
              期, mbigen是全局设备(node级VEC/TYPE寄存器, 全系统一份),
              没有任何per-CPU成分——CPU上下线不改变它任何状态, 注册了
              也没回调可写。它的问题在挂起方向: 电源域掉电丢VEC/TYPE。
              补法: 驱动per-pin缓存(event ID+触发类型) +
              register_syscore, resume全量重写VEC/TYPE。注册在probe晚
              于ITS(init_IRQ), 唤醒时ITS先恢复、mbigen后重写, 顺序天
              然正确。

启动核以及相关核心模块休眠
---------------------------

suspend_enter

  -> syscore_suspend

       // 处理全局模块suspend和最后一个core suspend。相关回调通过register_syscore
       // 注册，所有注册syscore下面整理。cpu_pm_syscore单独又包含一个子系统。
    -> syscore->ops->suspend    

     // 注意，suspend_ops全系统一个，处理最后一个core最后suspend。
  -> suspend_ops->enter 这里的回调是：psci_system_suspend_enter -> cpu_suspend

     

syscore是否需要注册：

全系统syscore注册梳理(以ARM平台为基础)：

cpu_pm_syscore        kernel/cpu_pm.c:205      CPU_PM/CLUSTER_PM事件链,
                      core_initcall注册, 挂起最后执行唤醒最先执行

timekeeping_syscore   kernel/time/timekeeping.c:2323  tick/clocksource/
                      clockevents统一关停与重同步

sched_clock_syscore   kernel/time/sched_clock.c:329    唤醒重设epoch防回绕

irq_pm_syscore        kernel/irq/pm.c:233     IRQF_EARLY_RESUME中断线在syscore
                      阶段先恢复(挂起方向无动作)

printk_syscore        kernel/printk/printk.c:3849      挂起前flush ring buffer

its_syscore           drivers/irqchip/irq-gic-v3-its.c:5867  ITS寄存器保存/
                      恢复+CMD队列重同步, init_IRQ阶段注册(最早)

psci_idle_syscore     drivers/cpuidle/cpuidle-psci.c:203  OSI层级拓扑下CPU
                      电源域经genpd开关(仅该拓扑才注册)

kvm_syscore           virt/kvm/kvm_main.c:5702  EL2卸载/重建+shutdown
                      (KVM使能时才注册, 最晚)

fw_syscore            drivers/base/firmware_loader/main.c:1669  firmware
                      cache挂起处理

ledtrig_cpu_syscore   drivers/leds/trigger/ledtrig-cpu.c:164  CPU LED
                      触发器挂起状态

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


