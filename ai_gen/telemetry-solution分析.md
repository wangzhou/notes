# Arm Telemetry Solution 分析

> 仓库：`https://gitlab.arm.com/telemetry-solution/telemetry-solution`
> 分析日期：2026-07-22
> 环境：Apple Silicon VM (OpenEuler 6.6.0-98), kernel `aarch64`

## 1. 项目概览

Arm Telemetry Solution 是 Arm 官方的系统级性能分析框架，提供从 PMU 事件定义、指标计算、到 Topdown 方法论分析的完整工具链。

### 仓库结构

```
telemetry-solution/
├── data/                  # 遥测规格定义 (JSON)
│   └── pmu/
│       ├── cpu/           # CPU PMU 规格 + mapping.json
│       │   ├── mapping.json          # MIDR → 规格文件 映射表
│       │   ├── schemas/              # JSON Schema 校验
│       │   └── specifications/       # 各 CPU 规格文件
│       │       ├── neoverse/        # Neoverse N1/N2/N3/V1/V2/V3/V3AE
│       │       ├── lumex/           # Lumex C1 系列
│       │       └── cortex/          # Cortex-A725, Cortex-X925
│       └── cmn/           # CMN 互联网络规格
│           ├── mapping.json
│           ├── schemas/
│           └── specifications/     # CMN-700
├── tools/                 # 工具链
│   ├── topdown_tool/      # 核心 CLI —— Arm Top-Down 性能分析工具
│   ├── perf_json_generator/  # 生成 Linux perf 兼容 JSON
│   ├── spe_parser/        # SPE 原始数据解析 (Parquet/CSV)
│   └── ustress_charts/    # ustress 基准测试可视化
├── benchmarks/            # 验证基准测试
│   ├── ustress/           # CPU 微架构压力测试 (25+ workload)
│   ├── systress/          # 系统级/CMN 压力测试
│   ├── matmul/            # 矩阵乘法内核变体
│   └── random_pointer_access/  # 指针追踪微基准
└── .ci/                   # GitLab CI + Black Duck 扫描
```

### 技术栈

| 组件 | 语言 | 依赖 |
|------|------|------|
| topdown_tool | Python 3.10+ | `rich==14.1.0`, `pydantic==2.13.4`, `jsonschema==4.25.1` |
| perf_json_generator | Python | - |
| spe_parser | Python | - |
| ustress | C | - |
| systress/sysstress | C (CMake) | - |
| matmul | C | - |
| random_pointer_access | C++ | - |

包管理：使用 `uv` (Rust 实现的极快 Python 包管理器)，`uv.lock` 锁死所有依赖版本以保证可复现。

---

## 2. 核心工具：topdown-tool

### 2.1 工作原理

```
遥测规格 JSON → CPU 识别 (MIDR) → 匹配 PMU 事件/指标
    → perf stat 采集 PMU 数据 → 计算 Topdown 指标 → 终端输出/CSV
```

### 2.2 Probe 架构

工具通过 **Probe + ProbeFactory** 插件架构组织：

- `CPU Probe`：默认启用，采集 CPU Topdown 指标
- `CMN Probe`：可选用 `--probe CMN` 启用，采集互联网络指标

Probe 通过 Python entry point 注册（`pyproject.toml` 中声明）：

```toml
[project.entry-points."topdown_tool.probe_factories"]
cpu_probe_factory = "topdown_tool.cpu_probe.cpu_factory:CpuProbeFactory"
cmn_probe_factory = "topdown_tool.cmn_probe.cmn_factory:CmnProbeFactory"
```

**必须通过 `pip install` 才能注册 entry point**，直接 `python -m topdown_tool` 会导致 `--probe-list` 返回空表。

### 2.3 CPU 识别流程

```
1. 读取 /sys/.../midr_el1 (或 /proc/cpuinfo fallback)
2. 解码 MIDR → implementer + part_num + variant + revision
3. cpu_id = (implementer << 12) | part_num
4. 查 mapping.json:
   - 优先匹配完整 MIDR
   - 回退匹配 cpu_id (short format)
5. 加载对应规格 JSON → 获取 PMU 事件列表和指标定义
```

**`mapping.json` 路径解析**（`telemetry_paths.py`）：

1. 优先：`topdown_tool/data/pmu/cpu/mapping.json`（安装包内，`pip install` 时由 `BuildPyWithBuildInfo` 从 repo `data/` 拷贝）
2. 回退：`<repo_root>/data/pmu/cpu/mapping.json`

`_resolve_mapping_file()` 还有额外回退——先尝试 `specifications/mapping.json`，不存在则回退 `MAPPING_FILE`（`telemetry_probe_mapping_file("cpu")`）。

---

