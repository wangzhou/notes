# 在 QEMU 嵌套虚机里跑 Firecracker —— 调试记录（未完成，待续）

> 目标：在 `run_qemu_qcow2_sandbox.sh` 启动的 QEMU 虚机（TCG 模拟）里，用**嵌套 KVM** 跑起 Firecracker microVM。
> **状态：✅ 已成功！microVM 3.7 秒完整启动进入 shell，嵌套 KVM 正常工作，rootfs 用国内镜像自制。**
> 关联：网络联网前提见 [`QEMU用户态网络联网调试记录.md`](/home/wz/notes/ai_gen/QEMU用户态网络联网调试记录.md)
>
> **成功的完整配置与最终根因见文末「§10 2026-07-14 成功：换内核后跑通」。**

---

## 1. 背景与关键结论（重要）

- 本机没有 KVM，sandbox 虚机用 **TCG（纯软件模拟）** 跑。
- 但外层启动参数带 `-machine virt,virtualization=true -cpu max`，**向 guest 暴露了 EL2（ARM 虚拟化扩展）**，所以 guest 内核能提供 `/dev/kvm`——即**嵌套虚拟化**。
- **已验证：Firecracker 能在该 guest 里通过嵌套 KVM 创建并运行 vCPU。** 这是整件事最不确定的一环，已打通。
- 代价：TCG 里嵌套 KVM **极慢**（microVM 内核引导时 firecracker 进程 CPU 96.9% 满载），只能验证功能，不能看性能。

### guest 的 KVM 前提（实测全部满足）

```
/dev/kvm                 → crw-rw---- root kvm 10,232   （存在）
dmesg | grep EL2         → CPU: All CPU(s) started at EL2
dmesg | grep kvm         → kvm [1]: IPA Size Limit: 52 bits / vgic interrupt IRQ9 …（KVM 已初始化）
/proc/config.gz          → CONFIG_KVM=y （内建，故 lsmod 里看不到，正常）
```

---

## 2. Firecracker 二进制的获取（GitHub 不通的绕法）

- guest 与宿主机**都无法访问 `github.com`**（超时），但 `www.baidu.com` 通、AWS S3 通。
- Firecracker release 二进制在 GitHub，下载入口 `github.com/.../releases/download/...` 那一跳超时，拿不到跳转到 `objects.githubusercontent.com` 的签名 URL。
- **最终解法**：在**宿主机本地**用 `git clone`（网速慢但能连 github，人工完成）拿到 release，解压在
  `/home/wz/release-v1.16.1-aarch64/`。
- 二进制特性：`firecracker-v1.16.1-aarch64` 是 **ARM aarch64、静态链接**（`statically linked`），**零库依赖**，直接扔进 guest 即可运行。

### 传给 guest 的方式：9p 共享目录（不走网络）

sandbox 脚本挂了 9p：`-fsdev local,path=./share,mount_tag=hostshare`。

```bash
# 宿主机：拷进共享目录
cp /home/wz/release-v1.16.1-aarch64/firecracker-v1.16.1-aarch64 \
   /home/wz/tests/qemu_debug_qcow2/share/firecracker

# guest 内：9p 已自动挂在 /mnt（注意不是 /mnt/hostshare）
cp /mnt/firecracker /usr/local/bin/firecracker && chmod +x /usr/local/bin/firecracker
firecracker --version    # → Firecracker v1.16.1  ✅
```

> 坑：guest 里 9p 已经挂载在 `/mnt`，重复 `mount ... /mnt/hostshare` 会报
> `hostshare already mounted on /mnt`。直接用 `/mnt` 即可。

---

## 3. microVM 素材（内核 OK，rootfs 卡住）

官方 CI 素材在 S3，用 **path-style URL** 访问（桶名带点 `spec.ccfc.min`，virtual-host 式会证书不匹配）：

```
基址：https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.10/aarch64
列目录：curl '.../?list-type=2&prefix=firecracker-ci/v1.10/aarch64/&max-keys=40'
```

