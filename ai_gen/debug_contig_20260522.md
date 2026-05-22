KVM Stage-2 Contig Bit Debug 记录 (2026-05-22)
================================================

## 问题概述

调试 KVM Stage-2 contig hugetlb，两个问题：
1. 首次启动 VM 报 `mmu.c:1940` WARN
2. 迁移目的端多 vCPU 时 Guest panic（内核访问空指针），1 vCPU 不触发

## 修复一：CONT_PTE_SHIFT → CONT_PTE_SIZE

### Bug

`fault_supports_stage2_huge_mapping()` 第三参数 `map_size` 期望的是字节大小（如 `PMD_SIZE`、`PUD_SIZE`），但传入的是 shift 值 `CONT_PTE_SHIFT`。

```c
// bug: 传 shift 值
fault_supports_stage2_huge_mapping(memslot, hva, CONT_PTE_SHIFT)

// fix: 传字节大小
fault_supports_stage2_huge_mapping(memslot, hva, CONT_PTE_SIZE)
```

以 64K 基础页为例：CONT_PTE_SHIFT = 20，CONT_PTE_SIZE = 1M。
- buggy: mask = 19 = 0b10011（无意义），range check 用 +20 代替 +1M
- fix: mask = 0xFFFFF（正确 1M 对齐），range check 正确

影响：buggy 版本 `fault_supports_stage2_huge_mapping` 几乎恒返回 true，
对齐和范围检查完全无效，可能在 memslot 边缘创建越界 contig 映射。

### 修复位置

`arch/arm64/kvm/mmu.c:1728`

## 修复二：WARN_ON_ONCE → WARN_ON

补丁中 6 处 debug 用 `WARN_ON_ONCE(1)` 改为 `WARN_ON(1)`，确保每次触发都可见：

| 文件 | 行号 | 说明 |
|------|------|------|
| mmu.c | 1733 | CONT_PTE_SHIFT 分支 else: fault_supports 返回 false |
| mmu.c | 1940 | relax_perms 路径 (fault_is_perm && vma_ps == fault_gr) |
| mmu.c | 1969 | handle_access_fault |
| pgtable.c | 1098 | stage2_map_contig_leaf Break 阶段 LOCKED 检查 |
| pgtable.c | 1424 | stage2_attr_contig_unaligned Break 阶段 LOCKED 检查 |
| pgtable.c | 1471 | stage2_attr_contig_aligned Break 阶段 LOCKED 检查 |

## Line 1940 WARN 分析

Line 1940 位于 `user_mem_abort` 的 relax_perms 路径：

```c
if (fault_is_perm && vma_pagesize == fault_granule) {
    ...
    WARN_ON(1);
    ret = stage2_relax_perms(...);
```

触发条件：权限 fault 且 `vma_pagesize == fault_granule`。

**首次启动时触发**：Guest 首次访问某页（翻译 fault → stage2_map），之后不同权限访问同一页（权限 fault → relax_perms）。路径是正常的。

**迁移时触发**：dirty logging 期间，`force_pte = true` → `vma_shift = PAGE_SHIFT` → `vma_pagesize = PAGE_SIZE = fault_granule` → relax_perms。

注意：迁移时 `force_pte = true` 在 switch 前就设置了 `vma_shift = PAGE_SHIFT`（line 1698-1699），CONT_PTE_SHIFT 分支根本不会走到。

**结论**：Line 1940 是 per-page relax_perms 的正常路径，与 contig 无关。迁移时它本就应该触发。

## 迁移目的端 Guest 数据损坏分析

### 症状
- 迁移目的端多 vCPU：Guest 内核访问空指针（panic）
- 迁移目的端 1 vCPU：正常
- 本地 save/restore：低概率复现
- 不加 contig 补丁：正常

### 排查过程

#### 1. PA（物理地址）计算
- `data->phys` 来自 `__kvm_faultin_pfn` → `__pfn_to_phys(pfn)`，与单页路径相同
- `fault_ipa` 被 `kvm_align_fault_ipa` 对齐到 CONT_PTE_SIZE
- 单 vCPU 首次启动正常 → PA 计算无误
- **排除**

#### 2. TLBI
- wrapper `kvm_tlb_flush_vmid_range()` 内部做 `size >> PAGE_SHIFT` 转换
- 传 CONT_PTE_SIZE（字节）正确转为 CONT_PTES 个 page
- 范围覆盖正确
- **排除**

