# 主线 MPAM 与 resctrl:支持现状、社区讨论与 RDT 中心化设计争议

> **生成时间**:2026-07-20
> **基准树**:本地 Linux **v7.2-rc4**(2026-07-19),所有 commit / 版本 / 引文均以此树 `git` 逐条核验
> **可信度说明**:`lore.kernel.org / LWN / LPC / patchwork` 在调研环境被 Anubis 反爬或域名策略拦截,**尚未合入、被 NACK、纯邮件列表上的活体争论无法直接引用**;因此"社区讨论"部分主要从**已合入 commit 的 message 与代码注释**反推,并显式标注推断成分。5 路网络调研 agent 有 3 处版本/路径错误已用本地 git 纠正(见文末附录)。

---

## 0. 一句话结论

**"MPAM 还在社区讨论、尚未进主线"这个前提已经过时。** MPAM 的 **host 侧支持已完整进入主线**(arm64 全栈在 **v7.1** 落地并解除门控),复用的是被重构成架构中立的 `fs/resctrl` 文件系统。而"resctrl 基于 Intel RDT、设计不完善"不是外部批评,而是**内核代码与官方文档白纸黑字承认的事实**——`mpam_resctrl.c` 里那句 *"Resctrl believes all the world's a Xeon"*(resctrl 以为全世界都是 Xeon)就是全部矛盾的浓缩。

当前真正的空白已经不在 host 侧,而在两处:**① KVM guest 内自管 MPAM/RDT(透传);② I/O 侧 MPAM(SMMU DMA / GIC ITS 流量)**。这两处对虚拟化最相关。

---

## 1. 主线 MPAM 支持现状

### 1.1 合入时间线(git describe 权威)

resctrl/MPAM 是近年内核最高强度的演进区之一:v6.14→v7.1 **每个版本 44–59 个 commit**,持续数年。

| 版本 | 时间 | 落地内容 | 关键 commit |
|---|---|---|---|
| **v6.13-rc1** | 2024-11 | **KVM 防御性支持**:默认对 guest 隐藏 FEAT_MPAM、补齐 guest 访问 MPAM 寄存器的 trap | `6685f5d5`、`31ff96c3`;merge `24bb1811 kvm-arm64/mpam-ni` |
| **v6.16-rc1** | 2025-05(commit)/2025-06(tag) | **fs/arch 拆分**:resctrl 文件系统代码从 `arch/x86` 搬到 `fs/resctrl/` | `7168ae33`、`bff70402` |
| **v6.19-rc1** | 2025-12 | **MPAM 设备驱动层**:MSC(Memory System Component)探测驱动 + ACPI MPAM 表解析 | `f04046f2`、`115c5325` |
| **v7.1-rc1** | 2026-03(commit)/2026-04(tag) | **arm64 host MPAM 全栈打通并解除门控**:resctrl 胶水层 + CPU 侧 PARTID/PMG 上下文切换 + KVM host 配置保护 | `mpam_resctrl.c`、`arch/arm64/kernel/mpam.c`;KVM `eda1cd1f`/`67faed4c`/`2e7c684b` |
| **v7.2**(当前) | 2026-06 起 | **稳定化 + 收敛**:use-after-free / SNC 域离线修复、MPAM 计数器分配准备、MPAM v0.1 架构版本、各 SoC 勘误 | 见 §3 |

**关键提交原文**(`7168ae330e81`,James Morse):

> *"Resctrl is a filesystem interface to hardware that provides cache allocation policy and bandwidth control for groups of tasks or CPUs. **To support more than one architecture, resctrl needs to live in /fs/.**"*

**分阶段解锁**:arch 位与 MSC 驱动在 v6.19 就进树了,但一度是 `EXPERT` 门控 / "does nothing yet";到 **v7.1 才去掉门控真正可用**。当前 `arch/arm64/Kconfig` 已是干净的完全体:

