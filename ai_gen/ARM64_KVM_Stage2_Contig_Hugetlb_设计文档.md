ARM64 KVM Stage-2 Contiguous Hugetlb 支持
===========================================

-v0.1 2026.05.09 Sherlock init
-v0.2 2026.05.13 Sherlock ...

简介：分析ARM64 KVM Stage-2对contiguous PTE的软件支持逻辑。

## 概述

ARM64硬件支持通过设置PTE的BIT(52)(CONT bit)将连续N个PTE合并为一个TLB entry，减少
TLB占用，提升hugetlb场景性能。本实现在KVM Stage-2页表中启用该硬件能力，覆盖map、
unmap、属性更新(wrprotect/mkyoung/relax_perms)三个核心操作路径。

## 背景

### ARM64 Contiguous PTE硬件机制

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

### Stage-2页表需求

KVM Stage-2页表负责IPA(Intermediate Physical Address) → PA(PhysicalAddress)的转换。
当Guest使用hugetlb时，Stage-2映射也应尽可能使用大页/连续页以减少TLB miss。Host内核
本身对hugetlb使用contig bit，但KVM Stage-2此前未实现此支持。

**注意**: ARM定义里block也是可以做contig hugetlb的，我们先看page的contig hugetlb
的支持逻辑，也就是说我们先只关注基础页作为页表叶子节点情况的contig hugetlb实现。

## 整体架构

软件支持逻辑基本的考虑点如下：

1. 基础逻辑修改。现在所有stage2内存管理都没有考虑contig bit的情况，比如user_mem_abort
   的缺页逻辑，虽然有处理contig bit的情况，但是还是做了“force pte”的处理，需要修改
   这里的逻辑，把contig hugetlb这个信息传递下去。

2. 各种对stage2页表的修改都应该是一次修改所有contig PTE。这个需要我们：1. 修改
   所有stage2页表的修改点逻辑，2. 考虑修改页表时的互斥逻辑以及BBM逻辑，我们把这个
   点拆成如下两个点。

3. BBM逻辑。

4. 一次修改一批PTE的加锁逻辑。

### 基础逻辑修改

### 所有对stage2页表的修改

stage2页表操作通过walker机制遍历页表，主要入口:

| 入口函数 | walker | 操作类型 | contig影响 |
|----------|--------|----------|------------|
| `kvm_pgtable_stage2_map()` | `stage2_map_walker` | 映射 | 支持设置CONT bit |
| `kvm_pgtable_stage2_unmap()` | `stage2_unmap_walker` | 取消映射 | 识别并清除contig block |
| `kvm_pgtable_stage2_wrprotect()` | `stage2_attr_walker` | 写保护 | 去掉CONT bit后重写 |
| `kvm_pgtable_stage2_mkyoung()` | `stage2_attr_walker` | 设置AF | 去掉CONT bit后重写 |
| `kvm_pgtable_stage2_relax_perms()` | `stage2_attr_walker` | 放宽权限 | 去掉CONT bit后重写 |
| `kvm_pgtable_stage2_test_clear_young()` | `stage2_age_walker` | 清除AF | **未处理contig**，直接改单个PTE的AF |
| `kvm_pgtable_stage2_set_owner()` | `stage2_map_walker` | 取消映射+标注 | 复用map路径，已覆盖 |
| `kvm_pgtable_stage2_flush()` | `stage2_flush_walker` | TLBI flush | 无修改 |
| `kvm_pgtable_stage2_destroy_range()` | `stage2_destroy_walker` | 销毁范围 | 无修改 |
| `kvm_pgtable_stage2_split()` | `stage2_split_walker` | 拆分block | 不涉及leaf contig |

其中前7个入口涉及PTE修改，`test_clear_young`使用的`stage2_age_walker`
未处理contig PTE，直接在单个PTE上修改AF位，是当前实现的缺口。所有入口最终
汇聚到`__kvm_pgtable_visit()`，contig block的地址跳过修复即在此处生效。

