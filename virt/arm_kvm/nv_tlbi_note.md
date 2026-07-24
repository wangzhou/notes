附录: NV TLBI trap详细逻辑
============================

普通虚机TLBI不trap
------------------

VHE下硬件支持VMID-tagged TLB，每个TLB entry打有当前VMID标签。当guest(EL1)执行TLBI
时，硬件自动只刷掉当前VMID的条目。正常guest的HCR_EL2不做TLB trap配置(`vcpu_set_hcr()`
中不设HCR_TTLB/HCR_TTLBIS)，guest TLBI直接在硬件执行。

唯一例外: 没有FGT且硬件不支持TLB OS时，需要设`HCR_TTLBOS`来单独trap OS变体的TLBI，
这是因为没有FGT就无法单独区分range-based TLBI(只有OS变体有range形式)。

NV下的TLBI trap触发
--------------------

NV场景L1在vEL2执行的TLBI必须trap到L0。trap通过两个机制:

| 机制 | 控制范围 | 配置位置 |
|------|---------|---------|
| HCR_EL2.TTLB | 所有EL1域TLBI指令 | vhe/switch.c:68 `hcr \|= HCR_NV \| HCR_NV2 \| HCR_AT \| HCR_TTLB` |
| HFGITR_EL2 | EL2域TLBI按指令粒度 | emulate-nested.c:742-801 SR_TRAP表 |

### HCR_EL2 trap bits

| bit | 含义 |
|-----|------|
| HCR_EL2.TTLB | FEAT_EVT前: trap所有EL1 TLBI |
| HCR_EL2.TTLBIS | FEAT_EVT后: 控制IS(inner-shareable)变体 |
| HCR_EL2.TTLBOS | FEAT_EVT后: 控制OS(outer-shareable)变体 |

TTLBIS+TILBOS = 之前TTLB的功能。拆分是为了让KVM可以按需只trap range-based TLBI(OS变体)。

### HFGITR_EL2 fine-grained trap

EL2域TLBI(ALLE2/VAE2/VALE2 + 变体)通过HFGITR_EL2按指令粒度单独控制。emulate-nested.c
为每条TLBI指令配置trap组合:

```
无IS/OS后缀: SR_TRAP(OP_TLBI_VMALLE1,  CGT_HCR_TTLB)              // 单控
IS变体:      SR_TRAP(OP_TLBI_VMALLE1IS, CGT_HCR_TTLB_TTLBIS)       // TTLB & TTLBIS
OS变体:      SR_TRAP(OP_TLBI_VMALLE1OS, CGT_HCR_TTLB_TTLBOS)       // TTLB & TTLBOS
Range变体:   SR_TRAP(OP_TLBI_RVAE1IS,   CGT_HCR_TTLB_TTLBIS)       // OS变体才有range
```

注意: NV2下L1的EL2 TLBI实际是通过EL2名字寄存器发出的，硬件自动重定向到EL1寄存器后
trap，所以EL2域TLBI最终也是通过HCR_TTLB的trap进入。

VHE fast path (vhe/switch.c)
------------------------------

VHE下HCR_EL2.TTLB常驻。E2H+TGE=1(InHost)时TLBI通过TTLB trap进来，KVM提供fast path
直接处理不做完整VM exit:

```c
// vhe/switch.c:412-436
if ((E2H && TGE && supported_tlbi_s1e1) || supported_tlbi_s1e2)
    ret = __kvm_tlbi_s1e2(NULL, val, instr);  // NULL mmu=不切换VMID,直接全局刷

// 有VNCR映射时回慢路径
if (E2H && TGE && atomic_read(&vcpu->kvm->arch.vncr_map_count))
    return false;
```

`__kvm_tlbi_s1e2()` (vhe/tlb.c:230) 变换规则:
- EL2 → EL1: ALLE2→vmalle1is, VAE2→vae1is, VALE2→vale1is
- non-shareable → inner-shareable
- outer-shareable → inner-shareable
- nXS → XS (去掉nXS前缀)

慢路径: sys_regs.c handler
----------------------------