| 素材 | 大小 | 状态 |
|------|------|------|
| `vmlinux-6.1.102` | **986K**（压缩 ARM64 Image，已验证是真内核） | ✅ 已下到 guest `/root/fc/vmlinux` |
| `ubuntu-22.04.id_rsa` | 2.6K | ✅ 已下，`chmod 600` |
| `ubuntu-22.04.ext4` | **300 MB** | ❌ **下不动**：到 S3 仅 ~8.8 KB/s，且 `Connection reset` |
| `ubuntu-22.04.squashfs` | 63 MB | （更小，但按此网速仍要 ~2h） |

> 证书坑：`https://spec.ccfc.min.s3.amazonaws.com/...` 会报
> `SSL: no alternative certificate subject name matches`。改用
> `https://s3.amazonaws.com/spec.ccfc.min/...`（path-style）即可。

---

## 4. 已跑通的部分：microVM 成功启动 vCPU

用 `--config-file` 一次性启动（**注意：config 里 `drives` 字段必填，哪怕空数组**，否则报
`missing field drives`）。

`/root/fc/vmconfig.json`：
```json
{
  "boot-source": {
    "kernel_image_path": "/root/fc/vmlinux",
    "initrd_path": "/root/fc/initrd.cpio.gz",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
  },
  "drives": [],
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 256 }
}
```

启动：
```bash
firecracker --api-sock /root/fc/fc.sock --config-file /root/fc/vmconfig.json
```

日志证据（**成功**）：
```
Running Firecracker v1.16.1
Successfully started microvm that was configured from one single json
[fc_vcpu 0] Received a VcpuEvent::Resume …    ← vCPU 已运行（嵌套 KVM 生效）
```
`ps` 显示 firecracker CPU 96.9% 满载 → microVM 内核确实在执行。

---

## 5. 今天没进到 microVM shell 的原因（非 Firecracker 本身问题）

试用 share 里现成的 `rootfs_mini.cpio.gz` 当 initrd（内含 `init`/`busybox`，结构完整），
但**内核 console 始终无输出**。原因：

1. **console 不匹配**：`rootfs_mini.cpio.gz` 是为**外层 QEMU 的 ARM `virt` 机器**定制的，
   其 console 是 `ttyAMA0`（PL011）；而 **Firecracker 的串口是 `ttyS0`（8250/16550 UART）**。
   内核在跑（CPU 满载）但 print 到了不匹配的设备 / 或 init 与该内核不兼容后 `panic=1` 直接重启。
2. 期间还踩了 console 捕获的坑：firecracker 前台运行会把 tty 设成 raw 模式，
   `> file` 重定向、`setsid script ... </dev/null`（PTY 立即 EOF）都抓不到内核输出，
   最后前台运行时 raw 模式还吞掉了 Ctrl-C，只能从外层 `tmux kill-session` 打破僵局。

**结论**：不要用这个 mini cpio。直接用官方 `ubuntu-22.04.ext4` rootfs（其内核/console/init 都是配套的），一步到位。

---

## 6. 明天的清单（好网络下，只差 rootfs）

**guest `/root/fc/` 已就位**（都在 qcow2 里持久保存）：firecracker 二进制、`vmlinux`、`ubuntu.id_rsa`、`vmconfig.json`。

### Step 1：下 rootfs（好网络下几十秒）
```bash
BASE="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.10/aarch64"
curl -o /root/fc/rootfs.ext4 $BASE/ubuntu-22.04.ext4     # 300MB
```
（若想传得快，也可在**宿主机**下好后放进 `./share/`，guest 从 `/mnt/` 取，绕开 guest 网络。）

### Step 2：改 `vmconfig.json` —— 去掉 initrd，挂 ext4 根盘
```json
{
  "boot-source": {
    "kernel_image_path": "/root/fc/vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw"
  },
  "drives": [
    { "drive_id": "rootfs", "path_on_host": "/root/fc/rootfs.ext4",
      "is_root_device": true, "is_read_only": false }
  ],
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 256 }
}
```

