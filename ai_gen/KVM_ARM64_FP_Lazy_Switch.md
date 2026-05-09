KVM ARM64 FP/SIMD Lazy Switch机制原理
======================================

-v0.1 2026.05.13 Sherlock init

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
   在一个物理核上调度，各个线程都独立的使用FP/SIMD寄存器。

   具体来说，host线程在上下文切换时被设置TIF_FOREIGN_FPSTATE标志，表示硬件FP的
   状态"未知"(不属于当前线程)。该线程首次用FP时，fpsimd_save()检查到此标志
   直接返回(无可保存数据)，随后fpsimd_restore_current_state()从task->thread.uw
   恢复该线程的FP到硬件，并清除TIF_FOREIGN_FPSTATE(硬件状态变"已知")。
   后续FP操作直接走硬件。换出时通过fpsimd_save()将硬件FP写回task->thread.uw，
   再通过fpsimd_save_and_flush_cpu_state()设置TIF_FOREIGN_FPSTATE。

   所以host线程的惰性切换和guest的惰性切换用同一套fpsimd框架——都是通过last
   指针来知道当前硬件里的FP数据属于谁、需要时该往哪存。

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

6. vCPU迁移到另一个物理核上时，即使之前在旧核上FP已经设为直通，新核上也会再次trap：
   ```
   CPU-A                                    CPU-B
   -----                                    -----
   vCPU first FP -> trap
     -> fp_owner = GUEST
     -> FPEN set, guest direct
         |
         v
   vCPU scheduled out
     -> vcpu_put_fp()
     -> fpsimd_save_and_flush_cpu_state()
     -> guest FP saved to vcpu memory
     -> hardware cleared
         |
         v                              vCPU scheduled in
         |                              -> vcpu_load_fp()
         |                              -> fp_owner = FREE  <-- CPU-B's own
         |                              -> FPEN cleared (trap set)
         |                                  |
         |                              vCPU first FP -> trap!  <-- traps here
         |                              -> restore guest FP to hw from vcpu
         |                              -> fp_owner = GUEST
         |                              -> direct access
   ```
   **注意**：这是惰性切换的另一个好处，不用在vCPU上线(vcpu_load)时无条件恢复寄存
   器(guest在新核上可能根本不用FP/SIMD)，等guest真用了再恢复!!

## 2. 核心数据结构

如上全局数据结构，注意这个结构里也是一堆指针，表示所有当前应该回写信息的地址的集合。
```c
// arch/arm64/kernel/fpsimd.c
static DEFINE_PER_CPU(struct cpu_fp_state *, last);
```

host内核或者线程保存FP/SIMD的数据结构：
```c
// arch/arm64/include/asm/processor.h
struct thread_struct {
    struct {
        ...
        u64         fpmr;                  // FPMR值
        struct user_fpsimd_state fpsimd_state;  // Q0-Q31, FPSR, FPCR
    } uw;
    ...
};
```

vCPU保存FP/SIMD的数据结构：
```c
// arch/arm64/include/asm/kvm_host.h
struct kvm_vcpu_arch {
    struct kvm_cpu_context ctxt;           // 通用sysreg数组(sys_regs[FPMR]在此)
        struct user_fpsimd_state fp_regs;  // Q0-Q31, FPSR, FPCR
    void *sve_state;                       // SVE向量状态(Z+P寄存器)
    enum fp_type fp_type;                  // FPSIMD / SVE / SME
    u64 svcr;                              // SME控制(直接字段, 不走sysreg)
    u16 sve_max_vl;                        // SVE最大向量长度
    ...
};
```

KVM用来控制的数据结构：
```c
// arch/arm64/include/asm/kvm_host.h (per-CPU, 每个物理核一份)
struct kvm_host_data {
    struct kvm_cpu_context host_ctxt;
    struct user_fpsimd_state *fpsimd_state;  // host FP状态, hyp VA
    u64 fpmr;                                // host FPMR暂存

    enum {
        FP_STATE_FREE,          // 硬件空闲, 无人占用
        FP_STATE_HOST_OWNED,    // 硬件中是host的值
        FP_STATE_GUEST_OWNED,   // 硬件中是guest的值
    } fp_owner;                 // FP硬件的所有权状态机
};
```

## 3. 具体实现逻辑

下面展开分析如上基本逻辑的具体实现。

### vCPU初次使用FP/SIMD的逻辑

vCPU首次运行时FPEN被清除，任何FP指令都会trap到EL2。

