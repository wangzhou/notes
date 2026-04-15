# HiSilicon DMA Engine 芯片手册 (HIP09)

## 概述

本手册描述了HiSilicon HIP09 DMA Engine的硬件寄存器规范。该DMA引擎是一个PCIe设备，支持内存到内存的数据传输。

- **Device ID**: 0xa122
- **Revision**: 0x30 (HIP09A)
- **通道数**: 4
- **MSI中断数**: 4

## 寄存器布局

### 通用队列寄存器 (每个通道, 偏移量: 0x100 * channel_id)

每个DMA通道占用0x100字节的寄存器空间。

| 偏移量 | 名称 | 描述 |
|--------|------|------|
| 0x000 | SQ_BASE_L | 发送队列基地址低32位 |
| 0x004 | SQ_BASE_H | 发送队列基地址高32位 |
| 0x008 | SQ_DEPTH | 发送队列深度 |
| 0x00C | SQ_TAIL_PTR | 发送队列尾指针 |
| 0x010 | CQ_BASE_L | 完成队列基地址低32位 |
| 0x014 | CQ_BASE_H | 完成队列基地址高32位 |
| 0x018 | CQ_DEPTH | 完成队列深度 |
| 0x01C | CQ_HEAD_PTR | 完成队列头指针 |
| 0x020 | CTRL0 | 控制寄存器0 |
| 0x024 | CTRL1 | 控制寄存器1 |
| 0x030 | FSM_STS | 状态机状态 |
| 0x040 | INT_STS | 中断状态 |
| 0x044 | INT_MSK | 中断屏蔽 |
| 0x048 | ERR_INT_STS | 错误中断状态 |
| 0x04C | ERR_INT_MSK | 错误中断屏蔽 |
| 0x068 | SQ_READ_ERR_PTR | SQ读取错误指针 |
| 0x084 | ERR_INT_NUM0 | 错误中断计数0 |
| 0x088 | ERR_INT_NUM1 | 错误中断计数1 |
| 0x08C | ERR_INT_NUM2 | 错误中断计数2 |

### 通用寄存器 (设备级)

| 偏移量 | 名称 | 描述 |
|--------|------|------|
| 0x0030 | COMMON_AND_CH_ERR_STS | 通用和通道错误状态 |
| 0x0150 | DMA_PORT_IDLE_STS | DMA端口空闲状态 |
| 0x0184 | DMA_CH_RAS_LEVEL | DMA通道RAS级别 |
| 0x0188 | DMA_CM_RAS_LEVEL | DMA通用RAS级别 |
| 0x0244 | DMA_CM_CE_RO | DMA通用可纠正错误计数(只读) |
| 0x0248 | DMA_CM_NFE_RO | DMA通用不可纠正错误计数(只读) |
| 0x024C | DMA_CM_FE_RO | DMA通用致命错误计数(只读) |
| 0x02E0 | DMA_CH_DONE_STS | DMA通道完成状态 |
| 0x0320 | DMA_CH_ERR_STS | DMA通道错误状态 |

### 端口配置寄存器

| 偏移量 | 名称 | 描述 |
|--------|------|------|
| 0x800 + port_id * 0x20 | PORT_CFG | 端口配置寄存器 |

## 寄存器字段详细描述

### CTRL0 (0x020) - 控制寄存器0

| 位 | 名称 | 描述 |
|----|------|------|
| 0 | QUEUE_EN | 队列使能: 1=使能, 0=禁用 |
| 4 | QUEUE_PAUSE | 队列暂停: 1=暂停, 0=继续 |
| 26 | SQ_DRCT | SQ方向: 0=本地侧, 1=远程侧 |
| 27 | CQ_DRCT | CQ方向: 0=本地侧, 1=远程侧 |
| 31:28 | ERR_ABORT_EN | 错误中止使能 |

### CTRL1 (0x024) - 控制寄存器1

| 位 | 名称 | 描述 |
|----|------|------|
| 0 | QUEUE_RESET | 队列复位: 1=复位 |
| 2 | VA_ENABLE | VA使能: 1=使能 |

### FSM_STS (0x030) - 状态机状态

| 值 | 状态名称 | 描述 |
|----|----------|------|
| 0 | IDLE | 空闲 |
| 1 | RUN | 运行中 |
| 2 | CPL | 完成 |
| 3 | PAUSE | 暂停 |
| 4 | HALT | 停止 |
| 5 | ABORT | 中止 |
| 6 | WAIT | 等待 |
| 7 | BUFFCLR | 缓冲清除 |

