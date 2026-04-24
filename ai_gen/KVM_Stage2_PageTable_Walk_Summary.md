# KVM Stage-2 Page Table Walk 总结

本文档总结 ARM64 KVM 中 stage-2 页表遍历和操作的相关函数。

## 1. kvm_pgtable_stage2_set_owner

**作用**：为 stage-2 页表中的指定内存区域设置 owner（所有者）ID

**函数位置**：`arch/arm64/kvm/hyp/pgtable.c:1121`

### 函数原型

```c
int kvm_pgtable_stage2_set_owner(struct kvm_pgtable *pgt, u64 addr, u64 size,
			 void *mc, u8 owner_id)
```

### 参数说明

- `pgt`: stage-2 页表结构
- `addr`: 起始地址
- `size`: 大小
- `mc`: 内存缓存
- `owner_id`: 所有者 ID（0表示默认 page-table owner）

### 工作原理

1. 创建一个 `stage2_map_data`，设置 `annotation = true` 表示这是标注操作
2. 使用 `force_pte = true` 强制使用 4K page 粒度
3. 遍历地址范围，为每个 PTE 位置写入无效 PTE，但携带 owner_id

```c
// pgtable.c:964-967
if (!data->annotation)
    new = kvm_init_valid_leaf_pte(phys, data->attr, ctx->level);
else
    new = kvm_init_invalid_leaf_owner(data->owner_id);
```

### 用途场景

- **内存所有权跟踪**：当多个 VM 共享同一块物理内存时，标记每块内存属于哪个 VM
- **Refcount 机制**：通过无效 PTE + owner_id 组合，让 refcount 能够跟踪有多少 VM 还在使用这块内存
- **VM 迁移**：标记哪些内存需要复制到目标主机
- **内存共享（KSM）**：标记哪些 pages 被哪些 VM 共享

### 关键数据结构

- `stage2_pte_is_counted()`: 判断 PTE 是否被计数（有效 PTE 或带 owner_id 的无效 PTE）

---

## 2. kvm_pgtable_stage2_flush

**作用**：刷新 CPU 的 data cache，确保数据一致性

**函数位置**：`arch/arm64/kvm/hyp/pgtable.c:1392`

### 函数原型

```c
int kvm_pgtable_stage2_flush(struct kvm_pgtable *pgt, u64 addr, u64 size)
```

### 工作原理

1. 遍历指定地址范围的所有 leaf PTE
2. 对每个可 cache 的 PTE（`stage2_pte_cacheable()`），执行：
   ```c
   mm_ops->dcache_clean_inval_poc(address, size);
   ```

### 操作说明

- **Clean**: 把 CPU cache 里的数据写回到 RAM
- **Invalidate**: 把 cache line 标记为无效，强制后续访问从 RAM 读取

### 调用条件

```c
// pgtable.c:1400-1401
if (cpus_have_final_cap(ARM64_HAS_STAGE2_FWB))
    return 0;  // 如果硬件支持 FWB，则不需要软件 flush
```

只有当系统没有 Hardware Fortran Write Back 支持时才需要软件 flush。

### 用途场景

- **VM 迁移**：源端把 dirty 数据 flush 到 RAM，以便复制到目标主机
- **共享内存**：确保其他 CPU 能看到最新数据
- **DMA 操作**：确保 DMA 硬件能访问到最新数据

---

## 3. kvm_pgtable_stage2_create_unlinked

**作用**：创建一个独立的、还未挂载到页表树上的子页表

**函数位置**：`arch/arm64/kvm/hyp/pgtable.c:1406`

### 函数原型

```c
kvm_pte_t *kvm_pgtable_stage2_create_unlinked(struct kvm_pgtable *pgt,
					      u64 phys, s8 level,
					      enum kvm_pgtable_prot prot,
					      void *mc, bool force_pte)
```

### 参数说明

- `pgt`: stage-2 页表
- `phys`: 物理地址
- `level`: 页表级别
- `prot`: 保护属性
- `mc`: 内存缓存
- `force_pte`: 是否强制使用 PTE 粒度

