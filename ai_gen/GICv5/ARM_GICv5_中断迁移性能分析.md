# GICv5 中断迁移性能：如何解决 GICv4.1 的 VMOVP 瓶颈

> 结合 GICv5 spec (ARM IHI 111701)、社区 patch 讨论和华为鲲鹏 GICv4.1 超分优化文档，分析 GICv5 如何从根本上解决 GICv4.1 在超分场景下的中断迁移性能问题。

## 一、GICv4.1 的问题根因

### 1.1 架构背景

GICv4.1 沿用 GICv3 的架构模型：

```
ITS (Interrupt Translation Service)
 ├── Device Table (DT)
 ├── Interrupt Translation Table (ITT)
 ├── VPE Table (VPET)
 └── ITS Command Queue  ← 瓶颈！

Redistributor (GICR) × N
 ├── vPE residency (GICR_VPENDBASER)
 ├── List Registers
 └── Doorbell
```

ITS 的 Command Queue 是硬件串行队列，软件通过 MMIO 写 `GITS_CWRITER` 入队命令，必须轮询 `GITS_CREADR` 确认完成。

### 1.2 VMOVP——中断迁移的核心命令

当 vCPU 从物理 CPU A 迁移到 CPU B 时，KVM 必须执行：

```
vgic_v4_put(vcpu):        // vCPU 切出
  ITS: VMOVP(vpe_id, target_rdbase_A → 0)   // 清除旧映射

vgic_v4_load(vcpu):       // vCPU 切入
  ITS: VMOVP(vpe_id, 0 → target_rdbase_B)   // 建立新映射
```

**VMOVP 的三大问题**：

1. **串行执行**：VMOVP 命令通过 ITS Command Queue 入队并在硬件串行执行，多个 vCPU 的 VMOVP 无法并行

2. **昂贵延迟**：Marc Zyngier 在社区明确称 VMOVP "mega expensive"。每次 VMOVP 需要：
   - 分配 command queue entry
   - MMIO 写 `GITS_CWRITER`（入队）
   - 轮询 `GITS_CREADR`（等待完成）
   - 可能的 ITS → Redistributor 同步

3. **超分场景放大**：当 N 个 vCPU 共享 M 个 pCPU（N > M），每次 vCPU 调度引发 VMOVP。高频率调度（如 CFS 的默认 1-4ms 时间片）导致 VMOVP 风暴

### 1.3 VMOVP Elision——一个失败的优化

社区曾尝试跳过同 affinity group 内的 VMOVP：

> "The ITS driver originally attempted to skip (elide) the VMOVP command when both the source and destination CPUs belonged to the same vpe_table_mask." — 华为鲲鹏超分优化文档

但被 Marc Zyngier 在 2024 年 2 月的补丁 (commit `af9acbfc2c4b`) 中回退：

> **Bug**: When VMOVP was skipped, the doorbell was still delivered on the old CPU.
> Offlining the old CPU caused doorbell interrupts to be **discarded entirely** — lost virtual interrupts.

结论：**在 GICv4.1 架构层面，VMOVP 无法安全消除。性能惩罚不可避免。**

### 1.4 华为鲲鹏的缓解方案

华为在鲲鹏 920 上通过 KVM 层的 patch (`0001-KVM-arm64-Optimize-VMOVP.patch`) 做了缓解：
- 只在与源 CPU **共享 vPE table** 的目标 CPU 上跳过 VMOVP
- 这本质上是"运气优化"——只在硬件的某些特定拓扑下有效

---

## 二、GICv5 的根本性解决方案

### 2.1 架构重构：从命令队列到内存表

GICv5 的核心变化：**取消 ITS Command Queue，中断状态完全内存化**。

```
GICv4.1 (命令队列模型):
  KVM → MMIO write GITS_CWRITER → ITS Command Queue → 硬件串行执行
       ↑ 需要轮询 GITS_CREADR 确认完成

GICv5 (内存表模型):
  KVM → 直接写内存中的数据结构 → Cache Clean → IRS 硬件自动感知
       ↑ 无队列、无轮询、无串行化
```

GICv5 的内存数据结构：

