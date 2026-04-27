QEMU 热迁移流程分析
=====================

-v0.1 2025.04.25 Sherlock init

本文档分析 QEMU 热迁移 (live migration) 的完整流程，包括迁移状态机、各阶段实现、核心数据结构及源端/目的端交互。基于 QEMU 源码分析。


## 核心文件

| 文件 | 功能 |
|------|------|
| `migration/migration.c` | 迁移主逻辑，状态机，迁移线程 |
| `migration/migration.h` | MigrationState/MigrationIncomingState 定义 |
| `migration/ram.c` | RAM 迁移，脏页追踪和传输 |
| `migration/savevm.c` | VM 状态保存/加载，设备序列化 |
| `migration/qemu-file.c` | 迁移数据流抽象层 |
| `migration/postcopy-ram.c` | Postcopy 迁移实现 |
| `migration/multifd.c` | 多通道并行传输 |
| `include/migration/register.h` | SaveVMHandlers 设备注册接口 |


## 核心数据结构

### MigrationState (源端)

```c
struct MigrationState {
    QemuThread thread;              // 迁移主线程
    QEMUFile *to_dst_file;          // 发送到目的端的流
    MigrationStatus state;          // 当前迁移状态
    int64_t downtime;               // 总停机时间
    uint64_t threshold_size;        // 切换阈值
    bool start_postcopy;            // 是否启用 postcopy
    // Return path
    QEMUFile *from_dst_file;        // 从目的端接收的流
    QemuThread rp_thread;           // 返回路径线程
};
```

### MigrationIncomingState (目的端)

```c
struct MigrationIncomingState {
    QEMUFile *from_src_file;        // 从源端接收的流
    QEMUFile *to_src_file;          // 发送到源端的流
    int userfault_fd;               // Postcopy 缺页处理 fd
    QemuThread fault_thread;        // 缺页处理线程
    GTree *page_requested;          // 请求的页面树
};
```

### SaveVMHandlers (设备迁移接口)

```c
typedef struct SaveVMHandlers {
    // Setup 阶段
    int (*save_setup)(QEMUFile *f, void *opaque, Error **errp);
    int (*load_setup)(QEMUFile *f, void *opaque, Error **errp);

    // 迭代阶段
    int (*save_live_iterate)(QEMUFile *f, void *opaque);
    void (*state_pending_estimate)(void *opaque, uint64_t *must_precopy,
                                   uint64_t *can_postcopy);

    // 完成阶段
    int (*save_complete)(QEMUFile *f, void *opaque);

    // 加载
    int (*load_state)(QEMUFile *f, void *opaque, int version_id);
} SaveVMHandlers;
```

设备通过 `register_savevm_live()` 注册这些回调。


## 迁移状态机

### 状态定义

```c
MIGRATION_STATUS_NONE              // 初始状态
MIGRATION_STATUS_SETUP             // 建立连接
MIGRATION_STATUS_ACTIVE            // 迭代传输中
MIGRATION_STATUS_POSTCOPY_ACTIVE   // Postcopy 模式运行
MIGRATION_STATUS_DEVICE            // 设备状态传输
MIGRATION_STATUS_COMPLETED         // 完成
MIGRATION_STATUS_FAILED            // 失败
```

### 状态转换

```
NONE ──► SETUP ──► ACTIVE ──► [POSTCOPY_ACTIVE] ──► DEVICE ──► COMPLETED
                            │           │
                            │           ▼
                            │    POSTCOPY_PAUSED
                            │           │
                            ▼           ▼
                         FAILED ◄───────┘
```


## 迁移阶段详解

### Setup 阶段

入口: `migration_thread()` (migration/migration.c:3492)

```
migration_thread()
    │
    ├─► multifd_send_setup()           // 多通道初始化
    │
    ├─► qemu_savevm_state_header()     // 发送头部 (magic: "QEVM")
    │
    ├─► qemu_savevm_send_open_return_path()  // 打开返回路径
    │
    ├─► qemu_savevm_send_postcopy_advise()   // Postcopy 协商 (可选)
    │
    ├─► qemu_savevm_state_do_setup()   // 设备 save_setup
    │
    └─► 等待设备 unplug 完成
```

### Iterative Copy 阶段

核心: `migration_iteration_run()` (migration/migration.c:3205)

```
migration_iteration_run()
    │
    ├─► qemu_savevm_state_pending_estimate()  // 估算待传输量
    │
    ├─► qemu_savevm_state_pending_exact()     // 精确计算
    │
    ├─► 判断切换 postcopy?
    │     └─► postcopy_start()
    │
    ├─► 判断可以完成?
    │     └─► migration_completion()
    │
    └─► qemu_savevm_state_iterate()   // 迭代传输
          └─► ram_save_iterate()
                └─► ram_find_and_save_block()  // 查找脏页
```

脏页传输逻辑 (`ram_save_iterate()`):

```c
static int ram_save_iterate(QEMUFile *f, void *opaque)
{
    while (true) {
        pages = ram_find_and_save_block(rs);  // 查找脏页并发送
        if (!pages) {
            break;  // 没有更多脏页
        }
    }
    qemu_fflush(f);
}
```

### Stop-and-Copy 阶段

入口: `migration_completion_precopy()` (migration/migration.c:2743)

```
migration_completion_precopy()
    │
    ├─► migration_stop_vm()            // 停止 VM (RUN_STATE_FINISH_MIGRATE)
    │
    ├─► migration_switchover_start()   // 开始切换
    │
    └─► qemu_savevm_state_complete_precopy()
          ├─► 保存可迭代设备最终状态
          ├─► 保存非可迭代设备状态
          └─► 发送 QEMU_VM_EOF
```

