ARM虚拟化开发者切入AI沙箱研究计划
================================

-v0.1 2026.09.06 Sherlock init

简介：针对ARM KVM虚拟化背景的开发人员，基于对CubeSandbox/AgentENV/
firecracker的分析结论，规划切入ARM AI沙箱技术研究与开发的路线。
内容包括定位分析、分阶段计划、优先级矩阵、需要补充的知识和里程碑。
作者：Sherlock。


## 一、定位：为什么ARM虚拟化背景正好切入

AI沙箱的两条技术线(CubeSandbox的cube-hypervisor、AgentENV的
firecracker)都在x86上成熟，ARM上存在真实的功能和工程缺口：

1. 功能缺口：CubeSandbox的soft-dirty增量快照在arm64不可用
   (CONFIG_MEM_SOFT_DIRTY依赖HAVE_ARCH_SOFT_DIRTY)，静默退化；
   需要uFFD-WP或KVM dirty log方案补位。
2. 性能缺口：arm64 KVM dirty log全软件路径(写保护+拆页+缺页)，
   没有x86 PML等价物，快照密集场景成本高；THP与快照无协同。
3. 工程缺口：两系统均无ARM KVM E2E测试，ARM支持停留在编译层面；
   64KiB页问题只修了一处。
4. 前沿空白：CCA/RME与快照/恢复的关系无人定义。

这些缺口的共同点是都在虚拟化层，而不是AI层。ARM虚拟化背景开发
者不需要懂RL训练，缺的是对"快照/恢复/克隆"这条主线的深度理解，
而这条线恰好是KVM/arm64、stage-2、GIC、异常处理这些已有功底的
直接延伸。

## 二、阶段规划

### 阶段0(1-2周)：建立实验环境

- 找一台ARM裸机或云metal实例(m6g/m7g系列)，确认KVM可用
- 编译cube-hypervisor的aarch64版本并跑通快照/恢复/clone最小流程
- 部署AgentENV单机版(它的quick start只要求KVM和内核6.8+)，复现
  pause/resume/fork
- 跑通firecracker上游的snapshot集成测试(test_snapshot.py)，
  建立自己的metrics.json采集习惯
- 产出：一张ARM上三系统能力实测矩阵

### 阶段1(1-2月)：快照/恢复主线深挖

- 精读firecracker的persist.rs、vstate/memory.rs、aarch64/vcpu.rs、
  gic/regs.rs，理解MicrovmState布局与保存顺序约束
- 对照读cube-hypervisor的vm_snapshot/vm_restore与soft_dirty.rs，
  理解pagemap方案与KVM dirty log方案的取舍
- 对照读AgentENV的overlaybd_snapshot.rs与process_vm_reader.rs，
  理解dirty-memory-ranges+跨进程取页方案
- 在ARM上实测三种脏页追踪的成本：开dirty tracking的恢复后首次写
  延迟、KVM_GET_DIRTY_LOG周期、快照时间随脏页量曲线
- 产出：快照/恢复主线技术笔记(本仓库的三篇分析即起点)+一组
  ARM实测数据

### 阶段2(2-3月)：选一个ARM特有缺口做出贡献

四个候选(按推荐度排序)：

- 选项A：ARM KVM E2E测试建设。给CubeSandbox或AgentENV补aarch64
  CI和快照E2E，门槛低、可见度高、社区容易接受，顺带建立声誉。
- 选项B：CubeSandbox的ARM增量快照替代方案。用uFFD-WP或KVM
  dirty log实现arm64可用的增量路径，替代不可用的soft-dirty。
  这是把两个系统的优点在ARM上缝合的实打实功能开发。
- 选项C：64KiB页适配补齐。梳理pagemap索引、THP对齐假设、内存
  摊销计算在64KiB下的剩余问题并修复。
- 选项D：arm64 KVM dirty log优化原型。基于kvm_age_gfn/AF机制
  做AF脏页汇报的原型补丁，试水KVM上游社区。

### 阶段3(3-6月)：性能优化研究

- THP/contig页与快照协同：恢复期2MB粒度脏收集，量化快照体积与
  恢复时间的改善
- 用ab_test.py的permutation方法建立自己的ARM回归设施(锁频、
  关DVFS、标注页大小)
- 复现并验证virtio-mem/MGLRU在ARM上的密度收益，与AgentENV的
  guest自驱动回收方案对比
- 产出：ARM上"冷启动/快照/恢复/clone/密度/抖动"六项benchmark的
  完整数据与一篇公开文章

### 阶段4(6月+)：软硬结合前沿

- 跟踪CCA/RME主线合入进度，重点读RMM的共享内存/委托接口设计，
  思考"强隔离+可快照"沙箱的形态
- 跟踪arm64 stage-2脏页硬件化的架构讨论(类PML的AF扩展)
- 若有芯片厂商资源，参与新特性的早期验证(MPAM带宽隔离、
  GICv4.1直注)

## 三、优先级矩阵

按三个维度打分：对AI沙箱的价值、ARM现状差距、与现有技能匹配度。

| 方向 | 价值 | 差距 | 匹配 | 推荐度 |
|------|------|------|------|--------|
| ARM KVM E2E测试建设 | 中 | 大 | 高 | 先做 |
| uFFD-WP增量快照替代soft-dirty | 高 | 大 | 高 | 重点 |
| THP/contig与快照协同 | 中高 | 中 | 高 | 重点 |
| ARM基准与回归设施 | 高 | 中 | 中 | 伴随做 |
| stage-2 AF脏页汇报(上游) | 高 | 大 | 高 | 中期 |
| virtio-mem/MGLRU密度 | 中 | 小 | 中 | 观察 |
| CCA/RME沙箱 | 战略 | 大 | 中 | 跟踪 |

## 四、需要补充的知识

1. Rust：三个系统的VMM和存储栈全是Rust(vmm、overlaybd、ublk、
   cubecow)，至少要能读能改。
2. 存储栈：overlaybd层链、ublk/io_uring、xfs reflink/FICLONE、
   对象存储布局。虚拟化背景通常只熟内存侧，存储侧是快照/克隆的
   另一半。
3. 性能工程：分层计时、分布统计、A/B permutation判定、环境固定
   (锁频/禁C-state/清page cache)。参考firecracker的tests/
   performance与tools/ab_test.py。
4. 上游社区：kvcache-ai/AgentENV、tencentcloud/CubeSandbox、
   firecracker-microvm、KVM/arm64邮件列表。前两个的ARM相关issue
   是最直接的工作入口。

## 五、里程碑

- M1(1-2周)：三系统在ARM上跑通快照/恢复/clone，输出能力矩阵
- M2(1-2月)：完成快照主线深挖，ARM实测脏页追踪成本数据
- M3(3月)：第一个上游贡献(E2E测试或ARM增量快照方案)，PR被合并
  或review认可
- M4(6月)：ARM六项benchmark完整数据+一篇公开技术文章
- M5(12月)：在"ARM AI沙箱虚拟化"方向上形成自己的差异化标签，
  例如dirty tracking优化或CCA沙箱原型

## 参考文件

- 同目录AI沙箱虚拟化技术分析.md 启动/快照/恢复/克隆机制
- 同目录AI沙箱性能测试指标与方法.md benchmark方案
- 同目录ARM平台AI沙箱软硬结合优化.md TOP 5方向
