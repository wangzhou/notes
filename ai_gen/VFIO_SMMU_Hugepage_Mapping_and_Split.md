# VFIO 直通 + 虚机大页场景：SMMU 侧映射与迁移拆分分析

## 问题

虚机使用大页（huge page），设备通过 VFIO 直通，SMMU 侧：
1. 是否也映射为大页（block mapping）？
2. 迁移时 SMMU 侧如何支持大页拆小页？代码逻辑是什么？

---

## 1. SMMU 侧是否映射为大页

**结论：是。** 在 IOVA 和 PA 对齐满足条件时，SMMU 会自动使用 block mapping。

### 映射流程

```
QEMU: ioctl(VFIO_IOMMU_MAP_DMA, {iova, vaddr, size})
  │
  ▼
vfio_iommu_type1_map_dma()                         [vfio_iommu_type1.c:2896]
  │
  ▼
vfio_dma_do_map()                                  [vfio_iommu_type1.c:1681]
  │  分配 vfio_dma，记录 IOVA range
  │
  ▼
vfio_pin_map_dma()                                 [vfio_iommu_type1.c:1581]
  │  循环 pin 物理连续页面，按 npage 批次调用 vfio_iommu_map()
  │
  ▼
vfio_iommu_map()                                   [vfio_iommu_type1.c:1554]
  │  iommu_map(domain, iova, paddr, npage << PAGE_SHIFT, prot)
  │
  ▼
iommu_map_nosync()                                 [iommu.c:2575]
  │  关键：iommu_pgsize() 决定最优映射粒度
  │
  ▼
iommu_pgsize()                                     [iommu.c:2519]
  │  选择原则：
  │  1. pgsize_bitmap & size 过滤（可选页大小不超过剩余长度）
  │  2. (iova | paddr) 的 LSB 对齐约束筛选最大可用粒度
  │  3. (iova ^ paddr) 对齐检查——I/O 和物理地址必须同级对齐
  │  4. 返回最大的可行 pgsize
  │
  ▼
arm_smmu_map_pages()                               [arm-smmu-v3.c:3424]
  │
  ▼
arm_lpae_map_pages() → __arm_lpae_map()            [io-pgtable-arm.c:549,422]
  │  if size == block_size(level): 安装 BLOCK 类型的叶子 PTE
  │  else: 下降到下一级 page table
  │
  ▼
arm_lpae_init_pte()                                [io-pgtable-arm.c:358]
     level < ARM_LPAE_MAX_LEVELS-1 → TYPE_BLOCK
     level == ARM_LPAE_MAX_LEVELS-1 → TYPE_PAGE  (4KB)
```

### 关键决策点：iommu_pgsize()

```c
// iommu.c:2519
static size_t iommu_pgsize(struct iommu_domain *domain, unsigned long iova,
                           phys_addr_t paddr, size_t size, size_t *count)
{
    pgsizes = domain->pgsize_bitmap & size;          // ① 不超过剩余长度
    pgsizes &= GENMASK(__ffs(paddr | iova), 0);      // ② IOVA/PA 对齐约束
    // 选取最大值
    pgsize = 1UL << __fls(pgsizes);
    // 若 IOVA 和 PA 在更大的粒度上也对齐，选取更大者
    if (__ffs(iova ^ paddr) >= __ffs(pgsize))
        pgsize *= 2;  // 尝试翻倍
    ...
}
```

**举例：** arm64 4KB granule、3-level paging，`pgsize_bitmap = 4K | 2M | 1G`：
- 若 `iova = 0x10000000`, `paddr = 0x80000000`, `size = 2MB` → IOVA/PA 都在 2MB 对齐 → **映射为 2MB block**
- 若 `iova = 0x10004000` → 最低对齐 bit 在 4KB → **映射为 4KB page**
- 若 `size = 1GB`, IOVA/PA 都在 1GB 对齐 → **映射为 1GB block**

### 控制参数

```c
// vfio_iommu_type1.c:54
static bool disable_hugepages;
module_param_named(disable_hugepages, disable_hugepages, bool, S_IRUGO | S_IWUSR);
```

当 `disable_hugepages=1` 时，`vfio_pin_pages_remote()` 强制 `npage=1`，每次只映射 4KB，无法形成 block mapping。此外，iommufd 的 VFIO compat v1 路径（`vfio_compat.c:345`）默认 `disable_large_pages=true`。

---

## 2. 迁移时大页拆分：两类路径

