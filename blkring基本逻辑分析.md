blkring基本逻辑分析
====================

v1.0 2026-04-10 Sherlock init

简介：分析下blkring无锁队列的基本逻辑。

## 概述

https://github.com/ARM-software/progress64.git

blkring (blocking ring buffer) 是一个支持多生产者多消费者(MP/MC)的批量无锁环形队列。
核心设计目标：以最少的共享原子操作完成批量入队/出队，极大提升并发吞吐量。

## 0. 数据结构

```
内存布局:

+---------------------------------------------------------+
|                     p64_blkring_t                       |
+----------------------------+----------------------------+
|  cons (缓存行 0)           |  prod (缓存行 1)           |
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
cons 和 prod 各自独占一个缓存行 -> 生产者只写 prod.tail,
消费者只写 cons.head -> 零干扰。
```

```
槽内部结构:

+----------------------------+
|  __int128 (128bit)         |
|  +-----------+----------+  |
|  |  sn       |  elem    |  |
|  |  8 Byte   |  8 字节  |  |
|  +-----------+----------+  |
+----------------------------+
```
sn 是序号(标记槽的代数)，elem 是元素指针(实际数据)。


## 1. 入队完整代码解析

```c
void p64_blkring_enqueue(p64_blkring_t *rb, void *const elems[], uint32_t nelem)
{
    // 第1步: 抢占序号区间
    uint32_t sn = atomic_fetch_add(&rb->prod.tail, nelem, RELAXED);
    uint32_t mask = *addr_dep(&rb->prod.mask, sn);

    // 第2步: 逐个写入槽
    for (uint32_t i = 0; i < nelem; i++, sn++)
    {
        if (elems[i] == NULL) abort();
        uint32_t idx = swizzle(sn) & mask;

#ifdef __ARM_FEATURE_ATOMICS
        // LSE 分支: CASP 原子写入
        struct ringslot cmp = {sn, NULL};
        struct ringslot swp = {sn, elems[i]};
        while (atomic_cas_n(&rb->ring[idx].i128, cmp.i128, swp.i128, RELEASE) != cmp.i128)
        {
            wait_until_equal_ptr(&rb->ring[idx].elem, NULL, RELAXED);
        }
#else
        // 无 LSE 分支: 自旋等待
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

```
入队示例: enqueue(ring, [A,B,C], 3)

第1步: fetch_add(&tail, 3) = 0，tail -> 3，获得序号 0,1,2

第2步:
  i=0, sn=0: idx = swizzle(0)&15 = 0
    CASP(&ring[0], {0,NULL}->{0,A}) 成功
  i=1, sn=1: idx = swizzle(1)&15 = 4
    CASP(&ring[4], {1,NULL}->{1,B}) 成功
  i=2, sn=2: idx = swizzle(2)&15 = 8
    CASP(&ring[8], {2,NULL}->{2,C}) 成功
```

## 2. 出队完整代码解析

```c
void p64_blkring_dequeue(p64_blkring_t *rb, void *elems[], uint32_t nelem, uint32_t *index)
{
    // 第1步: 抢占序号区间
    uint32_t head = atomic_fetch_add(&rb->cons.head, nelem, RELAXED);
    blkring_dequeue(rb, elems, nelem, index, head);
}

static void blkring_dequeue(...)
{
    uint32_t mask = *addr_dep(&rb->cons.mask, sn);
    *index = sn;

    for (uint32_t i = 0; i < nelem; i++, sn++)
    {
        uint32_t idx = swizzle(sn) & mask;

        // 等待槽有数据
        struct ringslot old;
        do {
#ifdef __ARM_FEATURE_ATOMICS
            old.i128 = atomic_icas_n(&rb->ring[idx].i128, ACQUIRE);
#else
            PREFETCH_FOR_WRITE(&rb->ring[idx]);
            old.sn = atomic_load_n(&rb->ring[idx].sn, RELAXED);
            old.elem = atomic_load_ptr(addr_dep(&rb->ring[idx].elem, old.sn), ACQUIRE);
#endif
        } while (old.sn != sn || old.elem == NULL);

        // 清空槽，序号前进一个 ring_size
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

```
出队示例: dequeue(ring, vec, 3, &index)

第1步: fetch_add(&head, 3) = 0，head -> 3，获得序号 0,1,2

第2步:
  i=0, sn=0: idx = swizzle(0)&15 = 0
    ICAS(&ring[0]) -> {0, elem=A}
    CASP(&ring[0], {0,A}->{16,NULL}) 成功
    vec[0] = A
  i=1, sn=1: idx = swizzle(1)&15 = 4
    ICAS(&ring[4]) -> {1, elem=B}
    vec[1] = B
  i=2, sn=2: idx = swizzle(2)&15 = 8
    ICAS(&ring[8]) -> {2, elem=C}
    vec[2] = C
```
