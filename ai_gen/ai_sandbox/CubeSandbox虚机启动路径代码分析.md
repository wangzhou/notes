CubeSandbox虚机启动路径代码分析
==============================

-v0.1 2026.09.07 Sherlock init

简介：CubeSandbox从containerd到guest内容器进程的完整启动路径代码分析,以
QEMU/KVM类比讲解(面向qemu/kvm专家)。含组件映射、逐阶段代码定位、内置打点
系统(stat_defer)、本机实测时延分布,以及"哪段时间太长"的结论。所有行号基于
~/CubeSandbox源码v0.7.0(git d0081641)。作者:Sherlock。


一、组件映射(QEMU/KVM类比)
--------------------------

先纠正一个常见误解:shim不是QEMU,QEMU的对应物是shim进程内嵌的
cube-hypervisor库(cloud-hypervisor系)。

| QEMU/KVM世界 | CubeSandbox对应 | 源码位置 |
|--------------|----------------|---------|
| qemu进程(独立) | cube-hypervisor库,静态链接进shim进程 | hypervisor/(lib_support feature) |
| qemu命令行参数 | VmConfig+device_tree.rs生成的DTB | hypervisor/vmm/src/device_tree.rs |
| libvirt/上层编排 | CubeShim(shim v2)+Cubelet | CubeShim/shim/ |
| KVM_RUN | vCPU线程 | hypervisor/vmm/src/cpu.rs |
| -kernel/-append | DTB chosen节点(kernel/cmdline) | device_tree.rs |
| -drive | pmem/rootfs配置 | VmConfig.payload/disks |
| SIGSTOP vCPU线程 | immediate_exit+thread::park | cpu.rs |
| qemu-guest-agent | cube-agent | agent/ |

关键差异:qemu是独立二进制、命令行驱动;cube里hypervisor被
containerd-shim-cube-rs静态链接(CubeShim/shim/Cargo.toml:
cube-hypervisor={path="../../hypervisor", features=["lib_support"]}),
shim通过进程内channel发ApiRequest驱动,无fork成本(LaunchVmm仅1-2ms)。

shim双重身份:向上对containerd实现Shim v2 API,向下经ttrpc/vsock管
guest内cube-agent(通信协议矩阵见cube-threading-model.md)。

每沙箱进程模型:1个shim进程(containerd-shim-cube-rs,Rust)+shim内嵌
的VMM(每vCPU一个命名线程vcpuN,可选sched_setaffinity绑核,cpu.rs:949)。


二、启动路径逐阶段代码
----------------------

编排总入口:sb.create_sandbox(CubeShim/shim/src/sandbox/sb.rs:478-553)。
start_vm(sb.rs:860-928)是VM启动编排:

```rust
async fn start_vm(&mut self) -> CResult<bool> {
    ch.launch_vmm().await?;                    // 1. VMM实例
    if self.by_snapshot() {
        match self.restore_vm().await { ... }  // 2a. 快照恢复(默认路径!)
    }
    if !snapshot { self.boot_vm().await?; }    // 2b. 冷启动(建模板时)
    // 3. 等VsockServerReady,10秒超时
    let ev = ch.wait_notify(Duration::from_nanos(1000*1000*1000*10)).await?;
    // 4. 连接guest agent(ttrpc over vsock)
    self.connect_agent().await?;
    // 5. 快照路径reset guest;6. add_device;7. CreateSandbox RPC
}
```

各阶段代码位置与内容:

1) launch_vmm(cube_hypervisor.rs:76-100)
   设seccomp白名单、建NotifyEvent channel、VmmInstance::new。
   类比:起qemu进程,但零fork。

2) create_vm(cube_hypervisor.rs:113-125)
   ApiRequest::VmCreate发往VMM线程(hypervisor/src/main.rs:700-730的
   vmm线程处理):MemoryManager(guest RAM)、DeviceManager(virtio设备)、
   CpuManager占位、ARM64生成DTB。

