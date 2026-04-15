# ARM64 KVM Stage2 2M 大页拆分为 4K 小页的所有场景

## 前提约束

- 虚机 stage2 使用 **2M 大页**（PMD block mapping）
- Guest 的 backing memory 使用 **hugetlbfs（传统预留大页）**，而非 THP
- hugetlbfs 页从预留池分配，不参与 host 内核常规内存管理
  （不可回收、不被 KSM 扫描、不被 NUMA balancing 自动迁移、不参与 compaction）

基于 Linux 内核源码（v7.0-rc 系列）整理。

---

## 一、脏页跟踪（Dirty Logging）相关 — 最常见的场景

### 1. 开启脏页跟踪时的主动拆页（Eager Split）

- **函数**: `kvm_mmu_split_huge_pages()` -> `kvm_pgtable_stage2_split()` -> `stage2_split_walker()`
- **文件**: `arch/arm64/kvm/mmu.c:120`, `arch/arm64/kvm/hyp/pgtable.c:1480`
- **触发**: 用户态通过 `KVM_SET_USER_MEMORY_REGION` 开启 memslot 的脏页跟踪
  （不带 `KVM_DIRTY_LOG_INITIALLY_SET` 标志时）
- **原理**: 脏页跟踪需要按 4K 粒度记录哪些页被写过，PMD block 无法提供这个粒度，
  因此需要预先把所有 2M 大页拆成 4K 小页

### 2. KVM_CLEAR_DIRTY_LOG 时的增量拆页

- **函数**: `kvm_arch_mmu_enable_log_dirty_pt_masked()` -> `kvm_mmu_split_huge_pages()`
- **文件**: `arch/arm64/kvm/mmu.c:1297`
- **触发**: 使用 `KVM_DIRTY_LOG_INITIALLY_SET` + `KVM_CLEAR_DIRTY_LOG` 的
  manual-protect 模式
- **原理**: 分批拆页，只在 userspace 清除脏标记的区域上拆，减少一次性拆页的开销

### 3. 写保护后的写缺页触发拆页

- **函数**: `user_mem_abort()` 中 `force_pte = logging_active`
- **文件**: `arch/arm64/kvm/mmu.c:1661`, `arch/arm64/kvm/mmu.c:1917`
- **触发**: 脏页跟踪开启期间，guest 对被 write-protect 的大页产生写缺页
- **原理**: `logging_active` 为 true 时，`force_pte = true`，映射粒度被强制为
  `PAGE_SIZE`。已有的 PMD block 会通过 `stage2_map_walk_leaf()` 被拆分

**详细时序**:

```
时刻 T1: 建立 2M PMD block mapping（RW）
         stage2 页表: IPA → HPA, PMD block, 可读可写

时刻 T2: 开启脏页跟踪
         → kvm_stage2_wp_range() 把 PMD block 原地改为只读（清除 S2AP_W）
         → 注意：此时没有拆页，仍然是 2M block，只是权限变了

时刻 T3: Guest 写该区域
         → ARM MMU 检测到写只读的 PMD block → permission fault
         → 进入 user_mem_abort():
           ┌─ logging_active = true
           ├─ force_pte = true
           ├─ vma_pagesize = PAGE_SIZE        ← 期望的映射粒度
           ├─ fault_granule = PMD_SIZE        ← 已有映射的粒度
           └─ vma_pagesize != fault_granule   ← 粒度不匹配!
         → 不能走 kvm_pgtable_stage2_relax_perms() 原地改权限
           （relax_perms 只能在粒度匹配时原地更新，不改变页表结构）
         → 只能走 kvm_pgtable_stage2_map(PAGE_SIZE) 重新映射
         → stage2_map_walk_leaf() 拆分 PMD block 为 4K PTE
```

**注意**: 不是 permission fault 本身导致粒度变小，而是脏页跟踪开启后
`force_pte=true` 导致期望粒度变成了 PAGE_SIZE。Permission fault 只是触发
重新进入 `user_mem_abort()` 的时机，在 `user_mem_abort()` 中发现期望粒度
（PAGE_SIZE）与已有映射粒度（PMD_SIZE）不匹配，才走了拆页路径。

