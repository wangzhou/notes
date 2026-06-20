ARM timer 体系 — KVM 视图
==========================

NV 硬件上，L0 KVM 可以启动两种虚机：
- **普通 VM**（EL0/EL1）：和非 NV 硬件行为一致，guest 看不到 EL2
- **NV VM**（EL0/EL1/EL2）：guest 内可以再跑 hypervisor（L1），L1 里再跑 L2

| Timer | 系统寄存器 | PPI | KVM 角色 | 普通 VM (EL0/EL1) | NV VM (EL0/EL1/EL2) |
|---|---|---|---|---|---|
| EL2 physical (真实) | CNTHP_CTL/CVAL/TVAL_EL2 | 26 | 不管 (host arch_timer) | L0 调度时钟 | L0 host，L1 跑时切给 L1 |
| | | | | | |
| vEL2 physical (虚拟) | 同上 (L1 视角的 CNTHP) | 26 | HPTIMER [3] | — | **L1 的调度时钟** |
| | | | | | |
| vEL2 virtual (虚拟) | CNTHV_CTL/CVAL_EL2 | 28 | HVTIMER [2] | — | L1 设 CNTVOFF 用，偶尔碰 |
| | | | | | |
| EL1 physical | CNTP_CTL/CVAL/TVAL_EL0 | 30 | PTIMER [0] | host 用 | guest 一般不使能 |
| | | | | | |
| EL1 virtual | CNTV_CTL/CVAL/TVAL_EL0 | 27 | VTIMER [1] | guest arch_timer | **L2 的 arch_timer** |

实际热路径就两个：`VTIMER` + `HPTIMER`。

---

NV VM 的 L1 调度时钟（HPTIMER）
===============================

## 先搞清硬件

ARM 有三组物理 timer 寄存器：

```
CNTP_CTL/CVAL_EL0  (3,3,14,2,1) ─── EL1 物理 timer
CNTHP_CTL_EL2      (3,4,14,2,1) ─── EL2 物理 timer
```

VHE 下 `SYS_CNTP_*_EL0` 从 EL2 访问时，HCR_EL2 决定它访问哪组：

| TGE | `write_sysreg_el0(SYS_CNTP_CTL)` 写到 |
|:---:|------|
| 0 | CNTP_CTL_EL0（EL1 物理 timer） |
| 1 | CNTHP_CTL_EL2（EL2 物理 timer） |

## L1 跑起来时

L0 把 L1 放在 EL1（HCR_EL2.NV/NV2 设了，TGE=0）。L1 访问 CNTP_CTL_EL0 → 真实的 EL1 物理 timer 寄存器。L1 以为这是 CNTHP_CTL_EL2（因为它觉得自己在 EL2+VHE），但实际上硬件是 EL1 那组。

所以 L1 的调度时钟，**底层硬件是 CNTP_CTL_EL0 + CNTPOFF_EL2**。

## 为什么 KVM 代码里叫 HPTIMER

HPTIMER 是 KVM 给这个 timer context 起的名字。sys_reg 存在 `CNTHP_CTL_EL2` / `CNTHP_CVAL_EL2` 槽位——因为从 L1 的视角看，这就是它的 EL2 物理 timer。但硬件上映射到 CNTP_CTL_EL0。

和 PTIMER 的区别只在 sys_reg 槽位不同：

```
timer_set_ctl(HPTIMER):  __vcpu_assign_sys_reg(vcpu, CNTHP_CTL_EL2, ctl)  // 存 L1 视角
timer_set_ctl(PTIMER):   __vcpu_assign_sys_reg(vcpu, CNTP_CTL_EL0, ctl)   // 存 EL1 视角
```

硬件上它们分时复用同一组 CNTP 寄存器。

## vcpu_load：写硬件

```
vcpu_load (TGE=1，VHE redirect 生效):
    timer_restore_state(HPTIMER):
        offset = poffset
        set_cntpoff(offset)                        // CNTPOFF_EL2 = poffset
        cval += offset
        write_sysreg_el0(cval, CNTP_CVAL)          // TGE=1 → 写到 CNTHP_CVAL_EL2
        write_sysreg_el0(ctl,  CNTP_CTL)           // TGE=1 → 写到 CNTHP_CTL_EL2
```

这一步写到 EL2 的寄存器，是**暂存**。下面 __activate_traps 才搬到 L1 真正用的 EL1 寄存器。

## __activate_traps：搬到 EL1

