ARM64 KVM Stage-2 Contiguous Hugetlb 支持
===========================================

-v0.1 2026.05.09 Sherlock init
-v0.2 2026.05.13 Sherlock partial range + unmap analysis
-v0.3 2026.05.14 Sherlock PTE[0]-as-block-lock fix + attr path

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

4. 锁页表逻辑。

### 基础逻辑修改

user_mem_abort对于CONT_PTE_SIZE的情况之前是force到pte的，去掉这个限制，把CONT_PTE_SIZE
这个信息一路传递到stage2 map的逻辑。

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

基本的逻辑是修改页表的时候要满足如上硬件的约束。具体看就是：

1. map的时候一次修改所有contig的PTE。
2. 对于已经有contig bit的PTE，修改其中一个PTE时要把全部contig bit去掉。
3. BBM约束。

### BBM逻辑

ARM架构要求修改PTE映射时遵守BBM序列。也就是改pte的顺序应该是：
锁页表-> invalid页表 -> TLBI -> 更新页表 -> 解锁页表。

### 锁页表逻辑

BBM改页表要先加锁，之前都是一次修改一个PTE。现在需要对这一批PTE加锁，而且修改PTE
的流程可能contig PTE修改和单个PTE修改流程并发，需要考虑怎么加锁互斥这些并发行为。

基本的考虑是，都使用contig PTE0(多个contig PTE中的第一个PTE)

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

综上具体代码修改要考虑的walker有：
1. stage2_map_walker
2. stage2_unmap_walker
3. stage2_attr_walker
4. stage2_age_walker  todo: ...

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
| 单页路径 PTE[0] 检查 | 单页 map/attr 路径在操作前检查 PTE[0]，LOCKED/CONT 时退让，INVALID 时抢锁 |
| `-EAGAIN`返回值 | 通知walker层重试(walker检测到-EAGAIN会重新遍历) |
| `smp_store_release` | 确保PTE[1..N-1]写入在PTE[0]之前全局可见 |
| `KVM_INVALID_PTE_LOCKED` | contig 与单页 BBM 共用锁值，争同一 PTE[0] 天然串行化 |

**注意**: 对于contig区域的单个pte修改，如上已经有逻辑，需要把整个区域的contig bit
去掉。

## 可能存在问题分析

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
## **重点分析并发问题**

### 总体并发建模

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
| `stage2_wrprotect` | 写保护 | 系统调用（dirty log） | attr_walker | `read_lock` | ❌ | WRITE_ONCE | ✅¹ | contig_leaf / PTE[0]检查 |
| `stage2_test_clear_young` | 清 AF + 老化 | 系统调用（MMU notifier） | age_walker | `read_lock` | ❌ | WRITE_ONCE | ✅¹ | **未处理**² |
| `stage2_unmap` | 取消映射 | 系统调用 / pKVM | unmap_walker | `write_lock` | ❌ | WRITE_ONCE | ❌³ | contig unmap |

> ¹ wrprotect 和 test_clear_young 持有 `read_lock` 但无 SHARED flag，使用
> WRITE_ONCE 直写而非 cmpxchg，因此不受 per-PTE LOCKED 保护。wrprotect 通过
> attr_walker 的 PTE[0] 检查解决此问题；test_clear_young **未适配** contig（见下注 ²）。
>
> ² `stage2_age_walker` 直接修改单个 PTE 的 AF 位，不检查 CONT，会破坏 contig block
> 的属性一致性，是当前实现的缺口。
>
> ³ `write_lock` 是排他锁，持有期间不存在任何其他软件 walker，无需 cmpxchg 或
> PTE[0] 检查。

读锁下三类并发的实际含义：

```
read_lock(&kvm->mmu_lock)
  ├─ fault (map/relax_perms/mkyoung):  SHARED, cmpxchg  → 互相并发，走 PTE[0] 互斥
  ├─ wrprotect:                       非SHARED, WRITE_ONCE → 与 fault 并发，走 PTE[0] 互斥
  └─ test_clear_young:                非SHARED, WRITE_ONCE → 与上两类并发，未处理 contig

write_lock(&kvm->mmu_lock)
  └─ unmap:                           非SHARED, WRITE_ONCE → 排他，无并发
```

**wrprotect 调用链**：

