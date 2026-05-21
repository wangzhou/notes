-v0.1 2025.10.7  Sherlock init
-v0.2 2025.11.22 Sherlock ...
-v0.3 2026.01.04 Sherlock ...
-v0.4 2026.01.05 Sherlock ...
-v0.5 2026.01.06 Sherlock ...
-v0.6 2026.01.07 Sherlock ...
-v0.7 2026.01.15 Sherlock ...
-v0.8 2026.03.13 Sherlock ...
-v0.9 2026.06.03 Sherlock ...

简介：使用本文持续整理ARM MPAM协议的相关内容，分析依据MPAM spec A.a。


需求
-----

现代服务器上运行多个用户的多个程序，硬件资源是共享的。我们可以通过类似cgroup的技
术对共享的硬件资源做调控，比如cgroup可以调控CPU和内存等资源。但是诸如cache使用、
内存带宽使用，软件难以直接做调控，这就需要引入新硬件，软件通过新硬件提供的接口做
资源调控。ARM上引入MPAM(memory partition and monitor)对内存相关的资源做控制和监
测。

对应的内存相关资源有：1. cache；2. 内部总线；3. 内存。控制的角度有使用大小和优先
级等。

概念和模型
-----------

MPAM使用一个全局唯一的三元组标记每个内存访问的源头，对于PE，这些信息需要配置到
MPAMx_ELn相关系统寄存器里，可以看到如果partition ID的语意就是PE本身，配置一次就
好，如果partition ID表示线程，就需要在线程切换的时候更新这个配置。在cache/内存控制器/
SMMU上增加MPAM控制节点(MSC(memory system compoment))，节点提供MMIO寄存器接口，这
些接口接受三元组的资源控制和监控的配置。相关配置提前配置好，系统运行的时候，访问
cache或者内存的请求根据提前配置的信息进行资源控制和监控。

三元组的三个元素是：partition ID space，partition ID，PMG(performance monitor group)。
partition ID space是安全态，主要用partition ID区分资源类型，PMG用来聚集一组监测
资源。MSC集成在各个内存相关的部件里，由专门的ACPI或者DTS MPAM表格报给OS。

MPAM协议里还定义了一些MPAM内部传递控制信息的概念(第四章)，感觉这些概念以及相关的
部件是软件较少感知的。

MPAM协议里简单描述了下硬件内部partitioning control的逻辑，简单讲就是当前使用的资
源和提前配置好的资源不断的做比较，如果还有余量就给分资源，反之就不给分资源。更近
一步看，capacity-based partitioning才需要这种动态调整，portion-based partitioning
(比如，直接配置可以用哪几个cache way的情况)的调整逻辑就可以比较简单。可以看到硬件
内部会用表格记录各种资源配置，如果这个表格在硬件内部，那么这个部件在使用中有低功
耗的上下电动作时，这些内容都要做保存和恢复。

MPAM只有两种类型中断：1. 报告错误的中断；2. monitor计数溢出中断。

MPAM的软硬件接口寄存器大致分为四类：ID寄存器，系统寄存器，control相关寄存器和monitor
相关的寄存器。ID寄存器配置MPAM MSC的各种规格，系统寄存器配置从流量源头带上的partition
ID和PMG。

注意，现代处理器实现都采用流水线技术，在单点控制相当于控制流水线中的一个点，容易
引发系统问题。另外，一旦系统里有共享部件，硬件逻辑综合起来就容易冲突，也可能引发
问题。

ID和系统寄存器
---------------

系统寄存器就是如上提到的：MPAMx_ELn

ID寄存器整理如下：
```
MPAMF_AIDR                    版本信息
MPAMF_IIDR                    厂商信息
MPAMF_IMPL_IDR                自定义特性信息
MPAMF_SIDR                    安全相关特性支持情况

MPAMF_IDR                     特性总体支持信息
MPAMF_CCAP/CPOR/CSUMON_IDR    cache相关信息
MPAMF_MBW/MBWUMON_IDR         memory相关信息
MPAMF_PRI_IDR                 优先级相关信息
MPAMF_PARTID_NRW_IDR          partition ID narrow相关信息
```

resource partitioning control
-------------------------------

软件需要配置MSC上各种资源的配置，这些配置用partition ID和RIS做标记。一个MSC上可能
同时支持多种不同类型的控制和监控，比如，同时支持memory和cache，RIS(resource instance
selection)就是对支持类型的标记。

软件需要用MPAMCFG_PART_SEL选择当前要配置的partition ID和RIS，然后配置对应的寄存，
配置选中partition ID和RIS对应的资源限制。