```
kvm_arch_vcpu_load_fp()
    |
    +-> fpsimd_save_and_flush_cpu_state()
    |     把当前CPU上host任务的FP全部写回内存，清空硬件
    |
    +-> fp_owner = FP_STATE_FREE
    |
    v
__activate_traps()
    |
    +-> guest_owns_fp_regs() == false (fp_owner != GUEST)
    |
    +-> CPACR_EL1 &= ~(FPEN_EL0EN | FPEN_EL1EN)
    |     清除FPEN -> guest的任何FP指令都会trap
    |
    v
Guest首次执行FP指令 -> trap (ESR_EL2.EC = 0x07)
    |
    v
kvm_hyp_handle_fpsimd()
    |
    +-> step 1: 验证trap类型 (FP_ASIMD / SVE)
    |
    +-> step 2: 临时禁用trap陷阱 (允许EL2操作FP寄存器)
    |     isb()
    |
    +-> step 3: [条件] 保存host FP
    |     if (fp_owner == HOST_OWNED) { 
    |         __fpsimd_save_state(host_fpsimd)
    |         *host_data_ptr(fpmr) = read_sysreg_s(SYS_FPMR) <-- KVM是多余的(这里针对pKVM)？
    |     }
    |
    +-> step 4: 恢复guest FP到硬件
    |
    |     __fpsimd_restore_state(&vcpu->arch.ctxt.fp_regs)
    |     write_sysreg_s(__vcpu_sys_reg(vcpu, FPMR), SYS_FPMR) <-- 恢复guest FPMR
    |
    +-> step 5: fp_owner = FP_STATE_GUEST_OWNED
    |
    \-> 返回guest, 重新执行被trap拦截的FP指令
        此时FPEN已在step 2中置位，后续FP操作直接走硬件
```

### Host使用FP/SIMD的逻辑

Host可能在任意时刻使用FP/SIMD(比如内核crypto中的NEON指令)。此时如果guest持有FP
硬件(fp_owner == GUEST_OWNED)，必须先保存guest的值再换上host的寄存器：
```
Host需要FP (kernel_neon_begin / 中断处理 / 上下文切换)
    |
    v
fpsimd_save()
    |
    +-> last = __this_cpu_read(last)
    |     (VM exit时ctxsync_fp已经把last指向guest的fp_state)
    |
    +-> if (test_thread_flag(TIF_FOREIGN_FPSTATE)) return
    |      TIF_FOREIGN_FPSTATE是per-task标志, 描述的是"current与硬件是否一致", 
    |      不是"硬件里有未保存的有效数据"。"硬件里是谁的、该存到哪"由per-CPU的
    |      fpsimd_last_state(即last指针)单独跟踪。
    |
    |      该标志被置上的前提是: 前一个owner在让出硬件时已经先通过last把值存回去, 
    |      再set TIF_FOREIGN_FPSTATE (见fpsimd_thread_switch / vcpu_put_fp / 
    |      kernel_neon_begin / fpsimd_save_and_flush_cpu_state)。
    |
    |      所以这个flag的语义是：**已经存过或硬件数据stale** 此时再写last指向的内存
    |      反而会用错误数据覆盖正确备份, 正确做法就是直接return。参考fpsimd.c:78-119
    |      的整体不变式描述。
    |
    +-> if (last->to_save == FP_STATE_SVE)
    |       sve_save_state(last->sve_state, last->st)
    |   else
    |       fpsimd_save_state(last->st)
    |     把硬件Q0-Q31,FPSR,FPCR写回last->st (指向vcpu或task)
    |
    +-> if (system_supports_fpmr())   <--- host前置代码回合的逻辑
    |       *(last->fpmr) = read_sysreg_s(SYS_FPMR)
    |     把硬件FPMR写回last->fpmr (指向vcpu或task)
    |
    +-> if (system_supports_sme())
    |       *last->svcr = read_sysreg_s(SYS_SVCR)
    |
    \-> fp_owner = FP_STATE_FREE (硬件已清空)
    |
    v
fpsimd_restore_current_state()
    |   ...
    |    
    +-> get_cpu_fpsimd_context()
    |     禁止内核NEON抢占, 保护后续操作
    |
    +-> if (test_and_clear_thread_flag(TIF_FOREIGN_FPSTATE)) {
    |       |
    |       |  TIF_FOREIGN_FPSTATE == 1 -> 硬件FP不属于current, 需要恢复
    |       |  TIF_FOREIGN_FPSTATE == 0 -> 硬件FP已属于current, 跳过(快速路径)
    |       |
    |       +-> task_fpsimd_load()
    |       |
    |       +-> fpsimd_bind_task_to_cpu()
    |       |     重新绑定per-CPU的fpsimd_last_state(last指针)到current:
    |       |       last->st       = &current->thread.uw.fpsimd_state
    |       |       last->sve_state = current->thread.sve_state
    |       |       last->fp_type   = &current->thread.fp_type
    |       |       current->thread.fpsimd_cpu = smp_processor_id()
    |       |     配置EL0 trap: TIF_SVE/SME -> user_enable, 否则disable
    |       |
    |       \-> 此时: last指向current, 硬件FP=current, FOREGIN已清除
    |                用户态FP/SIMD直通硬件
    |   }
    |
    \-> put_cpu_fpsimd_context()

**时序说明**: host抢FP时(kernel_neon_begin)只做save+flush(清空硬件,设FOREIGN), 
不恢复current。因为host抢FP后直接在硬件上操作NEON, 等返回用户态前(ret_to_user)
才检查TIF_FOREIGN_FPSTATE, 按需调用fpsimd_restore_current_state恢复current的FP。
如果host没抢过(current一路持有FP硬件), FOREGIN为0, 什么都不做, 零开销。

```
host用FP和vCPU下线都会调用fpsimd_save()，但触发路径不同。前者是host主动用FP时通过
last指针惰性回写，后者是put_fp()强制调用fpsimd_save_and_flush_cpu_state()。两种
路径最终都通过同一个last指针把硬件值写回正确位置。

