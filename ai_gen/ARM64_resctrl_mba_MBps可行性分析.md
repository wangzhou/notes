# ARM64 (MPAM) 支持 resctrl `mba_MBps` 可行性分析

> 分析基线:内核主线,`HEAD` 附近(`fs/resctrl/` 已从 `arch/x86/kernel/cpu/resctrl/` 拆出为架构无关通用层;ARM64 MPAM 驱动位于 `drivers/resctrl/`)。
> 相关文档:[[MPAM驱动与resctrl对接分析]]、[[主线vs_openEuler_MPAM支持对比]]

## 0. 结论(TL;DR)

**能支持,而且基础设施基本铺好了 —— 但当前还用不了。缺口不在 `mba_sc` 反馈环本身,而在它依赖的 MBM 带宽监控尚未接入 MPAM 的 arch 层。**

- `mba_MBps`(MBA 软件控制器 `mba_sc`)的全部反馈环逻辑都在 `fs/resctrl/` **通用层,架构无关**,ARM64 复用即可,**通用层一行都不用改**。
- 启用它的门槛函数 `supports_mba_mbps()` 有 4 个前置条件,ARM64/MPAM **已满足前 3 个**,只差第 4 个:**MBM 带宽事件未 enable**。
- 因此:**ARM64 支持 `mba_MBps` 的前提 == 先支持 MBM 带宽监控(MBWU)**。二者是同一件事的两面。当前 `mount -o mba_MBps` 会被通用层直接拒绝。

---

## 1. `mba_MBps` 是什么(回顾)

resctrl 挂载选项,启用 **MBA 软件控制器 (mba_sc)**:用户在 schemata 里用**绝对带宽 MiBps** 而非硬件百分比来限带宽,内核用 MBM 计数器构成**闭环反馈**,每秒调整硬件 throttle 使 `实际带宽 < 用户指定带宽`。

硬件 MBA 只接受**延迟百分比**,而百分比与实际带宽非线性(同样 10%,单线程组 vs 4 线程组实际带宽可能差 4 倍)。软件环把"百分比"这层对用户隐藏,改用直观的 MBps。

**核心事实:传感器(MBM)+ 执行器(MBA)+ 控制器(通用层反馈环)三件套。ARM64 缺的是传感器。**

---

## 2. 通用层是架构无关的(为什么 ARM64 不用改 `mba_sc`)

`fs/resctrl/` 从 x86 拆出就是为了让 ARM64 MPAM 复用。`mba_sc` 相关逻辑全部在通用层:

| 环节 | 通用层位置 | 说明 |
|---|---|---|
| 挂载选项解析 | `rdtgroup.c` `Opt_mba_mbps` → `set_mba_sc(true)` | 架构无关 |
| 每秒反馈环 | `monitor.c:836 mbm_handle_overflow` → `update_mba_bw` | 架构无关 |
| 带宽计算 | `monitor.c:564 mbm_bw_count`(字节增量/1M) | 架构无关 |
| 控制算法(增/减一档 + 抗抖动) | `monitor.c:730` | 架构无关 |
| 写回硬件 | `resctrl_arch_update_one()`(**arch 接口**) | arch 层已实现(写 `MPAMCFG_MBW_MAX`) |
| 读传感器 | `resctrl_arch_rmid_read()` / counter-assign 接口(**arch 接口**) | **arch 层缺口所在** |

执行器接口 `resctrl_arch_update_one()` MPAM 侧已实现(百分比 → `percent_to_mbw_max()` → 写 `MPAMCFG_MBW_MAX`)。**唯独传感器接口是空的。**

---

## 3. 门槛核对:`supports_mba_mbps()`

`fs/resctrl/rdtgroup.c:2518`:

```c
static bool supports_mba_mbps(void)
{
	struct rdt_resource *rmbm = resctrl_arch_get_resource(RDT_RESOURCE_L3);
	struct rdt_resource *r    = resctrl_arch_get_resource(RDT_RESOURCE_MBA);

	return (resctrl_is_mbm_enabled() &&            /* (4) 传感器：MBM 带宽事件 */
		r->alloc_capable &&                    /* (1) MBA 可分配         */
		is_mba_linear() &&                     /* (2) 线性刻度           */
		r->ctrl_scope == rmbm->mon_scope);     /* (3) 控制域 == 监控域   */
}
```

MPAM 驱动在 `mpam_resctrl_control_init()`(`drivers/resctrl/mpam_resctrl.c:1024`)已处理 MBA 资源:

| # | 条件 | ARM64/MPAM 现状 | 证据 |
|---|---|---|---|
| 1 | `alloc_capable` | ✅ true | `mpam_resctrl.c:1034` |
| 2 | `is_mba_linear()` (`delay_linear`) | ✅ true | `mpam_resctrl.c:1028` |
| 3 | `ctrl_scope == mon_scope` | ✅ 均为 `RESCTRL_L3_CACHE` | `:1026`(MBA ctrl) / `:1098`(L3 mon) |
| 4 | **`resctrl_is_mbm_enabled()`** | ❌ **不满足** | 见第 4 节 |

