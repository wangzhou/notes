KVM ARM64 FP Lazy Switch机制原理
===--------------------------------

-v0.1 2026.05.09 Sherlock init

简介：分析 KVM/ARM64 虚拟化中浮点寄存器惰性切换(Lazy Switch)的
设计原理与实现细节，涵盖 CPTR_EL2 硬件陷阱机制、hyp/host 两侧协作
流程、状态机设计，以及 FPMR 寄存器如何融入该框架。


## 1. 高层概述

### 1.1 问题

KVM 虚拟化中，host 和 guest 共用同一套物理 FP/SIMD 寄存器——
32个 128-bit Q 寄存器 + FPSR + FPCR + 可能的 SVE 向量寄存器，
总计可达数 KB。最简单的做法是每次 VM entry/exit 都完整保存和恢复
这组寄存器。但核心矛盾在于：

**大部分 guest 在被调度的时间片内根本不执行浮点指令。**
一个处理网络栈的 guest、一个跑 HTTP 服务的 guest，可能整个调度周期
(数 ms)内一条 FP 指令都没执行过。每次 entry/exit 都搬运几 KB 的
寄存器数据是纯粹的浪费。

### 1.2 解决思路

惰性切换(Lazy Switch)的核心思想只有一句话：

> **guest 不访问 FP 硬件就不切，只有 guest 真执行了 FP 指令才切。**

实现手段：利用硬件提供的 CPTR_EL2 控制寄存器。在 guest 入口处设置
一道"安检门"——任何 FP 指令都会触发异常(trap)进入 hypervisor。
KVM 在异常处理中完成上下文切换，然后拆除安检门。之后 guest 就可以
直接访问 FP 硬件，不再产生任何开销。

### 1.3 核心机制(30 秒版)

```
                     KVM 设置 CPTR_EL2 陷阱
                     (guest 无 FP 访问权限)
                              │
                              ▼
                     Guest 执行 FP 指令
                              │
                              ▼
                     硬件触发异常 → VM Exit
                              │
                              ▼
                     KVM 陷阱处理函数:
                     ① 保存 host FP (如果 host 还持有硬件)
                     ② 恢复 guest FP 到硬件
                     ③ 授予 guest FP 访问权限
                     ④ 返回 guest 重试那条 FP 指令
                              │
                              ▼
                     Guest 后续 FP 指令直接走硬件
                     (零额外开销, 直到 VM Exit)
```

### 1.4 核心数据结构关系

惰性切换依赖三个层次的 per-CPU 和 per-vCPU 数据结构协作：

```
per-CPU (hyp side)              per-vCPU                  per-CPU (host side)
┌─────────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│ kvm_host_data       │    │ kvm_vcpu_arch    │    │ cpu_fp_state  *last │
│                     │    │                  │    │                     │
│ fp_owner ───────────┼───►│ ctxt.fp_regs     │◄───│ st                  │
│   FREE/HOST/GUEST   │    │ sve_state        │◄───│ sve_state           │
│                     │    │ sys_regs[FPMR]   │◄───│ fpmr                │
│ host_ctxt           │    │ svcr             │◄───│ svcr                │
│ fpmr (host staging) │    │ fp_type          │◄───│ fp_type             │
└─────────────────────┘    └──────────────────┘    └─────────────────────┘

    fp_owner decides                when fp_owner == GUEST_OWNED,
    whose FP data is in             last points to guest fp_state,
    hardware                        fpsimd_save() writes back
                                    guest values via last ptr
```

`fp_owner` 是整个状态机的核心——它是一个三态标志，记录 FP 硬件当前
"属于"谁。`last` 是 host 侧 fpsimd 框架用来知道"硬件里装的是谁的
FP 数据"的指针。这两个变量配合，使得 hyp 侧和 host 侧不需要直接通信
就能协同工作。

### 1.5 状态机(全貌)

