

oe：

include/linux/irqflags.h:           local_irq_save         <-- 外部公共逻辑调用

arch/arm64/include/asm/irqflags.h:  arch_local_irq_save    <-- 注意，这层直接到汇编了。

arch/arm64/include/asm/daifflags.h: local_daif_mask        <-- arm64内部使用

最新NMI代码：

32/45  save_and_disable_exception x0, x1 操作daif和allint

       使用：cpu_switch_to, call_on_irq_stack？

arch/arm64/include/asm/interrupts/common_flags.h

                                  entry.h

                                  masking.h

local_irq_disable地层也是daif，这个时候NMI来了怎么办？新版本的代码这里也是只disable
daif，什么时候NMI也要关？

local_daif_mask没有了，换成了local_exceptions_final_mask
