AI沙箱vCPU绑核与自定义guest内核
===============================

-v0.1 2026.09.06 Sherlock init

简介：分析两个AI沙箱系统(CubeSandbox/cube-hypervisor与AgentENV/
firecracker)在ARM host上的两个实操问题：一是如何绑核启动虚机
(vCPU亲和)，二是如何用自己编译的内核替换guest内核。结论先行：
cube-hypervisor原生支持vCPU亲和(--cpus affinity=)，firecracker
无原生支持需外部taskset/cgroup；两个VMM的aarch64 guest内核都要求
PE格式的未压缩Image产物，替换入口分别在containerd注解与配置
文件。作者：Sherlock。


## 一、vCPU绑核

### 1.1 为什么要绑核

AI沙箱对延迟抖动敏感：快照恢复/克隆是数十毫秒级操作，vcpu线程
被调度器在核间迁移(尤其跨NUMA/cluster)会放大尾延迟；多沙箱共存
时绑核是隔离邻居噪声最直接的手段。firecracker的性能工程经验
(关C-state、锁频后抖动大降)表明host侧调度环境是尾延迟主因，
绑核是同类手段的进程级版本。

### 1.2 两系统现状

| 维度 | CubeSandbox(cube-hypervisor) | AgentENV(firecracker) |
|------|------------------------------|------------------------|
| 原生vCPU亲和 | 支持(--cpus affinity=) | 不支持，无affinity配置 |
| vcpu线程命名 | vcpu0/vcpu1(cpu.rs:972) | fc_vcpu 0(vcpu.rs:193-194) |
| 绑核实现 | VMM内sched_setaffinity(cpu.rs:949-975) | 需外部taskset/cgroup cpuset |

firecracker全树无affinity配置(src/下grep affinity只有GIC/MPIDR
等无关命中)，vcpu线程在thread::Builder spawn时只命名fc_vcpu N
(vstate/vcpu.rs:193-194)，不做任何亲和设置。AgentENV的src/与
services/同样无绑核代码。

cube-hypervisor原生支持：cpu.rs:546 affinity BTreeMap<u8, Vec<u8>>
(vcpu id到host cpu集合)，线程spawn时按vcpu id取cpuset，用
libc::sched_setaffinity绑到vcpu线程(cpu.rs:949-975)。

### 1.3 cube-hypervisor用法

CLI(src/main.rs:115-123的--cpus帮助)：

```
cube-hypervisor --cpus boot=2,affinity=0@[2,3],1@[4,5] ...
```

语法解析在vmm/src/config.rs:595-627：affinity是Tuple<u8, Vec<u8>>，
按'@'拆vcpu与host cpuset(option_parser/src/lib.rs:293-316)，cpuset
是IntegerList，支持"[a,b]"列表与"a-b"区间(option_parser/src/lib.rs:
220-235)。上例含义：vcpu0允许调度到host CPU 2-3，vcpu1允许调度
到host CPU 4-5。注意这是允许集合而非独占，独占需配合host侧隔离
(isolcpus或systemd AllowedCPUs)。

CubeShim接入注意：CubeShim以库形式使用cube-hypervisor，其VmConfig
透传(set_kernel等见sb.rs:752)，affinity是否已在shim的vm配置结构
中透传本次未深挖，需查CubeShim/shim/src/hypervisor/下的VmCreate
请求构造；若不透传可先直接改cube-hypervisor默认vcpus配置
(main.rs:831 affinity: None是默认值)。

### 1.4 firecracker用法(外部绑核)

firecracker无原生支持，三个外部手段：

1. 进程级taskset(最简单)：

```
fc_pid=$(pgrep -x firecracker)
taskset -pc 0-3 $fc_pid          # 整进程绑4核
```

2. 线程级taskset(vcpu0绑CPU2、vcpu1绑CPU3)：

```
# 按线程名找vcpu线程TID(comm为fc_vcpu 0，含空格)
for t in /proc/$fc_pid/task/*; do
    comm=$(cat $t/comm)
    case "$comm" in fc_vcpu*) echo "$(basename $t) $comm";; esac
done
taskset -pc 2 <vcpu0_tid>
taskset -pc 3 <vcpu1_tid>
```

3. cgroup v2 cpuset(推荐，可与内存等其他控制器组合)：

```
mkdir /sys/fs/cgroup/aenv-vm
echo "2-3" > /sys/fs/cgroup/aenv-vm/cpuset.cpus
echo 0    > /sys/fs/cgroup/aenv-vm/cpuset.mems
echo $fc_pid > /sys/fs/cgroup/aenv-vm/cgroup.procs
```

