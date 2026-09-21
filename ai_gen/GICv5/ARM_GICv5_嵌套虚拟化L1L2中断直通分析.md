# ARM GICv5 嵌套虚拟化下 L1/L2 中断直通分析

> 基于 ARM IHI 111701 A.a (GICv5 规范) 原文核对。
> 术语：L0 = 宿主 hypervisor (真 EL2)，L1 = guest hypervisor (EL1 + HCR_EL2.NV)，L2 = 嵌套 guest (EL1)。

## 结论先行

**L2 的中断直通是支持的，而且质量和 L1 基本一样好** —— 这是 GICv5 相对 GICv3 在嵌套场景下最实在的改进。
高频路径（直通设备 MSI、IPI、timer）在 L2 运行时全部走硬件，零 trap。

代价集中在 **L1 作为 hypervisor 去管理 L2 的那些操作**：8 条 `GIC VD*` 指令在 EL1+NV 下必然 trap；
但 `ICH_*_EL2` 寄存器组被 FEAT_NV2 全量纳入内存转换，上下文切换热路径不 trap。

## 一、为什么"只有一个虚拟中断域"反而不是问题

GICv5 每个 PE 只有一个 Virtual Interrupt Domain，没有"嵌套虚拟域"。但 **L1 和 L2 都运行在 EL1**，
所以它们天然共用同一套虚拟 CPU interface。

规范 DNSTKG (§2.3)：

```
Current Interrupt Domain = Virtual Interrupt Domain，当且仅当：
  • 当前 EL == EL1
  • HCR_EL2.IMO == 1
  • ICH_VCTLR_EL2.V3 == 0
否则 = Current Physical Interrupt Domain
```

这个判定式里**没有任何 NV 相关项**。于是：

| 运行者 | EL | 硬件判定 | 效果 |
|---|---|---|---|
| L1 (guest hypervisor) | EL1 | Current Domain = Virtual | L1 眼中的"物理中断"= 硬件虚拟中断 |
| L2 (nested guest) | EL1 | Current Domain = Virtual | L2 眼中的"物理中断"= 硬件虚拟中断 |

L0 只需要在 L1↔L2 切换时改写 `ICH_CONTEXTR_EL2.{VM, VPE}`，把 resident VPE 换成对方的 shadow vPE。
硬件根本不需要知道"这是第几层"。

`ICH_CONTEXTR_EL2` 字段（§9.6.2）：`VM[15:0]` + `VPE[47:32]`，扁平 16-bit 命名空间，
L0 完全可以为 L2 的每个 VM 单独分配一个 shadow VM ID。

## 二、L2 的三类中断直通

### 2.1 直通设备 MSI → L2 的 vLPI（零 trap）

ITS 的 ITT 表项 `L2_ITTE`（§11.1.4）直接编码虚拟目标：

```
L2_ITTE:
  VM_ID   [47:32]   传给 IRS 的 VM ID
  VALID   [31]
  VIRTUAL [30]      1 = 生成虚拟中断消息
  DAC     [29:28]
  LPI_ID  [23:0]
```

L0 把直通给 L2 的设备的 ITTE 填成 `{VIRTUAL=1, VM_ID=<L2 的 shadow VM>, LPI_ID=<L2 的 vLPI>}`。

路径：设备发 MSI → ITS 翻译 → IRS → 查 L2 的 virtual LPI IST → L2 的 vPE 正 resident → 直接 vIRQ。
**全程不经过 L0，也不经过 L1。**

要点：
- 每个 VM 有独立的 virtual LPI IST（§4.10.1），`L2_VMTE.LPI_IST_ADDR` 指向，L0 为 L2 单独分配一份。
- 虚拟 LPI 命名空间按 VM 隔离，L1 的 vLPI 和 L2 的 vLPI 互不干扰。
- L1 配置"它的 ITS"时走 MMIO，被 stage-2 trap，L0 shadow 成真 ITT —— 这是配置路径开销，不在中断热路径上。

### 2.2 L2 发 IPI（零 trap）

`GIC CDPEND` 的 EL1 执行逻辑（§8.1）：

```
elsif PSTATE.EL == EL1 then
    if EL2Enabled() && HCR_EL2.IMO=='1' && FEAT_GCIE_LEGACY && ICH_VCTLR_EL2.V3=='1' then
        UNDEFINED;
    elsif EL2Enabled() && ICH_HFGITR_EL2.GICCDPEND == '0' then
        AArch64.SystemAccessTrap(EL2, 0x18);
    else
        AArch64.GIC(X[t,64], GICInstrDomain_CD, GICInstr_PEND);   // ← 直接执行
```

