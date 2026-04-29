# QEMU 内存管理基本逻辑

## 核心概念分层

QEMU 的内存系统可以分成**三层**，理解这三层就抓住了主干：

### 第一层：建筑块 — MemoryRegion

**MemoryRegion** 是 QEMU 内存系统的基本单元。它不是"一段真实内存"，而是一个**抽象的描述**：描述一段地址范围是什么、怎么访问。

它有很多子类型：
- **RAM MemoryRegion** — 有实际的 host 端内存（RAMBlock）作为后背
- **MMIO MemoryRegion** — 读写时会回调 ops 里的 read/write 函数
- **ROM MemoryRegion** — 只读
- **Alias MemoryRegion** — 另一个 MemoryRegion 的"窗口"（类似符号链接）
- **Container MemoryRegion** — 纯粹用来装子 region 的容器，自身不占地址

MemoryRegion 是**树状结构**的。一个 Container 可以包含多个子 region，子 region 之间有优先级（priority），同优先级下后添加的覆盖先添加的。最终通过 `memory_region_add_subregion()` 等 API 组装成一棵树。

```c
// 定义在 include/system/memory.h:1051
struct MemoryRegion {
    Object parent_obj;
    bool romd_mode, ram, subpage, readonly, nonvolatile, rom_device, flush_coalesced_mmio, unmergeable;
    uint8_t dirty_log_mask;
    hwaddr addr, size;
    // ...
    MemoryRegion *alias;      // 如果是 alias，指向目标 region
    hwaddr alias_offset;
    // RAM 相关
    RAMBlock *ram_block;
    // MMIO 回调
    const MemoryRegionOps *ops;
    // 容器子节点
    QTAILQ_HEAD(, MemoryRegion) subregions;
    QTAILQ_ENTRY(MemoryRegion) subregions_link;
};
```

### 第二层：展平视图 — FlatView

一棵 MemoryRegion 树在给定时刻、给定 AddressSpace 下，经过**展平（flatten）**后，就得到一个 **FlatView**。

展平的过程就是：
1. 把树递归展开
2. 解析所有 alias（转化为直接引用）
3. 按照优先级和 overlap 规则，把重叠的 region 切成不相交的片段
4. 排序

结果是一个**有序的、互不重叠的 FlatRange 数组**——也就是 FlatView。

```c
// system/memory.c:222
struct FlatRange {
    MemoryRegion *mr;          // 指向原始 MemoryRegion
    hwaddr offset_in_region;   // 在 mr 内部的偏移
    AddrRange addr;            // 在地址空间中的起止地址
    uint8_t dirty_log_mask;    // dirty logging 状态
    bool readonly, nonvolatile, unmergeable;
};

// include/system/memory.h:1194
struct FlatView {
    unsigned ref;
    FlatRange *ranges;
    unsigned nr;
    MemoryRegion *root;
};
```

**FlatView 是 RCU 保护的**。读写者可以无锁访问（`address_space_map`、`address_space_rw` 等），写者（BQL 持有者）通过生成新的 FlatView 然后原子替换 `as->current_map` 来更新。

### 第三层：观察者 — MemoryListener

**MemoryListener** 做的事情很简单：当 FlatView 发生变化时，通知外部组件。