### BBM逻辑

ARM架构要求修改PTE映射时遵守BBM序列。也就是改pte的顺序应该是：
锁页表-> invalid页表 -> TLBI -> 更新页表 -> 解锁页表。

### 一次修改一批PTE的加锁逻辑

注意，如上BBM流程里需要锁页表，之前的逻辑都是更新单个页表，现在要更新一批页表。
所以，这里的逻辑是用这一批页表的第一个页表项来锁页表。

## 数据结构与常量定义

### 新增宏与枚举

```c
// kvm_pgtable.h — 硬件CONT bit
#define KVM_PTE_LEAF_ATTR_CONT   BIT(52)

// kvm_pgtable.h — 软件协议位(传递给stage2_set_prot_attr转换为硬件位)
KVM_PGTABLE_PROT_CONT           = BIT(6)
```

### struct stage2_attr_data扩展

```c
struct stage2_attr_data {
    kvm_pte_t   attr_set;
    kvm_pte_t   attr_clr;
    kvm_pte_t   pte;
    s8          level;
+   struct kvm_s2_mmu *mmu;   // 新增: contig路径需要mmu以执行TLBI
};
```

## 具体逻辑设计

需要考虑如上列出的所有stage2 map行为和contig bit一起工作的时候是否会有问题。

kvm_pgtable_stage2_map：

user_mem_abort的逻辑中会把fault的地址对齐到指定地址，walker的时候一次处理一批PTE，
然后把处理地址跳过这一批PTE对应的地址。

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

热迁移/dirty logging场景下dirty bitmap粒度是否会被contig影响，详见"对其他KVM
特性的影响 → 热迁移 / dirty logging"小节，结论是无问题。


### 基础逻辑修改

`user_mem_abort()`中`CONT_PTE_SHIFT`分支(`arch/arm64/kvm/mmu.c`):

```c
case CONT_PTE_SHIFT:
    if (fault_supports_stage2_huge_mapping(memslot, hva, CONT_PTE_SHIFT)) {
        prot |= KVM_PGTABLE_PROT_CONT;        // 请求contig映射
        vma_shift = CONT_PTE_SHIFT;            // 使用contig大页
        break;
    } else {
        vma_shift = PAGE_SHIFT;                // fallback到4K
        force_pte = true;
    }
    fallthrough;                                // 进入PAGE_SHIFT处理
```

决策逻辑:

1. `fault_supports_stage2_huge_mapping()`检查: memslot基地址对齐、HVA对齐、
   VMA大小 >= CONT_PTE_SIZE
2. 条件满足 → 设置`KVM_PGTABLE_PROT_CONT`，告知后续map流程使用contig路径
3. 条件不满足 → 退化到4KB单页映射

### 所有对stage2页表的修改

### BBM逻辑

```
1. Lock:     cmpxchg PTE[0] → KVM_INVALID_PTE_LOCKED
2. Break:    清除PTE[1..N-1]为INVALID
3. TLBI:     单次flush CONT_PTE_SIZE范围
4. Make:     写入新PTE[1..N-1]，最后写PTE[0](smp_store_release)
```

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
- PTE[0]最后写入且使用`smp_store_release`: 确保硬件看到PTE[0]时，
  PTE[1..N-1]已经全部可见
- 用`KVM_INVALID_PTE_LOCKED`做cmpxchg锁: 与已有单页BBM的锁机制一致

### 一次修改一批PTE的加锁逻辑

并发控制逻辑。

| 机制 | 用途 |
|------|------|
| `cmpxchg` on PTE[0] | 原子锁: 同一contig block只有一个线程可进入BBM |
| `-EAGAIN`返回值 | 通知walker层重试(walker检测到-EAGAIN会重新遍历) |
| `smp_store_release` | 确保PTE[1..N-1]写入在PTE[0]之前全局可见 |
| `KVM_INVALID_PTE_LOCKED` | 与单页BBM共用锁值，避免死锁 |

