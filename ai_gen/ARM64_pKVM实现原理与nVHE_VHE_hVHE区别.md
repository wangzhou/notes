ARM64 pKVM实现原理与nVHE/VHE/hVHE区别
===

-v0.1 2026.07.20 Sherlock init

简介:总结ARM64上KVM三种运行模式(nVHE/VHE)的实现区别,重点分析pKVM
如何在nVHE布局上反转信任模型把guest保护起来,辨析host被降权后是否等同
于guest,并说明当硬件把HCR_EL2.E2H固定为1(VHE-only)后,pKVM如何借助
hVHE继续运行。核心结论:能否跑pKVM取决于host在不在EL2,与E2H取值正交。


## 背景:EL模型与nVHE分裂问题

ARM64有四个异常级:EL0用户态、EL1内核态、EL2 hypervisor、EL3 firmware。
三种KVM模式的根源在于host内核跑在哪个EL,以及EL2里放什么、谁信任谁。

ARMv8.0的EL2是"残废"的:它不是为跑通用OS设计的(没有EL1那样的TTBR1,
寄存器布局也不同),而Linux是按"跑在EL1"写的。于是最初的KVM/ARM必须把
自己劈成两半,host留在EL1,只把一小段世界切换代码放进EL2,这就是nVHE的
由来。

ARMv8.1的VHE(Virtualization Host Extensions)扩展让EL2能直接跑通用OS,
消除了这个分裂。pKVM则是在nVHE基础上反转信任模型,让EL2反过来保护guest
不被host窥探。


## 基础模式:nVHE与VHE

pKVM建立在nVHE之上,而hVHE是nVHE与VHE的混血,所以先讲清这两种基础模式。


### nVHE(non-VHE,经典分裂模式)

布局:host内核在EL1,EL2只放一小段世界切换代码。

实现要点:

1. EL2代码单独编译,位于arch/arm64/kvm/hyp/nvhe/,产物用objcopy加
   __kvm_nvhe_前缀,链进独立section,与主内核不共享地址空间。
2. EL2有自己的页表(hyp idmap加hyp VA空间),自己的per-CPU,用TPIDR_EL2
   定位。
3. host跑guest要发HVC陷入EL2,世界切换代码保存host完整EL1上下文、加载
   guest状态,再eret到EL1跑guest,退出反向来一遍。
4. 地址转换用kern_hyp_va()把内核VA转成hyp VA(运行期patch的固定偏移),
   因为两个地址空间不同。
5. EL2与EL1的系统寄存器是两套独立的,访问guest的EL1寄存器直接用_EL1编码。

代价:每次host与hyp之间切换都要跨EL1/EL2边界,保存恢复整套EL1 sysreg,
开销大。


### VHE(ARMv8.1+,现代默认)

布局:host内核整个跑在EL2,不再分裂,guest仍在EL1。

核心机制:

1. HCR_EL2.E2H=1(配合TGE)开启VHE。开启后EL2获得类似EL1的能力,有了
   TTBR1_EL2,支持高低地址分离。
2. 寄存器重定向:E2H=1时,EL2执行MRS/MSR访问_EL1会被硬件重定向到对应
   的_EL2寄存器。于是按EL1写的host内核无需改动,访问TTBR0_EL1实际命中
   TTBR0_EL2。要访问guest真正的EL1寄存器时,用_EL12编码。
3. 内核用read_sysreg_el1()/write_sysreg_el1()宏封装,底层是ALTERNATIVE,
   被ARM64_HAS_VIRT_HOST_EXTN这个cap patch成_EL12(VHE)或_EL1(nVHE)。
4. 世界切换代码就是普通内核代码,位于arch/arm64/kvm/hyp/vhe/,直接链进
   vmlinux,和host同地址空间。kern_hyp_va()退化为恒等映射。
5. 进hyp不需要HVC:kvm_call_hyp()在VHE下是直接函数调用(nVHE下才是HVC)。
   跑guest时host无需切EL,只在EL2内部换到guest的EL1状态,eret下去。

