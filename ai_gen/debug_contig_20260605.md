KVM Stage-2 Contig Bit Debug 记录 (2026-06-05)
================================================

接续 `debug_contig_20260522.md`。本日核心进展：**否定了两个根因理论**
（TLB 残留、refcount UAF），且每次都是查实际代码验证前提，而非纸上推演。

## 今日起点

- 上次（05-22）基于"Make 窗口 + 缺 post-make TLBI"理论，加了 Make-phase
  TLBI（map 路径）+ 三个测试补丁（refcount fix / skip redundant BBM /
  Make 阶段 sanity check）。概率降低但 panic 仍在，sanity check 不触发。
- 今天把 Make-phase TLBI 和 CMO 补到**所有** contig 路径，已 commit。
- 用户测试结果：**仍复现原 panic**（迁移目的端多 vCPU，Guest 内核空指针；
  单 vCPU 永不触发）。

## 今日代码改动（已 commit）

commit `0655312d84a8` "KVM: ARM64: Add TLB and cache maintenance to contig
Stage-2 paths"（arch/arm64/kvm/hyp/pgtable.c，+111 行）：

- **Make-phase TLBI**（重写后仍带 CONT bit 的路径，Make 之后补刷）：
  - `stage2_map_contig_leaf`（05-22 已加）
  - `stage2_attr_contig_aligned`（今天加）
- **CMO 对齐**（镜像单页路径）：
  - map：dcache-clean（cacheable）+ icache-inval（exec），整个 block
  - unmap aligned/unaligned：dcache-clean（cacheable && !FWB），
    unaligned 只刷 in-range 页
  - attr aligned/unaligned：icache-inval（exec transition），
    unaligned 只刷 in-range 页
  - 加了 `stage2_pte_cacheable` 前向声明（unmap helper 在其定义之前）
- 编译通过：VHE / nVHE / kernel 三配置，整个 arch/arm64/kvm/ 子树无 warning。

注意：unmap、attr-unaligned 路径重建为 **non-CONT**（或完全 unmap），无
amalgamation，本不需要 post-make TLBI；只有 map 与 attr-aligned 两条
"重写后保留 CONT bit"的路径需要。

## 关键进展：否定两个理论

### 理论一否定 —— TLB 残留（bogus amalgamated entry persists）

**原理论**：Make 逐个写 PTE，窗口内 PTE[0]=LOCKED 而 PTE[1..15]=valid+CONT，
并发硬件 walk amalgamate 出 bogus TLB entry；break-TLBI 在 Make **之前**，
bogus entry 永不失效，持续到下次 BBM → Guest 用错翻译 → panic。

**验证** `kvm_tlb_flush_vmid_range`（pgtable.c:707）：
```c
pages = size >> PAGE_SHIFT;          // CONT_PTE_SIZE >> PAGE_SHIFT = 16
if (!system_supports_tlb_range()) {
    kvm_call_hyp(__kvm_tlb_flush_vmid, mmu);   // ← 全刷整个 VMID
    return;
}
// 支持 range：刷 16 页，覆盖 block
```
- 支持 TLB range：刷 16 页，覆盖 block
- **不支持 range：全刷整个 VMID**
- 两种情况，post-make TLBI 都**必然覆盖** contig block

**结论**：post-make TLBI 确实生效，但 panic 仍在 → **根因不是 TLB 残留**。
这条干净地否定了 05-22 和今天的 TLB 系理论。

### 理论二否定 —— refcount UAF（重入 BBM 时页表页被释放）

**原理论**：vCPU1 重入 vCPU0 建好的 block（如权限升级），重入 BBM 把
page table page 的 refcount put 到 0 → 页释放 → 另一 vCPU 的 mmu_cache
抢走并清零/改写 → 我们继续 smp_store_release 写它 → use-after-free。

**验证**：
- `put_page(ptep)` 减的是 **ptep 所在的 page table page**（`virt_to_page(ptep)`）
  的 refcount，**不是** PTE 指向的数据页。每个有效叶子 PTE 对该页表页贡献 +1。
- `kvm_s2_put_page`（mmu.c:258）：refcount 归 0 时 `put_page` 释放页
  （注释 "Dropping last refcount, the page will be freed"）。
- **但空末级页表的 base refcount = 1**。证据：`stage2_unmap_walker` 用
  `mm_ops->page_count(childp) != 1` 判断"空表可回收"——说明无叶子 PTE 时
  refcount 就是 1。
- 16 个有效 PTE 的页表页 refcount = 1(base) + 16 = **17**。
  重入 BBM put 16 次：17 → **1**，不归 0，**页不释放**。

**结论**：**无 UAF**。a44ef93（PTE[0] path refcount fix）防的是 **leak**
（重入时少 put 一次 → 每次重入多 +1 → 页永不回收），不是 UAF。

## PTE[0] cmpxchg 锁：反复验证正确

- **stale read**：walker 入口 `READ_ONCE(PTE[0])` 快照可能过期。但
  `stage2_try_set_pte` = `cmpxchg(PTE[0], ctx->old, LOCKED)`，用 stale 值
  作 expected；实际值变了 cmpxchg 失败 → -EAGAIN。stale 被挡住（ABA-safe，
  因为中间的 unmap 持 write lock，与 map 的 read lock 互斥）。
