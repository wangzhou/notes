ARM平台AI沙箱软硬结合优化
========================

-v0.1 2026.09.06 Sherlock init

简介：基于linux v7.2-rc4内核代码树证据，分析ARM平台上AI沙箱
(firecracker类microVM)的软硬件结合优化点。背景场景特征：海量短
生命周期microVM、毫秒级启动/恢复/克隆、高内存overcommit、快照
频繁落盘、镜像分层按需加载、多租户隔离。作者：Sherlock。


## 一、内存脏页追踪的硬件加速

现状：arm64 KVM dirty logging完全走软件路径(写保护+拆大页+缺页
标记)。使能日志时整段写保护并拆大页(kvm_arch_commit_memory_region，
arch/arm64/kvm/mmu.c:2572-2603)；CLEAR ioctl后按mask增量WP+拆页
(kvm_arch_mmu_enable_log_dirty_pt_masked:1325-1349)；写页故障时
mark_page_dirty_in_slot(:2089-2096)。核心原语是
kvm_pgtable_stage2_wrprotect(include/asm/kvm_pgtable.h:736)。

成本结构：每页首次写都触发EL2异常，加上mmu_lock上的扫描/拆页
竞争——这正是快照密集场景(AgentENV每轮pause都开dirty tracking)
的主要开销。对照x86：PML用硬件FIFO记录脏页地址，仅FIFO满才
vmexit(arch/x86/kvm/vmx/vmx.c:137,6161)，硬件化程度完全不同。

FEAT_HAFDBS现状：stage-1(宿主)的AF/DBM已启用；stage-2上硬件AF
目前只服务老化/回收——kvm_age_gfn/kvm_test_age_gfn(mmu.c:2447-2473)
经mmu_notifier回调(virt/kvm/kvm_main.c:833/855/864)清AF，guest再
访问触发access fault后kvm_pgtable_stage2_mkyoung恢复(:2144-2155)。
pKVM另有nvhe陷出路径(pkvm.c:527-560)。

优化方向：把现有AF机制扩展为dirty汇报(类PML语义)，消除写保护
拆页风暴。v7.2内核已有除"用AF报dirty"之外的全部地基——这是
最值得ARM虚拟化背景开发者切入的上游工作。

## 二、快照与恢复的软硬结合优化

1. arm64无HAVE_ARCH_SOFT_DIRTY：CRIU式soft-dirty差分在ARM不可用，
   CubeSandbox的SoftDirty路径退化到pagemap_anon(见主分析笔记4.3节)。
   替代品userfaultfd WP/minor均已支持(arch/arm64/Kconfig:254-255、
   pgtable.h:343/539)——uFFD-WP是ARM上做用户态增量快照/写时复制
   的主要手段，且清位成本由硬件DBM承担，软件代价远低于x86的
   soft-dirty PTE扫描。
2. KVM_MEM_READONLY/KVM_MEM_LOG_DIRTY_PAGES在arm64完整支持
   (mmu.c:2577,2632)，memslot"先只读、按需置脏"模式可用；但
   protected VM(pKVM)禁止dirty logging与READONLY(mmu.c:2624-2635)，
   快照方案与机密沙箱互斥——这是个硬约束。
3. THP问题：恢复后首轮全量脏标记会拆掉全部THP/contig映射
   (mmu.c:1310/1346 eager-split)，2MB拆成4K使随后的页粒度快照
   变慢、去重碎片化；transparent_hugepage_adjust(:1422)只认PMD级
   THP。建议恢复阶段关闭THP，或先AF/只读收集再按2MB粒度采脏。
4. memslot更新开销小：arm64无影子页表结构，kvm_arch_prepare_
   memory_region(mmu.c:2616-2703)纯校验。virtio-mem热插拔的
   memslot增删在ARM上代价低于x86。
5. MTE影响：启用Memory Tagging后每页多一份tag内存，快照体积增大
   (:2677)，tag状态本身也需要保存/恢复语义。

## 三、内存overcommit的软硬结合优化

1. virtio-balloon/virtio-mem是架构无关的paravirt设备(drivers/virtio/
   virtio_balloon.c、virtio_mem.c)。ARM上的价值在于与stage-2解绑：
   热拔出的页经memfd hole punch触发mmu_notifier->
   kvm_unmap_gfn_range(mmu.c:2434)自动清stage-2，无需KVM参与。
   virtio-mem粒度可到4K/2M，适合沙箱弹性内存。
2. MGLRU已主线化(mm/vmscan.c:885)：宿主按recency回收沙箱匿名页
   显著优于旧LRU，是密度关键。AgentENV的9.6x overcommit依赖的
   guest自驱动DAMON+free_page_reporting在ARM上同样可用。
3. zswap/zram与快照冲突：压缩内存页在快照读回时增加解压路径，且
   CRIU/KVM dirty位图按PFN对齐丢失；建议快照瞬时关闭zswap或按
   2M粒度刷盘。
4. KSM页在uFFD-WP下会分裂，ARM上无硬件加成，AI沙箱场景不建议
   依赖KSM做运行期去重(与主分析笔记6.2节结论一致)。

## 四、ARM特有能力

