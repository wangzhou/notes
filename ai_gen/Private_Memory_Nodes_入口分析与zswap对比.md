# Private Memory Nodes — 压缩内存入口分析与 zswap 对比

> **相关文档**:[[Private_Memory_Nodes_补丁分析]]
> **分析日期**:2026-06-21
> **代码版本**:Gregory Price RFC v4,`private_node` 分支,HEAD=`ebee9835033a`

---

## 第一部分：压缩内存入口分析

### 1. 总览：迁入 Private Node 的五条路径

内核中所有能导致页面迁入 N_MEMORY_PRIVATE node 的路径：

| # | 路径 | 触发方式 | 需要的 `NP_OPS_*` flag | cram 支持? |
|---|------|---------|----------------------|-----------|
| 1 | **vmscan demote** | kswapd/直接回收,memory tier 选为目标 | `NP_OPS_DEMOTION` | ✅ 主入口 |
| 2 | **`move_pages()` syscall** | 用户显式指定 private node 为迁移目标 | `NP_OPS_MIGRATION`(`migrate_to` 回调) | ✅ |
| 3 | **`migrate_pages()` syscall** | 同上 | `NP_OPS_MIGRATION` | ✅ |
| 4 | **`mbind()` syscall** | mempolicy 绑定 + `MPOL_MF_MOVE` | `NP_OPS_MEMPOLICY` + `NP_OPS_MIGRATION` | ❌ 缺 MEMPOLICY |
| 5 | **swapin 缺页** | VMA mempolicy(`MPOL_F_PRIVATE`)指向 private node | VMA 隐式(需 `NP_OPS_MEMPOLICY`) | ❌ 缺 MEMPOLICY |

**NUMA balancing 只能从 private node 迁出,不能迁入**——`migrate_misplaced_folio()` 的分配器 `alloc_misplaced_dst_folio()` 不设 `__GFP_PRIVATE`,永远被 `numa_zone_alloc_allowed()` 挡在门外。

结论：对 cram 而言,**生产环境真正的入口只有 vmscan demote 一条**。syscall 路径可作为调试/测试用,但不是自动化路径。

---

### 2. 主入口详解：vmscan demote 全链路

这是 cram 在生产环境中的唯一自动化入口。整个链路分四层：

#### 2.1 触发层：`can_demote()` — 门控

`mm/vmscan.c:352` — `shrink_folio_list()` 在处理每个 LRU folio 时,在决定"回收还是 demote"前先过这四道关：

```c
static bool can_demote(int nid, struct scan_control *sc, struct mem_cgroup *memcg)
{
    if (!numa_demotion_enabled)          // (a) 系统级 demotion 开关
        return false;
    if (sc && sc->no_demotion)           // (b) 本次扫描禁止 demotion
        return false;
    demotion_nid = next_demotion_node(nid); // (c) 有降级目标吗
    if (demotion_nid == NUMA_NO_NODE)
        return false;
    if (node_private_migration_blocked(demotion_nid)) // (d) 目标反压
        return false;
    return mem_cgroup_node_allowed(memcg, demotion_nid); // (e) cgroup 允许
}
```

门 (d) 是 cram 背压的关键：`cram_set_pressure() ≥ CRAM_PRESSURE_MAX` 时 `migration_blocked=true`,`can_demote()` 对所有源 node 返回 false——**全局关闸**。

`mm/vmscan.c:1302`——通过门控后,folio 被移入 `demote_folios` 链表,跳过回收：

```c
if (do_demote_pass &&
    (thp_migration_supported() || !folio_test_large(folio))) {
    list_add(&folio->lru, &demote_folios);  // 不放回 LRU,去 demote
    folio_unlock(folio);
    continue;                                // 跳过 swap/pageout
}
```

#### 2.2 路由层：`establish_demotion_targets()` — 目标选择

`mm/memory-tiers.c:420`——重建 demotion 拓扑时,把 opt-in 的 private node 纳入候选集：

```c
all_memory = node_states[N_MEMORY];
for_each_node_state(node, N_MEMORY_PRIVATE)
    if (node_private_has_flag(node, NP_OPS_DEMOTION))
        node_set(node, all_memory);
```

