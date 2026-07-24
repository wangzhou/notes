# PV Spinlock 与 vCPU 抢占检测机制分析

-v0.1 2026.7.24 基于 openEuler OLK-6.6 树（commit 521fd085be9d）的讨论总结

简介：本文总结 PV spinlock（paravirt qspinlock）与 vCPU 抢占检测（pv preempt）机制的全貌。
      覆盖两条战线：① preempted 被动检测（arm64 pvsched，已合入 OLK-6.6）；② WFI+kick 主动
      唤醒（PV qspinlock，v1 系列后 4 个 patch，被砍未合入）。同时深入分析 x86 的 PV spinlock
      实现（arm64 版的原型）、host 写 guest 共享页的地址翻译机制、以及 spinlock 完整调用链。

---

## 1. 总体框架：两条互补战线

PV spinlock/pv preempt 实际是两个独立特性共用一条 SMCCC PV-sched 框架：

| | preempted 被动检测（战线①） | kick 主动唤醒（战线②） |
|---|---|---|
| 作用对象 | 睡眠锁（mutex/rwsem 乐观自旋 osq）、sched | spinlock 本体（qspinlock 慢路径） |
| 机制 | host 在 vCPU put/load 时写共享页 preempted 标志，guest 等待者读到后放弃自旋 | 等待者自旋超阈值 WFI 睡眠；持锁者 unlock 时发 hypercall 踢醒 |
| 内核改动 | 接口接线（static_call / vcpu_is_preempted） | qspinlock 慢路径插 PV 钩子（wait/kick） |
| 语义 | 放弃型：放弃等待让出 CPU | 停车型：睡了还在队里，kick 保证唤醒 |

## 2. openEuler OLK-6.6 的 patch 系列：v1 0/9 → v2 0/5

### 2.1 原始 v1 系列（0/9，2024-02-22 投递，未合入）

| # | Patch | 状态 |
|---|---|---|
| 1 | KVM: arm64: Document PV-sched interface | ✅ v2 保留 |
| 2 | KVM: arm64: Implement PV_SCHED_FEATURES call | ✅ |
| 3 | KVM: arm64: Support pvsched preempted via shared structure | ✅ |
| 4 | KVM: arm64: Add interface to support vCPU preempted check | ✅ |
| 5 | KVM: arm64: Support the vCPU preemption check | ✅ |
| 6 | KVM: arm64: Add SMCCC PV-sched to kick cpu（0xC5000093） | ❌ 未合入 OLK-6.6 |
| 7 | KVM: arm64: Implement PV_SCHED_KICK_CPU call | ❌ |
| 8 | KVM: arm64: Add interface to support PV qspinlock | ❌ |
| 9 | KVM: arm64: Enable PV qspinlock | ❌ |

- v1 CI 转换 PR 时 patch 0003 打不上当前基线（2024-02-26 邮件回复），作者 02-28 重投缩减版 0/5
- v2 经 PR !4785 合入，merge commit `12698b5baea7`
- 后 4 个 patch 只存在于老分支（openEuler-1.0-LTS/22.03/OLK-5.10）：
  `7a645f6e24ee` kick 定义、`efed88dd5934` KVM 侧 kick 实现、`12e1ed766c34` qspinlock 接口、`72fa593a0e5f` Enable
- 衍生跟进：`!15241`（pvsched bugfix + module param）、`!21990`（pv_preempted 动态开关，随后被 `!22189` revert）
- Gitee issue IBTO64 追踪 kick/qspinlock 部分回移植到 OLK-6.6

### 2.2 已合入的 5 个 patch 文件级映射

| commit | 文件 |
|---|---|
| `3566c5bf78e8` Document | Documentation/virt/kvm/arm/pvsched.rst |
| `b4787311f202` FEATURES call | Kconfig、defconfig、kvm_host.h、pvsched-abi.h、kvm/Makefile、hypercalls.c、pvsched.c、arm-smccc.h |
| `c0d910ffc72e` shared structure | kvm_host.h、kvm/arm.c、hypercalls.c、pvsched.c |
| `dd18a07f5c90` preempted check interface | paravirt.h、spinlock.h、kernel/Makefile、paravirt-spinlocks.c（**纯 guest 侧接线**） |
| `858bccb74369` preemption check | kvm_host.h、paravirt.h、pvsched-abi.h、paravirt-spinlocks.c、paravirt.c、kvm/arm.c、hypercalls.c、arm-smccc.h、cpuhotplug.h |

