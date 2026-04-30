QEMU热迁移流程分析
=====================

-v0.3 2026.04.30 Sherlock update: 新增迭代收敛与速率控制详细分析（bandwidth估算、threshold计算、sleep/interval机制）

本文档分析 QEMU 热迁移 (live migration) 的完整流程，包括迁移状态机、各阶段实现、核心数据结构及源端/目的端交互。基于 QEMU 源码 (`/home/wz/qemu/migration/`) 分析。


## 核心文件

| 文件 | 功能 |
|------|------|
| `migration/migration.c` | 迁移主逻辑，状态机，迁移线程，速率限制，完成逻辑 |
| `migration/migration.h` | MigrationState/MigrationIncomingState 定义，MigThrError |
| `migration/ram.c` | RAM 迁移，脏页追踪和传输，RAMState |
| `migration/ram.h` | RAM 标志位，RAM_CHANNEL_* 常量 |
| `migration/savevm.c` | VM 状态保存/加载，SaveStateEntry，流格式 |
| `migration/savevm.h` | Section 类型常量 (QEMU_VM_*) |
| `migration/qemu-file.c` | 迁移数据流抽象层 QEMUFile |
| `migration/qemu-file.h` | QEMUFile 接口 |
| `migration/postcopy-ram.c` | Postcopy 迁移实现（缺页处理、监听线程） |
| `migration/postcopy-ram.h` | Postcopy 状态机定义 |
| `migration/multifd.c` / `multifd.h` | 多通道并行传输框架 |
| `migration/multifd-nocomp.c` | Multifd RAM 页传输实现 |
| `migration/options.c` / `options.h` | 迁移参数 (downtime, bandwidth 等) |
| `migration/migration-stats.c` | 迁移统计信息 |
| `migration/xbzrle.c` | XBZRLE 增量压缩 |
| `migration/cpu-throttle.c` | Auto-converge CPU 节流 |
| `migration/rdma.c` | RDMA 加速传输 |
| `include/migration/register.h` | SaveVMHandlers 设备注册接口 |


## 核心数据结构

### MigrationState (源端) — `migration/migration.h`

```c
struct MigrationState {
    // 线程
    QemuThread thread;                  // 迁移主线程

    // 状态
    MigrationStatus state;              // 当前迁移状态 (MigrationStatus 枚举)
    int64_t setup_time;                 // setup 阶段耗时

    // 通道
    QEMUFile *to_dst_file;              // 发送到目的端的主通道
    QEMUFile *from_dst_file;            // 从目的端接收的返回路径 (return path)
    QEMUFile *postcopy_qemufile_src;    // postcopy 源端文件

    // 返回路径线程
    QemuThread rp_thread;               // 返回路径线程，处理目的端发来的消息
    bool rp_thread_created;

    // 带宽 & 速率
    int64_t rate_limit_max;             // 最大带宽限制
    int64_t rate_limit_used;            // 当前周期已发送字节
    int64_t rate_limit_start_time;      // 当前周期起始时间
    int64_t downtime;                   // 总停机时间 (从 VM 停到迁移完成)
    int64_t downtime_start;             // VM 停止的时刻
    int64_t expected_downtime;          // 预期的停机时间 (migrate_downtime_limit())

    // 切换 (switchover / convergence)
    uint64_t threshold_size;            // 切换阈值，pending_size 小于此值则触发完成
    bool start_postcopy;                // 是否启用 postcopy 模式
    bool switchover_acked;              // 目的端是否确认切换
    int switchover_ack_count;           // 需要确认的设备数量

    // 事件
    QemuEvent postcopy_package_loaded_event;  // postcopy 打包数据加载完成事件

    // 迁移对象引用计数
    int refcount;
};
```

### MigrationIncomingState (目的端) — `migration/migration.h`

```c
struct MigrationIncomingState {
    QEMUFile *from_src_file;            // 从源端接收的主通道
    QEMUFile *to_src_file;              // 发送到源端的返回路径
    QemuThread fault_thread;            // postcopy 缺页处理线程
    int userfault_fd;                   // userfaultfd 文件描述符
    int userfault_event_fd;             // uffd 事件通知 fd

    QemuEvent main_thread_load_event;   // 主线程加载完成事件

    // 页面请求 (postcopy)
    GTree *page_requested;              // 已请求的页面树 (page addr -> 请求计数)

    // Postcopy 状态
    PostcopyState postcopy_state;       // postcopy 状态机
    bool postcopy_remote_fds;           // 是否使用远程 fd
    bool switchover_acked;              // 是否发送了 switchover ack

    Coroutine *loadvm_co;               // 加载协程
};
```

### RAMState (RAM 迁移核心) — `migration/ram.c`

```c
struct RAMState {
    PageSearchStatus pss[RAM_CHANNEL_MAX];  // 每个通道的页面搜索状态 [PRECOPY=0, POSTCOPY=1]
    int uffdio_fd;                          // userfaultfd 写保护追踪 fd
    uint64_t ram_bytes_total;               // RAM 总大小
    RAMBlock *last_seen_block;              // 上次扫描到的块
    ram_addr_t last_page;                   // 上次发送的页面
    uint32_t last_version;                  // 上次的 ram_list 版本
    int64_t time_last_bitmap_sync;          // 上次位图同步时间
    uint64_t bytes_xfer_prev;               // 上次同步时的传输量
    uint64_t num_dirty_pages_period;        // 本周期脏页数
    bool last_stage;                        // 是否处于最后阶段 (VM 已停)
    uint64_t target_page_count;             // 已处理页面总数
    uint64_t migration_dirty_pages;         // 脏页位图中脏页计数
    QemuMutex bitmap_mutex;                 // 保护位图和 pss 结构
    QemuMutex src_page_req_mutex;           // 保护页面请求队列
    QSIMPLEQ_HEAD(, RAMSrcPageRequest) src_page_requests;  // postcopy 页面请求队列
    PageLocationHint page_hint;             // postcopy 抢占页面提示
};
```