然后对每个 N_MEMORY node,按 memory tier 的 distance 找下一级 tier 中距离最短的 node,填入 `nd->preferred` 掩码。

`next_demotion_node()`(`mm/memory-tiers.c:333`)从 `preferred` 中**随机**选取(避免轮询的缓存行乒乓)：

```c
rcu_read_lock();
target = node_random(&nd->preferred);
rcu_read_unlock();
```

cram 在注册时通过 `memory_tier_refresh_demotion()` 触发重建。

#### 2.3 分发层：`demote_folio_list()` — 先 private 后普通

`mm/vmscan.c:1033`——这是关键分发器。逻辑是**逐个尝试 private node,全失败后 fallback 到普通 DRAM 降级**：

```c
/* 循环尝试所有 private node */
while (node_state(target_nid, N_MEMORY_PRIVATE)) {
    ret = node_private_migrate_to(demote_folios, target_nid,
                                  MIGRATE_ASYNC, MR_DEMOTION, &nr);
    nr_succeeded += nr;
    if (ret == 0 || list_empty(demote_folios))
        return nr_succeeded;    // 全部成功 → 返回

    target_nid = next_node_in(target_nid, allowed_mask);
    if (target_nid == first_nid)
        return nr_succeeded;    // 遍历完一圈,仍有未迁走的,返回
    if (!node_state(target_nid, N_MEMORY_PRIVATE))
        break;                  // 没有更多 private target → 走标准路径
}

/* 标准 DRAM demotion */
mtc.nid = target_nid;
migrate_pages(demote_folios, alloc_demote_folio, NULL, ...);
```

**重要细节**：标准 demotion 的 gfp 是 `GFP_HIGHUSER_MOVABLE & ~__GFP_RECLAIM | GFP_NOWAIT`——永不阻塞。private 路径的阻塞性由各个 `migrate_to` 回调自己决定(cram 选择 `__GFP_NORETRY`,也不阻塞,见下文)。

#### 2.4 执行层：`cram_migrate_to()` — 实际迁移

`mm/cram.c:174`：

```c
static int cram_migrate_to(struct list_head *demote_folios, int to_nid, ...)
{
    // 1. 获取 cram_node,检查 alive + 未 purge
    // 2. 检查 pressure < CRAM_PRESSURE_MAX,否则 -ENOSPC
    // 3. migrate_pages(demote_folios, alloc_cram_folio, cram_put_new_folio, ...)
}
```

目标页分配器 `alloc_cram_folio()`：

```c
gfp_t gfp = GFP_PRIVATE | __GFP_KSWAPD_RECLAIM |
            __GFP_HIGHMEM | __GFP_MOVABLE |
            __GFP_NOWARN | __GFP_NORETRY;
// GFP_PRIVATE = __GFP_PRIVATE | __GFP_THISNODE
return __folio_alloc_node(gfp, order, nid);
```

`__GFP_NORETRY` 保证**分配失败时立即返回 NULL,不进入直接回收、不阻塞调用者**。`__GFP_PRIVATE` 是通过 `numa_zone_alloc_allowed()` 门控的唯钥匙。

#### 2.5 完整调用图

```
DRAM node kswapd / direct reclaim
  │
  ├─ can_demote(): numa_demotion_enabled?
  │                 next_demotion_node() → N_MEMORY_PRIVATE?
  │                 migration_blocked? ← cram_set_pressure()
  │
  ├─ shrink_folio_list(): folio 移入 demote_folios 链表
  │
  ├─ demote_folio_list():
  │    while (target is N_MEMORY_PRIVATE):
  │      node_private_migrate_to() → cram_migrate_to()
  │        ├─ alloc_cram_folio(GFP_PRIVATE | __GFP_NORETRY)
  │        │    → __folio_alloc_node() → numa_zone_alloc_allowed()
  │        │       只有 __GFP_PRIVATE 能穿过 N_MEMORY_PRIVATE 门
  │        └─ migrate_pages() → folio_mc_copy(dst, src)
  │             → 数据从 DRAM 拷贝到 private node folio
  │
  └─ 成功: folio 进入 private node LRU,由 cram 自己的 kswapd 管理
     失败: 回退到标准 DRAM demotion 或 swap
```