## 3. preempted 被动检测详解（arm64 pvsched，本树实现）

本质是 x86 `KVM_FEATURE_STEAL_TIME` 里 preempted 字段的 arm64 版：guest 每 CPU 留一块共享内存，
host 在 vCPU load/put 时写"是否被抢占"标志，guest 锁慢路径读取决定是否提前放弃。

### 3.1 ABI

```c
/* arch/arm64/include/asm/pvsched-abi.h */
struct pvsched_vcpu_state {
	__le32 preempted;
	u8 padding[60];        /* 64 字节对齐（cache line） */
} __packed;
```

### 3.2 guest 侧（arch/arm64/kernel/paravirt.c）

- `DEFINE_PER_CPU(struct pvsched_vcpu_state, pvsched_vcpu_region)`（:183）——每 CPU 静态分配
- `pv_sched_init()`（:265，early_initcall）：
  1. `has_kvm_pvsched()`：SMCCC 1.1 ARCH_FEATURES 探测 host 支持
  2. cpuhp 注册 `init_pvsched_vcpu_state`（:218）：CPU online 时发 `PV_SCHED_IPA_INIT`
     hypercall 把 `virt_to_phys(reg)` 传给 host；dying 时发 `PV_SCHED_IPA_RELEASE`
  3. `static_call_update(pv_vcpu_preempted, kvm_vcpu_is_preempted)`（:281）
- `kvm_vcpu_is_preempted(cpu)`（:186）：`READ_ONCE` 读 per-CPU 共享结构 preempted 字段
- 接口层（patch 4）：`__native_vcpu_is_preempted` 恒 false 兜底 + `DEFINE_STATIC_CALL`
  + spinlock.h 里 `vcpu_is_preempted` 转发（`CONFIG_PARAVIRT && CONFIG_PARAVIRT_SCHED` 时才转发）

### 3.3 host 侧（arch/arm64/kvm/）

- hypercall 分发（hypercalls.c:378-390）：`IPA_INIT` 存 GPA 进 `vcpu->arch.pvsched.base`，
  `IPA_RELEASE` 置回 `INVALID_GPA`
- `kvm_arch_vcpu_load`（arm.c:791）写 preempted=0，`kvm_arch_vcpu_put`（arm.c:817）写 preempted=1
- `kvm_update_pvsched_preempted()`（pvsched.c:15）：`pagefault_disable()` + `srcu_read_lock(&kvm->srcu)`
  + `kvm_put_guest(kvm, base+offset, cpu_to_le32(preempted))`——原子上下文（调度路径）不能睡，
  不能用会拿 mutex 的 `kvm_write_guest`

### 3.4 消费者

`vcpu_is_preempted()`（spinlock.h:24 → static_call）被以下上游已存在的代码消费：
- `kernel/locking/osq_lock.c:150`：MCS 乐观自旋队列——**检查 prev（直接依赖）而非锁主**。
  令牌只能由 prev 传递；prev 被抢占 → 整条链停摆 → 及时止损退出队列去睡。
  注意注释 "vcpu_is_preempted() relies on polling"：prev 被抢占没有任何事件/中断通知
  本 vCPU（对比 need_resched 有 IPI），只能靠轮询重估条件表达式
- `kernel/locking/mutex.c:372`：mutex 乐观自旋
- `kernel/sched/syscalls.c:204` 等

### 3.5 关键机制：host 软件访问 guest 内存（IPA → HVA）

**host 软件访问 guest 内存永远不走 S2 页表**——S2 只对 vCPU 硬件访问生效。路径：

```
GPA ──(memslot 算术查找)──> HVA ──(host 内核页表 put_user)──> 物理页
```

本树 `kvm_put_guest` 是宏（kvm_host.h:1325）：`gfn_to_hva`（gfn_to_memslot 纯算术查表
+ `userspace_addr + offset*PAGE_SIZE`）→ `put_user` → `mark_page_dirty`。

**"怎么保证 IPA 有映射"三层答案**：
1. memslot 层：guest 传的是自己 per-CPU 静态变量 `virt_to_phys`，必然落在 memslot；
   KVM 在 IPA_INIT 时不校验，校验推迟到每次写入（非法 GPA → error HVA → 写跳过 → -EFAULT 被忽略）