```
                         kvm_arch_vcpu_load_fp()
       FP_STATE_FREE ───────────────────────────────► FP_STATE_FREE
       (hardware idle)                                (confirmed clean)
            │                                                │
            │ __activate_traps():                            │
            │ setup FP traps                                 │
            ▼                                                ▼
      ┌───────────┐    first guest FP → trap          ┌──────────────┐
      │ Guest run │ ─────────────────────────────────► │ hyp handler  │
      │ (no FP)   │                                    │              │
      │           │ ◄───────────────────────────────── │ save host FP │
      └───────────┘   return to guest, FPEN enabled    │ restore guest│
            │                                           │ fp_owner =  │
            │ guest FP direct hw access, zero cost       │   GUEST     │
            ▼                                           └──────────────┘
      ┌───────────┐
      │ Guest run │    VM Exit (IRQ/timer)
      │ (owns FP) │ ─────────────────────────────────────┐
      └───────────┘                                       │
            │                                             ▼
            │                             kvm_arch_vcpu_ctxsync_fp()
            │                             register last->fpmr ptr
            │                             (lazy: no hw read yet)
            │                                             │
            ▼                                             ▼
      [if guest re-enters]                 [when host needs FP hw]
      fp_owner still GUEST                fpsimd_save():
      zero cost continue                   write back guest FP via last
                                           then restore host FP
```

---

## 2. 硬件基础

### 2.1 CPTR_EL2 寄存器

CPTR_EL2(Architectural Feature Trap Register, EL2)是 EL2 用来
控制低异常级别哪些操作需要"陷阱"的系统寄存器。对于 FP 惰性切换，
最关键的是两个位：

| Bit | 名称 | 作用 |
|-----|------|------|
| 21 | FPEN_EL0EN | =0 → EL0 FP/SIMD 指令 trap 到 EL2 |
| 20 | FPEN_EL1EN | =0 → EL1 FP/SIMD 指令 trap 到 EL2 |
| 17 | ZEN_EL0EN | =0 → EL0 SVE 指令 trap 到 EL2 |
| 16 | ZEN_EL1EN | =0 → EL1 SVE 指令 trap 到 EL2 |

当一个异常级别访问 FP/SIMD/SVE 寄存器、但对应的 CPACR/CPTR 位为 0
时，CPU 产生同步异常，ESR_EL2.EC 编码为：

- `0x07` — FP/ASIMD 访问被 trap
- `0x19` — SVE 访问被 trap

两种异常在 KVM 中路由到同一个处理函数 `kvm_hyp_handle_fpsimd()`。

### 2.2 VHE 与非 VHE 的差异

```
nVHE mode                                VHE mode
─────────                                ────────
EL2 (Hyp)                                EL2 (Host Kernel)
  │                                         │
  │ CPTR_EL2 always controlled by hyp       │ CPACR_EL1=CPTR_EL2 (hw alias)
  │ Host at EL1, FP access also traps       │ Host at EL2, direct FP access
  │ host FP trap → ESR_ELx_EC_SYS64        │
  │                                         │
  pros: hyp fully controls FP               pros: host FP no trap, faster
  cons: host FP must go through hyp         cons: needs ARMv8.1+ VHE hw
```

### 2.3 HCRX_EL2.EnFPM

ARMv9.4 引入的 FPMR 寄存器(FP8 模式控制)有一个独立的陷阱控制位
`HCRX_EL2.EnFPM`：

- `EnFPM = 0` → guest 访问 FPMR(`MRS/MSR S3_3_C4_C4_2`)产生
  `ESR_ELx_EC_SYS64` 陷阱
- `EnFPM = 1` → guest 可直接读写 FPMR

当 VM 支持 FPMR 时，KVM 设置此位为 1，让 guest 自由访问 FPMR 而
不产生额外的系统寄存器陷阱。FPMR 值本身的保存/恢复跟随 FP 惰性切换
一起完成，不需要独立的陷阱路径。

---

## 3. 实现细节

惰性切换的实现分布在 hyp 侧(EL2，切换发生时执行)和 host 侧(EL1，
切换前后管理)。以下按执行时间线展开。

### 3.1 VM Entry 前：清空 host FP

`arch/arm64/kvm/fpsimd.c` — `kvm_arch_vcpu_load_fp()`:

