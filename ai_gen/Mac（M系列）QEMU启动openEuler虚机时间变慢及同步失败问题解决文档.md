# Mac（M系列）QEMU启动openEuler虚机时间变慢及同步失败问题解决文档

# 一、问题概述

环境：Mac（M系列芯片，Apple Silicon）\+ QEMU aarch64 \+ openEuler 24\.03\-LTS\-SP2（aarch64，最小化版）

核心问题：虚机运行一段时间后，时间逐渐变慢；尝试通过NTP同步时间时，多次失败，执行timedatectl显示`System clock synchronized: no`，即使NTP服务显示active，也无法成功同步。

补充环境：QEMU网络使用默认`\-net user`（NAT模式），启动参数已配置`\-rtc clock=host`，未配置`base=utc`。

# 二、问题排查过程

## 1\. 初步定位问题

执行`timedatectl`查看时间状态，发现：

- Local time（北京时间）、Universal time（UTC时间）、RTC time三者数值匹配（RTC time=UTC时间，Local time=UTC\+8小时），时区配置正确。

- 关键异常：`System clock synchronized: no`（系统时钟未同步）、`NTP service: inactive`（未启用时间同步服务）。

初步判断：时间变慢是因为QEMU HVF硬件虚拟化存在时钟漂移，且未启用NTP同步服务，漂移无法自动修正。

## 2\. 首次尝试解决：启用NTP服务（ntpd）

由于openEuler最小化版未预装chronyd，先尝试安装并启用ntpd服务：

```bash
# 安装ntpd
dnf install -y ntp
# 启用并启动ntpd
systemctl enable --now ntpd
# 尝试强制同步时间
ntpd -gq
```

报错：`unable to bind to wildcard address :: \- another process may be running \- EXITING`，原因是ntpd服务已启动，端口被占用。

尝试替代命令同步：

```bash
ntpdate pool.ntp.org
```

报错：`the NTP socket is in use, exiting`，仍为端口占用问题；重启ntpd服务后，再次执行timedatectl，依然显示`System clock synchronized: no`。

## 3\. 排查同步失败核心原因

分析得出两个关键问题：

- QEMU NAT模式（`\-net user`）对UDP 123端口（NTP专用端口）转发限制严格，导致ntpd无法与外部NTP服务器通信。

- ntpd对网络稳定性、延迟要求高，虚拟机NAT网络的不稳定性的，导致ntpd无法完成同步。

## 4\. 更换同步工具：使用chrony（适配虚拟机环境）

由于ntpd不适配虚拟机NAT环境，更换为专为不稳定网络（虚拟机、云服务器）设计的chrony工具，同时解决端口转发问题：

- 先停止并禁用ntpd服务，避免端口冲突；

- 安装并启动chrony服务；

- 配置QEMU转发UDP 123端口，确保NTP流量正常通行。

执行相关命令后，强制同步时间，最终timedatectl显示`System clock synchronized: yes`，问题解决。

# 三、完整解决方案（可直接复用）

## 步骤1：优化QEMU启动参数（关键，解决时钟漂移基础）

确保启动参数包含以下内容（无需添加`base=utc`，M系列Mac QEMU aarch64默认以UTC为基准，时区已正确）：

```bash
qemu-system-aarch64 \
  -machine virt,gic-version=3 \
  -cpu host,highmem=off  # 优化CPU调度，减少时钟漂移
  -accel hvf \
  -m 16G \
  -smp 10 \
  -drive file=~/ISO/openEuler-24.03-LTS-SP2-aarch64.qcow2,format=qcow2,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::4000-:4000,hostfwd=udp::123-:123 \  # 新增UDP 123端口转发
  -device virtio-net-pci,netdev=net0 \
  -nographic \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -fsdev local,id=fsdev0,path=/Users/sherlock,security_model=none \
  -device virtio-9p-pci,fsdev=fsdev0,mount_tag=hostshare \
  -rtc clock=host  # 绑定主机时钟，减少漂移
```

关键优化点：`hostfwd=udp::123\-:123`（转发UDP 123端口，解决NTP通信问题）、`\-cpu host,highmem=off`（优化CPU调度，减轻时钟漂移）。

## 步骤2：虚拟机内配置chrony时间同步（核心解决同步问题）

```bash
# 1. 停止并禁用ntpd服务（避免端口冲突）
systemctl stop ntpd
systemctl disable ntpd

# 2. 安装chrony（openEuler默认可通过dnf安装）
dnf install -y chrony

# 3. 启用并启动chrony服务
systemctl enable --now chronyd

# 4. 强制立刻同步时间（无需等待自动同步）
chronyc makestep

# 5. 验证同步结果
timedatectl
```

验证标准：timedatectl显示`System clock synchronized: yes`、`NTP service: active`，即为同步成功。

## 步骤3：（可选）开放虚拟机防火墙UDP 123端口（兜底保障）

若同步仍失败，可检查并开放虚拟机防火墙UDP 123端口：

```bash
# 检查防火墙状态
systemctl status firewalld

# 永久开放UDP 123端口
firewall-cmd --add-port=123/udp --permanent

# 重载防火墙生效
firewall-cmd --reload

# 验证端口是否开放
firewall-cmd --list-ports | grep 123
```

# 四、关键说明（避坑重点）

## 1\. 关于`\-rtc clock=host,base=utc`的使用

M系列Mac QEMU aarch64环境下，`\-rtc clock=host`默认以UTC为基准，无需额外添加`base=utc`；添加后效果一致，不会影响时区配置（虚拟机已正确识别Asia/Shanghai时区）。

## 2\. ntpd与chrony的区别（为什么ntpd不行，chrony可以）

|对比项|ntpd|chrony|
|---|---|---|
|网络容忍度|对延迟、丢包敏感，不适配NAT、虚拟机等不稳定网络|专门优化不稳定网络，支持高延迟、不对称路由，适配虚拟机/NAT|
|同步策略|时间偏差大时，缓慢修正，易卡在同步失败状态|可强制立刻同步，后台持续微调时钟频率，专治虚拟机时钟漂移|
|虚拟机适配性|官方不推荐，易同步失败|官方推荐，天生适配虚拟机环境|

## 3\. 时间变慢的根本原因及解决逻辑

- 根本原因：M系列Mac QEMU HVF硬件虚拟化存在时钟漂移，且未启用时间同步服务，漂移无法自动修正，导致时间越跑越慢。

- 解决逻辑：通过`\-rtc clock=host`绑定主机时钟，减少基础漂移；通过chrony服务后台持续同步，修正剩余漂移，确保时间与主机一致。

## 4\. 常见报错及解决

- 报错1：`ntpd \-gq` → `unable to bind to wildcard address :: \- another process may be running`：停止ntpd服务后再执行。

- 报错2：`ntpdate pool\.ntp\.org` → `the NTP socket is in use, exiting`：停止ntpd服务，或直接改用chrony。

- 报错3：`chronyc makestep` → `506 Cannot talk to daemon`：chronyd服务未启动，执行`systemctl start chronyd`后再尝试。

# 五、最终效果

配置完成后，虚拟机时间与Mac主机时间完全同步，即使长期运行，也不会出现时间变慢现象；timedatectl持续显示`System clock synchronized: yes`，chrony后台自动维护时间准确性，无需手动干预。

> （注：文档部分内容可能由 AI 生成）