## 3. PMU 事件体系

### 3.1 事件分类

| 类型 | 含义 | 示例 |
|------|------|------|
| `architecture_defined` | 写入 ARM ARM 的标准事件，所有 ARMv8/v9 实现必须或可选提供 | `INST_RETIRED (0x0008)`, `L1D_CACHE_REFILL (0x0003)` |
| `product_defined` | 微架构实现特定事件，各产品自行定义 | 厂商自定义 stall 细分事件 |

### 3.2 各 CPU 的事件依赖（关键发现）

| CPU 规格 | 总事件数 | arch-defined | prod-only | 指标使用的 arch 事件 | 指标使用的 prod 事件 |
|----------|---------|-------------|-----------|---------------------|---------------------|
| Neoverse N2 (r0p2) | 155 | 155 | **0** | 38 | **0** |
| Neoverse V3 (r0p0) | 253 | 226 | 27 | 67 | **0** |
| Cortex X925 (r0p0) | 261 | 234 | 27 | 67 | **0** |
| Lumex C1 Ultra (r0p0) | 372 | 311 | 61 | 114 | **35** |

**结论**：
- Neoverse 和 Cortex 的 Topdown 指标**完全依赖架构定义事件**，理论上是跨 ARM 实现可移植的
- Lumex C1 Ultra 的指标依赖了 35 个产品定义事件，不可移植
- Apple Silicon 理论上实现了大部分 arch-defined 事件（作为 ARMv8/v9 兼容实现），但：
  - ARM ARM 中有 mandatory 和 optional 之分，并非所有 arch-defined 事件都被实现
  - Apple M 系列在 VM 中不暴露硬件 PMU

### 3.3 JSON 规格结构

```jsonc
{
  "$schema": "路径到 JSON Schema",
  "document": { /* 文档元数据 */ },
  "product_configuration": { /* implementer, part_num, revision */ },
  "events": { /* PMU 事件定义: code, title, description, architecture_defined, product_defined */ },
  "metrics": { /* 派生指标: formula, events[], description, units, sample_events */ },
  "groups": {
    "function": { /* 功能分组: L1D_Cache, Branch_Effectiveness 等 */ },
    "metrics": { /* 指标分组: Topdown_L1, Cycle_Accounting 等 */ }
  },
  "methodologies": {
    "topdown_methodology": { /* 决策树: Stage 1 热点定位 → Stage 2 微架构探索 */ }
  }
}
```

---

## 4. 安装与运行

### 4.1 前置条件

| 条件 | 说明 |
|------|------|
| Arm 裸机或 PMU 透传 VM | **硬件 PMU 必须可用**（VM 中需启用 PMU 虚拟化） |
| perf_event_paranoid = -1 或 CAP_PERFMON | 允许系统级 PMU 访问 |
| Python 3.10+ | 运行时 |
| inotify-tools (Linux) | perf 输出监控 |

### 4.2 不使用 uv 的安装方式

依赖只有 3 个纯 Python 包：

```bash
pip3 install --user rich==14.1.0 pydantic==2.13.4 jsonschema==4.25.1
cd tools/topdown_tool
git submodule update --init --recursive     # 拉取 cmn-tools 子模块
pip3 install --user .                        # 安装 topdown-tool（注册 entry point）
```

### 4.3 使用方式

```bash
# 系统级采样 (Ctrl-C 停止)
topdown-tool

# 监控一个命令
topdown-tool -- sleep 10

# 监控指定 PID
topdown-tool -p 289156

# 指定 CPU 核心
topdown-tool -C 0,1 -- ./a.out

# 列出可用 probes
topdown-tool --probe-list

# CSV 输出
topdown-tool --generate-csv metrics -I 1000 -- sleep 10
```

### 4.4 `pip install .` 做了什么

1. 安装 3 个依赖到 site-packages
2. 执行 `BuildPyWithBuildInfo.run()`:
   - `_copy_retained_telemetry()` → 把 `data/pmu/` 拷贝到安装包内
   - `_write_version_file()` → 生成 `_version.py`（版本号 + git SHA）
   - `_write_build_info()` → 生成 `_build_info.py`（构建时间戳 + git 状态）
3. 注册 entry points → 生成 `~/.local/bin/topdown-tool` wrapper 脚本

---

## 5. Apple Silicon 兼容性分析

### 5.1 实验环境

```
CPU: Apple Silicon (implementer=0x61, part=0x000)
内核: 6.6.0-98.0.0.103.oe2403sp2.aarch64 (OpenEuler)
MIDR: 0x00000000610f0000 (所有 10 核相同)
perf_event_paranoid: -1  (已配置)
```

### 5.2 遇到的问题