### vCPU下线和exit的逻辑

vCPU exit和vCPU下线(put)是两种不同的路径，处理方式也不同：

**vCPU exit**(VM Exit, 但vCPU线程还在当前核上)：
```
kvm_arch_vcpu_ctxsync_fp()
    |
    +-> if (fp_owner == GUEST_OWNED) {
    |
    |       // 构建fp_state, 各指针指向guest的存储位置
    |       fp_state.st        = &vcpu->arch.ctxt.fp_regs
    |       fp_state.sve_state = vcpu->arch.sve_state
    |       fp_state.fpmr      = &__vcpu_sys_reg(vcpu, FPMR)
    |       fp_state.svcr      = &vcpu->arch.svcr
    |       fp_state.fp_type   = &vcpu->arch.fp_type
    |
    |       // 绑定last -> guest, 但不读硬件
    |       fpsimd_bind_state_to_cpu(&fp_state)
    |       clear_thread_flag(TIF_FOREIGN_FPSTATE)  <-- 绑定但没有保存，清标记
    |   }
    |
    \-> 如果guest很快又回来, fp_owner还是GUEST, FP直通零开销
        如果host需要FP, 则通过last惰性回写(见上一节)
```

**vCPU下线** (vCPU线程被调度出当前核)：
```
kvm_arch_vcpu_put_fp()
    |
    +-> if (fp_owner == GUEST_OWNED) {
    |       ...
    |       fpsimd_save_and_flush_cpu_state()
    |         |
    |         +-> fpsimd_save()
    |         |     通过last指针把硬件FP+FPMR写回vcpu内存
    |         |
    |         +-> fpsimd_flush_cpu_state()
    |         |     清空硬件寄存器(防止泄露给下一个host任务)
    |         |
    |         +-> set_thread_flag(TIF_FOREIGN_FPSTATE) <-- 保存寄存器，加标记
    |         |
    |         \-> fp_owner = FP_STATE_FREE
    |   }
    |
    \-> 下一个host任务的FP使用是干净的
```

两者关键区别：exit时只绑定指针不保存(惰性)，put时强制保存(安全兜底)。

### vCPU迁移到新物理核上的逻辑

fp_owner是per-CPU变量，每个物理核各自一份。vCPU从CPU-A迁移到CPU-B时，CPU-B的fp_owner
初始为FREE，FPEN被清除，首次FP必然trap。

```
CPU-A (旧核)                              CPU-B (新核)
------------                              ------------
[1] vCPU持有FP运行
    fp_owner = GUEST
    FPEN置位, guest直通
        |
        v
[2] vCPU被调度出去
    kvm_arch_vcpu_put_fp()
      fpsimd_save_and_flush_cpu_state()
        -> guest FP+FPMR写回vcpu内存
        -> 硬件清空
        -> fp_owner = FREE
        |
        v
[3] vCPU线程迁移                             [同时] vCPU被调度上来
                                         kvm_arch_vcpu_load_fp()
                                           fpsimd_save_and_flush_cpu_state()
                                           -> 保存CPU-B上旧host任务的FP
                                           -> fp_owner = FREE <- CPU-B自己的
                                           -> fp_owner不是GUEST
                                              |
                                              v
                                         __activate_traps()
                                           guest_owns_fp_regs() == false
                                           -> 清除FPEN, 设trap
                                              |
                                              v
                                         [4] guest首次FP -> trap!
                                         kvm_hyp_handle_fpsimd()
                                           step 3: fp_owner != HOST_OWNED
                                                   -> 不保存 (host已flush)
                                           step 4: 从vcpu内存恢复guest FP
                                                   __fpsimd_restore_state()
                                                   write_sysreg(vcpu->FPMR)
                                           step 5: fp_owner = GUEST
                                              |
                                              v
                                         后续guest FP直通硬件
```
这是惰性切换的另一个好处——vcpu_load时不需要无条件恢复FP寄存器(guest在新核上可能
根本不用FP)，等guest真用了再恢复。