### Step 3：启动并进 shell
```bash
firecracker --api-sock /root/fc/fc.sock --config-file /root/fc/vmconfig.json
```
- 换成官方 ext4 后，console=`ttyS0` 与该 rootfs 配套，应能看到内核 boot 日志并进入登录。
- 官方 rootfs 默认可用 `root` 直接登录（或用 `ubuntu.id_rsa` 走网络 SSH）。
- 提醒：嵌套 TCG+KVM 下 boot 会很慢，耐心等。

### （可选）给 microVM 配网
Firecracker 需宿主（=这台 guest）侧建 tap + 配 IP/NAT，再在 config 里加 `network-interfaces`。
初次验证可跳过，先进 shell 为准。

---

## 7. 启动 sandbox 虚机的方法备忘

```bash
cd /home/wz/tests/qemu_debug_qcow2
./run_qemu_qcow2_sandbox.sh          # 用户态网络，开机即联网（详见联网调试记录）
# tmux 驱动登录：send-keys "root" Enter → "wangroot" Enter
# guest 里 9p 共享已挂在 /mnt
```

---

## 8. 涉及的文件

| 位置 | 内容 |
|------|------|
| 宿主机 `/home/wz/release-v1.16.1-aarch64/` | 解压好的 Firecracker release（二进制 + 工具） |
| 宿主机 `.../share/firecracker` | 拷入 9p 共享目录的二进制（今天新增） |
| guest `/root/fc/` | `firecracker`、`vmlinux`、`ubuntu.id_rsa`、`vmconfig.json`、`initrd.cpio.gz`（mini，可弃用） |
| guest `/usr/local/bin/firecracker` | 已安装、可直接调用 |

---

## 9. 2026-07-14 续：rootfs 自制 + microVM 无输出问题

### 9.1 rootfs：放弃 AWS S3，改用国内镜像自制（已解决）

- 官方 `ubuntu-22.04.ext4`（300MB）/ `squashfs`（63MB）在 AWS S3 上**极慢**（8~86 KB/s，反复
  `Connection reset` / `Empty reply from server`），断点续传也磨不动，18% 后彻底卡死。**此路放弃。**
- **改用清华 TUNA 镜像的 `ubuntu-base`（arm64 最小根文件系统），速度 22 MB/s，1 秒下完：**
  ```
  https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-arm64.tar.gz  （27MB）
  ```
- 用脚本 `/home/wz/fc_dl/make_rootfs.sh` 把它灌成 ext4（需 root：mkfs/mount）：
  - 建 800MB 空 ext4 → `mount -o loop` → 解压 ubuntu-base → 配 DNS、root 空密码、
    自建极简 `/sbin/fc-init`（挂 proc/sys/dev 后 `exec /bin/bash`）→ umount。
  - 产物 `rootfs-ubuntu.ext4`，属主改 `wz:wz`，经 9p 共享目录 `share/` 传入 guest，
    再 `cp` 到 guest 本地 `/root/fc/rootfs.ext4`（9p 上直接跑不稳，拷本地）。
- 磁盘紧张提醒：宿主机 `/` 一度只剩 1.4G（99%）。800MB ext4 峰值占 800MB，够但紧。

### 9.2 关键坑：aarch64 firecracker 必须加 `keep_bootcon`

- 官方 getting-started 明确：**aarch64 的 boot_args 必须前置 `keep_bootcon`**，否则 ARM 内核
  在启动交接时会关掉 boot console，串口从此静默。x86 不需要，arm64 必须。
- 正确 boot_args：
  ```
  keep_bootcon console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/sbin/fc-init
  ```

### 9.3 当前未解决的问题：microVM 内核零输出、firecracker 随即退出