### INT_STS (0x040) - 中断状态

| 位 | 名称 | 描述 |
|----|------|------|
| 0 | INT_STS_MASK | 中断状态位 (0x1) |

### INT_MSK (0x044) - 中断屏蔽

| 位 | 名称 | 描述 |
|----|------|------|
| 0 | INT_MSK_MASK | 中断屏蔽位 |

### ERR_INT_STS (0x048) - 错误中断状态

| 位 | 名称 | 描述 |
|----|------|------|
| 18:1 | ERR_INT_STS_MASK | 错误中断状态掩码 |

## 队列条目结构

### 发送队列条目 (SQE) - 32字节

```c
struct hisi_dma_sqe {
    uint32_t dw0;           // 操作码(低4位) + 本地中断使能(第8位)
    uint32_t dw1;          // 保留
    uint32_t dw2;          // 保留
    uint32_t length;       // 传输长度
    uint64_t src_addr;     // 源地址
    uint64_t dst_addr;     // 目标地址
};
```

**dw0字段:**
- bits[3:0]: OPCODE
  - 0x1: 小包
  - 0x4: 内存到内存传输
- bit[8]: LOCAL_IRQ_EN - 本地中断使能

### 完成队列条目 (CQE) - 8字节

```c
struct hisi_dma_cqe {
    uint32_t rsv0;         // 保留
    uint32_t rsv1;         // 保留
    uint16_t sq_head;      // SQ头指针
    uint16_t rsv2;         // 保留
    uint16_t rsv3;         // 保留
    uint16_t w0;           // 状态
};
```

**w0字段:**
- bit[0]: VALID_BIT - 有效位
- bits[15:1]: STATUS
  - 0x0: 成功

## 队列初始化流程

1. 设置SQ基地址 (SQ_BASE_L, SQ_BASE_H)
2. 设置CQ基地址 (CQ_BASE_L, CQ_BASE_H)
3. 设置队列深度 (SQ_DEPTH, CQ_DEPTH) - 值 = 深度 - 1
4. 初始化SQ尾指针和CQ头指针为0
5. 配置CTRL0:
   - 设置SQ/CQ方向 (SQ_DRCT, CQ_DRCT = 0 本地侧)
   - 设置错误处理方式 (ERR_ABORT_EN = 0)
6. 配置CTRL1:
   - 设置VA_ENABLE = 1
7. 使能队列 (QUEUE_EN = 1)
8. 解除中断屏蔽

## 数据传输流程

### 发送端 (CPU侧)

1. 分配SQE空间并填充:
   - 设置length
   - 设置src_addr和dst_addr
   - 设置OPCODE = 0x4 (M2M)
   - 设置LOCAL_IRQ_EN
2. 更新SQ_TAIL_PTR指向新的SQE位置
3. DMA引擎读取SQE并执行传输

### 完成端

1. DMA引擎完成传输后写入CQE
2. 设置VALID_BIT和STATUS
3. 触发MSI中断
4. CPU读取CQ_HEAD_PTR获取完成信息
5. 更新CQ_HEAD_PTR释放CQE

## 中断处理

- 每个通道有独立的MSI中断
- 中断号对应通道号 (0-3)
- 中断屏蔽通过INT_MSK寄存器控制

## 复位流程

1. 暂停队列 (QUEUE_PAUSE = 1)
2. 禁用队列 (QUEUE_EN = 0)
3. 屏蔽中断
4. 等待状态机离开RUN状态
5. 执行复位 (QUEUE_RESET = 1)
6. 重置队列指针 (SQ_TAIL_PTR = 0, CQ_HEAD_PTR = 0)
7. 恢复队列 (QUEUE_PAUSE = 0)
8. 重新使能队列和中断

## BAR空间布局

DMA设备使用PCIe BAR2，基地址为0x2000开始:

```
0x0000 - 0x0FFF: 保留
0x1000 - 0x13FF: 通道0寄存器 (0x100 * 0 + 0x2000)
0x1400 - 0x17FF: 通道1寄存器
0x1800 - 0x1BFF: 通道2寄存器
0x1C00 - 0x1FFF: 通道3寄存器
0x2000+:       设备级通用寄存器
```