---

## 二、Host 极端事件（MMU Notifier 回调）

由于使用 hugetlbfs，host 常规内存管理操作（页面回收、KSM、NUMA balancing、
compaction、khugepaged）**都不会影响** hugetlb 页，因此以下仅列出仍可能
触发 stage2 unmap 的极端场景。

**注意**: 即使 stage2 被 unmap 后 re-fault，hugetlbfs 的 backing 仍然是完整的
2M 页（不会像 THP 那样被拆成 4K），因此**重建时通常仍恢复为 2M block mapping**，
不会真正"拆小"。只有 backing page 本身被 dissolve/释放的情况才会导致无法恢复。

### 4. 硬件内存错误（Memory Failure / MCE）

- **是否真正拆小**: 如果 hugetlb 页被 dissolve 为普通 4K 页，guest re-fault 时
  只能以 4K 重建映射。如果成功迁移到另一个 hugetlb 页，则可恢复 2M。

**完整函数调用链**:

```
MCE 硬件中断 / memory_failure_queue()
│
▼
memory_failure(pfn, flags)                        [mm/memory-failure.c:2342]
│  pfn_to_online_page(pfn) 获取 struct page
│
├─ 检测到是 hugetlb 页 ──────────────────────────────────────────────────┐
▼                                                                        │
try_memory_failure_hugetlb(pfn, flags, &hugetlb)  [mm/memory-failure.c:2035]
│                                                                        │
├─ get_huge_page_for_hwpoison(pfn, ...)            [mm/memory-failure.c:2045]
│    └─ __get_huge_page_for_hwpoison()             [mm/memory-failure.c:1972]
│         ├─ hugetlb_update_hwpoison(folio, page)  设置 HWPoison 标记
│         ├─ [空闲页] folio_test_hugetlb_freed()  → 返回 MF_HUGETLB_FREED
│         └─ [在用页] folio_test_hugetlb_migratable() → 返回 MF_HUGETLB_IN_USED
│
├─────── 路径 A: 空闲 hugetlb 页 (MF_HUGETLB_FREED) ──────────────────────
│  │
│  ▼
│  __page_handle_poison(p)                         [mm/memory-failure.c:171]
│    └─ dissolve_free_hugetlb_folio(folio)         [mm/hugetlb.c:2014]
│         ├─ remove_hugetlb_folio(h, folio)        从 hugetlb 空闲链表移除
│         └─ update_and_free_hugetlb_folio(h, folio) 拆为 buddy 4K 页
│
│  ※ 空闲页无用户态映射，不触发 mmu_notifier，不影响 stage2
│
├─────── 路径 B: 在用 hugetlb 页 (MF_HUGETLB_IN_USED) ────────────────────
│  │
│  ▼
│  hwpoison_user_mappings(folio, p, pfn, flags)    [mm/memory-failure.c:1580]
│  │  collect_procs(folio, p, &tokill)             收集受影响进程（QEMU）
│  │
│  ▼
│  unmap_poisoned_folio(folio, pfn, must_kill)     [mm/memory-failure.c:1524]
│  │  ttu = TTU_IGNORE_MLOCK | TTU_SYNC | TTU_HWPOISON
│  │
│  │  [hugetlbfs non-anon 路径, line 1552-1568]:
│  │    hugetlb_folio_mapping_lock_write(folio)    获取 i_mmap_rwsem 写锁
│  │
│  ▼
│  try_to_unmap(folio, ttu | TTU_RMAP_LOCKED)      [mm/rmap.c:2386]
│  │  遍历所有映射该 folio 的 VMA（rmap walk）
│  │
│  ▼
│  try_to_unmap_one(folio, vma, address, ...)      [mm/rmap.c:1978]
│  │
│  │  [hugetlb 特殊处理, line 2013-2023]:
│  │    adjust_range_if_pmd_sharing_possible()     调整 range 覆盖共享 PMD
│  │    hsz = huge_page_size(hstate_vma(vma))      获取 hugetlb 页大小
│  │
│  ▼
│  mmu_notifier_invalidate_range_start(&range)     [mm/rmap.c:2024]
│  │  event = MMU_NOTIFY_CLEAR
│  │
│  ▼ ═══════════════════════ 进入 KVM 层 ═══════════════════════════════
│
│  kvm_mmu_notifier_invalidate_range_start(mn, range)
│  │                                               [virt/kvm/kvm_main.c:726]
│  │  设置 hva_range.handler = kvm_mmu_unmap_gfn_range
│  │  递增 mn_active_invalidate_count
│  │
│  ▼
│  kvm_handle_hva_range(kvm, &hva_range)           [virt/kvm/kvm_main.c:561]
│  │  遍历 address spaces 和 memslots
│  │  HVA → GFN 地址转换
│  │  获取 KVM_MMU_LOCK (写锁)
│  │  kvm_mmu_invalidate_begin(kvm)
│  │
│  ▼
│  kvm_mmu_unmap_gfn_range(kvm, &gfn_range)       [virt/kvm/kvm_main.c:720]
│  │  kvm_mmu_invalidate_range_add(kvm, start, end) 记录失效范围
│  │
│  ▼
│  kvm_unmap_gfn_range(kvm, range)                 [arch/arm64/kvm/mmu.c:2224]
│  │  GFN → IPA 转换 (start << PAGE_SHIFT)
│  │  kvm_nested_s2_unmap(kvm)                     处理嵌套 stage2
│  │
│  ▼
│  __unmap_stage2_range(&kvm->arch.mmu, start, size, may_block)
│  │                                               [arch/arm64/kvm/mmu.c:328]
│  ▼
│  stage2_apply_range(mmu, start, end, kvm_pgtable_stage2_unmap, may_block)
│  │                                               [arch/arm64/kvm/mmu.c:62]
│  │  按 granule 大小分块迭代，每块调用:
│  │
│  ▼
│  kvm_pgtable_stage2_unmap(pgt, addr, size)       [arch/arm64/kvm/hyp/pgtable.c:1189]
│  │  设置 walker.cb = stage2_unmap_walker
│  │  walker.flags = WALK_LEAF | WALK_TABLE_POST
│  │
│  ▼
│  kvm_pgtable_walk(pgt, addr, size, &walker)      页表遍历
│  │
│  ▼
│  stage2_unmap_walker(ctx, visit)                 [arch/arm64/kvm/hyp/pgtable.c:1146]
│  │  对于 PMD block（leaf entry）:
│  │
│  ▼
│  stage2_unmap_put_pte(ctx, mmu, mm_ops)          [arch/arm64/kvm/hyp/pgtable.c:892]
│     ├─ kvm_clear_pte(ctx->ptep)                  清除 PMD block entry
│     ├─ __kvm_tlb_flush_vmid_ipa()                TLB 失效（或延迟到最后）
│     └─ mm_ops->put_page(ctx->ptep)               递减页表引用计数
│
│  [延迟 TLB flush 时]:
│  kvm_tlb_flush_vmid_range(mmu, addr, size)       批量 TLBI range
│
│ ═══════════════════════ 返回 MM 层 ════════════════════════════════════
│
│  huge_ptep_clear_flush(vma, address, pvmw.pte)   [mm/rmap.c:2157]
│     清除 host 侧 hugetlb PTE
│
│  set_huge_pte_at(mm, addr, pte, hwpoison_entry)  [mm/rmap.c:2199]
│     安装 hwpoison swap entry，后续访问产生 SIGBUS
│
│  mmu_notifier_invalidate_range_end(&range)       [mm/rmap.c:2360]
│
├─────── 后续处理 ─────────────────────────────────────────────────────────
│
▼
identify_page_state(pfn, p, page_flags)            [mm/memory-failure.c:2106]
  └─ me_huge_page(folio, pfn)                      [mm/memory-failure.c:1160]
       ├─ [有映射]: truncate_error_folio()         截断错误页
       └─ [匿名页无映射]: folio_put() + __page_handle_poison()
             └─ dissolve_free_hugetlb_folio()      拆为 buddy 4K 页，隔离毒页
```

