# arm64 KVM Stage2页表映射流程分析

-v0.1 2026.05.08  Sherlock init
-v0.2 2026.05.10 Sherlock init

简介：分析下ARM64 KVM stage2页表page table walk的逻辑。

## 基本逻辑

Stage2页表使用一个通用walker框架+回调机制，通过kvm_pgtable_walk()递归遍历每一级
页表，在不同的访问点调用回调函数完成映射。kvm_pgtable_stage2_map是入口，它复用
stage2_map_walker作为回调。

我们这里重点分析页表映射的流程，其中核心就是使用page table walker，一定要注意哪里
是框架逻辑，哪里是stage2页表map的具体业务逻辑。ARM KVM里还有很多使用walker的业务
逻辑，比如，stage2页表unmap、改页表属性、配置页表young属性、stage2 flush、stage2 split、
stage2 destroy range，dump stage页表等，所有这些都是对给定IPA/size操作对应stage2
页表的行为。

## 关键数据结构

```c
// 虚机stage2 page table的全局参数。
struct kvm_pgtable {
    u32   ia_bits;       // IPA地址宽度
    s8    start_level;   // 起始级数
    kvm_pteref_t pgd;    // 指向PGD页
    struct kvm_pgtable_mm_ops *mm_ops;  // 物理/虚拟地址转换、页表内存分配/释放回调等
    enum kvm_pgtable_stage2_flags flags;
    kvm_pgtable_force_pte_cb_t force_pte_cb;
    struct kvm_s2_mmu *mmu;
};

/*
 * walker框架的核心数据结构，注意，cb/arg是针对具体walker业务的回调函数和回调函数参数。
 * 比如，map的walker和split的walker，使用同一个walker框架，但是处理的业务不一样。
 */
struct kvm_pgtable_walker {
    const kvm_pgtable_visitor_fn_t cb;
    void * const                   arg;
    const enum kvm_pgtable_walk_flags flags;
};

// walker框架，visit这一层的核心数据结构。
struct kvm_pgtable_visit_ctx {
    kvm_pte_t *ptep;   // 当前PTE指针
    kvm_pte_t old;     // 当前PTE旧值
    void      *arg;    // walker->arg
    struct kvm_pgtable_mm_ops *mm_ops;
    u64 start, addr, end;  // 本次映射的起止地址、当前walk到的地址
    s8  level;             // 当前页表层数
    enum kvm_pgtable_walk_flags flags;
};

// 这个是stage2 map walker的私有参数。注意，这个不是框架的一部分。
struct stage2_map_data {
    const u64 phys;     // 起始物理地址
    kvm_pte_t attr;     // 预计算的 PTE 属性
    u8  owner_id;
    struct kvm_s2_mmu *mmu;
    void *memcache;     // 页表页分配缓存
    bool force_pte;     // 强制页级映射(禁止 block)
    bool annotation;    // 仅更新 owner_id
};
```

### 页表级数与block支持

页表的输入决定页表的级数，stage1上是VA，stage2上就是IPA。IPA是虚机的物理地址，所以
stage2上就是虚机物理地址位数决定S2页表级数。

例如，对于一个4KB基础页，48bit的IPA，页表结构大概如下：
```
   63    48 47    39 38    30 29    21 20    12 11     0
  ┌────────┬────────┬────────┬────────┬────────┬─────────┐
  │ IGNORE │  L0[9] │  L1[9] │  L2[9] │  L3[9] │  OFF[12]│
  └────────┴───┬────┴───┬────┴───┬────┴───┬────┴───┬─────┘
               │        │        │        │        │
   TTBR ──►   PGD ───► PUD ───► PMD ───► PTE       │
               │        │        │        │        │
               └────────┴────────┴────────┴────────┘
                                                   │
                                                   ▼
                                                PA[47:0]
```
如图，它是一个4级页表，每一级页表项的索引来自对应的VA/IPA域段。ARM spec上对于一个
页表项，有三个概念page/block/table，page是指叶子节点，比如这里的PTE就是一个page，
block是指中间的页表项，但是block已经没有再下一级，所以block就是我们一般说的传统
大页(这里不包括contig hugetlb)，table是中间的页表项，但是它还有下一级页表项。

