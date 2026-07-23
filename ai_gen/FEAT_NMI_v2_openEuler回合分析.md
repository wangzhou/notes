# FEAT_NMI v2 系列 openEuler 回合分析

- 系列:[RFC PATCH v2 00/45] arm64: Add support for FEAT_NMI(Vladimir Murzin, 2026-07-27)
  msgid `<20260727163453.7969-1-vladimir.murzin@arm.com>`,base v7.2-rc5
- 主线源码:/home/wz/linux_nmi(nmi_debug 分支,45 个补丁已按序 apply)
- openEuler 源码:/home/wz/oe_kernel(OLK-6.6)
- oe 已回合的是 Mark Brown 2022 风格 FEAT_NMI 支持(保留 daifflags.h,无 asm/interrupts/ 目录):
  基础系列 !4425(booting 文档 c8b89f40f639 → gic-v3 NMI 0408b5bc4300)+ KVM vNMI !5815
  + 本地修复:eefea6156921(hard LOCKUP)、f7cea6febbbc(ARM64_NMI 关闭时系统停摆)、
  626602294dca(NMI withdraw 竞态)、d36f46d6c39f(sdei_nmi_watchdog 段错误)、
  2df7bc4904b8(ID_AA64PFR1_NMI_SHIFT 告警)
- 判定原则:**只考虑修复实际问题的 patch,不考虑架构调整**。bugfix 且 oe 6.6 存在该问题且无等价修复 → 需要回合。

## 结论:需要回合的 6 个 — #3、#4、#33、#35、#36、#37

其余 39 个:29 个是架构重构/清理(Murzin 的 logical exception context 体系,不回合),
10 个是使能/文档类且 oe 已有等价实现。

## 全量分析表(45 行)

