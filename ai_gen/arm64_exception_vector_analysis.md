# ARM64 异常向量表实现分析

ARM64 异常向量表的实现在 Linux 内核中分为**三层**：汇编层向量表入口（`entry.S`）→ 汇编层 handler 分发（`entry.S`）→ C 层处理（`entry-common.c`）。

---

## 一、硬件背景

ARM64 架构定义了 4 种异常类型 × 4 种发生上下文 = **16 个向量槽位**：

| | Sync | IRQ | FIQ | Error |
|---|---|---|---|---|
| **EL1t** (SP_EL0) | ✓ | ✓ | ✓ | ✓ |
| **EL1h** (SP_EL1) | ✓ | ✓ | ✓ | ✓ |
| **EL0 64-bit** (SP_EL0) | ✓ | ✓ | ✓ | ✓ |
| **EL0 32-bit** (SP_EL0) | ✓ | ✓ | ✓ | ✓ |

向量表的基地址存放在 `VBAR_EL1` 寄存器中，每条向量占 128 字节（`.align 7`），整个表 2KB 对齐（`.align 11`）。

---

## 二、`kernel_ventry` 宏 —— 每条向量的前 128 字节

定义在 `arch/arm64/kernel/entry.S:39-101`：

```asm
.macro kernel_ventry, el:req, ht:req, regsize:req, label:req
    .align 7                                // 每条向量 128 字节
.Lventry_start\@:
    .if \el == 0
    b   .Lskip_tramp_vectors_cleanup\@      // EL0 的第一条指令，trampoline 会跳过
    // 保存 / 清除 tpidrro_el0（用于 spectre 缓解）
    .endif

    sub sp, sp, #PT_REGS_SIZE               // 在栈上预留 pt_regs 空间
    // 栈溢出检测：
    add  sp, sp, x0                          // sp' = sp + x0
    sub  x0, sp, x0                          // x0' = sp
    tbnz x0, #THREAD_SHIFT, 0f              // 测试 THREAD_SHIFT bit
    sub  x0, sp, x0                          // 恢复 x0
    sub  sp, sp, x0                          // 恢复 sp
    b    el\el\ht\()_\regsize\()_\label     // 跳转到具体 handler

0:  // 栈溢出路径：切换到 overflow_stack
    msr  tpidr_el0, x0                       // 保存原始 SP
    sub  x0, sp, x0
    msr  tpidrro_el0, x0                     // 保存原始 x0
    adr_this_cpu sp, overflow_stack + OVERFLOW_STACK_SIZE, x0
    // 检查是否已在 overflow stack 上
    mrs  x0, tpidr_el0
    sub  x0, sp, x0
    tst  x0, #~(OVERFLOW_STACK_SIZE - 1)
    b.ne __bad_stack                         // 不在 → 真正的 bad stack
    sub  sp, sp, x0                          // 恢复，继续执行
    mrs  x0, tpidrro_el0
    b    el\el\ht\()_\regsize\()_\label
.org .Lventry_start\@ + 128                  // 确保不溢出 128 字节
.endm
```

核心技巧：**栈溢出检测**利用进程栈/IRQ 栈按 `THREAD_SIZE` 对齐的特性 —— 如果 SP 的 `THREAD_SHIFT` 位为 1，说明 SP 已越界。

---

## 三、主向量表 `vectors`

定义在 `entry.S:519-539`：

```asm
.align 11
SYM_CODE_START(vectors)
    kernel_ventry 1, t, 64, sync    // Synchronous EL1t
    kernel_ventry 1, t, 64, irq     // IRQ EL1t
    kernel_ventry 1, t, 64, fiq     // FIQ EL1t
    kernel_ventry 1, t, 64, error   // Error EL1t

    kernel_ventry 1, h, 64, sync    // Synchronous EL1h
    kernel_ventry 1, h, 64, irq     // IRQ EL1h
    kernel_ventry 1, h, 64, fiq     // FIQ EL1h
    kernel_ventry 1, h, 64, error   // Error EL1h

    kernel_ventry 0, t, 64, sync    // Synchronous 64-bit EL0
    kernel_ventry 0, t, 64, irq     // IRQ 64-bit EL0
    kernel_ventry 0, t, 64, fiq     // FIQ 64-bit EL0
    kernel_ventry 0, t, 64, error   // Error 64-bit EL0

    kernel_ventry 0, t, 32, sync    // Synchronous 32-bit EL0
    kernel_ventry 0, t, 32, irq     // IRQ 32-bit EL0
    kernel_ventry 0, t, 32, fiq     // FIQ 32-bit EL0
    kernel_ventry 0, t, 32, error   // Error 32-bit EL0
SYM_CODE_END(vectors)
```

