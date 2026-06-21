# ARM64 KVM FnB TLBI 本地化设计文档（单 / 双 vCPU）

> 状态：**特性 A（单 vCPU）设计对齐完成、待实现**；**特性 B（双 vCPU）可行性分析完成、go/no-go 待硬件 benchmark、编码暂缓**
> 日期：2026-06-21
> 范围：特性 A 见 §1–§11；特性 B 见 §12
> 代码基线：`linux_tlbid_fnb` 分支（v7.1-rc 附近）

---

## 1. 背景与目标

AI agent 场景会启动**大量单 vCPU / 双 vCPU 小虚机**。ARM64 的 TLB 维护（TLBI）默认通过 inner-shareable DVM **广播**到整个物理机的所有核。当成百上千个小虚机并发时，单个虚机 guest 内部的 TLBI 广播会打扰到所有物理核，导致：

- 单虚机性能随并发虚机数增长而**线性度变差**；
- 物理机 DVM 总线流量随虚机数放大。

**目标**：利用 ARMv9.7-A 的 `FEAT_TLBID` 中的 **FnB（Force non-Broadcast）** 能力，把这类小虚机的 guest TLBI 收敛为"只作用本物理核"，在**不改 guest、不牺牲正确性**的前提下提升多虚机并发的扩展性。

本文档只覆盖**单 vCPU**（特性 A）。

---

## 2. 架构特性：FB 与 FnB

| 位 | 寄存器 | 语义 | KVM 现状 |
|----|--------|------|----------|
| `FB` | `HCR_EL2` | Force Broadcast：把 guest EL1 执行的 local（non-shareable）`TLBI` / `IC IALLU` / `BPIALL` **升级为 IS 广播** | 普通 VM 默认 **FB=1**（保证 vCPU 迁移安全）；定义见 `arch/arm64/include/asm/kvm_arm.h` |
| `FnB` | `HCRX_EL2` | Force non-Broadcast：反向，把 guest 的广播 `TLBI` / `IC IALLU` / `BPIALL` **降为 non-shareable 本核** | **内核无任何 FnB 支持**（`grep -rwin fnb arch/arm64/` 为空），需新增；依赖 `FEAT_HCX` |

关键点：**FB 与 FnB 都只作用于三类操作——`TLBI`、`IC IALLU`、`BPIALL`；不影响 `DC`（数据 cache）与硬件 cache coherency**，故数据一致性不受本设计影响。

---

## 3. 现状分析：单 vCPU 现在并非"天然 local"

一个常见的误解是"单 vCPU（guest possible CPU==1）时 guest 内核会自己用 local TLBI，所以天然收敛"。**从代码看不成立**：

1. **guest 内核恒发 IS 广播变体**。arm64 的 `flush_tlb_mm/range/page/kernel_range`（`arch/arm64/include/asm/tlbflush.h`）**无条件**使用 `aside1is` / `vae1is` / `vale1is` / `vaale1is` 等 inner-shareable 变体，**不看在线/possible CPU 数**。唯一的 local 变体 `local_flush_tlb_all()`（`vmalle1`）只用于启动 / ASID rollover / cpufeature / mte 等本核初始化路径，不在通用数据面。
2. **叠加 KVM 的 `FB=1`**：即便 guest 侥幸发了 local `vae1`，硬件也会因 `HCR_EL2.FB=1` 强制升级为 IS 广播。

**推论**：能否本核化，由 **host 的 FB/FnB** 决定，而**不由 guest 的 CPU 数决定**。因此优化重心在 host/KVM 的 FnB，**guest 零改动**——guest 照发 `vae1is`，硬件经 FnB 就地降级为本核有效。

---

## 4. 设计范围界定

