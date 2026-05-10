# ARM SMMU HTTU (Hardware Translation Table Update) 特性分析

## 概述

HTTU 是 ARM SMMUv3 的一项硬件特性，允许 SMMU 硬件自动更新页表中的 Access flag (AF) 和 Dirty flag，无需软件 trap 处理缺页中断。该特性由 IDR0 寄存器的 bits [7:6] 标识，分为两个级别:

| IDR0.HTTU 值 | 含义 |
|---|---|
| 1 (`IDR0_HTTU_ACCESS`) | 仅支持硬件 Access flag 更新 (HA) |
| 2 (`IDR0_HTTU_ACCESS_DIRTY`) | 同时支持 HA 和 Hardware Dirty 更新 (HD) |

---

## 硬件工作机制

HTTU 通过修改 LPAE 页表描述符的 bit[51] (DBM — Dirty Bit Modifier) 来实现:

- **写时变为脏**: 硬件对 writable PTE 进行写操作时，若 DBM=1，硬件自动清除 AP[2] (AP_RDONLY) 位，表示页面"已脏"
- **判断脏状态**: `DBM=1 && AP_RDONLY=0` → 页面可写且已被写过 (dirty)；`DBM=0 && AP_RDONLY=0` → 可写但 clean

相关宏定义 (`drivers/iommu/io-pgtable-arm.c`):

```c
#define ARM_LPAE_PTE_DBM                        (((arm_lpae_iopte)1) << 51)

#define iopte_writeable_dirty(pte)              \
    (((pte) & ARM_LPAE_PTE_AP_WR_CLEAN_MASK) == ARM_LPAE_PTE_DBM)

#define iopte_set_writeable_clean(ptep)         \
    set_bit(ARM_LPAE_PTE_AP_RDONLY_BIT, (unsigned long *)(ptep))
```

---

## 寄存器与特征位定义

### SMMU IDR0 (`drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.h`)

```c
#define IDR0_HTTU                  GENMASK(7, 6)
#define IDR0_HTTU_ACCESS           1
#define IDR0_HTTU_ACCESS_DIRTY     2
```

### Context Descriptor TCR (`arm-smmu-v3.h`)

```c
#define CTXDESC_CD_0_TCR_HA            (1UL << 43)
#define CTXDESC_CD_0_TCR_HD            (1UL << 42)
```

### 驱动内部特征位 (`arm-smmu-v3.h`)

```c
#define ARM_SMMU_FEAT_HA            (1 << 21)
#define ARM_SMMU_FEAT_HD            (1 << 22)
```

### ACPI IORT (`include/acpi/actbl2.h`)

```c
#define ACPI_IORT_SMMU_V3_HTTU_OVERRIDE     (3<<1)
```

### IO-Pagetable Quirk (`include/linux/io-pgtable.h`)

```c
#define IO_PGTABLE_QUIRK_ARM_HD             BIT(7)
```

---

## 软件启用流程

### 1. 硬件探测

`arm_smmu_get_httu()` (`arm-smmu-v3.c:4346`) 读取 IDR0.HTTU 字段，转换为驱动内部特征位:
- `IDR0_HTTU_ACCESS_DIRTY` → `ARM_SMMU_FEAT_HD | ARM_SMMU_FEAT_HA`
- `IDR0_HTTU_ACCESS` → `ARM_SMMU_FEAT_HA`

对于 ACPI 探测的设备，还会通过 IORT 表的 `ACPI_IORT_SMMU_V3_HTTU_OVERRIDE` 字段进行覆盖。

### 2. 能力上报

`arm_smmu_dbm_capable()` (`arm-smmu-v3.c:2474`) 要求同时满足 `ARM_SMMU_FEAT_HD` 和 `ARM_SMMU_FEAT_COHERENCY`:

```c
static bool arm_smmu_dbm_capable(struct arm_smmu_device *smmu)
{
    u32 features = (ARM_SMMU_FEAT_HD | ARM_SMMU_FEAT_COHERENCY);
    return (smmu->features & features) == features;
}
```

通过 `IOMMU_CAP_DIRTY_TRACKING` 上报给 IOMMU 核心层。

### 3. Domain 分配

用户通过 `IOMMU_HWPT_ALLOC_DIRTY_TRACKING` 标志分配 Stage-1 domain 时 (`arm-smmu-v3.c:3361`):
- 设置 `IO_PGTABLE_QUIRK_ARM_HD` quirk 到 io-pgtable 配置中
- 仅支持 Stage-1，Stage-2 返回 `-EOPNOTSUPP`

### 4. PTE 构造

io-pgtable 在构造 writable PTE 时设置 DBM 位 (`io-pgtable-arm.c:489`):

```c
else if (data->iop.cfg.quirks & IO_PGTABLE_QUIRK_ARM_HD)
    pte |= ARM_LPAE_PTE_DBM;
```

