# resctrl 带宽控制/监控泛化:三个在飞 patchset 详解(Generic schema · MPAM MB_NODE emulation · ABMC)

> **生成时间**:2026-07-20(2026-07-21 更新:补入 NVIDIA MB_NODE 系列一手 cover)
> **基准树**:本地 Linux **v7.2-rc4**;补丁 cover letter 均取自 lore/lkml 一手原文(经可读镜像 `lkml.iu.edu/hypermail` 抓取,`lore.kernel.org` 本身被 Anubis 反爬)
> **主文档**:`主线MPAM_resctrl现状与RDT中心化设计争议.md`(本篇是其 §3.0 的展开)

---

## 0. 这三个 patchset 是一回事的三个层

用户关注的三个系列,本质是**同一件事的三层**:让 resctrl 从"为 Intel RDT(Xeon)写死的单一控制、单一百分比、L3-中心"泛化成"能表达 MPAM(及 RISC-V)更丰富的带宽控制/监控,并支持控制点不在 L3、而在内存控制器 / CPU-less NUMA 节点的硬件"。

```
 ┌─────────────────────────────────────────────────────────────┐
 │ ① Generic schema description PoC   (Reinette Chatre / Intel) │  框架层
 │    resctrl fs 通用多控制模型:一个 resource 多控制、自描述     │  (通用侧)
 │    schema、info/<res>/resource_schemata/                     │
 └───────────────▲─────────────────────────────▲───────────────┘
                 │ 依赖(多控制框架 [1])       │ 依赖(计数器分配前置)
 ┌───────────────┴───────────────┐ ┌───────────┴─────────────────┐
 │ ② resctrl: MBA control        │ │ ③ arm_mpam: Counter         │  接入层
 │    emulation + MPAM MB_NODE    │ │    Assignment (ABMC)         │  (MPAM侧)
 │    (Fenghua Yu / NVIDIA, 23p)  │ │    (Ben Horgan / Arm)        │
 │    CPU-less NUMA 内存节点:      │ │    MPAM 带宽*监控*接线        │
 │    NODE-scope MB_NODE 控制 +    │ │    (MBWU→mbm_total,模拟ABMC) │
 │    mode 切 legacy/native 模拟MB │ │                              │
 └────────────────────────────────┘ └──────────────────────────────┘
     (另有已入 v7.1 的基础 MB:arm_mpam 'MB' resource,MBW_MAX→百分比,见附A)
```

- **① 是通用框架**(改 `fs/resctrl`,Intel 主导):定义"一个 resource 可有多个控制、每个控制自描述、可有不同 scope"。②③ 都声明建立在它之上。
- **② 是 NVIDIA 的 MPAM 带宽控制/监控扩展**(改 `fs/resctrl` + `drivers/resctrl/mpam_*`,Fenghua Yu 主导):针对 **MBA 控制点在内存级 MSC(CPU-less NUMA 节点,如 Grace)** 的平台,引入 **NODE scope 的 `MB_NODE`** 原生控制,并用一个可写的 `mode`(legacy/native)让 `MB_NODE` **模拟**出传统 `MB`;把监控从 L3 扩到 `mon_NODE_XX`。
- **③ 管 MPAM 带宽"监控"底座**(改 `mpam_resctrl.c`,Arm 主导):让 MPAM 有限的带宽计数器按需分配给监控组(模拟 AMD ABMC),从而能在 resctrl 里读到内存带宽。

**你最初给的标题 "resctrl: MBA control emulation and ARM MPAM MB_MODE support"** —— 经一手 cover 核实,实际是 **`MB_NODE`**(不是 MB_MODE),即 ② 这个 NVIDIA 系列。

**整体状态:①②③ 全部未合入主线**(截至 v7.2-rc4,均为 RFC)。另有一个**已合入 v7.1 的基础 `MB`**(`arm_mpam: 'MB' resource`,MBW_MAX→百分比,L3-scope)是它们的前提——见**附录 A**。注意区分:附录 A 是"L3 上的基础百分比 MB,已合入";② 是"内存级/NODE 上的 MB 及其模拟,RFC 未合入"。

---

## ① `[RFC] mpam,x86,fs/resctrl: Generic schema description Proof of Concept`

| 项 | 内容 |
|---|---|
| 作者 / 单位 | **Reinette Chatre / Intel** |
| 日期 | **2026-05-29** |
| Cover letter | <https://lore.kernel.org/lkml/aPtfMFfLV1l%2FRB0L@redhat.com/>(可读镜像 <https://lkml.iu.edu/2605.3/10984.html>) |
| 代码 | 不走邮件(补丁太多),git 分支 **`resctrl/controls_rfc_v1`**(`reinette/linux.git`,基于 **v7.1-rc2**) |
| 状态 | **RFC / "direction check"**,远未合入;MPAM 侧仅编译测试 |

