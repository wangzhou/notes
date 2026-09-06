AI沙箱虚拟化技术分析
====================

-v0.1 2026.09.06 Sherlock init
-v0.2 2026.09.06 Sherlock 重组为"总览矩阵+分章展开"结构，按操作×维度组织
-v0.3 2026.09.06 Sherlock 启动并入总览矩阵，补充技术精简
-v0.4 2026.09.06 Sherlock 总览矩阵按场景拆为四张表

简介：从ARM host视角分析两个开源AI沙箱系统：腾讯云CubeSandbox(基于
cube-hypervisor，Cloud Hypervisor 28 fork)与Moonshot AI AgentENV(基于
firecracker 1.15.1-patch-v1)。文档先给出关键技术总览矩阵(启动/快照/
快照恢复/克隆四个操作，CPU/内存/存储三个维度)，再按操作分章展开
技术细节，另覆盖快照持久化等矩阵之外的贯穿技术。同时以上游
firecracker 1.18-dev作为快照机制的参考实现对照。代码路径：
~/CubeSandbox、~/AgentENV、~/firecracker、~/linux(v7.2-rc4)。
作者：Sherlock。


## 一、系统概览

### 1.1 基本结论

CubeSandbox的hypervisor是cube-hypervisor，即Cloud Hypervisor 28.0.0
的fork(hypervisor/Cargo.toml:2-4)，不是firecracker fork。AgentENV
使用kvcache-ai的firecracker 1.15.1-patch-v1(发布产物下载，非
vendored源码，config/deps_manifest.toml:2)。~/firecracker是上游
1.18.0-dev，本文作为快照机制参考。三个系统构成两条独立技术线：

- 技术线A：cube-hypervisor(Cloud Hypervisor血统)+cubecow存储
- 技术线B：firecracker(上游1.15.1+kvcache私有patch)

两条线共同复用的底层机制：KVM、virtio设备模型、rust-vmm crates、
快照恢复代替冷启动。

### 1.2 CubeSandbox

定位：极速启动、高并发、硬件级强隔离的AI Agent沙箱服务，E2B兼容API。
组件分工：

| 组件 | 职责 |
|------|------|
| CubeAPI | HTTP入口(Rust/Axum)，转CubeMaster |
| CubeMaster | Go调度器，缓冲队列+filter/score选节点 |
| Cubelet | containerd插件，节点上容器生命周期管理 |
| CubeShim | containerd shim，cube-hypervisor以库形式链入同进程 |
| cube-hypervisor | Cloud Hypervisor fork，支持快照/恢复/软脏页增量快照 |
| cubecow | 基于xfs-reflink(FICLONE)的CoW存储引擎 |
| CubeS3lvol | SPDK NVMe/TCP(RCOW) daemon，卷数据放对象存储 |
| CubeProxy | 请求门控(lua)，闲置沙箱暂停/唤醒内联 |
| cube-lifecycle-manager | 闲置沙箱sweeper，触发pause |

关键性能数字(官方benchmark博客与README)：
- 串行冷启动avg 47.8ms/p95 57.4ms，20并发吞吐180.9个/s
- 快照串行单次约50ms，10并发均摊约13ms
- 从快照创建沙箱63.9ms(单并发)/3.6ms每个(50并发)
- 单VM内存摊销21-26MB，单机可跑数千实例

### 1.3 AgentENV

定位：为Kimi K3的agentic RL训练提供大规模agent执行环境，E2B兼容API。
README宣称：snapshot-backed环境50ms内boot/resume、100ms内pause；
增量快照内存+文件系统；fork多个独立沙箱；快照持久化到S3兼容对象存储；
ublk高性能I/O且与内存快照共享host page cache；内存ballooning实现
9.6x overcommit；overlaybd按需加载OCI镜像，生产规模150万镜像。

组件分工：

| 组件 | 职责 |
|------|------|
| gateway/scheduler(Go) | HTTP反代+资源准入(内存上限比例可>100%) |
| agentenv server(Rust) | orchestrator状态机+沙箱管理 |
| warm-pool | 预spawn firecracker进程池 |
| 自研overlaybd(Rust) | LSMT镜像层+内存快照层 |
| uvm-ublk-daemon | 每宿单例，io_uring UringCmd块设备daemon |
| OSS/OSD | 镜像与快照对象存储 |

### 1.4 两系统对比

| 维度 | CubeSandbox | AgentENV |
|------|-------------|----------|
| hypervisor | cube-hypervisor(CH 28 fork) | firecracker 1.15.1-patch-v1 |
| 内存增量快照 | pagemap soft-dirty/anon | KVM dirty log+dirty-memory-ranges API |
| 快照取页方式 | VMM进程内直接读 | process_vm_readv直读FC进程 |
| 存储引擎 | cubecow(FICLONE扁平快照) | 自研overlaybd(LSMT层链) |
| 块设备后端 | SPDK NVMe-oF/virtio-blk | ublk(io_uring) |
| 控制面 | Go CubeMaster/Cubelet+containerd | Go gateway/scheduler+Rust node |
| 进程模型 | VMM以库链入shim进程 | 独立FC进程+warm pool |
| 内存复用 | 快照文件MAP_PRIVATE跨进程共享 | 共享ublk设备读入(page cache共享) |
| 空闲回收 | 闲置pause到快照目录 | TTL pause杀进程零驻留 |