### Postcopy 阶段

入口: `postcopy_start()` (migration/migration.c:2464)

```
postcopy_start()
    │
    ├─► postcopy_preempt_establish_channel()  // 建立 preempt 通道 (可选)
    │
    ├─► qemu_savevm_state_postcopy_prepare()
    │
    ├─► migration_stop_vm()            // 停止 VM
    │
    ├─► qemu_savevm_state_complete_precopy_iterable()  // 非 postcopy 设备
    │
    ├─► ram_postcopy_send_discard_bitmap()  // 发送 discard bitmap
    │
    ├─► qemu_savevm_send_postcopy_listen()  // 发送 LISTEN 命令
    │
    ├─► qemu_savevm_state_non_iterable()    // 非迭代状态
    │
    └─► qemu_savevm_send_postcopy_run()     // 发送 RUN 命令
```


## 源端/目的端交互

### 源端流程

```
用户请求
    │
    ▼
migrate_init()
    │
    ▼
migration_start_outgoing()
    │
    ▼
migration_thread() ──────────────────────────────────────────┐
    │                                                        │
    ├─► 发送头部                                             │
    ├─► 设备 save_setup                                      │
    │                                                        │
    ├─► [迭代循环]                                           │
    │     ├─► 估算待传输量                                    │
    │     ├─► 迭代传输脏页                                    │
    │     └─► 速率限制                                        │
    │                                                        │
    ├─► 停止 VM                                              │
    ├─► 完成状态保存                                          │
    │                                                        │
    ▼                                                        │
完成                                                         │
```

### 目的端流程

```
qmp_migrate_incoming()
    │
    ▼
process_incoming_migration_co()
    │
    ├─► qemu_loadvm_state_header()    // 加载头部
    │
    ├─► qemu_loadvm_state_setup()     // 设置加载
    │
    ├─► qemu_loadvm_state_main()      // 主加载循环
    │     │
    │     ├─► SECTION_START/FULL      // 设备初始化
    │     ├─► SECTION_PART/END        // 设备状态
    │     ├─► COMMAND
    │     │     ├─► POSTCOPY_ADVISE
    │     │     ├─► POSTCOPY_LISTEN
    │     │     └─► POSTCOPY_RUN
    │     └─► EOF
    │
    └─► vm_start()                    // 启动 VM
```


## 返回路径通信

目的端到源端的返回路径用于:
- PONG 响应
- 请求页面 (REQ_PAGES)
- Switchover 确认 (SWITCHOVER_ACK)

```c
enum mig_rp_message_type {
    MIG_RP_MSG_PONG,           // PING 响应
    MIG_RP_MSG_REQ_PAGES,      // 请求页面
    MIG_RP_MSG_RECV_BITMAP,    // 接收位图
    MIG_RP_MSG_SWITCHOVER_ACK, // Switchover 确认
    MIG_RP_MSG_RESUME_ACK,     // 恢复确认
};
```


## VM Stream 格式

### 魔数和版本

```c
#define QEMU_VM_FILE_MAGIC    0x5145564d  // "QEVM"
#define QEMU_VM_FILE_VERSION  0x00000003
```

### Section 类型

```c
#define QEMU_VM_EOF           0x00  // 结束
#define QEMU_VM_SECTION_START 0x01  // 设备 section 开始
#define QEMU_VM_SECTION_PART  0x02  // section 部分
#define QEMU_VM_SECTION_END   0x03  // section 结束
#define QEMU_VM_SECTION_FULL  0x04  // 完整 section
#define QEMU_VM_SUBSECTION    0x05  // 子 section
#define QEMU_VM_COMMAND       0x08  // 命令
```

### RAM 保存标志

```c
#define RAM_SAVE_FLAG_ZERO    0x002  // 零页
#define RAM_SAVE_FLAG_MEM_SIZE 0x004 // 内存大小
#define RAM_SAVE_FLAG_PAGE    0x008  // 单页
#define RAM_SAVE_FLAG_EOS     0x010  // 结束
#define RAM_SAVE_FLAG_XBZRLE  0x040  // XBZRLE 压缩
```


## 关键优化技术

| 技术 | 作用 | 文件 |
|------|------|------|
| Multifd | 多通道并行传输 RAM | `migration/multifd.c` |
| XBZRLE | 增量压缩，减少重复数据 | `migration/xbzrle.c` |
| Postcopy Preemption | 高优先级通道传输紧急页面 | `migration/postcopy-ram.c` |
| Auto-converge | CPU 节流控制脏页生成速率 | `migration/cpu-throttle.c` |


## 流程总览

```
┌────────────────────────────────────────────────────────────┐
│                      源端 (Source)                         │
│                                                            │
│  SETUP ──► ACTIVE (迭代) ──► DEVICE ──► COMPLETED          │
│               │                                            │
│               ▼                                            │
│          [Postcopy]                                        │
│               │                                            │
│               ▼                                            │
│        POSTCOPY_ACTIVE                                     │
└────────────────────────────────────────────────────────────┘
                         │
                         ▼ 网络传输
┌────────────────────────────────────────────────────────────┐
│                    目的端 (Destination)                     │
│                                                            │
│  接收头部 ──► 设备初始化 ──► 加载RAM ──► 加载状态 ──► 启动VM │
│                                               │             │
│                                      [Postcopy]             │
│                                               ▼             │
│                                        按需拉取页面          │
└────────────────────────────────────────────────────────────┘
```


## 参考文件

- `migration/migration.c` - 迁移主逻辑
- `migration/ram.c` - RAM 迁移实现
- `migration/savevm.c` - 状态保存/加载
- `docs/devel/migration.rst` - 官方开发文档
