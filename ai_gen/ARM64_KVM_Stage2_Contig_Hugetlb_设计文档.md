ARM64 KVM Stage-2 Contiguous Hugetlb 支持
===========================================

-v0.1 2026.05.09 Sherlock init

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

传入的地址没有做对齐处理，现在的问题在于：1. 这些场景下关于contig bit的支持不对，
2. 如果初始地址没有对齐，后面跳过的地址会不对。

(todo: 讨论下如何修改)

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

### 页表遍历地址跳过修复

问题: KVM页表walker`__kvm_pgtable_visit()`在遍历叶子级PTE时，每个PTE处理后
`data->addr`递增`kvm_granule_size(level)`(即PAGE_SIZE)。但当PTE具有CONT位
时，该PTE实际覆盖CONT_PTE_SIZE(CONT_PTES * PAGE_SIZE)的地址范围，walker只
跳一个PAGE_SIZE会导致同一contig block内的后续PTE被重复处理。

修复逻辑:

```c
bool is_old_contig = ctx.old & KVM_PTE_LEAF_ATTR_CONT;   // 捕获旧值

// ... 执行visit callback ...

if (!table) {
    data->addr = ALIGN_DOWN(data->addr, kvm_granule_size(level));
    if (ctx.old & KVM_PTE_LEAF_ATTR_CONT || is_old_contig) {
        data->addr += kvm_granule_size(level) * CONT_PTES; // 跳过整个contig block
    } else {
        data->addr += kvm_granule_size(level);              // 普通单页
    }
    goto out;
}
```

设计要点:
- 同时检查`ctx.old & CONT`和`is_old_contig`: visit callback可能在map路径
  中将PTE从INVALID改为CONT新值（此时`ctx.old`无CONT但新PTE有），或在unmap中
  清除了CONT，两种情况下都需要基于旧值正确跳过
- 这是walker层面的通用修复，对map/unmap/attr三条路径都适用

注意：该patch的commit message标注"This is a hack patch，should think how
to do this formally"，说明walker地址跳过方式可能是临时方案，后续需更正式的
集成方式。

## 对其他KVM特性的影响

`pgtable.c`被编译两次：一次用于host内核(EL1)，一次用于EL2 nVHE hyp代码
(`nvhe/Makefile`中`hyp-obj-y += ../pgtable.o`，带`-D__KVM_NVHE_HYPERVISOR__`)。
两者的页表操作逻辑完全相同，仅tracepoint在EL2侧被替换为空操作。

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
