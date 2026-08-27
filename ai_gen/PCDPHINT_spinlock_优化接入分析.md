# PCDPHINT 优化 Linux spinlock：架构 hint 接入公共代码的方法分析

## 1. 背景定位

Armv9.6 的 **FEAT_PCDPHINT**（Producer-Consumer Data Placement Hints）提供两条指令：

- **`STSHH keep/strm`** —— 生产者侧。提示"**紧接着的下一条**写指令写的位置会被别的 PE 观察到，请以最小延迟把新值推给观察者"。编码在 HINT 空间：`keep` = `hint #0x30`（`0xd503261f`），`strm` = `hint #0x31`（`0xd503263f`）。**不实现该特性时架构保证解码为 NOP**。
- **`PRFM IR`** —— 消费者侧。提示"我要读一个还没被写成目标值的位置"，正好对应自旋等待。

当前内核树状态（基于本地 v7.2-rc5 附近代码）：

- 只有字段定义：`arch/arm64/tools/sysreg:2005` 的 `ID_AA64ISAR2_EL1.PCDPHINT`
- **没有任何使用者，也没有 cpucap**——这块是空白，适合从零接入。

### 1.1 在 spinlock 里的落点

| 侧 | 公共代码位置 | 该发什么 |
|---|---|---|
| producer | `queued_spin_unlock()` 的 `smp_store_release(&lock->locked, 0)`（`include/asm-generic/qspinlock.h:128`） | `STSHH` |
| producer | `arch_mcs_spin_unlock_contended()` 的 `smp_store_release(l, 1)`（`kernel/locking/mcs_spinlock.h:37`） | `STSHH` |
| consumer | `smp_cond_load_acquire(&lock->locked, !VAL)`（`kernel/locking/qspinlock.c:197`） | `PRFM IR` |
| consumer | `arch_mcs_spin_lock_contended()`（`kernel/locking/mcs_spinlock.h:27`） | `PRFM IR` |

### 1.2 决定接口设计的硬约束

STSHH 的语义绑定的是"**下一条**指令"。在 C 里写成两条独立语句（`stshh(); smp_store_release(...);`）不可靠——编译器可能在中间插东西。LLVM 为此专门做了 `__builtin_arm_atomic_store_with_stshh` 这个 **hint+store 合一**的内建来保证相邻性。

**结论：内核里的正确形态是一段把 hint 和 store 写在一起的内联汇编，而不是独立的 barrier 式宏。**

---

## 2. 内核里"往公共代码塞架构特定指令"的既有机制

从最轻到最重，有五类，都有现成先例。

### 2.1 `#ifndef arch_xxx` 宏 hook —— MCS 锁自带，ARM32 已经用过

`include/asm-generic/mcs_spinlock.h` 的注释直接写着"Architectures can define their own"，`kernel/locking/mcs_spinlock.h:20,33` 用 `#ifndef` 兜底。

**ARM32 就是这么把 ARM 特定指令塞进公共 MCS 代码的**，见 `arch/arm/include/asm/mcs_spinlock.h`：

```c
#define arch_mcs_spin_lock_contended(lock)	\
do {						\
	smp_mb();				\
	while (!(smp_load_acquire(lock)))	\
		wfe();				\
} while (0)

#define arch_mcs_spin_unlock_contended(lock)	\
do {						\
	smp_store_release(lock, 1);		\
	dsb_sev();				\
} while (0)
```

跟 PCDPHINT 的诉求形态几乎一模一样：unlock 侧发一条架构特定的"通知等待者"指令。arm64 目前没写这个文件，`arch/arm64/include/asm/Kbuild:13` 里是 `generic-y += mcs_spinlock.h`。

### 2.2 公共原语的 arch override —— arm64 把 WFE 塞进 qspinlock 用的就是这招

`include/asm-generic/barrier.h:245,267` 的 `smp_cond_load_relaxed/acquire` 是 `#ifndef` 包着的，arm64 在 `arch/arm64/include/asm/barrier.h:196,209` 整个重写为 `LDXR + WFE`（`__cmpwait_relaxed`）。

**公共代码一行没改**，`kernel/locking/qspinlock.c:197` 的 `smp_cond_load_acquire(&lock->locked, !VAL)` 就自动变成了事件等待。`kernel/locking/mcs_spinlock.h:21-25` 的注释甚至专门点名了这件事："some architectures such as ARM64 would like to do spin-waiting instead of purely spinning"。

**消费者侧的 `PRFM IR` 走这条路是零公共代码改动**——在 arm64 自己的 `smp_cond_load_*` 里、进 `__cmpwait_relaxed` 之前发一条即可。

### 2.3 `prefetchw()` —— 最贴近 PCDPHINT 的先例，公共 locking 代码里已经有一条纯性能 hint

`kernel/locking/qspinlock.c:301` 有 `prefetchw(next)`。兜底在 `include/linux/prefetch.h:42`（`__builtin_prefetch(x,1)`），arm64 在 `arch/arm64/include/asm/processor.h:401-405` 实现成 `prfm pstl1keep`。

这是说服 maintainer 的最强论据：**公共锁代码接受"无语义、纯性能"的架构 hint 已经是既成惯例**，PCDPHINT 属于同一类东西。

### 2.4 `spin_begin()/spin_cpu_relax()/spin_end()` —— 为一个架构的性能 hint 专门在公共头文件加空宏，并且合进去了

`include/linux/processor.h` 一整套 `#ifndef`，默认全空。唯一使用者是 powerpc（`arch/powerpc/include/asm/processor.h:364-378`），把它实现成 SMT 线程优先级调整（HMT_low/HMT_medium）。

