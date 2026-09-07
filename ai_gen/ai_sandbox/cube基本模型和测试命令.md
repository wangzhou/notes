- v0.1 2026.9.13 Sherlock init
- v0.2 2026.9.16 Sherlock ...
- v0.3 2026.9.17 Sherlock 增加测试入口访问路径表
- v0.4 2026.9.19 Sherlock ...
- v0.5 2026.9.19 Sherlock 修正错别字

简介：cube学习的一个速记，主要记录cube的基本逻辑架构和测试命令。

基本逻辑
---------

cube sandbox是腾讯开发的一个沙箱系统，基于kvm的虚机沙箱是其核心，但是它的范围很
广，涉及沙箱管理的各个方面。

cube的组件包括CubeAPI、CubeMaster、Cubelet、cube-shim、cube-hypervisor、cube-proxy等。

CubeAPI，估计是为了兼容E2B协议，所以这里先收请求然后转换格式后发送到CubeMaster。

CubeMaster，接收沙箱请求的核心部件，整个集群一个。CubeMaster负责管理沙箱，并把请求
转发到对应的Cubelet。

Cubelet可以是一台物理服务器一个实例，管理本实例下的所有沙箱。一台沙箱对应一个cube-shim，
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

基于以上的认识，所以用户可以通过各种接口使用cube沙箱。三类入口对服务端的
访问路径如下：

| 入口 | 服务端路径 | 入口参数 |
|------|-----------|----------|
| cube-bench / E2B SDK脚本 | CubeAPI :3000 -> CubeMaster | E2B_API_URL |
| cube自有SDK脚本(快照系列等) | CubeAPI :3000 -> CubeMaster | CUBE_API_URL |
| cubemastercli | 直连CubeMaster :8089 | -a/-p命令行参数 |
| cubecli | 本机Cubelet unix socket | 无 |

1. 通过E2B协议提供的接口。

cube-bench、cubebench.sh、examples目录下的各种脚本都是通过这种方式。cube提供的SDK
是对这些接口的封装，用户可以编程使用。

cube-bench提供沙箱起停的快速测试，examples/snapshot-rollback-clone下的脚本，提供
快照、回滚、克隆的单点性能测试。cubebench.sh提供批量性能测试。

```bash
export E2B_API_URL=http://127.0.0.1:3000 E2B_API_KEY=local
export CUBE_TEMPLATE_ID=<tpl-id>
export CUBE_API_URL=http://127.0.0.1:3000     # SDK脚本用

~/CubeSandbox/examples/cube-bench/bin/cube-bench -m create-delete -c 1 -n 5  # 建删压测：创建/销毁延迟与成功率

cd ~/CubeSandbox/examples/snapshot-rollback-clone
python bench_snapshot_concurrency.py -c 1 -n 5          # 快照单点延迟
python bench_snapshot_dirty.py -d 10 -n 3               # 快照脏页开销：写脏页后再打快照
python bench_clone_concurrency.py -c 1 -n 5             # 从快照克隆
python bench_create_concurrency.py -c 1 -n 3            # 从快照起沙箱
python bench_rollback_concurrency.py -c 1 -n 5          # 回滚
python bench_pause_resume_concurrency.py -c 1 -n 5      # 暂停/恢复

bash ~/CubeSandbox/tests/perf/cubebench.sh run 3.2      # 一键压测：3.2冷启动/3.3密度/4.x快照回滚克隆暂停
```

2. cubemastercli命令行。

这个直接发信息给CubeMaster。-a指定CubeMaster的IP。基本功能是沙箱镜像/快照的创建/管理，
沙箱运行，沙箱状态的管理等。

```bash
CM="cubemastercli -a 127.0.0.1"

# 建模板和模板管理
$CM tpl create-from-image --image cube-sandbox-int.tencentcloudcr.com/cube-sandbox/sandbox-code:latest \
  --writable-layer-size 1Gi --expose-port 49999 --probe 49999
$CM tpl ls

# 渲染创建请求(得到req.json)，起沙箱会输出sandbox id
$CM tpl render --template-id <tpl-id> --json > /tmp/render.json
python3 -c "import json;d=json.load(open('/tmp/render.json'));json.dump(d['api_request'],open('/tmp/req.json','w'))"
$CM multirun /tmp/req.json                     # 起沙箱测完即删，输出cube-e2e/sandbox-probe延迟
$CM multirun --norm /tmp/req.json              # 起沙箱并保留

# 沙箱状态、销毁沙箱、打快照
$CM cubebox ls                                 # 列沙箱(IP/状态)
$CM cubebox rm <sandBoxId>                     # 销毁
$CM snapshot create --sandbox-id <id>          # 给运行中沙箱打快照
 ```

3. cubecli命令行。

沙箱中执行命令，执行bash可以直接进入沙箱系统，交互式地执行沙箱里的命令。

```bash
sudo cubecli exec -it <sandBoxId> bash   # 交互式进沙箱(相当于SSH)
sudo cubecli exec -d <sandBoxId> cmd     # 沙箱内跑一条命令
sudo cubecli logs <sandBoxId>            # 看沙箱输出
```