---

### 3. syscall 入口：move_pages / migrate_pages

#### 3.1 通用调度器 `migrate_folios_to_node()`

`mm/migrate.c:2215`——所有以 node 为目标的迁移的通用调度器：

```c
int migrate_folios_to_node(struct list_head *folios, int nid, ...)
{
    if (node_state(nid, N_MEMORY_PRIVATE))
        return node_private_migrate_to(folios, nid, mode, reason, NULL);
    return __migrate_folios_to_node(folios, nid, mode, reason);
}
```

私有节点走 `migrate_to` 回调,普通节点走标准路径。

#### 3.2 `move_pages()` → `do_move_pages_to_node()`

`mm/migrate.c:2238`:`do_pages_move()` 收集用户指定的页面,验证目标 node 是 `N_MEMORY` 或 `N_MEMORY_PRIVATE`,然后调 `migrate_folios_to_node()`。

#### 3.3 `migrate_pages()` → `migrate_to_node()`

`mm/mempolicy.c:1341`:由 `do_migrate_pages()` 调起,按 from→to 映射把页面搬到目标 node。

两条 syscall 路径的生产价值有限——用户空间通常不会手动把页面往压缩内存搬。但对驱动开发/调试有用。

---

### 4. mempolicy 入口：mbind + swapin

这两条路径都需要 `NP_OPS_MEMPOLICY`,cram **没有**设置此 flag。

#### 4.1 mbind 迁入

`mm/mempolicy.c:1561`:`mpol_set_nodemask()` 检查目标掩码中的 private node 必须都有 `NP_OPS_MEMPOLICY`:

```c
if (nodes_private_mpol_allowed(&nsc->mask2))
    pol->flags |= MPOL_F_PRIVATE;
else if (nodes_intersects(nsc->mask2, node_states[N_MEMORY_PRIVATE]))
    return -EINVAL;  // 有 private node 但没 MEMPOLICY → 拒绝
```

通过后,`alloc_migration_target_by_mpol()` 在 `MPOL_F_PRIVATE` 时设 `__GFP_PRIVATE`,允许在 private node 上分配目标页。

#### 4.2 swapin 到 private node

`mm/memory.c:4448`:`__alloc_swap_folio()` → `vma_alloc_folio()` → 如果 VMA 有 `MPOL_F_PRIVATE` mempolicy → `__GFP_PRIVATE` → swapin 页面直接分配到 private node。

这也需要 `NP_OPS_MEMPOLICY`。cram 的哲学是"只读,只由 demotion 进",所以不需要也不应该通过 mempolicy 进。

---

### 5. NUMA balancing：只能出不能进

`mm/migrate.c:2737`:`migrate_misplaced_folio()` 的分配器 `alloc_misplaced_dst_folio()` 使用的 gfp 不含 `__GFP_PRIVATE`:

```c
gfp_t gfp = __GFP_THISNODE;  // 没有 __GFP_PRIVATE!
if (order > 0)
    gfp |= GFP_TRANSHUGE_LIGHT;
else
    gfp |= GFP_HIGHUSER_MOVABLE | __GFP_NOMEMALLOC | __GFP_NORETRY | __GFP_NOWARN;
```

这意味着 NUMA balancing 的"放置"决策**永远不会选 private node**。

但**迁出**是允许的:`folio_managed_allows_migrate()` 当 `NP_OPS_MIGRATION` 时放行,`NP_OPS_NUMA_BALANCING` 时 NUMA hinting 扫描 private node 上的页。所以 private node 上的热页可以被 NUMA balancing 提升回 DRAM——这是 demote-promote 之外的另一条"出"的路径。

---

## 第二部分：与 zswap 的对比

### 6. 一句话定位

**zswap 是"CPU 压缩的 swap 缓存"(夹在 LRU 和 swap 设备之间透明拦截 IO),cram/PMN 是"让硬件压缩内存变成标准 NUMA node"(复用整个 MM 子系统管理它)。**

---

### 7. 架构差异

