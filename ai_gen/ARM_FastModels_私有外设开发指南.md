# 基于 ARM Fast Models 开发私有外设模型：完整指南

## 一、整体架构理解

在开始之前，先理解 ARM Fast Models 的核心架构：

```
┌─────────────────────────────────────────────────────┐
│                   System Canvas                      │
│  ┌──────────┐   ┌──────────┐   ┌──────────────────┐ │
│  │ ARM Core │   │ Bus/Inter│   │ 你的私有外设模型  │ │
│  │ (CPU)    │◄─►│ connect  │◄─►│ (Custom Device)  │ │
│  └──────────┘   └──────────┘   └──────────────────┘ │
│                       ▲                              │
│                       │                              │
│                 ┌─────┴──────┐                       │
│                 │ Memory/其他│                       │
│                 │ 标准外设    │                       │
│                 └────────────┘                       │
└─────────────────────────────────────────────────────┘
```

---

## 二、环境准备

### Step 1：下载 Fast Models

Fast Models 由两个独立安装包组成，必须都下载：

| 安装包 | 说明 | 安装后的典型目录名 |
|--------|------|-------------------|
| **Fast Models Tools** | 编译构建工具链 (SimGen, sgcanvas, LISA+ 编译器等) | `FastModelsTools_<ver>/` |
| **Fast Models Portfolio** | 预编译好的 ARM IP 模型库 (CPU核、GIC、总线、内存等组件) | `FastModelsPortfolio_<ver>/` |

**下载入口：**

1. **Fast Models 产品页**：https://developer.arm.com/Tools%20and%20Software/Fast%20Models
2. **Arm Product Download Hub** (统一下载入口)：https://developer.arm.com/downloads
   - 搜索 "Fast Models" 即可找到 Tools 和 Portfolio 两个包
   - 需要 Arm 账户 (免费注册) + 有效的商业许可证才能下载
3. 也可以通过 **Arm Design Studio** 安装器一并获取 (Design Studio 会捆绑 Fast Models)

**许可证类型：**
- 开发自定义外设模型需要的是 **Fast Models Tools License** (不是只读的 FVP License)
- 仅有 FVP (Fixed Virtual Platforms) 许可证是不够的，FVP 只能运行预构建好的平台，不能编译新组件
- 许可证文件通常为 `license.dat`，通过 `ARMLMD_LICENSE_FILE` 环境变量指定

### Step 2：确认安装后的目录结构

安装完成后，你应该看到类似下面的目录结构（以版本 11.x 为例）：

```
FastModelsTools_11.xx/                    ← 这就是 MAXCORE_HOME
├── bin/
│   ├── simgen                            ← LISA+ 编译器/构建工具 (核心)
│   ├── sgcanvas                          ← System Canvas GUI 图形化连线工具
│   ├── sgproject                         ← 项目管理工具
│   └── ...
├── lib/
│   ├── Linux64_GCC-<ver>/                ← 针对特定编译器的运行时库
│   └── ...
├── include/
│   ├── sg/                               ← SimGen 头文件
│   ├── eslapi/                           ← ESL API 头文件
│   └── ...
├── source_all.sh                         ← ★ 环境变量设置脚本
└── ...

FastModelsPortfolio_11.xx/                ← 这就是 PVLIB_HOME
├── docs/                                 ← 文档 (重要! 包含 LISA+ 语言参考)
├── examples/                             ← ★ 官方示例 (强烈建议先看)
│   ├── LISA/
│   │   ├── FVP_MPS2_Cortex-M3/           ← M3 平台示例
│   │   ├── ...
│   │   └── peripheral_example/           ← 外设模型示例 (你最需要看的)
│   └── SystemC/
├── lib/
│   ├── Linux64_GCC-<ver>/
│   │   ├── libarmctmodel.a               ← ARM CT (Cycle Timing) 模型库
│   │   ├── libpvbus.a                    ← PVBus 总线模型库
│   │   ├── libscx.a                      ← SystemC 集成库
│   │   └── ...
│   └── ...
├── include/
│   ├── fmruntime/                        ← Fast Models 运行时头文件
│   ├── pv/                               ← PV (Programmer's View) 接口头文件
│   │   ├── PVBus.h
│   │   ├── PVTransaction.h
│   │   └── ...
│   ├── sg/                               ← SimGen 框架头文件
│   └── ...
├── plugins/                              ← 调试器插件等
│   ├── ModelDebugger/
│   └── ...
└── ...
```

**快速验证安装是否正确的方法：**