2. host 页表层：guest RAM 常驻（QEMU mmap + 被访问过）；`put_user` 有异常表兜底
3. S2 层：host 写不依赖 S2；guest 读才需要 S2 映射，该页因 guest 频繁访问早已映射
   （或首次访问时 stage-2 fault 按需建立）——不存在"host 写进去 guest 读不到"的窗口

**pagefault_disable 的逻辑**：per-task 计数器（`current->pagefault_disabled++`，
include/linux/uaccess.h:234），不防异常、不关抢占，只改变 fault handler 行为——
`do_page_fault` 入口（fault.c:654）`faulthandler_disabled()` 成立直接 `goto no_context`
→ `__do_kernel_fault` → `fixup_exception` 查异常表 → `ex_handler_uaccess_err_zero`
改 regs->pc 到 fixup 标签、x0=-EFAULT → put_user 返回 -EFAULT。不查 VMA、不拿 mmap_lock、
不调 handle_mm_fault（那是能睡眠的补页路径，原子上下文非法）。

**fixup 机制**：异常表 = 链接期生成的"哪些指令允许缺页、缺页后从哪继续"的表
（`_ASM_EXTABLE_UACCESS(1b, %l2)`）。查表只认 faulting 指令的 PC，不认缺页地址。
命中（uaccess 原语）→ 干净返回 -EFAULT；不命中（普通内核解引用）→ die_kernel_fault oops。
异常表还被两处复用：PAN 检查（fault.c:690 附近，内核在 uaccess 例程外访问用户内存→die）、
`get_mmap_lock_carefully`（mm/memory.c:6179，mmap_lock 竞争时内核态缺页是否允许睡眠等锁）。

**kvm_put_guest 不补页**：没有 GUP、没有 fault-in。缺页 → -EFAULT → 调用方忽略。
对比可睡眠路径 `kvm_write_guest → kvm_vcpu_map → hva_to_pfn_slow → get_user_pages_unlocked`
可以补页。补页的真实来源是 guest 自己访问时的 stage-2 fault 路径。

## 4. kick 机制（被砍的 PV qspinlock，v1 系列 6-9）

### 4.1 正确时序（注意方向：持锁者→等待者，unlock 时刻）

```
vcpu1 抢锁失败 → 慢路径排队
  ① 先忙等 SPIN_THRESHOLD(1<<15) 圈（短临界区直接等到）
  ② 超阈值 → kvm_wait(): 关中断→复查 *ptr→dsb(sy)+wfi → 睡眠，pCPU 让出
vcpu0 释放锁 → __pv_queued_spin_unlock
  ③ 查锁的 waiters 哈希表 → 发现睡着的 vcpu1
  ④ 发 hypercall PV_SCHED_KICK_CPU(vcpu1)
host 收到 (kvm_pvsched_kick_vcpu):
  ⑤ pv_unhalted=true（让目标 runnable，能从 WFI block 醒来）
  ⑥ kvm_vcpu_kick（已在别的 pCPU 跑则发 IPI）
  ⑦ kvm_vcpu_yield_to（把当前 vCPU 时间片让给目标——boost）
vcpu1 从 WFI 醒来，重新排队拿锁
```

**等待者睡觉本身就是对持锁链的助攻**——overcommit 下 pCPU 有限，不空转，持锁者多跑。
（不是"等待者踢持锁者"，那是 boost 语义，这里没有。）

### 4.2 其余逻辑

- 阈值 SPIN_THRESHOLD=1<<15：sleep/wake 一趟 hypercall+调度往返比短锁临界区还贵
- waiters 哈希表（lock_hash，来自通用 qspinlock_paravirt.h）：睡前登记、解锁者查表踢人；
  无等待者时 unlock 走 native 路径零开销（pv_is_native_spin_unlock 静态跳转）
- kvm_wait 唤醒竞态：local_irq_save → 复查 → dsb+wfi；NMI 里直接返回
- pv_unhalted 防丢唤醒：handle_exit.c 里 WFI 进 block 时清标志；runnable 判断（arm.c）
  加 pv_unhalted 条件——kick 先于 HLT/WFI 到达时不丢
- 默认关闭：arm_pvspin=false，需 cmdline `arm_pvspin`；单 vCPU 禁用
- 收益数据（patch 9 提交信息）：Kunpeng920 32 pCPU，60 vCPU 编内核 950s→437s