```c
// include/system/memory.h:889
struct MemoryListener {
    // --- 事务生命周期 ---
    void (*begin)(MemoryListener *listener);
    void (*commit)(MemoryListener *listener);

    // --- Region 变化回调 ---
    void (*region_add)(MemoryListener *listener, MemoryRegionSection *section);
    void (*region_del)(MemoryListener *listener, MemoryRegionSection *section);
    void (*region_nop)(MemoryListener *listener, MemoryRegionSection *section);

    // --- 每个 region 的 dirty logging 回调 ---
    void (*log_start)(MemoryListener *listener, MemoryRegionSection *section,
                      int old_val, int new_val);
    void (*log_stop)(MemoryListener *listener, MemoryRegionSection *section,
                     int old_val, int new_val);
    void (*log_sync)(MemoryListener *listener, MemoryRegionSection *section);
    void (*log_sync_global)(MemoryListener *listener, bool last_stage);
    void (*log_clear)(MemoryListener *listener, MemoryRegionSection *section);

    // --- 全局 dirty logging 回调 ---
    bool (*log_global_start)(MemoryListener *listener, Error **errp);
    void (*log_global_stop)(MemoryListener *listener);
    void (*log_global_after_sync)(MemoryListener *listener);

    // --- IO eventfd 回调 ---
    void (*eventfd_add)(MemoryListener *listener, MemoryRegionSection *section,
                        bool match_data, uint64_t data, EventNotifier *e);
    void (*eventfd_del)(MemoryListener *listener, MemoryRegionSection *section,
                        bool match_data, uint64_t data, EventNotifier *e);

    // --- Coalesced MMIO 回调 ---
    void (*coalesced_io_add)(MemoryListener *listener, MemoryRegionSection *section,
                             hwaddr addr, hwaddr len);
    void (*coalesced_io_del)(MemoryListener *listener, MemoryRegionSection *section,
                             hwaddr addr, hwaddr len);

    // --- 元数据 ---
    unsigned priority;   // 数字越小，add/start 越先被调用，del/stop 越后被调用
    const char *name;

    // --- 私有字段 ---
    AddressSpace *address_space;
    QTAILQ_ENTRY(MemoryListener) link;      // 全局 memory_listeners 链
    QTAILQ_ENTRY(MemoryListener) link_as;   // 每 AddressSpace 的 as->listeners 链
};
```

**它是观察者模式的实现**。MemoryListener 不参与 MemoryRegion 树的构建，也不参与 FlatView 的生成。它只是"订阅"了变化通知。

Priority 常量（`include/system/memory.h:879`）：
- `MEMORY_LISTENER_PRIORITY_MIN` = 0
- `MEMORY_LISTENER_PRIORITY_ACCEL` = 10
- `MEMORY_LISTENER_PRIORITY_DEV_BACKEND` = 10

Priority 越低，Forward 方向（add/start）越先被调用，Reverse 方向（del/stop）越后被调用。这保证了自然的层叠顺序。

---

## AddressSpace 的角色

**AddressSpace** 是把上面三层串起来的枢纽：

```c
// include/system/memory.h:1157
struct AddressSpace {
    struct rcu_head rcu;
    char *name;
    MemoryRegion *root;                         // 指向根 MemoryRegion（第一层）
    struct FlatView *current_map;               // 指向当前 FlatView（第二层）
    QTAILQ_HEAD(, MemoryListener) listeners;    // 监听器链表（第三层）
    int ioeventfd_nb;
    struct MemoryRegionIoeventfd *ioeventfds;
    QTAILQ_ENTRY(AddressSpace) address_spaces_link;
};
```

一个 QEMU VM 有两个主要的 AddressSpace：
- **`address_space_memory`** — 系统内存空间，root 是 `system_memory`
- **`address_space_io`** — I/O 端口空间，root 是 `system_io`

每个 vCPU 也有自己的 AddressSpace（`cpu->as`），使能了 SMM 后还有 SMM 专用的 AddressSpace。设备做 DMA 时也通过 AddressSpace 接口访问内存。

一句话概括：**AddressSpace = 一棵 MemoryRegion 树的 root + 一个展平后的 FlatView + 一组监听器**。

---

## 核心流程：拓扑变化如何传播

假设你调用了 `memory_region_add_subregion()` 向 `system_memory` 添加了一个新的 MMIO region：