```bash
# 1. source 环境变量
source /path/to/FastModelsTools_11.xx/source_all.sh

# 2. 验证关键环境变量已设置
echo $PVLIB_HOME       # 应指向 FastModelsPortfolio_11.xx
echo $MAXCORE_HOME     # 应指向 FastModelsTools_11.xx

# 3. 验证 simgen 可用
simgen --version
# 应输出类似: SimGen (Build ...) version 11.xx.xx

# 4. 验证官方示例目录存在
ls $PVLIB_HOME/examples/LISA/
# 应列出若干示例平台目录

# 5. 验证 PVBus 头文件存在 (你写外设模型必须用到)
ls $PVLIB_HOME/include/pv/PVBus.h
# 文件存在说明 Portfolio 安装正确
```

### Step 3：确认宿主机编译环境

```bash
# Linux 推荐环境
# - Ubuntu 18.04/20.04/22.04
# - GCC 9.x 或更高
# - Python 3.x (用于脚本辅助)

# 检查编译器
gcc --version
g++ --version

# 确保 LISA 编译器可用
which simgen    # SimGen 是 LISA+ 的编译器/构建工具
```

---

## 三、核心开发步骤

### Step 4：理解 LISA+ 语言基础

#### 4.1 LISA+ 是什么

LISA+ 全称 **Language for Instruction Set Architecture (Plus)**，是 ARM 专门为 Fast Models 设计的
**组件建模语言**。它不是通用编程语言，而是一种领域专用语言 (DSL)，用于描述硬件组件的行为模型。

**LISA+ 和其他技术的关系：**

```
┌─────────────────────────────────────────────────────┐
│                  建模语言对比                        │
├────────────┬────────────────────────────────────────┤
│ SystemC    │ 通用硬件建模，可周期精确，偏底层        │
│ Verilog/VH │ RTL级描述，综合用，最精确但最慢         │
│ LISA+      │ ARM专用，功能级 (PV)，专注快速仿真     │
│ QEMU C     │ 通用模拟器，手写C，无标准框架约束       │
└────────────┴────────────────────────────────────────┘

LISA+ 的定位：
  RTL (Verilog)  ←  精确但慢
       ↑
  TLM (SystemC)  ←  折中
       ↑
  PV  (LISA+)    ←  ★ 最快，功能正确即可，不追求时序精度
```

**选择 LISA+ 的原因：**
- ARM Fast Models 体系的唯一建模语言，没有其他选择
- SimGen 编译器只认 `.lisa` 文件
- 虽然 Fast Models 也支持包装 SystemC 组件 (通过 `scx` 桥接)，但原生开发必须用 LISA+

#### 4.2 LISA+ 核心语法概念

LISA+ 看起来像 C++，但有自己的关键字和结构：

```
┌─ component (组件) ─────────────────────────────────┐
│                                                     │
│  ┌─ properties ──────────┐  组件元信息              │
│  │  version, type, ...   │  (版本、类型、描述)      │
│  └───────────────────────┘                          │
│                                                     │
│  ┌─ ports ───────────────┐  对外接口                │
│  │  slave port<PVBus>    │  (总线从端口、中断等)    │
│  │  master port<Signal>  │                          │
│  └───────────────────────┘                          │
│                                                     │
│  ┌─ parameters ──────────┐  可配置参数              │
│  │  uint32_t base_addr   │  (实例化时可外部设置)    │
│  └───────────────────────┘                          │
│                                                     │
│  ┌─ internal ────────────┐  内部状态                │
│  │  寄存器、标志位等      │  (对外不可见)           │
│  └───────────────────────┘                          │
│                                                     │
│  ┌─ behaviors ───────────┐  行为 (核心)             │
│  │  init()               │  组件初始化              │
│  │  reset()              │  复位逻辑                │
│  │  pvbus_s.read()       │  处理总线读请求          │
│  │  pvbus_s.write()      │  处理总线写请求          │
│  │  自定义行为()          │  定时器回调等            │
│  └───────────────────────┘                          │
│                                                     │
│  ┌─ composition ─────────┐  子组件实例化            │
│  │  (仅系统级组件需要)    │  (连线、地址映射)       │
│  └───────────────────────┘                          │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**LISA+ 关键字与 C++ 的主要区别：**

| LISA+ 关键字 | 含义 | C++ 中的近似物 |
|-------------|------|---------------|
| `component` | 定义一个硬件组件 | class |
| `behavior` | 定义一个行为/方法 | member function |
| `slave port<PVBus>` | 从端口声明 (接收事务) | 无直接对应，类似回调接口 |
| `master port<Signal>` | 主端口声明 (发起信号) | 无直接对应，类似事件发射器 |
| `parameter` | 可配置参数 (构建时确定) | template parameter / constructor arg |
| `internal` | 内部状态块 | private 成员变量 |
| `composition` | 子组件实例化 | 成员对象 |
| `connection` | 端口连线 | 手动绑定/连接调用 |
| `properties` | 组件元数据 | 无直接对应 |

**behavior 内部的代码就是标准 C/C++ 语法**，可以直接用 `printf`、`switch/case`、指针操作等，
这也是 LISA+ 上手比较快的原因 —— 你只需要学框架结构，逻辑代码本身就是写 C。

#### 4.3 LISA+ 编译流程

```
  .lisa 源文件
       │
       ▼
  ┌──────────┐
  │  SimGen   │  ← LISA+ 编译器 ($MAXCORE_HOME/bin/simgen)
  └──────────┘
       │
       ├──→ 生成 C++ 中间代码
       │
       ▼
  ┌──────────┐
  │  GCC/MSVC │  ← 宿主机 C++ 编译器
  └──────────┘
       │
       ▼
  .so / .dll (可加载的组件库)
