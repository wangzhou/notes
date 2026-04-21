# Virtio-Mem-Block 完整方案设计

## 1. 术语定义

| 术语 | 说明 |
|------|------|
| app | Giant Page Memory，当前设计的暂用名 |
| GPA | Guest Physical Address |
| hugetlbfs | Linux大页文件系统 |
| Stage1 | 内存分配阶段 |
| Stage2 | 内存迁移阶段 |
| block_size | 迁移粒度（默认2M） |

## 2. 需求背景

### 2.1 问题描述
- 特定app需要使用hugetlbfs大页内存（Stage1: 分配）
- 迁移时（Stage2）大页不能拆成4K小页
- 需要保持hugetlb大页对齐

### 2.2 设计目标
- 在VM地址空间中预留一段GPA专门给app使用
- app内存不参与内核的Buddy/伙伴系统管理
- Guest用户态可以通过系统调用/驱动申请使用大页内存
- 迁移时按block_size整块迁移，不拆成4K

### 2.3 约束
- ARM64 + ACPI系统
- 迁移命令：使用monitor的`migrate`命令
- QMP支持：先不做，后续考虑

## 3. 需要实现的组件

### 3.1 组件列表

| 序号 | 组件 | 说明 |
|------|------|------|
| 1 | virtio-mem-block | QEMU设备，管理app内存和迁移 |
| 2 | 修改virt.c | 在内存布局中预留GPA |
| 3 | 修改QEMU ACPI | 上报app地址空间给Guest OS |
| 4 | Guest内核app驱动 | 映射app GPA到用户态 |
| 5 | Guest用户态API | 提供分配/释放接口 |

### 3.2 组件1: virtio-mem-block

职责：
- 管理app GPA区域
- 连接hugetlbfs backend
- 实现save/load迁移逻辑（按block_size）

```c
// hw/virtio/virtio-mem-block.c
// 已有实现框架
```

### 3.3 组件2: 修改virt.c

职责：
- 在memory layout中预留GPA区域
- 定义app_START和app_SIZE

```c
// hw/arm/virt.c
// 需要添加:
// - 定义app地址范围
// - 在map中预留
```

### 3.4 组件3: 修改QEMU ACPI

职责：
- 通过ACPI表上报app地址空间
- 声明为Reserved/Device Memory

```c
// ARM ACPI相关文件
// 需要添加:
// - 构建ACPI表时包含app区域
// - OS看到但不管理
```

### 3.5 组件4: Guest内核app驱动

职责：
- 发现app区域（通过ACPI）
- 建立GPA映射
- 提供用户态接口

```c
// Guest内核
// 需要添加:
// - ACPI解析
// - GPA到VA映射
// - 字符设备驱动 /dev/app
```

### 3.6 组件5: Guest用户态API

职责：
- 提供alloc/free接口
- App调用获取大页内存

```c
// Guest用户态
// API:
// int app_alloc(size, &ptr);
// void app_free(ptr);
```

### 3.7 整体数据流

```
组件1(virtio-mem-block) ──内存──> hugetlbfs backend
         │
         ▼
组件2(virt.c) ──────GPA────> 预留区域
         │
         ▼
组件3(ACPI) ────ACPI表──> Guest OS可见但不管理
         │
         ▼
组件4(guest内核) ──app驱动──> 用户态接口
         │
         ▼
组件5(用户态API) ──────App──> 大页内存使用
```

```
Guest VM:
  +------------------+      +------------------+
  |   Normal RAM    |      |    app Area     |
  |  Buddy管理     |      |  不归Buddy管   |  ← 关键差异
  +------------------+      +------------------+
         ↑                       ↑
         │                       │
  +------+------+        +------+------+
  | Kernel    |        | Kernel    |
  | Buddy    |        | app驱动  |  ← 通过ACPI发现
  +------+------+        +------+------+
         ↑                       ↑
         │                       │
  +------+------+        +------+------+
  | User App |        | User App  |
  | (malloc)|        | (app API)|
  +------+------+        +------+------+
```

