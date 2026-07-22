# GICv5 IPI 与 PPI 虚拟化中断直通

> 基于 ARM IHI 111701 A.a (GICv5 spec) 中对 IPI 机制和 PPI Direct Injection 的分析。

## 一、IPI（Inter-Processor Interrupts）

### 1.1 基本机制

GICv5 中 **IPI 不是一种独立的中断类型**，而是通过 **SPI 或 LPI** 实现的。核心思路：

1. 选取一个 SPI 或 LPI，配置为 **Edge 触发 + Targeted 路由模式**，目标指向目的 PE
2. 源 PE 执行 `GIC <domain>PEND` 指令（使中断 Pending）
3. IRI 将中断路由到目的 PE

**物理 IPI 流程**（PE 到 PE）：

```
Source PE:                          Destination PE:
  GIC CDPEND, Xt  ───────→ IRI ──→ LPI/SPI Pending → signaled to dest PE
  (INTID=ipi_lpi)
```

**虚拟 IPI 流程**（VPE 到 VPE）—— 完全相同的范式：

```
Source VPE (EL1):                   Destination VPE:
  GIC CDPEND, Xt  ───────→ IRI ──→ virtual LPI/SPI Pending for dest VPE
  (in Virtual Domain)
```

关键在于：当 EL1 执行 `GIC CDPEND` 且 `Current Interrupt Domain = Virtual` 时，该指令自动操作 **Virtual Interrupt Domain**（虚拟中断域），无需 trap 到 hypervisor。这是二进制兼容虚拟化的核心。

### 1.2 IPI 中断的配置

Boot 阶段软件为每个可能的目的 PE 配置 IPI 中断：

```
BOOT:
  GIC <domain>HM,  Xt     ; 配置为 Edge 模式
  GIC <domain>AFF, Xt     ; 配置为 Targeted 路由，Affinity = dest PE

RUNTIME:
  GIC <domain>PEND, Xt    ; 发送 IPI（使中断 Pending）
```

### 1.3 IPI 中断号分配

Arm 建议使用 **LPI** 作为 IPI（因为 LPI 由软件灵活分配），也可以使用未被外设占用的 SPI。

LPI 分配策略（m 个 PE，每个 PE 需要 n 个 IPI）：

```
分配 m × n 个 LPI（INTID 0 ~ m×n-1）
PE y 的 IPI #x → LPI INTID = y × n + x
```

### 1.4 IPI 的时序保证

- IPI 在 **有限时间**（finite time）内完成 Pending 状态更新
- 不保证目的 PE 会立即响应（目的 PE 可能正在屏蔽中断或处理更高优先级中断）

---

## 二、PPI 虚拟化直通（Direct Injection）

### 2.1 PPI 管理架构

GICv5 最关键的架构变化之一：**PPI 状态和配置存放在 PE 的 System Register 中（CPU Interface），而非 IRI/Redistributor**。

| 物理 PPI | 虚拟 PPI |
|---------|---------|
| `ICC_PPI_*_EL1` | `ICV_PPI_*_EL1`（EL1 视角） |
| - | `ICH_PPI_*_EL2`（EL2 管理视角） |

### 2.2 物理 PPI 与虚拟 PPI 的关系

```
   Physical PPI                      Virtual PPI
   (ICC_PPI_SPENDR.PEND[x])         (ICV_PPI_SPENDR.PEND[x])
         │                                    │
         │      ICH_PPI_DVIR.DVI[x]          │
         └─────────── 1: alias ──────────────→│
                      (直接直通)               │
                                              │
         ┌─────────── 0: independent ─────────┘
         │            (hypervisor 软件模拟)
   ICH_PPI_PENDR.PEND[x] 
   (hypervisor 可写，用于模拟)
```

物理 PPI 和同 INTID 的虚拟 PPI 是**独立的两个中断**，Direct Injection 建立了它们 Pending 状态的连接。

### 2.3 Direct Injection 机制（核心）

#### 控制寄存器

- **`ICH_PPI_DVIR<n>_EL2.DVI<x>`**（Direct-inject Virtual Interrupt Register）：控制每个 PPI ID 的直通
  - `DVI[x] = 1`：物理 PPI x 的 Pending 直接注入为虚拟 PPI x 的 Pending
  - `DVI[x] = 0`：虚拟 PPI x 的 Pending 由 hypervisor 通过 `ICH_PPI_PENDR` 独立管理

#### 行为变化

| DVI[x] | 虚拟 PPI Pending 状态来源 | ICH_PPI_PENDR.PEND[x] 角色 |
|--------|-------------------------|---------------------------|
| 0 | `ICH_PPI_PENDR.PEND[x]`（hypervisor 写） | 决定虚拟 PPI Pending |
| 1 | `ICC_PPI_SPENDR.PEND[x]`（物理 Pending） | **IGNORED**（被忽略） |

**当 DVI[x]=1 时**：
- `ICV_PPI_xPENDR.PEND[x]` 成为 `ICC_PPI_xPENDR.PEND[x]` 的 **alias**
- Hypervisor 写 `ICH_PPI_PENDR.PEND[x]` **无效**
- 物理 PPI 的 Pending 状态**透明地**变为虚拟 PPI 的 Pending 状态

