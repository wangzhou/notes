# VFIO设备热迁移分析文档

## 概述

VFIO (Virtual Function I/O) 设备热迁移是指将直通 (Passthrough) 到虚拟机中的PCI设备的状态在源宿主机保存并恢复到目标宿主机。这需要厂商驱动与VFIO框架配合，实现设备状态的序列化和恢复。

VFIO迁移协议目前有两个版本:
- **协议v1**: 基于region的协议，通过bitmap标志位表示状态 (已废弃)
- **协议v2**: 基于有限状态机 (FSM) 的流式协议，当前版本

## 状态机定义

### 核心状态 (必须支持 VFIO_MIGRATION_STOP_COPY)

| 状态 | 说明 |
|------|------|
| RUNNING | 设备正常运行，产生中断DMA响应MMIO |
| STOP | 设备停止，不产生中断/DMA，不改变内部状态 |
| STOP_COPY | 设备停止，可读取内部状态用于保存 |
| RESUMING | 设备停止，加载恢复状态 |
| ERROR | 设备失败，必须reset |

### 可选状态

| 状态 | 特性 | 说明 |
|------|------|------|
| RUNNING_P2P | VFIO_MIGRATION_P2P | 运行但禁止P2P DMA |
| PRE_COPY | VFIO_MIGRATION_PRE_COPY | 运行但跟踪脏状态 |
| PRE_COPY_P2P | VFIO_MIGRATION_P2P\|PRE_COPY | 跟踪脏状态且禁止P2P DMA |

### 状态转换图

```
                    STOP_COPY ─────────┐
                      ▲              │
                      │              ▼
RESUMING ──► STOP ◄──── RUNNING ◄──── PRE_COPY
  │                    ▲          │
  │                    │          │
  └────────────────────┴────► RUNNING_P2P
                        │            │
                        └────────► PRE_COPY_P2P
```

关键转换:
- **RUNNING → PRE_COPY**: 开始预拷贝阶段，跟踪设备状态变化
- **PRE_COPY → STOP_COPY**: 停止预拷贝，进入停机复制阶段
- **STOP → RESUMING**: 开始恢复，加载保存的状态
- **任意 → ERROR**: 转换失败时进入错误状态

## 协议v2 UAPI

### 迁移能力查询

```c
struct vfio_device_feature_migration {
    __u64 flags;
};
#define VFIO_DEVICE_FEATURE_MIGRATION 1
// flags:
//   VFIO_MIGRATION_STOP_COPY  (1<<0) - 必需，STOP/RUNNING/STOP_COPY/RESUMING
//   VFIO_MIGRATION_P2P     (1<<1) - 可选
//   VFIO_MIGRATION_PRE_COPY  (1<<2) - 可选
```

### 状态控制

```c
struct vfio_device_feature_mig_state {
    __u32 device_state;  // enum vfio_device_mig_state
    __s32 data_fd;   // 迁移数据文件描述符
};
#define VFIO_DEVICE_FEATURE_MIG_DEVICE_STATE 2
```

通过 `VFIO_DEVICE_FEATURE_GET` 查询当前状态，通过 `VFIO_DEVICE_FEATURE_SET` 触发状态转换。

### 预拷贝信息

```c
struct vfio_precopy_info {
    __u64 initial_bytes;  // 初始数据量
    __u64 dirty_bytes;   // 脏数据量
};
#define VFIO_MIG_GET_PRECOPY_INFO  _IO(VFIO_TYPE, VFIO_BASE + 21)
```

## QEMU实现

核心代码: `hw/vfio/migration.c`

### SaveVM回调

```c
static SaveVMHandlers vfio_savevm_handlers = {
    .save_setup    = vfio_save_setup,       // 初始化迁移，设置设备状态为PRE_COPY
    .save_iterate = vfio_save_iterate,   // 迭代传输预拷贝数据
    .save_complete = vfio_save_complete_precopy,  // 停机复制阶段
    .save_cleanup = vfio_save_cleanup,
    .load_setup  = vfio_load_setup,    // 恢复初始化，进入RESUMING
    .load_state = vfio_load_state,
    .load_cleanup = vfio_load_cleanup,
};
```

