CubeSandbox沙箱命令手册
======================

-v0.1 2026.09.07 Sherlock init

简介：CubeSandbox单机部署后最常用的沙箱操作命令与性能测试命令速查,与
CubeSandbox部署指导.md配套。分基本命令(模板/沙箱/进沙箱/快照)与性能
测试命令(cube-bench/multirun/cubebench.sh)两部分,命令可直接复制运行。
作者:Sherlock。


零、环境准备

每个新终端先执行一次,否则命令会撞上VPN代理劫持0.0.0.0的坑:

```bash
export no_proxy=127.0.0.1,0.0.0.0,localhost,10.0.2.15
export NO_PROXY=$no_proxy
CM="cubemastercli -a 127.0.0.1"    # 后续用 $CM 代替前缀
```

当前模板:

```text
tpl-ebf00021329c474d91d89408  READY  sandbox-code(带49999/49983端口与/health探针)
```

常用变量:

```bash
TPL=tpl-ebf00021329c474d91d89408
BIN=~/CubeSandbox/examples/cube-bench/bin/cube-bench
REQ=/tmp/req.json
```

注意权限分层:cubemastercli走HTTP到CubeMaster(8089),普通用户可跑;
cubecli连Cubelet本地gRPC(/data/cubelet/cubelet.sock,root权限),所有cubecli
命令都要sudo。本机嵌套虚拟化限制:并发创建会失败,压测保持串行-c 1。


一、基本命令
------------

1) 建模板(OCI镜像转ext4。image必须用int仓库,ARM64的cn仓库是amd64单架构)

```bash
$CM tpl create-from-image \
  --image cube-sandbox-int.tencentcloudcr.com/cube-sandbox/sandbox-code:latest \
  --writable-layer-size 1Gi \
  --expose-port 49999 --expose-port 49983 --probe 49999
```

参数:--probe 49999是就绪探针(GET /health),create会等app就绪才返回;
不加probe则VM起来即返回。--alias code可起别名。建模板[6/7]步偶发
10s event timeout,失败重试即可。建完用tpl ls等STATUS=READY。

2) 查模板 / 删模板

```bash
$CM tpl ls                                       # 列表
$CM tpl status --job-id <job_id>                 # 建模板job进度
$CM tpl info --template-id $TPL                  # 模板详情
$CM tpl delete --template-id <tpl-id>            # 删除
```

3) 起沙箱(先render出创建请求再multirun;不带--norm建完自动销毁)

```bash
$CM tpl render --template-id $TPL --json > /tmp/render.json
python3 -c "import json;d=json.load(open('/tmp/render.json'));json.dump(d['api_request'],open('$REQ','w'))"
$CM multirun $REQ                          # 起一个,测完即删
$CM multirun --norm $REQ                   # 常驻不删(记下sandBoxId)
```

4) 查看 / 销毁沙箱

```bash
$CM cubebox ls                             # 列表(含IP/状态)
$CM cubebox info <sandBoxId>               # 详情
$CM cubebox rm <sandBoxId>                 # 销毁单个
# 一键清空所有沙箱
$CM cubebox ls | awk '$1 ~ /^[0-9a-f]{32}$/{print $1}' \
  | xargs -rn1 $CM cubebox rm
```

5) 进沙箱(相当于SSH;沙箱镜像无sshd,走cubecli exec;需sudo)

```bash
sudo cubecli exec -it <sandBoxId> bash    # 交互式shell,无bash换sh
sudo cubecli exec -d <sandBoxId> cmd      # 后台跑一条命令
sudo cubecli logs <sandBoxId>             # 看沙箱输出
```

沙箱内就是完整Linux环境,可跑代码、装包、看文件。

6) 从沙箱内访问其服务

```bash
$CM cubebox ls                            # 拿到沙箱IP(如192.168.1.51)
curl --noproxy '*' http://192.168.1.51:49999/health
```

7) 快照 / 回滚

```bash
$CM snapshot create --sandbox-id <sandBoxId>     # 给运行中的沙箱打快照
$CM snapshot ls                                  # 列快照
$CM snapshot info <snapshotId>                   # 快照详情
$CM snapshot delete <snapshotId>                 # 删快照
```

