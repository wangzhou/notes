# ARM 异构热迁移：概念与实践

## 背景

传统热迁移要求源和目的主机使用相同的指令集架构（ISA）。但在异构数据中心场景中，这个限制越来越成问题：

- AWS Graviton、Ampere Altra 等 ARM 服务器逐渐普及
- 同一集群可能包含不同代际的 ARM 处理器
- 维护和负载均衡需要跨机器迁移虚拟机

## 热迁移基本原理

QEMU/KVM 的热迁移分为三个阶段：

1. **迭代传输**：预拷贝内存脏页
2. **停机拷贝**：暂停 VM，传输剩余状态
3. **恢复运行**：目的端启动 VM

整个过程可控制在百毫秒级，VM 对用户无感知。

## ARM 的特殊困难

### 问题本质：处理器 ID 不匹配

x86 世界迁移相对容易，是因为：
- CPU 功能通过 CPUID leaf 抽象，Intel/AMD 可共存
- 可使用统一的 CPU 模型（如 x86-64-v2）

ARM64 面临不同境遇：
- 每种处理器有独立的 MIDR_EL1（处理器 ID 寄存器）
- Cortex-A76、A55、A57 来自不同厂商，微架构不同
- **KVM 直接拒绝 MIDR 不一致的迁移**

### 迁移流中的状态问题

迁移流携带的 CPU 寄存器状态（如 `cpreg_values`）在不同 ARM 处理器间可能不兼容，导致迁移失败。

## 当前可行方案

### 同构迁移（保守做法）

要求源和目的使用相同的 SoC 或相近处理器。例如两台 RK3588 之间的迁移通常可行。

配置示例：

```bash
# 源端
qemu-system-aarch64 -machine virt -cpu host ...

# 目的端监听
qemu-system-aarch64 -machine virt -incoming tcp:0:4444
```

### 使用通用 CPU 模型（可能有性能损失）

```bash
qemu-system-aarch64 -machine virt -cpu cortex-a76
```

但不同代际的处理器仍可能失败。

### 组合 PMU（解决 PMU 问题）

Linux 6.10+ 引入了 `KVM_ARM_VCPU_PMU_V3_COMPOSITION`，允许创建兼容所有物理 CPU 的虚拟 PMU。

### vCPU Pinning（确保兼容性）

将 vCPU 固定到具有兼容 PMU 的物理 CPU，但会增加调度复杂度。

## 学术研究进展

真正实现 **ARM 到 x86** 的迁移，需要进程级或应用级转换方案：

| 方案 | 方法 | 迁移延迟 |
|-------|------|---------|
| HetMigrate | 基于 CRIU 的进程迁移 | ~720ms |
| H-Container | 容器级跨 ISA 迁移 | 10-100ms |
| HEXO | Unikernel 跨 ISA 迁移 | ~2ms 状态转换 |

这些方案需要对进程状态进行**转换**：
- 寄存器映射转换
- 调用约定适配
- 栈布局重写

## 总结

- **同 ISA 内迁移**：现有 KVM/QEMU 可行，但需要相同/相近处理器
- **跨 ISA 迁移**：x86 ↔ ARM 需要应用级或进程级迁移工具
- **未来**：需要 ARM 建立类似 x86-64-v2 的通用 CPU 抽象标准

---

## 深入技术细节：ARM64 ID 寄存器与 KVM 异构迁移

### 1. MIDR_EL1 寄存器结构

MIDR_EL1 (Main ID Register) 是 ARM64 处理器的核心标识寄存器，32 位宽，由以下字段组成
（定义在 `arch/arm64/include/asm/cputype.h`）：

```
  bits [31:24]  Implementer   (8 bits)  - 芯片设计商代码
  bits [23:20]  Variant       (4 bits)  - 主版本号
  bits [19:16]  Architecture  (4 bits)  - ARMv8 固定为 0xF
  bits [15:4]   PartNum       (12 bits) - 处理器型号编码
  bits [3:0]    Revision      (4 bits)  - 次版本号
```