```c
void kvm_arch_vcpu_load_fp(struct kvm_vcpu *vcpu)
{
    if (!system_supports_fpsimd())
        return;

    /*
     * openEuler CVE-2025-22013: eager save+flush.
     * 把当前 CPU 上 host 任务的 FP 全部写回内存，清空硬件寄存器。
     */
    fpsimd_save_and_flush_cpu_state();

    /* 标记硬件为"空闲"，guest 可以占用 */
    *host_data_ptr(fp_owner) = FP_STATE_FREE;
    *host_data_ptr(fpsimd_state) = NULL;
}
```

`fpsimd_save_and_flush_cpu_state()` 内部：
1. 检查 per-CPU 变量 `last`——如果非空，说明 CPU FP 硬件里装的是
   某个 host 任务的 FP 数据
2. 调用 `fpsimd_save()` 把 Q0-Q31、FPSR、FPCR、FPMR(通过
   `last->fpmr`)写回 `task->thread.uw`
3. 清空 FP 硬件(或标记为无效)
4. 设置 `TIF_FOREIGN_FPSTATE`，host 下次用 FP 时会先恢复

**结果**: host FP 已安全存入内存。硬件处于"无人占用"状态。
`fp_owner = FREE`。

### 3.2 VM Entry：设置陷阱

`arch/arm64/kvm/hyp/vhe/switch.c` — `__activate_traps()`:

```c
/* VHE 模式下的 __activate_traps() */
if (guest_owns_fp_regs(vcpu)) {
    /* guest 在上轮运行中已持有 FP → 不设陷阱，直接放行 */
    if (vcpu_has_sve(vcpu))
        val |= CPACR_EL1_ZEN_EL0EN | CPACR_EL1_ZEN_EL1EN;
} else {
    /* guest 还没有 FP 权限 → 清除 FPEN，设置"安检门" */
    val &= ~(CPACR_EL1_FPEN_EL0EN | CPACR_EL1_FPEN_EL1EN);
}
write_sysreg(val, cpacr_el1);  /* VHE 下 CPACR_EL1 硬件别名 = CPTR_EL2 */
```

```c
static inline bool guest_owns_fp_regs(struct kvm_vcpu *vcpu)
{
    return *host_data_ptr(fp_owner) == FP_STATE_GUEST_OWNED;
}
```

**首次 VM entry**：`fp_owner == FREE` → 清除 FPEN → guest 任何
FP 指令 trap。

**后续 VM entry**(guest 上轮已持有 FP 且未被调度出去)：
`fp_owner == GUEST_OWNED` → FPEN 保持置位 → guest FP 直通硬件，
零开销进入。

### 3.3 陷阱触发与分发

guest 执行第一条 FP 指令时的硬件流程：

```
Guest EL1:  FADD D0, D1, D2
                │
                ▼
CPU check CPTR_EL2.FPEN == 0  →  trigger sync exception
                │
                ▼
ESR_EL2.EC = 0x07 (FP/ASIMD)   →  VM Exit to EL2
                │
                ▼
__guest_enter() returns
                │
                ▼
fixup_guest_exit() → kvm_hyp_handle_exit()
                │
                ▼
lookup hyp_exit_handlers[]:
  [ESR_ELx_EC_FP_ASIMD] = kvm_hyp_handle_fpsimd
  [ESR_ELx_EC_SVE]      = kvm_hyp_handle_fpsimd
```

FP/ASIMD 和 SVE 两种陷阱都路由到同一个处理函数。

### 3.4 陷阱处理核心

`arch/arm64/kvm/hyp/include/hyp/switch.h` —
`kvm_hyp_handle_fpsimd()`:

```c
static inline bool kvm_hyp_handle_fpsimd(struct kvm_vcpu *vcpu,
                                         u64 *exit_code)
{
    bool sve_guest = vcpu_has_sve(vcpu);
    u8 esr_ec = kvm_vcpu_trap_get_class(vcpu);
    u64 reg;

    // ── step 1: validate trap type ──
    switch (esr_ec) {
    case ESR_ELx_EC_FP_ASIMD:
        break;                          /* legit: FP/SIMD trap */
    case ESR_ELx_EC_SVE:
        if (!sve_guest) return false;   /* guest has no SVE → skip */
        break;
    case ESR_ELx_EC_SYS64:
        /* nVHE: host at EL1 accessing FP also hits this EC */
        if (WARN_ON_ONCE(!is_hyp_ctxt(vcpu)))
            return false;
        fallthrough;
    default:
        return false;
    }

    // ── step 2: temporarily disable traps ──
    // traps still active → hyp itself can't touch FP (nested trap)
    if (has_vhe() || has_hvhe()) {
        reg = CPACR_EL1_FPEN_EL0EN | CPACR_EL1_FPEN_EL1EN;
        if (sve_guest)
            reg |= CPACR_EL1_ZEN_EL0EN | CPACR_EL1_ZEN_EL1EN;
        sysreg_clear_set(cpacr_el1, 0, reg);
    } else {
        reg = CPTR_EL2_TFP;
        if (sve_guest) reg |= CPTR_EL2_TZ;
        sysreg_clear_set(cptr_el2, reg, 0);
    }
    isb();  /* ensure trap disable is visible to subsequent insns */

    // ── step 3: [conditional] save host FP ──
    if (*host_data_ptr(fp_owner) == FP_STATE_HOST_OWNED) {
        __fpsimd_save_state(*host_data_ptr(fpsimd_state));
        if (system_supports_fpmr())
            *host_data_ptr(fpmr) = read_sysreg_s(SYS_FPMR);
    }

    // ── step 4: restore guest FP ──
    if (sve_guest)
        __hyp_sve_restore_guest(vcpu);
    else
        __fpsimd_restore_state(&vcpu->arch.ctxt.fp_regs);

    if (kvm_has_fpmr(kern_hyp_va(vcpu->kvm)))
        write_sysreg_s(__vcpu_sys_reg(vcpu, FPMR), SYS_FPMR);

    // ── step 5: transfer ownership ──
    *host_data_ptr(fp_owner) = FP_STATE_GUEST_OWNED;

    return true;  /* return to guest, retry the trapped insn */
}
```

**步骤 3 为何在 openEuler 下几乎不触发**：openEuler 的 eager flush
在 `vcpu_load` 时已经把 host FP 保存并清空，`fp_owner` 被设为
`FREE`，不是 `HOST_OWNED`。因此这个分支主要为 **pKVM** 场景设计
——pKVM 的 hyp 代码可能在 guest 运行期间执行(例如处理 stage-2 缺页)，
此时 hyp 可能持有 host FP 状态。

**步骤 4 的顺序有讲究**：FPMR 恢复放在 FPSIMD/SVE 之后。先恢复
数据寄存器(Q0-Q31)，再恢复控制寄存器(FPMR)，防止控制寄存器影响
后续数据加载的解释方式。

### 3.5 VM Exit：惰性回写注册

`arch/arm64/kvm/fpsimd.c` — `kvm_arch_vcpu_ctxsync_fp()`:

```c
void kvm_arch_vcpu_ctxsync_fp(struct kvm_vcpu *vcpu)
{
    struct cpu_fp_state fp_state;

    if (*host_data_ptr(fp_owner) == FP_STATE_GUEST_OWNED) {
        /*
         * guest owns FP hw → register writeback ptr, but don't
         * read hw yet. this is "lazy": guest FP values may be
         * reused soon; reading them out now is wasteful.
         */

        fp_state.st        = &vcpu->arch.ctxt.fp_regs;   /* Q0-Q31 */
        fp_state.sve_state = vcpu->arch.sve_state;       /* Z regs */
        fp_state.sve_vl    = vcpu->arch.sve_max_vl;
        fp_state.sme_state = NULL;
        fp_state.svcr      = &vcpu->arch.svcr;
        fp_state.fpmr      = &__vcpu_sys_reg(vcpu, FPMR); /* FPMR */
        fp_state.fp_type   = &vcpu->arch.fp_type;

        fp_state.to_save = vcpu_has_sve(vcpu) ? FP_STATE_SVE
                                               : FP_STATE_FPSIMD;

        /*
         * key: register this fp_state into per-CPU variable "last".
         * later, when host needs FP hw, fpsimd framework auto-
         * matically writes hw regs → vcpu memory via last ptr.
         */
        fpsimd_bind_state_to_cpu(&fp_state);
        clear_thread_flag(TIF_FOREIGN_FPSTATE);
    }
}
```

