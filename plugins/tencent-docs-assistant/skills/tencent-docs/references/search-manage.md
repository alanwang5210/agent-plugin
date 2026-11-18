# 检索与文件管理

## 定位与阅读

- 用户有链接时直接用当前工具支持的 `file_url`，或通过文件信息查询解析真实 `file_id`。不要自行解码并猜测 ID。
- `manage.search_file` 默认按标题搜索。`search_type=content` 是正文匹配，可能受套餐限制；标题无结果不代表正文无相关内容。
- 单次 `size` 为 1..50，默认 20；按需缩小范围。条件搜索翻页时将返回的 `next` 转为工具要求的整数 `from`，直到 `is_over=true` 或已满足任务范围；游标不前进时停止并说明。
- 可按文件类型、所有者、文件夹、列表、时间等筛选。`folder_id` 含各级子文件夹，不能与 `list_type`、`only_space` 同用。仅关键词搜索可能补充去重后的 AI 结果，`total` 和 `next` 不包含这部分，不据此宣称完整或精确计数。
- `manage.recent_online_file` 必须显式传 `count=1..20`，`num` 从 1 开始。省略 `count` 或传 0 当前会变成 100 而遭下游拒绝。它仅列文档类节点，不能用于判断文件夹是否存在。
- 查文件夹可用 `manage.search_file` 的 `only_folder`；遍历知识库时用 `query_space_list`、`query_space_node` 的真实节点 ID 和分页参数，不把节点 ID 当文档 ID。
- 阅读或总结可用 `get_content`；编辑时改用相应类型的结构查询工具。整理多个文档时保留标题、链接和来源对应关系，区分原文与归纳。

## 创建与整理

`manage.query_file_info` 用于核对身份、状态、类型和归属。创建前确认目标类型、标题、空间和文件夹；`manage.create_file` 的类型枚举以实时 schema 为准。

一般新建排版文档可选 `create_smartcanvas_by_mdx`，参照 [智能文档](smartcanvas.md)。用户要求 DOC、SHEET 或 SLIDE 时创建对应类型。创建成功不等于内容已写入，需继续填充并回读。移动、重命名、删除和分享依据当前工具与用户指定范围执行，不自动改为公开访问。

写入结果不明先查状态，不重复创建。文档不存在、账号无权访问、类型不匹配和搜索无结果要分别说明。权限和套餐错误参照连接 skill。
