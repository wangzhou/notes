# kvmtool virtio-blk 深度分析

基于 kvmtool 代码库 `/home/wz/kvmtool`，Linux 内核 KVM 代码 `/home/wz/linux`，分析 virtio-blk 的完整实现。

---

## 1. 组件角色与代码库边界

```
┌─────────────────────────────────────────────────────────────────┐
│                     Guest VM                                     │
│  virtio-blk 驱动 (不在本代码库, drivers/block/virtio_blk.c)      │
│  - 构造 descriptor chain, 填充 avail ring                       │
│  - 写 PCI doorbell / MMIO notify                                │
│  - 收中断, 从 used ring 取结果                                   │
└────────────────────────────┬────────────────────────────────────┘
                             │ VM Exit (Stage-2 Fault)
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│             Host KVM 内核 (不在本代码库, /home/wz/linux)         │
│  - ioeventfd: 拦截 Guest MMIO 写 → 直接 signal eventfd           │
│  - vGIC: 注入虚拟中断到 Guest, 硬件辅助加速                       │
└────────────────────────────┬────────────────────────────────────┘
                             │ eventfd 信号 / ioctl
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              kvmtool VMM (本代码库, /home/wz/kvmtool)            │
│                                                                  │
│  传输层: virtio/pci.c (PCI), virtio/mmio.c (MMIO)                │
│    - 注册 PCI BAR, MSI-X, ioeventfd                              │
│    - 中断注入: signal_vq → KVM_IRQ_LINE                          │
│                                                                  │
│  设备层: virtio/blk.c                                            │
│    - 独立 I/O 线程, 解析 descriptor chain                        │
│    - 分派到磁盘层, 写 used ring, 发完成中断                       │
│                                                                  │
│  磁盘层: disk/core.c, disk/aio.c, disk/raw.c                    │
│    - AIO 异步 I/O, 支持 raw/qcow/块设备                          │
└─────────────────────────────────────────────────────────────────┘
```

**文件索引：**

| 文件 | 内容 |
|------|------|
| `virtio/blk.c` | blk 设备主实现 (384 行) |
| `virtio/core.c` | virtio 核心：队列操作、设备初始化 |
| `virtio/pci.c` | PCI 传输层：BAR、MSI-X、ioeventfd、中断 |
| `virtio/mmio.c` | MMIO 传输层 |
| `include/linux/virtio_blk.h` | virtio-blk 协议定义 (Linux UAPI) |
| `include/kvm/virtio.h` | virt_queue, virtio_device, virtio_ops |
| `ioeventfd.c` | ioeventfd 封装：epoll + KVM_IOEVENTFD ioctl |
| `disk/core.c` | 磁盘镜像生命周期和 I/O 分发 |
| `disk/aio.c` | Linux AIO 异步 I/O |
| `disk/raw.c` | raw 格式 I/O |

**内核文件索引：**

| 文件 | 内容 |
|------|------|
| `arch/arm64/kvm/handle_exit.c` | VM Exit 总入口，异常分发 |
| `arch/arm64/kvm/mmu.c` | Stage-2 页表，kvm_handle_guest_abort |
| `arch/arm64/kvm/mmio.c` | MMIO 解码 + kvm_io_bus 分发 |
| `virt/kvm/kvm_main.c` | kvm_io_bus 设备总线和匹配 |
| `virt/kvm/eventfd.c` | ioeventfd 设备注册和回调 |
| `arch/arm64/kvm/vgic/vgic.c` | vGIC 中断注入 |

---

## 2. 设备初始化全流程

### 2.1 编译期：注册初始化回调

```c
// util-init.h: 优先级机制
core_init(cb)          // 优先级 0
base_init(cb)          // 优先级 2
dev_base_init(cb)      // 优先级 4
dev_init(cb)           // 优先级 5
virtio_dev_init(cb)    // 优先级 6
firmware_init(cb)      // 优先级 7
late_init(cb)          // 优先级 9
```

GCC `__attribute__((constructor))` 在 main() 前自动注册：

```
优先级 2: ioeventfd__init   → epoll 框架
优先级 4: disk_image__init  → 打开磁盘镜像文件
优先级 5: pci__init         → PCI 总线
优先级 6: virtio_blk__init  → 创建 blk 设备
```

### 2.2 命令行解析 → 磁盘初始化

