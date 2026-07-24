- v0.1 2026.8.20 Sherlock init
- v0.2 2026.8.21 Sherlock 增加剩余逻辑

基本逻辑
---------

X86很早就支持pv-spinlock，主线上ARM现在都不支持，社区之前有人尝试过支持，相关代码
在[这里](https://lkml.org/lkml/2022/11/4/113)，openEuler也有尝试支持，在[这里](https://mailweb.openeuler.org/archives/list/kernel@openeuler.org/thread/6A6CBZPMTBJQHOH7MLZIF3IASCQSNNMK/#Y5TWBHJ27KDKRUMGCXHEIQZ6GMDJT2LT)。逻辑上看，社区的支持并不完整，openEuler
的逻辑相对完整，但是没有合入openEuler的正式版本。openEuler最新上传的版本在[这里](https://atomgit.com/openeuler/kernel/pull/26044)。

pv-spinlock的收益基础是虚拟化和host CPU的实际形态是不一样的。物理CPU时刻都在运行，
而vCPU只是host系统的一个线程，vCPU线程会有挂起的情况，guest系统并不知道这样的情况，
如果guest系统知道vCPU是否处于挂起状态，就可以基于此做优化。pv-spinlock就是这种大
背景下的一个优化。

pv-spinlock的基本逻辑可以总结为以下三点。

QEMU/KVM通过半虚拟化的方式，把vCPU线程是否被挂起这个信息告诉guest系统。一般是通过
guest/KVM共享guest的一段IPA地址空间，KVM在vCPU上下线的时候更新对应的信息，guest里
通过读这段地址上的数据得到vCPU是否在位。每个vCPU都有一个这样的IPA地址空间。

对于抢锁vCPU，比如，vCPU0持有锁但是被调度出去了，vCPU1在抢锁。vCPU1知道vCPU0不在位，
vCPU1不在死等，vCPU1自己放弃物理CPU资源。

对于持锁vCPU，比如，vCPU0持有锁、vCPU1在等锁。vCPU0释放锁的时候，可以唤醒vCPU1线程，
触发vCPU1上位。

主线的patch只实现了如上1和2(但是不涉及qspinlock，是在其它类型的锁里判断vCPU是否
在位)，openEuler的patch如上各点都实现了。

Guest和KVM通信
---------------

这个特性涉及Guest和KVM通信的点有如下三个，其实正好对应上面的三个点。

需要一块共享的IPA地址空间，传递vCPU是否在位。一般的实现是，在guest里为vCPU申请
per-vCPU的全局变量，通过SMCCC接口把这个变量的IPA地址传递给KVM。KVM在vCPU上下线的
时候更新这个标记。
```
kvm_arch_vcpu_put -> kvm_update_pvsched_preempted(vcpu, 1)
kvm_arch_vcpu_load -> kvm_update_pvsched_preempted(vcpu, 0)
```
注意kvm_update_pvsched_preempted里的一些细节：
```
 kvm_update_pvsched_preempted
   ...
   /* 上下线是原子上下文，需要关page fault */
   pagefault_disable     
   /* 
    * 更新IPA上的标记，这里通过IPA找见HVA，然后更新。如果缺页这里就没有更新，但是
    * 不会返回失败。结果是vCPU是否在位的hint不准一次。
    */
   kvm_put_guest(...)    
   pagefault_enable

   vcpu->arch.pv_preempted = !!preempted;
```

KVM需要提供guest pv_wait和pv_kick两个接口，一个触发vCPU线程睡眠，一个唤醒睡眠的
vCPU线程。ARM上这两个接口可以使用SMCCC实现。

Guest内核逻辑
--------------

当有pvspinlock实现的时候，内核启动的时候会根据pvspinlock的支持情况，选择是挂上普通
qspinlock(当前内核默认使用qspinlock作为spinlock的实现)的实现，还是挂上pvspinlock
的实现。

X86的回调类似如下，wait和kick是上面提到的pv_wait/pv_kick的回调。
```
struct pv_lock_ops {                                                            
        void (*queued_spin_lock_slowpath)(struct qspinlock *lock, u32 val);     
        struct paravirt_callee_save queued_spin_unlock;                         
                                                                                
        void (*wait)(u8 *ptr, u8 val);                                          
        void (*kick)(int cpu);                                                  
                                                                                
        struct paravirt_callee_save vcpu_is_preempted;                          
}
```
X86这里搞的比较复杂，采用动态替换的方式，应该基本上没有开销。逻辑上先可以理解成
不同回调函数的实现。

再下一层pvspinlock具体的实现是内核公共代码了，具体在kernel/locking/qspinlock.c里。
注意，这个文件的最后使用宏把queued_spin_lock_slowpath名字换成了__pv_queued_spin_lock_slowpath：
```
[...]
#undef  queued_spin_lock_slowpath
#define queued_spin_lock_slowpath       __pv_queued_spin_lock_slowpath

#include "qspinlock_paravirt.h"
#include "qspinlock.c"
[...]
```

可以看到queued_spin_lock_slowpath中，PV的逻辑是嵌到普通pvspinlock逻辑里的，PV的
逻辑是在必要的地方，触发抢锁的vCPU睡眠。PV unlock的逻辑是在qspinlock_paravirt.h
头文件里，基本逻辑是在unlock的时候唤醒睡眠的抢锁vCPU。
