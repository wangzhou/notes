# ARM SMMU BBML2 (Broadcast Break-before-Make Level 2) 特性分析

## 概述

BBML2 是 ARM SMMUv3 的一项硬件特性，定义 SMMU 页表遍历器在遇到不一致或正在被软件修改的页表描述符时的行为级别。SMMU IDR3 寄存器的 bits [12:11] 标识 BBM 支持级别：

| IDR3.BBM 值 | 含义 |
|---|---|
| 0 (Level 0) | 无 BBM 保证：软件必须严格遵循 BBM 序列，任何非法修改可能触发 TLB conflict abort |
| 1 (Level 1) | 部分支持：SMMU 可容忍部分变更而不需要显式 TLB 无效化 |
| 2 (Level 2) | 完整支持：SMMU 容忍任意页表修改，无需软件执行中间 TLBI+DSB，且**保证不触发 TLB conflict abort** |

**核心问题**：在 BBM Level 0 下，当软件修改页表时（如将 block mapping 拆分为 table，或将 page mapping 合并为 block），必须严格遵循 break-before-make 序列——先将旧描述符设为无效 → TLBI+DSB → 写入新描述符。中间无效窗口导致并行的 SMMU DMA 访问看到缺页，引发性能和正确性问题。BBML2 消除这个约束，允许 hitless 的页表修改。

SMMUv3 架构规范（IHI 0070G §3.21.1.3）规定：当 SMMU 声明 BBML2 时，它承诺在遇到不一致页表时，要么重试以获取一致结果，要么产生一致的结果——**绝不产生 TLB conflict abort**。这一保证比 ARMv8-A CPU 架构更强，也是 SMMU 侧 BBML2 的关键价值。

---

## 寄存器与特征位定义

### SMMU IDR3 (`drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.h`)

```c
#define ARM_SMMU_IDR3           0xc
#define IDR3_BBM                GENMASK(12, 11)
```

### SMMU 驱动内部特征位 (`arm-smmu-v3.h`)

```c
#define ARM_SMMU_FEAT_BBML2     (1 << 24)
```

### IOMMUFD 用户态 ABI (`include/uapi/linux/iommufd.h:592`)

BBML 作为 IDR3 的字段暴露给用户态 VMM，使 VMM 可以查询 SMMU 是否支持 BBML2：

```
 * idr[3]: BBML, RIL
```

---

## 硬件探测

`arm_smmu_device_hw_probe()` 中直接读取 IDR3.BBM 字段（`drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c:4509`）：

```c
if (FIELD_GET(IDR3_BBM, reg) == 2)
    smmu->features |= ARM_SMMU_FEAT_BBML2;
```

- 仅当 BBM 字段值为 2（BBML2）时才设置特征位
- 与 HTTU 探测不同，BBML2 不需要 ACPI IORT 额外配置——它直接从硬件寄存器读取

---

## 两类场景：纯软件能解决 vs 必须依赖 BBML2

理解 BBML2 是否必需，关键在于区分**谁在修改页表**，以及**修改者能否与 SMMU 协调**。

---

### 类别 A：软件可以解决（BBM Level 0 下可行，BBML2 是优化）

当 **SMMU 驱动自身独占控制页表** 时，所有页表修改都发生在驱动代码中，驱动可以在每次修改时插入完整的 BBM 序列：

```
1. 写入 invalid descriptor
2. TLBI + DSB（确保 SMMU 不再缓存旧值）
3. 写入 new descriptor
4. （可选）TLBI 使新描述符生效
```

这个序列在 BBM Level 0 下是**架构正确的**。代价是步骤 1→2 之间存在一个无效窗口，SMMU 在此期间看到 invalid descriptor 会产生 translation fault。但这个 fault 是**可恢复的**（SMMU stall/resume 或 PRI/ATS 重试），不会导致系统崩溃。

**纯软件可解决的典型场景：**

| 场景 | 页表归属 | 修改者 | 软件方案 |
|---|---|---|---|
| DMA mapping domain | SMMU 驱动 | SMMU 驱动 | BBM 序列，代价是无效窗口 |
| VMM 管理的 S2 | VMM | VMM | BBM 序列，代价是无效窗口 |
| io-pgtable split block unmap | SMMU 驱动 | SMMU 驱动 | BBM 序列可行，但被移除因为非 hitless |
| CONT PTE 建立/拆分 | SMMU 驱动 | SMMU 驱动 | BBM 序列可行，有无效窗口 |