```
$ lkvm run -k bzImage -d rootfs.img

kvm_cmd_run_init()
  ├→ disk_img_name_parser()
  │    kvm->cfg.disk_image[0].filename = "rootfs.img"
  │    kvm->nr_disks = 1
  ├→ kvm__init()
  │    创建 vm_fd, 分配 Guest RAM, mmap
  └→ init_list__init(kvm)  ← 按优先级调用所有 init
```

### 2.3 disk_image__init (优先级 4)

```c
// disk/core.c:145
disk_image__open_all(kvm)
  for i in 0..nr_disks:
    disk_image__open("rootfs.img")
      尝试顺序探测:
        ① blkdev__probe()  → S_ISBLK? 块设备? (async=true)
        ② qcow_probe()     → QCOW 格式 (强转只读)
        ③ raw_image__probe() → raw 镜像
            只读: mmap(PRIVATE)
            读写: preadv/pwritev + AIO

      disk_image__new(fd, size, ops)
        └→ disk_aio_setup(disk)
              if ops->async:
                ├─ eventfd(0,0) → disk->evt
                ├─ io_setup(AIO_MAX) → disk->ctx
                └─ pthread_create → disk_aio_thread
                    阻塞在 read(disk->evt), 等待 AIO 完成
```

### 2.4 virtio_blk__init (优先级 6)

```c
// blk.c:354
virtio_blk__init(kvm)
  for each disk:
    virtio_blk__init_one(kvm, disk)  // blk.c:311
      ├─ 分配 blk_dev, 初始化 capacity = disk->size / SECTOR_SIZE
      ├─ list_add → 全局链表 bdevs
      │
      ├─ virtio_init()  // core.c:356 ★★★
      │    ├─ 分配 struct virtio_pci (或 virtio_mmio)
      │    │
      │    ├─ ★ 填充 vdev->ops: ★
      │    │   设备层提供 (blk_dev_virtio_ops):
      │    │     .get_config        → 返回 &blk_config
      │    │     .get_host_features → SEG_MAX|FLUSH|EVENT_IDX|INDIRECT_DESC|ANY_LAYOUT
      │    │     .init_vq           → 映射 vring, 创建 I/O 线程
      │    │     .notify_vq         → write(io_efd) 唤醒 I/O 线程
      │    │     .notify_status     → 填充 capacity/seg_max
      │    │     .get_vq            → &bdev->vqs[n]
      │    │
      │    │   传输层覆盖 (PCI 或 MMIO):
      │    │     .signal_vq      = virtio_pci__signal_vq
      │    │     .signal_config  = virtio_pci__signal_config
      │    │     .init           = virtio_pci__init
      │    │     .exit/reset     = virtio_pci__exit/reset
      │    │
      │    └─ virtio_pci__init()  // pci.c:339
      │         ├─ 分配 PIO/MMIO/MSI-X BAR 空间
      │         ├─ 构造 PCI config space:
      │         │    vendor=0x1af4, device=VIRTIO_BLK(0x1001)
      │         │    class=BLK(0x018000), subsys_id=2
      │         ├─ 注册 BAR MMIO/PIO 回调
      │         ├─ 配置 MSI-X (vq_vector/GIS 初始化)
      │         ├─ pci__assign_irq() → INTx 中断线
      │         └─ device__register() → Guest 可见
      │
      └─ disk_image__set_callback(bdev->disk, virtio_blk_complete)
```

### 2.5 Guest 启动后的协商 → init_vq

```
Guest 扫描 PCI → 发现 virtio-blk → 加载驱动

1. Guest 读 features → 返回 SEG_MAX|FLUSH|EVENT_IDX|...
2. Guest 写 features → virtio_set_guest_features()
3. Guest 写 status=DRIVER_OK → notify_status()
     填充: blk_config.capacity = bdev->capacity
          blk_config.seg_max   = DISK_SEG_MAX (254)
```

Guest 设置 vring 地址后触发 `init_vq()`:

```c
// blk.c:215
init_vq(kvm, bdev, vq=0)
  ├─ virtio_init_device_vq(kvm, vdev, &bdev->vqs[0], 256)
  │    // core.c:193
  │    根据 legacy/modern 解析 vring 地址:
  │      legacy: base = pfn * pagesize
  │      modern: desc/avail/used 各自由 desc_lo/hi 等指定
  │    ★ GPA→HVA: guest_flat_to_host(kvm, gpa)
  │      vq->vring.desc/avail/used 指向 Guest 内存的 HVA
  │
  ├─ for i in 0..255: 初始化 reqs[i] (按 head 索引的请求槽)
  ├─ bdev->io_efd = eventfd(0,0)
  └─ pthread_create → virtio_blk_thread
       阻塞在 read(io_efd)
```

