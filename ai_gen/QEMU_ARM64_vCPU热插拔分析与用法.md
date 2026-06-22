# QEMU ARM64 虚拟 CPU 热插拔（vCPU hotplug）分析与命令行用法

> 基于分支 `virt-cpuhp-armv8`（Salil Mehta 的 ARM64 vCPU hotplug RFC v7）。
> 说明：本版本（v7）的 QEMU 命令行用法与 v5 一致，未引入新的 `-smp` 子选项。
> 生成日期：2026-07-08

---

## 一、核心概念：ARM 不是"真热插拔"，而是"管理态使能/禁用"

与 x86 不同，ARM 架构**不允许在 VM 初始化完成后再新增 CPU**。CPU 拓扑在 VM 创建时就固定，无法动态改变。

为了在这个约束下仍然对外提供"热插/热拔"的效果，`virt` 机器采取如下做法（见 `hw/arm/virt.c:3475` `virt_setup_lazy_vcpu_realization` 及其注释）：

- 启动时按 **`maxcpus`** 把**所有可能的 vCPU 全部预创建**：拓扑固定、（KVM 下）在宿主机内预创建 vCPU、ACPI 表里全部列出；
- `-smp cpus=N` 数量以内的 vCPU 启动即 **enabled + online**；
- 超出 `cpus`、直到 `maxcpus` 的那些 vCPU，从一开始就描述给固件/ACPI，但处于 **administratively disabled（管理态禁用）** 状态，且**不在启动时 realize**（惰性 realize），以使启动时间正比于"已使能 CPU 数"而非 `maxcpus`。

运行时通过 QMP `device_add` / `device_del` **不创建/销毁 CPU 对象**，而是切换某个**已存在**的可能 vCPU 的管理态。Guest 通过 ACPI GED 事件收到通知，再用 PSCI `CPU_ON` / `CPU_OFF` 完成上下线。

### 与 x86 模型的区别

| 维度 | x86（真热插拔） | ARM v7（本分支） |
|---|---|---|
| CPU 对象 | `device_add` 时**新建** | 启动时**全部预创建**，运行时只切换 admin 态 |
| 拓扑槽位 | 可插入空槽 | 固定，`device_add` 必须**精确匹配**已有槽位 |
| 前置条件 | 通用 | GICv3+ 且 KVM/MTTCG |
| 状态查询 | `query-hotpluggable-cpus` | 该接口报"不支持"，改用 `query-cpus-power-state` / `info cpus-powerstate` |
| 依赖机制 | ACPI | ACPI GED + PSCI CPU_ON/OFF |

### 两个正交的状态

新增 QMP `query-cpus-power-state`（HMP `info cpus-powerstate`）为每个可能 vCPU 报告两个正交状态：

- **Admin state（主机策略，`CPUAdminPowerState`）**：`enabled` / `disabled` / `removed`
- **Oper state（Guest 运行时，`CPUOperPowerState`）**：`on` / `standby` / `off` / `unknown`

对应代码：`hw/core/qdev.c` 的 `admin_power_state` 属性、`qapi/machine.json:1160` 的 `query-cpus-power-state`。

---

## 二、启用条件（Requirements）

deferred-online（类热插拔）模型仅在**同时满足**以下条件时启用（否则 `maxcpus` 必须等于 `cpus`，功能不可用）。见提交 `hw/arm/virt: Clamp 'maxcpus' ...`（`37e7018314`）与 `virt.c:3592` 附近：

- 机器为 `virt`（或设置了 `has_online_capable_cpus` 的机器类型）；
- **`gic-version` ≥ 3**。GICv2 限制为 8 个 CPU 且不支持 online-capable CPU（会 `warn_report` 并关闭该能力，`virt.c:3594`）；
- 加速器支持安全的 deferred online：
  - **KVM**（宿主机支持时），或
  - **多线程 TCG（MTTCG）**；
  - **不支持 HVF / QTest**。

---

