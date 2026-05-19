ARM64 KVM Stage-2 Contiguous Hugetlb 支持
===========================================

- v0.1 2026.05.09 Sherlock init
- v0.2 2026.05.13 Sherlock partial range + unmap analysis
- v0.3 2026.05.18 Sherlock 修正锁文档：wrprotect/test_clear_young为write_lock（非read_lock），map/relax_perms恢复为read_lock（kvm_fault_lock）
- v0.4 2026.05.19 Sherlock 重写5.4.3.1：确认vma_pagesize不一致的唯一来源是force_pte（SRCU窗口），mprotect/madvise/THP不改变hugetlb VMA类型

简介：分析ARM64 KVM Stage-2对contiguous PTE的软件支持逻辑。

## 1. 概述

ARM64硬件支持通过设置PTE的BIT(52)(CONT bit)将连续N个PTE合并为一个TLB entry，减少
TLB占用，提升hugetlb场景性能。本实现在KVM Stage-2页表中启用该硬件能力，覆盖map、
unmap、属性更新(wrprotect/mkyoung/relax_perms)三个核心操作路径。

## 2. 背景

### 2.1 ARM64 Contiguous PTE硬件机制

ARM64架构支持contiguous bit(BIT 52)，当满足以下条件时，硬件可将连续的一组PTE视为
单个TLB entry:

- 所有PTE指向物理地址连续且自然对齐的页面
- 所有PTE的属性（权限、内存类型等）完全一致
- 每个PTE的BIT(52)置为1

连续PTE的数量由CONT_PTES、CONT_PMD决定，各种基础页下定义的全集是：
```
  ====== ========   ====    ========    ===
  -      CONT PTE    PMD    CONT PMD    PUD
  ====== ========   ====    ========    ===
  4K:         64K     2M         32M     1G
  16K:         2M    32M          1G
  64K:         2M   512M         16G
  ====== ========   ====    ========    ===
```
如上CONT PTE、CONT PMD就是contig hugetlb的大小。

**注意**: 硬件对contiguous区域内任意一个PTE的写操作，在TLB缓存了该区域的情况下视为
不可预测行为。因此任何修改都必须走完整的BBM(Break-Before-Make)流程。

**注意**: contig地址的IPA和物理地址都必须对齐到CONT_PTE_SIZE。

### 2.2 Stage-2页表需求

KVM Stage-2页表负责IPA(Intermediate Physical Address) → PA(PhysicalAddress)的转换。
当Guest使用hugetlb时，Stage-2映射也应尽可能使用大页/连续页以减少TLB miss。Host内核
本身对hugetlb使用contig bit，但KVM Stage-2此前未实现此支持。

**注意**: ARM定义里block也是可以做contig hugetlb的，我们先看page的contig hugetlb
的支持逻辑，也就是说我们先只关注基础页作为页表叶子节点情况的contig hugetlb实现。

## 3. 整体架构

软件支持逻辑基本的考虑点如下：

1. 基础逻辑修改。现在所有stage2内存管理都没有考虑contig bit的情况，比如user_mem_abort
   的缺页逻辑，虽然有处理contig bit的情况，但是还是做了“force pte”的处理，需要修改
   这里的逻辑，把contig hugetlb这个信息传递下去。

2. 各种对stage2页表的修改都应该是一次修改所有contig PTE。这个需要我们：1. 修改
   所有stage2页表的修改点逻辑，2. 考虑修改页表时的互斥逻辑以及BBM逻辑，我们把这个
   点拆成如下两个点。

3. BBM逻辑。

4. 锁页表逻辑。

### 3.1 基础逻辑修改

user_mem_abort对于CONT_PTE_SIZE的情况之前是force到pte的，去掉这个限制，把CONT_PTE_SIZE
这个信息一路传递到stage2 map的逻辑。

### 3.2 所有对stage2页表的修改

stage2页表操作通过walker机制遍历页表，主要入口:

| 入口函数 | walker | 操作类型 | contig影响 |
|----------|--------|----------|------------|
| `kvm_pgtable_stage2_map()` | `stage2_map_walker` | 映射 | 支持设置CONT bit |
| `kvm_pgtable_stage2_unmap()` | `stage2_unmap_walker` | 取消映射 | 识别并清除contig block |
| `kvm_pgtable_stage2_wrprotect()` | `stage2_attr_walker` | 写保护 | 去掉CONT bit后重写 |
| `kvm_pgtable_stage2_mkyoung()` | `stage2_attr_walker` | 设置AF | 去掉CONT bit后重写 |
| `kvm_pgtable_stage2_relax_perms()` | `stage2_attr_walker` | 放宽权限 | 去掉CONT bit后重写 |
| `kvm_pgtable_stage2_test_clear_young()` | `stage2_age_walker` | 清除AF | lockless 时通过编译互斥禁用 contig；非 lockless 时 write_lock 排他安全 |
| `kvm_pgtable_stage2_set_owner()` | `stage2_map_walker` | 取消映射+标注 | 复用map路径，已覆盖 |
| `kvm_pgtable_stage2_flush()` | `stage2_flush_walker` | TLBI flush | 无修改 |
| `kvm_pgtable_stage2_destroy_range()` | `stage2_destroy_walker` | 销毁范围 | 无修改 |
| `kvm_pgtable_stage2_split()` | `stage2_split_walker` | 拆分block | 不涉及leaf contig |

基本的逻辑是修改页表的时候要满足如上硬件的约束。具体看就是：

1. map的时候一次修改所有contig的PTE。
2. 对于已经有contig bit的PTE，修改其中一个PTE时要把全部contig bit去掉。
3. BBM约束。

### 3.3 BBM与锁页表

详细设计见 5.3（BBM 流程）和 5.4（PTE[0]-as-block-lock 并发设计），关键竞态窗
口分析见 5.4.3 场景 1a。

## 4. 数据结构与常量定义

### 4.1 新增宏与枚举

```c
// kvm_pgtable.h — 硬件CONT bit
#define KVM_PTE_LEAF_ATTR_CONT   BIT(52)

// kvm_pgtable.h — 软件协议位(传递给stage2_set_prot_attr转换为硬件位)
KVM_PGTABLE_PROT_CONT           = BIT(6)
```

### 4.2 struct stage2_attr_data扩展

```c
struct stage2_attr_data {
    kvm_pte_t   attr_set;
    kvm_pte_t   attr_clr;
    kvm_pte_t   pte;
    s8          level;
+   struct kvm_s2_mmu *mmu;   // 新增: contig路径需要mmu以执行TLBI
};
```