内核宏定义：
- `MIDR_IMPLEMENTOR_SHIFT = 24`, `MIDR_IMPLEMENTOR_MASK = 0xFF << 24`
- `MIDR_VARIANT_SHIFT = 20`, `MIDR_VARIANT_MASK = 0xF << 20`
- `MIDR_ARCHITECTURE_SHIFT = 16`, `MIDR_ARCHITECTURE_MASK = 0xF << 16`
- `MIDR_PARTNUM_SHIFT = 4`, `MIDR_PARTNUM_MASK = 0xFFF << 4`
- `MIDR_REVISION_MASK = 0xF`
- `MIDR_CPU_MODEL_MASK = MIDR_IMPLEMENTOR_MASK | MIDR_PARTNUM_MASK | MIDR_ARCHITECTURE_MASK`

常见 Implementer 代码：

| 代码 | 厂商 | 内核宏 |
|------|------|--------|
| 0x41 | ARM Ltd | `ARM_CPU_IMP_ARM` |
| 0x48 | HiSilicon | `ARM_CPU_IMP_HISI` |
| 0xC0 | Ampere | `ARM_CPU_IMP_AMPERE` |
| 0x51 | Qualcomm | `ARM_CPU_IMP_QCOM` |
| 0x61 | Apple | `ARM_CPU_IMP_APPLE` |
| 0x46 | Fujitsu | `ARM_CPU_IMP_FUJITSU` |
| 0x6D | Microsoft | `ARM_CPU_IMP_MICROSOFT` |

常见 PartNum（ARM Ltd 设计）：

| PartNum | 处理器 | 内核宏 |
|---------|--------|--------|
| 0xD0B | Cortex-A76 | `ARM_CPU_PART_CORTEX_A76` |
| 0xD0C | Neoverse-N1 | `ARM_CPU_PART_NEOVERSE_N1` |
| 0xD40 | Neoverse-V1 | `ARM_CPU_PART_NEOVERSE_V1` |
| 0xD49 | Neoverse-N2 | `ARM_CPU_PART_NEOVERSE_N2` |
| 0xD4F | Neoverse-V2 | `ARM_CPU_PART_NEOVERSE_V2` |
| 0xD84 | Neoverse-V3 | `ARM_CPU_PART_NEOVERSE_V3` |
| 0xD8E | Neoverse-N3 | `ARM_CPU_PART_NEOVERSE_N3` |
| 0xD41 | Cortex-A78 | `ARM_CPU_PART_CORTEX_A78` |
| 0xD81 | Cortex-A720 | `ARM_CPU_PART_CORTEX_A720` |

其他厂商的 PartNum 示例：
- Ampere Altra: `AMPERE_CPU_PART_AMPERE1 = 0xAC3` (Implementer=0xC0)
- HiSilicon Hip09: `HISI_CPU_PART_HIP09 = 0xD02` (Implementer=0x48)
- HiSilicon Hip12: `HISI_CPU_PART_HIP12 = 0xD06` (Implementer=0x48)
- Microsoft Azure Cobalt 100: `MICROSOFT_CPU_PART_AZURE_COBALT_100 = 0xD49` (Implementer=0x6D, 基于 Neoverse-N2)

`MIDR_CPU_MODEL(imp, partnum)` 宏将 Implementer、Architecture(固定0xF)、PartNum 合并成一个
model 值用于匹配，忽略 Variant/Revision。

### 2. ARM64 功能 ID 寄存器体系

ARM64 定义了一组功能 ID 寄存器（feature ID registers），每个 4 位字段标识一个 CPU 特性
的实现级别。这些寄存器在 KVM 系统寄存器表中的编码范围为：
`(Op0=3, Op1=0, CRn=0, CRm=1..7, Op2=0..7)`。

关键寄存器：

**ID_AA64PFR0_EL1** (Processor Feature Register 0)：
- EL0/EL1/EL2/EL3 支持级别
- FP/AdvSIMD 支持
- GIC 接口版本
- SVE 支持
- CSV2 (Spectre-v2 缓解) / CSV3 (Meltdown 缓解)
- AMU、MPAM、RAS 支持

**ID_AA64ISAR0_EL1** (Instruction Set Attribute Register 0)：
- AES、SHA1、SHA2、CRC32 等加密指令支持
- 原子操作（LSE）、TLB 范围操作
- RDM、DP 等 SIMD 扩展

**ID_AA64ISAR1_EL1**：
- 指针认证（APA/API/GPA/GPI）
- JSCVT、FCMA、LRCPC、DPB 等

