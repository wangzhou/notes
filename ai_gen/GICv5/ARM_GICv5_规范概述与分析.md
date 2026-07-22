# ARM GICv5 规范概述与分析

> 基于 `ARM IHI 111701 A.a` (2026/May/26, EAC) 的概括性分析。

## 一、总体定位

GICv5 是 Arm 最新的中断控制器架构规范（文档编号 ARM IHI 111701，版本 A.a，2026年5月发布为 EAC 质量等级）。它定义了 **FEAT_GCIE**（GICv5 CPU Interface Extension），从 Armv9.3-A 开始可选支持，仅限 AArch64。

关键约束：
- **要求实现 FEAT_NMI**（GICv5 必须支持 Non-maskable Interrupt）
- **与 FEAT_GICv3 互斥**（实现 GICv5 的 PE 不再实现 GICv3，`ID_AA64PFR0_EL1.GIC = 0`）
- GICv5 的 CPU Interface 可选支持向后兼容 GICv3 虚拟机（LEGACY virtual CPU interface）

---

## 二、核心架构：IRI + 三大组件

GICv5 的核心是 **IRI（Interrupt Routing Infrastructure，中断路由基础设施）**，连接 PE 的 CPU Interface 与后端中断管理逻辑。IRI 可以是 GICv5 系统架构定义的实现，也可以是 IMPLEMENTATION DEFINED。

### 2.1 系统组件

| 组件 | 角色 | 数量 |
|------|------|------|
| **IRS** (Interrupt Routing Service) | 核心：管理 LPI/SPI 的中断状态、优先级、路由；管理 VM/VPE 状态和虚拟中断；处理 VPE doorbell | >=1 |
| **ITS** (Interrupt Translation Service) | 将 MSI/wire 事件翻译为 LPI INTID；区分物理中断和虚拟中断；通过内存中的 Device Table 和 ITT 工作 | >=0 |
| **IWB** (Interrupt Wire Bridge) | 将传统有线中断信号转换为 ITS 可处理的事件，支持边沿/电平触发 | >=0 |

### 2.2 中断流转路径

```
IWB (有线信号) ──→ ITS (MSI翻译) ──→ IRS (路由/优先级) ──→ CPU Interface (PE)
         SPIs ─────────────────────────────→ IRS
         Software (IPI) ──────────────────→ IRS (via GIC System Instructions)
```

- **SPI**：硬连线直连 IRS，不走内存，适用于早期启动、高可靠、实时场景
- **LPI**：由 ITS 将 MSI 翻译后转发给 IRS，状态和配置存储在内存 IST 中
- **IPI**：软件通过 GIC System Instruction 向 IRS 发送命令使中断 Pending

---

## 三、中断域（Interrupt Domain）—— 最核心的概念革新

GICv5 将中断命名空间分为多个层次，这是与 GICv3/v4 最大的概念差异。

### 3.1 Physical Interrupt Domain（物理中断域）

与 Security state + PAS 绑定：

| Security State | Physical Interrupt Domain | PAS |
|---------------|--------------------------|-----|
| Non-secure | Non-secure | Non-secure |
| Secure | Secure | Secure |
| Realm | Realm | Realm |
| EL3 (Secure or Root) | EL3 | Secure or Root |

- **Current Physical Interrupt Domain**：PE 当前 Exception level + Security state 对应的物理中断域
- 每个 PE 同一时刻只有一个当前物理中断域

### 3.2 Logical Interrupt Domain（逻辑中断域）

- 仅 EL3 可用
- 由 `SCR_EL3.{NSE, NS}` 选择目标物理中断域
- 用途：EL3 软件可以操作非当前 Security state 的中断

### 3.3 Virtual Interrupt Domain（虚拟中断域）

- 当 EL2 实现时存在
- 由 **resident VPE**（驻留虚拟 PE）决定当前可见的虚拟中断集合
- 通过 `ICH_CONTEXTR_EL2` 编程 resident VPE 和 resident VM

### 3.4 Current Interrupt Domain（当前中断域）

运行时决定 System Instruction 操作的目标域：

| 条件 | Current Interrupt Domain |
|------|------------------------|
| EL1 + `HCR_EL2.IMO=1` + `ICH_VCTLR_EL2.V3=0` | Virtual Interrupt Domain |
| 其余所有情况 | Current Physical Interrupt Domain |
| `ICH_VCTLR_EL2.V3=1` + EL0/1 | 未定义（legacy 模式） |

---

## 四、中断类型

| 类型 | INTID 范围 | 特点 |
|------|-----------|------|
| **PPI** (PE-Private Peripheral Interrupt) | 16-31 | 每 PE 私有，如 timer、doorbell，由 CPU Interface 直接管理 |
| **SPI** (Shared Peripheral Interrupt) | 32+（硬件固定） | 硬连线，数量固定，不依赖内存存储，适用于早期启动/实时性场景 |
| **LPI** (Logical Peripheral Interrupt) | 8192+（内存管理） | 基于 IST 管理状态，由 ITS 翻译产生，用于 MSI 和 VPE doorbell |