```kconfig
config ARM64_MPAM
    bool "Enable support for MPAM"
    select ARM64_MPAM_DRIVER
    select ARCH_HAS_CPU_RESCTRL
    ...
    MPAM is exposed to user-space via the resctrl pseudo filesystem.
    This option enables the extra context switch code.
```

### 1.2 代码架构(拆分后的三层)

```
fs/resctrl/                    架构无关核心(rdtgroup.c 4698行 / monitor.c 1926 /
                               ctrlmondata.c 1058 / pseudo_lock.c 1099)
arch/x86/kernel/cpu/resctrl/   x86 RDT 后端(core.c / monitor.c / intel_aet.c=Intel遥测 …)
drivers/resctrl/mpam_*.c       ARM MPAM 后端(mpam_devices.c 驱动 2970行 +
                               mpam_resctrl.c 胶水 1712行 + KUnit 测试)
arch/arm64/kernel/mpam.c       arm64 CPU 侧(MPAM sysreg 上下文切换)
drivers/acpi/arm64/mpam.c      ACPI MPAM 表解析
include/linux/resctrl.h        边界 = 30 余个 resctrl_arch_* 回调
```

**Kconfig 依赖链**:

```
RESCTRL_FS          (depends ARCH_HAS_CPU_RESCTRL)      # 通用文件系统
ARM64_MPAM          → select ARM64_MPAM_DRIVER + ARCH_HAS_CPU_RESCTRL
ARM64_MPAM_DRIVER   (depends ARM64 && ARM64_MPAM, select ACPI_MPAM)
ARM64_MPAM_RESCTRL_FS (default y if DRIVER && RESCTRL_FS)
                    → select RESCTRL_RMID_DEPENDS_ON_CLOSID   # ★核心错配点
                    → select RESCTRL_ASSIGN_FIXED
```

其中 `RESCTRL_RMID_DEPENDS_ON_CLOSID` 的 help 直言:*"Enabled by the architecture when the RMID values depend on the CLOSID"* —— MPAM 的 PMG(监控 id)不像 RDT 的 RMID 那样独立于 CLOSID/PARTID,这是被固化进设计的第一处硬伤。

### 1.3 MPAM 目前只能暴露三样能力

`Documentation/arch/arm64/mpam.rst` 明列(其余 MPAM 能力对用户态**全部不可见**):

1. **CPOR**(cache portion bitmap)→ L2/L3 的 CBM。要求每个 CPU 在该层都有对应缓存且支持该特性;**big.LITTLE 大小核不匹配平台不支持**(否则控制效果会依赖任务落核)。
2. **MBW_MAX**(内存带宽上限)→ `MB` schema。要求固件为 L3 提供 cache-id;带宽控制点在内存控制器上时要能被"重绘"成 L3 cache-id。**CPU-less NUMA 节点(如 CXL 内存)无法暴露 MB**;多 socket 内存侧带宽也被排除。
3. **CSU**(cache storage usage)→ L3 的 `llc_occupancy`。其他缓存/设备的 CSU 不支持。

---

## 2. 核心矛盾:resctrl 的 RDT 中心化设计为何"不完善"

这是本次调研的重点。归纳为 6 条核心观点。

### 观点 1:历史根子——为什么是独立文件系统而非 cgroup

这是"设计不完善"的**制度性起源**。2016 年 Intel 做 RDT 用户接口时,曾试过 perf + cgroup 路线但被否:

- `c39a0e2c8850`(Vikas Shivappa / Intel,2017)"Wipe out perf based cqm" 的 message 直陈:**"RMID 是 per-package 的硬件标签,这使得像 cgroup 那样按层次监控、同时又单独监控任务变得困难;为修这些问题发到 lkml 的补丁被 NACK 了。"** 叠加 RMID 回收(recycling)导致 MBM 计数不准。
- 于是 `5ff193fbde20`(Fenghua Yu / Intel,2016)直接用 kernfs 起了个**独立伪文件系统 resctrl**。
- 2019 年 cgroup 核心开发者 **Johannes Weiner** 专门发 `e6d429313ea5` 抱怨:*"'Resource Control' 是个非常宽泛的词,还和容器、cgroup 相关联,极易混淆"*,把符号改名 `X86_RESCTRL`;Borislav Petkov 在同 commit 留下预言:*"将来 ARM 架构相关代码放 ARM_CPU_RESCTRL,架构无关部分收到 CPU_RESCTRL 伞下"* —— **多架构化方向 2019 年就定了,而非转向 cgroup**。

> **含义**:resctrl 的"给任务/CPU 打硬件标签"模型与 cgroup 的层次模型天生不合;社区选择"把 resctrl 架构中立化"而非"迁进 cgroup v2"。该决定至今**未被推翻,也无 resctrl2/新 ABI 提案落地**——代价是 MPAM 只能削足适履。

### 观点 2:"resctrl 以为全世界都是 Xeon"——拓扑假设

resctrl 假设机器就是 Xeon:末级缓存是 L3,所有带宽控制与监控都挂在 L3。MPAM 的现实完全不同(控制/监控点可在内存控制器、互连、任意层缓存)。于是 `mpam_resctrl.c` 到处在"假装":

> *"Resctrl 以为全世界都是 Xeon,这些计数器都在 L3……唯一的内存带宽计数器可能在内存控制器上,但为了能用,我们假装它们在 L3。"*

`topology_matches_l3()` / `traffic_matches_l3()` 强制:**单 socket、无 L4、单 NUMA 节点**,才能把内存带宽暴露成 `MB`。

### 观点 3:抽象层的具体阻抗失配(逐项)

| 维度 | Intel RDT | Arm MPAM | resctrl 里的妥协 |
|---|---|---|---|
| 控制 ID | CLOSID(独立、量小) | PARTID(量大,可上千) | 前置补丁 `dcb1d3d3`(Marvell)先**移除 x86 对 CLOSID 数目的硬编码上限**,MPAM 才塞得进 |
| 监控 ID | RMID(**独立**于 CLOSID) | PMG(**从属**于 PARTID) | 需 `RESCTRL_RMID_DEPENDS_ON_CLOSID`;`rmid_idx = closid*(pmg_max+1)+rmid`。注释坦承 *"userspace needs to know the architecture to correctly interpret this value"* —— **"架构中立"的 ABI 泄露架构语义** |
| Cache 分配 | CBM 位掩码(u32) | cache portion 位图(可 >32 bit) | `cpbm_wd <= 32` 检查:MPAM 硬件若支持更宽 portion,**Arm 代码静默拒用** |
| 带宽单位 | 百分比 / MBps 软件控制器 | 定点小数(bwa_wd 1–16 bit) | `mbw_max_to_percent()`/`percent_to_mbw_max()` **有损转换**,精度随硬件位宽漂移 |
| CDP(代码/数据分离) | 缓存属性 | 用 I/D 两个 PARTID **反向模拟** | 仅 `CONFIG_EXPERT` 可开,警告 *"CDP is an expert feature and may cause MPAM to malfunction"*;替身 PARTID 被所有 MSC 看到,无法按 MSC 启用 |

### 观点 4:MPAM 有、但 resctrl 表达不了的能力

`mpam.rst` 一句话定调:**"因为 MPAM 的用户接口是 resctrl,所以只有与 resctrl 兼容的 MPAM 特性才能暴露给用户态。"** 被挡在门外的至少有:带宽**下限**保证(MBW_MIN)、**优先级**分区、**比例步进**(proportional stride)、**非 L3 监控点**、CPU-less 节点带宽监控。resctrl 的 ABI 成了 MPAM 能力的**天花板**。⚠️ 注意:其中 MBW_MIN / MBW_PROP / MBW_PBM 在**驱动层已实现**(能探测能编程),只是 resctrl 胶水层没暴露——社区正用"通用 schema 描述 + MB_MODE"RFC 尝试抬高这个天花板,详见 §3.0。