传输层同步初始化 ioeventfd:

```c
// pci.c:119
virtio_pci_init_vq()
  ├─ virtio_pci__init_ioeventfd()
  │    创建 pio_fd, mmio_fd
  │    ioctl(KVM_IOEVENTFD, addr=doorbell, fd=pio_fd/mmio_fd, datamatch=0)
  │     ★ 告诉 KVM: Guest 写 doorbell 时直接 signal eventfd
  │    epoll_ctl(ADD, pio_fd/mmio_fd) → epoll 线程开始监听
  │
  └─ vdev->ops->init_vq()  (上面已执行)
```

---

## 3. I/O 处理：Guest kick → Host 处理 → Guest 完成

### 3.1 请求格式

Guest 提交的 descriptor chain 布局：

```
[descriptor0: OUT] virtio_blk_outhdr { type, ioprio, sector }  (12 bytes)
[descriptor1: IN/WRITE] 数据缓冲区
[descriptor2: IN/WRITE] 更多数据缓冲区 (散列)
...
[descriptorN: IN]  1字节 status (VIRTIO_BLK_S_OK / VIRTIO_BLK_S_IOERR)
```

请求类型：
- `VIRTIO_BLK_T_IN (0)` → disk_image__read → AIO/同步 → 回调
- `VIRTIO_BLK_T_OUT (1)` → disk_image__write → AIO/同步 → 回调
- `VIRTIO_BLK_T_FLUSH (4)` → disk_image__flush → 直接 complete
- `VIRTIO_BLK_T_GET_ID (8)` → disk_image__get_serial → 直接 complete

### 3.2 请求逆序列化

```c
// blk.c:82
virtio_blk_do_io_request()
  ├─ memcpy_fromiovec_safe(&req_hdr, iov, sizeof(outhdr), &iovcount)
  │    ★ 从 Guest 内存读 12 字节请求头
  │
  ├─ type   = virtio_guest_to_host_u32(endian, req_hdr.type)
  │   sector = virtio_guest_to_host_u64(endian, req_hdr.sector)
  │    ★ 端序转换 (同构 CPU 为 no-op)
  │
  ├─ // ★ 提取 status 字节: 从最后一个 writable iovec 尾部取 1 字节
  │   last_iov = iovcount - 1
  │   while (!iov[last_iov].iov_len) last_iov--
  │   iov[last_iov].iov_len--
  │   req->status = iov[last_iov].iov_base + iov[last_iov].iov_len
  │
  └─ switch (type) 分派到磁盘层
```

### 3.3 I/O 完成回调

```c
// blk.c:63
virtio_blk_complete(param=blk_dev_req, len)
  ├─ *req->status = (len < 0) ? VIRTIO_BLK_S_IOERR : VIRTIO_BLK_S_OK
  │   ★ 写 status 字节到 Guest 内存 (HVA)
  │
  ├─ mutex_lock(&bdev->mutex)
  ├─ virt_queue__set_used_elem(vq, head, len)
  │    ★ 写 used ring:
  │      used->ring[idx].id  = head
  │      used->ring[idx].len = len
  │      used->idx++ (wmb 保证顺序)
  ├─ mutex_unlock(&bdev->mutex)
  │
  └─ virtio_queue__should_signal(vq)
       检查 EVENT_IDX 或 NO_INTERRUPT 标志
       需要时 → ops->signal_vq → 注入中断
```

---

## 4. Guest 写 doorbell → KVM ioeventfd (arm64 内核路径)

### 4.1 概要

```
Guest:  writel(vq, doorbell_mmio)
  │
  ▼ Stage-2 page fault → EL2 trap (doorbell IPA 不在 memslot 中)
  │
KVM:  handle_exit → handle_trap_exceptions → kvm_handle_guest_abort
      → io_mem_abort → kvm_io_bus_write → ioeventfd_write
      → eventfd_signal(pio_fd) → ERET 回 Guest
  │
  ★ 全程无用户态退出, 仅一次 EL2 trap
  │
  ▼ (异步) kvmtool epoll 线程:
      virtio_pci__ioevent_callback → notify_vq
      → write(io_efd) → 唤醒 virtio_blk_thread
```

