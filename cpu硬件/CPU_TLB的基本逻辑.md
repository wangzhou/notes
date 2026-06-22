-v0.1 2026.3.29 Sherlock init
-v0.2 2026.6.22 Sherlock 补齐TLBI三节(指令/Host/虚机)

简介: 收集和ARM TLB硬件相关的知识，基于ARM构架。

## TLB硬件

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

注意，在虚拟话的情况下，需要TTBRx_EL1.CNP和VTTBR_EL2.CNP都是1，才会创建共享的TLB。
一个直观的硬件实现是，当硬件发现满足共享TLB的条件的时候，就去查找有无共享TLB，如果
没有就创建一个TLB，并打上共享的标记，如果找见共享TLB就直接使用。

## TLBI使用场景

从如上的TLB类型的角度看下TLBI指令都有哪些。

### TLBI指令

理解全部TLBI语义，只需要一个前提：**每条TLB条目都隐式携带一组"标签"**，TLBI做的事情
就是"构造一个匹配掩码，命中的条目全部失效"。一个贴近真实硬件的条目模型：

```c
struct tlb_entry {
    /* ---- 查找/匹配键 ---- */
    u64 in_addr;   // 输入地址: VA(stage1/combined) 或 IPA(stage2)
    u8  regime;    // 关键! EL1&0 / EL2 / EL2&0 / EL3  (× 安全状态 NS/S/Realm)
    u16 vmid;      // 仅"受stage2约束"的条目有效(guest EL1&0 与 stage2)
    u16 asid;      // 仅 stage1 非全局(nG=1) 条目有效
    u8  nG;        // 全局? nG=0 => 匹配时忽略 asid
    u8  stage;     // S1-only / S2-only / S1+S2 combined
    u8  ttl_size;  // 页/块/contig —— 即上面"覆盖范围"的三种
    /* ---- 载荷 ---- */
    u64 out_addr;  // PA
    /* attrs... */
};
```

其中 **regime 是最关键的字段**。它不是"哪个EL存进去的"，而是"属于哪个translation
regime"。ARM64的regime有：

1. EL1&0: TTBR0/1_EL1 + TCR_EL1(受hypervisor管辖时叠加stage2)。
2. EL2:   TTBR0_EL2(非VHE，单一VA段，无ASID，全局)。
3. EL2&0: TTBR0/1_EL2(**仅当 E2H=1 才存在**，有ASID，行为像EL1&0)。
4. EL3:   TTBR0_EL3。

**同一条TLBI机器码落到哪个regime，是运行期由 {当前EL, HCR_EL2.E2H, HCR_EL2.TGE,
安全状态} 决定的**。这就是为什么guest和host用一模一样的指令却互不干扰——见下面两节。

TLBI指令名可以拆成三段来读: `TLBI <操作><级别><范围>`。

- 操作(选哪类条目 / 用什么键匹配):
  - `VA`     : 按VA点名(带ASID)。
  - `VAA`    : 按VA点名，但忽略ASID(all-ASID)。
  - `ASID`   : 按ASID整体失效。
  - `VMALL`  : 当前VMID下，该regime的stage1/combined条目全清(不按地址)。
  - `VMALLS12`: 当前VMID下，stage1 + stage2 + combined 全清。
  - `IPAS2`  : 按IPA点名，只打 **stage2-only** 条目。
  - `ALL`    : 该级别regime全清(不看VMID/ASID)。
  - `R*`(如RVAE1/RIPAS2E1): Range变体，一条指令按 {BaseADDR,TG,SCALE,NUM} 失效一段区间。
- 级别(隐含目标regime，最终仍受E2H/TGE调制): `E1` / `E2` / `E3`。
- 范围: 无后缀=本PE local; `IS`=inner-shareable广播; `OS`=outer-shareable; `nXS`=不等XS。

一次TLBI，硬件对每条条目做的匹配(概念)：

```c
hit = (e.regime == target_regime)                            // 由 {EL,E2H,TGE,SS} 算出
   && (regime_has_vmid(target) ? e.vmid == cur_vmid : true)  // cur_vmid 来自 VTTBR_EL2
   && (by_asid ? (e.nG==0 || e.asid == op_asid) : true)      // 全局条目忽略ASID
   && (by_addr ? addr_covered(e, op_addr, op_ttl) : true)    // 见下"覆盖范围"
   && stage_matches(op, e.stage);                            // 由"操作"段决定
```

几个要点：

1. **VMID不在指令操作数里**，它是"当前上下文"隐式带的(取自VTTBR_EL2)。所以要刷某台
   特定VM，软件必须先把该VM的VMID装进VTTBR_EL2(KVM里的 `__load_stage2()`)。
2. **ASID对全局条目(nG=0)无效**：内核态那种全局映射，`TLBI ASID` 刷不掉，得靠VMALL。
   `VAE1` 时ASID取自操作数 `Xt[63:48]`。
3. **覆盖范围(页/块/contig)只影响 `addr_covered` 的判定**。`Xt` 里的TTL域(`[47:44]`)
   只是层级提示，帮硬件少走几层walk；真正规则是"条目覆盖区间包含操作数地址即命中"。
   而且硬件**永远允许"多失效"、绝不允许"少失效"**：你要求刷一个基础页，它可以顺手把
   包含该页的整条block/contig条目一起清掉。**软件绝不能假设"刷一页后相邻contig表项还在"**
   ——这条自由度就是contig PTE场景下必须整簇处理的架构依据。

`E1` 类指令最终命中哪个regime，取决于执行时的 {E2H,TGE}：

