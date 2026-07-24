# ARM64 FEAT_PCDPHINT 优化 qspinlock / PV spinlock 分析

-v0.1 2026.7.24 基于 Armv9.6-A 特性分析与 OLK-6.6 树现状

简介：Armv9.6-A 新增可选扩展 FEAT_PCDPHINT（Producer-Consumer Data Placement Hints），
      提供 STSHH 与 PRFM IR 两条 hint，为锁的"生产者 store → 消费者轮询"模式提供硬件级
      定向转发能力。本文分析其语义及在 host qspinlock 与 PV spinlock 中的优化切入点。

---

## 1. 指令语义（已核实）

FEAT_PCDPHINT 是 Armv9.6-A 的**可选**扩展（非必选，需 `+pcdphint` 显式启用），含两条 hint：

### 1.1 STSHH（Store Shared Hint）

放在一条 store **之前**，声明：这条 store 写的值会被**其他 PE 观察**（观察者可能在轮询
该位置，或已执行 PRFM IR），请以**最小延迟**推送给他们。

- 操作数 `<policy>` 两位：`keep`（保留本地副本，适合"本地稍后还要读"）和 `strm`
  （流式，不保留，数据转给消费者）
- 编码：`stshh keep` = `0x1f,0x26,0x03,0xd5`；`stshh strm` = `0x3f,0x26,0x03,0xd5`
- **不支持该特性的硬件上解码为 NOP** —— 功能上永远安全

### 1.2 PRFM IR（新 prefetch 操作数）

消费侧 hint：**我将要读一个可能还没被生产者写出来的值**。提前向 coherency 系统声明
等待意图，producer store 落地时定向转发，缩短"事件到达 → 第一次 load 命中"的延迟。

### 1.3 成对使用模型

```
生产者:  STSHH strm        ← 我这条 store 是给你吃的
         str <addr>
消费者:  PRFM <addr>, IR   ← 我在等这个地址上的生产
         (轮询 / WFE 等待 / 睡眠后醒来) ldr <addr>
```

一方声明"我在生产给你"，一方声明"我在等你的生产"，coherency fabric 据此做点对点转发，
替代传统的"广播失效 + 消费者重新 fetch"往返。

### 1.4 工具链状态（2025-2026）

- LLVM/Clang：汇编支持 2024.10 合入（PR #112341）；ACLE 内置 `stshh` atomic store
  曾加过又移除（#192419）
- Binutils/GAS：FEAT_PCDPHINT 支持 patch 2025.4 投递（Ezra Sitorus, Arm）
- GCC 16（2025.12）：Armv9.6-A 目标支持，接受 `armv9.6-a+pcdphint`

## 2. 对 host（原生）qspinlock 的优化切入点

对照 qspinlock 模型（锁字 tail/pending/locked + MCS 队列），四个插入点：

### 2.1 放锁 store（收益最高之一）

本树 `arch/arm64/include/asm/qspinlock.h:22`：

```c
static inline void native_queued_spin_unlock(struct qspinlock *lock)
{
	smp_store_release(&lock->locked, 0);   // ← 前面加 STSHH strm
}
```

最典型的 producer store：pending 者正在 locked 上 spin、MCS 队头在 WFE 循环轮询——
他们都是消费者。`strm` 策略正合适：放锁者不再碰这条线，把它"流"给等待者。
收益：coherency 系统把更新直接定向转发给轮询者，省掉失效广播 + 重新 fetch 的往返
（即 ticket spinlock 时代"cache 风暴"问题的硬件解法）。

### 2.2 MCS 令牌传递（收益最大的点）

`kernel/locking/qspinlock.c` 的 `mcs_lock_handoff → arch_mcs_lock_handoff →
WRITE_ONCE(next->locked, 1)`：同样 producer store 模式，且是**链式**的——队列中每个
节点依次把令牌传给下一个。N 个等待者省 N 次 coherency 往返，锁传递总延迟直接下降。

### 2.3 等待者侧 PRFM IR（两处）

- pending 者的 `smp_cond_load_acquire(&lock->locked, !VAL)` 前
- MCS 节点在自己 `node->locked` 的等待循环（arm64 `__cmpwait` WFE 循环）前

语义精确匹配"我将要读一个可能还没被写出来的值"。对 WFE 等待尤其有价值：**WFE 醒来后
的第一次 load 是唤醒关键路径**，IR 让数据在事件到达前就已就位/在途。

