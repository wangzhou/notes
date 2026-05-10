# Linux 内核 dma-buf 子系统分析

## 一、概述

dma-buf（DMA Buffer Sharing Framework）是 Linux 内核提供的一套**跨设备/子系统共享缓冲区**的框架。它创建于 2011 年（Linaro 主导，作者 Sumit Semwal），核心思想是：让一个设备（exporter/导出者）分配的物理内存缓冲区，能够通过文件描述符在进程间传递，并被另一个设备（importer/导入者）进行 DMA 访问。

## 二、使用场景

### 1. 零拷贝缓冲区共享（核心场景）

最典型的场景是**图形渲染管线**和**多媒体管线**：

```
GPU渲染 → DRM显示 → 视频编码 → 摄像头采集
   ↑__________________↓
      (通过 dma-buf fd 传递，零拷贝)
```

- **DRM/GEM → 显示控制器**：GPU 渲染的 framebuffer 通过 dma-buf fd 传给显示硬件直接扫描输出
- **摄像头(V4L2) → GPU/编码器**：摄像头采集的帧数据通过 dma-buf 传给 GPU 做处理或传给视频编码器做压缩
- **GPU → 视频编码器**：GPU 渲染结果直接作为编码器输入

### 2. Android ION / DMA-heap 替代

Android 原先使用 ION 做用户态内存分配，后来被 `dma-buf + dma-heap` 体系替代。用户态进程可以从 `/dev/dma_heap/<heap_name>` 设备节点分配特定类型的内存（system heap, CMA heap 等），获得 dma-buf fd，然后传递给 GPU/VPU/Camera 等硬件使用。

### 3. VirtIO / 虚拟化场景

`udmabuf`（userspace mappable dma-buf）允许用户态将 memfd 区域创建为可被 DMA 访问的缓冲区，用于 QEMU/VFIO 等虚拟化场景中 guest 与 host 共享内存。

### 4. PCIe Peer-to-Peer (P2P)

两个 PCIe 设备之间可以直接通过 dma-buf 共享数据，不需要经过系统内存中转。通过 `dma_buf_attach_ops.allow_peer2peer` 标记支持。

### 5. RDMA / 网络卸载

InfiniBand 和 RDMA 子系统通过 dma-buf 实现用户态内存到网卡的零拷贝传输（`drivers/infiniband/core/umem_dmabuf.c`）。

### 6. Xen 虚拟化

Xen 前端驱动可通过 `drivers/xen/gntdev-dmabuf.c` 将 grant table 映射导出为 dma-buf，实现 guest 间零拷贝数据共享。

---

## 三、使用方法

### 1. 内核态导出者 (Exporter)

导出者是**分配缓冲区**的驱动（如 DRM 驱动、DMA-heap、udmabuf），需要实现 `struct dma_buf_ops`。

```c
// 示例：简化的导出者实现

static struct sg_table *my_map_dma_buf(struct dma_buf_attachment *attach,
                                        enum dma_data_direction dir)
{
    struct my_buffer *buf = attach->dmabuf->priv;
    struct sg_table *sgt;
    // 为导入设备做 DMA 映射
    sgt = &buf->sg_table;
    dma_map_sgtable(attach->dev, sgt, dir, 0);
    return sgt;
}

static void my_unmap_dma_buf(struct dma_buf_attachment *attach,
                              struct sg_table *sgt,
                              enum dma_data_direction dir)
{
    dma_unmap_sgtable(attach->dev, sgt, dir, 0);
}

static void my_release(struct dma_buf *dmabuf)
{
    struct my_buffer *buf = dmabuf->priv;
    // 释放底层缓冲区
    kfree(buf);
}

static const struct dma_buf_ops my_dma_buf_ops = {
    .attach           = my_attach,              // 可选
    .detach           = my_detach,              // 可选
    .map_dma_buf      = my_map_dma_buf,         // 必须
    .unmap_dma_buf    = my_unmap_dma_buf,       // 必须
    .release          = my_release,             // 必须
    .mmap             = my_mmap,                // 可选
    .vmap             = my_vmap,                // 可选
    .begin_cpu_access = my_begin_cpu_access,    // 可选
};

// 导出流程
int export_my_buffer(size_t size)
{
    DEFINE_DMA_BUF_EXPORT_INFO(exp_info);
    struct dma_buf *dmabuf;
    int fd;

    exp_info.ops  = &my_dma_buf_ops;
    exp_info.size = size;
    exp_info.flags = O_RDWR;
    exp_info.priv = my_alloc_buffer(size);  // 分配私有缓冲区

    dmabuf = dma_buf_export(&exp_info);
    if (IS_ERR(dmabuf))
        return PTR_ERR(dmabuf);

    // 获取文件描述符传递给用户态
    fd = dma_buf_fd(dmabuf, O_CLOEXEC);
    // ... 通过 ioctl 或 fd 传递将 fd 返回给用户态
    return fd;
}
```

**dma_buf_ops 回调说明**：

