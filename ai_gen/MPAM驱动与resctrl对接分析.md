# MPAM 驱动与 resctrl 对接分析

- v0.1 2026.07.20 Sherlock init (AI generated)

配套阅读：`/home/wz/notes/ARM/MPAM基本逻辑分析.md`(协议与整体逻辑)。
本文聚焦 openEuler v6.6 内核 MPAM 驱动的几个实现细节，回答该笔记里遗留的
若干 todo：probe 为什么挂 cpuhp 回调、domain 如何分配、控制与监控如何关联、
resctrl 一个组如何触达系统全部资源。

代码位置：
- 驱动侧：`drivers/platform/mpam/{mpam_devices.c, mpam_resctrl.c, mpam_internal.h}`
- resctrl 核心：`fs/resctrl/{rdtgroup.c, ctrlmondata.c, monitor.c, internal.h}`
- 接口头：`include/linux/resctrl.h`


目录
====
1. 为什么 hw_probe / enable 挂在 cpuhp online 回调里
2. accessibility 由 firmware 决定，不是按 cache 层级
3. cpuhp_setup_state 会立即回放已 online 的 CPU
4. all_devices_probed 的判断逻辑
5. domain 的分配，以及控制/监控如何联系在一起
6. domain 是 component 的运行时投影(1:N)
7. resctrl 一个组如何触达系统全部资源(schemata / mon_data)
8. 数据结构全景图


1. 为什么 hw_probe / enable 挂在 cpuhp online 回调里
====================================================

结论：因为 MSC 寄存器是 MMIO，且只能从“能访问到该 MSC 的 CPU”上读写；
而 platform driver 的 probe 既不保证跑在这样的 CPU 上，boot 阶段这些 CPU
甚至可能还没 online。所以碰硬件的动作只能推迟到 cpuhp online 回调里做。

硬约束在最底层的寄存器访问函数(mpam_devices.c:99)：
```
static u32 __mpam_read_reg(struct mpam_msc *msc, u16 reg)
{
	WARN_ON_ONCE(reg + sizeof(u32) > msc->mapped_hwpage_sz);
	WARN_ON_ONCE(!cpumask_test_cpu(smp_processor_id(), &msc->accessibility));
	...
```
每次读写都断言“当前 CPU 必须在 msc->accessibility 里”。而
mpam_msc_hw_probe()(mpam_devices.c:756) 全是读 ID 寄存器(AIDR/IDR/各 RIS
的 feature IDR)，因此它必须在一个 accessible CPU 上执行。

probe(mpam_msc_drv_probe, mpam_devices.c:1916) 只做与 CPU 无关的“备料”：
- devm_kzalloc(msc)、get_msc_affinity() 算出 accessibility
- ioremap MMIO(映射在哪都行，受限的是“访问”)
- setup error irq、解析 ACPI/DT resources 建 RIS 占位
- list_add_rcu 进全局 mpam_all_msc

probe 末尾 fw_num_msc == mpam_num_msc 才注册 discovery 回调(:2029)：
```
if (!err && fw_num_msc == mpam_num_msc)
	mpam_register_cpuhp_callbacks(&mpam_discovery_cpu_online);
```
即等最后一个 MSC 的 platform device 都 probe 完、全局链表齐了，才开始遍历。

两阶段回调：
- 引导态 mpam_discovery_cpu_online(mpam_devices.c:1668)：只探测“当前 CPU 能
  访问且尚未 probed”的 MSC，探到新的就 schedule_work(&mpam_enable_work)。
    smp_processor_id() == cpu，且 cpumask_test_cpu(cpu, &msc->accessibility)
    过滤，正好满足底层断言。
- mpam_enable(mpam_devices.c:2497) 在 workqueue 里判 all_devices_probed，
  全齐了才 mpam_enable_once()，且用 static atomic_t once 保证只做一次。
- mpam_enable_once(mpam_devices.c:2376) 末尾 cpuhp_remove_state 摘掉 discovery
  回调(:2417)，再 mpam_register_cpuhp_callbacks(mpam_cpu_online)(:2430) 换成
  稳态回调。此后 online 只做 mpam_reprogram_msc + resctrl online/offline。