### 4.2 内核代码路径详解

#### 第1步：Guest Stage-2 Fault → EL2

Guest 写 PCI MMIO doorbell。该 IPA 在 PCI MMIO 空间，不在 memslot 中，Stage-2 页表无映射。触发 Data Abort，ESR_EL2 记录异常信息 (EC=0x24 DABT)，FAR_EL2 记录故障 IPA。CPU 进入 EL2。

#### 第2步：handle_exit → kvm_handle_guest_abort

```c
// arch/arm64/kvm/handle_exit.c:446
handle_exit(vcpu, exception_index=ARM_EXCEPTION_TRAP)
  └→ handle_trap_exceptions(vcpu)                 // line 421
       └→ kvm_get_exit_handler(vcpu)              // line 407
            esr_ec = ESR_ELx_EC_DABT_LOW (0x24)
            return arm_exit_handlers[esr_ec]
            = kvm_handle_guest_abort              // → mmu.c
```

#### 第3步：kvm_handle_guest_abort — 判断是否为 MMIO

```c
// arch/arm64/kvm/mmu.c:2067
kvm_handle_guest_abort(vcpu)
  ├→ ipa = kvm_vcpu_get_fault_ipa(vcpu)     // 从 FAR_EL2 读取
  ├→ gfn = ipa >> PAGE_SHIFT
  │
  ├→ memslot = gfn_to_memslot(kvm, gfn)     // ★ doorbell IPA 不在任何 memslot 中
  │   → memslot = NULL
  │
  ├→ hva = gfn_to_hva_memslot_prot(memslot, gfn, &writable)
  │   → hva = KVM_HVA_ERR                   // ← 标记为非 RAM
  │
  └→ if (kvm_is_error_hva(hva))
        ret = io_mem_abort(vcpu, ipa)        // ← 进入 MMIO 路径
```

**memslot 是分水岭：** IPA 在 memslot 中 → RAM (分配页建立映射)，不在 → MMIO (走 io bus 分发)。

#### 第4步：io_mem_abort — 解码写操作，分发到 io bus

```c
// arch/arm64/kvm/mmio.c:153
io_mem_abort(vcpu, fault_ipa)
  ├─ // 从 ESR_EL2 解码:
  │   is_write = kvm_vcpu_dabt_iswrite(vcpu)   // = true (store)
  │   len      = kvm_vcpu_dabt_get_as(vcpu)     // = 2 (u16)
  │   rt       = kvm_vcpu_dabt_get_rd(vcpu)     // 源寄存器
  │
  ├─ data = vcpu_get_reg(vcpu, rt)
  │   kvm_mmio_write_buf(data_buf, len, data)
  │
  ├─ ret = kvm_io_bus_write(vcpu, KVM_MMIO_BUS,
  │                          fault_ipa, len, data_buf)
  │
  ├─ if (!ret) {  // ★ 内核处理成功
  │     kvm_handle_mmio_return(vcpu)    // 递增 PC, 跳过已执行指令
  │     return 1;  // → 返回 Guest, 无用户态退出
  │   }
  │
  └─ // ret = -EOPNOTSUPP: 无人处理 → 退出到用户态
      run->exit_reason = KVM_EXIT_MMIO
      return 0;
```

#### 第5步：kvm_io_bus_write — 遍历 MMIO 设备总线

```c
// virt/kvm/kvm_main.c:5849
__kvm_io_bus_write(vcpu, bus, range, val)
  ├─ idx = kvm_io_bus_get_first_dev(bus, addr, len)  // 二分查找
  └─ while (地址范围匹配)
        if (!kvm_iodevice_write(vcpu, dev, addr, len, val))
          return idx;   // ★ 设备返回 0 → 已处理
```

bus 上的设备包括：普通 MMIO handler (返回 -EOPNOTSUPP，回退用户态)，以及 **ioeventfd 设备** (直接 signal eventfd)。

#### 第6步：ioeventfd_write — 匹配并 signal eventfd

```c
// virt/kvm/eventfd.c:807
ioeventfd_write(vcpu, this, addr, len, val)
  ├─ ioeventfd_in_range(p, addr, len, val)
  │    ├─ addr != p->addr          → false  // 地址精确匹配
  │    ├─ len != p->length         → false  // 长度精确匹配
  │    ├─ p->wildcard              → true   // 通配符
  │    └─ *(u16*)val == p->datamatch → true // 数据匹配 (vq=0)
  │
  └─ eventfd_signal(p->eventfd)              // ★
       return 0;   // 返回 0 → KVM 知道已在内核处理完毕
```

