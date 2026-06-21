# Private Memory Nodes (w/ Compressed RAM) 补丁分析

> **来源**:Gregory Price `<gourry@gourry.net>`,`[LSF/MM/BPF TOPIC][RFC PATCH v4 00/27] Private Memory Nodes (w/ Compressed RAM)`,2026-02-22
> **Cover msgid**:`20260222084842.1824063-1-gourry@gourry.net`
> **分析日期**:2026-06-21
> **规模**:27 patches,54 files,+4057 / -152
>
> **本地仓库状态**(`/home/wz/linux_private_node`):
> - 用 `b4 am` 下载;直接打在 7.1-rc6(master)上失败(仅 5/27 可 apply,核心 mm 文件已 diverge)。
> - 按系列真正的 base 应用:base = 作者 GitHub 分支 `gourryinverse/linux:private_compression` 中第一个 PMN 补丁的父提交 `13d776705623`(= `cxl/next` + 作者的 CXL housecleaning 补丁)。
> - `git am` 后 **27/27 干净应用**,结果 tree 与作者分支(本地 ref `gourry_pmn`)**逐字节一致**。
> - 已应用到 **`private_node`** 分支。还原:`git branch -f private_node f5e5d3509bff`。

---

> **配套文档**:[[Private_Memory_Nodes_入口分析与zswap对比]]——demote 全链路入口分析 与 zswap 技术+性能对比

---

## 0. 一句话概括

引入新的 NUMA node 状态 **`N_MEMORY_PRIVATE`**:由 buddy 分配器正常管理(真 `struct page`/folio、有 NUMA 拓扑、可进 LRU/reclaim/compaction),**但默认对一切普通分配不可达**;再通过一张 per-node 回调表 `node_private_ops` + 一组 `NP_OPS_*` 能力位,**有选择地、逐个子系统**地把它放进 mm/ 的某些服务。配套给出一个完整应用 `mm/cram.c`(压缩内存)作为压机样例。

核心思想:**先隔离,再在隔离上"按需打洞"**。

---

## 1. 背景与动机:为什么现有机制不够

驱动想让"非通用内存"(CXL 内存、加速器内存、带内联压缩的内存)享受 mm/ 服务,今天只有两条路:

| 方案 | 问题 |
|---|---|
| **ZONE_DEVICE**(自管理内存) | 每个想要的服务(分配、迁移、回收……)都要在驱动里**重新实现**;受 `struct page` 元数据限制;`pgmap` 这套越堆越大("ZONE_DEVICE boondoggle")。 |
| **热插进 `N_MEMORY`** | 能用真 `struct page`,但**挡不住普通分配**落上去——对"会撒谎的设备"是致命的。 |

两者都给不了真正想要的两件事:
1. 把这块内存从通用分配中**隔离**;
2. 同时**有选择地参与** mm/ 子系统。

**压缩内存的特殊难点**(本系列的主驱动场景):压缩设备对外**谎报容量**(报得比物理实际大)。若写入速度超过 OS 回收速度,真实后备耗尽 → 数据损坏 / 宕机。作者称之为"**追着你跑的熊**"(Out Run A Bear):一个"必须跑得比熊快才稳定"的系统是不可接受的。

---

## 2. 核心抽象

### 2.1 数据结构(均挂在 `pgdat`,RCU 保护)

```c
/* include/linux/node_private.h */

struct node_private {            /* 驱动分配、驱动持有 */
    void               *owner;
    refcount_t          refcount;        /* 1=已注册;>1=可睡眠回调的临时引用;0=可释放 */
    struct completion   released;        /* refcount 归零时触发,unregister 等待它 */
    const struct node_private_ops *ops;  /* 注册 ops 前为 NULL */
    bool                migration_blocked;/* 背压:服务示意暂停迁入 */
};

struct node_private_ops {        /* 回调表 —— 刻意镜像 ZONE_DEVICE 的 pgmap hook */
    bool       (*free_folio)(struct folio *);                 /* ~ free_zone_device_page() */
    void       (*folio_split)(struct folio *, struct folio *);/* huge page 拆分通知 */
    int        (*migrate_to)(struct list_head *, int nid, ...);/* 自定义"迁入本 node" */
    void       (*folio_migrate)(struct folio *src, *dst);    /* 迁移后位置变更通知 */
    vm_fault_t (*handle_fault)(struct folio *, struct vm_fault *, enum pgtable_level);
    void       (*reclaim_policy)(int nid, struct node_reclaim_policy *);
    void       (*memory_failure)(struct folio *, unsigned long pfn, int mf_flags);
    unsigned long flags;         /* NP_OPS_* 能力位 */
};
```

