# virsh 启动 openEuler aarch64 虚机配置记录

## 环境

| 项目 | 值 |
|------|-----|
| Host OS | openEuler 24.03 LTS-SP2 |
| 架构 | aarch64 |
| QEMU | 自编译 `/home/wz/qemu/build/qemu-system-aarch64` (v11.0.0-rc0) |
| libvirt | 9.10.0-20 |
| KVM | 不可用（当前机器不支持嵌套虚拟化），使用 TCG |
| 使用模式 | `virsh` 不加 `-c`（system mode），非 session mode |

## 遇到的坑及解决

### 1. KVM 不可用 → TCG

`/dev/kvm` 不存在，CPU 无虚拟化扩展标志。

解决：`<domain type='qemu'>` 替代 `<domain type='kvm'>`，使用 TCG 软件模拟。

### 2. 系统 QEMU 探测失败

系统自带的 `qemu-system-aarch64` (8.2.0) 无法被 libvirt 9.10.0 做 capabilities probing：
```
error: failed to get emulator capabilities
error: An error occurred, but the cause is unknown
```

原因：libvirt 9.10.0 通过 QMP 探测 QEMU 能力时，系统 QEMU 8.2.0 返回异常。

解决：使用自编译 QEMU `/home/wz/qemu/build/qemu-system-aarch64` (v11.0)，QMP probing 正常。
对应 XML：`<emulator>/home/wz/qemu/build/qemu-system-aarch64</emulator>`

### 3. ACPI 需要 UEFI

aarch64 上 libvirt 强制要求 ACPI 必须搭配 UEFI 固件：
```
error: unsupported configuration: ACPI requires UEFI on this architecture
```

解决：
- 安装 `edk2-aarch64` 包（`yum install edk2-aarch64`）
- 固件路径：`/usr/share/edk2/aarch64/`
- 必须使用 `-pflash.raw` 文件（64MB），不能用 `.fd` 文件（2MB，大小不匹配）

对应 XML：
```xml
<loader readonly='yes' type='pflash'>/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw</loader>
<nvram template='/usr/share/edk2/aarch64/vars-template-pflash.raw'/>
```

注意：带 nvram 的 domain 删除时需要用 `virsh undefine vm1 --nvram`。

### 4. 网络

#### 4.1 Bridge 模式被 ACL 拒绝

`<interface type='bridge' br='br0'>` 经 `qemu-bridge-helper` 检查 `/etc/qemu/bridge.conf`，该文件仅允许 `virbr0`，拒绝 `br0`。

#### 4.2 其他方式不适用

| 方式 | 失败原因 |
|------|----------|
| `<interface type='user'/>` (SLIRP) | 自编译 QEMU 未编译 user 网络后端 |
| `<interface type='user'><backend type='passt'/></interface>` | `passt` 包未安装 |

#### 4.3 解决方案：`<qemu:commandline>` 透传 tap 参数

绕过 bridge helper，用 `<qemu:commandline>` 直接传 `-netdev tap` 参数给 QEMU。

PCI 插槽冲突问题——libvirt 在 `pcie.0` 的 slot 0x1 上创建了 3 个 pcie-root-port（多功能），网卡需放到更高的空 slot：

```xml
<qemu:commandline>
  <qemu:arg value='-netdev'/>
  <qemu:arg value='tap,id=net0,ifname=tap0,script=no,downscript=no'/>
  <qemu:arg value='-device'/>
  <qemu:arg value='virtio-net-pci,netdev=net0,mac=52:54:00:12:34:01,bus=pcie.0,addr=0x2'/>
</qemu:commandline>
```

关键点：
- `ifname=tap0`：复用 setup_bridge.sh 已创建好的 tap 设备
- `bus=pcie.0,addr=0x2`：指定 PCI 地址避开 libvirt 占用的 slot 0x1
- 需要声明 `xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'` 命名空间

#### 4.4 VM 内配网

```bash
ip addr add 192.168.100.10/24 dev enp0s1 && ip link set enp0s1 up
```

