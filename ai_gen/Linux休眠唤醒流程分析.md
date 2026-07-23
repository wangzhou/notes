Linux休眠唤醒流程分析(s2mem/s2disk)
====================================

-v0.1 2026.07.24 Sherlock init

简介：分析Linux内核挂起/唤醒(suspend/resume)基本流程，覆盖s2idle、s2mem(S3)、
s2disk(S4/hibernation)的挂起与恢复路径，给出各阶段代码调用链。分析基于内核源码树
/home/wz/linux(7.2-rc4)，与机器上运行的6.6内核结构一致，演进差异见"六、注意事项"。
作者:Sherlock


## 一、概述

Linux的挂起/唤醒由kernel/power/子系统统一管理。用户态通过写/sys/power/state发起
转换，systemd的systemctl suspend/hibernate最终也走这条路：

| state值 | 状态 | 硬件行为 |
|---------|------|---------|
| freeze | s2idle | 冻结进程、设备空闲，CPU进深idle态，不掉电 |
| mem | s2ram(S3) | CPU/设备掉电，仅RAM自刷新，唤醒源供电 |
| disk | s2disk(S4) | 内存镜像写swap后完全断电 |

mem具体落到哪种睡眠由/sys/power/mem_sleep决定：s2idle/shallow/deep(S3)，现代x86
默认常为s2idle。

s2mem与s2disk共享同一套基础设施：进程冻结(kernel/power/process.c)、DPM设备电源
管理(drivers/base/power/main.c)、syscore核心设备(drivers/base/syscore.c)、平台
suspend_ops。区别在于：s2mem最终调用suspend_ops->enter()进入平台低功耗态；s2disk
则先做内存快照(kernel/power/snapshot.c)写入swap(kernel/power/swap.c)，再关机。

## 二、核心机制

### 1. 进程冻结(freezer)

用户态进程被置TIF_FREEZE标志，进程在返回用户态时检查到该标志后进入refrigerator
(不可中断睡眠)。内核线程必须使用wait_event_freezable()等freezable API才会在检查点
冻结，带PF_NOFREEZE标志的线程豁免。

```
freeze_processes()                             // kernel/power/process.c:121
    |
    +-> __usermodehelper_disable(UMH_FREEZING) // process.c:125
    +-> try_to_freeze_tasks(true)              // process.c:28
    |     \-> freeze_task() per task           // TIF_FREEZE + refrigerator
    \-> oom_killer_disable()                   // process.c:149

freeze_kernel_threads()                        // process.c:165
    \-> try_to_freeze_tasks(false)             // process.c:28
          \-> freeze_workqueues_begin() + wait for freezable kthreads
```

s2mem用suspend_freeze_processes()(kernel/power/power.h:277)合并两步：先
freeze_processes()再freeze_kernel_threads()，任一失败自动thaw。解冻走
thaw_processes()(process.c:179)，依次恢复OOM killer、workqueue、全部任务。

### 2. DPM设备回调四阶段

每个设备驱动通过struct dev_pm_ops提供四阶段回调，设备树自下而上执行：

| 阶段 | 回调 | 特点 |
|------|------|------|
| prepare/suspend | ->prepare ->suspend | 关设备电源/进D3hot，中断可用 |
| suspend_late | ->suspend_late | 最后可用IRQ的机会 |
| suspend_noirq | ->suspend_noirq | 中断已停，只能轮询或寄存器操作 |
| resume对称 | ->resume_noirq ->resume_early ->resume | 逆序恢复 |

封装关系：dpm_suspend_start() = dpm_prepare() + dpm_suspend()
(main.c:2334)；dpm_resume_end() = dpm_resume() + dpm_complete()
(main.c:1357)。dpm_suspend_noirq()内部先调suspend_device_irqs()再执行noirq回调
(main.c:1648-1655)，唤醒IRQ在device_wakeup_arm_wake_irqs()中被武装。

### 3. syscore与平台suspend_ops

syscore_ops(drivers/base/syscore.c)是最后停、最先启的核心设备：irqchip、
clocksource、timekeeping。此时系统处于单CPU、关中断状态，不允许睡眠和调度。