两者互补性很强：CubeSandbox强在存储侧的FICLONE扁平快照和SPDK远端
卷，AgentENV强在内存快照与文件系统快照同构的overlaybd层链、以及
warm pool的工程化。下文先给总览矩阵，再分章展开。


## 二、关键技术总览

### 2.1 关键技术矩阵：启动/快照/快照恢复/克隆 × CPU/内存/存储

脏页追踪、镜像分层、内存复用与回收三项技术不单列，已直接体现在
各操作的内存/存储单元格里。

启动：

| 维度 | CubeSandbox | AgentENV |
|------|-------------|----------|
| CPU | VMM以库链入shim进程，无进程边界(launch_vmm，CubeShim/shim/src/hypervisor/cube_hypervisor.rs:75)；模板VM快照的vCPU状态经restore_vm重放，无冷boot | warm pool预spawn未boot的FC进程+网络slot+workdir(src/sandbox/firecracker/pool.rs:45)，跳过进程创建与API socket轮询 |
| 内存 | 模板内存快照文件MAP_PRIVATE mmap成guest RAM(memory_manager.rs:1514-1530)，写时进程级COW | 内存镜像层经共享ublk设备全量load(instance.rs:523)，共享host page cache |
| 存储 | 挂cubecow模板卷(FICLONE克隆)；卷数据在对象存储，经SPDK NVMe-oF按需读 | 挂rootfs overlaybd ublk设备，层链按需加载；远端块缓存LRU(默认100GB)免回源 |

快照：

| 维度 | CubeSandbox | AgentENV |
|------|-------------|----------|
| CPU | state文件=设备状态serde JSON+DeviceTree+cpu_manager的vcpu状态(vmm/src/lib.rs:713、vmm/src/vm.rs:2262)；aarch64寄存器经KVM_GET_ONE_REG逐条采集(hypervisor/src/kvm/mod.rs:1175-1214) | FC原生Diff快照的state部分：aarch64实时KVM_GET_REG_LIST拿全量寄存器id再逐条GET_ONE_REG(firecracker arch/aarch64/vcpu.rs:407-433)；GIC保存前先把pending/ITS表刷入guest RAM，再逐mpidr取redist+ICC(gic/regs.rs:15-43)；pause时vCPU冻结 |
| 内存 | 三态SnapshotType(vm-migration/src/lib.rs:110-123)：Full整段写 / pagemap_anon筛CoW页 / soft-dirty(pagemap bit55+clear_refs "4\n"武装内核)；增量=先铺base文件、增量页按文件偏移覆盖写；不用KVM dirty log(仅migration用)、无userfaultfd | KVM dirty log(track_dirty_pages=true)+fork私有API /vm/dirty-memory-ranges取脏页范围(instance.rs:480)；脏页范围转SegmentMapping(moffset=FC进程HVA/512)；process_vm_readv直读已pause的FC进程地址空间(process_vm_reader.rs:45)；打包成overlaybd内存层，每轮pause追加一层，>32层合并 |
| 存储 | 磁盘不进VM快照；卷走cubecow：FICLONE reflink的O(1)扁平快照，快照即文件、无ledger；卷数据在对象存储(CubeS3lvol SPDK NVMe-oF先挂成host /dev/nvmeXnY) | rootfs=overlaybd LSMT：seal upper->rename成新层->原地重开upper(image_file.rs:268)；内存层与FS层同构；持久化到OSS(catalog/artifacts/managed-layers布局，稀疏层dense export) |

快照恢复：

| 维度 | CubeSandbox | AgentENV |
|------|-------------|----------|
| CPU | Vm::new_from_snapshot(vmm/src/lib.rs:784)反序列化+重建设备；cpu_manager恢复vcpu状态(aarch64底层SET_ONE_REG，kvm/mod.rs:1324-1346) | load_snapshot_file(resume_vm=false)后resume()；用快照kvi重跑KVM_ARM_VCPU_INIT；含KVM_REG_ARM64_SVE_VLS须在KVM_ARM_VCPU_FINALIZE之前写(vcpu.rs:262-269,320-328) |
| 内存 | 快照文件整体MAP_PRIVATE mmap成guest RAM(memory_manager.rs:1514-1530)，guest写触发进程级COW | 内存镜像层链经共享ublk设备(BackendType::File)让FC全量load(instance.rs:523)；恢复同一快照的所有实例共享同一份Linux page cache(device.rs:461-466注释明说) |
| 存储 | 挂载cubecow卷文件(FICLONE产物)；跨节点恢复走rcow_export/import_snapshot | overlaybd层链按需叠加(upper写层)；远端块缓存默认100GB，LRU+高低水位+磁盘压力驱逐(full_file_cache/cache_pool.rs:325-528) |