**现象**（加了 `keep_bootcon` 后仍然）：
- firecracker 的 **debug 日志（`level:Debug`, `log_path`）显示一切正常**：
  `build microvm for boot` → `vmgenid` 设备建好 → `boot microvm` → `event_end` → vCPU `Resume`
  → `Successfully started microvm`。**即 firecracker 侧成功加载内核、启动 vCPU。**
- 但 **guest 串口日志（firecracker stdout）里内核一个字都没有**，且 firecracker 进程很快 `Done`
  **退出**（不是卡住）。
- 用户经验判断：**内层即便是 QEMU 起 VM，10 秒内也该有输出**，所以「嵌套慢」不成立
  —— 是内核**极早期静默失败 / 立即 reset**，不是慢。

**已排除**：
- 非 console 交接问题（加了 `keep_bootcon` 无改善）。
- 非 firecracker 配置加载问题（debug 日志显示 build/boot 全部成功）。
- 非 rootfs 的 mini-cpio console 不匹配问题（已换成配套的 ubuntu-base ext4 + ttyS0）。

**下一步待验证的方向（未做完）**：
1. **`earlycon`**：boot_args 试 `earlycon=uart,mmio,0x40000000`（firecracker aarch64 串口 MMIO 基址）
   ——若 earlycon 也全黑，基本坐实「内核没真正跑起来」，而非 console 问题。（本次已加但仍无输出，
   需确认地址/驱动是否匹配该 CI 内核。）
2. **二分定位**：用**外层 QEMU 直接引导** `vmlinux + rootfs.ext4`（已知 QEMU 能工作），
   若 QEMU 能起 → 问题在 firecracker 与该内核的适配；若 QEMU 也起不来 → 内核/rootfs 本身有问题。
3. 核对该 CI `vmlinux-6.1.102` 的 `.config`：确认 `CONFIG_SERIAL_8250=y` /
   `CONFIG_SERIAL_8250_CONSOLE=y`（firecracker 用 8250/16550 UART）。
4. 可能需要**换内核**：这个 CI 内核或与当前嵌套环境不适配，可考虑用外层那个已知能跑的
   `/home/wz/linux/arch/arm64/boot/Image` 试作 firecracker guest kernel。

### 9.4 操作教训

- **firecracker 不要前台跑**：aarch64 上前台运行会把 tty 设成 raw 模式并**吞掉 Ctrl-C**，
  反复锁死 guest 终端，只能从外层 `tmux kill-session` 打断。
  **一律用后台 + 重定向日志**：`setsid bash -c 'firecracker ... > serial.log 2>&1' < /dev/null &`。
- 调试 microVM 必开 firecracker 的 **Debug logger**（config 里 `"logger":{"log_path":...,"level":"Debug"}`），
  它能证明「内核是否被成功加载/启动」，把问题范围快速缩小到 VMM 侧还是 guest 侧。

### 9.5 本次新增/涉及文件

| 位置 | 内容 |
|------|------|
| 宿主机 `/home/wz/fc_dl/make_rootfs.sh` | 用 ubuntu-base 制作 ext4 rootfs 的脚本 |
| 宿主机 `/home/wz/fc_dl/ubuntu-base-22.04.5-base-arm64.tar.gz` | 清华镜像下的 rootfs 源料（27MB） |
| 宿主机 `.../share/rootfs-ubuntu.ext4` | 自制的 ext4 rootfs（800MB，经 9p 传 guest） |
| guest `/root/fc/rootfs.ext4` | 拷到 guest 本地的 rootfs |
| guest `/root/fc/vmconfig.json` | 当前配置（含 drives + Debug logger） |
| guest `/root/fc/fc-debug.log` | firecracker debug 日志（证明 VMM 侧成功） |
| guest `/root/fc/serial.log` | guest 串口输出（当前为空——问题所在） |

---

## 10. 2026-07-14 成功：换内核后跑通 ✅

### 10.1 最终根因：那个 CI 内核 `vmlinux-6.1.102` 本身跑不起来