```

SimGen 本质上是一个 **LISA+ → C++ 的转译器**，最终还是靠宿主机的 C++ 编译器生成二进制。
所以编译错误有时候会看到 C++ 层面的报错，不要困惑。

#### 4.4 创建项目目录结构

```bash
mkdir -p my_peripheral/{src,doc,test}
cd my_peripheral

# 典型的项目结构：
# my_peripheral/
# ├── src/
# │   ├── MyDevice.lisa          # 主 LISA+ 组件文件
# │   ├── MyDevice.sgproj        # SimGen 项目文件
# │   └── protocol/              # 自定义协议 (如果需要)
# ├── doc/
# └── test/
#     └── test_system.sgproj     # 测试系统项目
```

### Step 5：编写 LISA+ 外设模型

以一个带中断的简单定时器外设为例：

```cpp
// 文件: src/MyTimer.lisa

component MyTimer
{
    properties
    {
        version = "1.0.0";
        component_type = "Peripheral";
        description = "My Custom Timer Peripheral";

        // 基地址和大小定义
        address_space_size = 0x1000;
    }

    // =========================================
    // 端口定义 (Ports)
    // =========================================
    slave port<PVBus> pvbus_s;          // PVBus 从端口，接收 CPU 读写
    master port<Signal> irq_out;        // 中断输出信号

    // =========================================
    // 参数 (可在实例化时配置)
    // =========================================
    parameter uint32_t clock_freq = 1000000;  // 默认 1MHz
    parameter bool     enable_log = false;

    // =========================================
    // 内部寄存器定义
    // =========================================
    internal
    {
        // 寄存器偏移定义
        enum REG_OFFSET
        {
            REG_CTRL     = 0x00,    // 控制寄存器
            REG_LOAD     = 0x04,    // 加载值寄存器
            REG_VALUE    = 0x08,    // 当前值寄存器
            REG_INTSTAT  = 0x0C,    // 中断状态寄存器
            REG_INTCLR   = 0x10     // 中断清除寄存器
        };

        // 寄存器存储
        uint32_t reg_ctrl;       // bit0: enable, bit1: interrupt enable
        uint32_t reg_load;
        uint32_t reg_value;
        uint32_t reg_intstat;

        // 内部状态
        bool timer_running;
        sg::Timer timer_event;   // SimGen 定时器事件
    }

    // =========================================
    // 行为定义 (Behaviors)
    // =========================================

    // 组件初始化
    behavior init()
    {
        reg_ctrl    = 0;
        reg_load    = 0;
        reg_value   = 0;
        reg_intstat = 0;
        timer_running = false;

        if (enable_log)
            printf("MyTimer: initialized, clock_freq=%u\n", clock_freq);
    }

    // 组件复位
    behavior reset(int level)
    {
        reg_ctrl    = 0;
        reg_load    = 0;
        reg_value   = 0;
        reg_intstat = 0;
        timer_running = false;

        // 取消定时器事件
        timer_event.cancel();

        // 清除中断
        irq_out.setValue(0);
    }

    // =========================================
    // PVBus 从端口读操作
    // =========================================
    slave behavior pvbus_s.read(pv::ReadTransaction tx)
        : pv::Tx_Result
    {
        uint32_t offset = static_cast<uint32_t>(tx.getAddress());
        uint32_t* data  = reinterpret_cast<uint32_t*>(tx.getData());

        switch (offset)
        {
            case REG_CTRL:
                *data = reg_ctrl;
                break;

            case REG_LOAD:
                *data = reg_load;
                break;

            case REG_VALUE:
                *data = reg_value;
                break;

            case REG_INTSTAT:
                *data = reg_intstat;
                break;

            default:
                if (enable_log)
                    printf("MyTimer: read from unknown offset 0x%x\n", offset);
                *data = 0;
                break;
        }

        if (enable_log)
            printf("MyTimer: READ  [0x%03x] = 0x%08x\n", offset, *data);

        return tx.writeComplete();
    }

    // =========================================
    // PVBus 从端口写操作
    // =========================================
    slave behavior pvbus_s.write(pv::WriteTransaction tx)
        : pv::Tx_Result
    {
        uint32_t offset = static_cast<uint32_t>(tx.getAddress());
        uint32_t data   = *reinterpret_cast<uint32_t*>(tx.getData());

        if (enable_log)
            printf("MyTimer: WRITE [0x%03x] = 0x%08x\n", offset, data);

        switch (offset)
        {
            case REG_CTRL:
                reg_ctrl = data;
                if (data & 0x1)  // enable bit
                    startTimer();
                else
                    stopTimer();
                break;

            case REG_LOAD:
                reg_load  = data;
                reg_value = data;
                break;

            case REG_INTCLR:
                reg_intstat = 0;
                irq_out.setValue(0);    // 释放中断
                break;

            default:
                if (enable_log)
                    printf("MyTimer: write to unknown/readonly offset 0x%x\n", offset);
                break;
        }

        return tx.writeComplete();
    }

    // =========================================
    // 定时器逻辑
    // =========================================
    behavior startTimer()
    {
        if (!timer_running)
        {
            timer_running = true;
            // 设置定时器回调，周期 = load_value / clock_freq
            double period_s = (double)reg_load / (double)clock_freq;
            timer_event.setTimer(period_s, this, &MyTimer::onTimerExpired);
        }
    }

    behavior stopTimer()
    {
        timer_running = false;
        timer_event.cancel();
    }

    behavior onTimerExpired()
    {
        reg_value = 0;

        // 如果中断使能
        if (reg_ctrl & 0x2)
        {
            reg_intstat = 1;
            irq_out.setValue(1);    // 触发中断
        }

        // 自动重载
        if (reg_ctrl & 0x1)
        {
            reg_value = reg_load;
            double period_s = (double)reg_load / (double)clock_freq;
            timer_event.setTimer(period_s, this, &MyTimer::onTimerExpired);
        }
        else
        {
            timer_running = false;
        }
    }
}
```

### Step 6：创建 SimGen 项目文件

```xml
<!-- 文件: src/MyTimer.sgproj -->
<?xml version="1.0" encoding="UTF-8"?>
<Project>
    <Name>MyTimer</Name>
    <Type>Component</Type>

    <Files>
        <File>MyTimer.lisa</File>
    </Files>

    <Includes>
        <Path>${PVLIB_HOME}/include</Path>
        <Path>${PVLIB_HOME}/include/fmruntime</Path>
    </Includes>

    <BuildConfig>
        <Compiler>gcc</Compiler>
        <Debug>true</Debug>
    </BuildConfig>