### SaveVMHandlers (设备迁移接口) — `include/migration/register.h`

```c
typedef struct SaveVMHandlers {
    // Setup
    int (*save_setup)(QEMUFile *f, void *opaque, Error **errp);
    int (*load_setup)(QEMUFile *f, void *opaque, Error **errp);
    void (*save_cleanup)(void *opaque);

    // Save
    int (*save_live_iterate)(QEMUFile *f, void *opaque);         // 返回 0=还有数据, 1=完成
    int (*save_complete)(QEMUFile *f, void *opaque);             // 最终保存
    void (*state_pending_estimate)(void *opaque, uint64_t *must_precopy,
                                   uint64_t *can_postcopy);      // 快速估算
    void (*state_pending_exact)(void *opaque, uint64_t *must_precopy,
                                uint64_t *can_postcopy);         // 精确计算

    // Postcopy
    bool (*has_postcopy)(void *opaque);
    bool (*save_postcopy_prepare)(QEMUFile *f, void *opaque, Error **errp);

    // Load
    int (*load_state)(QEMUFile *f, void *opaque, int version_id);
    bool (*load_state_buffer)(void *opaque, char *buf, size_t len, Error **errp);

    // Activity check
    bool (*is_active)(void *opaque);
    bool (*is_active_iterate)(void *opaque);

    // Switchover ack
    bool (*switchover_ack_needed)(void *opaque);
    int (*switchover_start)(void *opaque);
} SaveVMHandlers;
```

### SaveStateEntry (注册的设备状态) — `migration/savevm.c`

```c
typedef struct SaveStateEntry {
    QTAILQ_ENTRY(SaveStateEntry) entry;     // 链表
    char idstr[256];                        // 设备标识符
    uint32_t instance_id;                   // 实例 ID
    int version_id;                         // 保存格式版本
    int load_version_id;                    // 从流中读取的版本 (目的端)
    int section_id;                         // 全局唯一 section ID (递增分配)
    int load_section_id;                    // 从流中读取的 section_id (目的端)
    const SaveVMHandlers *ops;             // 可迭代设备的回调接口
    const VMStateDescription *vmsd;         // 非迭代设备的状态描述
    void *opaque;                           // 设备私有数据
    CompatEntry *compat;                    // 兼容性条目
} SaveStateEntry;
```

### PageSearchStatus (页面搜索游标) — `migration/ram.c`

```c
struct PageSearchStatus {
    QEMUFile    *pss_channel;               // 发送通道
    RAMBlock    *last_sent_block;           // 上一次发送的块
    RAMBlock    *block;                     // 当前搜索的块
    unsigned long page;                     // 当前搜索的页偏移
    bool         complete_round;            // 是否完成一轮完整扫描
    bool         host_page_sending;         // 是否在发送一个大页
    unsigned long host_page_start;          // 大页起始
    unsigned long host_page_end;            // 大页结束
};
```


## 迁移状态机

### 完整状态定义 (`qapi/migration.json` → `MigrationStatus`)

```
MIGRATION_STATUS_NONE              (0)  — 初始状态，未开始迁移
MIGRATION_STATUS_SETUP             (1)  — 连接建立，传输头部和设备 setup
MIGRATION_STATUS_CANCELLING        (2)  — 正在取消迁移
MIGRATION_STATUS_CANCELLED         (3)  — 取消完成
MIGRATION_STATUS_ACTIVE            (4)  — 预拷贝迭代传输中 (precopy active)
MIGRATION_STATUS_POSTCOPY_DEVICE   (5)  — postcopy: 目的端正加载设备状态
MIGRATION_STATUS_POSTCOPY_ACTIVE   (6)  — postcopy: 目的端 VM 运行，缺页拉取
MIGRATION_STATUS_POSTCOPY_PAUSED   (7)  — postcopy: 网络中断暂停
MIGRATION_STATUS_POSTCOPY_RECOVER  (8)  — postcopy: 准备恢复
MIGRATION_STATUS_POSTCOPY_RECOVER_SETUP (9) — postcopy: 重新建立连接
MIGRATION_STATUS_COMPLETED         (10) — 迁移成功完成
MIGRATION_STATUS_FAILING           (11) — 发生错误，清理中
MIGRATION_STATUS_FAILED            (12) — 错误处理完毕
MIGRATION_STATUS_COLO              (13) — COLO 容错模式
MIGRATION_STATUS_PRE_SWITCHOVER    (14) — 暂停 VM 等待设备序列化
MIGRATION_STATUS_DEVICE            (15) — 设备状态序列化/切换阶段
MIGRATION_STATUS_WAIT_UNPLUG       (16) — 等待 virtio-net 设备热拔
```

### 状态转换图

#### 源端主流程