| 回调 | 必要性 | 作用 |
|------|--------|------|
| `attach()` | 可选 | 设备附着时通知导出者，可检查设备兼容性。返回 -EBUSY 可拒绝附着 |
| `detach()` | 可选 | 设备分离时通知导出者，清理 per-attachment 数据 |
| `pin()` | 可选 | 锁定 buffer 位置防止迁移。与 `unpin` 必须成对出现，有此回调表示动态导出者 |
| `unpin()` | 可选 | 解锁 buffer 允许迁移 |
| `map_dma_buf()` | **必须** | 返回 `sg_table`，包含该设备可 DMA 访问的地址和长度。返回的地址必须 PAGE_SIZE 对齐 |
| `unmap_dma_buf()` | **必须** | 解除 DMA 映射，释放 `map_dma_buf` 返回的 sg_table |
| `release()` | **必须** | 释放底层缓冲区，在最后一个引用释放后调用 |
| `begin_cpu_access()` | 可选 | CPU 访问前保证缓存一致性（如 cache flush） |
| `end_cpu_access()` | 可选 | CPU 访问结束后的缓存操作 |
| `mmap()` | 可选 | 支持用户态 mmap 映射此 dma-buf |
| `vmap()` / `vunmap()` | 可选 | 内核态虚拟地址映射 |

### 2. 内核态导入者 (Importer)

导入者是**使用缓冲区做 DMA** 的驱动（如 DRM 显示驱动、V4L2 驱动、网卡驱动）。

```c
// 示例：简化的导入者实现

int import_and_dma(int dma_buf_fd)
{
    struct dma_buf *dmabuf;
    struct dma_buf_attachment *attach;
    struct sg_table *sgt;
    dma_addr_t dma_addr;
    int ret;

    // 1. 从 fd 获取 dma_buf（增加引用计数）
    dmabuf = dma_buf_get(dma_buf_fd);
    if (IS_ERR(dmabuf))
        return PTR_ERR(dmabuf);

    // 2. 附着到设备
    //    非动态方式（静态附着）:
    attach = dma_buf_attach(dmabuf, my_device);
    //    或动态方式:
    //    attach = dma_buf_dynamic_attach(dmabuf, my_device,
    //                                     &my_importer_ops, priv);

    if (IS_ERR(attach)) {
        ret = PTR_ERR(attach);
        goto err_put;
    }

    // 3. 获取 DMA 映射的 scatterlist（需持有 resv 锁）
    //    简化版（内部自动加锁）:
    sgt = dma_buf_map_attachment_unlocked(attach, DMA_BIDIRECTIONAL);
    if (IS_ERR(sgt)) {
        ret = PTR_ERR(sgt);
        goto err_detach;
    }

    // 4. 使用 sgt 中的 DMA 地址做硬件操作
    dma_addr = sg_dma_address(sgt->sgl);
    // ... 发起 DMA 传输 ...

    // 5. 清理
    dma_buf_unmap_attachment_unlocked(attach, sgt, DMA_BIDIRECTIONAL);
    dma_buf_detach(dmabuf, attach);
    dma_buf_put(dmabuf);
    return 0;

err_detach:
    dma_buf_detach(dmabuf, attach);
err_put:
    dma_buf_put(dmabuf);
    return ret;
}
```

**动态导入者 vs 静态导入者**：

| 特性 | 静态导入者 | 动态导入者 |
|------|-----------|-----------|
| 创建方式 | `dma_buf_attach()` | `dma_buf_dynamic_attach()` |
| buffer 迁移 | 不支持，buffer 在 map 时自动 pin | 通过 `move_notify` 回调支持 |
| map/unmap | 框架自动 pin/unpin | 导入者需自行调用 `dma_buf_pin()/unpin()` |
| fence 等待 | 框架在 map 时自动等待 | 导入者需自行等待 resv 的排他 fence |
| 适用场景 | 传统驱动，buffer 位置不变 | 现代 GPU 驱动，支持 buffer 热迁移 |

### 3. 用户态使用

```c
// 3.1 通过 DMA-heap 分配 dma-buf
int alloc_dma_buf(void)
{
    int heap_fd = open("/dev/dma_heap/system", O_RDWR);
    struct dma_heap_allocation_data data = {
        .len = 4096,
        .fd_flags = O_RDWR,
    };
    ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &data);
    close(heap_fd);
    return data.fd;  // dma-buf fd
}

// 3.2 mmap 到用户空间并访问
void use_dma_buf(int dma_buf_fd)
{
    struct dma_buf_sync sync;
    void *ptr;

    // mmap
    ptr = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, dma_buf_fd, 0);

    // CPU 访问前必须调用 SYNC_START
    sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW;
    ioctl(dma_buf_fd, DMA_BUF_IOCTL_SYNC, &sync);

    // 读写数据
    memset(ptr, 0, 4096);

    // CPU 访问结束后调用 SYNC_END
    sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW;
    ioctl(dma_buf_fd, DMA_BUF_IOCTL_SYNC, &sync);

    munmap(ptr, 4096);
}

// 3.3 隐式同步 - 使用 poll 等待 DMA 完成
void wait_for_dma(int dma_buf_fd)
{
    struct pollfd pfd = {
        .fd = dma_buf_fd,
        .events = POLLIN,  // POLLIN=可读(等待写者完成), POLLOUT=可写(等待所有访问者完成)
    };
    poll(&pfd, 1, -1);  // 阻塞直到 DMA 完成
}
```