**ID_AA64MMFR0_EL1** (Memory Model Feature Register 0)：
- PARange：物理地址范围（决定 IPA size limit）
- ASIDBits：ASID 位宽
- TGran4/TGran16/TGran64：支持的页表粒度
- TGran4_2/TGran16_2/TGran64_2：Stage-2 支持的页表粒度
- FGT：Fine-Grained Traps 支持

**ID_AA64MMFR1_EL1**：
- HAFDBS：硬件 Access Flag / Dirty Bit 更新
- VMIDBits：VMID 位宽
- VH：VHE 支持
- XNX：Execute-Never 扩展
- HDBSS：硬件脏位到软件 buffer（和迁移脏页追踪密切相关）

**ID_AA64MMFR2_EL1**：
- NV：嵌套虚拟化
- CCIDX：Cache ID 扩展
- FWB：Stage-2 Forced Write-Back
- EVT：Enhanced Virtualization Traps

不同处理器实现的差异举例：
- Cortex-A76 (Armv8.2)：无 SVE、无 MTE、PARange 通常 44 位、HAFDBS=2
- Neoverse-N1 (Armv8.2+)：无 SVE、无 MTE、PARange 48 位、RAS v1.0
- Neoverse-V1 (Armv8.4+)：SVE 支持、PARange 48 位、RAS v1.1
- Neoverse-N2 (Armv9.0)：SVE2、MTE2、PARange 48 位、FEAT_RNG
- Ampere Altra (Armv8.2+, Neoverse-N1 派生)：无 SVE、PARange 48 位
- HiSilicon Hip09 (Armv8.2+)：自定义实现、无 SVE

这意味着从 Neoverse-V1 迁移到 Neoverse-N1 时，SVE 寄存器状态无法在目的端恢复。

### 3. KVM ID 寄存器陷入与过滤

KVM 通过陷入（trapping）和过滤（filtering）机制向 guest 呈现经过清理的 ID 寄存器值。
核心代码在 `arch/arm64/kvm/sys_regs.c`。

**三种 ID 寄存器注册宏**：

```c
// 只读，使用内核 sanitised 值
ID_SANITISED(name)

// 可写，userspace 可通过 KVM_SET_ONE_REG 修改，受 mask 约束
ID_WRITABLE(name, mask)

// 需要额外过滤逻辑的寄存器（有自定义 set_user 回调）
ID_FILTERED(sysreg, name, mask)
```

**sanitise 链路**：

1. `read_sanitised_ftr_reg(id)` - 读取内核全局 sanitised 值（已考虑所有 CPU 的交集）
2. `__kvm_read_sanitised_id_reg(vcpu, r)` - 在内核 sanitised 基础上做 KVM 级过滤：
   - `SYS_ID_AA64PFR0_EL1`：调用 `sanitise_id_aa64pfr0_el1()` 处理 SVE/CSV2/CSV3/GIC/AMU/MPAM
   - `SYS_ID_AA64ISAR1_EL1`：根据 ptrauth 是否启用，屏蔽 APA/API/GPA/GPI 字段
   - `SYS_ID_AA64MMFR2_EL1`：屏蔽 CCIDX 和 NV 字段
   - `SYS_ID_AA64MMFR3_EL1`：仅保留 TCRX/SCTLRX/S1PIE/S1POE
3. `read_id_reg(vcpu, r)` - 读取 VM 维度最终值：`kvm_read_vm_id_reg(vcpu->kvm, ...)`

**Userspace 可写 ID 寄存器配置**：

从内核源码的寄存器表可以看到，关键寄存器的可写情况：
- `ID_AA64PFR0_EL1`: ID_FILTERED - 有限可写，AMU/MPAM/SVE/AdvSIMD/FP 字段被特殊处理
- `ID_AA64ISAR0_EL1`: ID_WRITABLE - 完全可写（除 RES0）
- `ID_AA64ISAR1_EL1`: ID_WRITABLE - 可写（除 GPI/GPA/API/APA 字段）
- `ID_AA64MMFR0_EL1`: ID_FILTERED - 可写（除 RES0 和 ASIDBITS），Stage-2 页表粒度有特殊验证
- `ID_AA64MMFR1_EL1`: ID_WRITABLE - 可写（除 RES0/XNX/VH/VMIDBits）

写入通过 `set_id_reg()` 函数，经 `arm64_check_features()` 验证值不超过硬件能力上限。
一旦 VM 启动（`kvm_vm_has_ran_once()`），ID 寄存器变为不可变，任何修改尝试返回 `-EBUSY`。

