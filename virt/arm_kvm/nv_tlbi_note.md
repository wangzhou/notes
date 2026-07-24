NV TLBI trap的逻辑
==================

-v0.1 2026.07.24 Sherlock init

简介：整理ARM嵌套虚拟化下TLBI的完整逻辑。普通虚机的TLBI由硬件原生执行；
嵌套虚机(L0/L1/L2三层)中vEL2发出的TLBI按目标物分为三类，都必须trap到
L0处理，三类分别对应三种不同的物理约束。本文还展开VNCR机制(第二类trap
的根基)，以及FEAT_NV3对这块的硬件化方案。本文是ARM64嵌套虚拟化的基本
逻辑.md中TLBI章节的详细展开。


## 背景

嵌套虚拟化三层术语沿用主笔记：L0 host kvm(EL2)、L1 guest hypervisor
(vEL2)、L2 nested guest(EL1/EL0)。

VHE下硬件支持VMID-tagged TLB，每个TLB条目带当前VMID标签。普通虚机
(非嵌套)的HCR_EL2不做TLB trap配置，guest执行的TLBI由硬件直接执行，
只刷掉自己VMID的条目，天然隔离。唯一例外：没有FGT且硬件不支持TLB OS
时，HCR_TTLBOS被置位单独trap OS变体TLBI(range形式只有OS变体有)。

嵌套虚机的TLBI分两个视角：L2自己刷自己的S1(默认原生执行)，以及vEL2
(L1)发出的TLBI(全部trap到L0)。本文主体讨论后者，按目标物分为三类。


## vEL2 TLBI的三类分类

| 类别 | 指令族 | 目标物的物理性质 | L0的处理 |
|------|--------|------------------|----------|
| 刷vEL2的S2 | VMALLS12E1/IPAS2E1/RIPAS2E1族 | 纯软件(shadow S2) | unmap shadow S2 |
| vEL2作为host刷自己 | EL2名+E2H下EL1名 | 半真半假 | fast path真实flush+伪TLB簿记 |
| 刷嵌套虚机的TLB | EL12族+guest-flush序列 | 全真(硬件条目) | 切VMID代发真实TLBI |

三类的trap原因完全不同：目标物有多"真"，L0就要处理多少。纯软件、
半真半假、全真三种物理性质一一对号入座。

### 类1: 刷vEL2的S2

指令族：VMALLS12E1IS/IPAS2E1IS/RIPAS2E1IS及其变体。语义是"我的S2页表
改了，旧映射作废"。

硬件从来不walk L1的S2页表，硬件walk的是L0派生出来的shadow S2。L1改
自己的S2页表是普通内存写，shadow S2里的PTE不会跟着变，还是旧映射。
如果这条指令原生执行，硬件只刷掉TLB条目，shadow S2里的旧PTE还活着：
L2下次访问该IPA，硬件walk命中旧PTE，把旧翻译重新填回TLB，L2访问到L1
已经unmap掉的内存。所以L0必须trap进来，把对应IPA从shadow S2页表里
真正删掉(unmap)，顺带刷TLB。刷缓存硬件能做，删派生数据只有知道派生
关系的L0能做。

两个关键点：

1. 页表改动和TLBI是两件事，但架构契约保证TLBI是完备的挂钩点：
   hypervisor改完S2页表必须执行对应TLBI改动才生效(改页表→DSB→TLBI)。
   所以L1的任何S2改动生效前必然跟着一条TLBI，trap住TLBI就能完整同步。

2. 同步动作是"删"不是"改"，而且必须eager：TLBI trap时把shadow条目
   删掉，之后L2访问缺页走fault路径按新页表重建。作废不能等fault，
   因为unmap没有后续信号——留着旧PTE硬件会直接服务旧PA，不产生任何
   异常，L0永远没机会纠正。建映射那一侧(eret trap)可以lazy，作废这一
   侧只有TLBI这一次信号。

### 类2: vEL2作为host刷自己的TLB

指令族：EL2名(ALLE2/VAE2/VALE2)，以及E2H下EL1名(VMALLE1/VAE1/...)。
语义是刷vEL2自己的EL2&0 regime。

vEL2的TLB是两半拼起来的：真的一半是L1自己执行的翻译(真实硬件条目，
VMID标记)；假的一半是VNCR相关的簿记(L0照L1页表抄的副本，软件结构)。
trap就是为了维护假的那半，真的那半硬件能刷。

trap触发：NV2硬件把EL2名TLBI重定向成EL1名等价物(alle2is→vmalle1is，
假装vEL2的TLB是真的)，再被L0强制的物理HCR_EL2.TTLB拦住。TTLB trap
是NV重定向的豁免，一律进EL2(L0)，不会投递到vEL2。