`fpsimd_bind_state_to_cpu()` 的实现极其简单——把指针写进 per-CPU
变量：

```c
/* arch/arm64/kernel/fpsimd.c */
static void fpsimd_bind_state_to_cpu(struct cpu_fp_state *state)
{
    __this_cpu_write(last, state);
}
```

真正的保存发生在 host 后续需要 FP 时，host 内核的通用 fpsimd 路径：

```c
/* arch/arm64/kernel/fpsimd.c — generic save, not KVM code */
static void fpsimd_save(void)
{
    struct cpu_fp_state *last = __this_cpu_read(last);

    /* save FPSIMD or SVE main regs */
    if (last->to_save == FP_STATE_SVE)
        sve_save_state(last->sve_state, last->st);
    else
        __fpsimd_save_state(last->st);   /* last->st = vcpu→fp_regs */

    /* control regs follow main regs */
    if (system_supports_fpmr())
        *(last->fpmr) = read_sysreg_s(SYS_FPMR);
        /*   ↑ hw FPMR → vcpu→sys_regs[FPMR] */

    if (system_supports_sme())
        *last->svcr = read_sysreg_s(SYS_SVCR);
}
```

这个函数不知道也不关心 `last->fpmr` 指向的是 host 任务还是 guest
vCPU——它只认 `last` 指针。这种**多态性**是惰性切换设计的精髓。

### 3.6 vCPU 换出：强制保存

`arch/arm64/kvm/fpsimd.c` — `kvm_arch_vcpu_put_fp()`:

```c
void kvm_arch_vcpu_put_fp(struct kvm_vcpu *vcpu)
{
    unsigned long flags;
    local_irq_save(flags);

    if (*host_data_ptr(fp_owner) == FP_STATE_GUEST_OWNED) {
        /*
         * vCPU is being scheduled out, guest FP is still in hw.
         * force save and flush to prevent leaking to next host task.
         */
        fpsimd_save_and_flush_cpu_state();
    }

    local_irq_restore(flags);
}
```

`fpsimd_save_and_flush_cpu_state()` 内部调用 `fpsimd_save()`，
通过 `last` 指针(此时指向 guest)把 guest FP + FPMR 全部写回 vCPU，
然后清空硬件。此后 `fp_owner` 变为 `FREE`，下一个 host 任务可以
安全使用 FP。

---

## 4. 时间线总览

下面以一个完整的"guest 从不碰 FP → 首次碰 FP → 被中断 → host 用
FP"的典型场景，展示所有阶段如何衔接：

```
═══════════════════════════════════════════════════════════════════════
time ───────────────────────────────────────────────────────────────►
═══════════════════════════════════════════════════════════════════════

[1] vcpu_load              [2] VM Entry             [3] first guest FP
     │                           │                       │
     │ fpsimd_save_and_          │ __activate_traps()    │ FADD D0, D1, D2
     │   flush_cpu_state()       │ clear FPEN            │ CPTR_EL2.FPEN==0
     │ host FP → memory          │                       │ → TRAP!
     │ fp_owner = FREE           │                       │
     │                           │                       ▼
     │                           │              [4] kvm_hyp_handle_fpsimd
     │                           │                 ① disable CPTR traps
     │                           │                 ② [pKVM] save host FP+FPMR
     │                           │                 ③ __fpsimd_restore_state()
     │                           │                 ④ write_sysreg(vcpu→FPMR)
     │                           │                 ⑤ fp_owner = GUEST_OWNED
     │                           │                 ⑥ return to guest
     │                           │                       │
     ▼                           ▼                       ▼
  hw: (empty)                hw: (empty)            hw: guest values
  fp_owner: FREE            fp_owner: FREE         fp_owner: GUEST_OWNED
  FPEN: -                   FPEN: 0 (trap)         FPEN: 1 (direct)

═══════════════════════════════════════════════════════════════════════

[5] guest FP direct          [6] VM Exit (timer)       [7] host uses FP
     │                            │                         │
     │ FADD, FMUL, ...            │ kvm_arch_vcpu_          │ kernel_neon_begin()
     │ all direct hw access       │   ctxsync_fp()          │   ↓
     │ zero cost                  │                         │ fpsimd_save()
     │                            │ fp_state.fpmr =         │ *(last→fpmr)=
     │                            │   &vcpu→FPMR           │   read_sysreg(FPMR)
     │                            │ fpsimd_bind_state_     │ guest FPMR → vcpu
     │                            │   to_cpu(&fp_state)    │
     │                            │                         │ fpsimd_restore_
     │                            │ last = &guest_fp_state  │   current_state()
     │                            │ (lazy, no hw read)      │ host FPMR → hw
     │                            │                         │
     ▼                            ▼                         ▼
  hw: guest values           hw: guest values (still!) hw: host values
  fp_owner: GUEST_OWNED      fp_owner: GUEST_OWNED    fp_owner: HOST_OWNED
  FPEN: 1 (direct)           FPEN: 1 (direct)         FPEN: 1 (direct)
```

