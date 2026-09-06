AI沙箱性能测试指标与方法
=======================

-v0.1 2026.09.06 Sherlock init

简介：从CubeSandbox、AgentENV、firecracker三个代码库中提炼AI沙箱
(基于microVM的agent执行环境)的关键性能测试指标、测量方法与ARM平台
注意点。先盘点三库的现成性能设施，再抽象出方法论共性和指标体系，
最后给出面向ARM虚拟化开发者的最小可行benchmark方案。作者：Sherlock。


## 一、三库现有性能设施盘点

### 1.1 AgentENV：criterion基准+产品内直方图

crates/benchmarks/下4个criterion基准(Cargo.toml:23-41)：

| 基准 | 内容 |
|------|------|
| snapshot | 真firecracker环境6场景：creation×3(普通/1G脏盘/1G脏内存)、resume、resume_cold、50并发resume |
| ublk_overlaybd | 6个I/O形态：seq读1m_qd8/128k_qd32、rand读4k_qd1/qd64、rand写4k_qd1/qd64，每迭代fadvise DONTNEED保证冷读 |
| orchestrator_store | 纯内存metadata store对照 |
| oci_conversion_pipeline | OCI转overlaybd流水线，合成层模拟下载/apply延迟，显式支持aarch64 |

特点：bounded模式默认10样本报mean/min/max，Rust侧无P50/P99；
缺端到端冷启动分段bench。

更完整的是产品内直方图：SandboxStageTimer/MetricGuard RAII
(src/observability/prometheus.rs:58-85,115-225)把
agentenv_sandbox_stage_duration_seconds打到create_cold
(src/api/impls/sandbox.rs:653)/create_warm:878(含load_snapshot:881)/
fork:1257/pause:1506/snapshot:1538/resume:1696各阶段；另有ublk设备
6操作、镜像解析3段、OSS 5操作的直方图。热路径刻意采样计量、
不调Instant(zfile.rs:31-60)。

### 1.2 CubeSandbox：黑盒业务压测

tests/perf/cubebench.sh(1955行编排器)经CubeAPI黑盒驱动，词表统一：
avg/min/max/p95(ms)+wall(整批墙钟)+per(wall/并发)+QPS。章节：

| 章节 | 内容 |
|------|------|
| 3.2 | 冷启动并发(c=1/10/20/50 create-only，刻意不预热) |
| 3.3 | 单机密度(每批100个直到连续2批增量<10判满，free(1)内存差摊销) |
| 4.1-4.6 | 快照并发/快照vs脏页/从快照建沙箱/回滚/clone/pause-resume |

辅助设施：

- examples/cube-bench(Go CLI)：time包测创建/删除，percentile排序+ceil
- examples/snapshot-rollback-clone/bench_snapshot_dirty.py:44-70：
  从Cubelet本机VMM日志grep真实脏页字节数，对应memory_manager.rs:2451,2597
  的PagemapAnon/Soft-dirty打印
- 生产埋点：CubeShim StatDefer RAII逐阶段Drop必报(CubeShim/shim/src/
  log/stat_defer.rs:14-52,111-115)；Cubelet每flow每step计时写回
  rsp.ExtInfo(Cubelet/plugins/workflow/metric.go:27-60)；Prometheus
  镜像吞吐直方图；guest内agent启动时间轴(agent/src/main.rs:146-394)

可复现基线见docs/blog/posts/2026-06-01-cubesandbox-perf-benchmark.md，
指标定义在其:72-86。

### 1.3 firecracker：最工程化的做法

三个特点：

1. 三类计时源：
   - host打点：ping 500次逐包、iperf3按vCPU数1:1且--time 20 --omit 5
     --json、guest内fio bs4K/iodepth32/numjobs=vcpus、vsock iperf3
     与host C工具vsock_helper自报rtt 15轮×31样本丢首样本
   - guest自报：boot-timer伪设备——guest写magic 123触发FC打印
     Guest-boot-time(含wall+CPU双时钟)，host轮询日志
     (src/vmm/src/devices/pseudo/boot_timer.rs:11-37)
   - FC内部指标：latencies_us.load_snapshot/full_create_snapshot/
     diff_create_snapshot/pause_vm，API请求始末计时
     (src/firecracker/src/api_server/mod.rs:107,152-183)