</Project>
```

### Step 7：编译你的组件

```bash
# 使用 SimGen 编译 LISA+ 组件
simgen -p src/MyTimer.sgproj \
       --num-comps-file 1 \
       --configuration Linux64_GCC-9.3 \
       -b

# 编译成功后会生成：
# - MyTimer.o            (目标文件)
# - MyTimer.a / .so      (库文件)
# - 可在 System Canvas 中使用的组件
```

---

## 四、集成到系统中

### Step 8：理解集成的核心概念

在写集成代码之前，必须先理解 Fast Models 系统是怎么组装起来的。

#### 8.1 整体思路：像拼电路板一样

Fast Models 的系统集成，本质上就是在做 **虚拟电路板设计**：
- 每个 `component` 是一个 **芯片/IP模块** (CPU、总线、你的外设、内存...)
- 每个 component 有若干 **port (端口)**，就像芯片的引脚
- 集成 = 把这些芯片放到板子上 + 用线把引脚连起来

```
  真实硬件世界                          Fast Models 世界
  ──────────                          ─────────────────
  芯片 (IC)                    ──→    component
  芯片引脚 (Pin)               ──→    port
  PCB走线                      ──→    connection (=>)
  地址解码器/总线矩阵           ──→    PVBusDecoder
  数据总线 (AXI/AHB/APB)       ──→    PVBus
  中断线 (IRQ)                 ──→    Signal port
  SoC 顶层设计                 ──→    顶层 component (type="System")
```

#### 8.2 端口 (Port) 详解

端口是组件对外暴露的接口，分两种角色：

```
  ┌──────────┐                    ┌──────────┐
  │          │   master           │          │
  │   CPU    ├───port──────►──────┤ BusDec   │
  │          │  (发起请求)  slave  │ oder     │
  │          │             port   │          │
  └──────────┘          (接收请求) └──────────┘

  master port: 主动发起事务的一方 (如 CPU 发起读写)
  slave  port: 被动响应事务的一方 (如 外设接收读写)