**注意**: 对于contig区域的单个pte修改，如上已经有逻辑，需要把整个区域的contig bit
去掉。

## 存在问题

### partial range处理

问题：原`stage2_unmap_put_pte`和`stage2_attr_contig_leaf`遇到contig PTE就把整个
block的N个PTE全部按用户请求处理，没有考虑用户范围`[ctx->start, ctx->end)`是否
覆盖整个block。导致partial覆盖时操作越界（详见"具体逻辑设计"小节）。原attr回调
还用`cmpxchg(first_ptep, ctx->old, LOCKED)`加锁，当`ctx->ptep`不是`first_ptep`
时`ctx->old != *first_ptep`，cmpxchg必然失败。

按照`ctx->addr`是否对齐到block起点划分两个分支，分别用独立的helper实现：

**分支1：addr未对齐（unaligned）**

`ctx->addr != block_start || ctx->end < block_end`，即walker从block中部进入，
或block跨过了`ctx->end`（end也可能就在同一block内）。这种情况无法保持block
内N个PTE attrs一致，必须unfold：

```c
1. BBM清空整个block
2. TLBI block_start, CONT_PTE_SIZE
3. for i in [0, CONT_PTES):
       pte_addr = block_start + i * PAGE_SIZE
       if pte_addr ∈ [ctx->start, ctx->end):
           // 范围内
           unmap: put_page(ptep)
           attr:  attrs = (old0 & ~attr_clr) | attr_set
       else:
           // 范围外：保留映射
           unmap: rewrite ptep = (phys+i, attrs & ~CONT)
           attr:  attrs = old0
       attrs &= ~CONT                        // 所有N个PTE都去CONT位
       attr路径: smp_store_release(ptep, new_pte(phys+i, attrs))
```

对应函数：`stage2_unmap_contig_unaligned()` / `stage2_attr_contig_unaligned()`。

**分支2：addr对齐且完整覆盖（aligned）**

`ctx->addr == block_start && ctx->end >= block_end`。一次操作整个block，**保留
CONT位**，TLB优化得以保留：

```c
1. BBM清空整个block
2. TLBI block_start, CONT_PTE_SIZE
3. unmap: 对所有N个PTE做put_page
   attr:  attrs = (old0 & ~attr_clr) | attr_set | CONT
          写PTE[1..N-1]，最后写PTE[0]
```

对应函数：`stage2_unmap_contig_aligned()` / `stage2_attr_contig_aligned()`。

**通用设计要点：**

- `first_ptep`由`ctx->ptep`向下对齐到block起点，**不再使用`ctx->ptep`本身**，
  避免`ctx->ptep`在block中部时越界 / cmpxchg错值
- attr路径的cmpxchg expected值改为`READ_ONCE(*first_ptep)`，修复原`ctx->old`不
  匹配的bug
- unfold后范围外PTE暂时丢失TLB优化，未来访问时fault handler可重新建立contig映射
- refcount变化：attr路径所有N个PTE refcount不变（只改属性）；unmap路径只对范围
  内的PTE做put_page
- BBM顺序：清空 → TLBI → 重写，attr路径PTE[0]最后写入作为"go"信号

### unmap路径无并发问题分析

contig BBM在unmap路径上不会与其他walker race，原因是unmap的调用方必须持有
`kvm->mmu_lock`写锁，rwlock语义保证写锁排他。

**SHARED flag的本质**：`KVM_PGTABLE_WALK_SHARED`只是walker内部行为开关（决定
是否走RCU解引用、lockless cmpxchg等），**并不实际加锁**。真正的并发隔离靠
caller持有的`kvm->mmu_lock`（rwlock）。

**unmap caller的锁约束**：