| 对象 | 处理 | 理由 |
|------|------|------|
| **guest stage-1 TLBI**（VA→IPA，guest 自管） | **FnB 降为本核**（本设计靶子） | AI agent guest OS 高频 `munmap`/回收/`fork` 产生，量大、原本条条广播 |
| guest `IC IALLU` / `BPIALL` | 随 FnB 一起降为本核（§6.5） | 与 stage-1 同属"per-核微架构状态" |
| **stage-2 TLBI**（IPA→PA，VMID 维度，host 发起） | **不动，继续广播** | 由 host/hyp 在缺页、迁移、dirty log 等路径经 `__kvm_tlb_flush_vmid*` 维护，不受 guest FnB 影响，也不该动 |
| `DC` / 硬件 coherency | 不涉及 | FB/FnB 不管这些 |

---

## 5. 总体方案（决策表）

| 维度 | 决策 |
|------|------|
| **靶子** | FnB 把 guest stage-1 TLBI（+ IC/BP）从 IS 广播降为本核；stage-2 由 host 广播维护、不动 |
| **使能** | **VMM 显式 opt-in**（VM 级 `KVM_ENABLE_CAP`），KVM 校验当前 vCPU ≤ 1；不靠 KVM 自动推断拓扑 |
| **兜底** | **方案1**：`vcpu_load` 换物理核时，本地失效该 VMID 的 stage-1（复用 `__kvm_flush_cpu_context`，连带 `ic iallu`），无 IPI、只在迁移时付一次 |
| **违约** | opt-in 后 VMM 再创建第 2 个 vCPU → **直接返错** |
| **guest** | **零改动** |

---

## 6. 详细设计

### 6.1 VMM 显式 opt-in 接口

**为什么不能让 KVM 自动"数 vCPU"**：vCPU 由 VMM 按需创建，任一时刻数到 1 不代表将来不再添加；KVM 也不知道 VMM 的拓扑意图。把"此 VM 就是单 vCPU、可安全本地化 TLBI"的承诺**显式交给 VMM** 最安全。

**接口**：新增 VM 级 capability（示意名 `KVM_CAP_ARM_TLBI_LOCAL`），VMM 通过 `KVM_ENABLE_CAP` 开启。语义预留扩展空间（未来 `single` / `paired` 对应特性 A/B）。

**模板 = `KVM_CAP_ARM_MTE`**（`arch/arm64/kvm/arm.c:151-158`）：

```c
/* kvm_vm_ioctl_enable_cap(), arch/arm64/kvm/arm.c:134 */
case KVM_CAP_ARM_TLBI_LOCAL:
        mutex_lock(&kvm->lock);
        if (system_supports_hcx_fnb() && !kvm->created_vcpus) {
                r = 0;
                set_bit(KVM_ARCH_FLAG_TLBI_FNB_ENABLED, &kvm->arch.flags);
                kvm->max_vcpus = 1;      /* 见 §6.2 */
        }
        mutex_unlock(&kvm->lock);
        break;
```

- `!kvm->created_vcpus`：要求在创建任何 vCPU 之前 opt-in（与 MTE / WRITABLE_IMP_ID_REGS 一致，见 `arm.c:153`、`arm.c:181`）。
- flag 存于 `kvm->arch.flags` 位图，新增 `KVM_ARCH_FLAG_TLBI_FNB_ENABLED`。

### 6.2 违约处理：拒绝第 2 个 vCPU

两道防线：

1. **主防线（复用通用层）**：opt-in 时置 `kvm->max_vcpus = 1`。通用 `kvm_vm_ioctl_create_vcpu()`（`virt/kvm/kvm_main.c:4170`）已有 `if (kvm->created_vcpus >= kvm->max_vcpus) return -EINVAL;`，第 2 个 vCPU 自动被拒。
2. **兜底（arch 层显式）**：`kvm_arch_vcpu_precreate()`（`arch/arm64/kvm/arm.c:511`）追加：

```c
int kvm_arch_vcpu_precreate(struct kvm *kvm, unsigned int id)
{
        if (test_bit(KVM_ARCH_FLAG_TLBI_FNB_ENABLED, &kvm->arch.flags) && id >= 1)
                return -EBUSY;          /* opt-in 后拒绝第 2 个 vCPU */
        ...
}
```