## 5. 具体逻辑设计

### 5.1 基础逻辑修改

`user_mem_abort()`中`CONT_PTE_SHIFT`分支(`arch/arm64/kvm/mmu.c`):

```c
case CONT_PTE_SHIFT:
    if (fault_supports_stage2_huge_mapping(memslot, hva, CONT_PTE_SHIFT)) {
        prot |= KVM_PGTABLE_PROT_CONT;         // 请求contig映射
        vma_shift = CONT_PTE_SHIFT;            // 使用contig大页
        break;
    } else {
        vma_shift = PAGE_SHIFT;                // fallback到4K
        force_pte = true;
    }
    fallthrough;                               // 进入PAGE_SHIFT处理
```

决策逻辑:

1. `fault_supports_stage2_huge_mapping()`检查: memslot基地址对齐、HVA对齐、
   VMA大小 >= CONT_PTE_SIZE
2. 条件满足 → 设置`KVM_PGTABLE_PROT_CONT`，告知后续map流程使用contig路径
3. 条件不满足 → 退化到4KB单页映射

### 5.2 所有对stage2页表的修改

综上具体代码修改要考虑的walker有：

1. stage2_map_walker
2. stage2_unmap_walker
3. stage2_attr_walker
4. stage2_age_walker(todo)

需要考虑如上列出的所有stage2 map行为和contig bit一起工作的时候是否会有问题。
(理解如下的分析，需要先理解KVM stage2 walk的基本逻辑，具体可以参考[这里](todo))

#### 5.2.1 请求地址从contig block中间进入

kvm_pgtable_stage2_map时，user_mem_abort的逻辑中会把fault的地址对齐到指定地址，
walker的时候一次处理一批PTE，然后把处理地址跳过这一批PTE对应的地址。

kvm_pgtable_stage2_unmap / kvm_pgtable_stage2_wrprotect / kvm_pgtable_stage2_mkyoung /
kvm_pgtable_stage2_relax_perms:

传入的地址没有做`CONT_PTE_SIZE`对齐处理。用户请求的`[addr, addr+size)`可能只覆盖
一个contig block的一部分PTE。直接对整个block应用操作会越界（unmap多解了别人的映射、
wrprotect写保护了其他PTE、relax_perms放宽了其他PTE的权限——后者是安全问题）。

对一个contig block的部分PTE做修改是与硬件CONT约束冲突的——硬件要求block内N个PTE的
属性完全一致。因此partial操作必须先"unfold"该block（清除N个PTE上的CONT位），让block
退化为N个独立PTE，再按用户范围对每个PTE分别处理。

walk中`[addr, addr+size]`可能跨越多个contig block。处理策略按block分类：

- **完整覆盖的contig block**（`[ctx->start, ctx->end)` ⊇ `[block_start, block_end)`）：
  走快速路径，一次对整个block做BBM，**保留CONT位**——对attr路径所有N个PTE应用同一份
  新attrs；对unmap路径所有N个PTE做put_page。TLB优化得以保留。
- **部分覆盖的contig block**（walker从block中部进入或block跨过了`ctx->end`）：走
  unfold路径，BBM清空整个block后，范围内PTE应用新attrs / put_page，范围外PTE保留
  原mapping但去掉CONT位。范围外PTE失去contig TLB优化，未来访问时fault handler可
  重新建立contig映射。

#### 5.2.2 页表遍历地址跳过修复

KVM页表walker`__kvm_pgtable_visit()`在遍历叶子级PTE时，每个PTE处理后`data->addr`
递增`kvm_granule_size(level)`(即PAGE_SIZE)。但当PTE具有CONT位时，该PTE实际覆盖
CONT_PTE_SIZE(CONT_PTES * PAGE_SIZE)的地址范围，walker只跳一个PAGE_SIZE会导致同一
contig block内的后续PTE被重复处理。

进一步地，对于unmap/wrprotect/mkyoung/relax_perms这些路径，调用者传入的`addr`并
不保证对齐到`CONT_PTE_SIZE`，walker可能从一个contig block的中间进入。此时如果只按
`PAGE_SIZE`对齐再加`CONT_PTE_SIZE`，跳完之后`addr`会落到下一个contig block的中间，
导致后续PTE跳过/重复处理。

修复逻辑:

```c
bool is_old_contig = ctx.old & KVM_PTE_LEAF_ATTR_CONT;   // 捕获旧值

// ... 执行visit callback ...

if (!table) {
    if (ctx.old & KVM_PTE_LEAF_ATTR_CONT || is_old_contig) {
        /* 先按contig block大小对齐，再跳过整个block */
        data->addr = ALIGN_DOWN(data->addr,
                                kvm_granule_size(level) * CONT_PTES);
        data->addr += kvm_granule_size(level) * CONT_PTES;
    } else {
        data->addr = ALIGN_DOWN(data->addr, kvm_granule_size(level));
        data->addr += kvm_granule_size(level);
    }
    goto out;
}
```

### 5.3 BBM逻辑

BBM流程:
```
Step 1: cmpxchg(PTE[0], ctx->old, KVM_INVALID_PTE_LOCKED)
          ├─ FAIL  → return -EAGAIN       // walker层重试
          └─ OK    → continue

Step 2: for i = 1 .. CONT_PTES-1:
            PTE[i] = INVALID              // put_page if counted

Step 3: TLBI range [ctx->addr, ctx->addr + CONT_PTE_SIZE)

Step 4: for i = 1 .. CONT_PTES-1:
            new = kvm_init_valid_leaf_pte(phys[i], attr, level)
            smp_store_release(&PTE[i], new)
            get_page

Step 5: smp_store_release(&PTE[0], new)   // PTE[0]最后写入，作为"go"信号
        get_page
```

设计要点:

- PTE[0]最后写入且使用`smp_store_release`: 确保硬件看到PTE[0]时，PTE[1..N-1]已经全部可见
- 用`KVM_INVALID_PTE_LOCKED`做cmpxchg锁: 与已有单页BBM的锁机制一致

### 5.4 一次修改一批PTE的加锁逻辑

#### 5.4.1 总体并发建模

KVM stage-2 的并发隔离靠两样东西：**`kvm->mmu_lock`（rwlock）** 保证软件 walker
之间不冲突，**per-PTE cmpxchg（`KVM_INVALID_PTE_LOCKED`）** 保证同一条读锁路径内的
walker 在对同一个 PTE 进行 BBM 时串行化。`KVM_PGTABLE_WALK_SHARED` 只是 walker
内部行为开关（RCU 解引用、cmpxchg vs WRITE_ONCE），**本身不加锁**。

