# mpam_resctrl_res 相关数据结构分析

基于 `/home/wz/oe_kernel/drivers/platform/mpam/` 代码重新整理。

---

## 数据结构层次

```
mpam_class                    <-- 一类MPAM设备 (cache/memory/IOMMU)
  +-> components              <-- 该类下的所有component链表
        |
        v
mpam_component                <-- 一组应统一配置的MSC/RIS
  +-> ris                     <-- 该component下所有mpam_msc_ris链表
  +-> cfg[]                   <-- 按partid索引的配置数组
  +-> class                   <-- 指回所属的mpam_class
        |
        v
mpam_msc_ris                  <-- 一个MSC上的一种资源类型
  +-> msc                     <-- 指回所属的mpam_msc
  +-> comp                    <-- 指回所属的mpam_component
  +-> props                   <-- 该RIS支持的feature和规格
```

## 和resctrl的对接层

```
mpam_resctrl_res              <-- 表示一种"资源类型" (如L3/MB)
  +-> class                   <-- 指向对应的mpam_class
  +-> resctrl_res             <-- 内嵌struct rdt_resource，注册到resctrl核心
        |
        | (1:N, 通过resctrl_res.domains链表关联)
        v
mpam_resctrl_dom              <-- 表示一个"控制域" (schemata中的一行)
  +-> comp                    <-- 指向对应的mpam_component
  +-> resctrl_dom             <-- 内嵌struct rdt_domain，注册到resctrl核心
```

## 全局数组

```c
// mpam_resctrl.c:33
static struct mpam_resctrl_res mpam_resctrl_exports[RDT_NUM_RESOURCES];
```

`resctrl_res_level` 枚举 (resctrl_types.h:82):
| 索引 | 枚举值 | 资源名 | 控制类型 |
|------|--------|--------|----------|
| 0 | RDT_RESOURCE_L3 | L3 | CPOR (cache portion bitmap) |
| 1 | RDT_RESOURCE_L2 | L2 | CPOR |
| 2 | RDT_RESOURCE_MBA | MB | MBW_PART or MBW_MAX |
| 3 | RDT_RESOURCE_SMBA | - | (x86软MBA, ARM不使用) |
| 4 | RDT_RESOURCE_L3_MAX | L3MAX | CMAX (cache max capacity) |
| 5 | RDT_RESOURCE_L2_MAX | L2MAX | CMAX |
| 6 | RDT_RESOURCE_L3_MIN | L3MIN | CMIN (cache min capacity) |
| 7 | RDT_RESOURCE_L2_MIN | L2MIN | CMIN |
| 8 | RDT_RESOURCE_MB_MIN | MBMIN | MBW_MIN |
| 9 | RDT_RESOURCE_L3_PRI | L3PRI | INTPRI |
| 10 | RDT_RESOURCE_L2_PRI | L2PRI | INTPRI |
| 11 | RDT_RESOURCE_MB_PRI | MBPRI | INTPRI |
| 12 | RDT_RESOURCE_MB_HDL | MBHDL | MAX_LIMIT (hard limit) |

## mpam_component 的语义

`mpam_component` 表示"应统一配置的一组MSC/RIS"：

- 对于 **cache**：component_id 来自 ACPI PPTT 表的 cache_reference，唯一标识一个
  特定缓存实例（如某个 socket 上的 L3）。同一 cache 下的所有 MSC 共享一个 component。
- 对于 **memory**：component_id 来自 proximity_domain 转换的 NUMA node ID。
  同一 NUMA node 上的多个内存控制器属于同一个 component。

一个 component 映射到 resctrl 的一个 domain（schemata 中的一行，
如 `L3:0=ffff`），是该 domain 的物理配置单元。

与 MSC 的关系：一般一个 component 只包含一个 MSC 的 RIS，但多个内存控制器在
同一 NUMA node 时，一个 component 会包含多个 MSC 的 RIS。

## 初始化流程

入口: `mpam_resctrl_setup()` (mpam_resctrl.c:1148)