为什么 enable 要丢进 workqueue 而不在 online 回调里直接做：
mpam_enable_once 要 cpus_read_lock()(:2385) 并调用 cpuhp_remove_state /
cpuhp_setup_state(:2417,:2430)——这些不能在 cpuhp 回调上下文里调，会死锁；
加上它还要跑 resctrl_setup、feature merge、注册 irq 等重活，必须解耦。


2. accessibility 由 firmware 决定，不是按 cache 层级
====================================================

常见误区：以为“只有 L2 私有 cache 才有 CPU 限制，L3/内存控制器没有”。
实际上驱动从不按 L2/L3/MC 区分，它只认 firmware 声明的 affinity。

get_msc_affinity()(mpam_devices.c:1869)：
```
/* ACPI */
err = device_property_read_u32(&dev, "cpu_affinity", &affinity_id);
if (err)
	cpumask_copy(&msc->accessibility, cpu_possible_mask);   // 没声明 -> 全部 CPU
else
	acpi_pptt_get_cpus_from_container(affinity_id, &msc->accessibility);

/* DT */
if (parent == of_root)
	cpumask_copy(&msc->accessibility, cpu_possible_mask);   // 挂根下 -> 全部 CPU
else if (of_device_is_compatible(parent, "cache"))
	get_cpumask_from_cache(parent, &msc->accessibility);    // 挂 cache 节点 -> 该 cache 的 CPU
```

- 没有 cpu_affinity / 挂 of_root 下 -> accessibility = cpu_possible_mask，
  那个 WARN_ON_ONCE 永不触发，等于无限制。这是 L3/SLC/内存控制器的典型情况。
- 指向 PPTT container / 挂 cache 节点 -> 限定到那组 CPU。cluster 私有 cache
  (L2)的典型情况。

关键点：这是 firmware 的自由，不是层级的必然。SoC 完全可以把 mesh 上分片的
SLC、或只从本 NUMA node 可达的内存控制器也声明成亲和的。真正物理原因是
电源域 / 地址路由域：cluster 私有 MSC 的 MMIO 窗口在 cluster 掉电时不可达，
必须由 cluster 内(必然上电)的 CPU 访问。这也是 offline 用 online_refs 引用
计数、最后一个可达 CPU 下线才 mpam_reset_msc 的原因(mpam_devices.c:1721)。

即便 accessibility 是全体 CPU，运行期所有硬件访问也统一走
mpam_touch_msc()(mpam_devices.c:1569)：
```
return smp_call_on_cpu(mpam_get_msc_preferred_cpu(msc), fn, arg, true);
```
mpam_get_msc_preferred_cpu()(:1559)：当前 CPU 可达就用当前 CPU(退化为就地
执行，不 bounce)，否则挑一个 accessible 的 online CPU 弹过去。对全局可达的
L3/MC 不 bounce，对受限的 L2 才 bounce。代码路径对两者一视同仁。


3. cpuhp_setup_state 会立即回放已 online 的 CPU
================================================

疑问：挂 online 回调时，会不会所有 CPU 早就 online 了？
答：这正是最常见的正常情况，而且驱动就靠它完成发现。

mpam_register_cpuhp_callbacks(mpam_devices.c:1736) 用的是 cpuhp_setup_state
(而非 _nocalls)，invoke=true。其内部 __cpuhp_setup_state_cpuslocked
(kernel/cpu.c:2489)：
```
for_each_present_cpu(cpu) {
	int cpustate = st->state;
	if (cpustate < state)
		continue;
	ret = cpuhp_issue_call(cpu, state, true, NULL);   // 在该 cpu 上同步跑 startup
}
```
注册当场就遍历所有 present CPU：凡 cpustate >= 目标 state 的(所有 online CPU
都停在 CPUHP_ONLINE，远高于 CPUHP_AP_ONLINE_DYN)，立即在那个 CPU 上同步执行
一遍 startup 回调。因为是 AP_ 段状态，回调经该 CPU 的 hotplug 线程执行，所以
smp_processor_id() == cpu，正好满足 accessibility 约束。

于是真实 boot 流程：
1. 所有 MSC platform device 陆续 probe，建好 mpam_all_msc。
2. 最后一个 probe 时 fw_num_msc == mpam_num_msc -> 注册 discovery 回调。
3. 就在这次注册调用里，discovery 回调在每个已 online 的 CPU 上同步跑一遍。
4. 此刻所有 CPU 都 online，任意 accessibility 的 MSC 都被覆盖。
5. enable_once 换成稳态回调，同样立即在所有 online CPU 上跑 reprogram +
   resctrl online。