线程级cgroup(per-vcpu粒度)需threaded模式：

```
echo threaded > /sys/fs/cgroup/aenv-vm/cgroup.type
mkdir /sys/fs/cgroup/aenv-vm/vcpu0
echo "2" > /sys/fs/cgroup/aenv-vm/vcpu0/cpuset.cpus
echo <vcpu0_tid> > /sys/fs/cgroup/aenv-vm/vcpu0/cgroup.threads
```

AgentENV生产化做法：在node服务的systemd unit里限制AllowedCPUs，
或启动包装脚本统一把FC进程echo进cgroup.procs；per-vcpu粒度需
wrap启动脚本对fc_vcpu线程逐个taskset(线程名稳定，见上)。

### 1.5 ARM上的注意点

1. vcpu线程就是普通pthread跑KVM_RUN，sched_setaffinity/taskset
   语义与架构无关，ARM无特殊要求。
2. ARM服务器NUMA/cluster拓扑：多cluster机型(Kunpeng、Ampère)
   跨cluster的延迟明显高于x86跨socket，绑核应绑在同一cluster的
   物理核上，配cpuset.mems绑对应内存节点。
3. 绑核与密度矛盾：高密度沙箱场景单核绑定会牺牲overcommit能力，
   折中是只对模板沙箱/关键租户绑核，普通沙箱走共享池。
4. 验证生效：ps -eLo pid,tid,psr,comm看vcpu线程实际所在核；
   cube-hypervisor绑核失败会在日志打error(cpu.rs:984附近)。


## 二、自定义guest内核

### 2.1 内核格式要求(ARM关键差异)

| VMM | aarch64内核格式 | 加载实现 |
|-----|----------------|---------|
| firecracker | PE格式未压缩Image | linux_loader pe::PE(arch/aarch64/mod.rs:23,276) |
| cube-hypervisor | PE格式Image，失败退化为UEFI二进制 | linux_loader pe::PE，InvalidImageMagicNumber时按UEFI加载(vmm/src/vm.rs:963-990) |

x86对照：firecracker x86_64支持ELF vmlinux与bzImage自动识别
(docs/rootfs-and-kernel-setup.md:7-9)；cube-hypervisor x86走
ELF+PVH头(vm.rs:1003-1030)。

结论：在ARM上两个VMM都要make Image的产物(arch/arm64/boot/Image)，
不是vmlinux(ELF)，也不是Image.gz(压缩后不是PE)。这是最容易踩的
坑——AgentENV默认内核虽然叫vmlinux-6.1.175(deps_manifest.toml:9-12)，
实际是PE Image格式；CubeSandbox的vmlinux-arm64资产同理。

### 2.2 编译步骤

```
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# 方式一：从firecracker推荐配置开始(最省事)
cp ~/firecracker/resources/guest_configs/microvm-kernel-ci-aarch64-6.18.config .config
make olddefconfig
make -j$(nproc) Image          # 产物 arch/arm64/boot/Image

# 方式二：defconfig + 手动补virtio等配置
make defconfig
# 关键配置项(推荐config里都有)：
#   FC aarch64：virtio走mmio -> CONFIG_VIRTIO_MMIO=y
#   CH aarch64：virtio走pci  -> CONFIG_VIRTIO_PCI=y
#   FC console：CONFIG_SERIAL_8250=y + CONFIG_SERIAL_8250_CONSOLE=y
#   CH console：CONFIG_SERIAL_AMBA_PL011=y + PL011_CONSOLE
#   通用：VIRTIO_BLK/NET、EXT4、OVERLAY_FS(镜像分层需要)
make olddefconfig
make -j$(nproc) Image
```

设备传输层差异有代码依据：firecracker aarch64的fdt写ns16550a
(fdt.rs:428)，CH aarch64的fdt写arm,pl011(fdt.rs:429)并建pci节点
(fdt.rs:127,553)——所以FC用ttyS0+virtio-mmio，CH用ttyAMA0+
virtio-pci，内核config要对应。

### 2.3 接入firecracker/AgentENV

firecracker通用API(boot source)：

```
curl --unix-socket /run/firecracker.socket -X PUT \
    http://localhost/boot-source \
    -H 'Content-Type: application/json' \
    -d '{"kernel_image_path": "/opt/kernel/Image",
         "boot_args": "console=ttyS0 reboot=k panic=1 pci=off init=/init"}'
```

字段kernel_image_path+boot_args(boot_source.rs:29-36)。

