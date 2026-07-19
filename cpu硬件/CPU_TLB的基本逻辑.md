-v0.1 2026.3.29 Sherlock init
-v0.2 2026.6.22 Sherlock 补齐TLBI三节(指令/Host/虚机)

简介: 收集和ARM TLB硬件相关的知识，基于ARM构架。

## TLB保存类型

TLB在硬件内部一般有三种保存情况：

1. stage1 TLB。

2. combine TLB，也就是stage1和stage2最后综合得到的TLB。

3. stage2 TLB，也就是保存IPA->PA的对应的TLB。

   注意，在虚拟化的场景之下，如果只有combine TLB，TLB miss的成本会比较高，因为
   为了地址翻译还需要做stage2的page table walk。有了stage2 TLB，可以立即得到IPA
   对应的实际物理地址。

从一条TLB覆盖范围看，又可以分为三种情况：

1. 覆盖一个基础页的大小。

2. 覆盖一个block页的大小。

3. 覆盖一个CONT PTE的大小。

一般来说一个PE有一个独立的结构来保存TLB，但是，ARM上新增加了CnP这个特性，可以多个
PE之间共享TLB。具体定义是，如果多个PE的TTBRx_ELx的页表是一样的(包括VMID，ASID)，
同时TTBRx_ELx.CNP配置为1，那么多个PE上的相同TLB可以共享一个TLB。

注意，在虚拟化的情况下，需要TTBRx_EL1.CNP和VTTBR_EL2.CNP都是1，才会创建共享的TLB。
一个直观的硬件实现是，当硬件发现满足共享TLB的条件的时候，就去查找有无共享TLB，如果
没有就创建一个TLB，并打上共享的标记，如果找见共享TLB就直接使用。

## TLBI指令

从如上的TLB类型的角度看下TLBI指令都有哪些。TLB是key-value的存储结构，key是一组数据
的集合，硬件执行TLBI指令就是根据TLBI指令带的输入，去匹配TLB的key，匹配上了，就把
对应的TLB无效化。

一个贴近真实硬件的条目模型如下：
```c
struct tlb_entry {
    /* -- key --  */
    u64 in_addr;        // 输入地址: VA(stage1/combined)或IPA(stage2)
    u8  regime;         // 各种EL1&0/EL2/EL2&0/EL3 translation regime (安全状态NS/S/Realm)
    u16 vmid;
    u16 asid;
    u8  size;
    /* -- value -- */
    u64 pa;
    /* -- attrs-- */
    ...
};
```

TLBI指令名可以拆成三段来读: TLBI <操作><级别><范围>。

- 操作:
  - VA        : 按VA失效(带ASID)。
  - VAA       : 按VA失效，但忽略ASID(all-ASID)。
  - ASID      : 按ASID整体失效。
  - VMALL     : 当前VMID下，该regime的stage1/combined条目全清(不按地址)。
  - VMALLS12  : 当前VMID下，stage1 + stage2 + combined全清。
  - IPAS2     : 按IPA失效，只失效stage2条目。
  - ALL       : 该级别regime全清(不看VMID/ASID)。
  - R*        : 按地址范围(Range)失效，一条指令失效一段区间。
- 级别: E1/E2/E3。
- 范围: 无后缀=本PE local; IS=inner-shareable广播; OS=outer-shareable; nXS=不等XS。

