# QEMU KVM 热迁移中 NUMA 拓扑一致性校验分析

## 1. 背景

QEMU 热迁移时，guest 的 ACPI 表（SRAT/SLIT）作为 guest 内存的一部分从源端迁移到目标端，**不会在目标端重新生成**。但目标端 QEMU 会根据自己的 `-numa` 命令行参数构建内部 `numa_state` 数据结构。如果两端 NUMA 配置不一致，会导致 guest 看到的 ACPI 拓扑与实际硬件拓扑不匹配。

## 2. NUMA 信息在迁移中的流转

### 2.1 源端启动时生成 ACPI 表

```
-numa node,nodeid=0,mem=4G,cpus=0-3
-numa node,nodeid=1,mem=4G,cpus=4-7
-numa dist,src=0,dst=1,val=20

→ 生成 SRAT 表（CPU/内存与 NUMA node 的亲和关系）
→ 生成 SLIT 表（NUMA 距离矩阵）
→ 写入 guest 内存
```

### 2.2 迁移过程

- SRAT/SLIT 作为 guest RAM 的一部分传输到目标端
- 目标端 QEMU 按自己的 `-numa` 参数构建内部 `MachineState->numa_state`
- **矛盾**：guest 看到的 ACPI 表是源端的，但目标端 QEMU 的内部 NUMA 状态是按目标端参数构建的

## 3. 当前 QEMU 的校验现状

### 3.1 有校验的部分

| 检查项 | 机制 | 说明 |
|--------|------|------|
| 内存总量 | RAMBlock 匹配 | `migration/ram.c` 中按 RAMBlock 的 idstr 和 length 匹配 |
| 每个 node 的内存大小 | RAMBlock 名称+大小 | 部分覆盖，取决于 RAMBlock 划分方式 |
| CPU 数量 | VMState | CPU 相关 vmstate 加载时会校验 |

### 3.2 没有校验的部分

| 检查项 | 风险等级 | 后果 |
|--------|---------|------|
| NUMA node 数量 | 高 | guest 调度策略完全错误 |
| CPU-to-node 绑定关系 | 高 | CPU 亲和性与实际拓扑不符 |
| NUMA 距离矩阵（SLIT） | 中 | 内存访问延迟预估错误 |
| 内存热插拔区域的 NUMA 归属 | 中 | 热插拔内存分配到错误 node |

### 3.3 核心风险

迁移后 guest 内核的 NUMA 调度策略基于源端的 ACPI SRAT/SLIT，但实际硬件拓扑已经变了。可能导致：
- 性能严重下降（跨 node 访问内存）
- 不会 crash，问题非常隐蔽
- 难以定位原因

## 4. 相关源码位置

| 文件 | 内容 |
|------|------|
| `hw/core/numa.c` | NUMA 拓扑解析和内部数据结构 |
| `hw/core/machine.c` | MachineState 中的 numa_state |
| `hw/acpi/aml-build.c` | SRAT/SLIT ACPI 表的构建 |
| `hw/acpi/piix4.c` | PIIX4 ACPI PM 设备的 vmstate |
| `hw/acpi/ich9.c` | ICH9 ACPI PM 设备的 vmstate |
| `hw/acpi/memory_hotplug.c` | 内存热插拔 ACPI 状态 |
| `migration/ram.c` | RAMBlock 迁移和匹配逻辑 |
| `migration/migration.c` | 迁移主流程 |

## 5. 添加 NUMA 拓扑迁移校验的方案

### 5.1 方案思路

在 machine 层面注册 vmstate，将 NUMA 拓扑摘要信息作为迁移状态的一部分，在 `post_load` 中校验源端和目标端的一致性。

### 5.2 示例代码

```c
/* 在 hw/core/numa.c 或 machine 的 vmstate 中添加 */

// 1. 定义 NUMA 拓扑摘要结构
typedef struct NumaMigrationState {
    uint16_t num_nodes;
    uint64_t node_mem[MAX_NODES];        // 每个 node 的内存大小
    uint16_t node_cpus[MAX_NODES];       // 每个 node 的 CPU 数量
    uint8_t  distance[MAX_NODES][MAX_NODES]; // SLIT 距离矩阵
} NumaMigrationState;

// 2. 在 post_load 中校验
static int numa_post_load(void *opaque, int version_id)
{
    NumaMigrationState *src = opaque;       // 源端迁移过来的
    MachineState *ms = MACHINE(qdev_get_machine());

    // 校验 node 数量
    if (src->num_nodes != ms->numa_state->num_nodes) {
        error_report("NUMA node count mismatch: src=%d dst=%d",
                     src->num_nodes, ms->numa_state->num_nodes);
        return -EINVAL;
    }

    // 校验每个 node 的内存
    for (int i = 0; i < src->num_nodes; i++) {
        if (src->node_mem[i] != ms->numa_state->nodes[i].node_mem) {
            error_report("NUMA node %d memory mismatch", i);
            return -EINVAL;
        }
    }

    // 校验 SLIT 距离矩阵
    for (int i = 0; i < src->num_nodes; i++) {
        for (int j = 0; j < src->num_nodes; j++) {
            if (src->distance[i][j] !=
                ms->numa_state->nodes[i].distance[j]) {
                error_report("NUMA distance mismatch [%d][%d]", i, j);
                return -EINVAL;
            }
        }
    }

    return 0;
}

// 3. 注册 vmstate
static const VMStateDescription vmstate_numa_topo = {
    .name = "numa-topology",
    .version_id = 1,
    .post_load = numa_post_load,
    .fields = (VMStateField[]) {
        VMSTATE_UINT16(num_nodes, NumaMigrationState),
        VMSTATE_UINT64_ARRAY(node_mem, NumaMigrationState, MAX_NODES),
        VMSTATE_UINT16_ARRAY(node_cpus, NumaMigrationState, MAX_NODES),
        VMSTATE_END_OF_LIST()
    }
};
```

### 5.3 注册方式

在 `machine_class_init` 或 `pc_machine_initfn` 中调用 `vmstate_register` 注册上述 vmstate，使其随迁移流自动 save/load。

## 6. 建议

1. **短期**：运维层面确保源端和目标端使用完全相同的 `-numa` 参数和 machine type 版本
2. **中期**：在迁移管理层（如 libvirt）添加 NUMA 配置一致性的前置检查
3. **长期**：向 QEMU 上游提交 NUMA 拓扑 vmstate 校验补丁，从根本上解决问题
