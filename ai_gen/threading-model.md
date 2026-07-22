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

---

## 附录：Benchmark HTTP 408 故障定界指南

### 408 的唯一来源

整个系统只有一处会产生 HTTP 408：

```
CubeAPI  src/routes.rs:44
  .layer(TimeoutLayer::new(Duration::from_secs(30)))   // 硬编码 30 秒，不可配置
```

tower-http 0.5.x 的 `TimeoutLayer` 在 handler Future 超过 30 秒未完成时，返回 `408 Request Timeout`，body 为 `"request has timed out"`。

**不是 504，不是 Nginx 超时，不是 gRPC 超时——就是 CubeAPI 的 30 秒硬超时。**

### 创建请求的完整超时链

```
SDK timeout (请求体传入，CubeAPI 默认填 15s)
  +-- CubeAPI TimeoutLayer (30s 硬编码，全局，最高优先级)
       +-- CubeMaster context.WithTimeout(req.Timeout) (默认 30s)
            +-- BufferQueue 排队等待（无独立超时，消耗 ctx 时间）
            +-- Cubelet gRPC Create（无独立超时，跟随上游 ctx）
                 +-- Workflow 引擎（semaphore 等待 + 各 step 执行）
                      +-- 存储池取盘（池空时 fallback 同步拷贝）
                      +-- 网络配置
                      +-- containerd.NewContainer
                      +-- shim.Create -> HV 启动
```

**如果 CubeMaster 的 BufferQueue 排队等了 25 秒，那留给 Cubelet 创建 VM 的时间只剩 5 秒。排队耗时和 VM 耗时消耗的是同一个 ctx。**

### 分阶段定界（不改代码）

#### 第一步：确认 408 发生在哪一层

打开 CubeMaster 和 Cubelet 的 Trace 级别日志。两个组件**已经有按阶段打点的耗时数据**，只是默认日志级别没开到 Trace。

**CubeMaster 侧** —— 关键字搜 Trace 日志：

```
# 看每个创建请求的最终结果
grep "CreateSandbox_rsp fail" cubemaster.log
  -> RetCode 字段就是错误码

# 看端到端耗时（master 收到请求到返回响应，不含 API->Master 网络）
grep "CalleeAction=ExtInfoCubeE2E" cubemaster.log
  -> Cost=xxx ms

# 看 BufferQueue 排队耗时
grep "Action=ActionBufferHandle" cubemaster.log
  -> Cost=xxx ms
  -> 如果这个值接近 30s，瓶颈在调度排队，不关 VM 的事

# 看 Cubelet gRPC 调用耗时
grep "cubeletCallDuration" cubemaster.log
  -> 如果这个值很小（< 1s），但 E2E 很大（> 25s），说明排队是主因
```

**Cubelet 侧** —— 看每个 workflow step 的耗时：

```
grep "Callee=" cubelet.log | grep "Cost="
  -> 每个 workflow step 的耗时明细：
     create-<n>-metadata:    spec 生成
     CubeNewContainerId:     containerd NewContainer 调用
     <n>-<shimId>:           task.Start（VM 启动）
     storage:                磁盘准备
     network:                网络配置
```

#### 第二步：根据耗时分布定界

| 现象 | 根因 | 排除 VM? |
|---|---|---|
| `ActionBufferHandle` 接近 30s，`cubeletCallDuration` 很小 | BufferQueue 排队拥堵，semaphore 满 | **是**，VM 没问题 |
| `ActionBufferHandle` < 1s，但 `cubeletCallDuration` > 25s | Cubelet 创建慢 | **否**，继续看 Cubelet 日志 |
| Cubelet 日志中 `<n>-<shimId>` （VM 启动）占比 > 80% | HV 启动慢 | **否**，是 VM 层问题 |
| Cubelet 日志中 `storage` 占比 > 80% | 存储池空了，fallback 到同步拷贝 | **否**，是磁盘问题 |
| Cubelet 日志中所有 step 都很快，但 `cubeletCallDuration` 很大 | gRPC 网络延迟 | **是**，VM 没问题 |
| E2E > 25s 但各个阶段加起来 < 5s | 有盲区耗时（见下方） | 待查 |

#### 第三步：定位盲区耗时