### 要解决什么

resctrl 现在假设"**一个 resource 就一个控制、且粒度粗**"。但即将到来的硬件有**细粒度控制**、以及**一个 resource 上多个控制**(MPAM 的 MBW_MIN/MAX/PROP、RISC-V 的用法)。这个 PoC 把去年 Plumbers 上讨论达成的方向做成可跑代码,作者明确称之为 *"direction check"*(方向确认),目的是**给做新硬件的人一个可往上搭的基座并重启讨论**——不是终版。

### 核心数据结构改动

引入 `struct resctrl_ctrl` 表示"一个控制",挂在新的 `rdt_resource::controls` 链表(一个 resource 可挂多个控制)。两点最关键:

- **`name`**:控制名拼到 resource 名后面 —— resource `MB` + 控制 `MAX` ⇒ schema 条目 **`MB_MAX`**。这就是 `MB_MIN`/`MB_MAX` 的来历。schemata 形如:
  ```
  MB_MAX:0=100;1=100
  MB_MIN:0=50;1=100
  MB:0=100;1=100
  L3:0=fff;1=fff
  ```
- **`domains`**:控制域列表从"挂 resource"改成"挂**控制**" ⇒ 同一 resource 的不同控制可有**不同 scope**。cover 直说这是"**为即将到来的 MPAM 和 RISC-V 用法准备的**"。
- 控制按类型分 `RESCTRL_CTRL_BITMAP`(缓存位图)/ `RESCTRL_CTRL_SCALAR`(带宽标量),各带类型专属属性;并在 **`info/<resource>/resource_schemata/`** 下用机读属性 `type/resolution/scale/min/max/scope/tolerance` 自描述每个控制。

### 作者自列的 opens(判断状态的关键)

- MPAM 侧改动**只编译测试**,没在 MPAM 上真正初始化新控制属性;作者承认自己那版 MPAM 重构(把 domain 复制到多个控制链表)"**definitely not good design**"。
- **还不支持"模拟控制"(emulated controls)** —— 但认为本 PoC 可作其基座,而 **`mba_MBps` 软件控制器是模拟控制的头号潜在客户**。(这正是 "MBA control emulation" 的落点。)
- schemata 的 **read-modify-write**(是否引入 `#` 前缀)曾讨论未达成一致,本 PoC 不支持。
- 控制间**互不校验**:目前 MIN 可被设得比 MAX 大。
- bitmap 控制属性尚未暴露到 `resource_schemata`。

### 前置依赖系列(cover 明列)

- `selftests/resctrl: Fixes and improvements focused on Intel platforms`(已 queued)
- `x86,fs/resctrl: Improve resctrl quality and consistency`(已 queued)
- `x86,fs/resctrl: Pave the way for MPAM counter assignment`(Ben Horgan)← 与 ③ 同源

---

## ② `[PATCH RFC 00/23] resctrl: MBA control emulation and ARM MPAM MB_NODE support`

| 项 | 内容 |
|---|---|
| 作者 / 单位 | **Fenghua Yu / NVIDIA**(`fenghuay@nvidia.com`;老 Intel RDT/resctrl 核心开发者,`mba_MBps` 软件控制器最初提出者) |
| 日期 / 版本 | **2026-07-16**,**PATCH RFC**,共 **23 个补丁** |
| Cover letter | <https://lore.kernel.org/all/cover.1784217438.git.fenghuay@nvidia.com/>(可读镜像 <https://lkml.iu.edu/hypermail/linux/kernel/2607.2/01921.html>) |
| 代码分支 | `https://github.com/fyu1/linux/` 分支 `emul.cpu_less.rfc/` |
| 基线 / 依赖 | 打在 **① Chatre 的 `resctrl/controls_rfc_v1`** 之上(cover 的 [2]);概念承接 ① 的 Generic schema 讨论(cover 的 [1]) |
| 状态 | **RFC,未合入**;cover 自述"x86 上只能编译、未测" |

### 要解决什么(cover 原话转述)

**痛点**:x86 上 MBA 带宽控制默认挂在 **L3**(schemata 用 L3 cache-id、监控域叫 `mon_L3_XX`)。但**有些 ARM MPAM 平台,MBA 控制点在"内存级 MSC"而不是 L3 cache MSC**——这个内存级 MSC 表示成一个 **NUMA 节点,且常常没有自己的 CPU**(CPU-less 的纯内存节点,如 NVIDIA Grace)。对这种资源,**控制 scope 是 NODE、schemata 标识符是 NUMA node-id、监控域叫 `mon_NODE_XX`**,而一个 **NODE scope 的 `MB_NODE` 控制可能是唯一有可用带宽硬件的控制**。

