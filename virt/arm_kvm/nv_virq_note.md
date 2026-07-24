NV vIRQ的逻辑
==============

-v0.1 2026.07.24 Sherlock init
-v0.2 2026.07.25 补充vPPI四情形分析和中断注入规则
-v0.3 2026.07.25 修正vPPI直通说法，补充vLPI嵌套逻辑

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

以vtimer为例(物理irq27分时复用，同时服务L1的hvtimer和L2的vtimer)。
物理EL1 vtimer同一时刻只装一份状态：谁在跑，硬件里装谁的状态
(direct)，另一份由L0的hrtimer软件模拟(emulated)。四种组合：

| 谁在跑 | 谁的时钟到点 | 走的路径 | 最终谁收到 |
|--------|-------------|----------|-----------|
| L1 | L1的hvtimer | 物理irq27，direct，硬件转发表 | L1收到28(27->28) |
| L1 | L2的vtimer | hrtimer，注入27进L1的vGIC | L1的vgic处理，转发L2 |
| L2 | L2的vtimer | 物理irq27，direct，硬件转发表 | L2收到27(27->27) |
| L2 | L1的hvtimer | hrtimer，注入28进L1的vGIC，IMO唤起 | L1在vEL2收到28 |

四个情形的细节：

1. L1在跑，L1的时钟到点：物理irq27响，GICv4硬件转发表把它投给vPE并
   翻译成28，L1读IAR拿28，零软件参与。L0的handler只记账，投递是硬件
   干的。

2. L1在跑，L2的时钟到点：纯软件接力。hrtimer响，L0注入27进L1的vGIC
   (顺带在CNTV_CTL发布ISTATUS位)；L1的vgic被唤起，认出"这是我的guest
   的时钟"；L1写自己的ICH_LR(vINTID=27、pINTID=28、HW位)进VNCR；L2
   下次上CPU时L0照抄这份决定，并把pINTID 28翻译回真实物理27；L2读
   IAR拿27。注意这条链的两层映射：L2的27 <- L1眼里的硬件28 <- 真实
   物理27，两级HW直通逐层翻译。

3. L2在跑，L2的时钟到点：与情形1对称，物理irq27响，转发表27->27投给
   L2，零软件。

4. L2在跑，L1的时钟到点：与真实hypervisor被自己的时钟打断而它当时在
   跑guest的情形一样。hrtimer响，注入28进L1的vGIC；但L1没在跑，L0
   检查L1的虚拟HCR_EL2.IMO，置位就以IRQ异常的形式注入vEL2
   (KVM_REQ_GUEST_HYP_IRQ_PENDING)，L1从L2的运行中被唤起，在自己的
   异常处理里收28。

规律总结：

- direct的两个格子(1/3)：物理中断走硬件转发表，投给当前在跑的那份，
  分时复用保证不歧义
- emulated的两个格子(2/4)：hrtimer是per-context的软件对象，归属在
  创建时就定了，注入的目标永远是L1的vGIC(27表示"guest的时钟"、28表
  示"自己的时钟"，L1自己认)
- 中断号呈现(27还是28)由进入时的转发表重映射决定，不是运行时判断
- 一般中断(SPI等)没有分时复用，规则退化成两条：永远注入L1的vGIC；
  L2在跑时L1有pending就用IRQ异常唤起vEL2

timer之外的vPPI没有分时复用，而且基本没有直通。全内核里
kvm_vgic_map_phys_irq的调用者只有arch_timer.c：物理中断映射进vGIC的
只有timer的四个PPI。PMU中断(pmu-emul.c)是kvm_vgic_inject_irq纯软件
注入，没有任何物理映射。所以vPPI的直通只有timer一家，分两层看：

- L1的vPPI：L0的vgic提供。timer四个有物理备份(HW位LR加forwarded机
  制，物理中断直接经LR呈递给vCPU接口)，其他vPPI(PMU 23、MI 25)是
  L0软件注入的纯虚拟中断
- L2的vPPI：L1的vgic提供，全部通过VNCR的LR复制投递。HW位只可能出
  现在timer的LR上，因为只有timer在L1的vGIC里有物理映射，L1才有硬
  件可直通给L2(pINTID=28，L0翻译成27)；其他vPPI在L1的vGIC里没有
  物理备份，LR必然无HW位，纯虚拟

maintenance interrupt(PPI 25)特殊：L1的那份由L0生成(物理MISR pending
时注入)，L1给L2的那份由L0按VNCR的LR状态软件计算MISR后注入。

一句话：vPPI的硬件直通只存在于有物理备份的那一层的那一类，即L0与L1
层的timer，其余全部是软件LR的层层复制。

### vSPI

L0的vgic软件分发(ap_list)，L1收到后由L1的vgic软件决策转发给L2，同样
落在VNCR的LR上。

### vSGI

L2的ICC_SGI1R由L1的vgic拦截(按L1的配置)，L1软件计算出目标vCPU并写各
自的ICH_LR(VNCR)，L0在进对应L2时兑现。全软件路径，但没有ITS那层：
映射是静态的，只有一层软件。L1自己的SGI(L1的vCPU之间的IPI)由L0按
普通guest SGI处理，无嵌套特判。

### vLPI

vLPI的嵌套特征是两层ITS软件叠加，和vPPI的静态映射完全不同：

1. L1的vITS：L0模拟的(vgic-its.c)。vgic-its.c里没有任何嵌套特判，
   对L0来说L1就是普通guest，ITS命令trap到L0由vgic-its软件处理。
   物理LPI到L1：软件注入，或GICv4的VLPI硬件直通(vPE转发表，DVI)

2. L2的ITS：L1的软件模拟的(guest KVM自己的vgic-its实现跑在L1里)。
   L2的ITS MMIO访问trap进vEL2(L1)，由L1的vgic-its软件处理

3. 两层软件叠加的命令流：
   L2的ITS命令 -> trap进L1 -> L1的vgic-its软件处理
   -> L1访问自己的vITS -> trap到L0 -> L0的vgic-its软件处理
   -> L0的vGIC状态

4. L2的LPI投递：L1的vgic写ICH_LR(VNCR，vINTID大于等于8192的LR表示
   LPI) -> L0 shadow LR兑现 -> L2读IAR拿LPI。投递环节和vPPI一样走LR
   复制，差异在建立映射的命令流是两层软件

5. 直通的天花板：GICv4只有一层vPE，VLPI硬件直通只能到L1；L2的LPI
   直通需要GICv5的嵌套vPE支持，vgic-v5.c的shadow结构是这块的雏形
   (todo: GICv5细节待挖)

四类中断的共同骨架：投递环节统一是"L1写VNCR的LR，L0在进L2时兑现"；
差异在映射和命令流的建立环节：vPPI无(静态映射)、vSGI一层软件、
vLPI两层软件(ITS)、vSPI一层软件加ap_list。


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