几个注意点：
- **不存在 EL1 32-bit**，ARM64 kernel 永远运行在 64 位模式
- **内核态只收 t/h（SP_EL0/SP_EL1）**，正常时用 `h`（SP_EL1），`t` 仅特殊场景（如 idle、kthread 还没切换 SP 时）
- **用户态只收 t**（SP_EL0），32/64 bit 各有 4 条

---

## 四、`entry_handler` —— 汇编层 handler 模板

定义在 `entry.S:570-581`：

```asm
.macro entry_handler el:req, ht:req, regsize:req, label:req
SYM_CODE_START_LOCAL(el\el\ht\()_\regsize\()_\label)
    kernel_entry \el, \regsize          // 保存所有 GPR 到栈上 pt_regs
    mov  x0, sp                          // x0 = pt_regs 指针（C 函数第一参数）
    bl   el\el\ht\()_\regsize\()_\label\()_handler   // 调用 C handler
    .if \el == 0
    b    ret_to_user                     // 返回用户态
    .else
    b    ret_to_kernel                   // 返回内核态
    .endif
SYM_CODE_END(el\el\ht\()_\regsize\()_\label)
.endm
```

随后 `entry_handler` 被展开 12 次（如 `el1h_64_sync`、`el0t_64_irq` 等），每个都调用对应的 C 函数。

`kernel_entry` 宏（`entry.S:197`）负责：保存 x0-x29、设置 SP_EL0（EL0 进入时）、保存 `elr_el1`/`spsr_el1`、处理 MTE/PTR_AUTH/SSBD 等。

---

## 五、C 层 handler 处理（`entry-common.c`）

### 5.1 EL1 同步异常：`el1h_64_sync_handler`（entry-common.c:430）

```c
asmlinkage void noinstr el1h_64_sync_handler(struct pt_regs *regs)
{
    unsigned long esr = read_sysreg(esr_el1);
    switch (ESR_ELx_EC(esr)) {
    case ESR_ELx_EC_DABT_CUR:        // Data Abort (current EL)
    case ESR_ELx_EC_IABT_CUR:        // Instruction Abort (current EL)
        el1_abort(regs, esr);
        break;
    case ESR_ELx_EC_PC_ALIGN:        // PC alignment fault
        el1_pc(regs, esr);
        break;
    case ESR_ELx_EC_SYS64:           // MSR/MRS/SYS
    case ESR_ELx_EC_UNKNOWN:
        el1_undef(regs, esr);
        break;
    case ESR_ELx_EC_BTI:             // Branch Target Identification
        el1_bti(regs, esr);
        break;
    case ESR_ELx_EC_BREAKPT_CUR:     // Breakpoint
    case ESR_ELx_EC_WATCHPT_CUR:     // Watchpoint
    case ESR_ELx_EC_BRK64:           // BRK instruction
        // ...
    default:
        __panic_unhandled(regs, "64-bit el1h sync", esr);
    }
}
```

### 5.2 EL0 同步异常：`el0t_64_sync_handler`（entry-common.c:737）

用户态同步异常的核心分发函数，处理的 EC 码包括：