```
mpam_resctrl_setup
  |
  |-- 初始化 mpam_resctrl_exports[] 所有槽位
  |   (rid = 索引值, domains/evt_list 置空)
  |
  |-- mpam_resctrl_pick_caches()    <-- 挑选cache类
  |    遍历 mpam_classes 链表, 对每个 type==MPAM_CLASS_CACHE 的 class:
  |      - 检查 level 是否为 2/3
  |      - 检查 feature (CPOR/CMAX/CMIN/INTPRI) 是否可用
  |      - 检查 affinity 是否覆盖所有 possible CPU
  |      - 按 level 和 feature 填入 exports[] 对应槽位:
  |          has_cpor  → L2/L3
  |          has_cmax  → L2MAX/L3MAX
  |          has_cmin  → L2MIN/L3MIN
  |          has_intpri → L2PRI/L3PRI
  |
  |-- mpam_resctrl_pick_mba()       <-- 挑选memory类
  |    遍历 mpam_classes 链表, 对每个 level>=3 的 class:
  |      - 检查 feature (MBW_PART/MBW_MAX/MBW_MIN/INTPRI/MAX_LIMIT) 是否可用
  |      - 填入 exports[] 对应槽位:
  |          has_mba     → MBA
  |          has_mbw_min → MBMIN
  |          has_intpri   → MBPRI
  |          has_limit    → MBHDL
  |
  |-- 对每个 class!=NULL 的槽位:
        mpam_resctrl_resource_init(res)
          根据 class->props 配置 rdt_resource:
            - format_str, schema_fmt, fflags
            - cache.cbm_len / membw.bw_gran / membw.max_bw 等
            - alloc_capable / mon_capable
```

**关键点**：每种 resource type (如 L3 和 L3MAX) 可以指向**同一个** mpam_class。
例如，一个同时支持 CPOR 和 CMAX 的 L3 cache class，会同时被填入
`exports[RDT_RESOURCE_L3]` 和 `exports[RDT_RESOURCE_L3_MAX]`，
两者的 `class` 指针指向同一个 mpam_class。

## CPU online 设计原理

MPAM 驱动必须依赖 CPU hotplug 回调，而不是仅在初始化时一次性配置，原因有两个
硬件约束：

**约束1：MSC 和 CPU 共享 power domain**

MSC 的寄存器是 MMIO，和 CPU 共享电源域。CPU 深度休眠（idle/cpuoff）时 MSC
也掉电，所有寄存器状态——PARTID 配置、monitor 配置、monitor 内部计数器——
全部丢失。CPU 唤醒后必须从软件缓存恢复 MSC 的全部寄存器。这就是为什么
`mpam_reprogram_msc()` 需要遍历所有 partid 逐个重写寄存器，并且恢复
MBWU monitor 状态。

**约束2：不是所有 CPU 都能访问所有 MSC**

每个 MSC 有 `accessibility` cpumask，标明哪些 CPU 能访问它的 MMIO 寄存器。
一个 socket/cluster 上的 MSC 只能由同 cluster 的 CPU 访问。因此 CPU online/offline
时，驱动需要通过 `accessibility` 判断该 CPU 关联了哪些 MSC，只恢复/重置
相关的那些。

### 为什么需要两个 cpuhp 回调

驱动注册了两次 cpuhp 回调，分别在 `mpam_enable()` 前后，对应两个阶段：

**Phase 1: 发现阶段 — `mpam_discovery_cpu_online`**
```
mpam_discovery_cpu_online(cpu)                  // 条件: !mpam_is_enabled()
  |
  |-- 遍历 mpam_all_msc, 找到该 CPU 能访问但还没 probed 的 MSC:
  |     mpam_msc_hw_probe(msc)                  // 读 ID 寄存器, 确定 feature/规格
  |
  |-- if (所有固件声明的 MSC 都已 probed)
  |     schedule_work(&mpam_enable_work)        // 触发 mpam_enable()
  |
  |-- return mpam_cpu_online(cpu)               // 如果已经 enable, 走恢复流程
```