一个 API 同时兜住两种情况：已 online 的 CPU(注册时立即回放，常态)、将来才
online 的 CPU(运行期热插，到时自动触发)。所以驱动不需要在 probe 里自己判断
“现在有没有合适的 online CPU”。


4. all_devices_probed 的判断逻辑
================================

mpam_enable(mpam_devices.c:2497)：
```
list_for_each_entry(msc, &mpam_all_msc, glbl_list) {
	mutex_lock(&msc->lock);
	if (!msc->probed) {
		cpumask_and(&mask, &msc->accessibility, cpu_online_mask);
		if (!cpumask_empty(&mask))
			all_devices_probed = false;
	}
	mutex_unlock(&msc->lock);
	if (!all_devices_probed)
		break;
}
if (all_devices_probed && !atomic_fetch_inc(&once))
	mpam_enable_once();
```

判断的不是“全部 MSC 都 probed”，而是“凡是当前够得着的都 probed 了”：

| MSC 状态                                                | 是否阻塞 enable |
|---------------------------------------------------------|-----------------|
| msc->probed == true (hw_probe 完成，:812 置位)          | 否，跳过        |
| 未 probed，且 accessibility & cpu_online_mask 非空      | 是(还得等)      |
| 未 probed，且 accessibility & cpu_online_mask 为空      | 否(够不着，放行)|

关键是那句 cpumask_and：一个未 probed 的 MSC，只有“现在就有 online CPU 能够
到它”时才拖住 enable(说明 discovery 本该已经探它却还没探到)；若它的 accessible
CPU 此刻全下线，根本没法探，就不该无限期等它。这是鲁棒性权衡：不为“够不着的
MSC”卡死整个 enable。boot 时全核 online，此循环等价于“等所有 MSC 都 hw_probe
完”。

once 去重：mpam_enable 会被多次 schedule_work(每个 CPU 探到新设备调度一次，
:1695)，用 !atomic_fetch_inc(&once) 保证 mpam_enable_once 只执行一次。

注意区分两个“齐了没”：
- fw_num_msc == mpam_num_msc (probe 里，:2029)：所有 MSC 的软件对象都创建好、
  挂上链表。gate “要不要注册 discovery 回调”。
- all_devices_probed (enable 里)：当前够得着的 MSC 硬件都 hw_probe 完。gate
  “要不要真正 enable”。

副作用(可作 todo)：enable_once 一旦跑就把回调换成稳态版(不再 hw_probe)。若
某 MSC 在 enable 那刻恰好不可达(accessible CPU 全 offline)，会被静默漏掉，之后
那些 CPU 再上线也只走稳态回调、不补探。boot 全核 online 通常碰不到；但“延迟
上线的 cluster + 该 cluster 私有 MSC”的拓扑理论上有缺口。


5. domain 的分配，以及控制/监控如何联系在一起
==============================================

结构层次(定义见 mpam_internal.h)：
```
mpam_class(资源类型 L3/L2/MC)           mpam_internal.h:141
  +-> mpam_component[](最小控制单元)    mpam_internal.h:180
        - comp_id                         <- domain id 来源
        - affinity                        <- 哪些 CPU 能访问
        - cfg[]  (per-partid 控制配置)
        - ris list -> mpam_msc_ris[]      mpam_internal.h:234

mpam_resctrl_res(对接 resctrl 的出口)   mpam_internal.h:263
  - class -> mpam_class
  - resctrl_res(内嵌 rdt_resource)

mpam_resctrl_dom(domain 本体)            mpam_internal.h:256
  - comp -> mpam_component               <- 控制与监控的共同纽带
  - resctrl_dom(内嵌 rdt_domain)
  - mbm_local_evt_cfg
```

domain 的创建时机 —— mpam_resctrl_online_cpu(cpu)(mpam_resctrl.c:1526)，即
enable 之后的 mpam_cpu_online 后半段：
```
for (i = 0; i < RDT_NUM_RESOURCES; i++) {
	res = &mpam_resctrl_exports[i];
	if (!res->class) continue;
	dom = mpam_get_domain_from_cpu(cpu, res);      // 已有？只加入 cpu_mask
	if (dom) { cpumask_set_cpu(cpu, &dom->resctrl_dom.cpu_mask); continue; }
	dom = mpam_resctrl_alloc_domain(cpu, res);     // 首次：新建 + online
	resctrl_online_domain(&res->resctrl_res, &dom->resctrl_dom);
}
```