以下阶段**没有打点**，如果上面各阶段加起来远小于 E2E，耗时就在这些盲区里：

| 盲区 | 位置 | 临时打点方法 |
|---|---|---|
| CubeAPI 收到请求 -> CubeMaster 收到请求 | 网络 + CubeAPI handler 开销 | 对比 SDK 侧耗时和 CubeMaster `startTime` |
| BufferQueue Push -> dispatcher pop | `bufferqueue.go` worker loop | 在 `wh.Handle()` 前后加 log |
| Cubelet semaphore TryAcquire 等待 | Workflow 引擎入口 | 已有 `LimiterId` metric |
| Cubelet containerd.NewTask 内部 | containerd client 调用 | 在调用前后加 log |
| destroy 阶段的 suspend/resume | `destroy.go` failover 路径 | destroy 用的是 10s timeout，应该不会超 30s |

### 快速排除 VM 层的两个验证方法

**方法一：单并发冷启动测试**

```
# 不做 benchmark，单次 create sandbox，看耗时
time curl -X POST http://localhost:3000/sandboxes \
  -H "Content-Type: application/json" \
  -d '{"templateID": "tpl-xxx", "timeout": 60}'
```

如果单并发能稳定在 1s 以内完成，说明 VM 层本身没问题，benchmark 的 408 是排队拥堵导致的。

**方法二：观察 Cubelet 存储池水位**

```
# 看 Cubelet 的 pool 状态
grep "pool" cubelet.log | tail -20
```

如果日志里频繁出现 `GetSync`（池空，同步拷贝），说明磁盘池耗尽、创建被同步拷贝拖慢。`PoolSize=500` 不够支撑 benchmark 的并发量时需要调大。

### 如果确认是 VM 层慢

看 Cubelet Trace 日志中各 step 的比例：

- **`<n>-<shimId>` 占比高**（VM 启动慢）：检查 KVM 是否正常、HV 镜像是否损坏、宿主 CPU/内存是否耗尽
- **`storage` 占比高**（磁盘慢）：存储池已空、XFS reflink 性能下降、磁盘 I/O 争抢
- **`network` 占比高**（网络配置慢）：network-agent 响应慢、eBPF 程序加载慢

### 如果确认是排队拥堵

- `CreateConcurrentLimit` 默认 100，benchmark 并发超过此值就会排队
- `BufferQueue` 的 semaphore 由 `monitorLimit` 每 5s 动态调整，高频压测时来不及扩容
- 临时缓解：调大 cubemaster.yaml 的 `create_concurrent_limit`，或降低 benchmark 并发

### 如果确认是盲区耗时

代码中缺少打点的位置（按影响排序）：

1. **BufferQueue 的出队等待** — `bufferqueue.go:60-130`，worker loop 没有计时
2. **CubeMaster gRPC 调用 Cubelet 的网络耗时** — `actions.go:24-32`，没有单独打点
3. **containerd.NewTask 内部** — 这是 containerd client 调用，Cubelet 侧无打点
4. **CubeAPI reqwest 调用 CubeMaster 的网络耗时** — 用 CubeAPI 的 TraceLayer 可以拿到 HTTP 层耗时，但没有和业务耗时关联

这些需要加代码打点，建议用 CubeMaster 和 Cubelet 已有的 `CubeLog.Trace` 模式（`defer` + `time.Since`），不引入新的依赖。

---

## 附录：上层组件零基础概念速查

### HTTP

一种文本格式的请求-应答协议。客户端发一行文本描述要做什么，服务端回一行文本描述结果。

```
客户端发送:
POST /sandboxes HTTP/1.1              ← 对 /sandboxes 这个路径执行 POST（创建）
Host: localhost:3000                   ← 目标主机
Content-Type: application/json        ← 下面携带的数据是 JSON 格式
Content-Length: 45

{"templateID": "tpl-xxx"}             ← JSON 格式的参数

服务端回复:
HTTP/1.1 200 OK                       ← 200 表示成功
Content-Type: application/json

{"sandboxID": "sb-123"}               ← JSON 格式的结果
```

- URL（如 `/sandboxes`）= 操作的对象
- Method（GET/POST/DELETE）= 操作的类型（读/创建/删除）
- Status code（200/404/408/500）= 结果（成功/找不到/超时/服务器内部错误）
- Body = 传的参数或结果，通常是 JSON 文本