启动时并非所有 MSC 都立即可访问——MSC 作为平台设备由 ACPI/DT 创建，某些
MSC 要等到所属 CPU cluster 第一次 online 才能被探到。`mpam_partid_max` 和
`mpam_pmg_max` 需要取所有 MSC 的最小值，只有全部 probe 完毕才能确定。这个
阶段每次有新的 MSC 被 probe，都触发一次 `mpam_enable_work` 重新合并 feature。

**Phase 2: 运行阶段 — `mpam_cpu_online`**
```
mpam_cpu_online(cpu)                            // 条件: mpam_is_enabled()
  |
  |-- 遍历 mpam_all_msc, 对 accessibility 包含该 CPU 的 MSC:
  |     _enable_percpu_irq()                    // 重新 enable percpu 错误中断
  |     if (atomic_fetch_inc(&msc->online_refs) == 0):
  |         mpam_reprogram_msc(msc)             // 首次在线 CPU: 全量恢复
  |           遍历所有 partid, 重写 CPBM/CMAX/MBW_MAX 等寄存器
  |           恢复 MBWU monitor 状态
  |
  |-- mpam_resctrl_online_cpu(cpu)              // 创建/更新 resctrl domain
```

`msc->online_refs` 是引用计数，追踪有多少个能访问该 MSC 的 CPU 在线。
第一个 CPU 上线（0→1）时做全量恢复，最后一个 CPU 下线（1→0）时 reset MSC。

对应地，`mpam_cpu_offline` 的递减逻辑：
```
mpam_cpu_offline(cpu)
  |-- 对 accessibility 包含该 CPU 的 MSC:
  |     disable_percpu_irq()                    // disable percpu 错误中断
  |     if (atomic_dec_and_test(&msc->online_refs) == 0):
  |         mpam_reset_msc(msc, false)          // 最后一个 CPU 离线: 复位
  |           所有 RIS 回归复位状态, 保存 MBWU monitor 状态
  |
  |-- mpam_resctrl_offline_cpu(cpu)
```

### 回调切换的时机

`mpam_enable()` (mpam_devices.c:2416-2430) 在两个阶段之间切换：

```
cpuhp_remove_state(mpam_cpuhp_state)             // 1. 摘掉 discovery 回调
spin_lock(&partid_max_lock)
partid_max_published = true                       // 2. 冻结 partid/pmg 上限
spin_unlock(&partid_max_lock)
static_branch_enable(&mpam_enabled)               // 3. 置全局使能标志
mpam_register_cpuhp_callbacks(mpam_cpu_online)    // 4. 换上正式运行回调
```

发生在所有 MSC probed、feature 合并完毕、IRQ 注册完毕、`mpam_resctrl_setup()`
创建 resctrl 文件系统之后。`partid_max_published = true` 之后 `mpam_partid_max`
不再变化，`mpam_discovery_cpu_online` 入口的 `if (mpam_is_enabled()) return 0`
直接短路，不再做 discovery。

## Domain 创建流程

`mpam_resctrl_online_cpu()` (mpam_resctrl.c:1526)，由上面的 cpuhp 回调调用：

```
mpam_resctrl_online_cpu(cpu)
  |
  遍历 mpam_resctrl_exports[]:
    |-- mpam_get_domain_from_cpu(cpu, res)
    |     遍历 res->resctrl_res.domains, 检查 domain 的 comp->affinity
    |     是否包含该 CPU → 如果已有 domain, 直接 set_cpu 到 cpu_mask
    |
    |-- mpam_resctrl_alloc_domain(cpu, res)  <-- 没有则新建
    |     遍历 res->class->components:
    |       找到 comp->affinity 包含该 CPU 的 component
    |     分配 mpam_resctrl_dom
    |       dom->comp = comp
    |       dom->resctrl_dom.id = comp->comp_id
    |     加入 res->resctrl_res.domains 链表
    |
    |-- resctrl_online_domain(&res->resctrl_res, &dom->resctrl_dom)
          向 resctrl 核心注册, 创建 sysfs 文件
```

**关键点**：domain 的创建时机是 CPU online，不是初始化时一次性创建。
每个 CPU 上线时，检查该 CPU 所属的 component 是否已有对应 domain，
没有就新建一个。domain 和 CPU 的绑定关系通过 `comp->affinity` 确定。

