-v0.1 Sherlock 2026.5.20 init
-v0.2 Sherlock 2026.5.20 补充CNTPOFF定义、TGE翻转机制、与CNTVOFF的对比
-v0.3 Sherlock 2026.5.20 补充嵌套虚拟化VTIMER完整逻辑、CNTPOFF在NV下的角色


简介：分析 ARM64 KVM 中 CNTPOFF_EL2 的功能和使用场景，以及偏移为 0 时的优化。


一、物理计数器和虚拟计数器的根本差异
====================================

ARM 系统里物理计数器 CNTPCT_EL0 是全系统共享的定海神针——每个 PE、host、EL3、
安全世界都依赖它。ARM 设计虚拟化时对两个计数器的态度完全相反：

  虚拟计数器 CNTVCT_EL0:  天生就是要被偏移的（给每个 VM 不同的时间视图）
  物理计数器 CNTPCT_EL0:  天生就是不该被改的（全系统共享）

所以 CNTVOFF_EL2 无条件生效（任何时候读 CNTVCT_EL0 硬件自动减去它），
CNTPOFF_EL2 则必须受控——只在 guest 上下文且软件显式使能时才生效：

  CNTVOFF: CNTVCT_EL0 = raw - CNTVOFF_EL2        → 一直生效，不受 TGE 影响
  CNTPOFF: CNTPCT_EL0 = raw + CNTPOFF_EL2        → 仅 TGE=0 且 ECV=1 时生效

CNTPOFF 的受控条件：
  - CNTHCTL_EL2.ECV = 1（KVM 在 kvm_timer_init_vhe() 里打开）
  - HCR_EL2.TGE = 0

  TGE=1 (host):   CNTPCT_EL0 = raw_counter           ← CNTPOFF 不生效
  TGE=0 (guest):  CNTPCT_EL0 = raw + CNTPOFF_EL2     ← CNTPOFF 生效

为什么必须受 TGE 控制？因为 host 自己也读 CNTPCT_EL0。TGE=1 时 host EL0
用户态读物理计数器，必须返回 raw 值，不能带偏移。CNTVOFF 则没这个问题——
host 根本不会读 CNTVCT_EL0（host 用物理计数器），无条件生效也无所谓。


二、为什么 CNTPOFF 要处理 CVAL 而不是 CNTPCT
============================================

CNTPCT_EL0 的偏移是硬件自动完成的，KVM 不需要干预：

  guest 读 CNTPCT_EL0 → 硬件自动返回 raw + CNTPOFF_EL2

但硬件定时器比较器 CNTP_CVAL_EL0 没有自动偏移机制。触发条件：

  raw_counter >= CNTP_CVAL_EL0

KVM 必须根据当前 TGE 状态手动计算写什么值：

  TGE=1 (CNTPOFF 不生效):  CNTP_CVAL_EL0 = guest_CVAL + offset
  TGE=0 (CNTPOFF 生效):    CNTP_CVAL_EL0 = guest_CVAL

  offset 靠 CNTPOFF_EL2 提供，比较器自动加上

TGE 翻转时，CNTPCT 那边硬件搞定，CNTP_CVAL_EL0 这边必须软件手动 ±offset。
这就是 __activate_traps 里要重写 CVAL 的根本原因。


三、为什么 VTIMER 不需要在 __activate_traps 里处理
==================================================

VTIMER 的比较器直接跟 CNTVCT_EL0 做比较：

  触发：CNTVCT_EL0 (= raw - CNTVOFF) >= CNTV_CVAL_EL0

CVAL 和 CNTVCT 在同一个"虚拟计数器参考系"里，CNTVOFF 对两者同时生效。
而且 CNTVOFF 不受 TGE 影响，TGE 翻转不改变任何东西。vtimer 在 timer_save/restore
里处理就够了，不需要在 activate/deactivate 补刀。

VTIMER restore（正常路径，非 broken）不调整 cval：
  cval = timer_get_cval(ctx)           // 从内存直接取
  set_cntvoff(offset)                  // CNTVOFF_EL2 = offset
  write_sysreg_el0(cval, CNTV_CVAL)    // 直接写，不加 offset

PTIMER restore 必须调整 cval：
  cval = timer_get_cval(ctx)
  offset = timer_get_offset(ctx)
  set_cntpoff(offset)
  cval += offset                       // 必须加 offset
  write_sysreg_el0(cval, CNTP_CVAL)