## 5. x86 PV spinlock 完整分析（arm64 版的原型）

### 5.1 三层架构

```
① 通用 PV 慢路径  kernel/locking/qspinlock_paravirt.h   ← hypervisor 无关
     只依赖 pv_wait(ptr,val)/pv_kick(cpu) 两个抽象
② guest 后端  pv_ops.lock.{wait,kick}
     KVM: kvm_wait(HLT) + kvm_kick_cpu(KVM_HC_KICK_CPU)
     Xen: SCHEDOP_block + event channel
③ host 侧  HLT 拦截→kvm_vcpu_block；KICK→APIC_DM_REMRD 伪中断注入
```

### 5.2 基本模型（在 native qspinlock 模型上的唯一变换）

**把"spin 等待"换成"先 spin 一会儿，然后睡觉，解锁的人踢醒我"**。排队模型
（锁字 tail/pending/locked、MCS 链表）完全不变。新东西只有：
- `_Q_SLOW_VAL=3`：锁字 locked 字节。bit0 仍为 1（锁被持有），3 额外表示"队头睡在哈希表里"
- node 三态：`vcpu_running → vcpu_halted → vcpu_hashed`（睡了+已登记哈希）
- 哈希表：锁地址 → 睡着的队头节点（谁睡谁登记，解锁者查表踢人）
- SPIN_THRESHOLD：先转再睡

**睡眠决策不查持锁者状态**：只依据时间阈值 + prev 节点状态（pv_wait_early）。
原因：① 等待者不知道持锁者是谁（锁字 32 位塞满，无 holder CPU 号；队列设计只依赖直接前驱）；
② 睡眠安全性由 kick 保证（持锁者必叫醒），与持锁者状态无关。查 prev 的逻辑（每 256 圈一次）：
prev 醒着→继续转（令牌随时到）；prev 睡了→提前睡（无人传令牌，转满也白转）。
上游新版还叠加 `vcpu_is_preempted(prev->cpu)`（本树只有 state 检查）。
"确认在位"是放弃型等待（osq）需要的；停车型等待不需要。

### 5.3 lock 路径（qspinlock.c 第三遍生成 + qspinlock_paravirt.h）

```
goto pv_queue（跳过 native 快路径/virt_spin_lock/pending 尝试）
  → 取 per-CPU MCS 节点（MAX_NODES=4，超了裸 trylock 自旋）
  → queued_spin_trylock = pv_hybrid_queued_unfair_trylock  ← 一次偷锁机会
       pending 位被队头置起后禁止偷锁（hybrid unfair/queued，防饿死）
  → smp_wmb; xchg_tail 入队
  → 有 prev: WRITE_ONCE(prev->next, node); pv_wait_node(node, prev)   ← hook①
  → 队头: pv_wait_head_or_lock(lock, node)                            ← hook②
  → 拿锁: try_clear_tail / set_locked + 等 next + handoff + pv_kick_node(lock, next) ← hook③
```

**hook① pv_wait_node**（等 MCS 令牌，:293）：阈值自旋（node->locked 置位返回）→
每 256 圈 pv_wait_early 查 prev->state → `smp_store_mb(state, halted)` → 复查
`pv_wait(&pn->state, halted)`（**睡在 state 上而非 locked 上**——唤醒者改 state 既是
唤醒又是通知）→ 醒来 `cmpxchg(halted→running)` → 虚假唤醒再转再睡。

**hook② pv_wait_head_or_lock**（队头等真锁，:403）：入口若 state==hashed（hook③ 代劳）
跳过自哈希 → set_pending（禁止偷锁）→ 阈值自旋 trylock_clear_pending → 失败：
`pv_hash` 登记 → `xchg(locked, _Q_SLOW_VAL)`（返回 0 = 锁恰好刚空，直接拥有并撤销哈希）
→ state=hashed → `pv_wait(&lock->locked, _Q_SLOW_VAL)` 睡。

**hook③ pv_kick_node**（传令牌时，:360）：`cmpxchg(state, halted→hashed)` 原地推进
（**不真踢**，避免醒来又睡一趟白醒）→ `WRITE_ONCE(lock->locked, _Q_SLOW_VAL)`（锁仍
被持有，bit0=1）→ `pv_hash` 代登记。**哈希登记总是被"下一个要 unlock 的人"提前做掉**。