## 写 schemata 的调用链

```
用户写 /sys/fs/resctrl/<group>/schemata
  |
  v
resctrl_arch_update_one(r, d, closid, type, cfg_val)  // mpam_resctrl.c:1307
  |
  |-- container_of(r, mpam_resctrl_res, resctrl_res)  → res
  |-- container_of(d, mpam_resctrl_dom, resctrl_dom)  → dom
  |-- 根据 r->rid 确定 configured_by (cpbm/cmax/cmin/mbw_max/...)
  |-- 将用户百分比值转换为硬件格式
  |     (percent_to_mbw_max / percent_to_ca_max / percent_to_mbw_pbm ...)
  |-- 如果 CDP 隐藏: 对 CDP_CODE 和 CDP_DATA 两个 partid 分别写
  |
  v
mpam_apply_config(comp, partid, &cfg)  // mpam_devices.c:2558
  |
  |-- comp->cfg[partid] = *cfg          <-- 更新软件缓存
  |-- 遍历 comp->ris:
       对每个 ris → mutex_lock(ris->msc->lock)
                → mpam_touch_msc(ris->msc, __write_config, &arg)
                  写 MSC 硬件寄存器 (MPAMCFG_CPBM/CMAX/MBW_MAX 等)
                → mutex_unlock(ris->msc->lock)
```

**关键点**：
1. 配置先更新到 `comp->cfg[partid]`（软件缓存），再遍历该 component 下的
   **所有 RIS** 写硬件寄存器。这保证了同一 component 下的所有 MSC 配置一致。
2. 硬件寄存器写入需要持有 `msc->lock` 互斥锁，因为多个 partid 的配置可能
   并发写入同一 MSC。
3. CPU offline 时，`mpam_resctrl_offline_cpu()` 从 domain 的 cpu_mask 中清除该 CPU，
   如果 domain 的 cpu_mask 变空，则调用 `resctrl_offline_domain()` 移除整个 domain。

## 数据结构关系总图

```
mpam_resctrl_exports[] (静态全局数组, 按资源类型索引)
|
|-- [RDT_RESOURCE_L3]  mpam_resctrl_res
|     +-- class ─────────────────────────→ mpam_class (L3 cache)
|     +-- resctrl_res (rdt_resource)        +-- components ──→ mpam_component (L3 on socket0)
|           +-- domains ──→ rdt_domain            +-- ris ──→ mpam_msc_ris (MSC0's L3 RIS)
|                            (embedded in)         +-- ris ──→ mpam_msc_ris (MSC1's L3 RIS, 如果有)
|                            mpam_resctrl_dom      +-- cfg[partid] (配置缓存)
|                              +-- comp ─────────→ mpam_component
|                              +-- resctrl_dom (id=comp_id, cpu_mask)
|
|-- [RDT_RESOURCE_L3_MAX]  mpam_resctrl_res
|     +-- class ─────────────────────────→ (同一个 mpam_class)
|     +-- resctrl_res (另一个 rdt_resource, 不同的 schema 格式)
|           +-- domains ──→ (同样的 domain 结构, 但独立维护)
|
|-- [RDT_RESOURCE_MBA]  mpam_resctrl_res
      +-- class ─────────────────────────→ mpam_class (memory)
      +-- resctrl_res (rdt_resource)
            +-- domains ──→ mpam_resctrl_dom
                              +-- comp ─────────→ mpam_component (NUMA node0)
                                                    +-- ris ──→ mpam_msc_ris (memory controller)
```

**核心关系**：
- `mpam_resctrl_res : mpam_class = N : 1`（多种资源类型可共享一个 class）
- `mpam_resctrl_dom : mpam_component = 1 : 1`（每个 domain 对应唯一 component）
- `mpam_component : mpam_msc_ris = 1 : N`（一个 component 聚合多个 MSC 的 RIS）
- `mpam_class : mpam_component = 1 : N`（一类资源跨多个物理域）

## 控制组、监控组与 domain 的关联

resctrl 核心层（fs/resctrl/）定义了用户可见的组结构，与 MPAM 驱动的 domain 对接。

