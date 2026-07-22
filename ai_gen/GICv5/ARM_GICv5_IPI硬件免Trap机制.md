# GICv5 IPI 硬件免 Trap 机制详解

> 基于 ARM IHI 111701 A.a，逐层分析硬件如何做到 Guest (EL1) 发送 IPI 时不需要 trap 到 hypervisor (EL2)。

## 一、核心问题

在 GICv3 中，Guest 发送虚拟 IPI 必须 trap 到 EL2，由 hypervisor 读取 Guest 的 `ICC_SGI*_EL1` 寄存器值，再通过 List Register 模拟注入。这个 trap 是虚拟化 IPI 的主要开销来源。

GICv5 的问题：**Guest (EL1) 执行 `GIC CDPEND` 发送虚拟 IPI 时，硬件如何直接路由到正确的目标 VPE，而不需要 trap？**

---

## 二、逐层分析

### 第 1 层：CPU 指令解码（Decode 阶段）

CPU 执行 `GIC CDPEND, Xt` 时的伪代码（来自 spec page 221）：

```
if PSTATE.EL == EL1 then
    // 条件 1: 是 Legacy 模式吗？
    if EL2Enabled() && HCR_EL2.IMO == '1'
       && IsFeatureImplemented(FEAT_GCIE_LEGACY)
       && ICH_VCTLR_EL2.V3 == '1' then
        UNDEFINED;   // Legacy GICv3 模式：EL1 不能执行此指令

    // 条件 2: Hypervisor 要求 trap 吗？
    elsif EL2Enabled() && ICH_HFGITR_EL2.GICCDPEND == '0' then
        AArch64.SystemAccessTrap(EL2, 0x18);  // Hypervisor 可选 trap

    // 正常路径：硬件直接执行！
    else
        AArch64.GIC(Xt, GICInstrDomain_CD, GICInstr_PEND);
```

关键点：
- **默认不 trap**：只要 hypervisor 不在 `ICH_HFGITR_EL2.GICCDPEND` 中显式要求 trap，硬件直接执行
- `GICInstrDomain_CD` = Current Domain，由硬件根据当前 CPU 状态自动解析

### 第 2 层：Domain 解析（CPU Interface 硬件）

CPU Interface 硬件根据当前执行上下文自动确定 "Current Interrupt Domain"：

```
if PSTATE.EL == EL1
   && HCR_EL2.IMO == 1           // Hypervisor 启用了虚拟 CPU interface
   && ICH_VCTLR_EL2.V3 == 0      // 不是 Legacy GICv3 模式
then
    Current Interrupt Domain = Virtual Interrupt Domain
else
    Current Interrupt Domain = Current Physical Interrupt Domain
```

这条逻辑完全由硬件实现，不需要任何软件查表或判断。`HCR_EL2.IMO` 本身就由 hypervisor 在调度 VPE 时设置好。

### 第 3 层：GICv5 Stream Protocol —— CPUIF → IRS

Domain 解析完成后，CPU Interface 通过 **GICv5 Stream Protocol**（一种基于 AXI5-Stream 的硬件传输协议）向 IRS 发送命令。

#### 物理 IPI 流程（spec Appendix A7.6）

```
IRS                          CPUIF                         PE
                                                        Issue GIC CDPEND, Xt
                             SetPending(Domain=NS, Virtual=0,
                                        INTID=A, Pending=1)
                             ←────────────────────────
                             SetAck()
                             ────────────────────────→
```

#### 虚拟 IPI 流程（spec Appendix A7.6）

```
IRS                          CPUIF                         PE

// 前置步骤：Hypervisor 在 VPE 调度时做了 SetResident
                             Write to ICH_CONTEXTR_EL2
                             making VPE 0 of VM 0 resident
                             SetResident(Valid=1, Domain=NS,
                                         VM=0, VPE=0)
                             ←────────────────────────
                             // IRS updates resident VPE tracking
                             Forward(Domain=NS, Virtual=1,
                                     INTID=A)  // if pending
                             ────────────────────────→
                                                        Assert vIRQ
                             SetResidentAck()
                             ────────────────────────→

// Guest 发送 IPI（无需 trap）
                                                        Issue GIC CDPEND, Xt
                             SetPending(Domain=NS, Virtual=1,
                                        INTID=A, Pending=1)
                             ←────────────────────────
                             SetAck()
                             ────────────────────────→
```

关键观察：
1. **`SetResident` 是 stateful 的**：IRS 记住了 "PE 上当前 resident 的 VPE 是 VM 0 的 VPE 0"
2. 后续的所有 virtual command **不需要再带 VM/VPE 信息**，IRS 自动关联到当前 resident VPE
3. 当 Guest 执行 `GIC CDPEND`，CPU Interface 发出 `SetPending(Virtual=1, INTID=A)`—— Domain、Virtual 标记、INTID 全部由硬件从指令编码和 CPU 状态中提取

### 第 4 层：IRS 处理

IRS 收到 `SetPending(Virtual=1, INTID=A)` 后：

```
1. 解析 Virtual=1 → 这是虚拟中断
2. 查找当前 PE 的 resident VPE → VM 0, VPE 0
3. 在 VM 0 的 virtual IST 中更新 virtual LPI A 的 Pending 状态
4. 检查 virtual LPI A 的 Affinity：
   - 如果 Routing mode = Targeted，取出目标 VPE ID
   - 如果 Routing mode = 1ofN，动态选择目标 VPE
5. IRS → 目标 PE CPUIF：Forward(Domain=NS, Virtual=1, INTID=A)
6. 目标 PE CPUIF：Assert vIRQ
```