```
1. memory_region_add_subregion()
   └─ memory_region_transaction_begin()
   └─ 把新 subregion 插入到父 region 的 subregions 链表
   └─ memory_region_transaction_commit()

2. memory_region_transaction_commit()   -- system/memory.c:1143
   │   (事务嵌套深度回到0，开始真正更新)
   │
   ├─ 遍历全局 memory_listeners 链表，调用每个 listener->begin()
   │   (MEMORY_LISTENER_CALL_GLOBAL(begin, Forward))
   │
   ├─ 对每个 AddressSpace:
   │   └─ address_space_set_flatview(as, new_view)
   │       └─ address_space_update_topology_pass()
   │           │  (两轮遍历新旧 FlatRange 数组，做 diff)
   │           │
   │           │  Pass 1 (adding=false):
   │           │    - range 只存在于旧 FlatView: 调用 listener->region_del()
   │           │    - range 属性有变化: 调用 listener->log_stop()
   │           │
   │           │  Pass 2 (adding=true):
   │           │    - range 只存在于新 FlatView: 调用 listener->region_add()
   │           │    - range 两边完全相同: 调用 listener->region_nop()
   │           │    - dirty log mask 有变化: 调用 listener->log_start()
   │           │
   │           └─ 原子更新 as->current_map = new_view  (RCU)
   │
   └─ 遍历全局 memory_listeners，调用每个 listener->commit()
      (MEMORY_LISTENER_CALL_GLOBAL(commit, Forward))
```

关键点：
- **begin/commit** 成对出现，一个事务可能包含多个 region 变化
- **Diff 算法**是类似 merge-sort 的两轮遍历，对旧的 FlatView 和新 FlatView 做对称差
- **第一轮删、第二轮加**，保证任何时刻地址空间都是合法的

### Diff 算法细节

`address_space_update_topology_pass()` （`system/memory.c:970`）对新旧两个 FlatRange 数组做 merge-like 遍历：

- **Range 在旧 FlatView 但不在新 FlatView**（或属性变了）：在"删除 pass"中调用 `region_del`
- **Range 在两边的完全相同**：在"添加 pass"中调用 `region_nop`，同时检查 dirty log mask 变化来调用 `log_start`/`log_stop`
- **Range 在新 FlatView 但不在旧 FlatView**：在"添加 pass"中调用 `region_add`

两个 pass 的遍历方向不同：删除 pass 用 Reverse（从高到低优先级），添加 pass 用 Forward（从低到高优先级），保证了正确的层叠顺序。

### 新 listener 注册时的 replay

当你调用 `memory_listener_register()` 时（`system/memory.c:3099`），QEMU 会立即**重放**当前 FlatView 的全部内容：

```
listener_add_address_space()           -- system/memory.c:2983
  ├─ listener->begin()
  ├─ 遍历当前 FlatView 的所有 FlatRange:
  │    ├─ listener->region_add()
  │    ├─ 如果有 dirty logging: listener->log_start()
  │    └─ 如果有 coalesced MMIO: listener->coalesced_io_add()
  ├─ 遍历所有已注册的 ioeventfd:
  │    └─ listener->eventfd_add()
  └─ listener->commit()
```

注销时同理（`listener_del_address_space()`, system/memory.c:3048），按相反顺序：

```
  ├─ listener->begin()
  ├─ 遍历所有 FlatRange（Reverse 顺序）:
  │    ├─ log_stop() / coalesced_io_del()
  │    └─ listener->region_del()
  ├─ 遍历所有 ioeventfd（Reverse 顺序）:
  │    └─ listener->eventfd_del()
  └─ listener->commit()
```

---

## Guest 物理内存的分配路径（ARM KVM）

上一节讲了 MemoryRegion 如何通过事务机制通知各个 AS 和 listener，但还没有回答一个更根本的问题：**guest 的 RAM 对应的 host 内存是从哪来的？** 这一节以 ARM KVM 为例，追踪从 `memory_region_init_ram()` 到 KVM 内核建立 stage-2 映射的完整链路。

### 第一段：创建 MemoryRegion

ARM virt 机器启动时，由 machine 层创建 `machine->ram`：

