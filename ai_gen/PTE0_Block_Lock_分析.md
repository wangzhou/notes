# PTE[0]-as-Block-Lock 并发正确性分析

本文分析 `stage2_map_walker_try_leaf` 中单页路径通过 PTE[0] 加锁的并发正确性，
按 PTE[0] 的可能状态分类讨论所有竞态场景。

## 背景

### 关键变量

- `ctx->old`：walker 在调用 callback **之前**通过 `READ_ONCE(*ctx->ptep)` 读到的值，
  可能与当前 PTE 实际值不同（TOCTOU）
- `pte0`：callback 内**此刻** `READ_ONCE(*first_ptep)` 读到的值
- `first_ptep`：`PTR_ALIGN_DOWN(ctx->ptep, sizeof(kvm_pte_t) * CONT_PTES)`
- `locked_pte0`：本线程是否成功 cmpxchg PTE[0] 为 LOCKED

### 线程命名约定

所有竞态分析使用以下命名：

- **T2**：本线程，即正在执行 `stage2_map_walker_try_leaf` 单页路径的线程（被分析的代码）
- **T1**：并发竞争者，可能是做 contig BBM 的线程、另一个做单页操作的线程等
- **T3**：第三个并发线程，仅在需要三个线程的竞态场景出现

### 关键函数行为

- `stage2_try_break_pte(ctx, mmu)`：
  1. 检查 ctx->old 不是 LOCKED
  2. `cmpxchg(ctx->ptep, ctx->old, LOCKED)`——依赖 ctx->old 匹配当前值
  3. 若 old 是 valid：TLBI + put_page
- `stage2_make_pte(ctx, new)`：
  1. `WARN_ON(!stage2_pte_is_locked(*ctx->ptep))`
  2. `smp_store_release(ctx->ptep, new)`
- `stage2_contig_supported(ctx, attr)`：检查 `attr & PROT_CONT` 且 level == LAST_LEVEL

### 前提

进入 PTE[0] 检查代码块（line 1188）意味着：

1. `stage2_contig_supported()` 已返回 false（否则前面已跳转 `stage2_map_contig_leaf`）
2. `stage2_pte_needs_update()` 已返回 true（不是重复映射）
3. 不是纯软件位修改快速路径
4. `kvm_pgtable_walk_shared(ctx)` 为 true（非 SHARED 路径不进入此块）

---

## 状态 1：PTE[0] = LOCKED

```
if (stage2_pte_is_locked(pte0))
    return -EAGAIN;
```

### 谁设置了 LOCKED？

| 设置者 | 场景 |
|--------|------|
| `stage2_map_contig_leaf` | contig BBM 持有 PTE[0] |
| `stage2_attr_contig_aligned` | attr contig BBM 持有 PTE[0] |
| `stage2_attr_contig_unaligned` | attr unfold BBM 持有 PTE[0] |
| 本函数（另一线程，PTE[0] 自身） | 单页 BBM 在 PTE[0] 上（子情况 4a） |
| 本函数（另一线程，PTE[k]） | 单页 BBM 在 PTE[k] 上，用 PTE[0] 做 block 锁（子情况 4b） |

### 分析

无论哪种情况，PTE[0]=LOCKED 表示有线程正在操作该 contig block 候选区域。
退让后 walker 重试，届时 PTE[0] 要么已释放为 0，要么已成为 valid 映射。

**ctx->ptep 位置无关**——LOCKED 时一律退让。

**正确性**：✓ 无问题。

---

## 状态 2：PTE[0] = Valid + CONT 位

```
if (pte0 & KVM_PTE_LEAF_ATTR_CONT)
    return -EAGAIN;
```

### 为什么会进入此分支？

前提是 `stage2_contig_supported()` 已返回 false，即当前 fault 不带 PROT_CONT。
但 PTE[0] 却有 CONT 位——说明存在一个完整的 contig block。

**如果没有此检查，单页路径会修改 contig block 内的一个 PTE，破坏 CONT 一致性**
（`contig block 内 N 个 PTE 的属性必须完全一致` 是硬件约束）。

### 核心问题：T2 自己走不出来

T2 返回 -EAGAIN 后，walker 重试。但 `data->attr` 来自 `user_mem_abort` 的 `prot`，
重试不会变——上轮没有 PROT_CONT，重试还是没有。所以：

```
T2: pte0 = valid+CONT → -EAGAIN → retry
T2: pte0 = valid+CONT → -EAGAIN → retry
...（T2 自己永远解不开）
```