```
                              +-------+
                              | SETUP |
                              +-+-+-+-+
                               /  |  \
                              /   |   \
                    +--------+    |    +-------------+
                    | FAILING|    |    | WAIT_UNPLUG |
                    +--------+    |    +------+------+
                                  |           |
                                  |    unplug done (returns to ACTIVE)
                           +------v------+
                           |    ACTIVE    |
                           +--+---+---+--+
                             /    |    \
                            /     |     \
               +-----------+      |      +----------------+
               |POSTCOPY   |      |      |PRE_SWITCHOVER  |
               |_ACTIVE    |      |      +-------+--------+
               |(no RP)    |      |              |
               +-----+-----+      |              |
                     |            |              |
                     v            |              |
               +-----------+      |              |
               | COMPLETED |      |              |
               +-----------+      |              |
                                  v              v
                             +----+--------------+----+
                             |         DEVICE         |
                             +--------+---+-----------+
                                     /     \
                                    /       \
                          +-----------+   +-----------------+
                          | COMPLETED |   | POSTCOPY_DEVICE |
                          | (precopy) |   +--------+--------+
                          +-----------+            |
                                            event triggered
                                                   |
                                          +--------v--------+
                                          | POSTCOPY_ACTIVE |
                                          +--------+--------+
                                                   |
                                                   v
                                             +-----------+
                                             | COMPLETED |
                                             +-----------+
```

Note: The NONE -> SETUP transition (via `migrate_init()`) is not shown in the tree above to keep the diagram focused. NONE is the initial state before any migration; `migrate_init()` transitions to SETUP.

#### Failure Paths

```
Any state --> FAILING --> FAILED
CANCELLING --> CANCELLED
POSTCOPY_ACTIVE --> POSTCOPY_PAUSED --> POSTCOPY_RECOVER_SETUP --> POSTCOPY_RECOVER --> POSTCOPY_ACTIVE
```

#### Destination State Transitions

```
SETUP --> ACTIVE (coroutine loads VM state)
  |
  +--> [precopy]  ACTIVE --> COMPLETED
  |
  +--> [postcopy] POSTCOPY_DEVICE --> POSTCOPY_ACTIVE --> COMPLETED
```


## 迁移阶段详解

### 阶段 1: 初始化 Setup

**入口**: `migrate_init()` (`migration.c:1617`) → `migration_start_outgoing()` (`migration.c:3755`) → `migration_thread()` (`migration.c:3492`)

#### 1.1 migrate_init() — 迁移准备

```
migrate_init()
  ├─► qemu_savevm_state_prepare()        // 调用所有设备的 save_prepare
  ├─► 重置 s->to_dst_file, s->state, s->mbps, s->downtime 等字段
  ├─► 清理旧错误信息
  ├─► 创建 JSON 写入器用于 vmdesc
  └─► migrate_set_state(NONE → SETUP)
```

#### 1.2 migration_start_outgoing() — 建立连接

```
migration_start_outgoing()
  ├─► s->expected_downtime = migrate_downtime_limit()   // 设置预期停机时间
  ├─► migration_rate_set(rate_limit)                    // 设置带宽限制
  ├─► qemu_file_set_blocking(to_dst_file, true)         // 切换到阻塞模式
  ├─► open_return_path_on_source()                      // 打开返回路径 (如果启用)
  │     └─► 创建 rp_thread，监听目的端消息
  ├─► postcopy_preempt_setup()                          // postcopy 抢占通道 (可选)
  ├─► 创建 migration_thread                             // 启动迁移主线程
  └─► s->migration_thread_running = true
```

#### 1.3 migration_thread() — 主线程 Setup 部分

```
migration_thread()
  ├─► rcu_register_thread()
  ├─► multifd_send_setup()                              // 初始化多通道
  │
  ├─► BQL lock
  ├─► qemu_savevm_state_header(s->to_dst_file)           // 写头部
  │     ├─► qemu_put_be32(QEMU_VM_FILE_MAGIC)  // 魔数 "QEVM" = 0x5145564d
  │     └─► qemu_put_be32(QEMU_VM_FILE_VERSION) // 版本 0x00000003
  ├─► BQL unlock
  │
  ├─► qemu_savevm_send_open_return_path()               // 通知目的端打开返回路径
  ├─► qemu_savevm_send_ping(to_dst_file, 1)              // 发 PING 测 RTT
  │
  ├─► qemu_savevm_send_postcopy_advise()                 // postcopy 协商 (如果启用)
  │
  ├─► cpu_throttle_dirty_sync_timer(true)                // 启动 auto-converge 定时器 (如果启用)
  │
  ├─► BQL lock
  ├─► qemu_savevm_state_do_setup()                       // 设备初始化
  │     ├─► 保存 early_setup 非迭代设备 (QEMU_VM_SECTION_FULL)
  │     └─► 调用每个可迭代设备的 save_setup()
  │           └─► 写 QEMU_VM_SECTION_START 头部
  ├─► BQL unlock
  │
  ├─► qemu_savevm_wait_unplug(s, SETUP, ACTIVE)          // 等待 virtio-net 热拔
  └─► 记录 s->setup_time
```

### 阶段 2: 迭代传输 Iterative Copy

**核心**: `migration_iteration_run()` (`migration.c:3205`)，由主线程循环调用。

`migration_thread()` 的主循环 (`while (migration_is_active())`):

