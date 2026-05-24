# ARM64 KVM PMU 虚拟化分析

## 目录

1. [架构总览](#1-架构总览)
2. [源文件与角色](#2-源文件与角色)
3. [核心数据结构](#3-核心数据结构)
4. [生命周期管理](#4-生命周期管理)
5. [系统寄存器仿真](#5-系统寄存器仿真)
6. [vPMU 寄存器 ↔ 主机 perf_event 映射机制](#6-vpmu-寄存器--主机-perf_event-映射机制)
7. [perf_event 的语义](#7-perf_event-的语义)
8. [Host/Guest 上下文切换](#8-hostguest-上下文切换)
9. [溢出与中断处理](#9-溢出与中断处理)
10. [Event Filter 事件过滤](#10-event-filter-事件过滤)
11. [异构系统 PMU 选择](#11-异构系统-pmu-选择)
12. [嵌套虚拟化支持](#12-嵌套虚拟化支持)
13. [完整数据流图](#13-完整数据流图)
14. [关键设计点总结](#14-关键设计点总结)
15. [Partitioned PMU：直通硬件计数器的 PMU 分区方案](#15-partitioned-pmu直通硬件计数器的-pmu-分区方案)

---

## 1. 架构总览

KVM ARM64 PMU 虚拟化利用宿主内核 **perf_event 子系统** 为每个 guest vPMU counter 提供真实硬件计数能力。整体分为三个层次：

```
┌─────────────────────────────────────────────────────┐
│  用户态 (VMM)                                        │
│  KVM_ARM_VCPU_PMU_V3_INIT / SET_PMU / FILTER / ...  │
├─────────────────────────────────────────────────────┤
│  KVM 层                                              │
│  ┌──────────────┐  ┌──────────┐  ┌───────────────┐ │
│  │ sys_regs.c   │  │pmu-emul.c│  │    pmu.c      │ │
│  │ (trap 处理)  │  │(perf 映射)│  │(上下文切换)   │ │
│  └──────┬───────┘  └────┬─────┘  └───────┬───────┘ │
│         │               │                │          │
├─────────┼───────────────┼────────────────┼──────────┤
│  Hyp 层 │               │                │          │
│  ┌──────┴──────┐        │         ┌──────┴──────┐  │
│  │switch.h     │        │         │nvhe/switch.c│  │
│  │(VHE PMUSER) │        │         │(nVHE PMCNT) │  │
│  └─────────────┘        │         └─────────────┘  │
├─────────────────────────┼──────────────────────────┤
│  内核 perf 子系统        │                          │
│  ┌──────────────────────┴──────────────────────┐   │
│  │        perf_event (硬件 PMC 代理)            │   │
│  │  - 事件计数                                 │   │
│  │  - 溢出检测                                 │   │
│  │  - PMC 调度与多路复用                       │   │
│  └──────────────────────┬──────────────────────┘   │
├─────────────────────────┼──────────────────────────┤
│  硬件 PMU (ARM PMUv3)    │                          │
│  PMC0..PMC30, PMCCNTR    │                          │
└──────────────────────────┴──────────────────────────┘
```

---

## 2. 源文件与角色

| 文件 | 行数 | 职责 |
|---|---|---|
| `arch/arm64/kvm/pmu-emul.c` | 1336 | **PMU 仿真核心**：counter 值管理、perf_event 创建/销毁、溢出回调、UAPI 处理、PMCEID 计算、嵌套过渡 |
| `arch/arm64/kvm/pmu.c` | 212 | **每个 CPU 的事件切换**：per-CPU `kvm_pmu_events` 位图维护、VHE EL0 过滤位切换、`PMUSERENR_EL0` 管理 |
| `arch/arm64/kvm/sys_regs.c` | - | **系统寄存器 trap-and-emulate**：所有 PMU 寄存器的访问控制、读/写分发 |
| `arch/arm64/kvm/hyp/include/hyp/switch.h` | 49 | **Hyp 层 trap 配置**：`PMUSERENR_EL0` 的 host/guest 保存恢复 |
| `arch/arm64/kvm/hyp/nvhe/switch.c` | 33 | **nVHE PMU 切换**：通过 `PMCNTENSET/CLR` 切换 host/guest 事件 |
| `arch/arm64/kvm/hyp/vhe/switch.c` | 26 | **VHE PMU 保护**：关中断保护 `PMUSERENR_EL0` 的竞态窗口 |
| `include/kvm/arm_pmu.h` | 200 | **PMU 头文件**：数据结构定义、函数声明、内联辅助 |
| `arch/arm64/include/asm/kvm_host.h` | - | **集成点**：`KVM_REQ_RELOAD_PMU`、`KVM_REQ_RESYNC_PMU_EL0`、`PMUSERENR_ON_CPU` 标志、`kvm_arch` 中的 PMU 字段 |
| `arch/arm64/include/uapi/asm/kvm.h` | - | **UAPI**：`KVM_ARM_VCPU_PMU_V3` 特性位、filter 结构体、设备属性定义 |
| `drivers/perf/arm_pmuv3.c` | - | **Host PMU 驱动**：调用 `kvm_set_pmu_events()`、`kvm_clr_pmu_events()`、`kvm_pmu_counter_deferred()` |
| `virt/kvm/kvm_main.c` | - | **Guest 状态回调**：`kvm_guest_state()` 向 perf 核心报告当前是否在 guest 中 |
| `arch/arm64/kvm/arm.c` | - | **主运行循环集成**：vCPU 加载/卸载、请求处理、状态刷新 |
| `arch/arm64/kvm/guest.c` | - | **设备属性路由**：`set_attr`/`get_attr`/`has_attr` → `kvm_arm_pmu_v3_*` |

---

## 3. 核心数据结构

### 3.1 per-vCPU PMU 状态

```c
// include/kvm/arm_pmu.h
struct kvm_pmu {
    struct irq_work overflow_work;                    // NMI 安全的延迟 vCPU kick
    struct kvm_pmu_events events;                     // nVHE: 本 CPU 的 host/guest 事件位图快照
    struct kvm_pmc pmc[KVM_ARMV8_PMU_MAX_COUNTERS];  // 最多 32 个 counter
    int irq_num;                                     // PPI 或 SPI 中断号
    bool created;                                     // INIT 完成标志
    bool irq_level;                                   // 当前中断输出电平
};
```

### 3.2 单个 Counter

```c
struct kvm_pmc {
    u8 idx;                          // 在 pmu->pmc[] 中的索引
    struct perf_event *perf_event;   // 宿主内核 perf_event 后盾，可为 NULL
};
```

### 3.3 Per-CPU 事件追踪

```c
struct kvm_pmu_events {
    u64 events_host;   // 需要在 host 侧启用 EL0 计数的事件位图
    u64 events_guest;  // 需要在 guest 侧启用 EL0 计数的事件位图
};

// per-CPU 实例
static DEFINE_PER_CPU(struct kvm_pmu_events, kvm_pmu_events);
```

### 3.4 PMU 实例链表

```c
struct arm_pmu_entry {
    struct list_head entry;
    struct arm_pmu *arm_pmu;   // 指向 host 的 arm_pmu 实例
};

static LIST_HEAD(arm_pmus);     // 全局 PMU 实例链表
```

### 3.5 kvm_arch 中的 PMU 字段

```c
// arch/arm64/include/asm/kvm_host.h
struct kvm_arch {
    unsigned long *pmu_filter;       // 事件过滤位图 (NULL = 无过滤)
    struct arm_pmu *arm_pmu;         // 当前使用的 PMU 实例
    cpumask_t supported_cpus;        // 该 PMU 支持的 CPU 集合
    u8 nr_pmu_counters;              // 虚拟化给 guest 的 counter 数量 (PMCR.N)
};
```

---

## 4. 生命周期管理

### 4.1 探测阶段

```
Host PMU 驱动注册 (drivers/perf/arm_pmu.c)
  → kvm_host_pmu_init(arm_pmu)
    → 检查 sanitised PMU 版本 (过滤 IMP_DEF)
    → 分配 arm_pmu_entry 加入 arm_pmus 全局链表
```

### 4.2 vCPU 初始化

```
kvm_vcpu_init()
  → kvm_vcpu_pmu_init(vcpu)            // 初始化 32 个 counter 的 idx
```

### 4.3 默认 PMU 分配

```
kvm_arch_vcpu_create() 结束时
  → 若 vCPU 有 PMU feature 但未设置 arm_pmu
    → kvm_arm_set_default_pmu(kvm)
      → kvm_pmu_probe_armpmu()        // 根据当前 CPU 探测默认 PMU
      → kvm_arch.arm_pmu = arm_pmu
      → kvm_arch.nr_pmu_counters = 硬件最大 counter 数
```

### 4.4 PMU 实例化

```
用户态: KVM_ARM_VCPU_PMU_V3_INIT
  → kvm_arm_pmu_v3_init(vcpu)
    ├─ in-kernel GIC: 验证中断号, kvm_vgic_set_owner()
    ├─ init_irq_work(&pmu->overflow_work, kvm_pmu_perf_overflow_notify_vcpu)
    └─ pmu->created = true
```

### 4.5 使能验证

```
用户态: KVM_ARM_VCPU_PMU_V3 特性最终确认
  → kvm_arm_pmu_v3_enable(vcpu)
    ├─ in-kernel irqchip: 验证 IRQ 有效性 (PPI / 合法 SPI)
    └─ userspace irqchip: 不能设置 IRQ 号
```

### 4.6 销毁

```
kvm_vcpu_destroy()
  → kvm_pmu_vcpu_destroy(vcpu)
    ├─ for all 32 counters: kvm_pmu_release_perf_event(pmc)
    │    → perf_event_disable() + perf_event_release_kernel()
    └─ irq_work_sync(&pmu->overflow_work)
```

---

## 5. 系统寄存器仿真

所有 PMU 寄存器在 EL1/EL0 访问时 trap 到 EL2，由 `sys_regs.c` 处理。

### 5.1 访问控制

所有 PMU 寄存器的 EL0 访问受 `PMUSERENR_EL0` 控制：

| 寄存器组 | PMUSERENR 控制位 | 检查函数 |
|---|---|---|
| PMCR_EL0, PMCEID, PMCNTEN, PMOVS, PMEVTYPER | `EN` | `pmu_access_el0_disabled()` |
| PMEVCNTRn (通过 PMXEVCNTR) | `ER` + `EN` | `pmu_access_event_counter_el0_disabled()` |
| PMCCNTR_EL0 | `CR` + `EN` | `pmu_access_cycle_counter_el0_disabled()` |
| PMSWINC_EL0 | `SW` + `EN` | `pmu_write_swinc_el0_disabled()` |
| PMUSERENR_EL0 | 仅特权级可写 | `vcpu_mode_priv()` |
| PMINTENSET/CLR | 特权级访问 | `check_pmu_access_disabled(0)` |

### 5.2 寄存器操作表

| 寄存器 | 读语义 | 写语义 |
|---|---|---|
| **PMCR_EL0** | `kvm_vcpu_read_pmcr()`，动态计算 N 字段 | `kvm_pmu_handle_pmcr()`：E/P/C 位触发 counter 操作 |
| **PMCNTENSET** | 返回 `PMCNTENSET_EL0` | `kvm_pmu_reprogram_counter_mask()`：按位启停 perf_event |
| **PMCNTENCLR** | 返回 `PMCNTENSET_EL0` | 清除位 + `kvm_pmu_reprogram_counter_mask()` |
| **PMOVSSET** | 返回 `PMOVSSET_EL0` | 写入 1 的位设置 overflow |
| **PMOVSCLR** | 返回 `PMOVSSET_EL0` | 写入 1 的位清除 overflow |
| **PMINTENSET/CLR** | 返回 `PMINTENSET_EL1` | 按位设置/清除中断使能 |
| **PMSWINC_EL0** | 只写寄存器 | `kvm_pmu_software_increment()`：纯软件模拟 |
| **PMEVCNTRn** | `kvm_pmu_get_counter_value()` = sys_reg + perf_event 增量 | `kvm_pmu_set_counter_value()`：释放→更新→重建 perf_event |
| **PMEVTYPERn** | 返回 sys_reg 值 | `kvm_pmu_set_counter_event_type()`：更新→重建 perf_event |
| **PMCCNTR_EL0** | 同 PMEVCNTR (idx=31) | 同 PMEVCNTR (idx=31) |
| **PMCCFILTR_EL0** | 返回 sys_reg 值 | 同 PMEVTYPER (idx=31) |
| **PMCEID0/1** | `kvm_pmu_get_pmceid()`：从 arm_pmu 位图计算 + filter 裁剪 | 只读 |
| **PMUSERENR_EL0** | 返回 sys_reg & MASK | 仅特权级可写 |
| **PMSELR_EL0** | 返回 SEL 字段 | 写入选择索引 |
| **PMXEVCNTR** | 读 `PMSELR.SEL` 选中的 counter | 写选中的 counter |
| **PMXEVTYPER** | 读 `PMSELR.SEL` 选中的 evtreg | 写选中的 evtreg |

### 5.3 PMCR.N 的动态计算

```c
u64 kvm_vcpu_read_pmcr(struct kvm_vcpu *vcpu)
{
    u64 pmcr = __vcpu_sys_reg(vcpu, PMCR_EL0);
    u64 n = vcpu->kvm->arch.nr_pmu_counters;

    // 嵌套且非 EL2: N = MDCR_EL2.HPMN (EL2 保留的 counter 数)
    if (vcpu_has_nv(vcpu) && !vcpu_is_el2(vcpu))
        n = FIELD_GET(MDCR_EL2_HPMN, __vcpu_sys_reg(vcpu, MDCR_EL2));

    return u64_replace_bits(pmcr, n, ARMV8_PMU_PMCR_N);
}
```

### 5.4 Counter 索引解码

| 寄存器编码 (CRn, CRm, Op2) | Counter 索引 |
|---|---|
| (9, 13, 0) → PMCCNTR_EL0 | `ARMV8_PMU_CYCLE_IDX` (31) |
| (9, 13, 2) → PMXEVCNTR_EL0 | `PMSELR_EL0.SEL` |
| (14, 8-11, 0-7) → PMEVCNTRn_EL0 | `((CRm & 3) << 3) \| (Op2 & 7)` |

---

## 6. vPMU 寄存器 ↔ 主机 perf_event 映射机制

### 6.1 核心模型：三个关键值

```
guest 可观测 counter 值 = sys_reg 值 + perf_event 已计数值
```

- **`sys_reg` 值**：VMM 或 guest 写入 counter 时的基线值，保存在 `__vcpu_sys_reg(vcpu, 寄存器)` 中
- **`perf_event` 增量**：自上次写入以来，主机硬件 PMU 实际累加的计数，由 `perf_event_read_value()` 返回
- **`overflow` 边界**：perf_event 的 `sample_period` 设在该 counter 从当前值到溢出所需的事件数

该分离设计是因为 guest 随时可能被 vCPU 调度出去，硬件 PMU 被 host 接管后 guest 事件不会继续计数。perf 子系统天然处理事件多路复用和停止的情况。

### 6.2 读 Counter 的完整路径

以 guest 执行 `MRS x0, PMEVCNTR0_EL0` 为例：

```
1. EL1 访问 PMEVCNTR0_EL0 → trap 到 EL2
2. sys_regs.c: access_pmu_evcntr()
   → 根据 CRn/CRm/Op2 解码出 idx=0
   → pmu_access_event_counter_el0_disabled(vcpu)
       检查 PMUSERENR_EL0.ER & EN
   → kvm_pmu_get_counter_value(vcpu, 0)
      ↓
3. kvm_pmu_get_pmc_value(pmc)
   counter = __vcpu_sys_reg(vcpu, PMEVCNTR0_EL0);   // 基线值
   if (pmc->perf_event)
       counter += perf_event_read_value(pmc->perf_event,
                                        &enabled, &running);
   // 若非 64bit counter: counter &= 0xFFFF_FFFF
   return counter;
```

`perf_event_read_value()` 读取的是 perf 子系统内部维护的 `event->count`，反映自创建以来硬件事件的实际触发次数（考虑了多路复用的缩放比例：`count = raw_count * enabled/running`）。

### 6.3 写 Counter：为什么必须销毁并重建 perf_event

```c
static void kvm_pmu_set_pmc_value(struct kvm_pmc *pmc, u64 val, bool force)
{
    kvm_pmu_release_perf_event(pmc);    // ① 销毁旧 perf_event
    __vcpu_assign_sys_reg(vcpu, reg, val);  // ② 保存新基线值
    kvm_pmu_create_perf_event(pmc);     // ③ 重建 perf_event
}
```

**为什么必须重建？** 关键在于 `compute_period()` 的计算：

```c
static u64 compute_period(struct kvm_pmc *pmc, u64 counter)
{
    if (kvm_pmc_is_64bit(pmc) && kvm_pmc_has_64bit_overflow(pmc))
        val = (-counter) & GENMASK(63, 0);   // 到 64bit 溢出还差多少次
    else
        val = (-counter) & GENMASK(31, 0);   // 到 32bit 溢出还差多少次
    return val;
}
```

perf_event 的 `sample_period` 被设为当前 counter 值到溢出边界的事件数。例如 guest 写入 `counter=0xFFFF_FFF0` 到一个 32bit counter，则 `sample_period = (-0xFFFF_FFF0) & 0xFFFFFFFF = 16`，perf_event 在计数 16 次后触发 overflow。如果只更新 sys_reg 而不重建 perf_event，旧的 `sample_period` 依然指向旧的溢出点，导致溢出时机错误。

**用户态写入的特殊路径** — `kvm_pmu_set_counter_value_user()`：
```c
void kvm_pmu_set_counter_value_user(struct kvm_vcpu *vcpu, u64 select_idx, u64 val)
{
    kvm_pmu_release_perf_event(...);        // 仅释放
    __vcpu_assign_sys_reg(vcpu, reg, val); // 更新 sys_reg
    kvm_make_request(KVM_REQ_RELOAD_PMU, vcpu); // 延迟重建
}
```
不立即重建，而是标记 `KVM_REQ_RELOAD_PMU`，在下次 vCPU 进入 guest 前由 `kvm_vcpu_reload_pmu()` 统一重建——减少 perf 操作开销。

**stop_counter** — 将 perf_event 的增量"结算"到 sys_reg 基线中：
```c
static void kvm_pmu_stop_counter(struct kvm_pmc *pmc)
{
    val = kvm_pmu_get_pmc_value(pmc);              // 读取当前总计数
    __vcpu_assign_sys_reg(vcpu, reg, val);          // 固化到 sys_reg
    kvm_pmu_release_perf_event(pmc);               // 释放 perf_event
}
```

### 6.4 Event Type 编程：创建 perf_event 的完整流程

Guest 写 `PMEVTYPERn_EL0` (选择要监控的事件) 时：

```
guest: MSR PMEVTYPER0_EL0, x0   (event=0x08, INST_RETIRED)
  ↓ trap
sys_regs.c: access_pmu_evtyper()
  → kvm_pmu_set_counter_event_type(vcpu, data, idx)
    ① 更新 __vcpu_sys_reg(PMEVTYPER0_EL0) = data & evtyper_mask
    ② kvm_pmu_create_perf_event(pmc)
```

**`kvm_pmu_create_perf_event()` 的 8 个步骤**：

```
① 读取 PMEVTYPERn_EL0，提取事件号
   eventsel = evtreg & kvm_pmu_event_mask(kvm);
   // PMUv3 IMP: 10bit (GENMASK(9,0))
   // PMUv3p1+: 16bit (GENMASK(15,0))

② 停止旧事件 (如果有) —— 先"结算"再销毁
   kvm_pmu_stop_counter(pmc)
     → val = sys_reg + perf_event_read_value()
     → sys_reg = val (固化基线)
     → perf_event_release_kernel()

③ 特殊事件短路 —— 不需要硬件后盾
   - SW_INCR (0x00): 纯软件模拟，return
   - CHAIN (0x1E):  由 overflow 联动实现，return
   - Cycle counter (idx=31): eventsel 固定为 CPU_CYCLES (0x11)

④ Event 过滤检查
   if (pmu_filter && !test_bit(eventsel, pmu_filter))
       return;  // 不在白名单内，不创建

⑤ 事件号映射 (非标准 PMUv3 硬件)
   eventsel = kvm_map_pmu_event(kvm, eventsel);
   // 某些 vendor PMU 需要把标准 PMUv3 事件号转译成自己的编码
   // 失败返回负值 → 不创建

⑥ 构建 perf_event_attr
   attr.type          = arm_pmu->pmu.type;          // PMU 实例类型
   attr.config        = eventsel;                   // 事件号
   attr.pinned        = 1;                          // 钉在硬件 counter 上
   attr.disabled      = !kvm_pmu_counter_is_enabled(pmc);
   attr.exclude_user  = !kvm_pmc_counts_at_el0(pmc); // PMEVTYPER.U
   attr.exclude_kernel= !kvm_pmc_counts_at_el1(pmc); // PMEVTYPER.P
   attr.exclude_hv    = 1;                          // 绝不统计 EL2/hypervisor
   attr.exclude_host  = 1;                          // 不计入 host 上下文
   attr.config1       = PERF_ATTR_CFG1_COUNTER_64BIT; // (如适用)
   attr.sample_period = compute_period(pmc, kvm_pmu_get_pmc_value(pmc));

⑦ 创建内核 perf_event
   event = perf_event_create_kernel_counter(&attr, -1, current,
                                            kvm_pmu_perf_overflow, pmc);
   // cpu=-1: 让 perf 选择 CPU (跟随创建者)
   // overflow_handler = kvm_pmu_perf_overflow
   // overflow_handler_context = pmc 指针

⑧ 保存
   pmc->perf_event = event;
```

**`attr` 中关键字段的作用**：

- **`exclude_host=1`**: 硬件 PMU 在 host 运行时不对该事件计数（VHE → `EXCLUDE_EL0`）。这是 host/guest 隔离的核心。
- **`sample_period`**: 不是用于采样，而是控制硬件 PMU 何时产生 overflow 中断。设为"到溢出边界的事件数"使 perf 在 guest counter 溢出时恰好触发回调。
- **`pinned=1`**: 保证 guest 的 perf_event 不被 perf 多路复用挤掉（宁可报错 EOVERFLOW 也不被交换出去）。

### 6.5 Counter Enable/Disable 映射

```c
static void kvm_pmc_enable_perf_event(struct kvm_pmc *pmc)
{
    if (!pmc->perf_event) {
        kvm_pmu_create_perf_event(pmc);  // 懒创建
        return;
    }
    perf_event_enable(pmc->perf_event);
}

static void kvm_pmc_disable_perf_event(struct kvm_pmc *pmc)
{
    if (pmc->perf_event)
        perf_event_disable(pmc->perf_event);
}
```

触发 enable/disable 的硬件事件：
- **PMCNTENSET/PMCNTENCLR 写入** → `kvm_pmu_reprogram_counter_mask()`
- **PMCR_EL0.E 位翻转** → `KVM_REQ_RELOAD_PMU` → `kvm_vcpu_reload_pmu()`
- **嵌套 EL1↔EL2 切换** → `kvm_pmu_nested_transition()`

每个 counter 的三层使能判断：
```c
static bool kvm_pmu_counter_is_enabled(struct kvm_pmc *pmc)
{
    if (!(PMCNTENSET_EL0 & BIT(pmc->idx)))
        return false;              // ① 位使能 (per-counter)
    if (kvm_pmu_counter_is_hyp(vcpu, pmc->idx))
        return MDCR_EL2 & MDCR_EL2_HPME;  // ② EL2 全局使能
    return PMCR_EL0 & ARMV8_PMU_PMCR_E;    // ③ EL1/0 全局使能
}
```

### 6.6 `__vcpu_rmw_sys_reg` / `__vcpu_assign_sys_reg` 辅助

这些宏操作 vCPU 的 sys_reg 数组（模拟 guest 可见的寄存器状态）：

```c
__vcpu_assign_sys_reg(vcpu, PMCR_EL0, val);     // 直接赋值
__vcpu_rmw_sys_reg(vcpu, PMOVSSET_EL0, |=, mask); // 读-改-写
__vcpu_rmw_sys_reg(vcpu, PMCNTENSET_EL0, &=, ~mask);
```

这只是纯粹的 vCPU context 内存操作，不涉及硬件访问。

---

## 7. perf_event 的语义

### 7.1 perf_event 是什么

`perf_event` 是 Linux perf 子系统的核心抽象对象，代表"**在特定 PMU 上对特定事件的单次计数会话**"。

| 层面 | 语义 |
|---|---|
| **逻辑层** | "计数值 + 溢出条件 + 回调"三位一体 |
| **调度层** | 硬件 PMC 资源由 perf 核心调度，多个事件可时分复用同一个硬件 counter |
| **硬件层** | 对应一个实际的硬件 PMC，`event->hw` 存硬件状态 |

### 7.2 三层 host/guest 隔离

**层面1：perf 核心层的上下文感知**

perf 子系统通过回调实时感知 host/guest 上下文：

```c
// virt/kvm/kvm_main.c
static unsigned int kvm_guest_state(void)
{
    struct kvm_vcpu *vcpu = kvm_get_running_vcpu();
    if (!vcpu) return 0;               // host 上下文
    state = PERF_GUEST_ACTIVE;         // guest 上下文
    if (!kvm_arch_vcpu_in_kernel(vcpu))
        state |= PERF_GUEST_USER;      // guest EL0
    return state;
}
```

perf 核心在计算事件运行时间时使用此信息，`exclude_host=1` 的事件在 host 上下文中运行时间不会被计入。

**层面2：ARM64 硬件 PMU 驱动的 EL 级过滤**

```c
// drivers/perf/arm_pmuv3.c: armv8pmu_set_event_filter()
if (is_kernel_in_hyp_mode()) {       // VHE 模式
    if (!attr->exclude_kernel && !attr->exclude_host)
        config_base |= ARMV8_PMU_INCLUDE_EL2;    // host 内核 = EL2
    if (attr->exclude_guest)
        config_base |= ARMV8_PMU_EXCLUDE_EL1;    // guest 内核 = EL1
    if (attr->exclude_host)
        config_base |= ARMV8_PMU_EXCLUDE_EL0;    // host 用户态 = EL0
} else {                               // 非 VHE
    if (!attr->exclude_hv && !attr->exclude_host)
        config_base |= ARMV8_PMU_INCLUDE_EL2;
}
```

这些 `config_base` 位直接写入 `PMEVTYPERn_EL0` 硬件寄存器。**硬件自身根据当前异常级别决定是否对事件计数**。

KVM 创建的 perf_event 设置 `exclude_host=1`，在 VHE 下被翻译为 `EXCLUDE_EL0`。guest 事件不会在 host EL0 上下文计数。

**层面3：KVM 的动态切换（nVHE 路径）**

在 nVHE 中硬件过滤不足以区分，KVM 在 hyp 层做显式切换：

```c
// arch/arm64/kvm/hyp/nvhe/switch.c
static bool __pmu_switch_to_guest(struct kvm_vcpu *vcpu) {
    if (pmu->events_host)
        write_sysreg(pmu->events_host, pmcntenclr_el0);   // 关 host 事件
    if (pmu->events_guest)
        write_sysreg(pmu->events_guest, pmcntenset_el0);   // 开 guest 事件
}
```

### 7.3 perf_event 在该场景下的关键语义

**1. "shadow counting" — 影子计数**

Guest 的 perf_event 不是独占硬件 PMC 的。它和 host 的 perf_event 共享硬件资源。perf 核心负责调度和时分复用。`attr.pinned=1` 保证 guest 事件不被挤出。

**2. "sample_period" 被语义重载**

- 非 KVM 场景："每隔 N 次事件取一次样本"
- KVM 场景："从当前 counter 值到溢出的距离"

**3. overflow_handler 是 KVM 的注入桥梁**

硬件 PMC 溢出 → perf_overflow → `kvm_pmu_perf_overflow()` → `PMOVSSET` → `kvm_vcpu_kick()` → vIRQ 注入

**4. 跨 PMU 实例可迁移**

在异构系统（big.LITTLE）中，vCPU 可能在不同微架构的核心间迁移。perf 子系统通过 `attr.type` 绑定到指定 `arm_pmu` 实例，自动处理 PMU 切换。

### 7.4 总结：perf_event 在这个场景中的一言以蔽之

> **perf_event 是 guest vPMU counter 的"硬件代理"**——它占用一个真实的硬件 PMC 资源，按照 guest 配置的事件类型进行计数，在 guest counter 的理论溢出边界触发回调，并通过 `exclude_host=1` 和 EL 级硬件过滤确保只统计 guest 运行期间的事件。它的 `count` 值是 guest 可见 counter 值的"增量部分"，它的 `overflow_handler` 是硬件 PMU 中断到虚拟 PMU 中断的桥接点。

KVM 没有重新实现 PMU 的计数逻辑——它把"计数"外包给了 perf 子系统，自己只负责：
- **配置翻译**：guest 寄存器 → `perf_event_attr`
- **值管理**：维护 `sys_reg` 基线 + `perf_event` 增量 = guest 可见值
- **中断桥接**：perf overflow → `PMOVSSET` → vGIC injection
- **生命周期管理**：guest 操作 → perf_event 的创建/销毁/启停

---

## 8. Host/Guest 上下文切换

VHE 和 nVHE 模式下的切换策略完全不同。

### 8.1 VHE 模式

VHE 下 host 内核跑在 EL2，guest 跑在 EL1，EL0 被 host 和 guest 复用。

**PMUSERENR_EL0 切换** (Hyp 层，`switch.h`)：

```c
// Guest entry (__activate_traps_common)
ctxt_sys_reg(hctxt, PMUSERENR_EL0) = read_sysreg(pmuserenr_el0); // 保存 host 值
write_sysreg(ARMV8_PMU_USERENR_MASK, pmuserenr_el0);             // 设 guest 值
vcpu_set_flag(vcpu, PMUSERENR_ON_CPU);                             // 标记 guest 值已装载

// Guest exit (__deactivate_traps_common)
write_sysreg(ctxt_sys_reg(hctxt, PMUSERENR_EL0), pmuserenr_el0); // 恢复 host 值
vcpu_clear_flag(vcpu, PMUSERENR_ON_CPU);
```

**EL0 过滤位切换** (`pmu.c`)：

```c
// 进入 guest 时：guest 事件在 EL0 计数，host 事件不计数
void kvm_vcpu_pmu_restore_guest(struct kvm_vcpu *vcpu)
{
    kvm_vcpu_pmu_enable_el0(events_guest);   // 清除 guest 事件的 EXCLUDE_EL0
    kvm_vcpu_pmu_disable_el0(events_host);   // 设置 host 事件的 EXCLUDE_EL0
}

// 退出 guest 时：恢复
void kvm_vcpu_pmu_restore_host(struct kvm_vcpu *vcpu)
{
    kvm_vcpu_pmu_enable_el0(events_host);
    kvm_vcpu_pmu_disable_el0(events_guest);
}
```

**Host perf 更新 PMUSERENR_EL0 的竞态保护**：

host perf 可能通过 IPI 更新 `PMUSERENR_EL0`，而此寄存器在 guest entry 时已被替换为 guest 的值。`kvm_set_pmuserenr()` 检测到 `PMUSERENR_ON_CPU` 标志后将值写入 **host context 的保存副本**，guest exit 时自动恢复。

VHE 路径通过关中断保护 `PMUSERENR_EL0` 读-保存-替换的竞态窗口（`vhe/switch.c`）。

### 8.2 nVHE 模式

nVHE 中没有 EL0 复用问题。切换通过直接操作硬件 `PMCNTENSET/CLR` 实现：

```c
// Guest entry
static bool __pmu_switch_to_guest(struct kvm_vcpu *vcpu) {
    if (pmu->events_host)
        write_sysreg(pmu->events_host, pmcntenclr_el0);   // 禁用 host 事件
    if (pmu->events_guest)
        write_sysreg(pmu->events_guest, pmcntenset_el0);   // 启用 guest 事件
}

// Guest exit
static void __pmu_switch_to_host(struct kvm_vcpu *vcpu) {
    if (pmu->events_guest)
        write_sysreg(pmu->events_guest, pmcntenclr_el0);   // 禁用 guest 事件
    if (pmu->events_host)
        write_sysreg(pmu->events_host, pmcntenset_el0);    // 启用 host 事件
}
```

**事件追踪注册** — host PMU 驱动在配置事件时调用：
- `kvm_set_pmu_events(mask, attr)` — 将事件加入 per-CPU `events_host`/`events_guest` 位图
- `kvm_clr_pmu_events(mask)` — 从位图中移除
- `kvm_pmu_switch_needed(attr)` — 决定是否需要切换（VHE+exclude_user 时不需要）
- `kvm_pmu_counter_deferred(attr)` — nVHE+exclude_host 时跳过直接写入 PMCNTENSET

**per-CPU 事件同步**：
```c
#define kvm_pmu_update_vcpu_events(vcpu)
    do {
        if (!has_vhe() && system_supports_pmuv3())
            vcpu->arch.pmu.events = *kvm_get_pmu_events();
    } while (0)
```
每次 vCPU 运行前（关中断后）从 per-CPU 数据同步到 vCPU 私有副本。

---

## 9. 溢出与中断处理

### 9.1 溢出触发路径

```
硬件 PMU 计数器溢出
  ↓ (perf 子系统)
perf_event_overflow()
  ↓ 调用注册的 overflow_handler
kvm_pmu_perf_overflow(perf_event, data, regs)
  │
  ├─① stop(perf_event, PERF_EF_UPDATE)     // 停掉硬件事件，刷新 count
  │
  ├─② 重新设置 sample_period              // 准备下一轮溢出
  │   period = compute_period(pmc, local64_read(&perf_event->count));
  │   perf_event->attr.sample_period = period;
  │   perf_event->hw.sample_period    = period;
  │
  ├─③ __vcpu_rmw_sys_reg(vcpu, PMOVSSET_EL0, |=, BIT(idx));
  │   设置 vPMU 溢出状态位
  │
  ├─④ 处理 CHAIN 事件
  │   if (kvm_pmu_counter_can_chain(pmc))
  │       kvm_pmu_counter_increment(vcpu, BIT(idx+1), ARMV8_PMUV3_PERFCTR_CHAIN);
  │   // 对配对的偶数 counter+1，可能产生级联溢出
  │
  ├─⑤ 检查是否需要注入中断
  │   if (kvm_pmu_overflow_status(vcpu)) {
  │       kvm_make_request(KVM_REQ_IRQ_PENDING, vcpu);
  │       if (!in_nmi())
  │           kvm_vcpu_kick(vcpu);            // 直接 kick
  │       else
  │           irq_work_queue(&pmu->overflow_work); // NMI 安全延迟
  │   }
  │
  └─⑥ start(perf_event, PERF_EF_RELOAD)     // 重启硬件事件
```

### 9.2 Overflow 状态判断

```c
static bool kvm_pmu_overflow_status(struct kvm_vcpu *vcpu)
{
    u64 reg = __vcpu_sys_reg(vcpu, PMOVSSET_EL0);
    reg &= __vcpu_sys_reg(vcpu, PMINTENSET_EL1);

    // EL1/0 全局使能: PMCR_EL0.E = 1 时所有非 hyp counter 可产生中断
    if (!(PMCR_EL0 & ARMV8_PMU_PMCR_E))
        reg &= kvm_pmu_hyp_counter_mask(vcpu);  // E=0 只 hyp counter 可触发

    // EL2 全局使能: MDCR_EL2.HPME = 1 时 hyp counter 可产生中断
    if (!(MDCR_EL2 & MDCR_EL2_HPME))
        reg &= ~kvm_pmu_hyp_counter_mask(vcpu);

    return reg != 0;  // 任一有效 overflow 条件成立
}
```

### 9.3 NMI 安全的中断注入

perf overflow 回调可能在 NMI 上下文中执行，此时不能直接操作 vCPU：

```c
if (!in_nmi())
    kvm_vcpu_kick(vcpu);       // 直接 kick
else
    irq_work_queue(&vcpu->arch.pmu.overflow_work);  // 延迟执行

// overflow_work 回调 (非 NMI 上下文):
static void kvm_pmu_perf_overflow_notify_vcpu(struct irq_work *work)
{
    struct kvm_vcpu *vcpu = container_of(work, ..., arch.pmu.overflow_work);
    kvm_vcpu_kick(vcpu);
}
```

### 9.4 中断注入到 vGIC

`kvm_pmu_update_state()` 在 guest entry (`kvm_pmu_flush_hwstate`) 和 guest exit (`kvm_pmu_sync_hwstate`) 时被调用：

```c
static void kvm_pmu_update_state(struct kvm_vcpu *vcpu)
{
    overflow = kvm_pmu_overflow_status(vcpu);
    if (pmu->irq_level == overflow)
        return;  // 电平未变，无需操作

    pmu->irq_level = overflow;

    if (likely(irqchip_in_kernel(vcpu->kvm))) {
        ret = kvm_vgic_inject_irq(vcpu->kvm, vcpu,
                                  pmu->irq_num, overflow, pmu);
        // 电平中断: overflow=1 拉高, overflow=0 拉低
    }
}
```

### 9.5 Userspace irqchip 通知

对于 userspace irqchip 的场景，通过 `kvm_run->s.regs.device_irq_level` 的 `KVM_ARM_DEV_PMU` 位通知：

```c
void kvm_pmu_update_run(struct kvm_vcpu *vcpu)
{
    regs->device_irq_level &= ~KVM_ARM_DEV_PMU;
    if (vcpu->arch.pmu.irq_level)
        regs->device_irq_level |= KVM_ARM_DEV_PMU;
}

bool kvm_pmu_should_notify_user(struct kvm_vcpu *vcpu)
{
    // 仅在 userspace irqchip 且电平变化时返回 true
    return pmu->irq_level != run_level;
}
```

### 9.6 软件增量 (PMSWINC)

`PMSWINC_EL0` 的写入不需要经过 perf 子系统，纯软件实现：

```c
void kvm_pmu_software_increment(struct kvm_vcpu *vcpu, u64 val)
{
    kvm_pmu_counter_increment(vcpu, val, ARMV8_PMUV3_PERFCTR_SW_INCR);
}

static void kvm_pmu_counter_increment(struct kvm_vcpu *vcpu,
                                      unsigned long mask, u32 event)
{
    if (!(PMCR_EL0 & ARMV8_PMU_PMCR_E))
        return;

    mask &= __vcpu_sys_reg(vcpu, PMCNTENSET_EL0); // 过滤禁用的 counter

    for_each_set_bit(i, &mask, ARMV8_PMU_CYCLE_IDX) {
        // 过滤事件类型不匹配的 counter
        type = __vcpu_sys_reg(vcpu, PMEVTYPERn);
        if ((type & kvm_pmu_event_mask(kvm)) != event)
            continue;

        // 软件 +1
        reg = __vcpu_sys_reg(vcpu, counter_reg) + 1;
        if (!kvm_pmc_is_64bit(pmc))
            reg = lower_32_bits(reg);
        __vcpu_assign_sys_reg(vcpu, counter_reg, reg);

        // 检查溢出
        if (kvm_pmc_has_64bit_overflow(pmc) ? reg : lower_32_bits(reg))
            continue;  // 未溢出

        // 标记溢出
        __vcpu_rmw_sys_reg(vcpu, PMOVSSET_EL0, |=, BIT(i));

        // CHAIN 事件级联
        if (kvm_pmu_counter_can_chain(pmc))
            kvm_pmu_counter_increment(vcpu, BIT(i + 1),
                                      ARMV8_PMUV3_PERFCTR_CHAIN);
    }
}
```

### 9.7 CHAIN 事件

当偶数 counter 配置 CHAIN 事件且溢出时，自动对配对的奇数 counter (idx+1) 做 +1：

```c
static bool kvm_pmu_counter_can_chain(struct kvm_pmc *pmc)
{
    return (!(pmc->idx & 1)                    // 偶数 counter
            && (pmc->idx + 1) < ARMV8_PMU_CYCLE_IDX  // 有配对的奇数
            && !kvm_pmc_has_64bit_overflow(pmc));     // 32bit 溢出模式
}
```

这意味着 guest 可以将两个 32bit counter 级联为 64bit counter——偶数 counter 溢出时自动将奇数 counter +1。

---

## 10. Event Filter 事件过滤

通过 UAPI `KVM_ARM_VCPU_PMU_V3_FILTER` 实现 guest 可见事件的过滤。

### 10.1 Filter 机制

```c
// 白名单模式: 第一个 filter 是 ALLOW
//   → 默认 bitmap_zero (全禁止)
//   → 只允许 filter 指定的范围
//
// 黑名单模式: 第一个 filter 是 DENY
//   → 默认 bitmap_fill (全允许)
//   → 只禁止 filter 指定的范围

if (!kvm->arch.pmu_filter) {
    kvm->arch.pmu_filter = bitmap_alloc(nr_events, GFP_KERNEL_ACCOUNT);
    if (filter.action == KVM_PMU_EVENT_ALLOW)
        bitmap_zero(kvm->arch.pmu_filter, nr_events);
    else
        bitmap_fill(kvm->arch.pmu_filter, nr_events);
}

if (filter.action == KVM_PMU_EVENT_ALLOW)
    bitmap_set(kvm->arch.pmu_filter, filter.base_event, filter.nevents);
else
    bitmap_clear(kvm->arch.pmu_filter, filter.base_event, filter.nevents);
```

### 10.2 Filter 的影响

1. **perf_event 创建时**：检查事件号是否在 filter 位图中，不在则不创建
2. **PMCEID 返回值**：`kvm_pmu_get_pmceid()` 将 filter 作为掩码裁剪事件位图，让 guest 看不到被过滤的事件
3. **VM 已运行后不可更改**：`kvm_vm_has_ran_once()` 检查阻止运行时修改

---

## 11. 异构系统 PMU 选择

### 11.1 PMU 实例管理

支持多 PMU 实例（big.LITTLE 异构场景），通过全局链表管理：

```c
static LIST_HEAD(arm_pmus);
static DEFINE_MUTEX(arm_pmus_lock);
```

### 11.2 用户态选择 PMU

```c
// KVM_ARM_VCPU_PMU_V3_SET_PMU
kvm_arm_pmu_v3_set_pmu(vcpu, pmu_id)
    → 遍历 arm_pmus 链表查找匹配的 arm_pmu->pmu.type
    → 更新 kvm->arch.arm_pmu
    → 更新 kvm->arch.supported_cpus (PMU 支持的 CPU 集合)
    → 重置 nr_pmu_counters
```

约束：
- VM 已运行后不能更改 PMU（`kvm_vm_has_ran_once` 检查）
- 已有 filter 且改变了 PMU 类型时不能更改

### 11.3 默认 PMU 选择

```c
int kvm_arm_set_default_pmu(struct kvm *kvm)
{
    arm_pmu = kvm_pmu_probe_armpmu();  // 根据当前 CPU 探测
    kvm_arm_set_pmu(kvm, arm_pmu);
}
```

### 11.4 Counter 数量限制

```c
u8 kvm_arm_pmu_get_max_counters(struct kvm *kvm)
{
    if (cpus_have_final_cap(ARM64_WORKAROUND_PMUV3_IMPDEF_TRAPS))
        return 1;  // IMPDEF 系统只给 1 个 counter
    return bitmap_weight(arm_pmu->cntr_mask, ARMV8_PMU_MAX_GENERAL_COUNTERS);
}

// 用户态可限制
KVM_ARM_VCPU_PMU_V3_SET_NR_COUNTERS → kvm_arm_pmu_v3_set_nr_counters()
```

---

## 12. 嵌套虚拟化支持

### 12.1 Counter 归属划分

`MDCR_EL2.HPMN` 将 counter 分为 EL2 (hypervisor) 和 EL1 (guest) 两组：

```c
static u64 kvm_pmu_hyp_counter_mask(struct kvm_vcpu *vcpu)
{
    hpmn = SYS_FIELD_GET(MDCR_EL2, HPMN, __vcpu_sys_reg(vcpu, MDCR_EL2));
    n = vcpu->kvm->arch.nr_pmu_counters;

    // HPMN >= N: 所有 counter 归 EL1
    if (hpmn >= n) return 0;

    // counter [hpmn, n-1] 归 EL2
    return GENMASK(n - 1, hpmn);
}
```

### 12.2 Counter 可见性

```c
u64 kvm_pmu_accessible_counter_mask(struct kvm_vcpu *vcpu)
{
    mask = kvm_pmu_implemented_counter_mask(vcpu);  // 硬件实现的 counter
    if (!vcpu_has_nv(vcpu) || vcpu_is_el2(vcpu))
        return mask;  // 非嵌套 或 运行在 EL2: 全部可见
    return mask & ~kvm_pmu_hyp_counter_mask(vcpu);  // EL1: 隐藏 hyp counter
}
```

### 12.3 嵌套切换过渡

当 guest 在 EL1↔EL2 之间切换时（嵌套场景），需要重新配置 counter 的异常级别过滤：

```c
void kvm_pmu_nested_transition(struct kvm_vcpu *vcpu)
{
    mask = PMCNTENSET_EL0;
    for_each_set_bit(i, &mask, 32) {
        struct kvm_pmc *pmc = kvm_vcpu_idx_to_pmc(vcpu, i);

        // 仅在 EL1 和 EL2 过滤条件不同时才需要重建 perf_event
        if (kvm_pmc_counts_at_el1(pmc) == kvm_pmc_counts_at_el2(pmc))
            continue;

        kvm_pmu_create_perf_event(pmc);  // 用新的过滤条件重建
    }
}
```

### 12.4 EL2 Counter 的全局使能

```c
static bool kvm_pmu_counter_is_enabled(struct kvm_pmc *pmc)
{
    if (!(PMCNTENSET_EL0 & BIT(pmc->idx))) return false;
    if (kvm_pmu_counter_is_hyp(vcpu, pmc->idx))
        return MDCR_EL2 & MDCR_EL2_HPME;  // hyp counter 由 HPME 全局控制
    return PMCR_EL0 & ARMV8_PMU_PMCR_E;    // 普通 counter 由 PMCR.E 控制
}

static bool kvm_pmc_counts_at_el2(struct kvm_pmc *pmc)
{
    // 非 hyp counter 但在 HPMD=1 时: 不在 EL2 计数
    if (!kvm_pmu_counter_is_hyp(vcpu, pmc->idx) && (MDCR_EL2 & MDCR_EL2_HPMD))
        return false;
    return kvm_pmc_read_evtreg(pmc) & ARMV8_PMU_INCLUDE_EL2;
}
```

---

## 13. 完整数据流图

### 13.1 vPMU 配置与计数流程

```
Guest 行为                         KVM 处理                             Perf/HW
─────────────────────────────────────────────────────────────────────────────────
写 PMEVTYPER0=0x08
  │
  ├─ TRAP ──────────▶ access_pmu_evtyper()
  │                    ├─ __vcpu_assign_sys_reg(PMEVTYPER0, 0x08)
  │                    └─ kvm_pmu_create_perf_event(pmc)
  │                         ├─ 读 sys_reg 基线值
  │                         ├─ 构建 attr: config=0x08,exclude_host=1,...
  │                         ├─ sample_period = 到溢出的事件数
  │                         └─ perf_event_create_kernel_counter()
  │                              └─────────────────────────▶ 硬件 PMC 开始计数
  │
  │  ... guest 运行 ...
  │
读 PMEVCNTR0
  │
  ├─ TRAP ──────────▶ access_pmu_evcntr()
  │                    └─ counter = sys_reg + perf_event_read_value()
  │                                                      ↑ 返回 event->count
  │
  │  ... 继续运行，发生溢出 ...
  │
  └────────────────────────────────── kvm_pmu_perf_overflow() ◀── 硬件溢出
                                         ├─ stop(event)    → 刷新 count
                                         ├─ PMOVSSET |= BIT(0)
                                         ├─ kvm_vcpu_kick()
                                         └─ start(event)   → 继续计数
                                              │
  ◀── KVM_REQ_IRQ_PENDING ───────── kvm_vcpu_kick()
  │
  └─ KVM run loop
       ├─ kvm_pmu_update_state()
       │    overflow = PMOVSSET & PMINTENSET & PMCR.E
       │    kvm_vgic_inject_irq(irq, overflow)
       │         └────────────────────────▶ vGIC 拉高中断
       │
  ◀── IRQ ─── guest 中断处理程序
                读 PMOVSSET → 写 PMOVSCLR → 处理溢出
```

### 13.2 Guest entry/exit 的 PMU 状态切换

```
Host 运行中
  │
  ├─ kvm_arch_vcpu_load()
  │   └─ kvm_vcpu_pmu_restore_guest()    [VHE: EL0 过滤位切换]
  │
  ├─ kvm_pmu_update_vcpu_events()         [nVHE: 同步 per-CPU 事件位图]
  │
  ├─ Guest entry (__activate_traps_common)
  │   └─ 保存 host PMUSERENR_EL0 → 写 guest 值
  │
  ├─ [nVHE] __pmu_switch_to_guest()
  │   └─ PMCNTENCLR(host_events) + PMCNTENSET(guest_events)
  │
  ├─ kvm_pmu_flush_hwstate()
  │   └─ kvm_pmu_update_state()          [检查 并注入 pending vIRQ]
  │
  │  ═══════════ Guest 运行 ═══════════
  │
  ├─ kvm_pmu_sync_hwstate()
  │   └─ kvm_pmu_update_state()          [检查 guest 内新溢出的 IRQ]
  │
  ├─ [nVHE] __pmu_switch_to_host()
  │   └─ PMCNTENCLR(guest_events) + PMCNTENSET(host_events)
  │
  ├─ Guest exit (__deactivate_traps_common)
  │   └─ 恢复 host PMUSERENR_EL0
  │
  └─ kvm_arch_vcpu_put()
      └─ kvm_vcpu_pmu_restore_host()     [VHE: 恢复 host EL0 过滤位]
```

---

## 14. 关键设计点总结

| 设计要点 | 说明 |
|---|---|
| **Hybrid 仿真** | guest 写 counter 值时销毁旧 perf_event → 更新 sys_reg → 重建新 perf_event，保证 `sample_period` 正确 |
| **值分离模型** | `counter = sys_reg (基线) + perf_event_read_value() (增量)`，允许 vCPU 调度时硬件 PMU 被 host 接管 |
| **NMI 安全** | perf overflow 可能在 NMI 中，通过 `irq_work_queue()` 延迟 kick vCPU |
| **CHAIN 事件** | 软件实现，counter 溢出后自动 +1 给配对的偶数 counter，支持 32bit×2 级联为 64bit |
| **sample_period 重载** | 不用于 profiling 采样，而是用它表示"到溢出的距离"，控制硬件 PMC 何时触发 overflow |
| **三层 host/guest 隔离** | perf 核心上下文感知 + 硬件 EL 级过滤 + KVM hyp 动态切换 |
| **VHE vs nVHE** | VHE 通过 EL0 过滤位切换；nVHE 通过 PMCNTENSET/CLR 切换 |
| **PMUVer 限制** | 最大支持到 PMUv3p5 (v3.5)，IMPDEF 系统降级为仅 1 个 counter |
| **事件号 Mask** | PMUv3 IMP: 10bit, PMUv3p1+: 16bit |
| **Event Filter 白/黑名单** | 第一个 filter 决定默认策略，影响 perf_event 创建和 PMCEID 返回值 |
| **PMCR.N 动态计算** | 非嵌套取 `nr_pmu_counters`，嵌套 EL1 取 `MDCR_EL2.HPMN` |
| **异构 PMU** | 全局链表管理多 PMU 实例，用户态可指定，vCPU 迁移时 perf 自动处理 |
| **嵌套虚拟化** | HPMN 划分 counter 归属，嵌套过渡时重建 EL1/EL2 过滤不同的 perf_event |
| **电平中断** | PMU IRQ 为电平型：overflow=1 拉高，overflow=0 拉低 |
| **PMUSERENR_EL0 竞态** | VHE 下通过关中断保护，host perf IPI 写入 host context 副本 |