mpam_resctrl_alloc_domain(mpam_resctrl.c:1456) 把 domain 三要素全部来自 comp：
```
list_for_each_entry(comp_iter, &class->components, class_list)
	if (cpumask_test_cpu(cpu, &comp_iter->affinity)) { comp = comp_iter; break; }
dom->comp            = comp;
dom->resctrl_dom.id  = comp->comp_id;              // domain id == comp_id
cpumask_set_cpu(cpu, &dom->resctrl_dom.cpu_mask);
```
一个 component 对应一个 domain；多个 CPU 归属同一 component 只建一个 domain，
后续 CPU online 只往 cpu_mask 加 bit。domain 消亡：offline 把 cpu_mask 清空后
resctrl_offline_domain + kfree(mpam_resctrl.c:1604)。

控制与监控如何联系 —— 共用同一个 mpam_resctrl_dom，经 dom->comp 指向同一个
mpam_component。rdt_resource 用 alloc_capable / mon_capable 两个标志表达
“既能控制又能监控”，二者共享同一 domains 链表，没有独立的“控制 domain 链表”
和“监控 domain 链表”。两条路径都先 container_of 拿 dom，再走 dom->comp：
```
控制写入 resctrl_arch_update_one()(mpam_resctrl.c:1307)
  dom = container_of(d, mpam_resctrl_dom, resctrl_dom)
  mpam_apply_config(dom->comp, partid, ...)   -> 写 MSC 的 MPAMCFG_*

监控读取 resctrl_arch_rmid_read()(mpam_resctrl.c:346)
  dom = container_of(d, mpam_resctrl_dom, resctrl_dom)
  mpam_msmon_read(dom->comp, ctx, ...)        -> 读 MSC 的 MSMON_*
```
comp->ris 列出该 component 对应的所有物理 MSC RIS(如同一 NUMA node 的多个内存
控制器)，配置时对所有 ris 写一遍，监控时聚合多个 ris counter。


6. domain 是 component 的运行时投影(1:N)
=========================================

“resctrl domain 由 mpam component 定义”这个说法抓住了本质，但需两点精确化：

精确化 1：domain 是 component 的运行时投影，不是 component 本身。
- component 是静态拓扑：firmware 解析后固定，affinity 不变。
- domain 是动态实例：cpu_mask 随 CPU 逐个 online 才填满(:1540)，全 offline 后
  kfree 销毁(:1604)。生命周期挂在 CPU 上。
component 定义 domain 的“形状”，domain 多了“当前哪些 CPU 活着”的运行时状态，
resctrl 需要它来决定往哪些 CPU 下发 MSR / 弹 IPI。

精确化 2：一个 component 投影成多个 domain(1:N)。
同一物理 class 被拆成多个 resctrl resource。cache 侧见 mpam_resctrl.c:764-804：
同一 L3 class 被赋给 RDT_RESOURCE_L3 / L3_MAX / L3_MIN / L3_PRI 四个
mpam_resctrl_res，res->class 都指向同一 L3。memory 侧类似(MBA/MB_MIN/MB_PRI/
MB_HDL，:836-854)。而 mpam_resctrl_online_cpu 按 resource 遍历(:1532)，于是同一
L3 component 被投影出 4 个 mpam_resctrl_dom，分属 4 个 rdt_resource 的 domains
链表，但 id 全相同(都是 comp_id)。

严格表述：
  单个 resctrl resource 视角下，component 与 domain 是 1:1；
  跨 resource 全局看，一个 component 对应 N 个 domain(N = 引用该 class 的
  resource 数)，这些 domain 共享 id 和底层 component。

因此可以说：
  resctrl domain = mpam component 在某个 resctrl resource 下的运行时投影。
  component 提供身份/边界/物理通路(静态)，resource 决定投影几份(每个控制维度
  一份)，CPU online/offline 决定这份投影当前的 cpu_mask 和存亡(动态)。


7. resctrl 一个组如何触达系统全部资源(schemata / mon_data)
==========================================================

核心设计：控制组/监控组本身几乎不“拥有”资源。系统资源拓扑是全局单例，一个组
只持有一个标量 id(closid 控制 / rmid 监控)。用户看到的每个文件都是“遍历全局
拓扑、用本组 id 索引”的结果。所以每建一个组，其目录下就自动复制出一整套全资源
视图——因为生成代码永远遍历全局链表。