§9.3 里「microVM 零输出、firecracker 立即退出」的问题，**根因不在 firecracker、不在嵌套 KVM、不在大页、不在 boot_args**，而是 **AWS S3 下的 CI 内核 `vmlinux-6.1.102` 在当前环境根本无法启动**（大概率是它为 firecracker-ci v1.10 的旧环境所编，与本机 QEMU 11.0 / 7.x 宿主内核不兼容）。

**决定性的二分测试**（关键方法）——绕开 firecracker，直接用 guest 里的 QEMU 引导同一个内核：

| 测试 | 内核 | 加速 | 结果 |
|------|------|------|------|
| firecracker | `vmlinux-6.1.102` | 嵌套 KVM | ❌ 零输出，进程退出 |
| QEMU `virt` | `vmlinux-6.1.102` | 嵌套 KVM | ❌ 零输出，进程退出 |
| QEMU `virt` | `vmlinux-6.1.102` | **纯 TCG** | ❌ 零输出，进程退出 ← **排除 KVM/firecracker** |
| QEMU `virt` | **`Image_new`（本地 7.0.0-rc6）** | 纯 TCG | ✅ **263 行日志狂输出** ← **坐实是内核问题** |
| **firecracker** | **`Image_new`** | **嵌套 KVM** | ✅ **313 行日志，3.7s 进 shell** |

> 教训：内核不出声时，用「同一 QEMU 换 TCG / 换已知好内核」做二分，一步就能把问题从
> firecracker/KVM 摘清，定位到内核本身。不要在 boot_args / console 上反复瞎试。

### 10.2 成功的配置

- **内核**：改用本机已知能跑的 `Image_new`（即 openEuler 自编内核 7.0.0-rc6，来自 `share/Image_new`，
  等同 `/home/wz/linux/arch/arm64/boot/Image` 系列）。放到 guest `/root/fc/Image_good`。
- **rootfs**：§9.1 用清华镜像 ubuntu-base 自制的 `rootfs.ext4`（ext4，可读写）。
- **firecracker 配置 `/root/fc/vm3.json`**：
  ```json
  {
    "boot-source": {
      "kernel_image_path": "/root/fc/Image_good",
      "boot_args": "keep_bootcon console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw"
    },
    "drives": [
      { "drive_id": "rootfs", "path_on_host": "/root/fc/rootfs.ext4",
        "is_root_device": true, "is_read_only": false }
    ],
    "machine-config": { "vcpu_count": 1, "mem_size_mib": 512 },
    "logger": { "log_path": "/root/fc/fc3.log", "level": "Debug" }
  }
  ```
- **启动命令**（后台，不锁终端）：
  ```bash
  setsid bash -c 'firecracker --api-sock /root/fc/fc.sock \
      --config-file /root/fc/vm3.json > /root/fc/serial3.log 2>&1' < /dev/null &
  ```

### 10.3 成功的启动日志证据（`serial3.log`）

```
[    0.000000] Booting Linux on physical CPU 0x0000000000
[    0.000000] Linux version 7.0.0-rc6-...-dirty (wz@oe) ...
[    0.000000] earlycon: uart0 at MMIO 0x0000000040002000
[    0.000000] smccc: KVM: hypervisor services detected      ← 嵌套 KVM 生效
[    3.337609] EXT4-fs (vda): mounted filesystem ... r/w      ← 自制 rootfs 挂载成功
[    3.426681] VFS: Pivoted into new rootfs
[    3.766413] Run /bin/sh as init process
/bin/sh: 0: can't access tty; job control turned off
#                                                            ← microVM shell 就绪
```

- 全程 **约 3.7 秒**从加电到 shell（嵌套 TCG+KVM 环境下）。
- 注：vm3.json 的 boot_args 未指定 `init=`，内核回退到 `/bin/sh`（一样进 shell）。
  若要用自建的 `/sbin/fc-init`，在 boot_args 末尾加 `init=/sbin/fc-init` 即可。
- `can't access tty` 只是 job control 提示（后台无交互终端），不影响功能。