克隆：

| 维度 | CubeSandbox | AgentENV |
|------|-------------|----------|
| CPU | 无进程级fork：克隆=从模板快照restore，寄存器全量重放(restore_vm，CubeShim/shim/src/sandbox/sb.rs:923)；运行中回滚=pause2snapshot+restore(rollback.go:366) | 父pause->resume；子从同一snapshot config走start_resume(src/sandbox/firecracker/sandbox.rs:403)，寄存器重放 |
| 内存 | CloneSandboxMemory/CommitTemplateMemory(Cubelet/storage/cubecow_volume_manager.go:270,228)；同一模板内存快照文件被多VMM进程MAP_PRIVATE共享、写时进程级COW——单VM摊销<5MB的根基 | COW在overlaybd层链：只读低层多子共享、每子独立upper；一轮pause产生的新层既是父的检查点又是子的起点(内存与FS同构，fork语义最干净) |
| 存储 | FICLONE reflink克隆=O(1)按extent数计价的卷克隆，模板卷克隆成新卷 | 子的FS写层=每子独立upper；只读低层与镜像层共享远端块缓存 |

### 2.2 矩阵之外的贯穿技术

| 贯穿技术 | 要点 | 展开章节 |
|----------|------|---------|
| 快照持久化与跨节点 | CubeSandbox经rcow_export/import_snapshot；AgentENV经OSS publish/resolve+dense export | 四.4、五.4 |
| 设备状态序列化 | CubeSandbox=serde JSON+DeviceTree；firecracker=bitcode+CRC64；设备先drain+flush再vCPU的保存顺序约束 | 四.1 |
| ARM特殊机制 | GIC寄存器重放不重建、REG_LIST动态集合、soft-dirty在arm64缺位退化、PTIMER不保存/PMU不支持 | 四、五、八 |


## 三、沙箱启动

### 3.1 CubeSandbox冷启动链路

创建调用链(协议逐跳)：

```
E2B POST /sandboxes
    |
    v
CubeAPI(Rust) --HTTP JSON--> CubeMaster(Go)
                                |
                                | 缓冲队列+filter/score选节点
                                v
                          Cubelet gRPC Create
                                |
                                v
                          containerd
                          runtime: io.containerd.cube.v2
                                |
                                v
                     CubeShim TaskService::create
                                |
                                +-> create_sandbox
                                |     |
                                |     +-> start_vm -> restore_vm(模板快照)
                                |     \-> boot_vm(冷boot旁路)
                                |
                                \-> launch_vmm: VMM库线程
```

Cubelet路径：CubeMaster/pkg/cubelet/actions.go:47 -> Cubelet/services/
cubebox/service.go:236 -> cube_container_create.go:368。shim路径：
CubeShim/shim/src/service/task_srv.rs:323 -> sandbox/sb.rs:472。

三个关键设计：

1. VMM以库形式链入shim进程，无独立进程边界。CubeShim依赖
   cube-hypervisor的lib_support feature，launch_vmm
   (CubeShim/shim/src/hypervisor/cube_hypervisor.rs:75)起vmm线程，
   通过channel收发VmCreate/VmBoot/VmRestore(hypervisor/src/lib.rs:86,273)。
   省掉了jailer、socket轮询、API往返等所有进程边界开销。

2. 模板即预热好的VM快照。冷启动一台临时microVM，等到guest内HTTP
   探针返回2xx才冻结存快照(docs/zh/guide/templates.md:13-15)，保证
   快照恢复后guest立即可用，不含有未就绪状态。

3. 沙箱"冷启动"实际走restore_vm(sb.rs:923)。所以CubeSandbox没有
   真正的冷boot路径在线上使用，boot_vm(sb.rs:915)只是旁路。

### 3.2 AgentENV warm pool

AgentENV预热的对象与CubeSandbox不同：warm pool里放的是"预spawn但
未boot的firecracker进程+网络slot+workdir"(src/sandbox/firecracker/
pool.rs:45 WarmFirecracker)，而非VM快照。pool.rs:1-5注释明确目的：
skip process spawn and API socket polling on the critical path，即把
进程创建和API socket握手移出关键路径。池采用低/高水位+几何增长填充
(crates/warm-pool/src/lib.rs:170-183)。

resume路径只有五步(start_resume，src/sandbox/firecracker/sandbox.rs:1692)：

```
start_resume
    |
    +-> 1. 从warm pool取预spawn FC进程
    +-> 2. 挂rootfs overlaybd ublk设备
    +-> 3. 取共享内存ublk设备
    +-> 4. load_snapshot_file(resume_vm=false)
    \-> 5. resume()
```

50ms的构成：进程/网络slot已预热 + 快照恢复代替冷boot + rootfs设备
按overlaybd层链按需加载。

### 3.3 启动加速的共性设计

1. 快照恢复代替冷启动boot。两个系统线上路径都没有guest内核完整
   boot，启动成本从秒级压到数十毫秒。
2. 把"准备"移出关键路径。CubeSandbox提前冻结模板快照，AgentENV
   提前spawn进程和网络资源。