| # | 补丁名 | 功能简介 | 需要回合? |
|---|--------|----------|-----------|
| 1 | arm64: ptrace: Remove INIT_PSTATE_EL2 | 删除无使用者的宏 | 否(清理) |
| 2 | arm64: debug: don't mask DAIF for mdscr_write() | 去掉无意义的 DAIF 保存恢复 | 否(清理) |
| **3** | **arm64: hibernate: mask DAIF before restoring hibernated kernel** | 恢复休眠内核前屏蔽 DAIF.D/A/F,防 Debug/SError/NMI 打断双内核切换 | **是** |
| **4** | **arm64: hibernate: Restore DAIF state on error** | MTE tags 保存失败返回前恢复 DAIF | **是** |
| 5 | arm64: suspend: rely on daif helpers to handle PMR | 删 cpu_suspend 冗余保存恢复 | 否(重构) |
| 6 | arm64: suspend: Initialize PMR on resume | resume 时初始化 PMR | 否(系列铺垫) |
| 7 | arm64: entry: mask DAIF before returning from C EL1 handlers | DAIF 屏蔽移入 C handler | 否(重构) |
| 8 | irqchip/gic-v3: make the unmasking of pseudo-NMIs explicit | gic_arch_enable_irqs 合并重组 | 否(重构) |
| 9 | arm64: entry: Avoid unnecessary local_irq_disable() on kernel exit | 省一次 irq_disable | 否(性能优化) |
| 10 | arm64: irqflags: Introduce arm64-specific irqflags type | DAIF+PMR 联合编码新类型 | 否(重构) |
| 11 | arm64: irqflags: save and use both DAIF and PMR | 双轨保存/判断 | 否(重构) |
| 12 | arm64: interrupts: Add common exception state helpers | 五档逻辑异常上下文 | 否(重构) |
| 13 | arm64: process: Use helper to check exception state | 换新 helper(oe 无此函数) | 否(清理) |
| 14 | arm64: entry: Introduce entry specific exception masking helpers | entry 辅助 API | 否(重构) |
| 15 | arm64: entry: replace DAIF helpers with entry helpers | entry 切新 API+删 PSR_I_SET | 否(重构) |
| 16 | arm64: interrupts: Introduce exception masking save/restore helpers | save/restore 配对 API | 否(重构) |
| 17 | arm64: interrupts: introduce a helper for GIC priority initialization | init_IRQ 换 helper | 否(重构) |
| 18 | arm64: replace local_daif helpers | 10 个文件切新 API | 否(重构) |
| 19 | arm64: cpuidle: use new helpers to bypass interrupt priority masking | cpuidle 切新 API | 否(重构) |
| 20 | arm64: remove daifflags.h | 删 daifflags.h | 否(清理,oe 依赖它) |
| 21 | arm64: gicv3: remove GIC_PRIO_PSR_I_SET | 删 PSR_I_SET | 否(清理,oe 在用) |
| 22 | arm64: cpufeature: Remove system_has_prio_mask_debugging() | 删无用户函数 | 否(清理) |
| 23 | arm64: irqflags: Switch to CONFIG_DEBUG_IRQFLAGS | WARN 改挂通用配置 | 否(重构) |
| 24 | arm64: Kconfig: Remove CONFIG_ARM64_DEBUG_PRIORITY_MASKING | 删 Kconfig 项 | 否(清理,oe 在用) |
| 25 | efi/runtime-wrappers: Permit architectures to override IRQ flags checks | 校验可覆盖化 | 否(重构) |
| 26 | arm64/efi: Implement override for IRQ flags checks | arm64 校验覆盖实现 | 否(重构) |
| 27 | arm64: booting: Document boot requirements for FEAT_NMI | 文档 TALLINT=0 | 否(oe 已有) |
| 28 | arm64: sysreg: Add definitions for immediate versions of MSR ALLINT | sysreg 定义 | 否(oe 已有,逐行相同) |
| 29 | arm64: ptrace: Add PSR_ALLINT_BIT | ALLINT pstate 位 | 否(oe 曾加后被回退;**是 33/35 的依赖**) |
| 30 | arm64: idreg: Add an override for FEAT_NMI | arm64.nmi= override | 否(oe 已有) |
| 31 | arm64: cpufeature: Detect PE support for FEAT_NMI | NMI 双 cap 检测 | 否(oe 已有) |
| 32 | arm64: nmi: Manage masking for superpriority interrupts | ALLINT 屏蔽顺序管理 | 否(重构) |
| **33** | **arm64: irq: Report FEAT_NMI masking local IRQs** | irq flags 记账纳入 ALLINT(带 system_uses_nmi 门控) | **是** |
| 34 | arm64: nmi: Add handling of superpriority interrupts as NMIs | ISR_EL1 分流 NMI handler | 否(oe 已有) |
| **35** | **arm64: suspend: Always initialise PSTATE.ALLINT** | resume 初始化 ALLINT,防 NMI 提前注入 | **是** |
| **36** | **arm64/efi: Add ALLINT to IRQ flags checks** | EFI runtime 校验/恢复 ALLINT | **是** |
| **37** | **arm64: kprobes: Disable NMIs** | kprobes 期间屏蔽 ALLINT 防 NMI 打断单步 | **是** |
| 38 | arm64: smp: Abstract SGI and LPI operations | ipi_irq_ops 抽象 | 否(重构) |
| 39 | arm64: smp: Fall back to IRQ when IPI NMI request fails | IPI NMI 请求失败回退 | 否(修的是 v2 新增路径;oe ipi_nmi.c 已自带回退) |
| 40 | arm64: nmi: Add Kconfig for NMI | CONFIG_ARM64_NMI | 否(oe 已有) |
| 41 | irqchip/gic-v3: Prepare for FEAT_GICv3_NMI support | 符号改名 | 否(重构) |
| 42 | irqchip/gic-v3: Implement FEAT_GICv3_NMI support | INMIR/NMIAR 实现 | 否(oe 已有等价超集+3 个本地 fix) |
| 43 | arm64: smp: Add NMI support for LPI-backed IPIs | LPI IPI NMI | 否(oe 无该框架) |
| 44 | irqchip/gic-v5: Add NMI support for PPIs, SPIs and LPIs | GICv5 NMI | 否(6.6 无该驱动) |
| 45 | irqchip/gic-v5: Add NMI support for IPIs | GICv5 IPI NMI | 否(同上) |

## 需要回合的 6 个补丁(证据与注意事项)

