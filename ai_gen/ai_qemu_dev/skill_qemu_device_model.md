# QEMU设备模型开发 Skill

> 基于HiSilicon HIP09 DMA Engine实战经验总结

## Skill概述

本skill用于指导从Linux内核驱动开发QEMU设备模型的完整流程。

**适用场景**：PCI/平台设备需要QEMU模拟，配合现有Linux驱动测试验证。

---

## 开发流程

```
┌─────────────────────────────────────────────────────────────────┐
│  1. 分析驱动      →  2. 生成手册    →  3. 创建骨架              │
│  提取关键信息         文档化设计        PCI设备框架               │
│         ↓                                                         │
│  4. 实现枚举      →  5. 寄存器MMIO  →  6. 功能逻辑              │
│  BAR/MSI配置         读写处理          实际数据传输              │
│         ↓                                                         │
│  7. 调试测试      →  8. 迭代完善                                │
│  dmatest验证         修复问题                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 第一步：分析Linux内核驱动

### 必看代码位置

```bash
# 驱动源文件
drivers/<category>/<device>.c

# 关键函数
- probe()      # 初始化流程
- remove()     # 清理流程
- suspend/resume()  # 电源管理
- ISR/interrupt handler  # 中断处理
```

### 提取的关键信息清单

| 信息类型 | 代码位置 | 示例 |
|---------|---------|------|
| PCI VID:DID | `pci_device_id` | `0x19e5:0xa122` |
| BAR配置 | `pcim_iomap_regions()` | `BIT(2)` 表示BAR2 |
| MSI向量数 | `pci_alloc_irq_vectors()` | 4个向量 |
| 寄存器偏移 | 宏定义 | `0x2000` 基址 |
| 队列结构 | 结构体定义 | SQE/CQE各32/8字节 |
| Revision区分 | `pdev->revision` | `0x30` = HIP09A |

### 分析模板

```c
// 1. 设备标识
static const struct pci_device_id xxx_pci_tbl[] = {
    { PCI_DEVICE(VID, DID) },
};

// 2. 寄存器布局 (grep "0x" 驱动文件)
#define REG_BASE     0x0000
#define REG_CTRL     0x0100
#define REG_STATUS   0x0200

// 3. 数据结构
struct xxx_desc {
    uint32_t status;
    uint64_t src;
    uint64_t dst;
    uint32_t len;
};

// 4. 初始化流程 (阅读probe函数)
//    a. pcim_enable_device()
//    b. pcim_iomap_regions()
//    c. pci_alloc_irq_vectors()
//    d. 硬件初始化
//    e. dmaenginem_async_device_register()
```

---

## 第二步：生成芯片手册

### 手册模板

```markdown
# <设备名> 芯片手册

## 1. 概述
- 功能描述
- 硬件规格

## 2. PCI配置
- Vendor ID: 0xXXXX
- Device ID: 0xXXXX
- Revision: 0xXX
- BAR配置:
  - BAR0: XXX (可选，避免MSI冲突)
  - BAR2: 寄存器空间 (0xXXXX大小)

## 3. 寄存器布局
| 偏移 | 名称 | 描述 |
|------|------|------|
| 0x00 | REG_A | 描述 |
| 0x04 | REG_B | 描述 |

## 4. 中断
- 类型: MSI/INTx
- 向量数: N
- 中断号分配: 每通道1个

## 5. 数据结构
### 描述符格式
- 字段1: XX位, 描述
- 字段2: XX位, 描述

## 6. 操作流程
### 初始化
1. 启用设备
2. 映射寄存器
3. 配置MSI
4. 初始化硬件

### 数据传输
1. 准备描述符
2. 写入队列
3. 更新尾指针
4. 硬件执行
5. 完成中断
```

---

## 第三步：创建QEMU模型骨架

### 项目结构

```
hw/<category>/
├── Kconfig
├── meson.build
└── <device>.c

