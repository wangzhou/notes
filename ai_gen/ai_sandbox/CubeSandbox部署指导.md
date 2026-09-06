CubeSandbox ARM64单机部署实录
==============================

-v0.1 2026.09.06 Sherlock init

简介：在一台aarch64 openEuler 24.03机器上部署CubeSandbox v0.7.0单节点
的完整实录。记录环境比对、前置准备、一键包安装，以及ARM平台特有的两个
关键坑(cn镜像仓库单架构、docker-compose v1.22崩溃)的定位与解法。以实际
命令与真实报错为准,可作为ARM host上复现部署的指导。作者:Sherlock。


一、部署环境与前置条件
----------------------


## 1.1 本机环境

部署目标机是一台ARM虚拟机(嵌套虚拟化KVM host),实测环境如下:

| 项 | 值 |
|----|----|
| 架构 | aarch64 |
| 发行版 | openEuler 24.03 (LTS-SP2) |
| 内核 | 6.6.0-98.0.0.103.oe2403sp2.aarch64 |
| CPU/内存 | 10核 / 15Gi |
| 根文件系统 | /dev/vda2 ext4 (虚机磁盘) |
| /dev/kvm | 存在,可读写(嵌套虚拟化已开) |
| glibc | 2.38 |
| cgroup | v1 (混合模式,/sys/fs/cgroup为tmpfs) |
| /sys/fs/bpf | 已挂载,type=bpf |
| 已有工具 | make gcc rustc1.86 python3 truncate mkfs.ext4 |
| 缺失工具 | docker go mkfs.xfs |
| DNS后端 | 无systemd-resolved,NetworkManager active+dnsmasq |

本地源码~/CubeSandbox版本为sdk/go/0.7.0-54-gd38cb6e5(master),实际部署
采用官方release包v0.7.0(git d0081641),二者同属0.7.0线。


## 1.2 CubeSandbox对前置的硬性检查

install.sh的preflight在启动前逐项检查,失败即abort。基于v0.7.0-arm64
一键包脚本梳理如下(file:line为bundle内脚本行号):

| 检查项 | 位置 | abort条件 | 本机 |
|--------|------|-----------|------|
| KVM | install.sh:889 | /dev/kvm不存在 | 通过 |
| 内存 | install.sh:915 | 低于约7.2GB | 通过 |
| glibc | common.sh | 低于2.31 | 通过 |
| bpf fs | install.sh:1100 | /sys/fs/bpf未挂载 | 通过 |
| cgroup cpu | install.sh:1057 | v2缺cpu controller | 跳过(本机v1) |
| XFS | install.sh:1019 | /data/cubelet非XFS | 需处理 |
| docker | install.sh:1141 | docker命令缺失 | 需安装 |
| root | common.sh:479 | 非root运行 | 需root |
| DNS | install.sh:359 | 无resolvectl且NM未loaded | 通过 |

注意,脚本只检查/dev/kvm是否存在(install.sh:889-908),不检测"本机是
虚拟机/嵌套虚拟化"。文档self-build-deploy.md写的"nested virtualization
is not supported"是文档取舍,脚本本身不据此拒绝,所以嵌套KVM虚机可部署。


二、部署路径选择
----------------

CubeSandbox提供三条路径:一键在线安装online-install.sh、下载release包
手动安装、源码builder容器自建。选择依据:

online-install.sh当前只自动发现x86_64包,ARM64尚未支持(bare-metal-deploy.md
明确说明),故排除。源码自建需docker builder容器,链路长。最终选择下载
官方ARM64 release一键包手动安装,最省事且组件均为预编译产物。

官方release页(GitHub TencentCloud/CubeSandbox)v0.7.0确有ARM64一键包:
cube-sandbox-one-click-v0.7.0-arm64.tar.gz,约188MB。


三、前置准备
------------


## 3.1 安装docker

install.sh对docker是硬依赖(needs_docker_for_install恒真,install.sh:328),
用来编排MySQL/Redis/MinIO/CubeProxy/CoreDNS/WebUI/egress/lcm等容器。沙箱
MicroVM本身由Cubelet经KVM直接拉起,不走docker。全库无podman支持。

openEuler包名与install.sh默认的yum install docker不一致:docker守护进程
在moby-engine包,命令行在moby-client包。手动安装避免脚本自动装失败:

```bash
sudo dnf install -y moby-engine moby-client
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

只要docker与docker-compose命令已存在,install.sh的install_docker会直接
跳过自动安装(common.sh:2536-2554靠command -v检测)。


## 3.2 准备XFS文件系统

install.sh要求/data/cubelet落在XFS上(check_cubelet_fs_preflight,
install.sh:1019-1055)。它按"就近祖先"取文件系统类型:只要/data/cubelet
所在fs是xfs即通过。本机根为ext4,无XFS分区,用回环文件造一个XFS挂上去:

```bash
sudo dnf install -y xfsprogs
sudo mkdir -p /data/cubelet
sudo truncate -s 20G /var/lib/cube-xfs.img
sudo mkfs.xfs /var/lib/cube-xfs.img
sudo mount -o loop /var/lib/cube-xfs.img /data/cubelet
echo "/var/lib/cube-xfs.img /data/cubelet xfs loop 0 0" | sudo tee -a /etc/fstab
```

挂载后df -T /data/cubelet应显示xfs(实测source为/dev/loop0)。


## 3.3 DNS

install.sh的DNS preflight(check_dns_preflight,install.sh:359-391)逻辑:
有resolvectl则走systemd-resolved;否则要求NetworkManager为loaded、dnsmasq
可用,走NM+dnsmasq路径。本机无systemd-resolved(不存在),NetworkManager
active且dnsmasq已装,恰好满足NM+dnsmasq分支,无需额外操作。


## 3.4 sudo/root

install.sh强制root(require_root,common.sh:479-483)。生产上不建议配
NOPASSWD:ALL,由具备sudo权限的用户直接执行install.sh即可。


四、下载与安装一键包
--------------------


## 4.1 下载ARM64一键包

```bash
mkdir -p ~/tests/cube && cd ~/tests/cube
wget -c "https://github.com/TencentCloud/CubeSandbox/releases/download/v0.7.0/cube-sandbox-one-click-v0.7.0-arm64.tar.gz"
tar -xzf cube-sandbox-one-click-v0.7.0-arm64.tar.gz
cd cube-sandbox-one-click-v0.7.0-arm64
```

完整包197646141字节(约188MiB),GitHub直连偏慢,国内可用ghfast.top等
加速前缀。解压后含install.sh、down.sh、smoke.sh、env.example、assets/
(sandbox-package.tar.gz约173M + guest内核19M)。


## 4.2 配置.env

```bash
cp env.example .env
```

关键:ARM64必须保持MIRROR为空(等价于int国际镜像仓库),不要设MIRROR=cn。
原因见第五章坑一。其余单节点默认值即可,节点IP自动从eth0探测。


## 4.3 执行install.sh

```bash
cd ~/tests/cube/cube-sandbox-one-click-v0.7.0-arm64
sudo ./install.sh --yes 2>&1 | tee ~/tests/cube/install.log
```

install.sh依次:加载.env与preflight、解包sandbox-package到
/usr/local/services/cubetoolbox、安装systemd unit、启动
cube-sandbox-control.target(经docker compose拉起各依赖容器)、quickcheck
健康检查。首次拉镜像耗时较长。

注意,若之前已装过,检测到/usr/local/services/cubetoolbox/.one-click.env
存在(detect_existing_install,common.sh:1262)时,--yes会触发
config-preserving upgrade,保留旧配置。要强制全新安装用--mode=install。


五、两个ARM64关键坑与解法
-------------------------

按上述流程首次install会卡在启动control.target,以下是两个ARM特有坑的
定位与解法,也是本次部署的主要调试内容。


## 5.1 坑一:cn镜像仓库只有amd64单架构

现象:install.sh卡在systemctl enable --now control.target。查服务状态,
coredns/cubelet起来了,mysql/redis/minio/proxy/egress全部activating不就绪。
cube-egress容器Exited(1),日志报:

```
exec /usr/local/openresty/nginx/sbin/start.sh: exec format error
```

exec format error是架构不匹配。docker image inspect确认:cn仓库拉下来的
cube-proxy/cube-egress/cube-lifecycle-manager都是amd64,在aarch64上无法执行。

根因:MIRROR=cn选中的cn镜像仓库(cube-sandbox-cn.tencentcloudcr.com),对
CubeSandbox自有组件镜像只发布了amd64单架构。而int仓库
(cube-sandbox-int.tencentcloudcr.com)是多架构(amd64+arm64)。用docker
manifest inspect对比可证实int的cube-proxy/egress/lcm均含arm64。opensource
依赖(mysql/redis/coredns走cube-sandbox-image.*仓库)本身多架构,不受影响。

镜像地址不落盘,是各up-*.sh启动时按MIRROR现算的:留空取int默认,MIRROR=cn
取cn默认,显式CUBE_SANDBOX_*_IMAGE最优先(如cube-egress-start.sh:32-39)。

解法:改持久化配置里的MIRROR为空,重启相关服务即可(无需重装)。注意改
bundle的.env无效,因为upgrade合并时旧.one-click.env优先。要改的是:

```bash
# /usr/local/services/cubetoolbox/.one-click.env
sudo sed -i 's/^MIRROR=.*/MIRROR=/' /usr/local/services/cubetoolbox/.one-click.env
sudo systemctl restart cube-sandbox-minio cube-sandbox-cube-proxy \
  cube-sandbox-cube-lifecycle-manager cube-sandbox-cube-egress
