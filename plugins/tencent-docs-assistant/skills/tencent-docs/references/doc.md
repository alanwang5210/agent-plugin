# 在线文档 DOC

## 编辑前定位

`get_content` 仅供只读任务。凡写工具需要 `idx`、`index`、`begin/end` 或 `ranges`，先用 `doc.resolve_document_structure` 获取结构，或用 `doc.find` 定位目标文本。不要把纯文本字符数、Markdown 行号或段落序号当成编辑索引。

- `resolve_document_structure` 的 `mode` 是整数：0=outline、1=compact（默认）、2=full。先用 compact 定位；只需章节目录时用 outline；表格单元格、样式或目标段详情才取 full。
- 顶层节点用 `offset`、`limit` 分页，默认 limit=150。单点查询传真实字符 `idx` 并按 schema 设置 `has_idx=true`，返回该位置所在块的详情；不要为了方便拉取不限量全文结构。
- `paragraph_index` 是全局 1-based 节点序号，不是字符位置。写入使用结构或 find 返回的真实位置，并核对具体写工具对区间边界、表格和段落的定义。
- 多处命中时结合上下文选择目标。定位后若发生编辑或版本冲突，重新获取结构，不复用已偏移的位置。

## 写入与验证

单处替换用 `doc.find` 后的 `doc.replace_text`，保留目标之外的内容。`doc.find_and_replace` 会替换所有匹配项，只有用户要求的范围确为全部命中时才使用。

插入文本和新增段落按相应工具处理；`doc.insert_text` 不能靠文本中的换行代替段落插入，需要新段落时用 `doc.insert_paragraph`。表格及格式使用 DOC 专用工具，不用智能文档的 MDX 或 Block ID。

支持 `version_info` 时传最近读取到且满足 schema 范围的真实版本；`base_version=0` 表示不指定版本，`is_latest=true` 不能替代协作冲突检查。不要猜版本或在冲突后直接覆盖。

写后用结构或 find 回读目标及附近内容，确认修改次数、位置、段落或表格结构和中文正确。仅当用户要求撤销且服务提供对应工具时，查询真实操作记录与目标版本后撤销，不凭记忆填版本号。