```
migration_thread() 主循环:
  while (state == ACTIVE || POSTCOPY_DEVICE || POSTCOPY_ACTIVE) {
    │
    ├─► [如果紧急或未达速率限制]:
    │     iter_state = migration_iteration_run(s)
    │       ├─► MIG_ITERATE_RESUME — 继续下一轮
    │       ├─► MIG_ITERATE_SKIP   — 跳过等待 (postcopy 启动)
    │       └─► MIG_ITERATE_BREAK  — 退出主循环 (完成或失败)
    │
    ├─► migration_detect_error(s)             // 检查错误和取消
    │     ├─► FATAL    → break
    │     └─► RECOVERED → 重置迭代状态 (postcopy 恢复)
    │
    └─► migration_rate_limit()                // 速率限制 (sleep until next timeslot)
  }
```

#### migration_iteration_run() 详解

```
migration_iteration_run(s)
  │
  ├─► qemu_savevm_state_pending_estimate()    // 快速估算剩余数据量
  │     └─► pending_size = must_precopy + can_postcopy
  │
  ├─► 如果是 POSTCOPY 状态:
  │     └─► complete_ready = (pending_size == 0)
  │
  ├─► 如果是 ACTIVE (precopy) 状态:
  │   │
  │   ├─► 如果 pending_size < threshold_size:
  │   │     └─► qemu_savevm_state_pending_exact()  // 精确计算剩余量
  │   │
  │   ├─► 判断是否触发 postcopy:
  │   │     if (must_precopy <= threshold_size && can_switchover && start_postcopy)
  │   │       └─► postcopy_start() → 返回 MIG_ITERATE_SKIP
  │   │
  │   └─► 判断是否可以完成:
  │         complete_ready = can_switchover && (pending_size <= threshold_size)
  │         // can_switchover: 无 switchover_ack 或已收到确认
  │         // threshold_size: expected_bw_per_ms * migrate_downtime_limit()
  │
  ├─► 如果 complete_ready:
  │     ├─► migration_completion(s)           // 进入完成阶段
  │     └─► 返回 MIG_ITERATE_BREAK
  │
  └─► 否则:
        ├─► qemu_savevm_state_iterate()       // 继续迭代传输
        └─► 返回 MIG_ITERATE_RESUME
```

#### 阈值计算 (`migration_update_counters()`, `migration.c:3119`)

```
threshold_size = expected_bw_per_ms * migrate_downtime_limit()
```
其中 `expected_bw_per_ms` 是当前估算带宽 (字节/毫秒)，`migrate_downtime_limit()` 是用户配置的最大允许停机时间。

#### qemu_savevm_state_iterate() 迭代过程

```
qemu_savevm_state_iterate(f, postcopy)
  │
  └─► 遍历所有设备 (按优先级):
        ├─► 跳过不活跃的设备 (!is_active)
        ├─► 跳过 is_active_iterate == false 的设备
        ├─► 在 postcopy 模式下跳过不支持 postcopy 的设备
        │
        ├─► 如果 migration_rate_exceeded(f) → 提前返回 (不再迭代更多设备)
        │
        └─► 写 QEMU_VM_SECTION_PART 头部
            调用 se->ops->save_live_iterate(f, opaque)
              └─► ram_save_iterate()         // RAM 迭代 (见下节)
            写 Section Footer
            返回 0=还有数据, 1=完成
```

### 阶段 3: RAM 脏页传输

#### 3.1 ram_save_setup() — RAM 初始化 (`ram.c:3113`)

```
ram_save_setup()
  ├─► ram_init_all()
  │     ├─► ram_state_init()           // 分配 RAMState，初始化 mutex
  │     ├─► xbzrle_init()              // 分配 XBZRLE 缓存
  │     └─► ram_init_bitmaps()         // 为每个 RAMBlock 创建脏页位图
  │           ├─► rb->bmap 全部置 1 (所有页初始为脏)
  │           └─► memory_global_dirty_log_start()  // 开启 KVM 脏页追踪
  │
  ├─► 发送 RAM_SAVE_FLAG_MEM_SIZE     // 发送所有 RAMBlock 元数据 (名称, 大小)
  │
  ├─► multifd_ram_save_setup()         // 初始化 multifd 发送端
  ├─► multifd_ram_flush_and_sync()     // 同步 multifd (让目的端准备就绪)
  └─► 发送 RAM_SAVE_FLAG_EOS          // setup 结束标志
```

#### 3.2 脏页位图机制

每个 RAMBlock 维护两套位图:
- **`rb->bmap`**: 主脏页位图，记录待传输的脏页。初始全 1。每轮扫描时 `find_next_bit(bmap)` 查找。
- **`rb->clear_bmap`**: 辅助位图，记录已清理 KVM 脏页日志的 chunk。
- **`rb->receivedmap`**: 目的端位图，记录已接收的页。

**位图同步流程** (`migration_bitmap_sync()`, `ram.c:1134`):
```
migration_bitmap_sync()
  ├─► memory_global_dirty_log_sync()        // 从 KVM 拉取脏页信息到 ram_list.dirty_memory[]
  └─► 遍历每个 RAMBlock:
        └─► ramblock_sync_dirty_bitmap()     // 将 KVM 脏位 OR 到 rb->bmap
```

**清除脏位** (`migration_bitmap_clear_dirty()`, `ram.c:829`):
```
migration_bitmap_clear_dirty(rs, rb, page)
  ├─► 如果非 last_stage 且非 postcopy:
  │     └─► migration_clear_memory_region_dirty_bitmap()  // 清除 KVM 日志
  ├─► test_and_clear_bit(rb->bmap[page])    // 原子地测试并清除
  └─► 如果该位本来是脏的 → rs->migration_dirty_pages--
```