### 5. NUMA 拓扑

16 核，2 个 NUMA 节点，每节点 2 clusters × 2 cores × 2 threads = 8 逻辑核。

对应 XML：
```xml
<cpu mode='custom'>
  <model>max</model>
  <topology sockets='2' dies='1' clusters='2' cores='2' threads='2'/>
  <numa>
    <cell id='0' cpus='0-7' memory='2' unit='GiB'/>
    <cell id='1' cpus='8-15' memory='4' unit='GiB'/>
  </numa>
</cpu>
```

实际生成的 QEMU 参数：
```
-smp 16,sockets=2,dies=1,clusters=2,cores=2,threads=2
-numa node,nodeid=0,cpus=0-7,memdev=ram-node0
-numa node,nodeid=1,cpus=8-15,memdev=ram-node1
```

拓扑结构：
```
socket 0 (NUMA 0, 2G)              socket 1 (NUMA 1, 4G)
├─ cluster 0                       ├─ cluster 0
│  ├─ core 0 ─ thread0, thread1   │  ├─ core 0 ─ thread0, thread1
│  └─ core 1 ─ thread0, thread1   │  └─ core 1 ─ thread0, thread1
└─ cluster 1                       └─ cluster 1
   ├─ core 0 ─ thread0, thread1      ├─ core 0 ─ thread0, thread1
   └─ core 1 ─ thread0, thread1      └─ core 1 ─ thread0, thread1

CPU 0-7                             CPU 8-15
```

VM 内查看拓扑：
```bash
lscpu -e=CPU,CLUSTER,CORE,SOCKET,NODE
grep . /sys/devices/system/cpu/cpu*/topology/cluster_id
lstopo                           # 需 yum install hwloc
```

## 当前最终 XML

```xml
<domain type='qemu' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>vm1</name>
  <memory unit='GiB'>6</memory>
  <currentMemory unit='GiB'>6</currentMemory>
  <vcpu placement='static'>16</vcpu>
  <os>
    <type arch='aarch64' machine='virt'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw</loader>
    <nvram template='/usr/share/edk2/aarch64/vars-template-pflash.raw'/>
    <kernel>/home/wz/linux/arch/arm64/boot/Image</kernel>
    <cmdline>root=/dev/vda2 rw console=ttyAMA0 default_hugepagesz=64K selinux</cmdline>
  </os>
  <features>
    <acpi/>
    <gic version='3'/>
  </features>
  <cpu mode='custom'>
    <model>max</model>
    <topology sockets='2' dies='1' clusters='2' cores='2' threads='2'/>
    <numa>
      <cell id='0' cpus='0-7' memory='2' unit='GiB'/>
      <cell id='1' cpus='8-15' memory='4' unit='GiB'/>
    </numa>
  </cpu>
  <clock offset='utc'/>
  <devices>
    <emulator>/home/wz/qemu/build/qemu-system-aarch64</emulator>

    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/home/wz/tests/qemu_debug_qcow2/openEuler-24.03-LTS-SP2-aarch64_src.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>

    <filesystem type='mount' accessmode='mapped'>
      <source dir='/home/wz/tests/qemu_debug_qcow2/share'/>
      <target dir='hostshare'/>
    </filesystem>

    <serial type='pty'>
      <target type='system-serial' port='0'>
        <model name='pl011'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
  <qemu:commandline>
    <qemu:arg value='-netdev'/>
    <qemu:arg value='tap,id=net0,ifname=tap0,script=no,downscript=no'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='virtio-net-pci,netdev=net0,mac=52:54:00:12:34:01,bus=pcie.0,addr=0x2'/>
  </qemu:commandline>
</domain>
```

## 常用管理命令

```bash
virsh list                    # 查看运行中的 VM
virsh start vm1               # 启动
virsh destroy vm1             # 强制停止
virsh undefine vm1 --nvram    # 删除定义（含 nvram）
virsh define xxx.xml          # 从 XML 定义
virsh console vm1             # 连接串口控制台
virsh dumpxml vm1             # 导出当前运行配置
```

