# ARMv9 RME - GPC/GPT 技术笔记

## 1. 概述

GPC (Granule Protection Check) 是 ARMv9 Realm Management Extension (RME) 架构中的核心硬件机制，用于在物理地址层面实现四个物理地址空间 (PAS) 之间的内存隔离。

### 四个 PAS (Physical Address Space)

| PAS | 描述 |
|-----|------|
| Secure | 安全状态 |
| Non-secure | 非安全状态 |
| Root | 根世界 (Root world) |
| Realm | 领域世界 (Realm world) |

## 2. GPT (Granule Protection Table) 表结构

### 2.1 两级页表结构

```
Level 0 GPT
    └── 指向 Level 1 GPT 描述符 (可覆盖 1GB ~ 512GB)

Level 1 GPT
    └── 包含 16 个 GPI 字段，每个描述一个物理页 (4KB 或 64KB)
```

### 2.2 配置参数

| 字段 | 含义 | 可能值 |
|------|------|--------|
| L0GPTSZ | L0 条目覆盖地址位数 | 30/34/36/39 bits |
| PGS | 物理粒度 | 4KB(0b00)/64KB(0b01)/16KB(0b10) |
| PPS | 物理地址空间大小 | 32-52 bits |
| T | 由 PPS 计算的地址位数 | - |
| P | 由 PGS 计算的地址位数 | - |
| SH | Shareability | - |
| ORGN | Outer Regimen | - |
| IRGN | Inner Regimen | - |

## 3. GPI (Granule Protection Information)

| GPI 值 | 含义 | 描述 |
|--------|------|------|
| 0x0 | NO_ACCESS | 禁止所有访问 |
| 0x8 | SECURE | 分配给 Secure PAS |
| 0x9 | NS / NON_SECURE | 分配给 Non-secure PAS |
| 0xA | ROOT | 分配给 Root PAS |
| 0xB | REALM | 分配给 Realm PAS |
| 0xF | ANY | 允许所有访问 (completer-side保护) |

## 4. 寄存器定义

### 4.1 PE 侧寄存器 (AArch64)

| 寄存器 | 描述 |
|--------|------|
| GPTBR_EL3 | Granule Protection Table Base Register |
| GPCCR_EL3 | GPT Configuration Control Register |
| GPCTLR_EL3 | GPT Locked Read |
| GPCKEY_EL3 | GPT Key |

#### GPTBR_EL3 格式

```
Bits:
[51:12] ADDR  - GPT 基地址 (4KB 对齐)
[11:0]  RES0
```

#### GPCCR_EL3 位定义

```
Bits:
[17]   GPCP    - GPC Priority
[16]   GPCEN   - GPC Enable (0=禁用, 1=启用)
[15:14] SH      - Shareability
[13:12] ORGN    - Outer Regimen
[11:10] IRGN    - Inner Regimen
[9:8]   PGS     - Physical Granule Size
[7:3]   PPS     - Physical address space Size
[2:0]   L0GPTSZ - Level 0 GPT entry size
```

### 4.2 SMMUv3 (设备侧) 寄存器

| 寄存器 | 描述 |
|--------|------|
| SMMU_ROOT_GPT_BASE | GPT Base Register |
| SMMU_ROOT_GPT_BASE_CFG | GPT Configuration Register |

## 5. Granule 生命周期状态

| 状态 | 描述 | GPT entry |
|------|------|----------|
| UNDELEGATED | 未委托给 RMM | 非 GPT_REALM |
| DELEGATED | 已委托但未使用 | GPT_REALM |
| RD | Realm Descriptor | GPT_REALM |
| REC | Realm Execution Context | GPT_REALM |
| REC_AUX | 辅助 REC 状态 | GPT_REALM |
| DATA | Realm 数据 | GPT_REALM |
| RTT | Realm Translation Table | GPT_REALM |

## 6. GPC 检查流程 (PE 侧)

```
1. VA → Stage-1/Stage-2 translation → PA
2. 检查 PA 是否超出 GPC 范围
3. GPT walk (VA[55:12] → GPI)
4. 比较 Access PAS vs GPI
   - Secure state → SECURE
   - Non-secure → NS
   - Root state → ROOT
   - Realm state → REALM
5. 匹配 → 允许访问
   不匹配 → GPF (Granule Protection Fault)
```

## 7. GPC 故障类型

| 故障码 | 描述 |
|--------|------|
| 0x0 | Invalid GPT configuration |
| 0x1 | L0 GPT 地址超限 |
| 0x2 | GPT fetch External abort |
| 0x3 | Invalid GPT entry |
| 0x4 | L1 GPT 地址超限 |
| 0x5 | GPF - Permission fault (PAS 不匹配) |

## 8. SMMU 集成

SMMUv3 通过以下机制支持 GPC：
- 对所有 client 访问执行 GPC
- 对 SMMU-originated 访问执行 GPC
- 支持广播 TLBI_PA 操���同步 GPT 缓存

## 9. 参考资料

- ARM DDI 0615: ARM Architecture Reference Manual Supplement, RME for Armv9-A
- ARM DEN 0129: RME System Architecture
- ARM IHI 0094: SMMUv3 RME Extension
- DEN0137: Realm Management Monitor (RMM) Specification
- TF-A GPT Library Documentation