**解除状态 2 依赖另一个线程通过其他路径修改 PTE[0]**（attr 路径 unfold，或 unmap 路径清空）。

### 何时触发：VMA 与 stage-2 的短暂不一致

状态 2 的实质是：**VMA 认为这块地址应该是单页（vma_pagesize=PAGE_SIZE，不含 PROT_CONT），但 stage-2 里还残留着之前的 contig block。**

不一致的根源在于 VMA 变更和 stage-2 更新之间存在 MMU notifier 窗口：

```
1. 初始状态：VMA 是 hugetlb，vma_pagesize=CONT_PTE_SIZE
   vCPU 已 fault，stage-2 有 contig block（PTE[0..7] 全 valid+CONT）

2. 用户态 madvise(MADV_DONTNEED) 部分范围：
   → mmu_notifier_invalidate_range_start()    // KVM 做轻量处理（可能不 unmap）
   → 修改 VMA（切分 / 缩小，vma_pagesize → PAGE_SIZE）
   --- 窗口：VMA 已变，但 stage-2 未完 ---
   → mmu_notifier_invalidate_range_end()       // KVM 做实际 unmap，清 contig block

3. vCPU 在窗口内发生缺页 fault：
   - user_mem_abort: 看 VMA → vma_pagesize=PAGE_SIZE，prot 不带 PROT_CONT
   - stage-2 页表: contig block 还在
   - map walker: pte0 & CONT → 命中状态 2，-EAGAIN
```

类似触发源：

| 触发源 | VMA 变化 | stage-2 解除者 |
|--------|----------|---------------|
| `madvise(MADV_DONTNEED)` 部分范围 | VMA 切分 | notifier end → unmap |
| `mprotect` 部分范围改权限 | VMA 切分 | notifier end → unmap/wrprotect |
| THP split（khugepaged） | 大页退化为 4K | notifier end → unmap |
| dirty logging 开启 + 过度窗口 | VMA 不变但 force_pte=true | wrprotect → attr unfold |

### 为什么不是死循环？

T2 之外的路径（MMU notifier 回调、wrprotect）最终会清理 contig block：

```
T2 fault:         pte0=valid+CONT → -EAGAIN（退让）
notifier end:     unmap 清空整个 contig block（持 write_lock，排他）
T2 再次 retry:    pte0=0 → cmpxchg PTE[0] → 正常安装单页映射
```

T2 需要等待那几条路径完成。窗口是 MMU notifier 回调的延迟，极窄（微秒量级）。

### 极端情况

如果 MMU notifier 回调永远不来（内核 bug），T2 会无限 -EAGAIN。但这不是这段代
码能解决的——notifier 不来意味着 stage-2 页表本身就是脏的，任何方案都无解。

**正确性**：✓ 防御性安全网。正常流程不触发；触发了由其他路径解除，不会死循环。

---

## 状态 3：PTE[0] = Valid + 无 CONT 位

不命中任何 if，`locked_pte0` 保持 false。走正常的单页 BBM 流程。

**关键事实**：PTE[0] 不空闲 ≠ contig 不能启动。T1 的 contig 路径可以通过
`cmpxchg(PTE[0], ctx->old_T1, LOCKED)` 替换掉现有的 4K 映射，升级为 contig block。
ctx->old_T1 是 T1 的 walker 读到的 PTE[0] 值（valid_non_CONT），与 PTE[0] 当前值
匹配，cmpxchg 会成功。

### 子情况 3a：ctx->ptep == first_ptep（就是 PTE[0] 本身）

正常单页 BBM：
1. `stage2_try_break_pte(ctx, mmu)`：cmpxchg(PTE[0], valid_non_CONT, LOCKED)
2. TLBI + put_page（若 old valid）
3. `stage2_make_pte(ctx, new)`：smp_store_release(PTE[0], new)

**竞态——T1 想做 contig 升级**：T1 也在 PTE[0] 上做
`cmpxchg(PTE[0], ctx->old_T1, LOCKED)`。T1 和 T2 的期望值都是 `valid_non_CONT`。
两个 cmpxchg 只有一个能赢。输的 -EAGAIN 重试。这是标准的 per-PTE 串行化，
与 PTE[0]-as-block-lock 机制无关。

T1 赢了 → 做 contig BBM，安装 contig block。T2 重试后看 PTE[0]=valid+CONT → 状态 2 退让。
T2 赢了 → 安装单页映射。T1 重试后看 PTE[0]=valid_non_CONT（新的）→ 再次和 T2 竞争，
或者 needs_update 返回 false（相同映射）→ -EAGAIN。