**注意这里没有 NV 分支**。只要 L0 不在 `ICH_HFGITR_EL2.GICCDPEND` 里显式要求 trap，
L2 在 EL1 执行 `GIC CDPEND` 就直接在 Virtual Domain 生效，硬件按 `IAFFID` 路由到同 VM 内的目标 VPE。

这是 GICv5 嵌套场景最大的单点收益。GICv3 下 L2 发 IPI 要 trap 到 L0，L0 还得模拟一遍 L1 的注入逻辑
（因为 L1 以为是它在注入），是双层开销。GICv5 直接归零。

目标 VPE 不 resident 时走 VPE doorbell（§4.10.7），产生物理中断给 L0 调度 —— 这是必要的，不是缺陷。

### 2.3 L2 的 timer PPI（零 trap）

`ICH_PPI_DVIR<n>_EL2.DVI<x> = 1` 把物理 PPI 的 Pending 态直接注入为同号虚拟 PPI（§2.10.1.1）。
L0 给 L2 配置时按普通 guest 处理即可，INTID 不变（PPI 27 → 虚拟 PPI 27）。

L2 的 EOI/deactivate 也全在虚拟 CPU interface 内完成，不 trap。

## 三、L1 自己的直通：NV 专属的 timer PPI 重定向

规范 §2.10.1.2 RGYGNW 是**整份 spec 里唯一一处显式为嵌套虚拟化设计的 GIC 硬件机制**。

当 `FEAT_GCIE && HCR_EL2.{NV,NV1}=={1,0} && EL2 实现且使能` 时，timer PPI 的注入目标 INTID 被重定向：

**Non-secure (SCR_EL3.NS==1)：**

| 物理 PPI | 名称 | → 注入为虚拟 PPI | 名称 |
|---|---|---|---|
| 30 | CNTP (EL1 Physical Timer) | 26 | CNTHP (NS EL2 Physical Timer) |
| 27 | CNTV (EL1 Virtual Timer) | 28 | CNTHV (NS EL2 Virtual Timer) |

**Secure (SCR_EL3.NS==0)：**

| 物理 PPI | → 注入为虚拟 PPI | 名称 |
|---|---|---|
| 30 | 20 | CNTHPS (Secure EL2 Physical Timer) |
| 27 | 19 | CNTHVS (Secure EL2 Virtual Timer) |

配套的别名规则（以 NS、DVI27 为例）：
- `ICV_PPI_xPENDR0_EL1.PEND28` 成为 `ICC_PPI_PENDR_EL1.PEND27` 的别名
- `ICV_PPI_xPENDR0_EL1.PEND27` 仍然访问虚拟 PPI 27 自己的 Pending 态
- `ICH_PPI_PENDR0_EL2.PEND28` 被 IGNORED（读写仍访问该字段，但不参与 Pending 判定）
- `ICH_PPI_DVIR0_EL2.DVI28` 除直接读该字段外一律按 0 处理

**为什么要这么设计**（IGPQTJ）：L1 是个写给 `HCR_EL2.E2H=1` 跑的 hypervisor。
它在 EL1 访问 EL1 timer 寄存器时，**期望**这些访问被重定向到 EL2 timer 寄存器（E2H 语义），
从而**期望看到 EL2 timer 的 PPI (26/28) 变 Pending**。
但在 EL1 上，这些寄存器访问是直接打到真 EL1 timer 的（不 trap）。
所以硬件把 **timer 输出的 INTID 也跟着重定向**，让 L1 的预期自洽。

而 L1 想访问"它的 guest（L2）的 EL1 timer"时，用 `_EL02` 后缀指令，在 `HCR_EL2.NV==1` 下 trap 到 L0，
由 L0 软件模拟，通过 `ICH_PPI_PENDR0_EL2` 置虚拟 PPI 30/27 的 Pending —— 正好用上被腾出来的 27/30。

> 勘误：目录下 `ARM_GICv5_PPI直通硬件机制.md` §六 把虚拟 PPI 28 写成了 "CNTHP, EL2 Phys Timer"。
> 按 §2.9 表：PPI 28 = CNTHV (NS EL2 **Virtual** Timer)，PPI 26 = CNTHP (NS EL2 Physical Timer)。