### #3 arm64: hibernate: mask DAIF before restoring hibernated kernel
- 问题:恢复休眠内核前只屏蔽了 IRQ,DAIF.D/A/F 全开;双内核切换不一致状态瞬间若来 Debug/SError/pseudo-NMI,静默致命崩溃
- oe 现状:hibernate.c:460-464 `__hyp_set_vectors()` 后直接 `hibernate_exit()`,全程无 DAIF masking,逐字复现;无等价修复
- 与 NMI 实现风格完全正交,可独立回合

### #4 arm64: hibernate: Restore DAIF state on error
- 问题:`swsusp_mte_save_tags()` 失败时 `swsusp_arch_suspend()` 带着 DAIF 全 mask 状态返回
- oe 现状:hibernate.c:338 `flags = local_daif_save()` 后 344-346 `if (ret) return ret;` 未 restore;无等价修复

### #33 arm64: irq: Report FEAT_NMI masking local IRQs
- 问题:SPINTMASK=0 时 ALLINT 屏蔽全部 IRQ,但 arch_local_save_flags / interrupts_enabled(regs) 等只记账 PSR.I → ALLINT 屏蔽状态下异常被误报"IRQ 使能",即 hard LOCKUP 一类问题的根源
- oe 历史:eefea6156921 曾给 interrupts_enabled/fast_interrupts_enabled 加 ALLINT 检查 → f7cea6febbbc(HEAD 分支对应 0081767f38ac)因"硬件支持 FEAT_NMI 时即使 ARM64_NMI 关闭,硬件也动 ALLINT 导致系统停摆"而**无门控地整体回退** → 现在 ARM64_NMI=y 时该问题回归
- v2 的写法正是正确形态:以 `system_uses_nmi()` 门控
- 回合注意:需适配 oe 老结构(irqflags.h / ptrace.h 的 interrupts_enabled 宏),并**补回 PSR_ALLINT_BIT 位定义**

### #35 arm64: suspend: Always initialise PSTATE.ALLINT
- 问题:SCTLR_EL1.NMI=1 而 PSTATE.ALLINT=0 时,resume 期间 NMI 可注入
- oe 现状:INIT_PSTATE_EL1 无 ALLINT 位(ptrace.h:14-15);cpu_do_resume 恢复 SCTLR_EL1(NMI=1,proc.S:148),ALLINT 无人初始化;suspend.c/proc.S/sleep.S grep ALLINT 零命中

### #36 arm64/efi: Add ALLINT to IRQ flags checks
- 问题:EFI runtime 调用破坏 ALLINT 时既不告警也不恢复(ALLINT 被置位 → IRQ 永久屏蔽)
- oe 现状:ARCH_EFI_IRQ_FLAGS_MASK 只含 DAIF(efi.h:51),runtime-wrappers.c:148-155 按 DAIF 校验;回合成本低(扩 mask + save/restore)

### #37 arm64: kprobes: Disable NMIs
- 问题:kprobe 单步期间 NMI 可打断 kprobe 状态机导致同 CPU 嵌套 kprobe / 状态损坏(只挡 PSR.I 挡不住 superpriority IRQ)
- oe 现状:kprobes.c:189-190、196-197 只 mask DAIF_MASK;oe 真实 .config 同时开 ARM64_NMI=y 与 KPROBES=y;无 NMI 相关本地修复

## ⚠️ 附带发现

oe 树中 `ALLINT_ALLINT`(PSTATE ALLINT 位宏)被两处引用但**全树无定义**:
- arch/arm64/include/asm/daifflags.h:158(local_daif_inherit)
- arch/arm64/kernel/entry-common.c:314(arm64_preempt_schedule_irq)

两处均无 #ifdef 保护(仅 runtime system_uses_nmi() 判断),疑似 f7cea6febbbc/0081767f38ac
回退 bit 定义时漏删使用点 → openeuler_defconfig(ARM64_NMI=y)下当前 HEAD 可能编译不过。
oe 最近一次构建产物是 2026-05-19,而 0081767f38ac 是 2026-01-06 合的(未验证实际编译)。
回合 #33/#37 时应一并补齐该位定义(参照 v2 的 PSR_ALLINT_BIT)。
