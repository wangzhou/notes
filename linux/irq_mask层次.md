

oe

include/linux/irqflags.h:           local_irq_save         <-- 外部公共逻辑调用

arch/arm64/include/asm/irqflags.h:  arch_local_irq_save    <-- 注意，这层直接到汇编了。



arch/arm64/include/asm/daifflags.h: local_daif_mask        <-- arm64内部使用