**核心机制**:
- 引入 **`MB_NODE`**(NODE scope)作**原生**带宽控制后端。
- `info/MB/resource_schemata/` 下加一个**可写的 `mode`**:
  - **`legacy`**:`MB` 被禁用(无 L3 硬件),但用 `MB_NODE` **镜像/模拟**出一个 `MB` 条目 —— schemata 里 `MB_NODE` 和 `MB` 显示相同值,让**老的、面向 `MB` 的用户态工具照常工作**(这就是"MBA control emulation")。
  - **`native`**:只暴露 `MB_NODE`,不再模拟 `MB`。
- 监控:从写死的 L3 路径**去硬编码**,新增 `mon_NODE_XX` 域和 **node-scope 的 `mbm_total` 事件**,让 CPU-less 内存节点也能读 `mbm_total_bytes`。
- 驱动侧:`mpam_ris_get_affinity()` 对空 CPU mask 的内存节点**回退到 `cpu_possible_mask`**(按 MSC 可达性掩码),否则该节点永远不会被注册;但这个"借来的 affinity"不计入 `class->affinity`(避免拆除时误删别的活节点仍依赖的 CPU)。

### schemata / info 布局示例(cover 原文)

**MB 禁用、MB_NODE 启用(`MB` 由 `MB_NODE` 模拟)**:
```
info/MB/resource_schemata/
+-- mode              # [legacy] native
L-- MB/               # scope=NODE, status=disabled
    L-- MB_NODE/      # scope=NODE, status=enabled
schemata:   MB_NODE 与 MB 显示相同值
    MB_NODE:0=100;1=100;2=100;10=100;...   ← NUMA node-id 作标识
         MB:0=100;1=100;2=100;10=100;...   ← 模拟出来的
         L3:1=ffff;2=ffff
mon_data/  mon_L3_01  mon_NODE_00  mon_NODE_01 ...
    mon_NODE_01/mbm_total_bytes            ← CPU-less 节点也能读带宽
```
写 `mode` 切到 `native` 后:schemata 里**只剩 `MB_NODE`,不再模拟 `MB`**。

### 23 个补丁的分组(cover 原文)

1. **修复(1–2)**:resource_schemata 子目录 owner、ARM MPAM 驱动 NULL 地址访问。
2. **resctrl 控制模拟框架(3–8)**:在 core 引入 MBA 模拟——可写的 `legacy/native` mode、每控制 status、嵌套 schemata 布局、对无 MBW 硬件的控制做 schemata 镜像、mode 变更时重建子目录;patch 8 写 `resctrl.rst` 文档。cover 明说**这组 + 第4组是在实现 [1](Chatre Generic schema)讨论里的概念**,且**当前只针对 MPAM CPU-less NUMA 节点模拟,x86 内存域 / RISC-V 模拟需再增强**;作者态度开放:"换掉这套实现或继续增强都行"。
3. **内存级 MSC 上的带宽监控与控制(9–17)**:把监控基础设施从写死 L3 泛化——去 L3 硬编码、暴露 MBA MBM 计数器分配、`mon_NODE_<id>` 命名、node-scope `mbm_total` 事件、MBM 路径 resource-aware;MPAM 侧加**内存级 MSC + ABMC** 支持、精化 L3 拓扑/class 选择、按 component 重构 domain 建立、处理 CPU-less 内存节点。
4. **`MB_NODE` 模拟 `MB`(18)**:在 ARM MPAM 驱动里把 `MB_NODE` 接成"模拟被禁用的 `MB`"的原生后端。
5. **文档(19–21)**:arm64 MPAM 指南的内存级 MB/NUMA 节点、resctrl 文档的 NODE-scope MBA 域与 `mon_NODE_*`、MB_NODE 模拟示例。
6. **测试(22–23)**:CPU-less NUMA 亲和性的 KUnit;`resctrl_tests -a mb_emulation_test` 的 kselftest(模拟模式切换、resource_schemata 层级、schemata 镜像)。

### 逐补丁详解(23 个,基于一手 commit message)

> 抓取方式:`lore.kernel.org` 被 Anubis 拦,改用 hypermail 镜像 `lkml.iu.edu/hypermail/linux/kernel/2607.2/`(01922–01950)逐封取原文。下面每条 = 改哪 + 干什么 + 技术要点。

#### 第 1 组:修复(1–2)—— 前置 bug

