# 连接参考

核实日期：2026-11-04。

## MCP 与 OAuth

- MCP：`https://docs.qq.com/openapi/mcp`，Streamable HTTP。
- 受保护资源元数据：`https://docs.qq.com/openapi/mcp/.well-known/oauth-protected-resource`。
- 授权服务器元数据：`https://docs.qq.com/.well-known/oauth-authorization-server`。
- 授权地址：`https://docs.qq.com/scenario/open-claw.html?authType=2`。
- 动态客户端注册：`https://docs.qq.com/openapi/mcp/oauth/register`。
- Token 端点：`https://docs.qq.com/openapi/mcp/oauth/token`。
- 发现信息声明授权码、refresh token、PKCE S256，客户端 Token 认证方式为 none；scopes 为 `docs:read`、`docs:write`、`docs:manage`。

插件保留 OAuth DCR 配置，由宿主管理凭据，不内嵌密钥。桌面连接已通过只读账号查询；这不证明所有工具、文档权限和网页宿主均可用。

## 官方参考与适配范围

- [腾讯文档官方接入说明](https://docs.qq.com/scenario/open-claw.html?nlc=1)
- [官方 skill 包](https://cdn.addon.tencentsuite.com/static/tencent-docs.zip)
- [腾讯文档团队 MCP 使用指南](https://developer.cloud.tencent.com/mcp/server/11803)
- [WorkBuddy 腾讯文档集成](https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Knowledge-Base/Tencent-Doc)

本次参考包主 SKILL.md 标注 1.0.42，而同日 `check_skill_update` 返回 1.0.41；这是官方包自己的版本，与本插件 0.2.0 不同。运行时以当前工具 schema 和官方返回为准，不固定工具总数。

官方包面向多种宿主，含个人 Token、mcporter、独立工具链、更新及上报等流程。本插件仅适配当前 MCP/OAuth 连接和文档工作流，不自动执行这些流程或静默上传内容。未来更新由用户请求后检查并发布。