### 4.3 两级 eventfd 的解耦设计

```
KVM ioeventfd (pio_fd / mmio_fd)         blk io_efd (bdev->io_efd)
         │                                        │
         │  传输层 (PCI/MMIO)                       │  设备层
         │  通用回调                                │  设备特定处理
         │                                        │
         └── virtio_pci__ioevent_callback ──→ notify_vq() ──→ write(io_efd)
              (pci.c:50)                    (blk.c:260)
```

- PCI 层的 ioeventfd 回调对所有 virtio 设备通用
- 不同设备的 `notify_vq` 实现不同：
  - **blk**: write(io_efd) 唤醒独立 I/O 线程
  - **rng**: thread_pool__do_job() 提交到共享线程池
  - **net**: 直接处理或走 vhost

---

## 5. 中断注入：KVM vGIC 硬件辅助

### 5.1 完整路径

```
virtio_blk_complete()
  └→ virtio_queue__should_signal(vq)
       └→ vdev->ops->signal_vq(kvm, vdev, vq)
            │
            ├── [PCI MSI-X]  virtio_pci__signal_vq()  // pci.c:227
            │     └→ kvm__irq_trigger(kvm, gsis[vq])
            │          // KVM_SIGNAL_MSI (x86/arm64) 或 KVM_IRQ_LINE
            │
            ├── [PCI INTx]   kvm__irq_line(kvm, legacy_irq_line, HIGH)
            │                // pci.c:246
            │
            └── [MMIO]       virtio_mmio_signal_vq()  // mmio.c:70
                  └→ kvm__irq_trigger(kvm, vmmio->irq)
```

### 5.2 KVM 内核侧：KVM_IRQ_LINE → vGIC

```c
// arm/gic.c:417
kvm__irq_line(kvm, irq, level)
  irq_level = {
    .irq   = KVM_ARM_IRQ_TYPE_SPI | (irq & KVM_ARM_IRQ_NUM_MASK),
    .level = !!level,
  }
  ioctl(vm_fd, KVM_IRQ_LINE, &irq_level)
```

KVM 内核处理：

```c
// arch/arm64/kvm/arm.c:1486
kvm_vm_ioctl_irq_line()           // KVM_IRQ_LINE → arm64 dispatch
  case KVM_ARM_IRQ_TYPE_SPI:
    kvm_vgic_inject_irq(kvm, NULL, irq_num, level, NULL)
```

```c
// arch/arm64/kvm/vgic/vgic.c:513
kvm_vgic_inject_irq(kvm, vcpu, intid, level, owner)
  ├─ irq = vgic_get_irq(kvm, intid)              // 获取 vGIC IRQ 对象
  ├─ // 设置 pending 状态:
  │   if (config == LEVEL):
  │     irq->line_level = level                    // 电平触发
  │   else:
  │     irq->pending_latch = true                  // 边沿触发
  │
  └─ vgic_queue_irq_unlock(kvm, irq, flags)
       ├─ vcpu = vgic_target_oracle(irq)           // 查路由目标 vCPU
       ├─ list_add_tail(&irq->ap_list,
       │        &vcpu->arch.vgic_cpu.ap_list_head)  // 挂入 pending 队列
       ├─ kvm_make_request(KVM_REQ_IRQ_PENDING, vcpu)
       └─ kvm_vcpu_kick(vcpu)                      // 唤醒 vCPU
```

### 5.3 Guest 接收中断

vCPU 下次 VM Entry：

```
kvm_arch_vcpu_ioctl_run()
  └→ kvm_vgic_flush_hwstate(vcpu)
       ├─ 检查 ap_list 有 pending 中断
       ├─ 写 GIC List Register (GICv3) 或 GICH_LR (GICv2)
       │   ★ 将虚拟中断写入硬件 GIC
       └─ 设置 HCR_EL2 使能虚拟中断

ERET → Guest
  → GIC 硬件注入虚拟中断到 vCPU
  → Guest IRQ handler → virtio-blk ISR
    → 读 ISR 状态 → 扫描 used ring → 处理完成
```