- **01 `resctrl: Fix ownership of resource_schemata control subdirectories`**(`fs/resctrl/rdtgroup.c`,+2/-1)。`resctrl_mkdir_schemata_dir()` 把 owner 错误地应用到父目录 `resource_schemata` 而非新建的控制子目录 `kn_ctrl`。root 挂载无害(`rdtgroup_kn_set_ugid()` 对 root 是 no-op),但**非 root 挂载**下控制子目录会保留 `root:root` 而非继承挂载用户。改成对 `kn_ctrl` 应用。
- **02 `arm_mpam: Fix NULL address access issue`**(`mpam_resctrl.c`,+1)。`mpam_resctrl_setup()` 初始化了每个 resource 的 `mon_domains` 但**没初始化 `controls` 链表**;`mpam_resctrl_controls[]` 是静态分配,链表头是零值而非空链表,通用侧 `for_each_resource_ctrl()` 遍历会解引用 NULL。补一句 `INIT_LIST_HEAD()`(x86 用编译期 `LIST_HEAD_INIT()` 同理)。

#### 第 2 组:resctrl 控制模拟框架(3–8)—— **本系列核心,通用侧**

- **03 `resctrl: Expose MBA resource_schemata mode sysfs`**(`rdtgroup.c` +77,`resctrl.h` +17)。在 `rdt_resource` 上加 `mode` 字段,暴露 `info/<res>/resource_schemata/mode`(`native`/`legacy`)。默认 `RESCTRL_CTRL_MODE_NONE`——**不支持模拟的架构没有这个文件、完全不受影响**。本补丁 mode 文件**先做只读**(切换要重建目录树,留到 patch 07)。
- **04 `resctrl: Expose per-control status in resource_schemata`**(`rdtgroup.c` +17,`resctrl.h` +4)。每个控制加只读 `status`(`enabled`/`disabled`),存为 `resctrl_membw::no_mbw_hw`(默认 false → 默认都报 `enabled`,无需各架构初始化)。标记"这个控制到底有没有真实 MBW 硬件背书"。
- **05 `resctrl: Add nested resource_schemata support for emulated controls`**(x86 `core.c`+2、`ctrlmondata.c`+1、`rdtgroup.c`+67、`resctrl.h`+7)。引入 **`resctrl_ctrl::emulated_by` 指针**(存在被模拟的默认控制上,指向模拟它的控制)+ **`RESCTRL_CTRL_NAME_NODE`** 控制名。目录树:先建默认控制目录,再把模拟控制**嵌套**在它下面;非模拟控制仍直接挂 `resource_schemata`。抽出 `resctrl_ctrl_create_subdir()` 并修 owner/错误处理。
- **06 `resctrl: Mirror schemata for controls without MBW hardware`**(`ctrlmondata.c` +93)。**模拟的关键一环**:当模拟控制自己没有 MBW 硬件时,把 schemata 的读/写**重定向到背书控制**,使两行(`MB` 和 `MB_NODE`)显示并更新同一个值。
- **07 `resctrl: Rebuild resource_schemata subdirs on MBA mode change`**(`rdtgroup.c` +334,**本组最大**)。把 03 的 mode 文件**改成可写**(0444→0644):`legacy` 下模拟控制嵌套在默认控制下、`native` 下所有控制平级;切 mode 时用 `resctrl_ctrl_rebuild_subdirs()` **重建整个控制子目录树**保持一致。
- **08 `Documentation: resctrl: document MBA control emulation`**(`resctrl.rst` +93)。文档化这套通用机制(mode/status/嵌套布局),**与具体架构无关**。

#### 第 3 组:内存级 MSC 上的带宽监控与控制(9–17)—— 去 L3 硬编码 + MPAM 驱动