#### 3.3 ram_save_iterate() — 迭代传输 RAM (`ram.c:3256`)

```
ram_save_iterate(f, opaque)
  │
  ├─► 如果 ram_list.version 变更 → ram_state_reset() 重置扫描游标
  │
  ├─► while (!migration_rate_exceeded(f) || postcopy_has_request(rs)):
  │     │
  │     ├─► pages = ram_find_and_save_block(rs)   // 查找并发送脏页
  │     │     ├─► 返回 0 → 没有更多脏页 (done=1, break)
  │     │     └─► 返回 N → 发送了 N 页
  │     │
  │     ├─► rs->target_page_count += pages
  │     └─► 每 64 次迭代检查是否超时 (MAX_WAIT = 50ms)，避免长时间持锁
  │
  ├─► [可选] multifd_ram_flush_and_sync()          // legacy per-section 同步
  ├─► 发送 RAM_SAVE_FLAG_EOS
  └─► 返回 done (=1 全部干净, =0 还有脏页)
```

#### 3.4 ram_find_and_save_block() — 查找脏页 (`ram.c:2322`)

```
ram_find_and_save_block(rs)
  │
  ├─► 从上次的游标 (last_seen_block, last_page) 恢复搜索位置
  │
  ├─► 循环搜索:
  │     │
  │     ├─► get_queued_page(rs, pss)           // 优先处理 postcopy 请求页面
  │     │     └─► 如果有请求队列 → 跳转到对应页
  │     │
  │     └─► find_dirty_block(rs, pss)           // 扫描位图找脏页
  │           ├─► pss_find_next_dirty(pss)       // find_next_bit(rb->bmap, ...)
  │           │
  │           ├─► 如果超出当前块末尾 → 移到下一个 RAMBlock
  │           │     └─► 如果遍历完所有块:
  │           │           ├─► pss->complete_round = true
  │           │           ├─► multifd_ram_flush_and_sync()  // per-round 同步
  │           │           └─► 启用 XBZRLE (第一轮后)
  │           │
  │           └─► 如果回到起点 → PAGE_ALL_CLEAN (本轮无脏页)
  │
  ├─► ram_save_host_page(rs, pss)              // 发送找到的脏页所在的大页
  │     │
  │     ├─► 确定大页边界 (host_page_start ~ host_page_end)
  │     │
  │     └─► 遍历大页内的每个 guest page:
  │           ├─► migration_bitmap_clear_dirty()     // 清除脏位
  │           ├─► 如果该页为脏:
  │           │     └─► ram_save_target_page()
  │           │           ├─► RDMA 路径: rdma_control_save_page()
  │           │           ├─► 零页检测: save_zero_page() + RAM_SAVE_FLAG_ZERO
  │           │           ├─► Multifd 路径: ram_save_multifd_page()
  │           │           │     └─► multifd_queue_page() 把页加入 multifd 队列
  │           │           ├─► XBZRLE 路径: save_xbzrle_page() + RAM_SAVE_FLAG_XBZRLE
  │           │           └─► 普通路径: save_normal_page() + RAM_SAVE_FLAG_PAGE
  │           │
  │           └─► pss_find_next_dirty()              // 找大页内下一个脏页
  │
  ├─► 更新游标 rs->last_seen_block, rs->last_page
  └─► 返回发送的页数 (或 0=全部干净, <0=错误)
```

### 阶段 4: 停止并拷贝 Stop-and-Copy (Precopy 完成)

#### 4.1 migration_completion() (`migration.c:2792`)

```
migration_completion(s)
  ├─► 如果 state == ACTIVE:
  │     └─► migration_completion_precopy(s)
  ├─► 否则如果 state == POSTCOPY_ACTIVE:
  │     └─► migration_completion_postcopy(s)
  │
  ├─► 停止返回路径线程
  │
  ├─► 如果启用 COLO → state → COLO
  └─► 否则 → migration_completion_end(s)
        └─► state → COMPLETED; 计算总时间和吞吐量
```

#### 4.2 migration_completion_precopy() (`migration.c:2743`)

```
migration_completion_precopy(s)
  │
  ├─► BQL lock
  │
  ├─► migration_stop_vm(RUN_STATE_FINISH_MIGRATE)   // ★ 停止 VM
  │
  ├─► migration_switchover_start(s)                  // 切换准备
  │     ├─► 处理 PRE_SWITCHOVER 暂停 (如果启用 pause_before_switchover)
  │     │     └─► 用户可通过 QMP 确认或超时
  │     ├─► migration_block_deactivate()             // 停用块设备
  │     ├─► qemu_file_set_rate_limit(NULL)           // 关闭速率限制
  │     └─► state → DEVICE
  │
  └─► qemu_savevm_state_complete_precopy(s)        // 完成状态保存
        ├─► qemu_savevm_state_complete_precopy_iterable()
        │     └─► 调用每个可迭代设备的 save_complete()
        │           └─► ram_save_complete()
        │                 ├─► rs->last_stage = true     // 标记最后阶段
        │                 ├─► migration_bitmap_sync_precopy(true)  // 最终同步 KVM 脏位
        │                 ├─► 循环 ram_find_and_save_block() 直到 pages==0
        │                 ├─► 保存 mapped-ram 位图 (如果启用)
        │                 └─► 发送 RAM_SAVE_FLAG_EOS
        │
        ├─► qemu_savevm_state_non_iterable()    // 保存所有非迭代设备 (QEMU_VM_SECTION_FULL)
        │     └─► 遍历 vmstate 设备，调用 vmstate_save()
        │
        └─► qemu_savevm_state_end_precopy()     // 写 QEMU_VM_EOF + QEMU_VM_VMDESCRIPTION
```