**前 3 条全绿。** 驱动里甚至有为 `mba_sc` 专门写的适配:`mpam_resctrl_pick_mba()` 选后备 class 时注释明说 *"MBA should correspond as closely as possible for proper operation of mba_sc"*(`mpam_resctrl.c:911`)——**设计时就是奔着 `mba_sc` 去的。**

> 注:`is_mba_linear()` 在 MPAM 语义下天然成立。MPAM `MBW_MAX` 是 0.xxx 定点小数的百分比上限,`bwa_wd` 位定点(见 `mbw_max_to_percent`/`percent_to_mbw_max`,`mpam_resctrl.c:640-676`),百分比刻度本身线性。反馈环按 `bw_gran` 步进对它成立。

---

## 4. 真正的缺口:MBM/MBWU 监控未接入

`resctrl_is_mbm_enabled()` 要求 `mbm_total_bytes` 或 `mbm_local_bytes` 事件被 enable(`rdtgroup.c:127`):

```c
static bool resctrl_is_mbm_enabled(void)
{
	return (resctrl_is_mon_event_enabled(QOS_L3_MBM_TOTAL_EVENT_ID) ||
		resctrl_is_mon_event_enabled(QOS_L3_MBM_LOCAL_EVENT_ID));
}
```

但在 MPAM 驱动里,MBM 带宽这条链路是断的:

### 4.1 只 enable 了缓存占用,没 enable 带宽
`mpam_resctrl_pick_counters()`(`mpam_resctrl.c:949`)遍历 class,**仅对 CSU(缓存占用)**调:
```c
counter_update_class(QOS_L3_OCCUP_EVENT_ID, class);   // :980
```
从不给 `QOS_L3_MBM_LOCAL/TOTAL_EVENT_ID` 设 backing class。于是这两个事件的 `mon_event_all[].enabled` 恒为 false → `resctrl_is_mbm_enabled()` 恒 false。

### 4.2 读带宽的 arch 接口全是空桩
- `resctrl_arch_rmid_read()`(`mpam_resctrl.c:499`)**只认** `QOS_L3_OCCUP_EVENT_ID`,其它一律 `-EINVAL`(`:521`)。函数头注释挑明:*"MBWU when not in ABMC mode (not supported), and CSU counters."*(`:498`)
- `resctrl_arch_cntr_read()` 直接 `return -EOPNOTSUPP`(`:134`)
- `resctrl_arch_mbm_cntr_assign_enabled()` 硬编码 `return false`(`:141`)
- `resctrl_arch_mbm_cntr_assign_set()` 直接 `return -EINVAL`(`:146`)

**后果:此刻 ARM64 上 `mount -o mba_MBps` 被通用层拒绝,报错**
`"mba_MBps requires MBM and linear scale MBA at L3 scope"`(`rdtgroup.c:2940`)。

---

## 5. 为什么卡在这:MPAM 监控模型 ≠ x86 传统模型

这不是没人做,而是 MPAM 的监控语义天然更复杂,必须走"计数器分配 (counter-assign)"这条路:

| 维度 | x86 传统 MBM | ARM64 MPAM MBWU |
|---|---|---|
| RMID/监控组 | RMID 只是标签,任意时刻可选任意 RMID 读一个持续累加的计数器 | 监控器(MBWU monitor)是**有限物理资源** |
| 分配方式 | 无需分配 | 须先把 PARTID+PMG **绑定**到某个 monitor 才能读 |
| 资源数量 | 计数器随 RMID 数走 | `num_mbwu_mon`,经 `ida_mbwu_mon` 分配(`mpam_internal.h:205/309`) |
| 对应 x86 特性 | 传统 MBM | 等价于 x86 后引入的 **ABMC(可分配带宽计数器)** |

**MPAM 的 MBWU 模型 ≈ x86 ABMC**,所以接 MBM 必须复用/实现 counter-assign 那套接口,而不是照抄传统 MBM。

### 上游方向已对准
- Kconfig `ARM64_MPAM_RESCTRL_FS` 已 `select RESCTRL_ASSIGN_FIXED` + `RESCTRL_RMID_DEPENDS_ON_CLOSID`(`drivers/resctrl/Kconfig`)——正是 counter-assign 模型需要的开关。
- 设备层已探测并记录 MBWU 能力:`mpam_feat_msmon_mbwu`、`num_mbwu_mon`、长计数器 31/44/63、`rwbw` 等(`mpam_devices.c:916-934`;特性枚举 `mpam_internal.h:184-189`)。
- 分配器 `mpam_alloc_mbwu_mon()` / `mpam_free_mbwu_mon()` 已存在(`mpam_internal.h:431-445`)。

**硬件能力探测 + 框架接口 + 分配器都在位,只差 `mpam_resctrl.c` 这层把 MBWU 通过 counter-assign 路径接出来。**

---

