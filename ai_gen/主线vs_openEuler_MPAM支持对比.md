# 主线 vs openEuler 内核 MPAM 支持情况对比

- v0.1 2026.07.20 Sherlock init (AI generated)

对比对象：
- 主线：`/home/wz/linux`，`v7.2-rc4-61-g248951ddc14d`
- openEuler：`/home/wz/oe_kernel`，分支 OLK-6.6（基于 v6.6）

配套：`MPAM驱动与resctrl对接分析.md`(openEuler 侧实现细节)、
`/home/wz/notes/ARM/MPAM基本逻辑分析.md`(协议与整体逻辑)。

数据采集方式：并行三路代码盘点(主线 driver / openEuler driver / fs/resctrl 层)
+ 人工复核关键交叉点(见文末“复核修正”)。所有结论附代码证据(文件:行号)。


0. 定性结论(先看这个)
======================

- **同源**：两边都是 James Morse 的 `arm_mpam:` 驱动系列 + 架构无关 `fs/resctrl/`。
  主线 driver 头 `Copyright (C) 2025 Arm`，2025 年才落地 `drivers/resctrl/`(见
  git log：`f04046f2577a arm_mpam: Add probe/remove ...`、`7168ae330e81
  x86,fs/resctrl: Move the resctrl filesystem code to live in /fs/resctrl`)。
  openEuler v6.6 是**提前把这套 patch series 移植**过来，再做下游改造。

- **不是包含关系，是交叉**。谁也不是谁的超集：
  - 主线更前沿的是**架构与框架**：domain 拆分为 ctrl/mon、MBM 硬件计数器分配、
    可配置监控事件、io_alloc、Intel PMT 遥测、KUnit 单测。
  - openEuler 更激进的是**用户可见功能面**：把 L3/L2/MB 拆成 12 个 resctrl 资源
    (MAX/MIN/PRI/HDL)、MBM 带宽监控真正可读、L2 级监控、IOMMU(SMMUv3)的
    CLOSID/RMID。

- **底层硬件特性抽象两边高度重合**(CPOR/CMAX/CMIN、MBW_*、intpri/dspri、
  CSU/MBWU、Partid Narrow、RIS、error irq 都在)，差异在**枚举细化程度**和
  **有没有接通到 resctrl 出口**。

两个最反直觉、也最关键的点(人工验证过)：
1. **MBWU 带宽监控方向相反**：主线通过 resctrl 只能读 llc_occupancy，MBM 读不了
   (`mpam_resctrl.c:520` `if (eventid != QOS_L3_OCCUP_EVENT_ID) return -EINVAL`)；
   openEuler MBM 带宽可读可用。
2. **导出资源方向相反**：主线只导出 L3/L2/MB 三个标准资源；openEuler 拆成 12 个。


1. 硬件特性抽象层(driver 探测/编程能力)
========================================

| 特性 | 主线 v7.2-rc4 | openEuler v6.6 | 备注 |
|---|---|---|---|
| Cache CPOR (cpbm) | 支持 探测+编程+导出 | 支持 探测+编程+导出 | 两边都通到 resctrl |
| Cache CMAX | 部分 探测+reset，未导出 | 支持 导出为 L3MAX/L2MAX | openEuler 通到用户 |
| Cache CMIN | 部分 探测+reset，未导出 | 支持 导出为 L3MIN/L2MIN | 同上 |
| Cache CASSOC | 部分 仅探测(主线有枚举) | 不支持 无枚举 | 都没导出 |
| MBW_MAX | 支持 探测+编程+导出(MB) | 支持 探测+编程+导出(MB) | |
| MBW_MIN | 部分 编程但未导出 | 支持 导出为 MBMIN | |
| MBW_PBM | 部分 编程但未导出 | 支持 探测+编程 | |
| MBW_PROP | 部分 编程(恒 0)未导出 | 支持 探测+编程 | |
| MBW_WINWD | 不支持 仅寄存器宏,从不碰 | 部分 有宏,driver 不编程 | 两边都没真用 |
| intpri / dspri | 部分 探测+reset,未导出 | 支持 导出为 L3PRI/L2PRI/MBPRI | openEuler 通到用户 |
| CSU (llc_occupancy) | 支持 探测+读+导出 | 支持 探测+读+导出 | |
| CSU xcl(exclude clean) | 部分 探测,未暴露 | (无独立处理) | 主线枚举更细 |
| MBWU 计数 31/44/63bit | 支持 三种都探测 | 支持 44/63bit(无独立 31 枚举) | |
| MBWU 读(mbm_*_bytes) | 不支持 rmid_read 返回 -EINVAL | 支持 可读可用 | ★ 方向相反,见 §3 |
| MBWU rwbw 读写过滤 | 支持 | 支持 | |
| capture 事件(CSU/MBWU) | 不支持 枚举有,从不探测 | 不支持 枚举有,从不驱动 | 两边都未启用 |
| monitor 溢出中断 | 不支持 软件累加,不用 HW 中断 | 不支持 软件累加(ACPI 解析了但不注册) | |
| Partid Narrow | 支持 探测+编程 INTPARTID | 支持 探测+编程 INTPARTID | |
| RIS | 支持 | 支持 | |
| error irq(PPI/SPI) | 支持 两种 | 支持 两种 | |
| MSC MMIO 接口 | 支持 | 支持 | |
| MSC PCC 接口 | 不支持 分支返回 -EINVAL | 支持 pcc_mbox 已实现(rx 回调空 TODO) | ★ openEuler 更全 |
| CDP | 支持(需 EXPERT) | 支持 | |
| CPU_PM 睡眠恢复 | 支持 mpam_pm_notifier | 支持 | |
| 虚拟化(VPM/MSC 模拟) | 不支持 | 部分 CPU 侧 VPM 基建就绪,driver 不涉及 | 都无完整虚拟化 |
| KUnit 单元测试 | 支持 test_mpam_{devices,resctrl}.c | 不支持 无 | ★ 主线独有 |