### 4. 显式同步 (Explicit Synchronization)

现代图形 API（如 Vulkan）使用显式同步模型，需要与隐式同步互操作：

```c
// 4.1 从 dma-buf 导出 fence 为 sync_file
int export_sync_file(int dma_buf_fd)
{
    struct dma_buf_export_sync_file exp = {
        .flags = DMA_BUF_SYNC_READ  // 等待所有写者完成
    };
    ioctl(dma_buf_fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &exp);
    return exp.fd;  // sync_file fd，可作为 GPU submit 的 wait fence
}

// 4.2 将 GPU 完成后的 sync_file 导入到 dma-buf
int import_sync_file(int dma_buf_fd, int render_done_fd)
{
    struct dma_buf_import_sync_file imp = {
        .flags = DMA_BUF_SYNC_WRITE,  // 插入写 fence
        .fd = render_done_fd,
    };
    return ioctl(dma_buf_fd, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &imp);
}
```

**典型 Vulkan 互操作流程**：

```
1. EXPORT_SYNC_FILE (READ) → sync_fd_A  (snapshot 当前写 fence)
2. vkQueueSubmit(wait=sync_fd_A, signal=sync_fd_B)  (GPU 等待并生成新 fence)
3. IMPORT_SYNC_FILE (WRITE, sync_fd_B)              (将 GPU 完成 fence 插入 dma-buf)
```

### 5. 设置 dma-buf 名称（调试用）

```c
ioctl(dma_buf_fd, DMA_BUF_SET_NAME, "my-framebuffer");
// 名称可在 /proc/<pid>/fdinfo/<fd> 和 debugfs 中查看
```

---

## 四、内核代码实现

### 1. 文件结构

```
drivers/dma-buf/
├── dma-buf.c              # 核心框架（缓冲区的导出、导入、映射、同步）
├── dma-buf-mapping.c      # 异步映射支持（MMIO/phys_vec → sg_table）
├── dma-heap.c             # DMA Heap 子系统（用户态分配入口）
├── dma-fence.c            # DMA Fence（DMA 完成同步原语）
├── dma-fence-array.c      # Fence 数组（多 fence 归为一组）
├── dma-fence-chain.c      # Fence 链式组合（时间线 fence）
├── dma-fence-unwrap.c     # Fence 展开迭代器
├── dma-resv.c             # 预留对象（共享/排他 fence 管理）
├── sync_file.c            # Sync File（用户态 fence fd 抽象）
├── sw_sync.c              # 软件同步点（调试/测试用）
├── udmabuf.c              # 用户态可映射的 dma-buf（memfd → dma-buf）
├── heaps/
│   ├── system_heap.c      # 系统内存 Heap 导出者（buddy 分配）
│   └── cma_heap.c         # CMA 连续内存 Heap 导出者
└── selftests.h / st-*.c   # 内核自测试

include/linux/
├── dma-buf.h              # 核心 API 头文件
├── dma-buf-mapping.h      # 映射辅助函数
├── dma-heap.h             # Heap 内核 API
├── dma-fence.h            # DMA Fence API
├── dma-fence-chain.h      # Fence Chain API
├── dma-fence-array.h      # Fence Array API
├── dma-fence-unwrap.h     # Fence Unwrap API
├── dma-resv.h             # Reservation Object API
└── sync_file.h            # Sync File API

include/uapi/linux/
├── dma-buf.h              # 用户态 ABI (ioctl 定义)
├── dma-heap.h             # Heap 用户态 ABI
├── udmabuf.h              # udmabuf 用户态 ABI
└── sync_file.h            # Sync File 用户态 ABI

Documentation/
├── driver-api/dma-buf.rst               # 驱动 API 文档
├── userspace-api/dma-buf-heaps.rst      # Heap 用户态文档
└── userspace-api/dma-buf-alloc-exchange.rst  # 缓冲区交换设计指南
```

### 2. 核心数据结构

