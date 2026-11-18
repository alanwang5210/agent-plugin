# 智能表格 SMARTSHEET

## 表、字段与记录

按当前 schema 使用 `smartsheet.list_tables`、`smartsheet.list_fields` 和 `smartsheet.list_records`，确认真实子表、字段定义、记录 ID。字段 ID、标题和展示标签不能互换；调用参数要求标题时传真实标题，要求 ID 时传真实 ID。

- `list_records` 每页 `limit` 最大 100，首次 offset=0，按返回的 `has_more`、`next` 继续分页。不把一页结果当全量统计。
- 用户有选区时保留其 `selection.viewId` 为 `view_id`，因为不同视图的行顺序可不同。不能按默认视图行号修改另一个视图的记录。
- 只需部分列时传 `field_titles`。读取公式、查找引用或关联列的计算结果时才启用 `include_computed_values=true`，并限制所需列；不需要时保持默认 false。
- 对筛选需求先核对工具实际支持的参数；不自行发明 filter。缺少服务端筛选时，可对任务必要范围分页读取后过滤，并说明未读取范围。

## 修改

批量添加或更新优先用 `smartsheet.add_records`、`smartsheet.update_records`，遵守当前单次限制并检查每项结果。更新以真实 `record_id` 定位，不能用可变的行号代替。

先检查字段类型，按 schema 组装文本、数字、日期、单选、多选、成员、附件、关联等值；计算字段不写成普通文本。创建字段或调整选项、视图之前检查现有结构，避免同名重复或改变其他记录的含义。

写后按 record_id 回读受影响记录，确认中文、类型和需要的计算结果。结果不明时先查目标，避免重复记录。批量请求不默认保证原子性。

## 内部工具

**AI 不直接调用** `smartsheet.fetch`、`smartsheet.commit_changeset`、`smartsheet.get_client_var`。这三个工具明确仅供 MCP App 内部使用，不能绕过高层记录接口去手工构造二进制关键帧或 changeset。高层接口不支持的操作如实说明。