**关键说明**:

1. **mmu_notifier 触发点**: 在 `try_to_unmap_one()` 中（`mm/rmap.c:2024`），
   event 类型为 `MMU_NOTIFY_CLEAR`
2. **stage2 处理方式**: `stage2_unmap_walker()` 是**整体清除** PMD block entry，
   而非拆分为 4K PTE。整个 2M 映射被移除，guest 后续访问会触发 stage2 fault
3. **re-fault 后的映射粒度**: 取决于 hugetlb 页是否被 dissolve。如果 `me_huge_page()`
   调用了 `dissolve_free_hugetlb_folio()` 将大页拆为 buddy 4K 页，
   则 guest re-fault 时只能建立 4K PTE 映射；如果大页未被 dissolve（仅做了
   poison 标记），则中毒子页产生 SIGBUS，其余部分 re-fault 仍可恢复 2M block

### 5. Host 内存热下线（Memory Hotplug Offline）

- **触发**: 管理员在 host 上执行
  `echo offline > /sys/devices/system/memory/memoryXX/state`，
  该物理内存块上恰好有被 VM 使用的 hugetlb 页
- **说明**: 这是 **host 侧**操作，不涉及 guest 内核。**IPA 不变，变的是底层 HPA**。
- **触发链**:
  ```
  管理员在 host offline 某个物理内存块
      -> offline_pages() -> 迁移该区域所有页
      -> hugetlb 页从旧 HPA 迁移到新 HPA（仍是 hugetlb 池中的 2M 页）
      -> mmu_notifier -> stage2 旧的 IPA→旧HPA 映射被 unmap
      -> guest re-fault -> 建立 IPA→新HPA 的映射
      -> 新 backing 仍然是 hugetlb 2M 页 -> 恢复 2M block mapping
  ```