```
                    ┌──────────────────────────────┐
                    │         dma_buf              │  (共享缓冲区对象)
                    ├──────────────────────────────┤
                    │ size: 缓冲区大小（不可变）     │
                    │ file ────────────────────────┼──→ struct file (fd 背后的文件)
                    │ ops ─────────────────────────┼──→ struct dma_buf_ops (导出者回调)
                    │ priv ────────────────────────┼──→ 导出者私有数据（如 system_heap_buffer）
                    │ resv ────────────────────────┼──→ struct dma_resv (fence 管理)
                    │ attachments (list_head)       │
                    │ vmapping_counter / vmap_ptr   │
                    │ poll / cb_in / cb_out         │
                    │ exp_name / name               │
                    │ owner (导出者模块)            │
                    └──────────────┬───────────────┘
                                   │ list_head: attachments
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
    ┌─────────────────────┐ ┌─────────────────────┐
    │ dma_buf_attachment  │ │ dma_buf_attachment  │
    ├─────────────────────┤ ├─────────────────────┤
    │ dmabuf → 指回 dma_buf│ │ dmabuf → 指回 dma_buf│
    │ dev → 导入设备        │ │ dev → 导入设备        │
    │ node (list node)     │ │ node (list node)     │
    │ peer2peer            │ │ peer2peer            │
    │ importer_ops ────────┼─┼→ dma_buf_attach_ops  │
    │ importer_priv        │ │   .allow_peer2peer   │
    │ priv (导出者私有)     │ │   .move_notify()     │
    └─────────────────────┘ └─────────────────────┘
```

#### `struct dma_buf` (include/linux/dma-buf.h:294)

```c
struct dma_buf {
    size_t size;                    // 缓冲区大小（生命周期内不变）
    struct file *file;              // 文件指针，用于跨进程共享和引用计数
    struct list_head attachments;   // 所有 dma_buf_attachment 链表
    const struct dma_buf_ops *ops;  // 导出者操作回调
    unsigned vmapping_counter;      // vmap 引用计数
    struct iosys_map vmap_ptr;      // 当前 vmap 指针
    const char *exp_name;           // 导出者名称（调试用）
    const char *name;               // 用户态设置的名称（via IOCTL）
    spinlock_t name_lock;           // name 访问锁
    struct module *owner;           // 导出者模块
    struct list_head list_node;     // 全局 dma-buf 链表节点
    void *priv;                     // 导出者私有数据
    struct dma_resv *resv;          // 预留对象（隐式同步 fence）
    wait_queue_head_t poll;         // poll 等待队列
    struct dma_buf_poll_cb_t {      // fence 完成回调
        struct dma_fence_cb cb;
        wait_queue_head_t *poll;
        __poll_t active;
    } cb_in, cb_out;                // cb_in=读等待, cb_out=写等待
};
```

#### `struct dma_buf_ops` (include/linux/dma-buf.h:37)

```c
struct dma_buf_ops {
    int  (*attach)(struct dma_buf *, struct dma_buf_attachment *);       // 可选
    void (*detach)(struct dma_buf *, struct dma_buf_attachment *);       // 可选
    int  (*pin)(struct dma_buf_attachment *attach);                      // 可选（成对出现）
    void (*unpin)(struct dma_buf_attachment *attach);                    // 可选（成对出现）

    struct sg_table * (*map_dma_buf)(struct dma_buf_attachment *,
                                      enum dma_data_direction);          // 必须
    void (*unmap_dma_buf)(struct dma_buf_attachment *,
                          struct sg_table *,
                          enum dma_data_direction);                      // 必须

    void (*release)(struct dma_buf *);                                   // 必须

    int  (*begin_cpu_access)(struct dma_buf *, enum dma_data_direction); // 可选
    int  (*end_cpu_access)(struct dma_buf *, enum dma_data_direction);   // 可选
    int  (*mmap)(struct dma_buf *, struct vm_area_struct *vma);          // 可选
    int  (*vmap)(struct dma_buf *dmabuf, struct iosys_map *map);         // 可选
    void (*vunmap)(struct dma_buf *dmabuf, struct iosys_map *map);       // 可选
};
```

#### `struct dma_buf_attachment` (include/linux/dma-buf.h:489)

```c
struct dma_buf_attachment {
    struct dma_buf *dmabuf;                       // 指向所属 dma_buf
    struct device *dev;                           // 导入设备
    struct list_head node;                        // 在 dma_buf.attachments 中的节点
    bool peer2peer;                               // 是否支持 P2P
    const struct dma_buf_attach_ops *importer_ops; // 导入者操作（动态导入者）
    void *importer_priv;                          // 导入者私有数据
    void *priv;                                   // 导出者私有 per-attachment 数据
};
```

#### `struct dma_buf_attach_ops` (include/linux/dma-buf.h:439)

```c
struct dma_buf_attach_ops {
    bool allow_peer2peer;                  // 是否支持 P2P 资源（无 struct page）
    void (*move_notify)(struct dma_buf_attachment *attach); // buffer 迁移通知
};
```

### 3. 核心流程代码分析

#### 3.1 dma_buf_export() — 导出缓冲区 (dma-buf.c:708)

```c
struct dma_buf *dma_buf_export(const struct dma_buf_export_info *exp_info)
```

**执行流程**：

