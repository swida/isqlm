# \placement 命令实现遇到的 Region Split 问题

## 背景

在 isqlm 中实现 `\placement` 命令，目标是：对一个已有表，split region 使后续新插入的数据写到指定的新节点上。

## 实现步骤

```
Step 1: ALTER INSTANCE SPLIT REGION <region_id> IN RG <rg_id> AT KEY '<split_key>' FORCE
        → 在 MAX(pk) 处分裂 region，使新旧数据分属不同 region

Step 2: ALTER INSTANCE SPLIT RG <rg_id> BY 'manual-assigned' SET 'right_regions' = '<new_region_id>'
        → 将新 region 分到新的 RG

Step 3: ALTER INSTANCE MIGRATE RG <new_rg_id> TO '<target_node>'
        → 将新 RG 迁移到目标节点
```

## 问题：Step 1 SQL 不报错但 Region Split 不生效

### 测试环境

- 集群：3 节点（node-1-001, node-1-002, node-1-003）
- RG quorum=2，members=[node-1-002, node-1-003]
- 连接方式：root@127.0.0.1:3306

### 复现步骤

```sql
-- 1. 创建测试表并插入数据
USE test;
CREATE TABLE t2 (a INT NOT NULL PRIMARY KEY, b INT, c INT);
-- 插入约 46000 行数据...

-- 2. OPTIMIZE TABLE 确保统计信息更新
OPTIMIZE TABLE t2;

-- 3. 确认 region 信息
SELECT region_id, rep_group_id, data_obj_id, start_key, end_key,
       region_stats_approximate_keys, region_stats_approximate_size
FROM information_schema.META_CLUSTER_REGIONS
WHERE data_obj_id=(SELECT tindex_id FROM information_schema.tables
                   WHERE table_schema='test' AND table_name='t2');
-- 结果：
-- region_id=373, rg_id=95067, start_key=00002746, end_key=00002747
-- approximate_keys=4629, approximate_size=83322

-- 4. 获取 split key
SELECT LPAD(HEX(tindex_id),8,'0') FROM information_schema.tables
WHERE table_schema='test' AND table_name='t2';
-- 结果: 00002746

SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(MYROCK_ENCODE(),';',1),':',-1)
FROM test.t2 FORCE INDEX(PRIMARY) WHERE a=(SELECT MAX(a) FROM t2);
-- 结果: 8000C7F6
-- split_key = 00002746 + 8000C7F6 = 000027468000C7F6

-- 5. 执行 SPLIT REGION
ALTER INSTANCE SPLIT REGION 373 IN RG 95067 AT KEY '000027468000C7F6' FORCE;
-- 返回: OK (无错误)

-- 6. 等待并检查
-- 等待 10s, 30s, 60s...
SELECT region_id, start_key, end_key
FROM information_schema.META_CLUSTER_REGIONS
WHERE data_obj_id=(SELECT tindex_id FROM information_schema.tables
                   WHERE table_schema='test' AND table_name='t2');
-- 结果始终只有 1 个 region，没有变化：
-- region_id=373, start_key=00002746, end_key=00002747
```

### 也尝试了不指定 key

```sql
ALTER INSTANCE SPLIT REGION 373 IN RG 95067 FORCE;
-- 返回: OK
-- 结果: 同样不生效，region 无变化
```

### 通过 MC API 验证

```bash
# 也尝试了直接调 MC API
curl -s --noproxy '*' -XPUT \
  "http://127.0.0.2:25479/meta-cluster/api/job/split-region-in-rep-group/1/95067/373?force=1&key=0000276e80000028"
# 返回: {"head":{},"rep_group_id":95067,"job_id":21923}

# 检查 job 状态：
curl -s --noproxy '*' -XGET \
  "http://127.0.0.2:25479/meta-cluster/api/get-history-rep-group-job/1/21923"
# 结果: rep_group_job_state = "SplitAborted"
# job_desc: {"reason":"EC_TDS_INVALID_ARGUMENT","reported_by":"node-1-002","job_detail":{"causeType":1}}
```

### 配置确认

```sql
SELECT config_key, config_value FROM information_schema.META_CLUSTER_SCHEDULE_CONFIGS
WHERE config_key IN ('manually-split-region-enabled','split-region-key-count-lower-bound',
                     'split-region-size-threshold');
-- manually-split-region-enabled = 1 ✓
-- split-region-key-count-lower-bound = 100 (已从1000改为100)
-- split-region-size-threshold = 33554432 (32MB)
```

Region 的 `approximate_keys=4629` 远超 `split-region-key-count-lower-bound=100`。

### 通过 MC API 确认 split job 未被创建