**结论：不是纯软件模拟。** KVM 在用户态只发一个 `KVM_IRQ_LINE` ioctl，vGIC 操作全部在内核完成，GIC 硬件辅助虚拟中断注入。

### 5.4 ioeventfd vs KVM_IRQ_LINE：两个方向的非对称性

```
Guest→Host (kick):               Host→Guest (中断):
  ioeventfd                         KVM_IRQ_LINE
  ─────────                         ────────────
  内核路径:                         内核路径:
  KVM ioeventfd 匹配                KVM vGIC 注入
  → eventfd_signal()                → ap_list → GIC LR → 硬件注入
  → 无用户态退出                     → 由 kvmtool 用户态 ioctl 触发
  → 异步并行                          → 可硬件加速 (GICv3 LR)
```

---

## 6. 性能分析

### 6.1 kvmtool virtio-blk 关键参数

| 参数 | 代码位置 | 含义 |
|------|----------|------|
| VIRTIO_BLK_QUEUE_SIZE = 256 | `blk.c:29` | 队列深度 256 |
| NUM_VIRT_QUEUES = 1 | `blk.c:30` | 单队列 (不支持 MQ) |
| DISK_SEG_MAX = 254 | `blk.c:28` | 每请求最多 254 散列段 |
| I/O 线程阻塞在 eventfd | `blk.c:205` | 唤醒需要一次 eventfd 写 |
| AIO 独立线程 | `aio.c:102` | io_getevents 阻塞, 独立线程 |

### 6.2 延迟分析

```
一次 virtio-blk I/O 的软件开销:

Guest kick:
  Stage-2 Fault → EL2 → kvm_handle_guest_abort
  → io_mem_abort → kvm_io_bus_write → ioeventfd_write
  → eventfd_signal → ERET
  延迟: ~1-2μs

Host 处理:
  epoll 线程: read(pio_fd) → virtio_pci__ioevent_callback
  → write(io_efd) → blk I/O 线程: read(io_efd)
  → 解析 descriptor chain → 端序转换
  → AIO: io_prep_preadv + io_submit
  延迟: ~3-5μs

AIO 完成:
  disk_aio_thread: read(disk->evt) → io_getevents
  → disk_req_cb → virtio_blk_complete
  → 写 used ring + status
  延迟: ~2-3μs

中断注入:
  signal_vq → KVM_IRQ_LINE → vGIC → 硬件注入
  延迟: ~1-2μs

总软件开销 (不含磁盘): ~7-12μs per I/O
```

### 6.3 吞吐估算

```
随机 4K 读 (单队列, IOPS 瓶颈在软件开销):
  IOPS = 1 / (软件 + 后端)
       = 1 / (~10μs + ~80μs NVMe)
       ≈ 11K IOPS
  带宽 ≈ 45 MB/s  ← 单队列瓶颈

大块顺序读 (128KB, 带宽瓶颈在后端):
  IOPS ≈ 1 / (~15μs + ~200μs) ≈ 4.6K
  带宽 ≈ 600 MB/s
```

### 6.4 kvmtool virtio-blk 的三个致命瓶颈

1. **单队列** — 所有 vCPU 的 I/O 都塞进一个 vq，单线程串行处理
2. **两次 eventfd 跳转** — ioeventfd → epoll → write(io_efd) → I/O 线程，无谓唤醒
3. **用户态 AIO syscall** — io_submit/io_getevents 每次都要进内核

### 6.5 完整性能对比

| | virtio-blk (kvmtool) | virtio-blk (QEMU+MQ) | vhost-kernel-blk | vhost-user-blk (SPDK) | NVMe 直通 | NVMe 物理机 |
|---|---|---|---|---|---|---|
| 队列数 | 1 | 1-16 | 1-16 | 1-16 | 硬件队列 | 硬件队列 |
| 队列深度 | 256 | 256-1024 | 256-1024 | 256-1024 | 1024-4096 | 1024-4096 |
| kick 延迟 | ~2μs | ~2μs | ~0.3μs | ~1μs | ~5μs | 0 |
| 中断延迟 | ~2μs | ~2μs | ~0.5μs | ~0.5μs (irqfd) | ~1μs | 0 |
| 数据拷贝 | 有 | 有 | 有 | 无 (共享内存) | 无 (IOMMU) | 无 |
| I/O 路径 | 用户态 | 用户态 | 内核 | 用户态轮询 | 硬件 | 硬件 |
| 4K 随机读 IOPS | ~11K | ~100K | ~500K | ~1M | ~400K | ~800K |
| 顺序读带宽 | ~600 MB/s | ~2 GB/s | ~5 GB/s | ~6 GB/s | ~6 GB/s | ~7 GB/s |
| 热迁移 | ❌ (kvmtool 不支持) | ✅ | ❌ | ✅ | ❌ | ❌ |
| CPU 开销 | 低 | 中 | 低 | 高 (轮询) | 零 | 零 |