### 5.4 unlock 路径

```c
// __pv_queued_spin_unlock :547
cmpxchg_release(&lock->locked, _Q_LOCKED_VAL, 0);  // fastpath：锁值恰为 1 才成功
// 读到 3 → __pv_queued_spin_unlock_slowpath :502
smp_rmb();                       // 哈希先行契约（见下）
node = pv_unhash(lock);          // 摘出睡着的队头
smp_store_release(&lock->locked, 0);
pv_kick(node->cpu);              // 放锁后踢；lock 可被复用，node 是 per-CPU 静态存储仍有效
```

### 5.5 内存序契约（三处成对注释是正确性骨架）

```
契约1 睡眠协议（pv_wait_node ↔ pv_kick_node）:
  [S] state=halted        [S] next->locked=1
      MB                       MB
  [L] locked              [RmW] state→hashed     ← cmpxchg 提供序
契约2 哈希先行（pv_wait_head_or_lock ↔ unlock slowpath）:
  [S] <hash>              [Rmw] locked==_Q_SLOW_VAL
      MB                       RMB
  [RmW] locked=_Q_SLOW_VAL [L] <unhash>          ← unlock 侧 smp_rmb 保证查得到
契约3 释放与唤醒: store_release(locked,0) 保证临界区可见后才 kick
```

### 5.6 KVM 后端细节

```c
// kvm.c:1048
static void kvm_wait(u8 *ptr, u8 val)
{
	if (in_nmi()) return;
	if (irqs_disabled()) { if (*ptr == val) halt(); }        // 裸 HLT
	else { local_irq_disable();
	       if (*ptr == val) safe_halt();                      // STI+HLT 原子
	       else local_irq_enable(); }
}
// irq 关闭时锁信息可能被覆盖且无 spurious interrupt 来救，用裸 halt 让 KVM 拦截
```

- `kvm_kick_cpu`（:1037）：`per_cpu(x86_cpu_to_apicid) → kvm_hypercall2(KVM_HC_KICK_CPU)`
- `kvm_spinlock_init`（:1075）门槛：KVM_HINTS_REALTIME（专属 pCPU）→ 禁用；单核 → 禁用；
  nopvspin → 禁用；无 KVM_FEATURE_PV_UNHALT → 禁用但保留 virt_spin_lock_key
- host 侧 kick（x86.c:10096）：`kvm_pv_kick_cpu_op` 构造 **APIC_DM_REMRD** 伪中断投递到
  目标 APIC ID——运行中→轻量 kick（APICv 优化）；halted→lapic.c:1345 置 `pv_unhalted=1`
  → 转 RUNNABLE。加 `kvm_sched_yield`（时间片 boost）
- HLT 拦截 → `kvm_vcpu_block`（halt-polling 先忙等一会）
- **丢唤醒竞态闭合**：kick 先于 HLT 到达 → `kvm_vcpu_check_block → kvm_arch_vcpu_runnable`
  检查 `pv_unhalted`（x86.c:13137）→ 不睡直接返回 guest 重试

### 5.7 PVOP_VCALL2 宏机制（paravirt 分发核心）

```
pv_wait(ptr, val) → PVOP_VCALL2(lock.wait, ptr, val)
  → ____PVOP_CALL: asm volatile(paravirt_alt(PARAVIRT_CALL))
       "call *%[paravirt_opptr]"           ← 内存间接调用 pv_ops.lock.wait
       + .parainstructions 段记录 {instr地址, type, len}
    type = offsetof(struct paravirt_patch_template, op)/sizeof(void*)  ← 字段下标
```

启动期 `alternative_instructions → apply_paravirt → paravirt_patch`（paravirt.c:87）三分支：
- opfunc==NULL → 补丁成 `call paravirt_BUG`
- opfunc==_paravirt_nop → **ret=0 保留间接调用**（给"补丁后才可能赋值"的 op 留逃生舱）
- 其他 → 补丁成 5 字节直接 `call rel32`（text_poke_early）