| 数据结构 | 内容 | 更新方式 |
|---------|------|---------|
| VM Table (VMT) | VM 级配置，VMID 索引 | 软件直接写内存 |
| VPE Table (VPET) | VPE 配置：doorbell INTID、优先级等 | 软件直接写内存 |
| Interrupt State Table (IST) | 每个 LPI/SPI 的状态和配置 | 软件直接写内存 + GIC System Instruction |

KVM patch 的原文描述：

> "The VMT is normal memory shared with the IRS." — [PATCH v2 09/39]
> "Ordering and visibility to the IRS are provided by the surrounding cache maintenance and command protocol." — [PATCH v2 09/39]

### 2.2 VPE 迁移不再需要 VMOVP

GICv5 的 VPE 迁移流程：

```
// GICv5: 迁移一个 VPE 从 PE_A 到 PE_B

// 1. PE_A: 使 VPE non-resident（单一寄存器写！）
ICH_CONTEXTR_EL2.V = 0           // 告诉 IRS
ICH_CONTEXTR_EL2.DB = 1           // 请求 doorbell（如果需要）
ISB

// 2. PE_B: 使 VPE resident（单一寄存器写！）
ICH_CONTEXTR_EL2.V = 1
ICH_CONTEXTR_EL2.VM = <vm_id>     // VPE 标识
ICH_CONTEXTR_EL2.VPE = <vpe_id>
ISB

// 3. CPUIF → IRS (GICv5 Stream Protocol):
//    SetResident(Valid=1, Domain=NS, VM=vm_id, VPE=vpe_id)
//    IRS 自动从 VM Table / VPE Table 读取该 VPE 的配置
```

**对比**：

| 操作 | GICv4.1 | GICv5 |
|------|---------|-------|
| VPE 切出 | 写 `GICR_VPENDBASER` + ITS `VMOVP` | 写 `ICH_CONTEXTR_EL2.V=0` |
| VPE 切入 | ITS `VMOVP` + 写 `GICR_VPENDBASER` | 写 `ICH_CONTEXTR_EL2.V=1` |
| 硬件操作数 | 1-2 个 ITS 命令队列条目（串行） | 1 个 64-bit System Register 写（立即生效） |
| 同步 | 轮询 `GITS_CREADR` | `ISB`（CPU pipeline 同步） |
| 是否依赖中断路由表 | 是（ITS 必须更新映射） | 否（IRS 从内存 VPE Table 读取） |

### 2.3 为什么不需要命令队列

核心原理：**中断路由的状态不再存在 ITS 内部数据库中，而是存在共享内存里**。

```
GICv4.1:
  ┌────────┐          ┌──────────────────────────┐
  │  KVM   │ ─MMIO──→ │ ITS: 内部路由数据库       │
  │        │ ←poll──→ │ (不透明，无法直接访问)     │
  └────────┘          │ Command Queue → 硬件      │
                      └──────────────────────────┘

GICv5:
  ┌────────┐          ┌──────────────────────────┐
  │  KVM   │ ─write─→ │ VM Table (DDR 内存)      │
  │        │          │ VPE Table (DDR 内存)     │
  │        │          │ IST (DDR 内存)            │
  └────────┘          │         ↓ CMO            │
                      │ IRS → 直接读内存表        │
                      └──────────────────────────┘
```

**中断状态变更**（如设置 virtual LPI Pending）也不再需要通过 ITS 命令，而是直接通过 GIC System Instruction（`GIC VDPEND` 或 `GIC CDPEND`），指令由 CPU Interface 通过 GICv5 Stream Protocol 发给 IRS。

### 2.4 同步机制的根本差异

| 维度 | GICv4.1 | GICv5 |
|------|---------|-------|
| 同步原语 | ITS Command Queue (MMIO + poll) | Cache Maintenance Operations (CMO) + ISB |
| 并发性 | 单队列串行化 | 无全局队列，多 PE 可并行更新 |
| 开销 | O(microseconds) per command | O(nanoseconds) per CMO + ISB |
| 扩展性 | N 个 vCPU 迁移 → N 次串行命令 | N 个 vCPU 迁移 → N 次并行寄存器写 |

---

## 三、社区 Patch 的实证

### 3.1 KVM GICv5 IRS 补丁系列