```

改后egress用arm64镜像正常启动,openresty日志显示OS: Linux ...aarch64,
worker进程正常。日志里setrlimit(RLIMIT_NOFILE)failed是无害warning。

最省事的做法是首次install前就在.env里保持MIRROR空,从根上避免此坑。


## 5.2 坑二:docker-compose v1.22与Python3.11不兼容

现象:切int后egress(不用compose,直接docker create)起来了,但mysql/redis/
minio/proxy/lcm/webui仍失败,systemctl显示这些服务ExecStart status=1/FAILURE。

手动跑一次compose复现真实报错:

```bash
cd /usr/local/services/cubetoolbox/support
docker-compose -f docker-compose.yaml up -d minio
```

报:

```
TypeError: kwargs_from_env() got an unexpected keyword argument 'ssl_version'
```

根因:openEuler自带的docker-compose是v1.22.0(2018年的老版本),与系统
Python3.11里新版docker库不兼容,ssl_version参数已被移除。凡走compose的
服务全部启动失败。egress例外是因为cube-egress-start.sh直接docker create,
不经compose。

CubeSandbox的compose封装是先试新版再退回老版(support-compose-lib.sh:16-22):

```bash
if docker compose version >/dev/null 2>&1; then   # 优先v2插件
    docker compose -f ... "$@"
elif command -v docker-compose ...; then           # 才退回坏掉的v1
    docker-compose -f ...
```

解法:装官方docker compose v2插件,脚本会自动优先用它。openEuler仓库无v2
插件包,用官方二进制(aarch64,约57MB):

```bash
sudo mkdir -p /usr/libexec/docker/cli-plugins
sudo curl -fSL -o /usr/libexec/docker/cli-plugins/docker-compose \
  https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-linux-aarch64
sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose
docker compose version   # 显示 v5.5.1 即成功
```

注意插件目录默认不存在,必须先mkdir -p。装好后手动实测一次能拉起容器:

```bash
cd /usr/local/services/cubetoolbox/support
docker compose -f docker-compose.yaml up -d mysql   # Container ... Running
```

确认v2可用后,重启整套服务:

```bash
sudo systemctl restart cube-sandbox-control.target
```

control.target会等下属服务全部就绪才返回,拉镜像+健康检查需一两分钟,
systemctl不立即返回属正常。


六、服务验证
------------

重启后全部核心服务active,control.target为active:

| 服务 | 状态 |
|------|------|
| mysql redis minio | active |
| cubemaster cubeops cube-api | active |
| cubelet | active |
| cube-proxy cube-egress | active |
| lcm webui dns | active |
| s3lvol | inactive(S3逻辑卷,单节点可选) |

监听端口:cube-api 3000、cubemaster 8089、cubeops 3010、WebUI 12088。

官方健康检查(需root):

```bash
sudo ~/tests/cube/cube-sandbox-one-click-v0.7.0-arm64/smoke.sh
```

smoke.sh通过,确认cube-api /health正常,部署健康。WebUI控制台可浏览器
访问 http://<节点IP>:12088。


七、端到端验证与EOF根因(VPN代理坑)
------------------------------------

部署本体就绪后做端到端验证:建模板、起沙箱。过程中一度卡在cubemastercli
建模板报错,排查后确认是客户端代理问题,并非CubeSandbox缺陷。全链路最终
跑通。这也是第三个ARM/环境相关的坑,值得单列。


## 7.1 现象:0.0.0.0的EOF/400

用cubemastercli默认命令建模板,报错:

```text
Post "http://0.0.0.0:8089/cube/template/from-image": EOF
```

换个时刻同一命令又变成HTTP 400。诡异点:cubemaster服务active、NRestarts=0
(未崩溃),8089也在*:8089正常监听,服务端日志无对应报错。


## 7.2 定位:直连失败,过中继反而成功

把cubemastercli实际发出的请求抓出来(本地起监听端口顶替8089),再分别打
真实服务,对比:

```text
curl直连127.0.0.1:8089            -> Empty reply from server(即EOF)
cubemastercli默认地址(0.0.0.0)    -> HTTP 400
经透明TCP中继转发到127.0.0.1:8089  -> 200 成功,job PENDING
```

同一个服务,直连失败、过中继反而成功,说明问题在客户端出站路径。查环境
变量,真相大白:

```text
http_proxy=http://10.0.2.2:8118
https_proxy=http://10.0.2.2:8118
```

VPN设了全局代理,且没有no_proxy。


## 7.3 根因:0.0.0.0不在代理绕过名单

cubemastercli的默认server地址是0.0.0.0(全局选项--address默认值),据此拼出
URL http://0.0.0.0:8089并带Host: 0.0.0.0:8089。Go的http代理自动绕过只认
127.0.0.1/localhost/::1,不认0.0.0.0,于是该请求被塞进VPN代理10.0.2.2:8118,
代理无法处理loopback便掐断连接,客户端看到EOF(代理在另一时刻返回400)。
curl同理:libcurl不自动绕过localhost,凡配了http_proxy一律经代理,故curl
直连也是EOF;加--noproxy '*'直连立刻200。

系统内部服务不受影响(smoke.sh能过),因为systemd unit不继承用户shell里的
http_proxy,守护进程间的127.0.0.1调用本就是直连。此坑只在带代理的交互
shell里手动跑cubemastercli/curl时出现。


## 7.4 解法

二选一,建议都做:

```bash
# 1) 给cubemastercli显式指定loopback地址(loopback自动绕过代理)
cubemastercli -a 127.0.0.1 tpl ls