#### 3. CMO（Cache Maintenance Operations）
- 单页路径 `stage2_map_walker_try_leaf` 有 DC CIVAC + IC IVAU
- contig 路径 `stage2_map_contig_leaf` 确实缺少 CMO
- 但 VHE 路径 `kvm_s2_mm_ops.dcache_clean_inval_poc` 非空，单页路径会执行
- 硬件 cache-coherent 系统上缺 DC CIVAC 不导致读到全零
- **排除**

#### 4. Make 窗口（硬件 CONT bit 一致性）

`stage2_map_contig_leaf` Make 阶段：

```
Step 4: smp_store_release(PTE[1]) = valid + CONT + attrs   ← PTE[1] 可见
        smp_store_release(PTE[2]) = valid + CONT + attrs
        ...
Step 5: smp_store_release(PTE[0]) = valid + CONT + attrs   ← PTE[0] 稍后可见
```

Step 4 和 5 之间，PTE[1] 有 CONT=1 但 PTE[0] 是 LOCKED（BIT0=0，硬件看就是 INVALID）。
如果另一个 vCPU 在 Guest 里做硬件 S2 walk 刚好撞上这个窗口，看到 PTE[1]=CONT=1 但 PTE[0]=INVALID → ARM ARM: CONSTRAINED UNPREDICTABLE。

**但用户确认：该硬件实现不会检查相邻 PTE 的 CONT bit。** 硬件只看 PTE[1] 自身。
CONT=1 相邻 PTE 不一致的 CONSTRAINED UNPREDICTABLE 条件不会触发。
Make 窗口无害。

- **排除**

#### 5. 冗余 BBM

vCPU0 拿到 PTE[0] 锁建 CONT block。其他 vCPU 拿 `-EAGAIN` 回 Guest 重执。
此时 CONT block 已建好，硬件 S2 walk 直接命中，不会再进入 fault handler。
不存在"vCPU1 回来再做一次 BBM"的情况。

- **排除**

### 当前状态

上述所有理论都被排除，静态分析陷入死胡同。已知：
- 多 vCPU 并发 S2 fault 时必然触发（save/restore 可复现）
- 1 vCPU 完全正常
- 软件锁（PTE[0] cmpxchg）互斥正确
- 硬件不检查相邻 PTE CONT bit
- 所有 WARN 都没触发（没走到异常软件分支）

下一步建议：在 `stage2_map_contig_leaf` Make 阶段加 sanity check，
写出 PTE 后立即读回验证 PA 正确性。如果 PA 全对，问题在更后面的环节
（TLB fill、页表被其他操作损坏、或非 contig 特定的并发问题）。

## 2026-05-22 续：发现 idempotency 漏洞

### 重新审查 #5 "冗余 BBM" 的排除论证

#### 论证回顾
"vCPU1 拿 -EAGAIN 回 Guest，CONT block 已建好，硬件 S2 walk 命中，不再进 handler"

#### 反例：vCPU1 已经在 fault handler 中

`kvm_fault_lock` 是 **read_lock**（`arch/arm64/include/asm/kvm_mmu.h:360`）。
多 vCPU 可以并发持有读锁同时在 user_mem_abort 中运行。

考虑时序：
- t0: vCPU0 进 fault handler (read_lock held)
- t0: vCPU1 进 fault handler (read_lock held, 并发)
- t1: vCPU0 走到 stage2_map_contig_leaf, cmpxchg PTE[0] INVALID→LOCKED 成功
- t2: vCPU0 完成 BBM, 写 PTE[0..N-1] = valid+CONT, 释放 read_lock
- t3: vCPU1 走到 stage2_map_contig_leaf, ctx->old (READ_ONCE 在更早) 仍可能为 valid+CONT

注意 ctx->old 是在 `__kvm_pgtable_visit` 入口 READ_ONCE 的，到调用 callback 之间没有重读。
如果 vCPU1 的 READ_ONCE 发生在 vCPU0 完成 BBM 之后：
- vCPU1.ctx->old = valid + CONT

#### `stage2_map_walker_try_leaf` 的漏洞 (pgtable.c:1140-1153)

