# ARM CPU 侧 BBML2 严格定义与场景分析

## 1. 架构定义

### 特性名称与寄存器

BBML2 来自 ARM 架构特性 **FEAT_BBM**（Break-Before-Make），通过 `ID_AA64MMFR2_EL1.BBM` 字段（bits [55:52]）报告支持级别：

```
ID_AA64MMFR2_EL1.BBM 编码:
  0b0000 → BBM Level 0: 无 BBM 保证
  0b0001 → BBM Level 1: 部分 BBM 支持
  0b0010 → BBM Level 2: 完整 BBM 支持
```

### 定义来源

ARM ARM（DDI 0487L.a）规则 **RNGLXZ** 和 **RJQQTC** 联合定义 BBM 的行为语义：

- **BBM Level 0**：不提供任何保证。PE 遇到不一致的页表描述符时，行为是 UNPREDICTABLE——可能返回不确定的翻译结果、触发 TLB conflict abort、或产生其他不可预期的后果。

- **BBM Level 1/2**：遇到不一致的页表描述符时，PE 的行为被约束为**二选一**：
  1. 产生一个 TLB conflict abort，或
  2. "produce an OA, access permissions, and memory attributes that are consistent with any of the programmed translation table values" —— 即返回与缓存中任一有效翻译一致的结果

  **注意：BBML1/2 允许实现选择 abort 路径。** 这是 SMMU 和 CPU 之间的关键差异（SMMUv3 BBML2 禁止 abort，CPU BBML2 不禁止）。

### 内核的 "noabort" 语义

ARM 架构允许 CPU BBML2 实现仍然触发 TLB conflict abort，但内核的大量关键路径（page fault handler、缺页处理、mTHP 折叠/展开等）如果被 CPU 自身的 TLB conflict abort 中断，会导致递归 abort 无法恢复。

因此内核引入 **`ARM64_HAS_BBML2_NOABORT`** 能力——只信任那些明确承诺**永不产生 TLB conflict abort** 的 CPU 实现。判断方式不是读 `ID_AA64MMFR2_EL1.BBM`，而是用 MIDR 白名单：

```c
// arch/arm64/kernel/cpufeature.c:2141
static const struct midr_range supports_bbml2_noabort_list[] = {
    MIDR_REV_RANGE(MIDR_CORTEX_X4,       0, 3, 0xf),
    MIDR_REV_RANGE(MIDR_NEOVERSE_V3,     0, 2, 0xf),
    MIDR_REV_RANGE(MIDR_NEOVERSE_V3AE,   0, 2, 0xf),
    MIDR_ALL_VERSIONS(MIDR_NVIDIA_OLYMPUS),
    MIDR_ALL_VERSIONS(MIDR_AMPERE1),
    MIDR_ALL_VERSIONS(MIDR_AMPERE1A),
    {}
};

bool cpu_supports_bbml2_noabort(void)
{
    if (!is_midr_in_range_list(supports_bbml2_noabort_list))
        return false;
    // 显式忽略 ID_AA64MMFR2_EL1.BBM 寄存器
    return true;
}
```

注释明确写道："We currently ignore the ID_AA64MMFR2_EL1 register, and only care about whether the MIDR check passes."

特性级别为 `ARM64_CPUCAP_EARLY_LOCAL_CPU_FEATURE`——所有 early CPU 和 late-onlined CPU 都必须支持，否则能力不会启用。

### FTR 定义

```c
// arch/arm64/kernel/cpufeature.c:490
ARM64_FTR_BITS(FTR_HIDDEN, FTR_STRICT, FTR_LOWER_SAFE,
               ID_AA64MMFR2_EL1_BBM_SHIFT, 4, 0),
```

- `FTR_HIDDEN`：不向用户态暴露 BBM 字段
- `FTR_STRICT`：所有 CPU 必须有一致的 BBM 值
- `FTR_LOWER_SAFE`：较低的 BBM 值更安全（即 BBM0 比 BBML2 "更安全"——内核保守时可以用更低的级别）

---

## 2. BBM 定义解决的核心问题

### 问题的本质

ARM 页表遍历器（MMU）可以缓存中间级的页表描述符。当软件修改页表时，硬件可能同时持有旧描述的缓存副本。BBM 定义的是：当硬件遍历过程中发现已缓存的描述符与当前内存中的描述符不一致时，硬件的契约是什么。