# 2) 或在shell里设no_proxy,覆盖0.0.0.0与本机IP
export no_proxy=127.0.0.1,0.0.0.0,localhost,10.0.2.15
export NO_PROXY=$no_proxy
```


## 7.5 端到端验证通过

绕开代理后,全链路跑通。建模板(OCI镜像转ext4 rootfs,注意ARM64同样用int
仓库):

```bash
cubemastercli -a 127.0.0.1 tpl create-from-image \
  --image cube-sandbox-int.tencentcloudcr.com/cube-sandbox/sandbox-code:latest \
  --writable-layer-size 1Gi \
  --expose-port 49999 --expose-port 49983 --probe 49999
```

job经PULLING很快到READY:11/11层拉取完成、artifact转ext4为READY、
distribution 1/1 ready。tpl ls显示模板STATUS=READY。

起沙箱(真实KVM MicroVM):先render拿到该模板的沙箱创建请求存为req.json,
再multirun拉起:

```bash
cubemastercli -a 127.0.0.1 tpl render --template-id <tpl-id> --json > render.json
python3 -c "import json;d=json.load(open('render.json'));json.dump(d['api_request'],open('req.json','w'))"
cubemastercli -a 127.0.0.1 multirun --printall --fail_exit req.json
```

结果:doCreateSandbox code:200,分到沙箱IP 192.168.1.51,49999端口的HTTP
就绪探针通过(sandbox-probe约3s),cube-e2e约4s,随后doDestroySandbox
Success,totalRunSuccCnt:1、totalRunErr:0。

至此aarch64上从镜像到可服务沙箱的完整链路(OCI拉取→ext4转换→MicroVM
启动→应用就绪探针通过→销毁)验证通过,部署可用。


## 7.6 进入运行中的沙箱(相当于SSH)

sandbox-code镜像跑的是E2B的envd,不开sshd,进沙箱走cubecli exec。先起一个
常驻沙箱(--norm建完不删),再exec进去:

```bash
# 起常驻沙箱(非root),记下打印的sandBoxId
cubemastercli -a 127.0.0.1 multirun --norm --printall /tmp/req.json

# 看在跑的沙箱、拿id
cubemastercli -a 127.0.0.1 cubebox ls

# 进沙箱,-it是交互式shell
sudo cubecli exec -it <sandBoxId> bash