3. 控制面链路逐层裁剪。CubeSandbox砍掉VMM进程边界，AgentENV砍掉
   socket轮询，两者都把E2B语义直接映射到VMM API。

对ARM的启示：这些裁剪全部是进程模型和协议栈层面的，与架构无关；
但快照恢复的vcpu状态重放(见5.2节)在ARM上的ioctl次数远多于x86，
是ARM上恢复时间的第一优化对象。


## 四、快照

### 4.1 快照的构成与保存顺序

以firecracker为参考，快照产物=state文件+内存文件+外部磁盘文件：

- state文件：magic64|version|State|CRC64(firecracker/src/vmm/src/
  snapshot/mod.rs:11-22)，bitcode序列化，CRC64做完整性校验
- 内存文件：恒为全尺寸稀疏文件(set_len，vstate/vm.rs:642-643)
- 磁盘镜像不进快照：VirtioBlockState只存disk_path字符串
  (devices/virtio/block/virtio/persist.rs:54-70,81)，恢复时按路径重开

保存顺序有明确约束(firecracker/src/vmm/src/lib.rs:503-506注释)：
设备先drain+flush，再vCPU/KVM状态，再内存文件，最后补标virtqueue
脏页。原因是设备drain期间产生的中断在恢复后可能丢失，必须先把
设备状态定住；而KVM无法跟踪宿主侧对virtqueue环的写，必须手动
补标进脏页集合，保证下一层diff快照包含queue页。

### 4.2 CPU寄存器维度

CubeSandbox：state文件=设备状态serde JSON+DeviceTree+cpu_manager的
vcpu状态。入口vmm/src/lib.rs:713 vm_snapshot，cpu_manager在
vmm/src/vm.rs:2262取saved_states。aarch64寄存器经KVM_GET_ONE_REG
逐条采集(hypervisor/src/kvm/mod.rs:1175-1214)，这是Cloud Hypervisor
血统的标准做法。

AgentENV/firecracker aarch64：保存时实时调KVM_GET_REG_LIST拿全部
寄存器id再逐条KVM_GET_ONE_REG(arch/aarch64/vcpu.rs:407-433)，无
白名单——存什么完全跟随内核REG_LIST，跨内核版本集合会变，所以
snapshot-editor提供aarch64专用remove-regs子命令做跨版本手术。GIC
保存顺序特殊：先把pending和ITS表刷入guest RAM
(KVM_DEV_ARM_VGIC_GRP_CTRL SAVE_PENDING_TABLES)，再逐mpidr取
redist+ICC(gic/regs.rs:15-43)，icc寄存器按PRIBITS裁剪为Option。

x86对照：x86 VcpuState=cpuid+分块msrs+xsave+sregs+tsc_khz
(x86_64/vcpu.rs:794-817)，靠固定ioctl序列保存；aarch64无GET顺序
限制，代价是数百次单reg ioctl。

### 4.3 内存维度

增量快照的核心是脏页追踪，三个系统里并存四种实现：

| 路线 | 机制 | 使用者 | ARM可用性 |
|------|------|--------|-----------|
| KVM dirty log | memslot注册KVM_MEM_LOG_DIRTY_PAGES，ioctl取位图 | firecracker/AgentENV | 可用，软件路径 |
| pagemap soft-dirty | /proc/self/pagemap bit55+写clear_refs "4\n" | CubeSandbox | 不可用 |
| pagemap anon | pagemap+kpageflags筛anon CoW页 | CubeSandbox | 可用，退化路径 |
| mincore近似 | mincore(2)过估脏页 | firecracker(未开tracking时) | 可用，需关swap |

ARM上有一个关键差异需要强调：CONFIG_MEM_SOFT_DIRTY依赖
HAVE_ARCH_SOFT_DIRTY(mm/Kconfig:1142-1144)，而arm64没有实现
HAVE_ARCH_SOFT_DIRTY。也就是说CubeSandbox的SoftDirty增量快照在
ARM host上无法使用，会静默退化到pagemap_anon路径(soft_dirty.rs
注释明确了这个fallback设计)。pagemap_anon记录的是"自恢复以来所有
CoW匿名页"，随运行时间累积变大，增量效果远差于soft-dirty。

另一个ARM差异：arm64的KVM dirty log全走软件路径——写保护+拆大页+
缺页标记(kvm_arch_commit_memory_region，arch/arm64/kvm/mmu.c:
2572-2603)，每页首次写触发EL2异常；x86有PML硬件脏页FIFO，仅FIFO
满才vmexit。详见软硬结合优化笔记。

CubeSandbox实现：SnapshotType三态定义在vm-migration/src/lib.rs:
110-123，默认Full；分发在memory_manager.rs:3114-3120：

- Full：逐内存区整段写文件
- Incremental：send_pagemap_anon_memory(memory_manager.rs:2388)
- SoftDirty：send_soft_dirty_memory(:2496)，pagemap bit55+clear_refs
  武装内核(vmm/src/soft_dirty.rs:41,52)