平台层通过suspend_set_ops()注册struct platform_suspend_ops，提供begin/prepare/
prepare_late/enter/wake/finish/end等回调；hibernation用另一套struct
platform_hibernation_ops(hibernation_set_ops())。

### 4. 唤醒事件处理

挂起过程中每个关键点都检查pm_wakeup_pending()：fs sync等待期间(main.c:141)、
syscore_suspend()入口(drivers/base/syscore.c:56)、suspend_ops->enter()前
(suspend.c:464)。有唤醒事件则中止挂起(wakeup abort)，避免事件丢失。用户态配合
/sys/power/wakeup_count做无竞态检查(main.c:862-901)。

## 三、s2mem调用流程

### 1. 挂起路径

```
state_store()                                  // kernel/power/main.c:799
    |
    \-> pm_suspend(state)                      // kernel/power/suspend.c:636
          |
          \-> enter_state(state)               // suspend.c:576
                |
                +-> mutex_trylock(&system_transition_mutex) // suspend.c:591
                +-> pm_sleep_fs_sync()         // main.c:125
                |     \-> ksys_sync on wq, poll pm_wakeup_pending
                +-> suspend_prepare(state)     // suspend.c:372
                |     |
                |     +-> pm_prepare_console() // suspend.c:379
                |     +-> pm_notifier_call_chain_robust(
                |     |       PM_SUSPEND_PREPARE, PM_POST_SUSPEND) // :381
                |     +-> filesystems_freeze(enable) // fs/super.c:1151
                |     \-> suspend_freeze_processes() // power.h:277
                +-> suspend_devices_and_enter(state) // suspend.c:504
                |     |
                |     +-> platform_suspend_begin()   // suspend.c:517
                |     +-> console_suspend_all()      // kernel/power/console.c
                |     +-> dpm_suspend_start(PMSG_SUSPEND) // main.c:2334
                |     |     \-> dpm_prepare + dpm_suspend // ->prepare/->suspend
                |     \-> suspend_enter(state, &wakeup) // suspend.c:419
                |           |
                |           +-> platform_suspend_prepare()     // suspend.c:423
                |           +-> dpm_suspend_late(PMSG_SUSPEND) // main.c:1779
                |           +-> platform_suspend_prepare_late() // suspend.c:432
                |           +-> dpm_suspend_noirq(PMSG_SUSPEND) // main.c:1648
                |           |     +-> device_wakeup_arm_wake_irqs() // main.c:1652
                |           |     +-> suspend_device_irqs() // kernel/irq/pm.c:126
                |           |     \-> dpm_noirq_suspend_devices() // ->suspend_noirq
                |           +-> platform_suspend_prepare_noirq() // suspend.c:441
                |           +-> pm_sleep_disable_secondary_cpus() // power.h:342
                |           |     \-> suspend_disable_secondary_cpus()
                |           |           \-> freeze_secondary_cpus() // cpu.c:1886
                |           +-> arch_suspend_disable_irqs() // suspend.c:401
                |           +-> syscore_suspend()           // syscore.c:47
                |           |     \-> check pm_wakeup_pending, reverse syscore_list
                |           \-> suspend_ops->enter(state)   // suspend.c:468
                |                 \-> [arm64] psci_system_suspend_enter()
                |                       \-> cpu_suspend(0, psci_system_suspend)
                |                             \-> PSCI SYSTEM_SUSPEND call
                |                                 // psci.c:540/535, suspend.c:97
                \-> suspend_finish()          // suspend.c:560
                      \-> thaw + PM_POST_SUSPEND + console restore
```

s2idle分支：suspend_enter()里state为TO_IDLE时直接走s2idle_loop()(suspend.c:449)，
不进平台enter。循环检查pm_wakeup_pending()后调用s2idle_enter()(suspend.c:91)，
把各CPU推入idle循环(wake_up_all_idle_cpus)，自身在swait_event_exclusive等待，
唤醒事件触发s2idle_wake()(suspend.c:163)。

### 2. 唤醒路径