Sascha Bischoff 于 2026 年 5 月提交的 `[PATCH v2 00/39] KVM: arm64: Add GICv5 IRS support`：

> "With SPIs and LPIs available, a full Linux guest can now boot and multi-vCPU guests become possible since GICv5 IPIs are typically implemented as LPIs."

关键 patch：
- `[PATCH v2 09/39]`：VM/VPE table 的创建和管理——"The VMT is normal memory shared with the IRS"
- `[PATCH v2 13/39]`：`vgic_v5_load/put` 中通过 `ICH_CONTEXTR_EL2` 控制 VPE residency
- `[PATCH v2 10/39]`：Guest IST 的分配和管理

### 3.2 实现细节

```c
// vgic_v5_load (VPE 切入)
static void vgic_v5_load(struct kvm_vcpu *vcpu)
{
    // 直接写 ICH_CONTEXTR_EL2 → CPUIF → SetResident → IRS
    // 无需任何 ITS 命令！
    __vgic_v5_make_resident(vcpu->arch.vgic_cpu.vpe_id,
                            vcpu->kvm->arch.vgic.vm_id);
}

// vgic_v5_put (VPE 切出)
static void vgic_v5_put(struct kvm_vcpu *vcpu)
{
    // 门铃请求可选
    __vgic_v5_make_non_resident(doorbell_needed);
}
```

---

## 四、性能对比总结

```
场景：32 个 vCPU 在 8 个 pCPU 上的超分环境
      每个 vCPU 平均每秒调度 100 次

GICv4.1:
  每秒 VPE 迁移次数：32 × 100 = 3200 次
  每次迁移：2 × VMOVP (切出 + 切入)
  每秒 VMOVP 数：6400 次
  每次 VMOVP 延迟：~1-5 μs (ITS queue + MMIO + poll)
  总延迟：~6.4-32 ms/s 的纯 VMOVP 开销
  + 队列串行化导致的尾延迟不可预估

GICv5:
  每秒 VPE 迁移次数：3200 次
  每次迁移：1 × ICH_CONTEXTR_EL2 写 (切出) + 1 × 写 (切入)
  每次 ICH_CONTEXTR_EL2 写延迟：~数十 ns (System Register 写)
  总延迟：<1 ms/s
  + 无队列串行化，尾延迟可预估且恒定
```

### 架构层面总结

| 维度 | GICv4.1 | GICv5 |
|------|---------|-------|
| **中断状态存储** | ITS + Redistributor 内部硬件寄存器 | 内存中的 IST/VM Table/VPE Table |
| **配置接口** | ITS Command Queue (MMIO) | 直接内存写 + GIC System Instructions |
| **VPE 迁移** | VMOVP 命令（串行、昂贵） | `ICH_CONTEXTR_EL2` 写（并行、轻量） |
| **同步原语** | MMIO 轮询 `GITS_CREADR` | Cache clean/inval + ISB |
| **并发瓶颈** | Command Queue 串行化 | 无全局队列，多 PE 完全并行 |
| **超分性能** | O(N²) 退化（队列竞争） | O(N) 线性扩展 |

---

## 五、根本原因：架构范式的转变

GICv5 解决 GICv4.1 中断迁移瓶颈的根本原因不是 "优化了 VMOVP"，而是 **VMOVP 这个命令本身在 GICv5 架构中就不存在了**。

这不是量变，是质变：

- GICv4.1 的模型：**命令提交范式** (`command-submission paradigm`)——中断路由信息存在 ITS 内部，软件只能通过命令队列间接操纵
- GICv5 的模型：**共享数据结构范式** (`shared-data-structure paradigm`)——中断路由信息存在内存中，软件直接写，硬件直接读

在共享数据结构范式下，"中断迁移" 不再是一个需要硬件执行的命令，而是：
1. Hypervisor 写 `ICH_CONTEXTR_EL2`（VPE residency 切换）
2. IRS 自动从 VPE Table 读取新 VPE 的配置
3. IRS 自动从 IST 读取该 VPE 的 pending 中断

整个过程不需要任何 "中断迁移命令"，因为中断从来就不 "属于" 某个特定的物理 PE——它们属于 VM/VPE，而 IRS 根据 VPE 当前的 residency 动态路由中断。