```
__activate_traps (TGE=0，VHE redirect 不生效):
    val = __vcpu_sys_reg(vcpu, CNTHP_CVAL_EL2)     // 读 sys_reg 里的原始 CVAL
    write_sysreg_el0(val, SYS_CNTP_CVAL)            // TGE=0 → 写到 CNTP_CVAL_EL0
```

现在 L1 的 EL1 物理 timer 有了正确的 CVAL，CNTPOFF 也设好了：

```
L1 运行中: CNTPCT_EL0 = kpt_read() - poffset
           定时器触发: kpt_read() - poffset >= CNTP_CVAL_EL0(L1)
           → kpt_read() >= CNTP_CVAL_EL0(L1) + poffset ✓
```

## L1 运行时

L1 访问 CNTP_CTL_EL0（以为是 CNTHP），NV trap 截获 → KVM 存到 CNTHP_CTL_EL2 sys_reg。下次 vcpu_load→activate 搬到硬件。

## __deactivate_traps：搬回 EL2

```
__deactivate_traps (TGE=1):
    val = read_sysreg_el0(SYS_CNTP_CVAL)            // TGE=1 → 读 CNTHP_CVAL_EL2 (?)
    __vcpu_assign_sys_reg(vcpu, CNTHP_CVAL_EL2, val) // 保存
    offset = read_sysreg_s(SYS_CNTPOFF_EL2)
    write_sysreg_el0(val + offset, SYS_CNTP_CVAL)    // 调整 for TGE=1
```

## vcpu_put：收尾

```
timer_save_state(HPTIMER):
    read_sysreg_el0(SYS_CNTP_CTL)  → 存 CNTHP_CTL_EL2
    read_sysreg_el0(SYS_CNTP_CVAL) → 存 CNTHP_CVAL_EL2
    set_cntpoff(0)
```

## 小结

L1 的调度时钟 = **CNTP_CTL_EL0 + CNTPOFF** 硬件，HPTIMER 只是 KVM 给 state 起的名字。__activate_traps 把值从 EL2 寄存器搬到 L1 实际跑的 EL1 寄存器（TGE 切换时），__deactivate_traps 搬回来。trap 截获 L1 的 "CNTHP" 访问存到 CNTHP 槽位。

---

NV VM 的 L2 arch_timer（VTIMER）
================================

L2 的 arch_timer 和非 NV guest 的 VTIMER 逻辑一样，唯一的区别是 offset 多了一层——L1 也设了一个 CNTVOFF_EL2，L0 要把它叠加上去。

## 数据结构：双层 offset

`timer_context_init` 先设 `vm_offset = &voffset`，`kvm_timer_vcpu_init` 写 `voffset = kpt_read()`。随后 `kvm_timer_vcpu_reset` 发现 NV，**覆盖**：

```
offs->vcpu_offset = &ctxt->CNTVOFF_EL2       // → L1 设的值
offs->vm_offset   = &kvm->timer_data.poffset  // → L0 的物理偏移
```

原来 voffset 被抛弃，VTIMER 的 offset 从此读这两个来源。

## vcpu_load：双层叠加写硬件

```
L2 上下文: direct_vtimer = VTIMER

timer_restore_state(VTIMER):
    offset = *CNTVOFF_EL2(L1) + *poffset(L0)
    set_cntvoff(offset)
    write_sysreg_el0(cval, CNTV_CVAL)
    write_sysreg_el0(ctl,  CNTV_CTL)
```

## L2 运行时

```
CNTVCT_EL0(L2) = CNTPCT_EL0(物理) - (L1_CNTVOFF + L0_poffset)
```

两层偏移一次写入硬件，L2 看到的 counter 自动正确。vtimer 一般不 trap（除非 `broken_cntvoff` 或 L1 在 CNTHCTL_EL2 里设了 trap 位），L2 直接读写硬件。

## vcpu_put：读回保存

```
timer_save_state(VTIMER):
    timer_set_ctl(ctx, read_sysreg_el0(SYS_CNTV_CTL))   // → CNTV_CTL_EL0
    cval = read_sysreg_el0(SYS_CNTV_CVAL)
    cval -= offset
    timer_set_cval(ctx, cval)                            // → CNTV_CVAL_EL0
    set_cntvoff(0)
```

## 中断注入

L2 的 CNTV_CVAL 到期→硬件 PPI 27→`kvm_arch_timer_handler`→注入虚拟 27 号中断给 L2。和非 NV 完全一样。

## 和非 NV 的差异