| 序号 | 问题 | 原因 | 解决 |
|------|------|------|------|
| 1 | `--probe-list` 返回空表 | entry point 未注册（未安装） | `pip install --user .` |
| 2 | `Unknown CPU at cores: 0-9` | MIDR (0x61, Apple) 不在 `mapping.json` 中 | 编辑 `mapping.json`，添加 `"0x61000"` 映射到 `neoverse/neoverse_n2_r0p2_pmu` |
| 3 | **mapping 编辑后在 repo 生效但工具仍报 Unknown CPU** | `pip install` 把旧 `mapping.json` 拷贝到 site-packages，工具运行时读的是安装副本 | 同时编辑 `~/.local/lib/.../topdown_tool/data/pmu/cpu/mapping.json` |
| 4 | `Perf version not supported. Unexpected acknowledgement message` | `perf stat --control fd:` 控制管道机制不工作 | - |
| 5 | **所有硬件 PMU 事件 `<not supported>`** | VM 没有 PMU 硬件计数器透传 | **无解（环境限制）** |
| 6 | `perf stat --control fd:N,M` 输出 `Failed to read from ctlfd` | 内核不支持此 perf 特性 | **无解（环境限制）** |

### 5.3 hacking mapping.json 的具体操作

编辑安装副本中的 `mapping.json`：

```json
"0x41d8c": {
    "name": "lumex/arm_c1_ultra_r0p0_pmu"
},
"0x61000": {                              // ← 新增
    "name": "neoverse/neoverse_n2_r0p2_pmu"
}
```

选择 Neoverse N2 规格的原因：
- 所有 155 个事件都是 `architecture_defined`（零产品定义事件）
- 所有 38 个指标事件都是 `architecture_defined`
- 是仓库中最"纯粹"的 ARM 架构规格

### 5.4 为什么最终跑不起来（根本原因）

```
Apple Silicon VM (OpenEuler)
  ├── 硬件 PMU 不可用 → perf stat -e cycles → <not supported>
  └── perf stat --control fd: 不支持 → "Failed to read from ctlfd"
```

**两个都是环境/平台层面的限制**，与代码无关：

1. **PMU 虚拟化缺失**：虚拟机没有把 Apple Silicon 的硬件 PMU 计数器透传进来。这是最根本的阻塞项——没有硬件计数器，Topdown 方法论完全无法运作。
2. **perf control pipe**：即使 PMU 可用，`topdown-tool` 依赖 `perf stat --delay -1 --control fd:N,M` 来精确同步事件采集和 workload 生命周期，此功能在内核 6.6.0-98.oe2403sp2 上（可能因架构差异）不可用。

### 5.5 能跑的环境

`topdown-tool` 设计运行在：
- **Arm 裸机服务器**：Graviton (AWS)、Arm Neoverse 参考平台等
- **启用 PMU 透传的 VM**：KVM with `-cpu host` + PMU 虚拟化支持
- **支持的 CPU**：Neoverse (N1/N2/N3/V1/V2/V3/V3AE)、Lumex (C1 系列)、Cortex (A725/X925)

---

## 6. 关键文件索引

| 文件 | 功能 |
|------|------|
| `data/pmu/cpu/mapping.json` | MIDR → 规格文件 映射（**被 pip install 拷贝到 site-packages**） |
| `data/pmu/cpu/specifications/<vendor>/<cpu>_pmu.json` | 各 CPU 的 PMU 事件、指标、方法论定义 |
| `tools/topdown_tool/topdown_tool/probe/probe.py` | Probe/ProbeFactory 基类 + `load_probe_factories()` |
| `tools/topdown_tool/topdown_tool/cpu_probe/cpu_factory.py` | CPU probe 工厂：CLI 解析、CPU 检测、规格匹配 |
| `tools/topdown_tool/topdown_tool/cpu_probe/cpu_detector.py` | MIDR 读取（sysfs/cpuinfo/perf），`cpu_id` 计算 |
| `tools/topdown_tool/topdown_tool/common/telemetry_paths.py` | 数据文件路径解析（打包优先，repo fallback） |
| `tools/topdown_tool/topdown_tool/perf/linux_perf.py` | perf stat 子进程管理 + control pipe 通信 |
| `tools/topdown_tool/topdown_tool/perf/linux_perf_base.py` | `_compose_stat_command()` 生成 perf CLI |
| `tools/topdown_tool/topdown_tool/build_info.py` | 构建钩子：生成 `_version.py`/`_build_info.py`，拷贝遥测数据 |
| `tools/topdown_tool/topdown_tool/version.py` | 运行时版本信息（fallback 到 git） |
| `tools/topdown_tool/pyproject.toml` | 包元数据、依赖声明、entry point 注册 |