| 执行位置 | HCR_EL2.{E2H,TGE} | `TLBI *E1*` 目标regime |
|---|---|---|
| EL1(guest 或 非VHE host) | — | **EL1&0** |
| EL2 | {0, x} 非VHE hyp | EL1&0 |
| EL2 | {1, 0} VHE 但跑在guest上下文 | **EL1&0** |
| EL2 | {1, 1} VHE host 跑自己 | **EL2&0** |

`E2` 类(在EL2执行)：`E2H=0` → EL2(无ASID)；`E2H=1` → EL2&0(有ASID)。

### Host上TLBI的使用

关键结论：**同一份Linux内核二进制，`flush_tlb_*()` 里那些 `__tlbi(vmalle1is)`
一行都不用改，既能当非VHE的EL1 host，也能当VHE的EL2 host**——靠的正是上表的regime调制。

1. **非VHE host(E2H=0)**：host内核跑在EL1。`__tlbi(vmalle1is)` / `vae1is` → EL1&0
   regime，刷的是host自己(裸机，不过stage2，无VMID)。EL2上只有一小段hyp stub代码，
   它维护自己的EL2 regime映射，用 `tlbi alle2` 之类整体失效(EL2无ASID，只能全清)。

2. **VHE host(E2H=1, TGE=1)**：host内核直接跑在EL2。同样的 `__tlbi(vmalle1is)` 源码，
   此时 → **EL2&0 regime = host自己那份条目**。因为EL2&0有ASID，host用户进程切换可以
   用 `tlbi aside1`(→EL2&0，按ASID)精确刷，而不必全清。

   注意：host的EL2&0条目是 **stage1-only**(裸机host不受stage2约束)，因此**无VMID**。
   这也解释了world switch时不需要因为host而动VMID——host和guest天然处在不同regime。

于是回到那个常见疑问："VHE下host在EL2用 `tlbi ...E1`，能操作到EL2保存的TLB吗？"
**能，而且这正是目的**——{E2H,TGE}={1,1} 时 `tlbi *E1` 打的就是EL2&0(host自己)。它同时
碰不到guest(EL1&0，带VMID)的条目。

### 虚机上TLBI的使用

分两个视角：guest自己发TLBI，和host(KVM)替guest刷。

**(A) guest在EL1自己发TLBI**

guest执行 `tlbi vae1is` → EL1&0 regime，而当前 `VTTBR_EL2.VMID` 就是该guest的VMID，
硬件自动把失效**锁定在这台guest**。默认KVM不trap guest的TLBI(`HCR_EL2.TTLB=0`)，
guest的TLBI原生执行、原生按VMID隔离，host完全不参与。
IS广播在物理上发给inner-shareable域内所有PE，但每个PE按标签匹配：别的guest(VMID不同)、
host(regime=EL2&0，压根不匹配)都不会误伤。

**(B) host(KVM)在EL2替guest刷**

难点：VHE下host平时是 {E2H,TGE}={1,1}，此时 `tlbi *E1` 打的是EL2&0(host自己)，
**打不到guest的EL1&0**。要打guest，必须翻转其中一位。改E2H不行(一动TTBR1_EL2就没了)，
所以KVM的做法是**临时把TGE清0**(`arch/arm64/kvm/hyp/vhe/tlb.c::__tlb_switch_to_guest`)：

```c
__load_stage2(mmu, mmu->arch);      // 先把目标VM的VMID装进VTTBR_EL2
val = read_sysreg(hcr_el2);
val &= ~HCR_TGE;                    // TGE: 1 -> 0
write_sysreg(val, hcr_el2);
isb();
// ...此刻 tlbi *E1 命中的是 guest 的 EL1&0(且限定当前VMID)...
```

刷完再把TGE置回1。可见"TGE"就是那把开关：TGE=1打EL2&0(host)，TGE=0打EL1&0(guest)。

**(C) 改了stage2页表后的经典序列**——为什么要两条TLBI一起打
(`__kvm_tlb_flush_vmid_ipa`)：

```c
__tlbi(ipas2e1is, ipa);   // (1) 打 stage2-only 条目: 按 IPA 精确失效
dsb(ish);                 //     等广播完成，保证 (2) 能看到 (1) 的效果
__tlbi(vmalle1is);        // (2) 打 combined(S1+S2) 条目: 只能按 VMID 全清
dsb(ish);
isb();
```

原因纯粹由**上面"三类TLB存储"的结构**决定：

- **stage2-only条目**用IPA做键 → `IPAS2E1` 能按IPA点名失效。✔
- **combined条目**(第2类，S1+S2塌缩成一条)用的是 **VA** 做键，里面**没有存IPA**。硬件
  拿到一个IPA，反查不出"哪些VA映到了它"。→ 只能退而求其次：`VMALLE1` 按VMID把该guest的
  所有combined/S1条目整片清掉。**"combined TLB的存在"直接解释了这段代码为什么长这样。**

相关的还有 `VMALLS12E1IS`("S1+S2+combined、当前VMID全清")，撤销整台VM映射时用
(`__kvm_tlb_flush_vmid`)。

**小结**：TLBI的作用范围 =
`regime`(由 {EL, E2H, TGE, 安全状态} 选)
× `VMID`(当前VTTBR_EL2)
× `ASID`(操作数 / nG)
× `地址范围`(VA或IPA + TTL)
× `stage`(操作段决定)。
guest与host用同一条指令互不越界，本质就是regime被运行期上下文自动路由到了不同地方。