**vhost-user-blk 几个关键点：**

- **IOPS 超过物理机** — SPDK 轮询模式：从 vring 直接取请求→提交 NVMe 队列→轮询 CQ→写 used ring。全程无中断、无 syscall、无上下文切换。物理机 NVMe 中断路径反而有开销。
- **高性能+热迁移** — vhost-user 把设备状态从内核 (vhost-kernel) 挪回用户态 (SPDK)。迁移时暂停 SPDK→排空 I/O→序列化 vring→传输→目的端拉起。状态全在用户态可控。
- **代价是 CPU** — 轮询占满一个 CPU core，即使无 I/O 也在空转。

---

## 7. 热迁移支持

### 7.1 各方案对比

| 方案 | 热迁移 | 原因 |
|------|--------|------|
| virtio-blk (QEMU) | ✅ | 设备状态全在 QEMU 用户态，可序列化传输 |
| virtio-blk (kvmtool) | ❌ | kvmtool 未实现热迁移 |
| vhost-user-blk (SPDK) | ✅ | 后端在用户态，可独立迁移 |
| vhost-kernel-blk | ❌ | 设备状态在内核，在飞的 bio 无法撤销 |
| NVMe 直通 | ❌ | 硬件状态 (FTL/队列/在飞操作) 无法导出 |

### 7.2 virtio 迁移原理

纯软件 virtio 设备状态完全在用户态：

```
迁移源端                            迁移目的端
════════                            ════════

① 设备配置空间
   blk_config { capacity, seg_max }  ──→  恢复 config space

② virtqueue 状态
   vring.desc/avail/used 地址映射    ──→  重新映射 GPA→HVA
   last_avail_idx                   ──→  恢复消费位置
   used->idx                        ──→  Guest 继续从正确位置取结果

③ 设备特性协商结果
   vdev->features                   ──→  恢复特性位
   vdev->status                     ──→  恢复设备状态机

④ 后端磁盘 (共享存储)
   同一文件路径打开即可
```

### 7.3 vhost-kernel 为何难迁移

设备状态分散在用户态 (QEMU) 和内核态 (vhost 线程)。内核中的在飞 bio 无法从块设备层撤回，vring 处理上下文需要内核配合保存/恢复。

### 7.4 VFIO 为何不支持

NVMe 控制器内部状态 (队列指针、FTL映射表、在飞 NAND 操作) 在硬件中，没有标准接口导出。除非有厂商私有的 migration-capable NVMe 设备。

---

## 8. 数据结构速查

```c
// blk.c:41 — blk 设备状态
struct blk_dev {
    struct virtio_device    vdev;           // 通用 virtio 设备抽象
    struct virtio_blk_config blk_config;    // Guest 可见的配置空间
    u64                     capacity;       // 扇区数 (512B/扇区)
    struct disk_image       *disk;          // 后端磁盘镜像
    struct virt_queue       vqs[1];         // 只有 1 个 virtqueue
    struct blk_dev_req      reqs[256];      // 预分配请求槽, 按 head 索引
    pthread_t               io_thread;      // 独立 I/O 线程
    int                     io_efd;         // eventfd 用于唤醒 I/O 线程
};

// blk.c:32 — 单个请求上下文
struct blk_dev_req {
    struct virt_queue   *vq;                // 所属 virtqueue
    struct blk_dev      *bdev;              // 所属设备
    struct iovec        iov[256];           // 展平后的 descriptor chain
    u16                 out, in, head;      // out/in 段计数, head 索引
    u8                  *status;            // Guest 内存中 status 字节的位置
};

// include/kvm/virtio.h:70 — virtqueue 状态
struct virt_queue {
    struct vring       vring;               // desc, avail, used 三元组
    struct vring_addr  vring_addr;          // Guest 给的 GPA
    u16                last_avail_idx;      // 下一次消费的位置
    bool               use_event_idx;       // VIRTIO_RING_F_EVENT_IDX
    bool               enabled;
};

// include/kvm/virtio.h:219 — 通用 virtio 设备
struct virtio_device {
    void            *virtio;               // 传输层状态 (virtio_pci / virtio_mmio)
    struct virtio_ops *ops;                // 设备+传输层函数表
    u16             endian;
    u64             features;               // 协商后的特性
    u32             status;
};
```