- **09 `resctrl: De-hardcode L3 monitor infrastructure`**(`monitor.c` +94,`rdtgroup.c` +35)。监控核心到处写死 `RDT_RESOURCE_L3`(域校验、上下线、计数器分配),挡住了给 MBA 复用。泛化成用 `r->rid`:`resctrl_l3_mon_resource_init/exit` → `resctrl_mon_init/exit`,域校验/上下线支持任意 resource id。**L3 用户态行为不变**。
- **10 `resctrl: Expose MBA MBM counter assignment sysfs`**(`monitor.c` +27 等)。MBWU 监控由 MBA resource 背书时,给出与 L3 相同的计数器分配接口,但键到 MBA 域、暴露成 **`mbm_MB_assignments`**(区别于 `mbm_L3_assignments`)。
- **11 `resctrl: name node-scoped monitor domains mon_NODE_<id>`**(`rdtgroup.c` +25)。内存侧 MSC 的域 id 是 **NUMA node id**,再叫 `mon_<资源名>`(即 `mon_MB`)会误导。加 `RESCTRL_NODE` 监控 scope + `mon_domain_name()`,node-scope 资源的监控目录改名 **`mon_NODE_<id>`**;L3/telemetry 命名不变。
- **12 `resctrl: Add node-scope MBM total event`**(`resctrl_types.h` +15 等)。加 **`QOS_NODE_MBM_TOTAL_EVENT_ID`**(node-scope 总带宽,MBA 背书),与现有 L3 MBM 事件 **id 连续**(保住 `for_each_mbm_event_id()` 区间和软件 MBM 状态数组的尺寸假设)。加 `resctrl_is/mbm_total_event()` 辅助:启用时选 node-scope 总量,否则回退 L3 总量。
- **13 `resctrl: Make MBM paths resource-aware`**(`monitor.c` +105,`rdtgroup.c` +53)。MBM 溢出/计数器分配/事件配置路径原本写死 L3 事件 id。改成遍历 `mon_event_all[]` 对每个启用的 MBM 事件按 owning resource 处理;**`mba_sc` 带宽反馈只对 L3 跑**;L3-only 系统**无功能变化**。
- **14 `arm_mpam: Support memory-level MSCs and ABMC per class`**(`mpam_resctrl.c` +112)。驱动原本假设所有 monitor 和 ABMC 状态都在 L3 resource。改成把 monitor class 映射到 L3 **或 MBA** resource、在拥有 MBWU 的 resource 上初始化 ABMC、给内存侧计数器选 node-scope 总量事件、用 `mbm_cntr_assignable` 判定而非"谁先共享 class"。
- **15 `arm_mpam: Refine L3 topology and class selection`**(`mpam_resctrl.c` +22)。class 挑选启发式原本一律按 L3 cache MSC 对待,会误拒有效内存 class。放宽:内存 class 可直接背书 MBWU;L3 拓扑匹配**只对 level-3 MBA 候选**要求;class 已覆盖全部 CPU 时跳过 traffic 匹配。
- **16 `arm_mpam: Include all MSC components during domain setup`**(`mpam_resctrl.c` +197,**驱动侧最大**)。建控制/监控域时**按 component 遍历每 CPU 的所有 MSC component**(以 component 为键),支持 MBA `mon_capable` 查找、从任意 L3/MBA 监控 resource 上报 mon 能力。
- **17 `arm_mpam: Handle CPU-less numa nodes`**(`mpam_devices.c` +59,`mpam_internal.h` +8)。**CPU-less 内存节点的关键补丁**:`mpam_ris_get_affinity()` 从 component 的 NUMA node id 推 affinity,纯内存节点会得到空 mask 而永不注册。空 mask 时**回退 `cpu_possible_mask`**(按 MSC 可达性掩码),用 `ris->cpu_less` 标记,且**不计入 `class->affinity`**(那些 CPU 已通过有 CPU 的节点贡献,拆除时减掉会误删别的活节点依赖的 CPU)。

#### 第 4 组:MB_NODE 模拟 MB(18)

- **18 `arm_mpam: Emulate MB control with node-scoped MB_NODE control`**(`mpam_resctrl.c` +166,`rdtgroup.c` +3)。内存 class MSC 上 MB 带宽控制是 node-scope。加 **`MB_NODE`** 控制,把它的 `resctrl_ctrl::emulated` 指向默认 `MB` 控制,从而在 `resource_schemata` 里**嵌套在 `MB` 下**。引入 `mpam_resctrl_ctrl_node()` 识别内存 class 资源,`scope` sysfs 报告 `NODE`(而非 "Unsupported control scope")。**这就是把第 2 组通用框架落到 MPAM 硬件的收口补丁。**

#### 第 5 组:文档(19–21)

- **19** `Documentation: arm64: mpam`(+105):arm64 MPAM 指南加"MB 控制/MBWU 监控的 L3-cache 路径 vs 内存 MSC 路径"、如何用 `scope` 文件区分、NUMA node id 与 `/sys/devices/system/node/node*/` 的映射、CPU-less 节点处理。
- **20** `Documentation: resctrl`(+45):resctrl 文档加 NODE-scope MBA 域、`mon_NODE_XX`、如何解读 L3-scope vs NODE-scope 的 `MB:` 行。
- **21** `Documentation: resctrl`(+52):在通用"MBA control emulation"节加 **ARM MPAM 具体示例**(`MB`/`MB_NODE` 的 scope/status/标识符、legacy 下如何模拟、各 enabled/disabled 组合的目录布局)。

#### 第 6 组:测试(22–23)

