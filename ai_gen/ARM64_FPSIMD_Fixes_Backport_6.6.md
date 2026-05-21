# ARM64 FPSIMD/SVE/SME/FPMR 修复总结 (v6.6 → v6.19)

本文档整理 Linux 6.6 之后所有 ARM64 fpsimd/SVE/SME/FPMR 相关的修复 patchset，分析每个修复解决了什么问题，并给出在 6.6 上回合后测试的具体方法。

---

## 0. 总体概览

v6.6 → v6.19 期间，ARM64 fpsimd 子系统经历了多个重大修复系列，按类别汇总如下：

| 类别 | 主要版本 | 核心问题 |
|------|---------|---------|
| Kernel Mode NEON Context Switch | v6.8 | 关闭抢占影响实时性 |
| Lazy Restore 回归 | v6.10 | dm-crypt 数据损坏 |
| SME Suspend/Resume | v6.8 | 休眠后 SME 寄存器丢失 |
| Signal 处理 (SVE 格式) | v6.8 | TIF_SVE vs fp_type 不一致 |
| Signal 处理全面重写 | v6.14 | FPMR 损坏、SME 状态竞争 |
| SME 状态分配 | v6.8 | 内存泄漏、状态损坏 |
| FEAT_FPMR 支持 | v6.9 | FP8 新特性使能 |
| ZCR/SMCR 已知值 | v6.9 | RES0 位初始化为随机值 |
| SVE Trap 竞争 | v6.12 | 抢占导致 stale CPU state |
| Ptrace FPMR | v6.12/13 | partial SETREGSET bug |
| KVM FPMR/FP8 | v6.12 | KVM 中使能 FP8 |
| KVM Host FP 管理重写 | v6.14 | Host SVE 丢弃、FPMR 损坏 |
| KVM NV SVE | v6.12/14 | 嵌套虚拟化 SVE 支持 |
| pKVM FP 修复 | v6.11/12 | protected KVM FP 安全 |
| SME/FPMR Bug 修复 | v6.14 | FPMR exec 未重置、SMSTOP 破坏 |
| Ptrace VL 修改修复 | v6.14/15 | VL 修改后状态非法 |
| EFI/Kernel NEON 优化 | v6.14/15 | task_struct 膨胀、关中断限制 |

---

## 1. Kernel Mode NEON Context Switch 系列 (v6.8)

**作者**: Ard Biesheuvel

**Patchset**: 无独立 cover letter。此系列 fpsimd 相关 patch 是 Ard 的大系列 "arm64: kernel mode NEON" 的一部分（patch 7-9），前面 6 个 patch 为其他准备工作。

**系列入口** (patch 7, fpsimd 的第一个 patch):
- https://lore.kernel.org/all/20231208113218.3001940-7-ardb@google.com/