include/hw/<category>/
└── <device>.h
```

### 头文件模板

```c
// include/hw/<category>/<device>.h

#ifndef <DEVICE>_H
#define <DEVICE>_H

#include "hw/pci/pci_device.h"

#define TYPE_<DEVICE> "<device>"

#define <DEVICE>(obj) OBJECT_CHECK(<Device>State, (obj), TYPE_<DEVICE>)

// 设备规格
#define <DEVICE>_MAX_CHANNELS  N
#define <DEVICE>_REVISION      0xXX
#define <DEVICE>_VENDOR_ID     0xXXXX

// 寄存器偏移
#define R_REG_A    0x00
#define R_REG_B    0x04

// 寄存器位域
#define REG_A_BIT0    BIT(0)
#define REG_A_MASK    GENMASK(7, 0)

// 设备结构
typedef struct <Device>State {
    PCIDevice parent_obj;
    MemoryRegion mmio;
    
    // 设备特定字段
    uint32_t regs[N];
} <Device>State;

#endif
```

### 源文件模板

```c
// hw/<category>/<device>.c

#include "qemu/osdep.h"
#include "hw/pci/pci.h"
#include "hw/<category>/<device>.h"

#define HISI_DMA_ERR_DEBUG 0

#define DPRINTF(fmt, ...) do { \
    if (HISI_DMA_ERR_DEBUG) { \
        qemu_log_mask(LOG_GUEST_ERROR, "<device>: " fmt, ## __VA_ARGS__); \
    } \
} while (0)

// ============== MMIO处理 ==============

static uint64_t <device>_mmio_read(void *opaque, hwaddr addr, unsigned size)
{
    <Device>State *s = <DEVICE>(opaque);
    uint32_t val = 0;
    
    switch (addr) {
    case R_REG_A:
        val = s->regs[R_REG_A/4];
        break;
    default:
        val = s->regs[addr/4];
        break;
    }
    
    return val;
}

static void <device>_mmio_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    <Device>State *s = <DEVICE>(opaque);
    
    switch (addr) {
    case R_REG_A:
        s->regs[R_REG_A/4] = val;
        // TODO: 触发逻辑
        break;
    default:
        s->regs[addr/4] = val;
        break;
    }
}

static const MemoryRegionOps <device>_mmio_ops = {
    .read = <device>_mmio_read,
    .write = <device>_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

// ============== PCI设备 ==============

static void <device>_realize(PCIDevice *pci_dev, Error **errp)
{
    <Device>State *s = <DEVICE>(pci_dev);
    
    /* BAR0 (可选，避免MSI占用) */
    MemoryRegion *bar0 = g_new(MemoryRegion, 1);
    memory_region_init(bar0, OBJECT(s), "<device>-bar0", 0x1000);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, bar0);
    
    /* 主要寄存器BAR */
    memory_region_init_io(&s->mmio, OBJECT(s), &<device>_mmio_ops, s,
                         TYPE_<DEVICE>, 0x4000);
    pci_register_bar(pci_dev, 2, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->mmio);
    
    /* MSI初始化 (可选) */
    msi_init(pci_dev, 0x50, N, true, false, errp);
}

static void <device>_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *pc = PCI_DEVICE_CLASS(klass);
    
    pc->realize = <device>_realize;
    pc->vendor_id = <DEVICE>_VENDOR_ID;
    pc->device_id = 0xXXXX;  // TODO
    pc->revision = <DEVICE>_REVISION;
    
    set_bit(DEVICE_CATEGORY_MISC, dc->categories);
}

static const TypeInfo <device>_info = {
    .name = TYPE_<DEVICE>,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(<Device>State),
    .class_init = <device>_class_init,
    .interfaces = (InterfaceInfo[]) {
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { }
    }
};

type_init(<device>_register_type)
```

### 构建配置

**hw/xxx/Kconfig**:
```kconfig
config <UPPERCASE_DEVICE>
    bool "<Device Name>"
    depends on PCI
    help
      <Description>
