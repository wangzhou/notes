ARM64硬件嵌套虚拟化(FEAT_NV2/NV3)基本逻辑分析
===

-v0.1 2026.07.20 Sherlock init

简介:分析ARM64硬件辅助嵌套虚拟化的基本逻辑,聚焦最新的FEAT_NV2/NV3,
从EL2寄存器模拟、vEL2异常处理、vEL2 stage-2翻译、timer、中断(GICv3)、
SMMU六个角度,说明KVM如何在只有一份物理EL2的硬件上模拟出三层管理者。


## 背景:一个"缺了一层"的架构

ARM64物理上只有四个异常级EL0/EL1/EL2/EL3,而且物理EL2只有一份。嵌套
虚拟化要在一台机器上叠三层管理者,映射关系如下:

| 角色 | 认为自己在 | 物理实际在 | KVM术语 |
|---|---|---|---|
| L0宿主hypervisor(KVM) | EL2 | EL2(真) | host |
| L1客户hypervisor | EL2 | EL1 | vEL2(虚拟EL2) |
| L2嵌套客户内核 | EL1 | EL1 | vEL1 |
| L2应用 | EL0 | EL0 | EL0 |

核心矛盾:L1以为自己独占EL2,但物理EL2被L0占着。于是L1被降级到物理
EL1,而L0必须伪造出一个EL2的假象。整套NV就是围绕这个伪造展开。

L1一般是VHE(HCR_EL2.E2H=1)hypervisor,KVM的NV模型也主要围绕VHE的L1
构建。相关基础见[[arm64_exception_vector_analysis]]。


## 核心机制:三种手段

硬件手段只有三类,后面每个子系统都是这三招的组合:

1. 寄存器内存重定向(FEAT_NV2/NV3的硬件新增能力):让L1读写它的EL2
   寄存器落到内存,不陷出。
2. 影子化(shadow):对硬件只有两级、却要模拟三级的有状态资源(stage-2
   页表、GIC CPU接口、SMMU S2),L0把L1的配置与自己的配置合成一份真
   硬件用的影子。
3. 陷入模拟(trap and emulate):对少数关键动作(ERET、异常注入、TLBI、
   AT、控制类寄存器)仍陷出到L0做软件模拟。

三代特性的定位:

| 特性 | 版本 | 定位 |
|---|---|---|
| FEAT_NV | v8.3 | 定义NV/NV1位与纯陷入模型,是NV2的架构前提 |
| FEAT_NV2 | v8.4 | VNCR内存重定向,KVM的最低硬件基线 |
| FEAT_NV3 | 后续 | NV2增量补强,对KVM软件模型基本透明 |

需要澄清一个常见误解:主线KVM是"FEAT_NV2 only",但这不等于主线不用
FEAT_NV。ID_AA64MMFR2_EL1.NV字段0b0001表示FEAT_NV、0b0010表示
FEAT_NV2。在v8.4的经典编码下,实现FEAT_NV2即蕴含FEAT_NV(NV2 implies
NV);到ARMv9.5又允许"仅NV2"实现,此时NV字段报0(仿佛未实现NV),改由
ID_AA64MMFR4_EL1.NV_frac=1来表示支持NV2。无论哪种编码,HCR_EL2的
NV/NV1控制位在NV2运行时都仍然存在且被KVM使用,例如ERET陷入L0这个
同步点就靠HCR_EL2.NV=1实现(ERET是唯一在v8.3前不是UNDEF、需要专门
handler的指令)。