### 阶段 5: Postcopy 模式

#### 5.1 postcopy_start() — 切换到 Postcopy (`migration.c:2464`)

```
postcopy_start(ms)
  │
  ├─► 清理 JSON 写入器
  ├─► postcopy_preempt_establish_channel()   // 建立抢占通道 (可选)
  │
  ├─► qemu_savevm_state_postcopy_prepare()   // 准备 postcopy
  │
  ├─► BQL lock
  ├─► migration_stop_vm()                    // ★ 停止 VM
  ├─► migration_switchover_start()           // 切换准备 (停用块设备等)
  │
  ├─► qemu_savevm_state_complete_precopy_iterable()
  │     └─► 保存不支持 postcopy 的可迭代设备
  │
  ├─► ram_postcopy_send_discard_bitmap()     // 发送 discard bitmap (告知目的端哪些页可能被丢弃)
  │
  ├─► 创建打包缓冲区 (打包设备状态和 RAM 元数据)
  ├─► qemu_savevm_send_postcopy_listen()     // 发送 POSTCOPY_LISTEN → 目的端启动监听
  │
  ├─► qemu_savevm_state_non_iterable()       // 将非迭代设备保存到缓冲区
  ├─► qemu_savevm_send_ping(PACKAGED_LOADED) // 通知目的端打包数据已就绪
  ├─► qemu_savevm_send_postcopy_run()        // 发送 POSTCOPY_RUN → 目的端启动 VM
  ├─► qemu_savevm_send_packaged()            // 发送打包数据
  │
  ├─► migration_downtime_end()               // 记录停机结束时间
  ├─► 切换到 postcopy 带宽限制
  │
  └─► state DEVICE → POSTCOPY_DEVICE (有返回路径) 或 POSTCOPY_ACTIVE
```

#### 5.2 Postcopy 目的端流程

```
postcopy_listen_thread()    // 由 POSTCOPY_LISTEN 命令触发
  │
  ├─► state ACTIVE → POSTCOPY_DEVICE
  │
  ├─► qemu_loadvm_state_main(f, mis)      // 在监听线程中处理:
  │     ├─► 处理页面请求 (来自缺页处理)
  │     ├─► 接收 REQ_PAGES 响应
  │     └─► 处理完成命令
  │
  └─► state POSTCOPY_ACTIVE → COMPLETED

loadvm_postcopy_handle_run()  // 处理 POSTCOPY_RUN 命令
  ├─► state POSTCOPY_DEVICE → POSTCOPY_ACTIVE
  └─► 调度 BH: vm_start()   // ★ 目的端 VM 开始运行
```

#### 5.3 Postcopy 缺页处理

```
目的端 VM 运行时:
  访问未迁移的页面 → userfaultfd 缺页
    │
    ▼
postcopy_ram_fault_thread()
  ├─► 读取 uffd_msg (缺页地址)
  ├─► 通过返回路径向源端发送 MIG_RP_MSG_REQ_PAGES
  ├─► 源端 ram_save_page_request() 处理请求
  ├─► 源端发送页面
  ├─► 目的端收到后通过 UFFDIO_COPY 写入
  └─► 唤醒等待的 vCPU
```


## 源端/目的端交互协议

### 源端同步流程

```
用户执行 migrate (QMP/HMP)
    │
    ▼
migrate_init()                     // NONE → SETUP
    │
    ▼
migration_start_outgoing()         // 建立连接, 创建 migration_thread
    │
    ▼
migration_thread()
    │
    ├─► 发送头部 (MAGIC + VERSION)
    ├─► qemu_savevm_state_do_setup()
    │     └─► 每个设备 SECTION_START + save_setup
    │
    ├─► [主循环] while (migration_is_active())
    │     │
    │     ├─► migration_iteration_run()
    │     │     ├─► state_pending_estimate/exact
    │     │     ├─► 判断完成条件
    │     │     └─► qemu_savevm_state_iterate()
    │     │           └─► 每个设备 SECTION_PART + save_live_iterate
    │     │
    │     ├─► migration_detect_error()
    │     └─► migration_rate_limit()
    │
    ├─► migration_completion()
    │     ├─► 停止 VM
    │     ├─► qemu_savevm_state_complete_precopy()
    │     │     ├─► 可迭代设备 SECTION_END + save_complete
    │     │     ├─► 非迭代设备 SECTION_FULL
    │     │     └─► QEMU_VM_EOF + VMDESCRIPTION
    │     └─► state → COMPLETED
    │
    └─► migration_iteration_finish()
```

### 目的端同步流程

