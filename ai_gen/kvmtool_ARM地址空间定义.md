# kvmtool ARM 地址空间定义

## 源码位置

`arm/include/arm-common/kvm-arch.h`

AArch64: `arm/aarch64/include/kvm/kvm-arch.h` (增加 `MAX_PAGE_SIZE SZ_64K`, `ARCH_HAS_CFG_RAM_ADDRESS`)
AArch32: `arm/aarch32/include/kvm/kvm-arch.h` (增加 `MAX_PAGE_SIZE SZ_4K`, kernel offset 固定为 `0x8000`)

两者最终都 `#include "arm-common/kvm-arch.h"`。

## 内存布局

```
0      64K  16M     32M     48M            1GB       2GB
+-------+----+-------+-------+--------+-----+---------+---......
|  PCI  |////| plat  |       |        |     |         |
|  I/O  |////| MMIO: | Flash | virtio | GIC |   PCI   |  DRAM
| space |////| UART, |       |  MMIO  |     |  (AXI)  |
|       |////| RTC,  |       |        |     |         |
|       |////| PVTIME|       |        |     |         |
+-------+----+-------+-------+--------+-----+---------+---......
```

## 各区域常量定义

| 常量 | 值 | 说明 |
|---|---|---|
| `ARM_IOPORT_AREA` | `0x0000_0000` | PCI I/O 空间起始 |
| `ARM_IOPORT_SIZE` | `0x0001_0000` (64K) | PCI I/O 空间大小 |
| `ARM_MMIO_AREA` | `0x0100_0000` (16M) | 平台 MMIO 区域起始 |
| `ARM_UART_MMIO_BASE` | `ARM_MMIO_AREA` (16M) | UART MMIO 基址 |
| `ARM_UART_MMIO_SIZE` | `0x0001_0000` (64K) | UART MMIO 大小 |
| `ARM_RTC_MMIO_BASE` | `ARM_UART_MMIO_BASE + 0x10000` | RTC MMIO 基址 |
| `ARM_RTC_MMIO_SIZE` | `0x0001_0000` (64K) | RTC MMIO 大小 |
| `ARM_PVTIME_BASE` | `ARM_RTC_MMIO_BASE + 0x10000` | PVTIME 基址 |
| `ARM_PVTIME_SIZE` | `SZ_64K` | PVTIME 大小 |
| `KVM_FLASH_MMIO_BASE` | `0x0200_0000` (32M) | Flash 基址 |
| `KVM_FLASH_MAX_SIZE` | `0x0100_0000` (16M) | Flash 大小 |
| `KVM_VIRTIO_MMIO_AREA` | `0x0300_0000` (48M) | Virtio MMIO 区域起始 |
| `ARM_GIC_DIST_BASE` | `ARM_AXI_AREA - ARM_GIC_DIST_SIZE` (1G - 64K) | GIC Distributor 基址 |
| `ARM_GIC_DIST_SIZE` | `0x0001_0000` (64K) | GIC Distributor 大小 |
| `ARM_GIC_CPUI_BASE` | `ARM_GIC_DIST_BASE - ARM_GIC_CPUI_SIZE` (1G - 192K) | GIC CPU Interface 基址 |
| `ARM_GIC_CPUI_SIZE` | `0x0002_0000` (128K) | GIC CPU Interface 大小 |
| `ARM_GIC_SIZE` | `0x0003_0000` (192K) | GIC 总大小 (DIST + CPUI) |
| `ARM_GIC_REDIST_SIZE` | `0x0002_0000` (128K per vCPU) | GICv3 Redistributor 大小 (运行时 × nrcpus) |
| `ARM_AXI_AREA` | `0x4000_0000` (1G) | PCI AXI 区域 / ECAM 配置空间起始 |
| `KVM_PCI_CFG_AREA` | `ARM_AXI_AREA` (1G) | PCI ECAM 配置空间基址 |
| `ARM_PCI_CFG_SIZE` | `0x1000_0000` (256M) | PCI ECAM 配置空间大小 |
| `KVM_PCI_MMIO_AREA` | `KVM_PCI_CFG_AREA + ARM_PCI_CFG_SIZE` (1.25G) | PCI MMIO (BAR) 空间起始 |
| `ARM_PCI_MMIO_SIZE` | `ARM_MEMORY_AREA - (ARM_AXI_AREA + ARM_PCI_CFG_SIZE)` (768M) | PCI MMIO 空间大小 |
| `ARM_MEMORY_AREA` | `0x8000_0000` (2G) | 客户机 DRAM 起始地址 |
| `ARM_LOMAP_MAX_MEMORY` | `(1ULL << 32) - ARM_MEMORY_AREA` (2G) | AArch32 最大 RAM (4G - 2G) |

## 设计要点

1. **低 2G 全部留给 MMIO**：PCI I/O、UART、RTC、PVTIME、Flash、Virtio、GIC、PCI ECAM/MMIO 均在 2G 以下
2. **DRAM 从 2G 开始** (`ARM_MEMORY_AREA = 0x80000000`)，这是客户机 RAM 的起始物理地址
3. **GIC 紧贴 1G 下方**：`ARM_GIC_DIST_BASE = 1G - 64K`
4. **PCI ECAM 从 1G 开始**：`ARM_AXI_AREA = 0x40000000`，占用 256M
5. **PCI MMIO 从 1.25G 开始**：大小 768M，延续到 2G 边界
6. **AArch32 限制**：最大 RAM 为 `ARM_LOMAP_MAX_MEMORY = 2G`（受 32-bit 物理地址空间限制）
7. **默认 RAM 基址**：`kvm__arch_default_ram_address()` 返回 `ARM_MEMORY_AREA`，AArch64 下可通过 `kvm_config.ram_addr` 修改但不得低于 `ARM_MEMORY_AREA`

## 运行时关键使用点

| 文件 | 用途 |
|---|---|
| `arm/kvm.c:60-69` | `kvm__init_ram()` 使用 `cfg.ram_addr` 注册 RAM |
| `arm/gic.c:153-283` | GICv2/GICv3 设备创建，使用 GIC 相关常量 |
| `arm/pci.c:37-58` | PCI FDT 节点生成，编码 PCI 地址范围到 device tree |
| `arm/fdt.c:107-109` | 生成 memory 节点的 `reg` 属性 |
| `arm/aarch64/kvm.c:44` | 校验 `ram_addr >= ARM_MEMORY_AREA` |
| `arm/aarch32/kvm.c:5-8` | 校验 RAM 不超过 `ARM_LOMAP_MAX_MEMORY` |