### 10.4 完整复现步骤（下次直接照做）

```bash
# —— 宿主机 ——
cd /home/wz/tests/qemu_debug_qcow2
./run_qemu_qcow2_sandbox.sh                 # 起外层 guest（已去掉 default_hugepagesz=64K）
# tmux: send-keys "root" / "wangroot" 登录

# —— guest 内（/root/fc/ 素材已持久在 qcow2）——
cp /mnt/Image_new /root/fc/Image_good       # 已知好内核（9p 共享）
cp /mnt/rootfs-ubuntu.ext4 /root/fc/rootfs.ext4   # 自制 rootfs（首次需要，之后已在本地）
# 用 §10.2 的 vm3.json
setsid bash -c 'firecracker --api-sock /root/fc/fc.sock \
    --config-file /root/fc/vm3.json > /root/fc/serial3.log 2>&1' < /dev/null &
sleep 20
cat /root/fc/serial3.log                    # 应见内核日志直到 shell
```

### 10.5 关键经验汇总

1. **CI 预编译内核未必能用**：AWS S3 的 `vmlinux-x.x.x` 可能与你的 QEMU/宿主环境不兼容，
   表现为「加载成功但零输出、进程立即退出」。优先用**本机已知能跑的内核**。
2. **二分定位法**：内核不出声 → 同一 QEMU 换 TCG、换好内核，一步摘清 firecracker/KVM 嫌疑。
3. **firecracker 一律后台跑 + Debug logger**：避免前台 raw 模式锁死终端；debug 日志证明 VMM 侧成功。
4. **aarch64 必加 `keep_bootcon`**（§9.2），虽非本次根因，但仍是必要参数。
5. **rootfs 走国内镜像自制**（§9.1）：清华 ubuntu-base，22MB/s，秒下；官方 S3 的 ext4 慢到不可用。
6. **嵌套 KVM 全链路打通**：TCG 外层虚机（暴露 EL2）→ guest KVM → firecracker microVM，
   `smccc: KVM: hypervisor services detected` 是嵌套生效的标志。

### 10.6 如何退出 microVM / 停掉 firecracker（易踩坑）

**核心区别：`reboot` 会让 firecracker 重新引导（循环），`poweroff` 才让它退出。**

| 在 microVM 里执行 | 触发 | 结果 |
|---|---|---|
| `reboot` / `echo b > /proc/sysrq-trigger` | ARM `SYSTEM_RESET` | 🔁 firecracker 重新引导 microVM（看着像“又启动了”） |
| **`echo o > /proc/sysrq-trigger`** | ARM `SYSTEM_OFF` | ✅ **firecracker 进程退出**，回到 guest shell |

- 极简 ubuntu-base rootfs **没有 `poweroff`/`halt`/`shutdown` 命令**（它们来自 systemd/sysvinit）。
  所以只能用内核 **SysRq**：
  ```bash
  echo 1 > /proc/sys/kernel/sysrq   # 若未开启
  echo o > /proc/sysrq-trigger      # o = poweroff → firecracker 退出
  ```
- 之前用 `reboot`/`reset` 一直循环重启，就是因为走了 `SYSTEM_RESET` 而非 `SYSTEM_OFF`。
- **firecracker 前台运行**会把 tty 设成 raw 模式、吞掉 Ctrl-C，一旦 microVM 里退不出来，
  终端就卡死。兜底手段（按代价从小到大）：
  1. 另开一个 guest 登录终端：`pkill -9 firecracker`
  2. 实在不行——**直接 kill 最外层 QEMU 虚机**：外层一关，guest + firecracker 全部随之消失
     （本次最终就是这么退出的，最干脆）。
- **建议**：调试阶段仍用 §10.4 的**后台 + 重定向日志**方式跑 firecracker（`setsid ... &`），
  避免前台锁终端；要交互再单独接串口。要干净退出就在 microVM 内 `echo o > /proc/sysrq-trigger`。
