- v0.1 2026.8.27 Sherlock init

简介：core-to-core-latency测试工具的用法和原理分析。


使用
----

一般使用core-to-core-latency这个小工具测试系统的core-to-core时延，github地址在：
https://github.com/nviennot/core-to-core-latency.git

这个工具使用rust写的，可以直接从源码编译，也可以使用rust的包管理工具cargo直接安装，
不管怎么用，都要先安装rust和cargo，openEuler上可以：
```
sudo yum install -y rust cargo
```

直接使用cargo安装：
```
cargo install core-to-core-latency
```
会安装到~/.cargo/bin下，把这个路径加入PATH就可以直接使用core-to-core-latency。

如下是一个Mac M5 air环境下，openEuler虚机里的测试结果。-b可以指定测试项，默认只跑
第一项，-c可以指定在哪些核上跑。
```
[wz@oe ~]$ core-to-core-latency -b 1,2,3
Num cores: 10
Num iterations per samples: 1000
Num samples: 300

1) CAS latency on a single shared cache line

           0       1       2       3       4       5       6       7       8       9   
      0
      1   46±1 
      2   63±1    49±0 
      3   43±0    43±0    42±0 
      4   42±1    44±0    44±0    43±0 
      5   44±1    42±0    41±0    43±0    41±0 
      6   44±0    42±0    42±0    42±0    43±0    44±0 
      7   41±0    43±0    42±0    43±0    43±0    43±0    44±0 
      8   42±0    43±0    43±0    43±0    44±0    42±0    42±0    41±0 
      9   43±0    43±0    42±0    43±0    42±0    44±0    42±0    42±0    42±0 

    Min  latency: 40.8ns ±0.2 cores: (8,7)
    Max  latency: 63.4ns ±0.6 cores: (2,0)
    Mean latency: 43.4ns

2) Single-writer single-reader latency on two shared cache lines

           0       1       2       3       4       5       6       7       8       9   
      0
      1   55±0 
      2   54±0    54±0 
      3   54±0    54±0    54±0 
      4   57±1    54±0    55±0    54±0 
      5   55±1    55±0    54±0    54±0    54±0 
      6   54±0    54±0    54±0    54±0    54±0    55±0 
      7   54±0    54±0    54±0    54±0    54±0    55±0    54±0 
      8   55±0    54±0    54±0    54±0    54±0    54±0    54±0    54±0 
      9   55±0    54±0    54±0    54±0    54±0    54±0    54±0    54±0    54±0 

    Min  latency: 53.6ns ±0.2 cores: (8,1)
    Max  latency: 56.6ns ±1.0 cores: (4,0)
    Mean latency: 54.2ns

thread 'main' panicked at /home/wz/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/cor
e-to-core-latency-1.2.0/src/utils.rs:45:29:
This benchmark is only compatible with x86
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

测试原理
---------

todo