- **SGI**（Software Generated Interrupt，INTID 0-15）在 GICv5 中仍然存在，用于传统 IPI
- **IPI** 也可通过软件向 IRS 发送 LPI/SPI 命令实现，统一使用 GIC System Instructions
- **VPE Doorbell**：每个 VPE 在 LPI INTID 空间分配一个 doorbell 中断

---

## 五、虚拟化支持

GICv5 的虚拟化是从第一原理设计的，而非像 GICv4 那样在 GICv3 上叠加。

### 5.1 核心概念

- **VM**：16-bit VM ID 标识（架构预留扩展到 >16 bit 的空间）
  - Non-secure VM（hypervisor 管理，EL2）
  - Realm（RMM 管理，Realm EL2）
  - Secure Partition（SPM 管理，Secure EL2）
- **VPE**：VM 内的执行上下文，每个 VPE 有独立的虚拟中断状态
- **Resident VPE**：当前 PE 上 "调度" 的 VPE，其虚拟中断直接可见
- **VPE Doorbell**：当 VPE 非驻留时，产生 doorbell 中断通知 hypervisor

### 5.2 虚拟化数据流

```
VM Table ──→ VM 配置（每个 VM 一项）
VPE Table ──→ VPE 配置（每个 VPE 一项，含 doorbell 配置、调度状态）
     ↓
ITS (虚拟中断翻译: DeviceID + EventID → vINTID + VMID)
     ↓
IRS (虚拟中断路由: vINTID + VMID → 目标 VPE → 目标 PE)
     ↓
CPU Interface (虚拟中断信号 → PE, 作为 virtual IRQ exception)
```

### 5.3 虚拟中断处理

虚拟中断使用与物理中断**相同的编程接口**（System Instructions with VD prefix），提供二进制兼容的虚拟化支持。当 `Current Interrupt Domain = Virtual` 时，EL1 执行的 `GIC CD*` 指令自动操作虚拟中断域，无需 trap。

---

## 六、编程接口

### 6.1 System Instructions 概述

GICv5 不再使用 GICv3 风格的 `ICC_*_EL1` / `ICV_*_EL1` 寄存器，改用统一的 **GIC/GICR System Instructions**：

```
GIC  <operation>, <Xt>     // 写语义（SYS alias）
GICR <Xt>, <operation>     // 读语义（SYSL alias）
```

操作格式：`<domain><command>`，三类域前缀：

| 前缀 | 含义 | 可用 Exception Level |
|------|------|---------------------|
| `CD` (Current Domain) | Current Interrupt Domain | EL1+ |
| `LD` (Logical Domain) | Logical Interrupt Domain | EL3 only |
| `VD` (Virtual Domain) | Virtual Interrupt Domain | EL2+ |

支持的命令：

| Command | 全称 | 功能 |
|---------|------|------|
| `AFF` | Affinity | 设置中断亲和性/路由目标 |
| `RCFG` | Request Configuration | 请求/读取中断配置 |
| `DI` | Deactivate Interrupt | 中断去激活 |
| `DIS` | Disable | 清除中断 Enable |
| `EN` | Enable | 设置中断 Enable |
| `EOI` | End Of Interrupt | 优先级下降 |
| `PEND` | Pending | 设置/清除 Pending 状态 |
| `PRI` | Priority | 设置中断优先级 |
| `IA` (GICR) | Interrupt Acknowledge | 中断确认（读） |
| `NMIA` (GICR) | NMI Acknowledge | NMI 确认（读） |
| `HM` | Handling Mode | 中断处理模式状态 |

### 6.2 GSB（GIC Synchronization Barrier）

两条专用同步屏障指令：

- **`GSB ACK`**：中断确认同步 — 保证之前的中断状态变更对后续 IA 可见
- **`GSB SYS`**：系统同步 — 保证中断配置变更对 IRS/ITS 可见

替代了 GICv3 中依赖 `DSB` + `ISB` 的同步方式。

### 6.3 中断生命周期

```
Inactive ──(pending event)──→ Pending ──(acknowledge)──→ Active ──(deactivate)──→ Inactive
                ↑                    ↓                      |
                └──(retrigger)──── Pending & Active ←───────┘
```

---

## 七、关键数据结构（全部在内存中）

| 数据结构 | 所属组件 | 用途 |
|---------|---------|------|
| **IST** (Interrupt State Table) | IRS | LPI/SPI 的状态（Pending/Active）和配置（Priority/Enable），两级表管理 |
| **VM Table** | IRS | VM 级配置，由 VMID 索引 |
| **VPE Table** | IRS | VPE 配置：调度状态、doorbell INTID、resident PE 等 |
| **Device Table (DT)** | ITS | DeviceID → ITT 基址的映射 |
| **ITT** (Interrupt Translation Table) | ITS | EventID → (INTID, VMID, Physical/Virtual flag) 的翻译 |

所有数据结构由软件分配内存并通过 MMIO 接口配置给 IRS/ITS。

---

## 八、安全性

### 8.1 PAS（Physical Address Space）模型