`pgdat` 新增两个字段(`include/linux/mmzone.h`):

```c
#ifdef CONFIG_NUMA
    struct memory_tier __rcu *memtier;
    struct node_private __rcu *node_private;   /* RCU 保护的回调容器 */
    bool                      private;          /* online_pages 据此置 N_MEMORY_PRIVATE */
#endif
```

### 2.2 统一谓词:收编而非新增

```c
static inline bool folio_is_private_managed(struct folio *folio)
{
    return folio_is_zone_device(folio) || folio_is_private_node(folio);
}
```

绝大多数集成点因此变成**一行替换**,而不是新增 call-site:

```c
- if (folio_is_zone_device(folio))
+ if (unlikely(folio_is_private_managed(folio)))
```

这是整个系列保持"侵入面最小"的关键手法——回调插入点全部对齐 ZONE_DEVICE 既有 hook。

---

## 3. 机制一:隔离(把内存挡在外面)

三道闸叠加:

**(1) `__GFP_PRIVATE`(patch 2)** —— 复用旧的 `0x200` 空闲 GFP 位:
```c
#define GFP_PRIVATE  (__GFP_PRIVATE | __GFP_THISNODE)
```
没有任何现存分配路径设此 flag ⇒ private node **默认零可达**。

**(2) `numa_zone_alloc_allowed()`(patch 3)** —— 把散落 3 处的 open-coded cpuset 过滤统一:
```c
bool numa_zone_alloc_allowed(int alloc_flags, struct zone *zone, gfp_t gfp_mask)
{
    /* 关键:即使没有 cpuset,也用 __GFP_PRIVATE 门控 private zone */
    if (!(gfp_mask & __GFP_PRIVATE) &&
        node_state(zone_to_nid(zone), N_MEMORY_PRIVATE))
        return false;

    if (cpusets_enabled() && (alloc_flags & ALLOC_CPUSET))
        return cpuset_zone_allowed(zone, gfp_mask);
    return true;
}
```
替换点:`get_page_from_freelist()` / `should_reclaim_retry()` / `alloc_pages_bulk_noprof()`。

**(3) `build_zonelists()`(patch 4)**:
- N_MEMORY 节点的 fallback 列表**剔除** private node;
- private node 主 fallback = `[自己, 然后 N_MEMORY]`(代表它做的内核/slab 分配可回退 DRAM);
- 它的 NOFALLBACK(thisnode)列表 = **仅自己**。

**(4) 状态互斥**:`N_MEMORY` 与 `N_MEMORY_PRIVATE` 互斥。注册时若 node 已是 N_MEMORY → `-EBUSY`;`online_pages()` 据 `pgdat->private` 二选一置位。

---

## 4. 机制二:逐项"打洞"(`NP_OPS_*`)

驱动只 opt-in 自己需要的子系统:

| Flag | 含义 | Patch |
|---|---|---|
| `NP_OPS_MIGRATION` | 迁入/迁出(须 `migrate_to`+`folio_migrate`) | 12 |
| `NP_OPS_MEMPOLICY` | mbind/mempolicy 定向分配与迁移 | 13 |
| `NP_OPS_DEMOTION` | 作为 memory-tiers 的 demotion 目标 | 14 |
| `NP_OPS_PROTECT_WRITE` | 禁止把 PTE/PMD 升级为可写 | 15 |
| `NP_OPS_RECLAIM` | 参与 kswapd / 直接回收 | 16 |
| `NP_OPS_OOM_ELIGIBLE` | = `RECLAIM\|DEMOTION`,计入 OOM 压力 | 17 |
| `NP_OPS_NUMA_BALANCING` | NUMA balancing 扫描/迁移 | 18 |
| `NP_OPS_COMPACTION` | compaction(服务须自启 kcompactd) | 19 |
| `NP_OPS_LONGTERM_PIN` | RDMA/VFIO 长期 pin | 20 |