结论:如果一块硬件只实现了FEAT_NV而没有FEAT_NV2,主线KVM无法为其提供
嵌套支持。门控在cpufeature ARM64_HAS_NESTED_VIRT:它仅当
ID_AA64MMFR2_EL1.NV不低于NV2(0b0010),或ID_AA64MMFR4_EL1.NV_frac
指示NV2_ONLY时才置位。纯FEAT_NV(NV=0b0001)两个条件都不满足,于是KVM
拒绝,用户态无法给vCPU置KVM_ARM_VCPU_HAS_EL2。实践中这是理论情形:
没有已知硬件仅实现FEAT_NV而不含FEAT_NV2,纯NV被称作"old and useless"
的变体。主线正式支持(补丁标题即"Nested Virtualization support
(FEAT_NV2 only)")于2025年合入mainline(约v6.14),早期RFC的纯NV软件
路径在并入时被移除。


## 一、EL2寄存器模拟(NV2/NV3核心)

这是NV2相对NV唯一但决定性的进步。

FEAT_NV的做法是纯陷入:HCR_EL2.NV=1后,EL1访问任何EL2寄存器、执行
ERET都陷入EL2。一个VHE hypervisor启动就是成千上万次陷出,不可用。

FEAT_NV2引入VNCR内存重定向。注意NV位并未被取消:在HCR_EL2.NV=1保持
不变(ERET等仍陷出)的基础上,再置HCR_EL2.NV2=1时,EL1对一大批*_EL2
寄存器的访问不再陷出,而是被硬件重定向到一页内存:

- VNCR_EL2(物理寄存器,L0编程)保存一页4KB内存的基址;
- 每个被重定向的EL2寄存器在这页里有架构固定的偏移;
- L1读写TTBR0_EL2/VTTBR_EL2/VBAR_EL2/SPSR_EL2等,硬件直接访存该页对
  应偏移,零陷出;
- L0需要L1的真实值时(切换、建影子表、注入异常),直接读这页内存。

一句话:NV2把一堆系统寄存器写变成了内存写。

KVM侧实现要点:

- 每vCPU一页vncr_array,VNCR()宏在vcpu_sysreg枚举里给每个可重定向
  寄存器登记偏移;
- vncr_tlb结构跟踪这页的虚实映射,内存变动时失效;
- sanitising(净化):L1写入的值不能直接生效,L0要过滤掉L1不该看到或
  不该改的特性位,防止L1借此看到不存在的能力或破坏L0。

仍然陷出的部分(NV2的边界):门控trap行为、或需L0立即响应的寄存器/
动作仍陷出:

- HCR_EL2、CPTR_EL2、MDCR_EL2、HSTR_EL2、细粒度陷入HFGxTR_EL2,它们
  决定什么东西该陷给谁,L0必须知道L1改了什么才能重算陷入路由;
- ERET、TLBI、AT指令,本身就是要L0做动作。

FEAT_NV3的增量,就是继续把上面这条陷出清单往内存里搬:

- 新增NVHCR_EL2(Nested Virtual HCR):为L1的HCR_EL2提供一份内存里的
  虚拟视图,除TGE位外其余位仅作存储、不影响PE行为。L1反复读写它自己
  的HCR_EL2也不陷出,真正影响路由的语义由L0在陷出点(如ERET)统一结算;
- HCRX_EL2变为VNCR-backed(内存重定向);
- 把NV2下几处零散陷出补进内存,进一步降低L1配置动作的陷出率。

结论:NV2解决了寄存器访问这个最高频的陷出源,NV3收尾把剩余控制寄存器
也搬进内存,对KVM是少几张trap handler加几张sanitise表,不改变架构。


## 二、vEL2异常处理

L0要让L1相信自己在EL2,关键是异常进出EL2的语义要真。

维护虚拟EL2态:硬件上vCPU始终在物理EL1,是不是vEL2完全靠KVM软件标记
(is_hyp_ctxt()判断虚拟SPSR、E2H/TGE等)。所有寄存器视图(_EL1 vs _EL2
vs _EL12别名、VHE语义)都据此切换。

陷入路由(往哪一层送):L2触发一个事件(异常/陷出),L0拿到后要判定归谁:

- L0自己处理(如缺页需补L0的S2);
- 直接返还L2;
- 或上送到L1的vEL2,只要L1通过它的虚拟HCR_EL2/CPTR_EL2/MDCR_EL2/
  HSTR_EL2/细粒度陷入配置要求陷这一类事件。

L0必须组合评估L1的虚拟陷入配置(NV3后大多在内存里读)来决策,这是NV
最繁琐的软件逻辑之一。

向vEL2注入异常:决定上送后,L0模拟一次进EL2的完整语义:

- 目标PC等于L1的VBAR_EL2加向量偏移;
- 填好L1会看到的SPSR_EL2/ELR_EL2/ESR_EL2/FAR_EL2/HPFAR_EL2,NV2下
  这些都是VNCR页里的内存写;
- 把vCPU标为vEL2态后恢复到L1向量。

KVM接口:kvm_inject_nested_sync()(同步异常)、kvm_inject_nested_irq()
(中断)。

ERET的模拟是进出L2的枢纽。HCR_EL2.NV=1使L1的ERET陷入L0,这是同步点:

```
L1 config EL2 regs (no trap, write to VNCR page)
   |
   v
L1 ERET  -->  trap to L0 (HCR_EL2.NV = 1)
   |
   +-> read L1 ELR_EL2 / SPSR_EL2 from VNCR page
   +-> resolve VTTBR_EL2 / VTCR_EL2, build / load shadow S2
   +-> switch GIC / timer context
   |
   v
ERET into L2
```

NV2的精髓正在这里:L1配寄存器时零陷出(内存),只在ERET这一个点集中
同步一次。


## 三、vEL2的stage-2翻译(影子S2)

硬件只有一套stage-2(VTTBR_EL2/VTCR_EL2),但嵌套要两层S2:

- L0的canonical S2:L1 IPA到PA,把L1这个VM关起来的那层;
- L1的S2:L2 IPA到L1 IPA,L1给L2建的,写在它的VTTBR_EL2(即VNCR内存)。

跑L2时装进真硬件VTTBR_EL2的,是二者合成的shadow S2:L2 IPA到PA。

```
L2 IPA           L1 IPA            PA
   |                |               ^
   +--- L1 S2 ----->+--- L0 S2 ---->+
   |                                |
   +----------- shadow S2 ----------+
   (loaded into real VTTBR_EL2 when running L2)
```

影子表的构造与语义:

- 对L1用过的每个{VMID, VTTBR, VTCR}三元组,L0建一个独立的s2_mmu影子
  上下文,分配一个真实VMID;
- 影子表按缺页逐条懒构建:L2缺页,L0走L1的S2得L2IPA到L1IPA,再走L0
  的S2得L1IPA到PA,把合成映射填进影子表;
- 若L1的S2里没映射,向vEL2注入stage-2 abort让L1自己处理;若L0的S2里
  没映射,走L0常规缺页;
- 这些影子上下文本质就是TLB/cache:数量有限(KVM按每vCPU同时跑两个
  VM预分配,约2倍vCPU个),随时可丢弃重建。

stage-2页表遍历的通用逻辑见[[KVM_Stage2_PageTable_Walk_Summary]]。

TLBI是最麻烦的部分。L1的TLB维护指令陷出后要正确落到影子表:

- EL2 S1失效:尽早直接软件模拟;
- EL1 S1失效:施加到影子表;
- TLBI VMALLS12E1/ALLE1/IPAS2E1等S1加S2组合失效、FEAT_TTL层级提示、
  outer-shareable、range-based(范围)、NXS变体,KVM都要逐一翻译成对
  相应影子上下文的失效。这块占了影子S2补丁系列的大半篇幅。


## 四、Timer

计时器有多套:EL1物理/虚拟(CNTP/CNTV)、EL2物理/虚拟(CNTHP/CNTHV,
CNTHV需VHE)、偏移量CNTVOFF_EL2/CNTPOFF_EL2、控制寄存器CNTHCTL_EL2。

嵌套要点:

- 模拟EL2定时器:L1 hypervisor自己要用CNTHP_*/CNTHV_*,L0必须把这两组
  EL2定时器完整仿真出来;
- 偏移量的级联:硬件CNTVOFF_EL2被L0用来给L1的虚拟计数器打偏移,而L1又
  想给L2打偏移。跑L2时,L0要把L1的CNTVOFF传播/合成进虚拟定时器的偏移
  (KVM的"Propagate CNTVOFF_EL2 to the virtual EL1 timer"补丁,就是把
  CNTVOFF_EL2访问直接接到vtimer的TIMER_REG_VOFF),保证L2看到的时间
  基准正确;
- FEAT_ECV(增强计数器虚拟化)对嵌套很关键:提供CNTPOFF_EL2(物理定时器
  偏移)和CNTHCTL_EL2.ECV等,让物理定时器也能无陷出地打偏移,否则L1给
  L2虚拟物理定时器就得靠陷出,代价很高。CNTPOFF细节见[[ARM64_CNTPOFF分析]];
- 中断注入:L1的EL2定时器到点后产生的中断,要注入到vEL2(经第五节路径),
  且KVM需注意先加载timer再加载GIC的顺序。


## 五、中断(GICv3)

GICv3硬件虚拟化靠虚拟CPU接口:一组ICH_*_EL2寄存器(ICH_HCR_EL2控制、
ICH_VMCR_EL2、ICH_LR<n>_EL2 List Register、ICH_AP0R/AP1R)。Hypervisor
往LR写待注入的虚拟中断,guest通过ICC_*_EL1系统寄存器接口消费,硬件把
二者自动对接。

嵌套难点:物理虚拟CPU接口只有一份(一组LR),但L1想用它给L2注入中断。
于是L0影子化整个CPU接口:

- L1的ICH_*访问,一部分NV2已做内存重定向(VNCR页给GIC CPU寄存器留了
  偏移),但LR和控制位仍需L0介入;
- L0维护影子GIC状态shadow_vgic_v3/nested_vgic_v3:跑L2前,把L1编程的
  LR(L1视图)校验、翻译后写进真硬件LR;
- HW位必须软件模拟:L1的LR里HW位加物理INTID,本意是L2 EOI时硬件自动
  deactivate那个物理中断,但L1给的物理INTID不是真的。L0得清掉/改写HW
  位,自己接管deactivation;
- 维护中断(maintenance interrupt)上送:GIC在LR需补充/underflow/EOI等
  条件下产生维护中断;若L1靠它管理自己的LR,L0必须把维护中断转发到
  vEL2。KVM判据:vgic_state_is_nested()且ICH_HCR_EL2.EN置位且
  ICH_MISR_EL2(MISR)有pending,则调kvm_inject_nested_irq();
- LR数量/分发器:ICH_VTR_EL2报告LR个数,L0给L1呈现的LR数可能少于硬件,
  需溢出到内存并靠维护中断轮转;L2的GIC分发器/重分发器由L1软件模拟,
  L0主要管CPU接口;
- 限制:GICv4的直接注入(vLPI/vSGI)对嵌套hypervisor不支持(虚拟ITS的
  ABI Revision 0只给虚拟GICv3语义),L2的LPI只能走软件路径。


## 六、SMMU(SMMUv3)

SMMUv3天生两级翻译,与CPU同构:

- Stage-1:VA到IPA,由guest拥有(Stream Table Entry指向Context
  Descriptor,再指向S1页表);
- Stage-2:IPA到PA,由host拥有(STE里的S2配置)。

场景一,单层虚机加vSMMU(嵌套翻译,最成熟):给guest一个自己的IOMMU
并直通设备,guest管S1,host管S2,硬件依次做S1到S2。Linux经iommufd
嵌套域落地:

- 父域等于host管的S2硬件页表;子域(nested/S1)等于guest管的页表,host
  把guest的STE/CD配置装进物理SMMU;
- guest通过它的vSMMU命令队列发TLBI/CFGI失效,被QEMU陷获,经iommufd
  转成对物理SMMU的失效;
- QEMU侧属性arm-smmuv3.stage=nested,向guest通告IDR0.S1P=1且IDR0.S2P=1。

场景二,真嵌套虚拟化(L1给L2分设备):L1要有自己的vSMMU、自己的S2做
DMA隔离。但物理SMMU还是只有S1加S2两级,和CPU同样的困境,于是需要影子
SMMU S2:把L1的S2与L0的S2合成一份真SMMU用的S2,再叠加guest的S1。这条
路径与CPU的shadow S2完全同构,但工程上仍在演进(命令队列/事件队列/PRI
故障路由、MSI经ITS的IPA处理都要额外做);近期可落地的主要是场景一的
guest S1加host S2。

配套还要处理:命令队列(失效)陷获转发、事件/故障队列从物理SMMU路由回
正确的guest、以及MSI(SMMU与ITS协作,MSI是被翻译的内存写)在嵌套下的
地址处理。


## 小结:影子化加内存重定向的统一图景

硬件只提供两级(一套S2、一套虚拟CPU接口、两级定时器),NV用三种手段
模拟出第三级:

| 资源 | 硬件给几级 | NV的手段 |
|---|---|---|
| EL2寄存器 | 无 | 内存重定向(NV2的VNCR,NV3扩到HCRX/NVHCR) |
| 异常/ERET | 无 | 陷入模拟(ERET陷出做同步点) |
| stage-2页表 | 1套 | 影子S2(合成L1乘L0,像TLB一样懒建/丢弃) |
| 定时器 | EL1加EL2两级 | 仿真EL2定时器加偏移级联(靠ECV免陷出) |
| GIC CPU接口 | 1套LR | 影子GIC加HW位软件模拟加维护中断上送 |
| SMMU | S1加S2两级 | guest S1加host S2直连;更深嵌套需影子SMMU S2 |

NV2是分水岭:它把最高频的寄存器访问从陷出变成访存,使嵌套第一次有了
可用的性能;NV3是收尾,把剩余控制寄存器也搬进内存。而影子化(S2/GIC/
SMMU)是硬件永远给不了的那一级,只能靠L0软件在陷出点(尤其ERET)集中
合成,这部分不会因NV几代演进而消失,是嵌套虚拟化复杂度与开销的真正
来源。与x86虚拟化PV特性的横向对比见[[x86_vs_ARM64_虚拟化PV特性对比分析]]。


## 参考文件

代码/机制来源:

- KVM嵌套虚拟化补丁系列(FEAT_NV2 only,v11):
  https://lore.kernel.org/kvm/3b51d760-fd32-41b7-b142-5974fdf3e90e@os.amperecomputing.com/T/
- ID_AA64MMFR2_EL1的NV字段编码(Arm):
  https://developer.arm.com/documentation/ddi0595/2020-12/AArch64-Registers/ID-AA64MMFR2-EL1--AArch64-Memory-Model-Feature-Register-2
- arm64: Add ARM64_HAS_NESTED_VIRT cpufeature:
  https://patchwork.kernel.org/project/kvm/patch/20190621093843.220980-4-marc.zyngier@arm.com/
- arm64: cpufeature: Handle NV_frac as a synonym of NV2:
  https://patchwork.kernel.org/project/kvm/patch/20250220134907.554085-2-maz@kernel.org/
- KVM: nv: Configure HCR_EL2 for nested virtualization:
  https://www.spinics.net/lists/kvm/msg260958.html
- KVM影子stage-2页表处理(LWN):https://lwn.net/Articles/969342/
- KVM嵌套虚拟化综述(LWN):https://lwn.net/Articles/919851/
- Arm AArch64虚拟化指南,Nested virtualization:
  https://developer.arm.com/documentation/102142/latest/Nested-virtualization
- NVHCR_EL2寄存器(Arm,FEAT_NV3):
  https://developer.arm.com/documentation/111107/2026-06/AArch64-Registers/NVHCR-EL2--Nested-Virtual-Hypervisor-Configuration-Register
- KVM: nv: Add sanitising to VNCR-backed HCRX_EL2:
  https://lists.infradead.org/pipermail/linux-arm-kernel/2024-February/904065.html
- KVM: nv: Propagate CNTVOFF_EL2 to the virtual EL1 timer:
  https://lore.kernel.org/linux-arm-kernel/20190621093843.220980-48-marc.zyngier@arm.com/
- KVM: nv: Nested GICv3 Support:
  https://www.mail-archive.com/kvmarm@lists.cs.columbia.edu/msg33085.html
- SMMUv3 nested translation support(QEMU):
  https://www.mail-archive.com/qemu-devel@nongnu.org/msg1055025.html

相关笔记:

- [[arm64_exception_vector_analysis]]
- [[KVM_Stage2_PageTable_Walk_Summary]]
- [[ARM64_CNTPOFF分析]]
- [[x86_vs_ARM64_虚拟化PV特性对比分析]]