## 四、不直通的部分：L1 管理 L2 的操作

### 4.1 `GIC VD*` 指令在 EL1 + NV 下必然 trap

8 条虚拟域管理指令 —— `GIC VDAFF / VDDI / VDDIS / VDEN / VDHM / VDPEND / VDPRI / VDRCFG` —— 
EL1 执行逻辑一致（§8.2）：

```
elsif PSTATE.EL == EL1 then
    if EffectiveHCR_EL2_NVx() IN {'xx1'} && (!FEAT_GCIE_LEGACY || ICH_VCTLR_EL2.V3=='0') then
        AArch64.SystemAccessTrap(EL2, 0x18);    // ← NV 下 trap，无法关闭
    else
        UNDEFINED;
```

没有 FGT 开关可以放行，没有 NV2 内存转换。**L1 每次给 L2 注入或配置一个虚拟中断，就是一次 trap。**

这是 GICv5 相对 GICv3 的一处**退步**：GICv3 用 List Register 注入，`ICH_LR<n>_EL2` 在 NV2 下转成内存写，
L1 可以攒一批 LR 写入，到 ERET 时 L0 一次性 shadow。GICv5 取消了 LR，改成指令式接口，
指令无法转内存，只能逐条 trap。

实际影响可控 —— 真正高频的中断（直通 MSI、IPI、timer）走的是第二节的硬件路径，
根本不经过 L1 的软件注入。受影响的是 L1 模拟的设备（virtio、emulated timer）。

### 4.2 `ICH_*_EL2` 寄存器：FEAT_NV2 全量覆盖（零 trap）

规范 §9.9 RKZTGX 把 GICv5 hypervisor 控制寄存器加进了 ARM ARM 的 NV2 内存偏移表：

| 寄存器 | VNCR 页偏移 |
|---|---|
| ICH_APR_EL2 | 0xB00 |
| ICH_CONTEXTR_EL2 | 0xB08 |
| ICH_HFGITR_EL2 | 0xB10 |
| ICH_HFGRTR_EL2 | 0xB18 |
| ICH_HFGWTR_EL2 | 0xB20 |
| ICH_VCTLR_EL2 | 0xB28 |
| ICH_PPI_ACTIVER\<n\>_EL2 | 0xB30 + 8n |
| ICH_PPI_DVIR\<n\>_EL2 | 0xB40 + 8n |
| ICH_PPI_ENABLER\<n\>_EL2 | 0xB50 + 8n |
| ICH_PPI_PRIORITYR\<n\>_EL2 | 0xB80 + 8n |
| ICH_PPI_HVIR\<n\>_EL2 | 0xC00 + 8n |
| ICH_VMCR_EL2 | 0x4C8 |

IHPNKC 补充：GICv3 定义的那些寄存器（含 `ICH_LR<n>_EL2`）偏移不变，GICv5 不改。

pseudocode 实证（`MSR ICH_APR_EL2, Xt`，§9.6.1）：

```
elsif PSTATE.EL == EL1 then
    if EffectiveHCR_EL2_NVx() IN {'1x1'} && ... then     // NV2=1 && NV=1
        NVMem[0xB00] = X[t, 64];                          // ← 纯内存写，不 trap
    elsif EffectiveHCR_EL2_NVx() IN {'xx1'} && ... then   // 只有 NV=1
        AArch64.SystemAccessTrap(EL2, 0x18);
```

这条很关键：**L1 做 vCPU 上下文切换时批量读写几十个 `ICH_*` 寄存器，全部是内存访问，零 trap。**
L0 在下一次自然退出点（通常是 L1 的 `ERET` 到 L2，NV 下必 trap）一次性读 VNCR 页，
把 L1 写的 `ICH_CONTEXTR_EL2.{VM,VPE}` 翻译成对应的 shadow vPE，再写真硬件寄存器。

### 4.3 ITS / IRS 的 MMIO 配置

L1 访问"它的虚拟 ITS/IRS"是 MMIO，靠 stage-2 trap，L0 shadow 一份真实 ITT / IST。
这与 GICv3 下 shadow ITS 代价相同，属于配置路径，不在中断热路径。

## 五、GICv3 vs GICv5 嵌套开销对比