7.1 控制侧 schemata
-------------------
全局资源登记(挂载时一次) schemata_list_create(rdtgroup.c:2651)：
```
for (i = 0; i < RDT_NUM_RESOURCES; i++) {
	r = resctrl_arch_get_resource(i);
	if (!r->alloc_capable) continue;
	schemata_list_add(r, ...);   // 挂进全局 resctrl_schema_all
}
```
resctrl_schema_all 是“系统全部可控资源”的唯一真相源；每个 schema 记 s->res /
s->name / s->num_closid。

读 schemata rdtgroup_schemata_show(ctrlmondata.c:438)：
```
list_for_each_entry(schema, &resctrl_schema_all, list)   // 遍历所有资源
	show_doms(s, schema, closid);                        // 用本组 closid
```
show_doms(ctrlmondata.c:394) 内层再遍历 r->domains，resctrl_arch_get_config(r,
dom, closid, ...) 用 closid 索引每个 domain 的配置，打印成 L3:0=ffff;1=ffff。
一次 show = 所有 schema x 所有 domain，用本组 closid 取值。

写 schemata rdtgroup_schemata_write(ctrlmondata.c:302)：
- rdtgroup_parse_resource 在全局链表按名字匹配 schema(:291)
- parse_line(:258) 在 r->domains 找 d->id == dom_id，值暂存到 d->staged_config
- 全部解析完，遍历所有 schema 调 resctrl_arch_update_domains(r, closid)(:362)
  统一下发硬件
closid 是索引，domain 是位置；写只是把 (closid, domain) -> value 暂存后 flush。

7.2 监控侧 mon_data
-------------------
目录展开 mkdir_mondata_all(rdtgroup.c:3181)：
```
for (i = 0; i < RDT_NUM_RESOURCES; i++) {
	r = resctrl_arch_get_resource(i);
	if (!r->mon_capable) continue;
	mkdir_mondata_subdir_alldom(kn, r, prgrp);   // 遍历 r->domains
}
```
mkdir_mondata_subdir_alldom(:3145) 每个 domain 建目录 mon_L3_00；目录内
mkdir_mondata_subdir(:3105) 遍历 r->evt_list 每个事件建一个文件。目录树 =
所有 mon 资源 x 所有 domain x 所有 event，这就是“mon_data 显示全部 monitor”。

关键技巧：坐标编码进文件 priv(rdtgroup.c:3103)：
```
priv.u.rid = r->rid;  priv.u.domid = d->id;  priv.u.evtid = mevt->evtid;
mon_addfile(kn, mevt->name, priv.priv);
```
union mon_data_bits(internal.h:79) 把 (rid:10, evtid:8, domid:14) 塞进一个
void* 存成 kernfs private data。每个监控文件自带 (资源, 域, 事件) 三元坐标。

读取时解坐标 rdtgroup_mondata_show(ctrlmondata.c:500)：
```
md.priv = of->kn->priv;
resid = md.u.rid; domid = md.u.domid; evtid = md.u.evtid;   // 文件自带坐标
r = resctrl_arch_get_resource(resid);
d = resctrl_arch_find_domain(r, domid);
mon_event_read(&rr, r, d, rdtgrp, evtid, false);            // rdtgrp 提供 rmid
```
坐标两个来源：(resource, domain, event) 来自文件 priv；(closid, rmid) 来自文件
所在 rdtgroup(由 kn 反查)。这解释了为何同名文件 mon_L3_00/llc_occupancy 出现在
不同组目录下——priv 相同、rdtgrp 不同 -> 读出不同组的占用量。
后续 mon_event_read -> smp_call_on_cpu 到 domain 的 CPU -> __mon_event_count
(closid, rmid, rr) -> resctrl_arch_rmid_read(进 mpam 驱动侧)。

7.3 归纳
--------
| 维度 | 全局拓扑(资源)                              | 每组标量   | 展开产物              |
|------|---------------------------------------------|------------|-----------------------|
| 控制 | resctrl_schema_all x r->domains             | closid     | schemata 一文件覆盖全部 |
| 监控 | mon 资源 x r->domains x r->evt_list         | rmid(+closid)| mon_data 每资源每域每事件一文件 |