---

## 5. FPMR 在惰性切换中的位置

FPMR 不单独管理，完全融入上述框架。在 hyp 侧和 host 侧分别有自己的
职责：

```
           hyp side (EL2)                      host side (EL1)
    ┌──────────────────────┐           ┌──────────────────────────┐
    │ trap handler (step 4)│           │ ctxsync_fp (phase 6):    │
    │ load guest FPMR into │           │ register last->fpmr ptr  │
    │ hardware register    │           │ → vcpu→sys_regs[FPMR]   │
    │                      │           │                          │
    │ trap handler (step 3)│           │ fpsimd_save (phase 7):   │
    │ store host FPMR into │           │ write hw FPMR → vcpu    │
    │ host_data.fpmr       │           │ memory via last->fpmr   │
    └──────────────────────┘           └──────────────────────────┘
            │                                      │
            │      same hardware FPMR register     │
            └────────────────┬─────────────────────┘
                             │
                        SYS_FPMR
                    (S3_3_C4_C4_2)
```

职责分离：
- **hyp 侧**：在 trap handler 中把 guest FPMR 装到硬件，让 guest
  能立即使用
- **host 侧**：通过惰性指针在 host 需要 FP 硬件时把 guest FPMR 从
  硬件卸到 vCPU 内存

两边通过 `last->fpmr` 指针串联，不需要额外的同步机制。

---

## 6. 开销分析

| 场景 | 频率 | 保存 | 恢复 | 总开销 |
|------|------|:---:|:---:|------|
| vCPU 首次用 FP | 每 vCPU 生命周期 1 次 | no | yes | 一次性陷阱开销(~几百周期) |
| vCPU 短暂 exit 后立即返回 | 高频(每 ms 级) | no | no | 零 |
| vCPU 被调度出去 | 中频(ms~s) | yes | yes | ~几百周期 |
| host 内核主动用 FP | 低频(偶发) | yes | yes | 完整往返 |

核心价值在第二行：guest 运行期间反复发生的中断 exit 不会触发任何
FP 保存/恢复。因为 FPEN 保持置位、`fp_owner` 保持 `GUEST_OWNED`
——guest 的 FP 寄存器一直留在硬件里。

---

## 7. 关键文件索引

| 文件 | 作用 |
|------|------|
| `arch/arm64/kvm/hyp/include/hyp/switch.h` | `kvm_hyp_handle_fpsimd()` 陷阱处理核心 |
| `arch/arm64/kvm/hyp/vhe/switch.c` | `__activate_traps()` VHE 模式陷阱设置 |
| `arch/arm64/kvm/hyp/nvhe/switch.c` | nVHE 模式陷阱设置 |
| `arch/arm64/kvm/hyp/nvhe/hyp-main.c` | `fpsimd_sve_sync()` nVHE VM Exit 同步 |
| `arch/arm64/kvm/fpsimd.c` | host 侧: load/ctxsync/put |
| `arch/arm64/kernel/fpsimd.c` | host fpsimd 框架: save/restore/bind |
| `arch/arm64/include/asm/kvm_host.h` | `kvm_host_data`, `kvm_vcpu_arch`, `kvm_has_fpmr()` |
| `arch/arm64/include/asm/fpsimd.h` | `cpu_fp_state` 结构体 |