### 路径 A：VFIO type1（软件 bitmap，不涉及 SMMU 页表）

```
QEMU: ioctl(VFIO_IOMMU_DIRTY_PAGES, START)
  │
  ▼
vfio_iommu_type1_dirty_pages()                    [vfio_iommu_type1.c:2968]
  │  为每个 vfio_dma 分配软件 bitmap
  │  以最小 pgsize（4KB 或 64KB）为粒度
  │
  ▼
  注册 vfio_dma->bitmap（软件侧，与 IOMMU 页表无关）

QEMU: ioctl(VFIO_IOMMU_DIRTY_PAGES, GET_BITMAP)
  │  遍历 dma->bitmap，copy_to_user 给 QEMU
  │  清零后重新标记已 pinned 页为 dirty

QEMU: ioctl(VFIO_IOMMU_DIRTY_PAGES, STOP)
  │  释放 bitmap
```

**关键点：**
- 整个脏页跟踪在 **`vfio_dma` 的软件 bitmap 层**完成
- **完全不涉及 SMMU 页表拆分**
- 脏页通过 pinned 时标记 + 写 region 时标记来追踪，而非硬件能力
- 不精确（所有 pinned 页都标记为 dirty），但正确
- SMMU 侧 block mapping 保持不变，不受影响
- **不需要 BBML2**

### 路径 B：iommufd + SMMU S1 + HTTU（硬件 DBM，不需要拆分）

```
QEMU: ioctl(IOMMU_HWPT_ALLOC, IOMMU_HWPT_ALLOC_DIRTY_TRACKING)
  │
  ▼
arm_smmu_domain_alloc_paging_flags()              [arm-smmu-v3.c:3361]
  │  仅支持 S1：IOMMU_HWPT_ALLOC_DIRTY_TRACKING
  │  S2 返回 -EOPNOTSUPP                          [arm-smmu-v3.c:2621]
  │
  ▼
arm_smmu_domain_finalise()                        [arm-smmu-v3.c:2590]
  │  enable_dirty = true
  │  pgtbl_cfg.quirks |= IO_PGTABLE_QUIRK_ARM_HD  [arm-smmu-v3.c:2615]
  │
  ▼
  构造 PTE 时对 writable PTE 设置 DBM=1            [io-pgtable-arm.c:489]
  配置 CD 时设置 TCR_HA | TCR_HD                   [arm-smmu-v3.c:1466]

定时 query 脏页：
QEMU: ioctl(IOMMU_HWPT_GET_DIRTY_BITMAP, {iova, length, bitmap})
  │
  ▼
iommu_read_and_clear_dirty() → arm_lpae_read_and_clear_dirty()
  │                                                [io-pgtable-arm.c:845]
  ▼
__arm_lpae_iopte_walk()                            [io-pgtable-arm.c:845]
  │  遍历页表树，对每个叶子 PTE 调用 visit_dirty()
  │
  ▼
visit_dirty()                                      [io-pgtable-arm.c:828]
  │  if iopte_writeable_dirty(pte):  // DBM=1 && AP_RDONLY=0
  │      记录到 dirty bitmap
  │      if !IOMMU_DIRTY_NO_CLEAR:
  │          iopte_set_writeable_clean(ptep)  // 设置 AP_RDONLY → clean
  │
  │  下次设备 DMA 写入 → 硬件自动清除 AP_RDONLY → 重新变 dirty
```

**关键点：**
- **不需要拆分 block mapping。** DBM 在 block 粒度也工作：硬件写 block mapping 覆盖的任意地址都会清除 AP_RDONLY
- 脏页检测粒度 = block 粒度（2MB block 则 2MB 全部标记 dirty，即使只写了 4KB）
- 迁移重传粒度变粗，但不影响正确性
- 仅支持 S1，S2 不支持（`-EOPNOTSUPP`）
- **不需要 BBML2**（因为不需要拆分）

### 路径 C：SMMU S2 dirty tracking（未实现，但分析为什么需要 BBML2）

当前 SMMUv3 S2 dirty tracking **直接返回 -EOPNOTSUPP**（`arm-smmu-v3.c:2621`）。假设未来要支持 S2 脏页跟踪，两种可能方案：

**方案 C1：S2 实现 DBM 等价机制（类似 S1 的 HTTU）**
- 不需要拆分大页
- 不需要 BBML2
- 但 ARM SMMUv3 架构 S2 没有 DBM/HTTU 定义