四、VHE 下 TGE 翻转的完整时间线
================================

kvm_vcpu_load_vhe()                          // TGE=1 (host)
  kvm_timer_vcpu_load()
    timer_restore_state(ptimer)
      cval = 内存 guest_CVAL
      offset = 0 (默认)
      set_cntpoff(0)                         // CNTPOFF_EL2 = 0
      cval += 0                              // cval 不变
      write CNTP_CVAL_EL0 = guest_CVAL       // TGE=1，offset 写在 CVAL 里
  __vcpu_load_activate_traps()               // CPTR 等，不写 HCR
  __load_stage2()                            // VTTBR/VTCR，不写 HCR
──────────────────────────────────────────────────────
... 返回用户态，可能被调度 ...
──────────────────────────────────────────────────────

__kvm_vcpu_run_vhe()                         // TGE=1 (host)
  sysreg_save_host_state_vhe()

  __activate_traps(vcpu)
    ___activate_traps(hcr)                   // write_sysreg_hcr(guest_hcr)
                                                TGE 1→0 ★
    if (has_cntpoff()):                      // TGE=0，CNTPOFF 开始生效
      从内存取 guest_CVAL（不带 offset）
      写 CNTP_CVAL_EL0 = guest_CVAL          // 重置，不带 offset

  __guest_enter()                            // ERET 到 guest (EL1)
  ════════════ guest 运行 (TGE=0) ════════════
  退出 guest
  ═══════════════════════════════════════════

  sysreg_save_guest_state_vhe()

  __deactivate_traps(vcpu)
    ___deactivate_traps()
    write_sysreg_hcr(HCR_HOST_VHE_FLAGS)     // TGE 0→1 ★
    if (has_cntpoff()):                      // TGE=1，CNTPOFF 不再生效
      val = read CNTP_CVAL_EL0              // 读硬件当前值
      保存 val 到内存
      read CNTPOFF_EL2
      if (offset) write CNTP_CVAL_EL0 = val + offset  // 恢复 TGE=1 写法

  sysreg_restore_host_state_vhe()
──────────────────────────────────────────────────────
回到 host


五、嵌套虚拟化 VTIMER 的实现逻辑
================================

5.1 单层虚拟化回顾

  L0 (KVM):  设置 CNTVOFF_EL2 = X（vcpu 创建时设一次）
  L1 (Guest): 读 CNTVCT_EL0 → 硬件返回 CNTPCT - CNTVOFF_EL2

  一个 offset，一个硬件寄存器，搞定。

5.2 嵌套引入的新问题

  嵌套下：
    L0 (KVM)
     ├─ L1 VM ─── 它也是个 hypervisor
     │   └─ L2 VM ─── 嵌套 guest

  L1 也要给 L2 设虚拟计数器偏移，会写 CNTVOFF_EL2 寄存器。
  但硬件只有一个 CNTVOFF_EL2！两级偏移必须叠加：

    L2 看到的 CNTVCT = CNTPCT - (L0_offset + L1_offset)

  硬件不支持两层，只能靠软件。

5.3 ARM 的方案：NV2 内存重定向

  核心思想：L2 在 EL1 读 CNTVCT_EL0 时，硬件不读真正的寄存器，
  而是读 VNCR 内存（per-vCPU 的一块内存）。L0 在进入 L2 之前，
  把合并好的计数器值提前写进 VNCR。

  L2 读 CNTVCT_EL0 → NV2 重定向 → 读 VNCR → 拿到 L0 写好的合并值

5.4 offset 如何组合

  L1 写 CNTVOFF_EL2：
    emulate-nested.c:915: SR_TRAP(SYS_CNTVOFF_EL2, CGT_HCR_NV)
    → trap 到 L0 → 值存入 vcpu->arch.ctxt[CNTVOFF_EL2]

  kvm_timer_vcpu_reset() 里设置指针：
    offs->vcpu_offset = __ctxt_sys_reg(&vcpu->arch.ctxt, CNTVOFF_EL2)  // 指向L1的值
    offs->vm_offset   = &vcpu->kvm->arch.timer_data.poffset            // L0的偏移

  timer_get_offset(vtimer) 自动合并：
    offset = poffset + L1_CNTVOFF_EL2   // 两级自动加起来