```
MPAMCFG_PART_SEL    配置partition ID和RIS

MPAMCFG_CASSOC      Cache Maximum Associativity Partition
MPAMCFG_CMAX        Cache Maximum Capacity Partition 配置cache使用的最大百分比
MPAMCFG_CMIN        Cache Minimum Capacity Partition 配置cache使用的最小百分比，
                    小于这个百分比的partition ID的优先级被提高，优先分cache。
MPAMCFG_CPBM<n>     Cache Portion Bitmap Partition 按照portion的配置寄存器。配置的方式:
                    1. 最大bit数，2. select出要配置的partition ID，3. 执行配置。

MPAMCFG_MBW_MAX     Memory Bandwidth Maximum Partition
MPAMCFG_MBW_MIN     Memory Bandwidth Minimum Partition
MPAMCFG_MBW_PBM<n>  Bandwidth Portion Bitmap Partition 
MPAMCFG_MBW_PROP    Memory Bandwidth Proportional Stride Partition
MPAMCFG_MBW_WINWD   Memory Bandwidth Partitioning Window Width 

MPAMCFG_PRI         Priority Partition
```

resource monitor
------------------

一个MSC上可能既有cache又有内存的monitor，相同种类里需要监控的partid和PMG又不一样，
对于某个type，特定partid和PMG的监控，需要先配置对应的监控控制寄存器，然后从对应的
counter里读监控得到的数据。

每个MSC中，某种类型实际的monitor counter又可以有多个。这个配置可以在对应的ID寄存器
里查到，比如memory的MPAMF_MBWUMON_IDR.NUM_NON定义这个MSC有多少个内部的counter，
MPAM里叫做monitor instance。

MPAM定义了一组控制寄存器和一个counter对外接口。所以，对于一个MSC，对于每个type，
每个instance，软件要先通过这些控制寄存器选择要配置的具体type/instance/partid+PMG，
再进行配置，或者读counter信息。

比如，先配置MSMON_CFG_MON_SEL.RIS选择type，MSMON_CFG_MON_SEL.MON_SEL选择instance，
MSMON_CFG_MBWU_FLT.PARTID/PMG选择partid+PMG。然后配置MSMON_CFG_MBWU_CTL启动对应
的监控行为，读MSMON_MBWU得到监控数据。

寄存器的具体定义如下：
```
MSMON_CFG_MON_SEL         monitor选择寄存器，MON_SEL选择instance，RIS选择type

MSMON_CAPT_EVNT           提供了一个软件控制接口把counter里的值保存到CAPTURE寄存
                          器里，写NOW触发这个保存动作。通过如下CTL寄存器可以配置

MSMON_CSU_CAPTURE         上次capture事件保存的cache使用量
MSMON_MBWU_CAPTURE        上次capture事件保存的带宽使用量
MSMON_MBWU_L_CAPTURE      MBWU长counter capture值

MSMON_CFG_CSU_CTL         CSU控制寄存器，TYPE配置触发capture的源头，写如上NOW是其中一种
                          PARTID/PMG过滤使能，EN使能monitor
MSMON_CFG_CSU_FLT         CSU过滤寄存器，PARTID/PMG配置要过滤的参数，XCL配置是否只记录被修改的cache line
MSMON_CFG_MBWU_CTL        MBWU控制寄存器，TYPE语义如上，各种overflow标记，EN使能monitor
MSMON_CFG_MBWU_FLT        MBWU过滤寄存器，PARTID/PMG语义如上，RWBW配置过滤只读/只写/读写

MSMON_CSU                 CSU counter，VALUE为cache使用量，NRDY指示数据是否就绪
MSMON_MBWU                MBWU counter(31位)，VALUE为带宽使用量，NRDY语义如上
MSMON_MBWU_L              MBWU长counter(44/63位)，用于长时间监控减少溢出，L_NRDY语义如上

MSMON_OFLOW_MSI_ADDR_L/H  溢出中断MSI地址
MSMON_OFLOW_MSI_ATTR      MSI属性配置
MSMON_OFLOW_MSI_DATA      MSI数据
MSMON_OFLOW_MSI_MPAM      MSI MPAM标识
MSMON_OFLOW_MSI_SR        MSI状态寄存器
```
注意，如上描述的是MSC处怎么配置具体的监控。请求发出的源端也要配置partid以及PMG，
这个依然是配置到MPAMx_ELn寄存器中的。监控需要匹配PARTID+PMG的组合。

SMMU MPAM
----------

SMMU上只是配置partid，联合内存或者cache上的控制单元实现内存或者cache资源的控制。