**鸡生蛋问题的答案——赋值在前，补丁在后**：
```
start_kernel → setup_arch → guest_late_init (setup.c:1291)
                → kvm_guest_init → kvm_spinlock_init 写 pv_ops.lock.*   ← ① 先写值
  → arch_call_rest_init → alternative_instructions
      → paravirt_set_cap()  按当前 ops 设 X86_FEATURE_PVUNLOCK/VCPUPREEMPT  ← ② 设 cap
      → apply_paravirt()    按"此刻"pov_ops 值一次性补丁成直接 call          ← ③ 固化
```
补丁后热路径零决策。native 启动时 wait/kick 保持 paravirt_nop → 保持间接形式但
native 慢路径根本不调 pv_wait，永不执行。

### 5.8 代码生成：qspinlock.c 自包含三遍

`__pv_queued_spin_lock_slowpath` 源码里**没有字面定义**——是宏改名+自包含重编译生成：

| 遍次 | 宏 | 生成符号 | hooks |
|---|---|---|---|
| 1 | `:294` → native_queued_spin_lock_slowpath | native（+virt_spin_lock 生效） | `__pv_*` 空 stub |
| 2 | `:629`（OLK 特性） | `__cna_queued_spin_lock_slowpath` | CNA NUMA-aware |
| 3 | `:655-656` → __pv_queued_spin_lock_slowpath | PV | qspinlock_paravirt.h 真实现 |

`EXPORT_SYMBOL(queued_spin_lock_slowpath)`（:602）随之改名，符号真实存在于 qspinlock.o。
`_GEN_PV_LOCK_SLOWPATH` 等宏即 include guard。

`kernel/locking/qspinlock_paravirt.h:496` 的 `#include <asm/qspinlock_paravirt.h>` 按架构
解析（-I arch/$ARCH/include）：
- x86：`arch/x86/include/asm/qspinlock_paravirt.h`——手写汇编 `PV_UNLOCK_ASM` 融合
  thunk+unlock 函数体（cmpxchg fastpath + slowpath call），`DEFINE_PARAVIRT_ASM` 定义
  `__raw_callee_save___pv_queued_spin_unlock` 符号，与 `PV_CALLEE_SAVE(func)` 的
  `__raw_callee_save_##func` 命名约定对上
- arm64：本树无此文件（老分支华为版只有 12 行 extern 声明）

### 5.9 spin_lock → queued spinlock 完整调用链

```
① spin_lock(lock)                    spinlock.h:349 → raw_spin_lock(&lock->rlock)
② _raw_spin_lock (inline)            spinlock_api_smp.h:130
     preempt_disable + spin_acquire(lockdep) + LOCK_CONTENDED(lockdep.h:479)
③ do_raw_spin_lock → arch_spin_lock  spinlock.h:184；arch_spin_lock 是宏别名
     asm-generic/qspinlock.h:146: #define arch_spin_lock(l) queued_spin_lock(l)
④ queued_spin_lock                   qspinlock.h:107
     atomic_try_cmpxchg_acquire(0→_Q_LOCKED_VAL) 快路径
     失败 → queued_spin_lock_slowpath(lock, val)   ← 未定义符号，arch 提供
⑤ x86: asm/qspinlock.h:53 → pv_queued_spin_lock_slowpath → PVOP_VCALL2
     → 启动补丁 → 直接 call native 或 __pv_...   ← "三明治"：公共入口→arch 选择→公共实现
```

host/guest 决策：同一 vmlinux 两种部署，默认值（pv_ops 静态初始化）即 native/host；
setup_arch 检测 hypervisor → kvm_spinlock_init 改写 pv_ops → alternative 固化。
运行期无判断。嵌套虚拟化各实例独立决策。

## 6. x86 vCPU 在位信息：steal time 的 preempted 字节

- 结构：`include/uapi/linux/kvm_para.h` 的 `struct kvm_steal_time`，preempted 是其中 1 字节
- guest 注册（kvm.c:322）：每个 CPU online 时把 per-CPU 变量的物理地址
  `wrmsrl(MSR_KVM_STEAL_TIME, phys | KVM_MSR_ENABLED)` —— **MSR 通道而非 hypercall**
- host 写 1：`kvm_arch_vcpu_put → kvm_steal_time_set_preempted`（x86.c:5003）——
  前置条件 `at_instruction_boundary`（仅 host 中断类 exit 允许标，防误导 guest 锁策略）；
  经 `gfn_to_hva_cache` 缓存的 HVA `copy_to_user_nofault` + mark_page_dirty
- host 清 0：`record_steal_time`（x86.c:3648）在重新进入 guest 时（PV_TLB_FLUSH 特性下
  用 xchgb 原子交换，复用该字节双向通信）