## 4. 数据流

### 4.1 Stage1: 内存分配

```
App → request_app_memory(size)
    → Guest Kernel: app驱动
    → GPA映射 ← virtio-mem-block设备管理
    → hugetlbfs backend ← 2M aligned page
    → 返回用户态指针
```

### 4.2 Stage2: 迁移

```
Source QEMU:
1. migrate tcp:dest:4444
2. virtio-mem-block保存:
   - 遍历block_size块
   - 按2M写入迁移流
   - 不拆分!
3. 标准迁移继续

Target QEMU:
1. 接收virtio-mem-block数据
2. 按2M block写入hugetlbfs
3. 恢复配置
4. VM启动
```

## 5. 详细设计

### 5.1 QEMU端设计

#### 5.1.1 VM地址空间分配 (virt.c)

在base_memmap中预留GPA:

```c
// hw/arm/virt.c
#define app_START   0x100000000ULL
#define app_SIZE    0x10000000ULL  // 256MB
```

#### 5.1.2 virtio-mem-block设备

属性:

| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| memdev | 内存后端 | - | hugetlbfs backend |
| block-size | uint64 | 2M | 迁移粒度 |
| memaddr | uint64 | app_START | GPA起始地址 |
| size | uint64 | app_SIZE | 内存大小 |

关键实现:

```c
// virtio-mem-block.c
static void virtio_mem_block_device_realize(DeviceState *dev, Error **errp)
{
    // 1. 检查memdev是hugetlbfs backend
    // 2. 检查block_size对齐
    // 3. host_memory_backend_set_mapped() - 让内存可用于guest
    // 4. 不调用vmstate_register_ram() - 不参与ram.c迁移!
}
```

#### 5.1.3 迁移逻辑

SaveVMHandlers:

```c
// 按block_size写入
static int virtio_mem_block_save_setup(...)
{
    for (offset = 0; offset < size; offset += block_size) {
        qemu_put_buffer(f, mem + offset, block_size);  // 2M
    }
}
```

### 5.2 Guest端设计

#### 5.2.1 ACPI上报

QEMU通过ACPI表把app地址空间上报给Guest OS：

```c
// QEMU生成ACPI表时添加app区域
// 作为ACPI设备或reserved memory entry

// Guest OS看到的效果:
$ cat /proc/iomem
10000000-1fffffff : app Device  ← OS看到但不管理
```

ACPI特点:
- OS可见：在ACPI表中有记录
- OS不管理：标记为reserved/device
- App访问：通过app驱动

#### 5.2.2 用户态API

```c
// 使用方式
#include <app.h>

void *ptr;
int ret = app_alloc(256 * 1024 * 1024, &ptr);  // 256MB
if (ret < 0) {
    perror("app_alloc");
    exit(1);
}

// 使用
memset(ptr, 0, 256 * 1024 * 1024);

// 释放
app_free(ptr);
```

## 6. 当前进度

### 6.1 已完成

| 组件 | 状态 | 说明 |
|------|------|------|
| virtio-mem-block设备 | ✅ | 基本框架 |
| 不参与ram.c迁移 | ✅ | 删除vmstate_register_ram() |
| 文档 | ✅ | 设计方案 |

### 6.2 后续任务

| 组件 | 状态 | 优先级 |
|------|------|--------|
| virt.c GPA预留 | ❌ | 高 |
| ACPI reserved上报 | ❌ | 高 |
| Guest内核app驱动 | ❌ | 高 |
| 自动迁移集成 | ❌ | 中 |
| Guest用户态API | ❌ | 中 |

## 7. 文件结构

```
qemu/
├── hw/
│   └── virtio/
│       └── virtio-mem-block.c       # 设备实现
├── hw/
│   └── arm/
│       └── virt.c                  # 修改：预留GPA
└── docs/
    └── virtio-mem-block.md         # 本文档
```