1. **参数验证**：检查 `ops->map_dma_buf`, `ops->unmap_dma_buf`, `ops->release` 三个必须回调都存在；检查 `pin`/`unpin` 必须成对出现；`priv` 不能为 NULL
2. **获取模块引用**：`try_module_get(exp_info->owner)` 防止导出者模块在使用中被卸载
3. **创建匿名 inode 和 file**：通过 `dma_buf_getfile()` 在伪文件系统 `dmabuf` 上创建 inode，绑定 `dma_buf_fops`（包含 mmap/poll/ioctl/llseek/show_fdinfo）
4. **分配 dma_buf 结构**：如果没有提供外部 `resv` 对象，则将 `dma_resv` 紧接在 `dma_buf` 之后分配（`dmabuf->resv = (struct dma_resv *)&dmabuf[1]`）
5. **初始化 poll**：设置 `init_waitqueue_head`, `cb_in`/`cb_out` 回调结构
6. **初始化 attachments**：`INIT_LIST_HEAD(&dmabuf->attachments)`
7. **建立关联**：`file->private_data = dmabuf`，`dentry->d_fsdata = dmabuf`，`dmabuf->file = file`
8. **加入全局列表**：`__dma_buf_list_add()` 维护全局链表，用于 debugfs 和迭代器

**关键设计**：resv 对象的分配优化——如果导出者未提供外部 resv，框架将其嵌入 dma_buf 所在的同一个 `kzalloc` 分配中，节省一次分配。

#### 3.2 dma_buf_attach() / dma_buf_dynamic_attach() — 设备附着 (dma-buf.c:1009)

```c
struct dma_buf_attachment *
dma_buf_dynamic_attach(struct dma_buf *dmabuf, struct device *dev,
                       const struct dma_buf_attach_ops *importer_ops,
                       void *importer_priv)
```

**执行流程**：

1. **分配 attachment 结构**：`kzalloc_obj()`
2. **设置 peer2peer 标记**：如果 importer_ops 存在且 `.allow_peer2peer` 为真
3. **调用导出者 attach 回调**（可选）：让导出者检查设备是否能访问这块内存——例如 VRAM 中的 buffer 无法被非 GPU 设备直接访问，导出者此时可返回 -EBUSY 拒绝附着
4. **加入 attachments 链表**：在 `dma_resv` 锁保护下将 attachment 插入 `dmabuf->attachments`

`dma_buf_attach()` 是 `dma_buf_dynamic_attach()` 的简化包装（不传 importer_ops），表示非动态导入者。非动态导入者在 `map_attachment` 时框架会自动执行 `pin` 和 fence 等待，无需导入者关心。

#### 3.3 dma_buf_map_attachment() — 获取 DMA 映射 (dma-buf.c:1169)

```c
struct sg_table *dma_buf_map_attachment(struct dma_buf_attachment *attach,
                                        enum dma_data_direction direction)
```

**执行流程**：

1. **加锁断言**：`dma_resv_assert_held()` — 调用者必须持有 resv 锁（`_unlocked` 变体内部自动加锁）
2. **Pin buffer**（对非动态导入者）：调用 `ops->pin()` 锁定 buffer 位置，防止导出者在此期间迁移 buffer
3. **调用导出者的 map_dma_buf**：获取 `sg_table`，包含 DMA 地址和长度。导出者在此处做实际的 DMA 映射（如 `dma_map_sgtable()`）
4. **等待 fence**（对非动态导入者）：`dma_resv_wait_timeout(DMA_RESV_USAGE_KERNEL)` 等待所有 kernel 类型 fence 完成。动态导入者需自行处理 fence 等待
5. **DMABUF_DEBUG 保护**（`CONFIG_DMABUF_DEBUG`）：包装 sg_table，将每个 sg entry 的 `page_link` 替换为 NULL，只暴露 `dma_address` 和 `dma_len`，防止导入者错误使用 `struct page`
6. **对齐检查**（`CONFIG_DMA_API_DEBUG`）：验证所有 DMA 地址和长度都是 PAGE_SIZE 对齐
7. **错误回滚**：如果任何步骤失败，调用 `unmap` 和 `unpin` 回滚

**关键设计**：`dma_buf_pin_on_map()` 的逻辑——只有非动态导入者才需要在 map 时自动 pin。动态导入者由框架保证映射一致性（通过 `move_notify` 机制），不需要强制 pin。

#### 3.4 dma_buf_poll() — 隐式同步轮询 (dma-buf.c:337)

```c
static __poll_t dma_buf_poll(struct file *file, poll_table *poll)
```

**执行流程**：

1. **获取 resv**：从 `dmabuf->resv` 获取 reservation object
2. **注册 poll_wait**：将调用者加入 `dmabuf->poll` 等待队列
3. **判断事件类型**：
   - `POLLOUT`（可写）：需要等待 resv 中的**所有** fence（包括共享和排他）
   - `POLLIN`（可读）：只需等待最近的**排他（写）fence**
4. **注册 fence 回调**：通过 `dma_buf_poll_add_cb()` 在相应的 fence 上注册 `dma_buf_poll_cb` 回调
5. **fence 完成时**：`dma_buf_poll_cb()` 被调用，唤醒 poll waitqueue，发送 `EPOLLIN`/`EPOLLOUT` 事件

