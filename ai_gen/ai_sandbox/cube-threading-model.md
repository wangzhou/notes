CubeSandbox线程模型
==================

-v0.2 2026.09.07 Sherlock init

简介：CubeSandbox各组件的进程/线程模型与通信拓扑,以及测试命令与线程
模型的对应关系。关键数字均与本机部署(~/CubeSandbox v0.7.0源码、
/usr/local/services/cubetoolbox配置)核对过。作者:Sherlock。


一、组件进程/线程模型
---------------------

## CubeAPI(Rust/Tokio)

1个进程。Tokio worker线程池处理全部HTTP请求,16个worker(本机实测
17线程=16worker+1日志),可配WORKER_THREADS。全部async无阻塞I/O。
另有1个日志线程,不在请求路径上。Axum路由整体包了30s TimeoutLayer
(routes.rs:26 DEFAULT_ROUTE_TIMEOUT),这是全系统唯一产生HTTP 408的地方。

## CubeMaster(Go)

1个进程。net/http每请求1个goroutine(瞬时)。常驻约30+goroutine:
BufferQueue每实例类型1个dispatcher+每在途任务1个、QueueWorker
1 supervisor+NumCPU个worker(最少4)、调度filter用errgroup并行
(每filter 1个goroutine)、gRPC清理worker池NumCPU*2个、约10个后台ticker。
GOMAXPROCS=automaxprocs(按cgroup读取)。

## CubeProxy(Nginx/OpenResty容器)

1 master+worker_processes auto个worker(本机实测22个;auto按nginx探测的
CPU数)。每worker单线程epoll,worker_connections 100000。reuseport按hash
均分入站连接。worker内Lua查路由:Host解析sandbox id→L1本地缓存→L2
Redis→动态proxy_pass。HTTP/gRPC upstream keepalive默认关闭
(nginx.conf:114有说明)。

## Cubelet(Go,内嵌containerd)

1个进程,containerd以Go库内嵌(go.mod依赖containerd/v2)。gRPC server每
请求1个goroutine。Workflow引擎:create/destroy各1条flow,每条concurrent
=100(config.toml [plugins."io.cubelet.workflow.v1.workflow"].flows),
semaphore限流,flow内各step用errgroup并行。另有存储池8个worker+1补充、
eventMonitor/deadContainerCleaner/imageGC/nodeStatusSync/loopReconcile/
loopUpdateStatus各1个、若干网络/agent goroutine。max_concurrent_requests
=8(HTTP请求采样等用途,config.toml:72)。

## 每个沙箱2个进程(动态)

containerd-shim-cube-rs(简称cube-shim,Rust):containerd拉起,id=sandbox
id,经ttrpc与Cubelet通信,负责VM生命周期与快照。
cube-runtime(Rust,cloud-hypervisor系hypervisor):shim的子进程,即VMM。
每vCPU 1个线程跑KVM_RUN循环,另有若干virtio I/O线程。per-vCPU亲和机制
存在(hypervisor/vmm/src/cpu.rs:546 affinity: BTreeMap<u8,Vec<u8>>,
vCPU线程启动时sched_setaffinity),但创建时不传affinity map,未启用。
guest侧还有cube-agent(Rust)与envd(代码解释器服务,暴露49999等端口)。

空闲时全节点约13个常驻进程;每个活跃沙箱+2个shim/runtime进程。


二、通信拓扑
------------

```text
SDK --HTTP--> CubeAPI(:3000) --HTTP--> CubeMaster(:8089)
                                            | gRPC --> Cubelet(内嵌containerd)
                                            | Redis写入路由信息
                                            |        CubeProxy读取Redis
                                            |        proxy_pass --> 沙箱MicroVM

Cubelet --ttrpc(unix socket)--> cube-shim --子进程--> cube-runtime --KVM ioctl--> 内核
Cubelet <--HTTP notify-- CubeMaster(节点注册/心跳,由CubeOps中转)
```

协议用途:

| 协议 | 双方 | 用途 |
|------|------|------|
| HTTP REST | SDK->CubeAPI、CubeAPI->CubeMaster | 控制面API |
| HTTP POST | Cubelet->CubeMaster | 节点注册/心跳 |
| gRPC | CubeMaster->Cubelet | 创建/销毁/exec |
| ttrpc | Cubelet->cube-shim | 容器生命周期 |
| Redis | CubeMaster写、CubeProxy读 | 沙箱路由元数据 |
| KVM ioctl | cube-runtime->内核 | vCPU/内存/设备模拟 |
| HTTP proxy_pass | CubeProxy->沙箱 | 用户流量 |

沙箱访问路径:请求Host如49999-<sandboxid>.cube.app,经CoreDNS解析到
CubeProxy,CubeProxy查Redis得到沙箱实际IP:端口再转发。


三、测试命令与线程模型的对应
---------------------------

## 命令执行位置与目标组件

所有命令都在host侧发出;只有cubecli exec真正把命令送进guest内执行。

