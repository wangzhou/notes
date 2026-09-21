AI沙箱ARM64超分现状与优化
=========================

-v0.1 2026.09.21 Sherlock init

简介：分析CubeSandbox与AgentENV两个开源AI沙箱在ARM64上的内存/CPU超分
(oversubscription/overcommit)实现现状与可优化点。证据来自本机源码树
~/CubeSandbox、~/AgentENV、~/firecracker(1.18.0-dev作上游对照)、
~/linux(v7.2-rc4)，以及本机openEuler 24.03 aarch64 6.6内核的实际配置。
结论全部基于源码与内核配置证据，不含实测密度数据(原因见第七章)。
作者：Sherlock。


## 一、超分的三层结构

AI沙箱的超分不是单一旋钮，而是三层叠加。分析两个系统时按这三层拆解：

```
超分能力
    |
    +-> L1 准入层超分：承诺 > 物理，调度器按配额比放行
    |       手段：overcommit ratio、quota、filter/score
    |
    +-> L2 运行期回收：把沙箱不用的内存动态还给host
    |       手段：balloon inflate、free page reporting、guest DAMON
    |
    \-> L3 闲置回收：时间维度复用，闲置沙箱腾出物理资源
            手段：TTL pause、快照落盘、杀VMM进程零驻留
```

L1决定敢承诺多少，L2/L3决定承诺能不能兑现。两个系统在L1/L3都有实现，
差距主要在L2。


## 二、CubeSandbox超分现状

### 2.1 L1准入层

节点容量由Cubelet自报quota，CubeMaster采信，不再二次放大。

| 项 | 默认值 | 代码位置 |
|----|--------|----------|
| CPU超分系数 | 2x(NumCPU*1000*2) | node_status.go:39,651-665 |
| 内存超分系数 | 1.25x(MemTotal*5/4) | node_status.go:41,667-687 |
| 每MVM内存记账 | 512MB | node_status.go:43,689-701 |
| Master的overcommit_ratio | 已废弃，解析时告警忽略 | config.go:254-258,972 |

这些系数可被host.quota配置覆盖(mcpu_limit/mem_limit/mvm_limit，
Cubelet/pkg/config/config.go:44-72)，conf.yaml:18-23默认全为空即走系数。

filter侧是quota与实际负载双卡：

- 内存：quotaMemFree = QuotaMem - EffectiveAllocated，且
  loadMemFree = MemMBTotal - MemUsage须大于请求加预留
  (memfilter.go:32-66)，预留默认10GiB(config.go:446-455,990)
- CPU：quotaCpuFree = QuotaCpu - allocated，且CpuUtil >= 80%直接拒绝
  (cpufilter.go:32-65，NodeMaxCpuUtil默认80，config.go:983-984)

注意，内存超分只有1.25x。这个数字远低于AgentENV宣称的9.6x，原因在L2。

### 2.2 L2运行期回收：缺失

内存复用完全靠静态共享，没有运行期归还通道。

模板快照以MAP_PRIVATE映射成guest RAM，多个VMM进程共享同一份page
cache，guest写才CoW私有化(memory_manager.rs:1514-1516)。这是单VM
摊销21-26MB的机理，但它是静态的：CoW出来的私有页在沙箱生命周期内
只增不减。

memory_manager.rs全文没有MADV_DONTNEED/MADV_FREE/打洞回收，唯一的
madvise是THP提示(:1556)与可选KSM标记(:1847-1869，mergeable默认false，
vm_config.rs:192)。

balloon设备实现是完整的：

- inflate走fallocate(PUNCH_HOLE)加MADV_DONTNEED(balloon.rs:149-166)
- deflate走MADV_WILLNEED(balloon.rs:198-201)
- free page reporting队列有实现(balloon.rs:224-250,370-382)

但上层Shim/Cubelet/CubeMaster/CLM/CubeProxy对balloon零调用，
free_page_reporting默认关(config.rs:1374-1377)。即设备可用但未接线。

### 2.3 L3闲置回收：完整