# 用完销毁
cubemastercli -a 127.0.0.1 cubebox rm <sandBoxId>
```

注意权限分层:cubemastercli走HTTP到CubeMaster(8089),普通用户即可;cubecli
连的是Cubelet本地gRPC(/data/cubelet/cubelet.sock,权限srw-rw----root),
所以exec/cubebox等cubelet层命令都要sudo。镜像若无bash就换sh。


## 7.7 压测

CubeSandbox自带三层压测手段,由简到全:

一是内置压测,cubemastercli multirun本身就是bench,加并发runcc与循环runcnt
即可,输出各阶段延迟百分位(create/probe/e2e/destroy),无需编译。注意本机
嵌套虚拟化只能串行,runcc保持1(并发原因见7.8):

```bash
cubemastercli -a 127.0.0.1 multirun \
  --runcnt 10 --runcc 1 --percents "0.5,0.9,0.99" --printall /tmp/req.json
```

二是源码examples/cube-bench,Go写的,直打CubeAPI(E2B)接口,带终端UI、可
导出JSON。它的go.mod要求go 1.25,而openEuler源里的golang是1.21.4;好在装
1.21.4后Go的GOTOOLCHAIN=auto会在编译时自动拉取1.25工具链(需联网),照样
能编:

```bash
sudo dnf install -y golang                    # 1.21.4,够引导
export PATH=$PATH:/usr/lib/golang/bin
make -C ~/CubeSandbox/examples/cube-bench     # 自动拉1.25工具链,产出bin/cube-bench
export no_proxy=127.0.0.1,0.0.0.0,localhost   # 打本机CubeAPI要绕代理
export E2B_API_URL=http://127.0.0.1:3000 E2B_API_KEY=local
export CUBE_TEMPLATE_ID=tpl-ebf00021329c474d91d89408
# 本机只能串行,-c 1;并发会失败,见7.8
~/CubeSandbox/examples/cube-bench/bin/cube-bench -m create-delete -c 1 -n 5
```

三是官方一键脚本tests/perf/cubebench.sh,覆盖冷启动延迟(3.2)、单机密度与
内存(3.3)、快照/回滚/克隆/暂停恢复(4.1-4.6):

```bash
bash ~/CubeSandbox/tests/perf/cubebench.sh sections   # 列可选章节
bash ~/CubeSandbox/tests/perf/cubebench.sh run 3.2     # 只跑冷启动延迟
bash ~/CubeSandbox/tests/perf/cubebench.sh run         # 全量
```

cubebench.sh两个前提要记牢:每次测量前它会销毁所有沙箱,别在有数据的环境
上跑;且要先把Cubelet的host.quota调大(dynamicconf/conf.yaml的mvm_limit、
mem_limit、creation_concurrent_num),否则很快报no more resource。另外3.x
章节需先make cube-bench,4.x章节需python3-venv联网装SDK。


## 7.8 压测实测:嵌套虚拟化下只能串行创建

在本机(嵌套KVM虚机)用cube-bench做并发压测会失败,这是又一个环境相关的
坑。现象:create-only或并发-c大于1时,5个请求全挂,cube-bench报:

```text
create HTTP 408:                        # 卡满30s超时
create HTTP 500: ...reset guest time failed:ttrpc err: Receive packet timeout
```

Cubelet日志(Cubelet-req.log)对应报错:

```text
Create sandbox failed:reset guest time failed:ttrpc err: Receive packet timeout Elapsed(())
```

根因:创建沙箱时shim(containerd-shim-cube-rs)要给新起的guest做一步reset
guest time,经ttrpc与guest内agent通信。并发拉起多个MicroVM时,嵌套虚拟化下
CPU抢占严重、guest agent起得慢,这个ttrpc调用收包超时,创建随即失败;其余
请求直接卡满30s报408。单个创建(-c1 -n1)则一直稳定成功。

解法:这台机器能压测,但只能串行。用-c 1,并优先create-delete(建完即删,
不堆积沙箱):

```bash
~/CubeSandbox/examples/cube-bench/bin/cube-bench -m create-delete -c 1 -n 5
```

实测串行结果(create-delete,-c1 -n3):成功率100%,CREATE延迟约4.7-4.8s、
DELETE约1.7-1.9s。CREATE这4秒多就是MicroVM冷启动量级(cube-bench评级D是按
快照热启动定的线,非故障)。要跑并发/高密度压测,得换非嵌套的裸金属宿主,
并按cubebench.sh要求调大Cubelet的host.quota。


## 7.9 冷启动为何比官方慢:延迟拆解

官方基准(裸金属2vCPU/2GiB,blog性能基准3.2,同样用cube-bench create-only)
串行冷启动约48ms、持续sub-100ms。本机实测约3s,差约两个数量级,拆开看
(multirun --printall空载串行3次):

```text
cube-e2e(总创建)         2757 .. 3311 ms   (p50 3216)
  sandbox-probe(app就绪)   1826 .. 2429 ms   (p50 1829)   <- 大头
  VM创建+guest agent       约 900 .. 1400 ms              <- 剩余
