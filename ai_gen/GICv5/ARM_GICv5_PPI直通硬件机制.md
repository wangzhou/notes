# GICv5 PPI 直接注入（Direct Injection）硬件免 Trap 机制

> 基于 ARM IHI 111701 A.a，以 vtimer (PPI 30 = CNTP) 为例，逐层分析硬件如何做到 PPI 虚拟中断直通，Guest 处理全程不 trap。

## 一、核心问题

GICv3 的做法：物理 timer 中断 → EL2 hypervisor trap → hypervisor 读物理 timer 状态 → 软件注入虚拟 timer 中断到 Guest 的 List Register → ERET 到 Guest。

GICv5 的做法：物理 timer 信号直接变为虚拟中断，Guest 全程通过 GIC System Instructions 处理，**一次 trap 都不发生**。

---

## 二、逐层分析（以 vtimer PPI 27 为例）

### 第 0 层：Hypervisor 的准备工作

在调度 VPE 之前，hypervisor 做三件事：

```
// 1. 开启 PPI 直接注入：物理 PPI 27 → 虚拟 PPI 27
ICH_PPI_DVIR0_EL2.DVI[27] = 1

// 2. 配置虚拟 CPU interface 接管 EL1
HCR_EL2.IMO = 1

// 3. 禁用物理域的 PPI 27，防止物理域也响应
ICC_PPI_ENABLER0_EL1.EN[27] = 0

// 4. 设置 resident VPE
ICH_CONTEXTR_EL2.V = 1
ICH_CONTEXTR_EL2.VM = <vm_id>
ICH_CONTEXTR_EL2.VPE = <vpe_id>
ISB
```

### 第 1 层：硬件 Pending 别名——核心机制

当 `DVI[27] = 1` 时，硬件建立了一条**寄存器别名路径**：

```
物理 PPI Pending               虚拟 PPI Pending
(ICC_PPI_SPENDR.PEND[27])     (ICV_PPI_SPENDR.PEND[27])
        │                              │
        └──── DVI[27]=1: alias ───────→┘
              (同一物理存储)

ICH_PPI_PENDR.PEND[27] : IGNORED (hypervisor 写无效)
```

spec 原文（2.10.1.1）：
> When the Pending state of a physical PPI is directly injected as the Pending state of a virtual PPI, the field in ICV_PPI_xPENDR.PEND[x] corresponding to the virtual PPI becomes an **alias** of the field in ICC_PPI_xPENDR.PEND[x] corresponding to the physical PPI, and the value of ICH_PPI_PENDR.PEND[x] is **IGNORED**.

这意味着：
- 物理 timer 信号到达 → CPU 硬件置 `ICC_PPI_SPENDR.PEND[27] = 1`
- 因为 alias 关系，`ICV_PPI_SPENDR.PEND[27]` **自动变为 1**（同一个 bit）
- 不需要任何软件动作

### 第 2 层：虚拟 HPPI 选择

当 PE 在 EL1 运行时（`HCR_EL2.IMO=1`, `ICH_VCTLR_EL2.V3=0`），CPU Interface 为 Virtual Interrupt Domain 选择 HPPI：

```
Virtual HPPI = max_priority(
    Candidate HPPI from IRI (virtual LPI/SPI for resident VPE),
    Candidate HPPI from virtual PPIs  ← PPI 27 在这里
)
```

虚拟 PPI 成为候选 HPPI 的条件（spec 2.10.1）：
```
ICV_PPI_ENABLER.EN[27] == 1    // Guest 自己 enable 的
ICV_PPI_SPENDR.PEND[27] == 1   // 由物理 Pending alias 而来
ICV_PPI_SACTIVER.ACTIVE[27] == 0  // 未被 acknowledge
```

注意：`ICH_PPI_DVIR.DVI[27]` **不是**候选 HPPI 的条件。它只是决定了 Pending 状态的来源，不参与 HPPI 选择逻辑。

### 第 3 层：vIRQ 信号

当虚拟 PPI 27 成为 Virtual HPPI 且优先级足够：
```
CPU Interface → vIRQ signal → PE
PE → 从 EL0/1 的当前执行流中 take vIRQ exception
```