唤醒在代码上表现为suspend_ops->enter()的返回。固件先把CPU交回内核(arm64从
cpu_resume入口，x86从实模式wakeup trampoline)，然后严格逆序恢复：

```
return from suspend_ops->enter()               // suspend.c:468
    |
    +-> syscore_resume()                       // syscore.c:93
    +-> arch_suspend_enable_irqs()             // suspend.c:479
    +-> pm_sleep_enable_secondary_cpus()       // power.h:348
    |     \-> suspend_enable_secondary_cpus()  // re-online non-boot CPUs
    +-> platform_resume_noirq(state)           // suspend.c:486 -> ->wake
    +-> dpm_resume_noirq(PMSG_RESUME)          // main.c:937
    |     +-> dpm_noirq_resume_devices()       // ->resume_noirq
    |     +-> resume_device_irqs()             // kernel/irq/pm.c:246
    |     \-> device_wakeup_disarm_wake_irqs() // main.c:942
    +-> platform_resume_early(state)           // suspend.c:490
    +-> dpm_resume_early(PMSG_RESUME)          // main.c:1033 -> ->resume_early
    \-> platform_resume_finish(state)          // suspend.c:496 -> ->finish

back in suspend_devices_and_enter():           // suspend.c:504
    dpm_resume_end(PMSG_RESUME)                // main.c:1357 -> ->resume/->complete
    console_resume_all()                       // suspend.c:541
```

## 四、s2disk调用流程

### 1. 挂起(写镜像)路径

```
hibernate()                                    // kernel/power/hibernate.c:760
    |
    +-> lock_system_sleep()                    // main.c:67
    +-> hibernate_acquire()                    // hibernate.c:94 (vs /dev/snapshot)
    +-> pm_prepare_console()                   // hibernate.c:790
    +-> PM_HIBERNATION_PREPARE notifier        // hibernate.c:791
    +-> pm_sleep_fs_sync()                     // hibernate.c:795
    +-> filesystems_freeze(enable)             // hibernate.c:799
    +-> freeze_processes()                     // hibernate.c:801
    +-> create_basic_memory_bitmaps()          // hibernate.c:807
    \-> hibernation_snapshot(platform_mode)    // hibernate.c:811 -> 401
          |
          +-> platform_begin()                 // hibernate.c:407
          +-> freeze_kernel_threads()          // hibernate.c:411
          +-> dpm_prepare(PMSG_FREEZE)         // hibernate.c:425
          +-> hibernate_preallocate_memory()   // hibernate.c:430 (image pages)
          +-> console_suspend_all()            // hibernate.c:434
          +-> pm_restrict_gfp_mask()           // hibernate.c:435
          +-> dpm_suspend(PMSG_FREEZE)         // hibernate.c:437 (quiesce only)
          \-> create_image(platform_mode)      // hibernate.c:442 -> 324
                |
                +-> dpm_suspend_end(PMSG_FREEZE) // hibernate.c:328 (late+noirq)
                +-> platform_pre_snapshot()     // hibernate.c:334
                +-> pm_sleep_disable_secondary_cpus() // hibernate.c:338
                +-> local_irq_disable()         // hibernate.c:342
                +-> syscore_suspend()           // hibernate.c:346
                +-> in_suspend = 1              // hibernate.c:355
                +-> save_processor_state()      // hibernate.c:356
                +-> swsusp_arch_suspend()       // hibernate.c:358
                |     \-> [arm64] __cpu_suspend_enter + swsusp_save()
                |           // arch/arm64/kernel/hibernate.c:333
                |           // snapshot happens here; after restore control
                |           // returns here with in_suspend = 0
                +-> restore_processor_state()   // hibernate.c:360
                +-> syscore_resume()            // hibernate.c:373
                +-> pm_sleep_enable_secondary_cpus() // hibernate.c:380
                +-> platform_finish()           // hibernate.c:387
                \-> dpm_resume_start(PMSG_THAW/PMSG_RESTORE) // hibernate.c:389

back in hibernate(), in_suspend == true:
    +-> swsusp_write(flags)                    // hibernate.c:839 -> swap.c:936
    |     +-> get_swap_writer()                // locate swap device
    |     +-> snapshot_read_next()             // struct swsusp_info header
    |     +-> swap_write_page(header)          // magic "S1SUSPEND" swap.c:36
    |     \-> save_image()/save_compressed_image() // pages, LZO/LZ4
    +-> swsusp_free()                          // hibernate.c:840
    \-> power_down()                           // hibernate.c:845 -> 675
          +-> mode=suspend: suspend_devices_and_enter(mem_sleep_current)
          |     // hibernate.c:681, hybrid-sleep
          +-> mode=platform: hibernation_platform_enter() // hibernate.c:695 -> 590
          |     \-> dpm_suspend_*(PMSG_HIBERNATE) -> syscore_suspend
          |           \-> hibernation_ops->enter() // hibernate.c:639 (S4, no return)
          \-> mode=shutdown: kernel_power_off()    // hibernate.c:705 (PSCI OFF)
```

