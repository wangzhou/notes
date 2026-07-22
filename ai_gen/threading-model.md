# CubeSandbox 线程模型

## 各组件进程/线程数量

### CubeAPI（Rust）

```
1 个进程
  +-- Tokio runtime: 16 个 worker 线程（默认，可配）
  +-- 1 个文件日志线程（不在请求路径上）
```

- Axum HTTP server 运行在 Tokio worker 线程池上。
- 每个请求是一个 `Future`，由 16 个 worker 以 work-stealing 方式多路复用。
- 无阻塞 I/O —— 全部 async。

### CubeMaster（Go）

```
1 个进程（Go runtime，GOMAXPROCS = automaxprocs 从 cgroup 读取）
  +-- net/http: 每个 HTTP 请求 1 个 goroutine（瞬时，请求结束即回收）
  +-- BufferQueue: 每种实例类型 1 个 dispatcher goroutine
  +-- BufferQueue: 每个在途的创建任务 1 个 goroutine（瞬时）
  +-- QueueWorker: 1 个 supervisor goroutine + NumCPU 个 worker goroutine（最少 4）
  +-- ~10 个后台 ticker goroutine（monitorLimit, collectMetric, localcache 等）
  +-- gRPC 连接清理: NumCPU*2 个 goroutine（worker pool）
```

- HTTP server（gorilla/mux）监听 8089 端口。
- 调度器用 `errgroup` 并行跑 filter（每个 filter 1 个 goroutine）。

### CubeProxy（Nginx + OpenResty）

```
1 个 master 进程
  +-- 12 个 worker 进程
       每个 worker: 单线程（epoll 事件循环），最大 10 万连接
```

- `reuseport` 将入站连接均匀分发到 12 个 worker。
- 后端 keepalive 连接池：每个 worker 1500 个。
- Redis 连接池：每个 worker 1000 个。

### Cubelet（Go + containerd）

```
1 个进程（Go runtime，GOMAXPROCS=32，GCPercent=500）
  +-- gRPC server: 每个请求 1 个 goroutine（瞬时）
  +-- Workflow 引擎: semaphore 限流 + errgroup 每步并行（瞬时 goroutine）
  +-- 存储池: 8 个 worker goroutine + 1 个补充 goroutine
  +-- eventMonitor: 1 个 goroutine（订阅 containerd 事件）
  +-- deadContainerCleaner: 1 个 goroutine
  +-- imageGC: 1 个 goroutine
  +-- nodeStatusSync: 1 个 goroutine
  +-- loopReconcile: 1 个 goroutine
  +-- loopUpdateStatus: 1 个 goroutine
  +-- ~5 个其他后台 goroutine（cubes listener, network agent 等）
```

- containerd **内嵌在进程内**（非独立 daemon）。
- Workflow 引擎并发上限：100（semaphore 控制）。
- Workflow 创建的 sandbox 容器由 shim 进程接管。

### CubeShim（每个 sandbox 一个，Go）

```
N 个进程（每个 sandbox 一个，动态创建/销毁）
  每个 shim: 若干 goroutine 处理 ttrpc 和 I/O
```

### CubeHypervisor（每个 sandbox 一个，Rust）

```
N 个进程（每个 sandbox 一个，由 shim 启动）
  每个 HV 进程:
    +-- 每个 vCPU 1 个线程（KVM_RUN 循环）
    +-- 若干 virtio I/O 线程
```

---

## 组件间通信

```
                         HTTP                  HTTP/gRPC/Redis        proxy_pass
  SDK ---------------> CubeAPI ------------> CubeMaster ----------> CubeProxy -----------> Sandbox
  (E2B SDK)            :3000                 :8089                  :8080/:8081            (MicroVM)

                        |                     |                      |
                        |                     |    gRPC              |   ttrpc + KVM
                        |                     +--------------------> Cubelet ------------> CubeShim --> CubeHypervisor
                        |                     |                      |                      (每个 sandbox)
                        |                     |    Redis             |
                        |                     +--------------------> Redis
                        |                     |   (元数据、           |
                        |                     |    代理路由信息)       |
                        |                     |                      |
                        |                     |    HTTP（notify）     |
                        |                     |<--------------------+ (节点注册/状态上报)
```