- **22** `arm_mpam: Add KUnit test for CPU-less NUMA node affinity`(`test_mpam_devices.c` +67):定位 CPU-less 节点、走 `MPAM_CLASS_MEMORY` 路径、验证 affinity == `cpu_possible_mask` ∩ MSC 可达性、`cpu_less` 被置位。
- **23** `selftests/resctrl: Add MB emulation test for ARM MPAM`(新增 `mb_emulation_test.c` +460):验证 `resource_schemata` 层级(legacy 下 `MB_NODE` 嵌套、native 下平级)、legacy/native 切换、默认 MB 禁用时的 schemata 可见性/镜像。

### 技术要点提炼(读完 23 patch 的判断)

1. **框架/驱动的清晰分层**:通用侧(3–13,`fs/resctrl`)与 MPAM 驱动侧(14–18,`drivers/resctrl`)分离;通用侧的每个补丁都反复强调"默认值使 x86/L3 行为不变、不需各架构初始化",**兼容性防线做得很克制**——这是能被上游接受的关键写法。
2. **模拟的本质** = "**schema 镜像**"(patch 06)+ "**目录嵌套**"(patch 05)+ "**可写 mode 重建**"(patch 07):`legacy` 下 `MB_NODE` 的值镜像到一个虚拟 `MB` 行,老工具照读 `MB:` 不变;`native` 下摘掉 `MB` 只留 `MB_NODE`。
3. **CPU-less NUMA 是真正的硬骨头**(patch 17 + KUnit 22):`cpu_possible_mask` 回退 + `cpu_less` 标记 + 不污染 `class->affinity`,这套处理是为 Grace 这类"内存节点无本地 CPU 但参与带宽控制"的拓扑量身定做,也是 §2 观点 2/4 的正面破解。
4. **去 L3 硬编码是重头**(patch 09/11/12/13):resctrl 监控层长期假设"监控都在 L3",这组把它泛化到任意 resource/NODE scope——**与 ① Chatre 的 Generic schema 是同一个战役的两翼**(① 泛化"控制描述",这里泛化"监控拓扑")。

### 评审进展(截至抓取时)

cover 与 patch 03 的页面显示有 **Ben Horgan(Arm)对多个补丁的 `Re:` 回复**(如 03 的 "Next in thread: Ben Horgan"),说明 Arm(MPAM 驱动维护者)已在 review 这个 NVIDIA 系列——**跨厂商协作的又一实证**。(具体意见需进一步抓取回复贴;本环境暂以 cover+patch 正文为准。)

### 与主文档结论的关系

这是 §2 观点 4(**CPU-less NUMA / CXL 内存节点无法暴露 MB**)和观点 2("all the world's a Xeon"、一切挂 L3)在 NVIDIA Grace 这类真实硬件上的**正面破解**:把 resctrl 的带宽控制/监控从"L3-scope"泛化到"NODE-scope",并用 `mode=legacy` 的**模拟层**保住老工具兼容。治理上意味深长——**推动 MPAM 通用化的这一手,来自 NVIDIA(Fenghua Yu),打在 Intel(Chatre)的框架分支上**,服务 Arm 硬件,是 §2 观点 5/6 跨厂商格局的又一例证。


## ③ `[RFC PATCH v2 0/5] arm_mpam: resctrl: Counter Assignment (ABMC)`

| 项 | 内容 |
|---|---|
| 作者 / 单位 | **Ben Horgan / Arm**(含 James Morse 3 patch) |
| 日期 / 版本 | **2026-03-19(v2)**;rfc v1 = 2026-02-25 |
| Cover letter | <https://lkml.iu.edu/hypermail/linux/kernel/2603.2/09226.html>(v1:<https://lore.kernel.org/lkml/20260225205436.3571756-1-ben.horgan@arm.com/>) |
| 代码分支 | `https://gitlab.arm.com/linux-arm/linux-bh.git` 分支 `mpam_abmc_v2` |
| 规模 | 5 patch,主要动 `mpam_resctrl.c`(+303 行)+ `mpam.rst` |
| 状态 | **RFC,未合入**;底座已进 v7.2,顶层接线未合 |

### 要解决什么

让 **MPAM 的内存带宽监控(MBWU)在 resctrl 里真正可用**。难点:**MPAM 的带宽计数器数量可能少于 resctrl 的监控组数量**,硬件没法给每组常驻一个计数器。方案 = **模拟 AMD 的 ABMC(Assignable Bandwidth Monitoring Counters)**:按需把有限物理计数器**分配/指派**给监控组,复用 AMD 引入、已进 fs 核心的 `mbm_cntr_assign` 通用接口。

补丁内容:预分配可指派 monitor、挑选用作 mbm 计数器的 class、`resctrl_arch_config_cntr()` / `cntr_read()` / `reset_cntr()`、MBWU 文档。