L0的处理分两层：

- fast path(hyp内，无完整exit)：代发一条变换后的TLBI
  (__kvm_tlbi_s1e2，ALLE2→VMALLE1IS、VAE2→VAE1IS、VALE2→VALE1IS，
  OS→IS、nXS→XS)刷掉真的一半。NULL mmu表示不切VMID，利用exit刚发生
  时当前translation context仍是L1的。vncr_map_count为0时直接跳过指令
  回guest，代价是一次trap加一条TLBI。

- 慢路径(完整exit，拿mmu_lock)：vncr_map_count大于0时退回，只做伪TLB
  失效(kvm_handle_s1e2_tlbi→compute_s1_tlbi_range解析scope→
  invalidate_vncr_va)，真实flush在fast path已经做过。

如果没有VNCR，这一整类trap都不需要：fast path的机械动作和硬件原生
执行一模一样，代码注释自己也承认理想情况是never trap。不能动态关
TTLB的两个现实约束：vncr_map_count运行中可变(首个VNCR访问fault时才
建映射)，vTGE无法跟踪(NV2让L1写HCR_EL2不trap，L0不知道L1何时在
InHost和guest-mode之间切换)。

### 类3: 刷嵌套虚机的TLB

指令族：EL12编码族，以及KVM实际使用的guest-flush序列。语义是刷L2的
S1 TLB。目标物全真：L2的S1条目是真实硬件条目，翻译数据就是硬件walk
的那份，没有副本问题。

trap的原因是VMID名字空间错位：L1的指令作用的是自己虚拟VTTBR_EL2里
的VMID(L2的VMID)，但L1执行指令时物理VTTBR_EL2装着L1自己执行的VMID
(两者必须不同，L1自己和L2是不同的逻辑机)。硬件原生执行会按物理
VTTBR的VMID刷，刷的是L1自己的(基本空的)条目，L2的条目纹丝不动。

KVM的guest-flush序列天然撞进现成的trap：L1刷L2的TLB用VHE标准套路，
先清虚拟TGE(写VNCR，不trap)，再发EL1名TLBI(被常驻TTLB拦住)。L0进
handler看虚拟HCR_EL2.{E2H,TGE}={1,0}，认出这是L1在替L2刷S1，走
handle_tlbi_el1的else分支：kvm_s2_mmu_iterate_by_vmid按虚拟VTTBR_EL2
的VMID遍历shadow S2(一个虚拟VMID对应多个shadow S2，每个L2 vCPU一
个)，逐个enter_vmid_context切VMID、代发真实TLBI。VA场景不删任何数据，
纯硬件操作，离原生只差VMID翻译这一步。全量场景(ALLE1族)由
handle_alle1is直接drop全部shadow S2。

### L2自己刷自己的S1

L2自己的EL1名TLBI默认原生执行：vTTLB为0时，guest context下物理TTLB
等于vTTLB合并值(见下)，没有trap。L2运行时vTGE=0，有效E2H=0，EL1名
TLBI语义正确指向L2自己的S1，条目带L2自己的VMID/ASID，硬件自给自足。

L1配了trap(vTTLB=1)时才被拦，且只经L0转发：triage_sysreg_trap查L1的
虚拟trap配置，发现是L1自己要的trap，用kvm_inject_nested_sync原样注入
回vEL2，L0不代做。L0自己的TLBI handler从不处理L2的TLBI，handle_tlbi_el1
开头有WARN_ON(!vcpu_is_el2(vcpu))，注释明说never called in a vEL1
context。


## trap触发与转发

物理HCR_EL2的TTLB按vCPU语境有两种来源(vhe/switch.c的__compute_hcr)：

- vEL2 InHost语境(虚拟E2H&TGE都置位)：L0强制置位
  HCR_NV|HCR_NV2|HCR_AT|HCR_TTLB，L1的trap配置不合并。

- guest语境(L2运行)：物理TTLB等于L1的vTTLB合并值。TTLB故意不在
  NV_HCR_GUEST_EXCLUDE排除列表里，L1的trap配置对L2硬件生效。

TTLB trap是NV重定向的豁免：NV=1时EL1到EL2的异常本应重定向到vEL2，
但TTLB/AT引起的trap仍然进EL2(L0)。因为同一个控制位同时服务于L1拦L2
和L0拦L1两个用途，硬件无法区分该谁收，统一送L0由软件triage转发。

triage在emulate-nested.c的triage_sysreg_trap：compute_trap_behaviour
查L1的虚拟trap配置(读VNCR里的vHCR_EL2/vHFGITR)，是L1自己要的trap则
注入vEL2，否则L0按sys_insn_descs表本地处理。