### 6.3 FnB 使能路径

现成设施齐全，只需把 FnB bit 加进已有的 `hcrx_el2` 值流：

- **字段**：`vcpu->arch.hcrx_el2`（`arch/arm64/include/asm/kvm_host.h:882`）。
- **置位点**：`vcpu_set_hcrx()`（`arch/arm64/include/asm/kvm_emulate.h:670`），按 feature 追加 bit。在此加：

```c
if (test_bit(KVM_ARCH_FLAG_TLBI_FNB_ENABLED, &vcpu->kvm->arch.flags))
        vcpu->arch.hcrx_el2 |= HCRX_EL2_FnB;
```

- **写入硬件**：`arch/arm64/kvm/hyp/include/hyp/switch.h:347`，进 guest 时 `if (cpus_have_final_cap(ARM64_HAS_HCX)) { hcrx = vcpu->arch.hcrx_el2; ... }` —— 写入路径现成，无需改动。
- **FEAT_HCX 检测**：cap `ARM64_HAS_HCX`（`arch/arm64/tools/cpucaps`、`arch/arm64/kernel/cpufeature.c:2633`，来自 `ID_AA64MMFR1_EL1.HCX`）。
- **⚠️ 待补**：`HCRX_EL2_FnB` 的**确切 bit 位**内核未定义，需查 ARM ARM（DDI0601 的 `HCRX_EL2` 描述）/ 目标硬件 TRM，并在 `arch/arm64/tools/sysreg` 中补 `HCRX_EL2` 的 FnB 字段（生成 `HCRX_EL2_FnB` 宏）。

### 6.4 迁移兜底：方案1（`vcpu_load` 换核刷本核）

**新增状态**：per-vcpu `vcpu->arch.last_ran_pcpu`（`vcpu_create` 初始化为 -1）。

> 为何不复用 `vcpu->cpu`：`vcpu->cpu` 在 `vcpu_load` 里被设为当前核（`arm.c:689`）、在 `vcpu_put` 被设为 -1（`arm.c:751`）。进入 `vcpu_load` 时它已是 -1，拿不到"上次的物理核"，故需独立字段。

**逻辑**：与现有 `last_vcpu_ran` 检查合并（`arch/arm64/kvm/arm.c:683`）：

```c
/* kvm_arch_vcpu_load() */
bool fnb = test_bit(KVM_ARCH_FLAG_TLBI_FNB_ENABLED, &vcpu->kvm->arch.flags);

if (*last_ran != vcpu->vcpu_idx ||            /* 现有：同核换 vCPU */
    (fnb && vcpu->arch.last_ran_pcpu != cpu)) /* 新增：同 vCPU 换核 */
{
        kvm_call_hyp(__kvm_flush_cpu_context, mmu);
        *last_ran = vcpu->vcpu_idx;
        vcpu->arch.last_ran_pcpu = cpu;
}
```

**复用的原语 `__kvm_flush_cpu_context`**（`arch/arm64/kvm/hyp/nvhe/tlb.c:247`、`hyp/vhe/tlb.c:199`），已验证实现为：

```c
enter_vmid_context(mmu, &cxt, ...);   // 切到该 VM 的 VMID
__tlbi(vmalle1);                      // 本地 nsh 失效该 VMID 的 stage-1 EL1&0（不碰 stage-2）
asm volatile("ic iallu");             // 本地失效 icache（IC 免费搭车）
dsb(nsh);                             // non-shareable barrier：本地、无广播、无 IPI
isb();
exit_vmid_context(&cxt);
```

正好满足需求：**只刷 stage-1、连带 IC、本地无广播、按该 VM 的 VMID**。`kvm_call_hyp` 在当前物理核进 EL2 执行 → 全程本地。

