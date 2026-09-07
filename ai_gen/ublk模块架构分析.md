# ublk 模块架构分析

> 整理日期：2026-09-07
> 分析基础：本仓库 v7.2-rc5 源码（`drivers/block/ublk_drv.c`，约 5926 行；`include/uapi/linux/ublk_cmd.h`，826 行）+ git 历史考证（v6.0 → v7.2）
> 背景：AgentENV 依赖 ublk 且要求内核 ≥ 6.8，本文覆盖架构全貌 + 版本演进与性能补丁考证

---

## 目录

1. [定位与零基础背景](#1-定位与零基础背景)
2. [三个用户可见设备](#2-三个用户可见设备)
3. [核心数据结构](#3-核心数据结构)
4. [生命周期（控制面）](#4-生命周期控制面)
5. [数据面：一次 IO 的完整旅程](#5-数据面一次-io-的完整旅程)
6. [数据传输模式（零拷贝演进）](#6-数据传输模式零拷贝演进)
7. [共享内存布局与 mmap](#7-共享内存布局与-mmap)
8. [io_uring 的创建时机与线程绑定](#8-io_uring-的创建时机与线程绑定)
9. [取消 / 恢复 / Quiesce](#9-取消--恢复--quiesce)
10. [关键设计取舍](#10-关键设计取舍)
11. [版本演进与性能补丁考证](#11-版本演进与性能补丁考证)
12. [附：零基础类比讲解](#12-附零基础类比讲解)

---

## 1. 定位与零基础背景

### 1.1 什么是块设备

块设备就是磁盘/SSD 这类设备，数据按固定大小的块（扇区）读写。`/dev/nvme0n1`、`/dev/sda` 都是块设备，mkfs、mount、swap 全部建立在它上面。内核里用块设备只有一种方式：发"从第 X 扇区开始读/写 N 个扇区"这样的请求。

传统块设备驱动（比如 nvme 驱动）的工作就是：收到请求 → 操作硬件 → 硬件完成 → 报告"做完了"。

### 1.2 ublk 的核心想法

**把"操作硬件"这一步，换成"把请求交给用户态的一个程序去处理"。**

为什么要这样？因为很多人爱把存储引擎写在用户态（好写、好调试、迭代快），但他们希望这个引擎对外仍然表现为一个标准块设备，内核的 mount、swap、cgroup 都能正常用。ublk 就是干这个的框架（Ming Lei，2022 年合入 6.0，代号 userspace block device）。

内核只干两件事：**接单**（把请求翻译好写进共享内存）和**销单**（用户态说做完了，内核向上层报告完成）。存储逻辑一点不碰。

```
   上层（文件系统、swap……）
        │  读/写请求
        ▼
 ┌──────────────────────────┐
 │ /dev/ublkbN  块设备       │   普通块设备，上层完全无感
 │  blk-mq（内核的排队框架）  │
 └────────────┬─────────────┘
              │ 把请求填进一块共享内存的"槽位"
              ▼
 ┌──────────────────────────┐
 │ io_uring 共享队列         │   内核和用户态之间的"信箱"
 └────────────┬─────────────┘
              │ 用户态程序拿走请求
              ▼
 ┌──────────────────────────┐
 │ ublksrv（用户态 daemon）  │   真正的存储引擎：
 │ 想怎么处理就怎么处理       │   读本地文件 / 发网络 / 内存模拟……
 └──────────────────────────┘
```

---

## 2. 三个用户可见设备

一个 ublk 设备 = 1 个字符设备 + 1 个块设备（"device pair"），共享同一个编号 N，由 `struct ublk_device` 统一管理。

| 设备 | 类型 | 用途 | 使用者 |
|---|---|---|---|
| `/dev/ublk-control` | misc 设备（全局唯一） | 控制命令 | ublksrv 管理线程 |
| `/dev/ublkcN` | 字符设备（每设备一个 cdev） | 数据面通道 | ublksrv IO 线程 |
| `/dev/ublkbN` | 块设备（gendisk） | 对外交付的产品 | 任何人（mkfs/mount/dd/fio/LVM/md……） |

一个很好用的观察视角：`/dev/ublkcN` 的生命周期代表**"服务是否在岗"**，`/dev/ublkbN` 的生命周期代表**"产品是否上架"**。recovery/quiesce 机制本质上就是在"服务暂时离岗"和"产品不下架"之间做文章。

### 2.1 `/dev/ublk-control` —— 管理台

- 全局只有一个，由 ublksrv 的**管理线程**使用，IO 线程不碰它。
- 通过 io_uring 的自定义命令（uring_cmd，要求 SQE128 编码）发送控制命令。
- 常用命令：

| 命令 | 作用 |
|---|---|
| `ADD_DEV` | 创建一对设备，内核分配编号 N，`/dev/ublkcN` 出现。传入特性 flag，内核清除不支持的 flag 后回传 = **能力协商** |
| `SET_PARAMS` | 告诉内核盘长什么样：容量、扇区大小、discard 支持等 |
| `START_DEV` | 让块设备上线（等待所有 FETCH_REQ 挂齐） |
| `STOP_DEV` / `DEL_DEV` | 下线 / 拆除（另有 `DEL_DEV_ASYNC`、`TRY_STOP_DEV`） |
| `QUIESCE_DEV` | 冻结设备，用于在线升级 daemon |
| `UPDATE_SIZE` | 运行时改容量 |
| `REG_BUF` / `UNREG_BUF` | SHMEM_ZC 模式注册/注销共享缓冲 |
| `START/END_USER_RECOVERY` | 恢复流程 |

- 权限模型：默认需要 `CAP_SYS_ADMIN`；声明"非特权设备"（`UBLK_F_UNPRIVILEGED_DEV`）后普通用户也能建，之后所有命令只有**属主**能发。非特权设备上限 `ublks_max` 可调（默认 64）。

### 2.2 `/dev/ublkcN` —— 车间窗口（数据面通道）

由 **ublksrv 的 IO 线程**专用，四种用法：

**① open —— 签到**

一次只能一个进程打开（第二个打开 `-EBUSY`）。open 记录进程 tgid，从此内核知道"daemon 活着"。进程死了/fd 关了，内核异步走回收流程——按 recovery 设置决定设备拆除还是假死保留。**这个 fd 本身就是一个心跳信号**。

**② mmap —— 共享白板**

把每个队列的请求描述区（io_cmd_buf）mmap 到 daemon 地址空间，**只读**（VM_WRITE 直接 `-EPERM`）。mmap 的 offset 编码队列号，N 个队列 mmap N 次。内核把请求描述直接写在这块内存里，daemon 轮询读取，零系统调用。

**③ io_uring 命令 —— 接单/交单**

- `FETCH_REQ` —— 预挂空单（启动时每个槽位挂一张）
- `COMMIT_AND_FETCH_REQ` —— "这个 IO 做完了" + 顺手挂下一张空单
- `REGISTER_IO_BUF` / `UNREGISTER_IO_BUF` —— 零拷贝模式下把内核内存页登记成 io_uring 固定缓冲
- 批量版本（`UBLK_F_BATCH_IO`）：`PREP_IO_CMDS` / `COMMIT_IO_CMDS` / `FETCH_IO_CMDS`（multishot），一次收发最多 128 个 tag

**④ pread/pwrite —— USER_COPY 模式下的数据搬运**

daemon 用 `pread`/`pwrite` 在 `/dev/ublkcN` 上自行搬数据。文件位置是编码：**队列号 | tag | 缓冲内偏移**，第 62 位兼作 integrity 标志。方向：写请求的数据用 pread 取走；读请求的结果用 pwrite 喂回。

### 2.3 `/dev/ublkbN` —— 客户门店

- **最后才出现**：ADD_DEV 只产生 `/dev/ublkcN`；要等 daemon 挂齐所有 FETCH 单、`START_DEV` 下发，内核才让它现身。保证块设备一亮相，数据通路就是通的。
- 谁都能用，跟真实磁盘无差别：

```
mkfs.ext4 /dev/ublkb0     ← 格式化
mount /dev/ublkb0 /mnt    ← 挂载
dd if=... of=/dev/ublkb0  ← 直接读写
```

- 自动做**分区扫描**（扫出 `/dev/ublkb0p1` 等），但被故意放到异步 workqueue 里做，防止 daemon 出问题时死锁；非特权设备永久禁用扫描；`UBLK_F_NO_AUTO_PART_SCAN` 可关。
- 行为由 `SET_PARAMS` 决定：只读、rotational、volatile cache/FUA、discard、zoned、integrity 等。

---

## 3. 核心数据结构

位置：`drivers/block/ublk_drv.c:206-346`

```
ublk_device                       ublk_queue (每 hw queue 一个)
 ├─ gendisk *ub_disk              ├─ io_cmd_buf[]      ← 每 tag 一个 ublksrv_io_desc
 ├─ blk_mq_tag_set                ├─ ios[] (q_depth)   ← struct ublk_io 数组
 ├─ cdev + cdev_dev               ├─ evts_fifo (batch) ← 待派发 tag 的 kfifo
 ├─ mm (daemon mm 绑定)           └─ flags
 ├─ params / dev_info / state
 └─ buf_tree (maple tree) ← SHMEM_ZC 专用

ublk_io (IO slot，与 request tag 1:1)      ublksrv_io_desc (共享内存里)
 ├─ buf.addr (daemon 数据缓冲地址)          ├─ op_flags / nr_sectors
 ├─ flags: ACTIVE / OWNED_BY_SRV /         ├─ start_sector
 │        NEED_GET_DATA / CANCELED         └─ addr
 ├─ cmd ↔ req (同一 union，按状态切换)
 ├─ task (负责该 slot 的 daemon task)
 └─ ref (refcount，zero-copy 生命周期)
```

**最核心的抽象是 "IO slot"**：tag 空间（≤4096/queue，`UBLK_MAX_QUEUE_DEPTH`）同时是 blk-mq 的 request tag、io_cmd_buf 数组下标、`ublk_io` 数组下标。三者一一对应，所以内核/用户态双方都用 `(q_id, tag)` 唯一寻址一个 in-flight IO，不需要任何 ID 翻译。

---

## 4. 生命周期（控制面）

```
ADD_DEV (ublk_ctrl_add_dev:4635)
  → 校验 flags 组合（recovery/quiesce/unprivileged 互斥约束:4662-4702）
  → 分配 dev number、建 tag_set、init_queues
  → 注册 /dev/ublkcN（此时 ub 处于 DEAD 态）
  → 把裁剪后的 flags 拷回用户态 = feature negotiation (:4760)
        ↓
daemon: open /dev/ublkcN → mmap io_cmd_buf → 对每个 slot 发 FETCH_REQ
        ↓
SET_PARAMS (queue_limits 用) → START_DEV (ublk_ctrl_start_dev:4420)
  → wait_for_completion 等所有 FETCH_REQ 就绪 (:4502)
  → blk_mq_alloc_disk + add_disk → /dev/ublkbN 出现，状态 LIVE
        ↓
运行期：STOP/DEL、UPDATE_SIZE、QUIESCE（升级 daemon）、RECOVERY
```

**关键设计：FETCH_REQ 必须在 START_DEV 之前全部预提交**——每个 io slot 预先挂一个等待中的 uring_cmd，`nr_queue_ready == nr_hw_queues * q_depth` 才允许 add_disk（`ublk_mark_io_ready:3029`）。所以队列深度 = daemon 预先 fetch 的 cmd 数，这保证了任何时刻到手的 request 总有一个可复用的 uring_cmd 立即通知 daemon，把"唤醒用户态"的延迟摊掉。

---

## 5. 数据面：一次 IO 的完整旅程

### 5.1 下发路径（内核 → daemon）

1. blk-mq 调 `ublk_queue_rq` (`:2203`) → `ublk_prep_req` 检查 fail_io/force_abort/canceling 后 `ublk_setup_iod` 把 request 翻译进共享内存的 `io_desc`（op/sector/扇区数/缓冲地址）；
2. `ublk_queue_cmd` (`:2082`) 调 **`io_uring_cmd_complete_in_task`**——把 slot 上预挂的 uring_cmd 通过 **task_work** 投递到 daemon task 上下文（`io->task`，FETCH 时记录 `:3282`），然后给 cqe；
3. daemon 从 cqe 拿到 tag → 读 mmap 的 io_desc → 用自己的引擎处理 IO。

`queue_rqs`（批量提交路径 `:2256`）会把属于同一 daemon task 的请求串成链表，一次 task_work 批量 dispatch（`ublk_cmd_list_tw_cb:2091`）。

### 5.2 完成路径（daemon → 内核）

daemon 发 `COMMIT_AND_FETCH_REQ`（commit 与下一个 fetch piggyback，`ublk_ch_uring_cmd_local:3445`）→ 校验 io->task == current（slot 只能由它的 daemon 处理）→ `io->res = result` → `__ublk_complete_rq` (`:1550`)：对 READ 先把用户缓冲数据 `ublk_unmap_io` 拷回 bio pages（支持 partial completion 走 `blk_update_request`/requeue），然后 `blk_mq_end_request`。同一 cmd 又被重新 ACTIVE 挂回去等下一个请求。

### 5.3 IO slot 状态机（`ublk_drv.c:160-189`）

```
ACTIVE（cmd 挂在槽上等 request）
  → dispatch 后清 ACTIVE、置 OWNED_BY_SRV（cqe 已交付 daemon）
  → commit 时再回到 ACTIVE
NEED_GET_DATA 是中间态（内核先只发 cqe，等 daemon 回缓冲地址）
AUTO_BUF_REG（自动注册了 io_uring 固定缓冲，完成前需注销）
CANCELED（bit31，与 cancel_lock 配合的原子 RW）
```

---

## 6. 数据传输模式（零拷贝演进）

这是 ublk 架构里最有内容的部分：

| 模式 | 机制 | 拷贝次数 |
|---|---|---|
| 默认 | dispatch 时内核把 WRITE 数据拷入 daemon 缓冲（`ublk_map_io:1461`，GUP pin daemon 页后拷贝），READ 完成时拷回 | 2 次 |
| `NEED_GET_DATA` | 内核先只发 cqe，daemon 回 `NEED_GET_DATA` 带缓冲地址，内核再拷数据——省去 FETCH 时提前提供地址的约束 | 2 次 |
| `USER_COPY` | daemon 用 `pread/pwrite /dev/ublkcN` 自行搬运，pos 编码 `(q_id, tag, offset)`（`ublk_pos_to_*:868`），内核侧 `ublk_user_copy:4050` | 2 次，但脱离 daemon task 限制（配 `refcount` 保护 request 生命周期，`__ublk_check_and_get_req:3490`） |
| `ZERO_COPY` | daemon 把 request 的 bio pages 注册成 io_uring fixed buffer（`ublk_register_io_buf:3181`），后续存储引擎 IO 直接吃 request 内存 | **0 次** |
| `AUTO_BUF_REG` | 内核在 dispatch 时自动完成上述注册，省掉两条 uring_cmd | 0 次 |
| `SHMEM_ZC` | 用户注册 memfd/hugetlbfs 共享缓冲，内核 `pin_user_pages` 后把 **PFN 区间插进 maple tree**（`__ublk_ctrl_reg_buf:5337`）；dispatch 时按 request page 的 PFN 查树命中（`ublk_try_buf_match:5578`），命中则直接告诉 daemon"数据就在你映射的 buffer 的 offset 处" | 0 次 |

**BATCH_IO**（`UBLK_F_BATCH_IO`，v7.0）是正交的优化：不逐个 slot 发 cqe，而是 tag 进 `evts_fifo`，由 multishot `FETCH_IO_CMDS` 把最多 128 个 tag 批量拷给 daemon（`__ublk_batch_dispatch:1922`），commit 也批量（`ublk_handle_batch_commit_cmd:3809`，部分成功按返回字节数回退）。为此有独立的 `ublk_batch_mq_ops`（多了 `commit_rqs`，`ublk_drv.c:2352`）和 fops。批量状态机见 `ublk_drv.c:265-285` 注释（IDLE/READY/ACTIVE，单 active_fcmd 读者 + evts_lock）。

---

## 7. 共享内存布局与 mmap

`ublk_ch_mmap:2634`：daemon 以**只读**方式 mmap 每队列的 `io_cmd_buf`（`alloc_pages` 连续物理页，NUMA 上按该队列 CPU 亲和选 node，`ublk_init_queue:4208`，亲和由 `ublk_get_queue_numa_node:4195` 从 tag_set mq_map 反推）。地址空间按 UAPI 常量编码：

```
offset 0         ← 预留给 ctrl cmd 缓冲（UBLKSRV_CMD_BUF_OFFSET）
0x80000000 (UBLKSRV_IO_BUF_OFFSET) ← io_cmd_buf 区：
    q_id << 41 | tag << 25 | buf_off << 0   (UBLKSRV_IO_BUF_TOTAL_BITS=53)
bit62 ← USER_COPY 时 pread/pwrite pos 的 integrity 标志
```

UAPI 常量（`include/uapi/linux/ublk_cmd.h:175-199`）：tag 16bit（每队列最多 4096 IO，实际受 q_depth 限）、q_id 12bit（最多 4096 队列）、单 IO 缓冲偏移 25bit（最大 32MB）。

---

## 8. io_uring 的创建时机与线程绑定

**io_uring 全部由用户态（ublksrv）创建，内核驱动从不创建它**，只是通过 uring_cmd 这个钩子"搭上"用户态建好的环。

两个时机、两类环：

```
ublksrv 启动
  ├─ 管理线程: io_uring_setup() ① ──► 控制环（发 ADD_DEV/SET_PARAMS）
  ├─ ADD_DEV 返回 dev_id，/dev/ublkcN 出现
  ├─ 每队列线程: io_uring_setup() ②③④… ──► 数据环 + mmap + 预挂 FETCH
  ├─ START_DEV：等所有 FETCH 到位 ──► /dev/ublkbN 上架
  └─ 运行期：IO 线程蹲自己的 CQ 环轮询接单，内核经 task_work 把单投进对应线程的环
```

8 队列设备 = 1 + 8 = 9 个 io_uring。

**时序是硬约束**：队列的数据环必须赶在 START_DEV 之前建好并挂满单。

**线程绑定关系**（跟 KVM 里 vcpu 线程亲和类似）：
1. daemon 发 FETCH_REQ 时，内核记录 `io->task = current`——谁发的 FETCH，这个槽位以后就归谁；
2. 有请求来了，内核不是随便唤醒一个线程，而是把槽位预挂的 uring_cmd 以 **task_work** 形式投递到当初那个 task 上（`io_uring_cmd_complete_in_task`）；
3. 所以每个队列的 io_uring 天然绑定在服务它的那个线程上。

好处：**请求投递无锁**（一个槽位永远只有一个 task 碰）、daemon 侧每线程只蹲自己的环，无跨线程同步。

`UBLK_F_PER_IO_DAEMON`（v6.17）把绑定再推一级：一个 (队列, 槽位) 一个线程。零拷贝的 buffer 注册要求发生在 FETCH 所在的那个环上（内核校验环归属，`ublk_belong_to_same_batch:2235` 校验 ctx_handle + task）。

---

## 9. 取消 / 恢复 / Quiesce

- **取消**：daemon task 退出时 `ublk_ch_release:2618` 只调度 `exit_work`，异步做：等 refcount 归零 → 设 `canceling`（防新 IO 挂死）→ abort 所有 in-flight → 按 recovery flags 决定去向。
- **三种恢复形态**（`ublk_drv.c:94-96` + state 机 `UBLK_S_DEV_*`）：

| flags | daemon 退出后行为 |
|---|---|
| 无 recovery | 拆设备 |
| `USER_RECOVERY` | 设备 quiesce 保留等 daemon 重启，in-flight IO 报错 |
| `USER_RECOVERY_REISSUE` | 同上，但 in-flight IO 重发 |
| `USER_RECOVERY_FAIL_IO` | 后续 IO 快速失败 |

- `UBLK_F_QUIESCE`（要求 USER_RECOVERY）支持"升级 daemon 期间设备不中断"。
- **timeout**（`ublk_timeout:2116`）：非特权设备不信任，直接 SIGKILL daemon 而不是等。
- 退出清理的难点：zero-copy 注册的缓冲要等 io_uring 上下文释放时才注销，`ublk_ch_release_work_fn:2516` 里用 delayed_work 轮询 active ref 归零。

---

## 10. 关键设计取舍

1. **task_work 是主调度机制**：request 的派发、fetch/commit 的处理都经 `io_uring_cmd_complete_in_task` 收敛到 daemon task——锁从 blk-mq 软中断上下文挪走，且天然绑定 io_uring 上下文生命周期，规避 UAF（`ublk_dispatch_req` 里对 task 退出/切换的检查 `:1788`）。
2. **锁序**：`ub->mutex`（大锁，控制面）在外、`cancel_mutex`、queue `evts_lock`、per-io `lock` 在内；commit 路径无锁读 evts_fifo 靠严格单读者保证（active_fcmd）。
3. **tag=slot=desc 三位一体** 让整个协议没有内存分配热路径，`io_desc` 直接写共享内存，daemon 零系统调用读请求。
4. **非特权设备**（`UBLK_F_UNPRIVILEGED_DEV`）：uid/gid 属主化 + 禁 zero-copy/USER_COPY（防未初始化内存泄漏）+ 禁 recovery（防恶意 daemon 挂死设备）。
5. **分区扫描延迟到 workqueue**（`ublk_partition_scan_work:2444`）：避免 daemon 出错时 partition scan 的 IO 持锁死等造成死锁。

---

## 11. 版本演进与性能补丁考证

（以下全部经 `git log` / `git describe --contains` 考证，基于本仓库历史）

### 11.1 时间线（v6.0 → v7.2）

| 版本 | 关键提交 | 内容 | 性质 |
|---|---|---|---|
| v6.0 | `71f28f3136af` | ublk 初始合入（io_uring 驱动用户态块设备） | 功能 |
| v6.1 | `c732a852b419` `a0d41dc11374` `77a440e2cbb4` | USER_RECOVERY / REISSUE | 功能 |
| v6.3 | `4093cb5a0634` | 非特权设备（`UBLK_F_UNPRIVILEGED_DEV`） | 功能/安全 |
| v6.4 | `2d786e66c966` | 切换到 ioctl 命令编码（`UBLK_F_CMD_IOCTL_ENCODE`） | 协议 |
| v6.5 | `1172d5b8beca` `62fe99cef94a` `38f2dd34410f` `8284066946e6` `29dc5d06613f` | **USER_COPY 系列**：字符设备 read/write、任意部分页拷贝、request 引用计数保护 | 功能+数据通路 |
| v6.6 | `29802d7ca33b` `851e06297f20` | zoned 支持（含 ZONE_RESET_ALL） | 功能 |
| v6.7 | `3421c7f68bba` 等（见 11.2） | **★ io cmd 提交者 task 化系列** | **性能分水岭** |
| v6.8 | （无 ublk 提交） | 仅跨树重构碰文件：`d73e93b4dfab` disk_set_zoned 简化、`7437bb73f087` 移除 host-aware zone、`b66509b8497f` io_uring cmd api 头拆分、iov_iter `import_ubuf` 替换 | — |
| v6.9 | `eaf4a9b19b99` | **★ 去除 segment 数量/大小限制** | **吞吐** |
| v6.15 | `1f6540e2aabb` | 真正的零拷贝（zc register/unregister bvec） | 性能 |
| v6.17 | `763ff02ce287` `81b4d1a1d033` | off-daemon 缓冲注册、PER_IO_DAEMON | 性能/灵活 |
| v7.0 | `e2723e6ce602` | BATCH_IO（批量 fetch/commit） | 性能 |
| v7.x | （本仓库） | SHMEM_ZC（共享内存零拷贝）、REG_BUF/UNREG_BUF | 性能 |

### 11.2 v6.7 "io cmd 提交者 task 化"系列（≤6.8 的性能分水岭）

Ming Lei，2023 年 10 月：

| commit | 内容 |
|---|---|
| `3421c7f68bba` | **io cmd 保证在提交者（daemon）task 上下文处理**：即使 server 误用 `IOSQE_ASYNC` 或链式 SQE，也强制用 task_work 拉回提交者 task，绝不落到 io-wq worker，且保证持有 ctx->uring_lock |
| `85248d670b71` | 把 `ublk_cancel_dev()` 移出 `ub->mutex` 大锁 |
| `8ed90e370f9b` | abort 队列不再额外持设备引用 |
| `bd23f6c2c2d0` | abort 时 quiesce 请求队列 |
| `216c8f5ef0f2` | 用 cancelable uring_cmd 替换 monitor workqueue |
| `b4e1353f4651` | 简化 abort 请求路径 |
| `6eba24aeb5e2` | ublks_max 可配置 |

**性能影响**：`3421c7f68bba` 之前，io cmd 有概率被 io-wq worker 处理——提交、数据拷贝、结果处理分散在不同线程，跨线程交接 + 缓存污染；之后**提交→拷贝→处理全程锁死在同一个 daemon task**，槽位"单线程所有权"不变量被内核强制保证，快路径固化。这是 ublk ≤6.8 时期对 IOPS/延迟最有意义的一批改动。

### 11.3 v6.8 为什么是 AgentENV 的门槛

**v6.8 本身对 ublk 是零改动版本**。`git log v6.7..v6.8 -- drivers/block/ublk_drv.c` 中没有一条 ublk 自身提交。

所以 6.8 门槛不是因为 ublk 在 6.8 合入了什么，而是 6.8 恰好是"把之前关键补丁全部收齐"的发行版基线——**Ubuntu 24.04 出厂就是 6.8**。功能性门槛实际是 v6.5（USER_COPY）/ v6.7（task 化系列）。（另注：AgentENV 的 docker-setup.sh 中 modprobe ublk_drv 失败时的提示就是"try upgrading the kernel to 6.8+"。）

### 11.4 6.8 之后的大补丁（6.8 吃不到）

- **v6.9 `eaf4a9b19b99` remove segment count and size limits**：纯性能补丁。之前 ublk 块设备沿用默认 128 segment / 64KB segment 上限，**1MB IO 配 4K 页会被拆成 256 段然后被块层切碎**。补丁作者（PureStorage）原话："can cause unnecessary performance issues if the ublk server is optimized to handle 1M I/Os"。ublk 没有硬件约束，直接放开。**如果 AgentENV 服务端是优化过的大 IO 场景，卡在 6.8 意味着没吃上这个**。
- v6.15：真正的零拷贝（zc register/unregister bvec）
- v6.17 / v7.x：off-daemon 缓冲注册、BATCH_IO、SHMEM_ZC

### 11.5 结论

- ≤6.8 对性能有实质影响的关键补丁：**v6.7 "io cmd 提交者 task 化"系列**（外加 v6.5 USER_COPY 的功能基础）；
- v6.8 本身没有 ublk 改动（发行版基线意义）；
- 下一个真正提吞吐的补丁在 v6.9（segment 限制解除），正好在 AgentENV 的门槛之外。

---

## 12. 附：零基础类比讲解

### 12.1 信箱：io_uring

io_uring 是内核和用户态共享的一对环形队列：用户态往"投递队列"放任务，内核做完往"完成队列"写结果，用户态不用发系统调用就能轮询到结果。ublk 借用这条通道，定义了自定义任务类型（uring_cmd）：`FETCH_REQ`（"槽位空着，下一个 IO 请求给我"）、`COMMIT`（"那个 IO 我做完了"）。类比 KVM：这就是 vcpu 的 run 循环——用户态进程蹲在通道上等事件，而不是每次事件都重新搭通道。

### 12.2 槽位 + 编号：预挂单

daemon 启动时不干等，而是**提前挂好一沓空单**：队列深度设 128，就一口气发 128 个 FETCH_REQ 占满槽位。内核来请求 → 填进空闲槽位 → 该槽位的 FETCH 单完成 → daemon 轮询到 → 处理 → 发 COMMIT → 槽位回到空闲。槽位编号就是 tag，双方用"3 号队列、56 号槽"指代在途 IO。请求描述直接写在共享内存里，传递请求零拷贝、零系统调用。"预挂单"省掉的是"用户态睡觉 → 内核唤醒 → 重新跑起来"的延迟。

### 12.3 数据搬运的三种选择

- **内核代拷（默认）**：内核拷进 daemon 缓冲，daemon 再取。两次拷贝，最简单。
- **零拷贝**：内核把自己的内存页"租"给 daemon 进程直接访问。0 次拷贝，协议复杂。
- **共享内存零拷贝**：反过来——daemon 预先注册一块自己的大缓冲（memfd/大页），内核记住它的物理页；请求数据页正好落在里面就直接告诉 daemon "去你缓冲的第 X 字节取"。

---

## 附：关键函数索引（`drivers/block/ublk_drv.c`）

| 函数 | 行号 | 作用 |
|---|---|---|
| `ublk_ctrl_add_dev` | 4635 | 创建设备对 + 能力协商 |
| `ublk_ctrl_start_dev` | 4420 | 上线块设备（等 FETCH 挂齐） |
| `ublk_init_queue` | 4208 | 分配队列 + io_cmd_buf（NUMA 亲和） |
| `ublk_ch_mmap` | 2634 | io_cmd_buf 只读映射 |
| `ublk_queue_rq` / `ublk_queue_rqs` | 2203 / 2256 | blk-mq 入口 |
| `ublk_dispatch_req` | 1769 | 派发请求到 daemon（task_work） |
| `ublk_ch_uring_cmd_local` | 3357 | fetch/commit/need_get_data 处理 |
| `__ublk_complete_rq` | 1550 | 请求完成（含 partial + unmap） |
| `ublk_user_copy` | 4050 | USER_COPY pread/pwrite |
| `ublk_register_io_buf` | 3181 | zero-copy 缓冲注册 |
| `ublk_ctrl_reg_buf` | 5383 | SHMEM_ZC 缓冲注册（GUP pin） |
| `ublk_try_buf_match` | 5578 | SHMEM_ZC PFN 匹配 |
| `ublk_ch_release_work_fn` | 2516 | daemon 退出异步回收 |
| `ublk_timeout` | 2116 | 超时处理（非特权→SIGKILL） |
| `ublk_ctrl_quiesce_dev` | 5220 | 设备冻结 |
| `ublk_batch_dispatch` | 1922 | BATCH_IO 批量派发 |

## 参考资料

- [AgentENV docker-setup.sh（ublk_drv + 6.8+ 要求出处）](https://raw.githubusercontent.com/kvcache-ai/AgentENV/main/scripts/docker-setup.sh)
- 上游文档：`Documentation/block/ublk.rst`
- 用户态参考实现：ublksrv（github.com/ublk-org/ublksrv）