```
zswap 数据路径:
  LRU folio → try_to_swap_out() → swap_writepage()
    → zswap_store() → CPU/hw compress → zsmalloc pool (无 PTE!)
    → (pool 满) shrinker → decompress → 写回 swap 磁盘
    → (缺页) zswap_load() → xarray 查 entry → decompress → 还给进程

cram/PMN 数据路径:
  LRU folio → shrink_folio_list() → demote_folios 链表
    → demote_folio_list() → cram_migrate_to()
    → buddy 分配 private node folio → folio_mc_copy() (只 copy,无压缩)
    → PTE 指向 private node 上的 folio (有真实 PTE!)
    → (读) MMU 页表遍历直达,不 fault
    → (写) cram_fault() → folio_isolate_lru → migrate_pages → 回到 DRAM
    → (private node 满) kswapd 回收 → swap out
```

最根本的区别：**zswap 的压缩数据没有 PTE,通过 swap cache 查找；cram 的 folio 有真实 PTE,走正常 MMU 页表遍历。**

---

### 8. 技术维度对比

| 维度 | zswap | PMN/cram |
|------|-------|----------|
| **架构模型** | 夹在 LRU 和 swap 之间的透明缓存层 | 独立 NUMA node,有自己的 LRU、kswapd、zonelist |
| **谁来压缩** | CPU(crypto API,可硬件 offload) | **硬件**(CXL 压缩内存控制器),kernel 不感知压缩 |
| **kernel 是否参与压缩操作** | 是(`crypto_acomp_compress/decompress`) | 否(只 migrate,copy_page) |
| **数据进入** | swap_writepage 时拦截,压缩存 zsmalloc | vmscan demote 时搬迁,copy_page,无压缩 |
| **数据出去** | swapin 时解压返回,migrate_pages 做 swap cache | 写 fault 时 migrate_pages 搬回 DRAM |
| **页面有无 PTE** | 无(通过 swap cache + xarray 索引) | 有(标准页表项,只读) |
| **满时行为** | shrinker → 解压 + 写回磁盘(块 IO) | `-ENOSPC` → vmscan 优雅降级为 swap |
| **需要 swap 设备** | 是(作为 backing store) | 否(private node 自己就是归宿) |
| **大页支持** | ❌ 显式拒绝(`zswap_load` 返回 `-EINVAL`) | ✅ 原生支持(`__GFP_COMP`,order 透传,multi-page `folio_mc_copy`) |
| **元数据开销** | `zswap_entry`(~72B) + zsmalloc handle + xarray slot | 仅 `struct page` 复用,零额外分配 |
| **内存分配器** | zsmalloc(slab-like,自己切片) | buddy(标准页分配器) |
| **NUMA 感知** | 弱(pool 按 node 隔离 LRU) | 一等公民:独立 node,参与 memory-tier distance,完整 zonelist 拓扑 |
| **并发模型** | per-CPU crypto ctx mutex + 全局 LRU 锁 + xarray 锁 | 标准 MM 锁(PTL、LRU lock、RCU) |
| **反压信号** | `max_pool_percent` + `accept_threshold_percent`(粗粒度阈值) | 硬件驱动 `cram_set_pressure(0-1000)` 连续量,watermark_boost 按比例渐进 |
| **反压粒度** | 两个阈值(上/下限),二进制 | 连续(0-1000)→ 渐进式 watermark_boost,满才关门 |
| **压缩比崩塌处理** | shrinker 写回磁盘(解压+IO,代价高) | 停止 demote + kswapd 加速 evict,无"解压再写盘"的二次伤害 |

---

### 9. 性能维度对比

#### 9.1 数据移动：每页多少次拷贝+转换

```
zswap store（页面进）:
  源 page → sg_list → crypto_acomp_compress → zsmalloc buffer
  典型 2-3 次内存 copy + 1 次压缩操作（硬件或软件）

zswap load（页面出）:
  zsmalloc buffer → sg_list → crypto_acomp_decompress → 目标 folio
  典型 1-2 次 copy + 1 次解压操作

cram demote（页面进）:
  DRAM folio → folio_mc_copy(dst, src) → private node folio
  精确 1 次 copy_page()，无压缩/解压

cram promote（页面出）:
  private node folio → folio_mc_copy(dst, src) → DRAM folio
  精确 1 次 copy_page()，无压缩/解压
```