**`node_private_set_ops()` 的依赖校验**(`drivers/base/node.c`):
- `MIGRATION` ⇒ 必须提供 `migrate_to` 且 `folio_migrate`;
- `MEMPOLICY` / `NUMA_BALANCING` / `COMPACTION` ⇒ 必须先有 `MIGRATION`;
- `MEMPOLICY` 与 `PROTECT_WRITE` **互斥**(只读内存不能被 mempolicy 任意写)。

**另一侧(patch 5–11)**:对**不支持的操作统一跳过**——mlock / madvise / KSM / khugepaged 用 `folio_is_private_managed()` 把原 zone_device 检查一起收编;另加 `free_folio`、`folio_split` 两个通知回调。

### demotion 集成示例(patch 14)
```c
/* establish_demotion_targets():把 opt-in 的 private node 纳入 demotion 候选 */
all_memory = node_states[N_MEMORY];
for_each_node_state(node, N_MEMORY_PRIVATE)
    if (node_private_has_flag(node, NP_OPS_DEMOTION))
        node_set(node, all_memory);
```
服务在 set/clear ops 后调用 `memory_tier_refresh_demotion()` 重建目标。

---

## 5. 生命周期与并发(最微妙的正确性部分)

### 5.1 注册顺序(`add_private_memory_driver_managed`,patch 22)
1. `node_private_register()`:在 `mem_hotplug_begin` + `node_private_lock` 下设 `pgdat->node_private` 与 `pgdat->private=true`;校验 N_MEMORY 互斥;一个 node 只允许一个 driver 注册。
2. `__add_memory_driver_managed()`:热插内存。
3. `online_pages()`:见 `pgdat->private` ⇒ 置 **`N_MEMORY_PRIVATE`** 而非 N_MEMORY,且**不启动 kswapd/kcompactd**(留给服务自己决定)。

### 5.2 拆除(逆序)
1. `offline_pages()`:最后一个 block 下线时**自动清** `N_MEMORY_PRIVATE`。
2. `node_private_unregister()`:仍是 N_MEMORY_PRIVATE 则 `-EBUSY`;否则清指针并 `wait_for_completion(released)` **等所有临时引用 drain**。
3. `do_migrate_range()` 对"不可迁移的 private node"在热拔时 `WARN_ONCE`(驱动有责任先保证内存可拔)。

### 5.3 RCU + refcount:三类回调(头文件注释已规范)
- **folio-referenced**:调用者持有该 node 上 folio 的引用 ⇒ 已 pin 内存,回调前可放 RCU。(`free_folio`/`folio_split`/`folio_migrate`/`handle_fault`/`memory_failure`)
- **refcounted**:源 folio 在别的 node(如**迁入**本 node),不 pin 本 node ⇒ 在 RCU 下 `refcount_inc_not_zero` 取临时引用,使结构与**模块**在回调期间不被卸载。(`migrate_to`,见 `node_private_migrate_to()`)
- **non-folio**:全程持 `rcu_read_lock`,**回调不得睡眠**。(`reclaim_policy`)

```c
/* node_private_migrate_to():refcounted 回调的标准舞步 */
rcu_read_lock();
np = rcu_dereference(NODE_DATA(nid)->node_private);
if (!np || !np->ops || !np->ops->migrate_to ||
    !refcount_inc_not_zero(&np->refcount)) { rcu_read_unlock(); return -ENODEV; }
fn = np->ops->migrate_to;
rcu_read_unlock();
ret = fn(folios, nid, mode, reason, nr_succeeded);     /* 可睡眠 */
if (refcount_dec_and_test(&np->refcount)) complete(&np->released);
```

---

## 6. 压机样例:CRAM(`mm/cram.c`,~350 功能行)

核心策略:**所有压缩内存一律只读映射**,从根本上消灭"背着分配器的写"。