### PTE属性位(stage-2)

| 位域  | 宏  | 含义 |
|-------|-----|------|
| bit[0] | `KVM_PTE_VALID` | PTE有效位 |
| bit[1] | `KVM_PTE_TYPE` | 0=BLOCK, 1=PAGE/TABLE |
| bit[5:2] | `KVM_PTE_LEAF_ATTR_LO_S2_MEMATTR` | 内存属性 (Device/NC/Normal) |
| bit[6] | `KVM_PTE_LEAF_ATTR_LO_S2_S2AP_R` | 读权限 |
| bit[7] | `KVM_PTE_LEAF_ATTR_LO_S2_S2AP_W` | 写权限 |
| bit[9:8] | `KVM_PTE_LEAF_ATTR_LO_S2_SH` | 可共享性 |
| bit[10] | `KVM_PTE_LEAF_ATTR_LO_S2_AF` | Access Flag |
| bit[52] | `KVM_PTE_LEAF_ATTR_CONT` | 连续 PTE 提示 |
| bit[54:53] | `KVM_PTE_LEAF_ATTR_HI_S2_XN` | 执行权限 |
| bit[58:55] | `KVM_PTE_LEAF_ATTR_HI_SW` | 软件位(保存prot信息) |
| bit[10] | `KVM_INVALID_PTE_LOCKED` | BBM 锁标记(仅在valid=0时有效) |

## 完整调用链分析

以stage2缺页处理流程分析下stage2 page table walk的逻辑。user_mem_abort的结尾进行
stage2 map的建立，这个时候已经有IPA、PA、size，这里的逻辑只是建立对应的页表。
```c
// pgt来自vcpu->arch.hw_mmu->pgt，一路传递下去，S2页表相关的内存管理回调函数
kvm_pgtable_stage2_map(struct kvm_pgtable *pgt, ...)
        /*
         * struct kvm_pgtable_walker
         *    +-> cb  = stage2_map_walker  <-- 实际pgtable walk时的回调，不同功能，回调不同
         *    +-> arg = struct stage2_map_data  <-- 物理地址
         *    ...
         */
    +-> kvm_pgtable_walk(pgt, addr, size, &walker)
            /*
             * 转换下数据结构，把walker封装到kvm_pgtable_walk_data里。同时处理L0
             * 页表是多页的情况。一般的，比如4K 48bit IPA，L0一个页，这个逻辑并
             * 没有发生作用。
             */
        +-> _kvm_pgtable_walk(pgt, &walk_data)
                /*
                 * 这里是开始walk的核心入口，语义是从L0页表开始walk，pteref是
                 * PGD页表项所在页的指针, start_level是0。一般，可以认为这里是
                 * walk的起点。
                 */
            +-> __kvm_pgtable_walk(data, pgt->mm_ops, pteref, pgt->start_level)
```

