ARM64汇编学习-以qm.c反汇编为分析材料

-v0.1 2020.2.20 Sherlock init
-v0.2 2020.2.23 Sherlock 分析到函数hisi_qm_debug_init


简介：本文是linux/drivers/crypto/hisilicon/qm.c的反汇编，我们分析反汇编的逐条
      指令，借此学习ARM64汇编指令。基于commit：b3a60822233中的qm.c

0000000000000000 <__raw_readl>:
       0:	b9400000 	ldr	w0, [x0]

__raw_readl的入参放在x0，这个入参是一个指针，所以这里load对应地址上的值到w0寄存器，
返回值就是存放到w0寄存器里。

       4:	d65f03c0 	ret

0000000000000008 <qm_db_v1>:
       8:	12003c21 	and	w1, w1, #0xffff
      10:	12003c63 	and	w3, w3, #0xffff
      14:	12001c84 	and	w4, w4, #0xff

几个入放在w1,w2,w3,w4寄存器里，c语言里定义的入参是u16和u8不满32bit，这里用and
把对应bit mask出来，其他一律是0。

      18:	d50332bf 	dmb	oshst

为啥有一个barrier?

      1c:	d3503c84 	lsl	x4, x4, #48

lsl逻辑左移指令: x4内容左移48bit, 这里和(u64)priority << QM_DB_PRIORITY_SHIFT_V1
是对应的。

      20:	92403c21 	and	x1, x1, #0xffff