**正确性**：✓ 与 contig 路径在 PTE[0] 上 cmpxchg 串行化。

### 子情况 3b：ctx->ptep != first_ptep（PTE[k], k>0）

正常单页 BBM 在 PTE[k] 上：
1. `stage2_try_break_pte(ctx, mmu)`：cmpxchg(PTE[k], ctx->old, LOCKED)
2. TLBI on ctx->addr（PTE[k] 覆盖的 IPA）
3. `stage2_make_pte`：smp_store_release(PTE[k], new)

**竞态——T1 想做 contig 升级**：T2 不触碰 PTE[0]（它是 valid 的，locked_pte0 保持 false）。
T1 在 PTE[0] 上 cmpxchg(PTE[0], ctx->old_T1, LOCKED) **可以成功**——PTE[0] 没变。

T1 成功后做 contig BBM，其 `kvm_clear_pte(PTE[k])` 与 T2 在 PTE[k] 上的 BBM 并发。
这是一个真实竞态，根因与设计文档中"contig BBM 的 per-PTE 锁缺口"相同：
PTE[1..N-1] 在 contig BBM 中不被锁保护。

具体时序有两个子情况：

**子情况 3b-1：T1 先清 PTE[k]**
```
T1: Lock PTE[0] → kvm_clear_pte(PTE[k]) → PTE[k] = 0
T2: cmpxchg(PTE[k], ctx->old, LOCKED) → PTE[k]=0 ≠ ctx->old → 失败 → -EAGAIN
```
T2 退让，重试后按新状态处理。✓

**子情况 3b-2：T2 先 cmpxchg 成功**
```
T2: cmpxchg(PTE[k], ctx->old, LOCKED) → 成功，PTE[k] = LOCKED
T1: kvm_clear_pte(PTE[k]) → PTE[k] = 0  （覆盖了 LOCKED！）
T2: smp_store_release(PTE[k], new) → PTE[k] = new
T1: smp_store_release(PTE[k], contig_new) → PTE[k] = contig_new  （覆盖了 T2 的结果！）
```
**T2 的映射被 T1 覆盖，丢失更新。**

```
┌─────────────────────────────────────────────────────────────┐
│ ⚠ 残留竞态                                                  │
│                                                             │
│ 子情况 3b-2 是从原始 contig BBM 实现继承的固有缺陷：         │
│ contig BBM 的 kvm_clear_pte(PTE[1..N-1]) 不受 PTE 级锁保护。│
│                                                             │
│ PTE[0]-as-block-lock 在状态 4（PTE[0]=0）关闭了此窗口；      │
│ 在状态 3b（PTE[0]=valid_non_CONT）仍有残留。                 │
│                                                             │
│ 触发需四个条件同时成立：                                     │
│ 1. VMA 过渡（PROT_CONT 不一致）+                             │
│ 2. PTE[0] 有 4K 映射 +                                      │
│ 3. T1 contig 升级 +                                         │
│ 4. T2 在 PTE[k] 的 cmpxchg 抢先 T1 的 kvm_clear_pte         │
│                                                             │
│ 窗口：MMU notifier 延迟，微秒量级，概率极低。                 │
│                                                             │
│ 未修复原因：完全关闭需在 PTE[0] valid 时也锁它，会导致        │
│ 同一 contig block 区域内两个无关的 4K 单页操作也互相串行化，  │
│ 代价大于收益。若后续发现触发概率高于预期，可考虑：             │
│   a) 事后检测：make 之后验证 PTE[0] 非预期值则回滚            │
│   b) cmpxchg PTE[0] 同时保留 saved_pte0，释放时恢复           │
└─────────────────────────────────────────────────────────────┘
```

---

## 状态 4：PTE[0] = INVALID (0)

最复杂的情况。做 cmpxchg(PTE[0], 0, LOCKED) 抢锁。成功则 `locked_pte0 = true`。
失败则返回 -EAGAIN（另一线程抢先改了 PTE[0]）。

### 子情况 4a：ctx->ptep == first_ptep（要修改的就是 PTE[0] 自己）

```
locked_pte0 = true
→ if (locked_pte0 && ctx->ptep == first_ptep) { /* 跳过 BBM */ }
→ CMO
→ stage2_make_pte(ctx, new)           // smp_store_release 将 LOCKED 覆盖为 new
→ 不触发 line 1229-1230 的释放        // ctx->ptep == first_ptep，不满足条件
```

**为什么跳过 BBM？** 三层分析：