如果最后确实需要**新增**公共 hook，这是最好的先例：动机同样是"某架构在自旋循环里想发一条别人不需要的 hint 指令"。

### 2.5 ALTERNATIVE / cpucaps 运行时打补丁 —— LSE atomics 那一套

`arch/arm64/include/asm/lse.h` 的 `ARM64_LSE_ATOMIC_INSN(llsc, lse)` 和 `__lse_ll_sc_body()`，基于 `alternative_has_cap_likely(ARM64_HAS_LSE_ATOMICS)`。

**但 PCDPHINT 大概率用不上这个**——STSHH 和 PRFM IR 在不实现该特性的 CPU 上是架构保证的 NOP，可以无条件发射，省掉 cpucap + alternative 的全部复杂度。只有满足以下条件之一时才需要上 `ALTERNATIVE("nop", "hint #0x30", ARM64_HAS_PCDPHINT)`：

- 担心老核上多一条 NOP 的取指开销；
- 实测某些实现上 hint 反而有害。

到那时 cpucaps 加一行，cpufeature.c 里照抄 `ARM64_HAS_MOPS`（`arch/arm64/kernel/cpufeature.c:3032`）或 `ARM64_HAS_WFXT`（:3009）的 entry 即可，sysreg 字段已经现成。

### 2.6 汇编器兼容 —— 用 `hint #N`，别用助记符

binutils 支持 `stshh` 助记符是 2025 年的事，内核的最低 binutils 要求肯定不够。内核惯例是直接写 HINT 编号，见 `arch/arm64/include/asm/barrier.h:33-35`：

```c
#define psb_csync()	asm volatile("hint #17" : : : "memory")
#define __tsb_csync()	asm volatile("hint #18" : : : "memory")
#define csdb()		asm volatile("hint #20" : : : "memory")
```

所以 `stshh keep` → `hint #0x30`，`stshh strm` → `hint #0x31`；或者用 `.inst 0xd503261f`（`SB_BARRIER_INSN` 就是这个套路）。`PRFM IR` 不在 HINT 空间，需要用 `.inst` 或确认 prefetch operand 编码。

---

## 3. 具体接入路线

**好消息：qspinlock 的三个落点，公共代码一行都不用改。**

| 落点 | 现成 hook | 动作 |
|---|---|---|
| `queued_spin_unlock` | `include/asm-generic/qspinlock.h:118` 的 `#ifndef queued_spin_unlock` | 新建 `arch/arm64/include/asm/qspinlock.h`，`#define queued_spin_unlock queued_spin_unlock` 自己实现（x86 pv 就是这么干的，见 `arch/x86/include/asm/paravirt-spinlock.h:52`），并从 Kbuild `generic-y` 去掉 |
| MCS 交接 | `arch_mcs_spin_unlock_contended` | 新建 `arch/arm64/include/asm/mcs_spinlock.h`（照抄 ARM32 那个文件的形态），并从 Kbuild `generic-y` 去掉 |
| 自旋等待 | arm64 已私有化的 `smp_cond_load_*` | 直接在 `arch/arm64/include/asm/barrier.h:196,209` 里加 `PRFM IR` |

### 3.1 建议先做 MCS 交接

`node->locked` 的传递是 qspinlock 慢路径里最典型的一对一 producer→consumer 单点唤醒，cache line 明确要从 unlock 者搬到队列下一个人手上，是 PCDPHINT 收益最干净、最容易做出 benchmark 数字的地方。

因为相邻性约束，unlock 侧要写成一段 asm，大意是：

```c
/* arch/arm64/include/asm/mcs_spinlock.h */
#define arch_mcs_spin_unlock_contended(l)			\
do {								\
	asm volatile(						\
		"hint	#0x30\n"	/* stshh keep */	\
		"stlr	%w1, %0"				\
		: "=Q" (*(l)) : "r" (1) : "memory");		\
} while (0)
```

（`stlr` 直接替掉 `smp_store_release`，保证 hint 和 store 之间编译器插不进东西。实际提交时还要处理 KASAN 检查、`__unqual_scalar_typeof` 等，参考 `arch/arm64/include/asm/barrier.h` 里 `__smp_store_release` 的写法。）

### 3.2 如果后来确实要加通用 hook

接口形态别做成独立的 `store_shared_hint(p)`——因为相邻性约束，那个在 C 层不可靠。应该做成 **hint+store 合一**，比如：

```c
smp_store_release_shared(p, v)
```

默认 `#define smp_store_release_shared(p,v) smp_store_release(p,v)`。这个设计理由要在 patch changelog 里写清楚，否则 review 时一定会被问"为什么不做成一个简单的 hint 宏"。

---

## 4. 参考链接

- [STSHH — Store shared hint（Arm A-profile A64 ISA）](https://developer.arm.com/documentation/ddi0602/2025-06/Base-Instructions/STSHH--Store-shared-hint-)
- [[PATCH v3] aarch64: Support for FEAT_PCDPHINT（binutils）](https://sourceware.org/pipermail/binutils/2025-May/140935.html)
- [[AArch64][clang][llvm] Add ACLE stshh atomic store builtin](https://github.com/llvm/llvm-project/commit/6d003f5033b324aa0319cd3ee8912bde80a915d6)
- [[AArch64][llvm] Fix encoding for stshh instruction](https://github.com/llvm/llvm-project/commit/cd7f7379a016b4456a44c9e4f8e4dfd2ce0bb00a)