即使 zswap 的压缩由硬件加速器完成,cram 仍然少了一个"压缩→变长 blob→zsmalloc 管理"的数据路径环节。

#### 9.2 分配器停滞：谁会在内存压力下阻塞

这是最具实际影响的运行时差异：

| 路径 | GFP 标志 | 内存压力下会阻塞? | 原因 |
|------|---------|------------------|------|
| **cram demote** | `__GFP_NORETRY` | **不阻塞** | 分配失败立即返回 NULL |
| **cram promote** | `__GFP_RETRY_MAYFAIL` | **会阻塞** | "promotion is mandatory"——页必须回 DRAM |
| **zswap store** | `GFP_KERNEL`(entry + xa_store) | **会阻塞** | entry 分配和 xarray 插入都可能进直接回收 |
| **zswap load** | 不分配(zswap 不负责目标页) | **不阻塞** | swapin 路径在调用前已分配好目标页 |
| **标准 vmscan demote** | `GFP_NOWAIT` | **不阻塞** | 快速失败 |

不对称性：

```
进的方向：cram >> zswap (cram 不阻塞，zswap store 可能卡在 GFP_KERNEL)
出的方向：zswap >> cram (zswap load 不分配，cram promote 可能卡在 __GFP_RETRY_MAYFAIL)
```

实际影响取决于工作负载：如果 demote 频繁而 promote 罕见（冷数据下沉），cram 占优；如果页面在压缩和未压缩之间频繁颠簸，zswap load 无分配的优势会放大。

#### 9.3 锁操作计数

| 路径 | 锁操作数 | 备注 |
|------|---------|------|
| **cram demote** | ~7-9 | 迁移锁 + `lru_add_drain_all()`(广播 IPI,批量时可能瓶颈) |
| **cram promote** | ~10-12 | PTL + folio_trylock×2 + xas_lock_irq + mmap_read_unlock |
| **zswap store** | ~8-10 | mutex(per-CPU crypto ctx) + xa_lock + zsmalloc 锁 + LRU lock |
| **zswap load** | ~5-7 | mutex + zsmalloc 读锁 + xa_lock(folio 已分配好) |

zswap load 锁最少(不需页面迁移,只做解压);cram promote 锁最多(完整 `migrate_pages`:页表更新、rmap、memcg 迁移)。

这是 **"move vs transform"** 的根本 tradeoff:
- zswap:用压缩/解压换取"不搬物理页"(页面不离开原位置,只存储压缩副本)
- cram:搬物理页(`migrate_pages`)换取"免压缩/解压"

#### 9.4 满时行为：谁承受更大的降级代价

```
zswap pool 满:
  shrinker → zswap_writeback_entry()
    → zswap_decompress()         ← 再触发一次硬件解压
    → __swap_writepage()         ← 写磁盘（块 IO，可休眠）
  = 两次昂贵操作串联,"解压→写盘"赔夫人折兵

cram private node 满:
  cram_migrate_to() → return -ENOSPC
    → 上层 vmscan 优雅换其他候选或走 swap
  = 零额外开销，直接拒绝
```

zswap 的溢写路径是性能灾难：pool 满后每个被挤出的页要先解压再写盘。cram 直接拒绝,让调用者从 LRU 链表中另选页面处理,不发生"解压→写盘"这种事。

#### 9.5 大页性能

zswap 显式拒绝 large folio(`mm/zswap.c`):

```c
if (folio_test_large(folio)) {
    WARN_ONCE(1, "Large folios should not be swapped in while zswap is being used.");
    return -EINVAL;
}
```

cram 的 `alloc_cram_folio()` 保留 `folio_order(src)` + `__GFP_COMP`:

```c
if (order)
    gfp |= __GFP_COMP;
return __folio_alloc_node(gfp, order, nid);
```

`folio_mc_copy()` 对大页逐子页 copy,子页间 `cond_resched()`。对 THP/folio 占比高的负载,zswap 必须先 split 成 4K 再逐页 store/load,cram 可以 2M 整块搬迁(一次锁,搬迁 512 页)。

#### 9.6 元数据内存开销