```

**你的外设模型中，端口是这样对应的：**

```
  slave port<PVBus> pvbus_s;
  │      │    │       │
  │      │    │       └── 端口名字 (连线时用这个名字引用)
  │      │    └────────── 端口协议 (PVBus = 程序员视角总线协议)
  │      └─────────────── 端口角色 (slave = 外设是被访问方)
  └────────────────────── 端口声明关键字

  master port<Signal> irq_out;
  │       │     │       │
  │       │     │       └── 端口名字
  │       │     └────────── 端口协议 (Signal = 单比特信号线)
  │       └────────────────  端口角色 (master = 外设主动发出中断)
  └─────────────────────── 端口声明关键字
```

**常见的端口协议类型：**

| 协议 | 用途 | 典型用法 |
|------|------|---------|
| `PVBus` | 总线读写事务 | CPU ↔ 外设之间的 MMIO 访问 |
| `Signal` | 单比特信号线 | 中断线、复位信号、使能信号 |
| `ClockSignal` | 时钟信号 | 给组件提供时钟 |
| `AMBAPVSignal` | AMBA 协议信号 | 更复杂的 AMBA 总线信号 |

#### 8.3 PVBusDecoder (地址解码器) 的作用

这是集成时最关键的组件。CPU 发出的所有读写请求，先到达 PVBusDecoder，
由它根据 **地址范围** 分发到不同的下游设备：

```
                        PVBusDecoder
                    ┌─────────────────┐
                    │                 │
  CPU ──pvbus_m──►──┤ pvbus_s (入口)  │
                    │                 │
                    │  地址解码逻辑：   │
                    │                 │
                    │  0x0000_0000 ─► ├──►── RAM     (pvbus)
                    │  ~ 0x0FFF_FFFF │
                    │                 │
                    │  0x1C00_0000 ─► ├──►── UART    (pvbus_s)
                    │  ~ 0x1C00_0FFF │
                    │                 │
                    │  0x4000_0000 ─► ├──►── MyTimer (pvbus_s)  ← 你的外设
                    │  ~ 0x4000_0FFF │
                    │                 │
                    └─────────────────┘

  软件执行: str r0, [0x40000004]
                    │
                    ▼
  CPU 发出写事务: addr=0x40000004, data=r0
                    │
                    ▼
  PVBusDecoder 看到地址 0x40000004 落在 [0x40000000..0x40000FFF]
                    │
                    ▼
  转发给 MyTimer.pvbus_s，地址变为 offset = 0x04 (减去基地址)
                    │
                    ▼
  MyTimer 的 pvbus_s.write() behavior 被调用
  tx.getAddress() 返回 0x04 → 命中 REG_LOAD 寄存器
```

#### 8.4 中断连线

中断是从外设到 CPU 方向的信号，走 Signal 端口：

```
  ┌──────────┐                           ┌──────────┐
  │ MyTimer  │                           │   CPU    │
  │          │  master port<Signal>      │          │
  │ irq_out ─├────────────────────►──────┤ irq_in  │
  │          │   irq_out.setValue(1)     │          │
  │          │   = 拉高中断线            │ (触发异常│
  │          │                           │  向量)   │
  │          │   irq_out.setValue(0)     │          │
  │          │   = 释放中断线            │          │
  └──────────┘                           └──────────┘

  注意：Fast Models 的中断是 "电平触发" 语义
  1. 外设 setValue(1) → CPU 看到中断 pending
  2. CPU 读 INTSTAT 确认中断源
  3. 软件写 INTCLR 清除
  4. 外设在 write(INTCLR) handler 中调用 setValue(0) → 释放
  5. 如果忘了 setValue(0)，CPU 会反复进入中断!
```

**对于有 GIC 的复杂系统 (Cortex-A 系列)：**

```
  ┌──────────┐         ┌──────────┐         ┌──────────┐
  │ MyTimer  │         │   GIC    │         │ Cortex-A │
  │          │  Signal │          │  内部    │          │
  │ irq_out ─├────►────┤ spi[32] ─├────►────┤          │
  │          │         │          │         │          │
  └──────────┘         └──────────┘         └──────────┘

  外设中断不直接连 CPU，而是连到 GIC 的某个 SPI 中断号上
  GIC 再统一管理中断优先级/路由，通知 CPU
```

#### 8.5 完整连线示例的逐行解读

下面是系统顶层的 LISA+ 代码，逐行加了注释：

```cpp
// 文件: test/TestSystem.lisa