增量语义：不是裸delta文件。恢复端(dest)先铺好外部base内存文件
(memory_vol_url指向模板内存快照)，增量页按文件偏移覆盖写。这保证
每份增量快照文件很小，base可跨沙箱共享。API面：ch-remote命令
snapshot/pause2snapshot/restore/resume-from-snapshot
(src/bin/ch-remote.rs:264-312)，VMM HTTP端点/vm.snapshot、
/vm.pause2snapshot、/vm.restore、/vm.resume-from-snapshot
(vmm/src/api/http/mod.rs:202-258)。

两个值得注意的取舍：

1. 全树无userfaultfd(零命中)。与上游Cloud Hypervisor的uffd lazy
   restore路线分道，恢复用MAP_PRIVATE，见5.3节。
2. KVM dirty log仅保留给live migration(memory_manager.rs:2327,3087)，
   不做快照脏页追踪。balloon设备完整存在(virtio-devices/src/
   balloon.rs:49)但上层零调用；virtio-mem仅骨架(vm_config.rs:144-147)。

AgentENV实现(pause流程，pause_sandbox_impl，src/orchestrator/
service.rs:1315)：

```
pause_sandbox_impl
    |
    +-> capture窗口: FC进程活着, vCPU冻结
    |
    +-> PUT /snapshot/create (Diff, 不含内存)
    |
    +-> GET /vm/dirty-memory-ranges (kvcache FC fork专有API)
    |
    +-> convert_dirty_memory_to_overlaybd
    |     |  脏页范围转SegmentMapping(moffset=FC进程HVA/512)
    |     \-> process_vm_readv直读已pause的FC进程地址空间
    |
    +-> 打包成overlaybd内存层(增量层)
    |
    +-> 持久化到对象存储(OSD catalog布局)
    |
    \-> stop()杀FC进程 -> Paused=零驻留内存
```

关键点：

1. kvcache-ai对firecracker的私有patch面：track_dirty_pages=true
   (config/default.toml:318，src/cfg.rs:463-475)在boot/load时经
   /machine-config配置(memory时带KVM_MEM_LOG_DIRTY_PAGES)，并新增
   /vm/dirty-memory-ranges端点(instance.rs:480)。快照本身用Diff
   不含内存，内存增量由AgentENV自己经process_vm_readv取页。
2. process_vm_readv是Linux的跨进程读取原语(无需ptrace)。AgentENV
   用它直读已暂停FC进程的地址空间(process_vm_reader.rs:45)，脏页
   范围按FC进程HVA计算(overlaybd_snapshot.rs:716,797)。这绕开了
   一切virtio/vhost通道，把"取内存"变成纯用户态操作。
3. 增量语义：每次pause追加一层，父层链继承(build_mem_snapshot_
   image_config，overlaybd_snapshot.rs:591)，超过32层触发合并
   (DEFAULT_MAX_OVERLAYBD_SNAPSHOT_LAYERS:43)。
4. 文件系统增量同构：rootfs是纯virtio-blk(无9p/virtiofs)上的
   overlaybd LSMT可写upper，所有块写进upper.data；pause时
   ImageFile::create_snapshot_and_restack(storage/overlaybd/src/
   image/image_file.rs:268)seal upper->rename成新layer->原地重开
   新upper。内存和文件系统的快照因此统一成同一套层链语义。
5. 持久化布局：catalog/records/、artifacts/{id}/、managed-layers/
   {digest}(src/snapshot/repository/backends/oss/layout.rs:13-41)，
   稀疏层需dense export成连续流再上传(dense_export.rs)。
