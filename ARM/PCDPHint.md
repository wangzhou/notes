-v0.1 2026.8.27 Sherlock init

简介：分析ARM PCDPHint特性的基本逻辑。


基本逻辑
---------

ARM9.6新增可选扩展FEAT_PCDPHINT(Producer-Consumer Data Placement Hints)，
提供STSHH和PRFM IR 两条hint指令，为类似"生产者 store -> 消费者轮询"模式提供硬件
级定向转发能力，硬件的可能实现就是把cache保留在本core或者推向目的core。

STSHH可以加KEEP或者STRM参数，KEEP表示留住本地的cache，STRM表示把信息推向目的core
cache。PRFM IR通过参数指定预取的地址，也有类似的KEEP/STRM参数，同时PRFM IR还有其
它参数控制预取的cache level和地址地址属性。

想象下硬件可能的实现原理。先只看STSHH STRM和PRFM KEEP的使用场景，PRFM可以先指定
要预取的地址，硬件把这个地址在cache系统里做标记，当有STSHH STRM的hint时，cache
系统会识别到这个地址，然后把这个地址上的数据发到对应核的cache上。
```
  stshh strm         prfm keep, addr  
  store x0, addr     load x1, addr 

  core0              core1

  local cache        local cache

          share cache 
```
比如，如上的场景中，core1上的指令触发share cache标记addr这个地址，当core0上的
store x0, addr相关请求访问到share cache，触发addr的这个标记，硬件把x0的值直接发
送到core1的local cache，core0的local cache标记成invalid。

可能的优化点
-------------

- C库的锁

- 内核的spinlock，futex，rwlock

- 无所队列的实现。e.g. DPDK无锁队列

- ...

公共代码如何加入ARM hint指令
-----------------------------


