# 腾讯智能文档 MDX 常用格式

依据官方 skill 包的 MDX 2.1.0 规范整理。以下子集用于常见文档，不是任意 JSX；需要其他组件时先核对最新官方规范，不创造标签或属性。

## 文档与块

完整新文档以 YAML frontmatter 开头，`title` 非空且与创建标题一致。可选字段仅 `cover`、`icon`、`fontFamily`、`fontSize`、`spacing`；无明确格式需求时省略字体、字号、间距。局部 edit 传所需块片段，不向每个 Block 重复插入整篇 frontmatter。

正文优先用 Markdown 标题、普通段落、列表与简单引用。正文开头不要重复一份与 frontmatter.title 相同的一级标题。行内样式用 `<Mark bold>重点</Mark>` 等 Mark，不能用 Markdown 的加粗、斜体、删除线语法。Mark 和 Link 与周围文本保持单行文本流。

MDX 属性值用双引号，布尔属性只写名称，如 `bold`、`checked`；不写 `="true"` 或 `="false"`。禁止花括号表达式、import/export、脚本及未定义组件。嵌套每级缩进 4 个空格，不使用 Tab。普通块用开标签、缩进内容、闭标签的多行形式；Image、Divider 用自闭合标签。

```mdx
---
title: 项目周会
---

## 结论

本周完成 <Mark bold>接口联调</Mark>，下周安排验收。

<Todo>
    李明：周五前完成验收清单
</Todo>

<Table>
    <TableRow>
        <TableCell>
            负责人
        </TableCell>
        <TableCell>
            行动项
        </TableCell>
    </TableRow>
    <TableRow>
        <TableCell>
            李明
        </TableCell>
        <TableCell>
            完成验收清单
        </TableCell>
    </TableRow>
</Table>
```

## 常用组件

- 表格必须用 `Table > TableRow > TableCell`，不用 Markdown 管道表格，不嵌套 Table。
- `Todo` 每个组件表示一个任务，已完成项写 `<Todo checked>`。不要把多个任务文本塞进一个 Todo。
- 无段落属性时不包 Paragraph；需要右对齐等属性才用 `<Paragraph textAlign="right">` 多行块。普通标题用 `#` 到 `######`，需要额外样式才用 Heading（level 为字符串 1..6）。
- `ColumnList` 只含 `Column`，Column 可写 `width="50%"`，不能单独出现。按内容安排合理比例。
- `Callout` 需同时指定 `blockColor`、`borderColor`；本子集两者均可用 `grey`、`blue`、`sky_blue`、`green`、`yellow`、`orange`、`red`、`rose_red`、`purple`。不传 CSS 颜色、hex 或 rgb。Mark.color 可用同一组颜色或 default。
- 行内链接用 `<Link href="https://...">来源</Link>`。图片用 `<Image src="上传返回的真实image_id" alt="说明" />`，不将示例文字当成真实 ID，不传 http/https 图片外链；需要尺寸时 width/height 是数字字符串，保持原始比例。

提交前检查 frontmatter、标签闭合、缩进、属性白名单和图片 ID。若所需排版没有已核实的组件，用基础文本表达并说明限制，不尝试任意 HTML 或 React 组件。