查询 RG 95067 的 jobs，发现只有一个 CREATE_RG job，没有任何 SPLIT 类型的 job 记录。说明 **SQL 返回 OK 但 MC 端实际没有创建 split job**（或者创建后立即被 TDStore 节点 abort 了）。

## 问题总结

| 现象 | 描述 |
|------|------|
| SQL 返回 | OK（无错误） |
| MC job 状态 | `SplitAborted`，reason: `EC_TDS_INVALID_ARGUMENT`，`causeType: 1` |
| region 变化 | 无变化，始终只有 1 个 region |
| 配置 | `manually-split-region-enabled=1`，`approximate_keys=4629` > `lower-bound=100` |

## 根因定位（通过 TDStore 日志）

在 node-1-002 (leader) 的 TDStore 日志中找到了真正的错误：

```
[tdstore/region/td_region.cc:12314] DoSplitKeyRangeRegion invalid argument
job_id:824 ... the split_key:000027468000C7F6 does not match a range block.

[tdstore/region/td_range_block_manager.cc:81] GetRangeBlockByEndKey not exist
key:000027468000C7F6
```

### 根因

**TDStore 要求 split key 必须恰好落在 SST 文件的 range block 边界上**。如果指定的 split key 不匹配任何 range block 的 end key，split 会被拒绝（`EC_TDS_INVALID_ARGUMENT`）。

在当前环境中，`GetRangeBlockByEndKey` 对所有尝试过的 key 都返回 `not exist`，说明 **这个 region 没有 range block 统计信息**（即使数据量有 46000 行、1.1MB、`approximate_keys=3394`，OPTIMIZE TABLE 后也没有生成 range block）。

### 完整错误链

```
1. SQLEngine: ALTER INSTANCE SPLIT REGION → 提交 RPC 到 MC → 返回 OK（不等 job 完成）
2. MC: 创建 split job (job_id=824)，分发给 leader (node-1-002)
3. TDStore (node-1-002):
   a. DoSplitKeyRangeRegion 检查 split_key 是否匹配 range block
   b. GetRangeBlockByEndKey(000027468000C7F6) → not exist
   c. 返回 EC_TDS_INVALID_ARGUMENT (341004)
4. TDStore 向 MC 报告 job_ret:341004
5. MC 将 job 标记为 SplitAborted
6. 同时 node-1-003 (follower) 的 GetReplicationGroupJobCtxInfo 也失败
   （因为 leader 都没创建 job context）
```

### 日志文件位置

- node-1-001: `/data/home/hadleywang/td3nodes_data/tdstore/1/log/db_log/tdstore-rocksdb.log`
- node-1-002 (leader): `/data/home/hadleywang/td3nodes_data/tdstore/2/log/db_log/tdstore-rocksdb.log`
- node-1-003 (follower): `/data/home/hadleywang/td3nodes_data/tdstore/3/log/db_log/tdstore-rocksdb.log`

## 需要确认的问题

1. **Range block 何时生成？** — 为什么 OPTIMIZE TABLE (compaction) 后仍然没有 range block 信息？是否需要满足特定数据量或 SST 文件大小？
2. **不指定 AT KEY 的 SPLIT REGION 为什么也不生效？** — `ALTER INSTANCE SPLIT REGION 373 IN RG 95067 FORCE`（让 TDStore 自选 split key）也失败了，是否也因为没有 range block？
3. **`ALTER INSTANCE SPLIT REGION` 返回 OK 但 split 不生效** — SQLEngine 端不等待 job 完成，用户无法知道 split 是否成功。是否应该同步等待或至少返回 job_id？
4. **`launch_range_block_job(1, 1, '00002746', '00002747')` 也无效** — 即使 `is_random_split_key=1` 也不行，是否是同样的 range block 不存在的问题？

## SQLEngine 代码分析

通过分析源码（`sql/sql_alter_instance.cc`、`tdsql/mc/server/sub_coord_api.go`）发现：

- SQLEngine 端：`Tdsql_split::execute()` 提交 RPC 到 MC，收到 job_id 后 `my_ok()` 返回成功。**不等待 job 完成**。
- MC 端：`ManuallySplitRegionInRepGroup()` → `DoSplitRegionInRepGroupWithKey()` → key 范围检查通过 → `TryAddRepGroupOperator` 成功 → 返回 job_id。
- TDStore 端 (`td_region.cc:12314`)：`DoSplitKeyRangeRegion` 调用 `GetRangeBlockByEndKey` → key 不匹配任何 range block → 返回 `EC_TDS_INVALID_ARGUMENT` → job abort。

**根因在 TDStore 的 range block 机制**：region split 依赖 range block 统计信息，但当前环境下 range block 没有被生成。