### 2.4 队尾发布 xchg_tail（收益弱，可选）

读 tail 的不是轮询者，转发收益有限。

## 3. 对 PV spinlock 的优化切入点

### 3.1 unlock slowpath 的 release store + kick 组合

`__pv_queued_spin_unlock_slowpath`（qspinlock_paravirt.h:502）：

```c
smp_store_release(&lock->locked, 0);   // ← 加 STSHH strm
pv_kick(node->cpu);                    // 控制路径：hypercall 唤醒
```

被踢的 vCPU 醒来第一件事就是读这个锁字。`STSHH` 让**数据路径**不必等**控制路径**
（hypercall 往返 + host 调度延迟）：值已定向转发/就位，vCPU 一被调度回来第一次 load
立即命中。缩短 "kick → wakeup → acquire" 整条链。

### 3.2 pv_wait 前发 PRFM IR

队头 `pv_wait(&lock->locked, _Q_SLOW_VAL)` 睡之前发 PRFM IR：vCPU 睡眠期间 coherency
系统"记住"这个等待者，unlock store 落地即定向转发——睡眠者醒来拿数据零延迟。
自旋阈值循环（pv_wait_node/pv_wait_head_or_lock 的 cpu_relax 段）同样可发 IR 声明等待意图。

### 3.3 与 WFET/WFIT 的组合（本树已有基础设施）

- `arch/arm64/include/asm/barrier.h` 已有 `wfet(val)`/`wfit(val)` 宏（msr s0_3_c1_c0_0/1）
- `arch/arm64/lib/delay.c` 已在用（WFIT 起手 + WFET 补足）
- KVM 侧已处理 WFIT 陷出：`arch/arm64/kvm/handle_exit.c` 有 `IN_WFIT` vcpu flag
  （handle_exit.c:111-146），WFIT 可配置为陷出并配背景定时器

应用方向：
- host qspinlock：WFET = 带超时的 WFE，等待循环从"纯 spin + 无超时 WFE"变
  "有界等待 + 定时重估"，空转时间可控
- PV spinlock：guest 阈值循环换 WFET（有界等待），超时才进 pv_wait（WFI/HLT）；
  host 通过 WFET/WFIT 陷出可**观察到 guest 在等锁**，给调度器更精确的信号——
  比现在"blind kick"多一个观测通道

## 4. 集成策略与注意点

### 4.1 特性探测 + ALTERNATIVE

FEAT_PCDPHINT 可选 → cpucap `ARM64_HAS_PCDPHINT` + `alternative_if`，把 NOP 换成
STSHH/PRFM IR，不支持平台零开销。建议封装成通用原语，qspinlock.c 公共代码不感知架构：

```c
smp_store_release_hint(&lock->locked, 0);      // alternative: stlrb / STSHH strm + stlrb
smp_cond_load_acquire_hint(&lock->locked, !VAL);  // alternative: PRFM IR + 原等待循环
```

### 4.2 policy 选择要实测

- 锁字释放用 `strm` 理论上正确（本地不再用），但若 unlock 后同一 PE 紧接着访问同
  cacheline（数据结构热区），`keep` 可能更好——需 per-benchmark 调
- `keep` 更适合"本地稍后还要读"的模式（如 task 交接类）

### 4.3 语义安全

hint 不参与内存序，release/acquire 语义由原指令保证，加 hint 不改变任何正确性；
不支持硬件上解码为 NOP，无兼容性风险。

### 4.4 验证指标

- 锁传递延迟（ping-pong benchmark、contended lock hold/handoff 时间）
- coherency 总线事务数（PMU 事件，验证"定向转发"确实减少了失效广播）
- overcommit 下 PV spinlock 的 wakeup→acquire 时间（kick 后第一次 load 的延迟）

## 5. 生态支持现状（GCC / Clang / C 库 / 用户态锁）

结论：2026.7 时点，**只有 GCC 刚合入内建**；C 库、用户态锁、内核 hwcap 通告均无支持。

### 5.1 GCC：内建已合入，接口仍在演化

- 2026-01-06 合入主线（r16-6521，Richard Ball，Arm）：
  `__atomic_store_with_stshh(addr, value, memory_order, ret)`，声明于 `arm_acle.h`，
  ret 参数 0=keep / 1=strm；store 本体按序生成 `str`（relaxed）或 `stlr/stlur`
  （release/seq_cst）；定义特性宏 `__ARM_FEATURE_PCDPHINT`