5.5 L1 跑 vs L2 跑

  get_timer_map() 决定当前用哪个 timer：

    L1 跑 (非 HYP):                   L2 跑 (HYP):
      direct_vtimer = vtimer            direct_vtimer = hvtimer (EL2)
      emul_vtimer  = hvtimer            emul_vtimer  = vtimer (EL1)

  L1 跑的时候：
    offset = poffset + L1_CNTVOFF_EL2
    set_cntvoff(poffset + L1_CNTVOFF)   → 合并值直接写硬件 CNTVOFF_EL2
    L1 读 CNTVCT → 硬件搞定，L1 无感知

  L2 跑的时候：
    offset = poffset（hvtimer 不含 L1 偏移）
    CNTVOFF_EL2 = poffset（只写 L0 层）

    L2 的 CNTVCT 值 = raw - poffset - L1_CNTVOFF
    L0 提前算好写入 VNCR
    L2 读 CNTVCT → NV2 重定向到 VNCR → 拿到合并值

  核心公式：
                L1 跑                      L2 跑
    CNTVOFF:    poffset + L1_CNTVOFF      poffset
    counter:    硬件自动                   L2 → VNCR(提前写入合并值)


六、CNTPOFF 在嵌套虚拟化下的角色
================================

6.1 平行对照 VTIMER 和 PTIMER

                      VTIMER                        PTIMER / CNTPOFF
  硬件偏移寄存器:       CNTVOFF_EL2                   CNTPOFF_EL2
  counter 公式:       raw - CNTVOFF                 raw + CNTPOFF (EL0, TGE=0)
  offset生效条件:      无条件                          TGE=0 且 ECV=1
  L1设偏移给L2的寄存器: CNTVOFF_EL2 (trap)             CNTPOFF_EL2 (trap)

6.2 L1 跑的时候

  VTIMER:
    CNTVOFF = poffset + L1_CNTVOFF     ← L0/L1 偏移合并写硬件
  PTIMER:
    CNTPOFF = poffset                   ← 只写 L0 偏移

  为什么 ptimer 不合并？L1 自己是 hypervisor，它设 CNTPOFF_EL2 是给 L2 用的，
  不是给自己用的。L1 看到 L0 的偏移就够了。L1 的 CNTPOFF 值 trap 后存 VNCR，
  留给 L2 用。

6.3 L2 跑的时候

  VTIMER:                               PTIMER:
    CNTVOFF = poffset                     CNTPOFF = poffset
    (L1偏移不在硬件寄存器)                  (L1偏移也不在硬件寄存器)

    EL0读CNTVCT → ECV trap               EL0读CNTPCT → ECV trap
    → 软件: raw - poffset - L1偏移       → 软件: raw + poffset + L1偏移

    EL1读CNTVCT → NV2→VNCR               EL1读CNTPCT → NV2→VNCR
    → L0提前写入合并值                    → L0提前写入合并值

6.4 核心结论

  CNTPOFF_EL2 硬件寄存器在 NV 下的角色很简单：只管 L0 这一层的偏移（poffset）。
  这和 vtimer 在 L1 跑时的情况不同——vtimer 在 L1 跑时可以合并两级写硬件
  （反正 CNTVOFF 无 TGE 门控，合并也无害），ptimer 因为 TGE 门控限制，
  L1 的偏移只能等 L2 真正跑起来通过 trap+软件合并。

  CNTPOFF_EL2 之所以是现在这个设计，根本原因：
  1. 物理计数器不应该随便偏移 → TGE 门控 + ECV enable
  2. 嵌套下 L1 偏移不走硬件寄存器 → NV2 内存重定向 / ECV trap 软件路径
  3. L0 只管自己那层 offset（poffset），不替 L1 合并
  4. [NOTE: 上述 6.2/6.3 里"L2 EL0 读 CNTPCT 走 ECV trap"的说法还需要再验证]


七、初始化和偏移来源
====================

1. vCPU 创建（arch_timer.c:1092）：
   timer_set_offset(vcpu_vtimer(vcpu), kvm_phys_timer_read())  // vtimer offset != 0
   timer_set_offset(vcpu_ptimer(vcpu), 0)                       // ptimer offset = 0