似乎没有作用，因为之前已经mask过了？

      24:	f9400c00 	ldr	x0, [x0, #24]

读取qm地址里的io_base值到x0。

      28:	d3701c42 	ubfiz	x2, x2, #16, #8

unsigned bit field insert zero, bit运算的指令, 貌似是把最低8bit的搬到16bit起始的
偏移处

      2c:	aa038083 	orr	x3, x4, x3, lsl #32

orr是或指令。x3, lsl, #32 可以独立的理解为x3的内容左移32bit。整体是，x3左移32bit
或上x4, 得到的值给x3。

      30:	aa010042 	orr	x2, x2, x1
      34:	aa020063 	orr	x3, x3, x2

这几步或出doorbell的值。

      38:	910d0000 	add	x0, x0, #0x340

io_base + dbase的到要写的地址，先保存在x0里。注意x0之前是第一个入参, 就是qm的地址。

      3c:	f9000003 	str	x3, [x0]

把doorbell的值写入对应的地址。

      40:	d65f03c0 	ret

函数返回。

      44:	d503201f 	nop

为啥要加一个nop指令？难道是为了ftrace之后做替换？

0000000000000048 <qm_db_v2>:
      48:	12001c42 	and	w2, w2, #0xff
      4c:	d2840006 	mov	x6, #0x2000                	// #8192
      50:	7100085f 	cmp	w2, #0x2

cmp是比较指令, 实际相当于有符号减法，然后设置条件标记(condition flags)。

      54:	d2820005 	mov	x5, #0x1000                	// #4096

这里的mov和上面的mov以及cmp完成一个if-else的操作给dbase赋值。

      58:	12003c21 	and	w1, w1, #0xffff
      5c:	12003c63 	and	w3, w3, #0xffff
      60:	12001c84 	and	w4, w4, #0xff
      64:	9a8630a5 	csel	x5, x5, x6, cc  // cc = lo, ul, last

csel是一个条件指令，根据最后位置处的flag, 决定是否x5 = x6。(to do: ...)

      68:	d50332bf 	dmb	oshst
      6c:	d3741c42 	ubfiz	x2, x2, #12, #8
      70:	92403c21 	and	x1, x1, #0xffff
      74:	f9400c00 	ldr	x0, [x0, #24]
      78:	aa04c044 	orr	x4, x2, x4, lsl #48
      7c:	aa038023 	orr	x3, x1, x3, lsl #32
      80:	aa030083 	orr	x3, x4, x3
      84:	8b050000 	add	x0, x0, x5
      88:	f9000003 	str	x3, [x0]

这一段同qm_db_v1中的分析。

      8c:	d65f03c0 	ret

0000000000000090 <qm_get_irq_num_v1>:
      90:	52800020 	mov	w0, #0x1                   	// #1
      94:	d65f03c0 	ret

像这种简单函数，一个mov就ok了。

0000000000000098 <qm_get_irq_num_v2>:
      98:	b9400402 	ldr	w2, [x0, #4]
      9c:	52800081 	mov	w1, #0x4                   	// #4
      a0:	52800040 	mov	w0, #0x2                   	// #2
      a4:	7100005f 	cmp	w2, #0x0
      a8:	1a800020 	csel	w0, w1, w0, eq  // eq = none

和上面一样，用mov + cmp + csel来实现if-else。cmp, w2如果等于0，Z = 1，csel中
如果 Z = 1，w0 = w1。

      ac:	d65f03c0 	ret

00000000000000b0 <qm_hw_error_init_v1>:
      b0:	d50332bf 	dmb	oshst

为啥要有一个barrier?

      b4:	f9400c00 	ldr	x0, [x0, #24]
      b8:	5283ffe1 	mov	w1, #0x1fff                	// #8191
      bc:	91440000 	add	x0, x0, #0x100, lsl #12
      c0:	91001000 	add	x0, x0, #0x4

这两条add指令完成 io_base + QM_ABNORMAL_INT_MASK (MASK值是0x100004)。第一条add
是add和lsl的结合，lsl是logic shift left，整体效果是：x0 = x0 + 0x100 << 12。
注意，这里把0x100004放在两条指令里拼在一起。

      c4:	b9000001 	str	w1, [x0]
      c8:	d65f03c0 	ret
      cc:	d503201f 	nop

00000000000000d0 <hisi_qm_get_free_qp_num>:
      d0:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
      d4:	910003fd 	mov	x29, sp

注意出现了之前没有的堆栈相关的操作, 是因为这个函数里有子函数调用。
stp指令store两个寄存器到连续的地址，注意这里地址计算的方式sp = sp - 48，先更新
sp, 然后再取sp地址的内存，把x29，x30写入sp和sp + 8的地址。x29是FP，也就会栈帧寄存器，
x30是LR，就是函数返回地址，其他函数在调用hisi_qm_get_free_qp_num的时候把下一条
指令的地址存在LR里。ARM64上bl会把下一条指令的地址存在LR。

这里的两条指令和函数结尾的ldp x29, x30, [sp], #48 是函数调用的时候保存x29，x30的
常用方式。要立即这里的逻辑，需要理解ARM64的函数调用的约定，这个是ARM64 ABI的一
部分，ARM有专门的文档描述。

简单的讲，这里的逻辑是:
```
                   |         |
	sp, x29 -> |         |   高地址
                   |         |
                   |         |
                   | x30 LR  |
        sp, x29 -> | x29 FR  |
	           +---------+   低地址
```
在进入这个函数的时候, sp和x29都指向调用这个函数的函数的栈定，栈向下生长，所以当
前的函数一进来首先把sp向下移动48，然后保存x29，x30到这个函数的栈里。注意这里有
几点，因为这个函数里又要调用其他的函数，所以这里为这个函数建了栈，像上面的简单
函数里，只要寄存器辅助就可以完成功能的就不需要使用栈；这里为什么要把FR和LR保存
在栈里，因为FR和LR的值马上可能要被重写，而这这个函数退出是又必须使用FR，LR当前
保存的信息, 一开始进入当前函数的时候，FR的值是高地址处x29的指向，LR保存的是
hisi_qm_get_free_qp_num的返回地址，在hisi_qm_get_free_qp_num FR会新指向新的栈
顶地址，就是mov x29, sp这条指令搞得, LR的值可能会在当前函数里有子函数调用的时候
被改掉，所以函数一开始就要把栈向下生长，然后是x29, x30入栈。

      d8:	a90153f3 	stp	x19, x20, [sp, #16]

下面要用x19，x20，所以先把他们入栈保存。

      dc:	aa0003f4 	mov	x20, x0

x0的值转存到x20，因为等下调用_raw_read_lock的时候要用x0给被调用的函数传参数。
read_lock是一个宏，所以这里看不到read_lock。

      e0:	f90013f5 	str	x21, [sp, #32]
      e4:	9102a015 	add	x21, x0, #0xa8

x21存放的已经是qps_lock的地址了。

      e8:	aa1503e0 	mov	x0, x21

利用x0传_raw_read_lock的参数。

      ec:	94000000 	bl	0 <_raw_read_lock>
      f0:	29450693 	ldp	w19, w1, [x20, #40]

x20存的是qm指针，所以这里取出qp_num和qp_in_used。

      f4:	aa1503e0 	mov	x0, x21

准备下次_raw_read_unlock的入参，这里应该不用在给x0赋值了？莫非_raw_read_lock
可能会改变x0的值？

      f8:	4b010273 	sub	w19, w19, w1
      fc:	94000000 	bl	0 <_raw_read_unlock>
     100:	f94013f5 	ldr	x21, [sp, #32]

把之前存在栈中的x21写回寄存器。

     104:	2a1303e0 	mov	w0, w19

为整个函数准备返回值，写到x0中。

     108:	a94153f3 	ldp	x19, x20, [sp, #16]

把之前存在栈中的x19, x20写回寄存器。

     10c:	a8c37bfd 	ldp	x29, x30, [sp], #48

把x29, x30的值出栈, 注意这里是先会sp处的值出栈，然后sp = sp + 48销毁栈。这时，
x29指向高地址的x29位置，x30已经是hisi_qm_get_free_qp_num的返回地址了。

     110:	d65f03c0 	ret
     114:	d503201f 	nop

0000000000000118 <hisi_qm_get_hw_version>:
     118:	39412000 	ldrb	w0, [x0, #72]

load系列的指令，load一个byte。还有ldrh, ldrsb, ldrsh等

     11c:	51008001 	sub	w1, w0, #0x20
     120:	7100083f 	cmp	w1, #0x2
     124:	5a9f3000 	csinv	w0, w0, wzr, cc  // cc = lo, ul, last

csinv也是一个条件指令, wzr不知道是什么?

     128:	d65f03c0 	ret
     12c:	d503201f 	nop

0000000000000130 <hisi_qm_debug_init>:
     130:	a9bb7bfd 	stp	x29, x30, [sp, #-80]!
     134:	910003fd 	mov	x29, sp
     138:	a90153f3 	stp	x19, x20, [sp, #16]
     13c:	aa0003f3 	mov	x19, x0
     140:	90000000 	adrp	x0, 0 <__raw_readl>

adrp是取出当前pc + label << 12, 然后把低12bit清0，赋值给x0。这里是用x0几下了
当前pc的值。

     144:	91000000 	add	x0, x0, #0x0
     148:	90000014 	adrp	x20, 0 <__raw_readl>
     14c:	f9407a61 	ldr	x1, [x19, #240]
     150:	94000000 	bl	0 <debugfs_create_dir>
     154:	aa0003e2 	mov	x2, x0

x0里有debugfs_create_dir的返回值, 是qm_d的地址，赋值给x2。

     158:	b9400660 	ldr	w0, [x19, #4]
     15c:	f9007e62 	str	x2, [x19, #248]

可以使用objdump --debugging查看一个结构体里对应域段的偏移。可以看到qm的248偏移
处是debug里的qm_d
```
27380  <2><d923>：缩写编号：1 (DW_TAG_member)
27381     <d924>   DW_AT_name        : (indirect string, offset: 0x6ad0): debug
27382     <d928>   DW_AT_decl_file   : 182
27383     <d929>   DW_AT_decl_line   : 160
27384     <d92a>   DW_AT_type        : <0xd71e>
27385     <d92e>   DW_AT_data_member_location: 232

27139  <2><d742>：缩写编号：1 (DW_TAG_member)
27140     <d743>   DW_AT_name        : (indirect string, offset: 0x93a5): qm_d
27141     <d747>   DW_AT_decl_file   : 182
27142     <d748>   DW_AT_decl_line   : 110
27143     <d749>   DW_AT_type        : <0x2999>
27144     <d74d>   DW_AT_data_member_location: 16
```

     160:	35000560 	cbnz	w0, 20c <hisi_qm_debug_init+0xdc>

cbnz是一个比较跳转指令，compare branch non zero, 如果w0非0，那么跳转到
hisi_qm_debug_init+0xdc的地址执行。这里的20c就是hisi_qm_debug_init+0xdc的地址。
这里是if语句没有进去，直接跳到了后面的debugfs_create_file去了。

     164:	a9025bb5 	stp	x21, x22, [x29, #32]
     168:	90000014 	adrp	x20, 0 <__raw_readl>
     16c:	f90023b9 	str	x25, [x29, #64]

x21, x22，x25入栈。

     170:	91040275 	add	x21, x19, #0x100

qm(x19) 0x100偏移是，qm->debug->files。注意这个对应的c代码已经在
qm_create_debugfs_file里了。

     174:	91000299 	add	x25, x20, #0x0
     178:	aa1503e3 	mov	x3, x21

x3是file。

     17c:	aa1903e4 	mov	x4, x25

x4是qm_debug_fops的指针。奇怪，为啥这里用adrp就可以取到qm_debug_fops的地址了？

     180:	a90363b7 	stp	x23, x24, [x29, #48]
     184:	52803001 	mov	w1, #0x180                 	// #384
     188:	90000000 	adrp	x0, 0 <__raw_readl>

这里太神奇，adrp又计算出了qm_debug_file_name的基地址。

     18c:	91000000 	add	x0, x0, #0x0
     190:	94000000 	bl	0 <debugfs_create_file>

注意这里没有了qm_create_debugfs_file, 估计是把这个函数里的内容直接展开了。

     194:	b901027f 	str	wzr, [x19, #256]

xzr/wzr是0寄存器。这里是写一个0到对应的内存。

     198:	90000018 	adrp	x24, 0 <__raw_readl>
     19c:	90000017 	adrp	x23, 0 <__raw_readl>
     1a0:	91000318 	add	x24, x24, #0x0
     1a4:	910002f7 	add	x23, x23, #0x0
     1a8:	aa1803e2 	mov	x2, x24
     1ac:	aa1703e1 	mov	x1, x23
     1b0:	91042260 	add	x0, x19, #0x108
     1b4:	94000000 	bl	0 <__mutex_init>
     1b8:	9103a276 	add	x22, x19, #0xe8
     1bc:	f9407e62 	ldr	x2, [x19, #248]
     1c0:	9104c275 	add	x21, x19, #0x130
     1c4:	f9009676 	str	x22, [x19, #296]
     1c8:	aa1903e4 	mov	x4, x25
     1cc:	aa1503e3 	mov	x3, x21
     1d0:	52803001 	mov	w1, #0x180                 	// #384
     1d4:	90000000 	adrp	x0, 0 <__raw_readl>
     1d8:	91000000 	add	x0, x0, #0x0
     1dc:	94000000 	bl	0 <debugfs_create_file>

return 0上面的debugfs_create_file

     1e0:	52800020 	mov	w0, #0x1                   	// #1
     1e4:	b9013260 	str	w0, [x19, #304]
     1e8:	aa1803e2 	mov	x2, x24
     1ec:	aa1703e1 	mov	x1, x23
     1f0:	9104e260 	add	x0, x19, #0x138
     1f4:	94000000 	bl	0 <__mutex_init>
     1f8:	f900ae76 	str	x22, [x19, #344]
     1fc:	f9407e62 	ldr	x2, [x19, #248]
     200:	a9425bb5 	ldp	x21, x22, [x29, #32]
     204:	a94363b7 	ldp	x23, x24, [x29, #48]
     208:	f94023b9 	ldr	x25, [x29, #64]
     20c:	91000284 	add	x4, x20, #0x0
     210:	aa1303e3 	mov	x3, x19
     214:	91040084 	add	x4, x4, #0x100
     218:	52802481 	mov	w1, #0x124                 	// #292
     21c:	90000000 	adrp	x0, 0 <__raw_readl>
     220:	91000000 	add	x0, x0, #0x0

20c~220是为下面debugfs_create_file准备入参：

     224:	94000000 	bl	0 <debugfs_create_file>
     228:	52800000 	mov	w0, #0x0                   	// #0
     22c:	a94153f3 	ldp	x19, x20, [sp, #16]
     230:	a8c57bfd 	ldp	x29, x30, [sp], #80
     234:	d65f03c0 	ret

注意这里尽然没有failed_to_create段的debugfs_remove_recursive这个函数，这是因为
这个函数里唯一跳到这个label的qm_create_debugfs_file是没有错误返回的，所以编译器
就没有把错误分支编译到二进制里。

0000000000000238 <qm_regs_open>:
     238:	a9bf7bfd 	stp	x29, x30, [sp, #-16]!
     23c:	910003fd 	mov	x29, sp
     240:	f9411c02 	ldr	x2, [x0, #568]
     244:	aa0103e0 	mov	x0, x1
     248:	90000001 	adrp	x1, 0 <__raw_readl>
     24c:	91000021 	add	x1, x1, #0x0
     250:	94000000 	bl	0 <single_open>
     254:	a8c17bfd 	ldp	x29, x30, [sp], #16
     258:	d65f03c0 	ret
     25c:	d503201f 	nop

0000000000000260 <hisi_qm_get_vft>:
     260:	f100003f 	cmp	x1, #0x0
     264:	fa401844 	ccmp	x2, #0x0, #0x4, ne  // ne = any

ccmp

     268:	54000120 	b.eq	28c <hisi_qm_get_vft+0x2c>  // b.none

b.eq

     26c:	a9bf7bfd 	stp	x29, x30, [sp, #-16]!
     270:	910003fd 	mov	x29, sp
     274:	f9407004 	ldr	x4, [x0, #224]
     278:	f9400084 	ldr	x4, [x4]
     27c:	b40000c4 	cbz	x4, 294 <hisi_qm_get_vft+0x34>

cbz

     280:	d63f0080 	blr	x4
     284:	a8c17bfd 	ldp	x29, x30, [sp], #16
     288:	d65f03c0 	ret
     28c:	128002a0 	mov	w0, #0xffffffea            	// #-22
     290:	d65f03c0 	ret
     294:	f9400800 	ldr	x0, [x0, #16]
     298:	90000001 	adrp	x1, 0 <__raw_readl>
     29c:	91000021 	add	x1, x1, #0x0
     2a0:	9102c000 	add	x0, x0, #0xb0
     2a4:	94000000 	bl	0 <_dev_err>
     2a8:	128002a0 	mov	w0, #0xffffffea            	// #-22
     2ac:	17fffff6 	b	284 <hisi_qm_get_vft+0x24>

00000000000002b0 <hisi_qm_hw_error_init>:
     2b0:	a9bf7bfd 	stp	x29, x30, [sp, #-16]!
     2b4:	910003fd 	mov	x29, sp
     2b8:	f9407005 	ldr	x5, [x0, #224]
     2bc:	f94010a5 	ldr	x5, [x5, #32]
     2c0:	b4000085 	cbz	x5, 2d0 <hisi_qm_hw_error_init+0x20>
     2c4:	d63f00a0 	blr	x5
     2c8:	a8c17bfd 	ldp	x29, x30, [sp], #16
     2cc:	d65f03c0 	ret
     2d0:	f9400800 	ldr	x0, [x0, #16]
     2d4:	90000001 	adrp	x1, 0 <__raw_readl>
     2d8:	91000021 	add	x1, x1, #0x0
     2dc:	9102c000 	add	x0, x0, #0xb0
     2e0:	94000000 	bl	0 <_dev_err>
     2e4:	17fffff9 	b	2c8 <hisi_qm_hw_error_init+0x18>

b和bl的区别

00000000000002e8 <hisi_qm_hw_error_handle>:
     2e8:	a9bf7bfd 	stp	x29, x30, [sp, #-16]!
     2ec:	910003fd 	mov	x29, sp
     2f0:	f9407001 	ldr	x1, [x0, #224]
     2f4:	f9401421 	ldr	x1, [x1, #40]
     2f8:	b4000081 	cbz	x1, 308 <hisi_qm_hw_error_handle+0x20>
     2fc:	d63f0020 	blr	x1
     300:	a8c17bfd 	ldp	x29, x30, [sp], #16
     304:	d65f03c0 	ret
     308:	f9400800 	ldr	x0, [x0, #16]
     30c:	90000001 	adrp	x1, 0 <__raw_readl>
     310:	91000021 	add	x1, x1, #0x0
     314:	9102c000 	add	x0, x0, #0xb0
     318:	94000000 	bl	0 <_dev_err>
     31c:	52800020 	mov	w0, #0x1                   	// #1
     320:	17fffff8 	b	300 <hisi_qm_hw_error_handle+0x18>
     324:	d503201f 	nop

0000000000000328 <hisi_qm_init>:
     328:	a9bc7bfd 	stp	x29, x30, [sp, #-64]!
     32c:	910003fd 	mov	x29, sp
     330:	a901d7f4 	stp	x20, x21, [sp, #24]
     334:	b9400001 	ldr	w1, [x0]
     338:	f9400815 	ldr	x21, [x0, #16]
     33c:	7100803f 	cmp	w1, #0x20
     340:	54000f40 	b.eq	528 <hisi_qm_init+0x200>  // b.none
     344:	7100843f 	cmp	w1, #0x21
     348:	54000801 	b.ne	448 <hisi_qm_init+0x120>  // b.any
     34c:	90000001 	adrp	x1, 0 <__raw_readl>
     350:	f9000bb3 	str	x19, [x29, #16]
     354:	91000021 	add	x1, x1, #0x0
     358:	f90017b6 	str	x22, [x29, #40]
     35c:	9108c021 	add	x1, x1, #0x230
     360:	f9007001 	str	x1, [x0, #224]
     364:	aa0003f3 	mov	x19, x0
     368:	9102c2b6 	add	x22, x21, #0xb0
     36c:	aa1503e0 	mov	x0, x21
     370:	94000000 	bl	0 <pci_enable_device_mem>
     374:	2a0003f4 	mov	w20, w0
     378:	37f81500 	tbnz	w0, #31, 618 <hisi_qm_init+0x2f0>

tbnz?

     37c:	f9400674 	ldr	x20, [x19, #8]
     380:	d2804001 	mov	x1, #0x200                 	// #512
     384:	aa1503e0 	mov	x0, x21
     388:	94000000 	bl	0 <pci_select_bars>
     38c:	aa1403e2 	mov	x2, x20
     390:	2a0003e1 	mov	w1, w0
     394:	aa1503e0 	mov	x0, x21
     398:	94000000 	bl	0 <pci_request_selected_regions>
     39c:	2a0003f4 	mov	w20, w0
     3a0:	37f81320 	tbnz	w0, #31, 604 <hisi_qm_init+0x2dc>
     3a4:	f9400a61 	ldr	x1, [x19, #16]
     3a8:	f9421ea0 	ldr	x0, [x21, #1080]
     3ac:	f9421c23 	ldr	x3, [x1, #1080]
     3b0:	f9422022 	ldr	x2, [x1, #1088]
     3b4:	b5000543 	cbnz	x3, 45c <hisi_qm_init+0x134>
     3b8:	d2800001 	mov	x1, #0x0                   	// #0
     3bc:	b5000502 	cbnz	x2, 45c <hisi_qm_init+0x134>
     3c0:	90000004 	adrp	x4, 0 <arm64_use_ng_mappings>
     3c4:	d280e0e3 	mov	x3, #0x707                 	// #1799
     3c8:	f2e00d03 	movk	x3, #0x68, lsl #48

movk?

     3cc:	d281e0e2 	mov	x2, #0xf07                 	// #3847
     3d0:	39400084 	ldrb	w4, [x4]
     3d4:	f2e00d02 	movk	x2, #0x68, lsl #48
     3d8:	7100009f 	cmp	w4, #0x0
     3dc:	9a820062 	csel	x2, x3, x2, eq  // eq = none
     3e0:	94000000 	bl	0 <__ioremap>
     3e4:	f9000e60 	str	x0, [x19, #24]
     3e8:	b4001020 	cbz	x0, 5ec <hisi_qm_init+0x2c4>
     3ec:	92800001 	mov	x1, #0xffffffffffffffff    	// #-1
     3f0:	aa1603e0 	mov	x0, x22
     3f4:	94000000 	bl	0 <dma_set_mask>
     3f8:	2a0003f4 	mov	w20, w0
     3fc:	7100001f 	cmp	w0, #0x0
     400:	54000340 	b.eq	468 <hisi_qm_init+0x140>  // b.none
     404:	5400038a 	b.ge	474 <hisi_qm_init+0x14c>  // b.tcont
     408:	f9400e60 	ldr	x0, [x19, #24]
     40c:	94000000 	bl	0 <iounmap>
     410:	d2804001 	mov	x1, #0x200                 	// #512
     414:	aa1503e0 	mov	x0, x21
     418:	94000000 	bl	0 <pci_select_bars>
     41c:	2a0003e1 	mov	w1, w0
     420:	aa1503e0 	mov	x0, x21
     424:	94000000 	bl	0 <pci_release_selected_regions>
     428:	aa1503e0 	mov	x0, x21
     42c:	94000000 	bl	0 <pci_disable_device>
     430:	2a1403e0 	mov	w0, w20
     434:	f9400bb3 	ldr	x19, [x29, #16]
     438:	f94017b6 	ldr	x22, [x29, #40]
     43c:	a941d7f4 	ldp	x20, x21, [sp, #24]
     440:	a8c47bfd 	ldp	x29, x30, [sp], #64
     444:	d65f03c0 	ret
     448:	128002b4 	mov	w20, #0xffffffea            	// #-22
     44c:	2a1403e0 	mov	w0, w20
     450:	a941d7f4 	ldp	x20, x21, [sp, #24]
     454:	a8c47bfd 	ldp	x29, x30, [sp], #64
     458:	d65f03c0 	ret
     45c:	91000442 	add	x2, x2, #0x1
     460:	cb030041 	sub	x1, x2, x3
     464:	17ffffd7 	b	3c0 <hisi_qm_init+0x98>
     468:	92800001 	mov	x1, #0xffffffffffffffff    	// #-1
     46c:	aa1603e0 	mov	x0, x22
     470:	94000000 	bl	0 <dma_set_coherent_mask>
     474:	aa1503e0 	mov	x0, x21
     478:	94000000 	bl	0 <pci_set_master>
     47c:	f9407260 	ldr	x0, [x19, #224]
     480:	f9400801 	ldr	x1, [x0, #16]
     484:	b4000bc1 	cbz	x1, 5fc <hisi_qm_init+0x2d4>
     488:	aa1303e0 	mov	x0, x19
     48c:	d63f0020 	blr	x1
     490:	2a0003e2 	mov	w2, w0
     494:	d2800004 	mov	x4, #0x0                   	// #0
     498:	aa1503e0 	mov	x0, x21
     49c:	52800043 	mov	w3, #0x2                   	// #2
     4a0:	2a0203e1 	mov	w1, w2
     4a4:	94000000 	bl	0 <pci_alloc_irq_vectors_affinity>
     4a8:	2a0003f4 	mov	w20, w0
     4ac:	37f80c40 	tbnz	w0, #31, 634 <hisi_qm_init+0x30c>
     4b0:	f9400a76 	ldr	x22, [x19, #16]
     4b4:	52800001 	mov	w1, #0x0                   	// #0
     4b8:	aa1603e0 	mov	x0, x22
     4bc:	94000000 	bl	0 <pci_irq_vector>
     4c0:	f9400664 	ldr	x4, [x19, #8]
     4c4:	90000001 	adrp	x1, 0 <__raw_readl>
     4c8:	aa1303e5 	mov	x5, x19
     4cc:	d2801003 	mov	x3, #0x80                  	// #128
     4d0:	d2800002 	mov	x2, #0x0                   	// #0
     4d4:	91000021 	add	x1, x1, #0x0
     4d8:	94000000 	bl	0 <request_threaded_irq>
     4dc:	2a0003f4 	mov	w20, w0
     4e0:	35000800 	cbnz	w0, 5e0 <hisi_qm_init+0x2b8>
     4e4:	b9400260 	ldr	w0, [x19]
     4e8:	7100841f 	cmp	w0, #0x21
     4ec:	540002c0 	b.eq	544 <hisi_qm_init+0x21c>  // b.none
     4f0:	b9002e7f 	str	wzr, [x19, #44]
     4f4:	91030260 	add	x0, x19, #0xc0
     4f8:	90000002 	adrp	x2, 0 <__raw_readl>
     4fc:	90000001 	adrp	x1, 0 <__raw_readl>
     500:	91000042 	add	x2, x2, #0x0
     504:	91000021 	add	x1, x1, #0x0
     508:	94000000 	bl	0 <__mutex_init>
     50c:	f900567f 	str	xzr, [x19, #168]
     510:	2a1403e0 	mov	w0, w20
     514:	f9400bb3 	ldr	x19, [x29, #16]
     518:	f94017b6 	ldr	x22, [x29, #40]
     51c:	a941d7f4 	ldp	x20, x21, [sp, #24]
     520:	a8c47bfd 	ldp	x29, x30, [sp], #64
     524:	d65f03c0 	ret
     528:	90000001 	adrp	x1, 0 <__raw_readl>
     52c:	f9000bb3 	str	x19, [x29, #16]
     530:	91000021 	add	x1, x1, #0x0
     534:	f90017b6 	str	x22, [x29, #40]
     538:	91080021 	add	x1, x1, #0x200
     53c:	f9007001 	str	x1, [x0, #224]
     540:	17ffff89 	b	364 <hisi_qm_init+0x3c>
     544:	52800021 	mov	w1, #0x1                   	// #1
     548:	f9001bb7 	str	x23, [x29, #48]
     54c:	aa1603e0 	mov	x0, x22
     550:	94000000 	bl	0 <pci_irq_vector>
     554:	f9400664 	ldr	x4, [x19, #8]
     558:	90000001 	adrp	x1, 0 <__raw_readl>
     55c:	aa1303e5 	mov	x5, x19
     560:	d2801003 	mov	x3, #0x80                  	// #128
     564:	d2800002 	mov	x2, #0x0                   	// #0
     568:	91000021 	add	x1, x1, #0x0
     56c:	94000000 	bl	0 <request_threaded_irq>
     570:	2a0003f7 	mov	w23, w0
     574:	35000280 	cbnz	w0, 5c4 <hisi_qm_init+0x29c>
     578:	b9400660 	ldr	w0, [x19, #4]
     57c:	350003c0 	cbnz	w0, 5f4 <hisi_qm_init+0x2cc>
     580:	52800061 	mov	w1, #0x3                   	// #3
     584:	aa1603e0 	mov	x0, x22
     588:	94000000 	bl	0 <pci_irq_vector>
     58c:	f9400664 	ldr	x4, [x19, #8]
     590:	90000001 	adrp	x1, 0 <__raw_readl>
     594:	aa1303e5 	mov	x5, x19
     598:	d2801003 	mov	x3, #0x80                  	// #128
     59c:	d2800002 	mov	x2, #0x0                   	// #0
     5a0:	91000021 	add	x1, x1, #0x0
     5a4:	94000000 	bl	0 <request_threaded_irq>
     5a8:	2a0003f7 	mov	w23, w0
     5ac:	34000240 	cbz	w0, 5f4 <hisi_qm_init+0x2cc>
     5b0:	52800021 	mov	w1, #0x1                   	// #1
     5b4:	aa1603e0 	mov	x0, x22
     5b8:	94000000 	bl	0 <pci_irq_vector>
     5bc:	aa1303e1 	mov	x1, x19
     5c0:	94000000 	bl	0 <free_irq>
     5c4:	52800001 	mov	w1, #0x0                   	// #0
     5c8:	aa1603e0 	mov	x0, x22
     5cc:	94000000 	bl	0 <pci_irq_vector>
     5d0:	2a1703f4 	mov	w20, w23
     5d4:	aa1303e1 	mov	x1, x19
     5d8:	94000000 	bl	0 <free_irq>
     5dc:	f9401bb7 	ldr	x23, [x29, #48]
     5e0:	aa1503e0 	mov	x0, x21
     5e4:	94000000 	bl	0 <pci_free_irq_vectors>
     5e8:	17ffff88 	b	408 <hisi_qm_init+0xe0>
     5ec:	12800094 	mov	w20, #0xfffffffb            	// #-5
     5f0:	17ffff88 	b	410 <hisi_qm_init+0xe8>
     5f4:	f9401bb7 	ldr	x23, [x29, #48]
     5f8:	17ffffbe 	b	4f0 <hisi_qm_init+0x1c8>
     5fc:	12800bd4 	mov	w20, #0xffffffa1            	// #-95
     600:	17ffff82 	b	408 <hisi_qm_init+0xe0>
     604:	90000001 	adrp	x1, 0 <__raw_readl>
     608:	aa1603e0 	mov	x0, x22
     60c:	91000021 	add	x1, x1, #0x0
     610:	94000000 	bl	0 <_dev_err>
     614:	17ffff85 	b	428 <hisi_qm_init+0x100>
     618:	aa1603e0 	mov	x0, x22
     61c:	90000001 	adrp	x1, 0 <__raw_readl>
     620:	91000021 	add	x1, x1, #0x0
     624:	94000000 	bl	0 <_dev_err>
     628:	f9400bb3 	ldr	x19, [x29, #16]
     62c:	f94017b6 	ldr	x22, [x29, #40]
     630:	17ffff87 	b	44c <hisi_qm_init+0x124>
     634:	90000001 	adrp	x1, 0 <__raw_readl>
     638:	aa1603e0 	mov	x0, x22
     63c:	91000021 	add	x1, x1, #0x0
     640:	94000000 	bl	0 <_dev_err>
     644:	17ffff71 	b	408 <hisi_qm_init+0xe0>

0000000000000648 <qm_qp_work_func>:
     648:	f85f8001 	ldur	x1, [x0, #-8]

ldur?

     64c:	b40009c1 	cbz	x1, 784 <qm_qp_work_func+0x13c>
     650:	a9bc7bfd 	stp	x29, x30, [sp, #-64]!
     654:	910003fd 	mov	x29, sp
     658:	a90153f3 	stp	x19, x20, [sp, #16]
     65c:	d101c013 	sub	x19, x0, #0x70
     660:	a9025bf5 	stp	x21, x22, [sp, #32]
     664:	aa0003f6 	mov	x22, x0
     668:	a90363f7 	stp	x23, x24, [sp, #48]
     66c:	91010275 	add	x21, x19, #0x40
     670:	52800037 	mov	w23, #0x1                   	// #1
     674:	785d6014 	ldurh	w20, [x0, #-42]

ldurh?

     678:	f85b8000 	ldur	x0, [x0, #-72]
     67c:	f9404e78 	ldr	x24, [x19, #152]
     680:	8b141014 	add	x20, x0, x20, lsl #4
     684:	d503201f 	nop
     688:	79401e81 	ldrh	w1, [x20, #14]
     68c:	39412260 	ldrb	w0, [x19, #72]
     690:	12000021 	and	w1, w1, #0x1
     694:	6b01001f 	cmp	w0, w1
     698:	540004a1 	b.ne	72c <qm_qp_work_func+0xe4>  // b.any
     69c:	d50331bf 	dmb	oshld
     6a0:	79401282 	ldrh	w2, [x20, #8]
     6a4:	aa1303e0 	mov	x0, x19
     6a8:	b9402301 	ldr	w1, [x24, #32]
     6ac:	f9401264 	ldr	x4, [x19, #32]
     6b0:	f9403663 	ldr	x3, [x19, #104]
     6b4:	1b017c41 	mul	w1, w2, w1
     6b8:	8b010081 	add	x1, x4, x1
     6bc:	d63f0060 	blr	x3
     6c0:	785d62c0 	ldurh	w0, [x22, #-42]
     6c4:	11000403 	add	w3, w0, #0x1
     6c8:	710ffc1f 	cmp	w0, #0x3ff
     6cc:	12003c63 	and	w3, w3, #0xffff
     6d0:	540004c0 	b.eq	768 <qm_qp_work_func+0x120>  // b.none
     6d4:	d37c3c60 	ubfiz	x0, x3, #4, #16
     6d8:	781d62c3 	sturh	w3, [x22, #-42]

sturh

     6dc:	f9407305 	ldr	x5, [x24, #224]
     6e0:	52800004 	mov	w4, #0x0                   	// #0
     6e4:	79400261 	ldrh	w1, [x19]
     6e8:	52800022 	mov	w2, #0x1                   	// #1
     6ec:	f9401674 	ldr	x20, [x19, #40]
     6f0:	f94004a5 	ldr	x5, [x5, #8]
     6f4:	8b000294 	add	x20, x20, x0
     6f8:	aa1803e0 	mov	x0, x24
     6fc:	d63f00a0 	blr	x5
     700:	14000018 	b	760 <qm_qp_work_func+0x118>
     704:	14000017 	b	760 <qm_qp_work_func+0x118>
     708:	2a1703e0 	mov	w0, w23
     70c:	91010261 	add	x1, x19, #0x40
     710:	4b0003e0 	neg	w0, w0
     714:	b820003f 	stadd	w0, [x1]

stadd

     718:	79401e81 	ldrh	w1, [x20, #14]
     71c:	39412260 	ldrb	w0, [x19, #72]
     720:	12000021 	and	w1, w1, #0x1
     724:	6b01001f 	cmp	w0, w1
     728:	54fffba0 	b.eq	69c <qm_qp_work_func+0x54>  // b.none
     72c:	f9407305 	ldr	x5, [x24, #224]
     730:	52800024 	mov	w4, #0x1                   	// #1
     734:	79400261 	ldrh	w1, [x19]
     738:	aa1803e0 	mov	x0, x24
     73c:	79408e63 	ldrh	w3, [x19, #70]
     740:	2a0403e2 	mov	w2, w4
     744:	f94004a5 	ldr	x5, [x5, #8]
     748:	d63f00a0 	blr	x5
     74c:	a94153f3 	ldp	x19, x20, [sp, #16]
     750:	a9425bf5 	ldp	x21, x22, [sp, #32]
     754:	a94363f7 	ldp	x23, x24, [sp, #48]
     758:	a8c47bfd 	ldp	x29, x30, [sp], #64
     75c:	d65f03c0 	ret
     760:	14000806 	b	2778 <hisi_qm_uninit+0x168>
     764:	17ffffc9 	b	688 <qm_qp_work_func+0x40>
     768:	385d82c1 	ldurb	w1, [x22, #-40]
     76c:	d2800000 	mov	x0, #0x0                   	// #0
     770:	781d62df 	sturh	wzr, [x22, #-42]
     774:	52800003 	mov	w3, #0x0                   	// #0
     778:	52000021 	eor	w1, w1, #0x1

eor

     77c:	381d82c1 	sturb	w1, [x22, #-40]
     780:	17ffffd7 	b	6dc <qm_qp_work_func+0x94>
     784:	d65f03c0 	ret

0000000000000788 <hisi_qm_release_qp>:
     788:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
     78c:	910003fd 	mov	x29, sp
     790:	a90153f3 	stp	x19, x20, [sp, #16]
     794:	aa0003f4 	mov	x20, x0
     798:	f90013f5 	str	x21, [sp, #32]
     79c:	f9404c13 	ldr	x19, [x0, #152]
     7a0:	3945a260 	ldrb	w0, [x19, #360]
     7a4:	34000100 	cbz	w0, 7c4 <hisi_qm_release_qp+0x3c>
     7a8:	f9400682 	ldr	x2, [x20, #8]
     7ac:	b40000c2 	cbz	x2, 7c4 <hisi_qm_release_qp+0x3c>
     7b0:	a9410683 	ldp	x3, x1, [x20, #16]
     7b4:	d2800004 	mov	x4, #0x0                   	// #0
     7b8:	f9400a60 	ldr	x0, [x19, #16]
     7bc:	9102c000 	add	x0, x0, #0xb0
     7c0:	94000000 	bl	0 <dma_free_attrs>
     7c4:	9102a275 	add	x21, x19, #0xa8
     7c8:	aa1503e0 	mov	x0, x21
     7cc:	94000000 	bl	0 <_raw_write_lock>
     7d0:	b9400282 	ldr	w2, [x20]
     7d4:	d2800021 	mov	x1, #0x1                   	// #1
     7d8:	f9405e60 	ldr	x0, [x19, #184]
     7dc:	f822781f 	str	xzr, [x0, x2, lsl #3]
     7e0:	b9400282 	ldr	w2, [x20]
     7e4:	f9405a63 	ldr	x3, [x19, #176]
     7e8:	53067c40 	lsr	w0, w2, #6
     7ec:	9ac22021 	lsl	x1, x1, x2
     7f0:	8b000c60 	add	x0, x3, x0, lsl #3
     7f4:	14000004 	b	804 <hisi_qm_release_qp+0x7c>
     7f8:	14000003 	b	804 <hisi_qm_release_qp+0x7c>
     7fc:	f821101f 	stclr	x1, [x0]
     800:	14000002 	b	808 <hisi_qm_release_qp+0x80>
     804:	140007e3 	b	2790 <hisi_qm_uninit+0x180>
     808:	b9402e61 	ldr	w1, [x19, #44]
     80c:	aa1503e0 	mov	x0, x21
     810:	51000421 	sub	w1, w1, #0x1
     814:	b9002e61 	str	w1, [x19, #44]
     818:	94000000 	bl	0 <_raw_write_unlock>
     81c:	aa1403e0 	mov	x0, x20
     820:	94000000 	bl	0 <kfree>
     824:	a94153f3 	ldp	x19, x20, [sp, #16]
     828:	f94013f5 	ldr	x21, [sp, #32]
     82c:	a8c37bfd 	ldp	x29, x30, [sp], #48
     830:	d65f03c0 	ret
     834:	d503201f 	nop

0000000000000838 <hisi_qp_send>:
     838:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
     83c:	910003fd 	mov	x29, sp
     840:	f9000bf3 	str	x19, [sp, #16]
     844:	aa0003f3 	mov	x19, x0
     848:	a9025bf5 	stp	x21, x22, [sp, #32]
     84c:	91010015 	add	x21, x0, #0x40
     850:	b9404000 	ldr	w0, [x0, #64]
     854:	79400aa3 	ldrh	w3, [x21, #4]
     858:	7110001f 	cmp	w0, #0x400
     85c:	540004c0 	b.eq	8f4 <hisi_qp_send+0xbc>  // b.none
     860:	f9000fb4 	str	x20, [x29, #24]
     864:	11000474 	add	w20, w3, #0x1
     868:	f9404e65 	ldr	x5, [x19, #152]
     86c:	f9402a64 	ldr	x4, [x19, #80]
     870:	f9401260 	ldr	x0, [x19, #32]
     874:	b94020a2 	ldr	w2, [x5, #32]
     878:	12000096 	and	w22, w4, #0x1
     87c:	1b027c63 	mul	w3, w3, w2

mul?

     880:	8b030000 	add	x0, x0, x3
     884:	37000424 	tbnz	w4, #0, 908 <hisi_qp_send+0xd0>
     888:	b4000580 	cbz	x0, 938 <hisi_qp_send+0x100>
     88c:	2a0203e2 	mov	w2, w2
     890:	94000000 	bl	0 <memcpy>
     894:	f9404e60 	ldr	x0, [x19, #152]
     898:	12002694 	and	w20, w20, #0x3ff
     89c:	79400261 	ldrh	w1, [x19]
     8a0:	52800004 	mov	w4, #0x0                   	// #0
     8a4:	2a1403e3 	mov	w3, w20
     8a8:	52800002 	mov	w2, #0x0                   	// #0
     8ac:	f9407005 	ldr	x5, [x0, #224]
     8b0:	f94004a5 	ldr	x5, [x5, #8]
     8b4:	d63f00a0 	blr	x5
     8b8:	14000006 	b	8d0 <hisi_qp_send+0x98>
     8bc:	14000005 	b	8d0 <hisi_qp_send+0x98>
     8c0:	52800020 	mov	w0, #0x1                   	// #1
     8c4:	91010261 	add	x1, x19, #0x40
     8c8:	b820003f 	stadd	w0, [x1]
     8cc:	14000003 	b	8d8 <hisi_qp_send+0xa0>
     8d0:	91010262 	add	x2, x19, #0x40
     8d4:	140007b5 	b	27a8 <hisi_qm_uninit+0x198>
     8d8:	79000ab4 	strh	w20, [x21, #4]
     8dc:	f9400fb4 	ldr	x20, [x29, #24]
     8e0:	2a1603e0 	mov	w0, w22
     8e4:	f9400bf3 	ldr	x19, [sp, #16]
     8e8:	a9425bf5 	ldp	x21, x22, [sp, #32]
     8ec:	a8c37bfd 	ldp	x29, x30, [sp], #48
     8f0:	d65f03c0 	ret
     8f4:	f9402a60 	ldr	x0, [x19, #80]
     8f8:	128001f6 	mov	w22, #0xfffffff0            	// #-16
     8fc:	3607ff20 	tbz	w0, #0, 8e0 <hisi_qp_send+0xa8>
     900:	f9404e65 	ldr	x5, [x19, #152]
     904:	14000002 	b	90c <hisi_qp_send+0xd4>
     908:	f9400fb4 	ldr	x20, [x29, #24]
     90c:	f94008a0 	ldr	x0, [x5, #16]
     910:	12800156 	mov	w22, #0xfffffff5            	// #-11
     914:	90000001 	adrp	x1, 0 <__raw_readl>
     918:	91000021 	add	x1, x1, #0x0
     91c:	9102c000 	add	x0, x0, #0xb0
     920:	94000000 	bl	0 <_dev_info>
     924:	2a1603e0 	mov	w0, w22
     928:	f9400bf3 	ldr	x19, [sp, #16]
     92c:	a9425bf5 	ldp	x21, x22, [sp, #32]
     930:	a8c37bfd 	ldp	x29, x30, [sp], #48
     934:	d65f03c0 	ret
     938:	128001f6 	mov	w22, #0xfffffff0            	// #-16
     93c:	f9400fb4 	ldr	x20, [x29, #24]
     940:	17ffffe8 	b	8e0 <hisi_qp_send+0xa8>
     944:	d503201f 	nop

0000000000000948 <hisi_qm_debug_regs_clear>:
     948:	d50332bf 	dmb	oshst
     94c:	f9400c01 	ldr	x1, [x0, #24]
     950:	91441021 	add	x1, x1, #0x104, lsl #12
     954:	9100c021 	add	x1, x1, #0x30
     958:	b900003f 	str	wzr, [x1]
     95c:	d50332bf 	dmb	oshst
     960:	f9400c01 	ldr	x1, [x0, #24]
     964:	91441021 	add	x1, x1, #0x104, lsl #12
     968:	91010021 	add	x1, x1, #0x40
     96c:	b900003f 	str	wzr, [x1]
     970:	d50332bf 	dmb	oshst
     974:	f9400c01 	ldr	x1, [x0, #24]
     978:	52800022 	mov	w2, #0x1                   	// #1
     97c:	91440023 	add	x3, x1, #0x100, lsl #12
     980:	91046063 	add	x3, x3, #0x118
     984:	b9000062 	str	w2, [x3]
     988:	90000002 	adrp	x2, 0 <__raw_readl>
     98c:	91000042 	add	x2, x2, #0x0
     990:	91028044 	add	x4, x2, #0xa0
     994:	14000002 	b	99c <hisi_qm_debug_regs_clear+0x54>
     998:	f9400c01 	ldr	x1, [x0, #24]
     99c:	f9400443 	ldr	x3, [x2, #8]
     9a0:	8b030021 	add	x1, x1, x3
     9a4:	b9400021 	ldr	w1, [x1]
     9a8:	d50331bf 	dmb	oshld
     9ac:	2a0103e1 	mov	w1, w1
     9b0:	ca010021 	eor	x1, x1, x1
     9b4:	b5000001 	cbnz	x1, 9b4 <hisi_qm_debug_regs_clear+0x6c>
     9b8:	91004042 	add	x2, x2, #0x10
     9bc:	eb04005f 	cmp	x2, x4
     9c0:	54fffec1 	b.ne	998 <hisi_qm_debug_regs_clear+0x50>  // b.any
     9c4:	d50332bf 	dmb	oshst
     9c8:	f9400c00 	ldr	x0, [x0, #24]
     9cc:	91440000 	add	x0, x0, #0x100, lsl #12
     9d0:	91046000 	add	x0, x0, #0x118
     9d4:	b900001f 	str	wzr, [x0]
     9d8:	d65f03c0 	ret
     9dc:	d503201f 	nop

00000000000009e0 <hisi_qm_stop_qp>:
     9e0:	f9402801 	ldr	x1, [x0, #80]
     9e4:	37000301 	tbnz	w1, #0, a44 <hisi_qm_stop_qp+0x64>
     9e8:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
     9ec:	910003fd 	mov	x29, sp
     9f0:	a90153f3 	stp	x19, x20, [sp, #16]
     9f4:	aa0003f4 	mov	x20, x0
     9f8:	f90013f5 	str	x21, [sp, #32]
     9fc:	52800153 	mov	w19, #0xa                   	// #10
     a00:	f9404c00 	ldr	x0, [x0, #152]
     a04:	f9400815 	ldr	x21, [x0, #16]
     a08:	b9404281 	ldr	w1, [x20, #64]
     a0c:	52800280 	mov	w0, #0x14                  	// #20
     a10:	340001e1 	cbz	w1, a4c <hisi_qm_stop_qp+0x6c>
     a14:	94000000 	bl	0 <msleep>
     a18:	71000673 	subs	w19, w19, #0x1
     a1c:	54ffff61 	b.ne	a08 <hisi_qm_stop_qp+0x28>  // b.any
     a20:	9102c2a0 	add	x0, x21, #0xb0
     a24:	90000001 	adrp	x1, 0 <__raw_readl>
     a28:	91000021 	add	x1, x1, #0x0
     a2c:	94000000 	bl	0 <_dev_err>
     a30:	52800000 	mov	w0, #0x0                   	// #0
     a34:	f94013f5 	ldr	x21, [sp, #32]
     a38:	a94153f3 	ldp	x19, x20, [sp, #16]
     a3c:	a8c37bfd 	ldp	x29, x30, [sp], #48
     a40:	d65f03c0 	ret
     a44:	52800000 	mov	w0, #0x0                   	// #0
     a48:	d65f03c0 	ret
     a4c:	91014281 	add	x1, x20, #0x50
     a50:	14000009 	b	a74 <hisi_qm_stop_qp+0x94>
     a54:	14000008 	b	a74 <hisi_qm_stop_qp+0x94>
     a58:	d2800020 	mov	x0, #0x1                   	// #1
     a5c:	f820303f 	stset	x0, [x1]

stset

     a60:	52800000 	mov	w0, #0x0                   	// #0
     a64:	f94013f5 	ldr	x21, [sp, #32]
     a68:	a94153f3 	ldp	x19, x20, [sp, #16]
     a6c:	a8c37bfd 	ldp	x29, x30, [sp], #48
     a70:	d65f03c0 	ret
     a74:	91014282 	add	x2, x20, #0x50
     a78:	14000752 	b	27c0 <hisi_qm_uninit+0x1b0>
     a7c:	52800000 	mov	w0, #0x0                   	// #0
     a80:	f94013f5 	ldr	x21, [sp, #32]
     a84:	a94153f3 	ldp	x19, x20, [sp, #16]
     a88:	a8c37bfd 	ldp	x29, x30, [sp], #48
     a8c:	d65f03c0 	ret

0000000000000a90 <qm_regs_show>:
     a90:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
     a94:	910003fd 	mov	x29, sp
     a98:	f9000bf3 	str	x19, [sp, #16]
     a9c:	90000013 	adrp	x19, 0 <__raw_readl>
     aa0:	f90017f6 	str	x22, [sp, #40]
     aa4:	91000273 	add	x19, x19, #0x0
     aa8:	91064261 	add	x1, x19, #0x190
     aac:	f9403c16 	ldr	x22, [x0, #120]
     ab0:	b94006c2 	ldr	w2, [x22, #4]
     ab4:	7100005f 	cmp	w2, #0x0
     ab8:	9a810273 	csel	x19, x19, x1, eq  // eq = none
     abc:	f9400261 	ldr	x1, [x19]
     ac0:	b40002a1 	cbz	x1, b14 <qm_regs_show+0x84>
     ac4:	a901d7b4 	stp	x20, x21, [x29, #24]
     ac8:	90000015 	adrp	x21, 0 <__raw_readl>
     acc:	aa0003f4 	mov	x20, x0
     ad0:	910002b5 	add	x21, x21, #0x0
     ad4:	d503201f 	nop
     ad8:	f9400661 	ldr	x1, [x19, #8]
     adc:	f9400ec3 	ldr	x3, [x22, #24]
     ae0:	8b010063 	add	x3, x3, x1
     ae4:	b9400063 	ldr	w3, [x3]
     ae8:	d50331bf 	dmb	oshld
     aec:	2a0303e1 	mov	w1, w3
     af0:	ca010021 	eor	x1, x1, x1
     af4:	b5000001 	cbnz	x1, af4 <qm_regs_show+0x64>
     af8:	f9400262 	ldr	x2, [x19]
     afc:	aa1503e1 	mov	x1, x21
     b00:	aa1403e0 	mov	x0, x20
     b04:	94000000 	bl	0 <seq_printf>
     b08:	f8410e61 	ldr	x1, [x19, #16]!
     b0c:	b5fffe61 	cbnz	x1, ad8 <qm_regs_show+0x48>
     b10:	a941d7b4 	ldp	x20, x21, [x29, #24]
     b14:	52800000 	mov	w0, #0x0                   	// #0
     b18:	f9400bf3 	ldr	x19, [sp, #16]
     b1c:	f94017f6 	ldr	x22, [sp, #40]
     b20:	a8c37bfd 	ldp	x29, x30, [sp], #48
     b24:	d65f03c0 	ret

0000000000000b28 <hisi_qm_create_qp>:
     b28:	a9ba7bfd 	stp	x29, x30, [sp, #-96]!
     b2c:	90000002 	adrp	x2, 0 <kmalloc_caches>
     b30:	910003fd 	mov	x29, sp
     b34:	a90153f3 	stp	x19, x20, [sp, #16]
     b38:	aa0003f4 	mov	x20, x0
     b3c:	f9400040 	ldr	x0, [x2]
     b40:	92800173 	mov	x19, #0xfffffffffffffff4    	// #-12
     b44:	f9001ff8 	str	x24, [sp, #56]
     b48:	f90027fa 	str	x26, [sp, #72]
     b4c:	12001c3a 	and	w26, w1, #0xff
     b50:	5281b801 	mov	w1, #0xdc0                 	// #3520
     b54:	f9400a98 	ldr	x24, [x20, #16]
     b58:	94000000 	bl	0 <kmem_cache_alloc>
     b5c:	b40007a0 	cbz	x0, c50 <hisi_qm_create_qp+0x128>
     b60:	f90023b9 	str	x25, [x29, #64]
     b64:	9102a299 	add	x25, x20, #0xa8
     b68:	f9001bb7 	str	x23, [x29, #48]
     b6c:	aa0003f3 	mov	x19, x0
     b70:	aa1903e0 	mov	x0, x25
     b74:	94000000 	bl	0 <_raw_write_lock>
     b78:	b9402a81 	ldr	w1, [x20, #40]
     b7c:	d2800002 	mov	x2, #0x0                   	// #0
     b80:	f9405a80 	ldr	x0, [x20, #176]
     b84:	94000000 	bl	0 <find_next_zero_bit>
     b88:	aa0003f7 	mov	x23, x0
     b8c:	b9402a80 	ldr	w0, [x20, #40]
     b90:	6b17001f 	cmp	w0, w23
     b94:	54000c89 	b.ls	d24 <hisi_qm_create_qp+0x1fc>  // b.plast
     b98:	a9025bb5 	stp	x21, x22, [x29, #32]
     b9c:	53067ef6 	lsr	w22, w23, #6
     ba0:	f9002bbb 	str	x27, [x29, #80]
     ba4:	d2800035 	mov	x21, #0x1                   	// #1
     ba8:	d37df2d6 	lsl	x22, x22, #3
     bac:	9ad722b5 	lsl	x21, x21, x23
     bb0:	f9405a81 	ldr	x1, [x20, #176]
     bb4:	8b160021 	add	x1, x1, x22
     bb8:	14000005 	b	bcc <hisi_qm_create_qp+0xa4>
     bbc:	14000004 	b	bcc <hisi_qm_create_qp+0xa4>
     bc0:	aa1503e0 	mov	x0, x21
     bc4:	f820303f 	stset	x0, [x1]
     bc8:	14000002 	b	bd0 <hisi_qm_create_qp+0xa8>
     bcc:	14000703 	b	27d8 <hisi_qm_uninit+0x1c8>
     bd0:	f9405e81 	ldr	x1, [x20, #184]
     bd4:	93407efb 	sxtw	x27, w23

sxtw

     bd8:	aa1903e0 	mov	x0, x25
     bdc:	9102c318 	add	x24, x24, #0xb0
     be0:	f83b7833 	str	x19, [x1, x27, lsl #3]
     be4:	b9402e81 	ldr	w1, [x20, #44]
     be8:	11000421 	add	w1, w1, #0x1
     bec:	b9002e81 	str	w1, [x20, #44]
     bf0:	94000000 	bl	0 <_raw_write_unlock>
     bf4:	f9004e74 	str	x20, [x19, #152]
     bf8:	3945a280 	ldrb	w0, [x20, #360]
     bfc:	35000360 	cbnz	w0, c68 <hisi_qm_create_qp+0x140>
     c00:	9101e261 	add	x1, x19, #0x78
     c04:	b27b7be2 	mov	x2, #0xfffffffe0           	// #68719476704
     c08:	90000000 	adrp	x0, 0 <__raw_readl>
     c0c:	b9000277 	str	w23, [x19]
     c10:	91000000 	add	x0, x0, #0x0
     c14:	3900127a 	strb	w26, [x19, #4]
     c18:	f9003a62 	str	x2, [x19, #112]
     c1c:	52800002 	mov	w2, #0x0                   	// #0
     c20:	f9003e61 	str	x1, [x19, #120]
     c24:	a9080261 	stp	x1, x0, [x19, #128]
     c28:	90000000 	adrp	x0, 0 <__raw_readl>
     c2c:	52800741 	mov	w1, #0x3a                  	// #58
     c30:	91000000 	add	x0, x0, #0x0
     c34:	94000000 	bl	0 <alloc_workqueue>
     c38:	f9004a60 	str	x0, [x19, #144]
     c3c:	b4000620 	cbz	x0, d00 <hisi_qm_create_qp+0x1d8>
     c40:	a9425bb5 	ldp	x21, x22, [x29, #32]
     c44:	f9401bb7 	ldr	x23, [x29, #48]
     c48:	f94023b9 	ldr	x25, [x29, #64]
     c4c:	f9402bbb 	ldr	x27, [x29, #80]
     c50:	aa1303e0 	mov	x0, x19
     c54:	f9401ff8 	ldr	x24, [sp, #56]
     c58:	a94153f3 	ldp	x19, x20, [sp, #16]
     c5c:	f94027fa 	ldr	x26, [sp, #72]
     c60:	a8c67bfd 	ldp	x29, x30, [sp], #96
     c64:	d65f03c0 	ret
     c68:	b9402281 	ldr	w1, [x20, #32]
     c6c:	d2800004 	mov	x4, #0x0                   	// #0
     c70:	52819803 	mov	w3, #0xcc0                 	// #3264
     c74:	91004262 	add	x2, x19, #0x10
     c78:	aa1803e0 	mov	x0, x24
     c7c:	53165421 	lsl	w1, w1, #10
     c80:	91401021 	add	x1, x1, #0x4, lsl #12
     c84:	f9000e61 	str	x1, [x19, #24]
     c88:	94000000 	bl	0 <dma_alloc_attrs>
     c8c:	f9000660 	str	x0, [x19, #8]
     c90:	b5fffb80 	cbnz	x0, c00 <hisi_qm_create_qp+0xd8>
     c94:	92800177 	mov	x23, #0xfffffffffffffff4    	// #-12
     c98:	aa1903e0 	mov	x0, x25
     c9c:	94000000 	bl	0 <_raw_write_lock>
     ca0:	f9405e80 	ldr	x0, [x20, #184]
     ca4:	f83b781f 	str	xzr, [x0, x27, lsl #3]
     ca8:	f9405a80 	ldr	x0, [x20, #176]
     cac:	8b160016 	add	x22, x0, x22
     cb0:	14000012 	b	cf8 <hisi_qm_create_qp+0x1d0>
     cb4:	14000011 	b	cf8 <hisi_qm_create_qp+0x1d0>
     cb8:	f83512df 	stclr	x21, [x22]

stclr

     cbc:	aa1903e0 	mov	x0, x25
     cc0:	94000000 	bl	0 <_raw_write_unlock>
     cc4:	a9425bb5 	ldp	x21, x22, [x29, #32]
     cc8:	f9402bbb 	ldr	x27, [x29, #80]
     ccc:	aa1303e0 	mov	x0, x19
     cd0:	aa1703f3 	mov	x19, x23
     cd4:	94000000 	bl	0 <kfree>
     cd8:	f9401bb7 	ldr	x23, [x29, #48]
     cdc:	aa1303e0 	mov	x0, x19
     ce0:	f94023b9 	ldr	x25, [x29, #64]
     ce4:	a94153f3 	ldp	x19, x20, [sp, #16]
     ce8:	f9401ff8 	ldr	x24, [sp, #56]
     cec:	f94027fa 	ldr	x26, [sp, #72]
     cf0:	a8c67bfd 	ldp	x29, x30, [sp], #96
     cf4:	d65f03c0 	ret
     cf8:	140006be 	b	27f0 <hisi_qm_uninit+0x1e0>
     cfc:	17fffff0 	b	cbc <hisi_qm_create_qp+0x194>
     d00:	3945a280 	ldrb	w0, [x20, #360]
     d04:	928001b7 	mov	x23, #0xfffffffffffffff2    	// #-14
     d08:	34fffc80 	cbz	w0, c98 <hisi_qm_create_qp+0x170>
     d0c:	a9408e62 	ldp	x2, x3, [x19, #8]
     d10:	d2800004 	mov	x4, #0x0                   	// #0
     d14:	f9400e61 	ldr	x1, [x19, #24]
     d18:	aa1803e0 	mov	x0, x24
     d1c:	94000000 	bl	0 <dma_free_attrs>
     d20:	17ffffde 	b	c98 <hisi_qm_create_qp+0x170>
     d24:	aa1903e0 	mov	x0, x25
     d28:	94000000 	bl	0 <_raw_write_unlock>
     d2c:	f9400a80 	ldr	x0, [x20, #16]
     d30:	90000001 	adrp	x1, 0 <__raw_readl>
     d34:	928001f7 	mov	x23, #0xfffffffffffffff0    	// #-16
     d38:	91000021 	add	x1, x1, #0x0
     d3c:	9102c000 	add	x0, x0, #0xb0
     d40:	94000000 	bl	0 <_dev_info>
     d44:	17ffffe2 	b	ccc <hisi_qm_create_qp+0x1a4>

0000000000000d48 <hisi_qm_set_vft>:
     d48:	b9403004 	ldr	w4, [x0, #48]
     d4c:	6b02009f 	cmp	w4, w2
     d50:	7a438080 	ccmp	w4, w3, #0x0, hi  // hi = pmore
     d54:	54001243 	b.cc	f9c <hisi_qm_set_vft+0x254>  // b.lo, b.ul, b.last
     d58:	0b030045 	add	w5, w2, w3
     d5c:	6b0400bf 	cmp	w5, w4
     d60:	540011e8 	b.hi	f9c <hisi_qm_set_vft+0x254>  // b.pmore
     d64:	a9b87bfd 	stp	x29, x30, [sp, #-128]!
     d68:	d3647c42 	ubfiz	x2, x2, #28, #32
     d6c:	910003fd 	mov	x29, sp
     d70:	a90153f3 	stp	x19, x20, [sp, #16]
     d74:	aa0003f3 	mov	x19, x0
     d78:	a90363f7 	stp	x23, x24, [sp, #48]
     d7c:	51000460 	sub	w0, w3, #0x1
     d80:	2a0103f8 	mov	w24, w1
     d84:	d28ae001 	mov	x1, #0x5700                	// #22272
     d88:	f2a00021 	movk	x1, #0x1, lsl #16
     d8c:	a9025bf5 	stp	x21, x22, [sp, #32]
     d90:	f2c20001 	movk	x1, #0x1000, lsl #32
     d94:	aa010041 	orr	x1, x2, x1
     d98:	aa00b442 	orr	x2, x2, x0, lsl #45
     d9c:	a9046bf9 	stp	x25, x26, [sp, #64]
     da0:	b2540040 	orr	x0, x2, #0x100000000000
     da4:	a90573fb 	stp	x27, x28, [sp, #80]
     da8:	d2884819 	mov	x25, #0x4240                	// #16960
     dac:	d2800d94 	mov	x20, #0x6c                  	// #108
     db0:	d2800b1c 	mov	x28, #0x58                  	// #88
     db4:	d2800b9b 	mov	x27, #0x5c                  	// #92
     db8:	d2800c1a 	mov	x26, #0x60                  	// #96
     dbc:	2a0303f6 	mov	w22, w3
     dc0:	f90037a1 	str	x1, [x29, #104]
     dc4:	52800017 	mov	w23, #0x0                   	// #0
     dc8:	f9003fa0 	str	x0, [x29, #120]
     dcc:	d360fc21 	lsr	x1, x1, #32
     dd0:	d360fc00 	lsr	x0, x0, #32
     dd4:	f2a001f9 	movk	x25, #0xf, lsl #16
     dd8:	f2a00214 	movk	x20, #0x10, lsl #16
     ddc:	f2a0021c 	movk	x28, #0x10, lsl #16
     de0:	f2a0021b 	movk	x27, #0x10, lsl #16
     de4:	f2a0021a 	movk	x26, #0x10, lsl #16
     de8:	f90033a1 	str	x1, [x29, #96]
     dec:	f9003ba0 	str	x0, [x29, #112]
     df0:	94000000 	bl	0 <ktime_get>
     df4:	8b190015 	add	x21, x0, x25
     df8:	14000007 	b	e14 <hisi_qm_set_vft+0xcc>
     dfc:	94000000 	bl	0 <ktime_get>
     e00:	eb0002bf 	cmp	x21, x0
     e04:	540009ab 	b.lt	f38 <hisi_qm_set_vft+0x1f0>  // b.tstop
     e08:	d2800141 	mov	x1, #0xa                   	// #10
     e0c:	d2800060 	mov	x0, #0x3                   	// #3
     e10:	94000000 	bl	0 <usleep_range>
     e14:	f9400e60 	ldr	x0, [x19, #24]
     e18:	8b140000 	add	x0, x0, x20
     e1c:	b9400000 	ldr	w0, [x0]
     e20:	3607fee0 	tbz	w0, #0, dfc <hisi_qm_set_vft+0xb4>

tbz

     e24:	d50332bf 	dmb	oshst
     e28:	f9400e60 	ldr	x0, [x19, #24]
     e2c:	8b1c0000 	add	x0, x0, x28
     e30:	b900001f 	str	wzr, [x0]
     e34:	d50332bf 	dmb	oshst
     e38:	f9400e60 	ldr	x0, [x19, #24]
     e3c:	8b1b0000 	add	x0, x0, x27
     e40:	b9000017 	str	w23, [x0]
     e44:	d50332bf 	dmb	oshst
     e48:	f9400e60 	ldr	x0, [x19, #24]
     e4c:	8b1a0000 	add	x0, x0, x26
     e50:	b9000018 	str	w24, [x0]
     e54:	34000176 	cbz	w22, e80 <hisi_qm_set_vft+0x138>
     e58:	b9400260 	ldr	w0, [x19]
     e5c:	7100801f 	cmp	w0, #0x20
     e60:	35000857 	cbnz	w23, f68 <hisi_qm_set_vft+0x220>
     e64:	54000960 	b.eq	f90 <hisi_qm_set_vft+0x248>  // b.none
     e68:	7100841f 	cmp	w0, #0x21
     e6c:	b94073a1 	ldr	w1, [x29, #112]
     e70:	b9407ba0 	ldr	w0, [x29, #120]
     e74:	1a9f0022 	csel	w2, w1, wzr, eq  // eq = none
     e78:	1a9f0001 	csel	w1, w0, wzr, eq  // eq = none
     e7c:	14000003 	b	e88 <hisi_qm_set_vft+0x140>
     e80:	52800002 	mov	w2, #0x0                   	// #0
     e84:	52800001 	mov	w1, #0x0                   	// #0
     e88:	d50332bf 	dmb	oshst
     e8c:	f9400e60 	ldr	x0, [x19, #24]
     e90:	91440000 	add	x0, x0, #0x100, lsl #12
     e94:	91019000 	add	x0, x0, #0x64
     e98:	b9000001 	str	w1, [x0]
     e9c:	d50332bf 	dmb	oshst
     ea0:	f9400e60 	ldr	x0, [x19, #24]
     ea4:	91440000 	add	x0, x0, #0x100, lsl #12
     ea8:	9101a000 	add	x0, x0, #0x68
     eac:	b9000002 	str	w2, [x0]
     eb0:	d50332bf 	dmb	oshst
     eb4:	f9400e60 	ldr	x0, [x19, #24]
     eb8:	8b140000 	add	x0, x0, x20
     ebc:	b900001f 	str	wzr, [x0]
     ec0:	d50332bf 	dmb	oshst
     ec4:	f9400e60 	ldr	x0, [x19, #24]
     ec8:	52800021 	mov	w1, #0x1                   	// #1
     ecc:	91440000 	add	x0, x0, #0x100, lsl #12
     ed0:	91015000 	add	x0, x0, #0x54
     ed4:	b9000001 	str	w1, [x0]
     ed8:	94000000 	bl	0 <ktime_get>
     edc:	8b190015 	add	x21, x0, x25
     ee0:	14000007 	b	efc <hisi_qm_set_vft+0x1b4>
     ee4:	94000000 	bl	0 <ktime_get>
     ee8:	eb0002bf 	cmp	x21, x0
     eec:	5400032b 	b.lt	f50 <hisi_qm_set_vft+0x208>  // b.tstop
     ef0:	d2800141 	mov	x1, #0xa                   	// #10
     ef4:	d2800060 	mov	x0, #0x3                   	// #3
     ef8:	94000000 	bl	0 <usleep_range>
     efc:	f9400e60 	ldr	x0, [x19, #24]
     f00:	8b140000 	add	x0, x0, x20
     f04:	b9400000 	ldr	w0, [x0]
     f08:	3607fee0 	tbz	w0, #0, ee4 <hisi_qm_set_vft+0x19c>
     f0c:	34000137 	cbz	w23, f30 <hisi_qm_set_vft+0x1e8>
     f10:	52800000 	mov	w0, #0x0                   	// #0
     f14:	a94153f3 	ldp	x19, x20, [sp, #16]
     f18:	a9425bf5 	ldp	x21, x22, [sp, #32]
     f1c:	a94363f7 	ldp	x23, x24, [sp, #48]
     f20:	a9446bf9 	ldp	x25, x26, [sp, #64]
     f24:	a94573fb 	ldp	x27, x28, [sp, #80]
     f28:	a8c87bfd 	ldp	x29, x30, [sp], #128
     f2c:	d65f03c0 	ret
     f30:	52800037 	mov	w23, #0x1                   	// #1
     f34:	17ffffaf 	b	df0 <hisi_qm_set_vft+0xa8>
     f38:	f9400e60 	ldr	x0, [x19, #24]
     f3c:	8b140000 	add	x0, x0, x20
     f40:	b9400000 	ldr	w0, [x0]
     f44:	3707f700 	tbnz	w0, #0, e24 <hisi_qm_set_vft+0xdc>
     f48:	12800da0 	mov	w0, #0xffffff92            	// #-110
     f4c:	17fffff2 	b	f14 <hisi_qm_set_vft+0x1cc>
     f50:	f9400e60 	ldr	x0, [x19, #24]
     f54:	8b140000 	add	x0, x0, x20
     f58:	b9400000 	ldr	w0, [x0]
     f5c:	3707fd80 	tbnz	w0, #0, f0c <hisi_qm_set_vft+0x1c4>
     f60:	12800da0 	mov	w0, #0xffffff92            	// #-110
     f64:	17ffffec 	b	f14 <hisi_qm_set_vft+0x1cc>
     f68:	540000c0 	b.eq	f80 <hisi_qm_set_vft+0x238>  // b.none
     f6c:	7100841f 	cmp	w0, #0x21
     f70:	52a20001 	mov	w1, #0x10000000            	// #268435456
     f74:	52800002 	mov	w2, #0x0                   	// #0
     f78:	1a9f0021 	csel	w1, w1, wzr, eq  // eq = none
     f7c:	17ffffc3 	b	e88 <hisi_qm_set_vft+0x140>
     f80:	528ae001 	mov	w1, #0x5700                	// #22272
     f84:	52800002 	mov	w2, #0x0                   	// #0
     f88:	72a20021 	movk	w1, #0x1001, lsl #16
     f8c:	17ffffbf 	b	e88 <hisi_qm_set_vft+0x140>
     f90:	b94063a2 	ldr	w2, [x29, #96]
     f94:	b9406ba1 	ldr	w1, [x29, #104]
     f98:	17ffffbc 	b	e88 <hisi_qm_set_vft+0x140>
     f9c:	128002a0 	mov	w0, #0xffffffea            	// #-22
     fa0:	d65f03c0 	ret
     fa4:	d503201f 	nop

----> ok this time we stop here.

0000000000000fa8 <hisi_qm_stop>:
     fa8:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
     fac:	910003fd 	mov	x29, sp
     fb0:	f90013f5 	str	x21, [sp, #32]
     fb4:	b4000740 	cbz	x0, 109c <hisi_qm_stop+0xf4>
     fb8:	f90017b6 	str	x22, [x29, #40]
     fbc:	f9400816 	ldr	x22, [x0, #16]
     fc0:	b40006d6 	cbz	x22, 1098 <hisi_qm_stop+0xf0>
     fc4:	f9000fb4 	str	x20, [x29, #24]
     fc8:	9102c2d6 	add	x22, x22, #0xb0
     fcc:	aa0003f4 	mov	x20, x0
     fd0:	d50332bf 	dmb	oshst
     fd4:	f9400c00 	ldr	x0, [x0, #24]
     fd8:	52800021 	mov	w1, #0x1                   	// #1
     fdc:	91003000 	add	x0, x0, #0xc
     fe0:	b9000001 	str	w1, [x0]
     fe4:	d50332bf 	dmb	oshst
     fe8:	f9400e80 	ldr	x0, [x20, #24]
     fec:	91001000 	add	x0, x0, #0x4
     ff0:	b9000001 	str	w1, [x0]
     ff4:	b9402a82 	ldr	w2, [x20, #40]
     ff8:	340004c2 	cbz	w2, 1090 <hisi_qm_stop+0xe8>
     ffc:	f9000bb3 	str	x19, [x29, #16]
    1000:	52800015 	mov	w21, #0x0                   	// #0
    1004:	52800013 	mov	w19, #0x0                   	// #0
    1008:	f9405e80 	ldr	x0, [x20, #184]
    100c:	f873d801 	ldr	x1, [x0, w19, sxtw #3]
    1010:	aa0103e0 	mov	x0, x1
    1014:	b40000a1 	cbz	x1, 1028 <hisi_qm_stop+0x80>
    1018:	94000000 	bl	9e0 <hisi_qm_stop_qp>
    101c:	2a0003f5 	mov	w21, w0
    1020:	37f80440 	tbnz	w0, #31, 10a8 <hisi_qm_stop+0x100>
    1024:	b9402a82 	ldr	w2, [x20, #40]
    1028:	11000673 	add	w19, w19, #0x1
    102c:	6b13005f 	cmp	w2, w19
    1030:	54fffec8 	b.hi	1008 <hisi_qm_stop+0x60>  // b.pmore
    1034:	f9400bb3 	ldr	x19, [x29, #16]
    1038:	b9400680 	ldr	w0, [x20, #4]
    103c:	340000e0 	cbz	w0, 1058 <hisi_qm_stop+0xb0>
    1040:	f9400fb4 	ldr	x20, [x29, #24]
    1044:	f94017b6 	ldr	x22, [x29, #40]
    1048:	2a1503e0 	mov	w0, w21
    104c:	f94013f5 	ldr	x21, [sp, #32]
    1050:	a8c37bfd 	ldp	x29, x30, [sp], #48
    1054:	d65f03c0 	ret
    1058:	52800003 	mov	w3, #0x0                   	// #0
    105c:	52800002 	mov	w2, #0x0                   	// #0
    1060:	52800001 	mov	w1, #0x0                   	// #0
    1064:	aa1403e0 	mov	x0, x20
    1068:	94000000 	bl	d48 <hisi_qm_set_vft>
    106c:	2a0003f5 	mov	w21, w0
    1070:	36fffe80 	tbz	w0, #31, 1040 <hisi_qm_stop+0x98>
    1074:	aa1603e0 	mov	x0, x22
    1078:	90000001 	adrp	x1, 0 <__raw_readl>
    107c:	91000021 	add	x1, x1, #0x0
    1080:	94000000 	bl	0 <_dev_err>
    1084:	f9400fb4 	ldr	x20, [x29, #24]
    1088:	f94017b6 	ldr	x22, [x29, #40]
    108c:	17ffffef 	b	1048 <hisi_qm_stop+0xa0>
    1090:	52800015 	mov	w21, #0x0                   	// #0
    1094:	17ffffe9 	b	1038 <hisi_qm_stop+0x90>
    1098:	f94017b6 	ldr	x22, [x29, #40]
    109c:	d4210000 	brk	#0x800
    10a0:	128002b5 	mov	w21, #0xffffffea            	// #-22
    10a4:	17ffffe9 	b	1048 <hisi_qm_stop+0xa0>
    10a8:	2a1303e2 	mov	w2, w19
    10ac:	aa1603e0 	mov	x0, x22
    10b0:	90000001 	adrp	x1, 0 <__raw_readl>
    10b4:	128001f5 	mov	w21, #0xfffffff0            	// #-16
    10b8:	91000021 	add	x1, x1, #0x0
    10bc:	94000000 	bl	0 <_dev_err>
    10c0:	a94153b3 	ldp	x19, x20, [x29, #16]
    10c4:	f94017b6 	ldr	x22, [x29, #40]
    10c8:	17ffffe0 	b	1048 <hisi_qm_stop+0xa0>
    10cc:	d503201f 	nop

00000000000010d0 <qm_irq>:
    10d0:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
    10d4:	910003fd 	mov	x29, sp
    10d8:	f9000bf3 	str	x19, [sp, #16]
    10dc:	aa0103f3 	mov	x19, x1
    10e0:	f9400c20 	ldr	x0, [x1, #24]
    10e4:	91002000 	add	x0, x0, #0x8
    10e8:	b9400000 	ldr	w0, [x0]
    10ec:	d50331bf 	dmb	oshld
    10f0:	2a0003e1 	mov	w1, w0
    10f4:	ca010021 	eor	x1, x1, x1
    10f8:	b5000001 	cbnz	x1, 10f8 <qm_irq+0x28>
    10fc:	34000740 	cbz	w0, 11e4 <qm_irq+0x114>
    1100:	a901d7b4 	stp	x20, x21, [x29, #24]
    1104:	52800015 	mov	w21, #0x0                   	// #0
    1108:	b9409274 	ldr	w20, [x19, #144]
    110c:	f9403260 	ldr	x0, [x19, #96]
    1110:	8b140814 	add	x20, x0, x20, lsl #2
    1114:	d503201f 	nop
    1118:	b9400281 	ldr	w1, [x20]
    111c:	110006b5 	add	w21, w21, #0x1
    1120:	39425262 	ldrb	w2, [x19, #148]
    1124:	52802000 	mov	w0, #0x100                 	// #256
    1128:	92403c23 	and	x3, x1, #0xffff
    112c:	91001294 	add	x20, x20, #0x4
    1130:	d3504021 	ubfx	x1, x1, #16, #1
    1134:	6b02003f 	cmp	w1, w2
    1138:	540003c1 	b.ne	11b0 <qm_irq+0xe0>  // b.any
    113c:	f9405e61 	ldr	x1, [x19, #184]
    1140:	f8637821 	ldr	x1, [x1, x3, lsl #3]
    1144:	9101c022 	add	x2, x1, #0x70
    1148:	b4000061 	cbz	x1, 1154 <qm_irq+0x84>
    114c:	f9404821 	ldr	x1, [x1, #144]
    1150:	94000000 	bl	0 <queue_work_on>
    1154:	b9409260 	ldr	w0, [x19, #144]
    1158:	11000401 	add	w1, w0, #0x1
    115c:	710ffc1f 	cmp	w0, #0x3ff
    1160:	540001c0 	b.eq	1198 <qm_irq+0xc8>  // b.none
    1164:	b9009261 	str	w1, [x19, #144]
    1168:	7107febf 	cmp	w21, #0x1ff
    116c:	52800004 	mov	w4, #0x0                   	// #0
    1170:	54fffd41 	b.ne	1118 <qm_irq+0x48>  // b.any
    1174:	f9407265 	ldr	x5, [x19, #224]
    1178:	52800015 	mov	w21, #0x0                   	// #0
    117c:	79412263 	ldrh	w3, [x19, #144]
    1180:	52800042 	mov	w2, #0x2                   	// #2
    1184:	52800001 	mov	w1, #0x0                   	// #0
    1188:	aa1303e0 	mov	x0, x19
    118c:	f94004a5 	ldr	x5, [x5, #8]
    1190:	d63f00a0 	blr	x5
    1194:	17ffffe1 	b	1118 <qm_irq+0x48>
    1198:	39425260 	ldrb	w0, [x19, #148]
    119c:	f9403274 	ldr	x20, [x19, #96]
    11a0:	52000000 	eor	w0, w0, #0x1
    11a4:	b900927f 	str	wzr, [x19, #144]
    11a8:	39025260 	strb	w0, [x19, #148]
    11ac:	17ffffef 	b	1168 <qm_irq+0x98>
    11b0:	f9407265 	ldr	x5, [x19, #224]
    11b4:	aa1303e0 	mov	x0, x19
    11b8:	79412263 	ldrh	w3, [x19, #144]
    11bc:	52800004 	mov	w4, #0x0                   	// #0
    11c0:	52800042 	mov	w2, #0x2                   	// #2
    11c4:	52800001 	mov	w1, #0x0                   	// #0
    11c8:	f94004a5 	ldr	x5, [x5, #8]
    11cc:	d63f00a0 	blr	x5
    11d0:	a941d7b4 	ldp	x20, x21, [x29, #24]
    11d4:	52800020 	mov	w0, #0x1                   	// #1
    11d8:	f9400bf3 	ldr	x19, [sp, #16]
    11dc:	a8c37bfd 	ldp	x29, x30, [sp], #48
    11e0:	d65f03c0 	ret
    11e4:	f9400a60 	ldr	x0, [x19, #16]
    11e8:	90000001 	adrp	x1, 0 <__raw_readl>
    11ec:	91000021 	add	x1, x1, #0x0
    11f0:	9102c000 	add	x0, x0, #0xb0
    11f4:	94000000 	bl	0 <_dev_err>
    11f8:	f9407265 	ldr	x5, [x19, #224]
    11fc:	aa1303e0 	mov	x0, x19
    1200:	79412263 	ldrh	w3, [x19, #144]
    1204:	52800004 	mov	w4, #0x0                   	// #0
    1208:	52800042 	mov	w2, #0x2                   	// #2
    120c:	52800001 	mov	w1, #0x0                   	// #0
    1210:	f94004a5 	ldr	x5, [x5, #8]
    1214:	d63f00a0 	blr	x5
    1218:	52800000 	mov	w0, #0x0                   	// #0
    121c:	17ffffef 	b	11d8 <qm_irq+0x108>

0000000000001220 <qm_hw_error_handle_v2>:
    1220:	a9bb7bfd 	stp	x29, x30, [sp, #-80]!
    1224:	910003fd 	mov	x29, sp
    1228:	f9000ff4 	str	x20, [sp, #24]
    122c:	f9400c01 	ldr	x1, [x0, #24]
    1230:	91440021 	add	x1, x1, #0x100, lsl #12
    1234:	91002021 	add	x1, x1, #0x8
    1238:	b9400021 	ldr	w1, [x1]
    123c:	d50331bf 	dmb	oshld
    1240:	2a0103e2 	mov	w2, w1
    1244:	ca020042 	eor	x2, x2, x2
    1248:	b5000002 	cbnz	x2, 1248 <qm_hw_error_handle_v2+0x28>
    124c:	b9416014 	ldr	w20, [x0, #352]
    1250:	6a140034 	ands	w20, w1, w20
    1254:	540000a1 	b.ne	1268 <qm_hw_error_handle_v2+0x48>  // b.any
    1258:	528000a0 	mov	w0, #0x5                   	// #5
    125c:	f9400ff4 	ldr	x20, [sp, #24]
    1260:	a8c57bfd 	ldp	x29, x30, [sp], #80
    1264:	d65f03c0 	ret
    1268:	a90363b7 	stp	x23, x24, [x29, #48]
    126c:	aa0003f7 	mov	x23, x0
    1270:	f9000bb3 	str	x19, [x29, #16]
    1274:	90000002 	adrp	x2, 0 <__raw_readl>
    1278:	a9025bb5 	stp	x21, x22, [x29, #32]
    127c:	90000001 	adrp	x1, 0 <__raw_readl>
    1280:	a9046bb9 	stp	x25, x26, [x29, #64]
    1284:	90000019 	adrp	x25, 0 <__raw_readl>
    1288:	d280029a 	mov	x26, #0x14                  	// #20
    128c:	91000333 	add	x19, x25, #0x0
    1290:	f9400ae3 	ldr	x3, [x23, #16]
    1294:	90000000 	adrp	x0, 0 <__raw_readl>
    1298:	91000042 	add	x2, x2, #0x0
    129c:	91000036 	add	x22, x1, #0x0
    12a0:	9102c078 	add	x24, x3, #0xb0
    12a4:	91000015 	add	x21, x0, #0x0
    12a8:	f2a0021a 	movk	x26, #0x10, lsl #16
    12ac:	91098273 	add	x19, x19, #0x260
    12b0:	52800023 	mov	w3, #0x1                   	// #1
    12b4:	14000002 	b	12bc <qm_hw_error_handle_v2+0x9c>
    12b8:	b9400263 	ldr	w3, [x19]
    12bc:	6a03029f 	tst	w20, w3
    12c0:	54000201 	b.ne	1300 <qm_hw_error_handle_v2+0xe0>  // b.any
    12c4:	91004273 	add	x19, x19, #0x10
    12c8:	f9400662 	ldr	x2, [x19, #8]
    12cc:	b5ffff62 	cbnz	x2, 12b8 <qm_hw_error_handle_v2+0x98>
    12d0:	d50332bf 	dmb	oshst
    12d4:	f9400ee0 	ldr	x0, [x23, #24]
    12d8:	91440000 	add	x0, x0, #0x100, lsl #12
    12dc:	b9000014 	str	w20, [x0]
    12e0:	52800060 	mov	w0, #0x3                   	// #3
    12e4:	f9400bb3 	ldr	x19, [x29, #16]
    12e8:	a9425bb5 	ldp	x21, x22, [x29, #32]
    12ec:	a94363b7 	ldp	x23, x24, [x29, #48]
    12f0:	a9446bb9 	ldp	x25, x26, [x29, #64]
    12f4:	f9400ff4 	ldr	x20, [sp, #24]
    12f8:	a8c57bfd 	ldp	x29, x30, [sp], #80
    12fc:	d65f03c0 	ret
    1300:	aa1603e1 	mov	x1, x22
    1304:	aa1803e0 	mov	x0, x24
    1308:	94000000 	bl	0 <_dev_err>
    130c:	37500374 	tbnz	w20, #10, 1378 <qm_hw_error_handle_v2+0x158>
    1310:	365ffdb4 	tbz	w20, #11, 12c4 <qm_hw_error_handle_v2+0xa4>
    1314:	f9400ee0 	ldr	x0, [x23, #24]
    1318:	91440000 	add	x0, x0, #0x100, lsl #12
    131c:	91004000 	add	x0, x0, #0x10
    1320:	97fffb38 	bl	0 <__raw_readl>
    1324:	d50331bf 	dmb	oshld
    1328:	2a0003e1 	mov	w1, w0
    132c:	ca010021 	eor	x1, x1, x1
    1330:	b5000001 	cbnz	x1, 1330 <qm_hw_error_handle_v2+0x110>
    1334:	d3461c01 	ubfx	x1, x0, #6, #2
    1338:	91000322 	add	x2, x25, #0x0
    133c:	12001403 	and	w3, w0, #0x3f
    1340:	910d8042 	add	x2, x2, #0x360
    1344:	2a0103e0 	mov	w0, w1
    1348:	71000c3f 	cmp	w1, #0x3
    134c:	540000e0 	b.eq	1368 <qm_hw_error_handle_v2+0x148>  // b.none
    1350:	f8607842 	ldr	x2, [x2, x0, lsl #3]
    1354:	90000001 	adrp	x1, 0 <__raw_readl>
    1358:	aa1803e0 	mov	x0, x24
    135c:	91000021 	add	x1, x1, #0x0
    1360:	94000000 	bl	0 <_dev_err>
    1364:	17ffffd8 	b	12c4 <qm_hw_error_handle_v2+0xa4>
    1368:	aa1503e1 	mov	x1, x21
    136c:	aa1803e0 	mov	x0, x24
    1370:	94000000 	bl	0 <_dev_err>
    1374:	17ffffd4 	b	12c4 <qm_hw_error_handle_v2+0xa4>
    1378:	f9400ee0 	ldr	x0, [x23, #24]
    137c:	8b1a0000 	add	x0, x0, x26
    1380:	97fffb20 	bl	0 <__raw_readl>
    1384:	d50331bf 	dmb	oshld
    1388:	2a0003e1 	mov	w1, w0
    138c:	ca010021 	eor	x1, x1, x1
    1390:	b5000001 	cbnz	x1, 1390 <qm_hw_error_handle_v2+0x170>
    1394:	91000322 	add	x2, x25, #0x0
    1398:	d3461c04 	ubfx	x4, x0, #6, #2
    139c:	910d0042 	add	x2, x2, #0x340
    13a0:	12001403 	and	w3, w0, #0x3f
    13a4:	90000001 	adrp	x1, 0 <__raw_readl>
    13a8:	aa1803e0 	mov	x0, x24
    13ac:	91000021 	add	x1, x1, #0x0
    13b0:	f8647842 	ldr	x2, [x2, x4, lsl #3]
    13b4:	94000000 	bl	0 <_dev_err>
    13b8:	17ffffd6 	b	1310 <qm_hw_error_handle_v2+0xf0>
    13bc:	d503201f 	nop

00000000000013c0 <qm_abnormal_irq>:
    13c0:	a9bc7bfd 	stp	x29, x30, [sp, #-64]!
    13c4:	910003fd 	mov	x29, sp
    13c8:	a90153f3 	stp	x19, x20, [sp, #16]
    13cc:	a9025bf5 	stp	x21, x22, [sp, #32]
    13d0:	aa0103f5 	mov	x21, x1
    13d4:	f9001bf7 	str	x23, [sp, #48]
    13d8:	a9415020 	ldp	x0, x20, [x1, #16]
    13dc:	91440294 	add	x20, x20, #0x100, lsl #12
    13e0:	9102c017 	add	x23, x0, #0xb0
    13e4:	91002294 	add	x20, x20, #0x8
    13e8:	b9400294 	ldr	w20, [x20]
    13ec:	d50331bf 	dmb	oshld
    13f0:	2a1403e0 	mov	w0, w20
    13f4:	ca000000 	eor	x0, x0, x0
    13f8:	b5000000 	cbnz	x0, 13f8 <qm_abnormal_irq+0x38>
    13fc:	b9416421 	ldr	w1, [x1, #356]
    1400:	90000013 	adrp	x19, 0 <__raw_readl>
    1404:	91000273 	add	x19, x19, #0x0
    1408:	90000002 	adrp	x2, 0 <__raw_readl>
    140c:	90000000 	adrp	x0, 0 <__raw_readl>
    1410:	91098273 	add	x19, x19, #0x260
    1414:	91000042 	add	x2, x2, #0x0
    1418:	91000016 	add	x22, x0, #0x0
    141c:	52800023 	mov	w3, #0x1                   	// #1
    1420:	0a010294 	and	w20, w20, w1
    1424:	14000002 	b	142c <qm_abnormal_irq+0x6c>
    1428:	b9400263 	ldr	w3, [x19]
    142c:	91004273 	add	x19, x19, #0x10
    1430:	6a14007f 	tst	w3, w20
    1434:	540001a1 	b.ne	1468 <qm_abnormal_irq+0xa8>  // b.any
    1438:	f9400662 	ldr	x2, [x19, #8]
    143c:	b5ffff62 	cbnz	x2, 1428 <qm_abnormal_irq+0x68>
    1440:	d50332bf 	dmb	oshst
    1444:	f9400ea0 	ldr	x0, [x21, #24]
    1448:	91440000 	add	x0, x0, #0x100, lsl #12
    144c:	b9000014 	str	w20, [x0]
    1450:	52800020 	mov	w0, #0x1                   	// #1
    1454:	f9401bf7 	ldr	x23, [sp, #48]
    1458:	a94153f3 	ldp	x19, x20, [sp, #16]
    145c:	a9425bf5 	ldp	x21, x22, [sp, #32]
    1460:	a8c47bfd 	ldp	x29, x30, [sp], #64
    1464:	d65f03c0 	ret
    1468:	aa1603e1 	mov	x1, x22
    146c:	aa1703e0 	mov	x0, x23
    1470:	94000000 	bl	0 <_dev_err>
    1474:	17fffff1 	b	1438 <qm_abnormal_irq+0x78>

0000000000001478 <qm_hw_error_init_v2>:
    1478:	2a030046 	orr	w6, w2, w3
    147c:	b9016404 	str	w4, [x0, #356]
    1480:	2a0100c6 	orr	w6, w6, w1
    1484:	b9016006 	str	w6, [x0, #352]
    1488:	2a0400c5 	orr	w5, w6, w4
    148c:	2a2503e5 	mvn	w5, w5
    1490:	d50332bf 	dmb	oshst
    1494:	f9400c06 	ldr	x6, [x0, #24]
    1498:	914400c6 	add	x6, x6, #0x100, lsl #12
    149c:	9103b0c6 	add	x6, x6, #0xec
    14a0:	b90000c1 	str	w1, [x6]
    14a4:	d50332bf 	dmb	oshst
    14a8:	f9400c01 	ldr	x1, [x0, #24]
    14ac:	52800026 	mov	w6, #0x1                   	// #1
    14b0:	91440021 	add	x1, x1, #0x100, lsl #12
    14b4:	9103e021 	add	x1, x1, #0xf8
    14b8:	b9000026 	str	w6, [x1]
    14bc:	d50332bf 	dmb	oshst
    14c0:	f9400c01 	ldr	x1, [x0, #24]
    14c4:	91440021 	add	x1, x1, #0x100, lsl #12
    14c8:	9103d021 	add	x1, x1, #0xf4
    14cc:	b9000022 	str	w2, [x1]
    14d0:	d50332bf 	dmb	oshst
    14d4:	f9400c01 	ldr	x1, [x0, #24]
    14d8:	91440021 	add	x1, x1, #0x100, lsl #12
    14dc:	9103c021 	add	x1, x1, #0xf0
    14e0:	b9000023 	str	w3, [x1]
    14e4:	d50332bf 	dmb	oshst
    14e8:	f9400c01 	ldr	x1, [x0, #24]
    14ec:	91441022 	add	x2, x1, #0x104, lsl #12
    14f0:	9103d042 	add	x2, x2, #0xf4
    14f4:	b9000044 	str	w4, [x2]
    14f8:	d2800082 	mov	x2, #0x4                   	// #4
    14fc:	f2a00202 	movk	x2, #0x10, lsl #16
    1500:	8b020021 	add	x1, x1, x2
    1504:	b9400021 	ldr	w1, [x1]
    1508:	d50331bf 	dmb	oshld
    150c:	2a0103e3 	mov	w3, w1
    1510:	ca030063 	eor	x3, x3, x3
    1514:	b5000003 	cbnz	x3, 1514 <qm_hw_error_init_v2+0x9c>
    1518:	d50332bf 	dmb	oshst
    151c:	f9400c00 	ldr	x0, [x0, #24]
    1520:	0a0100a1 	and	w1, w5, w1
    1524:	8b020000 	add	x0, x0, x2
    1528:	b9000001 	str	w1, [x0]
    152c:	d65f03c0 	ret

0000000000001530 <qm_aeq_irq>:
    1530:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
    1534:	910003fd 	mov	x29, sp
    1538:	b9409823 	ldr	w3, [x1, #152]
    153c:	f9400c22 	ldr	x2, [x1, #24]
    1540:	f9403424 	ldr	x4, [x1, #104]
    1544:	b9400042 	ldr	w2, [x2]
    1548:	d50331bf 	dmb	oshld
    154c:	2a0203e0 	mov	w0, w2
    1550:	ca000000 	eor	x0, x0, x0
    1554:	b5000000 	cbnz	x0, 1554 <qm_aeq_irq+0x24>
    1558:	52800000 	mov	w0, #0x0                   	// #0
    155c:	34000842 	cbz	w2, 1664 <qm_aeq_irq+0x134>
    1560:	2a0303e0 	mov	w0, w3
    1564:	f9000fb4 	str	x20, [x29, #24]
    1568:	39427023 	ldrb	w3, [x1, #156]
    156c:	8b000894 	add	x20, x4, x0, lsl #2
    1570:	b8607882 	ldr	w2, [x4, x0, lsl #2]
    1574:	d3504040 	ubfx	x0, x2, #16, #1
    1578:	6b03001f 	cmp	w0, w3
    157c:	54000701 	b.ne	165c <qm_aeq_irq+0x12c>  // b.any
    1580:	a9025bb5 	stp	x21, x22, [x29, #32]
    1584:	90000015 	adrp	x21, 0 <__raw_readl>
    1588:	910002b5 	add	x21, x21, #0x0
    158c:	90000016 	adrp	x22, 0 <__raw_readl>
    1590:	f9000bb3 	str	x19, [x29, #16]
    1594:	910d82b5 	add	x21, x21, #0x360
    1598:	910002d6 	add	x22, x22, #0x0
    159c:	aa0103f3 	mov	x19, x1
    15a0:	14000017 	b	15fc <qm_aeq_irq+0xcc>
    15a4:	f8637aa2 	ldr	x2, [x21, x3, lsl #3]
    15a8:	91000021 	add	x1, x1, #0x0
    15ac:	91001294 	add	x20, x20, #0x4
    15b0:	94000000 	bl	0 <_dev_err>
    15b4:	b9409a60 	ldr	w0, [x19, #152]
    15b8:	11000401 	add	w1, w0, #0x1
    15bc:	710ffc1f 	cmp	w0, #0x3ff
    15c0:	12003c23 	and	w3, w1, #0xffff
    15c4:	540003a0 	b.eq	1638 <qm_aeq_irq+0x108>  // b.none
    15c8:	b9009a61 	str	w1, [x19, #152]
    15cc:	f9407265 	ldr	x5, [x19, #224]
    15d0:	52800062 	mov	w2, #0x3                   	// #3
    15d4:	52800001 	mov	w1, #0x0                   	// #0
    15d8:	aa1303e0 	mov	x0, x19
    15dc:	52800004 	mov	w4, #0x0                   	// #0
    15e0:	f94004a5 	ldr	x5, [x5, #8]
    15e4:	d63f00a0 	blr	x5
    15e8:	b9400282 	ldr	w2, [x20]
    15ec:	39427260 	ldrb	w0, [x19, #156]
    15f0:	d3504041 	ubfx	x1, x2, #16, #1
    15f4:	6b00003f 	cmp	w1, w0
    15f8:	540002e1 	b.ne	1654 <qm_aeq_irq+0x124>  // b.any
    15fc:	f9400a60 	ldr	x0, [x19, #16]
    1600:	53117c43 	lsr	w3, w2, #17
    1604:	aa0303e2 	mov	x2, x3
    1608:	7100087f 	cmp	w3, #0x2
    160c:	90000001 	adrp	x1, 0 <__raw_readl>
    1610:	9102c000 	add	x0, x0, #0xb0
    1614:	54fffc89 	b.ls	15a4 <qm_aeq_irq+0x74>  // b.plast
    1618:	aa1603e1 	mov	x1, x22
    161c:	94000000 	bl	0 <_dev_err>
    1620:	b9409a60 	ldr	w0, [x19, #152]
    1624:	91001294 	add	x20, x20, #0x4
    1628:	11000401 	add	w1, w0, #0x1
    162c:	710ffc1f 	cmp	w0, #0x3ff
    1630:	12003c23 	and	w3, w1, #0xffff
    1634:	54fffca1 	b.ne	15c8 <qm_aeq_irq+0x98>  // b.any
    1638:	39427260 	ldrb	w0, [x19, #156]
    163c:	52800003 	mov	w3, #0x0                   	// #0
    1640:	f9403674 	ldr	x20, [x19, #104]
    1644:	52000000 	eor	w0, w0, #0x1
    1648:	b9009a7f 	str	wzr, [x19, #152]
    164c:	39027260 	strb	w0, [x19, #156]
    1650:	17ffffdf 	b	15cc <qm_aeq_irq+0x9c>
    1654:	f9400bb3 	ldr	x19, [x29, #16]
    1658:	a9425bb5 	ldp	x21, x22, [x29, #32]
    165c:	52800020 	mov	w0, #0x1                   	// #1
    1660:	f9400fb4 	ldr	x20, [x29, #24]
    1664:	a8c37bfd 	ldp	x29, x30, [sp], #48
    1668:	d65f03c0 	ret
    166c:	d503201f 	nop

0000000000001670 <qm_wait_mb_ready.isra.21>:
    1670:	a9be7bfd 	stp	x29, x30, [sp, #-32]!
    1674:	910003fd 	mov	x29, sp
    1678:	a90153f3 	stp	x19, x20, [sp, #16]
    167c:	aa0003f3 	mov	x19, x0
    1680:	94000000 	bl	0 <ktime_get>
    1684:	9143d014 	add	x20, x0, #0xf4, lsl #12
    1688:	91090294 	add	x20, x20, #0x240
    168c:	14000007 	b	16a8 <qm_wait_mb_ready.isra.21+0x38>
    1690:	94000000 	bl	0 <ktime_get>
    1694:	eb00029f 	cmp	x20, x0
    1698:	5400018b 	b.lt	16c8 <qm_wait_mb_ready.isra.21+0x58>  // b.tstop
    169c:	d2800141 	mov	x1, #0xa                   	// #10
    16a0:	d2800060 	mov	x0, #0x3                   	// #3
    16a4:	94000000 	bl	0 <usleep_range>
    16a8:	f9400260 	ldr	x0, [x19]
    16ac:	910c0000 	add	x0, x0, #0x300
    16b0:	b9400000 	ldr	w0, [x0]
    16b4:	376ffee0 	tbnz	w0, #13, 1690 <qm_wait_mb_ready.isra.21+0x20>
    16b8:	52800000 	mov	w0, #0x0                   	// #0
    16bc:	a94153f3 	ldp	x19, x20, [sp, #16]
    16c0:	a8c27bfd 	ldp	x29, x30, [sp], #32
    16c4:	d65f03c0 	ret
    16c8:	f9400260 	ldr	x0, [x19]
    16cc:	910c0000 	add	x0, x0, #0x300
    16d0:	b9400000 	ldr	w0, [x0]
    16d4:	366fff20 	tbz	w0, #13, 16b8 <qm_wait_mb_ready.isra.21+0x48>
    16d8:	12800da0 	mov	w0, #0xffffff92            	// #-110
    16dc:	17fffff8 	b	16bc <qm_wait_mb_ready.isra.21+0x4c>

00000000000016e0 <qm_mb>:
    16e0:	a9bb7bfd 	stp	x29, x30, [sp, #-80]!
    16e4:	72001c9f 	tst	w4, #0xff
    16e8:	12001c21 	and	w1, w1, #0xff
    16ec:	d360fc44 	lsr	x4, x2, #32
    16f0:	910003fd 	mov	x29, sp
    16f4:	a90153f3 	stp	x19, x20, [sp, #16]
    16f8:	aa0003f4 	mov	x20, x0
    16fc:	a9025bf5 	stp	x21, x22, [sp, #32]
    1700:	1a9f07e0 	cset	w0, ne  // ne = any
    1704:	32130021 	orr	w1, w1, #0x2000
    1708:	90000013 	adrp	x19, 0 <__stack_chk_guard>
    170c:	91000265 	add	x5, x19, #0x0
    1710:	2a003821 	orr	w1, w1, w0, lsl #14
    1714:	f94000a6 	ldr	x6, [x5]
    1718:	f90027a6 	str	x6, [x29, #72]
    171c:	d2800006 	mov	x6, #0x0                   	// #0
    1720:	91030295 	add	x21, x20, #0xc0
    1724:	aa1503e0 	mov	x0, x21
    1728:	790073a1 	strh	w1, [x29, #56]
    172c:	790077a3 	strh	w3, [x29, #58]
    1730:	91006296 	add	x22, x20, #0x18
    1734:	290793a2 	stp	w2, w4, [x29, #60]
    1738:	b90047bf 	str	wzr, [x29, #68]
    173c:	94000000 	bl	0 <mutex_lock>
    1740:	aa1603e0 	mov	x0, x22
    1744:	97ffffcb 	bl	1670 <qm_wait_mb_ready.isra.21>
    1748:	350002e0 	cbnz	w0, 17a4 <qm_mb+0xc4>
    174c:	f9400e80 	ldr	x0, [x20, #24]
    1750:	9100e3a3 	add	x3, x29, #0x38
    1754:	910c0000 	add	x0, x0, #0x300
    1758:	a9400861 	ldp	x1, x2, [x3]
    175c:	a9000801 	stp	x1, x2, [x0]
    1760:	d5033f9f 	dsb	sy
    1764:	aa1603e0 	mov	x0, x22
    1768:	97ffffc2 	bl	1670 <qm_wait_mb_ready.isra.21>
    176c:	2a0003f6 	mov	w22, w0
    1770:	35000280 	cbnz	w0, 17c0 <qm_mb+0xe0>
    1774:	aa1503e0 	mov	x0, x21
    1778:	91000273 	add	x19, x19, #0x0
    177c:	94000000 	bl	0 <mutex_unlock>
    1780:	2a1603e0 	mov	w0, w22
    1784:	f94027a2 	ldr	x2, [x29, #72]
    1788:	f9400261 	ldr	x1, [x19]
    178c:	ca010041 	eor	x1, x2, x1
    1790:	b5000261 	cbnz	x1, 17dc <qm_mb+0xfc>
    1794:	a94153f3 	ldp	x19, x20, [sp, #16]
    1798:	a9425bf5 	ldp	x21, x22, [sp, #32]
    179c:	a8c57bfd 	ldp	x29, x30, [sp], #80
    17a0:	d65f03c0 	ret
    17a4:	f9400a80 	ldr	x0, [x20, #16]
    17a8:	90000001 	adrp	x1, 0 <__raw_readl>
    17ac:	128001f6 	mov	w22, #0xfffffff0            	// #-16
    17b0:	91000021 	add	x1, x1, #0x0
    17b4:	9102c000 	add	x0, x0, #0xb0
    17b8:	94000000 	bl	0 <_dev_err>
    17bc:	17ffffee 	b	1774 <qm_mb+0x94>
    17c0:	f9400a80 	ldr	x0, [x20, #16]
    17c4:	128001f6 	mov	w22, #0xfffffff0            	// #-16
    17c8:	90000001 	adrp	x1, 0 <__raw_readl>
    17cc:	91000021 	add	x1, x1, #0x0
    17d0:	9102c000 	add	x0, x0, #0xb0
    17d4:	94000000 	bl	0 <_dev_err>
    17d8:	17ffffe7 	b	1774 <qm_mb+0x94>
    17dc:	94000000 	bl	0 <__stack_chk_fail>

00000000000017e0 <qm_get_vft_v2>:
    17e0:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
    17e4:	52800024 	mov	w4, #0x1                   	// #1
    17e8:	52800003 	mov	w3, #0x0                   	// #0
    17ec:	910003fd 	mov	x29, sp
    17f0:	a90153f3 	stp	x19, x20, [sp, #16]
    17f4:	aa0103f4 	mov	x20, x1
    17f8:	f90013f5 	str	x21, [sp, #32]
    17fc:	aa0203f3 	mov	x19, x2
    1800:	528000c1 	mov	w1, #0x6                   	// #6
    1804:	d2800002 	mov	x2, #0x0                   	// #0
    1808:	aa0003f5 	mov	x21, x0
    180c:	97ffffb5 	bl	16e0 <qm_mb>
    1810:	350002a0 	cbnz	w0, 1864 <qm_get_vft_v2+0x84>
    1814:	f9400ea1 	ldr	x1, [x21, #24]
    1818:	910c1021 	add	x1, x1, #0x304
    181c:	b9400021 	ldr	w1, [x1]
    1820:	d50331bf 	dmb	oshld
    1824:	2a0103e2 	mov	w2, w1
    1828:	ca020041 	eor	x1, x2, x2
    182c:	b5000001 	cbnz	x1, 182c <qm_get_vft_v2+0x4c>
    1830:	f9400ea1 	ldr	x1, [x21, #24]
    1834:	910c2021 	add	x1, x1, #0x308
    1838:	b9400021 	ldr	w1, [x1]
    183c:	d50331bf 	dmb	oshld
    1840:	2a0103e1 	mov	w1, w1
    1844:	ca010023 	eor	x3, x1, x1
    1848:	b5000003 	cbnz	x3, 1848 <qm_get_vft_v2+0x68>
    184c:	aa018041 	orr	x1, x2, x1, lsl #32
    1850:	d35c8422 	ubfx	x2, x1, #28, #6
    1854:	d36dd821 	ubfx	x1, x1, #45, #10
    1858:	b9000282 	str	w2, [x20]
    185c:	11000421 	add	w1, w1, #0x1
    1860:	b9000261 	str	w1, [x19]
    1864:	a94153f3 	ldp	x19, x20, [sp, #16]
    1868:	f94013f5 	ldr	x21, [sp, #32]
    186c:	a8c37bfd 	ldp	x29, x30, [sp], #48
    1870:	d65f03c0 	ret
    1874:	d503201f 	nop

0000000000001878 <hisi_qm_start_qp>:
    1878:	a9b97bfd 	stp	x29, x30, [sp, #-112]!
    187c:	910003fd 	mov	x29, sp
    1880:	f9000ff4 	str	x20, [sp, #24]
    1884:	f9001ff8 	str	x24, [sp, #56]
    1888:	f9002ffc 	str	x28, [sp, #88]
    188c:	aa0003fc 	mov	x28, x0
    1890:	f9404c14 	ldr	x20, [x0, #152]
    1894:	f9400802 	ldr	x2, [x0, #16]
    1898:	b9400000 	ldr	w0, [x0]
    189c:	b9006fa0 	str	w0, [x29, #108]
    18a0:	f9400a80 	ldr	x0, [x20, #16]
    18a4:	9102c000 	add	x0, x0, #0xb0
    18a8:	b4002402 	cbz	x2, 1d28 <hisi_qm_start_qp+0x4b0>
    18ac:	f240185f 	tst	x2, #0x7f
    18b0:	54002321 	b.ne	1d14 <hisi_qm_start_qp+0x49c>  // b.any
    18b4:	f9000bb3 	str	x19, [x29, #16]
    18b8:	52800038 	mov	w24, #0x1                   	// #1
    18bc:	a9025bb5 	stp	x21, x22, [x29, #32]
    18c0:	aa0103f6 	mov	x22, x1
    18c4:	f9001bb7 	str	x23, [x29, #48]
    18c8:	5281b801 	mov	w1, #0xdc0                 	// #3520
    18cc:	f90023b9 	str	x25, [x29, #64]
    18d0:	f9002bbb 	str	x27, [x29, #80]
    18d4:	9000001b 	adrp	x27, 0 <kmalloc_caches>
    18d8:	f9001b82 	str	x2, [x28, #48]
    18dc:	91000365 	add	x5, x27, #0x0
    18e0:	f9400783 	ldr	x3, [x28, #8]
    18e4:	f9001383 	str	x3, [x28, #32]
    18e8:	b9402284 	ldr	w4, [x20, #32]
    18ec:	53165484 	lsl	w4, w4, #10
    18f0:	8b040063 	add	x3, x3, x4
    18f4:	8b040042 	add	x2, x2, x4
    18f8:	f9001783 	str	x3, [x28, #40]
    18fc:	f9001f82 	str	x2, [x28, #56]
    1900:	f9400a95 	ldr	x21, [x20, #16]
    1904:	b9400299 	ldr	w25, [x20]
    1908:	b900479f 	str	wzr, [x28, #68]
    190c:	9102c2b7 	add	x23, x21, #0xb0
    1910:	39012398 	strb	w24, [x28, #72]
    1914:	f9002b9f 	str	xzr, [x28, #80]
    1918:	f9401ca0 	ldr	x0, [x5, #56]
    191c:	94000000 	bl	0 <kmem_cache_alloc>
    1920:	aa0003f3 	mov	x19, x0
    1924:	b4001ba0 	cbz	x0, 1c98 <hisi_qm_start_qp+0x420>
    1928:	94000000 	bl	0 <is_vmalloc_addr>
    192c:	72001c1f 	tst	w0, #0xff
    1930:	540018a1 	b.ne	1c44 <hisi_qm_start_qp+0x3cc>  // b.any
    1934:	f90027ba 	str	x26, [x29, #72]
    1938:	d2e00021 	mov	x1, #0x1000000000000       	// #281474976710656
    193c:	8b010261 	add	x1, x19, x1
    1940:	b26babe3 	mov	x3, #0xffffffffffe00000    	// #-2097152
    1944:	f9417aa0 	ldr	x0, [x21, #752]
    1948:	f2dfbfe3 	movk	x3, #0xfdff, lsl #32
    194c:	d34cfc21 	lsr	x1, x1, #12
    1950:	92402e62 	and	x2, x19, #0xfff
    1954:	8b011861 	add	x1, x3, x1, lsl #6
    1958:	b4000c40 	cbz	x0, 1ae0 <hisi_qm_start_qp+0x268>
    195c:	f9401007 	ldr	x7, [x0, #32]
    1960:	d2800005 	mov	x5, #0x0                   	// #0
    1964:	52800024 	mov	w4, #0x1                   	// #1
    1968:	d2800403 	mov	x3, #0x20                  	// #32
    196c:	aa1703e0 	mov	x0, x23
    1970:	d63f00e0 	blr	x7
    1974:	aa0003e7 	mov	x7, x0
    1978:	b10004ff 	cmn	x7, #0x1
    197c:	54001c40 	b.eq	1d04 <hisi_qm_start_qp+0x48c>  // b.none
    1980:	f9401b80 	ldr	x0, [x28, #48]
    1984:	12003ed6 	and	w22, w22, #0xffff
    1988:	2900027f 	stp	wzr, w0, [x19]
    198c:	7100833f 	cmp	w25, #0x20
    1990:	f800c27f 	stur	xzr, [x19, #12]
    1994:	d360fc00 	lsr	x0, x0, #32
    1998:	b9000a60 	str	w0, [x19, #8]
    199c:	79002a76 	strh	w22, [x19, #20]
    19a0:	79002e7f 	strh	wzr, [x19, #22]
    19a4:	b9001e7f 	str	wzr, [x19, #28]
    19a8:	54000aa0 	b.eq	1afc <hisi_qm_start_qp+0x284>  // b.none
    19ac:	7100873f 	cmp	w25, #0x21
    19b0:	540011c0 	b.eq	1be8 <hisi_qm_start_qp+0x370>  // b.none
    19b4:	39401385 	ldrb	w5, [x28, #4]
    19b8:	aa0703e2 	mov	x2, x7
    19bc:	7940dbba 	ldrh	w26, [x29, #108]
    19c0:	52800004 	mov	w4, #0x0                   	// #0
    19c4:	7900327a 	strh	w26, [x19, #24]
    19c8:	52800001 	mov	w1, #0x0                   	// #0
    19cc:	53180ca5 	ubfiz	w5, w5, #8, #4
    19d0:	f90033a7 	str	x7, [x29, #96]
    19d4:	321c00a5 	orr	w5, w5, #0x10
    19d8:	79003665 	strh	w5, [x19, #26]
    19dc:	2a1a03e3 	mov	w3, w26
    19e0:	aa1403e0 	mov	x0, x20
    19e4:	97ffff3f 	bl	16e0 <qm_mb>
    19e8:	2a0003f8 	mov	w24, w0
    19ec:	f9417aa0 	ldr	x0, [x21, #752]
    19f0:	f94033a7 	ldr	x7, [x29, #96]
    19f4:	b4000300 	cbz	x0, 1a54 <hisi_qm_start_qp+0x1dc>
    19f8:	f9401405 	ldr	x5, [x0, #40]
    19fc:	b40000e5 	cbz	x5, 1a18 <hisi_qm_start_qp+0x1a0>
    1a00:	d2800004 	mov	x4, #0x0                   	// #0
    1a04:	52800023 	mov	w3, #0x1                   	// #1
    1a08:	d2800402 	mov	x2, #0x20                  	// #32
    1a0c:	aa0703e1 	mov	x1, x7
    1a10:	aa1703e0 	mov	x0, x23
    1a14:	d63f00a0 	blr	x5
    1a18:	aa1303e0 	mov	x0, x19
    1a1c:	94000000 	bl	0 <kfree>
    1a20:	340002d8 	cbz	w24, 1a78 <hisi_qm_start_qp+0x200>
    1a24:	d503201f 	nop
    1a28:	f9400bb3 	ldr	x19, [x29, #16]
    1a2c:	a9425bb5 	ldp	x21, x22, [x29, #32]
    1a30:	f9401bb7 	ldr	x23, [x29, #48]
    1a34:	a9446bb9 	ldp	x25, x26, [x29, #64]
    1a38:	f9402bbb 	ldr	x27, [x29, #80]
    1a3c:	2a1803e0 	mov	w0, w24
    1a40:	f9400ff4 	ldr	x20, [sp, #24]
    1a44:	f9401ff8 	ldr	x24, [sp, #56]
    1a48:	f9402ffc 	ldr	x28, [sp, #88]
    1a4c:	a8c77bfd 	ldp	x29, x30, [sp], #112
    1a50:	d65f03c0 	ret
    1a54:	aa0703e1 	mov	x1, x7
    1a58:	d2800004 	mov	x4, #0x0                   	// #0
    1a5c:	52800023 	mov	w3, #0x1                   	// #1
    1a60:	d2800402 	mov	x2, #0x20                  	// #32
    1a64:	aa1703e0 	mov	x0, x23
    1a68:	94000000 	bl	0 <dma_direct_unmap_page>
    1a6c:	aa1303e0 	mov	x0, x19
    1a70:	94000000 	bl	0 <kfree>
    1a74:	35fffdb8 	cbnz	w24, 1a28 <hisi_qm_start_qp+0x1b0>
    1a78:	9100037b 	add	x27, x27, #0x0
    1a7c:	5281b801 	mov	w1, #0xdc0                 	// #3520
    1a80:	f9401f60 	ldr	x0, [x27, #56]
    1a84:	94000000 	bl	0 <kmem_cache_alloc>
    1a88:	aa0003f3 	mov	x19, x0
    1a8c:	b4001040 	cbz	x0, 1c94 <hisi_qm_start_qp+0x41c>
    1a90:	94000000 	bl	0 <is_vmalloc_addr>
    1a94:	72001c1f 	tst	w0, #0xff
    1a98:	54000f01 	b.ne	1c78 <hisi_qm_start_qp+0x400>  // b.any
    1a9c:	d2e00021 	mov	x1, #0x1000000000000       	// #281474976710656
    1aa0:	f9417aa0 	ldr	x0, [x21, #752]
    1aa4:	8b010261 	add	x1, x19, x1
    1aa8:	b26babe3 	mov	x3, #0xffffffffffe00000    	// #-2097152
    1aac:	f2dfbfe3 	movk	x3, #0xfdff, lsl #32
    1ab0:	92402e62 	and	x2, x19, #0xfff
    1ab4:	d34cfc21 	lsr	x1, x1, #12
    1ab8:	8b011861 	add	x1, x3, x1, lsl #6
    1abc:	b4000380 	cbz	x0, 1b2c <hisi_qm_start_qp+0x2b4>
    1ac0:	f9401007 	ldr	x7, [x0, #32]
    1ac4:	d2800005 	mov	x5, #0x0                   	// #0
    1ac8:	52800024 	mov	w4, #0x1                   	// #1
    1acc:	d2800403 	mov	x3, #0x20                  	// #32
    1ad0:	aa1703e0 	mov	x0, x23
    1ad4:	d63f00e0 	blr	x7
    1ad8:	aa0003fb 	mov	x27, x0
    1adc:	1400001a 	b	1b44 <hisi_qm_start_qp+0x2cc>
    1ae0:	d2800005 	mov	x5, #0x0                   	// #0
    1ae4:	52800024 	mov	w4, #0x1                   	// #1
    1ae8:	d2800403 	mov	x3, #0x20                  	// #32
    1aec:	aa1703e0 	mov	x0, x23
    1af0:	94000000 	bl	0 <dma_direct_map_page>
    1af4:	aa0003e7 	mov	x7, x0
    1af8:	17ffffa0 	b	1978 <hisi_qm_start_qp+0x100>
    1afc:	b9402281 	ldr	w1, [x20, #32]
    1b00:	52807fe0 	mov	w0, #0x3ff                 	// #1023
    1b04:	79002260 	strh	w0, [x19, #16]
    1b08:	1281ffe2 	mov	w2, #0xfffff000            	// #-4096
    1b0c:	5ac01020 	clz	w0, w1
    1b10:	7100003f 	cmp	w1, #0x0
    1b14:	4b000320 	sub	w0, w25, w0
    1b18:	51000400 	sub	w0, w0, #0x1
    1b1c:	53144c00 	lsl	w0, w0, #12
    1b20:	1a821000 	csel	w0, w0, w2, ne  // ne = any
    1b24:	b9000e60 	str	w0, [x19, #12]
    1b28:	17ffffa3 	b	19b4 <hisi_qm_start_qp+0x13c>
    1b2c:	d2800005 	mov	x5, #0x0                   	// #0
    1b30:	52800024 	mov	w4, #0x1                   	// #1
    1b34:	d2800403 	mov	x3, #0x20                  	// #32
    1b38:	aa1703e0 	mov	x0, x23
    1b3c:	94000000 	bl	0 <dma_direct_map_page>
    1b40:	aa0003fb 	mov	x27, x0
    1b44:	b100077f 	cmn	x27, #0x1
    1b48:	540009e0 	b.eq	1c84 <hisi_qm_start_qp+0x40c>  // b.none
    1b4c:	f9401f80 	ldr	x0, [x28, #56]
    1b50:	7100833f 	cmp	w25, #0x20
    1b54:	2900027f 	stp	wzr, w0, [x19]
    1b58:	f800c27f 	stur	xzr, [x19, #12]
    1b5c:	d360fc00 	lsr	x0, x0, #32
    1b60:	b9000a60 	str	w0, [x19, #8]
    1b64:	79002a76 	strh	w22, [x19, #20]
    1b68:	79002e7f 	strh	wzr, [x19, #22]
    1b6c:	b9001e7f 	str	wzr, [x19, #28]
    1b70:	54000520 	b.eq	1c14 <hisi_qm_start_qp+0x39c>  // b.none
    1b74:	7100873f 	cmp	w25, #0x21
    1b78:	54000061 	b.ne	1b84 <hisi_qm_start_qp+0x30c>  // b.any
    1b7c:	52887fe0 	mov	w0, #0x43ff                	// #17407
    1b80:	b9000e60 	str	w0, [x19, #12]
    1b84:	52800060 	mov	w0, #0x3                   	// #3
    1b88:	b9001a60 	str	w0, [x19, #24]
    1b8c:	52800004 	mov	w4, #0x0                   	// #0
    1b90:	2a1a03e3 	mov	w3, w26
    1b94:	aa1b03e2 	mov	x2, x27
    1b98:	52800021 	mov	w1, #0x1                   	// #1
    1b9c:	aa1403e0 	mov	x0, x20
    1ba0:	97fffed0 	bl	16e0 <qm_mb>
    1ba4:	2a0003f8 	mov	w24, w0
    1ba8:	f9417aa0 	ldr	x0, [x21, #752]
    1bac:	b40003e0 	cbz	x0, 1c28 <hisi_qm_start_qp+0x3b0>
    1bb0:	f9401405 	ldr	x5, [x0, #40]
    1bb4:	b40000e5 	cbz	x5, 1bd0 <hisi_qm_start_qp+0x358>
    1bb8:	d2800004 	mov	x4, #0x0                   	// #0
    1bbc:	52800023 	mov	w3, #0x1                   	// #1
    1bc0:	d2800402 	mov	x2, #0x20                  	// #32
    1bc4:	aa1b03e1 	mov	x1, x27
    1bc8:	aa1703e0 	mov	x0, x23
    1bcc:	d63f00a0 	blr	x5
    1bd0:	aa1303e0 	mov	x0, x19
    1bd4:	94000000 	bl	0 <kfree>
    1bd8:	b9406fa0 	ldr	w0, [x29, #108]
    1bdc:	7100031f 	cmp	w24, #0x0
    1be0:	1a801318 	csel	w24, w24, w0, ne  // ne = any
    1be4:	17ffff91 	b	1a28 <hisi_qm_start_qp+0x1b0>
    1be8:	b9402281 	ldr	w1, [x20, #32]
    1bec:	12818002 	mov	w2, #0xfffff3ff            	// #-3073
    1bf0:	5ac01020 	clz	w0, w1
    1bf4:	7100003f 	cmp	w1, #0x0
    1bf8:	2a2003e0 	mvn	w0, w0
    1bfc:	11008000 	add	w0, w0, #0x20
    1c00:	53144c00 	lsl	w0, w0, #12
    1c04:	32002400 	orr	w0, w0, #0x3ff
    1c08:	1a821000 	csel	w0, w0, w2, ne  // ne = any
    1c0c:	b9000e60 	str	w0, [x19, #12]
    1c10:	17ffff69 	b	19b4 <hisi_qm_start_qp+0x13c>
    1c14:	52880001 	mov	w1, #0x4000                	// #16384
    1c18:	52807fe0 	mov	w0, #0x3ff                 	// #1023
    1c1c:	b9000e61 	str	w1, [x19, #12]
    1c20:	79002260 	strh	w0, [x19, #16]
    1c24:	17ffffd8 	b	1b84 <hisi_qm_start_qp+0x30c>
    1c28:	d2800004 	mov	x4, #0x0                   	// #0
    1c2c:	52800023 	mov	w3, #0x1                   	// #1
    1c30:	d2800402 	mov	x2, #0x20                  	// #32
    1c34:	aa1b03e1 	mov	x1, x27
    1c38:	aa1703e0 	mov	x0, x23
    1c3c:	94000000 	bl	0 <dma_direct_unmap_page>
    1c40:	17ffffe4 	b	1bd0 <hisi_qm_start_qp+0x358>
    1c44:	90000000 	adrp	x0, 0 <__raw_readl>
    1c48:	39400001 	ldrb	w1, [x0]
    1c4c:	340002a1 	cbz	w1, 1ca0 <hisi_qm_start_qp+0x428>
    1c50:	aa1303e0 	mov	x0, x19
    1c54:	12800178 	mov	w24, #0xfffffff4            	// #-12
    1c58:	94000000 	bl	0 <kfree>
    1c5c:	d503201f 	nop
    1c60:	f9400bb3 	ldr	x19, [x29, #16]
    1c64:	a9425bb5 	ldp	x21, x22, [x29, #32]
    1c68:	f9401bb7 	ldr	x23, [x29, #48]
    1c6c:	f94023b9 	ldr	x25, [x29, #64]
    1c70:	f9402bbb 	ldr	x27, [x29, #80]
    1c74:	17ffff72 	b	1a3c <hisi_qm_start_qp+0x1c4>
    1c78:	90000001 	adrp	x1, 0 <__raw_readl>
    1c7c:	39400020 	ldrb	w0, [x1]
    1c80:	34000260 	cbz	w0, 1ccc <hisi_qm_start_qp+0x454>
    1c84:	aa1303e0 	mov	x0, x19
    1c88:	12800178 	mov	w24, #0xfffffff4            	// #-12
    1c8c:	94000000 	bl	0 <kfree>
    1c90:	17ffff66 	b	1a28 <hisi_qm_start_qp+0x1b0>
    1c94:	f94027ba 	ldr	x26, [x29, #72]
    1c98:	12800178 	mov	w24, #0xfffffff4            	// #-12
    1c9c:	17fffff1 	b	1c60 <hisi_qm_start_qp+0x3e8>
    1ca0:	39000018 	strb	w24, [x0]
    1ca4:	aa1703e0 	mov	x0, x23
    1ca8:	94000000 	bl	0 <dev_driver_string>
    1cac:	f9402ae2 	ldr	x2, [x23, #80]
    1cb0:	b4000262 	cbz	x2, 1cfc <hisi_qm_start_qp+0x484>
    1cb4:	90000003 	adrp	x3, 0 <__raw_readl>
    1cb8:	aa0003e1 	mov	x1, x0
    1cbc:	91000060 	add	x0, x3, #0x0
    1cc0:	94000000 	bl	0 <__warn_printk>
    1cc4:	d4210000 	brk	#0x800
    1cc8:	17ffffe2 	b	1c50 <hisi_qm_start_qp+0x3d8>
    1ccc:	52800022 	mov	w2, #0x1                   	// #1
    1cd0:	aa1703e0 	mov	x0, x23
    1cd4:	39000022 	strb	w2, [x1]
    1cd8:	94000000 	bl	0 <dev_driver_string>
    1cdc:	f9402ae2 	ldr	x2, [x23, #80]
    1ce0:	b4000162 	cbz	x2, 1d0c <hisi_qm_start_qp+0x494>
    1ce4:	90000003 	adrp	x3, 0 <__raw_readl>
    1ce8:	aa0003e1 	mov	x1, x0
    1cec:	91000060 	add	x0, x3, #0x0
    1cf0:	94000000 	bl	0 <__warn_printk>
    1cf4:	d4210000 	brk	#0x800
    1cf8:	17ffffe3 	b	1c84 <hisi_qm_start_qp+0x40c>
    1cfc:	f9405aa2 	ldr	x2, [x21, #176]
    1d00:	17ffffed 	b	1cb4 <hisi_qm_start_qp+0x43c>
    1d04:	f94027ba 	ldr	x26, [x29, #72]
    1d08:	17ffffd2 	b	1c50 <hisi_qm_start_qp+0x3d8>
    1d0c:	f9405aa2 	ldr	x2, [x21, #176]
    1d10:	17fffff5 	b	1ce4 <hisi_qm_start_qp+0x46c>
    1d14:	90000001 	adrp	x1, 0 <__raw_readl>
    1d18:	128002b8 	mov	w24, #0xffffffea            	// #-22
    1d1c:	91000021 	add	x1, x1, #0x0
    1d20:	94000000 	bl	0 <_dev_err>
    1d24:	17ffff46 	b	1a3c <hisi_qm_start_qp+0x1c4>
    1d28:	90000001 	adrp	x1, 0 <__raw_readl>
    1d2c:	128002b8 	mov	w24, #0xffffffea            	// #-22
    1d30:	91000021 	add	x1, x1, #0x0
    1d34:	94000000 	bl	0 <_dev_err>
    1d38:	17ffff41 	b	1a3c <hisi_qm_start_qp+0x1c4>
    1d3c:	d503201f 	nop

0000000000001d40 <qm_debug_read>:
    1d40:	a9b97bfd 	stp	x29, x30, [sp, #-112]!
    1d44:	910003fd 	mov	x29, sp
    1d48:	a90153f3 	stp	x19, x20, [sp, #16]
    1d4c:	90000014 	adrp	x20, 0 <__stack_chk_guard>
    1d50:	a9025bf5 	stp	x21, x22, [sp, #32]
    1d54:	aa0103f5 	mov	x21, x1
    1d58:	a90363f7 	stp	x23, x24, [sp, #48]
    1d5c:	aa0203f6 	mov	x22, x2
    1d60:	f90023f9 	str	x25, [sp, #64]
    1d64:	aa0303f7 	mov	x23, x3
    1d68:	f9406413 	ldr	x19, [x0, #200]
    1d6c:	91000280 	add	x0, x20, #0x0
    1d70:	f9400001 	ldr	x1, [x0]
    1d74:	f90037a1 	str	x1, [x29, #104]
    1d78:	d2800001 	mov	x1, #0x0                   	// #0
    1d7c:	aa1303f8 	mov	x24, x19
    1d80:	b8408719 	ldr	w25, [x24], #8
    1d84:	aa1803e0 	mov	x0, x24
    1d88:	94000000 	bl	0 <mutex_lock>
    1d8c:	34000519 	cbz	w25, 1e2c <qm_debug_read+0xec>
    1d90:	7100073f 	cmp	w25, #0x1
    1d94:	540001e0 	b.eq	1dd0 <qm_debug_read+0x90>  // b.none
    1d98:	aa1803e0 	mov	x0, x24
    1d9c:	94000000 	bl	0 <mutex_unlock>
    1da0:	928002a0 	mov	x0, #0xffffffffffffffea    	// #-22
    1da4:	91000294 	add	x20, x20, #0x0
    1da8:	f94037a2 	ldr	x2, [x29, #104]
    1dac:	f9400281 	ldr	x1, [x20]
    1db0:	ca010041 	eor	x1, x2, x1
    1db4:	b5000521 	cbnz	x1, 1e58 <qm_debug_read+0x118>
    1db8:	a94153f3 	ldp	x19, x20, [sp, #16]
    1dbc:	a9425bf5 	ldp	x21, x22, [sp, #32]
    1dc0:	a94363f7 	ldp	x23, x24, [sp, #48]
    1dc4:	f94023f9 	ldr	x25, [sp, #64]
    1dc8:	a8c77bfd 	ldp	x29, x30, [sp], #112
    1dcc:	d65f03c0 	ret
    1dd0:	f9401660 	ldr	x0, [x19, #40]
    1dd4:	f8530013 	ldur	x19, [x0, #-208]
    1dd8:	91440273 	add	x19, x19, #0x100, lsl #12
    1ddc:	91046273 	add	x19, x19, #0x118
    1de0:	b9400273 	ldr	w19, [x19]
    1de4:	d50331bf 	dmb	oshld
    1de8:	2a1303e0 	mov	w0, w19
    1dec:	ca000000 	eor	x0, x0, x0
    1df0:	b5000000 	cbnz	x0, 1df0 <qm_debug_read+0xb0>
    1df4:	aa1803e0 	mov	x0, x24
    1df8:	94000000 	bl	0 <mutex_unlock>
    1dfc:	2a1303e2 	mov	w2, w19
    1e00:	91014ba0 	add	x0, x29, #0x52
    1e04:	90000001 	adrp	x1, 0 <__raw_readl>
    1e08:	91000021 	add	x1, x1, #0x0
    1e0c:	94000000 	bl	0 <sprintf>
    1e10:	93407c04 	sxtw	x4, w0
    1e14:	91014ba3 	add	x3, x29, #0x52
    1e18:	aa1703e2 	mov	x2, x23
    1e1c:	aa1603e1 	mov	x1, x22
    1e20:	aa1503e0 	mov	x0, x21
    1e24:	94000000 	bl	0 <simple_read_from_buffer>
    1e28:	17ffffdf 	b	1da4 <qm_debug_read+0x64>
    1e2c:	f9401660 	ldr	x0, [x19, #40]
    1e30:	f8530013 	ldur	x19, [x0, #-208]
    1e34:	91441273 	add	x19, x19, #0x104, lsl #12
    1e38:	9100c273 	add	x19, x19, #0x30
    1e3c:	b9400273 	ldr	w19, [x19]
    1e40:	d50331bf 	dmb	oshld
    1e44:	2a1303e0 	mov	w0, w19
    1e48:	ca000000 	eor	x0, x0, x0
    1e4c:	b5000000 	cbnz	x0, 1e4c <qm_debug_read+0x10c>
    1e50:	53107e73 	lsr	w19, w19, #16
    1e54:	17ffffe8 	b	1df4 <qm_debug_read+0xb4>
    1e58:	94000000 	bl	0 <__stack_chk_fail>
    1e5c:	d503201f 	nop

0000000000001e60 <hisi_qm_start>:
    1e60:	a9bb7bfd 	stp	x29, x30, [sp, #-80]!
    1e64:	910003fd 	mov	x29, sp
    1e68:	a90153f3 	stp	x19, x20, [sp, #16]
    1e6c:	aa0003f3 	mov	x19, x0
    1e70:	b9402801 	ldr	w1, [x0, #40]
    1e74:	f9400800 	ldr	x0, [x0, #16]
    1e78:	9102c014 	add	x20, x0, #0xb0
    1e7c:	34002c81 	cbz	w1, 240c <hisi_qm_start+0x5ac>
    1e80:	f9405a60 	ldr	x0, [x19, #176]
    1e84:	b4002040 	cbz	x0, 228c <hisi_qm_start+0x42c>
    1e88:	3945a260 	ldrb	w0, [x19, #360]
    1e8c:	34001220 	cbz	w0, 20d0 <hisi_qm_start+0x270>
    1e90:	f9401e60 	ldr	x0, [x19, #56]
    1e94:	b4001280 	cbz	x0, 20e4 <hisi_qm_start+0x284>
    1e98:	f9402260 	ldr	x0, [x19, #64]
    1e9c:	b4001f40 	cbz	x0, 2284 <hisi_qm_start+0x424>
    1ea0:	b9402a60 	ldr	w0, [x19, #40]
    1ea4:	34002580 	cbz	w0, 2354 <hisi_qm_start+0x4f4>
    1ea8:	f90013b5 	str	x21, [x29, #32]
    1eac:	b9400661 	ldr	w1, [x19, #4]
    1eb0:	35000421 	cbnz	w1, 1f34 <hisi_qm_start+0xd4>
    1eb4:	d50332bf 	dmb	oshst
    1eb8:	f9400e60 	ldr	x0, [x19, #24]
    1ebc:	52800021 	mov	w1, #0x1                   	// #1
    1ec0:	91440000 	add	x0, x0, #0x100, lsl #12
    1ec4:	91010000 	add	x0, x0, #0x40
    1ec8:	b9000001 	str	w1, [x0]
    1ecc:	d2800894 	mov	x20, #0x44                  	// #68
    1ed0:	94000000 	bl	0 <ktime_get>
    1ed4:	9143d015 	add	x21, x0, #0xf4, lsl #12
    1ed8:	f2a00214 	movk	x20, #0x10, lsl #16
    1edc:	910902b5 	add	x21, x21, #0x240
    1ee0:	14000007 	b	1efc <hisi_qm_start+0x9c>
    1ee4:	94000000 	bl	0 <ktime_get>
    1ee8:	eb0002bf 	cmp	x21, x0
    1eec:	54001f8b 	b.lt	22dc <hisi_qm_start+0x47c>  // b.tstop
    1ef0:	d2800141 	mov	x1, #0xa                   	// #10
    1ef4:	d2800060 	mov	x0, #0x3                   	// #3
    1ef8:	94000000 	bl	0 <usleep_range>
    1efc:	f9400e60 	ldr	x0, [x19, #24]
    1f00:	8b140000 	add	x0, x0, x20
    1f04:	b9400000 	ldr	w0, [x0]
    1f08:	3607fee0 	tbz	w0, #0, 1ee4 <hisi_qm_start+0x84>
    1f0c:	29448e62 	ldp	w2, w3, [x19, #36]
    1f10:	52800001 	mov	w1, #0x0                   	// #0
    1f14:	aa1303e0 	mov	x0, x19
    1f18:	94000000 	bl	d48 <hisi_qm_set_vft>
    1f1c:	2a0003f4 	mov	w20, w0
    1f20:	35000fc0 	cbnz	w0, 2118 <hisi_qm_start+0x2b8>
    1f24:	a902dfb6 	stp	x22, x23, [x29, #40]
    1f28:	f9001fb8 	str	x24, [x29, #56]
    1f2c:	b9402a60 	ldr	w0, [x19, #40]
    1f30:	14000003 	b	1f3c <hisi_qm_start+0xdc>
    1f34:	a902dfb6 	stp	x22, x23, [x29, #40]
    1f38:	f9001fb8 	str	x24, [x29, #56]
    1f3c:	a9438662 	ldp	x2, x1, [x19, #56]
    1f40:	d37b7c00 	ubfiz	x0, x0, #5, #32
    1f44:	91024263 	add	x3, x19, #0x90
    1f48:	91400800 	add	x0, x0, #0x2, lsl #12
    1f4c:	91400445 	add	x5, x2, #0x1, lsl #12
    1f50:	91400424 	add	x4, x1, #0x1, lsl #12
    1f54:	a9061662 	stp	x2, x5, [x19, #96]
    1f58:	91400845 	add	x5, x2, #0x2, lsl #12
    1f5c:	8b000042 	add	x2, x2, x0
    1f60:	a9081261 	stp	x1, x4, [x19, #128]
    1f64:	a9050a65 	stp	x5, x2, [x19, #80]
    1f68:	91400824 	add	x4, x1, #0x2, lsl #12
    1f6c:	b900927f 	str	wzr, [x19, #144]
    1f70:	8b000020 	add	x0, x1, x0
    1f74:	90000017 	adrp	x23, 0 <kmalloc_caches>
    1f78:	a9070264 	stp	x4, x0, [x19, #112]
    1f7c:	910002e2 	add	x2, x23, #0x0
    1f80:	f9400a76 	ldr	x22, [x19, #16]
    1f84:	52800034 	mov	w20, #0x1                   	// #1
    1f88:	39001074 	strb	w20, [x3, #4]
    1f8c:	b900087f 	str	wzr, [x3, #8]
    1f90:	5281b801 	mov	w1, #0xdc0                 	// #3520
    1f94:	39003074 	strb	w20, [x3, #12]
    1f98:	9102c2d8 	add	x24, x22, #0xb0
    1f9c:	f9401c40 	ldr	x0, [x2, #56]
    1fa0:	94000000 	bl	0 <kmem_cache_alloc>
    1fa4:	aa0003f5 	mov	x21, x0
    1fa8:	b4001ee0 	cbz	x0, 2384 <hisi_qm_start+0x524>
    1fac:	94000000 	bl	0 <is_vmalloc_addr>
    1fb0:	72001c1f 	tst	w0, #0xff
    1fb4:	54001be1 	b.ne	2330 <hisi_qm_start+0x4d0>  // b.any
    1fb8:	f90023b9 	str	x25, [x29, #64]
    1fbc:	d2e00021 	mov	x1, #0x1000000000000       	// #281474976710656
    1fc0:	8b0102a1 	add	x1, x21, x1
    1fc4:	b26babe3 	mov	x3, #0xffffffffffe00000    	// #-2097152
    1fc8:	f9417ac0 	ldr	x0, [x22, #752]
    1fcc:	f2dfbfe3 	movk	x3, #0xfdff, lsl #32
    1fd0:	d34cfc21 	lsr	x1, x1, #12
    1fd4:	92402ea2 	and	x2, x21, #0xfff
    1fd8:	8b011861 	add	x1, x3, x1, lsl #6
    1fdc:	b4000120 	cbz	x0, 2000 <hisi_qm_start+0x1a0>
    1fe0:	f9401006 	ldr	x6, [x0, #32]
    1fe4:	d2800005 	mov	x5, #0x0                   	// #0
    1fe8:	52800024 	mov	w4, #0x1                   	// #1
    1fec:	d2800383 	mov	x3, #0x1c                  	// #28
    1ff0:	aa1803e0 	mov	x0, x24
    1ff4:	d63f00c0 	blr	x6
    1ff8:	aa0003f9 	mov	x25, x0
    1ffc:	14000007 	b	2018 <hisi_qm_start+0x1b8>
    2000:	d2800005 	mov	x5, #0x0                   	// #0
    2004:	52800024 	mov	w4, #0x1                   	// #1
    2008:	d2800383 	mov	x3, #0x1c                  	// #28
    200c:	aa1803e0 	mov	x0, x24
    2010:	94000000 	bl	0 <dma_direct_map_page>
    2014:	aa0003f9 	mov	x25, x0
    2018:	b100073f 	cmn	x25, #0x1
    201c:	54002040 	b.eq	2424 <hisi_qm_start+0x5c4>  // b.none
    2020:	f9404260 	ldr	x0, [x19, #128]
    2024:	b9400261 	ldr	w1, [x19]
    2028:	b90006a0 	str	w0, [x21, #4]
    202c:	d360fc00 	lsr	x0, x0, #32
    2030:	b9000aa0 	str	w0, [x21, #8]
    2034:	7100803f 	cmp	w1, #0x20
    2038:	540007a0 	b.eq	212c <hisi_qm_start+0x2cc>  // b.none
    203c:	52807fe0 	mov	w0, #0x3ff                 	// #1023
    2040:	52800004 	mov	w4, #0x0                   	// #0
    2044:	72a00020 	movk	w0, #0x1, lsl #16
    2048:	b9001aa0 	str	w0, [x21, #24]
    204c:	52800003 	mov	w3, #0x0                   	// #0
    2050:	aa1903e2 	mov	x2, x25
    2054:	52800041 	mov	w1, #0x2                   	// #2
    2058:	aa1303e0 	mov	x0, x19
    205c:	97fffda1 	bl	16e0 <qm_mb>
    2060:	2a0003f4 	mov	w20, w0
    2064:	f9417ac0 	ldr	x0, [x22, #752]
    2068:	b4000140 	cbz	x0, 2090 <hisi_qm_start+0x230>
    206c:	f9401405 	ldr	x5, [x0, #40]
    2070:	b40001c5 	cbz	x5, 20a8 <hisi_qm_start+0x248>
    2074:	d2800004 	mov	x4, #0x0                   	// #0
    2078:	52800023 	mov	w3, #0x1                   	// #1
    207c:	d2800382 	mov	x2, #0x1c                  	// #28
    2080:	aa1903e1 	mov	x1, x25
    2084:	aa1803e0 	mov	x0, x24
    2088:	d63f00a0 	blr	x5
    208c:	14000007 	b	20a8 <hisi_qm_start+0x248>
    2090:	d2800004 	mov	x4, #0x0                   	// #0
    2094:	52800023 	mov	w3, #0x1                   	// #1
    2098:	d2800382 	mov	x2, #0x1c                  	// #28
    209c:	aa1903e1 	mov	x1, x25
    20a0:	aa1803e0 	mov	x0, x24
    20a4:	94000000 	bl	0 <dma_direct_unmap_page>
    20a8:	aa1503e0 	mov	x0, x21
    20ac:	94000000 	bl	0 <kfree>
    20b0:	34000454 	cbz	w20, 2138 <hisi_qm_start+0x2d8>
    20b4:	a9425bb5 	ldp	x21, x22, [x29, #32]
    20b8:	a94363b7 	ldp	x23, x24, [x29, #48]
    20bc:	f94023b9 	ldr	x25, [x29, #64]
    20c0:	2a1403e0 	mov	w0, w20
    20c4:	a94153f3 	ldp	x19, x20, [sp, #16]
    20c8:	a8c57bfd 	ldp	x29, x30, [sp], #80
    20cc:	d65f03c0 	ret
    20d0:	52800014 	mov	w20, #0x0                   	// #0
    20d4:	2a1403e0 	mov	w0, w20
    20d8:	a94153f3 	ldp	x19, x20, [sp, #16]
    20dc:	a8c57bfd 	ldp	x29, x30, [sp], #80
    20e0:	d65f03c0 	ret
    20e4:	b9402a61 	ldr	w1, [x19, #40]
    20e8:	d2800004 	mov	x4, #0x0                   	// #0
    20ec:	52819803 	mov	w3, #0xcc0                 	// #3264
    20f0:	91010262 	add	x2, x19, #0x40
    20f4:	aa1403e0 	mov	x0, x20
    20f8:	d37a7c21 	ubfiz	x1, x1, #6, #32
    20fc:	91400821 	add	x1, x1, #0x2, lsl #12
    2100:	f9002661 	str	x1, [x19, #72]
    2104:	94000000 	bl	0 <dma_alloc_attrs>
    2108:	f9001e60 	str	x0, [x19, #56]
    210c:	b5ffec60 	cbnz	x0, 1e98 <hisi_qm_start+0x38>
    2110:	12800174 	mov	w20, #0xfffffff4            	// #-12
    2114:	17ffffeb 	b	20c0 <hisi_qm_start+0x260>
    2118:	2a1403e0 	mov	w0, w20
    211c:	f94013b5 	ldr	x21, [x29, #32]
    2120:	a94153f3 	ldp	x19, x20, [sp, #16]
    2124:	a8c57bfd 	ldp	x29, x30, [sp], #80
    2128:	d65f03c0 	ret
    212c:	52840000 	mov	w0, #0x2000                	// #8192
    2130:	b9000ea0 	str	w0, [x21, #12]
    2134:	17ffffc2 	b	203c <hisi_qm_start+0x1dc>
    2138:	910002f7 	add	x23, x23, #0x0
    213c:	5281b801 	mov	w1, #0xdc0                 	// #3520
    2140:	f9401ee0 	ldr	x0, [x23, #56]
    2144:	94000000 	bl	0 <kmem_cache_alloc>
    2148:	aa0003f5 	mov	x21, x0
    214c:	b40013a0 	cbz	x0, 23c0 <hisi_qm_start+0x560>
    2150:	94000000 	bl	0 <is_vmalloc_addr>
    2154:	72001c1f 	tst	w0, #0xff
    2158:	54001021 	b.ne	235c <hisi_qm_start+0x4fc>  // b.any
    215c:	d2e00021 	mov	x1, #0x1000000000000       	// #281474976710656
    2160:	f9417ac0 	ldr	x0, [x22, #752]
    2164:	8b0102a1 	add	x1, x21, x1
    2168:	b26babe3 	mov	x3, #0xffffffffffe00000    	// #-2097152
    216c:	f2dfbfe3 	movk	x3, #0xfdff, lsl #32
    2170:	92402ea2 	and	x2, x21, #0xfff
    2174:	d34cfc21 	lsr	x1, x1, #12
    2178:	8b011861 	add	x1, x3, x1, lsl #6
    217c:	b4000cc0 	cbz	x0, 2314 <hisi_qm_start+0x4b4>
    2180:	f9401006 	ldr	x6, [x0, #32]
    2184:	d2800005 	mov	x5, #0x0                   	// #0
    2188:	52800024 	mov	w4, #0x1                   	// #1
    218c:	d2800383 	mov	x3, #0x1c                  	// #28
    2190:	aa1803e0 	mov	x0, x24
    2194:	d63f00c0 	blr	x6
    2198:	aa0003f7 	mov	x23, x0
    219c:	b10006ff 	cmn	x23, #0x1
    21a0:	54000e40 	b.eq	2368 <hisi_qm_start+0x508>  // b.none
    21a4:	f9404660 	ldr	x0, [x19, #136]
    21a8:	52807fe1 	mov	w1, #0x3ff                 	// #1023
    21ac:	72a00021 	movk	w1, #0x1, lsl #16
    21b0:	b90006a0 	str	w0, [x21, #4]
    21b4:	b9001aa1 	str	w1, [x21, #24]
    21b8:	52800004 	mov	w4, #0x0                   	// #0
    21bc:	d360fc00 	lsr	x0, x0, #32
    21c0:	b9000aa0 	str	w0, [x21, #8]
    21c4:	52800003 	mov	w3, #0x0                   	// #0
    21c8:	aa1703e2 	mov	x2, x23
    21cc:	52800061 	mov	w1, #0x3                   	// #3
    21d0:	aa1303e0 	mov	x0, x19
    21d4:	97fffd43 	bl	16e0 <qm_mb>
    21d8:	2a0003f4 	mov	w20, w0
    21dc:	f9417ac0 	ldr	x0, [x22, #752]
    21e0:	b40008c0 	cbz	x0, 22f8 <hisi_qm_start+0x498>
    21e4:	f9401405 	ldr	x5, [x0, #40]
    21e8:	b4000105 	cbz	x5, 2208 <hisi_qm_start+0x3a8>
    21ec:	d2800004 	mov	x4, #0x0                   	// #0
    21f0:	52800023 	mov	w3, #0x1                   	// #1
    21f4:	d2800382 	mov	x2, #0x1c                  	// #28
    21f8:	aa1703e1 	mov	x1, x23
    21fc:	aa1803e0 	mov	x0, x24
    2200:	d63f00a0 	blr	x5
    2204:	d503201f 	nop
    2208:	aa1503e0 	mov	x0, x21
    220c:	94000000 	bl	0 <kfree>
    2210:	35fff534 	cbnz	w20, 20b4 <hisi_qm_start+0x254>
    2214:	f9403a62 	ldr	x2, [x19, #112]
    2218:	52800004 	mov	w4, #0x0                   	// #0
    221c:	52800003 	mov	w3, #0x0                   	// #0
    2220:	52800081 	mov	w1, #0x4                   	// #4
    2224:	aa1303e0 	mov	x0, x19
    2228:	97fffd2e 	bl	16e0 <qm_mb>
    222c:	2a0003f4 	mov	w20, w0
    2230:	35fff420 	cbnz	w0, 20b4 <hisi_qm_start+0x254>
    2234:	f9403e62 	ldr	x2, [x19, #120]
    2238:	52800004 	mov	w4, #0x0                   	// #0
    223c:	52800003 	mov	w3, #0x0                   	// #0
    2240:	528000a1 	mov	w1, #0x5                   	// #5
    2244:	aa1303e0 	mov	x0, x19
    2248:	97fffd26 	bl	16e0 <qm_mb>
    224c:	2a0003f4 	mov	w20, w0
    2250:	35fff320 	cbnz	w0, 20b4 <hisi_qm_start+0x254>
    2254:	d50332bf 	dmb	oshst
    2258:	f9400e60 	ldr	x0, [x19, #24]
    225c:	91003000 	add	x0, x0, #0xc
    2260:	b900001f 	str	wzr, [x0]
    2264:	d50332bf 	dmb	oshst
    2268:	f9400e60 	ldr	x0, [x19, #24]
    226c:	91001000 	add	x0, x0, #0x4
    2270:	b900001f 	str	wzr, [x0]
    2274:	a9425bb5 	ldp	x21, x22, [x29, #32]
    2278:	a94363b7 	ldp	x23, x24, [x29, #48]
    227c:	f94023b9 	ldr	x25, [x29, #64]
    2280:	17ffff90 	b	20c0 <hisi_qm_start+0x260>
    2284:	d4210000 	brk	#0x800
    2288:	17ffff06 	b	1ea0 <hisi_qm_start+0x40>
    228c:	2a0103e1 	mov	w1, w1
    2290:	5281b802 	mov	w2, #0xdc0                 	// #3520
    2294:	9100fc21 	add	x1, x1, #0x3f
    2298:	aa1403e0 	mov	x0, x20
    229c:	d346fc21 	lsr	x1, x1, #6
    22a0:	d37df021 	lsl	x1, x1, #3
    22a4:	94000000 	bl	0 <devm_kmalloc>
    22a8:	b9402a61 	ldr	w1, [x19, #40]
    22ac:	5281b802 	mov	w2, #0xdc0                 	// #3520
    22b0:	f9005a60 	str	x0, [x19, #176]
    22b4:	aa1403e0 	mov	x0, x20
    22b8:	d37df021 	lsl	x1, x1, #3
    22bc:	94000000 	bl	0 <devm_kmalloc>
    22c0:	f9405a61 	ldr	x1, [x19, #176]
    22c4:	f9005e60 	str	x0, [x19, #184]
    22c8:	f100003f 	cmp	x1, #0x0
    22cc:	fa401804 	ccmp	x0, #0x0, #0x4, ne  // ne = any
    22d0:	54ffddc1 	b.ne	1e88 <hisi_qm_start+0x28>  // b.any
    22d4:	12800174 	mov	w20, #0xfffffff4            	// #-12
    22d8:	17ffff7a 	b	20c0 <hisi_qm_start+0x260>
    22dc:	f9400e60 	ldr	x0, [x19, #24]
    22e0:	8b140014 	add	x20, x0, x20
    22e4:	b9400294 	ldr	w20, [x20]
    22e8:	3707e134 	tbnz	w20, #0, 1f0c <hisi_qm_start+0xac>
    22ec:	12800db4 	mov	w20, #0xffffff92            	// #-110
    22f0:	f94013b5 	ldr	x21, [x29, #32]
    22f4:	17ffff73 	b	20c0 <hisi_qm_start+0x260>
    22f8:	d2800004 	mov	x4, #0x0                   	// #0
    22fc:	52800023 	mov	w3, #0x1                   	// #1
    2300:	d2800382 	mov	x2, #0x1c                  	// #28
    2304:	aa1703e1 	mov	x1, x23
    2308:	aa1803e0 	mov	x0, x24
    230c:	94000000 	bl	0 <dma_direct_unmap_page>
    2310:	17ffffbe 	b	2208 <hisi_qm_start+0x3a8>
    2314:	d2800005 	mov	x5, #0x0                   	// #0
    2318:	52800024 	mov	w4, #0x1                   	// #1
    231c:	d2800383 	mov	x3, #0x1c                  	// #28
    2320:	aa1803e0 	mov	x0, x24
    2324:	94000000 	bl	0 <dma_direct_map_page>
    2328:	aa0003f7 	mov	x23, x0
    232c:	17ffff9c 	b	219c <hisi_qm_start+0x33c>
    2330:	90000000 	adrp	x0, 0 <__raw_readl>
    2334:	39400001 	ldrb	w1, [x0]
    2338:	340002e1 	cbz	w1, 2394 <hisi_qm_start+0x534>
    233c:	aa1503e0 	mov	x0, x21
    2340:	12800174 	mov	w20, #0xfffffff4            	// #-12
    2344:	94000000 	bl	0 <kfree>
    2348:	a9425bb5 	ldp	x21, x22, [x29, #32]
    234c:	a94363b7 	ldp	x23, x24, [x29, #48]
    2350:	17ffff5c 	b	20c0 <hisi_qm_start+0x260>
    2354:	128002b4 	mov	w20, #0xffffffea            	// #-22
    2358:	17ffff5a 	b	20c0 <hisi_qm_start+0x260>
    235c:	90000001 	adrp	x1, 0 <__raw_readl>
    2360:	39400020 	ldrb	w0, [x1]
    2364:	34000380 	cbz	w0, 23d4 <hisi_qm_start+0x574>
    2368:	aa1503e0 	mov	x0, x21
    236c:	12800174 	mov	w20, #0xfffffff4            	// #-12
    2370:	94000000 	bl	0 <kfree>
    2374:	f94023b9 	ldr	x25, [x29, #64]
    2378:	a9425bb5 	ldp	x21, x22, [x29, #32]
    237c:	a94363b7 	ldp	x23, x24, [x29, #48]
    2380:	17ffff50 	b	20c0 <hisi_qm_start+0x260>
    2384:	a9425bb5 	ldp	x21, x22, [x29, #32]
    2388:	12800174 	mov	w20, #0xfffffff4            	// #-12
    238c:	a94363b7 	ldp	x23, x24, [x29, #48]
    2390:	17ffff4c 	b	20c0 <hisi_qm_start+0x260>
    2394:	39000014 	strb	w20, [x0]
    2398:	aa1803e0 	mov	x0, x24
    239c:	94000000 	bl	0 <dev_driver_string>
    23a0:	f9402b02 	ldr	x2, [x24, #80]
    23a4:	b4000302 	cbz	x2, 2404 <hisi_qm_start+0x5a4>
    23a8:	90000003 	adrp	x3, 0 <__raw_readl>
    23ac:	aa0003e1 	mov	x1, x0
    23b0:	91000060 	add	x0, x3, #0x0
    23b4:	94000000 	bl	0 <__warn_printk>
    23b8:	d4210000 	brk	#0x800
    23bc:	17ffffe0 	b	233c <hisi_qm_start+0x4dc>
    23c0:	a9425bb5 	ldp	x21, x22, [x29, #32]
    23c4:	12800174 	mov	w20, #0xfffffff4            	// #-12
    23c8:	a94363b7 	ldp	x23, x24, [x29, #48]
    23cc:	f94023b9 	ldr	x25, [x29, #64]
    23d0:	17ffff3c 	b	20c0 <hisi_qm_start+0x260>
    23d4:	52800022 	mov	w2, #0x1                   	// #1
    23d8:	aa1803e0 	mov	x0, x24
    23dc:	39000022 	strb	w2, [x1]
    23e0:	94000000 	bl	0 <dev_driver_string>
    23e4:	f9402b02 	ldr	x2, [x24, #80]
    23e8:	b4000222 	cbz	x2, 242c <hisi_qm_start+0x5cc>
    23ec:	90000003 	adrp	x3, 0 <__raw_readl>
    23f0:	aa0003e1 	mov	x1, x0
    23f4:	91000060 	add	x0, x3, #0x0
    23f8:	94000000 	bl	0 <__warn_printk>
    23fc:	d4210000 	brk	#0x800
    2400:	17ffffda 	b	2368 <hisi_qm_start+0x508>
    2404:	f9405ac2 	ldr	x2, [x22, #176]
    2408:	17ffffe8 	b	23a8 <hisi_qm_start+0x548>
    240c:	aa1403e0 	mov	x0, x20
    2410:	90000001 	adrp	x1, 0 <__raw_readl>
    2414:	128002b4 	mov	w20, #0xffffffea            	// #-22
    2418:	91000021 	add	x1, x1, #0x0
    241c:	94000000 	bl	0 <_dev_err>
    2420:	17ffff28 	b	20c0 <hisi_qm_start+0x260>
    2424:	f94023b9 	ldr	x25, [x29, #64]
    2428:	17ffffc5 	b	233c <hisi_qm_start+0x4dc>
    242c:	f9405ac2 	ldr	x2, [x22, #176]
    2430:	17ffffef 	b	23ec <hisi_qm_start+0x58c>
    2434:	d503201f 	nop

0000000000002438 <qm_debug_write>:
    2438:	a9b97bfd 	stp	x29, x30, [sp, #-112]!
    243c:	aa0303e5 	mov	x5, x3
    2440:	aa0003e6 	mov	x6, x0
    2444:	910003fd 	mov	x29, sp
    2448:	f9000bf3 	str	x19, [sp, #16]
    244c:	90000013 	adrp	x19, 0 <__stack_chk_guard>
    2450:	91000263 	add	x3, x19, #0x0
    2454:	f94000a4 	ldr	x4, [x5]
    2458:	f9400060 	ldr	x0, [x3]
    245c:	f90037a0 	str	x0, [x29, #104]
    2460:	d2800000 	mov	x0, #0x0                   	// #0
    2464:	b50004a4 	cbnz	x4, 24f8 <qm_debug_write+0xc0>
    2468:	f9000fb4 	str	x20, [x29, #24]
    246c:	f100545f 	cmp	x2, #0x15
    2470:	aa0203f4 	mov	x20, x2
    2474:	54000ba8 	b.hi	25e8 <qm_debug_write+0x1b0>  // b.pmore
    2478:	a9025bb5 	stp	x21, x22, [x29, #32]
    247c:	aa0203e4 	mov	x4, x2
    2480:	aa0103e3 	mov	x3, x1
    2484:	aa0503e2 	mov	x2, x5
    2488:	f94064d5 	ldr	x21, [x6, #200]
    248c:	d28002a1 	mov	x1, #0x15                  	// #21
    2490:	91014ba0 	add	x0, x29, #0x52
    2494:	b94002b6 	ldr	w22, [x21]
    2498:	94000000 	bl	0 <simple_write_to_buffer>
    249c:	37f803e0 	tbnz	w0, #31, 2518 <qm_debug_write+0xe0>
    24a0:	91014ba1 	add	x1, x29, #0x52
    24a4:	910123a2 	add	x2, x29, #0x48
    24a8:	3820c83f 	strb	wzr, [x1, w0, sxtw]
    24ac:	52800001 	mov	w1, #0x0                   	// #0
    24b0:	91014ba0 	add	x0, x29, #0x52
    24b4:	94000000 	bl	0 <kstrtoull>
    24b8:	350009e0 	cbnz	w0, 25f4 <qm_debug_write+0x1bc>
    24bc:	f9001bb7 	str	x23, [x29, #48]
    24c0:	910022b7 	add	x23, x21, #0x8
    24c4:	aa1703e0 	mov	x0, x23
    24c8:	94000000 	bl	0 <mutex_lock>
    24cc:	340002f6 	cbz	w22, 2528 <qm_debug_write+0xf0>
    24d0:	710006df 	cmp	w22, #0x1
    24d4:	54000081 	b.ne	24e4 <qm_debug_write+0xac>  // b.any
    24d8:	f94027a0 	ldr	x0, [x29, #72]
    24dc:	7100041f 	cmp	w0, #0x1
    24e0:	54000769 	b.ls	25cc <qm_debug_write+0x194>  // b.plast
    24e4:	aa1703e0 	mov	x0, x23
    24e8:	94000000 	bl	0 <mutex_unlock>
    24ec:	a941d7b4 	ldp	x20, x21, [x29, #24]
    24f0:	928002a0 	mov	x0, #0xffffffffffffffea    	// #-22
    24f4:	a942dfb6 	ldp	x22, x23, [x29, #40]
    24f8:	91000273 	add	x19, x19, #0x0
    24fc:	f94037a2 	ldr	x2, [x29, #104]
    2500:	f9400261 	ldr	x1, [x19]
    2504:	ca010041 	eor	x1, x2, x1
    2508:	b50007e1 	cbnz	x1, 2604 <qm_debug_write+0x1cc>
    250c:	f9400bf3 	ldr	x19, [sp, #16]
    2510:	a8c77bfd 	ldp	x29, x30, [sp], #112
    2514:	d65f03c0 	ret
    2518:	93407c00 	sxtw	x0, w0
    251c:	f94017b6 	ldr	x22, [x29, #40]
    2520:	a941d7b4 	ldp	x20, x21, [x29, #24]
    2524:	17fffff5 	b	24f8 <qm_debug_write+0xc0>
    2528:	f94016a3 	ldr	x3, [x21, #40]
    252c:	f94027a0 	ldr	x0, [x29, #72]
    2530:	b9400061 	ldr	w1, [x3]
    2534:	6b01001f 	cmp	w0, w1
    2538:	54fffd62 	b.cs	24e4 <qm_debug_write+0xac>  // b.hs, b.nlast
    253c:	f8530061 	ldur	x1, [x3, #-208]
    2540:	d2880604 	mov	x4, #0x4030                	// #16432
    2544:	f2a00204 	movk	x4, #0x10, lsl #16
    2548:	53103c02 	lsl	w2, w0, #16
    254c:	8b040021 	add	x1, x1, x4
    2550:	b9400021 	ldr	w1, [x1]
    2554:	d50331bf 	dmb	oshld
    2558:	2a0103e0 	mov	w0, w1
    255c:	ca000000 	eor	x0, x0, x0
    2560:	b5000000 	cbnz	x0, 2560 <qm_debug_write+0x128>
    2564:	d50332bf 	dmb	oshst
    2568:	f8530060 	ldur	x0, [x3, #-208]
    256c:	12001421 	and	w1, w1, #0x3f
    2570:	2a020021 	orr	w1, w1, w2
    2574:	8b040004 	add	x4, x0, x4
    2578:	b9000081 	str	w1, [x4]
    257c:	d2880804 	mov	x4, #0x4040                	// #16448
    2580:	f2a00204 	movk	x4, #0x10, lsl #16
    2584:	8b040000 	add	x0, x0, x4
    2588:	b9400000 	ldr	w0, [x0]
    258c:	d50331bf 	dmb	oshld
    2590:	2a0003e1 	mov	w1, w0
    2594:	ca010021 	eor	x1, x1, x1
    2598:	b5000001 	cbnz	x1, 2598 <qm_debug_write+0x160>
    259c:	d50332bf 	dmb	oshst
    25a0:	f8530061 	ldur	x1, [x3, #-208]
    25a4:	12001400 	and	w0, w0, #0x3f
    25a8:	2a020000 	orr	w0, w0, w2
    25ac:	8b040021 	add	x1, x1, x4
    25b0:	b9000020 	str	w0, [x1]
    25b4:	aa1703e0 	mov	x0, x23
    25b8:	94000000 	bl	0 <mutex_unlock>
    25bc:	aa1403e0 	mov	x0, x20
    25c0:	a941d7b4 	ldp	x20, x21, [x29, #24]
    25c4:	a942dfb6 	ldp	x22, x23, [x29, #40]
    25c8:	17ffffcc 	b	24f8 <qm_debug_write+0xc0>
    25cc:	f94016a1 	ldr	x1, [x21, #40]
    25d0:	d50332bf 	dmb	oshst
    25d4:	f8530021 	ldur	x1, [x1, #-208]
    25d8:	91440021 	add	x1, x1, #0x100, lsl #12
    25dc:	91046021 	add	x1, x1, #0x118
    25e0:	b9000020 	str	w0, [x1]
    25e4:	17fffff4 	b	25b4 <qm_debug_write+0x17c>
    25e8:	92800360 	mov	x0, #0xffffffffffffffe4    	// #-28
    25ec:	f9400fb4 	ldr	x20, [x29, #24]
    25f0:	17ffffc2 	b	24f8 <qm_debug_write+0xc0>
    25f4:	928001a0 	mov	x0, #0xfffffffffffffff2    	// #-14
    25f8:	f94017b6 	ldr	x22, [x29, #40]
    25fc:	a941d7b4 	ldp	x20, x21, [x29, #24]
    2600:	17ffffbe 	b	24f8 <qm_debug_write+0xc0>
    2604:	a901d7b4 	stp	x20, x21, [x29, #24]
    2608:	a902dfb6 	stp	x22, x23, [x29, #40]
    260c:	94000000 	bl	0 <__stack_chk_fail>

0000000000002610 <hisi_qm_uninit>:
    2610:	a9bd7bfd 	stp	x29, x30, [sp, #-48]!
    2614:	910003fd 	mov	x29, sp
    2618:	a90153f3 	stp	x19, x20, [sp, #16]
    261c:	aa0003f3 	mov	x19, x0
    2620:	f90013f5 	str	x21, [sp, #32]
    2624:	3945a000 	ldrb	w0, [x0, #360]
    2628:	f9400a74 	ldr	x20, [x19, #16]
    262c:	aa1403f5 	mov	x21, x20
    2630:	340001a0 	cbz	w0, 2664 <hisi_qm_uninit+0x54>
    2634:	f9401e62 	ldr	x2, [x19, #56]
    2638:	b4000162 	cbz	x2, 2664 <hisi_qm_uninit+0x54>
    263c:	b9400260 	ldr	w0, [x19]
    2640:	7100841f 	cmp	w0, #0x21
    2644:	540005a0 	b.eq	26f8 <hisi_qm_uninit+0xe8>  // b.none
    2648:	a9440663 	ldp	x3, x1, [x19, #64]
    264c:	d2800004 	mov	x4, #0x0                   	// #0
    2650:	9102c280 	add	x0, x20, #0xb0
    2654:	94000000 	bl	0 <dma_free_attrs>
    2658:	f9400a75 	ldr	x21, [x19, #16]
    265c:	a903fe7f 	stp	xzr, xzr, [x19, #56]
    2660:	f900267f 	str	xzr, [x19, #72]
    2664:	52800001 	mov	w1, #0x0                   	// #0
    2668:	aa1503e0 	mov	x0, x21
    266c:	94000000 	bl	0 <pci_irq_vector>
    2670:	aa1303e1 	mov	x1, x19
    2674:	94000000 	bl	0 <free_irq>
    2678:	b9400260 	ldr	w0, [x19]
    267c:	7100841f 	cmp	w0, #0x21
    2680:	54000220 	b.eq	26c4 <hisi_qm_uninit+0xb4>  // b.none
    2684:	aa1403e0 	mov	x0, x20
    2688:	94000000 	bl	0 <pci_free_irq_vectors>
    268c:	f9400e60 	ldr	x0, [x19, #24]
    2690:	94000000 	bl	0 <iounmap>
    2694:	d2804001 	mov	x1, #0x200                 	// #512
    2698:	aa1403e0 	mov	x0, x20
    269c:	94000000 	bl	0 <pci_select_bars>
    26a0:	2a0003e1 	mov	w1, w0
    26a4:	aa1403e0 	mov	x0, x20
    26a8:	94000000 	bl	0 <pci_release_selected_regions>
    26ac:	aa1403e0 	mov	x0, x20
    26b0:	94000000 	bl	0 <pci_disable_device>
    26b4:	f94013f5 	ldr	x21, [sp, #32]
    26b8:	a94153f3 	ldp	x19, x20, [sp, #16]
    26bc:	a8c37bfd 	ldp	x29, x30, [sp], #48
    26c0:	d65f03c0 	ret
    26c4:	52800021 	mov	w1, #0x1                   	// #1
    26c8:	aa1503e0 	mov	x0, x21
    26cc:	94000000 	bl	0 <pci_irq_vector>
    26d0:	aa1303e1 	mov	x1, x19
    26d4:	94000000 	bl	0 <free_irq>
    26d8:	b9400660 	ldr	w0, [x19, #4]
    26dc:	35fffd40 	cbnz	w0, 2684 <hisi_qm_uninit+0x74>
    26e0:	52800061 	mov	w1, #0x3                   	// #3
    26e4:	aa1503e0 	mov	x0, x21
    26e8:	94000000 	bl	0 <pci_irq_vector>
    26ec:	aa1303e1 	mov	x1, x19
    26f0:	94000000 	bl	0 <free_irq>
    26f4:	17ffffe4 	b	2684 <hisi_qm_uninit+0x74>
    26f8:	d50332bf 	dmb	oshst
    26fc:	f9400e60 	ldr	x0, [x19, #24]
    2700:	52800021 	mov	w1, #0x1                   	// #1
    2704:	91081000 	add	x0, x0, #0x204
    2708:	b9000001 	str	w1, [x0]
    270c:	94000000 	bl	0 <ktime_get>
    2710:	9143d015 	add	x21, x0, #0xf4, lsl #12
    2714:	910902b5 	add	x21, x21, #0x240
    2718:	14000007 	b	2734 <hisi_qm_uninit+0x124>
    271c:	94000000 	bl	0 <ktime_get>
    2720:	eb0002bf 	cmp	x21, x0
    2724:	5400014b 	b.lt	274c <hisi_qm_uninit+0x13c>  // b.tstop
    2728:	d2800141 	mov	x1, #0xa                   	// #10
    272c:	d2800060 	mov	x0, #0x3                   	// #3
    2730:	94000000 	bl	0 <usleep_range>
    2734:	f9400e60 	ldr	x0, [x19, #24]
    2738:	91082000 	add	x0, x0, #0x208
    273c:	b9400000 	ldr	w0, [x0]
    2740:	3607fee0 	tbz	w0, #0, 271c <hisi_qm_uninit+0x10c>
    2744:	f9401e62 	ldr	x2, [x19, #56]
    2748:	17ffffc0 	b	2648 <hisi_qm_uninit+0x38>
    274c:	f9400e60 	ldr	x0, [x19, #24]
    2750:	91082000 	add	x0, x0, #0x208
    2754:	b9400000 	ldr	w0, [x0]
    2758:	3707ff60 	tbnz	w0, #0, 2744 <hisi_qm_uninit+0x134>
    275c:	f9400a60 	ldr	x0, [x19, #16]
    2760:	90000001 	adrp	x1, 0 <__raw_readl>
    2764:	91000021 	add	x1, x1, #0x0
    2768:	9102c000 	add	x0, x0, #0xb0
    276c:	94000000 	bl	0 <_dev_err>
    2770:	f9401e62 	ldr	x2, [x19, #56]
    2774:	17ffffb5 	b	2648 <hisi_qm_uninit+0x38>
    2778:	f98002b1 	prfm	pstl1strm, [x21]
    277c:	885f7ea0 	ldxr	w0, [x21]
    2780:	4b170000 	sub	w0, w0, w23
    2784:	88017ea0 	stxr	w1, w0, [x21]
    2788:	35ffffa1 	cbnz	w1, 277c <hisi_qm_uninit+0x16c>
    278c:	17fff7f6 	b	764 <qm_qp_work_func+0x11c>
    2790:	f9800011 	prfm	pstl1strm, [x0]
    2794:	c85f7c02 	ldxr	x2, [x0]
    2798:	8a210042 	bic	x2, x2, x1
    279c:	c8037c02 	stxr	w3, x2, [x0]
    27a0:	35ffffa3 	cbnz	w3, 2794 <hisi_qm_uninit+0x184>
    27a4:	17fff819 	b	808 <hisi_qm_release_qp+0x80>
    27a8:	f9800051 	prfm	pstl1strm, [x2]
    27ac:	885f7c40 	ldxr	w0, [x2]
    27b0:	11000400 	add	w0, w0, #0x1
    27b4:	88017c40 	stxr	w1, w0, [x2]
    27b8:	35ffffa1 	cbnz	w1, 27ac <hisi_qm_uninit+0x19c>
    27bc:	17fff847 	b	8d8 <hisi_qp_send+0xa0>
    27c0:	f9800051 	prfm	pstl1strm, [x2]
    27c4:	c85f7c40 	ldxr	x0, [x2]
    27c8:	b2400000 	orr	x0, x0, #0x1
    27cc:	c8017c40 	stxr	w1, x0, [x2]
    27d0:	35ffffa1 	cbnz	w1, 27c4 <hisi_qm_uninit+0x1b4>
    27d4:	17fff8aa 	b	a7c <hisi_qm_stop_qp+0x9c>
    27d8:	f9800031 	prfm	pstl1strm, [x1]
    27dc:	c85f7c20 	ldxr	x0, [x1]
    27e0:	aa150000 	orr	x0, x0, x21
    27e4:	c8027c20 	stxr	w2, x0, [x1]
    27e8:	35ffffa2 	cbnz	w2, 27dc <hisi_qm_uninit+0x1cc>
    27ec:	17fff8f9 	b	bd0 <hisi_qm_create_qp+0xa8>
    27f0:	f98002d1 	prfm	pstl1strm, [x22]
    27f4:	c85f7ec0 	ldxr	x0, [x22]
    27f8:	8a350000 	bic	x0, x0, x21
    27fc:	c8017ec0 	stxr	w1, x0, [x22]
    2800:	35ffffa1 	cbnz	w1, 27f4 <hisi_qm_uninit+0x1e4>
    2804:	17fff93e 	b	cfc <hisi_qm_create_qp+0x1d4>