| 场景 | GICv3 + NV2 | GICv5 + NV2 |
|---|---|---|
| L2 收直通设备中断 | GICv4 vLPI 可直通（需 L0 shadow vPE，且依赖 GICv4 可选扩展） | 直通，ITTE 直接指向 shadow VM（基础能力） |
| **L2 发 IPI** | trap 到 L0 + L0 模拟 L1 注入 | **零 trap**（`GIC CDPEND` 在 Virtual Domain 直接生效） |
| L2 ack / EOI / deactivate | 不 trap（LR 机制） | 不 trap（虚拟 CPU interface） |
| L1 收自己的 timer 中断 | 需 L0 模拟注入 | **硬件 PPI 重定向直通**（30→26, 27→28） |
| L1 给 L2 注入模拟中断 | 写 LR → NV2 转内存，攒批后一次 trap 处理 | `GIC VD*` → **每条 trap** ⚠️ |
| L1 保存/恢复 L2 GIC 上下文 | ICH_LR* → NV2 内存，零 trap | ICH_* → NV2 内存，零 trap |
| L1 配置虚拟 ITS | stage-2 trap + shadow | stage-2 trap + shadow（同） |

净效果：**中断投递路径全面改善，中断注入路径（L1 软件模拟那部分）略有退化**。
对 I/O 直通为主的嵌套负载是明确的净收益；对纯模拟设备的嵌套负载要看 `GIC VD*` trap 频率。

## 六、L0 实现要点（KVM 视角）

1. **为 L2 的每个 vCPU 分配 shadow {VM_ID, VPE_ID}**，在 IRS 的 VM table / VPE table 里建好条目，
   分配独立的 virtual LPI IST。VM_ID 16-bit 扁平空间，容量不是约束。
2. **L1↔L2 切换 = 改写 `ICH_CONTEXTR_EL2`**，把 resident VPE 从 L1 vCPU 换成 L2 shadow vPE。
   换出时按需置 `DB=1` 请求 doorbell，`DBPM` 设门限优先级。
3. **在 L1 的 ERET trap 点读 VNCR 页**（offset 0xB08）拿 L1 写入的 `ICH_CONTEXTR_EL2`，
   做 VM/VPE ID 的 shadow 映射后写真寄存器。其余 `ICH_*` 字段同理批量同步。
4. **`GIC VD*` trap handler 是嵌套热点**，值得优化：解析 L1 意图后直接操作 L2 shadow vPE 的虚拟中断状态。
5. **L1 的 timer 依赖 `ICH_PPI_DVIR0_EL2.DVI30 / DVI27`**，L0 必须置位才能让重定向生效；
   同时要记得虚拟 PPI 26/28（或 20/19）的 `ICH_PPI_PENDR0_EL2` 值被 IGNORED，
   L0 不能靠写它来模拟 L1 的 EL2 timer。
6. **注意 `ICH_PPI_DVIR<n>_EL2.DVI<x>` 的 Effective value**：
   若对应物理 PPI 不属于 Current Physical Interrupt Domain，该位按 0 处理（INVWGX）。

## 七、规范条目索引

| 内容 | 条目 ID | 章节 |
|---|---|---|
| Current Interrupt Domain 判定 | DNSTKG | §2.3 |
| 虚拟 CPU interface 启用条件 / ICC→ICV 重定向 | IXVDWC | §2.10 |
| 虚拟 PPI 直接注入 | DQNZMN, IVRZWD | §2.10.1.1 |
| **NV 下 timer PPI 重定向** | **RGYGNW, IMDYZD, IGPQTJ, IQKGXM** | **§2.10.1.2** |
| VPE doorbell 条件 | RCWZMW | §4.10.7 |
| 虚拟 LPI IST（每 VM 独立） | DJXYLG, IRMNHL | §4.10.1 |
| ITS Domain 虚拟中断支持 | RSXLJQ, RNTTVJ | §5.1 |
| `GIC CDPEND` EL1 执行 | — | §8.1.10 |
| `GIC VD*` EL1 + NV 必 trap | — | §8.2.1–8.2.8 |
| `ICH_CONTEXTR_EL2` 字段 | — | §9.6.2 |
| **NV2 内存偏移表扩展** | **IXDKPJ, RKZTGX, IHPNKC** | **§9.9** |
| `L2_ITTE` 结构（VIRTUAL / VM_ID） | — | §11.1.4 |
| Timer PPI 编号表 | — | §2.9 |