从快照起沙箱或回滚用Python SDK的sb.clone()/sb.rollback(),见二.4。


二、性能测试命令
----------------

1) cube-bench:标准压测(打CubeAPI,官方基准同款工具)

```bash
export E2B_API_URL=http://127.0.0.1:3000
export E2B_API_KEY=local
export CUBE_TEMPLATE_ID=$TPL

$BIN --dry-run -c 2 -n 5                      # 冒烟,不连服务器
$BIN -m create-delete -c 1 -n 5               # 串行建删压测(本机推荐)
$BIN -m create-delete -c 1 -n 10 -w 3         # 带3次预热,对齐官方口径
$BIN -m create-only -c 1 -n 3                 # 只建不删,测纯创建
$BIN -m create-delete -c 1 -n 10 -o bench.json  # 导出JSON
$BIN -m create-delete -c 5 -n 50              # 并发压测(仅裸金属,本机会失败)
```

参数:-c并发/-n总数/-w预热/-m模式(create-delete建完即删、
create-only只建不删)/-o导出JSON/-no-tui纯文本输出/-np网络策略。
输出看Success Rate、CREATE/DELETE各延迟百分位、Throughput。
create-only跑完要用基本命令4的批量rm清理。

2) multirun:内置轻量压测(打CubeMaster,无需编译)

```bash
$CM multirun --runcnt 10 --runcc 1 --printall $REQ      # 循环10次串行
$CM multirun --runcnt 10 --runcc 4 --printall $REQ      # 并发4(本机会失败)
$CM multirun --runcnt 10 --percents "0.5,0.9,0.99" $REQ # 自定义百分位
```

参数:--runcnt循环次数/--runcc并发/--percents百分位/--printall打印全部
指标/--norm不销毁/--fail_exit有失败即退出非零。输出各阶段
(cube-e2e、sandbox-probe、clientReqCost)的min/p5/p50/p80/p99。

3) cubebench.sh:官方一键全量压测(覆盖冷启动/密度/快照/回滚/克隆/暂停)

```bash
bash ~/CubeSandbox/tests/perf/cubebench.sh sections   # 列可选章节
bash ~/CubeSandbox/tests/perf/cubebench.sh run 3.2     # 只跑冷启动延迟
bash ~/CubeSandbox/tests/perf/cubebench.sh run 3.3     # 单机密度/内存
bash ~/CubeSandbox/tests/perf/cubebench.sh run 4.6     # 暂停/恢复
bash ~/CubeSandbox/tests/perf/cubebench.sh run         # 全量
```

前提:会销毁所有沙箱再测;需先调大Cubelet的host.quota(否则报
no more resource);3.x章节需先make cube-bench,4.x章节需python3-venv
联网装SDK。本机嵌套虚拟化下各章节的并发档大概率失败,串行档可用。

4) Python SDK压测:快照/克隆/回滚专项(4.x同款脚本)

```bash
python3 -m venv ~/tests/cube/venv && source ~/tests/cube/venv/bin/activate
pip install "cubesandbox>=0.2.0"
export CUBE_API_URL=http://127.0.0.1:3000
export CUBE_TEMPLATE_ID=$TPL
cd ~/CubeSandbox/examples/snapshot-rollback-clone
python bench_pause_resume_concurrency.py -c 1 -n 5   # 暂停/恢复延迟
python bench_snapshot_concurrency.py -c 1 -n 5       # 快照创建
python bench_create_concurrency.py -c 1 -n 3         # 从快照起沙箱
python 01_create_snapshot.py                         # 快照功能演示
```


三、使用须知
------------

1. 本机(嵌套KVM)并发创建会报reset guest time ttrpc超时/408,压测保持
   -c 1、--runcc 1串行;要并发/高密度需换非嵌套裸金属。
2. create-only与--norm会留沙箱,注意清理与内存(每沙箱约2GB)。
3. 本机冷启动约3s=VM创建约1s+app就绪探针约2s;去掉--probe可对齐官方
   48ms口径(只测VM创建)。
4. 所有命令先配好零章的环境变量(no_proxy+$CM),否则撞代理报EOF/400。