**第一层——ctx->old = 0，无过时（常见情况）**：
- PTE[0] 在 walker 读时是 0，现在也是 0（cmpxchg 验证）
- 没有 valid 映射存在过 → TLBI 是 no-op
- `stage2_pte_is_counted(0)` = false → 不需要 put_page
- BBM 完全是 no-op，跳过无影响

**第二层——ctx->old 过时（ctx->old = valid，但 PTE[0] 现在 = 0）**：
- 有人在 walker 读和我们 cmpxchg 之间把 PTE[0] 从 valid 改成了 0
- 那个线程在清除 valid 映射时**已经做了 TLBI + put_page**
- 我们再做一次 TLBI + put_page 就是 double-flush + double-put（错误）
- 跳过 BBM 正确避免了 double-put_page

**第三层——为什么不能走正常 BBM**：
- 正常 BBM 第一步：`cmpxchg(PTE[0], ctx->old, LOCKED)`
- PTE[0] 现在是 LOCKED（我们自己设的）≠ ctx->old
- cmpxchg 必然失败 → -EAGAIN → 释放 PTE[0] → 重试 → 又锁 PTE[0] → cmpxchg 又失败 → **死循环**
- 跳过 BBM 是**必要的**，不是优化

**TLBI 是否缺失？** 不缺失。PTE[0] 被锁时值为 0，不存在需要 flush 的 TLB entry。
过时 ctx->old 的情况下，清除者已做 TLBI。

**释放路径**：
- 成功路径：`stage2_make_pte` 用 smp_store_release 将 LOCKED 覆盖为新 valid PTE
- 失败路径：此分支无失败点（BBM 被跳过，CMO 不失败，make_pte 不失败）

**正确性**：✓ 跳过 BBM 正确且必要。

### 子情况 4b：ctx->ptep != first_ptep（修改 PTE[k], k>0，PTE[0] 做 block 级锁）

```
locked_pte0 = true                     // PTE[0] = LOCKED
→ 不命中 "ctx->ptep == first_ptep"
→ stage2_try_break_pte(ctx, mmu)       // 在 PTE[k] 上做正常 BBM
  → 若失败: WRITE_ONCE(PTE[0], 0); return -EAGAIN
→ CMO
→ stage2_make_pte(ctx, new)            // PTE[k] = new valid
→ WRITE_ONCE(PTE[0], 0)               // 释放 block 锁
```

**两条锁链同时存在**：
- **Block 级锁**：PTE[0] = LOCKED，阻止任何 contig map/attr 在此 block 开始
- **PTE 级锁**：PTE[k] = LOCKED（由 stage2_try_break_pte 设置），阻止其他单页 op 碰 PTE[k]

#### 竞态：vs 并发 contig BBM（T1）

```
T2（我们）:  READ_ONCE(PTE[0]) → 0 → cmpxchg(PTE[0], 0, LOCKED) → 成功
T1（contig）: cmpxchg(PTE[0], 0, LOCKED)
             → PTE[0] = LOCKED ≠ 0 → 失败 → -EAGAIN
T2:          BBM on PTE[k] → Make PTE[k] → WRITE_ONCE(PTE[0], 0)
T1 重试:     READ_ONCE(PTE[0]) → 0 → cmpxchg 成功 → 正常 contig BBM
```

T1 在 T2 持有 PTE[0] 期间被阻塞在 cmpxchg 上。T2 释放后 T1 正常继续。✓

#### 竞态：vs 另一单页 op 在 PTE[j]（j≠k, j≠0）

```
T2: PTE[0] = LOCKED
T3: READ_ONCE(PTE[0]) → LOCKED → -EAGAIN（状态 1 退让）
T2: 完成 → WRITE_ONCE(PTE[0], 0)
T3 重试: PTE[0] = 0 → 正常进行
```

T3 被 PTE[0]=LOCKED 挡在门外，不会与 T2 在 PTE[k] 上冲突。✓

#### 竞态：vs 另一单页 op 在 PTE[0] 自身

```
T2: cmpxchg(PTE[0], 0, LOCKED) → 成功
T3: READ_ONCE(PTE[0]) → LOCKED → -EAGAIN
T2: 完成 → WRITE_ONCE(PTE[0], 0)
T3 重试: PTE[0] = 0 → 正常（走子情况 4a）
```

T3 退让，T2 完成释放后 T3 正常进行。✓

#### 竞态：ctx->old 过时——T1 的 contig BBM 抢先完成