### 观点 5:治理张力——共享核心由 Intel 把关

- `fs/resctrl` 核心 + x86 后端走 **tip 树 x86/cache 分支**(Borislav Petkov 集成),维护者 **Tony Luck、Reinette Chatre(均 Intel)**;Arm(Morse/Martin)、AMD(Moger)仅 Reviewer。
- MPAM 驱动(`drivers/resctrl/mpam_*`)走 **arm64 树**,维护者 **James Morse、Ben Horgan(Arm)**。
- **无独立 resctrl 维护者/树**。结果:Arm 为 MPAM 改核心(哪怕在 `fs/`)也得过 Intel 把关的 tip。`fs/resctrl` 提交作者分布 **Tony Luck / Babu Moger / Reinette Chatre / Ben Horgan / James Morse** ≈ **核心话语权在 x86 阵营,Arm 主要在驱动侧**。无公开撕破脸,但是"合作良好、流程 Intel 优先"的模型。

**厂商特性互相拉扯核心**的实例:

- **SNC**(Intel Sub-NUMA)专有逻辑渗进通用路径,在 AMD 上误报,被迫加 `x86/resctrl: Only check Intel systems for SNC`(`6f6947b2`);
- **ABMC**(AMD 可分配带宽计数器,~19 补丁,2025-09 by Babu Moger)进 fs 核心;AMD 用固定映射、MPAM 用灵活映射,抽象成 `mbm_cntr_assign_fixed` 属性(`ee3d4c81`);
- AMD"事件可配置"假设逼 Arm 加"MPAM 不可配置时 `event_filter` 只读"(`94a12065`);
- `RDT_RESOURCE` 枚举被撑大:L3/L2/MBA/**SMBA**(AMD)/**PERF_PKG**(Intel 遥测)——接口靠**累加厂商特性**生长。

### 观点 6:社区实际共识——"重构,不重设计"

尽管缺陷公开承认,社区**没有**走 resctrl2 / 新 ABI / 迁 cgroup。既成路线:①把 resctrl 内部架构中立化(James Morse 四年重构,`resctrl_arch_*` 抽象);②必要时**小步扩 ABI**;③**接受部分 MPAM 能力永远暴露不出来**;④**文档里诚实列出限制**。理由:ABI 稳定性(既有 userspace 工具、selftests)压倒理想的架构中立设计;推倒重来会裂解生态,且换个 ABI 仍要面对"一套接口塞两种硬件模型"的同一难题。

---

## 3. 近期 / 在飞的工作(v7.1–v7.2 及后续)

### 3.0 【重点·社区讨论中,未合入】带宽控制/监控泛化:三个在飞 patchset

MPAM 硬件有四种带宽控制机制(`MBW_MAX/MIN/PROP/PBM`),驱动层 `mpam_devices.c` **全部探测且能编程**;但 v7.1 合入的 resctrl 胶水层 `mpam_resctrl.c` **只把 `mbw_max` 暴露成单一百分比 `MB`**(全文无 `mbw_min`/`mbw_prop`)。带宽**监控**(MBWU→`mbm_local/total`)在 resctrl 里**目前也读不到**(`mpam_resctrl.c:498` 仍是 `MBWU ... (not supported)`)。这正是 §2 观点 4"装不下"在带宽维度的体现:**能力驱动已实现、被 resctrl 接口砍掉**。

社区用**三个相互依赖的 patchset**正面攻坚(**全部未合入**,详解见独立文档 **`resctrl带宽泛化三个在飞patchset详解.md`**):

| # | Patchset | 主导 | 层 | 状态 |
|---|---|---|---|---|
| ① | `[RFC] mpam,x86,fs/resctrl: Generic schema description PoC` | Chatre / Intel | 通用框架:多控制 + 自描述 schema(`MB_MIN`/`MB_MAX`) | RFC(仅 x86 dummy 演示;git `controls_rfc_v1`) |
| ② | `arm_mpam: resctrl: Add support for 'MB' resource` | Morse/Horgan / Arm | MPAM 带宽**控制**(MBW_MAX→百分比) | 基础 `MB` 已入 v7.1;MIN/PROP 待 ① |
| ③ | `[RFC PATCH v2 0/5] arm_mpam: resctrl: Counter Assignment (ABMC)` | Horgan / Arm | MPAM 带宽**监控**(MBWU,模拟 AMD ABMC 分配计数器) | RFC;底座已入 v7.2,顶层接线未合 |

你提的 **"MBA control emulation and ARM MPAM MB_MODE support"** 跨 ①②:MB_MODE=① 的多带宽模式;MBA emulation=`mba_MBps` 软件控制器(① 点名为模拟控制头号客户)。**牵头人是 Intel(Chatre 做通用框架)、Arm 做接入(Horgan/Morse)**,面向 MPAM+RISC-V —— 印证 §2 观点 5/6 的治理格局。
1. **可分配带宽监控计数器(ABMC / `mbm_cntr_assign`)** —— 起于 AMD,现被抽象进 fs 核心;当前 fs/resctrl 最活跃的收敛点。Arm 侧引入 `mbm_cntr_assign_fixed`(`ee3d4c81`)、禁止软件控制器与之共存(`f52abe65`)。
2. **MPAM 监控稳定性(NRDY)** —— MPAM 计数有"未就绪"位、需稳定时间;主线在打各 SoC 勘误:CMN-650 CSU(`aeb8595a`)、Nvidia Grace/T241(`dc48eb1f`)、"假装 NRDY 始终硬件管理"简化模型(`4387970b`)。
3. **MPAM v0.1 旧架构版本兼容**(Zeng Heng / 华为)。
4. **io_alloc / SDCIAE**(Intel/AMD L3 I/O 分配)—— **已合入** fs/resctrl(7 个 commit:`48068e56` introduce … `9445c705` enable/disable … `d2bf45d0` "*" shorthand)。
5. **KVM 侧**(见 §4)。
6. **文档点名但未上桌的缺口**:多 socket 内存带宽、CPU-less NUMA(CXL)带宽控制、big.LITTLE 的 CPOR、MPAM 的优先级/带宽下限/比例步进。

---

## 4. 虚拟化角度(与 KVM 方向最相关)

### 4.1 主线 KVM 的 MPAM 是"纯防御性",不是 guest 透传

- **v6.13**:默认对 guest **隐藏 FEAT_MPAM**,补齐 guest 访问 MPAM 系统寄存器的 **trap**(`6685f5d5`、`31ff96c3`)——防 ID 寄存器意外暴露、防 guest 乱摸。
- **v7.1**:当 **host 内核自己在用 MPAM** 时:
  - 保护 host 的 MPAM2_EL2/PARTID 配置不被 trap 切换清掉(`eda1cd1f`);
  - **强制 guest EL1 使用 VMM(用户态)给定的 PARTID 配置**(`67faed4c`),等于把 guest 流量钉在默认/受控分区,守住 host 资源隔离边界;
  - `MPAMSM_EL1` 在 guest 里 UNDEF(`2e7c684b`)。

> ⚠️ 注意:`arm64: mpam: Initialise and context switch the MPAMSM_EL1 register` 的哈希是 `37fe0f98`;"Force guest EL1 用 userspace PARTID" 是 `67faed4c`,勿混。

### 4.2 两个真正的空白(潜在设计/投稿方向)

1. **无 guest 内自管 MPAM/RDT(透传)**:arm64 与 x86 KVM **都没有**把 resctrl 控制权交给 guest。若要做"虚机内资源分区"或"按 vCPU 打 PARTID",这是主线空白——但要先趟平 host 侧刚落地的语义,以及 nested/迁移下 PARTID 空间的一致性。
2. **无 I/O 侧 MPAM**:MPAM 架构上能给**所有**发往内存系统的事务打标签,含 **SMMU(设备 DMA)与 GIC ITS(中断)**;但主线驱动**只接了 CPU 发起的流量**,`include/linux/arm_mpam.h` 把 SMMU 这类 MSC 归到 `MPAM_CLASS_UNKNOWN`(注释 *"Everything else, e.g. SMMU"*)。**设备直通场景下对 DMA 做带宽/缓存 QoS 分区,主线做不到**。

---

## 5. 各方立场速览

- **James Morse(Arm,MPAM 与 resctrl 重构主导)**:务实派。四年把 resctrl 抠成架构中立,再把 MPAM 从后端插进去;代码注释里**主动坦白**所有妥协。不追求推翻 ABI。
- **Dave Martin(Arm)**:定点↔百分比转换层(`80d147d2`),处理 RMID 管理的 x86 假设。
- **Ben Horgan(Arm)**:2025–26 接手大量 MPAM↔resctrl 集成、NRDY 修复、CDP 门控、为 MPAM 适配 fs 核心。
- **Tony Luck / Reinette Chatre(Intel)**:核心与 selftests 守门人,在既有 ABI 内扩 Intel 特性(SNC、遥测 PERF_PKG),对 Arm/AMD 补丁做 gating review。
- **Babu Moger(AMD)**:推 io_alloc、ABMC/mbm_event、SMBA;2025-09 升为 Reviewer。
- **多厂商实测背书**(`80d147d2` 等的 Tested-by):Google(Peter Newman)、Nvidia(Gavin Shan / Fenghua Yu)、华为(Zeng Heng / Hanjun Guo)、Fujitsu(Shaopeng Tan)、Ampere(Jesse Chick)、Qualcomm(Punit Agrawal)、Red Hat —— MPAM 生态采纳面很广。

---

## 6. 信息来源与可信度

- **强证据(本地树逐条 `git show` 核实)**:合入时间线、代码架构、`resctrl_arch_*` 边界、`mpam.rst` 限制、CDP/CBM/带宽/PARTID 具体妥协、cgroup 被否三条历史 commit(`c39a0e2c`/`e6d42931`/`5ff193fb`)、治理结构、KVM 三连 commit、I/O 侧空白(`MPAM_CLASS_UNKNOWN`)。
- **弱证据 / 缺口**:`lore.kernel.org / LWN / LPC` 被反爬拦截,**未合入 / 被 NACK / 纯列表争论无法直接引用**。是否有人私下提过 resctrl2 / cgroup 整合 / 替代 ABI,只能说"在已合入的内核记录里查无实据",不能排除列表上存在;LPC 具体场次、Tejun Heo(cgroup 维护者)对 resctrl 的直接表态、学术评测——**未能证实**。

---

## 附录:调研 agent 错误纠正(以本地 git 为准)

1. 某 agent 称 MPAM 大合并在 **v6.15/v6.16(2026-04)**→ **错**,实为 **v7.1**(其版本与日期自相矛盾,v6.15 是 2025 年)。
2. 某 agent 称 **io_alloc "未找到"**→ **错**,已合入 fs/resctrl(见 §3.4)。
3. 某 agent 称 MPAM 驱动在 `drivers/arm-mpam/`→ **错**,实际在 **`drivers/resctrl/mpam_*.c`**。
4. 某 agent 把 KVM commit `37fe0f98` 标为"Force guest EL1 PARTID"→ **错**,那是 MPAMSM_EL1 上下文切换;正确哈希 `67faed4c`。

---

## 相关文档

- `ARM64_resctrl_mba_MBps可行性分析.md` —— mba_MBps 具体可行性
- `MPAM驱动与resctrl对接分析.md` —— 驱动与 resctrl 对接细节
- `主线vs_openEuler_MPAM支持对比.md` —— 主线与 openEuler 差异