cube-lifecycle-manager的sweeper按空闲时长触发：

```
sweeper轮询
    |
    +-> baseline = max(LastActiveMs, CreatedAt)     sweeper.go:119-146
    |     idleFor >= IdleTimeout(默认5min)?         config.go:107
    |
    +-> AutoPause -> CubeMaster Pause               sweeper.go:168-254
    |     |
    |     \-> Cubelet PauseToSnapshot               pause_cow.go:189-491
    |           |                                    CubeShim sb.rs:1365-1431
    |           +-> VmPauseToSnapshot，等vmshutdown
    |           \-> keep_tombstone Destroy          pause_cow.go:447-466
    |                 -> shim进程退出，guest RAM全释放
    |
    \-> 唤醒：CubeProxy检测paused态，capture触发CLM /internal/resume
          sandbox_state.lua:77-124
```

pause后VMM进程彻底退出，宿主内存零驻留，与AgentENV同级。
paused_resource_release_ratio控制pause后配额回收比例再放给调度。

### 2.4 压力响应：无

全树无PSI、无/proc/pressure读取、无水位触发的拒绝或降载。
/proc/meminfo只在注册时读MemTotal算默认quota(node_status.go:754-779)。
OOM只在guest侧感知(events.go:242-255 TaskOOM)。


## 三、AgentENV超分现状

### 3.1 L1准入层

配置项max_memory_allocated_percent与max_cpu_allocated_percent，注释
明写can exceed 100 (overcommit)(config.go:45-48)。另有含paused沙箱的
独立上限MaxSandboxCountIncludingPaused等(config.go:55-57)。

注意，这些字段是*uint32指针且defaultConfig()不初始化，缺省即nil即
不设限。README示例给的150(1.5x)只是示例，不是默认值。

filter逻辑(filter.go:40-63)：

```
allocatedPercent = allocated * 100 / total
allocatedPercent > max_*_allocated_percent ? 剔除候选
```

数据来自节点心跳NodeSnapshot，paused沙箱的VM资源在统计里视为已释放
(metrics.rs:69-106)，单独计入paused字段。scheduler只过滤候选、返回
Unavailable，不主动pause。

### 3.2 L2运行期回收：guest自驱动

9.6x overcommit的真实机理是guest主动回收加free page reporting，
不是host主动挤压。

host侧balloon配置(instance.rs:417-435)：

| 字段 | 值 | 含义 |
|------|-----|------|
| amount_mib | 0 | 目标恒为不膨胀 |
| deflate_on_oom | true | guest OOM时自动泄气兜底 |
| free_page_reporting | true | 开启reporting队列 |
| stats_polling_interval_s | None | 不轮询balloon统计 |

即balloon只当free page reporting的载体，没有动态inflate/deflate策略，
没有按host内存压力调节的代码。调用点只在冷启动start_fresh
(sandbox.rs:2151-2155)，resume路径靠vm_state恢复(sandbox.rs:1693-1698)。

guest侧靠内核命令行挂DAMON reclaim(config.rs:42-55、default.toml:33)：

| 参数 | 默认值 | 含义 |
|------|--------|------|
| min_age | 60000000ns | 冷60s才回收 |
| quota_ms / quota_sz | 100ms / 1GiB | 每轮回收预算 |
| wmarks_high/mid/low | 900/700/200‰ | 空闲<70%起回收，<20%激进 |
| wmarks_interval | 5000000us | 5s查一次水位 |
| skip_anon | Y | 只回收file-backed即pagecache |

注意skip_anon=Y这一条：DAMON只回收guest的pagecache，不碰匿名页。
agent负载(Python解释器堆等)大头是匿名内存，所以这条链路回收的是
镜像/文件缓存，不是业务堆。9.6x的成色需要按负载类型区别看待。

完整链路：

```
guest DAMON回收冷pagecache
    |
    v
页进guest buddy自由链
    |
    v
page reporting队列上报free block          mm/page_reporting.c:276
    |
    v
host balloon收到descriptor
    |
    v
FC discard_range -> MAP_FIXED匿名重映射   memory.rs:746-780
    |                 (MAP_PRIVATE file映射下不能用MADV_DONTNEED)
    v
host物理页释放
```