### 状态转换流程

**Save路径**:
1. `save_setup`: 设置设备状态为 PRE_COPY 或 STOP
2. `save_iterate`: 迭代传输预拷贝数据，通过 `vfio_save_block()` ��取迁移数据
3. `save_complete_precopy`: 切换到 STOP_COPY，传输所有剩余状态数据

**Load路径**:
1. `load_setup`: 设置设备状态为 RESUMING
2. `load_state`: 读取设备状态数据，写入 data_fd
3. `load_cleanup`: 清理，设备恢复到 RUNNING

### 脏页追踪

两种方式:
1. **Device Dirty Tracking**: 设备自身支持，需实现 `migration_get_dirty_pages()`
2. **IOMMU Dirty Tracking**: 通过 `VFIO_IOMMU_DIRTY_PAGES` ioctl 查询

```c
// vfio_iommu_type1.c
#define VFIO_IOMMU_DIRTY_PAGES_FLAG_START    (1 << 0)
#define VFIO_IOMMU_DIRTY_PAGES_FLAG_STOP    (1 << 1)
#define VFIO_IOMMU_DIRTY_PAGES_FLAG_GET_BITMAP (1 << 2)
```

## 内核实现

### 核心框架

`drivers/vfio/vfio_main.c`:

```c
static int vfio_ioctl_device_feature_migration(struct vfio_device *device, ...)
{
    // 返回设备支持的迁移能力 flags
}

static int vfio_ioctl_device_feature_mig_state(struct vfio_device *device, ...)
{
    // 获取/设置设备迁移状态
    // 转换成功时返回 data_fd 用于数据传输
}
```

状态转换校验: `vfio_mig_get_next_state()` 根据FSM表计算下一状态。

### Vendor驱动接口

```c
struct vfio_migration_ops {
    int (*migration_set_state)(struct vfio_device *device, enum vfio_device_mig_state new_state);
    int (*migration_get_state)(struct vfio_device *device, enum vfio_device_mig_state *curr_state);
    int (*migration_get_data_size)(struct vfio_device *device, u64 *stop_copy_length);
};
```

设备需在 `migration_flags` 中宣告支持的能力。

### 支持的驱动

- mlx5 (NVIDIA Mellanox) - v5.18+
- hisi-acc (HiSilicon) - v5.18+
- pds (AMD) - v6.6+
- qat (Intel) - v6.10+
- virtio-vfio-pci

## 迁移数据流

### Save (源端)

```
QEMU状态        设备状态
  RUNNING   --► RUNNING
    │           │
  SETUP   ──┐   │  设置 PRE_COPY，开始跟踪
    │     │   │
 ACTIVE  ──┼───┘  迭代调用 save_iterate()
    │       │
  ACTIVE  ──┐   │
    │     │   │ 切换 STOP_COPY
 FINISH ──┼───┘   │
    │       │      │
 DEVICE ──┘      ▼   传输剩余状态
   STOP   ◄── STOP_COPY
```

### Load (目标端)

```
QEMU状态        设备状态
  IDLE   ─►  STOP
    │          │
 SETUP ─────┐   │
    │     │   │ 设置 RESUMING
  RUN  ◄───┘   │
    │          │
  STOP  ◄──── RESUMING ◄── 从 data_fd 读取并恢复状态
    │              │
 POSTLOAD ──────► RUNNING
```

## 注意事项

1. **P2P设备**: 多设备互相访问时需要协调迁移顺序，使用P2P quiescent状态
2. **Dirty Tracking**: 必须支持否则所有设备内存会永久标记为脏
3. **vIOMMU**: 目前与部分脏页追踪方案不兼容，需配置为自动检测
4. **多设备迁移**: 内核需支持 `VFIO_MIGRATION_ALLOW_MULTI` (v8.0+)

## 关键文件路径

- 内核头文件: `include/uapi/linux/vfio.h` (状态定义)
- 内核驱动: `drivers/vfio/vfio_main.c` (核心FSM)
- QEMU代码: `hw/vfio/migration.c` (save/load实现)
- QEMU PCI: `hw/vfio/pci.c` (设备集成)