**poison 状态检测**：cb_in/cb_out 的 active 字段防止重复注册回调。如果回调已注册且未完成，返回 0（不报告事件）。

#### 3.5 DMA_BUF_IOCTL_SYNC — CPU 访问缓存管理 (dma-buf.c:540)

```c
case DMA_BUF_IOCTL_SYNC:
    if (sync.flags & DMA_BUF_SYNC_END)
        ret = dma_buf_end_cpu_access(dmabuf, direction);
    else
        ret = dma_buf_begin_cpu_access(dmabuf, direction);
```

`dma_buf_begin_cpu_access()` 做了两件事：

1. **调用导出者的 begin_cpu_access 回调**：让导出者做必要的准备（如 cache flush/invalidate）
2. **等待 fence**：`__dma_buf_begin_cpu_access()` 等待 resv 上对应方向的所有 fence，确保之前的 DMA 操作已完成

`dma_buf_end_cpu_access()` 调用导出者的 end_cpu_access 回调，让导出者做清理（如 cache writeback）。

#### 3.6 dma_buf_export_sync_file / dma_buf_import_sync_file — 显式同步 (dma-buf.c:436)

**EXPORT 流程**：

1. 从 dmabuf->resv 中获取对应方向的 singleton fence（合并所有匹配的 fence）
2. 如果没有 fence，使用 `dma_fence_get_stub()`（一个已完成的虚拟 fence）
3. 通过 `sync_file_create()` 将 fence 包装为 sync_file
4. 将 sync_file 的 fd 返回给用户态

**IMPORT 流程**：

1. 通过 `sync_file_get_fence()` 从传入的 fd 提取 fence
2. 统计 fence 数量
3. 在 dma_resv 锁内调用 `dma_resv_reserve_fences()` 预留插槽
4. 遍历展开的 fence，逐个通过 `dma_resv_add_fence()` 添加到 resv 中

### 4. 伪文件系统

dma-buf 使用一个名为 `dmabuf` 的伪文件系统类型（`struct file_system_type dma_buf_fs_type`），在模块初始化时通过 `kern_mount()` 挂载。

```c
static struct file_system_type dma_buf_fs_type = {
    .name = "dmabuf",
    .init_fs_context = dma_buf_fs_init_context,  // 创建匿名 inode，设置 dentry ops
    .kill_sb = kill_anon_super,
};
```

关键 dentry 操作：
- `dma_buf_release()`：在最后一个 reference 释放时调用 `ops->release()`，然后清理 resv 并释放内存
- `dmabuffs_dname()`：生成 `dmabuf:<name>` 格式的 dentry 路径名

#### file_operations 绑定

```c
static const struct file_operations dma_buf_fops = {
    .release        = dma_buf_file_release,    // 从全局列表移除
    .mmap           = dma_buf_mmap_internal,   // 转发到 ops->mmap
    .llseek         = dma_buf_llseek,          // 只支持 SEEK_SET(0) 和 SEEK_END(size)
    .poll           = dma_buf_poll,            // fence-based 隐式同步
    .unlocked_ioctl = dma_buf_ioctl,           // SYNC / EXPORT_SYNC_FILE / IMPORT_SYNC_FILE
    .compat_ioctl   = compat_ptr_ioctl,
    .show_fdinfo    = dma_buf_show_fdinfo,     // 显示 size/count/exp_name/name
};
```

`is_dma_buf_file()` 通过比较 `file->f_op == &dma_buf_fops` 来判断一个 fd 是否是 dma-buf。

### 5. 全局管理

```c
static DEFINE_MUTEX(dmabuf_list_mutex);
static LIST_HEAD(dmabuf_list);  // 全局 dma-buf 链表
```

所有活跃的 dma-buf 对象都链入全局 `dmabuf_list`，通过以下接口访问：

- `dma_buf_iter_begin()` / `dma_buf_iter_next()`：安全遍历全局列表（正确处理并发释放）
- debugfs `/sys/kernel/debug/dma_buf/bufinfo`：展示所有 buffer 的大小、引用计数、导出者名称、附属设备列表

### 6. Locking 约定 (dma-buf.c:923)

为防止死锁，dma-buf 有严格的锁规则：

**导入者必须在持有 dma_resv 锁时调用**：
- `dma_buf_pin()` / `dma_buf_unpin()`
- `dma_buf_map_attachment()` / `dma_buf_unmap_attachment()`
- `dma_buf_vmap()` / `dma_buf_vunmap()`

**导入者不能在持有 dma_resv 锁时调用**：
- `dma_buf_attach()` / `dma_buf_detach()`
- `dma_buf_export()` / `dma_buf_fd()` / `dma_buf_get()` / `dma_buf_put()`
- `dma_buf_mmap()` / `dma_buf_begin_cpu_access()` / `dma_buf_end_cpu_access()`
- `dma_buf_map_attachment_unlocked()` / `dma_buf_vmap_unlocked()`

