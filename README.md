# Agent Plugin

个人 Codex 插件集合。

## 插件

| 插件 | 说明 | 版本 |
| --- | --- | --- |
| `codex-token-monitor` | 在 Windows 本地查看 Codex 会话的 Token 用量。 | `0.1.0-beta.4` |
| `tencent-docs-assistant` | 通过腾讯文档官方 MCP 搜索、读取和编辑文档与表格。 | `0.2.0` |

## 安装

在终端添加插件市场，再安装需要的插件：

```powershell
codex plugin marketplace add alanwang5210/agent-plugin --ref master
codex plugin add codex-token-monitor@agent-plugin
codex plugin add tencent-docs-assistant@agent-plugin
```

Token Monitor 需要 Windows 和 Windows PowerShell。腾讯文档助手需要通过腾讯的授权页面登录；可用功能取决于腾讯文档服务和账号权限。

## 目录

- `.agents/plugins/marketplace.json`：插件市场清单。
- `plugins/codex-token-monitor/`：Token 监控插件。
- `plugins/tencent-docs-assistant/`：腾讯文档插件。

GitHub 仓库与 ChatGPT 中已创建的私有插件是独立的发布位置，推送代码不会自动更新账号中的插件。