- `__unmap_stage2_range`显式`lockdep_assert_held_write(&kvm->mmu_lock)`
- 所有进入路径（`kvm_arch_flush_shadow_range`、`stage2_unmap_vm`、
  `kvm_mmu_wp_memory_region`关联调用等）都在`write_lock(&kvm->mmu_lock)`下
- pKVM EL2路径走`host_lock_component`，同样exclusive

**互斥矩阵**：

| 其他caller | 持锁 | 与unmap并发 |
|-----------|------|------------|
| fault handler (map/mkyoung/relax_perms) | `read_lock` + WALK_SHARED | ❌ 被写锁阻塞 |
| dirty log wp (`stage2_wrprotect`) | `read_lock` + WALK_SHARED | ❌ |
| 另一个unmap | `write_lock` | ❌ rwlock串行 |
| split / destroy | `write_lock` | ❌ |
| MMU notifier (age / test_clear_young) | `read_lock` | ❌ |

写锁持有期间任何reader拿不到锁，因此**同一pgt上不会有第二个软件walker**与
unmap并发，与SHARED flag无关。

**HW page table walker的安全性**：其他vCPU的guest执行仍在硬件层walk stage-2，
但由BBM序列（clear所有N个PTE → TLBI整个block → put_page）保证：TLBI之后HW
看不到旧entry，put_page在TLBI之后执行不会出现refcount与映射不一致。

结论：unmap路径上的contig BBM不需要per-PTE锁，原`stage2_unmap_put_pte`直接
写0的设计在写锁保护下是安全的。我们之前为attr路径讨论的race（PTE[k]清0
后被并发SHARED walker抢走）在unmap这里不存在。

### contig BBM与单页BBM的并发race（**未修复**）

问题：当前contig BBM只对`PTE[0]`做`cmpxchg → LOCKED`加锁，`PTE[1..N-1]`在Break
阶段被直接写0（`kvm_clear_pte`）。`PTE[k]`(k≠0)在Break到Make之间的窗口里既不
valid也不LOCKED，过不了任何并发保护。

race场景（aligned和unaligned两个分支都存在）：

```
T1: 在某contig block上做contig BBM
    cmpxchg(PTE[0], old0, LOCKED)        // OK
    kvm_clear_pte(PTE[k])                // PTE[k] = 0
    --- 此时窗口打开 ---
    TLBI block
    smp_store_release(PTE[k], 新值)      // 覆盖T2的install！

T2: 同时在PTE[k]上做单页操作（map / attr，走SHARED walk）
    stage2_try_break_pte(ctx) {
        if (stage2_pte_is_locked(ctx->old))   // ctx->old=0，不是LOCKED → 过
            return false;
        cmpxchg(ctx->ptep, ctx->old, LOCKED); // ctx->old=0, *ptep=0 → 成功
    }
    // T2以为拿到了PTE[k]的BBM锁，install新映射
```

T1的Make阶段会把T2刚装上的映射覆盖掉，造成丢失更新。这个race在原contig实现里
就存在，不是partial range修复引入的。

修复思路（待实现）：Break阶段把PTE[k]写成`KVM_INVALID_PTE_LOCKED`而不是0：

```c
for (i = 1; i < CONT_PTES; i++)
    WRITE_ONCE(first_ptep[i], KVM_INVALID_PTE_LOCKED);
```

这样并发的`stage2_try_break_pte`：

- 若在T1改之前读ctx->old（=原contig PTE），cmpxchg期望原值但实际是LOCKED → 失败
- 若在T1改之后读ctx->old（=LOCKED），`stage2_pte_is_locked`命中 → 直接返回false

Make阶段仍用`smp_store_release`写最终值（不需要cmpxchg解锁），因为LOCKED是
invalid编码，HW看不到，release store会原子切换到valid新值。

触发条件需要两个SHARED walker并发：partial wrprotect/relax_perms（mmu read
lock）+ 另一个vcpu在同block的其他页上map（也是mmu read lock）。优先级先记录，
后续再修。