**为何在换核时保守全刷该 VMID 的 stage-1**：host 不知道 guest 在别核改了哪些页表条目，故不做精确失效，全清让 guest 重新 fault 建立最新条目；换核后本核 TLB 本就凉，代价可接受。

### 6.5 IC / BP 的处理

FnB 同样把 guest 的 `IC IALLU` / `BPIALL` 降为本核，二者与 stage-1 TLB **同构**（均为 per-核微架构状态的跨核 stale）：

- **IC（指令 cache）**：单 vCPU 运行期本核 IC 失效即正确（只有本核在跑该 guest）；迁移时的跨核 stale 由 §6.4 的 `__kvm_flush_cpu_context` **连带 `ic iallu` 一并覆盖**（icache 按 PA、全清最稳），**功能正确性有保证**。
- **BP（分支预测）**：**不影响功能正确性**（BP 仅性能提示，预测错只是重取指，绝不会执行错误指令）。唯一潜在影响是 guest 拿 `BPIALL` 做的安全缓解在迁移后短暂减弱；现代实现 `BPIALL` 多被 CSV2/RCTX 类更精确机制取代甚至为 NOP，且 host 在 vCPU 切换本有独立 BP mitigation。若要严格覆盖，可在 §6.4 的换核兜底里补一条本核 BP 失效，成本极小。

---

## 7. 正确性论证

### 7.1 迁移 stale 问题（不做兜底会怎样）

单 vCPU、VMID=V 的 vCPU-X：

| 时刻 | 事件 |
|------|------|
| t0 | X 在物理核 A，建立 stage-1 TLB 条目 |
| t1 | X 迁到核 B |
| t2 | X 在 B 上 `munmap`，发 `TLBI VAE1`（FnB 降级为本核）→ **只清 B，A 上条目 stale** |
| t3 | X 迁回 A，命中 A 上 stale 条目（VMID/ASID 匹配）→ 读到已 unmap 的旧翻译 → **正确性 bug** |

FB=1 广播世界里 t2 会广播回 A 自愈；FnB 本核化后不再自愈，故必须兜底。

### 7.2 方案1 的不变量与证明

**不变量**：*X 开始在任何物理核 C 上运行前，C 上不存在 X 的 stale stage-1 条目。*

**证明**（设 X 上次运行的核为 P）：
- **C == P（未换核）**：X 是该 VM 唯一 vCPU，自上次在 C 运行以来没在别处改过页表，C 上条目都是 X 自己最近维护的、一致 → 不需刷（不变量保持）。
- **C ≠ P（迁移）**：C 上可能残留 X 更早在 C 建立、之后在别处 `unmap` 且只本地失效了别处的 stale 条目 → 方案1 在 `vcpu_load(C)` 处 `__kvm_flush_cpu_context` 清 C → 不变量恢复。

有了该不变量，§7.1 的 t3 被 `vcpu_load(A)`（A ≠ 上次的 B）触发清理，bug 消除。∎

### 7.3 边界

| 情形 | `last_ran_pcpu` vs `cpu` | 动作 |
|------|--------------------------|------|
| 首次上核 | -1 ≠ cpu | 清一次（本核本无该 VMID 条目，多余但无害），记录 |
| `put`→`load` 回同核 | == | **不清**，TLB 复用（省开销关键） |
| 迁移到新核 | ≠ | 清新核 stale，记录 |
| 中间被别的 VM 占用该核 | VMID 隔离，无害 | `vmalle1` 只清本 VMID |

### 7.4 闭环

- **进 guest 前**：换核刷 → 本核只剩 X 的最新 stage-1（无 stale）。
- **guest 运行期**：FnB 让 X 的 stage-1 TLBI 只作用本核。
- 合起来：**本核 stage-1 始终 = X 的最新视图，且失效不外广播** → 正确性闭环。