### JSON

一种用花括号和冒号表示"键值对"的数据格式。

```json
{
  "templateID": "tpl-xxx",
  "timeout": 60,
  "envVars": {"PYTHON_VERSION": "3.11"}
}
```

本质就是字符串形式的 `map<string, any>`。任何语言都能解析。

### REST API

一种约定俗成的 HTTP API 风格：
- URL 用名词指代资源：`/sandboxes` 表示沙箱这个资源
- Method 表示动作：`POST /sandboxes` = 创建，`GET /sandboxes` = 列表，`DELETE /sandboxes/sb-123` = 删除
- 参数和返回都是 JSON

### 反向代理（Reverse Proxy）

```
用户 ----> [Nginx] ----> 后端服务器 A
                  \----> 后端服务器 B
                  \----> 后端服务器 C
```

用户只知道 Nginx 的地址，不知道后面有哪些服务器。Nginx 根据请求内容（Host header、URL 等）决定转发给谁。CubeProxy 就是 Nginx 的定制版，根据请求里的 `Host: 49999-sb123.cube.app` 解析出 sandbox ID，再查 Redis 找到这沙箱的实际 IP 和端口，然后把请求转过去。

### Nginx 的进程模型

```
多进程:
  1 个 master 进程           —— 只负责管理 worker，不处理请求
  N 个 worker 进程           —— 每个独立处理请求，互不干扰
      每个 worker 内部: 单线程 + epoll
```

每个 worker 是单线程的。一个线程同时监听几万个连接——靠 `epoll` 这个 Linux 系统调用：内核告诉它"这 100 个连接中，有 3 个来数据了"，worker 就只处理这 3 个。所以一个线程能扛几万并发。

`reuseport` 是一个 socket 选项：多个 worker 监听同一个端口，内核按 hash 把新连接平均分给各个 worker，不需要 master 来分配。

### OpenResty / Lua

Nginx 原生只支持静态配置（配置文件写好就不能变）。OpenResty 在 Nginx 里嵌入了一个 Lua 解释器，让请求处理的每个阶段都可以写 Lua 脚本来**动态做决定**。

CubeProxy 的 Lua 脚本做了三件事：
1. 从请求的 Host header 里提取 sandbox ID 和端口号
2. 查本地缓存（L1）或 Redis（L2），找到这 sandbox 在哪个 IP
3. 动态设置转发的目标地址

### Redis

一个**内存版的 key-value 数据库**，所有数据在内存里，所以极快（微秒级）。

```
SET key value          — 存
GET key                — 取
HGETALL hash_key       — 取一个 hash 的所有字段
```

在 CubeSandbox 里的用途：CubeMaster 创建 sandbox 后，把它的 IP 和端口信息写到 Redis；CubeProxy 收到路由请求时从 Redis 读出来。因为 CubeProxy 和 CubeMaster 是不同的进程，Redis 充当了它们之间的共享内存。

### goroutine（Go）

Go 语言里创建并发任务的机制。`go func() { ... }()` 就启动了一个 goroutine。

与 OS 线程的关键区别：
- OS 线程 ~8MB 栈，goroutine ~2KB 起步动态增长
- OS 线程切换走内核，goroutine 切换在用户态
- 一个 OS 线程上可以同时跑成千上万个 goroutine

所以代码里看到一个进程起 30+ 个 goroutine 很正常，开销极低。

### Rust async / Tokio

Rust 的异步运行时。核心思想：**一个线程不只处理一个请求——当一个请求在等网络 I/O 时，线程去处理另一个请求。**

```rust
// .await 这一行：当前任务暂停，线程去跑别的任务，
// 等网络数据到了再回来继续执行
let resp = client.get(url).await;
```

Tokio 默认起 N 个 worker 线程（CubeAPI 用 16 个），每个线程上跑一个 work-stealing 调度器：线程把自己的任务做完了就从别的线程队列里"偷"任务来跑。

### gRPC

Google 出的 RPC 框架。本质是让一台机器上的程序可以**像调用本地函数一样**调用另一台机器上的函数。