// 定义一个顶层系统组件
// component_type = "System" 表示它是可以直接运行的顶层
component TestSystem
{
    properties
    {
        version = "1.0.0";
        component_type = "System";   // ← "System" 才能编译出可执行的仿真器
    }

    // ========== composition: 声明这个系统里包含哪些子组件 ==========
    // 相当于在电路板上放置芯片
    composition
    {
        // 放一颗 ARM Cortex-M3 处理器
        // "cpu" 是实例名，后面配置参数、连线都用这个名字
        armcortexm3ct : ARMCortexM3CT("cpu");

        // 放一个地址解码器 (相当于总线矩阵)
        pvbusdecoder : PVBusDecoder("busdecoder");

        // 放一块内存
        memory : RAMDevice("ram")
        {
            size = 0x10000000;   // 256MB, 这是 RAMDevice 的 parameter
        };

        // ★ 放你自己的外设 ★
        // MyTimer 就是你在 Step 5 中写的组件
        // "mytimer" 是实例名
        mytimer : MyTimer("mytimer")
        {
            clock_freq = 1000000;   // 设置 parameter: 1MHz 时钟
            enable_log = true;      // 设置 parameter: 打开日志
        };
    }

    // ========== connection: 把子组件的端口用线连起来 ==========
    // => 操作符就是 "连线"，左边连右边
    connection
    {
        // 连线1: CPU 的总线主端口 → 解码器的从端口
        //
        //   CPU (master) ────────► BusDecoder (slave)
        //
        // CPU 发出的所有读写请求都先到达 BusDecoder
        armcortexm3ct.pvbus_m => pvbusdecoder.pvbus_s;

        // 连线2: 解码器 → 内存
        //
        // 地址范围 [0x00000000, 0x0FFFFFFF] 的访问转发给 memory
        // CPU 访问 0x00000000 ~ 0x0FFFFFFF 就是在读写 RAM
        pvbusdecoder.pvbus_m_range[0x00000000..0x0FFFFFFF]
            => memory.pvbus;

        // 连线3: 解码器 → 你的外设
        //
        // 地址范围 [0x40000000, 0x40000FFF] 的访问转发给 mytimer
        // CPU 访问 0x40000000 就是在操作你的定时器寄存器
        // mytimer 收到的 offset = 实际地址 - 0x40000000
        pvbusdecoder.pvbus_m_range[0x40000000..0x40000FFF]
            => mytimer.pvbus_s;

        // 连线4: 中断线
        //
        // 定时器的中断输出 → CPU 的中断输入
        // mytimer 调用 irq_out.setValue(1) 时，CPU 就会收到中断
        mytimer.irq_out => armcortexm3ct.irq_in;
    }
}
```

#### 8.6 数据流完整走一遍

以 CPU 写定时器 LOAD 寄存器为例，从软件到硬件模型的完整路径：

```
  ① 软件执行一条 store 指令
     ────────────────────────────
     C 代码:  MYTIMER_LOAD = 1000;
     等价于:  *(volatile uint32_t*)0x40000004 = 1000;
     编译为:  MOV R0, #1000
              LDR R1, =0x40000004
              STR R0, [R1]

         │
         ▼
  ② CPU 模型 (ARMCortexM3CT) 执行 STR 指令
     生成一笔总线写事务:
       addr = 0x40000004
       data = 1000 (0x3E8)
       size = 4 bytes
     通过 pvbus_m (master port) 发出

         │
         ▼
  ③ PVBusDecoder 收到事务 (通过 pvbus_s)
     查地址映射表:
       0x40000004 落在 [0x40000000..0x40000FFF] → 转发给 mytimer
     转发时自动减去基地址:
       新 addr = 0x40000004 - 0x40000000 = 0x00000004

         │
         ▼
  ④ MyTimer 的 pvbus_s.write() behavior 被调用
     tx.getAddress() → 0x04
     tx.getData()    → 指向值 1000 的指针
     switch(0x04) → case REG_LOAD:
       reg_load  = 1000;
       reg_value = 1000;

         │
         ▼
  ⑤ 返回 tx.writeComplete()
     事务完成，CPU 的 STR 指令执行完毕，继续执行下一条指令
```

**中断的数据流 (反方向)：**

```
  ① MyTimer 定时器到期
     onTimerExpired() 被调用

         │
         ▼
  ② 检查中断使能位 (reg_ctrl & 0x2)
     如果使能:
       reg_intstat = 1;
       irq_out.setValue(1);    ← 通过 master port 发出信号

         │
         ▼
  ③ CPU 模型收到中断信号 (irq_in 被置1)
     CPU 暂停当前执行，跳转到中断向量表

         │
         ▼
  ④ 中断处理函数执行
     读 INTSTAT → pvbus_s.read() → 返回 reg_intstat = 1
     写 INTCLR  → pvbus_s.write() → reg_intstat = 0, irq_out.setValue(0)

         │
         ▼
  ⑤ 中断线释放，CPU 返回正常执行
```

### Step 9：创建测试系统 (两种方式)

有两种方式集成：

**方式 A：使用 System Canvas GUI (图形化拖拽)**

```bash
# 启动图形化 System Canvas
sgcanvas &