3) boot_vm(cube_hypervisor.rs:126-135)
   ApiRequest::VmBoot->vm.rs:2129的Vm::boot():
   entry_point()载入内核(vm.rs:964 load_kernel)->create_boot_vcpus
   (KVM_CREATE_VCPU+设入口,vm.rs:2170)->configure_system(ARM64设x0=
   DTB地址)->start_boot_vcpus(vm.rs:2223)。boot()返回只代表vCPU已进
   KVM_RUN,不代表guest内核boot完。

   vCPU线程(cpu.rs:940-1000):每vCPU一个命名线程vcpuN,可选
   sched_setaffinity(affinity map为空则不绑核)、seccomp、
   Barrier同步起跑、loop里vcpu.run()=KVM_RUN循环(cpu.rs:1010-1080)。
   暂停/恢复=immediate_exit+thread::park。

4) vsock等待(sb.rs:906-928)
   wait_notify等VsockServerReady事件,10s超时。guest内核boot完、
   cube-agent监听vsock后VMM发该事件。此段无独立打点,是
   CreatePodSandbox减各子项的残差。之前"Receive event timeout after
   10000ms"即此处超时。

5) connect_agent(common/utils.rs:529起)
   经vsock路径UnixStream连agent,发"CONNECT 1024\n"握手,dup出fd建
   ttrpc Client。

6) ResetVm(sb.rs:444-480):两个ttrpc:
   SetGuestDateTime->agent settimeofday(rpc.rs:2136-2152,一个syscall)
   ReseedRandomDev->reseed_rng(rpc.rs:1601-1610)。
   业务微秒级,耗时几乎全是ttrpc/vsock RTT+guest调度延迟。

7) CreateSandbox(sb.rs:497-553):agent rpc.rs:1348 create_sandbox:
   挂virtiofs存储(add storage:0-95ms)、配网络接口/路由/ARP
   (config net:约13ms)、setup_shared_namespaces。agent自带细粒度打点:
   "create sandbox!, config net:Xms, add storage:Yms, ..."。

8) CreateContainer(container/mod.rs:574起,agent rpc.rs:152
   do_create_container):OCI spec解析->container_mounts挂存储->
   update_container_namespaces->setup_bundle写spec->rustjail
   LinuxContainer.start(p)=guest内fork+namespace+mount+cgroup全套。
   类比:guest内runc拉进程。

9) 就绪探针(create流程外,multirun/e2e口径):Cubelet doProbe
   (services/cubebox/probe.go)按模板probe配置(如GET /health@49999)
   轮询到app应答。


三、内置打点系统(stat_defer)
----------------------------

无需自研打点,CubeShim的stat_defer覆盖全启动路径:
shim/src/log/stat_defer.rs定义常量,各调用点用StatDefer::new包一段
逻辑,Drop时落一条带CostTime(毫秒)的日志到
/data/log/CubeShim/cube-shim-stat.log。

| 打点(stat.log CalleeAction) | 位置 | 含义 |
|------------------------------|------|------|
| CreatePodSandbox | task_srv.rs:357 | 总账=init+VM阶段+vsock等待+agent三RPC |
| LaunchVmm | cube_hypervisor.rs:94 | VMM实例化 |
| CreateVm | cube_hypervisor.rs:117 | 内存/设备/DTB |
| BootVm | cube_hypervisor.rs:128 | 载内核+建vCPU+首KVM_RUN |
| RestoreVm | cube_hypervisor.rs:175 | 快照恢复 |
| ResetVm | sb.rs:444 | 对钟+喂随机数 |
| CreateSandbox | sb.rs:497 | agent建sandbox |
| CreateContainer | container/mod.rs:574 | agent起容器进程 |

vsock等待无独立打点=CreatePodSandbox残差。BootVm内部(内核解压/init)
无细打点,仅trace_scoped!/event!宏,生产cube-runtime未编tracing
feature;要细分需重编译或看guest侧dmesg/agent日志时间戳。

