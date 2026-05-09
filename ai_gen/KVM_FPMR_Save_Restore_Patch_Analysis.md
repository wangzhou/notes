# KVM FPMR Save/Restore 补丁逻辑分析

## 概述

补丁 commit `ac6fcb4e719c`（对应主线 `ef3be86021c3`："KVM: arm64: Add save/restore support for FPMR"），在 KVM 的 FP lazy switch 路径中插入 FPMR（Floating Point Mode Register）的保存/恢复逻辑。

FPMR 不区分 EL1/EL2，是 ARMv9.4 引入的单一物理寄存器（编码 `S3_3_C4_C4_2`），用于控制 FP8（8-bit 浮点）运算的模式和格式。KVM 需要保证 host 和 guest 之间的 FPMR 值正确隔离。

---

## 核心设计：Lazy Switch

FPMR 不像通用寄存器那样每次 VM entry/exit 都切换。它跟随 FPSIMD 状态一起做 **lazy switch**：

- guest 不用 FP 指令就不切 FPMR，零开销
- guest 一旦用了 FP（触发 CPTR_EL2 陷阱），才在 trap handler 中切
- guest 的 FPMR 保存也是惰性的——VM exit 时不立即读硬件，而是注册一个指针，等 host 需要 FP 硬件时才真正回写

补丁在 3 个文件、4 个位置插入 FPMR 处理，串联起整个 lazy switch 链条。

---

## 改动详解

### 改动 1：per-CPU 存储槽位 — `kvm_host_data.fpmr`

**文件**: `arch/arm64/include/asm/kvm_host.h`

```c
struct kvm_host_data {
    struct kvm_cpu_context host_ctxt;
    struct user_fpsimd_state *fpsimd_state;    /* hyp VA */
+   u64 fpmr;

    /* Ownership of the FP regs */
    enum {
        FP_STATE_FREE,
        FP_STATE_HOST_OWNED,
        FP_STATE_GUEST_OWNED,
    } fp_owner;
};
```

预留一个 per-CPU 槽位来暂存 host 的 FPMR 值。pKVM 场景下，hypervisor 在 guest 运行期间可能持有 host 的 FP 寄存器（包括 FPMR），在把硬件交给 guest 之前必须先把 host 的 FPMR 存到这里。标准 KVM 下这个字段通常用不到（`vcpu_load` 时 eager flush 已清掉 host FP），但字段必须存在。

**与主线的差异**：主线用 `u64 *fpmr_ptr`（指针，指向 `current->thread.uw.fpmr`），openeuler 用 `u64 fpmr`（直接存值）。这是因为 openeuler 的 eager save+flush 在 `vcpu_load` 时已经把 host FP 全部保存，不需要再维护指向 host 内存的指针，存值即可。

---

### 改动 2：Host FPMR 保存（陷阱处理中）

**文件**: `arch/arm64/kvm/hyp/include/hyp/switch.h` — 函数 `kvm_hyp_handle_fpsimd()`

```c
/* Write out the host state if it's in the registers */
-if (*host_data_ptr(fp_owner) == FP_STATE_HOST_OWNED)
+if (*host_data_ptr(fp_owner) == FP_STATE_HOST_OWNED) {
     __fpsimd_save_state(*host_data_ptr(fpsimd_state));
+    if (system_supports_fpmr())
+        *host_data_ptr(fpmr) = read_sysreg_s(SYS_FPMR);
+}
```

**时机**：guest 第一次执行 FP 指令 → CPTR_EL2 陷阱触发 → hyp 陷阱处理函数被调用。

**做的事**：如果 host 还持有 FP 硬件（`fp_owner == FP_STATE_HOST_OWNED`），在保存 host FPSIMD 状态的同时，把硬件 FPMR 也读出来存到 `kvm_host_data.fpmr`。

**数据流**：

```
硬件 SYS_FPMR  ──(read_sysreg_s)──>  *host_data_ptr(fpmr)
                                     = kvm_host_data.fpmr (per-CPU)
```

**实际触发频率**：openeuler 的 eager flush 补丁（CVE-2025-22013）在 `kvm_arch_vcpu_load_fp()` 中调用 `fpsimd_save_and_flush_cpu_state()`，已经把 host FP 全部保存并 flush，`fp_owner` 被设为 `FP_STATE_FREE`。所以标准 VHE KVM 下这个分支几乎不会进入（`fp_owner` 不会是 `HOST_OWNED`）。它实际服务于 **pKVM 场景**——pKVM 的 hyp 代码可能在 trap 发生时仍持有 host FP 状态。

---

### 改动 3：Guest FPMR 恢复（陷阱处理中）

**文件**: `arch/arm64/kvm/hyp/include/hyp/switch.h` — 同上函数，在 guest 状态恢复之后