与内核既有保证一致：`arm.c:675-681` 注释已声明"TLBs and I-cache are private to each vcpu"、"over-invalidation doesn't affect correctness"。方案1 是把该 private 保证从"per-(mmu,pcpu) 换 vCPU"维度扩展到"per-vcpu 换核"维度。

---

## 8. 为什么 `vcpu_load` 换核刷优于 `vcpu_put` 离核刷

两者都正确，纯开销取舍：

| | `vcpu_put` 离核刷（方案 a） | `vcpu_load` 换核刷（方案1，采用） |
|---|---|---|
| 清的是什么 | 刚跑完、**仍有效**的条目（还没去别处改页表）——清掉好数据 | **可能已 stale** 的旧条目 |
| 触发频率 | 每次让核（**极高频**，多数还回同核 → 过刷 + 破坏 TLB 局部性） | 仅真迁移（**低频**） |
| IPI | 无 | 无 |
| 实现 | 需在 `vcpu_put` 另起逻辑 | **复用现有 `vcpu_load` 里 `last_vcpu_ran` 路径**，同源 |
| 缺点 | 过刷有效 TLB | 迁走后源核残留死条目至自然淘汰（正确性无碍） |

结论：稳态下 vCPU 倾向粘同核，"过刷有效 TLB"占主导，方案1 更省且改动更小。

---

## 9. 关键代码落点

| 功能 | 文件:行 | 说明 |
|------|---------|------|
| `hcrx_el2` 字段 | `arch/arm64/include/asm/kvm_host.h:882` | 每 vcpu 的 HCRX_EL2 值 |
| FnB 置位 | `arch/arm64/include/asm/kvm_emulate.h:670` `vcpu_set_hcrx()` | 按 feature 追加 bit |
| HCRX 写硬件 | `arch/arm64/kvm/hyp/include/hyp/switch.h:347` | 进 guest 时写入，现成 |
| HCX cap | `arch/arm64/kernel/cpufeature.c:2633` `ARM64_HAS_HCX` | FEAT_HCX 检测 |
| opt-in CAP | `arch/arm64/kvm/arm.c:134` `kvm_vm_ioctl_enable_cap()` | 新增 case，模板见 `:151` MTE |
| 拒绝第 2 vCPU | `arch/arm64/kvm/arm.c:511` `kvm_arch_vcpu_precreate()` + `virt/kvm/kvm_main.c:4170` | 两道防线 |
| 迁移兜底挂点 | `arch/arm64/kvm/arm.c:683` `kvm_arch_vcpu_load()` | 合并 last_vcpu_ran 判断 |
| 本地失效原语 | `arch/arm64/kvm/hyp/nvhe/tlb.c:247`、`hyp/vhe/tlb.c:199` `__kvm_flush_cpu_context()` | `vmalle1`+`ic iallu`+`dsb nsh` |
| `last_vcpu_ran`（对偶维度参考） | `arch/arm64/include/asm/kvm_host.h:180`、`arm.c:683` | 现有"同核换 vCPU"机制 |
| `last_ran_pcpu`（新增） | `struct kvm_vcpu_arch` | per-vcpu "上次物理核" |

---

## 10. 风险与待确认项

1. **`HCRX_EL2_FnB` 的确切 bit 位**：内核未定义，需查 ARM ARM（DDI0601）/ 目标硬件 TRM 后在 `arch/arm64/tools/sysreg` 补齐。（唯一还依赖外部 spec 的点）
2. **`enter_vmid_context` 在 `vcpu_load` 上下文的开销**：`__kvm_flush_cpu_context` 会切 VMID 上下文再失效，现有 `last_vcpu_ran` 已在同一位置以同样方式调用，故正确性/上下文安全有先例；但换核时多一次调用的开销需 benchmark。
3. **pKVM**：`is_protected_kvm_enabled()` 路径 `vcpu_load` 走 `nommu` 分支（`arm.c:655/688`），FnB 在 pKVM 下的使能与兜底需单独评估（本文档默认非 pKVM）。
4. **收益量化**：需实测（见 §11）。

