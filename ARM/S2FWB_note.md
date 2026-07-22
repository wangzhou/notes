-v0.1 2026.03.17 Sherlock init
-v0.2 2026.08.04 Sherlock 补齐基本逻辑

简介：记录ARM64 S2FWB特性相关的软硬件逻辑。


## 硬件逻辑

ARMv8.1引入的特性，通过HCR_EL2.FWB使能。

Stage-2页表翻译的任何Normal memory访问，硬件忽略PTE里的memory type bits，统一按
相关配置处理，一般会配置成Write-Back Cacheable。

本质是把cache策略的控制权从guest(stage-1页表)收到hypervisor手里。guest再怎么设
PTE的memory type也改不了硬件实际用的缓存策略。

收益：KVM做stage-2 unmap/flush时不再需要dcache_clean_inval_poc来清扫cache，因为
所有访问强制WB，不存在"non-cacheable的访问绕过了cache里的脏数据"这种不一致。

更近一步解释如下。对于同一PA，虚拟化情况下，其实就有两个访问入口的，一个是guest
里的访问，一个是host上的访问，访问的cache属性受页表控制，其中guest一侧受两级页表
的控制，最后的cache属性按两级页表里最强的属性来。host侧的访问一般是cache的，如果
guest侧按non-cache访问，有可能数据还是cache里，从而访问到不对的数据。
```
                    guest VA
                       /
    host VA           /  non-cache
        \            /
         \         IPA
          \        /
           \      /
            \    /
              PA
```
把guest的访问强制配置成Write-Back Cacheable，和host这边的属性一样，就不会错了。

## 软件支持

没有S2FWB时，以下位置需要dcache/icache刷cache操作，都在arch/arm64/kvm/hyp/pgtable.c。

### map路径: dcache(line 1045)

安装新的cacheable映射前，清扫陈旧cache行。

```c
if (!kvm_pgtable_walk_skip_cmo(ctx) && mm_ops->dcache_clean_inval_poc &&
    stage2_pte_cacheable(pgt, new))
    mm_ops->dcache_clean_inval_poc(kvm_pte_follow(new, mm_ops), granule);
```


### map路径: icache(line 1050)

安装新的可执行映射前，刷I-cache。

```c
if (!kvm_pgtable_walk_skip_cmo(ctx) && mm_ops->icache_inval_pou &&
    stage2_pte_executable(new))
    mm_ops->icache_inval_pou(kvm_pte_follow(new, mm_ops), granule);
```


### unmap路径: dcache(line 1226, 1236)

拆cacheable映射后，把脏cache行写回内存。有FWB时need_flush=false跳过。

```c
need_flush = !cpus_have_final_cap(ARM64_HAS_STAGE2_FWB);  // line 1226
...
if (need_flush && mm_ops->dcache_clean_inval_poc)         // line 1236
    mm_ops->dcache_clean_inval_poc(...);
```


### relax_perms路径: icache(line 1295)

给已有映射加X权限前，刷I-cache。

```c
if (mm_ops->icache_inval_pou &&
    stage2_pte_executable(pte) && !stage2_pte_executable(ctx->old))
    mm_ops->icache_inval_pou(kvm_pte_follow(pte, mm_ops), granule);
```


### flush路径: dcache(line 1446, 1460)

显式flush操作。有FWB时整个函数直接return 0。

```c
if (cpus_have_final_cap(ARM64_HAS_STAGE2_FWB))           // line 1460
    return 0;
...
mm_ops->dcache_clean_inval_poc(...);                      // line 1446
```

需要反过来看这个逻辑，如果没有S2FWB，我们需要在哪里加刷cache的操作。有了S2FWB，
就是这些刷cache的地方都不需要了。
