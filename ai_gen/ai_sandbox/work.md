
分析下cube sandbox和agentEVN/firecracker这两个AI沙箱系统。要求如下：

1. 基于ARM host平台分析。
2. 分析和虚拟化相关的内容：沙箱启动，快照，快照恢复，沙箱克隆中使用到的关键技术。
3. 从虚机内存和虚机存储的角度分析如上关键技术是怎么实现的。
4. 独立分析下AI沙箱都有什么关键性能测试指标，以及对应的测试方法。
5. 独立分析潜在的软硬件结合的优化点。

另外，我是做ARM虚拟化的开发人员，需要切入基于ARM的AI沙箱技术研究和开发，你有什么
建议或者规划一个计划出来。

代码路径如下：

cube sandbox：~/CubeSandbox
agentEVN：~/AgentENV
firecracker：~/firecracker
linux内核：~/linux

文档写作要求(2026.09.06 迭代沉淀)：

1. 总览先行：关键技术先用表格呈现，给出整体概念；正文再分章打开分析技术细节。
2. 表格组织：按四个场景(沙箱启动、快照、快照恢复、克隆)拆成四张表，
   每张表的分析维度是CPU、内存、存储三行，列是CubeSandbox与AgentENV。
3. 直接写结论，不要铺垫过程；阅读指引之类的辅助小节不要。
4. 补充的关键技术(脏页追踪、镜像分层、内存复用与回收等)尽量整合进
   CPU/内存/存储三个维度里，不单独成节。
5. 分析以代码证据为准(file:line引用)，基于ARM host视角。

todo:

1. 给AI沙箱性能测试指标与方法.md补充具体测试命令(被中断，未完成)。
   已验证的命令入口：
   - AgentENV：make bench-snapshot / bench-ublk / bench-orchestrator-store /
     bench-oci-conversion(Makefile:162-179)，AENV_BENCH_FULL=1放开全量采样
   - CubeSandbox：tests/perf/cubebench.sh sections/run <章节>；
     examples/cube-bench bin/cube-bench -m create-only -c 50 -n 100 -t <模板>
   - firecracker 1.18：tools/devtool test -- tests/integration_tests/performance/
     test_snapshot.py -m nonci(pytest默认排除nonci，pytest.ini:8)
   注意：文中引用的tests/performance/旧路径需同步改为
   tests/integration_tests/performance/，test_snapshot.py的latencies_us
   行号改为134-137与294-302。

2. 在我这台机器上部署下cube sandbox，输出部署指导文档(当前目录下)。
   部署的文件可以放到~/tests/cube下

3. 在我这台机器上部署下agentENV，输出部署指导文档(当前目录下)。
   部署的文件可以放到~/tests/agentENV下
