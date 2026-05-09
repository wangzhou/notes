KVM ARM64 FP/SIMD Lazy Switch机制原理
======================================

-v0.1 2026.05.09 Sherlock init

简介：分析KVM/ARM64虚拟化中浮点寄存器惰性切换(Lazy Switch)的设计原理与实现细节，
      基于openEuler v6.6内核。


## 1. 基本逻辑

KVM 虚拟化中，host和guest共用同一套物理FP/SIMD寄存器，最直观的做法是每次VM entry/exit
和host线程使用FP/SIMD都完整保存和恢复这组寄存器。但是，FP/SIMD并是每个线程或者VM
都要使用，每次使用都做保存和恢复造成了很多比必要的开销。

ARM内核和KVM使用惰性切换(Lazy Switch)的机制解决这个问题。基本逻辑是这些寄存器尽
可能不保存回软件的数据结构里，直到有其他vCPU或者host线程要上线使用这些寄存器，才
把这些寄存器的值保存回vCPU或者host线程对应的软件数据结构里。

具体的做法是，物理CPU用一个全局变量保存这些寄存器应该被保存到的软件数据结构的地址，
当需要保存的时候，就直接保存。

展开看下实现如上所要满足的所有逻辑。

1. host线程/host内核使用FP/SIMD应该有自己的lazy switch逻辑。比如，多个host线程
   在一个物理核上调度，各个线程都独立的使用FP/SIMD寄存器。(todo)

2. KVM一开始配置vCPU使用FP/SIMD时会trap，KVM负责查看FP/SIMD寄存器是否被其他vCPU
   或者host使用。如果是，就需要保存这些寄存器寄存器，然后换上当前vCPU的相关寄存器。
   然后配置为不trap，返回虚机重新执行相关指令。

3. vCPU正常执行FP/SIMD指令(不trap)，vCPU下线的时候需要保存FP/SIMD寄存器。

4. vCPU exit的时候只更新如上全局变量，指示要把寄存器保存在哪里。

   **注意**：这里的vCPU下线和vCPU exit的语义不同，前者是说vCPU线程被调度出这个物理
   核(会调用vcpu_put)，后者是说，物理core从EL0/EL1退到EL2，但是当前还在这个vCPU
   线程里。这两者的区别是，后者vCPU线程还在当前物理核上，guest可能马上又投入运行。
   所以，vCPU exit时，没有必要把FP/SIMD寄存器保存到软件结构。

5. Host使用FP/SIMD的时候，如果有vCPU在用这些寄存器，需要先保存这些寄存器，然后
   换成host的对应寄存器。

   **注意**：host可能在任何时候使用这些寄存器，比如内核crypto里使用NEON指令，所以
   并不是vCPU下线时保存寄存器没法满足这里，比如host内核中断vCPU运行，先处理host
   中断时就有可能使用FP/SIMD。



## 2. 核心数据结构

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
void kvm_arc
```
_vcpu_put_fp(struct kvm_vcpu *vcpu)
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