```
调用方代码:                         被调用方代码:
resp, err := client.Create(ctx,     func (s *Server) Create(ctx,
    &CreateRequest{Name: "x"})           req *CreateRequest) (*CreateResponse, error)
```

传参和返回值用 protobuf 序列化（一种二进制编码，比 JSON 小、快），传输走 HTTP/2（二进制帧，支持多路复用——一个连接上同时跑多个请求）。

CubeSandbox 里：CubeMaster 通过 gRPC 远程调用 Cubelet 的 Create/Destroy/Exec 等接口。

### ttrpc

containerd 自用的极简 RPC 协议，只保留了请求-响应的基本语义，去掉了 HTTP/2 的流控、多路复用等功能。因为 containerd 和 shim 在同一台机器上通过 Unix socket 通信，不需要 TCP 协议栈那套复杂机制。

---

## 附录：CubeSandbox CLI 命令参考

### cubemastercli

```bash
cubemastercli --help
cubemastercli -a <CubeMaster IP> -p 8089 <command>

# 全局参数
#   -a, --address     CubeMaster 地址（默认 0.0.0.0，客户端使用需显式指定 127.0.0.1）
#   -p, --port        CubeMaster HTTP 端口（默认 8089）
#   --timeout         请求超时（默认 35s）
```

**沙箱管理：**

```bash
cubemastercli -a 127.0.0.1 cubebox run <sandbox-id>
  # 创建沙箱（手动指定 sandbox-id）

cubemastercli -a 127.0.0.1 cubebox list
  # 列出所有沙箱

cubemastercli -a 127.0.0.1 cubebox info <sandbox-id>
  # 查看沙箱详情（IP、端口、状态、资源）

cubemastercli -a 127.0.0.1 cubebox destroy <sandbox-id>
  # 销毁沙箱
```

**批量压测：**

```bash
cubemastercli -a 127.0.0.1 cubebox multi-run <json-file>
  # -c, --concurrency <N>    并发数
  # -n, --count <N>          总量
  # -w, --wait <N>           等待间隔
  # -m, --mode <mode>        create-only | pause-resume | destroy
  # -o, --output <dir>       输出日志目录
```

**模板管理：**

```bash
cubemastercli -a 127.0.0.1 cubebox template create-from-image
  # --image <image>             OCI 镜像地址
  # --writable-layer-size 1G    可写层大小
  # --expose-port 49999         暴露端口
  # --probe 49999               就绪探测端口

cubemastercli -a 127.0.0.1 cubebox template list          # 列出模板
cubemastercli -a 127.0.0.1 cubebox template info <id>     # 模板详情
cubemastercli -a 127.0.0.1 cubebox template delete <id>   # 删除模板
cubemastercli -a 127.0.0.1 cubebox template commit <sid>  # 从沙箱提交为模板
cubemastercli -a 127.0.0.1 cubebox template create-snapshot  # 创建模板快照
cubemastercli -a 127.0.0.1 cubebox template watch --job-id <job>  # 看构建进度
```

**节点管理：**

```bash
cubemastercli -a 127.0.0.1 cubebox node list              # 列出所有节点
cubemastercli -a 127.0.0.1 cubebox node info <node-id>    # 节点详情
```

---

## 附录：环境变量参考

### CubeAPI

| 变量 | 默认值 | 说明 |
|---|---|---|
| `LOG_LEVEL` | `info` | 日志级别：trace/debug/info/warn/error |
| `WORKER_THREADS` | `16` | Tokio worker 线程数，0 = CPU 核数 |
| `CUBE_API_BIND` | `0.0.0.0:3000` | 监听地址 |
| `CUBE_MASTER_ADDR` | (无) | **必须设**，CubeMaster 地址 |
| `CUBE_API_SANDBOX_DOMAIN` | `cube.app` | Sandbox 域名后缀 |
| `AUTH_CALLBACK_URL` | (无) | 外部鉴权回调地址，不设则不鉴权 |
| `LOG_DIR` | `/data/log/CubeAPI` | 日志目录 |

### CubeMaster

| 变量 | 说明 |
|---|---|
| `CUBE_MASTER_CONFIG_PATH` | **必须设**，指向 `cubemaster.yaml` |
| `CUBEMASTER_ROOTFS_ARTIFACT_STORE_DIR` | 模板镜像制品存储目录 |