综合入口 API、触发源、持锁、SHARED 语义和 contig 并发策略的完整视图：

| 入口 API | 操作 | 触发源 | walker | 持锁 | SHARED | set_pte | 并发 reader | contig 策略 |
|----------|------|--------|--------|------|--------|---------|------------|-------------|
| `stage2_map` | 缺页映射 | fault (`user_mem_abort`) | map_walker | `read_lock` | ✅ | cmpxchg | ✅ | contig_leaf / PTE[0]检查 |
| `stage2_set_owner` | pKVM owner 标记 | pKVM EL2 | map_walker | exclusive | ❌ | WRITE_ONCE | ❌ | 不冲突 |
| `stage2_relax_perms` | 放宽权限 | fault（写故障） | attr_walker | `read_lock` | ✅ | cmpxchg | ✅ | contig_leaf / PTE[0]检查 |
| `stage2_mkyoung` | 设 AF | fault（AF 故障） | attr_walker | `read_lock` | ✅ | cmpxchg | ✅ | contig_leaf / PTE[0]检查 |
| `stage2_wrprotect` | 写保护 | 系统调用（dirty log） | attr_walker | `write_lock` | ❌ | WRITE_ONCE | ❌ | contig_leaf / PTE[0]检查¹ |
| `stage2_test_clear_young` | 清 AF + 老化 | MMU notifier | age_walker | `write_lock` / lockless² | ❌ | WRITE_ONCE | ❌/✅² | lockless 时编译互斥禁用 contig³ |
| `stage2_unmap` | 取消映射 | 系统调用 / pKVM | unmap_walker | `write_lock` | ❌ | WRITE_ONCE | ❌ | contig unmap |

> ¹ wrprotect 持有 `write_lock` 排他，与其他 walker 无并发。attr_walker 中的
> PTE[0] 检查对 wrprotect 本身不提供并发保护（无需保护），但 wrprotect 走同一
> walker 代码路径，PTE[0] 检查无害。
>
> ² test_clear_young 的持锁取决于 `CONFIG_KVM_MMU_LOCKLESS_AGING`：
> 默认走 `KVM_MMU_LOCK(kvm)` = `write_lock`；lockless 配置下无锁。lockless
> 时 age_walker 会与 read_lock 下的 fault 路径并发，存在竞态。
>
> ³ lockless 路径下 age_walker 会破坏 contig 属性一致性，已通过在
> `user_mem_abort` 中增加 `IS_ENABLED(CONFIG_KVM_MMU_LOCKLESS_AGING)` 检查，
> 编译时互斥解决：lockless 启用时禁止创建 contig 映射。

并发视图：

```
read_lock(&kvm->mmu_lock)                                // fault 路径，共享
  ├─ map:               SHARED, cmpxchg     → 互相并发，走 PTE[0] 互斥
  ├─ relax_perms:       SHARED, cmpxchg     → 与 map/mkyoung 并发，走 PTE[0] 互斥
  └─ mkyoung:           SHARED, cmpxchg     → 与 map/relax_perms 并发，走 PTE[0] 互斥

write_lock(&kvm->mmu_lock)                               // 系统调用路径，排他
  ├─ wrprotect:         非SHARED, WRITE_ONCE → 无并发，PTE[0] 检查代码无害
  ├─ test_clear_young:  非SHARED, WRITE_ONCE → 无并发（非lockless）；lockless 时编译互斥禁用 contig
  └─ unmap:             非SHARED, WRITE_ONCE → 无并发，contig unmap
```

#### 5.4.2 unmap路径无并发问题

contig BBM在unmap路径上不会与其他walker race，原因是unmap的调用方必须持有
`kvm->mmu_lock`写锁，rwlock语义保证写锁排他。

#### 5.4.3 contig BBM的per-PTE 锁分析

当前 contig BBM 只对 `PTE[0]` 做 `cmpxchg → LOCKED` 加锁，`PTE[1..N-1]` 在 Break 
阶段被直接写 0（`kvm_clear_pte`）。`PTE[k]`(k≠0)在 Break 到 Make 之间的窗口里既不
valid 也不 LOCKED，过不了任何并发保护。

**受影响的三处代码**：

| 函数 | Break 写法 | 路径 |
|------|-----------|------|
| `stage2_map_contig_leaf` | `kvm_clear_pte(ptep)` | map fresh contig |
| `stage2_attr_contig_aligned` | `kvm_clear_pte(ptep)` | attr 完整覆盖 |
| `stage2_attr_contig_unaligned` | `kvm_clear_pte(ptep)` | attr 部分覆盖 |

三处都是 T1 lock PTE[0] 后，T1 写 PTE[k]=0 + T2 登入 PTE[k] 的经典 race，
**aligned 分支不因"全 block 覆盖"而豁免**。

**race 时序**：

```
T1: 在某 contig block 上做 contig BBM
    cmpxchg(PTE[0], old0, LOCKED)        // OK
    kvm_clear_pte(PTE[k])                // PTE[k] = 0
    --- 此时窗口打开 ---
    TLBI block
    smp_store_release(PTE[k], 新值)      // 覆盖 T2 的 install！

T2: 同时在 PTE[k] 上做单页操作（map，走 SHARED walk）
    stage2_try_break_pte(ctx) {
        if (stage2_pte_is_locked(ctx->old))   // ctx->old=0，不是 LOCKED → 过
            return false;
        cmpxchg(ctx->ptep, ctx->old, LOCKED); // ctx->old=0, *ptep=0 → 成功
    }
    // T2 以为拿到了 PTE[k] 的 BBM 锁，install 新映射
```

T1 的 Make 阶段会把 T2 刚装的映射覆盖掉，**丢失更新**。

race 的双向破坏：

1. **T1 覆盖 T2**：T1 Make 阶段 `smp_store_release(PTE[k], 新值)` 覆写 T2 刚
   装的映射，T2 get_page 的 refcount 泄漏
2. **T1 读 T2**：`stage2_map_contig_leaf` 的 Break 阶段先读 `*ptep` 判断是否
   valid/counted 再做 put_page/clear，而 T2 正在改 PTE[k]，read-then-write
   之间无原子性，可能 put_page 指向 T2 刚装的页

两项是同一个 race 的两种表现，根因相同：PTE[k] 在 T1 锁住 PTE[0] 之后、写
最终值之前没有任何保护。

##### 5.4.3.1 冲突场景分析