## VNCR机制

第二类trap的根基是VNCR，这里展开。

### VNCR内存是谁的

VNCR那块内存是L1的：L1的KVM给自己的vCPU分配VNCR页，把虚拟VNCR_EL2
指向自己的虚拟地址，随时可以重映射换位置。这块内存就是"vEL2的寄存
器"，L1的mrs/mrs对EL2寄存器的访问被NV2重定向成对这块内存的访问。
L1完全知道并掌控它。

L0的角色是让硬件够得着：硬件做VNCR访问时，按ARM的规则走物理EL2&0
翻译(host的页表)，所以L0必须在host页表里为这块内存建一条映射。

### 硬件用什么翻译VNCR

物理VNCR_EL2(BADDR)里放的是host内核虚拟地址(per-CPU fixmap槽)，硬件
翻译它走物理EL2&0 translation regime的stage-1，即host的内核页表：
VHE下这组页表的基地址在TTBR0_EL2/TTBR1_EL2里，fixmap是高地址区间，
走TTBR1_EL2(swapper_pg_dir)，不是用户态页表。没有stage 2。

关键事实：EL2命名组(TTBR0_EL2/TTBR1_EL2/TCR_EL2)和guest用的EL1命名
组(TTBR0_EL1/TTBR1_EL1/TCR_EL1)是两套独立的物理状态。guest切换只动
EL1命名组，host的内核页表永远挂在那里，任何时候(不管L1/L2谁在跑、
guest页表什么状态)硬件都能直接翻译VNCR地址。

### L1的VA和fixmap VA怎么对应

两者没有VA层面的对应关系，是通过PA接上头的：同一个物理页在两个地址
空间里的两个名字。

```
L1-VA (virtual VNCR_EL2)          fixmap VA (physical VNCR_EL2)
    |                                  ^
    | L0 walks L1's EL2 stage-1        | host kernel page table
    v                                  | (TTBR1_EL2)
   IPA --(L1's stage-2, memslot)--> PA
```

三步接起来：

1. L0软件走L1的EL2页表(kvm_translate_vncr，regime TR_EL20)，把L1-VA
   翻译成IPA；再过L1的S2(kvm的memslot表，gfn_to_memslot加faultin_pfn)
   得到真实PA。语义上IPA的下一步是PA，不是host HVA；faultin_pfn内部
   对HVA-backed memslot会一闪而过QEMU的HVA，那是KVM找任何guest页的
   pfn都走的内部路径，与VNCR机制无关。

2. L0在host内核页表里建fixmap VA到PA的映射，物理VNCR_EL2设为fixmap
   VA。

3. 硬件访问fixmap VA，走host页表到达PA，和L1通过自己的VA访问到的是
   同一块物理内存。

必须绕PA的原因：两边约束在VA层面无法调和——左边必须是L1的VA(L1的代
码拥有它，虚构的一部分)，右边必须是host的VA(异常交付只能走永远有效
的host页表)，只能让PA当接头。L1改VNCR_EL2后，联系断在PA上，左半边
重新走表、右半边重新fixmap，两边都要重接。

### 伪TLB和TLBI的关系

伪TLB(vncr_tlb)记的是gva→ipa→pa加权限，是照L1页表抄的副本。副本的
有效性挂在L1的翻译上：L1改页表(比如重新映射VNCR页)后按架构惯例刷
TLB，L1的TLBI就是"旧翻译作废"的信号，L0必须把副本一起作废，下次
VNCR访问时重新照抄。这就是L1的TLBI到达L0时顺带失效伪TLB的原因——
不是L1在关心L0的簿记，而是L0的簿记底稿过期了。MMU notifier则按IPA
方向失效(kvm_invalidate_vncr_ipa)。

### 为什么硬件用host翻译

如果VNCR地址走L1自己的EL2页表：读TTBR0_EL2/TCR_EL2等要访问VNCR内存
(循环依赖)；walk的是guest内存，可能缺页，而VNCR访问最关键的场合是
L2正在trap进vEL2的当口，异常交付过程中再产生异常没有出口；walk结果
是L1的IPA，还要再过L1的S2(虚拟VTTBR_EL2又在VNCR里，第二层循环)。

走host regime三个问题全部消失：永远有效、无stage 2、fault有明确去处
(带VNCR标志位的data abort进EL2，L0本来就是模拟责任人)。代价就是镜像
机制(软件走表加fixmap加权限照抄)。这笔账的本质：用外层软件的复杂度
换异常交付路径的确定性。

VNCR fault是正常冷启动路径：L0还没建fixmap时，硬件VNCR访问产生带
VNCR位的data abort进EL2，L0走L1页表建伪TLB、建fixmap、重试。不是
错误路径。