- **瞬态 LOCKED**：并发 vCPU 看到 PTE[0]=LOCKED → `stage2_map_contig_leaf`
  入口 `if (stage2_pte_is_locked(ctx->old)) return -EAGAIN`。挡住。
- **进入点对齐**：map 的 fault_ipa 对齐到 CONT_PTE_SIZE，walk 从 PTE[0] 起；
  从 block 中间进入的操作（mkyoung/unmap/attr）在 helper 里
  `PTR_ALIGN_DOWN` 回 PTE[0] 再 cmpxchg。锁粒度正确。
- walker advance（`__kvm_pgtable_visit` 238-258）：遇 CONT/LOCKED 跳整个
  block，避免从 PTE[1] 重入。逐个场景推演均自洽。

**结论**：软件互斥每次推演都正确。

## 当前状态

- 三个理论全部否定：
  1. 05-22 Make 窗口 TLB 不一致（用户确认硬件不检查邻居 CONT）
  2. 今天 TLB 残留（post-make TLBI 必覆盖 block，仍 panic）
  3. 今天 refcount UAF（base refcount=1 兜底，最低到 1 不归 0）
- 软件锁经反复静态验证正确。
- **静态分析到瓶颈**，不应再产出纸上理论。
- **没有可靠的强线索**。曾以为"概率随重入 BBM 次数变化"是线索，但此因果
  推断不成立（用户 06-05 纠正）：
  - 复现本身是概率性 race，概率波动是固有的，"加补丁后概率降低"可能只是
    采样波动，不是补丁的因果效应。
  - 05-22 是**一次性加了三个补丁**（refcount fix / skip redundant BBM /
    sanity check），即使概率真降低也无法归因到 skip redundant BBM。
  - 故"重入 BBM 是元凶"**降级**为众多未验证可能之一，不再独占优先级。

## 未验证的可能路径之一：重入 BBM（非已确认主因）

以下是**机制事实**，但它只是众多可能之一，不是已确认的根因（见上节，
"概率相关"的因果推断已被否定）：

- contig 权限 fault（R→RW）：因 `vma_pagesize=CONT_PTE_SIZE(64K)` !=
  `fault_granule=PAGE_SIZE(4K)`，**不走** relax_perms 快捷路径，走完整
  `stage2_map` → 触发重入 BBM。
- 这是迁移目的端 Guest 跑起来后的一个典型场景（先 read 建 block，后 write
  升权限）。多 vCPU 并发权限升级 → 多次并发重入。
- 但"重入 BBM 在复现时是否真发生、发生时 old/new 差异是什么"**无数据**。
- 其他同等地位的未验证可能：硬件 amalgamation 行为、首次建立路径、
  walker advance 在 contig/单页混合时的边界、非 contig 路径被 advance
  改动影响等。

## 下一步方向（待用户确认，需复现环境配合）

因"重入 BBM 概率相关"已被否定，优先选**不依赖概率推断、能确定性切开
问题域**的实验：

1. **二分实验：禁用硬件 CONT bit**（首选）：建 16 个 valid PTE 但不设
   BIT(52)，保留全部 contig 软件路径（锁、refcount、批量 BBM、advance）。
   - panic 消失 → 根因在**硬件 amalgamation 行为**，聚焦硬件 contig 语义。
   - panic 仍在 → 根因在**纯软件逻辑**，与硬件 CONT 无关，聚焦并发/页表。
   - 一刀切开硬件/软件两大问题域，不受概率波动干扰。
   - 实现要点：advance 逻辑当前依赖 CONT bit 识别 block，需改用不依赖
     CONT bit 的方式（如内部标记或按对齐跳），否则实验不纯。
2. **加 trace 抓 contig map 全景**：在 map / attr / unmap 关键路径加
   trace_printk（addr / old / new / phys / vCPU / 时间戳），复现后 dump
   ftrace 看**真实并发模式**（不预设重入是元凶）。概率性 race 可能需多次
   复现才采到关键时序。
3. **二分实验：消除重入 BBM**：仅在方向 1 指向"软件并发"后才值得做——
   让 contig 权限 fault 不重入，看 panic 是否消失，验证重入是否其中一环。

还需收集：panic backtrace + 空指针地址。
- 0x0 / 小偏移 → 倾向"页内容被清零"
- 看似有效内核地址但映射错乱 → 倾向"翻译指向错误物理页"
- 每次地址无规律 → 倾向"页表/物理页被并发损坏"

## 教训

- 连续否定的理论都"完美契合症状"。**症状契合不等于根因正确**。
- 验证理论前提务必查实际代码（put_page 实现、base refcount、TLBI fallback），
  不能假设。本日两个理论都是在"前提"上被证伪的，不是逻辑推导错。
- multi-vCPU-only 是并发指纹，但并发危险点不一定在最显眼的 BBM 窗口；
  PTE[0] 锁本身经反复验证是对的，问题可能在锁覆盖不到的地方或硬件层。
- **概率性 race 的"概率变化"不能作为因果证据**：复现是概率性的，波动是
  固有的；一次加多个补丁时更无法把"概率降低"归因到某个补丁。不要把采样
  波动当成"补丁生效/某路径是元凶"的信号。定位要靠确定性实验（二分、
  禁用某机制看 panic 是否消失），不靠概率观感。