6. 死代码线索：完整的uffd懒加载路径存在于storage/uffd-core(独立
   孤儿crate，SCM_RIGHTS传uffd fd、UFFDIO_COPY/ZEROPAGE，
   handler.rs:250/320/347)，以及load_snapshot_uffd(instance.rs:489，
   #[allow(dead_code)])，均未接线。这是早期设计残留，说明AgentENV
   曾经考虑过firecracker原生UFFD路线，最终选择了ublk读入。

firecracker上游细节(参考)：

1. 双bitmap：KVM侧dirty log记录guest写；宿主侧写guest RAM由VMM
   手动mark_dirty(如devices/virtio/queue.rs:337、block async完成
   路径async_io.rs:63-65)进AtomicBitmap。
2. diff写：dump_dirty(vstate/memory.rs:1109-1142)逐slot按u64 word
   遍历，两bitmap OR合并，连续脏页批量write_all_volatile，干净页
   seek跳过留洞。
3. 绝对偏移写：若mem_file_path就是base快照文件，diff即原地把base
   升级为当前全量(vm.rs:594-599注释)，无需load侧合并；换新文件的
   diff层才需要rebase-snap工具或snapshot-editor edit-memory rebase
   合并。
4. KVM dirty log是消费型：dump失败必须把位图并入本地bitmap防丢页
   (store_dirty_bitmap，memory.rs:1135-1173)。
5. 未使用KVM_CAP_MANUAL_DIRTY_LOG_PROTECT和dirty ring，用的仍是
   老式KVM_GET_DIRTY_LOG(vm.rs:563-592)。
6. 未开启tracking时diff退化用mincore过估(vm.rs:769-800)，要求
   宿主关swap。

### 4.4 存储维度

CubeSandbox实现：

- cubecow：基于xfs-reflink FICLONE的CoW引擎(cubecow/README.md:3)。
  扁平快照模型——快照即文件、快照的快照仍是一次FICLONE、删任一
  快照不影响其他、崩溃恢复靠扫目录重建索引无ledger。设计上明确
  否掉dm-thin(cubecow/src/engine/reflink.rs:7-46的理由：依赖
  内核模块、慢、跨机难)。
- CubeS3lvol：SPDK实现的NVMe/TCP(RCOW)daemon，卷数据在对象存储
  (COS)，本地盘只放WAL/元数据(CubeS3lvol/README.md:2-4)。先以
  NVMe-oF把远端卷挂成宿主/dev/nvmeXnY，cubecow经UnixStream
  JSON-RPC调rcow_*接口(cubecow/src/engine/s3.rs:336)，跨节点靠
  rcow_export/import_snapshot。
- hypervisor/qcow是crosvm派生的qcow2库，仅供本地virtio-blk文件
  后端；E2B Volume插件走virtiofs bind-mount进VM。

AgentENV实现：

- overlaybd LSMT：rootfs可写upper，块写全进upper.data；pause时
  seal+restack成层链。内存快照复用同一层链格式。
- ublk：每宿单例uvm-ublk-daemon，Unix socket+JSON RPC控制面，
  io_uring UringCmd80控制/每队列UringCmd16数据(storage/ublk/src/
  ctrl.rs:11、queue.rs:226)。
- 镜像缓存两层：overlaybd远端块缓存(file cache默认100GB，LRU+
  高低水位+磁盘压力驱逐，full_file_cache/cache_pool.rs:325-528)
  与commit层缓存GC(src/image/cache/service.rs:743/912)。本地盘是
  有界缓存，冷数据驱逐，所以聚合镜像足迹可超本地盘容量几个数量级。
- 持久化：S3兼容对象存储，布局catalog/records等，dense export。

firecracker本身零存储格式支持：磁盘就是外部文件，快照只存
disk_path。这看似简陋，实则是分层解耦——镜像分层、快照、克隆
全部由存储侧承担，VMM只关心一致性：快照时每设备先
prepare_save->drain_and_flush+排空async完成队列，块设备无条件
fsync(device_manager/persist.rs:277-283；device.rs:746-755)，
该fsync不受sync_snapshot_files开关影响。


## 五、快照恢复

### 5.1 通用恢复流程

state文件CRC/版本校验 -> 设备重建(按固定顺序，决定MMIO/GSI分配与
保存一致) -> 内存建立 -> vCPU状态恢复 -> resume。firecracker的顺序
是balloon->block->mmds->net->vsock->rng->pmem->virtio-mem
(device_manager/persist.rs:401-640)，每设备先恢复transport再按原
activated状态重新activate。

### 5.2 CPU寄存器维度

firecracker的aarch64实现(arch/aarch64/vcpu.rs)与x86差异显著：

1. 恢复时用快照中的kvm_vcpu_init重跑KVM_ARM_VCPU_INIT(:314)；
   若含KVM_REG_ARM64_SVE_VLS必须在KVM_ARM_VCPU_FINALIZE之前写
   (:262-269,320-328)。POWER_OFF位在save时已清除，避免secondary
   vCPU恢复后挂起(:247)。
2. GIC不重建(host环境现建，GIC版本由host决定)，纯寄存器重放；
   GICv2/v3间不可互恢复。
3. MPIDR由KVM按vcpu index生成、VMM不可设，存它只为GIC attr定位
   (construct_kvm_mpidrs，lib.rs:755-765)。
4. PMU不支持(init_vcpu对PMU_V3位直接报错，vcpu.rs:303-312)。
   PTIMER状态不进快照，CNTPCT连续性靠host计数器，属简化。
5. 跨恢复的厂商一致性检查只读MIDR_EL1 manufacturer id且仅warn
   (persist.rs:274-305)。

CubeSandbox恢复入口vmm/src/lib.rs:726 vm_restore -> :784
Vm::new_from_snapshot，反序列化JSON/DeviceTree后cpu_manager按
SET_ONE_REG恢复vcpu状态(kvm/mod.rs:1324-1346)。对AI沙箱的含义：
同集群同KVM版本内克隆是自洽的；异构集群需要remove-regs手术，且
guest时间戳跨快照不严格连续。

### 5.3 内存维度

三个系统给出了三种内存恢复范式：

1. MAP_PRIVATE文件映射(firecracker File backend、CubeSandbox)：
   内存快照文件整体mmap成guest RAM(firecracker memory.rs:964-990，
   CubeSandbox memory_manager.rs:1514-1530)，guest写触发进程级COW。
   firecracker对文件过短报错防SIGBUS(:975-981)。
2. UFFD按需填页(firecracker UFFD backend)：先anonymous()建guest
   RAM，注册userfaultfd后经SCM_RIGHTS把fd+区域布局传给外部handler，
   handler用UFFDIO_COPY按需填页(persist.rs:555-663)。hugetlbfs
   快照禁止File恢复强制走此路(persist.rs:457-462)。AgentENV的
   uffd-core就是这条路线的残骸。
3. ublk设备读入(AgentENV)：内存镜像作为overlaybd层链，经共享
   ublk设备(BackendType::File)让FC全量load(instance.rs:523)。
   device.rs:461-466注释点明原理：share a single ublk device (and
   thus the same Linux page cache)，即所有恢复同一快照的FC进程读
   的是同一份host page cache，物理内存复用发生在内核层。

路线1和路线3的共同点：模板内存文件的page cache天然跨进程共享，
写入页才私有化。这是"同模板千实例"密度(<5MB/沙箱账目)的根基，
也是firecracker官方文档强调"mem文件加载后必须视为不可变"的原因
(经page cache的改动会写穿污染所有实例)。

恢复后的内存回收细节：firecracker balloon对常规匿名内存用
MADV_DONTNEED；对file+MAP_PRIVATE恢复场景MADV_DONTNEED无效(会读回
文件页)，改用MAP_FIXED重映射匿名零页打洞(memory.rs:746-813)。

### 5.4 存储维度

CubeSandbox：挂载cubecow卷文件(FICLONE快照产物)，跨节点恢复走
rcow_export/import_snapshot——先SPDK侧export再import成宿主块设备。

AgentENV：overlaybd层链按需叠加(只读低层+新upper)，上层实例只读
共享远端块缓存；恢复前的冷读走file cache LRU(默认100GB)，命中
则免回源对象存储。


## 六、沙箱克隆

### 6.1 CPU寄存器维度

两系统都没有进程级fork，克隆的CPU侧动作都是"从快照restore，
寄存器全量重放"：

- CubeSandbox：克隆=从模板快照restore(restore_vm，CubeShim/shim/
  src/sandbox/sb.rs:923)；运行中沙箱回滚走pause2snapshot+restore
  配置(Cubelet/services/cubebox/rollback.go:366)，shim侧
  resume_vm_cube_with_config(cube_hypervisor.rs:334)。数字：从快照
  创建63.9ms(单并发)/3.6ms每个(50并发)，差值即并发并行度红利。
- AgentENV：fork_sandbox_inner(src/orchestrator/service.rs:635)，
  父沙箱pause(产生新内存层+FS层)->resume，子沙箱从同一snapshot
  config走start_resume(sandbox.rs:403 SandboxBackend::fork)。

### 6.2 内存维度

- CubeSandbox：Cubelet提供CloneSandboxMemory/CommitTemplateMemory
  (storage/cubecow_volume_manager.go:270,228)。同一模板内存快照
  文件被多VMM进程MAP_PRIVATE共享、写时进程级COW——单VM摊销
  <5MB、单机数千实例的机理。
- AgentENV：COW不在host页表，而在overlaybd层链——只读低层多子
  共享、每子独立upper；一轮pause产生的新层既是父的检查点又是子
  的起点(内存与FS同构)。

共享机理对比：

| 维度 | CubeSandbox | AgentENV |
|------|-------------|----------|
| 共享粒度 | 模板内存快照文件 | overlaybd内存层 |
| 共享机制 | 多VMM进程MAP_PRIVATE同一文件 | 共享ublk设备+同一page cache |
| 写时私有化 | 进程级COW | 子独立upper层 |
| 触发点 | guest首次写页 | pause产生新层 |
| 运行期去重 | 无(balloon未接线) | 无(guest自驱动DAMON回收) |

两者都放弃了KSM/balloon运行期去重，转而依赖"同一份快照产物被
多实例共享读"这一静态复用。这与AI沙箱的工作负载特征匹配：克隆
出来的沙箱初始状态完全一致，分歧只在clone之后，静态复用已覆盖
大部分共享收益，且没有KSM的扫描开销和延迟风险。

### 6.3 存储维度

- CubeSandbox：FICLONE reflink克隆=O(1)按extent数计价的卷克隆，
  模板卷克隆成新卷后即独立文件，与内存快照的MAP_PRIVATE共享同一
  套"共享读、写时私有"哲学。
- AgentENV：子的FS写层=每子独立upper；只读低层与镜像层共享远端
  块缓存，fork不产生新的镜像下载。


## 七、虚机内存与存储视角总结

### 7.1 内存视角

| 维度 | CubeSandbox | AgentENV | firecracker上游 |
|------|-------------|----------|-----------------|
| guest内存分配 | memfd/匿名MAP_PRIVATE | FC进程匿名内存 | 两层mmap对齐THP |
| 脏页追踪 | soft-dirty/pagemap_anon | KVM dirty log(fork扩展) | KVM dirty log+手动打点 |
| 增量快照 | base文件+偏移覆盖 | overlaybd层链追加 | 原地升级/rebase |
| 取页方式 | 进程内读 | process_vm_readv | 进程内读 |
| 恢复内存建立 | MAP_PRIVATE | ublk全量load | MAP_PRIVATE或UFFD |
| 内存回收 | balloon未接线 | guest DAMON+free_page_reporting | balloon MADV_DONTNEED/打洞 |
| ARM特有风险 | soft-dirty不可用退化 | dirty log软件WP开销 | 同左 |

共性结论：

1. 增量快照的脏页追踪是ARM上的第一痛点：soft-dirty缺位、KVM
   dirty log软件路径、无硬件PML等价物。
2. 快照文件MAP_PRIVATE/共享page cache是密度根基，代价是恢复后
   文件不可变、回收需特殊打洞。
3. 三个系统都没有运行期内存去重，靠静态共享+guest自回收。

### 7.2 存储视角

AI沙箱存储是三层模型：

```
镜像层(OCI/模板, 只读)
    |
    +-> 快照层(增量, base+delta或层链)
    |
    \-> CoW写层(每实例可写)
```

- CubeSandbox=FICLONE扁平快照实现这三层(每层都是文件)，跨节点靠
  SPDK rcow_export/import。
- AgentENV=overlaybd层链实现这三层(内存与FS同层同构)，跨节点靠
  OSS publish/resolve+dense export。
- firecracker本身不感知分层，只负责快照时设备drain+fsync的一致
  性边界。


## 八、ARM平台分析汇总

### 8.1 支持现状矩阵

| 维度 | CubeSandbox | AgentENV |
|------|-------------|----------|
| hypervisor编译ARM | 完整(arch/aarch64平级x86_64) | 完整(aarch64 release CI) |
| guest镜像 | arm64镜像+vmlinux-arm64 | linux/arm64 Docker镜像 |
| ARM KVM E2E测试 | 缺(CI无arch矩阵) | 缺(无aarch64验证证据) |
| 嵌套虚拟化PVM | 仅x86_64 | 仅x86_64(src/setup/kvm.rs:70) |
| 内存增量快照 | soft-dirty不可用，退化pagemap_anon | KVM dirty log可用 |
| 已知ARM修复 | 64KiB页pagemap索引(23d31267) | 无 |

### 8.2 ARM特有缺口清单

1. CubeSandbox的SoftDirty增量快照在arm64不可用(CONFIG_MEM_SOFT_DIRTY
   依赖HAVE_ARCH_SOFT_DIRTY，arm64未实现)，静默退化到pagemap_anon，
   增量体积随运行时间增长。这是ARM移植的最大功能缺口。
2. 两系统均无ARM KVM E2E，宣称的ARM支持停留在编译层面。
3. arm64的KVM dirty log软件路径(写保护+拆页+缺页)在快照密集场景
   的开销显著高于x86 PML。
4. 64KiB页：pagemap索引按宿主页大小计算(CubeSandbox已修)；
   firecracker的THP对齐假设(2MiB)在64KiB页上有差异；内存摊销
   数字在ARM上会漂移。
5. firecracker ARM特有简化：GIC跨版本限制、PTIMER不保存、PMU
   不可用、异构机型克隆需remove-regs手术。

## 参考文件

- CubeSandbox/hypervisor/vmm/src/lib.rs:713,726,784 快照入口
- CubeSandbox/hypervisor/vmm/src/vm.rs:2262,2292 vcpu状态
- CubeSandbox/hypervisor/hypervisor/src/kvm/mod.rs:1175-1214,1324-1346
- CubeSandbox/hypervisor/vmm/src/soft_dirty.rs soft-dirty增量
- CubeSandbox/hypervisor/vmm/src/memory_manager.rs:1514-1530,2388,2496,3114
- CubeSandbox/cubecow/README.md 存储引擎设计
- CubeSandbox/CubeShim/shim/src/sandbox/sb.rs:472,866,923 启动
- AgentENV/src/orchestrator/service.rs:635,1315  fork/pause
- AgentENV/src/sandbox/firecracker/sandbox.rs:403,1692,2043 fork/恢复/启动
- AgentENV/src/sandbox/ublk/overlaybd_snapshot.rs:591,716,797
- AgentENV/src/sandbox/firecracker/process_vm_reader.rs:45
- AgentENV/src/sandbox/ublk/device.rs:461-466,523 共享page cache
- AgentENV/storage/uffd-core/src/handler.rs uffd死代码
- firecracker/src/vmm/src/persist.rs:169-228,377-493,528-663
- firecracker/src/vmm/src/vstate/vm.rs:563-664 dirty log与内存快照
- firecracker/src/vmm/src/vstate/memory.rs:964-990,1109-1173
- firecracker/src/vmm/src/arch/aarch64/vcpu.rs:247-433
- firecracker/src/vmm/src/arch/aarch64/gic/regs.rs:15-43
- linux/mm/Kconfig:1142-1144 MEM_SOFT_DIRTY依赖
- linux/arch/arm64/kvm/mmu.c:2572-2603 dirty log软件路径