注意，如上ELx级别不是直接指对应EL级别的TLB，ELx结合当前机器所处在的状态(HCR_EL2.E2H/TGE)
会最终决定无效化作用于哪个translation regime，translation regime的定义可以参考[这里](https://wangzhou.github.io/ARM64系统寄存器总结/)。
简单讲，EL1&0 translation regime表示虚机S1+S2的翻译，EL2&0 translation regime表示
VHE host的翻译，EL2 translation regime表示nVHE hypervisor的翻译。

VHE场景下，TLBI xEL1x + TGE为1，表示EL2&0 translation regime，TLBI xEL1x + TGE为0
表示EL1&0 translation regime。所以，guest/host内核使用相同的TLBI xEL1x指令，在guest
和host下均可以做正确的TLBI操作。

TLBI xIPAx表示对stage2 TLB的无效化。

## TLBI使用场景

### Host上TLBI的使用

todo: Host上使用TLBI的场景。

### 虚机上TLBI的使用

分两个视角：guest自己发TLBI，和host(KVM)替guest刷。

- Guest在EL1自己发TLBI

guest执行tlbi vae1is → EL1&0 regime，而当前VTTBR_EL2.VMID就是该guest的VMID，硬件
自动把失效锁定在这台guest。默认KVM不trap guest的TLBI(HCR_EL2.TTLB=0)，guest的TLBI
原生执行、原生按VMID隔离，host完全不参与。IS广播在物理上发给inner-shareable域内
所有PE，但每个PE按标签匹配：别的guest(VMID不同)、host(regime=EL2&0，压根不匹配)
都不会误伤。

- Host(KVM)在EL2替guest刷

todo: 什么时候需要

VHE下host平时是{E2H,TGE}={1,1}，此时tlbi *E1打的是EL2&0(host自己)，打不到guest
的EL1&0。所以KVM的做法是临时把TGE清0：
```c
// arch/arm64/kvm/hyp/vhe/tlb.c::__tlb_switch_to_guest
__load_stage2(mmu, mmu->arch);      // 先把目标VM的VMID装进VTTBR_EL2
val = read_sysreg(hcr_el2);
val &= ~HCR_TGE;                    // TGE: 1 -> 0
write_sysreg(val, hcr_el2);
isb();
// ...此刻tlbi *E1命中的是guest的EL1&0(且限定当前VMID)。
```
刷完再把TGE置回1。

- 无效stage2 TLB的一般逻辑

todo: 什么时候需要

由于如上的存储结构，无效stage2 TLB后，还要无效下虚机的combined TLB:
```c
//__kvm_tlb_flush_vmid_ipa
__tlbi(ipas2e1is, ipa);   // (1) 打stage2-only条目: 按IPA精确失效
dsb(ish);                 //     等广播完成，保证(2)能看到(1)的效果
__tlbi(vmalle1is);        // (2) 打combined(S1+S2)条目: 只能按VMID全清
dsb(ish);
isb();
```

## 虚机上CnP的软件支持

如下是和虚机上CnP软硬件逻辑相关的一个问题。这个是一个独立问题，先在这个文档中记录。

kvm_arch_vcpu_load里会有：
```
         /*                                                                      
          * We guarantee that both TLBs and I-cache are private to each          
          * vcpu. If detecting that a vcpu from the same VM has                  
          * previously run on the same physical CPU, call into the               
          * hypervisor code to nuke the relevant contexts.                       
          *                                                                      
          * We might get preempted before the vCPU actually runs, but            
          * over-invalidation doesn't affect correctness.                        
          */                                                                     
         if (*last_ran != vcpu->vcpu_idx) {                                      
                 kvm_call_hyp(__kvm_flush_cpu_context, mmu);                     
                 *last_ran = vcpu->vcpu_idx;                                     
         }                                                                       
```
上线的时候检测，如果这个物理CPU跑过同一个VM上的其它vCPU，就先无效下这个物理CPU
上虚机的TLB，因为其它vCPU的TLB可能和上线vCPU的ASID/VA相同、PA不同(what?)。这个支
持确保vCPU的TLB始终是private的。

但是，如上逻辑在使能CnP的虚机还正确么？当前的软件是，只要检测到host支持CnP，S2就
会把CnP配置上，guest默认也会配置上CnP，这样，从硬件配置角度看，虚机的CnP是全部打
开的。

当多个vCPU同时在多个thread上运行时，CnP会实际运行：
```
     ASID1 VA1 PA1         ASID1 VA1 PA2
     vcpu0 s1 cnp = 1      vcpu1 s1 cnp = 1
     +--------+            +---------+
     | thread0|            | thread1 |
     +--------+            +---------+
               \          /
                \        /
                 +------+       s2 cnp = 1 
                 | core |
                 +------+
```
这样逻辑上会错，但是这种情况是违反ARM构架的。(上面的场景也可能是CnP打开的, 为啥
上面就不违反ARM构架?)