```c
static const struct node_private_ops cram_ops = {
    .handle_fault   = cram_handle_fault,
    .migrate_to     = cram_migrate_to,
    .folio_migrate  = cram_folio_migrate,
    .free_folio     = cram_free_folio_cb,
    .reclaim_policy = cram_reclaim_policy,
    .flags = NP_OPS_MIGRATION | NP_OPS_DEMOTION | NP_OPS_NUMA_BALANCING |
             NP_OPS_PROTECT_WRITE | NP_OPS_RECLAIM,
};
```

闭环:

1. **进(只能靠回收 demotion)**:`cram_migrate_to()` 复用 `migrate_pages()`;到达时由 `fixup_migration_pte` 写保护 PTE,`PROTECT_WRITE` hook 阻止任何静默升级 ⇒ **设备永远看不到写**。
2. **写 → 出(promote)**:写错误命中 `handle_fault`=`cram_fault()`,在 PTL 下 `folio_isolate_lru` 串行化多 CPU 竞争,释放 PTL 后**同步迁回本地 DRAM**;失败 putback + 返回 `VM_FAULT_RETRY`(避免在写保护项上 tight livelock)。
3. **背压(防熊笼)**:`cram_set_pressure()` 把设备真实利用率换算成 `zone->watermark_boost` 唤醒 kswapd;满压置 `migration_blocked` 停止迁入(`cram_migrate_to` 返回 `-ENOSPC`)。压力大 ⇒ 停 demote、转激进 evict。
4. **回收**:`reclaim_policy` 声明 `may_swap/may_writepage/managed_watermarks=true`,服务自管 boost;private node 上的 folio 被 kswapd 老化后**走 swap**(对 private node 抑制再 demote,它是终端 tier)。
5. **释放**:`free_folio`=`cram_free_folio_cb()` 还给 buddy 前 **scrub**(清零或交设备 flush)。

> "没有熊可追"——只读模型把"写驱动的失控压缩"这件事彻底从分配器背后挪到 `handle_fault` 这条受控路径上。
>
> 未来若放宽只读(允许可写比例),代价约为 **32MB DRAM / 1TB CRAM**(1 bit / 4KB page),作者认为基于这套 ops 改动很小。

---

## 7. 补丁分组地图(27 patches)

> 下列哈希为本地 `private_node` 分支(`git am` 重建)的哈希。

**核心私有节点基础设施(1–22)**

| # | hash | 主题 |
|---|---|---|
| 1 | `7e71ffaec678` | 引入 `N_MEMORY_PRIVATE` 脚手架(node state / `node_private*` / `node.c` 注册 API) |
| 2 | `fbed9d9eb60b` | `__GFP_PRIVATE` + cpuset 门控 |
| 3 | `eadb1d0c61b8` | `numa_zone_allowed()` 统一过滤并接线 |
| 4 | `61149428ff27` | `build_zonelists` 的 private node 处理 |
| 5 | `c8961688f4bd` | `folio_is_private_managed()` 统一谓词 |
| 6 | `101a0a0f2ccc` | mlock 跳过 |
| 7 | `fe81eb0edb3f` | madvise 跳过 |
| 8 | `4d8f5002c642` | KSM 跳过 |
| 9 | `0b12f2dcf339` | khugepaged collapse 跳过 |
| 10 | `138d494c742c` | `free_folio` 回调(`__folio_put`/`folios_put_refs`) |
| 11 | `a7065f96502e` | `folio_split` 通知回调 |
| 12 | `e9db503e5b40` | **MIGRATION** —— 用户/内核迁移 |
| 13 | `7fa3aeac1677` | **MEMPOLICY** —— mbind/mempolicy |
| 14 | `4ba127d8e02a` | **DEMOTION** —— memory-tiers 目标 |
| 15 | `fb7f56bb74c4` | **PROTECT_WRITE** —— 禁止写升级 |
| 16 | `fcd66632f68d` | **RECLAIM** —— 回收参与 |
| 17 | `bc2843c6e9a0` | **OOM_ELIGIBLE** —— OOM 压力计入 |
| 18 | `8dd6a0b622ae` | **NUMA_BALANCING** |
| 19 | `4c616a370359` | **COMPACTION** |
| 20 | `f4d1701fa5f3` | **LONGTERM_PIN** |
| 21 | `9c5dfe4aedfa` | `memory_failure` 回调 |
| 22 | `09f942ed174d` | 热插管线 `add_private_memory_driver_managed()` |