**导出者回调在以下状态调用**：
- `attach()`, `detach()`, `release()`, `begin_cpu_access()`, `end_cpu_access()`, `mmap()` — **未持有** resv 锁，导出者可自行加锁
- `pin()`, `unpin()`, `map_dma_buf()`, `unmap_dma_buf()`, `vmap()`, `vunmap()` — **已持有** resv 锁，导出者不能再加锁

### 7. DMA Heap 子系统

DMA-heap 提供了标准化的用户态 dma-buf 分配入口。

**heap 注册**：调用 `dma_heap_add()` 注册 heap，创建 `/dev/dma_heap/<name>` 字符设备。

**分配流程**（`dma-heap.c:57`）：

```c
static int dma_heap_buffer_alloc(struct dma_heap *heap, size_t len,
                                 u32 fd_flags, u64 heap_flags)
{
    len = PAGE_ALIGN(len);                          // 页对齐
    dmabuf = heap->ops->allocate(heap, len, ...);   // 调用 heap 特定分配
    fd = dma_buf_fd(dmabuf, fd_flags);              // 获取 fd
    return fd;
}
```

#### System Heap (heaps/system_heap.c)

- 从 buddy 分配器分配页面
- 使用三个 order：`{8(1MB), 4(64KB), 0(4KB)}`，优先尝试大页以优化 IOMMU TLB
- 支持 mmap（`remap_pfn_range`）、vmap（`vmap()`）、CPU access
- 注册名称为 `"system"`，生成 `/dev/dma_heap/system`

#### CMA Heap (heaps/cma_heap.c)

- 从 CMA 区域分配物理连续内存，适用于需要连续内存的设备
- 支持 page fault 方式的 mmap（`vmf_insert_pfn`）
- 默认名称为 `"default_cma_region"`

### 8. Udmabuf

`udmabuf.c` 将 memfd 区域转换为 dma-buf，主要用于 QEMU 等虚拟化软件：

- `UDMABUF_CREATE` ioctl：单个 memfd 区域 → dma-buf
- `UDMABUF_CREATE_LIST` ioctl：多个 memfd 区域列表 → dma-buf
- 限制条件：memfd 必须 sealed（`F_SEAL_SHRINK`），不能是 writable sealed；默认 size_limit = 64MB，单次创建项数限制 1024

### 9. Debugfs 调试接口

```
/sys/kernel/debug/dma_buf/bufinfo
```

输出示例：
```
Dma-buf Objects:
size     flags    mode     count    exp_name ino      name
00004000 00008002 00008002 00000001 system  00000013  <none>

        Attached Devices:
Total 0 devices attached

Total 1 objects, 16384 bytes
```

此外，每个进程的 `/proc/<pid>/fdinfo/<fd>` 也包含 dma-buf 详情。

### 10. Kconfig 配置选项

```
CONFIG_DMA_SHARED_BUFFER      # 核心 dma-buf 支持（自动选中）
CONFIG_SYNC_FILE              # 显式同步框架（sync_file）
CONFIG_SW_SYNC                # 软件同步测试框架（标记为危险）
CONFIG_UDMABUF                # 用户态 memfd → dma-buf
CONFIG_DMABUF_MOVE_NOTIFY     # 动态 buffer 迁移支持（实验性）
CONFIG_DMABUF_DEBUG           # 调试检查（隐藏 struct page）
CONFIG_DMABUF_SELFTESTS       # 内核自测试
CONFIG_DMABUF_HEAPS           # DMA Heap 子系统
CONFIG_DMABUF_HEAPS_SYSTEM    # System Heap
CONFIG_DMABUF_HEAPS_CMA       # CMA Heap
```

---

## 五、同步机制总结

dma-buf 有两套同步机制，可以混合使用：

| 机制 | 接口 | 适用场景 | 特点 |
|------|------|---------|------|
| **隐式同步** | `poll()` + dma_resv fences | OpenGL, 传统媒体驱动 | 内核自动管理 fence 依赖，导入者框架层自动等待 |
| **显式同步** | `EXPORT/IMPORT_SYNC_FILE` + sync_file | Vulkan, 现代 GPU API | 用户态显式控制 fence 流转，更灵活可控 |

核心是 `dma_resv` 对象，它管理着一组 `dma_fence`：

- **共享 fence（DMA_RESV_USAGE_READ）**：表示读操作，允许多个读操作并发
- **排他 fence（DMA_RESV_USAGE_WRITE）**：表示写操作，与所有其他操作互斥
- **KERNEL fence（DMA_RESV_USAGE_KERNEL）**：内核内部使用

所有同步最终都通过 dma_resv 中的 fence 来协调访问顺序。

### 同步数据流示意