## 三、命令行用法（与 v5 一致）

**关键点：`maxcpus` 必须大于启动 CPU 数 `cpus`**，差值即为"启动时禁用、运行时可使能"的 vCPU 数量。

> 注意：`virt.c:3481` 的注释里提到 `-smp disabledcpus=N`，但经全树确认**该选项并不存在**（仅是注释里的遗留说法）。真正生效的是 `cpus` 与 `maxcpus` 的差值。

```bash
qemu-system-aarch64 \
    -machine virt,gic-version=3,accel=kvm \
    -cpu host \
    -smp cpus=4,maxcpus=8 \
    -m 4096 \
    -bios QEMU_EFI.fd \
    -nographic \
    -monitor stdio \
    -qmp unix:/tmp/qmp-sock,server=on,wait=off
```

上例中：4 个 vCPU 启动即在线；另外 4 个（index 4..7）present 但管理态 disabled，可在运行时使能。

---

## 四、查询 CPU 状态

### ⚠️ ARM 上不能用 `info hotpluggable-cpus`

`info hotpluggable-cpus`（QMP `query-hotpluggable-cpus`）在 ARM `virt` 上会报错：

```
(qemu) info hotpluggable-cpus
machine does not support hot-plugging CPUs
```

原因：该命令要求 `mc->has_hotpluggable_cpus == true`（`hw/core/machine-qmp-cmds.c:179`），
而 **ARM `virt` 从不设置这个标志**（只有 x86-pc、ppc-spapr、s390、loongarch 设了）。
这**与 `-cpu` 取值无关**（`max` / `host` / `cortex-a57` 都一样报错）。

这是**有意为之**：`has_hotpluggable_cpus` 表示"能新建/销毁 CPU 对象的真热插拔"（x86 模型）；
ARM 走的是另一个标志 `has_online_capable_cpus`（`virt.c:4922`），即"管理态 enable/disable
已存在的 vCPU"。所以旧的 hotpluggable-cpus 接口对 ARM 故意不适用。

### 用 `query-cpus-power-state`（HMP：`info cpus-powerstate`）— 本特性新增

这是为 ARM 这套模型专门新增的接口。为每个可能 vCPU 报告 Admin + Oper 两个状态，
并带拓扑 id（socket/cluster/core/thread-id）——`device_add` 需要的槽位信息就从这里读：

```
(qemu) info cpus-powerstate
```

Admin 状态：
- `Enabled`：CPU 可被 Guest 使用
- `Disabled`：CPU 存在但被管理态阻断
- `Removed`：CPU 不存在（对 Guest 隐藏）

Oper 状态（若可得）：
- `On`：已上电并执行
- `Standby`：空闲/低功耗，可被事件唤醒（如 WFI）
- `Off`：已下电或被 Guest offline
- `Unknown`：无法确定（极早期 init、teardown、热插瞬态窗口、无 power-state handler 等）

---

## 五、使能一个 vCPU（热插 / hot-add）

从 `info cpus-powerstate` 里选一个 admin 态为 `Disabled` 的槽位，把它**精确的拓扑**传给 `device_add`。`driver` 必须与启动时 `-cpu` 一致的具体 CPU 类型（如 `-cpu host` 对应 `host-arm-cpu`，`-cpu max` 对应 `max-arm-cpu`）：

```
(qemu) device_add driver=host-arm-cpu,id=cpu4,socket-id=1,cluster-id=0,core-id=0,thread-id=0
```

要点（见 `virt.c:2730` `virt_find_cpu` 与 `qdev-monitor.c:719`）：

- `socket-id` / `cluster-id` / `core-id` / `thread-id` 必须命中某个预创建的可能 CPU 槽位；**省略的拓扑字段按 `0` 处理**。
- 请求必须**精确描述**已存在的 vCPU。因为拓扑与 per-CPU 配置在 VM 初始化后就固定，任何不匹配（类型/拓扑/其他 CPU 属性）都会被拒绝——`device_add` **不能重新配置** vCPU。
- 内部实现：把 `id` 作为管理（admin）link 挂到已存在的 CPU 对象上并置为 `enabled`，**不创建新 CPU 对象**；随后通过 ACPI GED 通知 Guest，Guest 用 PSCI `CPU_ON` 上线。