### 通信矩阵

```
+------------------+---------------+---------------+---------------+---------------+---------------+
|                  |   CubeAPI     |  CubeMaster   |   CubeProxy   |    Cubelet    |  Shim + HV    |
+------------------+---------------+---------------+---------------+---------------+---------------+
| CubeAPI          |       -       |   HTTP REST   |       -       |       -       |       -       |
|                  |               | (reqwest,     |               |               |               |
|                  |               |  async)       |               |               |               |
+------------------+---------------+---------------+---------------+---------------+---------------+
| CubeMaster       |   HTTP 响应   |       -       |  Redis 写入   | gRPC 客户端   |       -       |
|                  |   （被动）     |               | (sandbox      | 调用 Cubelet  |               |
|                  |               |               |  路由信息)     | + HTTP 接收   |               |
|                  |               |               |               | 通知（被动）   |               |
+------------------+---------------+---------------+---------------+---------------+---------------+
| CubeProxy        |       -       |       -       |       -       |       -       |  HTTP 代理    |
|                  |               |               |               |               |  (nginx       |
|                  |               |               |               |               |   upstream)   |
|                  |               |               | Redis 读取    |               |               |
|                  |               |               | (路由         |               |               |
|                  |               |               |  查询)        |               |               |
+------------------+---------------+---------------+---------------+---------------+---------------+
| Cubelet          |       -       | HTTP POST     |       -       |       -       | ttrpc         |
|                  |               | (节点注册、    |               |               | (到 shim,     |
|                  |               |  心跳上报)     |               |               |  通过内嵌      |
|                  |               | gRPC server   |               |               |  containerd)  |
|                  |               | (接收 sandbox |               |               |               |
|                  |               |  操作请求)     |               |               |               |
+------------------+---------------+---------------+---------------+---------------+---------------+
| Shim + HV        |       -       |       -       |       -       | ttrpc（被动）  | shim 启动 HV  |
|                  |               |               |               |               | 为子进程      |
|                  |               |               |               |               | KVM ioctl     |
|                  |               |               |               |               | (到内核)      |
+------------------+---------------+---------------+---------------+---------------+---------------+
```

### 通信协议汇总

| 协议 | 通信双方 | 用途 |
|---|---|---|
| **HTTP REST** | SDK <-> CubeAPI，CubeAPI <-> CubeMaster，Cubelet <-> CubeMaster（心跳） | 控制面 API、节点注册 |
| **gRPC** | CubeMaster -> Cubelet | Sandbox 创建/销毁/exec 等操作 |
| **ttrpc** | Cubelet（内嵌 containerd）<-> CubeShim | 容器生命周期管理（containerd 原生 shim 协议） |
| **Proxy pass（HTTP）** | CubeProxy -> Sandbox（MicroVM） | 用户流量路由到运行中的 sandbox |
| **Redis** | CubeMaster（写），CubeProxy（读） | Sandbox 路由元数据（`bypass_host_proxy:<id>` hash）、节点指标 |
| **KVM ioctl** | CubeHypervisor -> Linux 内核 | 硬件虚拟化（vCPU、内存、I/O） |
| **Unix socket** | Cubelet <-> 本地 shim | 本地 containerd task API |

---

## 运行时进程数快照

```
物理节点（96 核，裸金属）:
  |
  +-- CubeProxy x 1 容器（1 master + 12 worker 进程）
  +-- Cubelet x 1 进程（空闲时 ~25 goroutine，创建时暴涨）
  |
  +-- 每个 sandbox:
  |     +-- cube-shim x 1 进程
  |     +-- cube-hypervisor x 1 进程（N 个 vCPU 线程）
  |
  +-- 合计: 空闲时 ~13 个进程 + 每个活跃 sandbox 2 个进程
  |          （2000 个 sandbox = 单机 ~4000 个 shim+HV 进程）

控制节点:
  +-- CubeAPI x 1 进程（16 个 Tokio worker 线程）
  +-- CubeMaster x 1 进程（~30+ goroutine）
  +-- Redis x 1
  +-- MySQL x 1
```