---

## 11. 验证计划

**功能正确性**：
- 单 vCPU VM + 高频迁移（`taskset` 反复改 affinity / 制造抢占）+ TLBI 密集负载（大量 `munmap`/`mprotect`/`fork`），长时间跑内存一致性校验，确认无 stale。
- 对照：FnB 关（现状）与 FnB 开的行为一致性。

**性能/扩展性**：
- N 个单 vCPU VM 并发跑 TLBI 密集负载，测**单 VM 性能随 N 的 scaling 曲线**：FB=1（现状）vs FnB。
- 测 host 侧 DVM 广播流量随 N 的变化（应显著下降）。

---

## 12. 特性 B（双 vCPU）可行性分析

> 状态：**可行性分析完成，go/no-go 待硬件 benchmark，编码暂缓**。与特性 A（§1–§11，设计定稿）不同，本节是评估性质。

### 12.1 定位与正确性机制

双 vCPU 若两 vCPU 分处不同物理核，本核化 TLBI 覆盖不到对方核 → stale。解法：**FnB（本物理核）+ CnP**——把两 vCPU 绑到**同一物理核的两个 SMT 兄弟逻辑核**，二者物理共享 TLB，CnP（`TTBR.CnP=1` + 同 ASID/VMID + 同页表）令 TLB 条目为 common，于是一个 vCPU 的 non-broadcast TLBI 经共享 TLB **覆盖到兄弟核**。

- **隐含硬件前提**：目标核有 **SMT**（一物理核两 thread）。无 SMT 则此方案不成立。
- **待落 spec（正确性基石）**：non-broadcast + CnP "覆盖兄弟逻辑核"的确切 ARM ARM / 硬件 TRM 语义，须对手册坐实。
- FnB 使能、迁移兜底刷 stage-1 等**复用特性 A** 的机制（§6.3、§6.4），单位从"单 vCPU"变"绑定对"。

### 12.2 core scheduling 查证：隔离 ≠ gang（不采用）

曾设想用 Linux core scheduling 保证两 vCPU 同物理核。查证结论（`Documentation/admin-guide/hw-vuln/core-scheduling.rst`）：

- core scheduling 是**隔离**语义——保证"不同 cookie 的任务**永不**同时共享一个 core"（`:37`）；**不保证**"相同 cookie 的两任务被拉到同一 core、同时运行"（各 sibling runqueue 独立选任务，同 cookie 没 runnable 就选 idle，`:105–110`）。两 vCPU 完全可能被负载均衡分到不同物理核。
- 内核主线**无 gang scheduling 实现**：文档仅把 "Gang scheduling … vCPUs of a VM" 列为 "**could be realized**" 的设想（`:224–226`），`kernel/sched/` 无对应逻辑。
- 附加代价：即便强行同 core，forced-idle（`:119–128`）会在只有 1 个 vCPU runnable 时**强制 idle 兄弟核**、不能给别的 VM 用——与"提升小虚机密度"矛盾。

### 12.3 认知修正：要的是 affinity 空间绑定，不是 gang

CnP 覆盖兄弟核靠的是"两 SMT 兄弟核**物理共享 TLB**"这一**空间**事实，**不依赖两 vCPU 同时运行**。因此只需 **CPU affinity 硬绑定**两 vCPU 到同一物理核的两个逻辑核（`sched_setaffinity`），CnP 即成立——**不需要 core scheduling，也就没有 forced-idle 的亏**。

（`FEAT_TLBID` domain 定向广播曾作为"不要求同核"的替代路线，**已否决，不采用**。）

### 12.4 使能与绑定的架构难题（"分裂"问题）

特性 B 的正确性契约"两 vCPU 绑同物理核 + 成对迁移"，**KVM 无法像特性 A 那样硬性强制**——特性 A 能用 `precreate` 拒绝第 2 个 vCPU，特性 B 却不能阻止 VMM 改 affinity。于是：