### 5. CD 配置

`arm_smmu_make_s1_cd()` (`arm-smmu-v3.c:1466`) 在 Context Descriptor 中设置 HA 和 HD 位:

```c
if (pgtbl_cfg->quirks & IO_PGTABLE_QUIRK_ARM_HD)
    target->data[0] |= cpu_to_le64(CTXDESC_CD_0_TCR_HA |
                                   CTXDESC_CD_0_TCR_HD);
```

### 6. 脏页回收

`arm_lpae_read_and_clear_dirty()` (`io-pgtable-arm.c:845`) 遍历页表进行脏页回收:
- 通过 `visit_dirty()` 回调检查每个叶子 PTE
- 使用 `iopte_writeable_dirty()` 判断是否脏
- 将脏页 IOVA 记录到 bitmap 中
- 可通过设置 `AP_RDONLY` 清除脏状态 (除非 `IOMMU_DIRTY_NO_CLEAR` 被设置)

---

## 完整数据流

```
探测            IDR0.HTTU  →  FEAT_HA / FEAT_HD
                    ↓
能力检查         FEAT_HD + FEAT_COHERENCY  →  IOMMU_CAP_DIRTY_TRACKING
                    ↓
Domain分配       IOMMU_HWPT_ALLOC_DIRTY_TRACKING  →  QUIRK_ARM_HD
                    ↓
PTE构造          对 writable PTE 设置 DBM=1
                    ↓
CD编程           设置 TCR_HA=1, TCR_HD=1
                    ↓
运行时           硬件写操作时自动清除 AP_RDONLY，标记脏页
                    ↓
脏页回收         遍历 PTE，检测 DBM=1 && AP_RDONLY=0 的 PTE，记录到 bitmap
```

---

## 主要限制

### 1. 仅支持 Stage-1

Stage-2 domain 的 dirty tracking 明确返回 `-EOPNOTSUPP` (`arm-smmu-v3.c:2621`)。`arm_lpae_read_and_clear_dirty()` 中也强制检查:

```c
if (data->iop.fmt != ARM_64_LPAE_S1)
    return -EINVAL;
```

原因:
- Stage-2 页表描述符格式不同于 Stage-1，没有等价的 DBM 位定义
- KVM 的 Stage-2 页表由 VMM 软件管理 dirty logging，不需要硬件自动更新
- 嵌套虚拟化场景下 Guest S1 和 Hypervisor S2 的 HTTU 协同复杂

### 2. 不支持嵌套虚拟化

iommufd 嵌套接口 (`include/uapi/linux/iommufd.h:601`) 明确列出 HTTU 为不支持的 SMMUv3 特性:

```
 * Several features in the SMMUv3 architecture are not currently
 * supported by the kernel for nesting: HTTU, BTM, MPAM and others.
```

### 3. SVA 路径未启用 HTTU

`arm-smmu-v3-sva.c` 在构造 SVA Context Descriptor 时不设置 HA/HD 位，因此 SVA domain 不支持 HTTU。

### 4. 依赖硬件一致性

HTTU 需要 `ARM_SMMU_FEAT_COHERENCY`（SMMU 的页表遍历与 CPU 之间 cache 一致），否则硬件脏位更新可能产生数据不一致。

---

## CONT PTE 与 HTTU 的交互

提交 `97c5550b7631` ("arm64: contpte: fix set_access_flags() no-op check for SMMU/ATS faults") 修复了一个关键问题:

当 SMMU 没有 HTTU (或 HA/HD 在 CD.TCR 中被禁用) 时，页表遍历器独立评估每个描述符。`ptep_get()` 会在 CONT block 级别聚合 AF/dirty 状态，这会导致 `set_access_flags()` 的 no-op 检查错误地跳过对目标 PTE 的更新——目标 PTE 可能仍然缺少 AF 或 dirty/write 位，但聚合后的状态使检查认为不需要更新。

---

## 相关文件索引

| 文件 | 关键内容 |
|---|---|
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.h` | IDR0_HTTU 寄存器定义、FEAT_HA/FEAT_HD 特征位、CD TCR HA/HD 位 |
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c` | HTTU 探测、DBM 能力检查、CD 配置、domain 分配、脏页回收 |
| `drivers/iommu/io-pgtable-arm.c` | DBM PTE 位定义、PTE 构造、脏页遍历与清除 |
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3-sva.c` | SVA CD 构造 (未启用 HTTU) |
| `include/linux/io-pgtable.h` | IO_PGTABLE_QUIRK_ARM_HD 定义 |
| `include/acpi/actbl2.h` | ACPI IORT HTTU override 定义 |
| `include/uapi/linux/iommufd.h` | 嵌套虚拟化不支持 HTTU 的声明 |
| `arch/arm64/mm/contpte.c` | CONT PTE 与 SMMU 无 HTTU 时的交互修复 |
