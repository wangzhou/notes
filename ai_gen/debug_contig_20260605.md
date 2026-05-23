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

================================================================
# 今日后续（同日，接"下一步方向"第 1 条）
================================================================

接上文。本段进展：**二分实验直接出结论（纯软件）** + **代码级证实 map
路径绕过 PTE[0] 锁** + **加 3 处探针** + **关键自我修正：state-3b 触发
前提（4K fault 来源）未验证，可能被否**。

## 0. 关键输入（用户提供）

调试用的**硬件本来就不支持 stage2 contig bit**（硬件忽略 BIT 52 hint）。
故上文"下一步方向"排第一的二分实验"禁用硬件 CONT bit"**天然已经跑过**。

## 1. 确定性结论：根因在纯软件逻辑

- 二分判据（见上文方向 1）：禁用硬件 CONT → panic 消失=硬件 amalgamation；
  仍在=纯软件。
- 硬件本就忽略 CONT ≡ 实验已跑，且 panic 仍在 → **确定性落到纯软件逻辑**，
  排除硬件 amalgamation。确定性切分，非概率推断。
- 查证（查 .config 验证前提，非假设）：`CONFIG_KVM_MMU_LOCKLESS_AGING`
  **未配置** → user_mem_abort 的 1725 分支不生效，contig 路径**确实启用**
  （排除"contig 根本没跑"这一可能）。

## 2. 代码级证实：map 路径绕过 PTE[0] 锁（= 上文记的"状态3b"）

PTE[0]-as-block-lock 前提是"所有碰 block 的操作都对齐回 PTE[0] 串行"。
**map 路径不满足**：

- `stage2_contig_supported`（pgtable.c:130）走 contig 的门槛含**请求几何**：
  `addr 按 64K 对齐 && 区间 ≥64K`。
- 4K 区间、落 PTE[k]（k≠0）的 fault 必然失败几何检查 → 走
  `stage2_map_walker_try_leaf` 单页分支，直接对 `ctx->ptep`=PTE[k] 做
  break+make，**不对齐 PTE[0]、不拿锁**。
- 即便 PTE[k] 当前有 CONT bit 也如此（`CONT=BIT(52) ∉ HI_SW=GENMASK(58,55)`，
  故是完整 BBM，不走软件位快存路径）。
- **路由不对称（关键）**：attr 路径（`stage2_attr_walker`:1694）走 contig
  只看 `old&CONT` → 任何 CONT PTE 都对齐 PTE[0]，mkyoung/relax/wrprotect
  **安全**；唯独 map 路径因几何门槛漏。

## 3. 加了 3 处调试探针（编译过 VHE/nVHE/kernel 无 warning；临时代码，未 commit）

1. **单页侧 WARN**（pgtable.c:1292，`stage2_map_walker_try_leaf` 单页分支
   入口）：`ctx->old & CONT` 时打印 addr/old/phys/level/cpu。抓"4K map 在锁
   外动一个 CONT PTE"。
2. **owner 侧 WARN**（pgtable.c:1182，`stage2_map_contig_leaf` make 循环）：
   make 写 PTE[i] 前若 `cur != 0`（我 break 已清 0）则打印。抓"PTE[0] 锁外
   有人写了 block 内 PTE"。
3. **已存在 owner 侧 WARN_ON**（pgtable.c:1131，break 循环）：break 时
   PTE[i]=LOCKED。
- 用 `WARN`（非 ONCE）以看并发模式；注意高频可能扰动 race 时序。

## 4. 关键自我修正：state-3b 触发前提未验证（用户质疑）

用户质疑：`vma_pagesize=CONT_PTE_SIZE` 时不会有单页 fault，4K 从哪来？

查 `user_mem_abort`（查代码验证前提）：`force_pte` 唯一正常来源 =
`logging_active`（mmu.c:1660-1661）。其余：1732 else 带 `WARN_ON(1)`（异常、
对固定 GFN 稳定，不会与 64K 并发同一 block）、1746 nested（非嵌套不适用）。

| logging | fault 粒度 | 结果 |
|---|---|---|
| 关 | 全 64K | 全 contig（contig-vs-contig，PTE[0] 锁串行） |
| 开 | 全 4K force_pte | **不建 CONT block** |

- 故 state-3b（4K 撞 CONT）只在 **logging 关→开切换 + 切换后 4K 落到已建
  CONT block** 时成立。
- "迁移目的端是否有这种 logging 切换"**未验证**（标准 live migration：源端
  开 logging，目的端通常关）→ **用户质疑很可能成立，可能判 state-3b 出局**。
- 教训重申（呼应"概率不是因果"那条）：又一次基于未验证前提（"目的端有
  logging 切换"）设主攻方向。

## 5. 方向收窄

- **owner 侧 WARN 不依赖"有没有 4K fault"这个前提**，直接判 PTE[0] 锁严不严：
  - 触发 → 锁有洞（绕过者：4K map / contig-vs-contig 锁失效 / advance 重入，
    任一）。
  - 不触发 → 锁严密，panic 在**锁之外** → 收窄到 contig-vs-contig 内部的多核
    问题（可见性/TLB/refcount/advance）。
- 单页侧 WARN 不触发 → 坐实无 4K 入侵。

## 6. 下一步

- **待加 E（源头侧）**：`user_mem_abort` 记 gfn/vma_pagesize/force_pte/
  logging_active/cpu，复现时直接测：目的端 logging 状态、有无 4K fault 落到
  contig 区、vCPU 间粒度分歧。一锤定音 state-3b 前提是否成立。
- 复现后收集：3 处 WARN 输出 + 栈回溯；panic backtrace + 空指针地址。
- 候选探针：A 后果侧 refcount 配平（contig unmap/put_page）；B advance
  LOCKED 过跳记录。

## 7. 今日教训

- "查实际代码/配置验证前提"再次奏效：`LOCKLESS_AGING`、`force_pte` 来源均
  查证而非假设。
- state-3b 症状契合，但其前提（logging 切换）未证 → **症状契合 ≠ 根因**
  （与本文上半天两次否定同一教训）。
- 探针设计要**可证伪 + 不依赖争议前提**：owner 侧 WARN 的价值正在于绕开
  "有没有 4K fault"的争论，直接判锁严不严。