**关键触发条件：软件修改页表描述符但未执行完整的 BBM 序列（break → TLBI → make）。**

### BBM Level 0 下的约束

所有以下操作在 BBM0 下都需要显式的 break-before-make + TLBI：

| 操作 | 为什么需要 BBM |
|---|---|
| 改变描述符类型（block ↔ table） | 遍历器可能缓存了旧的描述符类型 |
| 改变地址范围大小 | 粒度变化导致地址解析不一致 |
| 改变 contiguous bit | CONT block 成员关系变化 |
| 改变页表项的有效性 | valid ↔ invalid 的跳变 |

### BBM Level 2 下放开的内容

BBML2 允许软件**在不执行中间 TLBI+DSB 的情况下**做以下变更：
1. 改变 block descriptor 为 table descriptor（或反向）
2. 改变 block/table 的覆盖范围（如 2MB block → 4KB page）
3. 修改 PTE 的权限位（AP、PXN、XN）
4. 设置/清除 contiguous bit
5. 修改内存类型属性（部分场景）

软件仍需确保变更前后的描述符分别自洽，但不再需要中间的 invalid + TLBI 隔离步骤。

---

## 3. 具体使用场景

### 场景 1：mTHP Contiguous PTE 折叠/展开

这是内核中 BBML2 最核心的使用场景（`arch/arm64/mm/contpte.c`）。

**折叠（fold）：4 个非 contiguous PTE → 1 个 contiguous block**

```
BBML0 步骤:                           BBML2 步骤:
─────────────────                     ─────────────────
[RO,n][RO,n][RO,n][RW,n]  (初始)      [RO,n][RO,n][RO,n][RW,n]  (初始)
       ↓                                     ↓
[ 0 ][ 0 ][ 0 ][ 0 ]      (清零)       [ 0 ][ 0 ][ 0 ][ 0 ]      (清零)
       ↓                                     ↓
__flush_tlb_range()        (TLBI+DSB)   [ 跳过 ]
       ↓                                     ↓
[RO,c][RO,c][RO,c][RO,c]  (写入 CONT)   [RO,c][RO,c][RO,c][RO,c]  (写入 CONT)
       ↓                                     ↓
最终 TLBI (来自调用者)                   最终 TLBI (来自调用者)
```

在 BBML2 下跳过中间 TLBI+DSB 后，可能出现新旧两种 TLB entry 同时存在（例如旧的 `[RW,n]` 单页 entry 和新的 `[RO,c]` contig entry）。BBML2 规范保证：
- 要么 raise TLB conflict abort（对 noabort 实现不会发生）
- 要么返回一个一致的结果（来自任一合法缓存 entry，但不会"融合"二者）
- 最终 TLBI 后，两个 entry 都被清除，新访问产生正确的 contig TLB entry

代码位置 (`contpte.c:227`):
```c
if (!system_supports_bbml2_noabort())
    __flush_tlb_range(&vma, start_addr, addr, PAGE_SIZE, true, 3);
```

**展开（unfold）：同理**，BBML2 跳过中间 TLBI，因为最终 TLBI 保证覆盖原 contig TLB entry。

### 场景 2：内核线性映射权限变更

这是 `force_pte_mapping()` 和 `split_kernel_leaf_mapping()` 的应用场景（`arch/arm64/mm/mmu.c`）。

**问题背景**：内核线性映射使用 block mapping（2MB/1GB）。当需要修改权限（如 `rodata=full` 改变只读属性，或 KFENCE 需要拆分 pool 页面），在 BBM0 下：
- 不能直接修改 block PTE 的权限位（因为可能改变的是 block 内部分页面的权限，或 block PTE 的权限变更在 BBM0 下需要 BBM 序列）
- 必须先将 block 拆分为 512 个 4KB PTE，然后修改目标 PTE

**BBML2 的优化**：
```c
// mmu.c:760
static inline bool force_pte_mapping(void)
{
    const bool bbml2 = system_capabilities_finalized() ?
        system_supports_bbml2_noabort() : cpu_supports_bbml2_noabort();
    if (bbml2)
        return false;  // <-- 不强制 PTE mapping，允许 block mapping + 直接改权限
    return rodata_full || arm64_kfence_can_set_direct_map() || is_realm_world();
}
```

BBML2 系统上：
- 不强制 PTE 映射，可以保留大块映射（节省 TLB 和页表内存）
- 可以直接修改 block descriptor 的权限位（`update_mapping_prot()`），因为它属于"许可权限属性变更"范畴

