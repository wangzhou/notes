# x86 vs ARM64 虚拟化 PV 特性对比分析

> 日期：2026/07/20
> 主题：对比 x86 与 ARM64 在 KVM 半虚拟化（Paravirtualization, PV）特性上的差异，识别哪些值得在 ARM64 上补齐。
> 结论先行：ARM64 PV 特性看似少，但很多 x86 PV 特性是在补架构短板，ARM64 已用硬件解决，不该照搬。真正值得补的是"**把被抢占（preempted）语义暴露给 guest**"这一族特性，核心地基是 `vcpu_is_preempted()`（当前是空桩）。

---

## 一、PV 特性清单对比（基于当前内核树核实）

代码核实来源：
- x86 feature 位：`arch/x86/include/uapi/asm/kvm_para.h`
- x86 hypercall：`include/uapi/linux/kvm_para.h`
- x86 guest 侧：`arch/x86/kernel/kvm.c`
- ARM64 SMCCC func：`include/linux/arm-smccc.h`
- ARM64 KVM 侧：`arch/arm64/kvm/hypercalls.c`、`arch/arm64/kvm/pvtime.c`
- ARM64 guest 侧：`arch/arm64/kernel/paravirt.c`、`arch/arm64/include/asm/spinlock.h`

| PV 特性 | x86 KVM | ARM64 KVM | 说明 |
|---|---|---|---|
| Steal time（被抢占时间统计） | ✅ `KVM_FEATURE_STEAL_TIME` | ✅ `PV_TIME_ST` | 两边都有，ARM64 走 SMCCC `ARM_SMCCC_HV_PV_TIME_ST` |
| PV 时钟 | ✅ kvmclock（`CLOCKSOURCE2`） | ⚠️ 部分（仅 PTP） | 见第二节架构说明 |
| PV EOI（中断结束免陷出） | ✅ `KVM_FEATURE_PV_EOI` | ❌ | GIC 模型不同 |
| PV spinlock（`PV_UNHALT`+wait/kick） | ✅ | ❌ | `vcpu_is_preempted` 是空桩 |
| Directed yield（`PV_SCHED_YIELD`） | ✅ | ❌ | 依赖 preempted 标志 |
| PV TLB flush | ✅ `KVM_FEATURE_PV_TLB_FLUSH` | ❌（架构不需要） | 硬件 TLBI 广播 |
| PV send IPI（批量 IPI） | ✅ `KVM_FEATURE_PV_SEND_IPI` | ❌（架构基本不需要） | ICC_SGI1R 系统寄存器 |
| Async page fault | ✅ `ASYNC_PF*`（PF/VMEXIT/INT） | ❌ | x86 侧本身在重构 |
| Halt-poll 控制 | ✅ `POLL_CONTROL` + cpuidle-haltpoll | ❌ | cpuidle-haltpoll 目前仅 x86 |
| 机密内存 map GPA range | ✅ `KVM_HC_MAP_GPA_RANGE` | ✅ pKVM `MEM_SHARE/UNSHARE` | 等价能力，机制不同 |
| PTP 跨时间戳 | ✅ `ptp_kvm_x86` | ✅ `ptp_kvm_arm` | 两边都有 |

---

## 二、为什么"差距"没有清单看上去那么大

很多 x86 PV 特性是在**补架构短板**，ARM64 架构本身已把这些坑填了，照搬过来是负优化：

- **PV TLB flush**：x86 远程 TLB shootdown 必须靠 IPI，vCPU 被抢占时 IPI 打空转，故要 PV 化。ARM64 有 `TLBI ...IS` 硬件广播，根本不发 IPI。**不该照搬**。唯一残留问题：广播打到一个被 host 换出的 vCPU 上会做无用功——这才是 ARM64 值得优化的点（需要 preempted 信息），与 x86 的 PV_TLB_FLUSH 是两码事。
- **PV send IPI**：x86 发 IPI 要写 APIC（可能多次 VM-exit），故批量化。ARM64 SGI 走 `ICC_SGI1R_EL1` 系统寄存器，一条指令多目标，vGIC 侧成本已低很多。收益有限。
- **kvmclock**：x86 TSC 历史上不稳定、迁移会跳，才需要 PV 时钟。ARM64 的 `CNTVCT` 是稳定虚拟计数器，配合 `CNTVOFF`/`CNTPOFF` 硬件偏移（见 [[ARM64_CNTPOFF分析]]），迁移/偏移问题在架构层解决，不需要完整 kvmclock，PTP 补齐跨时间戳即可。
- **PV EOI**：x86 每次 EOI 可能陷出；GICv3 有硬件 LR/优先级投放机制，`ICC_*` 系统寄存器路径，收益结构不同，不是简单移植。

---

## 三、真正值得在 ARM64 上补的（按性价比排序）

### 1. `vcpu_is_preempted` 落地 —— 地基，必做
`arch/arm64/include/asm/spinlock.h` 当前实现是硬编码 `return false`：
```c
#define vcpu_is_preempted vcpu_is_preempted
static inline bool vcpu_is_preempted(int cpu)
{
	return false;
}
```
落地它（host 在 steal-time 共享区加一个 preempted 标志位，guest 读取）本身收益不大，但它是下面两项及 TLBI 优化的前置。这是唯一"必须先做"的。

### 2. PV qspinlock / 锁持有者被抢占感知 —— 超卖场景收益最大
ARM64 队列自旋锁靠 WFE 自旋。当锁持有者 vCPU 被 host 换出，其他 vCPU 空转到超时（lock holder preemption, LHP / lock waiter preemption）。在 vCPU 超卖（overcommit）下这是 ARM64 最痛的点。可做：
- `vcpu_is_preempted` 让 `osq_lock`/`mutex` 乐观自旋在持有者被抢占时提前退出；
- 或引入 wait/kick 型 PV 锁（类似 x86 `PV_UNHALT`，guest 侧 `kvm_wait`/`kvm_kick_cpu`）。

社区反复有 RFC，一直未并入主线，是块实打实的空地。

### 3. Directed yield（`PV_SCHED_YIELD` 等价）
guest 在自旋等一个已被抢占的 vCPU 时，主动让出并提示 host 优先调度目标 vCPU。同样依赖第 1 项。实现路径清晰（加一个 vendor SMCCC func）。

### 4. cpuidle-haltpoll 支持 ARM64
`drivers/cpuidle/cpuidle-haltpoll.c` 目前只在 x86 启用。ARM64 用 WFI 进 idle，guest 侧 poll 一小段再 WFI 可砍掉轻负载下的 exit。移植成本相对低，是较独立的一块。

### 次要 / 存疑
- **Async page fault**：移植性差且 x86 侧在重构，不建议。
- **PV EOI**：需贴着 GICv3 重新设计，投入产出比低。

---

## 四、建议路径

动手顺序：**`vcpu_is_preempted` 落地 → directed yield / PV 锁 → （可选）haltpoll**。

核心主线是"**把被抢占语义暴露给 guest**"这一族特性——这正是 ARM64 缺失、且在 vCPU 超卖下收益最明确的方向。TLB / IPI / 时钟这些，ARM64 架构已用硬件解决，不必跟着 x86 走。

---

## 五、待深入（TODO）
- [ ] `vcpu_is_preempted` 具体落地方案：steal-time 共享结构扩展 preempted 位的布局与内存序
- [ ] directed yield 的 vendor SMCCC func ID 分配与 guest/host 接口设计
- [ ] PV 锁：`osq_lock` 提前退出 vs wait/kick 两条路线的收益实测对比