- 2026-02 修复 C++ 支持（_Generic 宏 → overloaded builtin）
- 配套 `__pldir` 内建（PRFM IR 侧）
- 2026-06 起被 FEAT_CMH 系列泛化：`__arm_atomic_store_with_hint(addr, value, order, hint)`
  统一 hint 家族（SHUH/STCPH），新增 `__arm_atomic_fetch_*_with_hint`

关键点：
1. 普通 C11 `__atomic_store`/`std::atomic` **不会**自动获得 STSHH——内建是显式接口，
   用户态锁必须改代码才能受益
2. 必须做成内建的原因：STSHH 语义是"紧跟在后面的下一条 store 才被 hint"，
   需要编译器保证 hint+store 成对原子发出，普通 hint asm 无法保证

### 5.2 Clang/LLVM：加了又删，无可用内建

- 汇编器/反汇编支持：2024.10 合入（PR #112341）
- ACLE 内建 `__arm_atomic_store_with_stshh` 加过（PR #181386），因内存序约束实现错误
  **被移除**（PR #192419 / commit 456bf22："removing for now so users don't pick this up"）
- 2026 年移除汇编层 `+pcdphint` gating（PR #181633）——指令可汇编，语言内建缺失

### 5.3 glibc / C 库：零支持

libc-alpha 无任何 STSHH/PCDPHINT patch。glibc aarch64 锁优化目前止步于 LSE2 CAS
（pthread spinlock/condvar）与 CMPBR。pthread_mutex_lock、pthread_spin_lock、
futex 路径均未使用 PCDP hint。

### 5.4 用户态锁：零支持，缺两环依赖

pthread spinlock、pthread mutex（futex）、userspace RCU、folly 等锁库均未使用。
生态链缺：
- 编译器稳定内建：GCC 刚合入且接口在 hint 家族化重构中；Clang 已移除
- **内核 HWCAP 通告**：无 `HWCAP2_PCDPHINT`/`ARM64_HAS_PCDPHINT` 内核 patch
  （本树 grep 确认无 PCDP 字样）。虽然 NOP 兼容（用了不坏），但 glibc 类库
  需要 hwcap 位做 ifunc/alternative dispatch 双路径，否则无特性平台无收益

### 5.5 用户态锁的潜在映射（生态就绪后）

- pthread spinlock：unlock 的 store 前加 STSHH strm（与内核 qspinlock unlock 同构）
- futex 路径：`pthread_mutex_unlock` 里 `atomic_store_release(futex_word, 0)` 前加
  STSHH——等待者在 futex wait，wake 后第一次 load 是关键路径（与 PV spinlock kick
  场景同构）；`futex_wake` 调用前的 store 尤其典型
- PRFM IR：spinlock CAS 失败重试循环前（"我要读一个可能还没被写的值"）

## 6. 小结

PCDP hint 把"点对点传递"从软件（MCS 队列、kick hypercall）延伸到硬件（coherency
定向转发）：宿主 qspinlock 的令牌链和 PV spinlock 的 kick 链都受益。PV 场景收益可能
更大——wakeup→acquire 延迟里"数据在途"占的比重更高。与 WFET/WFIT（本树已有基础）
组合，可同时优化"等待侧"（有界等待 + 观测通道）与"唤醒侧"（定向转发 + 提前就位）。

## 7. 参考资料

- [Arm A-profile A64 ISA: STSHH (Store Shared Hint)](https://developer.arm.com/documentation/ddi0602/2025-06/Base-Instructions/STSHH--Store-shared-hint-)
- [STSHH — A64 (Stanford ARM64 reference)](https://www.scs.stanford.edu/~zyedidia/arm64/stshh.html)
- [binutils: aarch64 Support for FEAT_PCDPHINT](https://sourceware.org/pipermail/binutils/2025-April/140442.html)
- [LLVM: Armv9.6-A memory systems extensions assembler support (PR #112341)](https://github.com/llvm/llvm-project/pull/112341)
- [LLVM: Add ACLE stshh atomic store builtin (#181386)](https://github.com/llvm/llvm-project/commit/6d003f5033b324aa0319cd3ee8912bde80a915d6)
- [GCC 16 Lands Armv9.6-A Target Support (Phoronix)](https://www.phoronix.com/news/GCC-16-Armv9.6-A)