本节**只分析问题**：contig BBM 与各条并发路径之间存在哪些竞态窗口。修复方案在
5.4.3.2 讨论。

**（一）race 根源**

contig BBM 的保护模型是：只对 `PTE[0]` 做 `cmpxchg → LOCKED`，对 PTE[1..N-1] 直接
`kvm_clear_pte`（`WRITE_ONCE(*ptep, 0)`）。PTE[k]（k≠0）在 Break 阶段既不 valid
也不 LOCKED，而 KVM 的 SHARED 路径依赖 LOCKED 做互斥——任何 SHARED 并发路径只要在
PTE[k] 上看到 LOCKED 之外的 "安全" 态（0 或 valid 非 LOCKED），就会认为无人操作而
继续。

```
T1: contig BBM                          T2: 在 PTE[k] 上做单页操作
    cmpxchg(PTE[0], old0, LOCKED) → OK      ↓
    kvm_clear_pte(PTE[k]) ───────────→  READ_ONCE(PTE[k]) = 0 或 valid_non_LOCKED
    (WRITE_ONCE, 无原子性)               → 认为安全，cmpxchg 成功 / WRITE_ONCE 执行
    ... TLBI ...                              ↓
    smp_store_release(PTE[k], new) ────→  结果被 T1 或 T2 覆盖
```

T2 的 "误判" 有两种：

| T2 读到的 PTE[k] | T2 的行为 | 后续冲突 |
|-----------------|----------|---------|
| valid（T1 清之前读到） | 认为可以安全修改，cmpxchg 成功 | T1 的 `kvm_clear_pte` 覆盖 LOCKED |
| 0（T1 清之后读到） | 认为空闲，cmpxchg(0, LOCKED) 成功 | T1 的 `smp_store_release` 覆盖 T2 的 make |

**（二）并发矩阵：T1 为 contig BBM，T2 为各路径**

T1 固定为 contig 块级操作（`stage2_map_contig_leaf` / `stage2_attr_contig_aligned` /
`stage2_attr_contig_unaligned`），均以 `cmpxchg(PTE[0], ...)` 为入口。以下按 T2
路径分类讨论。

| T2 路径 | 持锁 | 写 PTE 方式 | 与 T1 并发？ |
|---------|------|-----------|------------|
| map 单页（`stage2_map_walker_try_leaf`） | read_lock | cmpxchg（BBM） | ✅ 是 |
| attr mkyoung（`stage2_attr_walker`） | read_lock | cmpxchg（`stage2_try_set_pte`） | ✅ 是 |
| attr relax_perms（`stage2_attr_walker`） | read_lock | cmpxchg（`stage2_try_set_pte`） | ✅ 是 |
| attr wrprotect（`stage2_attr_walker`） | write_lock | WRITE_ONCE | ❌ 排他 |
| unmap（`stage2_unmap_walker`） | write_lock | WRITE_ONCE | ❌ 排他 |
| test_clear_young（`stage2_age_walker`） | write_lock / lockless | WRITE_ONCE | ❌/✅ |
| map contig / attr contig | read_lock | cmpxchg PTE[0] | ❌ PTE[0] 串行化 |

下面逐一分析有并发的路径。

**（三）SRCU 窗口与 vma_pagesize 不一致**

场景 1（map contig vs map 单页）的前提是两个 vCPU 对同一 contig block 得出不同的
`vma_pagesize`。这需要它们读到不同版本的 memslot flags。本节解释为什么这不但是可能的，
而且 KVM 的 SRCU 机制本身就允许这种短暂的不一致。

**为什么 memslot 数据需要 SRCU**：vCPU fault handler 通过 `gfn_to_memslot()` 读
memslot flags 时不持 `slots_lock`。如果 ioctl 线程直接原地修改 memslot，与 vCPU
的并发读就是 C 标准的 data race。vCPU 不能拿 `slots_lock`（mutex）的原因是：
fault handler 是每个缺页都要走的热路径，mutex 会严重降低多 vCPU 并发性能；且 fault
handler 在关中断上下文运行，mutex 可能在 atomic 上下文中睡眠。

**SRCU 如何保护**：ioctl 修改 memslot 时不原地写，而是准备新副本 → 更新 inactive
slots → `rcu_assign_pointer` 原子切换 active/inactive → `synchronize_srcu_expedited`
等老 reader 退出。`srcu_read_lock` 只递增 per-CPU 计数器，热路径开销可忽略。

**SRCU 的不一致窗口**：SRCU 保证每个 reader 读到的数据是**内部一致**的（要么全是旧版
本，要么全是新版本），但**不保证所有 reader 同时看到新版本**。

```
kvm_swap_active_memslots()
  rcu_assign_pointer(memslots[as_id], slots)
      ← SRCU 窗口开始 ─────────────────────┐
  slots_arch_lock 释放                       │ 新 reader: flags=0 → force_pte=false
  synchronize_srcu_expedited(&kvm->srcu)     │ 老 reader: flags=LOG → force_pte=true
      ← SRCU 窗口结束 ─────────────────────┘
```

**为什么 logging 关闭窗口里老 reader 不重试**：`user_mem_abort` 在拿到 mmu_lock 后
检查 `mmu_invalidate_retry`。但 logging 关闭时 `kvm_arch_commit_memory_region`
（disable 分支）只 free split_page_cache，不 bump `mmu_invalidate_seq`，不拿 mmu_lock。
所以老 reader 的 `mmu_invalidate_retry` 返回 false——不重试，带着 force_pte=true 继续。

对比 logging 开启：`kvm_arch_commit_memory_region`（enable 分支）调用
`kvm_mmu_wp_memory_region` → `write_lock(&kvm->mmu_lock)` → wrprotect 全范围。
write_lock 排他，fault 路径的 read_lock 全部挡在门外。等 write_unlock 后，老 reader
要么已通过 SRCU sync 退出，要么重入时看到新 flags。

**为什么原来没有这个问题**：原来 force_pte 差异导致的是跨层级分歧——老 reader 走 PTE
级（4K），新 reader 走 PMD 级（2M block mapping）。两者操作不同的页表 entry，不存在
同一条 entry 上的竞争。contig 是第一次把批量 PTE 操作（`kvm_clear_pte` 裸 WRITE_ONCE）
和单 PTE 操作（`cmpxchg`）放在了同一层级竞争。

