ARM64固件优先SEA/SEI RAS处理基本逻辑
=====================================

-v0.1 2026.04.25 Sherlock init
-v0.2 2026.04.25 Sherlock 增加固件优先寄存器配置、EL3到OS通知机制

简介：分析ARM64架构上固件优先（Firmware First）模式的SEA/SEI RAS错误处理流程，包括异常触发、固件处理、OS处理及关键数据结构。


## 基本逻辑

**SEA (Synchronous External Abort)**
- 同步外部中止，由当前指令执行直接触发
- 异常返回地址指向触发异常的指令本身
- 常见原因：内存错误、设备访问错误、页表遍历错误

**SEI (SError Interrupt)**
- 异步外部中止，与当前指令执行无直接关联
- 异常返回地址指向下一条指令
- 也称为 SError

**RAS (Reliability, Availability, Serviceability)**
- ARMv8.2-A 引入的 RAS 扩展，提供硬件错误检测和报告机制
- 支持错误记录、错误注入、错误恢复等功能

当SEI/SEA发生的时候，硬件可以通过配置决定是报到EL2还是EL3(固件)，通常系统会配置
成报到固件，因为固件是私有的可以查看私有硬件模块的出错信息。固件处理完成后，固件
把需要报给OS的信息放到APEI表里，然后退回OS处理，这里一般是直接退到OS的异常向量
入口。OS里通过读APEI表的信息，得到RAS的更多信息。

硬件通过SCR_EL3配置SEA/SEI报到EL2还是EL3。
```
SCR_EL3
┌─────────────────────────────────────────────────────────────┐
│ Bit 10 │ FIEN (Firmware Interrupt Enable)                   │
│        │ 1 = EA/SError routed to EL3 (Firmware First)       │
│        │ 0 = EA/SError routed to current EL                 │
├────────┼────────────────────────────────────────────────────┤
│ Bit 5  │ EA (External Abort)                                │
│        │ 1 = External Abort/SError routed to EL3            │
│        │ 0 = External Abort routed based on exception level │
├────────┼────────────────────────────────────────────────────┤
│ Bit 2  │ FIQ (Fast Interrupt)                               │
│        │ 1 = FIQ routed to EL3                              │
├────────┼────────────────────────────────────────────────────┤
│ Bit 1  │ IRQ (Interrupt Request)                            │
│        │ 1 = IRQ routed to EL3                              │
└────────┴────────────────────────────────────────────────────┘
```

注意，整个硬件系统分很多部件，比如很多L3/内存相关的部件OS里是看不见的，而core上
报SEA/SEI是core和这些OS看不见部件综合作用的结果，这些部件可以有私有的配置，这些
私有的配置甚至可以决定给core是否返回可以触发core SEA/SEI的信号，这些私有配置有些
还可以决定是否这些私有模块发现错误的时候直接报RAS相关的中断上来。

如果存在虚拟化层，还需要配置 HCR_EL2：
```
HCR_EL2
┌─────────────────────────────────────────────────────────────┐
│ Bit 36 │ Fien (Firmware Interrupt Enable)                   │
│        │ 1 = SError/FIQ can be routed to EL3                │
├────────┼────────────────────────────────────────────────────┤
│ Bit 13 │ TGE (Trap General Exceptions)                      │
│        │ 1 = Traps exceptions to EL2                        │
├────────┼────────────────────────────────────────────────────┤
│ Bit 5  │ AMO (Asynchronous Mask Override)                   │
│        │ 1 = SError routed to EL2 (覆盖SCR_EL3配置)         │
├────────┼────────────────────────────────────────────────────┤
│ Bit 4  │ IMO (Interrupt Mask Override)                      │
│        │ 1 = IRQ routed to EL2                              │
├────────┼────────────────────────────────────────────────────┤
│ Bit 3  │ FMO (FIQ Mask Override)                            │
│        │ 1 = FIQ routed to EL2                              │
└────────┴────────────────────────────────────────────────────┘
```

// Linux 内核处理
```
// arch/arm64/kernel/traps.c
do_sea(unsigned long addr, unsigned int esr, struct pt_regs *regs)
{
    // 1. 检查是否来自用户态
    if (user_mode(regs)) {
        // 发送信号给用户进程
        arm64_notify_die("Synchronous External Abort", regs, ...);
        return;
    }

    // 2. 内核态 SEA 处理
    // 检查是否是 RAS 错误
    if (esr_aet_is_sea(esr)) {
        // 调用 GHES 处理
        ghes_notify_sea();
    }
}
```