| EC 码 | 含义 | 处理函数 |
|-------|------|---------|
| `ESR_ELx_EC_SVC64` | SVC 系统调用 | `el0_svc()` |
| `ESR_ELx_EC_DABT_LOW` | Data Abort (lower EL) | `el0_da()` |
| `ESR_ELx_EC_IABT_LOW` | Instruction Abort (lower EL) | `el0_ia()` |
| `ESR_ELx_EC_FP_ASIMD` | FP/ASIMD trap | `el0_fpsimd_acc()` |
| `ESR_ELx_EC_SVE` | SVE trap | `el0_sve_acc()` |
| `ESR_ELx_EC_SME` | SME trap | `el0_sme_acc()` |
| `ESR_ELx_EC_FP_EXC64` | FP exception | `el0_fpsimd_exc()` |
| `ESR_ELx_EC_SYS64` / `WFx` | MRS/MSR/WF{I,E} | `el0_sys()` |
| `ESR_ELx_EC_BREAKPT_LOW` | Breakpoint | `el0_breakpt()` |
| `ESR_ELx_EC_WATCHPT_LOW` | Watchpoint | `el0_watchpt()` |
| `ESR_ELx_EC_BRK64` | BRK instruction | `el0_brk64()` |
| `ESR_ELx_EC_FPAC` | FPAC fail | `el0_fpac()` |

### 5.3 IRQ/FIQ/Error handler

- **IRQ**: `el1h_64_irq_handler` / `el0t_64_irq_handler` → `el{1,0}_interrupt()` → `irq_enter_rcu()` → `do_interrupt_handler()` → GIC handler
- **FIQ**: 类似 IRQ 路径，调用 `handle_arch_fiq`
- **Error (SError)**: `do_serror()` → NMI 上下文处理

---

## 六、Spectre 缓解与多重向量表

为应对 Spectre-BHB（Branch History Buffer）攻击和 KPTI（Kernel Page Table Isolation），系统维护了**三套向量表**：

| 向量表 | 位置 | 用途 |
|--------|------|------|
| `vectors` | `.entry.text` | 默认完整向量表 |
| `tramp_vectors` | `.entry.tramp.text` | KPTI 场景，通过 trampoline 映射/取消映射内核页表后跳转 |
| `__bp_harden_el1_vectors` | `.entry.text` | EL1 进入时的 BHB 缓解（不使用 KPTI 时） |

`arm64_get_bp_hardening_vector()` 在 `vectors.h:62` 选择合适的向量表槽位：

```c
static inline const char *
arm64_get_bp_hardening_vector(enum arm64_bp_harden_el1_vectors slot)
{
    if (cpus_have_cap(ARM64_UNMAP_KERNEL_AT_EL0))
        return (char *)(TRAMP_VALIAS + SZ_2K * slot);
    return __bp_harden_el1_vectors + SZ_2K * slot;
}
```

trampoline 的核心是 `tramp_ventry` 宏（`entry.S:684`），它在跳转到真正的 kernel vectors 之前会：

1. 执行 BHB 循环/固件调用/`clearbhb` 指令
2. 映射内核页表（KPTI 场景，通过 `tramp_map_kernel`）
3. 设置 `VBAR_EL1` 指向 `vectors`
4. `ret` 到正确向量

---

## 七、完整异常处理流程总结

```
硬件触发异常
  → VBAR_EL1 查表跳转到 vectors + offset
    → kernel_ventry: 预留 pt_regs + 栈溢出检测 → 跳转 elXy_XX_XXXX
      → kernel_entry: 保存 x0-x29, elr_el1, spsr_el1 到栈上
        → C handler (elXy_XX_XXXX_handler): 读 ESR_EL1, 按 EC 码分发
          → 具体处理函数 (el1_abort, el0_svc, do_serror, ...)
            → ret_to_user / ret_to_kernel
              → kernel_exit: 恢复寄存器 → eret 返回
```

---

## 八、涉及的核心文件

| 文件 | 作用 |
|------|------|
| `arch/arm64/kernel/entry.S` | 汇编向量表、`kernel_ventry`/`entry_handler`/`kernel_entry`/`kernel_exit` 宏、trampoline |
| `arch/arm64/kernel/entry-common.c` | C 层 handler 分发（12 个 `asmlinkage` 函数） |
| `arch/arm64/include/asm/vectors.h` | 向量表声明和 Spectre 缓解选择逻辑 |
| `arch/arm64/include/asm/esr.h` | ESR_EL1 的 EC 字段定义 |
| `arch/arm64/include/asm/exception.h` | 异常处理辅助声明 |
