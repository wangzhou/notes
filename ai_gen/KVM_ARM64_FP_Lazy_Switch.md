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

6. vCPU迁移到另一个物理核上时，即使之前在旧核上FP已经设为直通，新核上也会再次trap：
   ```
   CPU-A                                    CPU-B
   ─────                                    ─────
   vCPU首次FP → trap
     → fp_owner = GUEST
     → FPEN置位, guest直通
         │
         ▼
   vCPU被调度出去
     → vcpu_put_fp()
     → fpsimd_save_and_flush_cpu_state()
     → guest FP写回vcpu内存
     → 硬件清空
         │
         ▼                              vCPU被调度上来
         │                              → vcpu_load_fp()
         │                              → fp_owner = FREE  ← CPU-B自己的fp_owner
         │                              → FPEN清除(设陷阱)
         │                                  │
         │                              vCPU首次FP → trap!  ← 这里会trap
         │                              → 从vcpu内存恢复guest FP到硬件
         │                              → fp_owner = GUEST
         │                              → 后续直通
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
struct kvm_vcpu_arch
  (todo)
```

KVM用来控制的数据结构：
```c
struct kvm_host_data
  (todo)
```

## 3. 具体实现逻辑

下面展开分析如上基本逻辑的具体实现。

### vCPU初次使用FP/SIMD的逻辑

(todo)

### Host使用FP/SIMD的逻辑

(todo)

### vCPU下线和exit的逻辑

(todo)

### vCPU迁移到新物理核上的逻辑

(todo)

