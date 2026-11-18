# 在线表格 SHEET

先调用 `sheet.get_sheet_info`，获取真实 `sheet_id`、名称、类型、隐藏状态和 `used_range`。工作簿可能包含 worksheet、smartsheet、smartcanvas 等类型，按实际子表类型选择工具。

`used_range` 表示已用区域的末行/末列，数值是 1-based，空表为 0；不要把网格总行列数当成实际数据条数。若未返回 used_range，可根据网格大小分段读取必要区域，避免整张大表无界读取。

## 范围与写入

1. 获取目标区域及必要表头，核对列含义、现有公式、合并单元格和类型。工具参数使用 A1 还是数字坐标，以当前 schema 为准，不混用。
2. `sheet.set_range_value` 用 `values` 批量写单元格；每项 `row`、`col` 是 0-based。`value_type` 使用 NUMBER、STRING、BOOL、FORMULA，并填写对应的 `number_value`、`string_value`、`bool_value`、`formula`。A1 对应 row=0、col=0。
3. 仅写目标单元格。用户没要求改公式时保留公式，不把显示结果写回公式格。日期、百分比、长编号和带前导零的编码需按业务类型处理，不能全部转成数字或字符串。
4. 插入/删除行列、排序和合并会影响坐标与公式引用，先读取结构并确认用户范围；操作后重新获取定位信息。
5. 写后读取目标范围，核对值、公式、格式及相邻数据；批量失败时核实已成功部分，再补余下操作。

面向摘要只读场景可以用 `get_content`；编辑和精确统计要读取专用范围数据，不能从摘要文本推算单元格位置。