```c
if (!stage2_leaf_mapping_allowed(ctx, data))
    return -E2BIG;

if (stage2_contig_supported(ctx, data->attr))   // ← 提前 return
    return stage2_map_contig_leaf(ctx, data);

if (!data->annotation)
    new = kvm_init_valid_leaf_pte(phys, data->attr, ctx->level);

if (!stage2_pte_needs_update(ctx->old, new))   // ← 单页路径才有 idempotency 检查
    return -EAGAIN;
```

contig 路径在 `stage2_pte_needs_update` 之前 return，**没有 idempotency 保护**。
相同 (phys, attrs) 的重建也会走完整 BBM。

#### `stage2_map_contig_leaf` 内部 (pgtable.c:1080-1124)

```c
if (stage2_pte_is_locked(ctx->old))           // ctx->old = valid+CONT, 不是 LOCKED → false
    return -EAGAIN;

if (!stage2_try_set_pte(ctx, KVM_INVALID_PTE_LOCKED))  // cmpxchg(valid+CONT, LOCKED) → 成功
    return -EAGAIN;

for (ptep++, i = 1; i < CONT_PTES; i++, ptep++) {
    WARN_ON(stage2_pte_is_locked(*ptep));
    if (kvm_pte_valid(*ptep)) {              // PTE[1..N-1] = valid+CONT
        if (stage2_pte_is_counted(*ptep))
            mm_ops->put_page(ptep);          // ← put N-1 次
        kvm_clear_pte(ptep);                  // ← 直接清零，不走标准 BBM
    }
}

kvm_tlb_flush_vmid_range(mmu, ctx->addr, CONT_PTE_SIZE);

// 重写 PTE[1..N-1] + PTE[0]
for (i = 1; ...) {
    smp_store_release(ptep, new);
    mm_ops->get_page(ptep);                   // ← get N-1 次
}
smp_store_release(PTE[0], new);
mm_ops->get_page(PTE[0]);                     // ← get 1 次
```

#### 后果

1. **Refcount 不对称**：cmpxchg PTE[0] valid→LOCKED 没有 put_page，
   循环 PTE[1..N-1] put_page * (N-1)，最后 get_page * N。
   净增加 page table page 的 refcount = +1。每次冗余 BBM leak 1 个 ref。

2. **Page table 内容短暂破坏**：从 t1 (cmpxchg) 到 t5 (写完 PTE[0]) 之间，
   PTE 状态变化：
   - t1: PTE[0]=LOCKED, PTE[1..N-1]=valid+CONT (vCPU0 的)
   - t2: PTE[0]=LOCKED, PTE[1..N-1]=0           ← 已经全 invalid
   - t3: TLBI
   - t4: PTE[0]=LOCKED, PTE[1..N-1]=valid+CONT (vCPU1 的，phys 应与 vCPU0 一致)
   - t5: PTE[0..N-1]=valid+CONT

3. **关键风险**：在 t2 到 t4 之间，**vCPU0 的 TLB 仍然 valid**（TLBI 还没发），
   vCPU0/Guest 继续访问该 block 的内存能命中 TLB。
   TLBI (t3) 后，其他 vCPU 的 TLB 失效，但 vCPU0 仍可能在执行某些操作。
   如果硬件存在"page table walk during TLB hit"的 prefetch 路径，可能产生异常。

4. **如果 vCPU0 和 vCPU1 的 phys 不一致**：那么 vCPU1 的 BBM 会把
   PTE 改成不同的 phys，Guest 访问会读到错误的内存。但是同样 gfn → 同样 pfn
   （在 mmu_seq 不变时）这种情况应该不会发生。

### 验证步骤

需要确认上述 race 是否真的发生。建议加 sanity check：

```c
// 在 stage2_map_contig_leaf 入口
if (kvm_pte_valid(ctx->old) && (ctx->old & KVM_PTE_LEAF_ATTR_CONT)) {
    /* Idempotency: PTE 已经是 valid+CONT, 检查 phys 是否一致 */
    u64 expected_phys = stage2_map_walker_phys_addr(ctx, data);
    u64 actual_phys = kvm_pte_to_phys(ctx->old);
    if (actual_phys == expected_phys) {
        /* 已经是想要的 mapping, 不需要重做 */
        trace_printk("contig: redundant BBM avoided, phys=%llx\n", actual_phys);
        return -EAGAIN;  // 让 caller 知道 mapping 已存在
    } else {
        WARN(1, "contig: phys mismatch! old=%llx new=%llx\n",
             actual_phys, expected_phys);
        // 这种情况是真正的 bug
    }
}
```