**为什么 mprotect/madvise/THP 不会产生 vma_pagesize 不一致**：三者都不改变 hugetlb
VMA 的类型——mprotect 只改权限，madvise 只释放页但不改 VMA 属性，THP 是独立子系统
与 hugetlbfs 无交集。所有 fault 都在同一 hugetlb VMA 上，`get_vma_page_shift` 一致
返回 `CONT_PTE_SIZE`，都走 contig 路径，PTE[0] cmpxchg 串行化。vma_pagesize 不一致
的**唯一来源**是 `force_pte`（memslot logging flag），不是 VMA 变化。

**（四）场景 1：contig BBM vs map 单页 —— 核心竞态**

T1 走 contig BBM（`stage2_map_contig_leaf`），T2 走单页 BBM（`stage2_map_walker_try_leaf`），
同属 `user_mem_abort` map 路径，均持 `read_lock`。

**锁缺口**。Contig BBM 流程为：
```
Step 1: cmpxchg(PTE[0], old, LOCKED)            // 锁 block
Step 2: for k=1..N-1: WRITE_ONCE(PTE[k], 0)     // 清 PTE[k]——无锁
Step 3: TLBI block
Step 4: for k=1..N-1: smp_store_release(PTE[k], new)
Step 5: smp_store_release(PTE[0], new)
```
仅 PTE[0] 通过 cmpxchg 加锁，PTE[1..N-1] 在 Step 2~4 间既不 valid 也不 LOCKED。
KVM SHARED 路径以 LOCKED 为互斥信号——并发者在 PTE[k] 上见到非 LOCKED 即认为安全。
单页路径见 PTE[0]=valid 非 CONT，不锁 PTE[0]；但 T1 在 PTE[0] 上的 cmpxchg 可以
成功（PTE[0] 当前确是那个 valid 值）。两路在 PTE[k] 上无锁碰撞。

**触发条件**：T1 和 T2 对同一 contig-aligned 区域得出不同的 `vma_pagesize`——
T1=CONT_PTE_SIZE（prot 带 PROT_CONT，走 contig），T2=PAGE_SIZE（走单页）。
`vma_pagesize` 由 `force_pte ? PAGE_SHIFT : get_vma_page_shift(...)` 决定，
`force_pte = memslot_is_logging(memslot)`。

唯一触发源：dirty logging 关闭的 SRCU 窗口。QEMU 关闭 dirty logging 时
（`KVM_SET_USER_MEMORY_REGION2` 清 `KVM_MEM_LOG_DIRTY_PAGES`）：

```
kvm_swap_active_memslots()
  rcu_assign_pointer(kvm->memslots[as_id], slots)
      ← 新 reader: logging=false, force_pte=false → CONT_PTE_SIZE, 带 PROT_CONT
      ← 老 reader: logging=true,  force_pte=true  → PAGE_SIZE,  无 PROT_CONT
  mutex_unlock(&kvm->slots_arch_lock)
  synchronize_srcu_expedited(&kvm->srcu)
      ← 老 reader 全部退出
kvm_arch_commit_memory_region()  // disable: 不拿 mmu_lock，不 bump invalidate_seq
```

关键：disable 分支**不拿 mmu_lock**，老 reader 的 `mmu_invalidate_retry()` 为 false，
不重试，携 `force_pte=true` 继续。对比 logging 开启：enable 分支通过
`kvm_mmu_wp_memory_region` 拿 write_lock 排他，fault 路径全挡门外。

窗口内两 vCPU：

| | vCPU0（老 reader）= T2 单页 | vCPU1（新 reader）= T1 contig |
|---|---|---|
| force_pte | true → PAGE_SIZE | false → CONT_PTE_SIZE |
| prot | 无 PROT_CONT | 带 PROT_CONT |
| ctx->ptep | PTE[k]（k>0） | PTE[0] |
| 入口 | stage2_map_walker_try_leaf | stage2_map_contig_leaf |

两者 fault IPA 同在 contig block 内，在 PTE[k] 上冲突——T1 改全 block（含 PTE[k]），
T2 只改 PTE[k]。

**竞态时序**：
```
T1: stage2_map_contig_leaf()            T2: stage2_map_walker_try_leaf()
  cmpxchg(PTE[0], V, LOCKED) → OK         READ_ONCE(PTE[0]) → valid 非 CONT
  kvm_clear_pte(PTE[k]) ──┐               locked_pte0 = false（PTE[0] valid，不锁）
  (WRITE_ONCE, PTE[k]=0)  │               stage2_try_break_pte(PTE[k]):
                           │                 cmpxchg(PTE[k], Vk, LOCKED)
                           └── 竞态 ──────→
  ... TLBI ...                              ...
  smp_store_release(PTE[k], contig_new)     smp_store_release(PTE[k], single_new)
```

- **1a-1（安全）**：T1 `WRITE_ONCE(PTE[k], 0)` 先到 → T2 cmpxchg 因 0≠Vk 失败 → 退让。
  安全来自 per-PTE cmpxchg 固有串行化。
- **1a-2（丢失更新）**：T2 cmpxchg 先到 → PTE[k]=LOCKED → T1 `WRITE_ONCE(PTE[k], 0)`
  覆盖 LOCKED → T1 `smp_store_release(PTE[k], contig_new)` 覆盖 T2 安装 →
  **T2 映射丢失，refcount 泄漏**。即状态 3b。

**为什么原来没问题**：原来 force_pte 差异导致跨层级分歧——老 reader 走 PTE 级（4K），
新 reader 走 PMD 级（2M block）。两者操作不同 entry，无竞争。Contig 首次将批量 PTE
操作（裸 WRITE_ONCE）与单 PTE 操作（cmpxchg）放在同一层级。

**不受影响的路径**：mprotect/madvise/THP 不改变 hugetlb VMA 类型。同一 VMA 上所有
fault 一致返回 `CONT_PTE_SIZE`，都走 contig 路径，PTE[0] cmpxchg 天然串行化。
vma_pagesize 不一致的**唯一来源**是 `force_pte`（memslot logging flag）。

**结论**：场景 1a 是 contig BBM per-PTE 锁缺口的唯一可触发真实路径，可致丢失更新。
修复见 5.4.3.2。

**（五）场景 2：contig BBM vs attr mkyoung / relax_perms**

T2 走 `stage2_attr_walker`（read_lock, SHARED, cmpxchg），在 PTE[k] 上做属性更新
（`stage2_try_set_pte` = `cmpxchg(PTE[k], ctx->old, new_attr)`）。

关键：attr_walker 入口有 CONT 位检查（`ctx->old & CONT` → 走 contig 路径）。只有当
PTE[k] 的 CONT 位不存在时，T2 才走单页 attr 路径。因此此场景的前提是 **PTE[k] 无
CONT 位**。