SMMU上的STE/CD可以看作是具体外设在SMMU上的代理，所以对一个具体的外设只需要把partid
配置到SMMU上即可。

Partid Narrow
--------------

所谓Partid Narrow是进入MSC的partid可以通过提前配置好的映射被映射成另外一个partid，
后面的控制和检测都基于新的partid。

Partid Narrow的硬件编程序列：1. 用reqPARTID写MPAMCFG_PART_SEL（不带INTERNAL位）；
2. 用目标intPARTID写MPAMCFG_INTPARTID，置上MPAMCFG_INTPARTID_INTERNAL位；
3. 写MPAMCFG_PART_SEL，置上INTERNAL位选择intPARTID；4. 后续控制寄存器操作
（如MPAMCFG_CMAX）都基于此intPARTID。主要用途是扩展监控容量——多个reqPARTID
可以映射到同一个intPARTID，复用同一组资源配置，但可以通过不同reqPARTID区分
监控上下文。INTAPPID_MAX在MPAMF_PARTID_NRW_IDR中读出，表示最大intPARTID值。

MPAM虚拟化
-----------

1. partition ID预留，2. 虚拟物理partition ID映射，3. MSC模拟。

Linux软件接口
--------------

Intel最早实现了MPAM类似的功能(RDT)，软件上用一个独立的文件系统resctrl向外导出使用接口。
文件系统层次结构如下：
```
/sys/fs/resctrl/
├── cpus                     # 整个resctrl系统的CPU列表
├── cpus_list                # 人类可读的CPU列表格式
├── mon_groups/              # 监控组目录
├── info/                    # 系统资源信息，静态信息，只出现在顶层目录
│   ├── L3/                  # cache控制资源信息
│   │   ├── cbm_mask
│   │   ├── min_cbm_bits
│   │   ├── num_closids      # 最大控制组数(class of service ID)，Intel定义的古怪名字
│   │   └── shareable_bits
│   ├── L3_MON/              # cache监控资源信息
│   │   ├── num_rmids        # 最大PMG数
│   │   └── mon_features     # 支持的监控事件
│   ├── MB/                  # 内存带宽控制资源信息
│   │   ├── bandwidth_gran
│   │   ├── delay_linear
│   │   ├── min_bandwidth
│   │   └── num_closids      # MB支持的最大控制组数
│   ├── MB_MON/              # 内存带宽监控资源信息
│   │   ├── num_rmids
│   │   └── mon_features
│   └── last_cmd_status      # 最后一次命令执行状态
├── mon_data/                # 根控制组的监控数据
│   ├── mon_L3_00/           # resctrl把控制和监控的MSC直接暴露出来，这里是一个L3 monitor。如果有多个，这里就会有多个节点
│   │   ├── llc_occupancy
│   │   ├── mbm_total_bytes
│   │   └── mbm_local_bytes
│   └── ...                  # 如果有多个L3 monitor，这里就会有多个节点出来
├── schemata                 # 资源分配方案。如上，整个系统的资源控制MSC都会呈现在整个文件中
├── size                     # 根控制组的缓存大小
├── tasks                    # 根控制组的进程列表
├── <用户创建的目录>/        # 用户自定义控制组，在用户目录下创建一样的文件
│   ├── cpus
│   ├── cpus_list            # A
│   ├── schemata
│   ├── size
│   ├── mon_groups/          # B。该控制组的监控组。可以在这个目录下创建子监控组。
│   ├── mon_data/            # 该控制组的顶层监控数据。注意，这里会再次展示系统中所有的监控MSC
│   └── tasks
└── <mon_groups创建的目录>/  # 监控组目录。注意这里是全局监控组目录。
    ├── mon_data/            # 监控组的具体监控数据
    └── ...
(AI生成)
```
resctrl使用层次化的结构控制资源，resctrl的根目录是全局资源，用户通过在resctrl
目录下创建目录，创建对应的控制组和监控组，可以看到在用户创建的目录下会新创建一整
套resctrl相关的控制和监控目录和文件。可以看到，用户创建的目录和对应的partition ID
对应起来，partition ID和CPU/线程的绑定关系通过配置cpus/cpus_list/tasks来实现。

控制组创建后，会在控制组目录自动生成监控组控制目录(mon_groups)和监控组数据目录
(mon_data)。可以在mon_group里创建自定义子监控组。拿如上的用户自定义控制组作为一个
例子，比如在A处的cpus_list配置控制和监控CPU 1-4，完全可以在B处mon_groups中创建多个
子监控组目录，配置子监控组目录下的cpus_list，独立监控CPU1。