```c
/* Restore the guest state */
if (sve_guest)
    __hyp_sve_restore_guest(vcpu);
else
    __fpsimd_restore_state(&vcpu->arch.ctxt.fp_regs);

+if (kvm_has_fpmr(kern_hyp_va(vcpu->kvm)))
+    write_sysreg_s(__vcpu_sys_reg(vcpu, FPMR), SYS_FPMR);
```

**时机**：同上，在保存 host 状态之后、恢复 guest 状态时。位于 FPSIMD/SVE 状态恢复之后。

**做的事**：从 vcpu 的 sysreg 数组中读出 guest 的 FPMR 值，写入硬件寄存器。

**数据流**：

```
__vcpu_sys_reg(vcpu, FPMR)  ──(write_sysreg_s)──>  硬件 SYS_FPMR
   (vcpu 内存中的 guest 值)                           (物理寄存器)
```

**关键细节**：

- `kvm_has_fpmr()` 做双重检查：物理 CPU 是否支持 FPMR（`system_supports_fpmr()`）+ 该 VM 是否配置了 FPMR（检查 `ID_AA64PFR2_EL1.FPMR` 字段）
- `kern_hyp_va()` 在 nVHE 模式下做 hyp VA → kernel VA 转换（VHE 下是 no-op），因为 `kvm_has_fpmr()` 内部调用的 `kvm_read_vm_id_reg()` 需要 kernel VA
- 返回 guest 后，FPEN 陷阱已被清除，guest 后续所有 FP 操作直接走硬件，**零开销**

---

### 改动 4：Guest FPMR 惰性回写指针注册（VM Exit 侧）

**文件**: `arch/arm64/kvm/fpsimd.c` — 函数 `kvm_arch_vcpu_ctxsync_fp()`

```c
fp_state.sve_vl = vcpu->arch.sve_max_vl;
fp_state.sme_state = NULL;
fp_state.svcr = &vcpu->arch.svcr;
+fp_state.fpmr = &__vcpu_sys_reg(vcpu, FPMR);
fp_state.fp_type = &vcpu->arch.fp_type;

if (vcpu_has_sve(vcpu))
    fp_state.to_save = FP_STATE_SVE;
else
    fp_state.to_save = FP_STATE_FPSIMD;

fpsimd_bind_state_to_cpu(&fp_state);
```

**时机**：每次 VM exit 后，host 侧 `kvm_arch_vcpu_ctxsync_fp()` 被调用。

**做的事**：**不直接保存 FPMR**。只是把 `fp_state.fpmr` 指针指向 vcpu sysreg 数组中 FPMR 的槽位，然后调用 `fpsimd_bind_state_to_cpu(&fp_state)` 把这个 `fp_state` 记录到 per-CPU 变量 `last` 中。

**真正的保存延迟到之后**——当 host 内核需要使用 FP 硬件时，fpsimd 框架的通用保存路径通过 `last->fpmr` 指针自动把硬件 FPMR 写回 vcpu：

```c
// arch/arm64/kernel/fpsimd.c 中的通用保存路径（已有代码，非本补丁）
if (system_supports_fpmr())
    *(last->fpmr) = read_sysreg_s(SYS_FPMR);
//   ↑ last->fpmr 指向 &__vcpu_sys_reg(vcpu, FPMR)
//     所以：硬件 FPMR → guest vcpu sysreg 数组，完成惰性回写
```

**数据流**：

```
硬件 SYS_FPMR  ──(read_sysreg_s)──>  *(last->fpmr)
    │                                   │
    │                                   └── &__vcpu_sys_reg(vcpu, FPMR)
    │                                        = vcpu->arch.ctxt.sys_regs[FPMR]
    │
    └── 触发时机：host 内核调用 kernel_neon_begin()
                 或 fpsimd_save_and_flush_cpu_state()
                 或 __fpsimd_save_state()
```

---

## 完整状态机与数据流

```
时间线 ─────────────────────────────────────────────────────────────►

[vcpu_load]               [Guest 首次 FP 指令]            [VM Exit]
    │                            │                            │
    │ eager flush:               │ CPTR_EL2 陷阱!             │ ctxsync_fp():
    │ host FP 已存入内存         │                            │ last->fpmr =
    │ fp_owner = FREE            ▼                            │   &vcpu→FPMR
    │                   kvm_hyp_handle_fpsimd()              │
    │                   ┌────────────────────────┐           │
    │                   │ 1. 禁用 CPTR 陷阱      │           │
    │                   │    isb()               │           │
    │                   │                        │           │
    │                   │ 2. [pKVM] 保存host:    │           │
    │                   │    *fpmr = FPMR_hw     │           │
    │                   │                        │           │
    │                   │ 3. 恢复 guest FP/SVE   │           │
    │                   │                        │           │
    │                   │ 4. 恢复 guest FPMR:    │           │
    │                   │    FPMR_hw = vcpu→FPMR │           │
    │                   │                        │           │
    │                   │ 5. fp_owner = GUEST    │           │
    │                   │                        │           │
    │                   │ 6. 重新启用 CPTR 陷阱  │           │
    │                   └────────────────────────┘           │
    │                            │                            │
    ▼                            ▼                            ▼
  FPMR_hw:                   FPMR_hw:                    FPMR_hw:
  (任意/0)                   guest 的值                  guest 的值 (仍在硬件中!)
                                                             │
                                                    [稍后 host 需要 FP 硬件时]
                                                    fpsimd_save():
                                                      *last→fpmr = FPMR_hw
                                                      → guest FPMR 安全存入 vcpu
                                                      → 然后恢复 host FPMR:
                                                        FPMR_hw = current→fpmr
```