# 操作步骤：
# 1. File -> New Project
# 2. 从 Component 列表中拖入 ARM 处理器 (如 Cortex-A53)
# 3. 拖入 PVBusDecoder (地址解码器)
# 4. 拖入你编译好的 MyTimer 组件
# 5. 连线：CPU -> BusDecoder -> MyTimer
# 6. 设置地址映射 (如 MyTimer 映射到 0x1A000000)
# 7. 连接 irq_out 到 GIC 的某个 SPI 中断
```

**方式 B：使用 LISA+ 编写系统顶层 (推荐，可版本管理)**

见上面 8.5 节的完整代码。

### Step 10：编译完整系统并运行

#### 10.1 sgproj 项目文件：告诉 SimGen 组件在哪里

之前的文档里编译系统时只写了 `simgen -p test/TestSystem.sgproj`，
但没有说清楚 **SimGen 怎么知道 MyTimer 组件在哪里**。

关键就在 `.sgproj` 项目文件里。它描述了依赖关系：

```xml
<!-- 文件: test/TestSystem.sgproj -->
<?xml version="1.0" encoding="UTF-8"?>
<Project>
    <Name>TestSystem</Name>
    <Type>System</Type>          <!-- 注意这里是 System，不是 Component -->

    <!-- 系统顶层的 LISA 文件 -->
    <Files>
        <File>TestSystem.lisa</File>
    </Files>

    <!-- ★ 关键: 声明依赖的子组件项目 ★ -->
    <!-- SimGen 会先编译这些依赖，再编译系统 -->
    <SubProjects>
        <!-- 你的自定义外设 — 指向它的 .sgproj -->
        <SubProject>../src/MyTimer.sgproj</SubProject>
    </SubProjects>

    <!-- ARM 提供的标准组件不需要你在 SubProjects 里列出 -->
    <!-- ARMCortexM3CT, PVBusDecoder, RAMDevice 等 -->
    <!-- SimGen 会自动从 $PVLIB_HOME 中找到它们 -->

    <Includes>
        <Path>${PVLIB_HOME}/include</Path>
        <Path>${PVLIB_HOME}/include/fmruntime</Path>
    </Includes>

    <!-- 链接 Portfolio 中的标准组件库 -->
    <Libraries>
        <Path>${PVLIB_HOME}/lib/${CONFIG}</Path>
    </Libraries>

    <BuildConfig>
        <Compiler>gcc</Compiler>
        <Debug>true</Debug>
    </BuildConfig>
</Project>
```

#### 10.2 编译和链接的完整过程

```
  SimGen 编译系统时的内部流程:

  simgen -p test/TestSystem.sgproj -b
         │
         ▼
  ① 解析 TestSystem.sgproj
     发现 SubProjects 里有 ../src/MyTimer.sgproj
         │
         ▼
  ② 先编译 MyTimer.sgproj
     MyTimer.lisa  ──SimGen──►  MyTimer 的 C++ 代码  ──GCC──►  MyTimer.o
         │
         ▼
  ③ 再编译 TestSystem.sgproj
     TestSystem.lisa  ──SimGen──►  TestSystem 的 C++ 代码  ──GCC──►  TestSystem.o
         │
         ▼
  ④ 链接阶段: 把所有东西链在一起
     TestSystem.o
     + MyTimer.o                        ← 你的外设
     + $PVLIB_HOME/lib/.../libarmctmodel.a  ← ARM CPU 模型 (ARMCortexM3CT)
     + $PVLIB_HOME/lib/.../libpvbus.a       ← PVBus, PVBusDecoder
     + $PVLIB_HOME/lib/.../libRAMDevice.a   ← RAMDevice
     + SimGen 运行时库
         │
         ▼
  ⑤ 输出: TestSystem 可执行文件 (或 .so)
     这就是一个完整的虚拟平台仿真器!
```

**所以回答你的问题：**
- SimGen **不需要**你手动指定 MyTimer 的 .so 路径
- 你只需要在系统的 `.sgproj` 文件的 `<SubProjects>` 里引用 MyTimer 的 `.sgproj`
- SimGen 会自动处理编译顺序和链接
- ARM 标准组件 (CPU、总线、内存等) 在 `$PVLIB_HOME/lib/` 下，SimGen 自动找到

#### 10.3 实际编译和运行命令

```bash
# 编译系统
simgen -p test/TestSystem.sgproj \
       --configuration Linux64_GCC-9.3 \
       -b

# 运行 (ISIM 模式)
./TestSystem \
    -a test/test_firmware.axf \
    --parameter mytimer.enable_log=true \
    --parameter mytimer.clock_freq=2000000
```

---

## 五、编写固件测试

### Step 11：编写裸机测试代码验证外设

```c
// 文件: test/test_firmware.c

#include <stdint.h>

// 你的外设寄存器基地址
#define MYTIMER_BASE    0x40000000