### 第 4 层：Guest 确认中断（GICR CDIA）

Guest (EL1) 中断处理程序执行：

```
GICR X0, CDIA    // Interrupt Acknowledge in Current Domain
```

硬件伪代码（spec page 227）：
```
if PSTATE.EL == EL1 then
    if HCR_EL2.IMO == '1' && ICH_VCTLR_EL2.V3 == '1' then
        UNDEFINED;  // legacy mode
    elsif ICH_HFGITR_EL2.GICRCDIA == '0' then
        SystemAccessTrap(EL2);  // hypervisor 可选 trap
    else
        X[t] = AArch64.GICR(GICInstrDomain_CD, GICInstr_IA);
        // ↑ Current Domain = Virtual → 确认虚拟中断
```

返回 `<Xt>` 编码：
```
TYPE = 0b001   (PPI)
ID   = 27      (虚拟 PPI 27)
VALID = 1
```

确认时的硬件动作：
```
// 操作在 Virtual Interrupt Domain
ICV_PPI_SACTIVER.ACTIVE[27] = 1       // 设置虚拟 Active
ICV_PPI_SPENDR.PEND[27] = 0           // Edge 触发：原子清除 Pending
// 因为 alias，ICC_PPI_SPENDR.PEND[27] 也被清为 0
// 虚拟 PPI 27 的 priority 成为 Virtual Domain 的 active priority
```

**关键**：物理 PPI 27 的 Active 状态**不受影响**。物理和虚拟 PPI 是独立的中断，只有 Pending 状态是 alias 的。

### 第 5 层：Guest Priority Drop（GIC CDEOI）

```
GIC CDEOI   // Priority Drop in Current Domain (= Virtual)
```

硬件动作：
```
// 操作在 Virtual Interrupt Domain
Virtual Domain 中最高 active priority 停止 active
Virtual running priority 更新为下一个 active priority 或 Idle Priority (0xFF)
```

注意 GICv5 的 `GIC CDEOI` **不需要 INTID 参数**（与 GICv3 不同），它总是对 Virtual Domain 的当前 running priority 执行 priority drop。

### 第 6 层：Guest Deactivate（GIC CDDI）

```
GIC CDDI, X0   // X0 包含 INTID = PPI 27
```

硬件动作：
```
// 操作在 Virtual Interrupt Domain
ICV_PPI_CACTIVER.ACTIVE[27] = 1    // 清除虚拟 Active
// 虚拟 PPI 27 完整处理完毕，回到 Idle+Inactive 状态
```

---

## 三、硬件免 Trap 的完整数据流

```
物理 Timer 信号
     │
     ▼
┌──────────────────────────────────────────────────┐
│ CPU Interface 硬件                                │
│                                                    │
│  ICC_PPI_SPENDR.PEND[27] = 1  ← 物理 Pending      │
│         │                                          │
│         │ DVI[27]=1 (hardware alias, 同一寄存器)    │
│         ▼                                          │
│  ICV_PPI_SPENDR.PEND[27] = 1  ← 虚拟 Pending      │
│                                                    │
│  Virtual HPPI 选择:                                │
│    Enabled[27]=1 ✓ (Guest 配的)                    │
│    Pending[27]=1  ✓ (alias → 物理 timer)           │
│    Active[27]=0   ✓                                │
│    Priority = Guest 配的优先级                      │
│                                                    │
│  → vIRQ signal to PE                              │
└──────────────────────────────────────────────────┘
     │
     ▼ (PE take vIRQ exception)
┌──────────────────────────────────────────────────┐
│ Guest EL1 中断处理 (全程非特权指令，零 trap)        │
│                                                    │
│  GICR X0, CDIA   → TYPE=PPI, ID=27, VALID=1      │
│       ↓                                            │
│  handler(timer)                                    │
│       ↓                                            │
│  GIC CDEOI       → Virtual Priority Drop          │
│       ↓                                            │
│  GIC CDDI, X0    → Virtual Deactivate             │
│                                                    │
└──────────────────────────────────────────────────┘
```