```
qmp_migrate_incoming() / -incoming
    │
    ▼
process_incoming_migration_co()   // 协程
    │
    ├─► qemu_loadvm_state()
    │     │
    │     ├─► qemu_loadvm_state_header()      // 验证魔数和版本
    │     ├─► qemu_loadvm_state_setup()        // 调用各设备 load_setup
    │     │
    │     └─► qemu_loadvm_state_main()         // 主加载循环
    │           │
    │           ├─► QEMU_VM_SECTION_START      // 从源端的 save_setup
    │           │     └─► qemu_loadvm_section_start_full()
    │           │           └─► 创建/初始化设备
    │           │
    │           ├─► QEMU_VM_SECTION_PART       // 从源端的 save_live_iterate
    │           │     └─► qemu_loadvm_section_part_end()
    │           │           └─► 加载迭代数据 (如 RAM 页)
    │           │
    │           ├─► QEMU_VM_SECTION_END        // 从源端的 save_complete
    │           │     └─► qemu_loadvm_section_part_end()
    │           │
    │           ├─► QEMU_VM_SECTION_FULL       // 非迭代设备
    │           │     └─► qemu_loadvm_section_start_full()
    │           │           └─► vmstate_load() 加载完整设备状态
    │           │
    │           ├─► QEMU_VM_COMMAND             // 命令
    │           │     └─► loadvm_process_command()
    │           │           ├─► MIG_CMD_OPEN_RETURN_PATH → 打开返回路径
    │           │           ├─► MIG_CMD_PING → 回复 PONG
    │           │           ├─► MIG_CMD_POSTCOPY_ADVISE → 初始化 postcopy
    │           │           ├─► MIG_CMD_POSTCOPY_LISTEN → 启动监听线程
    │           │           ├─► MIG_CMD_POSTCOPY_RUN → 启动 VM
    │           │           ├─► MIG_CMD_PACKAGED → 递归加载打包数据
    │           │           └─► MIG_CMD_POSTCOPY_RESUME → 恢复 postcopy
    │           │
    │           └─► QEMU_VM_EOF → 退出循环
    │
    ├─► process_incoming_migration_bh()         // BH 回调
    │     ├─► multifd_recv_shutdown()
    │     ├─► vm_start()                        // ★ 启动目的端 VM
    │     └─► state ACTIVE → COMPLETED
    │
    └─► migration_incoming_state_destroy()
```

### VM Stream 格式

#### 魔数和版本

```c
#define QEMU_VM_FILE_MAGIC    0x5145564d  // "QEVM"
#define QEMU_VM_FILE_VERSION  0x00000003
```

#### Section 类型 (`savevm.h`)

| 值 | 常量 | 含义 |
|----|------|------|
| 0x00 | `QEMU_VM_EOF` | 流结束 |
| 0x01 | `QEMU_VM_SECTION_START` | 可迭代设备 section 开始 (setup) |
| 0x02 | `QEMU_VM_SECTION_PART` | 可迭代设备 section 部分 (iterate) |
| 0x03 | `QEMU_VM_SECTION_END` | 可迭代设备 section 结束 (complete) |
| 0x04 | `QEMU_VM_SECTION_FULL` | 完整 section (非迭代设备) |
| 0x05 | `QEMU_VM_SUBSECTION` | 子 section |
| 0x06 | `QEMU_VM_VMDESCRIPTION` | JSON VM 描述 (在 EOF 后) |
| 0x07 | `QEMU_VM_CONFIGURATION` | 配置 section (在 header 后) |
| 0x08 | `QEMU_VM_COMMAND` | 命令包 |
| 0x7e | `QEMU_VM_SECTION_FOOTER` | Section 尾部校验 (可选) |

#### RAM 保存标志 (`ram.h`)

| 标志 | 值 | 含义 |
|------|-----|------|
| `RAM_SAVE_FLAG_ZERO` | 0x002 | 全零页 (不传内容) |
| `RAM_SAVE_FLAG_MEM_SIZE` | 0x004 | RAMBlock 元数据 |
| `RAM_SAVE_FLAG_PAGE` | 0x008 | 完整页数据 |
| `RAM_SAVE_FLAG_EOS` | 0x010 | RAM section 结束 |
| `RAM_SAVE_FLAG_CONTINUE` | 0x020 | 连续页 (省略 block id) |
| `RAM_SAVE_FLAG_XBZRLE` | 0x040 | XBZRLE 压缩页 |
| `RAM_SAVE_FLAG_HOOK` | 0x080 | RDMA hook |
| `RAM_SAVE_FLAG_MULTIFD_FLUSH` | 0x200 | Multifd 同步点 |

标志位编码在地址的低位中。地址为 `addr & TARGET_PAGE_MASK`，标志为 `addr & ~TARGET_PAGE_MASK`。由于最小页面大小为 1K (0x400)，标志位 0x001-0x3ff 不与地址冲突。

#### MIG_CMD_* 命令

| 命令 | 含义 | 阶段 |
|------|------|------|
| `MIG_CMD_OPEN_RETURN_PATH` | 打开返回路径 | Setup |
| `MIG_CMD_PING` | 请求 PONG 响应 | 测试 RTT |
| `MIG_CMD_POSTCOPY_ADVISE` | 通知可能切换到 postcopy | Setup |
| `MIG_CMD_POSTCOPY_LISTEN` | 开始 postcopy 监听 | 切换 |
| `MIG_CMD_POSTCOPY_RUN` | 目的端 VM 开始运行 | 切换 |
| `MIG_CMD_POSTCOPY_RAM_DISCARD` | 通知要丢弃的页面列表 | 切换 |
| `MIG_CMD_PACKAGED` | 封装的设备状态数据 | 切换 |
| `MIG_CMD_POSTCOPY_RESUME` | 恢复 postcopy | 恢复 |
| `MIG_CMD_RECV_BITMAP` | 请求目的端已接收页面位图 | 恢复 |
| `MIG_CMD_SWITCHOVER_START` | Switchover 开始通知 | 切换 |