| 命令 | 在哪里跑 | 打到哪个组件(协议/端口) | 权限 |
|------|---------|------------------------|------|
| cubemastercli tpl/cubebox/snapshot/multirun | 任意可达CubeMaster的机器 | CubeMaster HTTP :8089 | 普通用户 |
| cubecli exec/logs/container/multirun | 必须在Cubelet所在节点本机 | Cubelet gRPC,unix socket /data/cubelet/cubelet.sock | root |
| cube-bench | 任意可达CubeAPI的机器 | CubeAPI HTTP :3000(E2B协议) | 普通用户 |
| cubebench.sh | 任意;3.3测内存须本机;清场用cubecli | 驱动cube-bench(3.x)+SDK脚本(4.x)->CubeAPI | 清场需root |
| examples/*.py(SDK脚本) | 任意 | CubeAPI HTTP :3000(CUBE_API_URL,默认127.0.0.1:3000) | 普通用户 |
| cubeopscli | 任意 | CubeOps HTTP :3010 | 普通用户 |
| smoke.sh | 部署机本机 | 多组件健康检查汇总 | root |

## 测试命令与线程模型的对应

| 命令 | 路径与参与的线程模型 | 瓶颈对应点 |
|------|---------------------|-----------|
| cube-bench -m create-only | SDK->CubeAPI(Tokio worker)->CubeMaster(BufferQueue+调度filter)->Cubelet(workflow semaphore+各step并行)->shim/runtime(KVM_RUN线程) | 全链路;408=API 30s TimeoutLayer;排队=BufferQueue/flow semaphore(concurrent=100) |
| cube-bench -m create-delete | 上面+销毁反向路径 | destroy flow同样concurrent=100 |
| cube-bench -c N并发 | 并发打CubeAPI worker;CubeMaster每请求1 goroutine;Cubelet workflow排队 | API 16 worker、master goroutine数、flow semaphore 100 |
| multirun --runcc N | 同上,直连CubeMaster(不经CubeAPI) | 无API层,专测master+cubelet |
| multirun 输出的sandbox-probe | Cubelet probe.go(doProbe,tcp/http/ping三种handler) | app就绪时间,非VM boot |
| multirun 输出的cube-e2e | master收到请求->响应返回全程 | 与官方口径差异见部署指导7.9 |
| cubecli exec -it | 不走上层,本机unix socket->Cubelet gRPC->shim ttrpc->guest cube-agent | 压测探针/交互,走的是Cubelet本地路径 |
| cubebench.sh 3.2(冷启动) | 同create-only,cube-bench实现 | 建沙箱单点延迟 |
| cubebench.sh 3.3(密度) | 大量沙箱常驻,shim+runtime进程数线性增长,内存=2Gi/沙箱+开销 | 进程/内存规模 |
| cubebench.sh 4.1/4.2(快照) | shim快照流程(cube-runtime --snapshot-type soft-dirty/incremental/full) | 快照脏页迁移 |
| cubebench.sh 4.3(从快照起) | 创建路径改从快照恢复,跳过boot | 快照恢复延迟 |
| cubebench.sh 4.4(回滚) | cube-runtime快照回滚 | 回滚延迟 |
| cubebench.sh 4.5(克隆) | 同快照+多目标分发 | 克隆扇出 |
| cubebench.sh 4.6(暂停/恢复) | cube-runtime暂停vCPU线程/恢复KVM_RUN | vCPU线程调度 |

要点:并发压测的瓶颈在CubeAPI的30s TimeoutLayer+BufferQueue排队+
workflow semaphore(=100,config可调);VM创建延迟在shim/runtime层;
探针(app就绪)延迟在Cubelet doProbe与guest内envd;快照/回滚/克隆/暂停
延迟都在cube-runtime。


四、408排障速查(与线程模型对应)
-------------------------------

408唯一来源:CubeAPI TimeoutLayer 30s(routes.rs,常量可改)。

超时链:SDK timeout(请求体,API默认填15s)->API TimeoutLayer(30s)
->Master context.WithTimeout(req.Timeout,默认30s)->BufferQueue排队
(消耗同一ctx)->Cubelet gRPC(跟随上游ctx)->workflow semaphore+steps。

分阶段定界(Master/Cubelet开debug,搜日志):

| 关键字(Master) | 含义 |
|----------------|------|
| Action=ActionBufferHandle Cost | 排队耗时;接近30s=排队拥堵 |
| CalleeAction=ExtInfoCubeE2E Cost | master端到端耗时 |
| cubeletCallDuration | 调Cubelet耗时;小但E2E大=排队主因 |

Cubelet日志里workflow各step耗时:storage(磁盘准备)、network(网络配置)、
<n>-<shimId>(task.Start即VM启动)。

判定:ActionBufferHandle大=排队(调大create/destroy flow的concurrent或
降并发);storage大=存储池空fallback同步拷贝(调大PoolSize);<shimId>大
=VM启动慢(查KVM/HV);全快但E2E大=盲区耗时(BufferQueue出队、gRPC网络、
containerd.NewTask无打点)。

快速验证VM层:单并发冷启动`time curl -X POST http://localhost:3000/sandboxes
-d '{"templateID":"tpl-xxx"}'`若<1s则VM没问题;本机嵌套虚拟化场景VM约
1s(见部署指导7.9拆解)。日志级别:Cubelet用curl localhost:9966/debug/
loglevel?level=debug;CubeMaster改conf.yaml log.level(热加载约10s);
CubeAPI设LOG_LEVEL=debug。


五、本机实测注意事项
--------------------

本机(嵌套KVM)与裸金属线程模型相同但表现不同:并发创建会触发guest响应
超时(reset guest time ttrpc超时/event timeout 10s),失败后可能残留孤儿
shim进程(占内存,参考立方体上的观察)。压测保持串行-c 1;清理孤儿:
sudo cubecli unsafe destroy <sandbox-id>或重启相关服务。每沙箱约2Gi内存
+shim/runtime各约140MB进程开销。