| | 每页额外元数据 | TB 级设备额外开销 |
|---|---|---|
| **zswap** | `zswap_entry`(~72B) + zsmalloc handle + xarray node | 数百 MB ~ GB 级 |
| **cram** | 无(复用 `struct page`) | 零 |

zswap 的 zsmalloc 本身从 buddy 拿内存再用自己的 slab-like 分配器切片管理——比 cram 多了一层分配器开销和一层 LRU 结构。

---

### 10. 性能小结

```
                     demote/store（进）           promote/load（出）      大页   满时
                     ────────────────           ─────────────────      ────   ──────
cram/PMN            1 copy, 不阻塞              1 copy, 可阻塞          ✅    拒绝(0 开销)
zswap               2-3 copy + 压缩, 可阻塞      1-2 copy + 解压, 不阻塞  ❌    解压+写盘(昂贵)
```

**cram 的 tradeoff**:让 demote 方向更便宜(1 copy,不阻塞,无压缩),代价是 promote 方向更贵(要搬页,DRAM 紧张时可能阻塞)。

**zswap 的 tradeoff**:让 load 方向更简单(just decompress,不分配),代价是 store 方向更贵(compress + zsmalloc,GFP_KERNEL 可能阻塞) + pool 满时惩罚性写盘。

**选哪个的参数**:
- **demote 频繁、promote 少见**(冷数据下沉):cram 占优
- **store 和 load 都频繁**(热数据颠簸):zswap load 不阻塞的优势放大
- **大页占比高**:cram 有明显优势(zswap 不支持)
- **不希望有 swap 设备**:cram 是唯一选项
- **元数据敏感**(TB 级设备):cram 复用 `struct page` 开销更低

---

### 11. 入口分析的代码位置索引

| 功能 | 文件:行 | 函数 |
|------|--------|------|
| demotion 门控 | `mm/vmscan.c:352` | `can_demote()` |
| folio 收集 | `mm/vmscan.c:1302` | `shrink_folio_list()` |
| demotion 分发 | `mm/vmscan.c:1033` | `demote_folio_list()` |
| demotion 目标建立 | `mm/memory-tiers.c:420` | `establish_demotion_targets()` |
| 目标随机选择 | `mm/memory-tiers.c:333` | `next_demotion_node()` |
| 目标刷新 | `mm/memory-tiers.c:886` | `memory_tier_refresh_demotion()` |
| 通用迁移调度 | `mm/migrate.c:2215` | `migrate_folios_to_node()` |
| move_pages 入口 | `mm/migrate.c:2238` | `do_move_pages_to_node()` |
| migrate_pages 入口 | `mm/mempolicy.c:1341` | `migrate_to_node()` |
| mbind 入口 | `mm/mempolicy.c:1511` | `do_mbind()` |
| swapin 分配 | `mm/memory.c:4448` | `__alloc_swap_folio()` |
| NUMA balancing(迁出) | `mm/migrate.c:2737` | `migrate_misplaced_folio()` |
| cram demote 执行 | `mm/cram.c:174` | `cram_migrate_to()` |
| cram 目标分配 | `mm/cram.c:126` | `alloc_cram_folio()` |
| cram promote | `mm/cram.c:229` | `cram_fault()` |
| cram 提升分配 | `mm/cram.c:161` | `alloc_cram_promote_folio()` |
| cram 背压 | `mm/cram.c:452` | `cram_set_pressure()` |
| 分配器门控 | `mm/page_alloc.c:3696` | `numa_zone_alloc_allowed()` |
| private node zonelist | `mm/page_alloc.c:5698` | `build_zonelists()` |
| zswap store | `mm/zswap.c:1494` | `zswap_store()` |
| zswap load | `mm/zswap.c:1600` | `zswap_load()` |
| zswap 压缩 | `mm/zswap.c:854` | `zswap_compress()` |
| zswap 解压 | `mm/zswap.c:933` | `zswap_decompress()` |
| zswap 溢写 | `mm/zswap.c:1000` | `zswap_writeback_entry()` |
| node_private ops 定义 | `include/linux/node_private.h:123` | `struct node_private_ops` |
| NP_OPS_* 标志 | `include/linux/node_private.h:140` | — |