aarch64上PSCI未注册hibernation_ops，默认shutdown模式直接关机；x86 ACPI才有
platform模式(hibernation_set_ops(&acpi_hibernation_ops))。hybrid-sleep对应
/sys/power/disk里选suspend模式：写完镜像后进S3而不是关机。

### 2. 恢复(读镜像)路径

启动的是全新内核，恢复流程在init阶段触发：

```
software_resume_initcall (late_initcall_sync)  // hibernate.c:1123
    |
    +-> find_resume_device()                   // hibernate.c:982
    |     \-> early_lookup_bdev(resume= / resume_offset=)
    \-> software_resume()                      // hibernate.c:1013
          |
          +-> swsusp_check(true)               // hibernate.c:1023 -> swap.c:1559
          |     \-> verify magic "S1SUSPEND" and CRC in header
          +-> check LZO/LZ4 support            // hibernate.c:1031
          +-> hibernate_acquire()              // hibernate.c:1044
          +-> PM_RESTORE_PREPARE notifier      // hibernate.c:1052
          +-> filesystems_freeze()             // hibernate.c:1056
          +-> freeze_processes()               // hibernate.c:1059
          |     // new kernel freezes tasks too, to protect memory
          +-> freeze_kernel_threads()          // hibernate.c:1065
          \-> load_image_and_restore()         // hibernate.c:1072 -> 726
                |
                +-> create_basic_memory_bitmaps() // hibernate.c:734
                +-> swsusp_read(&flags)        // hibernate.c:740 -> swap.c:1520
                |     \-> read pages back, overwrite current kernel memory
                \-> hibernation_restore()      // hibernate.c:743 -> 565
                      |
                      +-> console_suspend_all() // hibernate.c:570
                      +-> dpm_suspend_start(PMSG_QUIESCE) // hibernate.c:571
                      \-> resume_target_kernel() // hibernate.c:573 -> 488
                            |
                            +-> dpm_suspend_end(PMSG_QUIESCE) // hibernate.c:492
                            +-> platform_pre_restore()   // hibernate.c:498
                            +-> suspend_disable_secondary_cpus() // :504
                            +-> syscore_suspend()        // hibernate.c:511
                            +-> save_processor_state()   // hibernate.c:515
                            +-> restore_highmem()        // hibernate.c:516
                            \-> swsusp_arch_resume()     // hibernate.c:518
                                  \-> [arm64] copy swsusp_arch_suspend_exit to
                                      safe page, then cpu_resume
                                      // arch/arm64/kernel/hibernate.c:405
                                      // jump into saved kernel: control
                                      // reappears in swsusp_arch_suspend()
                                      // -> back through hibernation_snapshot()
                                      // -> hibernate(): "image restored"
                                      //    hibernate.c:850
                                      // -> thaw_processes() hibernate.c:863
```

恢复成功的本质：新内核从swap读回镜像页面覆盖自己的内存，swsusp_arch_resume()
恢复CPU上下文后跳到镜像内核继续执行，代码上表现为回到swsusp_arch_suspend()
的返回点。

## 五、平台层对照

### 1. aarch64 + PSCI

挂起走PSCI固件接口，psci驱动在init时探测SYSTEM_SUSPEND特性后注册suspend_ops
(drivers/firmware/psci/psci.c:582-592)：