对应 QMP：
```json
{ "execute": "device_add",
  "arguments": { "driver": "host-arm-cpu", "id": "cpu4",
                 "socket-id": 1, "cluster-id": 0, "core-id": 0, "thread-id": 0 } }
```

---

## 六、禁用一个 vCPU（热拔 / hot-remove）

用 hot-add 时提供的 `id` 调用 `device_del`：

```
(qemu) device_del id=cpu4
```

因为 CPU 对象并未真正 unplug，该请求会被转成 **administrative disable**（而非 QOM 对象移除）。见 `qmp_device_del`（`qdev-monitor.c:977`）：先尝试常规 hot-unplug，ARM vCPU 不允许 unplug，于是转为 `admin_disable_pending`。

> **注意（需要 Guest 配合）**：`device_del` 只是一个"请求"。Guest 收到 ACPI 事件后把 CPU offline（PSCI `CPU_OFF`），QEMU 才完成状态迁移：标记为管理态 disabled、移除 admin link、发出 `DEVICE_DELETED` 事件。
>
> 启动 CPU（index 0）永远不能被 disable。

---

## 七、迁移（Migration）语义

- 管理态 disabled（未 realize）的 vCPU **不参与迁移**；
- 管理态 enabled 的 vCPU **迁移其操作态**，包括 `off` 状态。

见 `virt_park_cpu_in_userspace`（`virt.c:2854`）：disabled vCPU 会 `cpu_vmstate_unregister`，从而不迁移其状态。

---

## 八、关键代码索引

| 功能 | 文件:行 / 函数 |
|---|---|
| maxcpus 裁剪、`has_online_capable_cpus` 判定 | `hw/arm/virt.c` 提交 `37e7018314` |
| 惰性 realize / 启动时禁用 CPU | `hw/arm/virt.c:3475` `virt_setup_lazy_vcpu_realization` |
| device_add 解析到已存在 vCPU | `hw/arm/virt.c:2730` `virt_find_cpu`、`:2833` `virt_find_device` |
| device_add → admin-enable 通用路径 | `system/qdev-monitor.c:719` `qdev_try_add_admin_link_and_enable_existing_device` |
| device_del → admin-disable | `system/qdev-monitor.c:977` `qmp_device_del` |
| admin power state 属性/枚举/访问器 | `hw/core/qdev.c`、提交 `58cce2d8fc` |
| QMP `query-cpus-power-state` / HMP `info cpus-powerstate` | `qapi/machine.json:1160`、`hmp-commands-info.hx`、提交 `2beb25c7da` |
| ACPI GED 上报 CPU 事件 | `hw/acpi/ged.c`、提交 `ae50ffa910` |
| park/unpark（迁移排除） | `hw/arm/virt.c:2854` / `:2866` |
| ACPI eject → 同步 disable | `hw/acpi/cpu.c` `cpu_hotplug_wr`、提交 `7bb9929f0e` |

---

## 九、完整流程时序（概览）

**热插（enable）：**
```
device_add id=cpuN,...  ->  virt_find_cpu 匹配槽位  ->  挂 admin link + 置 enabled
                        ->  惰性 realize + unpark vCPU  ->  ACPI GED 通知 Guest
                        ->  Guest PSCI CPU_ON  ->  vCPU 上线执行
```

**热拔（disable）：**
```
device_del id=cpuN  ->  hot-unplug 被拒 -> 转 admin_disable_pending
                    ->  ACPI GED 通知 Guest  ->  Guest offline + PSCI CPU_OFF
                    ->  QEMU 完成：park vCPU + 置 disabled + 移除 admin link
                    ->  发出 DEVICE_DELETED 事件
```