- **KVM 主动校验 affinity**：控制权在 VMM、KVM 却回头盯 VMM，职责**分裂**。
- **KVM 纯信任 opt-in**：又因"可迁移"漏——成对迁移非原子，中途两 vCPU 必然短暂分处两核，那一瞬 FnB 就是错的。

**采用方案：VMM 显式驱动 + 迁移握手**（KVM 不做 affinity 判断，只听令）：

```
VMM 迁移这对 vCPU:
  1) ioctl(关 FnB) → KVM 关 FnB + 广播失效该 VMID，之后走广播（安全覆盖迁移窗口）
  2) sched_setaffinity 两 vCPU 到新的一对 SMT 兄弟核
  3) ioctl(开 FnB) → KVM 重开 FnB
```

- 控制、绑定、迁移、通报**全在 VMM**；KVM 只提供"开/关 FnB + 配套失效"的机制，职责统一。
- 诚实说：KVM 在"开 FnB"时仍**信任** VMM 真绑好了（不校验）。特性 B 正确性本质是 **"信任 VMM 声明" vs "KVM 校验"** 二选一；取前者 + 迁移握手，代价是 VMM 迁移路径要插这两个 ioctl。

### 12.5 性能权衡（决定 go/no-go）

绑同物理核 = 两 vCPU 共享一物理核的两个 SMT thread，相比各占独立物理核：

| 对比 | 总吞吐 | 每 vCPU 相对独占 |
|------|--------|------------------|
| 各占独立物理核 | 2.0×（基准） | 100% |
| 绑同物理核两 thread | 约 **1.1~1.3×** | 约 **55~65%** |

即绑同核相比各占独立核，**总吞吐通常掉 35~45%**。强依赖：

- **workload**：compute-bound 争抢执行端口 → SMT 收益趋 0，单 vCPU 逼近 ~50-55%；memory/IO-bound 多 stall → SMT 收益大，单 vCPU ~70-80%。
- **基线放置**：低密度独占 → 实打实损失；**高密度超卖**（vCPU 本就共享物理核）→ 绑同核几无额外损失、FnB 省的广播纯赚。

（数字为业界范围，ARM SMT 实现少且因微架构而异，须在目标硬件实测。）

### 12.6 迁移策略

采用**成对迁移**（用户需求）：VMM 把两 vCPU 作为一对迁到另一对 SMT 兄弟核，经 §12.4 的握手关/开 FnB，迁移瞬间兜底刷源物理核该 VMID 的 stage-1（复用 §6.4 方案1 思路）。不做静态 pin。

### 12.7 结论与建议

特性 B 相比特性 A 累积了明显更高的复杂度与代价：**契约 KVM 不可强制**（需 VMM 握手）+ **SMT 压缩损失 35~45%** + 依赖 **SMT 硬件** + **non-broadcast/CnP 覆盖语义待坐实**。

**建议 go/no-go 基于硬件数据，编码暂缓**。先量两个数：
1. 目标 workload 绑同核 vs 独立核的**实际 SMT 损失**；
2. FnB 在高密度下**省下的 TLBI 广播收益**。

**净收益 = (2) − (1) 为正才值得投入。** AI agent 小虚机若是"高密度超卖 + memory/IO 等待型"，大概率为正；"低密度独占 + compute 满载"则大概率为负。

---

## 附：术语

- **DVM**：Distributed Virtual Memory，ARM 的 TLB/cache 维护广播机制。
- **stage-1 / stage-2**：guest VA→IPA（guest 自管）/ IPA→PA（host/KVM 管，VMID 维度）。
- **FB / FnB**：Force Broadcast / Force non-Broadcast。
- **CnP**：Common not Private（FEAT_TTCNP），多 PE 共享 TLB 条目。
- **FEAT_TLBID**：Armv9.7-A TLBI Domains，含 FnB 能力。