**子场景 2a：T1 contig map 升级 vs T2 mkyoung 在 PTE[k] 上**

```
初始：PTE[0..N-1] 是 N 个独立 4K 映射（valid 非 CONT）。

T1: stage2_map_contig_leaf              T2: stage2_attr_walker (mkyoung)
    PTE[0] = valid 非 CONT                  ctx->old = READ_ONCE(PTE[k])
    cmpxchg(PTE[0], old, LOCKED) → OK         = valid 非 CONT（无 CONT 位）
    PTE[0] = LOCKED                           data->pte = old
                                              pte = old | AF
    kvm_clear_pte(PTE[k])                     data->pte != pte → 进入更新
    → WRITE_ONCE(PTE[k], 0)                   
        ↓                                    stage2_try_set_pte(PTE[k], pte):
        ┌─── 竞态 ───┐                          cmpxchg(PTE[k], old, pte|AF)
        │            │
```

**2a-1：T1 的 kvm_clear_pte 先到**
```
T1: WRITE_ONCE(PTE[k], 0)
T2: cmpxchg(PTE[k], old, pte|AF)    // *PTE[k]=0 ≠ old → 失败 → -EAGAIN ✓
```

**2a-2：T2 的 cmpxchg 先到**
```
T2: cmpxchg(PTE[k], old, pte|AF)    // OK，PTE[k] = old|AF（设了 AF）
T1: WRITE_ONCE(PTE[k], 0)           // 覆盖！清除 T2 的 AF 更新
T1: TLBI
T1: smp_store_release(PTE[k], contig_new)  // 最终值：contig 映射（AF 可能有/无）
                                            // T2 的 AF 设置丢失
```

**后果**：T2 的 AF 更新可能丢失。但由于 AF 本身是"best-effort"（硬件也可异步设 AF），
丢失一次 AF 仅意味着多一次 access fault，不影响正确性。

**子场景 2b：T1 contig map 升级 vs T2 relax_perms 在 PTE[k] 上**

与 2a 结构相同，但 T2 做的是权限放宽（如 RO → RW）：

**2b-2：T2 的 cmpxchg 先到**
```
T2: cmpxchg(PTE[k], old, pte|S2AP_W)  // OK，PTE[k] = RW
T1: WRITE_ONCE(PTE[k], 0)             // 覆盖！
T1: smp_store_release(PTE[k], contig_new)  // 最终值取决于 contig_new 的属性
```

后果取决于 contig_new 的权限：如果 contig_new 也是 RW（与 T2 一致），无功能影响；
如果 contig_new 是 RO（例如 guest 对同一 contig 块内不同页有不同权限），T2 放宽的
权限被 T1 覆盖为 RO——guest 下次写入触发正确 fault 重试。也不影响正确性。

**（六）场景 3：contig BBM vs test_clear_young（lockless）——已通过编译时互斥解决**

```
T1: contig BBM                          T2: stage2_age_walker (lockless)
    cmpxchg(PTE[0], old0, LOCKED) → OK      ctx->old = valid+CONT
    kvm_clear_pte(PTE[k])                     ↓
    → PTE[k] = 0                          无视 CONT，直接改 PTE[k] 的 AF：
                                              new = old & ~AF
    smp_store_release(PTE[k], contig_new)     WRITE_ONCE(PTE[k], new)
        ↓                                       ↓
```

两个子情况：

**3a：T2 的 WRITE_ONCE 在 T1 的 kvm_clear_pte 和 smp_store_release 之间**
```
T1: WRITE_ONCE(PTE[k], 0)
T2: WRITE_ONCE(PTE[k], (valid+CONT) & ~AF)  // 写回了一个有 CONT 位的值！
T1: smp_store_release(PTE[k], contig_new)    // 又覆盖掉
```
最坏：T2 写的值有 CONT 位（从 ctx->old 继承），对 T1 无影响（T1 后面覆盖）。

**3b：T2 的 WRITE_ONCE 在 T1 smp_store_release 之后**
```
T1: smp_store_release(PTE[k], contig_new)   // contig block 安装完成
T2: WRITE_ONCE(PTE[k], contig_new & ~AF)    // 修改了一个 contig PTE！
```
这破坏了 contig 硬件约束：block 内 N 个 PTE 的属性不再完全一致（PTE[k] 的 AF 位
与其他 PTE 不同）。**这是独立于 contig BBM 锁缺口之外的另一问题**——即使没有 T1
的并发 contig BBM，age_walker 独自操作一个已存在 contig block 内的单个 PTE 也是
非法的。

**修复方案：contig 与 lockless aging 编译时互斥**

为 age_walker 适配 contig 需要其识别 CONT 位并走完整的 BBM 流程（锁 PTE[0]、
清全部 N 个 PTE、TLBI、重写），改动范围大且 lockless 路径下同步复杂。当前选择
更简单的方案：`CONFIG_KVM_MMU_LOCKLESS_AGING` 启用时，禁止创建 contig 映射。

实现：在 `user_mem_abort` 的 `CONT_PTE_SHIFT` 分支（`mmu.c:1725`）增加
`IS_ENABLED(CONFIG_KVM_MMU_LOCKLESS_AGING)` 检查，lockless 配置下直接退化到
PAGE_SHIFT，不设置 `KVM_PGTABLE_PROT_CONT`。两个 config 符号均为 bool 类型，
编译时即可判定，无运行时开销。

**（七）场景 4：contig BBM vs contig BBM（无问题）**

两个 T 都走 contig 路径，都在 PTE[0] 上 cmpxchg。只有一个能赢，另一个 -EAGAIN。
PTE[0] 自身的 per-PTE 锁天然串行化两个 contig 操作。

**（八）竞态汇总**

| 场景 | T1 | T2 路径 | 可触发？ | 冲突？ | 后果 |
|------|----|---------|---------|-------|------|
| 1a | contig BBM | map 单页（logging 关闭 SRCU 窗口） | **是（低概率）** | cmpxchg 竞态 | 双向丢失更新（状态 3b） |
| 1b | contig BBM | map 单页（mprotect/madvise/THP） | **否** | — | hugetlb VMA 不被拆分，vma_pagesize 不变，所有 fault 走 contig |
| 2a | contig BBM | mkyoung | **是** | cmpxchg 竞态 | AF 丢失，多一次 fault，可自愈 |
| 2b | contig BBM | relax_perms | **是** | cmpxchg 竞态 | 权限丢失，多一次 fault，可自愈 |
| 3 | contig BBM | age_walker lockless | **否（已修复）** | — | 编译时互斥，lockless 时 contig 禁用 |
| 4 | contig BBM | contig BBM | **是** | ❌ PTE[0] 串行化 | — |
| — | contig BBM | wrprotect / unmap | — | ❌ write_lock 排他 | — |

