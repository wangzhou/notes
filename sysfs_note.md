sys文件系统学习
---------------

-v0.1 2015.6.22 Sherlock draft

在调试linux驱动的时候需要实时的读出，写入寄存器或是变量的值。使用sys文件系统
提供的接口写一个驱动插入内核调试是一个好办法。本文分析这样一个驱动该怎么写。
其实内核中已经提供的样板例子, 他们的路径在 linux/samples/kobject/*

为了更好的理解上面的代码，我们现在列举其中关键的数据结构以及他们之间的逻辑关系。
主要的数据结构有：struct kobject, struct kset, struct kobj_type,
struct attribute, struct sysfs_ops

struct kobject表示一个内核对象，是最核心的数据结构。从代码上看，它的抽象是最高
的，几乎再具体一点的内核对象(比如 struct device)都包含有一个kobject; 从逻辑上
讲kobject是其他内核对象的父对象; 从sys文件系统讲，每个kobject在sys文件系统中都
对应一个目录。实际上就连struct kset对象都包含一个kobject，kset表示一些kobject
的集合，但是集合的本身也是一个内核对象。

每个kobject都有一个指向kobj_type的指针。kobj_type里包含一个struct sysfs_ops的
指针和struct attribute的指针数组。从sys文件系统的角度看attribute指针数组中每个
struct attribute指针指向的结构都表示这个kobject对应目录下的一个文件, 而sysfs_op
中含有读写这些文件的函数：store, show

有了这些基础，现在以kset-sample.c




