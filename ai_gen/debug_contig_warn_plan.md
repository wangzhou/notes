# Contig PTE[k] LOCKED WARN 调试计划

## 问题

正常起虚机（无迁移，无 dirty logging）时，`stage2_map_contig_leaf` 的 `WARN_ON_ONCE(stage2_pte_is_locked(*ptep))` 概率触发。

按当前分析，触发条件（"状态 3b"）是：PTE[0]=valid 非 CONT 时，T1 走 contig BBM（锁 PTE[0]），T2 走单页 BBM（在 PTE[k] 上 cmpxchg → LOCKED），两路在 PTE[k] 碰撞。

T1/T2 都是 map 路径，需要 vma_pagesize 分歧——一个拿到 PROT_CONT，一个没拿到。

## 单页路径入口回退

正常起虚机时，真正并发的 walker 只有 **map vs map**，持 read_lock：

- **unmap** — write_lock 排他，排除
- **wrprotect** — write_lock 排他，排除
- **mkyoung** — HAFDBS 硬件自动管理 AF，排除（加 WARN 验证）
- **relax_perms** — contig 下 vma_pagesize ≠ fault_granule，走不到快速路径，落到 map（加 WARN 验证）
- **test_clear_young** — 编译时互斥（`IS_ENABLED(CONFIG_KVM_MMU_LOCKLESS_AGING)` 时不创 contig）

## 加的 WARN（均在 mmu.c）

| 位置 | 目的 |
|------|------|
| `CONT_PTE_SHIFT` else 分支（`fault_supports` 否决处） | 抓 VMA 说 64K 但 memslot 条件不满足 |
| `handle_access_fault` 入口 | 确认 mkyoung 路径不被调用 |
| `relax_perms` 快速路径调用前 | 确认 perm fault 不走 relax_perms |

## 验证逻辑

1. 正常起虚机，压力或长时间跑
2. 如果 `CONT_PTE_SHIFT` else 的 WARN 爆了 → memslot 对齐/边界问题，force_pte 分歧的根因
3. 如果 `handle_access_fault` 的 WARN 爆了 → HAFDBS 没生效，mkyoung 也在跑
4. 如果 `relax_perms` 的 WARN 爆了 → perm fault 走了 relax_perms 而非 map
5. 如果只有 contig 的 WARN 爆，但以上三个都不爆 → 还有其他未知触发路径