### 为什么是 RFC(状态关键)

cover 说这些改动**原本在 MPAM 胶水系列里,因 resctrl 缺前置被踢出来**单独走。v2 的主要变化是处理"**砍掉'非计数器分配模式的带宽监控'之后的连带影响**"——作者决定 **MPAM 只保留"计数器分配"这一种带宽监控模式**(*"两种模式并存的额外复杂度看起来没必要"*)。依赖 ② 的胶水系列 + ① 同源的 resctrl 前置。

### 与本地 v7.2 树的精确界线(核实结论)

- ✅ 通用侧 `resctrl_arch_config_cntr/cntr_read/reset_cntr` **函数已在 v7.2 树存在**;MPAM 驱动侧 **MBWU 计数器底座已合入**(`Use long MBWU counters if supported`、`Probe for long/lwd mbwu counters`、`Add helper to reset saved mbwu state`)。
- ❌ **但** `mpam_resctrl.c:498` 仍写 **`/* MBWU when not in ABMC mode (not supported) */`**,`mpam.rst` **尚无 MBWU 文档**(patch 5/5 未落地)。
- ⇒ **结论:目前在 resctrl 里"读不到 MPAM 的内存带宽"(`mbm_local`/`mbm_total` 不可用),正卡在这个 RFC。MPAM 现在能读的只有 CSU→`llc_occupancy`(缓存占用)。** 这直接影响能否用 `mba_MBps` 软件控制器——mba_sc 需要 MBM 带宽反馈(见 [[ARM64_resctrl_mba_MBps可行性分析]])。

### 逐补丁详解(5 个,基于一手 commit message)

> 抓取:hypermail 镜像 `lkml.iu.edu/.../2603.2/`;编号 1/5=09228、2/5=09217、3/5=09229、4/5=09208、5/5=09213(跨列表多副本,已逐一核实正文)。作者 **Ben Horgan(Arm)2 个 + James Morse(Arm)3 个**,Tested-by 含 Shaopeng Tan(Fujitsu)、Zeng Heng(华为)。

- **1/5 `arm_mpam: resctrl: Pick classes for use as mbm counters`**(Morse,`mpam_resctrl.c` +26)。resctrl 有两类计数器:**NUMA-local 与 global**。**MPAM 只能数 global**(用 L3 cache 的 MSC 或内存控制器的 MSC)。当 global 与 local 等价时,继续按 global 处理。→ 挑选哪个 MPAM class 作为 mbm 计数器来源。
- **2/5 `arm_mpam: resctrl: Pre-allocate assignable monitors`**(Horgan,`mpam_internal.h` +6、`mpam_resctrl.c` +135,**本组最大**)。**MPAM 通过"让带宽 monitor 可指派"来模拟 ABMC(mbm_event 模式)**。关键决定:**永远只用 `mbm_event` 模式,即使 monitor 足够也不用 `default` 模式**——因为 per-monitor 事件配置只在 `mbm_event` 模式下由 resctrl 提供,只走这一种模式能简化 MPAM 的 per-monitor 配置;当前只支持 `mbm_total` 事件。加第二个数组按 resctrl 的 `cntr_id` 索引 monitor 值。**CDP 下需要两个 monitor,可用计数器减半**——只有 1 个 monitor 的平台开 CDP 后会变成 0 个。
- **3/5 `arm_mpam: resctrl: Add resctrl_arch_config_cntr() for ABMC use`**(Morse,`mpam_resctrl.c` +43)。ABMC(mbm_event 模式)有个 `resctrl_arch_config_cntr()` 用来改 `cntr_id` ↔ CLOSID/RMID 对的映射。MPAM 侧靠更新 `mon->mbwu_idx_to_mon[]` 实现,**CDP 又意味着要按三种方式各做一遍**。
- **4/5 `arm_mpam: resctrl: Add resctrl_arch_cntr_read() & resctrl_arch_reset_cntr()`**(Morse,`mpam_resctrl.c` +99)。`mbm_event` 模式(ABMC emulation)下,resctrl 用 arch hook 读/复位 MBWU 计数器。补上这两个 hook。
- **5/5 `arm64: mpam: Add memory bandwidth usage (MBWU) documentation`**(Horgan/co-dev Morse,`mpam.rst` +17)。MBWU 监控现在经 resctrl 暴露给用户,补文档说明预期行为。

### 技术要点提炼(读完 5 patch 的判断)