```
machine_run_board_init()                           [hw/core/machine.c:1592]
  │
  ├─ 有 -object memory-backend-* : machine_consume_memdev() 直接用已有 MR
  │
  └─ 无 (默认): create_default_memdev()                     [hw/core/machine.c:1005]
       └─ object_new("memory-backend-ram")
          └─ user_creatable_complete() → 触发 realize
             └─ memory_region_init_ram(mr, ...)             [system/memory.c:3659]
```

### 第二段：分配 host 内存

```
memory_region_init_ram()
  └─ memory_region_init_ram_flags_nomigrate()              [system/memory.c:1592]
       ├─ memory_region_init(mr, "virt.ram", size)          // 初始化 MR 字段
       ├─ qemu_ram_alloc(size, ...)                         // ← 真正分配
       │    └─ qemu_ram_alloc_internal()
       │         ├─ 分配 RAMBlock 结构体 (g_malloc0)
       │         └─ ram_block_add()
       │              ├─ qemu_anon_ram_alloc(size)          [util/oslib-posix.c:208]
       │              │    └─ qemu_ram_mmap(-1, size, ...)  [util/mmap-alloc.c:247]
       │              │         ├─ mmap(PROT_NONE, MAP_ANON)  // 预留虚地址
       │              │         └─ mmap(MAP_FIXED, MAP_ANON)  // 提交物理页
       │              │              └─ rb->host = 返回的 HVA
       │              │
       │              ├─ madvise(MADV_HUGEPAGE)              // 尝试 THP 大页
       │              ├─ madvise(MADV_DONTFORK)              // 禁止 fork 复制
       │              └─ 插入全局 ram_list.blocks (RCU 链表)
       │
       └─ memory_region_set_ram_block(mr, rb)              // mr->ram_block = rb
```

如果传了 `-mem-path /dev/hugepages`：走 `file_ram_alloc() → qemu_ram_mmap(fd, ...)`，从 hugetlbfs 文件 mmap，页大小由 fd 决定（2M/1G）。如果没传：普通匿名 mmap，4K 页，靠 `madvise(MADV_HUGEPAGE)` 让内核 THP 尝试合并。

### 第三段：映射到 AddressSpace

```c
// hw/arm/virt.c:2508
memory_region_add_subregion(sysmem, base, machine->ram);
```

这里 `board` 把 `machine->ram` 插入到 `system_memory` 树，然后触发 `memory_region_transaction_commit()`，重建全局 FlatView。此时 `system_memory` 的 FlatView 里多了一条 `[base, base+ram_size) → machine->ram`。

### 第四段：KVM 收知 —— 建立 GPA→HVA 映射

FlatView 更新后，commmit 阶段触发 KVM listener：

```
kvm_region_commit()                                     [accel/kvm/kvm-all.c:1888]
  └─ kvm_set_phys_mem(kml, section, true)               [accel/kvm/kvm-all.c:1633]
       ├─ ram  = memory_region_get_ram_ptr(mr)          // = RAMBlock.host + offset
       ├─ mem = kvm_alloc_slot(kml)                     // 从 slots[] 取一个空位
       ├─ mem->ram         = ram                        // HVA (host 侧指针)
       ├─ mem->start_addr  = section 的 GPA 起址
       ├─ mem->memory_size = section 大小
       └─ kvm_set_user_memory_region(kml, mem, true)
            └─ kvm_vm_ioctl(KVM_SET_USER_MEMORY_REGION, &mem)
                 │   mem.slot             = slot 编号（ARM 只有一个 AS，slot 从 0 开始）
                 │   mem.guest_phys_addr  = GPA
                 │   mem.userspace_addr   = HVA
                 │   mem.memory_size      = 大小
                 │   mem.flags            = 属性
                 ▼
              内核 KVM: 把这个 GPA 范围写进 stage-2 页表，
              映射到 userspace_addr 对应的 host 物理页
```

### 关键数据结构的关系