### 为什么L1要有虚拟VNCR

VNCR首先是L1的架构状态，不是L0的私事：L1的KVM代码像真hypervisor一样
编程VNCR_EL2，mrs/mrs重定向必须在L1自己的地址空间里发生，否则L1的
代码对寄存器状态的访问全部落空。硬件不用L1的值(异常交付约束)，于是
形成原件与副本的关系：L1的值是原件(会变)，L0的fixmap是副本(硬件实
际用的)，副本必须跟踪原件。


## FEAT_NV3

NV3的设计目标就是消掉上述三类trap，把NV2留给软件的三个"必须插手的
点"全部下沉成硬件行为：

- 类1：硬件双级S2 walk(硬件读L1的VTTBR_EL2/VTCR_EL2，自己完成
  IPA→IPA'→PA)，shadow S2整个消失，没有数据副本需要同步，S2维护
  指令由硬件原生执行。连带解决：shadow S2内存、遍历shadow S2的
  write-protect类操作、L2内层S2缺页的软件注入、主笔记里"EL2怎么知道
  IPA→IPA'映射"的todo。

- 类2：硬件直接翻译VNCR(走L1自己的页表S1+S2)，fixmap嫁接和伪TLB簿记
  整套删除。证据在内核里：伪TLB的分配和失效逻辑gate在NV2_ONLY上
  (nested.c:1007/1330)，NV3硬件上直接跳过。NVHCR_EL2让硬件直接看到
  guest的HCR(不用读VNCR内存)，其中TGE位直接参与硬件行为：ERET不再
  每条trap，回自己的场景直接执行；L1的host TLBI由HCRX_EL2的
  NVTGE/NVnTTLB等位控制trap elision，原生执行。

- 类3：TLB条目带双VMID(内层+外层)，硬件认识L1的VMID名字空间，L1刷
  L2的TLBI直接原生执行命中正确的内层VMID条目。

连带收益：AT指令有了硬件执行的基础(S12的软件走表模拟才有替代品)；
FEAT_NV2p1修了CNTHCTL_EL2/CPTR_EL2从EL1访问时缺stateful bit的问题。
性能上FVP的L1少约1.5%指令，深嵌套(L2/L3)近似模拟显示约40%/60%提升，
trap链越深放大效应越大。

软件侧现状：v7.2内核已用NV3的VNCR硬件翻译(伪TLB跳过)，但shadow S2
机制仍完整存在，NV3也尚未暴露给L1(guest可见的NV_frac伪装成NV2_ONLY)。
还没有解决的：除HCR外的大部分EL2寄存器仍VNCR-backed，NVHCR_EL2只把
最热的HCR单独拎了出来。


## 参考

- ARM64嵌套虚拟化的基本逻辑.md
- arch/arm64/kvm/hyp/vhe/switch.c:50 NV_HCR_GUEST_EXCLUDE定义
- arch/arm64/kvm/hyp/vhe/switch.c:68 强制HCR_NV|HCR_NV2|HCR_AT|HCR_TTLB
- arch/arm64/kvm/hyp/vhe/switch.c:381 kvm_hyp_handle_tlbi_el2 fast path
- arch/arm64/kvm/hyp/vhe/tlb.c:230 __kvm_tlbi_s1e2变换规则
- arch/arm64/kvm/sys_regs.c:3938 handle_alle1is
- arch/arm64/kvm/sys_regs.c:4135 handle_tlbi_el2
- arch/arm64/kvm/sys_regs.c:4147 handle_tlbi_el1(4172的WARN)
- arch/arm64/kvm/sys_regs.c:4030/4109/4054 vmalls12/ipas2/ripas2 handler
- arch/arm64/kvm/emulate-nested.c:742 SR_TRAP表(TLBI条目)
- arch/arm64/kvm/emulate-nested.c:2542 triage_sysreg_trap
- arch/arm64/kvm/nested.c:954 get_asid_by_regime
- arch/arm64/kvm/nested.c:1038 invalidate_vncr_va
- arch/arm64/kvm/nested.c:1206 kvm_handle_s1e2_tlbi
- arch/arm64/kvm/nested.c:1296 VNCR设计注释
- arch/arm64/kvm/nested.c:1360 kvm_translate_vncr(IPA→PA经memslot)
- arch/arm64/kvm/nested.c:1548 kvm_map_l1_vncr
- https://lwn.net/Articles/1084204/ KVM NV2p1/NV3补丁
- https://developer.arm.com/documentation/111107/2026-06/AArch64-Registers/NVHCR-EL2--Nested-Virtual-Hypervisor-Configuration-Register?lang=en
