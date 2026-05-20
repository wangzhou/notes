# 单页路径 PTE[0]-as-Block-Lock 必要性分析

2026.05.20 Sherlock

## 问题

`stage2_map_walker_try_leaf` 中单页路径（`!PROT_CONT`）通过 PTE[0] 加锁来"防止
contig BBM 同时对同一个 block 的 PTE 做修改"。本文论证该机制对正确性并非必要。

## 背景

### 锁模型

```
kvm_fault_lock(kvm)    → read_lock(&kvm->mmu_lock)    // map/relax_perms
KVM_MMU_LOCK(kvm)      → write_lock(&kvm->mmu_lock)   // MMU notifier (unmap/wrprotect)
```

read_lock 之间可并发；write_lock 对所有读者排他。

### 单页 vs contig fault 的 PROT_CONT 决策

```
stage2_contig_supported() → PROT_CONT → stage2_map_contig_leaf
                          → !PROT_CONT → 单页路径
```

PROT_CONT 来自 `user_mem_abort`:
```
if (fault_supports_stage2_huge_mapping(...)) {
    prot |= PROT_CONT;
    vma_shift = CONT_PTE_SHIFT;
} else {
    vma_shift = PAGE_SHIFT;
    force_pte = true;
}
```

`fault_supports_stage2_huge_mapping` 返回 false 的情况:
- `fault_status == FSC_PERM`
- `kvm_is_dirty_logging_active(kvm)`
- `map_size < CONT_PTE_SIZE`

## 分析

### 命题

**同一 contig-aligned block 内，contig BBM 和单页 BBM 不可能并发。**

### 引理 1: VMA 变更由 MMU notifier 在 VMA 修改之前同步 stage-2

`mmu_notifier_invalidate_range_start()` → `kvm_handle_hva_range()`:

```c
// virt/kvm/kvm_main.c:626
KVM_MMU_LOCK(kvm);                        // write_lock
range->handler(kvm, &gfn_range);          // kvm_mmu_unmap_gfn_range
// ... release write_lock
```

VMA 修改（mprotect/madvise/THP split）发生在 notifier start **返回之后**。
此时 stage-2 页表已被清理，不存在旧 contig block 残留。

vCPU 在 VMA 修改后 fault 时:
- VMA 已更新（如 non-hugetlb）
- stage-2 已被 notifier 清理（PTE=0）

**不存在新 VMA + 旧 contig block 共存的窗口。**

### 引理 2: 同一 VMA 内，并发 fault 的 PROT_CONT 决策一致

所有 vCPU 在任意时刻:
- 读同一个 VMA 状态
- `force_pte` 的条件（`fault_status`, `logging_active`）对所有 vCPU 同时成立或不成立
- `PROT_CONT` 对所有并发 fault 相同

不存在一个 vCPU 走 contig 而另一个走单页的情况。

### 引理 3: 相邻不同类型 VMA 不跨 contig block 边界

- hugetlb VMA 对齐于 huge page size（≥CONT_PTE_SIZE）
- mprotect 切分时，VMA 在页边界处切分
- contig block 边界与 hugetlb VMA 边界重合

不存在一个 contig block 内部分 PTE 属于 hugetlb VMA、部分属于 non-hugetlb VMA 的情况。

### 引理 4: write_lock 路径与 read_lock 路径不并发

wrprotect/unmap (write_lock) 修改 contig block 时，map fault (read_lock) 被阻塞。
两者不可能同时修改同一 PTE。

### 结论

上述四个引理穷举了 contig BBM 和单页 BBM 可能并发竞争同一 contig block 的所有路径。
**四项穷举均证明并发不可能发生。**

因此 `stage2_map_walker_try_leaf` 中 PTE[0]-as-block-lock 代码（LOCKED 检查、
CONT 检查、PTE[0] cmpxchg 加锁、跳过 BBM 逻辑、PTE[0] 释放）对正确性并非必要。

## 附录: `stage2_attr_walker` 单页路径

`stage2_attr_walker`（pgtable.c line 1586-1627）中同样存在 PTE[0]-as-block-lock
代码。该路径处理非 contig PTE 的属性更新（wrprotect/relax_perms/mkyoung），
同样适用于上述分析结论——contig BBM 不可能与此路径并发。

该代码也应考虑一并移除。
