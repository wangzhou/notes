blkring基本逻辑分析
====================

v1.0 2026-04-10 Sherlock init
v1.1 2026-05-01 Sherlock ...
v1.2 2026-05-04 Sherlock ...

简介：分析下blkring无锁队列的基本逻辑。

## 概述

block ring(blkring)是ARM开发的一个并发计算库里的一个软件无锁队列的实现，这个库的地址在[这里](https://github.com/ARM-software/progress64.git)。
对应代码在这个库的src/p64_blkring.c, 这个软件无锁队列的性能(并发吞吐量)目前看起来很高。

## 数据结构
blkring的内存布局如下：
```
+---------------------------------------------------------+
|                     p64_blkring_t                       |
+----------------------------+----------------------------+
|  cons (cacheline0)         |  prod (cacheline1)         |
|  +----------+----------+   |  +----------+----------+   |
|  |  head    |  mask    |   |  |  tail    |  mask    |   |
|  +----------+----------+   |  +----------+----------+   |
+----------------------------+----------------------------+
|                        ring[]                           |
|  +---------------+---------------+---------------+      |
|  | slot[0]       | slot[1]       | slot[2]       | ...  |
|  | {sn, elem}    | {sn, elem}    | {sn, elem}    |      |
|  +---------------+---------------+---------------+      |
+---------------------------------------------------------+
cons/prod是队列的头尾信息，cons/prod各自独占一个缓存行，生产者只写 prod.tail，
消费者只写cons.head。ring是队列，slot是每个队列元素。
```

slot内部结构如下：
```
+----------------------------+
|  __int128 (128bit)         |
|  +-----------+----------+  |
|  |  sn       |  elem    |  |
|  |  8 Byte   |  8 字节  |  |
|  +-----------+----------+  |
+----------------------------+
```
sn是slot的序号，sn可以一直增长(超过slot个数的sn)。elem是元素指针，是队列元素的实际数据。

## 入队完整代码解析
```c
void p64_blkring_enqueue(p64_blkring_t *rb, void *const elems[], uint32_t nelem)
{
    // 抢占序号区间。
    uint32_t sn = atomic_fetch_add(&rb->prod.tail, nelem, RELAXED);
    // 队列size的mask，因为队列长度必然是2的幂次，所以mask用全1表示队列size mask。
    uint32_t mask = *addr_dep(&rb->prod.mask, sn);

    // 逐个写入slot
    for (uint32_t i = 0; i < nelem; i++, sn++)
    {
        if (elems[i] == NULL) abort();
        /*
         * 注意，sn是逻辑上的slot编号，为了使连续写入位置不在一个cache line上，
         * 这里使用swizzle函数重新计算了实际的写入位置。具体计算方法是根据cache
         * line大小和一个slot大小(16B)，比如，对于cache line为64的情况，一个cache
         * line放4个slot，所以，swizzle计算实际存放位置是：
         *   sn         0   1   2   3   4  ...
         *   实际位置   0   4   8   12  1  ...
         * 这样做还是在尽量错开cache line。
         */
        uint32_t idx = swizzle(sn) & mask;

#ifdef __ARM_FEATURE_ATOMICS
        // LSE 分支: CASP 原子写入。slot.elem是NULL，表示该slot没有保存元素。
        struct ringslot cmp = {sn, NULL};
        struct ringslot swp = {sn, elems[i]};
        /* 如果写入位置是sn和NULL，才写入。队列初始化的时候slot.sn要给对应的初值。
         *
         * 注意，这样的实现，实际上对于写入者在一个slot上构建了一个队列。读出者在
         * 读出数据的时候，同时更新下一次应该写入的sn值，防止逻辑上出现错误：
         *
         * 比如，队列不断写入，但是没有读出，会出现多个写入者竞争一个写入位置的
         * 情况。如下的例子，write1写入的值应该是slot[mask + 1(队列长度)，elem1]，
         * write2写入的值应该是slot[2(mask + 1)，elem2]，读出slot[0, xxx]时，会
         * 原子的把这个slot的值更新为slot[mask + 1，NULL]，这样write1就可以写入
         * 对应的值，write2则继续等待。
         *
         *      writer2
         *                                   
         *      writer1
         *                                    
         *   slot[0, xxx]  slot[1, xxx]  slot[2, xxx] ...
         *
         * 注意，ARM架构下，这里128bit的CAS是一个CASP指令。
         */
        while (atomic_cas_n(&rb->ring[idx].i128, cmp.i128, swp.i128, RELEASE) != cmp.i128)
        {
            // 原子读elem的值，直到读到elem的值为NULL。
            wait_until_equal_ptr(&rb->ring[idx].elem, NULL, RELAXED);
        }
#else
        // 无LSE分支: 自旋等待
        struct ringslot old;
        do {
            PREFETCH_FOR_WRITE(&rb->ring[idx]);
            old.sn = atomic_load_n(&rb->ring[idx].sn, RELAXED);
            old.elem = atomic_load_ptr(addr_dep(&rb->ring[idx].elem, old.sn), RELAXED);
        } while (old.sn != sn || old.elem != NULL);
        atomic_store_ptr(&rb->ring[idx].elem, elems[i], RELEASE);
#endif
    }
}
```

## 出队完整代码解析
```c
void p64_blkring_dequeue(p64_blkring_t *rb, void *elems[], uint32_t nelem, uint32_t *index)
{
    // 抢占序号区间。注意返回值head是旧值。
    uint32_t head = atomic_fetch_add(&rb->cons.head, nelem, RELAXED);
    blkring_dequeue(rb, elems, nelem, index, head);
}

static void blkring_dequeue(rb, elems, nelem, index, sn)
{
    uint32_t mask = *addr_dep(&rb->cons.mask, sn);
    *index = sn;

    for (uint32_t i = 0; i < nelem; i++, sn++)
    {
        uint32_t idx = swizzle(sn) & mask;

        // 等待slot有数据。
        struct ringslot old;
        do {
#ifdef __ARM_FEATURE_ATOMICS
            old.i128 = atomic_icas_n(&rb->ring[idx].i128, ACQUIRE);
#else
            PREFETCH_FOR_WRITE(&rb->ring[idx]);
            old.sn = atomic_load_n(&rb->ring[idx].sn, RELAXED);
            old.elem = atomic_load_ptr(addr_dep(&rb->ring[idx].elem, old.sn), ACQUIRE);
#endif
        // 注意，这里sn的判断和如上写入者多轮写入的逻辑是一样的，只不过这里是读者这边。
        } while (old.sn != sn || old.elem == NULL);

        // 清空slot.elem，同时把slot.sn增加一个队列size。
#ifdef __ARM_FEATURE_ATOMICS
        struct ringslot swp = {sn + mask + 1, NULL};
        atomic_cas_n(&rb->ring[idx].i128, old.i128, swp.i128, RELAXED);
#else
        atomic_store_ptr(&rb->ring[idx].elem, NULL, RELAXED);
        atomic_store_n(&rb->ring[idx].sn, sn + mask + 1, RELEASE);
#endif
        elems[i] = old.elem;
    }
}
```