2. 回归判定外置：tools/ab_test.py对双commit同机交替A/B跑
   permutation test，门槛p<0.01且均值相对差>5%(:236-261,377-398)，
   易噪指标进IGNORED名单；测试内无通过阈值，逐样本落盘metrics.json。
3. 环境工程：CI专用metal独占agent(.buildkite/pipeline_perf.py)，
   aarch64机型m6g/m7g/m8g/m9g metal都在跑(.buildkite/common.py:19-31)；
   CPU固定单NUMA连续核；devtool --performance关turbo、锁P-state、
   x86禁C6深C-state(:866-913)；guest内核/rootfs pin版本。


## 二、方法论共性

从三库提炼出的共识：

1. 计时分三层，以黑盒端到端为真值，内部计时做归因分段：
   黑盒API墙钟 / VMM内部latencies_us / guest内自报。
2. 降噪三件套：丢预热(CubeSandbox注释明言warmup掩盖冷启动，
   cubebench.sh:841-850)+fio/iperf的ramp_time/omit与清page cache+
   机器固定(锁频/禁C-state/独占)。
3. 统计一律报分布(avg/p95/p99/wall/per/QPS)并逐样本落盘；回归
   判定用双commit同机A/B permutation test而非硬阈值——云机噪声
   无法靠固定阈值稳定过滤。
4. 除纯内存bench外全部要真机(KVM+真实镜像)；criterion类可进CI，
   业务数字必须上裸机。


## 三、AI沙箱关键性能指标体系

| 指标 | 定义与意义 | 测试方法 |
|------|-----------|---------|
| 冷启动时间 | 独占式长任务每任务付一次，决定任务单价 | create→guest ready→首命令可执行全程P50/P95+分段归因；create-only并发扫描不预热(cube-bench模式) |
| 快照时间 | 保存agent进度占host成本 | 全量+diff两档，脏页量0/100M/1G扫描看超线性；读latencies_us.full_create_snapshot或VMM日志真实脏页字节 |
| 恢复/resume时间 | warm沙箱取回等待时间 | 30次循环测瞬时分布(test_snapshot.py:103模式)，分段spawn/netns/ublk attach/load/envd-ready |
| pause时间 | 抢占与配额控制的延迟 | latencies_us.pause_vm+停摆期in-flight影响 |
| fork/clone时间与成本 | 批量克隆是并发扩缩关键 | clone wall/per随并发缩放曲线(参考：63.9ms@c=1→3.6ms@c=50)；成本含写层新建、网络接口复用 |
| 沙箱密度 | 每host并发agent容量 | 分批创建到stall判满(run_mvm_bench)，记录内存摊销(21-26MB/VM)与失败原因，区分内存/接口/PID哪层先满 |
| 内存overcommit比 | 预留vs实际RSS，决定可否超卖 | VMM+ublk daemon+guest内核三份都算；firecracker法=host侧排除guest内存区的进程RSS |
| 快照体积 | 决定clone速度与存储成本 | 增量/全量diff bytes+脏页字节数随时间曲线，定增量阈值 |
| 镜像加载时间 | 数GB镜像按需加载是冷启动主成分 | manifest/config/layer-convert分段(resolver.rs:111,282,293)、全量vs懒加载对比、回源命中率 |
| I/O吞吐与延迟 | agent读写仓库/日志/权重 | guest内fio 4k随机(ublk/overlaybd即agent型I/O)+iperf3/vsock双向；每轮drop_caches |
| CPU干扰/抖动 | 共享host多沙箱互踩尾延迟，最易被低估 | 满载host重测冷启动/恢复P99；guest steal time+host CPU%采样；对比空载基线 |
| 端到端请求延迟 | API→调度→创建/复用→执行→返回 | 并发c扫描全程无预热墙钟；按warm命中/冷建分标签 |
| 资源回收时间 | GC不净吃掉密度 | DELETE→资源可复用时长与泄漏检查；循环create+delete看稳态曲线 |