以 io-pgtable split block unmap 为例：将 block IOPTE 替换为 table descriptor 时，软件完全可以做 BBM 序列（invalid → TLBI → table）。提交 `33729a5fc0ca` 移除这个路径，不是因为架构上做不到，而是因为**非 hitless 的性能代价不可接受**。BBML2 在此场景下是**性能优化**，不是正确性依赖。

---

### 类别 B：软件无法解决（BBML2 是硬性必需）

当 **SMMU 遍历的页表由另一个 agent 修改**，且该 agent 不受 SMMU 驱动控制时，纯软件方案失效。

**根本原因：SMMU 的页表遍历器是一个独立于 CPU 的硬件 agent。** 它可以在任何时钟周期发起页表遍历。如果页表正在被另一个 agent（CPU）修改，且修改过程没有插入 SMMU 的 TLBI+DSB 隔离，SMMU 就可能观察到不一致的中间态。

#### 核心场景：SVA

SVA 是唯一已落地的一定需要 BBML2 的场景。分析如下：

**SVA 的架构前提：** CPU 和 SMMU 共享同一个进程页表。进程页表由 CPU 的 MM 子系统（缺页处理、mprotect、THP、mremap 等）管理，而不是由 SMMU 驱动管理。

**需要先澄清一个关键区别：SMMU 的 translation fault 和 TLB conflict abort 是两种不同的异常。**

SVA 场景下，SMMU 遇到一个 invalid/non-present 描述符触发的 translation fault（或 permission fault），确实可以通过 PRI/Stall 机制上报给 CPU 端软件处理，和 CPU 自身的缺页处理类似。这一点是 SVA 能够工作的基础。

但 **TLB conflict abort 是另一类异常**——它发生在 SMMU 页表遍历过程中检测到页表内部一致性被破坏时。这是系统级 fatal error（类似 SError），无法通过 PRI/Stall 恢复，无法绑定到进程上下文，一旦触发整个系统不可用。

**为什么软件无法解决：**

核心问题是 BBM Level 0 下，SMMU 遍历到正在被 CPU 修改的页表时，行为是架构上的 **UNPREDICTABLE**：

```
CPU 修改 PTE 的序列:                 SMMU 并发遍历同一页表:

  store new value → [cache line        TLB walker 读取该 PTE
  传播中，SMMU 可能看到:                   │
  · 旧值 (一致)                  ──── 正常，返回旧翻译
  · 新值 (一致)                  ──── 正常，返回新翻译
  · 中间态/撕裂值 (不一致)       ──── 行为 UNPREDICTABLE：
                                       可能是 translation fault (可恢复)
                                       可能是 TLB conflict abort (不可恢复)
                                       可能是 corrupted data (静默错误)]
```

BBM0 规范不对这个中间态做任何约束——实现可以触发 fault、abort、或返回不确定数据。软件无法控制 SMMU 硬件会走哪条路径：

1. **CPU 修改页表时不会插入 SMMU TLBI。** CPU MM 热路径（缺页处理是最高频的内核路径之一）修改 PTE 的步进是 write PTE → dsb(ishst) → isb，没有 SMMU 的 TLBI。要在所有 CPU 页表修改点插入 SMMU TLBI 在数量和性能上都不现实。

2. **无法"暂停" SMMU 遍历。** SMMU 页表遍历是异步的、自主的硬件行为，没有任何机制可以在 CPU 修改页表时短暂禁用 SMMU。

3. **修改点高度分散。** CPU 页表修改发生在数十个调用路径中（pte_offset_map、set_pte_at、ptep_set_access_flags、pmdp_huge_get_and_clear、THP collapse/split 等），无集中入口。

**BBML2 解决的核心问题：**

BBML2 把 SMMU 遇到不一致页表时的行为从 **UNPREDICTABLE** 收紧为**确定性保证**：SMMU 必须要么重试遍历、要么返回一致的旧值或新值——**明确禁止**产生 TLB conflict abort，也禁止返回不确定的翻译结果。这样，无论 CPU 如何修改页表，SMMU 侧都不会 Crash，至多触发一个可恢复的 translation fault（由 PRI/Stall 正常处理）。

**这就是为什么 `arm_smmu_sva_supported()` 把 BBML2 作为硬性 gate：** 没有 BBML2，SVA 在架构上就是 unsafe 的（不是性能问题，是正确性问题）。

#### 潜在场景：嵌套翻译中的 Guest S1

在嵌套翻译场景下，如果 Guest 直接管理自己的 S1 页表（不经 VMM 截获），且设备直接分配给 Guest，SMMU 遍历 Guest S1 时可能遇到 Guest vCPU 正在修改的中间态。这与 SVA 面临同样的问题，也需要 BBML2。但当前主线嵌套翻译未支持此模式。

---

### 区分总结