### 工作原理

1. 分配一个新的页表页面
2. 在这个页表上"遍历"一个虚拟地址范围（`0 ~ granule_size(level)`）
3. 为这个虚拟范围创建完整的页表项（可以是 block 或 page）
4. **返回这个新创建的页表，但不链接到主页表树**

```c
// pgtable.c:1445-1456
pgtable = mm_ops->zalloc_page(mc);      // 分配空页表
ret = __kvm_pgtable_walk(&data, mm_ops, (kvm_pteref_t)pgtable, level + 1);
// 在空页表上"走"一次，建立完整的页表项
return pgtable;  // 返回但不链接
```

### 为什么叫 "unlinked"

这个子页表已经包含了完整的映射信息，但 PTE 值还没有写入到主页表树中。需要后续手动调用 `stage2_make_pte()` 把指向这个子页表的 table PTE 写入主页表，完成"链接"。

### 使用场景

**主要在 `stage2_split_walker` 中使用**，用于把大页拆分成小页：

```c
// pgtable.c:1528-1544
childp = kvm_pgtable_stage2_create_unlinked(...);  // 1. 创建子页表
// ...
new = kvm_init_table_pte(childp, mm_ops);        // 2. 创建指向子页表的 PTE
stage2_make_pte(ctx, new);                    // 3. 写入主页表（链接）
```

---

## 4. stage2_split_walker 和调用链

### stage2_split_walker 函数

**作用**：将大页（block mapping）拆分成小页（4K page）

**函数位置**：`arch/arm64/kvm/hyp/pgtable.c:1480`

### 工作流程

对于遍历到的每个 block PTE（64K/16M/32M 等）：

1. **检查是否需要拆分**：只有有效的 block mapping 才需要拆分
2. **分配子页表**：调用 `kvm_pgtable_stage2_create_unlinked()` 创建 4K 页表
3. **Break-before-make**：调用 `stage2_try_break_pte()` 破坏原 PTE
4. **链接新页表**：调用 `stage2_make_pte()` 写入 table PTE

```c
// pgtable.c:1480-1546
static int stage2_split_walker(...) {
    // 1. 检查
    if (level == KVM_PGTABLE_LAST_LEVEL) return 0;
    if (!kvm_pte_valid(pte)) return 0;

    // 2. 分配子页表
    childp = kvm_pgtable_stage2_create_unlinked(mmu->pgt, phys, level, prot, mc, force_pte);

    // 3. Break-before-make
    if (!stage2_try_break_pte(ctx, mmu)) return -EAGAIN;

    // 4. 链接
    new = kvm_init_table_pte(childp, mm_ops);
    stage2_make_pte(ctx, new);
    return 0;
}
```

### 调用链汇总

#### 场景1：启用 dirty logging 时

```
用户空间 (QEMU/Libvirt)
    │
    ▼
ioctl(KVM_GET_DIRTY_LOG, &dirty_log)
    │
    ▼
kvm_get_dirty_log()                    // virt/kvm/kvm_main.c
    │
    ▼
kvm_get_dirty_log_protect()
    │
    ├─► 扫描 dirty bitmap
    │
    ▼
kvm_arch_mmu_enable_log_dirty_pt_masked()  // arch/arm64/kvm/mmu.c:1297
    │
    ├─► kvm_dirty_log_manual_protect_and_init_set(kvm) 检查 manual protect
    │
    ▼
kvm_mmu_split_huge_pages(kvm, start, end)    // mmu.c:120
    │
    ▼
kvm_pgtable_stage2_split(pgt, addr, size, cache)   // pgtable.c:1548
    │
    ▼
stage2_split_walker()                     // pgtable.c:1480
    │
    ├─► kvm_pgtable_stage2_create_unlinked()  // pgtable.c:1406
    │     └─► 创建子页表（4K小页的页表）
    │
    └─► stage2_try_break_pte() + stage2_make_pte()
          └─► 把原 block PTE 替换成 table PTE（链接到子页表）
```