### 核心数据结构（resctrl 核心层）

```
rdtgroup                        // 用户创建的目录 /sys/fs/resctrl/<name>
  +-> closid                    // = PARTID，控制组标识
  +-> cpu_mask                  // 分配到该组的 CPU
  +-> type                      // RDTCTRL_GROUP 或 RDTMON_GROUP
  +-> mon.rmid                  // = PMG，监控组标识
  +-> mon.parent                // 父 rdtgroup（监控组指向其控制组）
  +-> mon.crdtgrp_list          // 子监控组链表

rdt_domain                      // 资源的一个物理实例
  +-> id                        // = comp_id，如 socket 上的 L3 编号
  +-> cpu_mask                  // 属于该 domain 的 CPU
  +-> staged_config[CDP_NUM_TYPES]
  |     +-> new_ctrl            // 用户写入的待生效配置
  |     +-> have_new_ctrl
  +-> mbm_total[]               // 按 rmid 索引的带宽监控状态
  +-> mbm_local[]

rmid_entry                      // RMID 分配追踪
  +-> closid                    // 该 RMID 所属的 CLOSID
  +-> rmid                      // RMID 值
  +-> busy                      // 多少 domain 还在使用此 RMID
```

### 两种组类型

**控制组** — 在 resctrl 根目录下创建，`rdtgroup_mkdir_ctrl_mon()`：
```
mkdir /sys/fs/resctrl/foo
  → closid_alloc()              // 分配新的 PARTID
  → alloc_rmid(closid)          // 分配新的 PMG，存入 rdtgrp->mon.rmid
  → 创建 mon_groups/ 目录       // 可在此创建子监控组
  → 创建 mon_data/ 目录         // 每个 (resource, domain) 一个子目录
```

**监控组** — 在 `mon_groups/` 下创建，`rdtgroup_mkdir_mon()`：
```
mkdir /sys/fs/resctrl/foo/mon_groups/bar
  → rdtgrp->closid = parent->closid  // 继承父组的 PARTID
  → alloc_rmid(closid)               // 分配独立的 PMG
  → 创建 mon_data/ 目录
  → list_add_tail(&rdtgrp->mon.crdtgrp_list, &parent->mon.crdtgrp_list)
```