- guest 读：`__kvm_vcpu_is_preempted`（kvm.c:785），x86-64 手写三指令汇编
  （PV_VCPU_PREEMPTED_ASM），是 pv_ops.lock.vcpu_is_preempted 的 KVM 后端
- **QEMU 不参与**：IPA 只是 guest RAM 普通页面（memslot 覆盖），QEMU 只透传 CPUID
  特性位；MSR 写时 host 校验 reserved bits，非法 GPA → 写失败 → 特性失效，无安全后果
- 对比 arm64 pvsched：x86 用 MSR + gfn_to_hva_cache（翻译缓存一次）；arm64 用 SMCCC
  hypercall + 每次写现查 memslot

## 7. 当前树（OLK-6.6）PV 回调清单

### 7.1 arm64 guest 侧（paravirt.c）— 4 组 static_call

| 回调 | 探测 | 实现 | 方向 |
|---|---|---|---|
| pv_steal_clock | pvtime SMCCC | para_steal_clock | host→guest |
| pv_vcpu_preempted | has_kvm_pvsched | kvm_vcpu_is_preempted | host→guest |
| pvtimer_status_set | vendor SMCCC | pv_set_pvtimer_status | **guest→host**（代码在树，defconfig 未开） |
| pv_timer_early_inject | vendor SMCCC | pv_get_timer_early_inject_ns | host→guest（2026 新合入） |

host 侧：arch/arm64/kvm/ 的 pvtime.c、pvsched.c、pvtimer_status.c、pvtimer_early.c
defconfig：PARAVIRT=y、PARAVIRT_SCHED=y、PARAVIRT_TIME_ACCOUNTING=y、VIRT_TIMER_EARLY_INJECT=y

### 7.2 x86 guest 侧 — pv_ops 全套

lock.queued_spin_lock_slowpath/unlock/wait/kick/vcpu_is_preempted + pv_steal_clock
static_call + PV EOI/async pf 等。

### 7.3 当前树没有的

- arm64 PV qspinlock（kick）：CONFIG_PARAVIRT_SPINLOCKS 无 arm64 实现

## 8. 关键认知点汇总（FAQ）

1. **preempted 检测不碰 qspinlock**：消费者是上游已存在的 osq/mutex/sched；
   qspinlock 的 PV 化是独立的 kick 战线
2. **kick 方向**：持锁者→等待者（unlock 时刻），不是等待者踢持锁者；
   "让持锁者上线"靠等待者睡眠让出 pCPU + host 调度
3. **睡眠决策**：阈值 + prev 状态，不查持锁者（不知道是谁、不需要——kick 保证唤醒）
4. **哈希登记谁做**：谁睡谁登记；传令牌者代为推进状态（halted→hashed）+ 预登记，
   避免"醒来又睡"的白醒
5. **host 写共享页**：GPA→HVA→host 页表，不经过 S2；原子路径 pagefault_disable +
   异常表 fixup，不补页（补页在 guest stage-2 fault 的 GUP 慢路径）
6. **x86 分发**：setup_arch 先写 pv_ops（guest 检测）→ alternative_instructions 后补丁
   固化——运行期零决策
7. **paravirt_nop 特例**：保留间接调用 = 运行期晚赋值逃生舱
8. **同一 vmlinux 双部署**：默认值即 host；检测到 hypervisor 才改；补丁后直接 call
9. **arm64 移植**：华为版完全复用通用 qspinlock_paravirt.h，只换 pv_wait(WFI)/pv_kick(SMCCC)

## 9. 相关链接

- [v1 0/9 系列 patch 6/9（kick 定义）](https://mailweb.openeuler.org/archives/list/kernel@openeuler.org/message/EVBRU35TPR3HUJGBQRYTMSPUDCCHUI6Q/)
- [v1 系列 CI 驳回回复](https://mailweb.openeuler.org/archives/list/kernel@openeuler.org/message/B5LC7KZR3P44ZUIU7I66MFHHG6TAEO3U/)
- [v2 0/5 重投系列](https://mailweb.openeuler.org/archives/list/kernel@openeuler.org/message/XFIVEBSUQZOP7QWYBIG5FVWH2QBQTQTE/)
- [Gitee issue IBTO64：pv spinlock 特性回合](https://gitee.com/openeuler/kernel/issues/IBTO64)