注：主线大量特性标“部分/未导出”——它们在 driver 里能探测/编程，但 resctrl
资源初始化没把它们做成 resctrl 资源，**用户在 schemata 里看不到**。这是主线
“架构完备但功能面保守”的直接体现。

证据要点(主线)：
- CMAX/CMIN/CASSOC 探测 mpam_devices.c:807-821，reset 编程 :1614-1621，未 export。
- MBW_MIN/PBM/PROP 编程 mpam_devices.c:1584-1612，未 export。
- intpri/dspri 探测 :866-877，未 export。
- MBWU 读被挡 mpam_resctrl.c:520。
- PCC 分支 return -EINVAL mpam_devices.c:2093-2094。
- 单测 drivers/resctrl/test_mpam_{devices,resctrl}.c，Kconfig gate KUnit。

证据要点(openEuler)：
- CPOR/CMAX/CMIN 写 mpam_devices.c:1361-1386；MBW_* 写 :1388-1420；pri 写 :1422-1440。
- MBWU 读放行 mpam_resctrl.c:363-373；mon_evt 注册 :1612-1634(含 mbm_*_bytes)。
- PCC 实现 mpam_devices.c:1983-2013(rx_callback 空 TODO :1911)。


2. resctrl 导出资源(用户在 schemata 看到什么)
==============================================

|  | 主线 | openEuler |
|---|---|---|
| 枚举 resctrl_res_level | L3,L2,MBA,SMBA,PERF_PKG(后两 MPAM 不用) | L3,L2,MBA,SMBA + 8 个 MPAM 扩展 |
| 实际导出 | L3 / L2 / MB (3 个) | L3/L3MAX/L3MIN/L3PRI, L2/L2MAX/L2MIN/L2PRI, MB/MBMIN/MBPRI/MBHDL (12 个) |
| 每个控制维度 | 挤在一个资源的不同字段 | 每维度拆成独立 resctrl 资源 |

★ 这解释了 openEuler 那个“L3 拆成 4 行 schemata”的现象——是 openEuler 的下游
设计，主线没有。主线一个 `L3:` 行内部承载 cpbm，CMAX/CMIN/PRI 根本没暴露。

证据：
- 主线 include/linux/resctrl.h:51-60(5 项)，实际只填 L3/L2/MBA
  (mpam_resctrl.c:863/865/923，SMBA/PERF_PKG 从不填)。
- openEuler include/linux/resctrl_types.h(L3..MB_HDL，CONFIG_ARM64_MPAM 下 15 项含哨兵)；
  填充 mpam_resctrl_pick_caches()/pick_mba() (mpam_resctrl.c:709-860)。


3. 监控能力(方向相反的关键差异)
================================

