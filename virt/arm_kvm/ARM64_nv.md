-v0.1 2026.6.15 Sherlock init
-v0.2 2026.7.21 补充vEL2寄存器模拟的完整分析

简介：梳理ARM64 nested virtualization的基本逻辑。


基本逻辑
--------

 L2: nested guest OS  (virtual EL0, virtual EL1)

 L1: guest hypervisor (EL1, virtual EL2)

 L0: host kvm (EL2)


vEL2寄存器模拟
---------------

1. NV2 硬件基础: VNCR_EL2

NV2 的核心设计: L1 所有 Op0=4 (EL2 编码) 的 MSR/MRS 指令, 硬件自动转为对
[VNCR_EL2 + offset] 地址的内存读写, 不产生 trap。

L0 为每个 vCPU 分配一页内存 vncr_array[] (kvm_vcpu_init_nested, nested.c:79-81),
这就是 L1 的 VNCR 页。物理 VNCR_EL2 根据当前运行的身份指向不同地址:

    L1 在跑 (is_hyp_ctxt=true):  VNCR_EL2 = vncr_array
    L2 在跑 (is_hyp_ctxt=false): VNCR_EL2 = fixmap(L1 VNCR 页的 HPA)

2. 两层寄存器架构

┌─────────────────────────────────────────────────────┐
│ VNCR 页 (内存): 所有 EL2 寄存器的持久存储               │
│  - 硬件自动管理，不 trap                              │
│  - 值永远不丢                                        │
├─────────────────────────────────────────────────────┤
│ 物理 EL1 寄存器: 当前正在跑的身份的"舞台"               │
│  - L1 跑时 = L1 的 vEL2 寄存器                       │
│  - L2 跑时 = L2 的 vEL1 寄存器                       │
│  - L0 在切换时搬运                                    │
└─────────────────────────────────────────────────────┘

3. L0 的角色: 在该搬的时候把 VNCR 的值搬进/搬出物理 EL1 寄存器

vcpu_load(L1):                 vcpu_put(L1):
  VNCR[VBAR_EL2] → 物理 VBAR    物理 VBAR → VNCR[VBAR_EL2]
  VNCR[SCTLR_EL2]→ 物理 SCTLR   物理 SCTLR→ VNCR[SCTLR_EL2]
  VNCR[TCR_EL2]  → 物理 TCR     物理 TCR  → VNCR[TCR_EL2]
  ...                           ...

代码: sysreg-sr.c __sysreg_restore_vel2_state() / __sysreg_save_vel2_state()

4. L1 访问 EL2 寄存器的语义表

EL1 和 EL2 是两套编码。VHE Host 写 _EL1 编码设自己的 EL2 寄存器
(硬件重定向), L1 也写同样的代码, L0 保证语义一致。

┌────────┬─────────────┬──────────────────────┬──────────────────────┐
│ 谁来访问 │ 用什么编码     │ 语义                   │ 硬件行为                │
├────────┼─────────────┼──────────────────────┼──────────────────────┤
│ L1      │ MSR x_EL2    │ 设我的 vEL2 寄存器      │ NV2 → VNCR 页          │
│         │ (Op0=4)      │                       │ 不进物理寄存器           │
│         │ MSR x_EL1    │ 设我的 vEL2 寄存器      │ 直接物理 EL1 寄存器      │
│         │ (Op0=3)      │ (和上面一样，不同路径，   │ L0 vcpu_load 已从 VNCR   │
│         │              │  VHE Host 也这样写)     │ 搬到物理寄存器           │
├────────┼─────────────┼──────────────────────┼──────────────────────┤
│ L2      │ MSR x_EL1    │ 设自己的 vEL1 寄存器     │ 直接物理 EL1 寄存器      │
│         │ (Op0=3)      │                       │ L0 已加载 L2 的值        │
│         │ MSR x_EL2    │ 不该碰                  │ NV2 → fixmap →         │
│         │ (Op0=4)      │                       │ 直写进 L1 的 VNCR 页     │
└────────┴─────────────┴──────────────────────┴──────────────────────┘

