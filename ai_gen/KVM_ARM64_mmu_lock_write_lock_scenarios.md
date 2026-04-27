# KVM ARM64 mmu_lock 写锁场景分析（非 pKVM）

## 概述

在非 pKVM 场景下，`user_mem_abort`（guest 缺页处理）使用读锁，但有一些特殊场景需要写锁。本文档分析这些写锁场景。

## mmu_lock 的类型

ARM64 KVM 使用读写锁（rwlock）：

```c
// arch/arm64/include/asm/kvm_host.h
#define KVM_HAVE_MMU_RWLOCK

// virt/kvm/kvm_mm.h
#ifdef KVM_HAVE_MMU_RWLOCK
#define KVM_MMU_LOCK_INIT(kvm)   rwlock_init(&(kvm)->mmu_lock)
#define KVM_MMU_LOCK(kvm)        write_lock(&(kvm)->mmu_lock)
#define KVM_MMU_UNLOCK(kvm)      write_unlock(&(kvm)->mmu_lock)
#endif
```

## 读锁 vs 写锁的保护范围

### 读锁（`user_mem_abort`）

- 使用 `KVM_PGTABLE_WALK_SHARED` 标志
- 多 vCPU 可并发处理 fault
- 使用 `cmpxchg` 处理 PTE 并发修改
- 配合 `mmu_invalidate_retry` 检测页面失效

### 写锁（其他操作）

- 没有 `KVM_PGTABLE_WALK_SHARED` 标志
- 串行化执行
- 直接写 PTE，不需要 `cmpxchg`
- 保证页表修改的独占性

## 非 pKVM 写锁场景详解

### 1. `kvm_phys_addr_ioremap` - 设备 MMIO 映射

```c
int kvm_phys_addr_ioremap(struct kvm *kvm, phys_addr_t guest_ipa,
                          phys_addr_t pa, unsigned long size, bool writable)
{
    // ...
    for (addr = guest_ipa; addr < guest_ipa + size; addr += PAGE_SIZE) {
        write_lock(&kvm->mmu_lock);
        ret = kvm_pgtable_stage2_map(pgt, addr, PAGE_SIZE, pa, prot, &cache, 0);
        write_unlock(&kvm->mmu_lock);
        // ...
    }
}
```

**触发场景**：
- 用户空间通过 ioctl 将设备 MMIO 区域映射到 guest IPA
- 例如：VFIO 设备 passthrough 前的内存映射

**为什么需要写锁**：
- `flags = 0`，没有 `KVM_PGTABLE_WALK_SHARED` 标志
- 这是用户主动调用的 ioctl，不是 fault 处理
- 使用写锁独占访问，代码路径更简单

### 2. `kvm_mmu_split_huge_pages` - 大页拆分

```c
static int kvm_mmu_split_huge_pages(struct kvm *kvm, phys_addr_t addr, phys_addr_t end)
{
    lockdep_assert_held_write(&kvm->mmu_lock);

    do {
        if (need_split_memcache_topup_or_resched(kvm)) {
            write_unlock(&kvm->mmu_lock);
            cond_resched();
            __kvm_mmu_topup_memory_cache(cache, ...);
            write_lock(&kvm->mmu_lock);
        }
        ret = kvm_pgtable_stage2_split(pgt, addr, next - addr, cache);
    } while (addr < end);
}
```

**触发场景**：
- Dirty logging 开启时，需要将大页拆分为 4K 页
- 通过 `kvm_mmu_split_memory_region()` 调用

**为什么需要写锁**：
- 需要修改页表结构（block entry → table entry）
- 涉及分配新页表页、修改多个 PTE
- 操作复杂，不适合并发执行

### 3. `kvm_stage2_wp_range` - 写保护

```c
void kvm_mmu_slot_remove_write_access(struct kvm *kvm, const struct kvm_memory_slot *memslot)
{
    // ...
    write_lock(&kvm->mmu_lock);
    kvm_stage2_wp_range(&kvm->arch.mmu, start, end);
    kvm_nested_s2_wp(kvm);
    write_unlock(&kvm->mmu_lock);
    kvm_flush_remote_tlbs_memslot(kvm, memslot);
}
```

**触发场景**：
- 开启 dirty logging 时，对 memslot 进行写保护
- Guest 写入时会触发 fault，记录脏页

**为什么需要写锁**：
- 需要修改 PTE 权限位（清除写权限）
- 可能涉及多个页的批量修改
- 需要与 TLB 刷新操作同步

### 4. `stage2_unmap_vm` - 刷新整个 VM 的页表

```c
void stage2_unmap_vm(struct kvm *kvm)
{
    // ...
    write_lock(&kvm->mmu_lock);

    slots = kvm_memslots(kvm);
    kvm_for_each_memslot(memslot, bkt, slots)
        stage2_unmap_memslot(kvm, memslot);

    kvm_nested_s2_unmap(kvm, true);

    write_unlock(&kvm->mmu_lock);
}
```

**触发场景**：
- VM 重置或重新启动
- KVM_VM_RESET 等 ioctl

**为什么需要写锁**：
- 大规模 unmap 操作
- 需要保证操作的原子性
- 防止期间有新的映射建立

### 5. `kvm_arch_flush_shadow_memslot` - 刷新单个 memslot