### 第 5 层：Virtual LPI 的 Affinity 路由

Guest 在发送 IPI 之前，必须配置该 virtual LPI 的 Affinity（指向目标 VPE）。这也是通过 `GIC CDAFF` 指令完成的，同样是免 trap 的：

```
GIC CDAFF, Xt  // EL1 执行，Current Domain = Virtual
→ CPUIF 发送 SetTarget(Virtual=1, INTID=A, VPE=dest_vpe)
→ IRS 更新 virtual LPI A 的 Affinity = dest_vpe
```

---

## 三、硬件免 Trap 的核心设计

### 3.1 三个硬件自动完成的转换

| 步骤 | 谁来转换 | 输入 | 输出 |
|------|---------|------|------|
| Domain 判定 | CPU Interface 硬件 | PSTATE.EL, HCR_EL2.IMO, ICH_VCTLR_EL2.V3 | Current Domain = Virtual |
| 指令执行 | CPU 硬件 | `GIC CDPEND, Xt` (INTID) | `SetPending(Virtual=1, INTID)` |
| VPE 上下文 | IRS 硬件（stateful） | PE ID (物理通道) | 当前 resident VM/VPE |

### 3.2 为什么不需要 trap

```
GICv3 做法（需要 trap）:
  Guest EL1: MCR ICC_SGI0R_EL1   → trap to EL2
  Hypervisor EL2: 读寄存器，解析 SGI target
  Hypervisor: 查 VM 映射表，找到目标 VPE
  Hypervisor: 写 List Register 注入虚拟 SGI

GICv5 做法（免 trap）:
  Guest EL1: GIC CDPEND, Xt
  CPU HW: PSTATE.EL=EL1 + HCR_EL2.IMO=1 → Virtual Domain
  CPUIF HW: SetPending(Virtual=1, INTID=X) → IRS
  IRS HW: 查 resident VPE + virtual IST affinity → 目标 PE
  目标 PE CPUIF HW: Forward → Assert vIRQ
```

每一步都是硬件完成的，没有任何软件介入。

### 3.3 Hypervisor 的控制点

虽然默认不 trap，hypervisor 保留了精确控制：

**调度级控制**：
- `HCR_EL2.IMO`：0 → 整个虚拟 CPU interface 不可见，EL1 操作回退到物理域
- `ICH_CONTEXTR_EL2.V`：0 → 没有 resident VPE，virtual commands 被当作 NOP
- `ICH_CONTEXTR_EL2.IRICHPPIDIS`：1 → IRI 的中断不参与 Virtual HPPI 选择

**指令级控制（细粒度 trap）**：
- `ICH_HFGITR_EL2.GICCDPEND` = 0 → trap `GIC CDPEND`
- `ICH_HFGITR_EL2.GICCDAFF` = 0 → trap `GIC CDAFF`
- `ICH_HFGRTR_EL2` / `ICH_HFGWTR_EL2` → 类似地控制读写指令

**中断级控制**：
- `ICH_PPI_HVIR<n>_EL2.HVI<x>`：隐藏/暴露特定虚拟 PPI
- `ICH_PPI_DVIR<n>_EL2.DVI<x>`：PPI 直接注入开关

---

## 四、与 GICv3 的对比

```
GICv3 IPI 路径:
  EL1: MCR ICC_SGI0R_EL1, Xn
      → trap to EL2 (HCR_EL2.IMO=1 导致所有 ICC_* 访问 trap)
  EL2: 读 ICH_LR* 判断是 SGI
  EL2: 软件查 GICv3 Redistributor 确定目标 PE
  EL2: 软件模拟虚拟 SGI 到目标 VPE 的 List Register
      → ERET 回 EL1
  延迟: O(microseconds) 量级

GICv5 IPI 路径:
  EL1: GIC CDPEND, Xt
  CPUIF HW → IRS HW: SetPending(Virtual=1, INTID=X)
  IRS HW 查 resident VPE, 更新 IST, 路由到目标 PE
  延迟: O(nanoseconds) 量级（硬件 protocol 延迟）
```

---

## 五、总结

GICv5 的 IPI 免 trap 不是靠单一技巧，而是**三个层面的硬件协同**：

1. **CPU 指令集层面**：`GIC CDPEND` 指令本身支持 `CD`（Current Domain）语义，CPU 根据 `HCR_EL2.IMO` 自动判定操作在物理域还是虚拟域

2. **CPU Interface 硬件层面**：通过 GICv5 Stream Protocol 的 **stateful 连接模型**，`SetResident()` 预先建立 VPE 上下文，后续所有 virtual commands 自动关联到当前 VPE，不需要每条命令携带 VM/VPE ID

3. **IRS 硬件层面**：IRS 维护 VM Table 和 VPE Table 的硬件缓存，virtual interrupt 的 affinity 路由和目标 VPE 选择由 IRS 硬件完成，不需要软件查表转发

本质上，GICv5 把 GICv3 中需要 hypervisor 软件完成的 "Domain 转换 → VPE 查找 → 中断转发" 三步全部下沉到了硬件。