**应用:压缩内存(23)**

| 23 | `8b7e137dc1bc` | `mm/cram.c` 压缩内存子系统 |

**CXL 驱动样例(24–27)**

| 24 | `a54db9ca35fb` | `cxl/core`: `cxl_sysram` region type |
| 25 | `d93fbf442f2e` | `cxl/core`: `cxl_sysram` 的 private node 支持 |
| 26 | `8de059f4641a` | `cxl_mempolicy` 样例驱动(MIGRATION\|MEMPOLICY) |
| 27 | `ebee9835033a` | `cxl_compression` 样例驱动(通用) |

---

## 8. 与 ZONE_DEVICE 对比

| 维度 | ZONE_DEVICE | N_MEMORY_PRIVATE |
|---|---|---|
| `struct page` | 受限(pgmap 元数据) | 真 page/folio,无限制 |
| 分配器 | 驱动自实现 | 复用 buddy |
| NUMA 拓扑 | 无 | 免费获得 |
| reclaim/compaction/LRU | 自己造 | 复用,flag 门控 |
| 隔离粒度 | 设备 | node |
| 回调粒度 | `pgmap`(设备级) | `node_private_ops`(node 级) |

作者主张:这套**有望取代多数 DEVICE_COHERENT 用户**,免去每驱动一套分配器+迁移代码。

---

## 9. 评价 / 讨论点 / ARM64 角度

- **最大争议**(作者自列 #1):该用新 node state 还是扩展 ZONE_DEVICE?讨论串里 David Hildenbrand、Alistair Popple、Balbir Singh、Vlastimil Babka 深度参与,焦点正在此。
- **复杂度真相**:CRAM 仅 ~350 行的前提,是 mm/ 里多了一层 `node_private_ops` 间接 + RCU/refcount 协议。该协议(拆除 drain、回调睡眠约束、`migrate_to` 的 refcount 舞步)是 review 的真正难点。
- **可疑/待验证点**:
  - `cram_fault()` 失败路径返回 `VM_FAULT_RETRY` 的活锁规避是否在所有 arch fault handler 上成立。
  - private node 上 kswapd 由服务 `kswapd_run(nid)` 自启,而 demotion 对 private node 抑制——"终端 tier + 自管 watermark_boost"的交互需在真实压力下验证。
  - `numa_zone_alloc_allowed` 现在对**每个** zonelist 迭代都查 `node_state(N_MEMORY_PRIVATE)`,普通系统(无 private node)上的开销需关注。
- **ARM64 / KVM 角度**(与本机日常相关):纯 mm/ 系列,不碰 KVM;但 **Zenghui Yu(ARM64 KVM)在 2026-06-12 参与讨论**。"buddy 管理但隔离 + 按需打洞"的范式,对 guest_memfd / CXL 内存做 VM 后备、机密 VM 内存管理是值得关注的方向。

---

## 10. 复现步骤

```bash
# 1. 下载
b4 am -o /tmp/pmn 20260222084842.1824063-1-gourry@gourry.net

# 2. 对齐 base(作者用 cxl/next + housecleaning)
git fetch --no-tags https://github.com/gourryinverse/linux \
    private_compression:refs/heads/gourry_pmn
#    第一个 PMN 补丁的父提交即 base:
BASE=$(git rev-list -n1 gourry_pmn --grep='numa: introduce N_MEMORY_PRIVATE')^
#    本仓库中 BASE = 13d776705623

# 3. 应用
git checkout -b private_node $BASE
git am --whitespace=nowarn /tmp/pmn/v4_*.mbx     # 27/27 干净
```

---

## 来源

- RFC v4 cover letter:<https://lore.kernel.org/all/20260222084842.1824063-1-gourry@gourry.net/>
- 作者完整分支:<https://github.com/gourryinverse/linux/tree/private_compression>
- David Hildenbrand 回复:<https://lkml.org/lkml/2026/2/23/847>
- Alistair Popple 回复:<https://lkml.org/lkml/2026/2/24/338>