```
MemoryRegion (mr)
  │  name = "virt.ram"
  │
  └─ ram_block
       │
       ▼
     RAMBlock
       ├─ host      = mmap 返回的 HVA（比如 0xffff12340000）
       ├─ offset    = 在 ram_addr_t 地址空间中的偏移
       ├─ fd        = -1 (匿名 mmap) 或 hugetlbfs fd
       ├─ page_size = 4K / 2M / 1G
       └─ mr        = 回指 MemoryRegion

KVM 内核:
  KVMSlot (kvm-all.c 中的 kml->slots[])
       ├─ slot         = KVM slot 编号
       ├─ start_addr   = GPA（guest 物理地址起址）
       ├─ ram          = HVA（直接 == RAMBlock.host + 偏移）
       ├─ memory_size  = 大小
       └─ flags        = 读写属性 / dirty log
```

**`KVMSlot.ram` 直接等于 `RAMBlock.host + 偏移`，就是那块 mmap 内存的同一个指针。内核 KVM 用 GPA→HVA 的映射执行 stage-2 翻译：guest 访问 GPA → CPU 硬件查 stage-2 页表 → 找到 HPA（即 HVA 对应的 host 物理页）。**

### 完整链路（一张图）

```
QEMU userspace                          KVM kernel
─────────────                          ──────────
memory_region_init_ram()
  qemu_ram_alloc()
    mmap(匿名)
    → HVA = 0xffff12340000
       (host 虚地址)
       │
  mr->ram_block->host = HVA
       │
  memory_region_add_subregion()
    → FlatView 更新
       │
  kvm_region_commit()                   KVM_SET_USER_MEMORY_REGION
    kvm_set_user_memory_region()          slot.guest_phys_addr = GPA
       │                                  slot.userspace_addr  = HVA
       │                                        │
       │                                        ▼
       │                                 内核建立 stage-2 映射:
       │                                   GPA → HPA
       │                                   (HPA 是 HVA 对应的物理页)
       │
       │                                 Guest 访问 GPA:
       │                                  CPU 硬件走 stage-2 页表
       │                                  GPA → HPA
       │                                  → QEMU mmap 的那块物理内存
```

### ARM 特有的 VM 创建

ARM 的 IPA（Intermediate Physical Address）位宽在创建 VM 时就确定了：

```
kvm_init()                                           [kvm-all.c:2890]
  └─ find_kvm_machine_type()
       └─ virt_kvm_type()                            [hw/arm/virt.c:3359]
            ├─ kvm_arm_get_max_vm_ipa_size()         [target/arm/kvm.c:573]
            │    └─ KVM_CAP_ARM_VM_IPA_SIZE → 返回支持的 bit 数（如 40/48）
            ├─ 根据 vms->highest_gpa 计算需要的 bit 数
            └─ 返回 IPA bit count
                 │
                 ▼
  └─ do_kvm_create_vm(s, type)
       └─ kvm_ioctl(KVM_CREATE_VM, ipa_bits)        // type 参数就是 IPA bits
```

IPA 位宽决定了 stage-2 页表能寻址的最大物理地址范围，但这不改变 host 侧的 mmap 分配逻辑——host 内存的分配永远走 `qemu_ram_mmap()`。

---

## MemoryListener 的具体例子

### 最简单的例子：Virtio

Virtio 只关心 `commit` 回调（`hw/virtio/virtio.c`）：

```c
static void virtio_memory_listener_commit(MemoryListener *listener)
{
    VirtIODevice *vdev = container_of(listener, VirtIODevice, listener);
    for (int i = 0; i < VIRTIO_QUEUE_MAX; i++) {
        if (vdev->vq[i].vring.num == 0) break;
        virtio_init_region_cache(vdev, i);  // 重新解析 DMA 地址映射
    }
}

// 注册（virtio_device_realize 中）:
vdev->listener.commit = virtio_memory_listener_commit;
vdev->listener.name = "virtio";
memory_listener_register(&vdev->listener, vdev->dma_as);
```

内存拓扑变化后，virtqueue 的 descriptor/available/used ring 的 GPA 对应的 HVA 可能变了，所以 commit 时重新做一次 `address_space_cache_init()` 翻译。