### 2.4 直通后的中断处理流程

```
1. 物理 PPI 信号到达 CPU Interface
   └→ ICC_PPI_SPENDR.PEND[23] = 1

2. ICH_PPI_DVIR.DVI[23] = 1
   └→ ICV_PPI_SPENDR.PEND[23] = 1 (alias, 虚拟 PPI 也 Pending)

3. HCR_EL2.IMO = 1, PE @ EL1
   └→ Current Interrupt Domain = Virtual

4. Virtual HPPI 选择：
   ┌─ Candidate HPPI from IRI (virtual LPI/SPI)
   ├─ Candidate HPPI from virtual PPIs ← 包含被注入的 PPI 23
   └→ 取更高优先级者

5. vIRQ signaled to PE
   └→ EL1 执行 GICR CDIA (Interrupt Acknowledge)
   └→ 返回 virtual INTID
   └→ 配置取决于 virtual PPI (ICV_PPI_PRIORITYR, ICV_PPI_ENABLER etc.)

6. EL1 执行 GIC CDEOI (Priority Drop) + GIC CDDI (Deactivate)
   └→ 操作在 Virtual Interrupt Domain
   └→ ICC_PPI_CACTIVER (物理 Active) 同时被清除
```

关键点：**从 EL1 的角度看不到物理 PPI**，一切操作都是在 Virtual Interrupt Domain 中通过 GIC System Instructions 完成。

### 2.5 重要约束

1. **物理 PPI 应该被 disable**（Arm 强烈建议）：当物理 PPI 被直接注入为虚拟 PPI 时，应在物理域 disable 它，避免物理域和虚拟域的中断处理例程同时尝试服务同一中断。

2. **Effective DVI 条件**：`ICH_PPI_DVIR.DVI[x]` 的有效值为 0，如果对应的物理 PPI **没有被 assign 到 Current Physical Interrupt Domain**。

3. **虚拟 PPI 可被隐藏**：通过 `ICH_PPI_HVIR<n>_EL2.HVI<x>` 可以将虚拟 PPI 从 VM 的视角隐藏（访问 RAZ/WI）。

4. **DVI 不影响 HPPI 选择条件**：`ICH_PPI_DVIR.DVI[x]` 只决定 Pending 状态的来源（物理 or hypervisor），不是候选 HPPI 的条件。

### 2.6 嵌套虚拟化下的 PPI 重定向

当启用嵌套虚拟化（`HCR_EL2.{NV, NV1} = {1, 0}`）时，Timer PPI 需要重定向：

| 物理 PPI | 重定向到虚拟 PPI | 场景 |
|---------|----------------|------|
| PPI 30 (CNTP, EL1 Phys Timer) | Virtual PPI 26 (EL1 Virt Timer) | NS=1, DVI30=1 |
| PPI 27 (CNTV, EL1 Virt Timer) | Virtual PPI 28 (EL2 Phys Timer) | NS=1, DVI27=1 |
| PPI 30 | Virtual PPI 20 (Secure EL2 Phys Timer) | NS=0, DVI30=1 |
| PPI 27 | Virtual PPI 19 (Secure EL2 Virt Timer) | NS=0, DVI27=1 |

这样，guest hypervisor (EL1) 看到的虚拟 timer PPI 对应的是物理 PPI 的直通，而真正的虚拟 PPI (如 PPI 27) 则由 EL2 hypervisor 软件模拟。

---

## 三、总结

### IPI 方案对比

| 方面 | GICv3 | GICv5 |
|------|-------|-------|
| IPI 机制 | SGI (INTID 0-15)，专用 SGI 寄存器 | 统一使用 LPI/SPI + GIC PEND 指令 |
| 虚拟 IPI | 需要 trap 到 hypervisor 模拟 | EL1 直接执行 `GIC CDPEND`，在 Virtual Domain 生效 |
| 扩展性 | 最多 16 个 SGI | 软件可分配任意数量 LPI |
| 编程接口 | `ICC_SGI*_EL1` | 统一 `GIC <domain>PEND` |

### PPI 虚拟化方案对比

| 方面 | GICv4 | GICv5 |
|------|-------|-------|
| PPI 存储位置 | Redistributor | CPU Interface (PE System Registers) |
| 虚拟 PPI 支持 | 通过 List Register 间接 | 原生 ICV_PPI_* 寄存器 + Direct Injection |
| 直通方式 | 不支持（或需要 hypervisor 转发） | `ICH_PPI_DVIR.DVI` 一键 alias |
| 虚拟化开销 | PPI 访问 trap 到 EL2 | HCR_EL2.IMO=1 时 EL1 直接操作 Virtual Domain，零 trap |

**核心设计理念**：GICv5 通过 **Interrupt Domain** 分层（物理/虚拟/逻辑/当前）+ **Direct Injection** 机制，让物理 PPI 的 Pending 状态透明映射到虚拟 PPI，使得 Guest (EL1) 可以完全通过 GIC System Instructions 在 Virtual Domain 中处理中断，无需任何 hypervisor trap，实现了真正意义上的 **PPI 中断直通**。
