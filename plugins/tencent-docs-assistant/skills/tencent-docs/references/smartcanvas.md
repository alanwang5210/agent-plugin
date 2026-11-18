# 智能文档 SMARTCANVAS

## 阅读与定位

多页文档先用 `smartcanvas.get_top_level_pages` 获取页面，再读任务相关页面。`smartcanvas.read` 返回 MDX；`size` 最大 20，按返回的 `next_token` 继续读取同一页面，游标为空才是该页结束。未传 `page_id` 只默认读取首个页面，不代表全文。

编辑前用 `smartcanvas.find(query=目标文本)` 获取真实 Block ID 和 MDX。同名或多次命中时查看上下文，不从 `read` 返回的普通文本猜 ID。

## 精准编辑

`smartcanvas.edit` 的 `action` 使用下表值，`file_id` 是目标智能文档 ID：

| 目的 | action | 参数含义 |
| --- | --- | --- |
| 在锚点前插入 | INSERT_BEFORE | `id` 为锚点 Block ID，`content` 为新增 MDX |
| 在锚点后插入 | INSERT_AFTER | `id` 为锚点 Block ID，`content` 为新增 MDX |
| 修改一个块 | UPDATE | `id` 必填，`content` 是该块的新 MDX，需保留块内其他内容 |
| 删除一个块 | DELETE | `id` 必填，仅限用户授权的目标块 |

两种插入操作不传 `id` 都会追加到文档末尾，不能用来表示开头或某页顶部。用户要求特定位置时必须有锚点。写后用 find/read 验证实际内容；失败结果不明先查再重试。

不要使用旧的 `get_element_info`、`create_smartcanvas_element`、`update_element`、`delete_element`、`append_insert_smartcanvas_by_markdown` 流程。

## 创建与 MDX

用 `create_smartcanvas_by_mdx` 新建排版文档，参数是 `title` 和 `mdx`，标题最长 36 个字符。默认 `content_format=mdx`；用户明确要求 Markdown 时才传 `content_format=markdown`。创建和 edit 的 MDX 内容先按 [MDX 格式](mdx.md) 自查。

MDX 图片先用 `upload_image` 上传得到 `image_id`，再用于封面或 Image 的 src。即使个别参数说明提到外链转存，本插件仍按官方创建工具的图片约束使用已上传 ID。上传参数需真实文件内容的 base64，不能传本地路径或 URL；大图先压缩，不能为失败而改用外链。

创建成功后核对返回的链接、标题和内容。普通添加内容不得用重新创建整篇文档替代。