### 最完整的例子：VFIO

VFIO listener（`hw/vfio/listener.c`）实现了几乎所有回调：

```c
static const MemoryListener vfio_memory_listener = {
    .name = "vfio",
    .begin = vfio_listener_begin,
    .commit = vfio_listener_commit,
    .region_add = vfio_listener_region_add,     // VFIO_IOMMU_MAP_DMA
    .region_del = vfio_listener_region_del,     // VFIO_IOMMU_UNMAP_DMA
    .log_global_start = vfio_listener_log_global_start,  // 开启 dirty tracking
    .log_global_stop = vfio_listener_log_global_stop,    // 关闭 dirty tracking
    .log_sync = vfio_listener_log_sync,                  // 读取 dirty bitmap
};
```

- **region_add**: 调用 `VFIO_IOMMU_MAP_DMA` ioctl 在 IOMMU 里建映射
- **region_del**: 调用 `VFIO_IOMMU_UNMAP_DMA` ioctl 移除映射
- **log_sync**: 热迁移时从 VFIO 容器读取 dirty bitmap

---

## 各概念的对比关系

| 概念 | 本质 | 生命周期 | 谁拥有它 |
|------|------|----------|----------|
| **MemoryRegion** | 一段内存/MMIO 的**描述** | 静态（设备 realize 时创建） | 设备或 board 代码 |
| **RAMBlock** | RAM 类型 MR 的 **host 端实际内存** | 和 RAM MR 绑定 | MemoryRegion |
| **FlatView** | 一个 AddressSpace 的**展开快照** | 动态（每次拓扑变化重新生成） | AddressSpace |
| **FlatRange** | FlatView 中的**一条记录** | 随 FlatView 创建和销毁 | FlatView |
| **AddressSpace** | 内存的**视角**（CPU 视角 / DMA 视角） | 静态（系统初始化时创建） | QEMU core |
| **MemoryRegionSection** | 传递给 listener 的**参数对象** | 临时（回调期间有效） | 栈上 |
| **MemoryListener** | 拓扑变化的**回调接口** | 静态注册，回调动态触发 | 各子系统（VFIO、KVM、virtio 等） |

---

## 容易混淆的关键区分

### 1. MemoryRegion vs FlatView

MemoryRegion 是**声明式的树**（"我希望这块内存长这样"），FlatView 是**编译后的结果**（"当前时刻，这段地址对应的就是这块 MR 的这个偏移量"）。同一个 MR 在不同 FlatView（不同 AddressSpace）中可能出现、也可能不出现。

### 2. MemoryRegion vs MemoryRegionSection

一个大的 MemoryRegion 在 FlatView 中可能被切割成多个 FlatRange（因为它被更高优先级的 region 部分覆盖了）。每个 FlatRange 转换成一个 **MemoryRegionSection**，它是一个 MR 的一个连续切片。

举例：你有一个 0-4K 的 RAM region，但它中间被一个 1K-2K 的 MMIO region 覆盖了。展平后会产生 3 个 section：
- MR=RAM, offset_within_region=0, offset_within_as=0, size=1K
- MR=MMIO, offset_within_region=0, offset_within_as=1K, size=1K
- MR=RAM, offset_within_region=2K, offset_within_as=2K, size=2K

### 3. MemoryListener vs AddressSpace

**MemoryListener 不直接读 FlatView**。它只在变化时收到通知，通知里携带了变化的信息（MemoryRegionSection）。如果 listener 需要主动查询当前状态（比如 virtio 的 commit 回调里），它通过 `address_space_cache_init()` 等 API 间接访问当前的 FlatView。

### 4. 全局 listeners vs 每-AS listeners

MemoryListener 同时存在两个链表中：
- **全局 `memory_listeners`**：用于 begin/commit、log_global_start/stop 等全局操作
- **`as->listeners`**：用于该 AS 的 region_add/del/nop 等 per-region 操作