**四个改动在流程中的位置**：

```
                    ┌─────────────────────────────────┐
                    │     kvm_hyp_handle_fpsimd()     │
                    │                                 │
                    │  改动2: 保存 host FPMR          │
                    │  *fpmr = read_sysreg(FPMR)      │
                    │                                 │
                    │  改动3: 恢复 guest FPMR         │
                    │  write_sysreg(vcpu→FPMR, FPMR)  │
                    │                                 │
                    │  改动1: fpmr 存储在这里          │
                    │  kvm_host_data.fpmr             │
                    └─────────────────────────────────┘

                    ┌─────────────────────────────────┐
                    │  kvm_arch_vcpu_ctxsync_fp()     │
                    │                                 │
                    │  改动4: 注册 guest FPMR 回写指针 │
                    │  last->fpmr = &vcpu→FPMR        │
                    └─────────────────────────────────┘
```

---

## 与主线的差异

| 方面 | 主线 (v6.11) | openEuler (6.6) | 原因 |
|------|-------------|-----------------|------|
| `kvm_host_data` 中的 FPMR | `u64 *fpmr_ptr`（指针） | `u64 fpmr`（值） | openEuler 用 eager flush，不需要维护指向 host 内存的指针 |
| vcpu_load 时注册 host FPMR | `*host_data_ptr(fpmr_ptr) = &current->thread.uw.fpmr` | 不需要 | eager flush 已保存，host FPMR 安全在 `current->thread.uw.fpmr` 中 |
| `kvm_hyp_save_fpsimd_host()` | 独立函数，pKVM 专用 | 内联在 `kvm_hyp_handle_fpsimd()` 中 | 逻辑等价，减少函数调用层级 |
| nVHE `fpsimd_sve_sync()` | 有 FPMR 保存/恢复 | 未适配 | eager save+flush + lazy switch 已覆盖该路径 |
| `fpmr` union 类型 | `u64 fpmr` + `u64 *fpmr_ptr` 的 union | 直接 `u64 fpmr` | 简化，openEuler 6.6 无此需求 |

---

## 关键设计决策

### 为什么 hyp 侧只管"装"，host 侧只管"卸"

这是一种**职责分离**设计：

- **hyp 侧**（EL2）：负责在 trap 处理时把 guest FPMR "装"到硬件寄存器（改动 3），让 guest 能立即使用
- **host 侧**（EL1）：通过惰性指针（改动 4）在 host 需要 FP 时自动把 guest FPMR 从硬件"卸"到 vcpu 内存

两边通过 per-CPU 变量 `last->fpmr` 串联，不需要额外的同步或通信。hyp 侧不知道也不需要知道 host 侧何时回写；host 侧的 fpsimd 框架不知道也不需要知道 guest FPMR 是什么时候装到硬件里的。

### 为什么标准 KVM 下改动 2 几乎不触发

openEuler 的 eager save+flush 在 `kvm_arch_vcpu_load_fp()` 中做了：

```c
fpsimd_save_and_flush_cpu_state();   // 保存当前 host FP，清空硬件
*host_data_ptr(fp_owner) = FP_STATE_FREE;  // 标记硬件为空闲
```

所以 VM entry 时 `fp_owner` 始终是 `FP_STATE_FREE`，改动 2 的条件 `fp_owner == FP_STATE_HOST_OWNED` 不成立。但在 **pKVM** 中，hyp 代码可能在 guest 运行期间执行（例如处理 stage-2 缺页），此时 hyp 可能持有 host 的 FP 状态，`fp_owner` 为 `HOST_OWNED`，保存路径就会被触发。

---

## 前置依赖

此补丁依赖以下架构层支持（来自主线 v6.9 FPMR 架构回合，非 KVM）：

| 依赖项 | 位置 |
|--------|------|
| `system_supports_fpmr()` | `arch/arm64/include/asm/cpufeature.h` |
| `cpu_fp_state.fpmr` 成员 | `arch/arm64/include/asm/fpsimd.h` |
| `SYS_FPMR` 寄存器编码 | `arch/arm64/tools/sysreg` → 生成 `arch/arm64/include/asm/sysreg.h` |
| `kvm_host_data` + `host_data_ptr()` 机制 | 已有，OLK-6.6 已存在 |
| `fpsimd_bind_state_to_cpu()` | 已有，OLK-6.6 已存在 |
| `kvm_read_vm_id_reg()` | 已有，OLK-6.6 已存在 |
