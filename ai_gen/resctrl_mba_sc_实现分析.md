# resctrl `mba_MBps` (mba_sc) 实现分析

> 分析对象:Intel RDT 的 MBA 软件控制器(mba_sc)在主线 `fs/resctrl/` 通用层 + `arch/x86/kernel/cpu/resctrl/` arch 层的完整实现。
> 分析基线:主线 HEAD(2026-07),通用层位于 `fs/resctrl/`。
> 相关文档:[[ARM64_resctrl_mba_MBps可行性分析]]、[[MPAM驱动与resctrl对接分析]]

---

## 0. 特性定位

Intel RDT MBA 硬件寄存器(`IA32_MBA_THRTL_MSR`)只接受**延迟百分比**(如 50% = 带宽砍半),用户无法直接限 MB/s。且百分比与实际带宽的映射随负载线程数变化(同 10%,1 线程 vs 4 线程实际带宽差 4 倍)。

mba_sc 的解法:**用 MBM 计数器做传感器,构成软件反馈环**,用户给 MB/s 目标,内核每秒测实际带宽并调整 throttle MSR,维持 `实际带宽 < 用户目标`。

**三件套**:传感器(MBM 计数器)+ 执行器(MBA throttle MSR)+ 控制器(通用层反馈环)。

---

## 1. 演进历史(不是单一补丁集)

2018 年 LWN 752439(Vikas Shivappa)的原始补丁集只有 **3 个 patch**,只搭骨架:

| commit | 内容 |
|--------|------|
| `19c635ab24a1` | mount 选项 `-o mba_MBps` 的启用/禁用 |
| `1bd2a63b4f0d` | 初始化 `mbps_val[]` 数组,默认 `U32_MAX` |
| `8205a078ba78` | schemata 文件解析 MB/s 输入 |

后续功能横跨 5 年多作者累加:

| 时间 | 作者 | 关键补丁 | 内容 |
|------|------|---------|------|
| 2018.11 | Babu Moger | `580ebb66cbb3` | vendor check(当时限 Intel) |
| 2020.12 | Xiaochen Shen | `06c5fe9b12dd` | 修 mba_sc 污染 `mbm_local_bytes` 计数 |
| 2022.09 | James Morse | `b045c2158663`/`ff6357bb5002` | 抽象 `supports_mba_mbps()`;`update_mba_bw()` 直接写 MSR |
| 2024.01 | Tony Luck | `c2427e70c163` | **换新 throttle 启发式**(旧 delta_comp 算法 phase change 死锁) |
| 2024.06 | Tony Luck | `ac20aa423052` | SNC 系统禁用 mba_MBps |
| 2024.12 | Tony Luck | `3b49c37a2f46` 等 5 个 | per-CTRL_MON group `mba_MBps_event`;ctrl group 汇总子 mon group 带宽 |
| 2025.03/05 | James Morse | `37bae1756734` 等 | 初始化逻辑从 arch 挪到通用层 |
| 2026.05 | Ben Horgan | `f52abe650241` | **mbm_cntr_assignable 时禁用 mba_sc**(对 MPAM 关键) |

---

## 2. 核心框架(3 个函数 + 1 个定时器)

```
mbm_handle_overflow()      ← 1s 定时器回调 (per L3 mon domain), 自调度
  ├─ mbm_update()
  │    └─ mbm_bw_count()   ← 字节差 ÷ 1M = MB/s, 存 m->prev_bw
  └─ update_mba_bw()       ← 比较 cur_bw vs user_bw, 每次动一档 bw_gran
       └─ resctrl_arch_update_one()  ← 写硬件寄存器
```

### 2.1 定时器注册(三处)

```
① domain 创建时: INIT_DELAYED_WORK(&d->mbm_over, mbm_handle_overflow);   // rdtgroup.c:4478
② mount 时:      mbm_setup_overflow_handler(d, 1000, ...)                 // rdtgroup.c:2897
   └── schedule_delayed_work_on(cpu, &d->mbm_over, 1s)
③ 回调末尾自调度: schedule_delayed_work_on(..., 1000)                      // monitor.c:879
```

注意:`rdt_enable_ctx()` 只做 `set_mba_sc(true)`(设 flag + 初始化 mbps_val),**不启动定时器**;定时器启动在 `rdt_get_tree()` 尾部独立完成,且与 mba_sc 是否开启无关——只要 MBM 可用就跑。

### 2.2 读计数器 → 算 MB/s

```c
// mbm_bw_count()  monitor.c:569
cur_bytes = rr->val;                    // 硬件返回累计字节
bytes = cur_bytes - m->prev_bw_bytes;   // 本次 - 上次 = 1 秒增量
m->prev_bw_bytes = cur_bytes;
m->prev_bw = bytes / SZ_1M;             // → MB/s (定时器间隔恰为 1s)
```

### 2.3 反馈决策

```c
// update_mba_bw()  monitor.c:679
// 输入: cur_bw(实测) / user_bw(目标, mbps_val[closid]) / cur_msr(当前 MSR 值)
// ctrl group 还会累加所有子 mon group 的 prev_bw

if (cur_msr_val > min_bw && user_bw < cur_bw) {
    new_msr_val = cur_msr_val - bw_gran;              // 收紧: 无条件
} else if (cur_msr_val < MAX_MBA_BW &&
           (user_bw > cur_bw * (cur_msr_val + min_bw) / cur_msr_val)) {
    new_msr_val = cur_msr_val + bw_gran;              // 放松: 保守预估
} else {
    return;                                            // 不动
}
resctrl_arch_update_one(r_mba, dom_mba, closid, CDP_NONE, new_msr_val);
```