1. CCA/RME：v7.2-rc4主线尚未合入KVM RME支持(arch/arm64/kvm/下无
   rme.c，仅有FEAT_RME的feature校验config.c:186/1000与文档
   Documentation/arch/arm64/arm-cca.rst)。当前可交付的是pKVM：
   guest内存对宿主不可见(hyp/nvhe/mem_protect.c:564-618页所有权)，
   但pKVM下禁dirty log/balloon式回收(mmu.c:2631-2634)——"强隔离+
   快照"目前只能等RME的共享内存/委托接口成熟。
2. SVE/SME：guest支持SVE、不支持SME(fpsimd.c:87明示)。每vcpu
   sve_state按VL线性分配(kvm_host.h:1106-1120)，VL=2048bit时约
   9-10KB/vcpu；上下文切换需save+unbind宿主FP状态(fpsimd.c:46-99)。
   沙箱agent负载几乎不用SVE，应关闭KVM_ARM_VCPU_SVE，省切换开销
   与快照体积(快照要逐vq序列化KVM_REG_ARM64_SVE)。
3. GICv4/v4.1：vPE直注+doorbell(vgic-v4.c:70-100)使virtio中断
   绕过VMM注入、按vcpu亲和直达，v4.1消除并发注入的锁竞争(:94)。
   对毫秒级I/O延迟沙箱价值大，但依赖ITS直通到vPE的物理中断资源，
   云主机上通常不可得，裸金属私有集群可行。
4. NV2已支持(nested.c:1007)但对AI沙箱无用，略。

## 五、CPU侧优化

1. PMU虚拟化：guest PMU映射为宿主perf event(arch/arm64/kvm/pmu.c:
   17-40)，溢出注入需trap；沙箱密度高时PMU event计数与vcpu抢占
   叠加放大噪声。建议默认关guest PMU(firecracker ARM正是这么做的)。
2. 抢占/调度：KVM经preempt_notifier的sched_in/out(virt/kvm/
   kvm_main.c:6376-6389)。microVM恢复的尾延迟主要受宿主调度器与
   mmu_lock竞争影响，锁竞争正是dirty log软件路径放大出来的。
3. MPAM：主线已支持ARM64_MPAM(arch/arm64/Kconfig:2053-2076，经
   resctrl暴露)，arch/arm64/kernel/mpam.c。沙箱场景可做"关键租户
   内存带宽预留"缓解邻居噪声；前提是硬件PARTID/PMG使能。
4. 侧信道：主线无cache coloring；隔离靠EL2/pKVM与后续RME。

## 六、I/O路径

1. ARM上firecracker类沙箱常用virtio-mmio(drivers/virtio/
   virtio_mmio.c)：无MSI、中断走SPI/GIC，吞吐与多队列弱于
   virtio-pci+LPI。对I/O敏感的沙箱可评估PCI后端。
2. ublk(drivers/block/ublk_drv.c)+io_uring已成熟，适合"镜像分层
   按需加载"的用户态块后端，避免每镜像独占内核线程——AgentENV
   已验证这条路线。
3. SMMUv3直通：短生命周期设备直通需反复建/拆流+flush TLB，成本
   高；vCPU数少的沙箱应选virtio共享而非直通。主线arm-smmu-v3
   无pKVM stage-2支持。
4. ARM平台几乎全DMA-coherent(dma-direct)：virtio无需x86式bounce/
   sync开销——这是ARM microVM I/O相对x86的天然优势，benchmark
   对比时应单列。

## 七、按AI沙箱价值排序的TOP 5方向

1. stage-2硬件脏页追踪(AF扩展/未来RME代PML缓冲)：一次消灭WP+
   拆页风暴与每页首写EL2故障，快照成本降一个量级。现有kvm_age_gfn/
   AF框架就是跳板，且是ARM虚拟化背景开发者最能发力的上游方向。
2. 基于uFFD-WP+dirty ring的用户态差分快照链路(arm64已具备全部
   使能点)：让快照做到页粒度+增量+与balloon页共存，直接弥补
   CubeSandbox在ARM上soft-dirty缺位的问题。
3. THP/contig页与快照协同(恢复期2MB粒度脏收集与落盘去重)：直接
   缩小快照体积与恢复时间，纯软件、收益明确。
4. virtio-mem/MGLRU驱动的弹性密度层：让提交内存远大于物理内存，
   而回收不惊扰正在运行的agent任务。
5. CCA/RME多租户可信沙箱底座：跟踪其快照/恢复与脏页接口设计，
   要求不退化为pKVM式"不可快照"——这是唯一能把安全隔离和秒级
   克隆同时给到的路线。

## 参考文件

- linux/arch/arm64/kvm/mmu.c:1267,1295,1325-1349,2089-2096,2447-2473,2572-2703
- linux/include/asm/kvm_pgtable.h:736 stage-2写保护原语
- linux/arch/x86/kvm/vmx/vmx.c:6161 PML对照
- linux/arch/arm64/Kconfig:254-255 uffd-wp/minor支持
- linux/mm/vmscan.c:885 MGLRU
- linux/arch/arm64/kvm/fpsimd.c:46-99,87 SVE切换与SME不支持
- linux/arch/arm64/kvm/kvm_host.h:1106-1120 sve_state布局
- linux/arch/arm64/kvm/vgic/vgic-v4.c:70-100 vPE直注
- linux/arch/arm64/kvm/pmu.c:17-40 guest PMU映射
- linux/arch/arm64/Kconfig:2053-2076 MPAM