关联数据:agent细粒度日志转发进/data/log/CubeShim/cube-shim-req.log
(搜"create sandbox!");VMM日志在/data/log/CubeVmm/vmm.log(67次
"Booting VM"事件,无时间戳)。


四、本机实测时延分布
--------------------

数据源:/data/log/CubeShim/cube-shim-stat.log全部历史样本
(aarch64 openEuler 24.03嵌套KVM,10核15Gi)。

| 阶段 | n | min | p50 | avg | max |
|------|---|-----|-----|-----|-----|
| LaunchVmm | 4 | 1 | 1 | 1.2 | 2 ms |
| BootVm | 3 | 6 | 35 | 27 | 39 ms |
| RestoreVm | 61 | 6 | 9 | 17 | 172 ms |
| ResetVm | 61 | 164 | 238 | 589 | 3005 ms |
| CreateSandbox | 58 | 11 | 56 | 105 | 522 ms |
| CreateContainer | 58 | 55 | 258 | 451 | 1660 ms |
| CreatePodSandbox(总) | 64 | 414 | 774 | 2084 | 10041 ms |

CreatePodSandbox分布双峰:主峰0.5-1s,次峰2-2.5s,尾部偶发5-10s。

空载单次创建(cube-e2e约3.2s)拆解:探针约2.4s+shim CreatePodSandbox
约0.8s(其中VM阶段约10-35ms、vsock等待残差约0.1-0.2s、agent三RPC
约0.55s)。

关键事实:61次RestoreVm对3次BootVm,运行时创建沙箱绝大多数走模板内置
快照恢复(p50 9ms),冷boot只在建模板时发生。

三层数据链:shim stat.log(阶段级)+agent转发日志(阶段内细分)+
vmm.log(boot事件),可按sandbox_id关联成完整时间线。


五、哪段时间太长(结论)
----------------------

1) 最长的单段是就绪探针(约2.4s)=guest内代码解释器起完答/health,是
   业务自身启动,口径问题(官方48ms不含探针,见部署指导7.9)。

2) shim侧内部最长是agent阶段:ResetVm 238ms+CreateContainer 258ms
   合计约0.5s,占shim创建的约60%。VM本身boot仅约35ms,不背锅。

3) 变长的两处:ResetVm最大3005ms、CreatePodSandbox尾部最大10s(内含
   vsock等待),对应之前三类报错:reset guest time ttrpc超时=ResetVm、
   Receive event timeout 10000ms=vsock等待、HTTP 408=30s总闸。

4) ResetVm慢的原因独特:业务只是settimeofday+reseed_rng两个微秒级
   syscall,238ms几乎全是ttrpc/vsock RTT+guest内agent线程调度延迟。
   嵌套虚拟化下guest CPU被抢,agent迟迟不被调度,该值掉到秒级。

5) CreateContainer是真活:guest内fork+namespace+mount+cgroup
   (rustjail,runc类比),258ms在嵌套下正常。

优化方向:探针口径(去掉或预热)、嵌套虚拟化的guest调度延迟(非裸金属
难解)、CreateContainer的fork/mount路径;VM boot本身无可优化空间。


六、研究时延分布的实操
----------------------

1. 开日志级别(需要时):Cubelet用curl localhost:9966/debug/loglevel?
   level=debug;CubeMaster改conf.yaml log.level(热加载);shim/agent的
   stat_defer默认就落盘。
2. 起N个沙箱:multirun --runcnt 20 --runcc 1 --printall req.json。
3. 聚合:CubeShim stat.log按CalleeAction分组统计;agent细分在
   cube-shim-req.log搜"create sandbox!";master总耗时搜
   CalleeAction=ExtInfoCubeE2E(需debug级别)。
4. 想钻BootVm内部:需重编译cube-runtime带tracing feature,或用guest
   内核dmesg时间戳、agent日志对照。