2. 用户态写 CNTVCT_EL0/CNTPCT_EL0（sys_regs.c:1624-1629）：
   用于 VM 迁移恢复时间戳。计算新 offset = 当前物理计数 - 用户设的值。

3. KVM_ARM_SET_COUNTER_OFFSET ioctl（arch_timer.c:1709）：
   用户态（QEMU）直接设置 VM 级别的计数器偏移，voffset 和 poffset 同时设。
   设置后禁止通过 sysreg 写路径再改。


八、offset 数据结构
===================

struct arch_timer_offset {
    u64 *vm_offset;      // 指向 kvm->arch.timer_data.{voffset, poffset}（VM 级别）
    u64 *vcpu_offset;    // 指向 vcpu->arch.ctxt 中某个 sysreg 地址（per-vcpu，NV）
};

timer_get_offset() = (*vm_offset 或 0) + (*vcpu_offset 或 0)

PTIMER：
  vm_offset   = 指向 poffset，默认 0
  vcpu_offset = 始终为 NULL

VTIMER（普通VM）：
  vm_offset   = 指向 voffset，值为 kvm_phys_timer_read()
  vcpu_offset = NULL

VTIMER（NV场景）：
  vm_offset   = 指向 poffset
  vcpu_offset = 指向 vcpu->arch.ctxt[CNTVOFF_EL2]（L1设的偏移）


九、CNTPOFF 热路径代码（VHE）
============================

__activate_traps (switch.c:119) — 进入 guest：
  ___activate_traps() 写 HCR 后 TGE=0，从内存取不带 offset 的 guest CVAL
  重写 CNTP_CVAL_EL0。

__deactivate_traps (switch.c:153) — 退出 guest：
  HCR 已恢复为 host (TGE=1)，读硬件 CNTP_CVAL_EL0 保存到内存，
  读 CNTPOFF_EL2，根据 offset 调整 CVAL 回到 TGE=1 的写法。

timer_restore_state (arch_timer.c:632) — vcpu_load 时：
  case TIMER_PTIMER/HPTIMER：
    cval = 内存 guest_CVAL + offset 写入 CNTP_CVAL_EL0 (TGE=1)
    set_cntpoff(offset) → 写硬件 CNTPOFF_EL2

timer_save_state (arch_timer.c:490) — vcpu_put 时：
  case TIMER_PTIMER/HPTIMER：
    读硬件 CNTP_CVAL_EL0，cval -= offset，存入内存（去掉 offset）
    set_cntpoff(0) → 清零 CNTPOFF_EL2


十、get_timer_map (arch_timer.c:154)
====================================

  VHE + 非NV：direct_ptimer = vcpu_ptimer，emul_ptimer = NULL
  nVHE      ：direct_ptimer = NULL，emul_ptimer = vcpu_ptimer
  NV + hyp  ：direct_ptimer = vcpu_hptimer，emul_ptimer = vcpu_ptimer
  NV + !hyp ：direct_ptimer = vcpu_ptimer，emul_ptimer = vcpu_hptimer


十一、使用场景
==============

| 场景                           | ptimer offset | has_cntpoff() | 使用 CNTPOFF |
|--------------------------------|:------------:|:-------------:|:----------:|
| 普通 VM（默认）                 | 0            | false          | 否         |
| 普通 VM（有ECV硬件的默认场景）   | 0            | true           | 否，但白走 save/restore |
| 普通 VM + SET_COUNTER_OFFSET    | 非0          | true/false     | 视硬件     |
| NV                             | 非0?         | true/false     | 待验证      |


十二、优化（本分支改动）
========================

场景：系统有 ECV CNTPOFF 硬件支持（has_cntpoff() = true），但 ptimer offset 为 0。

问题：__activate_traps / __deactivate_traps 中会走进 has_cntpoff() 块，
offset 为 0 时 TGE=1 和 TGE=0 下 CVAL 写值相同，所有 save/reload 都是无用的。

改动：在 has_cntpoff() 块内加 timer_get_offset(map.direct_ptimer) != 0 的判断，
offset 为 0 时跳过整个 CNTPOFF 相关 CVAL 操作。

注：set_cntpoff(0) 写 0 到 CNTPOFF_EL2 也存在一次无用的 MSR 写，但不在核心路径上，暂未优化。
