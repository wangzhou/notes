# CubeSandbox Threading Model

## Process / Thread Count per Component

### CubeAPI (Rust)

```
1 process
  +-- Tokio runtime: 16 worker threads (default, configurable)
  +-- 1 file-logger thread (off request path)
```

- Axum HTTP server runs on the Tokio worker pool.
- Each request is a `Future` multiplexed onto the 16 workers (work-stealing).
- No blocking I/O — everything is async.

### CubeMaster (Go)

```
1 process (Go runtime, GOMAXPROCS = automaxprocs from cgroup)
  +-- net/http: 1 goroutine per incoming HTTP request (transient)
  +-- BufferQueue: 1 dispatcher goroutine per instance type
  +-- BufferQueue: 1 goroutine per in-flight create-sandbox task (transient)
  +-- QueueWorker: 1 supervisor goroutine + NumCPU worker goroutines (min 4)
  +-- ~10 background ticker goroutines (monitorLimit, collectMetric, localcache, etc.)
  +-- gRPC conn cleanup: NumCPU*2 goroutines (worker pool)
```

- HTTP server (gorilla/mux) on port 8089.
- Scheduler uses `errgroup` to run filters in parallel (1 goroutine per filter).

### CubeProxy (Nginx + OpenResty)

```
1 master process
  +-- 12 worker processes
       each worker: single-threaded (epoll event loop), 100k max connections
```

- `reuseport` distributes incoming connections across the 12 workers.
- Backend keepalive pool: 1500 connections per worker.
- Redis connection pool: 1000 connections per worker.

### Cubelet (Go + containerd)

```
1 process (Go runtime, GOMAXPROCS=32, GCPercent=500)
  +-- gRPC servers: 1 goroutine per request (transient)
  +-- Workflow engine: semaphore-guarded, errgroup per step (transient goroutines)
  +-- Storage pool: 8 worker goroutines + 1 refill goroutine
  +-- eventMonitor: 1 goroutine (containerd event subscriber)
  +-- deadContainerCleaner: 1 goroutine
  +-- imageGC: 1 goroutine
  +-- nodeStatusSync: 1 goroutine
  +-- loopReconcile: 1 goroutine
  +-- loopUpdateStatus: 1 goroutine
  +-- ~5 other background goroutines (cubes listener, network agent, etc.)
```

- containerd is embedded **in-process** (not a separate daemon).
- Workflow engine concurrency cap: 100 (semaphore).
- Workflow creates sandbox containers that are handled by shim processes.

### CubeShim (per sandbox, Go)

```
N processes (1 per sandbox, dynamically created/destroyed)
  each shim: a few goroutines for ttrpc serving and I/O
```

### CubeHypervisor (per sandbox, Rust)

```
N processes (1 per sandbox, spawned by shim)
  each HV process:
    +-- 1 thread per vCPU (KVM_RUN loop)
    +-- a few virtio I/O threads
```

---

## Inter-Component Communication

```
                        HTTP                HTTP/gRPC/Redis        proxy_pass
  SDK ---------------> CubeAPI -----------> CubeMaster ----------> CubeProxy -----------> Sandbox
  (E2B SDK)            :3000                :8089                  :8080/:8081            (MicroVM)

                        |                    |                      |
                        |                    |    gRPC              |   ttrpc + KVM
                        |                    +--------------------> Cubelet ------------> CubeShim --> CubeHypervisor
                        |                    |                      |                      (per sandbox)
                        |                    |    Redis             |
                        |                    +--------------------> Redis
                        |                    |   (metadata,         |
                        |                    |    proxy routing)    |
                        |                    |                      |
                        |                    |    HTTP (notify)     |
                        |                    |<--------------------+ (node register/status)
```

### Communication Matrix

```
+------------------+---------------+---------------+---------------+---------------+---------------+
|                  |   CubeAPI     |  CubeMaster   |   CubeProxy   |    Cubelet    |  Shim + HV    |
+------------------+---------------+---------------+---------------+---------------+---------------+
| CubeAPI          |       -       |   HTTP REST   |       -       |       -       |       -       |
|                  |               | (reqwest,     |               |               |               |
|                  |               |  async)       |               |               |               |
+------------------+---------------+---------------+---------------+---------------+---------------+
| CubeMaster       |   HTTP RESP   |       -       |  Redis write  | gRPC (client) |       -       |
|                  |   (passive)   |               | (sandbox      | to Cubelet    |               |
|                  |               |               |  route info)  | + HTTP notify |               |
|                  |               |               |               | (passive      |               |
|                  |               |               |               |  receive)     |               |
+------------------+---------------+---------------+---------------+---------------+---------------+
| CubeProxy        |       -       |       -       |       -       |       -       |  HTTP proxy   |
|                  |               |               |               |               |  (nginx       |
|                  |               |               |               |               |   upstream)   |
|                  |               |               | Redis read    |               |               |
|                  |               |               | (route        |               |               |
|                  |               |               |  lookup)      |               |               |
+------------------+---------------+---------------+---------------+---------------+---------------+
| Cubelet          |       -       | HTTP POST     |       -       |       -       | ttrpc         |
|                  |               | (node reg,    |               |               | (to shim,     |
|                  |               |  heartbeat)   |               |               |  via containerd|
|                  |               | gRPC server   |               |               |  embedded)    |
|                  |               | (receive      |               |               |               |
|                  |               |  sandbox ops) |               |               |               |
+------------------+---------------+---------------+---------------+---------------+---------------+
| Shim + HV        |       -       |       -       |       -       | ttrpc (passive)| shim spawns HV|
|                  |               |               |               |               | as child proc |
|                  |               |               |               |               | KVM ioctl     |
|                  |               |               |               |               | (to kernel)   |
+------------------+---------------+---------------+---------------+---------------+---------------+
```

### Communication Protocols

| Protocol | Used Between | Purpose |
|---|---|---|
| **HTTP REST** | SDK <-> CubeAPI, CubeAPI <-> CubeMaster, Cubelet <-> CubeMaster (heartbeat) | Control plane API, node registration |
| **gRPC** | CubeMaster -> Cubelet | Sandbox create/destroy/exec operations |
| **ttrpc** | Cubelet (containerd) <-> CubeShim | Container lifecycle (containerd's native shim protocol) |
| **Proxy pass (HTTP)** | CubeProxy -> Sandbox (MicroVM) | User traffic to running sandboxes |
| **Redis** | CubeMaster (write), CubeProxy (read) | Sandbox routing metadata (`bypass_host_proxy:<id>` hash), node metrics |
| **KVM ioctl** | CubeHypervisor -> Linux Kernel | Hardware virtualization (vCPU, memory, I/O) |
| **Unix socket** | Cubelet <-> local shims | Local containerd task API |
```

---

## Snapshot: Process Count in a Running Cluster

```
Physical Node (96 cores, bare metal):
  |
  +-- CubeProxy x 1 container (1 master + 12 worker processes)
  +-- Cubelet x 1 process (~25 goroutines idle, bursts during creates)
  |
  +-- Per sandbox:
  |     +-- cube-shim x 1 process
  |     +-- cube-hypervisor x 1 process (N vCPU threads)
  |
  +-- Total: ~13 processes idle + 2 processes per active sandbox
  |          (~2000 sandboxes = ~4000 shim+HV processes on one node)

Control Node:
  +-- CubeAPI x 1 process (16 Tokio worker threads)
  +-- CubeMaster x 1 process (~30+ goroutines)
  +-- Redis x 1
  +-- MySQL x 1
```