### 3.3 L3闲置回收：激进

| 项 | 默认值 | 代码位置 |
|----|--------|----------|
| 默认沙箱TTL | 15s | default.toml:205，cfg.rs:583 |
| 扫描间隔 | 1000ms | default.toml:203，cfg.rs:581 |
| auto-resume保底TTL | 300s | default.toml:207 |
| timeout动作 | Pause或Delete | metadata.rs:17-20 |

evict_expired_sandboxes(service.rs:2139-2197)按expires_at扫描，Pause
动作杀FC进程零驻留。15s这个默认值极其激进，是它敢在L1不设限的底气：
沙箱大部分时间不占物理内存。

warm pool水位默认low=2/high=64(default.toml:287-290)，预spawn的FC
进程不下发machine-config(pool.rs:292-342)，驻留只是FC进程自身开销。

### 3.4 压力响应：只有OOM兜底

无PSI、无水位闭环。/proc/meminfo的MemTotal/MemAvailable只上报心跳
指标，不驱动决策(observability/host.rs:118-131)。

唯一安全阀是给FC进程设oom_score_adj=1000(instance.rs:135-141)，即让
FC当OOM首选牺牲品保护server进程。换句话说，OOM killer就是最后一道
准入控制。


## 四、两系统超分能力对比

| 维度 | CubeSandbox | AgentENV |
|------|-------------|----------|
| L1内存超分默认 | 1.25x(可配) | 不设限(nil，可配) |
| L1 CPU超分默认 | 2x(可配) | 不设限(可配) |
| L1兜底 | CpuUtil 80%硬顶+10GiB内存预留 | 无 |
| L2运行期回收 | 无(balloon未接线) | guest DAMON+free page reporting |
| L2回收范围 | 不适用 | 仅pagecache(skip_anon=Y) |
| L2主动挤压 | 无 | 无(amount_mib恒0) |
| L3闲置阈值 | 5min | 15s |
| L3回收彻底性 | 杀shim进程，零驻留 | 杀FC进程，零驻留 |
| 内存静态共享 | 模板快照MAP_PRIVATE多进程共享 | 共享ublk设备同一page cache |
| host压力闭环 | 无 | 无(仅oom_score_adj=1000) |
| vCPU默认数 | 1(vm_config.rs:68) | 2(cfg.rs:309-310) |
| CPU cgroup限额 | 有(cgroup.go:228-237) | 无 |
| vCPU绑核 | VMM支持但Shim不传，生产无pinning | 无 |

两条路线的取舍很清楚：

- CubeSandbox靠静态共享加保守配额，L2空缺用L3的5min pause补，
  适合长驻沙箱但单机密度上限受限于CoW私有页只涨不落
- AgentENV靠激进L3(15s TTL)把L1放开，L2只做guest自驱动的弱回收，
  适合短任务agent，长驻沙箱下9.6x的成色要打折

CubeSandbox要把内存超分从1.25x往上推，L2接线是必经之路。


## 五、ARM64特有问题

### 5.1 AgentENV脏页路径硬编码4K，64K页host直接不可用

overlaybd_snapshot.rs:46定义FIRECRACKER_DIRTY_PAGE_SIZE = 4096，
转换前强校验：

```rust
// overlaybd_snapshot.rs:720-722
ensure!(dirty_ranges.page_size == 4096, ...);
```

dirty ranges的page_size来自FC的/vm/dirty-memory-ranges(instance.rs:480)，
反映的是FC内存映射的实际host页。64K页host上该值为65536，直接报错。
后果是pause打包快照失败，而pause正是AgentENV超分的生命线(L3)，
等于超分能力整体失效。

同一文件的moffset = base_host_virt_addr / OVERLAYBD_ALIGNMENT，
OVERLAYBD_ALIGNMENT = 512(:47)，隐含4K页对应8扇区，无按页大小换算。