**结论**：
- 场景 1a（map contig vs map 单页）在 dirty logging 关闭时的 SRCU 窗口中可触发，
  是状态 3b 的真实路径——双向丢失更新，需要修复。
- 场景 2（contig BBM vs mkyoung/relax_perms）可触发，后果可自愈
  （AF/权限丢失触发额外 fault 即可恢复），不影响正确性。
- 场景 3（age_walker）已通过 contig 与 `CONFIG_KVM_MMU_LOCKLESS_AGING` 编译时互斥解决。
- 场景 1b（VMA 切分）在 PTE[0] 检查 + mmu_invalidate_seq 双重保护下不可达。

涉及四处修改，均在 `arch/arm64/kvm/hyp/pgtable.c`。

###### 修改 1：contig 侧 LOCKED 防御（`stage2_map_contig_leaf`）

在 `stage2_try_set_pte` 之前增加 LOCKED 检查，防止 cmpxchg(LOCKED, LOCKED)
双方都以为持有锁：

```c
if (stage2_pte_is_locked(ctx->old))
    return -EAGAIN;
if (!stage2_try_set_pte(ctx, KVM_INVALID_PTE_LOCKED))
    return -EAGAIN;
```

###### 修改 2：单页 map PTE[0] 检查（`stage2_map_walker_try_leaf`）

在 `kvm_pgtable_walk_shared` 且 `level == LAST_LEVEL` 条件下，
在 BBM 之前检查并锁定 PTE[0]：

```c
if (ctx->level == KVM_PGTABLE_LAST_LEVEL &&
    kvm_pgtable_walk_shared(ctx)) {
    first_ptep = PTR_ALIGN_DOWN((kvm_pte_t *)ctx->ptep,
                                sizeof(kvm_pte_t) * CONT_PTES);
    pte0 = READ_ONCE(*first_ptep);

    if (stage2_pte_is_locked(pte0))
        return -EAGAIN;
    if (pte0 & KVM_PTE_LEAF_ATTR_CONT)
        return -EAGAIN;
    if (!kvm_pte_valid(pte0)) {
        if (cmpxchg(first_ptep, 0,
                    KVM_INVALID_PTE_LOCKED) != 0)
            return -EAGAIN;
        locked_pte0 = true;
    }
}
```

PTE[0] 状态处理逻辑：

| PTE[0] 状态 | 行为 | 依据 |
|------------|------|------|
| LOCKED | -EAGAIN 退让 | contig BBM 或其他单页 op 正在进行 |
| Valid + CONT | -EAGAIN 退让 | 已存在 contig block，单页路径无权破坏 |
| Valid 非 CONT | 不锁，正常 BBM | contig 升级可与单页在 PTE[0] 上 cmpxchg 串行化 |
| INVALID (0) | cmpxchg 抢锁 | 阻止 contig 在此期间开始 |

`pte0 & CONT → -EAGAIN` 是防御性检查。正常流程下此时 `stage2_contig_supported`
已返回 false（fault 不带 PROT_CONT），如有 CONT block 说明存在 VMA 过渡窗口
（MMU notifier 间隙），依赖 notifier end / wrprotect 清除后重试。

**locked_pte0 为 true 后的 BBM 处理**：

```c
if (locked_pte0 && ctx->ptep == first_ptep) {
    // ctx->ptep 是 PTE[0] 本身，已持有 LOCKED，跳过 BBM
} else if (!stage2_try_break_pte(ctx, data->mmu)) {
    if (locked_pte0)
        WRITE_ONCE(*first_ptep, 0);
    return -EAGAIN;
}
```

当 `ctx->ptep == first_ptep` 且 `locked_pte0 = true` 时，PTE[0] 已是 LOCKED。
如果走正常 BBM，`stage2_try_break_pte` 的 cmpxchg(PTE[0], ctx->old, LOCKED)
会因 PTE[0]=LOCKED≠ctx->old 而失败 → 死循环。必须跳过。

跳过 BBM 的安全性：PTE[0] 被锁时值为 0（INVALID），不存在需要 flush 的 TLB entry；
即使 ctx->old 过时（valid），清除它的线程已做了 TLBI 和 put_page。

**释放**：
- `ctx->ptep == first_ptep`：`stage2_make_pte` 用 smp_store_release 将
  LOCKED 覆盖为新的 valid PTE，自然释放
- `ctx->ptep != first_ptep`：BBM → Make 之后 `WRITE_ONCE(PTE[0], 0)` 显式释放

###### 修改 3：单页 attr PTE[0] 检查（`stage2_attr_walker`）

与 map 路径类似，但在 `data->pte != pte`（需要更新）之后：

```c
if (data->pte != pte) {
    if (ctx->level == KVM_PGTABLE_LAST_LEVEL) {
        first_ptep = PTR_ALIGN_DOWN(...);
        pte0 = READ_ONCE(*first_ptep);
        if (stage2_pte_is_locked(pte0))
            return -EAGAIN;
        if (!kvm_pte_valid(pte0)) {
            if (cmpxchg(first_ptep, 0, LOCKED) != 0)
                return -EAGAIN;
            locked = true;
        }
    }
    // 原有 attr 更新逻辑 ...
    if (locked)
        WRITE_ONCE(*first_ptep, 0);
}
```

**关键差异**：
- **不加** `kvm_pgtable_walk_shared` 门：relax_perms 和 mkyoung 走此路径且有 SHARED，
  与 contig BBM 存在真实并发需要保护。wrprotect 持 write_lock 排他无需保护，
  但走同一代码路径无害。
- **不检查** `pte0 & CONT`：入口已有 `ctx->old & CONT` 过滤，CONT 时已走
  `stage2_attr_contig_leaf`；即使 ctx->old 过时而 pte0 有 CONT，接下来的
  `stage2_try_set_pte`（cmpxchg）或 WRITE_ONCE 会因值不匹配而失败

##### 5.4.3.3 残留窗口：状态 3b

当 PTE[0]=valid_non_CONT、T1 做 contig 升级、T2 在 PTE[k] 上做单页 BBM 时，
T2 不锁 PTE[0]（它是 valid）。T1 的 cmpxchg(PTE[0], valid_non_CONT, LOCKED)
可以成功，然后 `kvm_clear_pte(PTE[k])` 可能与 T2 并发的 BBM 冲突。