## 6. 启用 `mba_MBps` 需要做的工作(全部在 arch 层)

按依赖顺序:

1. **让 MBM 事件获得 backing class**
   在 `mpam_resctrl_pick_counters()` 中,仿照现有 CSU 逻辑,用 `mpam_has_feature(mpam_feat_msmon_mbwu, ...)` 判定后,对 `QOS_L3_MBM_LOCAL/TOTAL_EVENT_ID` 调 `counter_update_class()` + `resctrl_enable_mon_event()`,使 `resctrl_is_mbm_enabled()` 变真。

2. **实现 counter-assign 读取路径**
   填实 `resctrl_arch_mbm_cntr_assign_enabled/set()` 与 `resctrl_arch_cntr_read()`:用 MBWU 监控器 + `MPAMCFG_MON_SEL` 选中目标 monitor,读带宽字节数返回给通用层。

3. **管理"监控器数量 < 监控组数量"**
   MBWU monitor 有限,须做分配/回收/复用(这是 MPAM 接 MBM 的固有难点;x86 ABMC 已有对应管理框架可参考对照)。

做完第 1、2 步,`supports_mba_mbps()` 四条件即全满足,**通用层 `mba_sc` 反馈环会自动开始工作**(`update_mba_bw` → `resctrl_arch_update_one` 写 `MPAMCFG_MBW_MAX`),无需改任何 `mba_sc` 代码。

---

## 7. 隐含前提与风险

1. **反馈环每秒都要读到每组 MBM**
   `mba_sc` 反馈环挂在 MBM 溢出定时器上,每秒读一次每个 CTRL_MON 组(含所有子 mon 组之和,`monitor.c:709`)。若 MBWU monitor 不够覆盖所有活跃组,反馈环会拿不到数据 → 环失效。这是"接入 MBM"本身的复杂度,不是 `mba_sc` 的额外负担。

2. **`bw_gran` 台阶可能很粗**
   `get_mba_granularity()`(`mpam_resctrl.c:613`)= `DIV_ROUND_UP(100, 1 << bwa_wd)`。若硬件 `bwa_wd` 很小(1 bit = 50% 台阶),反馈环步进过粗,收敛差/振荡。取决于具体 SoC 的 `MPAMF_MBW_IDR.BWA_WD`。

3. **收敛慢 + 尽力而非硬保证**(继承自 `mba_sc` 本身)
   每秒一档,从 100% 收到目标需数十秒;突发流量在下一次采样前不受控。

4. **后备 class 拓扑匹配**
   `mba_sc` 要求测量点(MBM/L3 出口)与控制点(MBA)拓扑贴合。`pick_mba()` 的 `topology_matches_l3()` / `traffic_matches_l3()`(`mpam_resctrl.c:900-907`)已做此保证;若平台上 MBA 后备 class 不满足,MBA 本身就不会 alloc_capable,`mba_MBps` 自然也不可用。

---

## 8. 一句话给决策者

> `mba_MBps` 在 ARM64 上**不是"新增一个特性",而是"MPAM 接入 MBM 带宽监控 (MBWU/counter-assign) 的自然副产品"**。通用层反馈环、MBA 执行器、硬件能力探测都已就绪;把 MBWU 读取通过 counter-assign 接口接出来,`mba_MBps` 即随之点亮,零通用层改动。工作量与风险集中在"MPAM 稀缺监控器的分配管理"这一 MPAM 固有难题上。

---

## 附:关键代码坐标速查

| 主题 | 文件:行 |
|---|---|
| 门槛函数 `supports_mba_mbps()` | `fs/resctrl/rdtgroup.c:2518` |
| `resctrl_is_mbm_enabled()` | `fs/resctrl/rdtgroup.c:127` |
| 挂载拒绝报错串 | `fs/resctrl/rdtgroup.c:2940` |
| 反馈环入口 `mbm_handle_overflow` | `fs/resctrl/monitor.c:836` |
| 控制算法 `update_mba_bw` | `fs/resctrl/monitor.c:674` |
| 带宽计算 `mbm_bw_count` | `fs/resctrl/monitor.c:564` |
| MPAM MBA 资源初始化 | `drivers/resctrl/mpam_resctrl.c:1024` |
| MPAM 选 MBA 后备 class(注释提 mba_sc) | `drivers/resctrl/mpam_resctrl.c:870/911` |
| MPAM 选监控 class(仅 CSU) | `drivers/resctrl/mpam_resctrl.c:949/980` |
| `resctrl_arch_rmid_read`(只认 CSU) | `drivers/resctrl/mpam_resctrl.c:499/521` |
| counter-assign 空桩 | `drivers/resctrl/mpam_resctrl.c:134/141/146` |
| MBWU 能力探测 | `drivers/resctrl/mpam_devices.c:916` |
| MBWU 分配器 | `drivers/resctrl/mpam_internal.h:431` |
| Kconfig(select ASSIGN_FIXED) | `drivers/resctrl/Kconfig` |