**MIDR_EL1 的特殊处理**：

MIDR_EL1、REVIDR_EL1、AIDR_EL1 被归类为"实现 ID 寄存器"（implementation ID registers），
使用 `IMPLEMENTATION_ID` 宏注册，有独立的处理逻辑：

```c
IMPLEMENTATION_ID(MIDR_EL1, GENMASK_ULL(31, 0)),  // 全 32 位可写
IMPLEMENTATION_ID(REVIDR_EL1, GENMASK_ULL(63, 0)),
```

默认行为（历史兼容）：guest 读取 MIDR_EL1 返回当前物理 CPU 的值（通过 `read_cpuid_id()`）。
在 big.LITTLE 系统上，vCPU 被调度到不同核心时会看到不同的 MIDR 值。

启用 `KVM_CAP_ARM_WRITABLE_IMP_ID_REGS` 后：
- userspace 可通过 `KVM_SET_ONE_REG` 设置虚拟的 MIDR_EL1 值
- 该值存储在 `kvm->arch.midr_el1` 中，是 VM 范围的
- guest 读取时返回虚拟值而非物理值（通过 VPIDR_EL2 硬件寄存器注入）
- 在 `__sysreg_restore_el1_state()` 中：`write_sysreg(midr, vpidr_el2)`
- `ctxt_midr_el1()` 函数根据是否设置了 `KVM_ARCH_FLAG_WRITABLE_IMP_ID_REGS` 标志，
  决定返回物理值还是虚拟值

这是异构迁移的关键基础：源端和目的端可以配置相同的虚拟 MIDR_EL1，使 guest 看到一致的
处理器标识。

### 4. CPU Errata 与迁移的冲突

ARM64 的 errata workaround 系统严重依赖 MIDR_EL1 匹配（`arch/arm64/kernel/cpu_errata.c`）。

**errata 匹配机制**：

```c
struct midr_range {
    u32 model;      // MIDR_CPU_MODEL(imp, partnum)
    u32 rv_min;     // 最低 variant/revision
    u32 rv_max;     // 最高 variant/revision
};
```

`is_midr_in_range()` 使用 `midr_is_cpu_model_range()` 做精确匹配。

**Spectre 系列 errata 的 MIDR 关联**：

Spectre-BHB (`spectre_bhb_loop_affected()` in `proton-pack.c`) 影响列表按 MIDR 精确枚举：
- 24 次循环：Cortex-X3, Neoverse-V2
- 16 次循环：Cortex-A715, A720, A720AE
- 8 次循环：Cortex-A76/A76AE/A77, Neoverse-N1
- 32 次循环：Cortex-A78/A78AE/A78C/X1/X1C, Cortex-A710/X2, Neoverse-N2/V1

**对迁移的影响**：
迁移后 guest 运行在不同物理 CPU 上，errata 状态可能不一致：
- 源端可能需要 Spectre-BHB 24 次循环缓解（如 Cortex-X3）
- 目的端可能只需 8 次循环（如 Cortex-A76）或完全不受影响
- KVM 通过 `ID_AA64PFR0_EL1.CSV2` 向 guest 报告 Spectre-v2 缓解状态
- `sanitise_id_aa64pfr0_el1()` 根据 `arm64_get_spectre_v2_state()` 设置 CSV2 字段

**MTE errata**：
MTE（Memory Tagging Extension）是 Armv8.5 引入的特性，不同处理器实现不同：
- `ID_AA64PFR1_EL1.MTE` 和 `ID_AA64PFR1_EL1.MTE_frac` 字段标识 MTE 版本
- `ID_AA64PFR2_EL1.MTEFAR` 和 `MTESTOREONLY` 是更细粒度的 MTE 特性
- KVM 对 MTE 有额外的 sysreg 保存/恢复逻辑（TFSR_EL1、TFSRE0_EL1、GCR_EL1、RGSR_EL1）
- 如果源端有 MTE 而目的端没有，MTE 标签内存和相关寄存器状态无法恢复

**target_impl_cpu 机制**：
内核引入了 `cpu_errata_set_target_impl()` 函数，允许设置"目标实现 CPU"列表来覆盖
errata 检测，这对异构迁移场景有潜在用途——可以在目的端告知内核需要应用源端 CPU 的
errata workaround。