关键区别：监控组**共享**父控制组的 closid（所以资源配置相同），但有**独立**的 rmid（所以监控数据隔离）。本质上，控制组提供 (closid, rmid) 组合，监控组复用 closid 但提供新的 rmid，形成 (closid, rmid') 的新监控端点。

### mon_data 目录按 domain 展开

每个 rdtgroup 的 `mon_data/` 下，遍历该资源的所有 domain，为每个 domain 创建一个子目录：

```
/sys/fs/resctrl/foo/mon_data/
├── mon_L3_00/           ← r=rdt_resource(L3), d->id=0 (对应 component comp_id=0)
│   ├── llc_occupancy
│   ├── mbm_total_bytes
│   └── mbm_local_bytes
├── mon_L3_01/           ← 同一 resource, domain 1
├── mon_MB_00/           ← r=rdt_resource(MB), domain 0
```

`mkdir_mondata_subdir()` (rdtgroup.c:3077) 按 `mon_<r->name>_<d->id>` 命名。
每个事件文件通过 `mon_data_bits.priv` 编码了 `{rid, evtid, domid}`，
读操作时解码出对应的 resource、event 和 domain。

### 控制路径：schemata → domain 的映射

用户写 `L3:0=ffff;1=ffff` 时：

```
schemata 解析
  |
  |-- 通过 resctrl_schema.name="L3" 找到 schema
  |     schema->res = &mpam_resctrl_exports[RDT_RESOURCE_L3].resctrl_res
  |
  |-- 解析 domain_id=0 → resctrl_arch_find_domain(r, 0)
  |     遍历 r->domains, 找 dom->comp->comp_id == 0 的 rdt_domain
  |     → 写入 dom->staged_config[].new_ctrl, have_new_ctrl = true
  |
  v
resctrl_arch_update_domains(r, closid)
  遍历 r->domains:
    resctrl_arch_update_one(r, d, closid, type, staged_config->new_ctrl)
      → dom = container_of(d, mpam_resctrl_dom, resctrl_dom)
      → mpam_apply_config(dom->comp, partid, &cfg)
        遍历 comp->ris: 写 MSC 硬件寄存器
```

映射链：`schemata 中的 "L3:0" → (r=resctrl_res, d->id=comp_id) + rdtgroup.closid → mpam_apply_config(comp, partid, cfg)`

### 监控路径：mon_data → domain 的映射

用户读 `mon_data/mon_L3_00/llc_occupancy` 时：

```
mon_event_read(rr, r, d, rdtgrp, evtid, first)
  |
  |-- r = 从 mon_data_bits.priv 解码出 resource (rid)
  |-- d = 从 mon_data_bits.priv 解码出 domain (domid)
  |-- closid = rdtgrp->closid
  |-- rmid   = rdtgrp->mon.rmid
  |
  v
resctrl_arch_rmid_read(r, d, closid, rmid, evtid, val, arch_mon_ctx)
  → dom = container_of(d, mpam_resctrl_dom, resctrl_dom)
  → res = container_of(r, mpam_resctrl_res, resctrl_res)
  → 根据 num_mon 计算 mon instance: cfg.mon = closid % num_mon
  → mpam_msmon_read(dom->comp, &cfg, type, val)
     mon instance 选择寄存器, 过滤 PARTID=closid 和 PMG=rmid, 读 counter
```

映射链：`mon_data/mon_L3_00/llc_occupancy → (resource, domain, event) + (closid, rmid) → mpam_msmon_read(comp, {partid, pmg, mon}, type, val)`

### RMID 分配与回收

```
alloc_rmid(closid)
  +-> resctrl_find_free_rmid()
       从 rmid_free_lru 取可用的 rmid_entry
  +-> entry->closid = closid
  +-> entry->rmid = index
  +-> rdtgrp->mon.rmid = entry->rmid

free_rmid(closid, rmid)
  +-> 检查 entry->busy（多少 domain 还在用这个 RMID 的缓存数据）
  +-> busy==0 → 放回 rmid_free_lru
  +-> 否则 → 进入 limbo 状态，等 occupancy 降到阈值以下再回收
```

RMID 按 closid 隔离管理：每个 closid 有自己的 dirty RMID 计数
（`closid_num_dirty_rmid[closid]`）。MPAM 硬件中 monitor 过滤靠
(PARTID, PMG) 组合，因此 RMID 在不同 closid 之间实际上可以复用，
但 resctrl 核心以 rmid_idx = (closid << pmg_shift) | rmid 编码全局唯一索引。

### 整体映射总图

```
/sys/fs/resctrl/
│
├── (根组)  rdtgroup_default
│     closid = 0 (保留)
│     mon.rmid = 0
│
├── foo/    rdtgroup (RDTCTRL_GROUP)
│     closid = 1  ────────────────→ PARTID=1 ──→ 所有 domain 的 staged_config[1]
│     mon.rmid = 1  ──────────────→ PMG=1
│     │
│     ├── schemata  ← 写 "L3:0=ffff"
│     │     → rdt_resource(L3).domains → d->id=0
│     │     → staged_config[1].new_ctrl = 0xffff
│     │     → mpam_apply_config(comp_id=0, partid=1, cfg)
│     │
│     ├── mon_data/
│     │   ├── mon_L3_00/llc_occupancy  ← 读
│     │   │     → (r=L3, d->id=0, closid=1, rmid=1)
│     │   │     → mpam_msmon_read(comp_id=0, {partid=1, pmg=1}, ...)
│     │   └── mon_L3_01/  ← 另一个 domain
│     │
│     └── mon_groups/
│           └── bar/  rdtgroup (RDTMON_GROUP)
│                 closid = 1  ← 继承 foo
│                 mon.rmid = 2  ← 独立 PMG
│                 └── mon_data/mon_L3_00/llc_occupancy
│                       → (closid=1, rmid=2) ← 与控制组不同的监控端点
```