```
psci_suspend_ops = {
    .valid = suspend_valid_only_mem,
    .enter = psci_system_suspend_enter,        // psci.c:540
    .begin = psci_system_suspend_begin,
}                                              // psci.c:554

psci_system_suspend_enter()
    \-> cpu_suspend(0, psci_system_suspend)    // arch/arm64/kernel/suspend.c:97
          \-> invoke_psci_fn(SYSTEM_SUSPEND, pa_cpu_resume) // psci.c:535
              // firmware powers down; on wakeup it restores the CPU
              // from the cpu_resume physical entry point
```

### 2. x86 + ACPI

suspend_ops = acpi_suspend_ops(drivers/acpi/sleep.c)：->prepare/->prepare_late执行
_PTS并配置唤醒GPE，->enter写SLP_TYP/SLP_EN进S3，->finish执行_WAK。
hibernation_ops = acpi_hibernation_ops，platform模式进S4。

### 3. uswsusp(用户态s2disk)

/dev/snapshot字符设备暴露SNAPSHOT_FREEZE/CREATE_IMAGE/POWER_OFF等ioctl，分发在
kernel/power/user.c:286起的snapshot_ioctl()。用户态s2disk工具通过它冻结系统后
直接read()拿镜像流，自行压缩/加密/写盘，恢复时反向write()灌回。

## 六、注意事项

1. dpm_suspend_noirq()及之后(含syscore阶段)中断已停，设备驱动只能轮询；代码
   不能睡眠、不能依赖调度，全程跑在唯一在线的启动CPU上。
2. 唤醒竞态防护：syscore_suspend()入口先查pm_wakeup_pending()(syscore.c:56)，
   ->enter()前再查一次(suspend.c:464)，挂起过程中到来的唤醒事件会导致挂起中止。
3. 7.2树与机器上6.6内核的演进差异：
   - suspend_device_irqs()移入dpm_suspend_noirq()内部(main.c:1653)
   - 文件系统冻结由/sys/power/freeze_filesystems开关控制，s2mem也参与
     (suspend.c:385)，不再是hibernation专属
   - pm_sleep_fs_sync()异步化(main.c:125)，sync期间周期性检查唤醒事件可提前中止
   - 内核级hibernation默认LZO压缩(hibernate.c:51)，压缩不再是uswsusp专属
4. 调试手段：
   - /sys/power/pm_test：freezer/devices/platform/processors/core分级测试，在指定
     阶段提前返回定位失败层(main.c:323-385)
   - /sys/kernel/debug/suspend_stats：各阶段失败计数、最后失败设备(main.c:390-636)
   - /sys/power/pm_debug_messages + dmesg阶段日志；no_console_suspend启动参数
   - /sys/power/wakeup_count配合systemd做无竞态挂起(main.c:862-901)

## 七、参考文件

| 文件 | 内容 |
|------|------|
| kernel/power/main.c | sysfs入口state_store、互斥锁、fs sync、统计 |
| kernel/power/suspend.c | s2mem/s2idle主流程 |
| kernel/power/process.c | 进程冻结/解冻 |
| kernel/power/hibernate.c | s2disk主流程、写镜像、软件恢复 |
| kernel/power/snapshot.c | 内存快照 |
| kernel/power/swap.c | swap镜像读写、swsusp header |
| kernel/power/user.c | /dev/snapshot ioctl(uswsusp) |
| kernel/power/power.h | 冻结/CPU辅助内联封装 |
| drivers/base/power/main.c | DPM设备电源管理四阶段 |
| drivers/base/syscore.c | 核心设备syscore_ops |
| kernel/irq/pm.c | suspend_device_irqs/resume_device_irqs |
| kernel/cpu.c | 非启动CPU下线/上线 |
| drivers/firmware/psci/psci.c | aarch64平台suspend_ops |
| arch/arm64/kernel/suspend.c | cpu_suspend/cpu_resume |
| arch/arm64/kernel/hibernate.c | swsusp_arch_suspend/resume |
| drivers/acpi/sleep.c | x86平台suspend_ops |