### 5. "Migration-Safe" CPU 特性集概念

ARM/Arm Ltd 尚未发布类似 x86-64-v2/v3 的正式"迁移安全"CPU 模型规范。但 KVM 的
writable ID register 框架提供了构建此概念的技术基础。

**当前实践方式**：

1. **ID 寄存器交集法**：取所有可能迁移目标的 ID 寄存器最小公共子集
   - 例如：Neoverse-N1 和 Neoverse-V1 的交集不包含 SVE
   - userspace（QEMU/libvirt）在 VM 创建时通过 KVM_SET_ONE_REG 设置这个交集
   
2. **MIDR 虚拟化**：通过 `KVM_CAP_ARM_WRITABLE_IMP_ID_REGS` 设置统一的虚拟 MIDR
   - 消除 guest 对特定物理 CPU 型号的依赖
   - 防止 guest 内核根据 MIDR 启用特定 CPU 的优化路径

3. **PMU 兼容性**：Linux 6.10+ 的 `KVM_ARM_VCPU_PMU_V3_COMPOSITION` 允许创建
   兼容多种物理 PMU 的虚拟 PMU

**限制与挑战**：
- 没有标准化的"虚拟 CPU 型号"概念：x86 有 `-cpu qemu64/host/EPYC`，ARM 缺乏等价物
- `arm64_check_features()` 只验证值不超过硬件上限，不验证跨主机兼容性
- QEMU 的 `-cpu` 模型对 ARM 的支持远不如 x86 成熟
- 缺少类似 x86 `invtsc` 的迁移安全时钟抽象

### 6. 迁移流中的系统寄存器保存/恢复

KVM 在 vCPU 上下文切换时保存/恢复的系统寄存器列表定义在 `hyp/include/hyp/sysreg-sr.h`。
这些寄存器也是通过 KVM_GET_ONE_REG/KVM_SET_ONE_REG 进入迁移流的。

**核心 EL1 寄存器（始终保存/恢复）**：
```
SCTLR_EL1, CPACR_EL1, TTBR0_EL1, TTBR1_EL1, TCR_EL1,
ESR_EL1, AFSR0_EL1, AFSR1_EL1, FAR_EL1, MAIR_EL1,
VBAR_EL1, CONTEXTIDR_EL1, AMAIR_EL1, CNTKCTL_EL1,
PAR_EL1, TPIDR_EL1, SP_EL1, ELR_EL1, SPSR_EL1,
MDSCR_EL1, TPIDR_EL0, TPIDRRO_EL0
```

**条件保存的寄存器（取决于 feature 是否启用）**：
- `TCR2_EL1`, `PIR_EL1`, `PIRE0_EL1`, `POR_EL1`: 需要 FEAT_TCR2/S1PIE/S1POE
- `SCTLR2_EL1`: 需要 FEAT_SCTLR2
- `TFSR_EL1`, `TFSRE0_EL1`: 需要 MTE
- `POR_EL0`: 需要 S1POE
- `DISR_EL1`: 需要 RAS

**异构迁移的问题寄存器**：

1. **ACTLR_EL1** (Auxiliary Control Register)：完全 IMPLEMENTATION DEFINED，不同 CPU
   实现含义完全不同。KVM 目前用 `access_actlr` 处理但内容是实现相关的。

2. **AIDR_EL1** (Auxiliary ID Register)：IMPLEMENTATION DEFINED，现在可通过
   `KVM_CAP_ARM_WRITABLE_IMP_ID_REGS` 虚拟化。

3. **REVIDR_EL1**：也是 IMPLEMENTATION DEFINED，同上可虚拟化。

4. **PMU 寄存器** (PMCR_EL0, PMCNTENSET_EL0, PMEVCNTRn_EL0, PMEVTYPERn_EL0 等)：
   PMU 计数器数量和事件编码因 CPU 实现而异。

5. **Debug 寄存器** (DBGBVR/DBGBCR/DBGWVR/DBGWCR)：断点/观察点数量因实现而异，
   由 `ID_AA64DFR0_EL1.BRPs`/`WRPs`/`CTX_CMPs` 字段决定。

6. **SVE 寄存器** (Z0-Z31, P0-P15, FFR, ZCR_EL1)：向量长度不同导致寄存器大小不同，
   KVM 通过 `KVM_REG_ARM64_SVE_VLS` 伪寄存器控制。