|  | 主线 | openEuler |
|---|---|---|
| llc_occupancy | 支持 可读 | 支持 可读 |
| mbm_total/local_bytes | 不支持 框架就绪但 rmid_read 未接通(:520 -EINVAL) | 支持 可读(注册 mon_evt + rmid_read 分发) |
| L2 监控(l2 occup / mbm core) | 不支持 | 支持 QOS_L2_OCCUP / QOS_L2_MBM_CORE，mount -o l2 |
| Intel PMT 遥测事件(能耗/stall 等 9 个) | 支持(x86 用) | 不支持 |
| MBM 硬件计数器分配(assign/cntr) | 支持 完整框架 | 不支持 |
| 可配置监控事件(evt_cfg/event_filter) | 支持 | 不支持 |
| mon_data 多域求和(sum) | 支持 struct mon_data.sum | 不支持 union mon_data_bits 位域,无 sum |

要点：主线的监控**框架**远比 openEuler 强(计数器分配 mbm_cntr_alloc/free/get、
可配置事件、PMT)，但**具体到 MPAM 的 MBM 带宽读取还没接上**；openEuler 用更朴素
的框架**却把 MBM 读通了、还加了 L2 监控**。这正是“移植早快照 + 下游补功能”的痕迹。

证据：
- 主线 mon_ctx 为三事件都分配(mpam_resctrl.c:384-388)，但 rmid_read 只放 occup(:520)。
- 主线计数器分配框架 monitor.c:374/401/420/1141；mon_data(含 sum) internal.h:109-115。
- openEuler mon_evt: llc_occupancy/l2 occup/mbm_total/mbm_local/mbm_core
  (mpam_resctrl.c:1612-1634)。


4. resctrl 核心层(fs/resctrl)架构差异
======================================

| 维度 | 主线 | openEuler |
|---|---|---|
| domain 结构 | 拆分 rdt_domain_hdr + rdt_ctrl_domain + rdt_l3_mon_domain | 单一 rdt_domain |
| 资源域链表 | 双链表 ctrl_domains + mon_domains | 单链表 domains |
| ctrl/mon scope | 独立 ctrl_scope / mon_scope | 无(共用) |
| online/offline 回调 | 拆成 resctrl_online_ctrl_domain / _mon_domain | 合一 resctrl_online_domain |
| RMID 编码 | idx_encode/decode 抽象层 + arch hook | 直接用 closid+rmid |
| 关键 arch 钩子签名 | 用 rdt_ctrl_domain* / rdt_domain_hdr* | 用 rdt_domain* |
| info/ 文件机制 | RFTYPE_INFO 系列 | 无该机制 |
| debugfs | debugfs_resctrl | 部分 |
| IOMMU CLOSID/RMID | 不支持 | 支持 CONFIG_RESCTRL_IOMMU(SMMUv3) |
| monitor.c 代码量 | 1926 行 | 839 行 |

★ **domain 拆分是主线最大的架构演进**：控制和监控可以有不同 scope，为 SMBA、
PERF_PKG 等铺路。openEuler 移植时这个重构还没发生，所以“控制和监控共用同一个
mpam_resctrl_dom”只对 openEuler 成立——**主线已经是两个独立结构了**(见
MPAM驱动与resctrl对接分析.md 的版本说明补记)。

证据：
- 主线 include/linux/resctrl.h:125-206(domain_type/hdr/ctrl_domain/l3_mon_domain)，
  资源双链表 :319-335。
- openEuler include/linux/resctrl.h:115-130(单一 rdt_domain)，单链表 :233。

arch 钩子集差异(节选)：
- 主线独有：resctrl_arch_mbm_cntr_assign_*、resctrl_arch_config_cntr/cntr_read/
  reset_cntr、resctrl_enable_mon_event、resctrl_arch_io_alloc_*、
  resctrl_online_{ctrl,mon}_domain、resctrl_arch_rmid_idx_encode/decode。
- openEuler 独有：resctrl_arch_is_{llc_occupancy,mbm_total,mbm_local,mbm_core}_enabled、
  resctrl_arch_set_iommu_closid_rmid / match_iommu_*、resctrl_arch_find_domain、
  mbm_config_rftype_init。
- 共享但签名不同：update_one/get_config(ctrl_domain* vs domain*)、
  rmid_read(domain_hdr* vs domain*)、reset_rmid(l3_mon_domain* vs domain*)。


5. Kconfig / 组织
==================