### 涉及的 commits

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `9b19700e623f` | arm64: fpsimd: Drop unneeded 'busy' flag | [通用] | [link](https://lore.kernel.org/all/20231208113218.3001940-7-ardb@google.com/) |
| `aefbab8e77eb` | arm64: fpsimd: Preserve/restore kernel mode NEON at context switch | [通用] | [link](https://lore.kernel.org/all/20231208113218.3001940-8-ardb@google.com/) |
| `2632e2521769` | arm64: fpsimd: Implement lazy restore for kernel mode FPSIMD | [通用] | [link](https://lore.kernel.org/all/20231208113218.3001940-9-ardb@google.com/) |

### 修复的问题

原先内核态使用 NEON（如 crypto 加速，AES-XTS 等）需要 `kernel_neon_begin()` / `kernel_neon_end()`，这期间会关闭内核抢占和软中断。对于输入大小可能不受限制的 CPU 密集型操作（如 dm-crypt 加密），长时间禁用抢占对实时性能影响很大。

该系列修改了上下文切换逻辑：
1. 引入 `TIF_KERNEL_FPSTATE` 标志，在上下文切换时保存/恢复内核态 FPSIMD 状态到 `struct thread_struct`
2. 软中断也可以安全使用 FPSIMD，内核 task 上下文中的 FPSIMD 状态会被保护
3. 实现 lazy restore，避免不必要的寄存器重载

### 已知回归

`2632e2521769` (lazy restore) 在 Apple M1 上导致 dm-crypt 数据损坏（见下节）。

---

## 2. Lazy Restore 回归修复 (v6.10)

**作者**: Ard Biesheuvel / Will Deacon

**Patchset**: 无独立 cover letter。修复 lazy restore 导致的数据损坏，共 2 个 patch（reapply + fix）。

**Bug 报告**:
- https://lore.kernel.org/all/cb8822182231850108fa43e0446a4c7f@kernel.org/

**系列入口** (reapply patch):
- https://lore.kernel.org/all/20240522091335.335346-2-ardb+git@google.com/

### 涉及的 commits

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `b8995a184170` | Revert "arm64: fpsimd: Implement lazy restore for kernel mode FPSIMD" | [通用] | (同系列, 无独立 lore link) |
| `f481bb32d60e` | Reapply "arm64: fpsimd: Implement lazy restore for kernel mode FPSIMD" | [通用] | [link](https://lore.kernel.org/all/20240522091335.335346-2-ardb+git@google.com/) |
| `e92bee9f861b` | **arm64/fpsimd: Avoid erroneous elide of user state reload** | [通用] | [link](https://lore.kernel.org/all/20240522091335.335346-2-ardb+git@google.com/) |

### 修复的问题

**问题根因**（`e92bee9f861b`）:

`TIF_FOREIGN_FPSTATE` 标志表示当前 CPU 是否持有任务最近的用户态 FP/SIMD 状态。当任务因内核态 NEON 被调度出时，`TIF_KERNEL_FPSTATE` 被设置，同时 `TIF_FOREIGN_FPSTATE` 也被设置（因为 CPU 不持有用户态状态）。

但是，如果任务在**完成内核态 NEON 之后、返回用户空间之前**被调度出去，`TIF_FOREIGN_FPSTATE` 不会保留，下次调度回来时基于过时条件重新计算。这导致返回用户空间时**跳过**用户态 FP 状态的重新加载，用户进程看到损坏的浮点寄存器数据。

**修复**: 在调度入带有 `TIF_KERNEL_FPSTATE` 的任务时，调用 `fpsimd_flush_cpu_state()` 更新底层状态，使 `TIF_FOREIGN_FPSTATE` 能根据正确条件重新计算。

**影响**: 任何使用内核态 NEON 加速的场景（dm-crypt、raid、网络 checksum 等），Apple M1 用户首先报告了 dm-crypt 数据损坏。

---

## 3. SME Suspend/Resume 修复 (v6.8)

**作者**: Mark Brown

**Cover Letter**:
- Subject: [PATCH v3 0/2] arm64/sme: Fix resume from suspend
- https://lore.kernel.org/all/20240213-arm64-sme-resume-v3-0-17e05e493471@kernel.org/

### 涉及的 commits

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `9533864816fb` | **arm64/sme: Restore SME registers on exit from suspend** | [通用] | [link](https://lore.kernel.org/all/20240213-arm64-sme-resume-v3-1-17e05e493471@kernel.org/) |
| `d7b77a0d565b` | **arm64/sme: Restore SMCR_EL1.EZT0 on exit from suspend** | [通用] | [link](https://lore.kernel.org/all/20240213-arm64-sme-resume-v3-2-17e05e493471@kernel.org/) |

### 修复的问题

SMCR_EL1 和 SMPRI_EL1 的字段在系统休眠（suspend to RAM）后会被硬件重置为**架构上 UNKNOWN 的值**。内核没有在其他路径上管理这些 trap 配置寄存器，休眠恢复后 trap 配置丢失，导致：

- 后续 SME 用户程序可能产生意外的 SME trap
- SMCR_EL1.EZT0（Zero ZT0 控制位）的值丢失，影响 SME2 功能

修复在休眠恢复路径中显式重新配置这些寄存器。

---

## 4. Signal 处理修复

### 4a. Signal 保存格式检查修复 (v6.8)

**作者**: Mark Brown

**Patchset**: 单 patch，无 cover letter。

- https://lore.kernel.org/all/20240130-arm64-sve-signal-regs-v2-1-9fc6f9502782@kernel.org/

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `61da7c8e2a60` | **arm64/signal: Don't assume that TIF_SVE means we saved SVE state** | [通用] | [link](https://lore.kernel.org/all/20240130-arm64-sve-signal-regs-v2-1-9fc6f9502782@kernel.org/) |

**修复的问题**: v6.7 引入的 `8c845e273104` ("arm64/sve: Leave SVE enabled on syscall if we don't context switch") 改变了行为：syscall 中只保存 FPSIMD 子集（尽管用户仍有完整 SVE 访问权限），但 TIF_SVE 标志可能仍然被设置。信号处理代码错误地假设 TIF_SVE 被设置就意味着寄存器状态以 SVE 格式保存，导致信号帧中保存的数据格式不正确。

**修复**: 检查 `fp_type`（实际保存的格式）而非 TIF_SVE 来判断状态格式。

### 4b. Signal 处理全面重写 (v6.14)

**作者**: Mark Rutland

此系列属于更大的 "Preparatory FPSIMD/SVE/SME fixes" patchset 的一部分。

**Cover Letter** (整个系列):
- Subject: [PATCH v2 00/13] arm64: Preparatory FPSIMD/SVE/SME fixes
- https://lore.kernel.org/all/20250409164010.3480271-1-mark.rutland@arm.com/

#### 涉及的 commits (arch/arm64/kernel/fpsimd.c)

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `d3a181588df9` | arm64/fpsimd: Add fpsimd_save_and_flush_current_state() | [通用] | [link](https://lore.kernel.org/all/20250409164010.3480271-11-mark.rutland@arm.com/) |
| `929fa99b1215` | **arm64/fpsimd: signal: Always save+flush state early** | [通用] | [link](https://lore.kernel.org/all/20250409164010.3480271-13-mark.rutland@arm.com/) |
| `c94f2f326146` | **arm64/fpsimd: Fix merging of FPSIMD state during signal return** | [通用] | [link](https://lore.kernel.org/all/20250409164010.3480271-10-mark.rutland@arm.com/) |

#### 涉及的 commits (arch/arm64/kernel/signal.c) — 均属于同一个 v2 系列

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `99560c9452bb` | arm64/fpsimd: signal: Use SMSTOP behaviour in setup_return() | [通用] | [link](https://lore.kernel.org/all/20250409164010.3480271-12-mark.rutland@arm.com/) |
| `2fe2b96c3818` | arm64/fpsimd: signal: Simplify preserve_tpidr2_context() | [通用] | 同系列 |
| `b376108e1f88` | arm64/fpsimd: signal: Clear TPIDR2 when delivering signals | [通用] | 同系列 |
| `1bf663a86a45` | arm64/fpsimd: signal: Clear PSTATE.SM when restoring FPSIMD frame only | [通用] | 同系列 |
| `b465ace42620` | arm64/fpsimd: signal: Mandate SVE payload for streaming-mode state | [通用] | 同系列 |
| `be625d803c3b` | arm64/fpsimd: signal: Consistently read FPSIMD context | [通用] | 同系列 |
| `ea8ccfddbce0` | arm64/fpsimd: signal: Allocate SSVE storage when restoring ZA | [通用] | 同系列 |
| `d2907cbe9ea0` | **arm64/fpsimd: signal: Fix restoration of SVE context** | [通用] | 同系列 |

#### 修复的问题

1. **FPMR 信号处理损坏**（自引入起就存在）: 在有 FPMR 的硬件上，信号代码在 FPMR 不属于当前任务时访问该寄存器。由于缺乏适当的锁定和 ownership 检查，可能损坏当前任务或其他任务的 FPMR 值。引入 `fpsimd_save_and_flush_current_state()` helper 确保操作前状态已保存到内存。

2. **SME 状态信号处理竞争**: `setup_return()` 同时修改 live 寄存器状态和保存的状态，而不持有 `cpu_fpsimd_context`。与抢占/软中断中的内核 NEON 使用产生竞争，导致：
   - 损坏其他有 PSTATE.SM/PSTATE.ZA 置位的任务状态
   - 任务意外进入 streaming mode 或启用 ZA storage
   - 从 streaming SVE 模式进入 non-streaming 模式时可能继承 stale SVE 寄存器（不同 VL 下可能被任意打包）

3. **信号返回时 FPSIMD 合并失败**: 向后兼容性要求：信号返回恢复 SVE 状态时，Z 寄存器低 128 位应从 FPSIMD 信号帧覆盖。但 `fpsimd_update_current_state()` 依赖 TIF_SVE 做合并判断：
   - **SME without SVE 系统**: TIF_SVE 永远不能设置 → 合并永远不发生
   - **SVE+SME 系统**: TIF_SVE 可独立于 PSTATE.SM 变化 → 合并非确定性地发生/不发生
   - sigreturn() 开始时 TIF_SVE 可被 syscall 清除，用户空间观察到的行为非确定

4. **SVE context 恢复丢弃状态**: 多个恢复函数使用 `fpsimd_flush_task_state()` 丢弃 live 状态，当仅恢复了部分 FPSIMD/SVE/SME 状态时，其余寄存器被非确定性地重置为历史上某个任意时间点的 stale 快照。

5. **PSTATE.SM 清除逻辑**: 仅恢复 FPSIMD 帧时需要正确清除 PSTATE.SM（退出 streaming mode），此前未做。

---

## 5. SME 状态分配修复 (v6.8)

**作者**: Mark Brown

### 5a. sme_alloc() 修复

**Cover Letter**:
- Subject: [PATCH v1] arm64/sme: Always exit sme_alloc() early with existing storage
- https://lore.kernel.org/all/20240115-arm64-sme-flush-v1-0-7472bd3459b7@kernel.org/

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `dc7eb8755797` | **arm64/sme: Always exit sme_alloc() early with existing storage** | [通用] | [link](https://lore.kernel.org/all/20240115-arm64-sme-flush-v1-1-7472bd3459b7@kernel.org/) |

### 5b. SVE 支持检查修复

**Cover Letter**:
- Subject: [PATCH v1] arm64/fpsimd: Remove spurious check for SVE support
- https://lore.kernel.org/all/20240115-arm64-sve-enabled-check-v1-0-a26360b00f6d@kernel.org/

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `8410186ca480` | **arm64/fpsimd: Remove spurious check for SVE support** | [通用] | [link](https://lore.kernel.org/all/20240115-arm64-sve-enabled-check-v1-1-a26360b00f6d@kernel.org/) |

### 修复的问题

1. **sme_alloc() 内存泄漏**: 当已有 sme_state 存储且不需要 flush 时，`sme_alloc()` 仍然分配新存储，导致旧存储泄漏和状态损坏。修复为分离 "flush" 和 "已有存储" 的检查逻辑（与 SVE 分配逻辑对齐）。

2. **SVE 支持检查错误**: 改变 vector length 时检查 SVE 支持（`system_supports_sve()`），但 SME-only 系统（有 SME 无 SVE）也需要 SVE 状态存储给 streaming SVE 模式使用。移除错误的 SVE 支持检查。

---

## 6. Ptrace SVE Regset 大小限制 (v6.8)

**作者**: Mark Brown

**Cover Letter**:
- Subject: [PATCH v2] arm64/sve: Lower the maximum allocation for the SVE ptrace regset
- https://lore.kernel.org/all/20240213-arm64-sve-ptrace-regset-size-v2-0-c7600ca74b9b@kernel.org/

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `2813926261e4` | **arm64/sve: Lower the maximum allocation for the SVE ptrace regset** | [通用] | [link](https://lore.kernel.org/all/20240213-arm64-sve-ptrace-regset-size-v2-1-c7600ca74b9b@kernel.org/) |

**修复的问题**: 降低 ptrace SVE regset 的最大分配大小，避免在高 VL（如 256 字节）时内核内存分配失败。

---

## 7. FEAT_FPMR / FP8 支持 (v6.9)

**作者**: Mark Brown

**Cover Letter**:
- Subject: [PATCH v5 0/8] arm64: Support for 2023 DPISA extensions
- https://lore.kernel.org/all/20240306-arm64-2023-dpisa-v5-0-c568edc8ed7f@kernel.org/

### 涉及的 commits (FP/FPMR 相关子集)

| Commit | 标题 | 标记 | 文件 | Lore Link |
|--------|------|------|------|-----------|
| `203f2b95a882` | **arm64/fpsimd: Support FEAT_FPMR** | [FPMR] | fpsimd.c | [link](https://lore.kernel.org/all/20240306-arm64-2023-dpisa-v5-3-c568edc8ed7f@kernel.org/) |
| `4035c22ef7d4` | arm64/ptrace: Expose FPMR via ptrace | [FPMR] | ptrace.c | [link](https://lore.kernel.org/all/20240306-arm64-2023-dpisa-v5-4-c568edc8ed7f@kernel.org/) |
| `8c46def44409` | arm64/signal: Add FPMR signal handling | [FPMR] | signal.c | [link](https://lore.kernel.org/all/20240306-arm64-2023-dpisa-v5-5-c568edc8ed7f@kernel.org/) |

### 问题/功能

FEAT_FPMR 定义了新的 EL0 可访问寄存器 FPMR，用于配置 FP8 相关特性。需要：
- 检测硬件支持并进行上下文切换（fpsimd.c）
- Ptrace 接口暴露 FPMR（NT_ARM_FPMR regset）
- 信号处理中保存/恢复 FPMR

注意：在 KVM 中 FP8 支持的使能还需要后续 KVM 侧 patch（见第 11 节）。

---

## 8. ZCR_EL1/SMCR_EL1 RES0 位初始化 (v6.9)

**作者**: Mark Brown

**Cover Letter**:
- Subject: [PATCH v1 0/2] arm64/fp: Ensure that all fields in ZCR/SMCR are set to known values
- https://lore.kernel.org/all/20240213-arm64-fp-init-vec-cr-v1-0-7e7c2d584f26@kernel.org/

### 涉及的 commits

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `2f0090549b64` | **arm64/sve: Ensure that all fields in ZCR_EL1 are set to known values** | [通用] | [link](https://lore.kernel.org/all/20240213-arm64-fp-init-vec-cr-v1-1-7e7c2d584f26@kernel.org/) |
| `93576e349887` | **arm64/sme: Ensure that all fields in SMCR_EL1 are set to known values** | [通用] | [link](https://lore.kernel.org/all/20240213-arm64-fp-init-vec-cr-v1-2-7e7c2d584f26@kernel.org/) |

### 修复的问题

CPU 初始化时从未显式设置 ZCR_EL1 和 SMCR_EL1 中除 LEN 外的 RES0 字段。之前所有更新都是 read/modify/write，RES0 位保持硬件复位后的 Unknown 值。如果未来的架构扩展赋予这些位新的含义，旧的 Unknown 值可能导致意外行为。修复显式将这些 RES0 位初始化为 0。

---

## 9. SVE Trap Stale CPU State 修复 (v6.12)

**作者**: Mark Rutland

**Cover Letter**:
- Subject: [PATCH 0/2] arm64/fp: Fix missing invalidation when working with foreign FP state
- https://lore.kernel.org/all/20241030-arm64-fpsimd-foreign-flush-v1-0-bd7bd66905a2@kernel.org/

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `751ecf6afd65` | **arm64/sve: Discard stale CPU state when handling SVE traps** | [通用] | [link](https://lore.kernel.org/all/20241030-arm64-fpsimd-foreign-flush-v1-1-bd7bd66905a2@kernel.org/) |

### 修复的问题

SVE trap 处理函数 `do_sve_acc()` 中存在与抢占的竞争：

```
T0: // CPU 0, TIF_SVE clear, SVE traps 使能
    // task->fpsimd_cpu == 0
    // per_cpu(fpsimd_last_state, 0) == task

T1: // 被抢占，迁移到 CPU 1
    // TIF_FOREIGN_FPSTATE 被设置

T2: get_cpu_fpsimd_context()
    test_and_set_thread_flag(TIF_SVE)  // 设置 TIF_SVE
    // TIF_FOREIGN_FPSTATE 为 true,
    // 调用 fpsimd_to_sve(current) 从 FPSIMD 转换
    put_cpu_fpsimd_context()

T3: // 被抢占，迁移回 CPU 0
    // task->fpsimd_cpu 仍为 0
    // 如果 per_cpu(fpsimd_last_state, 0) 仍是 task:
    //   - Stale HW state 被重用 (SVE traps 仍然使能)
    //   - TIF_FOREIGN_FPSTATE 被清除
    //   - 返回用户空间时跳过 HW state 恢复
```

**结果**: 任务有 TIF_SVE 置位但 CPU 上的硬件状态是 stale 的（SVE trap 仍使能），返回用户空间时跳过恢复，用户态看到错误寄存器值，并触发 `do_sve_acc()` 中的 `WARN_ON(1)`。

**修复**: 当状态不在当前 CPU 且 TIF_FOREIGN_FPSTATE 被设置时，调用 `fpsimd_flush_task_state()` 解除与已保存 CPU 状态的绑定。

---

## 10. Ptrace FPMR / SVE Layout 修复 (v6.12/v6.13)

### 10a. Ptrace FPMR partial write 修复 (v6.12)

**作者**: Mark Rutland

**Patchset**: 多 patch 系列的部分内容（patch 3/5）。

**Cover Letter** (推测系列):
- https://lore.kernel.org/all/20241205121655.1824269-1-mark.rutland@arm.com/

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `f5d71291841a` | **arm64: ptrace: fix partial SETREGSET for NT_ARM_FPMR** | [FPMR] | [link](https://lore.kernel.org/all/20241205121655.1824269-3-mark.rutland@arm.com/) |

### 10b. Ptrace SVE layout 修复 (v6.13)

**作者**: Mark Brown

**Patchset**: 单 patch，无 cover letter。

- https://lore.kernel.org/all/20240325-arm64-ptrace-fp-type-v1-1-8dc846caf11f@kernel.org/

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `b017a0cea627` | **arm64/ptrace: Use saved floating point state type to determine SVE layout** | [通用] | [link](https://lore.kernel.org/all/20240325-arm64-ptrace-fp-type-v1-1-8dc846caf11f@kernel.org/) |

### 修复的问题

1. **NT_ARM_FPMR partial write**: `f5d71291841a` 修复 NT_ARM_FPMR regset 的 partial SETREGSET 处理 bug。

2. **SVE layout 判断**: ptrace 应使用 `thread.fp_type`（保存的浮点状态类型）而非 TIF_SVE 来判断 SVE 布局，与 signal 修复（第 4a 节）相同类型的问题。

---

## 11. KVM FPMR/FP8 支持 (v6.12)

**作者**: Marc Zyngier

**Cover Letter**:
- Subject: [PATCH v4 0/8] KVM: arm64: Add support for FP8
- https://lore.kernel.org/all/20240820131802.3547589-1-maz@kernel.org/

### 涉及的 commits

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `7d9c1ed6f4bf` | KVM: arm64: Move FPMR into the sysreg array | [FPMR] | [link](https://lore.kernel.org/all/20240820131802.3547589-4-maz@kernel.org/) |
| `ef3be86021c3` | KVM: arm64: Add save/restore support for FPMR | [FPMR] | [link](https://lore.kernel.org/all/20240820131802.3547589-5-maz@kernel.org/) |
| `b8f669b491ec` | KVM: arm64: Honor trap routing for FPMR | [FPMR] | [link](https://lore.kernel.org/all/20240820131802.3547589-6-maz@kernel.org/) |
| `c9150a8ad9cd` | KVM: arm64: Enable FP8 support when available and configured | [FPMR] | [link](https://lore.kernel.org/all/20240820131802.3547589-8-maz@kernel.org/) |

### 问题/功能

在 KVM 中使能 FP8 支持：
- FPMR 纳入 sysreg 数组进行 save/restore（包括 pKVM 的特殊处理）
- HCRX_EL2.EnFPM 的 trap routing 正确配置（NV guest 中可 reinject 异常）
- 用户空间通过设置 ID_AA64PFR2_EL1.FPMR 来控制是否向 guest 暴露 FP8

---

## 12. KVM Host FP State 管理全面重写 (v6.14)

**作者**: Mark Rutland

**Cover Letter**:
- Subject: [PATCH v3 0/8] KVM: arm64: FPSIMD/SVE/SME fixes
- https://lore.kernel.org/all/20250210195226.1215254-1-mark.rutland@arm.com/

### 涉及的 commits

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `fbc7e61195e2` | **KVM: arm64: Unconditionally save+flush host FPSIMD/SVE/SME state** | [通用] | [link](https://lore.kernel.org/all/20250210195226.1215254-2-mark.rutland@arm.com/) |
| `8eca7f6d5100` | KVM: arm64: Remove host FPSIMD saving for non-protected KVM | [通用] | [link](https://lore.kernel.org/all/20250210195226.1215254-3-mark.rutland@arm.com/) |
| `407a99c4654e` | KVM: arm64: Remove VHE host restore of CPACR_EL1.SMEN | [通用] | [link](https://lore.kernel.org/all/20250210195226.1215254-5-mark.rutland@arm.com/) |
| `459f059be702` | KVM: arm64: Remove VHE host restore of CPACR_EL1.ZEN | [通用] | [link](https://lore.kernel.org/all/20250210195226.1215254-6-mark.rutland@arm.com/) |
| `59419f10045b` | **KVM: arm64: Eagerly switch ZCR_EL{1,2}** | [通用] | [link](https://lore.kernel.org/all/20250210195226.1215254-9-mark.rutland@arm.com/) |

### 修复的问题

1. **Host SVE 被意外丢弃**（自 v5.17 起就有相关问题）:
   hyp 代码在延迟保存 host FPSIMD/SVE 状态时，TIF_SVE 和 CPACR_ELx.ZEN 的配置不一致。这导致 host SVE 被非预期丢弃。Eric Auger 报告 QEMU 中 memmove() 使用 SVE 时崩溃（RHEL-68997）。

2. **Ptrace ABI 改变**: host SVE 状态在 ptrace 修改后被延迟丢弃，改变了 ptrace 修改 SVE 状态的行为（之前修改会被保留）。

3. **Host FPMR 值损坏**: 非 protected VM 运行时（不向 VM 暴露 FPMR），hyp 代码在 unbind host FPSIMD/SVE/SME 状态前不保存 host FPMR，导致内存中留下 stale FPMR 值。下次恢复时 host 的 FPMR 被污染。

4. **ZCR_EL2 VL 不匹配导致 SIGKILL**:
   - VHE+NV 场景：ZCR_EL2 包含 guest hypervisor 约束的值（可能小于等于 guest max VL）
   - nVHE/hVHE 场景：ZCR_EL1 包含 guest 写入的值（可能大于或小于 guest max VL）
   - guest 退出到 host 后、`kvm_arch_vcpu_put_fp()` 之前如果发生 softirq 使用 kernel NEON，`fpsimd_save_user_state()` 检测到 VL 不匹配会发送 SIGKILL

**解决方案**:
- 在加载 vCPU 时 **eagerly save+flush** host 的 FPSIMD/SVE/SME 状态（不再延迟保存），避免所有与延迟保存相关的竞争和遗漏
- Eagerly switch ZCR_EL{1,2} 在 hyp 的 guest<->host 转换中，确保 host 总是看到正确的 VL

---

## 13. KVM NV SVE 支持 (v6.12/v6.14)

**作者**: Oliver Upton

**Cover Letter**:
- Subject: [PATCH v3 00/15] KVM: arm64: nv: FPSIMD/SVE, plus some other CPTR goodies
- https://lore.kernel.org/all/20240620164653.1130714-1-oliver.upton@linux.dev/

### 涉及的 commits (FP/SVE 相关子集)

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `2e3cf82063a0` | **KVM: arm64: nv: Ensure correct VL is loaded before saving SVE state** | [通用] | [link](https://lore.kernel.org/all/20240620164653.1130714-8-oliver.upton@linux.dev/) |
| `399debfc9749` | KVM: arm64: nv: Forward SVE traps to guest hypervisor | [通用] | [link](https://lore.kernel.org/all/20240620164653.1130714-3-oliver.upton@linux.dev/) |
| `d2b2ec8ba8dd` | KVM: arm64: nv: Forward FP/ASIMD traps to guest hypervisor | [通用] | [link](https://lore.kernel.org/all/20240620164653.1130714-2-oliver.upton@linux.dev/) |
| `f1ee914fb626` | KVM: arm64: Allow the use of SVE+NV | [通用] | [link](https://lore.kernel.org/all/20240620164653.1130714-15-oliver.upton@linux.dev/) |

### 修复的问题

嵌套虚拟化场景下：
1. Guest hypervisor 可能为 nested guest 选择**小于最大 VL** 的 VL。退出 nested guest 时 ZCR_EL2 可能被配置为与最大 VL 不同的值。保存 SVE 状态前必须设置 ZCR_EL2 为最大 VL（因为 SVE save area 按 max VL 分配）。

2. SVE/FP/ASIMD trap 需要正确转发给 guest hypervisor（当 guest hypervisor 启用了 SVE trap 时不加载 host SVE 状态，而是转发 trap）。

---

## 14. pKVM FP State 管理修复 (v6.11-v6.12)

**作者**: Fuad Tabba

**Cover Letter**:
- Subject: [PATCH v4 0/9] KVM: arm64: Fix handling of host fpsimd/sve state in protected mode
- https://lore.kernel.org/all/20240603122852.3923848-1-tabba@google.com/

### 涉及的 commits (FP 相关子集)

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `afb91f5f8ad7` | **KVM: arm64: Ensure that SME controls are disabled in protected mode** | [通用] | [link](https://lore.kernel.org/all/20240603122852.3923848-10-tabba@google.com/) |
| `b5b9955617bc` | KVM: arm64: Eagerly restore host fpsimd/sve state in pKVM | [通用] | [link](https://lore.kernel.org/all/20240603122852.3923848-7-tabba@google.com/) |
| `e511e08a9f49` | KVM: arm64: Specialize handling of host fpsimd state on trap | [通用] | [link](https://lore.kernel.org/all/20240603122852.3923848-6-tabba@google.com/) |
| `66d5b53e20a6` | KVM: arm64: Allocate memory mapped at hyp for host sve state in pKVM | [通用] | [link](https://lore.kernel.org/all/20240603122852.3923848-5-tabba@google.com/) |
| `87bb39ed40bd` | KVM: arm64: Reintroduce __sve_save_state | [通用] | [link](https://lore.kernel.org/all/20240603122852.3923848-3-tabba@google.com/) |
| `d48965bc47e4` | KVM: arm64: Do not map the host fpsimd state to hyp in pKVM | [通用] | 同系列 |
| `f11290e0aa6e` | KVM: arm64: Refactor checks for FP state ownership | [通用] | [link](https://lore.kernel.org/all/20240603122852.3923848-9-tabba@google.com/) |
| `5294afdbf45a` | KVM: arm64: Exclude FP ownership from kvm_vcpu_arch | [通用] | 同系列 |

### 修复的问题

pKVM 下 host FP 状态管理不完善：
1. **SME 控制保护**: pKVM 不支持 SME guest，但需要防止恶意/buggy host 在 protected mode 下以 SME 控制使能状态运行 guest。确保在 protected mode 下 SME 控制被显式禁用。
2. **Host SVE 恢复**: 改为 eagerly restore host fpsimd/sve state，避免延迟恢复可能的安全问题。
3. **Memory mapped at hyp**: 为 host SVE state 在 hyp 分配内存映射，解决内存访问安全问题。
4. 重构 FP state ownership 检查逻辑，将其从 `kvm_vcpu_arch` 中分离。

---

## 15. SME/FPMR Bug 修复系列 (v6.12-v6.14)

这一节汇集了两个相关联的 patchset。

### 15a. SME 修复 (v6.12)

**作者**: Mark Brown

**Cover Letter**:
- Subject: [PATCH v2 0/6] arm64/sme: Collected SME fixes
- https://lore.kernel.org/all/20241204-arm64-sme-reenable-v2-0-bae87728251d@kernel.org/

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `d3eaab3c7090` | **arm64/fpsimd: Discard stale CPU state when handling SME traps** | [通用] | [link](https://lore.kernel.org/all/20241204-arm64-sme-reenable-v2-1-bae87728251d@kernel.org/) |
| `e5fa85fce08b` | **arm64/fpsimd: Don't corrupt FPMR when streaming mode changes** | [FPMR] | [link](https://lore.kernel.org/all/20241204-arm64-sme-reenable-v2-2-bae87728251d@kernel.org/) |

### 15b. Preparatory FPSIMD/SVE/SME 修复 (v6.14)

**作者**: Mark Rutland

**Cover Letter** (与第 4b 节信号重写为同一系列):
- Subject: [PATCH v2 00/13] arm64: Preparatory FPSIMD/SVE/SME fixes
- https://lore.kernel.org/all/20250409164010.3480271-1-mark.rutland@arm.com/

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `95507570fb2f` | **arm64/fpsimd: Avoid RES0 bits in the SME trap handler** | [通用] | [link](https://lore.kernel.org/all/20250409164010.3480271-2-mark.rutland@arm.com/) |
| `45fd86986b79` | arm64/fpsimd: Remove redundant SVE trap manipulation | [通用] | [link](https://lore.kernel.org/all/20250409164010.3480271-4-mark.rutland@arm.com/) |
| `d7649a4a601e` | **arm64/fpsimd: Remove opportunistic freeing of SME state** | [通用] | [link](https://lore.kernel.org/all/20250409164010.3480271-5-mark.rutland@arm.com/) |
| `01098d893fa8` | **arm64/fpsimd: Avoid clobbering kernel FPSIMD state with SMSTOP** | [通用] | [link](https://lore.kernel.org/all/20250409164010.3480271-8-mark.rutland@arm.com/) |
| `a90878f297d3` | **arm64/fpsimd: Reset FPMR upon exec()** | [FPMR] | [link](https://lore.kernel.org/all/20250409164010.3480271-9-mark.rutland@arm.com/) |
| `61db0e0ba398` | arm64/fpsimd: Remove unused fpsimd_force_sync_to_sve() | [通用] | [link](https://lore.kernel.org/all/20250409164010.3480271-3-mark.rutland@arm.com/) |
| `f699c66691fb` | arm64/fpsimd: Avoid warning when sve_to_fpsimd() is unused | [通用] | [link](https://lore.kernel.org/all/20250430173240.4023627-1-mark.rutland@arm.com/) (独立 patch) |

### 修复的问题

1. **SME trap handler 使用 RES0 bits**: SME trap handler 直接使用 ESR 的 RES0 bits（bits [24:3]）来判断 trap 原因。未来这些位可能被分配新含义且不再读为零，导致误判 trap 类型。修复为只提取 SMTC 字段（bits [2:0]）。

2. **SVE trap 操控冗余**: `task_fpsimd_load()` 中配置 EL0 SVE trap 的调用是冗余的——所有调用点后续都会通过 `fpsimd_bind_task_to_cpu()` 根据 TIF_SVE/TIF_SME 覆盖 trap 配置。移除冗余代码。

3. **SME state 被机会主义地释放**: 改变 SVE VL 时，如果 SVCR.{SM,ZA}=={0,0}，`vec_set_vector_length()` 机会主义地释放 sme_state 并清除 TIF_SME。这没有理由，且 SME VL 没有改变所以 sme_state 大小仍然合适。移除不必要的释放。

4. **SME trap 与抢占的竞争** (`d3eaab3c7090`): 与第 9 节 SVE trap 修复相同的问题模式，发生在 `do_sme_acc()` 中。可能导致 TIF_SME 置位但 CPU 上硬件状态 stale（SME trap 使能），触发 `do_sme_acc()` 中的 `WARN_ON(1)`。

5. **FPMR 被 streaming mode 切换破坏** (`e5fa85fce08b`):
   - 硬件规则：PSTATE.SM 变化时硬件自动清零 FPMR（ARM DDI 0487 L.a）
   - 内核 bug：`task_fpsimd_load()` 在恢复 FPMR **之后**才恢复 SVCR（即 PSTATE.{SM,ZA}）
   - 如果恢复的 PSTATE.SM 与当前 CPU 的 PSTATE.SM 不同，硬件清零 FPMR，覆盖刚恢复的值
   - 修复：将 FPMR 的恢复移到 SVCR 恢复之后

6. **kernel FPSIMD 被 SMSTOP 破坏** (`01098d893fa8`):
   - 场景：CPU 在 streaming SVE 模式，上下文切换到有 kernel FPSIMD 状态的任务
   - `fpsimd_thread_switch()` 先恢复 kernel FPSIMD 状态（`fpsimd_load_kernel_state()`）
   - 然后调用 `fpsimd_flush_cpu_state()` 执行 SMSTOP 退出 streaming 模式
   - SMSTOP 导致硬件清零 SVE Z/P 寄存器、FFR、FPMR — **破坏刚恢复的 kernel FPSIMD**
   - 修复：先执行 `fpsimd_flush_cpu_state()` 退出 streaming mode，再恢复 kernel FPSIMD 状态

7. **FPMR 在 exec() 时未重置** (`a90878f297d3`):
   - exec() 应重置所有 FP/SIMD/SVE/SME 状态为零
   - `fpsimd_flush_thread()` 中遗漏了 FPMR 的重置
   - 导致 exec() 后子进程继承父进程的 FPMR 值——信息泄露和安全边界破坏

---

## 16. Ptrace/PRCTL VL 修改修复系列 (v6.14-v6.15)

**作者**: Mark Rutland

**Cover Letter**:
- Subject: [PATCH v2 00/24] arm64: FPSIMD/SVE/SME fixes + re-enable SME
- https://lore.kernel.org/all/20250508132644.1395904-1-mark.rutland@arm.com/

### 涉及的 commits (fpsimd.c)

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `6ef1d778ce56` | arm64/fpsimd: Add task_smstop_sm() | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-9-mark.rutland@arm.com/) |
| `8738288a08b8` | arm64/fpsimd: Factor out {sve,sme}_state_size() helpers | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-8-mark.rutland@arm.com/) |
| `b255be426913` | arm64/fpsimd: Clarify sve_sync_*() functions | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-7-mark.rutland@arm.com/) |
| `b87c8c4aca11` | **arm64/fpsimd: ptrace/prctl: Ensure VL changes leave task in a valid state** | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-16-mark.rutland@arm.com/) |
| `49ce484187f7` | **arm64/fpsimd: ptrace/prctl: Ensure VL changes do not resurrect stale data** | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-15-mark.rutland@arm.com/) |
| `316283f276eb` | **arm64/fpsimd: ptrace: Consistently handle partial writes to NT_ARM_(S)SVE** | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-6-mark.rutland@arm.com/) |
| `398edaa12f9c` | **arm64/fpsimd: Do not discard modified SVE state** | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-2-mark.rutland@arm.com/) |

### 涉及的 commits (ptrace.c)

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `054d627c5554` | arm64/fpsimd: ptrace: Save task state before generating SVE header | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-11-mark.rutland@arm.com/) |
| `b93e685ecff7` | arm64/fpsimd: ptrace: Do not present register data for inactive mode | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-12-mark.rutland@arm.com/) |
| `f916dd32a943` | arm64/fpsimd: ptrace: Mandate SVE payload for streaming-mode state | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-13-mark.rutland@arm.com/) |
| `9f8bf718f292` | arm64/fpsimd: ptrace: Gracefully handle errors | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-14-mark.rutland@arm.com/) |
| `472800cd5e38` | arm64/sme: Support disabling streaming mode via ptrace on SME only systems | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-20-mark.rutland@arm.com/) |
| `128a7494a9f1` | **arm64/fpsimd: ptrace: Fix SVE writes on !SME systems** | [通用] | [link](https://lore.kernel.org/all/20250508132644.1395904-10-mark.rutland@arm.com/) |

### 修复的问题

1. **VL 修改后任务状态非法** (`b87c8c4aca11`):
   - 问题 A：修改 SVE VL 时，如果 `sve_alloc()` 失败，任务留在 PSTATE.ZA==1 但 sve_state==NULL 的非法状态 → 后续 NULL pointer dereference
   - 问题 B：修改 SVE VL 时，如果任务 PSTATE.SM==1，修改后 fp_type 为 FP_STATE_FPSIMD，但 PSTATE.SM 仍为 1 → 非法状态，恢复时可能继承 stale streaming mode predicate 和 FFR
   - 问题 C：修改 SME VL 时，如果任务 PSTATE.SM==1，Z 寄存器低 128 位被迁移到 non-streaming mode（而非清零）
   - 修复：eagerly 分配新的 sve_state/sme_state 再修改任务；保留 PSTATE.SM 和 fp_type，一致截断 SVE 状态

2. **Stale 数据复活** (`49ce484187f7`):
   - `vec_set_vector_length()` 使用 `sve_to_fpsimd()` 从保存的 SVE 状态复制低 128 位到 FPSIMD 状态
   - 但 v6.7 后，任务可能以 FPSIMD 格式存储状态同时 TIF_SVE 被置位，此时 SVE 状态是 stale 的
   - `sve_to_fpsimd()` 会**用 stale SVE 数据覆盖 live FPSIMD 状态**
   - 修复：使用 `fpsimd_sync_from_effective_state()` 替代

3. **Partial ptrace write 不一致** (`316283f276eb`):
   - NT_ARM_SVE / NT_ARM_SSVE 的 partial write 行为历史上不一致且非确定
   - 取决于 TIF_SVE、PSTATE.SM 和 fp_type 的组合，剩余寄存器可能被保留、清零、或从 FPSIMD 迁移
   - 修复：统一为 partial write 时清零未覆盖的状态

4. **SVE 状态被非确定性地丢弃** (`398edaa12f9c`):
   - v6.7 的 SVE 保留优化后，`fpsimd_save_user_state()` 在 syscall 中丢弃 SVE 状态
   - ptrace tracer 在 syscall entry/exit 修改的 SVE 状态可能在 syscall 返回时非确定丢失
   - 破坏了 ptrace 修改 SVE 状态后保留的 ABI
   - `current_pt_regs()->syscallno` 可由 ptrace 修改，进一步非确定化

5. **SVE sync 函数命名/语义混乱** (`b255be426913`):
   - `sve_sync_from_fpsimd_zeropad()` 仍基于 TIF_SVE+PSTATE.SM 判断（而非 fp_type），与已更新的 `sve_sync_to_fpsimd()` 不一致
   - 重命名为 `fpsimd_sync_from_effective_state()` / `fpsimd_sync_to_effective_state_zeropad()`
   - 统一使用 fp_type 判断

6. **Ptrace 读取 SVE header 前未保存状态** (`054d627c5554`):
   生成 SVE regset header 前需要确保 task state 已保存（否则 header 信息可能反映 stale 状态）

7. **SME-only 系统上禁用 streaming mode** (`472800cd5e38`):
   SME-only（无 SVE）系统上 ptrace 无法禁用 streaming mode，需要特殊处理

8. **!SME 系统上 SVE 写入修复** (`128a7494a9f1`):
   SVE 写入到非 SME 系统时的标志检查错误导致写入失败

---

## 17. EFI/Kernel Mode NEON 优化与清理 (v6.14-v6.15)

**作者**: Ard Biesheuvel

此系列包含多个独立 patch，有些有 cover letter，有些是独立提交。

### 17a. fpsimd-on-stack 系列

**Merge tag**: `fpsimd-on-stack-for-linus` (Eric Biggers 的 tree)

**Cover Letter**: 无统一 cover letter，Ard 的多 patch 系列的一部分。

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `4fa617cc6851` | **arm64/fpsimd: Allocate kernel mode FP/SIMD buffers on the stack** | [通用] | (无独立 lore link，含在 merge tag 中) |

**修复**: task_struct 中分配 528 字节的 kernel FPSIMD 状态缓冲区导致内存开销过大（高进程数系统性能影响显著）。改为在调用者栈上透明分配，只在确实需要 context switch 时才存储到 task_struct。

### 17b. IRQ off 支持 + EFI 优化系列

| Commit | 标题 | 标记 | Lore Link |
|--------|------|------|-----------|
| `7137a203b251` | arm64/fpsimd: Permit kernel mode NEON with IRQs off | [通用] | (多 patch 系列，无独立 lore link) |
| `1d038e801833` | arm64/fpsimd: Don't warn when EFI execution context is preemptible | [通用] | 同上 |
| `e04796c8b598` | arm64/fpsimd: Avoid unnecessary per-CPU buffers for EFI runtime calls | [通用] | [link](https://lore.kernel.org/all/20250318132421.3155799-2-ardb+git@google.com/) |
| `63de2b3859ba` | arm64/efi: Remove unneeded SVE/SME fallback preserve/store handling | [通用] | 同系列 |

### 修复的问题

1. **task_struct 膨胀**: Kernel FPSIMD 状态缓冲区（528 bytes）分配在 `struct thread_struct` 中（即 `task_struct` 的一部分），每个任务都有这份开销。大量进程的系统上内存开销不可忽视，影响性能。改为在调用者栈上透明分配，只在确实需要 context switch 时才存储到 task_struct。

2. **关中断时不能使用 kernel NEON**: reboot/poweroff 路径中调用 EFI ResetSystem runtime service 时 IRQ 可能被关闭，而原先 `may_use_simd()` 在关中断时返回 false，导致 kernel NEON 无法使用。修复为条件性 dis/enable softirq（IRQ 已关闭时不需要禁用 softirq），允许关中断时使用 kernel NEON。

3. **EFI 不必要的 per-CPU buffer**: EFI runtime 调用被 `efi_runtime_lock` 全局序列化，不需要 per-CPU 变量保存 FP/SIMD/SVE 状态。改为 singleton 实例，显著节省多核系统内存。

4. **EFI SVE/SME fallback 路径清理**: 自从允许关中断时使用 kernel NEON 后，EFI fallback 路径仅在 hardirq/NMI 上下文中触发（实际只有 EFI pstore panic/oops 场景）。这些场景不会返回用户空间，因此旧的 SVE/SME fallback 保存/恢复逻辑是多余的，可以移除。

---

## 18. 其他修复

| Commit | 版本 | 标题 | Lore Link |
|--------|------|------|-----------|
| `525fd6a1b34e` | v6.13 | [通用] | arm64/fpsimd: Fix a typo | (trivial) |
| `19dd484cd19c` | v6.15 | [通用] | arm64/fpsimd: simplify sme_setup() | (优化) |
| `334a1a1e1a5f` | v6.18 | [通用] | KVM: arm64: Fix comment in fpsimd_lazy_switch_to_host() | (comment fix) |
| `da2e743419cb` | v6.18 | [通用] | KVM: arm64: VHE: Save and restore host MDCR_EL2 value correctly | [link](https://lore.kernel.org/all/20250319235444.1334756-3-oliver.upton@linux.dev/) |
| `fed55f49fad1` | v6.17 | [通用] | arm64: errata: Work around AmpereOne's erratum AC04_CPU_23 | (erratum workaround) |

---

## 19. Cover Letter 汇总表

| 章节 | 作者 | Cover Letter Subject | Lore Link |
|------|------|---------------------|-----------|
| 1 | Ard Biesheuvel | (无独立 cover，为 "kernel mode NEON" 系列 patch 7-9) | [系列入口](https://lore.kernel.org/all/20231208113218.3001940-7-ardb@google.com/) |
| 2 | Ard Biesheuvel | (无 cover letter，bug 报告见) | [Bug report](https://lore.kernel.org/all/cb8822182231850108fa43e0446a4c7f@kernel.org/) |
| 3 | Mark Brown | [PATCH v3 0/2] arm64/sme: Fix resume from suspend | [link](https://lore.kernel.org/all/20240213-arm64-sme-resume-v3-0-17e05e493471@kernel.org/) |
| 4a | Mark Brown | (单 patch，无 cover) | [link](https://lore.kernel.org/all/20240130-arm64-sve-signal-regs-v2-1-9fc6f9502782@kernel.org/) |
| 4b | Mark Rutland | [PATCH v2 00/13] arm64: Preparatory FPSIMD/SVE/SME fixes | [link](https://lore.kernel.org/all/20250409164010.3480271-1-mark.rutland@arm.com/) |
| 5a | Mark Brown | [PATCH v1] arm64/sme: Always exit sme_alloc() early with existing storage | [link](https://lore.kernel.org/all/20240115-arm64-sme-flush-v1-0-7472bd3459b7@kernel.org/) |
| 5b | Mark Brown | [PATCH v1] arm64/fpsimd: Remove spurious check for SVE support | [link](https://lore.kernel.org/all/20240115-arm64-sve-enabled-check-v1-0-a26360b00f6d@kernel.org/) |
| 6 | Mark Brown | [PATCH v2] arm64/sve: Lower the maximum allocation for the SVE ptrace regset | [link](https://lore.kernel.org/all/20240213-arm64-sve-ptrace-regset-size-v2-0-c7600ca74b9b@kernel.org/) |
| 7 | Mark Brown | [PATCH v5 0/8] arm64: Support for 2023 DPISA extensions | [link](https://lore.kernel.org/all/20240306-arm64-2023-dpisa-v5-0-c568edc8ed7f@kernel.org/) |
| 8 | Mark Brown | [PATCH v1 0/2] arm64/fp: Ensure that all fields in ZCR/SMCR are set to known values | [link](https://lore.kernel.org/all/20240213-arm64-fp-init-vec-cr-v1-0-7e7c2d584f26@kernel.org/) |
| 9 | Mark Rutland | [PATCH 0/2] arm64/fp: Fix missing invalidation when working with foreign FP state | [link](https://lore.kernel.org/all/20241030-arm64-fpsimd-foreign-flush-v1-0-bd7bd66905a2@kernel.org/) |
| 10a | Mark Rutland | (多 patch 系列，fpmr partial write 是 patch 3/5) | [系列入口](https://lore.kernel.org/all/20241205121655.1824269-1-mark.rutland@arm.com/) |
| 10b | Mark Brown | (单 patch，无 cover) | [link](https://lore.kernel.org/all/20240325-arm64-ptrace-fp-type-v1-1-8dc846caf11f@kernel.org/) |
| 11 | Marc Zyngier | [PATCH v4 0/8] KVM: arm64: Add support for FP8 | [link](https://lore.kernel.org/all/20240820131802.3547589-1-maz@kernel.org/) |
| 12 | Mark Rutland | [PATCH v3 0/8] KVM: arm64: FPSIMD/SVE/SME fixes | [link](https://lore.kernel.org/all/20250210195226.1215254-1-mark.rutland@arm.com/) |
| 13 | Oliver Upton | [PATCH v3 00/15] KVM: arm64: nv: FPSIMD/SVE, plus some other CPTR goodies | [link](https://lore.kernel.org/all/20240620164653.1130714-1-oliver.upton@linux.dev/) |
| 14 | Fuad Tabba | [PATCH v4 0/9] KVM: arm64: Fix handling of host fpsimd/sve state in protected mode | [link](https://lore.kernel.org/all/20240603122852.3923848-1-tabba@google.com/) |
| 15a | Mark Brown | [PATCH v2 0/6] arm64/sme: Collected SME fixes | [link](https://lore.kernel.org/all/20241204-arm64-sme-reenable-v2-0-bae87728251d@kernel.org/) |
| 15b | Mark Rutland | [PATCH v2 00/13] arm64: Preparatory FPSIMD/SVE/SME fixes (与 4b 同系列) | [link](https://lore.kernel.org/all/20250409164010.3480271-1-mark.rutland@arm.com/) |
| 16 | Mark Rutland | [PATCH v2 00/24] arm64: FPSIMD/SVE/SME fixes + re-enable SME | [link](https://lore.kernel.org/all/20250508132644.1395904-1-mark.rutland@arm.com/) |
| 17a | Ard Biesheuvel | Merge tag `fpsimd-on-stack-for-linus` (Eric Biggers tree) | (merge tag, 无独立 cover letter) |
| 17b | Ard Biesheuvel | (多独立 patch 合并，无统一 cover) | [EFI buffer patch](https://lore.kernel.org/all/20250318132421.3155799-2-ardb+git@google.com/) |

---

## 20. 回合建议

### 依赖关系

如果要使能 ARM FP8 特性，以下是推荐的回合顺序：

```
第1层 (基础修复, v6.8):
  └─ 5. SME 状态分配修复 (dc7eb8755797, 8410186ca480)
  └─ 3. SME Suspend/Resume (9533864816fb, d7b77a0d565b)
  └─ 6. Ptrace SVE Regset (2813926261e4)

第2层 (信号/状态跟踪修复, v6.8-v6.9):
  └─ 4a. Signal 保存格式修复 (61da7c8e2a60)
  └─ 8. ZCR/SMCR 已知值 (2f0090549b64, 93576e349887)

第3层 (kernel NEON 基础设施, v6.8):
  └─ 1. Kernel Mode NEON Context Switch
      (9b19700e623f, aefbab8e77eb, 2632e2521769)
  └─ 2. Lazy Restore 回归修复
      (b8995a184170, f481bb32d60e, e92bee9f861b)

第4层 (FEAT_FPMR 使能, v6.9):
  └─ 7. FEAT_FPMR 支持 (203f2b95a882, 4035c22ef7d4, 8c46def44409)

第5层 (FPMR Bug 修复, v6.14):
  └─ 15. SME/FPMR Bug 修复 (全部)
  └─ 先决条件: d3a181588df9 (fpsimd_save_and_flush_current_state)

第6层 (KVM 支持, v6.12+):
  └─ 11. KVM FPMR/FP8 支持
  └─ 12. KVM Host FP State 管理重写 (先决条件)
  └─ 13. KVM NV SVE (如果支持 NV)
  └─ 14. pKVM FP 修复 (如果使用 pKVM)

第7层 (全面修复, v6.14-v6.15):
  └─ 4b. Signal 处理全面重写 (依赖 fpsimd_save_and_flush_current_state)
  └─ 16. Ptrace VL 修改修复
  └─ 17. EFI/Kernel NEON 优化
```

### 最小回合集（使能 FP8 并修复已知严重 bug，含 KVM）

以下是在 6.6 上使能 FP8 且稳定运行（含 KVM guest 支持）的最小补丁集合。补丁按回合顺序排列，同一 cover letter 系列的补丁尽量一起回合以减少冲突。每个 commit 附带了所属 cover letter 的 lore 链接。

---

#### 第 1 组: 基础依赖 — fpsimd_save_and_flush_current_state

| Commit | 标题 | 标记 | Cover Letter |
|--------|------|------|-------------|
| `d3a181588df9` | arm64/fpsimd: Add fpsimd_save_and_flush_current_state() | [通用] | [PATCH v2 00/13] Preparatory FPSIMD/SVE/SME fixes |

- Cover: https://lore.kernel.org/all/20250409164010.3480271-1-mark.rutland@arm.com/

**说明**: 此函数被后续信号修复、FPMR 修复和 KVM host FP 管理重写所依赖，是基础设施。

---

#### 第 2 组: FEAT_FPMR / FP8 特性使能 (v6.9)

| Commit | 标题 | 标记 | Cover Letter |
|--------|------|------|-------------|
| `203f2b95a882` | arm64/fpsimd: Support FEAT_FPMR | [FPMR] | [PATCH v5 0/8] Support for 2023 DPISA extensions |
| `4035c22ef7d4` | arm64/ptrace: Expose FPMR via ptrace | [FPMR] | (同上) |
| `8c46def44409` | arm64/signal: Add FPMR signal handling | [FPMR] | (同上) |

- Cover: https://lore.kernel.org/all/20240306-arm64-2023-dpisa-v5-0-c568edc8ed7f@kernel.org/

**说明**: 核心 FP8 使能补丁，上下文切换 + ptrace + 信号处理。注意该系列还包含其他 DPISA 特性（如 FEAT_SME_F16F16 等），如需完整 DPISA 支持应回合整个系列。

---

#### 第 3 组: SVE/SME Trap 竞争修复 (v6.12)

| Commit | 标题 | 标记 | Cover Letter |
|--------|------|------|-------------|
| `751ecf6afd65` | arm64/sve: Discard stale CPU state when handling SVE traps | [通用] | [PATCH 0/2] Fix missing invalidation when working with foreign FP state |
| `d3eaab3c7090` | arm64/fpsimd: Discard stale CPU state when handling SME traps | [通用] | [PATCH v2 0/6] arm64/sme: Collected SME fixes |

- Cover (751ecf6afd65): https://lore.kernel.org/all/20241030-arm64-fpsimd-foreign-flush-v1-0-bd7bd66905a2@kernel.org/
- Cover (d3eaab3c7090): https://lore.kernel.org/all/20241204-arm64-sme-reenable-v2-0-bae87728251d@kernel.org/

**说明**: SVE 和 SME trap handler 中因抢占导致 stale CPU state 被重用，触发 `WARN_ON(1)` 并导致用户态寄存器状态错误。任何使用 SVE/SME（包括 streaming mode）的系统上都可能触发。

---

#### 第 4 组: FPMR / 信号 Bug 修复 (v6.14)

| Commit | 标题 | 标记 | Cover Letter |
|--------|------|------|-------------|
| `95507570fb2f` | arm64/fpsimd: Avoid RES0 bits in the SME trap handler | [通用] | [PATCH v2 00/13] Preparatory FPSIMD/SVE/SME fixes |
| `e5fa85fce08b` | arm64/fpsimd: Don't corrupt FPMR when streaming mode changes | [FPMR] | [PATCH v2 0/6] arm64/sme: Collected SME fixes |
| `01098d893fa8` | arm64/fpsimd: Avoid clobbering kernel FPSIMD state with SMSTOP | [通用] | [PATCH v2 00/13] Preparatory FPSIMD/SVE/SME fixes |
| `a90878f297d3` | arm64/fpsimd: Reset FPMR upon exec() | [FPMR] | (同上) |
| `c94f2f326146` | arm64/fpsimd: Fix merging of FPSIMD state during signal return | [通用] | (同上) |
| `929fa99b1215` | arm64/fpsimd: signal: Always save+flush state early | [通用] | (同上) |

- Cover (Mark Rutland 系列, 4 个 patch): https://lore.kernel.org/all/20250409164010.3480271-1-mark.rutland@arm.com/
- Cover (e5fa85fce08b): https://lore.kernel.org/all/20241204-arm64-sme-reenable-v2-0-bae87728251d@kernel.org/

**说明**:
- `95507570fb2f`: SME trap handler 使用 ESR RES0 bits 判断 trap 类型，未来 RES0 位被赋予新含义会误判
- `e5fa85fce08b`: FPMR 在 SM 切换时被硬件清零，内核恢复 FPMR 在 SVCR 之前导致值丢失
- `01098d893fa8`: SMSTOP 执行在 kernel FPSIMD 恢复之后，导致刚恢复的状态被硬件清零
- `a90878f297d3`: exec() 后 FPMR 未重置为 0，信息泄露 / 安全边界破坏
- `c94f2f326146`: 信号返回时 FPSIMD 低 128 位合并非确定性地失败（SME without SVE 系统上永远失败）
- `929fa99b1215`: 信号处理中 FPMR 可能在错误的 ownership 上下文中被访问，导致损坏

---

#### 第 5 组: KVM FPMR/FP8 支持 (v6.12)

| Commit | 标题 | 标记 | Cover Letter |
|--------|------|------|-------------|
| `7d9c1ed6f4bf` | KVM: arm64: Move FPMR into the sysreg array | [FPMR] | [PATCH v4 0/8] KVM: arm64: Add support for FP8 |
| `ef3be86021c3` | KVM: arm64: Add save/restore support for FPMR | [FPMR] | (同上) |
| `b8f669b491ec` | KVM: arm64: Honor trap routing for FPMR | [FPMR] | (同上) |
| `c9150a8ad9cd` | KVM: arm64: Enable FP8 support when available and configured | [FPMR] | (同上) |

- Cover: https://lore.kernel.org/all/20240820131802.3547589-1-maz@kernel.org/

**说明**: 在 KVM 中使能 FP8 —— FPMR 纳入 sysreg 数组进行 save/restore、trap routing 正确配置、用户空间可控制是否向 guest 暴露 FP8。注意该系列依赖第 1 组和第 2 组（`203f2b95a882`）。

---

#### 第 6 组: KVM Host FP State 管理重写 (v6.14)

| Commit | 标题 | 标记 | Cover Letter |
|--------|------|------|-------------|
| `fbc7e61195e2` | KVM: arm64: Unconditionally save+flush host FPSIMD/SVE/SME state | [通用] | [PATCH v3 0/8] KVM: arm64: FPSIMD/SVE/SME fixes |
| `8eca7f6d5100` | KVM: arm64: Remove host FPSIMD saving for non-protected KVM | [通用] | (同上) |
| `407a99c4654e` | KVM: arm64: Remove VHE host restore of CPACR_EL1.SMEN | [通用] | (同上) |
| `459f059be702` | KVM: arm64: Remove VHE host restore of CPACR_EL1.ZEN | [通用] | (同上) |
| `59419f10045b` | KVM: arm64: Eagerly switch ZCR_EL{1,2} | [通用] | (同上) |

- Cover: https://lore.kernel.org/all/20250210195226.1215254-1-mark.rutland@arm.com/

**说明**: 该系列修复 host SVE 在 VM entry/exit 过程中被意外丢弃（QEMU + SVE memmove 崩溃）、host FPMR 值被污染、ZCR_EL2 VL 不匹配导致 SIGKILL 等问题。这是 KVM guest 使用 FP8 的前置条件。注意该系列依赖第 1 组（`d3a181588df9`）。

---

#### 第 7 组: 编译修复

| Commit | 标题 | 标记 | Cover Letter |
|--------|------|------|-------------|
| `f699c66691fb` | arm64/fpsimd: Avoid warning when sve_to_fpsimd() is unused | [通用] | (单 patch, 无 cover) |

- Patch: https://lore.kernel.org/all/20250430173240.4023627-1-mark.rutland@arm.com/

**说明**: 回合第 4 组后 `sve_to_fpsimd()` 在 `CONFIG_ARM64_SVE=n` 时无人调用，产生 `-Wunused-function` 编译 warning。

---

#### 最小回合集汇总

**非 KVM 场景（13 个 commit）**:

```
d3a181588df9 arm64/fpsimd: Add fpsimd_save_and_flush_current_state()
203f2b95a882 arm64/fpsimd: Support FEAT_FPMR
4035c22ef7d4 arm64/ptrace: Expose FPMR via ptrace
8c46def44409 arm64/signal: Add FPMR signal handling
751ecf6afd65 arm64/sve: Discard stale CPU state when handling SVE traps
d3eaab3c7090 arm64/fpsimd: Discard stale CPU state when handling SME traps
95507570fb2f arm64/fpsimd: Avoid RES0 bits in the SME trap handler
e5fa85fce08b arm64/fpsimd: Don't corrupt FPMR when streaming mode changes
01098d893fa8 arm64/fpsimd: Avoid clobbering kernel FPSIMD state with SMSTOP
a90878f297d3 arm64/fpsimd: Reset FPMR upon exec()
c94f2f326146 arm64/fpsimd: Fix merging of FPSIMD state during signal return
929fa99b1215 arm64/fpsimd: signal: Always save+flush state early
f699c66691fb arm64/fpsimd: Avoid warning when sve_to_fpsimd() is unused
```

**含 KVM 的全集（22 个 commit）**:

```
d3a181588df9 arm64/fpsimd: Add fpsimd_save_and_flush_current_state()
203f2b95a882 arm64/fpsimd: Support FEAT_FPMR
4035c22ef7d4 arm64/ptrace: Expose FPMR via ptrace
8c46def44409 arm64/signal: Add FPMR signal handling
751ecf6afd65 arm64/sve: Discard stale CPU state when handling SVE traps
d3eaab3c7090 arm64/fpsimd: Discard stale CPU state when handling SME traps
95507570fb2f arm64/fpsimd: Avoid RES0 bits in the SME trap handler
e5fa85fce08b arm64/fpsimd: Don't corrupt FPMR when streaming mode changes
01098d893fa8 arm64/fpsimd: Avoid clobbering kernel FPSIMD state with SMSTOP
a90878f297d3 arm64/fpsimd: Reset FPMR upon exec()
c94f2f326146 arm64/fpsimd: Fix merging of FPSIMD state during signal return
929fa99b1215 arm64/fpsimd: signal: Always save+flush state early
7d9c1ed6f4bf KVM: arm64: Move FPMR into the sysreg array
ef3be86021c3 KVM: arm64: Add save/restore support for FPMR
b8f669b491ec KVM: arm64: Honor trap routing for FPMR
c9150a8ad9cd KVM: arm64: Enable FP8 support when available and configured
fbc7e61195e2 KVM: arm64: Unconditionally save+flush host FPSIMD/SVE/SME state
8eca7f6d5100 KVM: arm64: Remove host FPSIMD saving for non-protected KVM
407a99c4654e KVM: arm64: Remove VHE host restore of CPACR_EL1.SMEN
459f059be702 KVM: arm64: Remove VHE host restore of CPACR_EL1.ZEN
59419f10045b KVM: arm64: Eagerly switch ZCR_EL{1,2}
f699c66691fb arm64/fpsimd: Avoid warning when sve_to_fpsimd() is unused
```

**注意**: 如果使用 pKVM 还需要额外回合第 14 节（pKVM FP 修复）的补丁；如果使用 NV 还需要第 13 节（KVM NV SVE）。

---

## 21. 测试方法

### 21.1 前置条件

- 测试硬件需要支持 FEAT_FPMR（FP8）、SVE、SME（最好 SVE+SME 都支持的硬件，如 ARM FVP 或支持这些特性的实际 SoC）
- 如无 SME 硬件，至少确保 SVE 路径正确
- 在 6.6 上回合 patchset 后编译安装内核

### 21.2 基础功能测试 — kselftest

```bash
cd tools/testing/selftests/arm64

# 编译所有测试
make -C fp
make -C signal

# === FP/SIMD 功能测试 ===
# 读取 SVE VL
./fp/rdvl_sve
# 读取 SME VL
./fp/rdvl_sme
# 探测可用 VL
./fp/sve-probe-vls
./fp/sme-probe-vls
# Vector 系统配置
./fp/vec-syscfg

# === 信号处理测试 ===
./signal/testcases/sve_regs          # SVE 信号保存/恢复
./signal/testcases/sme_regs          # SME 信号保存/恢复
./signal/testcases/fpmr_regs         # FPMR 信号保存/恢复 (需要硬件)
./signal/testcases/ssve_regs         # Streaming SVE 信号
./signal/testcases/za_regs           # ZA 信号
./signal/testcases/tpidr2_siginfo    # TPIDR2 信号

# 返回码检查：所有测试应 PASS
```

### 21.3 压力测试

```bash
# fpsimd-stress: 并发运行多个 FPSIMD/SVE/SME 测试进程
# -t 指定最长运行时间(秒)，建议至少 300 秒
./fp/fpsimd-stress -t 300

# 在运行期间不断检查 dmesg 是否有 WARN/BUG
dmesg -w | grep -E "WARN|BUG|SVE|SME|fpsimd|FPMR"
```

### 21.4 Syscall + Ptrace 并发测试

验证信号处理的竞争条件和 ptrace 行为修复：

```bash
# 编写 SVE 循环测试程序
cat > /tmp/sve_loop.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <arm_sve.h>
void handler(int sig) {
    svfloat32_t v = svdup_f32(2.0f);
}
int main() {
    signal(SIGUSR1, handler);
    signal(SIGUSR2, handler);
    while(1) {
        svfloat32_t v = svdup_f32(1.0f);
        for(volatile int i=0; i<1000; i++);
        usleep(100);
    }
}
EOF

# 编译 (需要 SVE 编译器支持)
# aarch64-linux-gnu-gcc -march=armv8-a+sve -o /tmp/sve_loop /tmp/sve_loop.c

# 运行并用 GDB attach/detach
# 验证 NT_ARM_SVE regset 读写正确
# 并发用 kill -USR1/USR2 发送信号
```

### 21.5 KVM 测试

```bash
# 启动带有 SVE/SME 的 guest VM
qemu-system-aarch64 \
  -M virt,gic-version=3 \
  -cpu max,sve=on,sme=on \
  -m 4G -smp 4 \
  -kernel /path/to/guest_Image \
  -append "console=ttyAMA0" \
  -nographic

# Guest 内运行:
# ./fp/fpsimd-stress -t 300
# ./fp/sve-probe-vls
# ./fp/sme-probe-vls
```

#### Host/Guest 交替压力测试

```bash
# Host 上运行 SVE/SME 负载
./fp/fpsimd-stress -t 600 &

# 同时启动多个 VM 运行 SVE/SME 密集计算
# 关键观察:
# - 是否出现 SIGKILL (SVE VL 不匹配导致)
# - 是否有 kernel WARN/BUG
# - Host SVE 状态是否在 VM entry/exit 过程中丢失

# 监控命令:
dmesg -w | grep -iE "sve|sme|fpsimd|fpmr|sigkill|warn"
```

#### 如果支持 NV（嵌套虚拟化）

```bash
# 启动 L1 guest (作为 hypervisor)
# 在 L1 内启动 L2 guest
# 验证 SVE trap 转发、ZCR_EL2 VL 正确设置
# 验证 FPMR save/restore
```

### 21.6 休眠恢复测试

```bash
# 启动 SVE/SME 程序后执行休眠
./fp/fpsimd-stress &
FP_PID=$!
sleep 5

# 触发 suspend to RAM
rtcwake -m mem -s 10

# 恢复后检查
kill $FP_PID
# 检查 dmesg 无 SMCR_EL1/SMPRI_EL1 相关 warning
# 重新运行 fpsimd-stress 确认功能正常
./fp/fpsimd-stress -t 60
```

### 21.7 EFI Runtime 测试

仅适用于 EFI 系统：

```bash
# 1. reboot/poweroff 路径测试 (调用 EFI ResetSystem)
# 正常重启系统，确认无 kernel BUG/WARN
reboot

# 2. EFI pstore 路径测试 (panic 时写 EFI 变量)
# 触发 panic 前确认 EFI pstore 后端已配置:
# CONFIG_EFI_PSTORE=y
# CONFIG_PSTORE=y
# 注意: 这会重启系统，保存工作先
echo c > /proc/sysrq-trigger
# 重启后检查 /sys/fs/pstore/ 是否有日志
```

### 21.8 性能回归测试

```bash
# Kernel mode NEON crypto 性能
# 验证 context switch 改进没有引起性能回退
cryptsetup benchmark --cipher aes-xts

# 对比回合前后的性能数据
# 预期: 性能不应有明显下降
# v6.8 的 kernel mode NEON 改进可能改善实时延迟
```

### 21.9 FPMR 针对性验证

```bash
# 测试 1: FPMR 在 exec() 后清零
cat > /tmp/fpmr_exec_test.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/wait.h>

// 在父进程中通过 ptrace 或内联汇编设置 FPMR
// 然后 exec 子进程检查 FPMR 值

int main() {
    // 子进程在 exec 后应有 FPMR == 0
    printf("FPMR exec test: check dmesg and FPMR value after exec\n");
    return 0;
}
EOF

# 测试 2: SM 切换不破坏 FPMR
# 编写程序在 streaming / non-streaming 模式间切换
# 每次切换后验证 FPMR 值保持不变

# 测试 3: 信号返回后 FPSIMD 合并
# SME+SVE 系统上，信号返回后 Z 寄存器低 128 位应正确
```

### 21.10 推荐测试执行顺序

按重要性排序，至少执行前 4 项：

| 优先级 | 测试项 | 预期耗时 | 关键验证点 |
|--------|--------|---------|-----------|
| **P0** | kselftest arm64 fp/signal | 5 min | 所有测试 PASS |
| **P0** | fpsimd-stress 长时间运行 | 5-30 min | 无 WARN/BUG/SIGKILL |
| **P1** | KVM guest SVE/SME + host 并发 | 10-30 min | host SVE 不丢失、无 SIGKILL |
| **P1** | 休眠恢复测试 | 5 min | SMCR_EL1/SMPRI_EL1 恢复正确 |
| **P2** | 信号处理回归测试 | 10 min | FPSIMD 合并、FPMR 信号帧 |
| **P2** | Ptrace SVE/SME regset 测试 | 10 min | VL 修改、partial write |
| **P3** | EFI/Kernel NEON 路径 | 5 min | reboot/panic 路径正常 |
| **P3** | 性能回归 (crypto benchmark) | 5 min | cipher 性能无明显下降 |

---

## 附录 A: ARM64 信号帧 (Signal Frame) 机制

### A.1 什么是信号帧

信号帧是内核在**用户态进程的栈上**构造的一块内存，用于在信号处理期间保存进程的完整 CPU 上下文。它是信号处理机制实现 "透明中断" 的核心——进程被信号中断、执行 signal handler、然后通过 sigreturn 恢复，就好像什么都没发生过。

### A.2 信号处理的完整流程

```
时间线:
  ┌──────────────────────────────────────────────────────────┐
  │ 1. 进程正常运行 (user mode, 使用 SVE/FPMR/ZA 等寄存器)     │
  ├──────────────────────────────────────────────────────────┤
  │ 2. 信号到达 (硬件中断/定时器/kill/其他进程发来)              │
  │    内核切换到信号处理路径:                                  │
  │      a) fpsimd_save_and_flush_current_state()             │
  │         → 把当前 live 的 FP/SVE/SME 状态保存到 task_struct │
  │      b) get_sigframe() → 在用户栈上分配 sigframe 空间       │
  │      c) setup_sigframe() → 把所有寄存器 dump 到 sigframe   │
  │      d) setup_return() → 篡改 PC=handler, SP=跳过 sigframe │
  ├──────────────────────────────────────────────────────────┤
  │ 3. 信号 handler 执行 (user mode)                          │
  │    可以通过 ucontext 读写 sigframe 里的寄存器内容           │
  │    可以调用 sigreturn() 返回，也可以直接 exit/longjmp       │
  ├──────────────────────────────────────────────────────────┤
  │ 4. sigreturn() 系统调用                                   │
  │    内核从 sigframe 中逐一恢复所有寄存器                      │
  │    进程从被中断的地方继续执行                               │
  └──────────────────────────────────────────────────────────┘
```

### A.3 信号帧的内存布局

```
高地址 (栈顶方向)
┌─────────────────────────────────┐
│   struct rt_sigframe {           │  ← "信号帧" 整体
│                                  │
│     // ---- 固定头部 ----         │
│     struct siginfo info;         │  si_signo, si_code, si_addr ...
│                                  │
│     struct ucontext uc {         │
│       uc_flags;                  │
│       uc_link;                   │
│       uc_stack;                  │  信号栈信息
│       uc_sigmask;                │  信号屏蔽字
│                                  │
│       struct sigcontext {        │  uc_mcontext
│         __u64 regs[0..30];       │  GP 寄存器 (x0-x30)
│         __u64 sp;                │  栈指针
│         __u64 pc;                │  程序计数器
│         __u64 pstate;            │  处理器状态
│       } mcontext;                │
│                                  │
│       // ---- 可扩展的记录链 ----  │
│       __u8 __reserved[4096];     │  ← 实际是变长的
│         ┌──────────────────┐     │
│         │ fpsimd_context   │     │  magic=FPSIMD_MAGIC
│         │  .magic, .size   │     │  V0-V31, FPSR, FPCR
│         │  .fpsr, .fpcr    │     │
│         │  .vregs[0..31]   │     │
│         ├──────────────────┤     │
│         │ sve_context      │     │  magic=SVE_MAGIC (可选)
│         │  .z[0..31]       │     │  SVE Z 寄存器
│         │  .p[0..15]       │     │  SVE P 寄存器
│         │  .ffr            │     │
│         ├──────────────────┤     │
│         │ tpidr2_context   │     │  magic=TPIDR2_MAGIC (可选)
│         ├──────────────────┤     │
│         │ fpmr_context     │     │  magic=FPMR_MAGIC (可选)
│         │  .fpmr           │     │  FP8 格式控制寄存器
│         ├──────────────────┤     │
│         │ za_context       │     │  magic=ZA_MAGIC (可选)
│         ├──────────────────┤     │
│         │ zt_context       │     │  magic=ZT_MAGIC (可选)
│         ├──────────────────┤     │
│         │ extra_context    │     │  magic=EXTRA_MAGIC
│         │  (更多扩展...)    │     │  超大寄存器的溢出区
│         ├──────────────────┤     │
│         │ ...              │     │
│         │ terminator       │     │  magic=0, size=0 (结束标记)
│         └──────────────────┘     │
│     } ucontext;                  │
│   } rt_sigframe;                 │
├─────────────────────────────────┤
│   进程原始栈帧                     │
└─────────────────────────────────┘
低地址
```

### A.4 可扩展记录链 (Extensible Context Records)

ARM64 信号帧最精巧的设计：`uc_mcontext.__reserved[]` 不是固定布局，而是一个由 `{magic, size}` 组成的**单向链表**。

每个 record 的结构:
```c
struct _aarch64_ctx {
    __u32 magic;  // 类型标识 (FPSIMD_MAGIC, SVE_MAGIC, FPMR_MAGIC ...)
    __u32 size;   // 本 record 的总大小 (含 head), 用于遍历
    // 后面跟着 record 特定的数据
};
```

**遍历逻辑** (用户态/内核通用):
```c
struct _aarch64_ctx *ctx = (void *)uc->uc_mcontext.__reserved;
while (ctx->magic != 0) {       // magic=0 是结束标记
    switch (ctx->magic) {
    case FPSIMD_MAGIC:  /* 处理 FPSIMD */  break;
    case SVE_MAGIC:     /* 处理 SVE */     break;
    case FPMR_MAGIC:    /* 处理 FPMR */    break;
    // ... 不认识的 magic → 直接跳过
    }
    ctx = (void *)ctx + ctx->size;  // size 包含 head, 跳到下一个
}
```

**这个设计的核心价值**:
- **向前兼容**: 旧内核不知道 FPMR → 信号帧中没有 FPMR context → 旧用户态代码跳过
- **向后兼容**: 旧用户态不认识 FPMR_MAGIC → 根据 size 跳过 → 不影响后续 record 解析
- **可扩展**: 每个新寄存器类型只需定义新的 magic + data struct，无需修改已有结构体

### A.5 构造过程 (setup_rt_frame)

```c
static int setup_rt_frame(int usig, struct ksignal *ksig, sigset_t *set,
                          struct pt_regs *regs)
{
    // 步骤 1: 先把当前 live 的 FP 状态保存到 task_struct
    fpsimd_save_and_flush_current_state();

    // 步骤 2: 在用户栈上分配空间
    get_sigframe(&user, ksig, regs);

    // 步骤 3: 填写信号帧 (dump 所有寄存器)
    setup_sigframe(&user, regs, set);
    //   ├── __put_user(regs->regs[i], &sf->uc.uc_mcontext.regs[i])  // GP 寄存器
    //   ├── preserve_fpsimd_context()   → fpsimd_context record
    //   ├── preserve_sve_context()      → sve_context record (如果有 SVE)
    //   ├── preserve_fpmr_context()     → fpmr_context record (如果有 FPMR)
    //   ├── preserve_za_context()       → za_context record (如果有 ZA)
    //   └── ...

    // 步骤 4: 篡改 PC 和 SP, "返回用户空间" → 实际进入 signal handler
    setup_return(regs, ksig, &user, usig);
    //   regs->pc = handler_addr;
    //   regs->sp = (unsigned long)frame;
}
```

### A.6 恢复过程 (restore_sigframe)

```c
static int restore_sigframe(struct pt_regs *regs,
                            struct rt_sigframe __user *sf)
{
    // 步骤 1: 再次确保当前状态已保存 (防御性)
    fpsimd_save_and_flush_current_state();

    // 步骤 2: 解析信号帧, 遍历所有 context record
    parse_user_sigframe(&user, sf);
    //   遍历 __reserved[], 填 user.fpsimd / user.sve / user.fpmr / user.za ...

    // 步骤 3: 按顺序恢复寄存器
    restore_fpsimd_context(&user);     // V0-V31, 清除 PSTATE.SM
    restore_sve_fpsimd_context(&user); // 如果有 SVE
    restore_fpmr_context(&user);       // ★ FPMR (在 SM 切换之后, 安全)
    restore_za_context(&user);         // ZA (如果有)
    restore_zt_context(&user);         // ZT0 (如果有)

    // 步骤 4: 恢复 GP 寄存器
    for (i = 0; i < 31; i++)
        regs->regs[i] = sf->uc.uc_mcontext.regs[i];
    regs->sp  = sf->uc.uc_mcontext.sp;
    regs->pc  = sf->uc.uc_mcontext.pc;  // → 跳回被中断的位置
}
```

**恢复顺序至关重要**: FPMR 必须在 PSTATE.SM 切换之后恢复, 因为硬件在 SM 切换时会自动清零 FPMR。`restore_fpsimd_context()` 先清除了 PSTATE.SM, `restore_fpmr_context()` 随后写入 FPMR, 顺序正确。

### A.7 FPMR 在信号帧中的位置

```
setup_sigframe()
  ...
  ├── preserve_fpsimd_context()   ← 保存 V0-V31
  ├── preserve_sve_context()      ← 保存 SVE (如果 TIF_SVE)
  ├── preserve_tpidr2_context()   ← 保存 TPIDR2
  ├── preserve_fpmr_context()     ← ★ 保存 FPMR
  │       current->thread.uw.fpmr = read_sysreg_s(SYS_FPMR);  // 硬件 → 内存
  │       __put_user(FPMR_MAGIC,  &ctx->head.magic);
  │       __put_user(sizeof(*ctx), &ctx->head.size);
  │       __put_user(current->thread.uw.fpmr, &ctx->fpmr);    // 内存 → 信号帧
  └── ...

restore_sigframe()
  ...
  ├── parse_user_sigframe()      ← 找 FPMR_MAGIC, 记录指针和 size
  ├── restore_fpsimd_context()   ← 恢复 V0-V31, 清除 PSTATE.SM
  ├── restore_fpmr_context()     ← ★ 恢复 FPMR
  │       fpmr = user->fpmr->fpmr;                // 信号帧 → 局部变量
  │       write_sysreg_s(fpmr, SYS_FPMR);         // 局部变量 → 硬件
  └── ...
```

### A.8 PCIe AER 类比

信号帧的设计理念类似于 PCIe AER (Advanced Error Reporting) 中的扩展 capabilities 链表:

| 特性 | PCIe Capabilities | ARM64 Signal Frame |
|------|------------------|-------------------|
| 遍历方式 | `pcie_cap + offset` 链表 | `{magic, size}` 链表 |
| 兼容性 | 未知 cap → 跳过 | 未知 magic → 跳过 |
| 终止条件 | 特定 cap id | magic=0 |
| 可扩展性 | 新 cap 加新 id | 寄存器加新 magic |

---

## 附录 B: Ptrace 寄存器读写原理 — 一个调试案例

### B.1 场景

你写了一个 FP8 程序，怀疑 FPMR 配置错了导致计算结果异常。用 GDB 断点停在关键函数处，想看一眼 FPMR 的当前值：

```c
// test_fp8.c
#include <arm_fp8.h>
int main() {
    __arm_wsr_fpmr(0x8842);         // 写入 FPMR, 选择 FP8 格式
    do_fp8_matmul();                // ← 怀疑这里算错了
    return 0;
}
```

```gdb
$ gdb ./test_fp8
(gdb) b do_fp8_matmul
(gdb) run

Breakpoint 1, do_fp8_matmul () at test_fp8.c:5

(gdb) p/x $fpmr                    ← 你敲下这行
$1 = 0x8842                        ← GDB 显示了 FPMR 的值
```

### B.2 从敲下回车到看到结果, 分三步

**第一步: GDB 把 `$fpmr` 翻译成 ptrace 系统调用**

GDB 维护了一张寄存器表, 记录每个寄存器名对应哪个 ptrace regset。`$fpmr` 的映射是:

```
GDB 寄存器名      ptrace 参数                           读的是
────────────────────────────────────────────────────────────────
$x0 .. $x30       PTRACE_GETREGSET, NT_PRSTATUS         GP 寄存器组
$sp, $pc, $cpsr   同上
$v0 .. $v31       PTRACE_GETREGSET, NT_ARM_FPREGSET     FPSIMD V 寄存器组
$z0 .. $z31       PTRACE_GETREGSET, NT_ARM_SVE          SVE Z 寄存器组
$fpmr             PTRACE_GETREGSET, NT_ARM_FPMR    ←    FPMR 寄存器
```

所以 `p/x $fpmr` 实际上触发了:

```c
// GDB 内部执行的系统调用 (伪代码)
struct iovec iov = { .iov_base = buf, .iov_len = 8 };
ptrace(PTRACE_GETREGSET, 被调试进程的pid, NT_ARM_FPMR, &iov);
// 调用返回后, buf 里就是 tracee 的 FPMR 值
```

**第二步: 内核在 regset 数组中查找 NT_ARM_FPMR**

```
sys_ptrace()
  └─→ ptrace_request()
        └─→ copy_regset_to_user()                    // 遍历 regset 表
              └─→ 在 aarch64_regsets[] 中寻找 .core_note_type == NT_ARM_FPMR
                    └─→ 找到 REGSET_FPMR:
                          .regset_get = fpmr_get     // ← 调用这个函数
```

第三步: `fpmr_get()` 从 tracee 的 `task_struct` 里读出值

```c
// arch/arm64/kernel/ptrace.c
static int fpmr_get(struct task_struct *target, ...)
{
    // target  = 被 GDB 调试的那个 test_fp8 进程
    // current = GDB 自己 (几乎不可能等于 target)

    if (target == current)
        fpsimd_preserve_current_state();  // 只有 tracee 读自己才需要同步硬件

    // ★ 就这一行: 从被调试进程的 task_struct 里读 FPMR
    return membuf_store(&to, target->thread.uw.fpmr);
}
```

核心逻辑: tracee 已经被 GDB 断点停住了, 它的最后一条 `__arm_wsr_fpmr(0x8842)` 已经把 FPMR 写入了硬件, 内核在停住 tracee 时又把它从硬件保存到了 `thread.uw.fpmr`。所以直接读内存就行。

### B.3 完整交互流程 (附时序图)

```
GDB 进程                          被调试的 test_fp8 进程
    │                                  │
    │  ptrace(ATTACH, pid)             │
    │ ───────────────────────────────→ │ 内核: 标记为 TRACED
    │                                  │
    │  waitpid(pid)                    │
    │ ← - - - - - - - - - - - - - - -  │ SIGSTOP (tracee 停下来)
    │                                  │
    │  ptrace(POKEDATA, breakpoint)    │
    │ ───────────────────────────────→ │ 内核: 把断点指令写入
    │                                  │   do_fp8_matmul 地址
    │  ptrace(CONT)                    │
    │ ───────────────────────────────→ │ ─── tracee 恢复执行 ───
    │                                  │   ...
    │                                  │   执行 __arm_wsr_fpmr(0x8842)
    │                                  │   执行到 do_fp8_matmul
    │                                  │   触发断点异常
    │                                  │   内核: 停止 tracee
    │  waitpid(pid)                    │   内核: 保存 FP 状态到
    │ ← - - - - - - - - - - - - - - -  │     thread.uw.fpmr = 0x8842
    │  SIGTRAP (断点命中!)             │
    │                                  │
    │  ☆ tracee 已完全停止 ☆           │
    │  ☆ FPMR 值在 tracee->thread.uw.fpmr 里 ☆
    │                                  │
    │  ptrace(GETREGSET,               │
    │         pid, NT_FPMR)            │
    │ ───────────────────────────────→ │ 内核: fpmr_get(tracee)
    │                                  │   → 读 tracee->thread.uw.fpmr
    │                                  │   → 值是 0x8842
    │ ← 返回 0x8842                    │   → 拷贝给 GDB
    │                                  │
(gdb) p/x $fpmr                        │
$1 = 0x8842                            │
```

### B.4 写操作: `set $fpmr = 0x01` 的过程

如果 GDB 用户修改 FPMR 然后继续执行:

```gdb
(gdb) set $fpmr = 0x01
(gdb) continue
```

内核路径:

```c
ptrace(SETREGSET, pid, NT_FPMR, {0x01})
  └─→ copy_regset_from_user()
        └─→ fpmr_set(test_fp8, new_value=0x01)
              │
              ├── target->thread.uw.fpmr = 0x01;   // ★ 写到 tracee 内存
              │
              └── fpsimd_flush_task_state(target);  // ★ 告诉内核:
                                                    //   "这个 task 的 FP 状态已过时,
                                                    //    下次恢复时必须重新加载"
```

最后一行是关键: `fpsimd_flush_task_state(target)` 的作用。

tracee 在断点前可能已经执行了 `__arm_wsr_fpmr(0x8842)`, CPU 硬件 FPMR 寄存器里还持有那个旧值。如果 GDB 只修改了内存中的 `thread.uw.fpmr = 0x01` 但不清掉 CPU 上的绑定, tracee 恢复执行时硬件上可能还是旧值 0x8842。

`fpsimd_flush_task_state()` 就是用来处理这个场景的:

```c
void fpsimd_flush_task_state(struct task_struct *t)
{
    t->thread.fpsimd_cpu = NR_CPUS;   // 解绑: 这个 task 不再持有任何 CPU 的 FP 状态
    t->thread.fp_type = FP_STATE_FPSIMD;
    clear_thread_flag(TIF_SVE);       // 清除 SVE 标志
    barrier();
}
```

之后 tracee 被调度恢复执行时, `fpsimd_thread_switch()` 检查到 `fpsimd_cpu != smp_processor_id()`, 认为 CPU 上的状态是 "foreign" 的, 从而调用 `task_fpsimd_load()` 从内存重新加载 FPMR (值为 `0x01`)。

### B.5 本质总结

把 ptrace 看作一个 "远程内存读写协议":

```
ptrace 操作             实质
──────────────────────────────────────────────
ATTACH/DETACH           设置/清除 tracee 的 TRACED 标记
PEEKDATA/POKEDATA       读/写 tracee 的用户态内存
GETREGSET               读 tracee->task_struct.某个字段
SETREGSET               写 tracee->task_struct.某个字段
                          + fpsimd_flush_task_state 强制重载
CONT/SINGLESTEP         让 tracee 继续跑 (或走一步)

所有操作的本质: 内核帮你以受控的方式, 操作另一个进程的 task_struct 或地址空间。
FPMR 的 NT_ARM_FPMR regset 就是这张表里的一个新条目, 逻辑和 NT_PRSTATUS、NT_ARM_SVE
完全相同。
```

### B.6 为什么每个新寄存器都要加 ptrace regset

```
调试器的寄存器可见性:

  用户敲 "p $fpmr"
    → GDB 查寄存器表
        → 表里有 NT_ARM_FPMR → GDB 发 ptrace → 内核返回 FPMR 值 ✔
        → 表里没有           → GDB 报错: "No register named '$fpmr'"  ✘
```

不加 `NT_ARM_FPMR` 就意味着: 任何调试器、CRIU、core dump 工具都无法访问 FPMR。对 FP8 程序的调试和运维是一个不可接受的盲区。

**注意**: `NT_ARM_FPMR` 还在 core dump (ELF note) 中使用 —— `core_note_type` 字段同时用于 ptrace 和 ELF core dump, 确保 crash 工具可以从 coredump 文件中读取 FPMR。

---

## 附录 C: 提示词记录

以下是生成本文档所使用的对话提示词，供后续类似任务参考：

我在linux6.6的版本上使能ARM FP8特性，高版本的内核修复了一堆相关问题，看起来主要
集中在arch/arm64/kernel/fpsimd.c，不过也不排除其他文件。整理下，6.6后续所有关于
ARM64 fpsimd的修复。主要要列出修复的patchset，分析下修复了什么问题。给出在6.6上
回合相关patchset后，测试的具体方法。

每个patchset的cover letter patch也列出来吧，另外加上最后合入一版的lore.kernel.org的连接，
你要查下连接是否正确