一般来说系统里有多个MSC，对于一个被控制对象，比如一个线程，可以在这些MSC上配置这个
被控制对象的资源控制和资源监控，这个完全是用户自己的配置行为。resctrl通过schemata
文件在每个控制层级暴露所有MSC的控制信息，每个域(domain)对应如下代码中的一个mpam_component。(todo)

resctrl中标准监控事件有：llc_occupancy(末级缓存占用)、mbm_total_bytes(总内存带宽)等。

Linux内核实现
--------------

MPAM对外使用resctrl文件系统作为接口。以openEuler v6.6内核为例，驱动代码在drivers/platform/mpam/。
这个驱动是一个平台设备驱动，但是，真正probe的地方在注册的cpu online的会调函数里。

核心数据结构：
```
/* MPAM设备的分类，比如，cache/memory/IOMMU等 */
struct mpam_class
  +-> components list

/* 表示一个MSC设备 */
struct mpam_msc
  +-> ris list

/* 表示一个MSC上的一个resource type */
struct mpam_msc_ris

/* 表示MSC上的一个instance ? */
struct mpam_component
  +-> ris list

/*
 * 和resctrl fs的交互的数据结构，每个mpam_resctrl_res内嵌resctrl_resource，
 * 全局数组mpam_resctrl_exports[RDT_NUM_RESOURCES]索引L3/L2/MC。初始化时
 * mpam_domains_init()遍历每个class的component，调用mpam_resctrl_alloc_domain()
 * 分配mpam_resctrl_dom（内嵌resctrl_domain），通过resctrl_online_domain()向
 * resctrl核心注册。用户写schemata时，驱动遍历对应component的所有RIS，调用
 * mpam_reprogram_ris_partid()写MSC硬件寄存器。(todo)
 */
struct mpam_resctrl_res
```

MSC设备解析：
```
mpam_msc_drv_probe                  <-- probe以及创建MSC
  +-> acpi_mpam_parse_resources     <-- 创建mpam_ris
    +-> mpam_ris_create 
      +-> mpam_class_get            <-- 如果还没有，就创建一个
          /*
           * component表示应统一配置的一组MSC。对于cache，component_id来自ACPI PPTT
           * 表的cache_reference，唯一标识一个特定缓存（如某个L3）；对于memory，
           * component_id来自proximity_domain转换的NUMA node ID，同一NUMA node上的
           * 多个内存控制器属于同一个component。每个component映射到一个resctrl域
           * （schemata中的一行），是该域的最小配置单元。(todo)
           */
      +-> mpam_component_get

mpam_discovery_cpu_online
  +-> mpam_msc_hw_probe             <-- probe MSC硬件
      /* work queue里执行 */
  +-> mpam_resctrl_setup
    +-> mpam_resctrl_resource_init  <-- 创建mpam_resctrl_res数组
    +-> resctrl_init                <-- 创建resctrl相关文件
```

resctrl文件创建: 
```
/* fs/resctrl/rdtgroup.c */
resctrl_init
  +-> register_filesystem
    +-> rdt_init_fs_context
          /* 创建resctrl各个文件的逻辑在get_tree里 */
      +-> rdt_fs_context_ops.get_tree

rdt_get_tree
      /*
       * 增加resctrl下创建/销毁目录的回调函数: rdtgroup_mkdir/rdtgroup_rmdir
       *
       * resctrl增加控制和监控项目的时候，需要在resctrl sysfs下新增目录，resctrl
       * 会在新增的目录中增加和顶层一样的目录和文件，相关代码逻辑就在rdtgroup_mkdir。
       */
  +-> rdtgroup_setup_root
  +-> rdt_enable_ctx
  +-> schemata_list_create
  +-> closid_init
      /*
       * resctrl把所有要增加的公共文件都定义在res_common_files数组里，每个文件一个
       * 数组项，数组项中的fflags标记该文件增加到哪里。
       */
  +-> rdtgroup_add_files
  +-> rdtgroup_create_info_dir
  +-> mongroup_create_dir
  +-> mkdir_mondata_all

rdtgroup_mkdir
  +-> rdtgroup_mkdir_ctrl_mon
    +-> mkdir_rdt_prepare
  +-> rdtgroup_mkdir_mon
```
resctrl和驱动的接口是直接arch实现函数调用的... 如此粗暴...

MPAM资源配置的一般逻辑是，用户已经知道整个系统的cache和memory相关控制节点的拓扑，
相关控制节点直接呈现在resctrl文件系统中。用户实际上通过resctrl把特性CPU或线程和
partid绑定，用户通过在各个控制节点上配置partid对应的控制和监控信息达到控制和监控
的功能。partid最终呈现对应的可能是一个个独立的目录。