- **是否真正拆小**: **不会**。hugetlb 迁移是 hugetlb→hugetlb，新页从 hugetlb 池分配，
  re-fault 后一定能恢复 2M block mapping。迁移失败的话 offline 操作本身就失败，
  什么都没变。此场景仅造成临时 unmap，不会导致拆小。

### 6. QEMU/Userspace 主动操作（非常规场景）

- **触发**: QEMU 调用 `madvise(MADV_DONTNEED)` / `munmap()` / `mremap()`
  释放或重映射 hugetlbfs 页
- **是否真正拆小**: 取决于后续是否重新 mmap hugetlbfs 页。正常运行中 QEMU 不会这么做。

### 7. 显式页面迁移请求

- **触发**: 管理员或运维工具通过 `move_pages()` / `mbind()` 主动请求迁移
  hugetlb 页到其他 NUMA node
- **是否真正拆小**: hugetlb 页迁移后仍是 2M，re-fault 可恢复 2M block mapping。

---

## 三、对齐/大小约束不满足

### 8. Memslot 或 VMA 对齐不满足 PMD 块映射要求

- **函数**: `fault_supports_stage2_huge_mapping()`
- **文件**: `arch/arm64/kvm/mmu.c:1328`
- **触发**: memslot 的 IPA 起始地址与 HVA 起始地址的对齐不满足 PMD_SIZE 对齐，
  或 block 映射会超出 memslot 边界
- **原理**: ARM64 的 block mapping 要求 IPA 和 PA 在对应粒度上对齐，不满足时只能用 4K
- **备注**: 使用 hugetlbfs 时，HVA 本身是 2M 对齐的。此场景主要出现在
  memslot IPA 配置不对齐的情况下，属于配置问题。

---

## 四、设备直通 / MMIO

### 9. VFIO 设备直通 / MMIO 映射

- **函数**: `kvm_phys_addr_ioremap()`
- **文件**: `arch/arm64/kvm/mmu.c:1177`
- **触发**: 设备直通时映射设备 MMIO 区域到 guest IPA 空间
- **原理**: 该函数固定以 `PAGE_SIZE` 粒度映射，如果目标 IPA 上已有 PMD block，会被拆分
- **备注**: 这是 MMIO 区域，不是 guest RAM 区域。正常情况下 MMIO 地址段不会与
  hugetlbfs 的 RAM 映射重叠。

---

## 五、嵌套虚拟化（Nested Virtualization）