同一个 listener 的 `begin` 和 `commit` 只会被调用一次（通过全局链），但 `region_add` 只在它所属的那个 AddressSpace 的链中被调用。

### 6. RAMBlock vs KVMSlot vs MemoryRegion

- **MemoryRegion** 是 guest 可见的抽象（"有一块从 GPA x 到 y 的 RAM"）
- **RAMBlock** 是 host 侧的实际内存（`rb->host` 指向 mmap 返回的 HVA），一个 MR 对应一个 RAMBlock
- **KVMSlot** 是 KVM 内核中的"内存槽"（告诉内核 "GPA 范围→HVA"），一个大 MR 可能被拆成多个 slot（受 `max_slot_size` 限制）

当 `memory_region_add_subregion()` 把 MR 连接到 AS 之后，KVM listener 创建 KVMSlot，让 `KVMSlot.ram` 直接指向 `RAMBlock.host` 内的地址。GPA→HVA→HPA 的完整链条由此建立。

### 5. 新 listener 注册时的 replay

当你调用 `memory_listener_register()` 时，QEMU 会立即**重放**当前 FlatView 的全部内容给这个 listener（调用 begin → 遍历所有 range 调 region_add → 调用 commit）。这样 listener 不用自己扫描初始状态，直接通过 region_add 拿到当前全貌。

---

## 相关源码文件

| 文件 | 内容 |
|------|------|
| `include/system/memory.h` | MemoryListener 结构体定义（line 889）、MemoryRegionSection（line 105）、AddressSpace（line 1157）、FlatView（line 1194）、FlatRange typedef（line 1189）、priority 常量（line 879） |
| `system/memory.c` | 所有核心逻辑：全局链表（line 48-52）、MEMORY_LISTENER_CALL 宏（line 109-163）、FlatRange 结构体（line 222）、listener_add/del_address_space（line 2983/3048）、memory_listener_register/unregister（line 3099/3138）、address_space_set_flatview（line 1081）、address_space_update_topology_pass（line 970）、memory_region_transaction_commit（line 1143）、全局 dirty log 函数（line 2846+） |
| `system/physmem.c` | 物理内存管理：`qemu_ram_alloc_internal()`（line 2466）、`ram_block_add()`（line 2155）、`cpu_address_space_init()`（line 754） |
| `util/mmap-alloc.c` | `qemu_ram_mmap()`（line 247），底层 mmap 封装：reserve + activate 两阶段映射 |
| `util/oslib-posix.c` | `qemu_anon_ram_alloc()`（line 208），匿名内存分配入口 |
| `accel/kvm/kvm-all.c` | `kvm_region_commit()`（line 1888）、`kvm_set_phys_mem()`（line 1633）、`kvm_set_user_memory_region()`（line 371），KVM 内存槽管理 |
| `include/system/kvm_int.h` | `KVMSlot` 结构体（line 22） |
| `include/system/ramblock.h` | `RAMBlock` 结构体（line 25） |
| `hw/arm/virt.c` | ARM virt 机器：`virt_kvm_type()`（line 3359）确定 IPA 位宽，`memory_region_add_subregion(sysmem, base, machine->ram)`（line 2508）映射 RAM |
| `target/arm/kvm.c` | `kvm_arm_get_max_vm_ipa_size()`（line 573）查询 KVM 支持的 IPA 大小 |
| `hw/vfio/listener.c` | 最完整的 MemoryListener 实际例子：实现了所有主要回调用于 IOMMU 映射 + dirty tracking |
| `hw/virtio/virtio.c` | 最简单的 MemoryListener 实际例子：只实现 commit 回调来刷新 virtqueue ring 地址缓存 |

---

## 一句话总结

> **MemoryRegion 树**是蓝图，**FlatView** 是按蓝图编译出的运行结果，**AddressSpace** 持有这两者加上一个监听器链表，**MemoryListener** 是当蓝图变化导致编译结果变化时被调用的回调接口。