对照：ublk侧是动态取的(queue.rs:123-124调getpagesize)，说明团队知道
这个问题，只是快照路径没跟上。

### 5.2 free page reporting在4K guest/64K host组合下静默失效

这条链路的页大小有三方：guest页、reporting order、host页。

guest侧内核已经处理了64K guest的问题。virtio_balloon.c:1021-1037：

```c
vb->pr_dev_info.order = PAGE_REPORTING_ORDER_UNSPECIFIED;
/* 默认order是pageblock_order，在ARM64 64KB基页下对应512MB，
 * 空闲块凑不出这么大就永远不触发上报，故指定order=5即2MB */
#if defined(CONFIG_ARM64) && defined(CONFIG_ARM64_64K_PAGES)
	vb->pr_dev_info.order = 5;
#endif
```

该修复是commit f8af4d0892cb，v5.14-rc1合入，AgentENV的guest内核
6.1.175已包含。默认路径见page_reporting.c:369-374取pageblock_order，
pageblock_order = MIN(HPAGE_PMD_ORDER, PAGE_BLOCK_MAX_ORDER)
(pageblock-flags.h:66)，64K页下HPAGE_PMD_ORDER=13即512MB。

但注意该修复紧接着的注释：

```c
/* Ideally, the page reporting order is selected based on the
 * host's base page size. However, it needs more work to report
 * that value. The hard-coded order would be fine currently. */
```

即reporting order无法感知host页大小，这是上游遗留缺口。具体后果：
4K页guest跑在64K页host上，guest按4K粒度算order，上报的块起始地址
只保证4K对齐。host侧madvise/mmap要求host页对齐，未对齐的块在64K
host上返回EINVAL，只增加free_page_report_fails计数，不报错不降级。

要让这条链路在64K host上有效，需要guest的reporting order满足
2^order * guest_page_size >= host_page_size，即4K guest需要order>=4。

### 5.3 VMM侧的host页对齐校验：版本差异明显

上游firecracker 1.18.0-dev已经加了校验(memory.rs:739-744)：

```rust
// The address and length can come straight from a guest descriptor
// (balloon), so reject unaligned input here rather than letting the
// mmap/madvise below fail on it.
let page_size = host_page_size() as u64;
if !caddr.raw_value().is_multiple_of(page_size) || ... {
    return Err(GuestMemoryError::InvalidGuestAddress(...));
}
```

AgentENV用的是FC 1.15.1-patch-v1(deps_manifest.toml:2)。v1.15.1的
discard_range(memory.rs:386-421)只取get_host_address后直接做
mmap(MAP_FIXED|MAP_ANONYMOUS|MAP_PRIVATE)，没有任何对齐校验。
mmap对len会向上取整到host页，所以在64K host上一个4K粒度的descriptor
会覆盖掉64KB，多出来的60KB是guest仍在使用的内存。

触发条件是guest上报了小于host页的块。默认配置下guest的
page_reporting_order取pageblock_order(4K guest下2MB)或ARM64 64K
分支的order=5(2MB)，都远大于64K，所以默认安全。但
page_reporting_order是可写模块参数(page_reporting.c:36 module_param_cb
权限0644)，运维调小即可踩中。属配置相关隐患，不是无条件bug。

CubeSandbox的balloon同病且更重：process_queue逐个PFN处理，
range_len固定为1 << VIRTIO_BALLOON_PFN_SHIFT = 4096(balloon.rs:50)，
无合并、无host页对齐判断。64K host上16个连续4K PFN里只有第1个
64K对齐，其余15个madvise返回EINVAL。

### 5.4 CubeSandbox balloon接线前需先修的两个缺陷

这两个是接L2时必然撞上的，记录清楚免得重复踩。

缺陷一：会打穿共享模板快照文件。create_ram_region的snap_file分支
同时做了两件事(memory_manager.rs:1514-1521)：

```rust
let fo = if let Some(f) = snap_file {
    mmap_flags |= libc::MAP_PRIVATE;
    Some(FileOffset::new(f, snap_offset))   // 注意region带了file_offset
}
```