“一个组能触达系统全部资源”不是组里存了资源表，而是 mkdir 时用全局拓扑批量生成
视图、读写时用本组标量 id 参数化访问。schemata 每行的 domain id 与 mon_data
目录名里的 00 都是 dom->id = comp_id——控制与监控共用同一 domain id 空间。


8. 数据结构全景图
=================

8.1 Overall layering and ownership
----------------------------------
```
                          User interface (kernfs files)
   /sys/fs/resctrl/<grp>/schemata      .../mon_data/mon_L3_00/llc_occupancy
            |                                        |
============+================ resctrl core layer ====+==============================
            |                                        |
   +----------------+  global list             +----------------+ global list rdt_all_groups
   | resctrl_schema |<- resctrl_schema_all     |  rdtgroup      |<-(ctrl grp / mon grp)
   +----------------+   (one per ctrl resource)+----------------+
   | name  "L3"     |                          | closid         |  <- ctrl identity (scalar)
   | num_closid     |                          | mon.rmid       |  <- mon identity  (scalar)
   | conf_type      |                          | mon.mon_data_kn|
   | res -----------+--+                       | kn (dir)       |
   +----------------+  |                       +----------------+
                       |  several schema may point to one res (CDP)
                       v
   +-------------------------------+   resctrl_arch_get_resource(rid)
   | rdt_resource                  |<-- indexed from mpam_resctrl_exports[].resctrl_res
   +-------------------------------+
   | rid / name                    |
   | alloc_capable  mon_capable    |  <- same resource can be ctrl + mon at once
   | domains ----------+           |
   | evt_list ---------+--+        |  <- monitor event list (llc_occupancy, mbm_*)
   +-------------------+--+--------+
                       |  +-------> mon_evt{ name, evtid }
                       |  (one subdir per domain, one file per event)
                       v  list r->domains
   +-------------------------------+
   | rdt_domain                    |  <- domain: one schemata column / one mon_data subdir
   +-------------------------------+
   | id          (= comp_id)       |
   | cpu_mask    (filled as CPUs   |
   |              come online)     |
   | staged_config[]  ctrl staging |
   | mbm_total / mbm_local  mon st |
   +-------------------------------+
            ^ embedded in                     ^ embedded in
============+=============== glue layer (mpam_resctrl) ============================
            |                                 |
   +------------------+ global array     +----------------------+
   | mpam_resctrl_res | mpam_resctrl_    | mpam_resctrl_dom     |
   +------------------+ exports[N]       +----------------------+
   | class --------+  |                  | comp -------------+  |
   | resctrl_res   |  |(embeds           | resctrl_dom       |  |(embeds rdt_domain)
   +---------------+--+ rdt_resource)    | mbm_local_evt_cfg |  |
                   |                     +-------------------+--+
================ mpam hardware abstraction layer =======+=========================
                   v                                    |
   +---------------------------+  global mpam_classes   |
   | mpam_class                |<-(L3 / L2 / MC ...)    |
   +---------------------------+                        |
   | level / type              |                        |
   | affinity                  |                        |
   | props (hw capability agg) |                        |
   | components ------+        |                        |
   | ida_csu_mon      |        |  <- monitor instance   |
   | ida_mbwu_mon     |        |     allocators         |
   +------------------+--------+                        |
                      v list class->components          |
   +---------------------------+<-----------------------+
   | mpam_component            |   dom->comp points here (ctrl + mon share it)
   +---------------------------+
   | comp_id   (= domain id)   |
   | affinity                  |
   | cfg[] -----------+        |  <- per-partid control config array
   | ris -------------+--+     |
   | class (back-ptr) |  |     |
   +------------------+--+-----+
                      |  v list comp->ris (comp_list)
                      |  +----------------------+
                      |  | mpam_msc_ris         |  <- one resource type (RIS) on an MSC
                      |  +----------------------+
                      |  | ris_idx / idr        |
                      |  | props                |
                      |  | comp_list          <-+ on component
                      |  | msc_list           <-+--+ on msc  (same ris on both lists)
                      |  | comp (back-ptr)      |  |
                      |  | msc  (back-ptr)      |  |
                      |  | mbwu_state ----------+--+--> msmon_mbwu_state{cfg,correction}
                      |  +----------------------+--+
                      v                         |  v list msc->ris (msc_list)
   +-----------------------------+              | +----------------------+
   | mpam_config (cfg[partid])   |              | | mpam_msc             | <- physical MSC device
   +-----------------------------+              | +----------------------+
   | features (which fields valid)              | | id                   |
   | cpbm  (cache portion bitmap)|              | | pdev                 |
   | mbw_max/min  cmax/cmin      |              | | accessibility(cpumask)
   | dspri/intpri                |              | | mapped_hwpage(MMIO)  |
   +-----------------------------+              | | partid_max/pmg_max   |
                                                | | ris -----------------+
       global mpam_all_msc -------------------->| | glbl_list            |
                                                | +----------------------+
                                                +--> actual MMIO: MPAMCFG_* / MSMON_*
```