## 9. 代码片段参考

### 9.1 virtio_queue__should_signal — 中断抑制判断

```c
// core.c:246
bool virtio_queue__should_signal(struct virt_queue *vq)
{
    mb();  // 确保 used idx 已更新

    if (!vq->use_event_idx) {
        // 没有 EVENT_IDX: 看 NO_INTERRUPT 标志
        return !(vq->vring.avail->flags & VRING_AVAIL_F_NO_INTERRUPT);
    }

    // 有 EVENT_IDX: 用 vring_need_event 精确判断
    old_idx   = vq->last_used_signalled;
    new_idx   = vq->vring.used->idx;
    event_idx = vring_used_event(&vq->vring);

    if (vring_need_event(event_idx, new_idx, old_idx)) {
        vq->last_used_signalled = new_idx;
        return true;
    }
    return false;
}
```

### 9.2 io_mem_abort — 内核 MMIO 分发 (完整版)

```c
// arch/arm64/kvm/mmio.c:153
int io_mem_abort(struct kvm_vcpu *vcpu, phys_addr_t fault_ipa)
{
    struct kvm_run *run = vcpu->run;
    bool is_write = kvm_vcpu_dabt_iswrite(vcpu);
    int len = kvm_vcpu_dabt_get_as(vcpu);
    u8 data_buf[8];
    int ret;

    if (is_write) {
        unsigned long data = vcpu_data_guest_to_host(
            vcpu, vcpu_get_reg(vcpu, kvm_vcpu_dabt_get_rd(vcpu)), len);
        kvm_mmio_write_buf(data_buf, len, data);
        ret = kvm_io_bus_write(vcpu, KVM_MMIO_BUS, fault_ipa, len, data_buf);
    } else {
        ret = kvm_io_bus_read(vcpu, KVM_MMIO_BUS, fault_ipa, len, data_buf);
    }

    run->mmio.phys_addr = fault_ipa;  // 准备 kvm_run, 防止回退到用户态

    if (!ret) {
        // ★ 内核处理成功: 不退出到用户态
        if (!is_write)
            memcpy(run->mmio.data, data_buf, len);
        vcpu->stat.mmio_exit_kernel++;
        kvm_handle_mmio_return(vcpu);  // 递增 Guest PC
        return 1;   // → 返回 Guest
    }

    // 内核无人处理: 退出到用户态
    run->exit_reason = KVM_EXIT_MMIO;
    return 0;
}
```

### 9.3 kvm_assign_ioeventfd_idx — ioeventfd 注册到 io bus

```c
// virt/kvm/eventfd.c:863
static int kvm_assign_ioeventfd_idx(struct kvm *kvm,
                                    enum kvm_bus bus_idx,
                                    struct kvm_ioeventfd *args)
{
    struct eventfd_ctx *eventfd = eventfd_ctx_fdget(args->fd);
    struct _ioeventfd *p;

    p = kzalloc(sizeof(*p), GFP_KERNEL_ACCOUNT);
    p->addr    = args->addr;    // doorbell 的 IPA
    p->length  = args->len;     // 2 (u16)
    p->eventfd = eventfd;       // 要 signal 的 eventfd
    p->bus_idx = bus_idx;       // KVM_MMIO_BUS

    if (args->flags & KVM_IOEVENTFD_FLAG_DATAMATCH)
        p->datamatch = args->datamatch;  // vq=0
    else
        p->wildcard = true;              // 通配符

    kvm_iodevice_init(&p->dev, &ioeventfd_ops);
    // ioeventfd_ops = { .write = ioeventfd_write, .destructor = ioeventfd_destructor }

    kvm_io_bus_register_dev(kvm, bus_idx, p->addr, p->length, &p->dev);
    // ★ 将 ioeventfd 设备插入 kvm->buses[KVM_MMIO_BUS]
    bus->ioeventfd_count++;
    list_add_tail(&p->list, &kvm->ioeventfds);

    return 0;
}
```
