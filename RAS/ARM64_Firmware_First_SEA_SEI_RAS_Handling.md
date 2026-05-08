ARM64固件优先SEA/SEI RAS处理基本逻辑
=====================================

-v0.1 2026.04.25 Sherlock init
-v0.2 2026.04.25 Sherlock 增加固件优先寄存器配置、EL3到OS通知机制

简介：分析ARM64架构上固件优先(Firmware First)模式的SEA/SEI RAS错误处理流程，包括异常触发、固件处理、OS处理及关键数据结构。


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
│ Bit 3  │ EA (External Abort)                                │
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

## Linux内核处理
```c
// arch/arm64/mm/fault.c
do_sea(unsigned long addr, unsigned int esr, struct pt_regs *regs)
{
    ...
    arm64_notify_die
        if (user_mode(regs))   <--- 用户态触发错误时，会向进程发信号，终止进程
            arm64_force_sig_fault
        else                   <--- 如果是内核触发，会做一系列的处理后panic内核
            die(str, regs, err)
                ...
                __die()
                crash_kexec()  <--- 注意crash要显式调用，不然不会有vmcore
                panic()
}
```
注意，有的时候，一个RAS错误源头可能触发一个SEA和一个SEI，如果在SEA处理逻辑还没有
关中断的时候，SEI被taken了，那么SEI看到的信息是SEA的栈信息，无法打印出实际触发这个
RAS错误的栈。这个时候可以hack下这里的do_sea，一进来就panic内核，这样可以看到触发
RAS错误的栈。