CubeMaster 所有运行参数（端口、超时、调度参数）都在 yaml 文件里，不走环境变量。

### Cubelet

| 变量 | 说明 |
|---|---|
| `CUBE_SANDBOX_NODE_IP` | 本机 IP，注册到 CubeMaster 时上报 |

Cubelet 大部分配置在 `config.toml` + `cubelet.yaml` 里。

### SDK 客户端（E2B 兼容）

| 变量 | 说明 |
|---|---|
| `E2B_API_URL` | CubeAPI 地址，如 `http://127.0.0.1:3000` |
| `E2B_API_KEY` | API Key，不鉴权时填 `dummy` |
| `CUBE_TEMPLATE_ID` | 默认模板 ID |

### 调用链

```
E2B_API_URL           → CubeAPI 在哪儿
CUBE_MASTER_ADDR      → CubeMaster 在哪儿
CUBE_MASTER_CONFIG_PATH → CubeMaster 配置文件在哪
CUBE_SANDBOX_NODE_IP  → 本节点外部 IP
```

---

## 附录：日志配置与开启方法

### 日志级别

Go 组件（CubeMaster、Cubelet）没有 trace 级别，最高是 **debug**。CubeAPI（Rust）支持 trace。

### Cubelet 开 debug

```bash
# 运行时切换，不重启（debug HTTP 端口 :9966，默认已开启）
curl "http://localhost:9966/debug/loglevel?level=debug"

# 原理：Cubelet 启动时注册了一个 HTTP handler，
# 收到请求后直接改内存里的全局日志级别变量
```

### CubeMaster 开 debug

```bash
# 编辑配置文件
vim /usr/local/services/cubetoolbox/CubeMaster/conf.yaml

# 改一行:
#   log.level: "info"  →  log.level: "debug"

# 保存后 ~10 秒自动生效（hot-reload），不用重启
```

### CubeAPI 开 debug

```bash
export LOG_LEVEL=debug
# 或启动参数 --log-level debug
```

### 日志路径

```
CubeAPI:    由 LOG_DIR 指定，默认 /data/log/CubeAPI
CubeMaster: 由 cubemaster.yaml 的 log.path 指定，默认 /data/log/CubeMaster
Cubelet:    由 --logpath 参数指定，默认 /data/log/Cubelet
```

---

## 附录：Sandbox VM 默认配置

### vCPU 和内存

Sandbox 创建时的资源来源（优先级从高到低）：

1. SDK 请求指定 `container_overrides.resources`
2. 未指定则用 CubeMaster 默认值

```go
// CubeMaster/pkg/templatecenter/template_image.go:68-69
defaultTemplateCPU    = "2000m"    // 2 核
defaultTemplateMemory = "2000Mi"   // 2 GiB
```

Cubelet 收到后加 VMM 开销：

```
实际 VM 内存 = 请求内存 + 42Mi(VMM基础) + 16Mi(消息) + 系数补偿(~1.6%)
实际 vCPU  = 请求 CPU
```

**vCPU 和内存创建后不可动态修改。** Update API 只有 pause/resume，没有 CPU/内存热插拔。Cloud Hypervisor 底层支持 `vm_resize`，但 Cubelet 未暴露。

### 其他固定配置

```
Kernel:   /usr/local/services/cubetoolbox/cube-kernel-scf/vmlinux
Rootfs:   /usr/local/services/cubetoolbox/cube-image/cube-guest-image-cpu.img (pmem0)
启动参数:  root=/dev/pmem0 rootflags=dax ro console=hvc0 mitigations=off ...
数据磁盘:  请求 volume size + 100Mi 开销
```

---

## 附录：VM 启动探测（Probe）

VM 启动后，Cubelet 通过 `doProbe` 检测 Guest 是否就绪。三种探测方式：

| 方式 | 行为 |
|---|---|
| **TCP Socket** | `net.Dial("tcp", "IP:Port")` — TCP 三次握手成功即通过 |
| **HTTP GET** | 发 HTTP GET，要求返回 200 |
| **Ping (ICMP)** | ICMP ping 通即通过 |

### 重试逻辑