**方案 C2：软件 write-protect，必须拆分到 4KB**
- 软件 dirty 跟踪需要 write-protect 页面 → 触发 SMMU fault → 标记 dirty → 恢复 writable
- 但如果 block mapping 中的 512 个 4KB 页面只有部分需要 write-protect，必须将 block 拆分为 4KB PTEs，才能对单个 4KB 做权限控制
- 拆分操作：`[block PTE] → [table desc → 512×4KB PTE]`
- 这个操作在 BBM0 下需要 `invalid → TLBI → table` 序列，中间无效窗口导致设备 DMA fault
  
  **而且设备不能 stall/fault**（VFIO 直通设备通常不支持 PRI，且迁移场景下 DMA 必须持续运作）

**这就是 BBML2 成为前提条件的场景：**
```
迁移中 SMMU S2 脏页跟踪：

无 HTTU (S2 不支持)
  → 必须软件 write-protect
  → 必须拆 block → 4KB PTEs（才能逐页控制权限）
  → 拆分时设备 DMA 并发访问，不能容忍 fault
  → 纯软件方案全部失败：
      · BBM 序列: 有无效窗口 → DMA fault ✗
      · 直接替换: BBM0 下 illegal → UNPREDICTABLE ✗
      · 换 TTB: 太重在迁移中不可行 ✗
  → BBML2 成为硬性前提
```

---

## 3. 总结

### 当前主线状态

```
                    当前是否支持        页表格式      是否需要拆分
                    ───────────       ──────────    ────────────
VFIO type1          支持（软件）       不变（保持      不需要（软件 bitmap）
(dirty tracking)    bitmap 在         原始 block     在 vfio_dma 层
                    vfio_dma 层       映射）         追踪

iommufd S1          支持（硬件 DBM）  不变（保持      不需要（DBM 在
(dirty tracking)    SMMU S1 HTTU      原始 block     block 粒度也可
                    需要 FEAT_HD      映射）         以标记脏页）

iommufd S2          不支持             不支持          如果实现了，
(dirty tracking)    -EOPNOTSUPP                       且无 S2 HTTU，
                                                      就需要拆分
```

### 三个关键结论

1. **虚机使用大页时，SMMU 侧确实映射为大页（block mapping）。** 由 `iommu_pgsize()` 根据 IOVA/PA 对齐自动决定，整个映射路径从 VFIO → IOMMU 核心 → io-pgtable-arm 全链路支持。

2. **当前主线迁移时不需要拆大页。** VFIO type1 路径用软件 bitmap（与 SMMU 页表无关），iommufd S1 路径用硬件 DBM（block 粒度即可标记脏页），都不需要拆分。

3. **如果未来要实现无 HTTU 的 S2 dirty tracking，BBML2 会成为必须。** 因为必须拆分 block → 4KB 才能逐页 write-protect，而拆分操作在 BBM0 下无论哪种软件方案（BBM 序列 / 直接替换 / 换 TTB）都无法同时满足"架构合法 + 零 fault + 迁移可接受"的约束。

### 相关文件索引

| 文件 | 关键内容 |
|---|---|
| `drivers/vfio/vfio_iommu_type1.c:1681` | `vfio_dma_do_map()` 入口 |
| `drivers/vfio/vfio_iommu_type1.c:1554` | `vfio_iommu_map()` → `iommu_map()` |
| `drivers/vfio/vfio_iommu_type1.c:2968` | `vfio_iommu_type1_dirty_pages()` 软件 bitmap |
| `drivers/vfio/vfio_iommu_type1.c:54` | `disable_hugepages` 参数 |
| `drivers/iommu/iommu.c:2519` | `iommu_pgsize()` 决定 block/page 粒度 |
| `drivers/iommu/io-pgtable-arm.c:422` | `__arm_lpae_map()` 递归映射 |
| `drivers/iommu/io-pgtable-arm.c:358` | `arm_lpae_init_pte()` BLOCK vs PAGE 类型决定 |
| `drivers/iommu/io-pgtable-arm.c:845` | `arm_lpae_read_and_clear_dirty()` 硬件 DBM 脏页回收 |
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c:2621` | S2 dirty tracking → -EOPNOTSUPP |
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c:2615` | S1 启用 IO_PGTABLE_QUIRK_ARM_HD |
| `drivers/iommu/iommufd/io_pagetable.c:1287` | `iopt_area_split()` iommufd 层的 split |
| `drivers/iommu/iommufd/vfio_compat.c:345` | VFIO compat v1 强制 disable_large_pages |