AgentENV入口：config/default.toml的[kernel]段(default.toml:52-56，
注释：Use an existing uncompressed Linux kernel image instead of
downloading one)：

```
[kernel]
image_path = "/opt/agentenv/custom-Image"   # 必须是PE格式Image
```

deps.rs:158-164对显式内核做存在性/非空校验。boot_args在
[firecracker]段(default.toml:31-33)，默认console=ttyS0+
damon_reclaim参数；自己编译的内核若不带DAMON，必须把
damon_reclaim.*从boot_args去掉，否则启动报错。

警告：换内核后已有模板快照不兼容——aarch64 vcpu状态是REG_LIST
全量寄存器，集合随内核版本变化(见AI沙箱虚拟化技术分析笔记5.2节)，
模板需要重建。

### 2.4 接入CubeSandbox/cube-hypervisor

cube-hypervisor CLI：

```
cube-hypervisor --kernel /path/Image --cmdline "console=ttyAMA0 ..."
```

CubeShim配置入口(containerd注解，CubeShim/shim/src/sandbox/
config.rs)：

| 机制 | 内容 |
|------|------|
| 注解cube.vm.kernel.path | 指定内核路径(config.rs:24) |
| 注解cube.vm.kernel.cmdline.append | 追加内核参数(config.rs:26) |
| 默认内核 | /usr/local/services/cubetoolbox/cube-kernel-scf/vmlinux(config.rs:48) |
| 透传 | sb.rs:752 vc.set_kernel(conf.kernel) |

替换方式：a)替换SCF路径下的vmlinux文件(注意aarch64上是PE Image)；
b)沙箱注解cube.vm.kernel.path指向新路径。CubeShim对append参数做
冲突检测(sb.rs:785-796)，重复参数会被拒绝。

部署侧资产：deploy/release-assets.yaml:10-12定义kernel_bm_arm64
→ vmlinux-arm64+kernel-metadata.json，构建脚本build-vm-assets.sh:103
ensure_kernel_vmlinux；自己编译后替换该资产并同步metadata即可
被集群安装流程使用。

### 2.5 注意事项汇总

1. 快照/模板兼容性：换内核版本后模板快照的vcpu状态可能不兼容，
   需重建模板；跨内核版本恢复在firecracker中本就是unstable。
2. 内存增量快照与guest内核无关：CubeSandbox的soft-dirty退化
   (ARM不可用)和AgentENV的dirty-memory-ranges都是host侧机制，
   换guest内核不影响。
3. guest功能依赖config：AgentENV的damon_reclaim参数要求
   CONFIG_DAMON/CONFIG_DAMON_RECLAIM；free_page_reporting依赖
   CONFIG_PAGE_REPORTING。
4. 验证：boot后guest内uname -r确认版本；FC的Guest-boot-time日志
   (boot_timer伪设备)可确认内核正常拉起。

## 参考文件

- CubeSandbox/hypervisor/vmm/src/cpu.rs:546,949-975 绑核实现
- CubeSandbox/hypervisor/vmm/src/config.rs:595-627 affinity解析
- CubeSandbox/hypervisor/option_parser/src/lib.rs:220-235,293-316
- CubeSandbox/hypervisor/src/main.rs:115-123,831 --cpus CLI与默认值
- CubeSandbox/hypervisor/vmm/src/vm.rs:963-990 aarch64内核加载
- CubeSandbox/hypervisor/arch/src/aarch64/fdt.rs:127,429,553 设备树
- CubeSandbox/CubeShim/shim/src/sandbox/config.rs:24-48 注解与默认内核
- CubeSandbox/CubeShim/shim/src/sandbox/sb.rs:752,785-796 内核透传
- CubeSandbox/deploy/release-assets.yaml:10-12 内核资产
- firecracker/src/vmm/src/vstate/vcpu.rs:193-194 vcpu线程命名
- firecracker/src/vmm/src/arch/aarch64/mod.rs:23,266-289 PE加载
- firecracker/docs/rootfs-and-kernel-setup.md:7-9,18-58 编译指南
- firecracker/resources/guest_configs/ 推荐内核config
- firecracker/src/firecracker/src/api_server/request/boot_source.rs:29-36
- AgentENV/config/default.toml:31-33,52-56 boot_args与kernel配置
- AgentENV/src/setup/deps.rs:158-164 内核文件校验
- AgentENV/config/deps_manifest.toml:9-12 默认内核
- AgentENV/src/sandbox/firecracker/instance.rs:294-310 set_boot_source