```

**hw/xxx/meson.build**:
```python
softmmu_ss.add(when: 'CONFIG_<UPPERCASE_DEVICE>', then: files('<device>.c'))
```

**hw/arm/Kconfig** (ARM virt支持):
```kconfig
config VIRT
    ...
    select <UPPERCASE_DEVICE>
```

---

## 第四步：调试与测试

### 快速测试命令

```bash
# 编译
cd /path/to/qemu/build && ninja

# 启动QEMU
/home/wz/qemu/build/qemu-system-aarch64 \
    -m 4G -smp 4 -cpu max \
    -machine virt,gic-version=3 \
    -kernel /path/to/linux/arch/arm64/boot/Image \
    -initrd /path/to/rootfs.cpio.gz \
    -append "console=ttyAMA0" \
    -device <device>,bus=pcie.0
```

### 验证清单

- [ ] 设备枚举: `dmesg | grep -i <device>`
- [ ] MSI分配: `lspci -v` 查看中断
- [ ] BAR映射: `lspci -xxx` 查看地址
- [ ] 功能测试: 驱动probe成功

### 常见问题排查

| 问题 | 原因 | 解决方案 |
|-----|------|---------|
| 设备未枚举 | ID不匹配 | 确认VID:DID |
| MSI失败 | 平台不支持 | 改用INTx或修复MSI |
| 寄存器读0 | MMIO未正确映射 | 检查BAR注册 |
| 中断不触发 | 中断处理错误 | 使用msi_notify() |

---

## 常见陷阱与解决

### 1. MSI vs INTx

**错误**:
```c
pci_set_irq(&s->parent_obj, 1);  // INTx方式
```

**正确**:
```c
msi_notify(&s->parent_obj, vector);  // MSI方式
```

### 2. sq_head vs sq_tail

驱动和硬件的视角不同：
- 驱动写入SQ_TAIL_PTR指向"下一个可用位置"
- 硬件从sq_head读取，指向"下一个待处理位置"

```c
// 硬件视角
if (channel->sq_head == channel->sq_tail) {
    // 队列空
    return;
}
// 处理sq_head位置的描述符
// 处理完后sq_head++
```

### 3. BAR0保留

如果MSI需要BAR0但你不想用它，注册一个dummy BAR：
```c
MemoryRegion *dummy = g_new(MemoryRegion, 1);
memory_region_init(dummy, OBJECT(s), "dummy", 0x1000);
pci_register_bar(pci_dev, 0, ..., dummy);
```

### 4. 字节序

内存中的数据通常是LE：
```c
val = le32_to_cpu(regs[offset]);
cpu_to_le32(val);
```

---

## AI辅助开发提示

### 给AI的prompt模板

```
我正在开发一个QEMU设备模型，基于Linux驱动 <驱动路径>。

需要提取的信息：
1. PCI设备ID (VID:DID)
2. MSI/中断配置
3. 寄存器布局 (偏移、名称、功能)
4. 数据结构 (描述符格式)
5. 初始化流程 (probe函数)
6. 操作流程 (读写、传输、中断)

当前状态：
- 已有骨架代码 <路径>
- 需要解决: <具体问题>

请帮我：
1. 分析驱动代码
2. 找出寄存器访问模式
3. 识别关键的硬件交互
```

### AI擅长的工作

- 阅读和理解复杂代码
- 生成代码骨架
- 模式匹配和重复代码生成
- 解释硬件协议

### 需要人工验证的

- 数据结构的正确性
- 时序依赖关系
- 边界条件处理
- 实际硬件行为

---

## 参考文件

- 完整示例: `hw/dma/hisi_dma.c`
- 芯片手册: `DMA芯片手册.md`
- 开发文档: `如何利用AI做QEMU模型开发.md`
- Linux驱动: `drivers/dma/hisi_dma.c`

---

*Skill版本: 1.0*
*基于项目: HiSilicon HIP09 DMA Engine*
*创建日期: 2026-04-16*