分析walk核心函数__kvm_pgtable_walk。
```c
/*
 * 这个函数会被递归调用，所以它的语义是，给定IPA/size/当前walk页表所在page的基地址，
 * 创建页表映射。
 */
__kvm_pgtable_walk
        // 从IPA的L0域段计算出具体PGD页表项的位置
    +-> for (idx = kvm_pgtable_idx(data, level); idx < PTRS_PER_PTE; ++idx)
            kvm_pteref_t pteref = &pgtable[idx];
            /*
             * 注意，输入的IPA和size，walk中会更新下次map的新IPA，如果size很大，
             * 会在这个循环里多次调用visit函数。
             */
            if (data->addr >= data->end)
                    break;

            /*
             * 注意，这里给的是一个页表项，已经找到IPA在这一级页表对应的页表项。
             * visit这个函数的核心作用是处理当前这个页表项。
             */
            __kvm_pgtable_visit(data, mm_ops, pteref, level);
                    /*
                     * 这个页表项是table，检测给的参数是否可以在这一级直接按block做map，
                     * 如果可以，就按block做map。
                     *
                     * 不管是否可以按block map，下面都会把这个pte读出来做处理。
                     */
                +-> ret = kvm_pgtable_visitor_cb(data, &ctx, KVM_PGTABLE_WALK_TABLE_PRE)
                        ...
                    +-> stage2_map_walk_table_pre
                        +-> stage2_leaf_mapping_allowed
                        +-> stage2_map_walker_try_leaf

                    /*
                     * 这个页表项是block、page或者是空的。注意，不管直接page map
                     * 还是创建table，下面都会把这个pte重新load出来做处理。
                +-> ret = kvm_pgtable_visitor_cb(data, &ctx, KVM_PGTABLE_WALK_LEAF)
                        ...
                    +-> stage2_map_walk_leaf
                            // 如果可以做page映射，就在这里做，做完walk_leaf结束了。
                        +-> stage2_map_walker_try_leaf
                            /* 
                             * 如果上面做不了page map，可以走到这里说明也不是table，
                             * 那就是当前这一级页表太大了，需要继续在下一级页表里
                             * 做映射。所以，这里分配下一级页表的内存，更新当前页表项
                             * 指向下一级页表。
                             *
                             * 这里其实是创建一个table。
                             */
                        +-> childp = mm_ops->zalloc_page(data->memcache)
                            stage2_try_break_pte(ctx, data->mmu)
                            new = kvm_init_table_pte(childp, mm_ops)
                            stage2_make_pte(ctx, new)
                            
                +-> ctx.old = READ_ONCE(*ptep)
                    table = kvm_pte_table(ctx.old, level)
                    
                    // 根据之前的ret值，决定是否需要继续walk。这似乎有点bug。
                +-> if (!kvm_pgtable_walk_continue(data->walker, ret))
                        goto out;

                    /*
                     * 不是table，说明上面做了page或block map。不需要继续walk，
                     * 但是, size可能比较大，可以在同级页表继续visit。
                     */
                +-> if (!table) {
                             data->addr = ALIGN_DOWN(data->addr, kvm_granule_size(level));
                             data->addr += kvm_granule_size(level);
                             goto out;
                     }

                    // 得到下一级页表所在页的基地址。
                +-> childp = (kvm_pteref_t)kvm_pte_follow(ctx.old, mm_ops)

                    // 进入下一级页表walk。
                +-> ret = __kvm_pgtable_walk(data, mm_ops, childp, level + 1)

                +-> if (!kvm_pgtable_walk_continue(data->walker, ret))
                             goto out;

                +-> kvm_pgtable_visitor_cb(data, &ctx, KVM_PGTABLE_WALK_TABLE_POST)
```

### Break-Before-Make机制

ARM架构要求修改PTE映射时遵守BBM序列。也就是改pte的顺序应该是：
锁页表-> invalid页表 -> TLBI -> 更新页表 -> 解锁页表。上面stage2_map_walker_try_leaf
以及stage2_map_walk_leaf涉及PTE修改的地方都需要遵守这个流程，下面具体看下：
```
// 原子写入KVM_INVALID_PTE_LOCKED(BIT(10)置1)替换旧PTE，实际上是一起做了前两步。
stage2_try_set_pte(ctx, KVM_INVALID_PTE_LOCKED)

// 有些场景是可以跳过BBM的。
if (!kvm_pgtable_walk_skip_bbm_tlbi(ctx))
    // 如有修改的是一个table，那么这个table覆盖的IPA都要做TLBI。
    if (kvm_pte_table(ctx->old, ctx->level))
            kvm_tlb_flush_vmid_range(mmu, addr, size);
    // 如果修改的是page/block，只有对应的page/block做TLBI就好。
    else if (kvm_pte_valid(ctx->old))
            kvm_call_hyp(__kvm_tlb_flush_vmid_ipa, mmu, ctx->addr, ctx->level); 

// 释放page的引用计数。
put_page()

// 构建新页表项。
new = kvm_init_table_pte(childp, mm_ops)
// 实际上一起做了后面两步。
stage2_make_pte(ctx, new)
```
