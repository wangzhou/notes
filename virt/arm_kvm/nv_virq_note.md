NV vIRQ的逻辑
==============

-v0.1 2026.07.24 Sherlock init

简介：整理ARM嵌套虚拟化下vIRQ的整体逻辑。L1的vgic是跑在guest里的真实软
件GIC，它对L2的全部中断意图通过VNCR里的ICH_LR表达；L0在进L2时把这份
意图兑现成物理list registers，在出L2时把硬件效果折回VNCR。本文是
ARM64嵌套虚拟化的基本逻辑.md中vIRQ章节的详细展开。


## 背景

GICv3虚拟化的基本机制：hypervisor把guest的中断写进物理ICH_LR(list
registers)，guest运行时读IAR/写EOIR原生作用于这些LR；LR支持HW位把物理
中断直接映射给guest；maintenance interrupt(默认PPI 25)通知hypervisor
LR状态需要维护。

嵌套场景有三层GIC：

- L0的vGIC：L0模拟给L1的GIC(GICD/GICR/ITS的MMIO访问trap到L0)，L1的
  中断都来自它，L1运行时物理LR装L1的中断状态
- L1的vgic：跑在guest里的真实软件GIC(guest KVM自己的vgic实现)，给L2
  用，它维护的数据结构在L1自己的内存里，L0看不到也不需要看
- 物理硬件LR：承载"当前谁在跑"的中断状态

关键事实：L1的ICH_LR*_EL2、ICH_HCR_EL2、ICH_VMCR_EL2是VNCR-backed
寄存器，L1的vgic写它们被NV2重定向到VNCR内存，不trap。


## 核心机制：shadow LR

L1对L2的全部中断意图都在VNCR里的ICH_LR上。L0的角色是把这份意图在vCPU
切换时双向兑现：

进L2(vgic_v3_load_nested)：

1. create_shadow_state：从VNCR读HCR/VMCR/APR/LR，组装shadow状态
2. create_shadow_lr：把VNCR里有效的LR影子化，其中translate_lr_pintid
   做pINTID翻译——L1视角的物理中断号替换成真实硬件中断号(HW直通位)
3. 物理ICH_HCR = L1的ICH_HCR_EL2值 | L0强制的trap位
   (vgic_ich_hcr_trap_bits)，这是flush_nested做的
4. 影子LR写入物理ICH_LR，L2开始跑

L2运行时：IAR/EOI/DIR原生作用于物理LR，不trap。

出L2(vgic_v3_put_nested + vgic_v3_sync_nested)：

1. APR存回VNCR，物理LR清零，撤trap
2. sync_nested：把物理LR的STATE位(active/pending等)合并回VNCR里L1的
   LR——L1之后读自己的ICH_LR看到的就是L2活动后的结果
3. HW直通中断的deactivate补做：LR进入时HW位有效、离开时变invalid的，
   L0调用vgic_v3_deactivate模拟硬件效果
4. VMCR和EOIcount同步回VNCR

整个机制和TLBI/VNCR的讨论是同一个套路：VNCR是原件，物理LR是副本，
vCPU切换时双向同步。


## 注入链

物理中断到L2的完整路径：

```
HW interrupt
    |
    v
L0 host IRQ ------------------------> L0's vGIC (physical LR / ap_list / ITS)
                                        |
                                        | inject to L1's vGIC
                                        v
L1 runs: IAR (native) ---------------> L1's vgic decision
                                        |
                                        | write ICH_LR*_EL2 (VNCR, no trap)
                                        v
L0 enters L2: shadow LR -> physical LR
                                        |
                                        v
L2 runs: IAR (native)
```

物理中断入口必然在L0(物理中断只能host收)。之后L1到L2的注入不是trap，
而是L1写VNCR加L0在切换时批量兑现。


## 同步链

L2的中断活动怎么回到L1的视图：

- L2的IAR/EOI原生作用于物理LR
- 出L2时sync_nested把状态位折回VNCR
- L1的MISR是软件计算的：vgic_compute_mi_state遍历VNCR的LR推出
  EISR(EOI)/ELRSR(empty)/pending，vgic_v3_get_misr再结合L1的
  ICH_HCR_EL2配置(U/NP/VGrp等位)算出完整MISR——因为物理MISR说的是物理
  LR的事，不能直接给L1
- maintenance interrupt两条路：
  - L2退出时物理MISR有pending：vgic_v3_handle_nested_maint_irq把L1的
    maintenance interrupt(mi_intid，默认PPI 25)注入L1的vGIC，让L1的
    vgic重同步LR、重采样level中断
  - L1运行时：vgic_v3_nested_update_mi按VNCR的LR状态计算L1的虚拟MI，
    需要时注入


## 中断交付的特殊情形

L1想拦截L2的中断交付时(vHCR_EL2.IMO置位)，kvm_vgic_flush_hwstate的嵌
套分支检测到"有pending IRQ给L2、L1不满足运行条件"，就放
KVM_REQ_GUEST_HYP_IRQ_PENDING请求——中止进L2的流程，把IRQ异常注入
vEL2，让L1以异常形式截获L2的中断。


## trap分布

| 访问 | 去向 |
|------|------|
| 物理中断 | L0(只能host收) |
| L1的GIC访问(GICD/GICR/ITS MMIO) | trap到L0，vGIC模拟 |
| L2的GIC配置(ICC_*_EL1等) | 按L1的ICH_HCR配置trap进vEL2，L1直接收 |
| L2的IAR/EOI/DIR | 原生，不trap |
| L2的SGI | L1的vgic拦截后写目标vCPU的ICH_LR(VNCR)，L0兑现 |


## 四类中断

### vPPI

两层都是LR的事：L0把物理PPI注进L1的LR(物理LR装L1的中断)，L1处理后把
自己的LR写进VNCR给L2。timer就是典型：irq27到irq28的映射发生在L1的
vGIC里，L0只在pINTID翻译时把L1视角的中断号换成真实硬件号。

### vSPI

L0的vgic软件分发(ap_list)，L1收到后由L1的vgic软件决策转发给L2，同样
落在VNCR的LR上。

### vSGI

L2的ICC_SGI1R由L1的vgic拦截(按L1的配置)，L1软件计算出目标vCPU并写各
自的ICH_LR(VNCR)，L0在进对应L2时兑现。全软件路径。

### vLPI

最复杂，细节待挖(todo)：

1. L1的vITS是L0模拟的(ITS命令trap到L0)
2. L2的vLPI由L1通过ITS命令编程
3. GICv4/v5硬件直通(VLPI、vPE映射)下L0要管理vPE和物理PE的对应
4. GICv5(plan里的doing项)在这块另有变化


## 参考

- vgic.c:1070 kvm_vgic_sync_hwstate嵌套分支
- vgic.c:1130 kvm_vgic_flush_hwstate嵌套分支
- vgic-v3-nested.c:140 vgic_compute_mi_state
- vgic-v3-nested.c:224 translate_lr_pintid
- vgic-v3-nested.c:237 vgic_v3_create_shadow_lr
- vgic-v3-nested.c:271 vgic_v3_flush_nested
- vgic-v3-nested.c:278 vgic_v3_sync_nested
- vgic-v3-nested.c:333 vgic_v3_load_nested
- vgic-v3-nested.c:366 vgic_v3_put_nested
- vgic-v3-nested.c:396 vgic_v3_handle_nested_maint_irq
- vgic.h:170 vgic_ich_hcr_trap_bits
