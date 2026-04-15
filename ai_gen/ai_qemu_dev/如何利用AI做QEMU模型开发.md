# 如何利用AI做QEMU模型开发

> 基于HiSilicon HIP09 DMA Engine模型的实战经验

## 目录

1. [项目背景](#项目背景)
2. [开发环境准备](#开发环境准备)
3. [第一步：分析Linux内核驱动](#第一步分析linux内核驱动)
4. [第二步：生成芯片手册](#第二步生成芯片手册)
5. [第三步：创建QEMU模型骨架](#第三步创建qemu模型骨架)
6. [第四步：实现PCI设备枚举](#第四步实现pci设备枚举)
7. [第五步：实现寄存器访问](#第五步实现寄存器访问)
8. [第六步：实现DMA传输逻辑](#第六步实现dma传输逻辑)
9. [第七步：调试与测试](#第七步调试与测试)
10. [经验总结](#经验总结)

---

## 项目背景

### 目标
基于现有的Linux内核驱动，反向生成芯片手册，然后编写对应的QEMU模型，最终使模型能通过内核驱动的测试验证。

### 工具路径
```
Linux内核: /home/wz/linux
QEMU代码: /home/wz/qemu
DMA驱动: /home/wz/linux/drivers/dma/hisi_dma.c
```

### 关键要求
- QEMU分支: `hisi-dma-dev`
- 设备ID: `0x19e5:a122` (Huawei)
- 支持4个DMA通道
- 使用MSI中断

---

## 开发环境准备

### 1. 编译QEMU
```bash
cd /home/wz/qemu
mkdir build && cd build
../configure
make -j$(nproc)
```

### 2. 编译Linux内核
```bash
cd /home/wz/linux
make -j$(nproc) Image modules
```

### 3. 启用dmatest（内核自测工具）
```bash
cd /home/wz/linux
scripts/config -e DMATEST
make olddefconfig
make -j$(nproc)
```

### 4. 创建开发分支
```bash
cd /home/wz/qemu
git checkout -b hisi-dma-dev
```

---

## 第一步：分析Linux内核驱动

### 阅读驱动代码
分析 `/home/wz/linux/drivers/dma/hisi_dma.c`，提取关键信息：

1. **PCI设备信息**
```c
static const struct pci_device_id hisi_dma_pci_tbl[] = {
    { PCI_DEVICE(PCI_VENDOR_ID_HUAWEI, 0xa122) },
    { 0, }
};
```

2. **寄存器布局（按revision区分）**
```c
#define HISI_DMA_HIP09_Q_BASE     0x2000
#define HISI_DMA_HIP09_CHAN_NUM   4
#define HISI_DMA_HIP09_MSI_NUM    4
#define HISI_DMA_REVISION_HIP09A  0x30
```

3. **队列寄存器偏移**
```c
#define HISI_DMA_Q_SQ_BASE_L      0x0
#define HISI_DMA_Q_SQ_BASE_H      0x4
#define HISI_DMA_Q_SQ_DEPTH       0x8
#define HISI_DMA_Q_SQ_TAIL_PTR    0xc
#define HISI_DMA_Q_CQ_BASE_L      0x10
#define HISI_DMA_Q_CQ_BASE_H      0x14
#define HISI_DMA_Q_CQ_DEPTH       0x18
#define HISI_DMA_Q_CQ_HEAD_PTR    0x1c
#define HISI_DMA_Q_CTRL0          0x20
#define HISI_DMA_Q_CTRL1          0x24
#define HISI_DMA_Q_FSM_STS        0x30
```

4. **SQE/CQE结构**
```c
struct hisi_dma_sqe {
    __le32 dw0;        // opcode: bit[3:0]
    __le32 dw1;
    __le32 dw2;
    __le32 length;
    __le64 src_addr;
    __le64 dst_addr;
};

struct hisi_dma_cqe {
    __le32 rsv0;
    __le32 rsv1;
    __le16 sq_head;
    __le16 rsv2;
    __le16 rsv3;
    __le16 w0;         // status: bit[15:1], valid: bit[0]
};
```

5. **初始化流程（probe函数）**
```c
hisi_dma_probe() {
    pcim_enable_device()
    pcim_iomap_regions()  // BAR2
    pci_alloc_irq_vectors()  // MSI
    hisi_dma_init_hw_qp()   // 配置队列
    hisi_dma_enable_qp()
}
```

### 关键发现
- HIP09有4个通道，每个通道占0x100字节
- 队列基址从0x2000开始
- MSI向量数=通道数=4
- Opcode 0x4 表示内存拷贝

---

## 第二步：生成芯片手册

根据驱动代码编写芯片手册，记录：
- PCI配置空间
- 寄存器布局
- 中断机制
- 队列结构
- 操作流程

---

## 第三步：创建QEMU模型骨架

### 1. 创建头文件 `include/hw/dma/hisi_dma.h`

```c
#ifndef HISI_DMA_H
#define HISI_DMA_H

#include "hw/pci/pci_device.h"

#define TYPE_HISI_DMA "hisi-dma"
#define HISI_DMA(obj) OBJECT_CHECK(HisiDMAState, (obj), TYPE_HISI_DMA)

#define HISI_DMA_MAX_CHANNELS 4
#define HISI_DMA_REVISION_HIP09 0x30
#define HISI_DMA_PCI_VENDOR_ID 0x19e5

/* 寄存器偏移 */
#define R_SQ_BASE_L    0x00
#define R_SQ_TAIL_PTR  0x0C
#define R_CQ_HEAD_PTR  0x1C
#define R_CTRL0        0x20
#define R_FSM_STS      0x30

typedef struct HisiDMAChannel {
    uint32_t sq_head;
    uint32_t sq_tail;
    dma_addr_t sq_dma;
    dma_addr_t cq_dma;
    enum hisi_dma_fsm_state state;
    bool queue_enabled;
} HisiDMAChannel;

typedef struct HisiDMAState {
    PCIDevice parent_obj;
    MemoryRegion mmio;
    HisiDMAChannel channels[HISI_DMA_MAX_CHANNELS];
    uint32_t regs[HISI_DMA_MAX_CHANNELS][0x100/4];
} HisiDMAState;

#endif
```

### 2. 创建设备实现 `hw/dma/hisi_dma.c`

```c
#include "hw/pci/pci.h"
#include "hw/dma/hisi_dma.h"

static void hisi_dma_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *pc = PCI_DEVICE_CLASS(klass);

    pc->vendor_id = HISI_DMA_PCI_VENDOR_ID;
    pc->device_id = 0xa122;
    pc->revision = HISI_DMA_REVISION_HIP09;
}

static TypeInfo hisi_dma_info = {
    .name = TYPE_HISI_DMA,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(HisiDMAState),
    .class_init = hisi_dma_class_init,
};

type_init(hisi_dma_register_type)
```

### 3. 注册设备

编辑 `hw/dma/Kconfig`:
```kconfig
config HISI_DMA
    bool "HiSilicon DMA Engine"
    depends on PCI
    help
      HiSilicon HIP09 DMA Engine PCI device
```

编辑 `hw/dma/meson.build`:
```python
softmmu_ss.add(when: 'CONFIG_HISI_DMA', then: files('hisi_dma.c'))
```

编辑 `hw/arm/Kconfig`:
```kconfig
config VIRT
    ...
    select HISI_DMA
```

---

## 第四步：实现PCI设备枚举

### realize函数中完成设备初始化

```c
static void hisi_dma_realize(PCIDevice *pci_dev, Error **errp)
{
    HisiDMAState *s = HISI_DMA(pci_dev);
    MemoryRegion *bar0_mr;

    /* 注册BAR0（避免MSI冲突） */
    bar0_mr = g_new(MemoryRegion, 1);
    memory_region_init(bar0_mr, OBJECT(s), "hisi-dma-bar0", 0x1000);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, bar0_mr);

    /* BAR2用于DMA寄存器 */
    memory_region_init_io(&s->mmio, OBJECT(s), &hisi_dma_mmio_ops, s,
                         TYPE_HISI_DMA, 0x4000);
    pci_register_bar(pci_dev, 2, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->mmio);

    /* MSI初始化 */
    msi_init(pci_dev, 0x50, HISI_DMA_MAX_CHANNELS, true, false, NULL);
}
```

---

## 第五步：实现寄存器访问

### MMIO读写处理

```c
static uint64_t hisi_dma_mmio_read(void *opaque, hwaddr addr,
                                   unsigned size)
{
    HisiDMAState *s = opaque;
    uint32_t ch = (addr - HISI_DMA_Q_BASE) / HISI_DMA_QUEUE_OFFSET;
    addr = (addr - HISI_DMA_Q_BASE) % HISI_DMA_QUEUE_OFFSET;

    if (ch >= HISI_DMA_MAX_CHANNELS) return 0;

    switch (addr) {
    case R_SQ_BASE_L:
    case R_SQ_TAIL_PTR:
        return s->regs[ch][addr/4];
    case R_CTRL0:
        return s->regs[ch][addr/4] |
               (s->channels[ch].queue_enabled ? CTRL0_QUEUE_EN : 0);
    default:
        return s->regs[ch][addr/4];
    }
}

static void hisi_dma_mmio_write(void *opaque, hwaddr addr,
                                uint64_t val, unsigned size)
{
    HisiDMAState *s = opaque;
    HisiDMAChannel *ch = &s->channels[(addr - HISI_DMA_Q_BASE) / 0x100];
    addr = (addr - HISI_DMA_Q_BASE) % 0x100;

    switch (addr) {
    case R_SQ_BASE_L:
        s->regs[ch->qp_num][0] = val;
        ch->sq_dma = (ch->sq_dma & ~0xFFFFFFFFULL) | val;
        break;

    case R_SQ_TAIL_PTR:
        s->regs[ch->qp_num][3] = val;
        ch->sq_tail = val;
        if (ch->queue_enabled) {
            hisi_dma_start_transfer(s, ch->qp_num);
        }
        break;

    case R_CTRL0:
        s->regs[ch->qp_num][8] = val;
        ch->queue_enabled = (val & CTRL0_QUEUE_EN) != 0;
        break;
    }
}
```

---

## 第六步：实现DMA传输逻辑

### 核心：处理SQ_TAIL_PTR写入时触发传输

```c
static void hisi_dma_start_transfer(HisiDMAState *s, int ch)
{
    HisiDMAChannel *channel = &s->channels[ch];

    if (!channel->queue_enabled) return;

    channel->state = FSM_RUN;
    s->regs[ch][R_FSM_STS/4] = FSM_RUN;

    hisi_dma_do_transfer(s, ch);
}

static void hisi_dma_do_transfer(HisiDMAState *s, int ch)
{
    HisiDMAChannel *channel = &s->channels[ch];
    HisiDMASQE sqe;
    uint8_t *buf;
    MemTxResult result;

    /* 检查是否有待处理的任务 */
    if (channel->sq_head == channel->sq_tail) {
        channel->state = FSM_IDLE;
        return;
    }

    /* 读取SQE */
    address_space_read(&address_space_memory,
        channel->sq_dma + channel->sq_head * sizeof(sqe),
        MEMTXATTRS_UNSPECIFIED, &sqe, sizeof(sqe));

    /* 提取参数 */
    uint32_t opcode = le32_to_cpu(sqe.dw0) & 0xF;
    uint32_t length = le32_to_cpu(sqe.length);
    uint64_t src = le64_to_cpu(sqe.src_addr);
    uint64_t dst = le64_to_cpu(sqe.dst_addr);

    /* 执行内存拷贝 */
    buf = g_malloc(length);
    address_space_read(&address_space_memory, src,
                      MEMTXATTRS_UNSPECIFIED, buf, length);
    address_space_write(&address_space_memory, dst,
                       MEMTXATTRS_UNSPECIFIED, buf, length);
    g_free(buf);

    /* 更新sq_head */
    channel->sq_head = (channel->sq_head + 1) % HISI_DMA_MAX_Q_DEPTH;

    /* 写入CQE并触发中断 */
    hisi_dma_complete_transfer(s, ch);
}

static void hisi_dma_complete_transfer(HisiDMAState *s, int ch)
{
    HisiDMAChannel *channel = &s->channels[ch];
    HisiDMACQE cqe = {0};

    cqe.w0 = cpu_to_le16(CQE_STATUS_SUCC | CQE_VALID_BIT);
    cqe.sq_head = cpu_to_le16(channel->sq_head);

    address_space_write(&address_space_memory,
        channel->cq_dma + channel->cq_head * sizeof(cqe),
        MEMTXATTRS_UNSPECIFIED, &cqe, sizeof(cqe));

    channel->cq_head = (channel->cq_head + 1) % HISI_DMA_MAX_Q_DEPTH;

    /* 触发MSI中断 */
    s->regs[ch][R_INT_STS/4] |= 0x1;
    msi_notify(&s->parent_obj, ch);
}
```

### 关键点：sq_head vs sq_tail

```
Driver视角:                    Hardware视角:
┌─────────────────┐           ┌─────────────────┐
│ 写SQE到sq_tail位置│   ──→   │ 读sq_head位置SQE │
│ sq_tail++       │           │ 处理完 sq_head++│
└─────────────────┘           └─────────────────┘
      ↑                               ↑
  SQ_TAIL_PTR寄存器              Hardware内部跟踪
```

---

## 第七步：调试与测试

### 1. 启动QEMU
```bash
/home/wz/qemu/build/qemu-system-aarch64 \
    -m 4G -smp 4 -cpu max \
    -machine virt,gic-version=3 \
    -kernel /home/wz/linux/arch/arm64/boot/Image \
    -initrd /home/wz/tests/qemu_debug/rootfs_sshd_new.cpio.gz \
    -append "console=ttyAMA0" \
    -device hisi-dma,bus=pcie.0
```

### 2. 验证设备枚举
```bash
dmesg | grep -i hisi
# 应该看到:
# hisi_dma 0000:00:03.0: probe SUCCESS
# DMA channels: 4个
```

### 3. 运行dmatest
```bash
# 方法1: 内核命令行
dmatest.run=1

# 方法2: 手动运行
modprobe dmatest
echo 1 > /sys/module/dmatest/parameters/run
dmesg | grep dmatest
```

### 4. 成功标志
```
dmatest: Started 1 threads using dma0chan0
dmatest: Started 1 threads using dma0chan1
dmatest: Started 1 threads using dma0chan2
dmatest: Started 1 threads using dma0chan3
# 无 timeout 错误
```

---

## 经验总结

### 1. 从驱动代码提取信息
- 仔细阅读 `probe()` 函数，了解初始化流程
- 关注 `pci_device_id` 确定设备ID
- 提取寄存器偏移和队列结构

### 2. 调试技巧
- 添加debug输出，跟踪关键路径
- 使用 `-d guest_errors` 查看QEMU日志
- 逐步验证：先枚举，再寄存器，最后传输

### 3. 常见问题
- **MSI不工作**: 使用 `msi_notify()` 而非 `pci_set_irq()`
- **传输不触发**: 检查 `sq_head` 是否正确更新
- **中断丢失**: 确认MSI向量数与通道数匹配

### 4. 开发流程
```
分析驱动 → 生成手册 → 创建骨架 → 枚举设备
   → 寄存器 → 传输逻辑 → 调试测试 → 迭代完善
```

### 5. AI辅助开发
- 让AI帮你阅读和理解复杂代码
- 让AI生成代码骨架
- 自己验证和调试关键逻辑
- AI擅长处理重复性工作和模式匹配

---

## 附录：完整测试命令

```bash
# 编译
cd /home/wz/qemu/build && ninja

# 测试
cd /home/wz/qemu/qemu_debug
./start.sh -append "console=ttyAMA0 dmatest.run=1"
```

---

*文档版本: 1.0*
*日期: 2026-04-16*