Intel 参数:`MAX_MBA_BW=100`, `min_bw=10`, `bw_gran=10`,MSR 取 100/90/.../10 十档。

---

## 3. 算法特性

### 3.1 纯 P 控制

每 tick 最多动一档(`bw_gran`),调整量与偏差大小无关 → 从 100→10 或 10→100 需要 9 秒;无积分项(不能加速收敛)、无微分项(不能预判趋势)。本质是带量化(10 档)的阶跃控制。

### 3.2 放松分支的保守预估

`cur_bw × (cur_msr + min_bw)/cur_msr` = 假设带宽随 MSR **线性**、松一档后最坏能涨到的值。只有该预估值仍低于目标才松——防过冲防震荡。公式中 `min_bw` 在 Intel 上恰等于 `bw_gran`,语义上就是松一档后的新 MSR。

### 3.3 两个 regime(重要推论)

松档条件等价于:`cur_msr > cur_bw × min_bw / (user_bw - cur_bw)`。

| 场景 | 松档后 cur_bw 行为 | 结果 |
|------|--------------------|------|
| **throttle 绑定**(负载需求 > 限制) | 按比例涨 → 预估值逼近目标 | 收敛在 target 附近,停住 |
| **throttle 未绑定**(负载需求 < 限制) | 不变 → 预估不变 | **一路漂到 100%(无限制)** |

典型:恒定 1000 MB/s 负载、目标 2000 → 每 tick 预估都低于目标 → 5 秒内漂到 100。**空载(cur_bw=0)同理**。漂到 100 本身无害(throttle 本来就没效果),代价是新的大流量负载进来后从 100 压下去的数秒窗口。

---

## 4. 用户接口

| 接口 | 作用 |
|------|------|
| `mount -o mba_MBps` | 启动:`set_mba_sc(true)` → 设 flag、`mbps_val[*]=U32_MAX`、暴露 `mba_MBps_event` 文件 |
| `schemata` 写 `MB:0=2048` | 只存 `dom->mbps_val[closid]`,**不写 MSR**——写 MSR 是定时器的事(`parse_bw()` 见 ctrlmondata.c:78) |
| `mba_MBps_event` 读写 | per-group 选 `mbm_total_bytes`/`mbm_local_bytes` 作信号源(`rdtgrp->mba_mbps_event`) |
| `mon_data/mbm_*_bytes` 读 | 纯查询原始累计字节数,走 `mon_event_read()`,**不调 mbm_bw_count()**,不污染调节状态 |

---

## 5. 已知问题

1. **控测错位**:MBA 控 L2→L3 出口,MBM 测 L3→Mem 出口,间隔 L3 cache。
   - cache 友好负载(L3 hit 高):L2→L3 被打爆但 MBM≈0 → mba_sc 无感,门全开
   - 负载从内存型转 cache 型:残留的低 MSR 不必要地压 L2↔L3 流量,只能等慢慢松回
2. **1s 采样**:毫秒级尖峰控不住;收敛/恢复最慢 9s。
3. **兼容性禁令**(`supports_mba_mbps()` 五个条件,rdtgroup.c:2535):
   - MBM 必须 enabled
   - MBA 必须 alloc_capable
   - **MBA 必须线性**(`is_mba_linear()`)——AMD 非线性,用不了
   - **MBA ctrl_scope == MBM mon_scope**——SNC 系统用不了
   - **MBM counter 不可 assignable**——mbm_event 模式用不了(**对 MPAM 关键**,见 §6)
4. **无硬件上限感知**:`MBA_MAX_MBPS=U32_MAX` 默认不限制,系统真实带宽上限(通道数/频率/链路)内核不可知,用户目标值纯靠经验。
5. 历史 bug(已修):delta_comp 启发式 phase change 死锁(`c2427e70c163` 换算法);mba_sc 污染 `mbm_local_bytes` 计数(`06c5fe9b12dd`);AMD MBA 硬编码上限过低(`0976783bb123`);SNC 数组越界(`a547a5880cba`);MBM 位宽错误(`2c18bd525c47`/`7517e899e1b8`)。

---

## 6. 构建要点(ARM64/MPAM 落地)

通用层(`fs/resctrl/`)零改动,全部反馈逻辑架构无关。arch 层只需三个钩子:

```c
resctrl_arch_rmid_read()    → MPAM MBWU (MSMON_MBWU) 返回字节计数   ← 传感器缺口
resctrl_arch_update_one()   → 写 MPAMCFG_MBW_MAX                     ← 已实现
is_mba_linear()             → true (MPAM 线性)                       ← 天然满足
```

**最大障碍**:`f52abe650241` 加入的 `!mbm_cntr_assignable` 条件。commit log 明言 MPAM "will use 'mbm_event' mode whenever there are assignable MBM counters"——若 ARM64 MPAM 只能走 mbm_event counter assign 模式,`mount -o mba_MBps` 会被 `supports_mba_mbps()` 直接拒绝。这是策略性互斥,非硬件限制。出路二选一:

- MPAM 走默认 counter 模式(不暴露 `mbm_cntr_assignable`),条件自然通过
- 推动社区修改该互斥条件(需要解决"软件控制器依赖的 counter 可能未被分配"的语义问题)

详细可行性论证见 [[ARM64_resctrl_mba_MBps可行性分析]]。