### 页表遍历地址跳过修复

问题: KVM页表walker`__kvm_pgtable_visit()`在遍历叶子级PTE时，每个PTE处理后
`data->addr`递增`kvm_granule_size(level)`(即PAGE_SIZE)。但当PTE具有CONT位
时，该PTE实际覆盖CONT_PTE_SIZE(CONT_PTES * PAGE_SIZE)的地址范围，walker只
跳一个PAGE_SIZE会导致同一contig block内的后续PTE被重复处理。

进一步地，对于unmap/wrprotect/mkyoung/relax_perms这些路径，调用者传入的
`addr`并不保证对齐到`CONT_PTE_SIZE`，walker可能从一个contig block的中间
进入。此时如果只按`PAGE_SIZE`对齐再加`CONT_PTE_SIZE`，跳完之后`addr`会落
到下一个contig block的中间，导致后续PTE跳过/重复处理。

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

设计要点:
- 同时检查`ctx.old & CONT`和`is_old_contig`: visit callback可能在map路径
  中将PTE从INVALID改为CONT新值（此时`ctx.old`无CONT但新PTE有），或在unmap中
  清除了CONT，两种情况下都需要基于旧值正确跳过
- contig分支的`ALIGN_DOWN`基准必须是`CONT_PTE_SIZE`(=`kvm_granule_size *
  CONT_PTES`)，而不是`kvm_granule_size`本身。map路径下`addr`一定对齐到
  `CONT_PTE_SIZE`，两种基准等价；但unmap/attr路径下调用者不做对齐，只有
  按`CONT_PTE_SIZE`对齐再前进才能正确跳到下一个contig block的起点
- 这是walker层面的通用修复，对map/unmap/attr三条路径都适用

## 对其他KVM特性的影响

`pgtable.c`被编译两次：一次用于host内核(EL1)，一次用于EL2 nVHE hyp代码
(`nvhe/Makefile`中`hyp-obj-y += ../pgtable.o`，带`-D__KVM_NVHE_HYPERVISOR__`)。
两者的页表操作逻辑完全相同，仅tracepoint在EL2侧被替换为空操作。

### 热迁移 / dirty logging

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

### nVHE

无影响。contig修改对VHE/nVHE透明，纯粹的页表格式优化不涉及EL切换逻辑。

### pKVM

pKVM的EL2代码在`mem_protect.c`中使用以下stage2 API:

| API | contig处理 |
|-----|-----------|
| `kvm_pgtable_stage2_map()` | 已处理 |
| `kvm_pgtable_stage2_unmap()` | 已处理 |
| `kvm_pgtable_stage2_set_owner()` | 复用map路径，已处理 |
| `kvm_pgtable_stage2_relax_perms()` | 已处理 |
| `kvm_pgtable_stage2_wrprotect()` | 已处理 |
| `kvm_pgtable_stage2_mkyoung()` | 已处理 |
| `kvm_pgtable_stage2_test_clear_young()` | **未处理**，`stage2_age_walker`直接改单个PTE的AF位 |

`test_clear_young`的缺口在pKVM场景同样存在(`mem_protect.c:1178`)，如果
protected VM的stage2使用了contig PTE，`stage2_age_walker`会破坏contig block
的属性一致性。不过pKVM的host stage2通常使用`force_pte`做小粒度映射，实际触
发概率较低。

### 安全虚机(Realm/CCA)

无影响。Realm的stage2由RMM(Realm Management Monitor)在R-EL2管理，完全独立
于KVM的`pgtable.c`，二者无交集。

### ARM嵌套虚拟化(NV)

无影响。NV代码(`nested.c`/`at.c`)已通过`contiguous_bit_shift()`处理guest页表
中的contig bit，用于AT指令模拟等场景。当前contig修改针对的是KVM自身的stage2
(L0→L1)，与NV的guest页表读取逻辑正交，不存在冲突。