```
用户态:
   Vulkan App
      │
      ├── EXPORT_SYNC_FILE → sync_fd (snapshot 写 fence)
      │
      ├── vkQueueSubmit(wait=sync_fd, signal=done_fd)
      │                        (GPU 等待读权限, 完成后发信号)
      │
      └── IMPORT_SYNC_FILE(done_fd, WRITE)
                                  (将 GPU 完成信号注入 dma-buf)
内核态:
   dma_resv:
      │  .fences[WRITE] = fence_A (来自上次 IMPORT)
      │  .fences[READ]  = fence_B, fence_C
      │
      ├── poll(EPOLLIN):  wait on fences[WRITE] → 等待所有写者完成
      ├── poll(EPOLLOUT): wait on all fences    → 等待所有访问完成
      │
      └── dma_buf_map_attachment():
              static importer: dma_resv_wait_timeout(KERNEL)
              dynamic importer: manual wait on exclusive fences
```

---

## 六、关键设计要点

1. **文件描述符传递**：dma-buf 通过 fd 在进程间传递，利用了 Unix 域的 fd 传递能力（`SCM_RIGHTS`），Android Binder 也支持 fd 传递
2. **引用计数**：`dma_buf` 的生命周期由 `file->f_ref` 管理，`dma_buf_get()` 增加引用，`dma_buf_put()` 减少引用。当最后一个引用释放时触发 `ops->release()`
3. **伪文件系统**：所有 dma-buf 文件都在名为 `dmabuf` 的伪文件系统下，dentry 路径格式为 `dmabuf:<name>`
4. **resv 嵌入优化**：如果导出者未提供外部 resv，框架将 dma_resv 嵌入 dma_buf 的同一次分配中，减少碎片
5. **模块引用保护**：通过 `module_get/put` 确保导出者模块在使用期间不会被卸载
6. **动态 vs 静态**：框架同时支持简单的静态模型（pin on map）和灵活的动态模型（move_notify），兼容不同复杂度的驱动
7. **安全防护**：`CONFIG_DMABUF_DEBUG` 下的 sg_table 包装防止导入者绕过 API 直接访问 `struct page`

---

## 七、完整文件索引

### 核心实现 (`drivers/dma-buf/`)

| 文件 | 说明 |
|------|------|
| `dma-buf.c` | 核心框架：导出/导入/映射/同步 |
| `dma-buf-mapping.c` | MMIO 映射辅助（phys_vec → sg_table） |
| `dma-heap.c` | DMA Heap 注册框架 |
| `dma-fence.c` | DMA fence 基础实现 |
| `dma-fence-array.c` | fence 数组容器 |
| `dma-fence-chain.c` | fence 链式时间线 |
| `dma-fence-unwrap.c` | fence 容器展开 |
| `dma-resv.c` | reservation object（fence 容器） |
| `sync_file.c` | sync_file（用户态 fence fd） |
| `sw_sync.c` | 软件同步（调试用，标记为危险） |
| `udmabuf.c` | 用户态 memfd → dma-buf |
| `heaps/system_heap.c` | System heap（buddy 分配器） |
| `heaps/cma_heap.c` | CMA heap（物理连续内存） |

### 头文件 (`include/linux/` 和 `include/uapi/linux/`)

| 文件 | 说明 |
|------|------|
| `include/linux/dma-buf.h` | 核心内核 API |
| `include/linux/dma-fence.h` | fence 内核 API |
| `include/linux/dma-resv.h` | resv 内核 API |
| `include/linux/dma-heap.h` | heap 内核 API |
| `include/linux/sync_file.h` | sync_file 内核 API |
| `include/uapi/linux/dma-buf.h` | 用户态 ABI (ioctl) |
| `include/uapi/linux/dma-heap.h` | heap 用户态 ABI |
| `include/uapi/linux/udmabuf.h` | udmabuf 用户态 ABI |
| `include/uapi/linux/sync_file.h` | sync_file 用户态 ABI |

### 文档

| 文件 | 说明 |
|------|------|
| `Documentation/driver-api/dma-buf.rst` | 驱动 API 完整文档 |
| `Documentation/userspace-api/dma-buf-heaps.rst` | Heap 用户态文档 |
| `Documentation/userspace-api/dma-buf-alloc-exchange.rst` | 缓冲区交换设计指南 |

### 各子系统集成文件

| 文件 | 子系统 |
|------|--------|
| `drivers/gpu/drm/i915/gem/i915_gem_dmabuf.c` | i915 DRM dmabuf |
| `drivers/gpu/drm/i915/gvt/dmabuf.c` | i915 GVT 虚拟化 |
| `drivers/gpu/drm/omapdrm/omap_gem_dmabuf.c` | OMAP DRM |
| `drivers/infiniband/core/umem_dmabuf.c` | RDMA/InfiniBand |
| `drivers/vfio/pci/vfio_pci_dmabuf.c` | VFIO PCI |
| `drivers/xen/gntdev-dmabuf.c` | Xen grant table |
| `drivers/media/platform/nvidia/tegra-vde/dmabuf-cache.c` | Tegra VDE |
| `kernel/bpf/dmabuf_iter.c` | BPF dma-buf 迭代器 |