- 每个 Physical Interrupt Domain 绑定一个 PAS（Non-secure / Secure / Realm / Root）
- IRS/ITS 的内存访问始终携带 Physical Interrupt Domain，受对应 PAS 约束
- MMIO 寄存器访问按页粒度（ITS/IRS）或寄存器粒度（IWB）进行 PAS 过滤

### 8.2 GPC（Granule Protection Check）

- 支持 RME（Realm Management Extension）的 GPC 机制
- 如果 GIC 内存访问失败 GPC，产生 external abort
- GPC 可在 SMMU 或系统级实现（规范不限定具体方式）

### 8.3 MPSS / MPPAS

定义了系统中最特权 Security state 和 PAS，用于确定最高权限中断域：

| 支持的 Security states | MPSS | MPPAS |
|-----------------------|------|-------|
| Non-secure | Non-secure | Non-secure |
| Non-secure, Secure | Secure | Secure |
| Non-secure, Realm, Root | Root | Root |

---

## 九、中断路由与亲和性

### 9.1 IRS 路由条件

IRS 将一个中断转发给 PE 的条件：
1. 中断以该 PE 为 target（直接指定或 1ofN 路由）
2. 中断为 **Pending & Inactive & Enabled**
3. 该中断是此 PE 上所有满足条件的中断中**优先级最高**的

### 9.2 多 IRS 系统

- 系统可以包含多个 IRS，一个 PE 精确连接到一个 IRS，一个 IRS 可连接多个 PE
- 多 IRS 间的通信机制由实现定义（规范不规定）
- 支持跨 IRS 迁移中断亲和性，不丢失状态和配置

### 9.3 1ofN 路由

中断可以被路由到一组 PE 中的任意一个（类似 GICv3 的 1-of-N 中断分发模型），由 IRS 选择组内最合适的 PE。

---

## 十、其他重要特性

### 10.1 NMI（Non-maskable Interrupt）

- 物理 NMI 和虚拟 NMI 均原生支持
- 有独立的 NMI acknowledge 指令（`GICR NMIA`）
- 优先级高于所有普通中断和异常

### 10.2 PMU（Performance Monitoring Unit）

- IRS 和 ITS 各自独立 PMU
- 支持 CoreSight PMU 扩展
- 可过滤按 Security state、Event 类型等维度统计中断事件
- PMU overflow 本身可以产生中断

### 10.3 MPAM（Memory System Resource Partitioning and Monitoring）

- ITS 和 IRS 支持 MPAM，允许对中断处理引发的内存访问进行资源分区

### 10.4 Memory Encryption Contexts

- ITS 和 IRS 支持内存加密上下文，适应机密计算场景

### 10.5 Software Error Reporting

- 各组件均定义了标准化的软件错误报告机制

---

## 十一、与 GICv3/GICv4 的关键差异总结

| 方面 | GICv3/GICv4 | GICv5 |
|------|------------|-------|
| **架构特性** | FEAT_GICv3 / FEAT_GICv4 | FEAT_GCIE（与 GICv3 互斥） |
| **编程接口** | ICC_*_EL1 系统寄存器 | GIC/GICR System Instructions（CD/LD/VD 三域） |
| **中断管理后端** | Redistributor (GICR) 管理 PPI/SPI/LPI | IRS 统一管理 LPI/SPI，PPI 在 CPU Interface |
| **虚拟化模型** | GICv4 直接注入（doorbell + VPE 表），GICv3 需要 trap | 原生 VPE 模型，VM Table/VPE Table，统一 System Instruction 接口 |
| **中断域模型** | 物理 + 虚拟（简单二分） | Physical/Virtual/Logical/Current 四层域 |
| **NMI** | 无原生支持 | FEAT_NMI 强制要求，独立 NMI ack 指令 |
| **同步机制** | DSB + ISB | 新增专用 GSB 指令（GSB ACK / GSB SYS） |
| **RME 支持** | 有限 | 完整 GPC + PAS 过滤 + Memory Encryption Contexts |
| **Security 模型** | 两个 Security state | 最多四个 Security state（Non-secure/Secure/Realm/Root） |

---

## 十二、核心设计思想总结

GICv5 的根本变化可以归结为三条主线：

1. **从寄存器到内存表**：中断状态管理从 Redistributor 寄存器迁移到内存中的 IST/VM Table/VPE Table，实现更灵活的扩展性和虚拟化支持。

2. **从物理/虚拟二分到多域统一**：通过 Physical/Virtual/Logical/Current 四层中断域 +统一的 System Instruction 接口，让物理中断、虚拟中断、EL3 逻辑中断使用同一套指令集，仅在 domain prefix 上区分。

3. **为 Armv9 架构特性做基础设施**：NMI、RME/GPC、Realm、MPAM、Memory Encryption 等 Armv9 的核心特性都在 GICv5 的中断模型中得到了原生的、而非打补丁式的支持。

本质上，GICv5 不只是 GICv4 的 "下一代"，而是一次中断控制器架构的重新设计，为 Armv9 及以后的机密计算、实时性、虚拟化场景提供了统一的中断基础设施。