8.2 container_of bridge (glue layer rides on core structs)
----------------------------------------------------------
```
   mpam_resctrl_res                         mpam_resctrl_dom
   +--------------+                         +--------------+
   | class --> mpam_class                   | comp --> mpam_component
   | +----------+ |                         | +----------+ |
   | |rdt_resource|<-- container_of --> core | |rdt_domain |<-- container_of --> core
   | +----------+ |   (both directions)     | +----------+ |
   +--------------+                         +--------------+

   core calls an arch hook (resctrl_arch_update_domains(r,...) /
                            resctrl_arch_rmid_read(r,d,...))
      gets r/d --container_of--> res/dom --(->class / ->comp)--> program/read hardware
```
核心只认 rdt_resource / rdt_domain；arch 钩子一进 mpam 侧，第一步就是
container_of 还原 res/dom，再顺 ->class / ->comp 摸到硬件。

8.3 how the two scalar ids index into hardware
----------------------------------------------
```
control: rdtgroup.closid --(map to partid)--> mpam_component.cfg[partid] --> write MPAMCFG_*
                                               each domain has its own cfg[]

monitor: rdtgroup.mon.rmid --(map to pmg)--> mon_cfg{partid,pmg} --> set MSMON_CFG_*_FLT --> read counter
         file coordinate union mon_data_bits{rid,domid,evtid}
                                          --> locate (which resource, which domain, which event)
```
- control identity = closid，落点是“每个 domain 的 cfg[partid]”——同一 closid
  在不同 domain 上是独立配置值(所以一行 schemata 里 0=ffff;1=ff00 可不同)。
- monitor identity = rmid，配合文件自带 (rid,domid,evtid) 坐标定位具体 counter。
- schemata 列号、mon_data 目录名的 _00，都是 dom->id = comp_id——控制与监控
  共用同一 domain-id 空间，是二者对齐的根。

8.4 one L3 class expansion (why "1 component -> N domains")
-----------------------------------------------------------
```
                       mpam_class (L3, one physical L3)
                              | components
              +---------------+---------------+
        component#0 (comp_id=0)          component#1 (comp_id=1)
              |                                |
   projected into one domain by each of 4 resources (all domain id = comp_id):
   +--------------+--------------+--------------+--------------+
   | L3    res    | L3MAX res    | L3MIN res    | L3PRI res    |  <- mpam_resctrl_exports[]
   | dom(id=0,1)  | dom(id=0,1)  | dom(id=0,1)  | dom(id=0,1)  |     4 res, class all -> same L3
   +--------------+--------------+--------------+--------------+
        |  the ->comp of all 4 doms point back to the same component
        v
   shows up in schemata as 4 lines, same column numbers (domain id):
        L3   :0=ffff;1=ffff        <- cpbm
        L3MAX:0=...  ;1=...        <- cmax
        L3MIN:0=...  ;1=...        <- cmin
        L3PRI:0=...  ;1=...        <- dspri/intpri
```

要点小结：
1. 三条链表撑起拓扑：class->components、component->ris、msc->ris。mpam_msc_ris
   同时挂在 component 和 msc 两条链表(comp_list / msc_list)，是“逻辑控制单元”
   与“物理设备”的交叉点。
2. 对接层是薄胶水：mpam_resctrl_res / _dom 只加一个指针(class / comp) + 内嵌
   核心结构，靠 container_of 双向走。
3. 控制与监控共用 mpam_component：dom->comp 一个指针同时供控制(cfg[]->MPAMCFG)
   和监控(ris->mbwu_state->MSMON)使用，domain id 也共用。
4. 组只存标量：rdtgroup 里就 closid / rmid 两个数，其余资源视图全是遍历全局
   拓扑现生成。