## 9p 文件共享

Host 目录 `./share` → Guest mount tag `hostshare`。

VM 内部手动挂载：
```bash
mkdir -p /mnt/share
mount -t 9p -o trans=virtio hostshare /mnt/share
```

开机自动挂载（`/etc/fstab`）：
```
hostshare /mnt/share 9p trans=virtio 0 0
```

## 网络拓扑

```
host: bridge br0 (192.168.100.1)
         │
         │ tap0
         ▼
     vm1 (192.168.100.10)
```

bridge 是一台虚拟交换机，tap0 是交换机上的一个端口。QEMU 把 VM 内的 virtio 网卡和 tap0 背靠背连在一起，VM 发到 enp0s1 的包经 QEMU 从 tap0 进 br0，br0 上所有设备（host、其他 VM）都能收到。

## 热迁移

TCG 支持热迁移，QEMU 的迁移框架与加速器无关。

### 基本语法

```bash
virsh migrate [options] <domain> <dest-uri> [migrate-uri]
```

### 关键选项

| 选项 | 作用 |
|------|------|
| `--live` | 热迁移，不停机 |
| `--persistent` | 目标端保存持久化 XML |
| `--undefinesource` | 迁移完自动删源端定义 |
| `--suspend` | 迁移完在目标端暂停 |
| `--timeout <n>` | 超时（秒） |
| `--compressed` | 压缩传输 |
| `--auto-converge` | CPU 忙时自动降频加速收敛 |
| `--p2p` | 源端 QEMU 直连目标端 QEMU |
| `--direct` | 数据走 QEMU 直连，不经 libvirtd |
| `--tunnelled` | 数据走 libvirtd 隧道 |
| `--verbose` | 显示进度 |

### 三种传输模式

```
直连 (--direct)：
src QEMU ──TCP──→ dst QEMU

隧道 (--tunnelled)：
src QEMU ──libvirtd──ssh──libvirtd──→ dst QEMU

默认：
src libvirtd 协调，数据通道由 migrate-uri 决定
```

### 速度控制

```bash
virsh migrate-setspeed vm1 --bandwidth 500        # 限速 MiB/s
virsh migrate-getspeed vm1                        # 查看当前速度
virsh migrate-setmaxdowntime vm1 200               # 最大停机时间 ms
```

### 常见用法

```bash
# 远程热迁移
virsh migrate --live vm1 qemu+ssh://dst-host/system

# 带持久化和清理
virsh migrate --live --persistent --undefinesource vm1 qemu+ssh://dst/system

# 压缩加速
virsh migrate --live --compressed --auto-converge vm1 qemu+ssh://dst/system

# 暂停模式
virsh migrate --live --suspend vm1 qemu+ssh://dst/system
virsh resume vm1       # 目标端继续
```

### 迁移流程

```
1. src libvirtd → 连 dst libvirtd，传 VM 定义
2. dst libvirtd 创建空 QEMU，等待 incoming
3. src QEMU 开始迭代拷贝脏页到 dst QEMU
4. 最后一轮停机，拷剩余脏页
5. dst QEMU 接管，VM 恢复运行
```

### 当前环境限制

TCG 下脏页追踪靠软件，迁移速度慢但功能正常。目标端需要：同样的自编译 QEMU、br0+tap 设备、nvram 文件。

## 文件位置

- XML 定义文件：`/home/wz/tests/qemu_debug_qcow2/openEuler-aarch64-src.xml`
- qcow2 镜像：`/home/wz/tests/qemu_debug_qcow2/openEuler-24.03-LTS-SP2-aarch64_src.qcow2`
- 自编译 QEMU：`/home/wz/qemu/build/qemu-system-aarch64`
- 内核 Image：`/home/wz/linux/arch/arm64/boot/Image`
- UEFI 固件：`/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw`
- NVRAM 文件：`/home/wz/.config/libvirt/qemu/nvram/vm1_VARS.raw`