```

两个原因叠加,并非"嵌套虚拟化慢100倍":

一是口径不同,占大头。本机模板带--probe 49999,cube-bench/multirun的create会
一直等到guest内代码解释器在49999答/health才算完成,这段约2s。官方那条是
create-only且模板无就绪探针,create在VM起来即返回,压根不含app启动。去掉
探针即可对齐口径。cube-bench(走E2B层)测出的4s多比multirun的3s更高,是多了
E2B一层且当时机器有负载。

二是嵌套虚拟化开销,真实但有限。纯VM创建+guest agent约1s,对比裸金属约48ms
是约20倍。嵌套KVM下每次VM操作要多陷入一层L0,boot、时钟、事件上报都变慢,
这是合理量级,不是100倍。

三者同源:建模板[6/7]偶发Receive event timeout after 10000ms(重试即可)、
并发创建reset guest time ttrpc超时(7.8),以及这里app就绪偏慢,根子都是
guest在嵌套虚拟化下响应慢、逼近内部超时线。想要接近官方数字,需裸金属或
支持良好的硬件虚拟化宿主,并用无探针模板对齐测量口径。


八、最小复现步骤汇总
--------------------

在一台干净的aarch64 openEuler机器上,把上面拆散的步骤合并为最短路径:

```bash
# 1. 前置:docker + compose v2 + XFS
sudo dnf install -y moby-engine moby-client xfsprogs
sudo systemctl enable --now docker
sudo mkdir -p /usr/libexec/docker/cli-plugins
sudo curl -fSL -o /usr/libexec/docker/cli-plugins/docker-compose \
  https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-linux-aarch64
sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose
sudo mkdir -p /data/cubelet
sudo truncate -s 20G /var/lib/cube-xfs.img && sudo mkfs.xfs /var/lib/cube-xfs.img
sudo mount -o loop /var/lib/cube-xfs.img /data/cubelet

# 2. 下载解压一键包
mkdir -p ~/tests/cube && cd ~/tests/cube
wget -c "https://github.com/TencentCloud/CubeSandbox/releases/download/v0.7.0/cube-sandbox-one-click-v0.7.0-arm64.tar.gz"
tar -xzf cube-sandbox-one-click-v0.7.0-arm64.tar.gz
cd cube-sandbox-one-click-v0.7.0-arm64

# 3. 配置(关键:MIRROR保持空=int多架构)并安装
cp env.example .env
sudo ./install.sh --yes 2>&1 | tee ~/tests/cube/install.log

# 4. 验证:健康检查 + 端到端(建模板起沙箱)
sudo ./smoke.sh
export no_proxy=127.0.0.1,0.0.0.0,localhost   # 有VPN代理时必须,见第七章
cubemastercli -a 127.0.0.1 tpl create-from-image \
  --image cube-sandbox-int.tencentcloudcr.com/cube-sandbox/sandbox-code:latest \
  --writable-layer-size 1Gi --expose-port 49999 --probe 49999
cubemastercli -a 127.0.0.1 tpl ls          # 等STATUS=READY
```

关键点提炼:aarch64必须用int镜像仓库(MIRROR空),且必须有可用的docker
compose v2;这两点在干净安装前备好,可一次装成,不必经历第五章的两轮
返工。第三点是若shell里有VPN代理(http_proxy),调cubemastercli要用
-a 127.0.0.1或设no_proxy,否则0.0.0.0被代理劫持报EOF/400(第七章)。


九、参考文件
------------

部署脚本(bundle内,基于v0.7.0-arm64):

```
install.sh                              一键安装主脚本
lib/common.sh                           公共函数(root/docker/detect检查)
scripts/one-click/support-compose-lib.sh  compose命令选择
scripts/systemd/cube-egress-start.sh    egress镜像地址与启动
down.sh smoke.sh env.example
```

部署产物目录:

```
/usr/local/services/cubetoolbox/        安装根
  .one-click.env                        运行时配置(MIRROR等)
/data/cubelet/                          Cubelet数据(XFS)
/data/log/{CubeMaster,Cubelet,CubeAPI}/ 各组件日志
~/tests/cube/                           本次下载与部署文件
```

官方文档:docs/guide/bare-metal-deploy.md、self-build-deploy.md、
downloads.md。