7. **AArch32 状态寄存器** (SPSR_ABT/UND/IRQ/FIQ, DACR32_EL2, IFSR32_EL2)：
   仅在 EL0 32-bit 支持时保存。

**VPIDR_EL2 注入机制**：

在 `__sysreg_restore_el1_state()` 中，MIDR_EL1 和 MPIDR_EL1 通过硬件虚拟化寄存器注入：
```c
write_sysreg(midr,  vpidr_el2);   // Guest 读 MIDR_EL1 时返回此值
write_sysreg(mpidr, vmpidr_el2);  // Guest 读 MPIDR_EL1 时返回此值
```

这是 ARM 架构提供的硬件虚拟化支持——EL1 guest 读取 MIDR_EL1 时，硬件自动返回
VPIDR_EL2 的值而非真实的 MIDR_EL1。

### 7. IPA Size、Page Size 与 Stage-2 翻译差异

**IPA Size（Intermediate Physical Address Size）**：

KVM 的 IPA 大小限制由 `ID_AA64MMFR0_EL1.PARange` 字段决定
（`arch/arm64/kvm/reset.c: kvm_set_ipa_limit()`）：

```c
mmfr0 = read_sanitised_ftr_reg(SYS_ID_AA64MMFR0_EL1);
parange = cpuid_feature_extract_unsigned_field(mmfr0, ID_AA64MMFR0_EL1_PARANGE_SHIFT);
kvm_ipa_limit = id_aa64mmfr0_parange_to_phys_shift(parange);
```

PARange 值对应关系：
| PARange | 物理地址位数 |
|---------|-------------|
| 0b0000  | 32 bits     |
| 0b0001  | 36 bits     |
| 0b0010  | 40 bits     |
| 0b0011  | 42 bits     |
| 0b0100  | 44 bits     |
| 0b0101  | 48 bits     |
| 0b0110  | 52 bits (LPA2) |

不同实现的 PARange 差异：
- 大多数服务器级 ARM 处理器（Neoverse-N1/V1/N2）：48 位
- 部分嵌入式/移动处理器可能只有 40 或 44 位

VM 创建时通过 `KVM_VM_TYPE_ARM_IPA_SIZE_MASK` 指定 IPA 大小。如果目的端的
`kvm_ipa_limit` 小于源端 VM 配置的 IPA size，迁移无法完成。

**Page Size（Stage-2 翻译粒度）**：

`ID_AA64MMFR0_EL1` 的 TGran*_2 字段标识 Stage-2 支持的页表粒度：
- `TGRAN4_2`：4KB 页 Stage-2 支持
- `TGRAN16_2`：16KB 页 Stage-2 支持
- `TGRAN64_2`：64KB 页 Stage-2 支持

KVM 在 `kvm_set_ipa_limit()` 中检查当前 `PAGE_SIZE` 是否被 Stage-2 支持：
```c
switch (cpuid_feature_extract_unsigned_field(mmfr0, ID_AA64MMFR0_EL1_TGRAN_2_SHIFT)) {
case ID_AA64MMFR0_EL1_TGRAN_2_SUPPORTED_NONE:
    kvm_err("PAGE_SIZE not supported at Stage-2, giving up\n");
    return -EINVAL;
...
}
```

KVM 对 Stage-2 页表粒度的用户态设置做了严格验证（`set_id_aa64mmfr0_el1()`）：
userspace 只能缩减（de-feature）Stage-2 粒度支持，不能声称支持硬件不支持的粒度。

**LPA2 (Large Physical Address) 特殊处理**：
```c
if (!kvm_lpa2_is_enabled() && PAGE_SIZE != SZ_64K)
    parange = min(parange, (unsigned int)ID_AA64MMFR0_EL1_PARANGE_48);
```
IPA 超过 48 位仅在 LPA2 可用或 64KB 页时才支持。这是跨主机迁移的另一个兼容性约束。

**Stage-2 翻译对迁移的影响**：
- VTCR_EL2 由 KVM 配置（`kvm_get_vtcr()`），包含 IPA size、粒度等参数
- 如果源端和目的端的 VTCR 配置不同，Stage-2 页表结构不一致
- 迁移时不传输 Stage-2 页表本身（目的端重建），但 IPA 布局和大小必须兼容
- 大页（block descriptor）的拆分/合并策略可能影响迁移期间的脏页追踪效率
