NV 代码学习大纲
===============

-v0.1 2026.07.25 Sherlock init

简介：ARM嵌套虚拟化KVM代码的阅读大纲。以"每阶段回答一个目标问题"为原
则，按层切换、trap中转、VNCR、TLBI、shadow S2、vGIC、timer七个阶段组
织，每个阶段附对应补丁。补丁按时间序阅读，commit message是设计动机，
diff是验证。配合三份笔记使用：ARM64嵌套虚拟化的基本逻辑.md(骨架)、
nv_tlbi_note.md(TLBI展开)、nv_virq_note.md(vIRQ展开)。


## 阶段一：层切换引擎

- 目标问题：L0怎么把物理机器配成"跑L1"或"跑L2"？
- 代码：hyp/vhe/switch.c
- 补丁(按时间序读)：
  04ab519bb86d Configure HCR_EL2 for FEAT_NV2
  d9552fe133f9 Emulate PSTATE.M for a guest hypervisor
  dd0717a998f7 Fast-track 'InHost' exception returns
  213b3d1ea161 Handle ERETA[AB] instructions
  4cc3f31914d6 Honor HFGITR_EL2.ERET being set
- 对照：主笔记"vEL2寄存器模拟"三分类
- 验证点：HCR的NV/NV2/AT/TTLB何时被谁置位；两种语境下物理VNCR_EL2分别
  指向什么；EL2h模式fixup的进出方向


## 阶段二：trap中转引擎

- 目标问题：L2的sysreg访问trap进来，L0怎么决定"转发给L1"还是"自己处理"？
- 代码：emulate-nested.c加sys_regs.c的kvm_handle_sys_reg
- 补丁：
  47f3a2fc765a Support virtual EL2 exceptions
  e58ec47bf68d Add trap forwarding infrastructure
  d0fc0a2519a6 Add trap forwarding for HCR_EL2
  15b4d82d69d7 Add fine grained trap forwarding infrastructure
  039f9f12de5f Add trap forwarding for HFGITR_EL2(TLBI的trap条目在这)
- 对照：nv_tlbi_note的"trap触发与转发"
- 验证点：挑SGI1R或一条TLBI，从SR_TRAP条目走一遍条件评估


## 阶段三：VNCR引擎

- 目标问题：L1的VNCR VA怎么变成硬件能访问的内存？伪TLB怎么生怎么死？
- 代码：nested.c的VNCR设计大注释、kvm_translate_vncr、
  kvm_map_l1_vncr
- 补丁：
  9f75b6d447d7 Filter out unsupported features from ID regs(nested.c诞生)
  89b0e7de3451 Introduce nested virtualization VCPU feature(系列起点)
  伪TLB原版补丁：Add pseudo-TLB backing VNCR_EL2、
  Handle mapping of VNCR_EL2 at EL2(树里用git log --grep="VNCR"找)
  本地已确认的后续打磨：
  5949004d7032 Fully update VNCR fixmap state in kvm_translate_vncr()
- 对照：nv_tlbi_note的"VNCR机制"整章
- 验证点：走一遍fault冷启动路径(VNCR fault到建伪TLB到fixmap到重试)


## 阶段四：TLBI落地

- 目标问题：三类TLBI的handler分别干了什么？
- 代码：sys_regs.c的handle_tlbi_*加vhe/tlb.c
- 补丁：
  67fda56e76da Handle EL2 Stage-1 TLB invalidation
- 对照：nv_tlbi_note全文
- 验证点：三类分别对应"删数据/真刷加簿记/切VMID代刷"


## 阶段五：shadow S2

- 目标问题：merged S2怎么建、怎么删、缺页怎么注入？
- 代码：mmu.c的kvm_s2_mmu加nested.c的kvm_nested_s2_*
- 补丁：
  4f128f8e1aaa Support multiple nested Stage-2 mmu structures
  fd276e71d1e7 Handle shadow stage 2 page faults
  ec14c272408a Unmap/flush shadow stage 2 page tables
  61e30b9eef7f Implement nested Stage-2 page table walk logic
- 对照：主笔记"vEL2 Stage2页表管理"
- 验证点：顺便解掉"EL2怎么知道IPA到IPA'映射"的todo


## 阶段六：vGIC嵌套

- 目标问题：shadow LR的双向同步加MISR软件计算
- 代码：vgic-v3-nested.c加vgic.c的嵌套分支
- 补丁：
  96c2f03311de Plumb handling of GICv3 EL2 accesses
  146a050f2d8c Nested GICv3 emulation
  201c8d40dde9 Add Maintenance Interrupt emulation
  7682c023212e Propagate used_lrs between L1 and L0 contexts
  89896cc15911 Fold GICv3 host trapping requirements into guest setup
- 对照：nv_virq_note
- 验证点：挑timer的LR走一遍flush到运行到sync


## 阶段七：timer

- 目标问题：direct/emulated怎么判定、怎么切换？
- 代码：arch_timer.c
- 补丁：
  1e0eec09d43a timers: Add a per-timer, per-vcpu offset
  81dc9504a700 timers: Support hyp timer emulation
  4bad3068cfa9 Sync nested timer state with FEAT_NV2
  cc45963cbf63 Publish emulated timer interrupt state in the in-memory state
  2cd2a77f9c32 Use FEAT_ECV to trap access to EL0 timers
- 对照：主笔记vtimer章节加四情形表
- 验证点：四情形表的direct/emulated判定逻辑


## 读补丁的方法

1. 先读commit message再读diff：NV系列的commit message质量很高，设计动
   机和取舍都在里面，diff只是验证
2. diff只看+行：新增的逻辑就是patch的贡献，-行是改造的上下文
3. 每个阶段的补丁按时间序读(老到新)：后面patch引用前面patch建立的结
   构，顺序乱了会看不懂
4. 读完patch回到当前代码对一次：patch告诉你"初版为什么这么设计"，当
   前代码告诉你"最终形态"，这个系列的后续fix很多(比如VNCR那些SEA注
   入的打磨)
5. 每个阶段结束写回笔记：补丁里的动机句可以直接进笔记的"为什么"部分

建议阶段二和阶段四合并读：trap forwarding的HFGITR补丁正好是TLBI trap
条的出处，两条线同源。补丁作者是Marc Zyngier，系列历史较长，单个补丁
一般几百行，一个阶段一次读完压力不大。