收益:世界切换不跨EL、不用整套EL1上下文搬运,延迟显著低于nVHE。


### 两种模式的EL布局对比

```
              nVHE (E2H=0)          VHE (E2H=1)

EL2           hyp stub              HOST kernel
              (world-switch)        (host runs here)

EL1           host + guest          guest only

EL0           host/guest apps       host/guest apps
```

VHE的关键就是把host从EL1抬进了EL2。记住这一点,后面判断pKVM能否运行全
靠它。


## pKVM:信任模型反转

前提:pKVM只在nVHE布局下实现(kvm-arm.mode=protected),host仍在EL1,
hyp在EL2。

它和普通nVHE的根本区别是信任模型反转。普通nVHE/VHE中host完全可信,能随
意读写guest内存(migration、virtio都依赖此);pKVM中host不可信,EL2 hyp
负责把guest保护起来,即使host内核被攻破也读不到guest数据。典型场景是机密
计算和Android AVF(Android Virtualization Framework)。


### 实现要点

1. hyp变成自包含的最小hypervisor,不再只是世界切换代码。相关文件在
   hyp/nvhe/下:mem_protect.c(host/guest的stage-2与页所有权)、pkvm.c
   (EL2侧VM/vCPU管理)、page_alloc.c(hyp自己的页分配器)、hyp-main.c
   (HVC dispatch)、setup.c(初始化)。
2. host也被套上stage-2:启动时hyp接管所有stage-2翻译,host变成一个近似
   1:1映射的受管实体。这一步叫host de-privilege,__pkvm_init之后host失去
   对EL2的自由控制。
3. 页所有权跟踪:hyp维护每页的owner(host/hyp/某guest)与share状态。创建
   guest时,guest内存从host的stage-2中解除映射,host再也访问不到。
4. guest状态放在hyp私有内存:普通模式下struct kvm_vcpu(含guest寄存器)在
   host内存里、host随便读写;pKVM下权威guest状态(struct pkvm_hyp_vcpu)在
   hyp保护内存,host退出时只能看到被过滤的最小子集(如需要它处理的MMIO)。
5. 固定且受校验的HVC ABI:host只能调用一组枚举好的__pkvm_*调用(如
   __pkvm_host_share_guest、__pkvm_host_donate_guest等),hyp对来自不可信
   host的所有入参做校验。
6. I/O:protected guest用bounce buffer(guest内swiotlb)显式share页给host
   做virtio,因为host看不到guest普通内存。


## host被降权:像guest还是不像

一个常见困惑:pKVM给host套了stage-2后,host是不是就变成了一个guest?
准确说法是host被关进了一个内存牢笼,而不是变成了guest。

需要先厘清:host像guest这件事是pKVM的属性,与hVHE无关。hVHE只负责把EL2
的寄存器视图切成E2H=1;把host用stage-2管起来的是pKVM的de-privilege那步。
所以经典nVHE-pKVM和hVHE-pKVM在这点上完全一样;而普通(非protected)模式
里host根本不套stage-2,更谈不上像guest。


### 像guest的地方(就一条,但关键)

pKVM给host建了一张host stage-2页表,用的是和guest完全相同的stage-2硬件
机制。于是host访问不属于它的页(被捐给某guest、或属于hyp的页)会触发
stage-2 abort陷入EL2,和guest踩到未映射IPA是同一套路径。这就是host不可信
能落地的物理基础:不靠软件检查,靠硬件二级翻译把它圈住。


### 不像guest的地方(定义guest的属性都不成立)

| 维度 | host(被pKVM降权) | 真正的guest |
|---|---|---|
| 地址 | 恒等映射,IPA约等于PA,看到真实物理地址 | 有真正的地址虚拟化 |
| 调度 | 在EL1原生运行,是它发HVC让EL2跑vCPU | 被EL2换进换出 |
| 硬件访问 | 直接摸真实硬件(timer/GIC/设备) | 被trap-and-emulate |
| 内存归属 | 初始拥有全部内存,guest内存从host划出 | 内存被分配给它 |
| 信任语义 | 对机密性不可信,但仍是受信任的资源管理者 | 完全被管理 |