|  | 主线 | openEuler |
|---|---|---|
| 驱动位置 | drivers/resctrl/ | drivers/platform/mpam/ |
| 顶层开关 | ARM64_MPAM(default y) -> select ARM64_MPAM_DRIVER | ARM64_MPAM -> select ARM_CPU_RESCTRL(default y)/ACPI_MPAM/RESCTRL_FS |
| 依赖 | ARCH_HAS_CPU_RESCTRL | + ARM_CPU_RESCTRL，RESCTRL_IOMMU if ARM_SMMU_V3 |
| 单测 gate | KUnit | — |
| 注册方式 | platform_driver | platform_driver |


6. 特性枚举对照(直接抄源码)
============================

主线 enum mpam_device_features (mpam_internal.h:166-192，24 项)：
```
cpor_part, cmax_softlim, cmax_cmax, cmax_cmin, cmax_cassoc,
mbw_part, mbw_min, mbw_max, mbw_prop,
intpri_part, intpri_part_0_low, dspri_part, dspri_part_0_low,
msmon, msmon_csu, msmon_csu_capture, msmon_csu_xcl,
msmon_mbwu, msmon_mbwu_31counter, msmon_mbwu_44counter, msmon_mbwu_63counter,
msmon_mbwu_capture, msmon_mbwu_rwbw, partid_nrw, MPAM_FEATURE_LAST
```

openEuler enum mpam_device_features (mpam_internal.h:86-115，21 项)：
```
ccap_part, cpor_part, cmin,
mbw_part, mbw_min, mbw_max, max_limit, mbw_prop,
intpri_part, intpri_part_0_low, dspri_part, dspri_part_0_low,
msmon, msmon_csu, msmon_csu_capture,
msmon_mbwu, msmon_mbwu_44counter, msmon_mbwu_63counter, msmon_mbwu_capture,
msmon_mbwu_rwbw, msmon_capt, partid_nrw, MPAM_FEATURE_LAST
```
差异：主线把 cmax 细分为 softlim/cmax/cmin/cassoc 四项且有 csu_xcl、mbwu_31counter；
openEuler 是 ccap_part/cmin 两项 + max_limit + msmon_capt。→ openEuler 移植的是
更早快照，主线后续在硬件抽象层继续细化。

主线 enum resctrl_res_level (include/linux/resctrl.h:51-59)：
```
RDT_RESOURCE_L3, RDT_RESOURCE_L2, RDT_RESOURCE_MBA,
RDT_RESOURCE_SMBA, RDT_RESOURCE_PERF_PKG, RDT_NUM_RESOURCES
```
openEuler enum resctrl_res_level (include/linux/resctrl_types.h)：
```
RDT_RESOURCE_L3, RDT_RESOURCE_L2, RDT_RESOURCE_MBA, RDT_RESOURCE_SMBA,
#ifdef CONFIG_ARM64_MPAM
RDT_RESOURCE_L3_MAX, RDT_RESOURCE_L2_MAX, RDT_RESOURCE_L3_MIN, RDT_RESOURCE_L2_MIN,
RDT_RESOURCE_MB_MIN, RDT_RESOURCE_L3_PRI, RDT_RESOURCE_L2_PRI, RDT_RESOURCE_MB_PRI,
RDT_RESOURCE_MB_HDL,
#endif
RDT_NUM_RESOURCES
```


复核修正(相对自动盘点的更正)
============================

- 主线 MBWU：自动盘点一度记“部分支持”，人工核到 mpam_resctrl.c:520 确认**通过
  resctrl 完全读不了**，措辞改为“框架就绪但未接通”。
- 主线 PCC：不是遗漏，是**探测分支显式 return -EINVAL**(mpam_devices.c:2093-2094)；
  openEuler 真的实现了 pcc_mbox，但 rx_callback 空 TODO。两边都不算生产可用，成熟度不同。
- 主线 resctrl_res_level 实为 5 项(多 SMBA/PERF_PKG，MPAM 不用)，openEuler 是
  4 + 8 扩展。


待深挖(todo)
============

- openEuler 那 8 个扩展资源(L3MAX/MIN/PRI 等)对应主线尚未 export 的 CMAX/CMIN/
  intpri——若要 upstream，需按主线 domain 拆分后的接口重写导出层。
- 主线 MBM 计数器分配框架(mbm_cntr_*)与 openEuler 朴素 rmid 读取的语义差异，
  升级 rebase 时是重点冲突区。
- 主线 domain 拆分后，openEuler“控制/监控共用 mpam_resctrl_dom”的模型需要改造成
  ctrl_domain + mon_domain 两套。