而balloon的release_memory_range看到region.file_offset()为Some就
fallocate(PUNCH_HOLE)(balloon.rs:~140-160)。这个文件是模板内存快照，
被所有从该模板克隆的沙箱MAP_PRIVATE共享。打洞会把这些页在文件里
清零，污染所有尚未CoW该页的兄弟沙箱。这正是firecracker文档强调
"mem文件加载后必须视为不可变"的场景。

正确做法就是firecracker的实现：(Some(file_offset), MAP_PRIVATE)组合
时改用MAP_FIXED匿名重映射打洞，绝不碰共享文件。原因见FC注释
(memory.rs:752-756)：MAP_PRIVATE file映射下MADV_DONTNEED只丢弃匿名
私有页，后续访问会把文件页重新读回来，所以既无法真正回收也语义错误。

缺陷二：无host页对齐，见5.3。

### 5.5 脏页追踪成本随超分密度放大

已在ARM平台AI沙箱软硬结合优化.md第一章展开，这里只补超分视角的
因果链：

```
arm64 KVM dirty log全软件路径        mmu.c:2572-2603
    |  使能即整段写保护+拆大页
    v
每页首写触发EL2异常 + mmu_lock竞争
    |
    v
pause耗时上升
    |
    v
L3闲置回收周转率下降
    |
    \-> 同样TTL下，单位时间能腾出的物理内存变少 = 有效超分比下降
```

AgentENV每轮pause都开track_dirty_pages，15s TTL意味着高频pause，
这条放大路径在ARM上比x86(有PML硬件FIFO)明显。

一个现成但未用的缓解手段：arm64已select HAVE_KVM_DIRTY_RING_ACQ_REL
(arch/arm64/kvm/Kconfig:29)，而firecracker仍用老式KVM_GET_DIRTY_LOG
全量位图(vm.rs:563-592)。dirty ring避免每轮扫整张位图，密度越高收益
越大。

### 5.6 THP粒度与回收互相打架

恢复后首轮全量脏标记会eager-split掉全部THP(mmu.c:1310/1346)。
4K页下是2MB拆4K；64K页下PMD级THP是512MB，拆分代价是灾难性的。

另有一处上游已知问题，FC自己标注(memory.rs:760-762)：

```rust
// TODO: this does not re-apply the region's madvise flags, so it
// would drop the MADV_HUGEPAGE hint on a THP + file-restore VM.
// That combination is unsupported today; revisit if it becomes
// supported.
```

即THP加file-restore组合在上游FC就是unsupported的。本机THP是
[always]，恰好落在这个组合里。


## 六、优化点

### 6.1 部署层，零代码

| 动作 | 理由 |
|------|------|
| echo y > /sys/kernel/mm/lru_gen/enabled | MGLRU编译进了但默认关，见7.2 |
| 内核参数加psi=1 | PSI编译进了但PSI_DEFAULT_DISABLED=y |
| ARM上坚持4K host页 | 64K页在两系统当前代码下都不安全，见5.1/5.2/5.3 |
| AgentENV显式配max_*_allocated_percent | 默认nil不设限，只靠OOM兜底太裸奔 |
| 沙箱host设THP=madvise而非always | 见5.6，避免与恢复期拆页互斥 |

MGLRU这条值得强调：arm64已select ARCH_HAS_HW_PTE_YOUNG
(arch/arm64/Kconfig:47)，所以LRU_GEN_WALKS_MMU在arm64上是y
(mm/Kconfig:1433-1435)，MGLRU能用硬件AF做页表扫描，与x86同级。
高密度超分场景白白放着不用可惜。

### 6.2 AgentENV代码层

1. 修4096硬编码(overlaybd_snapshot.rs:46,720-722)。按
   dirty-memory-ranges返回的page_size动态换算，而不是ensure拒绝；
   moffset的/512也要按页大小推导。这是64K页ARM64可用性的前置条件。