---

## 四、物理 PPI 与虚拟 PPI 的状态分离

这是理解免 trap 的关键设计：

```
物理 PPI 27 (ICC_PPI_*)          虚拟 PPI 27 (ICV_PPI_*)
┌─────────────────────┐          ┌─────────────────────┐
│ Enable    = 0       │          │ Enable    = 1       │  ← Guest 控制
│ Priority  = X       │          │ Priority  = Y       │  ← Guest 控制
│ Pending   = alias ←─┼─DVI=1──→─│ Pending   = alias  │  ← 硬件 alias
│ Active    = N/A     │          │ Active    = 0/1     │  ← Guest ack 设置
│ Domain    = Secure  │          │ Domain    = Virtual │
└─────────────────────┘          └─────────────────────┘

它们是两个独立的中断！
- 物理 PPI 被 disable → 不参与物理 HPPI 选择
- 虚拟 PPI 被 enable → 参与虚拟 HPPI 选择
- 只有 Pending 状态通过 alias 共享
```

spec 原文（2.4.1）：
> For each implemented PPI, the physical and virtual PPI with the same INTID are **separate interrupts**.

> When a physical PPI is directly injected, Arm expects that the physical PPI is disabled to avoid separate interrupt handling routines attempting to service the same interrupt.

---

## 五、与 IPI 免 Trap 的机制对比

| 维度 | IPI (virtual LPI/SPI) | PPI Direct Injection |
|------|----------------------|---------------------|
| 触发源 | Guest 写 `GIC CDPEND` | 物理 PPI 信号（如 timer） |
| 免 trap 关键 | CPUIF 向 IRS 发 `SetPending(Virtual=1)`，IRS 用 stateful VPE 上下文路由 | `DVI=1` 建立 Pending 寄存器 alias，物理信号直接变为虚拟状态 |
| 路由 | IRS 查 IST 中 virtual interrupt affinity → 目标 PE | 无需路由（PPI 是 PE 私有的，直接在本 PE 的 CPU Interface 内完成） |
| 状态存储 | IRS 内存中的 IST | PE 的 System Register（CPU Interface 内部） |
| Guest ack | `GICR CDIA` → CPUIF 发 `Activate` 给 IRS | `GICR CDIA` → 直接操作 ICV_PPI_* 寄存器 |

---

## 六、嵌套虚拟化下的 vtimer 重定向

当 `HCR_EL2.{NV, NV1} = {1, 0}` 时（Guest hypervisor 在 EL1 运行），需要重定向：

```
物理 PPI 27 (CNTV, EL1 Virt Timer)
    │
    │ DVI[27]=1 (redirect under NV)
    ▼
虚拟 PPI 28 (CNTHP, EL2 Phys Timer)
```

spec（2.10.1.2）：
> Physical PPI 27 is directly injected as virtual PPI 28.
> ICV_PPI_xPENDR.PEND[28] is an alias of ICC_PPI_PENDR.PEND[27].

这样 Guest hypervisor (EL1) 通过 `FEAT_NV` 重定向看到的 "EL1 物理 timer"（对应虚拟 PPI 28），实际被直通到了物理 PPI 27，而同时 Guest VM (EL1 下的嵌套 Guest) 看到的虚拟 timer（虚拟 PPI 27）由 EL2 hypervisor 软件模拟。

---

## 七、总结

GICv5 的 PPI 直通比 IPI 更简单 —— PPI 是 PE 私有的，不需要跨 PE 路由，所有状态都在 PE 的 CPU Interface 硬件内完成。

核心机制就是一条硬件 alias：

```
ICH_PPI_DVIR.DVI[x] = 1  →  ICV_PPI_xPENDR.PEND[x]  ≡  ICC_PPI_xPENDR.PEND[x]
```

这建立了一条从物理中断信号到虚拟中断可见性的**零延迟硬件通路**。此后的 HPPI 选择、acknowledge、priority drop、deactivate 全部在 Virtual Interrupt Domain 中通过 GIC System Instructions 完成 —— Guest 看到的编程模型与物理中断完全一致（二进制兼容），但全程零 trap。