```
页表修改者 == SMMU 页表拥有者？
    │
    ├── 是 → 类别 A：软件 BBM 序列可行
    │       BBML2 = 性能优化（消除无效窗口，hitless）
    │       场景：DMA domain, VMM S2, io-pgtable 操作
    │
    └── 否 → 类别 B：纯软件无法解决
            BBML2 = 正确性必需（防止 TLB conflict abort）
            场景：SVA（CPU 改 S1，SMMU 同时遍历）
                  嵌套 S1（Guest vCPU 改 S1，SMMU 同时遍历）
```

---

## 使用场景详述

### 1. SVA — 唯一已落地的 BBML2 硬依赖

`arm_smmu_sva_supported()` 将 BBML2 作为 SVA 在 SMMU 侧的硬性前提条件（`drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3-sva.c:209`）：

```c
bool arm_smmu_sva_supported(struct arm_smmu_device *smmu)
{
    u32 feat_mask = ARM_SMMU_FEAT_COHERENCY;
    if (system_supports_bbml2_noabort())
        feat_mask |= ARM_SMMU_FEAT_BBML2;
    if ((smmu->features & feat_mask) != feat_mask)
        return false;
    ...
}
```

BBML2 是 SVA 在 SMMUv3 上安全工作的架构前提，不是性能优化。没有 BBML2 的 SMMU 不支持 SVA。

### 2. io-pgtable split block unmap — 纯软件可解决，BBML2 是优化

提交 `33729a5fc0ca` 移除了 `arm_lpae_split_blk_unmap()`。当前代码禁止部分 unmap 大块映射（`drivers/iommu/io-pgtable-arm.c:679`）：

```c
WARN_ONCE(true, "Unmap of a partial large IOPTE is not allowed");
return 0;
```

软件 BBM 序列可以正确实现此操作，但中间无效窗口会导致无关 DMA 看到 translation fault。BBML2 可以消除无效窗口，实现 hitless split。这是 BBML2 的优化用例，非硬依赖。

### 3. Stage-2 CONT PTE 管理 — 纯软件可解决，BBML2 是优化

SMMU Stage-2 CONT PTE 的建立/拆分，页表由 VMM/SMMU 驱动控制，软件 BBM 序列可行。BBML2 可实现 hitless 转换。当前主线未利用 BBML2 优化此路径。

---

## 架构规范中对 BBML2 的保证

SMMUv3 架构规范（IHI 0070G §3.21.1.3）对 BBM Level 2 的定义要点：

1. **不产生 TLB conflict abort**：SMMU 遇到不一致页表时，保证不产生 TLB conflict abort。这一点 SMMU 比 CPU 更强——CPU 架构允许 BBML2 实现选择产生 abort

2. **更改描述符类型（block ↔ table）**：允许直接将 block descriptor 替换为 table descriptor（或反向），无需中间 invalid descriptor + TLBI

3. **更改地址范围大小**：允许改变 block/table 的粒度（如 2MB ↔ 4KB）

4. **更改访问权限**：允许直接修改描述符的 AP、XN 等属性位

上述所有操作无需 TLBI+DSB 隔离，SMMU 保证最终看到一致的结果。

---

## 相关文件索引

| 文件 | 关键内容 |
|---|---|
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.h` | IDR3_BBM 定义、ARM_SMMU_FEAT_BBML2 特征位 |
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c:4509` | IDR3.BBM 探测与 BBML2 特征位设置 |
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3-sva.c:209` | SVA 对 SMMU BBML2 的强制依赖检查 |
| `drivers/iommu/io-pgtable-arm.c:679` | split block unmap 移除（因 BBM0 约束） |
| `include/uapi/linux/iommufd.h:592` | IDR3 BBML 字段暴露给用户态 VMM |

---

## 主线支持状态总结

**(1) 硬件探测：已完成** (`arm-smmu-v3.c:4509`)
- SMMUv3 驱动通过 IDR3.BBM 检测 BBML2，设置 `ARM_SMMU_FEAT_BBML2`

**(2) SVA 依赖：已完成** (`arm-smmu-v3-sva.c:209`)
- SVA 开启要求 SMMU 具备 BBML2 特性

**(3) io-pgtable：间接完成** (`io-pgtable-arm.c:679`)
- 移除了 BBM0 下非法的 split block unmap 路径
- 尚未为 BBML2 设备实现恢复 split 优化

**(4) Stage-2 CONT PTE：未涉及**
- SMMU Stage-2 CONT PTE 管理中未利用 BBML2 优化 BBM 序列

**(5) 嵌套虚拟化：未涉及**
- BBML2 在嵌套虚拟化场景下的使用尚未实现