## 返回路径通信 (Return Path)

目的端到源端的返回路径 (`migration.c`)，由源端的 `rp_thread` 处理:

| 消息类型 | 含义 |
|----------|------|
| `MIG_RP_MSG_PONG` | PING 的响应 (用于 RTT 测量) |
| `MIG_RP_MSG_REQ_PAGES` | Postcopy 页面请求 (指定哪些页需要) |
| `MIG_RP_MSG_RECV_BITMAP` | 目的端已接收页面位图 (用于恢复) |
| `MIG_RP_MSG_SWITCHOVER_ACK` | Switchover 确认 (目的端就绪后告知源端) |
| `MIG_RP_MSG_RESUME_ACK` | 恢复确认 (postcopy 恢复) |

### Switchover Ack 机制

某些设备 (如 VFIO) 在目的端需要异步初始化，通过 switchover ack 告知源端就绪:
1. 源端 `qemu_savevm_state_do_setup()` 后检查哪些设备需要 ack
2. 目的端设备 `load_setup` 中设置 `switchover_ack_needed`
3. 目的端准备好后调用 `switchover_start` 发送 `MIG_RP_MSG_SWITCHOVER_ACK`
4. 源端 `can_switchover()` 检查所有 ack 已收到 + 设备状态 `is_ready`
5. 只有所有 ack 收到后，源端才允许进入完成阶段


## 关键优化技术

| 技术 | 作用 | 关键文件 |
|------|------|----------|
| **Multifd** | 多通道并行传输 RAM 页面，每个通道独立压缩 | `multifd.c`, `multifd-nocomp.c` |
| **XBZRLE** | 增量压缩，对脏页做 XOR 后 RLE，减少重复数据传输 | `xbzrle.c` |
| **Postcopy Preemption** | 高优先级通道传输紧急页面，优先于正常 postcopy 页面请求 | `postcopy-ram.c` |
| **Auto-converge** | 检测脏页速率超过传输速率时，CPU 节流减缓脏页产生 | `cpu-throttle.c` |
| **Zero Page Detection** | 检测全零页，仅发送标志不发送数据 | `ram.c:save_zero_page()` |
| **RDMA** | 使用 RDMA 进行零拷贝传输 | `rdma.c` |
| **Mapped-ram** | 直接映射 RAM 到文件，避免序列化 | `ram.c` mapped-ram 路径 |

### Multifd 同步模式

- **per-section** (legacy): 每个 `RAM_SAVE_FLAG_EOS` 后执行全通道 SYNC
- **per-round** (modern): 每完整扫描一轮所有 RAMBlock 后执行一次 SYNC，效率更高


## 流程总览

```
+-----------------------------------------------+
|                  SOURCE                       |
|                                               |
|  NONE -> SETUP -> ACTIVE -> DEVICE            |
|              |        |  ^     |  ^           |
|              v        |  |     |  |           |
|           FAILING     |  +-----+  +-postcopy  |
|                       |  WAIT_     |          |
|                       |  UNPLUG    v          |
|                       |       POSTCOPY_DEVICE |
|                       +-postcopy     |        |
|                       |  (no RP)     v        |
|                       v       POSTCOPY_ACTIVE |
|                  POSTCOPY        |            |
|                  _ACTIVE         v            |
|                     |        COMPLETED        |
|                     v                         |
|                 COMPLETED                     |
|                                               |
|  precopy path:  ACTIVE -> DEVICE -> COMPLETED |
+-----------------------------------------------+
                        |
                        | QEMUFile
                        v
+----------------------------------------------+
|                DESTINATION                   |
|                                              |
|  recv_header -> device_setup                 |
|                     |                        |
|                     v                        |
|               main_load_loop                 |
|                     |                        |
|                     v                        |
|                vm_start() -> COMPLETED       |
|                                              |
|  [Postcopy]:                                 |
|  POSTCOPY_LISTEN -> listen_thread            |
|  POSTCOPY_RUN -> vm_start()                  |
|  page_fault <--> return_path                 |
+----------------------------------------------+
```


## 参考文件

- `migration/migration.c` — 迁移主逻辑，状态机，migration_thread，速率限制
- `migration/ram.c` — RAM 迁移，脏页位图，页面搜索和发送
- `migration/ram.h` — RAM 标志位 (RAM_SAVE_FLAG_*)
- `migration/savevm.c` — VM 状态保存/加载，SaveStateEntry，流格式
- `migration/savevm.h` — Section 类型常量 (QEMU_VM_*)
- `migration/postcopy-ram.c` — Postcopy 源端/目的端，缺页处理
- `migration/postcopy-ram.h` — Postcopy 状态机
- `migration/multifd.c` / `multifd.h` — 多通道传输
- `migration/multifd-nocomp.c` — Multifd RAM 页传输
- `migration/qemu-file.c` / `qemu-file.h` — QEMUFile 抽象
- `migration/migration-stats.c` — 统计信息
- `migration/xbzrle.c` — XBZRLE 压缩
- `migration/cpu-throttle.c` — 自动收敛 CPU 节流
- `migration/rdma.c` — RDMA 加速
- `include/migration/register.h` — SaveVMHandlers 接口
- `docs/devel/migration.rst` — 官方开发文档