第1、2、3、5、11项对AI沙箱最关键：冷启动与恢复直接决定端到端
体验，fork/clone决定并发扩缩，neighbor noise决定多租户下的尾延迟
是否可控。


## 四、ARM平台注意点

1. 计时一致性：优先host侧monotonic或VMM内部计数(get_time_us)。
   ARM guest内计时经KVM arch timer虚拟化(CNTPCT trap/VHE)，语义
   与x86 TSC不同，跨架构只比相对回归不比绝对值。firecracker
   boot-timer的"guest写magic、host打印"模式天然规避此问题，可照搬。
2. PMU/SVE/NEON：guest内PMU(PMCCNTR)默认受控，需perf_event放行；
   计算型bench(overlaybd压缩/哈希)NEON与x86 SIMD的差异会被误读为
   性能变化，bench须分计算型/I/O型解读。
3. 中断路径：vGIC注入延迟与x86 APIC不同，IRQ密集的vsock/网络小包/
   小I/O尾部延迟不可跨架构直比，须同机同arch A/B。
4. 页大小：ARM host/guest常用16K/64K vs x86 4K/2M，内存overhead、
   overcommit比、UFFD缺页计数结论随页配置漂移，报告必须标注。
5. 调优手段差异：devtool的intel_pstate/禁C6是x86专属，aarch64需
   手动cpufreq performance+关DVFS。
6. 嵌套虚拟化(Mac/qemu上的KVM)vmexit成本与timer精度被放大，绝对值
   与P99不可外推真机，只做功能/相对验证；发布数字上aarch64 metal
   (m6g/m7g系列)。


## 五、ARM开发者最小可行方案

5个优先benchmark：

1. 端到端冷启动分段bench(最优先)：黑盒create-only并发扫描
   (c=1/10/20/50、不预热、P50/P95/wall/QPS，照cube-bench runner.go
   模式)，叠加已有stage计时(AgentENV直方图/Cubelet ExtInfo)归因；
   pin内核+rootfs版本，丢首轮预热，空载与满载各跑一遍。
2. 快照create/restore循环：30次循环测restore瞬时分布(照
   test_snapshot.py:103，读内部latencies_us)；脏页0/100M/1G扫描
   diff create，输出create/restore vs脏页量曲线。
3. 密度+内存摊销：每批100个创建直到stall(照run_mvm_bench)，记录
   存活数、RSS差/VM摊销与失败原因(ENOSPC/408)，区分内存/接口/
   PID哪层先满。
4. 热路径I/O：fio 4k随机读/写(ublk/overlaybd后端，qd1与qd64两档)
   +iperf3与vsock双向吞吐/延迟，并列host CPU%；每轮drop_caches。
5. Neighbor-noise压力：固定N个负载沙箱下重测1、2的P99与guest
   steal time，与空载基线差为抖动预算；回归判定用双commit A/B
   permutation(照ab_test.py：p<0.01+相对差>5%)。

横切卫生：逐样本落盘metrics.json；ARM上锁频关DVFS、标注页大小/
内核/rootfs；密度与延迟分机测；基准前清page cache。

## 参考文件

- AgentENV/crates/benchmarks/Cargo.toml:23-41 四个bench定义
- AgentENV/crates/benchmarks/benches/snapshot_benchmark.rs 6场景
- AgentENV/src/observability/prometheus.rs:58-85,115-225 stage直方图
- CubeSandbox/tests/perf/cubebench.sh:833-1062,1737-1920 编排器
- CubeSandbox/examples/cube-bench/runner.go:25-80 黑盒压测
- firecracker/tests/performance/test_snapshot.py:103,136-142,298-303
- firecracker/tests/performance/test_network.py:63,97 iperf3规范
- firecracker/tools/ab_test.py:236-261,377-398 permutation判定
- firecracker/tests/framework/utils_fio.py:61-103 fio参数