| | 非 NV VM | NV VM 的 L2 |
|---|---|---|
| offset 来源 | voffset（L0 设，= VM 启动时的 kpt_read）| L1_CNTVOFF_EL2 + L0_poffset（两层叠加）|
| vm_offset 指向 | `&timer_data.voffset` | `&timer_data.poffset` |
| vcpu_offset | NULL | `&ctxt->CNTVOFF_EL2` |
| trap | `broken_cntvoff` 时 trap | 同左 + L1 的 CNTHCTL_EL2 trap 位累加 |
| 中断 | 虚拟 PPI 27 | 虚拟 PPI 27（一样）|

核心：L1 的 CNTVOFF_EL2 作为一个额外偏移层，L0 在 vcpu_load 时读出来和 poffset 加在一起写硬件。其余逻辑和非 NV 完全相同。

---

NV timer 代码实现
=================

## 1. vCPU 数据结构

```c
// include/kvm/arm_arch_timer.h
#define vcpu_get_timer(v,t)  (&vcpu_timer(v)->timers[(t)])
#define vcpu_vtimer(v)       (&(v)->arch.timer_cpu.timers[TIMER_VTIMER])   // [1]
#define vcpu_ptimer(v)       (&(v)->arch.timer_cpu.timers[TIMER_PTIMER])   // [0]
#define vcpu_hvtimer(v)      (&(v)->arch.timer_cpu.timers[TIMER_HVTIMER])  // [2]
#define vcpu_hptimer(v)      (&(v)->arch.timer_cpu.timers[TIMER_HPTIMER])  // [3]

static int nr_timers(struct kvm_vcpu *vcpu)
{
    if (!vcpu_has_nv(vcpu))
        return NR_KVM_EL0_TIMERS;   // 2: PTIMER + VTIMER
    return NR_KVM_TIMERS;           // 4: + HVTIMER + HPTIMER
}
```

## 2. get_timer_map：L1 ↔ L2 上下文切换

L1 和 L2 共用同一组硬件寄存器，`get_timer_map` 按 `is_hyp_ctxt` 切换谁占有硬件：

```c
// arch/arm64/kvm/arch_timer.c:154
void get_timer_map(struct kvm_vcpu *vcpu, struct timer_map *map)
{
    if (vcpu_has_nv(vcpu)) {
        if (is_hyp_ctxt(vcpu)) {
            // L1 hypervisor 上下文
            map->direct_vtimer = vcpu_hvtimer(vcpu);  // L1 的 EL2 vtimer → 硬件
            map->direct_ptimer = vcpu_hptimer(vcpu);  // L1 的 EL2 ptimer
            map->emul_vtimer   = vcpu_vtimer(vcpu);   // L1 给 L2 的 → 软件
            map->emul_ptimer   = vcpu_ptimer(vcpu);
        } else {
            // L2 guest 上下文 (is_nested_ctxt = true)
            map->direct_vtimer = vcpu_vtimer(vcpu);   // L2 的 EL1 vtimer → 硬件
            map->direct_ptimer = vcpu_ptimer(vcpu);   // L2 的 EL1 ptimer
            map->emul_vtimer   = vcpu_hvtimer(vcpu);  // L2 视角的 EL2 → 软件
            map->emul_ptimer   = vcpu_hptimer(vcpu);
        }
    } else if (has_vhe()) {
        // 非 NV VHE: 直接映射，无 emulated
        map->direct_vtimer = vcpu_vtimer(vcpu);
        map->direct_ptimer = vcpu_ptimer(vcpu);
        map->emul_vtimer = map->emul_ptimer = NULL;
    } else {
        // 非 NV nVHE: ptimer 是 emulated
        map->direct_vtimer = vcpu_vtimer(vcpu);
        map->direct_ptimer = NULL;
        map->emul_ptimer = vcpu_ptimer(vcpu);
    }
}
```

## 3. vcpu_load 完整流程

```c
void kvm_timer_vcpu_load(struct kvm_vcpu *vcpu)
{
    get_timer_map(vcpu, &map);                       // ① 确定 direct/emulated

    if (vcpu_has_nv(vcpu))
        kvm_timer_vcpu_load_nested_switch(vcpu, &map); // ② NV: 重绑 GIC 中断

    kvm_timer_vcpu_load_gic(map.direct_vtimer);       // ③ 已到期 → 注入中断

    timer_restore_state(map.direct_vtimer);           // ④ 写硬件 CNTV
    if (map.direct_ptimer)
        timer_restore_state(map.direct_ptimer);       // ⑤ 写硬件 CNTP
    if (map.emul_vtimer)
        timer_emulate(map.emul_vtimer);               // ⑥ 软件 hrtimer
    if (map.emul_ptimer)
        timer_emulate(map.emul_ptimer);

    timer_set_traps(vcpu, &map);                      // ⑦ 配置 CNTHCTL_EL2
}
```