注意,控制关系是反的:host是那个发HVC让EL2去跑guest vCPU的人。它甚至能靠
拒绝调度把guest饿死(DoS),而这属于pKVM威胁模型之外。真正的guest没有这种
权力。

结论:host被降权加用恒等映射的stage-2圈进内存沙盒,所以在"会被EL2挡内存"
这层像guest;但它仍原生运行、掌管调度与分配,只是被蒙住眼睛看不见guest
内存,是个被限制的管理者,不是被虚拟化、被调度、被模拟的guest。


## VHE-only硬件与hVHE

ARM有新特性会使HCR_EL2.E2H变成RES1(恒为1、不可写0),由ID寄存器
ID_AA64MMFR4_EL1.E2H0描述:某个编码值表示该实现不再支持E2H=0,即架构上
只保留VHE布局。ARM这样做是为了甩掉非VHE(split-mode)这个历史包袱,未来的
核会走这条路。


### 为什么这会威胁pKVM

pKVM只在nVHE布局(E2H=0)下实现。E2H恒为1意味着经典nVHE根本进不去。如果
没有别的办法,VHE-only硬件就只能跑普通VHE KVM(host上EL2、host可信),
拿不到pKVM的隔离能力。


### 解决办法:hVHE模式

hVHE(hypervisor VHE)让nVHE那套hypervisor(pKVM就建在其上)在E2H=1下
运行,但host仍留在EL1。它是nVHE和VHE的混血,约在Linux 6.6(2023)合入。
它同时保留了两边的关键属性:

| 属性 | 取自哪种模式 |
|---|---|
| host运行在EL1 | 像nVHE(host不可信、需de-privilege的模型不变) |
| EL2是独立自包含的hyp,自己的页表、TPIDR_EL2、受限HVC ABI | 像nVHE |
| EL2用E2H=1运行 | 像VHE(满足RES1硬件) |
| kern_hyp_va()仍做VA变换 | 像nVHE(hyp和host不同地址空间) |
| is_kernel_in_hyp_mode()仍为false | 像nVHE(host不在EL2) |

所以从host视角看它还是nVHE,只是底层EL2的寄存器视图切成了VHE布局。三种
布局放在一起看:

```
              nVHE (E2H=0)      VHE (E2H=1)       hVHE (E2H=1)

EL2           hyp stub          HOST kernel       hyp (self-contained)

EL1           host + guest      guest             host + guest

EL0           apps              apps              apps

can pKVM?     yes               NO                yes
```


### 关键的寄存器改写问题

这是hVHE唯一真正棘手的地方。E2H=1时,EL2代码访问_EL1会被硬件重定向到
_EL2。而nVHE的世界切换代码是按"_EL1即guest状态"写的,直接跑会全错。

hVHE的处理方式和VHE完全一致:

1. hyp要访问guest真正的EL1状态时,改用_EL12编码。
2. 复用早就存在的read_sysreg_el1()/write_sysreg_el1()宏,底层是
   ALTERNATIVE。原本在nVHE下patch成_EL1、VHE下patch成_EL12;hVHE让这套
   访问器按E2H是否置位来选,而不是按host是否在hyp mode。于是同一份hyp
   代码在E2H=0/E2H=1两种情况下都正确。
3. hyp自己的EL2配置继续用_EL2直接访问,不受影响。

host那边反而最省事:host在EL1,E2H只影响EL2自己的寄存器视图,所以未改动
的nVHE host在EL1用真正的_EL1寄存器正常跑。


### 内核的实际行为

1. 启动时el2_setup读ID_AA64MMFR4_EL1.E2H0:发现E2H是RES1就保持E2H=1;
   若请求的是kvm-arm.mode=protected(或nvhe),就置上hVHE能力位,让hyp
   初始化走E2H=1路径。
2. 因此kvm-arm.mode=protected在VHE-only硬件上照常生效,只是内部落到hVHE。
3. 反过来,在支持E2H=0的硬件上也可以主动强制hVHE(过去主要用于测试这条
   路径)。