#### 场景2：创建 memory slot 时

```
用户空间 (QEMU/Libvirt)
    │
    ▼
ioctl(KVM_CREATE_USER_MEMORY_REGION)
    │
    ▼
kvm_create_memslot()
    │
    ▼
kvm_mmu_create_memslot()              // arch/arm64/kvm/mmu.c
    │
    ├─► 检查是否需要 eager splitting
    │
    ▼
kvm_mmu_split_huge_pages(kvm, start, end)
    │
    ▼
...后续同上...
```

#### 场景3：Protected VM (pkvm)

```
pkvm_host_init()
    │
    ▼
pkvm_pgtable_stage2_split()          // pkvm.c:482
    │
    ▼
stage2_split_walker()
```

### 调用流程图

```
+---------------------------+
|  用户触发 (ioctl/创建slot)  |
+---------------------------+
              │
              ▼
+---------------------------+
|   kvm_mmu_split_huge_pages |
|     (mmu.c:120)        |
+---------------------------+
              │
              ▼
+---------------------------+
|  kvm_pgtable_stage2_split |
|     (pgtable.c:1548)   |
+---------------------------+
              │
              ▼
+---------------------------+
|   stage2_split_walker    |
|    (pgtable.c:1480)   |
+---------------------------+
    │                    │
    │ 对于每个 block PTE:
    │    │
    │    ├─► 创建子页表 (4K)
    │    └─► 替换原来的 block
    │
    ▼
+---------------------------+
|    BLOCK → TABLE 拆分完成  |
|   64K → 16x4K pages     |
+---------------------------+
```

---

## 完整函数调用关系图

```
kvm_pgtable_walk()                      // pgtable.c:268
    │
    ├─► _kvm_pgtable_walk()            // pgtable.c:245
    │     │
    │     └─► __kvm_pgtable_walk()    // pgtable.c:221
    │           │
    │           └─► __kvm_pgtable_visit()  // pgtable.c:155
    │                 │
    │                 ├─► walker->cb(..., KVM_PGTABLE_WALK_TABLE_PRE)
    │                 ├─► walker->cb(..., KVM_PGTABLE_WALK_LEAF)
    │                 └─► walker->cb(..., KVM_PGTABLE_WALK_TABLE_POST)
    │
    ├─► hyp_map_walker()              // 映射 (stage-1)
    │     └─► hyp_map_walker_try_leaf()
    │
    ├─► stage2_map_walker()         // 映射 (stage-2)
    │     ├─► stage2_map_walk_table_pre()
    │     ├─► stage2_map_walk_leaf()
    │     └─► create_unlinked 子页表
    │
    ├─► stage2_unmap_walker()        // 取消映射
    │
    ├─► stage2_attr_walker()       // 属性修改 (wrprotect/relax_perms)
    │
    ├─► stage2_age_walker()        // 年龄操作
    │
    ├─► stage2_split_walker()      // 大页拆分
    │     └─► kvm_pgtable_stage2_create_unlinked()
    │
    ├─► stage2_flush_walker()      // Cache flush
    │
    └─► stage2_free_walker()      // 释放页表
```

---

## 总结

| 函数 | 作用 | 调用场景 |
|------|------|----------|
| `kvm_pgtable_stage2_set_owner` | 设置内存区域的 owner ID | 内存共享、迁移、所有权跟踪 |
| `kvm_pgtable_stage2_flush` | 刷新 CPU cache | VM迁移、共享内存、DMA |
| `kvm_pgtable_stage2_create_unlinked` | 创建未链接的子页表 | 大页拆分、内部使用 |
| `stage2_split_walker` | 把大页拆成4K小页 | 启用 dirty logging、创建 slot、pkvm |
| `kvm_pgtable_stage2_split` | 拆分大页的入口函数 | 被上层调用拆分大页 |

---

*生成时间: 2024*
*文件位置: /home/wz/linux/arch/arm64/kvm/hyp/pgtable.c*