```
InitialDelay  →  等 VM 先启动（初始延迟）
    ↓
  探测一次
    ↓
  失败 → 等 Period → 再探测
  成功 → 计数++
    ↓
  连续成功 >= SuccessThreshold  → 通过
  连续失败 >= FailureThreshold  → 失败
  总耗时  > ProbeTimeout        → 超时失败
```

### 注意

- 如果创建模板时**不指定 `--probe`**，则 `doProbe` 跳过，耗时 0。
- 探测耗时与创建共享同一个 30s ctx 超时预算。若 `ProbeTimeout` 设得过大，探测本身就可能触发 408。
- 在 Cubelet Trace 日志中这一步的 metric id 是 `CubeProbeId`。

---

## 附录：CubeMaster 调度器

### 调度什么

收到创建 sandbox 请求时，从集群中选一台最合适的物理节点。

### 三步流程

```
1. 过滤（prefilter + filters 并行）
   排除: 资源不够、节点挂了、sandbox 数超上限、backoff 中的节点

2. 打分（scores 串行）
   按剩余资源、当前负载、亲和性、模板预热状态等计算分数

3. 选择
   从高分中随机挑一个（LeastRandomSelect）
```

### 节点亲和性

节点注册时带 `labels`（在 cubelet.yaml 配），创建沙箱时可指定 `label_selector` 限制调度范围：

```json
{
  "label_selector": {
    "cpu_type": "high_freq"
  }
}
```

调度器过滤时排除不匹配的节点。支持的操作符：`In`、`NotIn`、`Exists`、`DoesNotExist`、`Gt`、`Lt`。

### Node 概念

**Node = 一台物理机（或虚拟机宿主机），不是 sandbox。** 每个 Node 上跑一个 Cubelet 守护进程，Cubelet 管理该节点上所有的 sandbox MicroVM。

---

## 附录：CPU 绑核机制

Sandbox VM 有两层 CPU 绑定，代码都有但创建时未启用：

### 第一层：cgroup cpuset（限制整个 HV 进程）

```go
// Cubelet/plugins/cube/internals/cgroup/handle/v2/manager.go:70
func CreateWithCpuSet(ctx, group, cpuset, numaId) {
    cpuResource.Cpus = cpuset     // 例如 "0-3,8-11"
    cpuResource.Mems = numaId     // NUMA 节点号
    // 写入 /sys/fs/cgroup/<group>/cpuset.cpus
    // 效果: HV 进程所有线程只能跑在指定核上
}
```

### 第二层：per-vCPU affinity（单个 vCPU 线程绑核）

```rust
// hypervisor/vmm/src/cpu.rs:897-927
let cpuset = self.affinity.get(&vcpu_id);  // vCPU0 → [pCPU0,pCPU1]

thread::spawn(move || {
    // 每个 vCPU 线程启动时调 sched_setaffinity
    libc::sched_setaffinity(0, &cpuset);
    // 进入 KVM_RUN 循环
    vcpu.run();
});
```

### 区别

```
cgroup cpuset:  HV 进程范围，所有线程受限
per-vCPU affinity: 单 vCPU 线程范围，可精细控制
```

### 现状

创建 sandbox 时不传 `affinity` map（为空），`sched_setaffinity` 不调用。cgroup cpuset 也默认为空。两个能力都在但未通过 API 暴露。

---

## 附录：组件拆分原因

CubeAPI、CubeMaster、Cubelet 拆成三个独立进程的原因：

### 1. 部署位置不同

```
控制节点:                      计算节点（有 KVM）:
  CubeAPI  (HTTP 入口)           Cubelet x N
  CubeMaster (调度决策)
```

Cubelet 必须在有 KVM 的物理机上，API 和 Master 不需要。

### 2. 故障隔离

- CubeAPI 挂了 → sandbox 继续跑，创建暂停
- CubeMaster 挂了 → 同上
- Cubelet 挂了 → 只影响本机 sandbox

### 3. 独立扩容

- CubeAPI：无状态，可随意加实例
- CubeMaster：有状态，通常单实例
- Cubelet：每台机器一个

### 4. 语言不同

```
CubeAPI  → Rust (axum)，高并发 HTTP 网关
CubeMaster → Go (gorilla/mux)，复杂调度逻辑
```

无法合并进同一个进程。