```c
// mmu.c:128 - 允许在 BBM2 下直接修改的属性
pteval_t mask = PTE_PXN | PTE_RDONLY | PTE_WRITE | PTE_NG | PTE_SWBITS_MASK;
```

注意：`PTE_CONT` 明确不可在 live 映射上修改（line 145），因为 contiguous bit 的修改不在此列。

### 场景 3：KFENCE Pool 初始化

```c
// mmu.c:1103
/*
 * Since the system supports bbml2_noabort, tlb invalidation is not
 * required here; the pgtable mappings have been split to pte but larger
 * entries may safely linger in the TLB.
 */
```

BBML2 下 KFENCE pool 拆分后可以跳过 TLB 无效化——因为 BBML2 保证旧的大页 TLB entry 与新拆分后的 PTE TLB entry 并存时不会产生错误的访问许可（取最严格者）。

### 场景 4：KPTI + 混合 CPU 拓扑（部分 CPU 无 BBML2）

当 boot CPU 有 BBML2 但 secondary CPU 没有（big.LITTLE / 混合架构）：

```c
// mmu.c:965
if (linear_map_requires_bbml2 && !system_supports_bbml2_noabort()) {
    init_idmap_kpti_bbml2_flag();
    stop_machine(linear_map_split_to_ptes, NULL, cpu_online_mask);
}
```

- Boot CPU（有 BBML2）在 secondary CPU 被锁在 idmap 中的时候，遍历整个线性映射，将所有 block mapping 拆分为 4KB PTE
- 拆分完成后 secondary CPU 被释放
- 这样所有 CPU 对外部访问者有统一的 PTE 级线性映射

### 场景 5：嵌套虚拟化 —— BBM 对 Guest 隐藏

```c
// arch/arm64/kvm/nested.c:1623
case SYS_ID_AA64MMFR2_EL1:
    val &= ~(ID_AA64MMFR2_EL1_BBM   |    // 清除 BBM → Guest 看到 BBM=0
             ID_AA64MMFR2_EL1_TTL   |
             ...);
```

KVM 将 `ID_AA64MMFR2_EL1.BBM` 对 Guest 隐藏，Guest 看到 BBM=0。这是因为 Guest 的 Stage-1 页表和 Host 的 Stage-2 页表由不同实体管理，BBM 的保证需要跨 S1+S2 共同维护，当前不支持暴露给 Guest。

---

## 4. CPU BBML2 vs SMMU BBML2

```
                CPU FEAT_BBM L2        SMMU IDR3.BBM L2
                ──────────────         ────────────────
检测寄存器       ID_AA64MMFR2_EL1.BBM   SMMU IDR3 bits[12:11]
TLB conflict    允许产生                禁止产生 (IHI 0070G §3.21.1.3)
abort           
内核检测方式     MIDR 白名单            直接读 IDR3
                (忽略架构寄存器)
一致性保证      二选一:                 单一路径:
                abort 或 一致结果       必须返回一致结果
使用场景        CPU 自身 MM              设备 DMA 地址翻译
                (进程页表/内核页表)       (SMMU 页表遍历)
```

**为什么 CPU 架构允许 abort？** CPU 侧的 TLB conflict abort 理论上可以在 abort handler 中处理。但问题是，内核的缺页处理和许多 MM 操作路径本身就是 abort handler 的上下文——它们不能被递归 abort 打断。所以内核需要 "noabort" 的额外保证。

**为什么 SMMU 禁止 abort？** SMMU 的 abort 是异步系统级事件，无法绑定到任何进程或 DMA 上下文，无法恢复。SVA 场景下如果 SMMU abort，系统只能 panic。

---

## 5. 总结

| 维度 | 内容 |
|---|---|
| 架构定义 | FEAT_BBM，ID_AA64MMFR2_EL1.BBM (bits[55:52])，L0/L1/L2 三个级别 |
| 核心语义 | L2 保证遇到不一致页表时返回一致结果或 abort，不再 UNPREDICTABLE |
| 内核要求 | 额外要求 "noabort"——实现必须选择"返回一致结果"，不能选 abort 路径 |
| 主要场景 | mTHP contpte fold/unfold、内核线性映射权限变更、KFENCE、KPTI 混合 CPU |
| 与 SMMU 区别 | CPU 允许 abort，SMMU 禁止；CPU 用白名单，SMMU 直接读寄存器 |