fast path不适用时,TLBI trap进入sys_regs.c的handler,按guest TLBI类型分5类:

### 1. handle_tlbi_el1 — EL1域TLBI (30条变体)

```c
// sys_regs.c:4147
if (E2H && TGE)  // vEL2 InHost: EL1指令实际刷vEL2 TLB
    kvm_handle_s1e2_tlbi(vcpu, encoding, val);  // → VNCR路径
else             // vEL2非InHost: EL1就是L2的EL1
    kvm_s2_mmu_iterate_by_vmid(vcpu->kvm, get_vmid(VTTBR_EL2),
                               &info, s2_mmu_tlbi_s1e1);
                                    // → __kvm_tlbi_s1e2(mmu, va, encoding)
                                    // 每个shadow S2做S1E2→S1E1映射的TLBI
```

### 2. handle_tlbi_el2 — EL2域TLBI

```c
kvm_handle_s1e2_tlbi(vcpu, encoding, val);
// → compute_s1_tlbi_range() 解析scope: ALL/VA/VAA/ASID
// → invalidate_vncr_va()    遍历vCPU清VNCR TLB
```

### 3. handle_vmalls12e1is — 全量S1+S2

```c
// 直接删除所有匹配VMID的shadow S2
kvm_s2_mmu_iterate_by_vmid(kvm, vmid,
    {.range = {0, limit}}, s2_mmu_unmap_range);
```

### 4. handle_ipas2e1is — IPA精准无效

```c
base_addr = (val & GENMASK_ULL(35,0)) << 12;
max_size  = compute_tlb_inval_range(mmu, val);
kvm_s2_mmu_iterate_by_vmid(kvm, vmid,
    {.ipa = {val}}, s2_mmu_unmap_ipa);
```

### 5. handle_ripas2e1is — IPA Range无效

```c
base = decode_range_tlbi(val, &range, NULL);
kvm_s2_mmu_iterate_by_vmid(kvm, vmid,
    {.range = {base, range}}, s2_mmu_unmap_range);
```

### 核心: kvm_s2_mmu_iterate_by_vmid

handler 1/3/4/5都通过此函数遍历所有匹配VMID的shadow S2:

```
s2_mmu_unmap_range() → kvm_stage2_unmap_range() → stage2_unmap_walker()
                     → 逐PTE: __kvm_tlb_flush_vmid_ipa/range

s2_mmu_tlbi_s1e1()  → __kvm_tlbi_s1e2(mmu, va, encoding)
                     → 对shadow S2做真实的S1 TLBI
```

s2_mmu_unmap_range允许drop mmu_lock并阻塞(安全, 见代码注释sys_regs.c:4004-4027):
1. 被回收的MMU重用时整体刷TLB
2. 在guest TLBI retirement前其他vCPU允许用stale translation
3. 多unmap最多导致更多shadow S2缺页重填

VNCR pseudo-TLB维护
--------------------

NV2用VNCR_EL2指向的内存区模拟vEL2寄存器。L1做TLBI时，对应vCPU的VNCR TLB也要失效:

```c
// nested.c:1038 invalidate_vncr_va()
kvm_for_each_vncr_tlb(i, vcpu, vt, kvm) {
    // TLBI_ALL  → 无条件invalidate_vncr(vt)
    // TLBI_VA   → va范围有交集则失效
    // TLBI_VAA  → 同上忽略ASID
    // TLBI_ASID → ASID匹配则失效
}
```

VNCR IPA范围失效(invalidate_vncr_ipa)在更大范围操作中调用: kvm_nested_s2_wp()
和kvm_nested_s2_unmap()把所有shadow S2操作完后统一清VNCR。

shadow S2 vs TLBI的关系总结
----------------------------

vEL2 S2被合并进shadow S2。L1的TLBI在L0有两种翻译方式:
- **unmap shadow S2**: IPAS2E1/RIPAS2E1/VMALLS12E1 → 直接kvm_stage2_unmap_range()
- **真实TLBI**: S1E1 VA TLBI → s2_mmu_tlbi_s1e1() → __kvm_tlbi_s1e2() 对shadow S2做实TLBI