```
T2 walker:  ctx->old = V (valid, PTE[k] 有旧映射)
T1 contig:  锁 PTE[0], 清 PTE[1..N-1], TLBI, 装 PTE[1..N-1]=valid+CONT,
            装 PTE[0]=valid+CONT
T2 此刻:    READ_ONCE(PTE[0]) → valid+CONT
            → pte0 & CONT → -EAGAIN（状态 2 退让）
T2 重试:    walker 重读 ctx->old = valid+CONT
            → 走 contig 路径（若 PROT_CONT）或再次退让
```

如果 T1 还在 BBM 中（PTE[0]=LOCKED）：
```
T2 此刻: READ_ONCE(PTE[0]) → LOCKED → -EAGAIN（状态 1 退让）
```

无论哪种，T2 安全退让。✓

#### 竞态：ctx->old 过时——T3 的单页 op 在 PTE[k] 抢先

```
T2 walker:  ctx->old = 0 (PTE[k] 空闲)
T3 单页:    BBM on PTE[k], 安装 valid 映射（PTE[k] 现在 = valid）
T2 此刻:    cmpxchg(PTE[0], 0, LOCKED) → 成功, locked_pte0 = true
            stage2_try_break_pte: cmpxchg(PTE[k], 0, LOCKED)
            → PTE[k] = valid ≠ 0 → 失败
            → WRITE_ONCE(PTE[0], 0) // 释放 block 锁
            → return -EAGAIN
T2 重试:    walker 重读 ctx->old = valid
            → needs_update 比较新旧值 → 若相同映射 return -EAGAIN
            → 若不同则继续，PTE[0]=valid 非 CONT（状态 3）→ 正常单页 BBM ✓
```

**正确性**：✓ T2 重试后正确处理。

---

## 完整竞态矩阵

| T1 操作 | T2（我们，单页） | PTE[0] 状态 | 结果 |
|---------|-----------------|-------------|------|
| contig BBM 中 | PTE[k] 进入 | LOCKED | T2 → -EAGAIN |
| contig 准备开始 | PTE[0] 进入，cmpxchg | 0 | 只有一方赢 cmpxchg |
| contig 准备开始 | PTE[k] 进入，cmpxchg PTE[0] | 0 | T2 锁 PTE[0] 成功 → T1 contig cmpxchg 失败 |
| contig 已完成 | PTE[k] 进入 | valid+CONT | T2 → -EAGAIN（防御性） |
| 单页 on PTE[0] BBM 中 | PTE[k] 进入 | LOCKED | T2 → -EAGAIN |
| 单页 on PTE[j] (j≠0,k) | PTE[k] 进入 | LOCKED（PTE[0] 被 T2 锁） | T1 → -EAGAIN（在状态 1 退让） |
| 无并发操作 | PTE[k] 进入，ctx->old 过时 | valid+CONT（T1 刚装完） | T2 → -EAGAIN 后重试 |
| 无并发操作 | PTE[0] 进入 | 0 | T2 锁 PTE[0] → 跳过 BBM → make |

---

## 总结

| PTE[0] 状态 | 行为 | 正确性 |
|------------|------|--------|
| LOCKED | -EAGAIN 退让 | ✓ |
| Valid + CONT | -EAGAIN 退让 | ✓ 防御性，不会死循环 |
| Valid 非 CONT | 正常单页 BBM | ✓ PTE[0] 不空闲，contig 不可能启动 |
| INVALID, ctx->ptep==PTE[0] | 锁 PTE[0] + 跳过 BBM | ✓ 跳过 BBM 正确且必要 |
| INVALID, ctx->ptep!=PTE[0] | 锁 PTE[0] + BBM PTE[k] + 释放 | ✓ 双重锁串行化所有并发操作 |

### 三个具体问题的回答

1. **`if (pte0 & CONT) return -EAGAIN` 为什么需要？**
   防御性检查。正常路径（有 PROT_CONT）已被 `stage2_contig_supported` 拦截；
   force_pte 路径依赖 attr 路径 unfold。返回 -EAGAIN 给那些路径时间完成，不会死循环。

2. **valid PTE 怎么处理？**
   Valid 非 CONT → 不需要特殊处理，contig block 不可能在此启动，正常单页 BBM 即可。
   Valid + CONT → 退让（状态 2）。

3. **跳过 BBM 导致 TLBI 缺失？**
   不缺失。PTE[0] 被锁时值为 0（INVALID），不存在需要 flush 的 TLB entry。
   过时 ctx->old 的情况下，清除者已做 TLBI。而且**不能**走正常 BBM——PTE[0] 已经是
   LOCKED，cmpxchg(ctx->ptep, ctx->old, LOCKED) 必然失败导致死循环。