```
QEMU ioctl(KVM_SET_USER_MEMORY_REGION2)
  → kvm_vm_ioctl_set_memory_region()
    → kvm_mmu_wp_memory_region()
      → read_lock(&kvm->mmu_lock)
      → stage2_apply_range_resched(..., kvm_pgtable_stage2_wrprotect)
        → kvm_pgtable_stage2_wrprotect()  // IGNORE_EAGAIN, 无 SHARED
          → stage2_update_leaf_attrs()
            → stage2_attr_walker()        // 非 SHARED
              → stage2_try_set_pte()      // WRITE_ONCE
      → read_unlock(&kvm->mmu_lock)
```

**test_clear_young 调用链**：

```
ksm / khugepaged / madvise
  → mmu_notifier_clear_young()
    → kvm_mmu_notifier_clear_young()
      → read_lock(&kvm->mmu_lock)
      → kvm_pgtable_stage2_test_clear_young()  // LEAF, 无 SHARED
        → stage2_age_walker()                  // 直接改单 PTE 的 AF
      → read_unlock(&kvm->mmu_lock)
```

**为什么 attr_walker 的 PTE[0] 检查不加 `walk_shared` 门**：wrprotect 持有
`read_lock` 但不设 SHARED，`stage2_try_set_pte` 用 WRITE_ONCE 直写，不做 cmpxchg。
如果 contig BBM 同时持有 PTE[0]=LOCKED，wrprotect 可以盲写 PTE[k]——contig Make
阶段会把它覆盖掉。因此 PTE[0] 检查必须对所有读锁调用生效，不能限定 SHARED。
map 路径不需要放宽：非 SHARED map 只有 pKVM set_owner，跑 exclusive 锁。


### unmap路径无并发问题

contig BBM在unmap路径上不会与其他walker race，原因是unmap的调用方必须持有
`kvm->mmu_lock`写锁，rwlock语义保证写锁排他。

**unmap caller的锁约束**：

- `__unmap_stage2_range`显式`lockdep_assert_held_write(&kvm->mmu_lock)`
- 所有进入路径（`kvm_arch_flush_shadow_range`、`stage2_unmap_vm`、
  `kvm_mmu_wp_memory_region`关联调用等）都在`write_lock(&kvm->mmu_lock)`下
- pKVM EL2路径走`host_lock_component`，同样exclusive

写锁持有期间任何reader拿不到锁，因此**同一pgt上不会有第二个软件walker**与
unmap并发，与SHARED flag无关。

**HW page table walker的安全性**：其他vCPU的guest执行仍在硬件层walk stage-2，
但由BBM序列（clear所有N个PTE → TLBI整个block → put_page）保证：TLBI之后HW
看不到旧entry，put_page在TLBI之后执行不会出现refcount与映射不一致。

结论：unmap路径上的contig BBM不需要per-PTE锁，原`stage2_unmap_put_pte`直接
写0的设计在写锁保护下是安全的。我们之前为attr路径讨论的race（PTE[k]清0
后被并发SHARED walker抢走）在unmap这里不存在。

### contig BBM 的 per-PTE 锁分析

问题：当前 contig BBM 只对 `PTE[0]` 做 `cmpxchg → LOCKED` 加锁，
`PTE[1..N-1]` 在 Break 阶段被直接写 0（`kvm_clear_pte`）。`PTE[k]`(k≠0)
在 Break 到 Make 之间的窗口里既不 valid 也不 LOCKED，过不了任何并发保护。

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

T1 的 Make 阶段会把 T2 刚装的映射覆盖掉，**丢失更新**。这个 race 在原 contig
实现里就存在，不是 partial range 修复引入的。

race 的双向破坏：

1. **T1 覆盖 T2**：T1 Make 阶段 `smp_store_release(PTE[k], 新值)` 覆写 T2 刚
   装的映射，T2 get_page 的 refcount 泄漏
2. **T1 读 T2**：`stage2_map_contig_leaf` 的 Break 阶段先读 `*ptep` 判断是否
   valid/counted 再做 put_page/clear，而 T2 正在改 PTE[k]，read-then-write
   之间无原子性，可能 put_page 指向 T2 刚装的页

两项是同一个 race 的两种表现，根因相同：PTE[k] 在 T1 锁住 PTE[0] 之后、写
最终值之前没有任何保护。