### kvm_timer_vcpu_load_nested_switch

```c
static void kvm_timer_vcpu_load_nested_switch(vcpu, map)
{
    hw = kvm_vgic_get_map(vcpu, timer_irq(map->direct_vtimer));
    if (hw < 0) {
        // 新 direct_timer 还没绑定 → 解绑旧的 emul，绑新的 direct
        kvm_vgic_unmap_phys_irq(vcpu, timer_irq(map->emul_vtimer));
        kvm_vgic_unmap_phys_irq(vcpu, timer_irq(map->emul_ptimer));
        kvm_vgic_map_phys_irq(vcpu, direct_vtimer → host_timer_irq,
                              timer_irq(map->direct_vtimer), &arch_timer_irq_ops);
        kvm_vgic_map_phys_irq(vcpu, direct_ptimer → host_timer_irq,
                              timer_irq(map->direct_ptimer), &arch_timer_irq_ops);
    }
}
```

L1↔L2 切换时 `get_timer_map` 产出不同的 direct/emulated 映射。如果新的 direct timer 还没有 GIC 映射（`hw < 0`），说明刚发生了切换，需要把旧 emul 的硬件中断解绑，新 direct 的绑上。

## 4. timer_set_traps：四层判断

```c
// 初始: tvt=tpt=tvc=tpc=tvt02=tpt02=false

// ① ECV + is_hyp_ctxt: L1 hypervisor 在跑
//    NV2 把 EL1 timer 重定向到内存 → ECV 全 trap 补救
if (ECV && is_hyp_ctxt(vcpu)) {
    if (E2H)  tvt02 = tpt02 = true;   // VHE L1: trap _EL02 寄存器
    else      tvt = tpt = true;       // nVHE L1: trap _EL0 寄存器
}

// ② 无 CNTPOFF + offset≠0: 必须 trap 软件修正
if (!has_cntpoff() && timer_get_offset(map->direct_ptimer))
    tpt = tpc = true;

// ③ Lazy ptimer detection: VHE 非 NV, ptimer 还没用过 → trap CTL
if (has_cntpoff() && !vcpu_has_nv(vcpu) && !vcpu_timer(vcpu)->ptimer_used)
    tpt = true;

// ④ is_nested_ctxt: L2 在跑
//    读 L1 的 CNTHCTL_EL2, 把 L1 已设的 trap 累加上去 (不能放掉)
if (is_nested_ctxt(vcpu)) {
    val = __vcpu_sys_reg(vcpu, CNTHCTL_EL2);
    if (!E2H)  val = (val & (EL1PCEN|EL1PCTEN)) << 10; // nVHE→VHE 格式
    tpt |= !(val & EL1PCEN);               // L1 关了 EN → L0 也要 trap
    tpc |= !(val & EL1PCTEN);
    tpt02 |= (val & EL1NVPCT);             // L1 设了 _EL02 trap
    tvt02 |= (val & EL1NVVCT);
}

// 写入硬件:
assign_clear_set_bit(tpt, EL1PCEN<<10, set, clr);    // tpt=true → EL1PCEN=0 → trap
assign_clear_set_bit(tpc, EL1PCTEN<<10, set, clr);
assign_clear_set_bit(tvt, EL1TVT, clr, set);
assign_clear_set_bit(tvc, EL1TVCT, clr, set);
sysreg_clear_set(cnthctl_el2, clr, set);
```

## 5. L1 ↔ L2 切换对比

| | L1 hypervisor 上下文 | L2 guest 上下文 |
|---|---|---|
| 硬件 CNTV | HVTIMER (L1 EL2 vtimer) | VTIMER (L2 arch_timer) |
| 硬件 CNTP | HPTIMER (L1 物理 timer) | PTIMER (L2 物理 timer) |
| 软件 hrtimer | VTIMER | HVTIMER |
| GIC 中断映射 | PPI 直连 (切换时 `kvm_vgic_map_phys_irq`) | PPI 直连 |
| CNTVOFF | poffset | L1_CNTVOFF + poffset |
| CNTPOFF | poffset | poffset |
| trap | ① ECV tpt02/tpt | ④ L1 CNTHCTL 累加 + ②/③ |