触发条件极为苛刻（VMA 过渡 + 4 个条件同时成立），完全修复的代价（同一 block
内独立 4K 也互斥）大于收益。已通过 WARN_ON_ONCE 在代码中标记检测点。

详细分析见 `PTE0_Block_Lock_分析.md` 状态 3b 章节。

**非 contig 系统影响**：无 contig 时 PTE[0] 永不设 LOCKED 或 CONT。

- `PTE[0] = valid`：多一次 `READ_ONCE(PTE[0])`，O(1) 开销不可测
- `PTE[0] = INVALID`：单页 op 锁 PTE[0]，同 64K block 内初始填充时有微弱
  串行化。一旦 PTE[0] 建立映射，后续走 valid 分支无影响

## 6. 对其他KVM特性的影响

`pgtable.c`被编译两次：一次用于host内核(EL1)，一次用于EL2 nVHE hyp代码
(`nvhe/Makefile`中`hyp-obj-y += ../pgtable.o`，带`-D__KVM_NVHE_HYPERVISOR__`)。
两者的页表操作逻辑完全相同，仅tracepoint在EL2侧被替换为空操作。

### 6.1 热迁移 / dirty logging

担心点：dirty logging期间整个contig block被写保护后，guest写其中一页的处理粒度
会不会按contig block，破坏per-page的脏页跟踪。

结论：**dirty bitmap粒度严格per-page，无问题**。链路如下：

1. **写保护阶段**：`kvm_mmu_wp_memory_region` → `kvm_pgtable_stage2_wrprotect`。
   wp范围与contig block对齐时走aligned分支（N个PTE同时wp、保留CONT位）；否则
   unaligned分支直接unfold。两种情况wp状态都正确。

2. **写错误后fault处理**（`user_mem_abort`）：

   - `mmu.c`中`force_pte = logging_active`，dirty log期间新fault强制4K粒度，
     `vma_pagesize`保持`PAGE_SIZE`，THP/CONT block升级路径被跳过
   - `kvm_vcpu_trap_get_perm_fault_granule()`从ESR的fault level取粒度——**ARM
     硬件按页表层级而非CONT块**报，contig叶子level仍是LAST_LEVEL → granule =
     `PAGE_SIZE`
   - `vma_pagesize == fault_granule == PAGE_SIZE` → 走`relax_perms`，传入
     `[fault_ipa, fault_ipa + PAGE_SIZE)`

3. **relax_perms落到contig leaf**：

   - `ctx->end < block_end` → unaligned分支 → unfold
   - 故障页变可写（去CONT），block内其余N-1个PTE保持wp（去CONT）
   - `mark_page_dirty_in_slot`标1个gfn dirty
   - 后续对同block内其他页的写各自单独fault → relax单PTE → 单页标dirty

代价：CONT块内第一次写要付一次unfold开销（BBM改8个PTE + TLBI一次）。仅发生一
次，后续访问就是普通4K PTE的fault路径。

### 6.2 nVHE

无影响。contig修改对VHE/nVHE透明，纯粹的页表格式优化不涉及EL切换逻辑。

### 6.3 pKVM

pKVM的EL2代码在`mem_protect.c`中使用以下stage2 API:

| API | contig处理 |
|-----|-----------|
| `kvm_pgtable_stage2_map()` | 已处理 |
| `kvm_pgtable_stage2_unmap()` | 已处理 |
| `kvm_pgtable_stage2_set_owner()` | 复用map路径，已处理 |
| `kvm_pgtable_stage2_relax_perms()` | 已处理 |
| `kvm_pgtable_stage2_wrprotect()` | 已处理 |
| `kvm_pgtable_stage2_mkyoung()` | 已处理 |
| `kvm_pgtable_stage2_test_clear_young()` | 内核侧编译互斥；pKVM侧见下文 |

`test_clear_young` 在内核侧已通过 contig 与 `CONFIG_KVM_MMU_LOCKLESS_AGING`
编译互斥解决。pKVM 场景下（`mem_protect.c:1178`），如果 protected VM 的
stage-2 使用了 contig PTE，`stage2_age_walker` 仍会破坏 contig block 的
属性一致性。不过 pKVM 的 host stage-2 通常使用 `force_pte` 做小粒度映射，
实际触
发概率较低。

### 6.4 安全虚机(Realm/CCA)

无影响。Realm的stage2由RMM(Realm Management Monitor)在R-EL2管理，完全独立
于KVM的`pgtable.c`，二者无交集。

### 6.5 ARM嵌套虚拟化(NV)

无影响。NV代码(`nested.c`/`at.c`)已通过`contiguous_bit_shift()`处理guest页表
中的contig bit，用于AT指令模拟等场景。当前contig修改针对的是KVM自身的stage2
(L0→L1)，与NV的guest页表读取逻辑正交，不存在冲突。

## 7. 备注

**wrprotect 调用链**：

```
QEMU ioctl(KVM_SET_USER_MEMORY_REGION2)
  → kvm_vm_ioctl_set_memory_region()
    → kvm_mmu_wp_memory_region()
      → write_lock(&kvm->mmu_lock)     // mmu.c:1251
      → kvm_stage2_wp_range()          // mmu.c:1252
        → stage2_apply_range_resched(..., kvm_pgtable_stage2_wrprotect)
          → kvm_pgtable_stage2_wrprotect()  // IGNORE_EAGAIN, 无 SHARED
            → stage2_update_leaf_attrs()
              → stage2_attr_walker()        // 非 SHARED
                → stage2_try_set_pte()      // WRITE_ONCE（write_lock 排他，安全）
      → write_unlock(&kvm->mmu_lock)
```

**test_clear_young 调用链**：

```
ksm / khugepaged / madvise
  → mmu_notifier_clear_young()
    → kvm_age_hva_range()
      → kvm_handle_hva_range()
        → KVM_MMU_LOCK(kvm)                    // = write_lock(&kvm->mmu_lock)
          → kvm_age_gfn()
            → kvm_pgtable_stage2_test_clear_young()  // LEAF, 无 SHARED
              → stage2_age_walker()                  // 直接改单 PTE 的 AF
        → KVM_MMU_UNLOCK(kvm)                  // mmu_invalidate_seq 保证 lockless
                                               // 路径在 notifier 后重试

注：当 CONFIG_KVM_MMU_LOCKLESS_AGING=y 时，KVM_MMU_LOCK 被省略，走 lockless 路径。
```