```c
void kvm_arch_flush_shadow_memslot(struct kvm *kvm, struct kvm_memory_slot *slot)
{
    gpa_t gpa = slot->base_gfn << PAGE_SHIFT;
    phys_addr_t size = slot->npages << PAGE_SIZE;

    write_lock(&kvm->mmu_lock);
    kvm_stage2_unmap_range(&kvm->arch.mmu, gpa, size, true);
    kvm_nested_s2_unmap(kvm, true);
    write_unlock(&kvm->mmu_lock);
}
```

**触发场景**：
- Memslot 删除或修改
- 内存区域大小变化

**为什么需要写锁**：
- 需要完全清空指定范围的映射
- 操作期间不能有新的映射建立

### 6. `kvm_free_stage2_pgd` - 销毁 S2 页表

```c
void kvm_free_stage2_pgd(struct kvm_s2_mmu *mmu)
{
    struct kvm *kvm = kvm_s2_mmu_to_kvm(mmu);
    struct kvm_pgtable *pgt = NULL;

    write_lock(&kvm->mmu_lock);
    pgt = mmu->pgt;
    if (pgt) {
        mmu->pgd_phys = 0;
        mmu->pgt = NULL;
        free_percpu(mmu->last_vcpu_ran);
    }
    write_unlock(&kvm->mmu_lock);

    if (pgt) {
        kvm_stage2_destroy(pgt);
        kfree(pgt);
    }
}
```

**触发场景**：
- VM 销毁
- Nested VM 退出

**为什么需要写锁**：
- 需要原子地清除页表指针
- 防止其他线程在清除后继续使用页表

## 写锁场景总结表

| 场景 | 触发源 | 操作类型 | 为什么需要写锁 |
|------|--------|----------|----------------|
| `kvm_phys_addr_ioremap` | 用户 ioctl | 建立 MMIO 映射 | 独占操作，无 SHARED 标志 |
| `kvm_mmu_split_huge_pages` | Dirty logging | 大页拆分 | 修改页表结构 |
| `kvm_stage2_wp_range` | Dirty logging | 写保护 | 批量修改 PTE 权限 |
| `stage2_unmap_vm` | VM reset | 全局 unmap | 大规模清空映射 |
| `kvm_arch_flush_shadow_memslot` | Memslot 操作 | 范围 unmap | 清空指定范围 |
| `kvm_free_stage2_pgd` | VM 销毁 | 销毁页表 | 原子清除页表指针 |

## 读锁 vs 写锁对比

```
┌─────────────────────────────────────────────────────────────────┐
│                    user_mem_abort (读锁)                         │
├─────────────────────────────────────────────────────────────────┤
│  触发源：Guest 缺页异常                                          │
│  标志：KVM_PGTABLE_WALK_SHARED                                  │
│  并发：多 vCPU 可并发处理                                        │
│  PTE 更新：cmpxchg + KVM_INVALID_PTE_LOCKED                     │
│  性能：优先（并发执行）                                          │
│  保护：mmu_invalidate_retry 与 stage2_map 的原子性              │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    其他操作 (写锁)                               │
├─────────────────────────────────────────────────────────────────┤
│  触发源：用户 ioctl、VM 管理、Dirty logging                      │
│  标志：无 KVM_PGTABLE_WALK_SHARED                               │
│  并发：串行化执行                                               │
│  PTE 更新：直接 WRITE_ONCE                                      │
│  性能：较低（串行）                                              │
│  保护：页表结构的完整性和一致性                                  │
└─────────────────────────────────────────────────────────────────┘
```

## 关键代码路径

### 写锁路径的 PTE 更新

```c
// arch/arm64/kvm/hyp/pgtable.c
static bool stage2_try_set_pte(const struct kvm_pgtable_visit_ctx *ctx, kvm_pte_t new)
{
    if (!kvm_pgtable_walk_shared(ctx)) {
        // 写锁路径：直接写，调用者已持有写锁
        WRITE_ONCE(*ctx->ptep, new);
        return true;
    }

    // 读锁路径：使用 cmpxchg
    return cmpxchg(ctx->ptep, ctx->old, new) == ctx->old;
}
```

### 写锁路径的 break-before-make

```c
static bool stage2_try_break_pte(const struct kvm_pgtable_visit_ctx *ctx,
                                 struct kvm_s2_mmu *mmu)
{
    // ...
    if (!stage2_try_set_pte(ctx, KVM_INVALID_PTE_LOCKED))
        return false;

    // TLB invalidation...

    return true;
}
```

即使使用写锁，仍然需要 break-before-make 流程来满足 ARM 架构要求，但不需要 `cmpxchg` 竞争处理。

## 结论

非 pKVM 场景下，写锁主要用于：

1. **用户主动触发的操作**（ioctl）：如 `kvm_phys_addr_ioremap`
2. **页表结构修改**：如大页拆分、页表销毁
3. **批量权限修改**：如 dirty logging 的写保护
4. **大规模 unmap**：如 memslot 删除、VM reset

这些操作都需要对页表进行独占访问，不适合并发执行。而 guest fault 处理是高频操作，使用读锁允许并发以提高性能，通过 `cmpxchg` 机制处理 PTE 并发修改。