#define MYTIMER_CTRL    (*(volatile uint32_t*)(MYTIMER_BASE + 0x00))
#define MYTIMER_LOAD    (*(volatile uint32_t*)(MYTIMER_BASE + 0x04))
#define MYTIMER_VALUE   (*(volatile uint32_t*)(MYTIMER_BASE + 0x08))
#define MYTIMER_INTSTAT (*(volatile uint32_t*)(MYTIMER_BASE + 0x0C))
#define MYTIMER_INTCLR  (*(volatile uint32_t*)(MYTIMER_BASE + 0x10))

// 控制位定义
#define CTRL_ENABLE     (1 << 0)
#define CTRL_INT_EN     (1 << 1)

void timer_irq_handler(void)
{
    // 中断处理
    if (MYTIMER_INTSTAT & 0x1)
    {
        // 清除中断
        MYTIMER_INTCLR = 1;
        // 处理定时事件...
    }
}

int main(void)
{
    // 1. 设置加载值
    MYTIMER_LOAD = 1000;

    // 2. 使能定时器 + 中断
    MYTIMER_CTRL = CTRL_ENABLE | CTRL_INT_EN;

    // 3. 轮询方式检查 (或等待中断)
    while (1)
    {
        uint32_t val = MYTIMER_VALUE;
        // 检查定时器值是否在递减...

        if (MYTIMER_INTSTAT)
        {
            // 定时器到期!
            MYTIMER_INTCLR = 1;
            break;
        }
    }

    return 0;
}
```

---

## 六、高级特性

### Step 12：添加调试可视性 (CADI 接口)

```cpp
// 在 MyTimer.lisa 中添加 CADI 寄存器可视性
// 这样在 Model Debugger 中可以直接看到和修改寄存器

component MyTimer
{
    // ... 之前的代码 ...

    // CADI 寄存器组定义
    cadi_reg_group("Timer Registers")
    {
        cadi_reg(reg_ctrl,    "CTRL",     32, "Control Register");
        cadi_reg(reg_load,    "LOAD",     32, "Load Value");
        cadi_reg(reg_value,   "VALUE",    32, "Current Value");
        cadi_reg(reg_intstat, "INT_STAT", 32, "Interrupt Status");
    }
}
```

### Step 13：添加 trace 支持 (MTI)

```cpp
// 添加 Model Trace Interface 支持，用于分析和调试

component MyTimer
{
    // ... 之前的代码 ...

    // Trace 源定义
    trace_source "TimerEvent"
    {
        field uint32_t counter_value;
        field bool     interrupt_fired;
    }

    // 在定时器到期行为中添加 trace
    behavior onTimerExpired()
    {
        // ... 原有逻辑 ...

        // 输出 trace 事件
        TRACE("TimerEvent",
              counter_value = reg_value,
              interrupt_fired = (reg_intstat != 0));
    }
}
```

---

## 七、开发流程总结

```
┌──────────────────────────────────────────────┐
│           开发流程总览                        │
│                                              │
│  ① 需求分析 & 寄存器规格定义                  │
│       │                                      │
│       ▼                                      │
│  ② 编写 LISA+ 组件 (.lisa)                   │
│       │                                      │
│       ▼                                      │
│  ③ SimGen 编译 (simgen -b)                   │
│       │                                      │
│       ├── 编译错误 → 回到 ②                   │
│       ▼                                      │
│  ④ System Canvas 集成 (连线/地址映射)         │
│       │                                      │
│       ▼                                      │
│  ⑤ 编写测试固件 (裸机 C 代码)                 │
│       │                                      │
│       ▼                                      │
│  ⑥ 运行仿真 & 调试                           │
│       │                                      │
│       ├── 功能异常 → 回到 ② 或 ⑤              │
│       ▼                                      │
│  ⑦ 添加 CADI/Trace 调试特性                  │
│       │                                      │
│       ▼                                      │
│  ⑧ 交付组件 (.so/.dll + 文档)                │
└──────────────────────────────────────────────┘
```

## 八、常见坑和建议

| 问题 | 建议 |
|------|------|
| **字节序问题** | PVBus transaction 要注意处理不同 access size (8/16/32 bit) |
| **时序精度** | Fast Models 是 **功能模型**，不是周期精确的，别追求精确时序 |
| **中断行为** | 确保中断是 **电平触发** 语义：assert → 保持 → CPU ack → deassert |
| **地址对齐** | 处理未对齐访问的情况，至少返回 bus error 而非崩溃 |
| **多核安全** | 如果外设会被多核访问，需要考虑原子性和锁 |
| **License** | 确保你有 **Fast Models Tools** 的许可证，不仅仅是 FVP 使用许可证 |
| **参考示例** | `$PVLIB_HOME/examples/` 下有官方示例组件，**强烈建议先读懂** |

```bash
# 强烈推荐先看官方示例
ls $PVLIB_HOME/examples/LISA/
# 通常包含:
#   - peripheral_example/
#   - timer_example/
#   - bus_example/
```