1. **MPAM 只有 global 带宽计数、且计数器稀缺**是核心约束(patch 1/2):不像 x86 每个 RMID 常驻计数器,MPAM 计数器少,必须"按需指派"——所以**借用 AMD 的 ABMC(可分配计数器)通用接口**,而非另造一套。
2. **"只走 mbm_event 一种模式"是有意简化**(patch 2/5):放弃"两种带宽监控模式并存",换取 per-monitor 事件配置的简单性——与 cover 说的"砍掉非计数器分配模式"一致。
3. **CDP 到处是税**(patch 2/3):CDP 用双 PARTID/双 monitor,直接让可用计数器减半、配置逻辑×3——再次印证主报告 §2 里"CDP 在 MPAM 上是模拟且代价高"。
4. 与 ② 的关系:③ 是**带宽监控的底座**(让 MPAM 能数带宽),② 的第 3 组(patch 9–17)在此之上做**内存级 MSC / node-scope** 的监控泛化。②③ 都依赖"ABMC/mbm_event 计数器分配"这套通用机制。

---

## 附:三者关系与状态汇总

| # | Patchset | 主导 | 层次 | 改哪 | 状态(v7.2-rc4) |
|---|---|---|---|---|---|
| ① | `[RFC] Generic schema description PoC` | Chatre / Intel | 通用框架(多控制/自描述) | `fs/resctrl` | RFC,未合入(仅 x86 dummy 演示,MPAM 未接) |
| ② | `[PATCH RFC] MBA control emulation + MPAM MB_NODE`(23p) | **Fenghua Yu / NVIDIA** | CPU-less NUMA 内存节点带宽控制+监控+模拟 | `fs/resctrl`+`drivers/resctrl` | **RFC,未合入**(2026-07-16,x86 仅编译) |
| ③ | `[RFC v2] arm_mpam: Counter Assignment (ABMC)` | Horgan / Arm | MPAM 带宽监控(MBWU) | `mpam_resctrl.c` | RFC,未合入;底座已入 v7.2,顶层未接 |
| 附A | `arm_mpam: 'MB' resource` | Morse/Horgan / Arm | 基础 MB(L3,MBW_MAX→%) | `drivers/resctrl` | **已合入 v7.1**(②③ 的前提) |

**一句话**:MPAM 在 L3 上的**基础带宽控制**(百分比)已进主线(附A);但**内存级/CPU-less NUMA 节点的带宽控制+监控+MB 模拟**(②,NVIDIA)、**通用多控制框架**(①,Intel)、**MPAM 带宽监控计数器分配**(③,Arm)都还是 RFC。这三者是 §2"resctrl RDT 中心化、装不下 MPAM"矛盾在带宽维度上的正面攻坚,格局是**Intel 出框架、NVIDIA+Arm 出硬件接入**——印证治理与跨厂商协作。

---

## 附录 A:`arm_mpam: resctrl: Add support for 'MB' resource'`(已合入 v7.1,②③ 的前提)

- **作者 / 演进**:James Morse `[RFC PATCH 16/38]`(2025-12-05)→ Ben Horgan `v2 25/45`→`v3 27/47`→`v4 26/41`→`v6 25/40`(2026-03-13,Tested-by Shaopeng Tan)
- **补丁**:<https://lkml.org/lkml/2025/12/5/1404>(RFC)、<https://lkml.org/lkml/2026/1/12/1659>(v3)
- **干什么**:把 MPAM 的内存带宽**控制**接成 resctrl 的 `MB`(L3-scope,百分比)。用 MPAM 的**定点小数 `MBW_MAX`** 背书百分比(`get_mba_granularity()`:`bwa_wd` 位数 → 1bit=50%…);**刻意不用 PBM 位图**("难挑不冲突的 bit"),并留话 *"未来可能以非百分比形式暴露"*——正是 ② 要接的钩子。
- **拓扑限制(评审焦点)**:要求单 L3、内存拓扑与 L3 egress 等价才允许内存 class 背书 `MB`。Jonathan Cameron 质疑"这个 shape 启发式在多数系统上是否有用";Zeng Heng 指出**内存级 MSC(如 Mata 平台)不在 L3 时,`MB` 控制和 `mbm_total` 都用不了**——**这正是 ② 要解决的痛点**。
- **本地 v7.2 对应**:`mpam_resctrl.c` 的 `MB` 只由 `mpam_feat_mbw_max` 支撑(`mbw_max_to_percent()`),无 `mbw_min`/`mbw_prop`。

## 相关文档
- `主线MPAM_resctrl现状与RDT中心化设计争议.md` —— 总报告(本篇是其 §3.0 展开)
- `ARM64_resctrl_mba_MBps可行性分析.md` —— mba_MBps 与 MBM 带宽反馈依赖
- `MPAM驱动与resctrl对接分析.md` —— 驱动↔resctrl 对接细节