#### 触发条件分析

**两个 SHARED walker 并发 + 语义不一致**。具体需要：

- T1：在做 contig 块级操作（map contig / attr contig）
- T2：在 PTE[k] 上走**单页**路径，而不是 contig 路径

T2 在什么情况下会走单页路径而不走 contig 路径？

正常情况下，同一 VMA 内所有 vcpu 的 fault 都会算出相同的 `vma_pagesize`（在
`user_mem_abort` 中基于 VMA 属性决定，不依赖 vcpu）。如果 `vma_pagesize==
CONT_PTE_SIZE`，则所有 fault 都请求 contig，map walker 都会进
`stage2_map_contig_leaf`，两个 contig walker 在 PTE[0] 上 cmpxchg 串行化，
不会在 PTE[k] 上抢。同样，attr 路径上 attr_walker 看到 CONT 位也走 contig
路径，在 PTE[0] 串行化。

冲突只发生在 **vma_pagesize 不一致的窗口**：

- **attr contig vs map 单页**：dirty logging 开启期间 `force_pte=true`，
  `vma_pagesize=PAGE_SIZE`。此时 contig block 如果被 partial wrprotect
  或 subsequent write fault 的 relax_perms 触发 unfold（attr_contig_*），
  另一 vcpu 在同一 block 的其他页上做 map（force_pte → 单页）。窗口存在但
  极窄：第一次 write fault 触发 unfold 之后 contig block 已不存在，后续不再
  触发。
- **map contig vs map 单页**：VMA 被 madvise/mprotect 切分 hugepage 策略的
  过渡窗口。同样极窄。

**为什么 attr / mkyoung 的单页路径不会触发**：attr_walker 入口有
`ctx->old & CONT` 检查，如果 CONT 还在就走 contig 路径；如果 CONT 不在了
（被 T1 清了），`!kvm_pte_valid(ctx->old)` 也直接 `-EAGAIN`。

#### 修复实现：PTE[0] 作为 block 级互斥点

**核心思想**：contig BBM 已经在 PTE[0] 上持有 LOCKED。让**单页路径也通过 PTE[0]
判断和加锁**，两个路径争同一个 PTE——PTE[0]——天然串行化。

涉及四处修改，均在 `arch/arm64/kvm/hyp/pgtable.c`。

##### 修改 1：contig 侧 LOCKED 防御（`stage2_map_contig_leaf`）

在 `stage2_try_set_pte` 之前增加 LOCKED 检查，防止 cmpxchg(LOCKED, LOCKED)
双方都以为持有锁：

```c
if (stage2_pte_is_locked(ctx->old))
    return -EAGAIN;
if (!stage2_try_set_pte(ctx, KVM_INVALID_PTE_LOCKED))
    return -EAGAIN;
```

##### 修改 2：单页 map PTE[0] 检查（`stage2_map_walker_try_leaf`）

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

##### 修改 3：单页 attr PTE[0] 检查（`stage2_attr_walker`）

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
- **不加** `kvm_pgtable_walk_shared` 门：wrprotect 是系统调用触发，持 read_lock
  但不设 SHARED flag（使用 WRITE_ONCE 非 cmpxchg），同样需要保护
- **不检查** `pte0 & CONT`：入口已有 `ctx->old & CONT` 过滤，CONT 时已走
  `stage2_attr_contig_leaf`；即使 ctx->old 过时而 pte0 有 CONT，接下来的
  `stage2_try_set_pte`（cmpxchg）或 WRITE_ONCE 会因值不匹配而失败

##### 修改 4：WARN 检测第 3b 类残留竞态

在三处 contig BBM 的 `kvm_clear_pte` 循环前加 `WARN_ON_ONCE`，
检测是否有并发单页 BBM 的 LOCKED 被覆盖：

- `stage2_map_contig_leaf` clear 循环（PTE[1..N-1]）
- `stage2_attr_contig_aligned` clear 循环
- `stage2_attr_contig_unaligned` clear 循环

```c
for (i = 1; i < CONT_PTES; i++, ptep++) {
    WARN_ON_ONCE(stage2_pte_is_locked(*ptep));
    kvm_clear_pte(ptep);
}
```

unmap 路径不需要（write_lock 排他）。

#### **残留窗口：状态 3b**

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