### 修复建议

修复方向是参考单页路径，在 contig 路径加 idempotency check：

```c
static int stage2_map_walker_try_leaf(...)
{
    ...
    if (stage2_contig_supported(ctx, data->attr)) {
        /* 已经是相同的 contig mapping, 跳过 */
        if (kvm_pte_valid(ctx->old) && 
            (ctx->old & KVM_PTE_LEAF_ATTR_CONT) &&
            kvm_pte_to_phys(ctx->old) == stage2_map_walker_phys_addr(ctx, data) &&
            !((ctx->old ^ data->attr) & ~KVM_PTE_LEAF_ATTR_S2_PERMS))
            return -EAGAIN;
        return stage2_map_contig_leaf(ctx, data);
    }
    ...
}
```

但是这个修复**不能完全解释 Guest panic 的根因**，因为：
- 重做 BBM 是 idempotent 的（phys/attrs 都一致）
- 最终 PTE 状态相同
- 只有 refcount leak 和性能问题

panic 的根因可能是别的，需要继续调查。

## 下一步实验性步骤

静态分析陷入瓶颈，需要实际复现来定位。建议三个并行方向：

### 方向 A：先修复 idempotency bug，看是否能 mitigate panic

在 `stage2_map_walker_try_leaf` 中，contig 路径加入 idempotency 检查：

```c
if (stage2_contig_supported(ctx, data->attr)) {
    /* 防御性：已经是相同的 contig mapping 则跳过 */
    if (kvm_pte_valid(ctx->old) &&
        (ctx->old & KVM_PTE_LEAF_ATTR_CONT) &&
        kvm_pte_to_phys(ctx->old) == 
            stage2_map_walker_phys_addr(ctx, data) &&
        !((ctx->old ^ data->attr) & 
          ~(KVM_PTE_LEAF_ATTR_S2_PERMS | KVM_PTE_VALID | KVM_PTE_TYPE)))
        return -EAGAIN;
    return stage2_map_contig_leaf(ctx, data);
}
```

若 panic 消失：race 是根因（具体机制可能比理论分析复杂，比如硬件相关的 TLB 一致性问题）。
若 panic 仍在：根因在别处。

### 方向 B：加 sanity check 与详细 trace，复现时收集信息

在 `stage2_map_contig_leaf` 完成 Make 阶段后，读回所有 PTE 验证：

```c
/* Sanity check: 验证写入的 PTE 内容正确 */
{
    kvm_pte_t *p0 = (kvm_pte_t *)ctx->ptep;
    u64 expected_phys = stage2_map_walker_phys_addr(ctx, data);
    for (i = 0; i < CONT_PTES; i++) {
        kvm_pte_t v = READ_ONCE(p0[i]);
        u64 actual_phys = kvm_pte_to_phys(v);
        u64 exp_i = expected_phys + i * PAGE_SIZE;
        if (!kvm_pte_valid(v) || !(v & KVM_PTE_LEAF_ATTR_CONT) ||
            actual_phys != exp_i) {
            trace_printk("BUG contig[%llu] addr=%llx "
                         "pte=%llx expected_phys=%llx actual_phys=%llx\n",
                         i, ctx->addr + i*PAGE_SIZE,
                         v, exp_i, actual_phys);
            BUG();
        }
    }
}
```

如果触发 BUG()，说明 Make 阶段写入有问题；
如果不触发，说明问题在 Make 之后（比如其他 walker 损坏了 PTE，或者硬件 walker 看到不一致状态）。

### 方向 C：扩展 trace points 捕捉 race 详情

现有的 `trace_kvm_pgtable_visit` / `trace_kvm_stage2_map` 不够细。建议在 contig 关键路径加 trace：

```c
TRACE_EVENT(kvm_stage2_contig_bbm,
    TP_PROTO(u64 addr, kvm_pte_t old, kvm_pte_t new_first, u64 phys),
    ...
);
```

入口处 trace ctx->old 和 ctx->ptep，出口处 trace 写入的新值。复现时通过 ftrace dump 检查并发模式。

### 关键观察

无论根因如何，方向 A 的修复都是必要的：
- 单页路径有 stage2_pte_needs_update idempotency check
- contig 路径漏掉了这个保护
- 即使不导致 panic，也是 refcount leak 与性能问题