2. balloon动态inflate。/balloon的resize API现成(instance.rs已有
   set_balloon)，按host MemAvailable或PSI水位驱动amount_mib，把当前
   被动的guest DAMON升级成host主动挤压，覆盖skip_anon=Y够不到的
   匿名内存。
3. backport上游discard_range的host页对齐校验(见5.3)。
4. 补host压力闭环：observability/host.rs已在采MemAvailable，接上
   PSI后可做"压力超阈值则提前pause最低价值沙箱"，替代现在
   oom_score_adj=1000的OOM兜底。

### 6.3 CubeSandbox代码层

1. balloon加free_page_reporting接线。设备层全齐(balloon.rs:149-250,
   370-382)，只差Shim传参与config.rs:1374-1377默认值。这是把内存超分
   从1.25x往上推的唯一通路，也是与AgentENV最大的能力差。
   前置：先修5.4的两个缺陷。
2. 恢复后回收通道。照搬FC的MAP_FIXED匿名重映射方案
   (memory.rs:746-780)，让长驻沙箱CoW出来的私有页可归还。
3. uFFD-WP替代soft-dirty做增量快照。arm64已支持uffd-wp
   (arch/arm64/Kconfig:254-255)，可补上soft-dirty缺位导致的增量快照
   退化，间接提升L3周转率。
4. vCPU绑核接线。每NUMA的cpuset池已有(pool.go:160-213)，VMM侧
   sched_setaffinity也有(cpu.rs:948-990)、CLI也有(config.rs:604-628)，
   但Shim的hypervisor config没有affinity字段，生产上全程无pinning。
   多NUMA ARM(如鲲鹏920双路128核)跨cluster访存代价高于x86跨socket，
   把vCPU线程绑到模板快照page cache所在NUMA节点是低成本收益。

### 6.4 内核与上游，长线

1. stage-2 AF/DBM扩展为脏页汇报(类PML语义)。现有kvm_age_gfn/
   kvm_test_age_gfn框架(mmu.c:2447-2473)是跳板，一次消灭写保护拆页
   风暴。这是ARM虚拟化背景最能发力的上游方向，超分密度场景收益
   一个量级。
2. firecracker接dirty ring(arm64 ACQ_REL已就绪)，替代全量位图。
3. 推动page reporting order感知host页大小，填上5.2的上游缺口。


## 七、本机环境与可验证性

### 7.1 环境

```
内核    6.6.0-98.0.0.103.oe2403sp2.aarch64
页大小  4096 (CONFIG_ARM64_4K_PAGES=y)
CPU     10核
内存    15GB
虚拟化  嵌套KVM虚机
```

### 7.2 关键内核开关实测

| 开关 | 编译 | 运行态 | 影响 |
|------|------|--------|------|
| CONFIG_PSI | y | DEFAULT_DISABLED=y，无/proc/pressure | 压力闭环无信号源 |
| CONFIG_LRU_GEN | y | LRU_GEN_ENABLED未设，运行态0x0000 | MGLRU未启用 |
| CONFIG_DAMON_RECLAIM | y | host侧可用 | 可做host侧回收 |
| CONFIG_KSM | y | sysfs齐全 | 见下 |
| THP | y | [always] madvise never | 与恢复期拆页冲突 |

注意，MGLRU未启用这一条与之前笔记里"MGLRU是密度关键"的判断有出入：
能力在内核里，但openEuler默认没打开，属于部署侧漏项。

KSM虽可用，但结论不变：两系统都不该依赖KSM做运行期去重，扫描开销
与uFFD-WP下的页分裂在ARM上无硬件加成。

### 7.3 本机不可验证的部分

本机是嵌套KVM虚机且并发创建沙箱会失败(见部署笔记坑4：并发下
reset guest time的ttrpc收包超时)，只能串行创建，15GB内存也撑不起
有意义的密度压测。所以本文所有结论是源码与内核配置证据，不是实测
数字。

