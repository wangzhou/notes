- v0.1 2026.9.13 Sherlock init

简介：cube学习的一个速记，主要记录cube的基本逻辑构架和测试命令。

基本逻辑
---------

cube sandbox是腾讯开发的一个沙箱系统，基于kvm的虚机沙箱是其核心，但是它的范围很
广，涉及沙箱管理的各个方面。

cube的组件包括CubeAPI、CubeMaster、Cubelete、cube-shim、cube-hypervisor、cube-proxy等。

CubeAPI，估计是为了兼容E2B协议，所以这里先收请求然后转换格式后发送到CubeMaster。

CubeMaster，接收沙箱请求的核心部件，整个系统一个？CubeMaster负责管理沙箱，并把请求
转发到对应的Cubelete。

Cubelete可以是一台物理服务器一个实例，管理本实例下的所有沙箱。一台沙箱对应一个cube-shim，
cube-shim里的cube-hypervisor对应VMM。虚机里面跑cube-agent。

```
+---------------------------+  CubeSandbox v0.7.0  +-----------------------+
|                              all-in-one node                             |
|                                                                          |
|   CLIENTS                                                                |
|                                                                          |
|     +----------------------+    +------------------+    +-------------+  |
|     |  E2B / Python SDK    |    |  cubemastercli   |    |  cubecli    |  |
|     |  cube-bench (Go)     |    |  (mgmt CLI)      |    |  (node CLI) |  |
|     +-----------+----------+    +--------+---------+    +------+------+  |
|                 |                        |                     |         |
|                 | E2B HTTP               | REST                | unix    |
|                 |                        |                     | socket  |
|                 v                        v                     v         |
|   CONTROL PLANE                                                          |
|     +----------------------+        +---------------------+              |
|     |  CubeAPI  :3000      |        |  CubeMaster  :8089  |              |
|     |  Rust / Tokio        |------->|  Go                 |              |
|     |  30s TimeoutLayer    |        |  scheduler          |              |
|     +----------------------+        |  templates          |              |
|                                     +----------+----------+              |
|                                                |                         |
|                                                | gRPC                    |
|                                     +----------+----------+              |
|                                     |                     |              |
|                            +--------+--------+   +--------+--------+     |
|                            |  CubeOps :3010  |   |  WebUI :12088   |     |
|                            |  node registry  |   |  (nginx)        |     |
|                            +--------+--------+   +-----------------+     |
|                                     |                                    |
|                                     | HTTP notify (heartbeat)            |
|                                     v                                    |
|   STORAGE / INFRA                                                        |
|     +------------+   +------------+   +------------+   +-------------+   |
|     |  MySQL     |   |  Redis     |   |  MinIO     |   |  CoreDNS    |   |
|     |  (meta)    |   |  (routes)  |   |  :9000     |   |  127.0.0.54 |   |
|     +------------+   +------------+   |  (S3 vol)  |   |  (cube.app  |   |
|                                       +------------+   |   lookup)   |   |
|                                                        +-------------+   |
+--------------------------------------------------------------------------+
                                     |
                                     | gRPC (create / destroy / exec)
                                     v
+--------------------------------------------------------------------------+
|   DATA PLANE                                                             |
|     +------------------------------------------------+                   |
|     |  Cubelet                                       |                   |
|     |  Go, embedded containerd                       |                   |
|     |  workflow semaphore = 100                      |                   |
|     |  unix sock: /data/cubelet/cubelet.sock         |                   |
|     +---------------------+--------------------------+                   |
|                           |                                              |
|                           | ttrpc                                        |
|                           v                                              |
|     +-------------------------------------------------------+            |
|     |  per-sandbox (x N)                                    |            |
|     |                                                       |            |
|     |   +----------------------------------------------+    |            |
|     |   |  cube-shim (Rust, containerd shim v2)        |    |            |
|     |   |    |                                         |    |            |
|     |   |    +--> embedded cube-hypervisor             |    |            |
|     |   |         vcpu0..N threads (KVM_RUN)           |    |            |
|     |   +----------------------+-----------------------+    |            |
|     |                          |                            |            |
|     |                     KVM ioctl                         |            |
|     |                          v                            |            |
|     |                    +------------+                     |            |
|     |                    |  /dev/kvm  |                     |            |
|     |                    +------------+                     |            |
|     |                          ^                            |            |
|     |                          | ttrpc / vsock              |            |
|     |                   +------+-------------------------+  |            |
|     |                   |  guest MicroVM                 |  |            |
|     |                   |  cube-agent                    |  |            |
|     |                   |  envd :49999 / :49983 (app)    |  |            |
|     |                   +--------------------------------+  |            |
|     +-------------------------------------------------------+            |
|                                                                          |
|     +-------------------------------------------------------+            |
|     |  CubeProxy  :80 / :443 / :9090                        |            |
|     |  nginx + OpenResty, reads Redis for routing           |            |
|     |  CubeEgress :9091 (L7 MITM)                           |            |
|     |  lcm (lifecycle manager)                              |            |
|     +-------------------------------------------------------+            |
|                                                                          |
+--------------------------------------------------------------------------+
```
(AI生成)

测试命令
---------

基于以上的认识，所以用户可以通过各种接口使用cube沙箱。

1. 通过E2B协议提供的接口。cube-bench、cubebench.sh、examples目录下的各种脚本都是
   通过这种方式。cube提供的SDK是对这些接口的封装，用户可以编程使用。

   cube-bench提供沙箱起停的快速测试, examples/snapshot-rollback-clone下的脚本，
   提供快照、回滚、克隆的单点性能测试。cubebench.sh提供批量性能测试。

2. cubemastercli命令行。这个直接发信息给CubeMaster。-a指定CubeMaster的IP。基本
   功能是沙箱镜像/快照的创建/管理，沙箱运行，沙箱状态的管理等。

3. cubecli命令行。沙箱中执行命令，执行bash可以直接进入沙箱系统，交互式的执行沙箱
   里的命令。






TRAFFIC PATHS

1. Control path (create sandbox)

     SDK
      |
      |  E2B HTTP
      v
     CubeAPI :3000
      |
      |  REST
      v
     CubeMaster :8089
      |
      |  gRPC
      v
     Cubelet
      |
      |  ttrpc (unix socket)
      v
     cube-shim
      |
      |  process-internal channel
      v
     embedded cube-hypervisor  ->  /dev/kvm  ->  guest boot
      |
      |  vsock ready event
      v
     cube-agent:  CreateSandbox -> CreateContainer -> app starts


2. Data path (access sandbox)

     curl http://49999-<sandboxid>.cube.app
      |
      v
     CoreDNS (127.0.0.54)
      |
      v
     CubeProxy
      |
      |  Redis lookup: sandbox IP + port
      v
     proxy_pass direct to sandbox MicroVM


3. Node registration / heartbeat

     Cubelet
      |
      |  HTTP notify
      v
     CubeOps :3010
      |
      v
     CubeMaster (node metadata, resources)
