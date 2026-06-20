ptimer lazy detection 测试
=======================

## 环境

- **物理机**: ARM64 aarch64, QEMU TCG
- **L1**: QEMU TCG, `-cpu max -machine virtualization=true`, 4 vCPU, 6G
- **L1 内核**: `/home/wz/linux_debug_cntpoff/arch/arm64/boot/Image`
- **L2**: QEMU KVM, `-cpu host -machine virt,gic-version=3`, 512M, 4 vCPU, 最小 initramfs
- **L2 内核**: 同 L1（同一份 Image，通过 9p 共享传到 L1）

## 方法

在 L1/L2 共用内核的 `arch/arm64/kvm/arch_timer.c` 末尾插入 initcall：

```c
static int __init test_ptimer_enable_write(void)
{
    u64 val = 1;
    asm volatile("msr cntp_ctl_el0, %0" :: "r"(val));
    return 0;
}
arch_initcall_sync(test_ptimer_enable_write);
```

- L1 boot 时 initcall 在 L1 上下文执行，写 CNTP_CTL_EL0 直通硬件，不 trap
- L2 boot 时 initcall 在 L2（KVM guest）上下文执行，触发 L1 KVM 的 lazy trap

同时在关键路径加了 pr_info 观察 trap 设置和触发。

## 结果

**L1 boot 时**:

```
[0.610019] KVM: ptimer test: about to write CNTP_CTL_EL0 ENABLE=1
[0.610056] KVM: ptimer test: write done
```

L1 的 initcall 执行，写入硬件，不经过 KVM。

**L2 启动后**:

L1 dmesg 中看到：
```
[57.119226] KVM: ptimer lazy: trapping CNTP_CTL (used=0)   ← vcpu_load 设置 trap
...
[482.815496] KVM: ptimer: deactivate CVAL save (nv=0 used=1)  ← trap 触发后 used 变 1
[482.815986] KVM: ptimer: deactivate CVAL save (nv=0 used=1)
```

- `used=0` → L2 尚未使能 ptimer，仅设 trap
- L2 boot，initcall 执行 `MSR CNTP_CTL_EL0, #1` → trap 到 L1 KVM
- KVM trap handler 设置 `ptimer_used = true`，清除 `CNTHCTL_EL1PCEN` trap
- `used=1` → CNTPOFF CVAL save/reload block 开始执行

## 结论

- QEMU TCG 正确模拟了 `CNTHCTL_EL1PCEN` trap
- 首次 `CNTP_CTL_EL0 ENABLE=1` 写入正确触发 lazy detection
- trap 清除后 guest 后续访问直通硬件
- 测试完成后已删除 initcall 和 debug 打印