要拿到真实超分曲线需要非嵌套裸金属ARM机器，测法按
AI沙箱性能测试指标与方法.md的"内存overcommit比"与"沙箱密度"两项：
分批创建到stall判满，记录VMM加guest内核加ublk daemon三份RSS，
host侧排除guest内存区算摊销。报告必须标注host页大小，因为
overcommit比与UFFD缺页计数的结论随页配置漂移。


## 参考文件

CubeSandbox：

- Cubelet/pkg/cubelet/node_status.go:39-43,651-701 quota超分系数
- Cubelet/pkg/config/config.go:44-72 HostConfigQuota语义
- CubeMaster/pkg/base/config/config.go:254-258,446-455,983-990
- CubeMaster/pkg/selector/filter/memfilter.go:32-66 内存准入
- CubeMaster/pkg/selector/filter/cpufilter.go:32-65 CPU准入
- hypervisor/vmm/src/memory_manager.rs:1514-1521,1556,1847-1869
- hypervisor/virtio-devices/src/balloon.rs:50,149-250,370-382
- hypervisor/vmm/src/config.rs:604-628,1374-1377
- hypervisor/vmm/src/cpu.rs:948-990 sched_setaffinity
- hypervisor/arch/src/lib.rs:139 残余PAGE_SIZE=4096
- hypervisor/vmm/src/pagemap_anon.rs:27-47 host_page_size(23d31267)
- cube-lifecycle-manager/internal/sweeper/sweeper.go:119-254
- Cubelet/services/cubebox/pause_cow.go:189-491
- Cubelet/plugins/cube/internals/cgroup/pool.go:160-213 NUMA cpuset池

AgentENV：

- services/shared/config/config.go:45-57 超分比配置
- services/scheduler/internal/filter.go:40-86 准入过滤
- src/sandbox/firecracker/instance.rs:135-141,417-435,480
- src/sandbox/firecracker/config.rs:42-55 DAMON boot args
- src/sandbox/firecracker/sandbox.rs:1693-1698,2151-2155
- src/sandbox/firecracker/overlaybd_snapshot.rs:46-47,716-772
- src/orchestrator/service.rs:2139-2197 TTL evict
- src/orchestrator/metrics.rs:69-106 paused资源口径
- src/observability/host.rs:118-131 MemAvailable仅上报
- config/default.toml:33,203-207,287-290
- config/deps_manifest.toml:2 FC 1.15.1-patch-v1

firecracker：

- 1.18.0-dev src/vmm/src/vstate/memory.rs:739-744 页对齐校验
- 1.18.0-dev src/vmm/src/vstate/memory.rs:746-780 MAP_FIXED方案
- 1.18.0-dev src/vmm/src/devices/virtio/balloon/device.rs:618-653
- v1.15.1 src/vmm/src/vstate/memory.rs:386-421 无对齐校验

linux(v7.2-rc4)：

- drivers/virtio/virtio_balloon.c:1021-1041 reporting order
- commit f8af4d0892cb(v5.14-rc1) ARM64 64K页order修复
- mm/page_reporting.c:36,276,369-374 默认order与模块参数
- include/linux/pageblock-flags.h:66 pageblock_order定义
- arch/arm64/Kconfig:47 ARCH_HAS_HW_PTE_YOUNG
- arch/arm64/Kconfig:254-255 uffd-wp支持
- arch/arm64/Kconfig:1696-1700 ARCH_FORCE_MAX_ORDER
- arch/arm64/kvm/Kconfig:29 HAVE_KVM_DIRTY_RING_ACQ_REL
- arch/arm64/kvm/mmu.c:1310,1346,2447-2473,2572-2603
- mm/Kconfig:1409-1435 LRU_GEN与LRU_GEN_WALKS_MMU

相关笔记：

- AI沙箱虚拟化技术分析.md 两系统快照/克隆机制总览
- ARM平台AI沙箱软硬结合优化.md 脏页追踪与硬件加速
- AI沙箱性能测试指标与方法.md overcommit比与密度测法
- AI沙箱vCPU绑核与自定义guest内核.md 绑核与密度的矛盾
- CubeSandbox部署指导.md 嵌套虚拟化下的并发限制