4. 隔离语义不变:hVHE纯粹是EL2的布局/寄存器管线适配,pKVM对guest内存的
   保护、host de-privilege、页所有权跟踪这些安全属性一个都不少。


## 澄清:VHE不实现pKVM,E2H与host EL正交

有一个很常见的错误等式:"E2H=1即VHE即host在EL2"。它错在第一个等号。


### 为什么VHE永远做不了pKVM

pKVM的保护逻辑必须放在一个host够不到的地方,也就是EL2。而VHE的定义就是
host自己整个跑在EL2。于是VHE里host就是EL2的占用者,它就是那个本该做保护
的人。让host去保护guest内存不被host看,等于让保险箱主人承诺自己不开保险
箱,钥匙在他手里,承诺没有意义。这跟E2H无关,是host在EL2这件事本身让
pKVM出局。


### E2H=1不等于host必须待在EL2

E2H只是EL2的一个寄存器位,它决定的是EL2内部的寄存器视图长什么样(VHE式
布局),它不决定host跑在哪个EL。CPU从firmware进内核时人在EL2,内核启动
代码此刻有的选:

1. 就地留在EL2跑,得到VHE。
2. 在EL2装好一个独立hyp,然后eret下到EL1去跑host,得到hVHE(E2H照样为1)。

E2H恒为1只是禁掉了EL2用nVHE那种旧布局,它没禁掉把host放到EL1。换个直觉:
E2H描述的是EL2这个房间里家具怎么摆,不是host住哪个房间。


### 三者正交拆开看

| 模式 | host在哪个EL | E2H | EL2里是谁 | 能做pKVM |
|---|---|---|---|---|
| 经典nVHE | EL1 | 0 | 独立hyp | 能(pKVM老家) |
| VHE | EL2 | 1 | host自己 | 不能(host就在EL2) |
| hVHE | EL1 | 1 | 独立hyp | 能(VHE-only硬件上的pKVM) |

一眼看出:能不能做pKVM只取决于host在不在EL2、EL2里是不是独立hyp,和E2H
的值无关。VHE和hVHE都E2H=1,一个能一个不能,差别纯粹在host的EL。


## 小结

1. nVHE追求兼容老硬件,是经典分裂式;VHE追求性能,host上EL2消除分裂;
   pKVM是在nVHE之上追求隔离/机密性,让EL2反过来保护guest。
2. pKVM要的是host之上还有一个host碰不到的EL2。撑起这句话的是host待在
   EL1,不是E2H等于几。
3. VHE把host塞进EL2所以出局;hVHE在E2H=1下依然把host留在EL1,EL2留给独立
   hyp,所以pKVM照跑。这正是pKVM在未来只有VHE的ARM核上继续存活的方式。
4. host在pKVM下被降权成一个被蒙眼的资源管理者,不是guest。


## 参考

内核代码:

1. arch/arm64/kvm/hyp/nvhe/ - nVHE世界切换代码与pKVM hyp
2. arch/arm64/kvm/hyp/vhe/ - VHE世界切换代码
3. arch/arm64/kvm/hyp/nvhe/mem_protect.c - host/guest stage-2与页所有权
4. arch/arm64/kvm/hyp/nvhe/pkvm.c - EL2侧VM/vCPU管理
5. arch/arm64/kvm/arm.c、arch/arm64/kernel/hyp-stub.S、head.S - el2_setup
   与模式选择

系统寄存器/接口:

1. HCR_EL2.E2H/TGE - VHE开关
2. ID_AA64MMFR4_EL1.E2H0 - 描述E2H是否RES1(VHE-only)
3. kvm-arm.mode=nvhe/protected - 启动参数强制模式
4. read_sysreg_el1()/write_sysreg_el1() - _EL1与_EL12访问器的ALTERNATIVE

相关笔记:

1. [[ARM64_KVM嵌套虚拟化FEAT_NV2_NV3分析]] - E2H=1的VHE型L1与NV模型
2. [[kvm_stage2_page_table_walk]] - stage-2页表机制