5. VNCR 页上 EL2 寄存器如何保证功能 — 分三类

┌──────────────────────────────────────────────────────────────┐
│ 第一类: 控制 CPU 行为 (硬件必须读到物理寄存器才能生效)           │
├────────────┬─────────────────────────────────────────────────┤
│ HCR_EL2    │ L0 读 VNCR → __compute_hcr() 合并进物理 HCR     │
│ VTCR_EL2   │ L0 读 VNCR → 查找影子 S2 → 加载物理 VTCR         │
│ VTTBR_EL2  │ L0 读 VNCR → 查影子 S2 → 加载物理 VTTBR          │
│ CPTR_EL2   │ L0 读 VNCR → translate → 物理 CPACR_EL1         │
│ CNTHCTL_EL2│ L0 读 VNCR → 跟 CNTKCTL_EL1 合并                │
│ FGT 寄存器  │ L0 读 VNCR → triage_sysreg_trap 查表判断         │
├────────────┴─────────────────────────────────────────────────┤
│ 第二类: 纯状态值 (CPU 在异常时会写，但不主动读来做决策)          │
├────────────┬─────────────────────────────────────────────────┤
│ VBAR_EL2   │ vcpu_load: VNCR → 物理 EL1 VBAR                │
│ SCTLR_EL2  │                        同上                      │
│ TCR_EL2    │                        同上                      │
│ SPSR_EL2   │                        同上                      │
│ ELR_EL2    │                        同上                      │
│ ESR_EL2    │ vcpu_put: 物理 EL1 → VNCR (CPU 异常时写物理EL1)  │
│ FAR_EL2    │                        同上                      │
├────────────┴─────────────────────────────────────────────────┤
│ 第三类: 纯数据 (CPU 不碰，只有软件读写)                         │
├────────────┬─────────────────────────────────────────────────┤
│ VSESR_EL2  │ L0 注入 SError 时读到它填物理寄存器               │
│ VDISR_EL2  │                        同上                      │
│ TPIDR_EL2  │ 就留在 VNCR 页，L0 搬都不搬                       │
└────────────┴─────────────────────────────────────────────────┘

6. L2 异常到 vEL2 的完整流程

L2 在物理 EL1 跑，执行了 L1 设置要 trap 的操作:

    L2 → 硬件 trap 到 L0 (真 EL2)
      │  trap 目标永远是 L0，不会是 vEL2
      ▼
    L0: triage_sysreg_trap() → "这个 trap L1 想要"
      │
      ├─ vcpu_put(L2):  保存 L2 的 EL1 寄存器 (物理→内存)
      ├─ kvm_inject_el2_exception(): 标记 pending exception
      ├─ vcpu_load(L1): VNCR[VBAR_EL2] → 物理 EL1 VBAR
      │                  VNCR[SCTLR_EL2]→ 物理 EL1 SCTLR
      │                  现在物理 EL1 = L1 的 vEL2
      ▼
    L1 运行 (vEL2), CPU 从物理 EL1 VBAR (即 L1 的 VBAR_EL2 值) 取向量
      │  CPU 自动写物理 EL1 SPSR/ELR/ESR/FAR (= L1 的 vEL2 对应寄存器)
      ▼
    L1 ERET → L0 → vcpu_put(L1) / vcpu_load(L2) → L2 继续跑

L1 的 vEL2 VBAR 和 L2 的 vEL1 VBAR 不会同时需要物理 EL1 寄存器 —
L0 总在中间做切换，物理 EL1 寄存器只承载"当前在跑"的值。

但 VNCR 页上的值 "同时" 有效: L2 在跑时写 EL2 编码 (如 ICH_LR0_EL2),
硬件通过 fixmap VNCR 直写进 L1 的 VNCR 页。L1 无论是当前在跑还是
后续被调度，读到 VNCR 页都能看到 L2 写入的最新值。


分解逻辑点
-----------

- vEL2 Stage2页表和L0 Stage2页表合并的逻辑

- vtimer整体逻辑

- vIRQ整体逻辑

  vPPI/vSGI/vSPI

- TLBI整体逻辑

- VMID整体逻辑