### 10. 嵌套 guest 的 stage-2 映射粒度限制

- **函数**: `user_mem_abort()` 中 `force_pte = (max_map_size == PAGE_SIZE)`
- **文件**: `arch/arm64/kvm/mmu.c:1752`
- **触发**: L1 guest 运行 L2 guest 时，L2 的 stage-2 翻译使用 4K 粒度
- **原理**: 如果 guest 自身的 stage-2 page table 使用 PAGE_SIZE 粒度，
  则 host 的 shadow stage-2 也必须使用 PAGE_SIZE

---

## 六、pKVM（Protected KVM）特有场景

### 11. pKVM 非默认权限的页面映射

- **函数**: `host_stage2_force_pte_cb()` -> `force_pte_cb` in `kvm_pgtable_stage2_map()`
- **文件**: `arch/arm64/kvm/hyp/nvhe/mem_protect.c:565`, `arch/arm64/kvm/hyp/pgtable.c:1099`
- **触发**: pKVM 模式下，mapping 的权限不是默认的 RWX（memory）或 RW（MMIO）
- **原理**: pKVM 需要精细控制每个页面的权限和所有权，非默认权限不能用 block 映射

### 12. pKVM 页面所有权标注

- **函数**: `kvm_pgtable_stage2_set_owner()`
- **文件**: `arch/arm64/kvm/hyp/pgtable.c:1121`
- **触发**: pKVM 设置页面 ownership annotation
- **原理**: 硬编码 `force_pte = true`，所有权标注必须在 4K 粒度

---

## 七、Guest Memory (gmem / 机密计算)

### 13. guest_memfd 缺页

- **函数**: `gmem_abort()`
- **文件**: `arch/arm64/kvm/mmu.c:1567`
- **触发**: 基于 `guest_memfd` 的机密计算场景下的 guest 缺页
- **原理**: 固定以 `PAGE_SIZE` 映射，不支持大页

---

## 总结

在 hugetlbfs backing 的约束下，各场景的实际影响：

| 类别 | 场景 | 是否会真正拆小 stage2 | 备注 |
|------|------|:---:|------|
| **脏页跟踪** | 主动拆页、增量拆页、写缺页 | **是** | 最常见，热迁移必经之路 |
| **硬件故障** | MCE / memory failure | 可能 | hugetlb 页被 dissolve 时才会 |
| **内存热下线** | memory offline | 临时 unmap | 迁移成功可恢复 2M |
| **Userspace 操作** | QEMU munmap 等 | 罕见 | 正常运行不会发生 |
| **显式迁移** | move_pages/mbind | 临时 unmap | 迁移后可恢复 2M |
| **对齐约束** | IPA/HVA 对齐不满足 | **是** | 属于配置问题 |
| **嵌套虚拟化** | L2 stage-2 粒度限制 | **是** | 使用嵌套虚拟化时 |
| **pKVM** | 权限/所有权精细控制 | **是** | pKVM 场景 |
| **gmem** | guest_memfd 固定 4K | **是** | 机密计算场景 |
| **设备直通** | MMIO 映射 | 不涉及 RAM | MMIO 与 RAM 不重叠 |

**核心结论**: 使用 hugetlbfs 后，host 常规内存管理（回收、KSM、NUMA balancing、
compaction）**完全不会干扰 stage2 大页映射**。最主要的拆页场景仍然是**脏页跟踪
（热迁移）**，其次是嵌套虚拟化、pKVM、机密计算等特定功能场景。

---

## 关键底层函数

所有拆页路径最终都依赖以下核心原语：

- **`stage2_try_break_pte()`** (`pgtable.c:828`): ARM 的 break-before-make 原语，
  原子地将已有 PTE 替换为 `KVM_INVALID_PTE_LOCKED`，执行 TLB 无效化
- **`stage2_map_walk_leaf()`** (`pgtable.c:1029`): 当映射粒度小于已有 block 时，
  分配子页表并替换 block entry 为 table entry
- **`kvm_pgtable_stage2_create_unlinked()`** (`pgtable.c:1406`): 创建离线子页表树，
  用于 eager split 时的原子替换
