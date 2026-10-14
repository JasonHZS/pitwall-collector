# Pitwall

Coding Agent 的维修墙。Pitwall 是一个本地 macOS 看板，统一查看 Codex、Claude Code、Cursor、Pi 和 Devin 的会话：每个会话在做什么、哪个需要你处理，一键返回原会话。不需要账号，采集的数据只留在你的 Mac 上。

[官网](https://pitwall.oasislab.dev) · [下载](https://github.com/JasonHZS/pitwall-collector/releases/latest) · [English](README.md)

## 这个仓库包含什么

| | 许可 |
| --- | --- |
| `collector/`：在你的 Mac 上记录 Agent 事件的 hook 与 Pi 扩展 | [MIT](LICENSE) |
| [Releases](https://github.com/JasonHZS/pitwall-collector/releases) 中的 `Pitwall.app`：读取这些事件的菜单栏 App | 专有软件，见[使用条款](https://pitwall.oasislab.dev/terms.html) |

采集器开源，方便你核对它究竟记录了什么，也方便社区贡献新 Agent 的接入。App 不开源。

## 安装

需要 macOS 15 或更新版本。

```sh
brew install --cask jasonhzs/tap/pitwall
pitwall-collector install
```

第二条命令为要监督的 Agent 安装事件采集；安装器随 App 附带，修改各 Agent 的配置前会自动备份。不带参数会为所有支持的 Agent 安装，只装其中几个时在后面列出，例如 `pitwall-collector install codex claude-code`。升级用 `brew upgrade --cask pitwall`。

也可以从 [Releases](https://github.com/JasonHZS/pitwall-collector/releases/latest) 下载 `Pitwall.dmg`，拖进“应用程序”。不用 Homebrew 时没有 `pitwall-collector` 命令，改为按路径运行 App 内附带的安装器（Pitwall 设置页里列出了每个 Agent 对应的命令）：

```sh
sh /Applications/Pitwall.app/Contents/Resources/collector/install.sh install
```

从本仓库安装则运行 `sh collector/install.sh install`。

**Codex 需要手动信任一次新 hook。** 打开 Codex CLI，输入 `/hooks`，信任 pitwall 的 hook。新开的 Agent 会话生效；已打开的 Pi 会话可运行 `/reload`。

移除 Pitwall 的 hook 和扩展（事件文件与备份会保留）：

```sh
pitwall-collector uninstall   # DMG 安装时：sh /Applications/Pitwall.app/Contents/Resources/collector/install.sh uninstall
```

## 支持的 Agent

| Agent | 已验证形态 | 等待处理时提醒 | 返回原会话 |
| --- | --- | --- | --- |
| Claude Code | CLI 与 Claude 桌面版 | 支持 | 桌面会话，或终端标签页 |
| Codex | 桌面版、内置 CLI、Chrome 插件 | 用户审批请求支持批准通知；被动状态仍为未知 | 桌面会话，或终端标签页 |
| Cursor | IDE 与后台 Agent | 没有可靠信号；不支持在 Pitwall 中审批 | 打开 Cursor |
| Pi | 终端版 | 支持：扩展请求输入时；允许 / 拒绝类提示可在 Pitwall 中回答 | 终端标签页 |
| Devin | Devin for Terminal | 交互会话的审批请求支持批准通知；被动状态仍为未知 | 终端标签页 |

精准返回标签页支持终端、iTerm2 和 Otty。没有可靠信号时，Pitwall 不会猜测 Agent 正在等你。

## 采集器如何工作

各 Agent 通过官方 hook 调用 `collector/bin/pitwall-hook`（Pi 通过扩展 API 加载 `collector/pi/pitwall.ts`）。hook 只保留状态字段与简短摘录，向 `~/.pitwall/events/<agent>.jsonl` 追加一行 JSON。它永远不写 stdout、永远以 0 退出，因此不会批准或拒绝任何操作、不会阻塞请求，也不会向 Agent 注入内容。它不发起任何网络请求。

Claude Code 另登记了 `collector/bin/pitwall-approval`（`PermissionRequest`），让你可以在 Pitwall App 里批准或拒绝请求。Claude Code 同时照常显示自己的审批框，先回答的一方生效。这个 hook 只在你于 Pitwall 中点击“批准”或“拒绝”时作答；Pitwall 没在运行时它立即无输出退出。等待期间，请求只保存在本机的 `~/.pitwall/approvals/`，回答或撤回后删除；用于显示的工具输入 JSON 超过 4000 字符时截断。终端先回答时，有调用 ID 就按 ID 撤回，否则按完整输入的唯一指纹匹配。同一会话曾多次请求相同输入且没有调用 ID 时，保留请求到 hook 退出、轮次 / 会话结束或超时，不按工具名猜测撤回。本机关联标记保留到会话结束，避免迟到事件撤回重复的新请求。请求格式为内部接口，可能随版本变化。

Codex 也在 `PermissionRequest` 登记 `pitwall-approval codex`。重装采集器后，在 Codex `/hooks` 或钩子设置中信任新 hook。只接管当前 rollout 轮次明确 `approvals_reviewer = "user"` 的请求；自动审查、缺失或未知 metadata 立即交回 Codex。Codex 会先等待 hook，再显示原审批框：60 秒内可在 Pitwall 批准 / 拒绝，或从通知横幅批准。未回答、Pitwall 退出或停止监听时无输出回落到原审批流程。请求按 Agent、会话与轮次隔离，中断与结束仅撤回对应轮。hook 最多读取 rollout 末尾 1 MiB 判断 reviewer，不保存正文；待批文件临时保存用于显示的输入，事件 spool 仍不记录 Codex 工具参数。

Devin 也在 `PermissionRequest` 登记 `pitwall-approval devin`。与 Codex 一样，Devin 等 hook 返回后才显示原审批框：60 秒内可在 Pitwall 批准 / 拒绝，或从通知横幅批准；未回答时无输出退出，Devin 随即显示原审批框。打印模式（`devin -p`）没有人能回答，立即交回 Devin。Devin 的 payload 不带工作目录，请求记录 `DEVIN_PROJECT_DIR`。`Stop` 只撤回本轮请求，`SessionEnd` 清理整个会话。

Pi 没有审批 hook，审批框来自命令守卫等其它扩展。Pitwall 监听时，`collector/pi/pitwall.ts` 把 Agent 运行中弹出的允许 / 拒绝提示按同一请求格式交给 Pitwall：选项里恰好有一个“允许”和一个“拒绝”的选择框，或确认框。终端选择框照常显示，先回答的一方生效；在 Pitwall 回答会关闭终端选择框，并把对应选项交还给弹框的扩展。其它提示原样不动。审批卡片显示选择框的标题或确认框的标题与正文，不推断工具归属。扩展不读取或保留工具参数；事件 spool 仍只记录标题的前 120 字。

Cursor 不支持：它没有只在需要你确认时触发的 hook，`before*` hook 对每条拟执行命令都会触发。

**记录：** 事件名、时间、会话与轮次 ID、工作目录、transcript 路径、工具名、状态与结束原因、截断的错误信息、请求首行（最多 80 字），以及用于返回原会话的终端线索（tty、`TERM_PROGRAM`）。仅 Claude Code 和 Pi 额外记录：待审批内容的首行（最多 120 字）和最后一条回复的前 160 字，用于在看板上显示“在等什么”和“结果如何”。

**不记录：** 请求的其余内容、工具输入与输出、上述摘录以外的回复、思考过程和 transcript 内容。摘录和路径仍可能含敏感文字，截短不等于脱敏。

事件文件会一直增长，直到你删除。安装器修改每个配置文件前都会备份（备份可能含敏感设置）；卸载只移除 Pitwall 的条目，不会用备份覆盖回去，事件文件和备份都会保留。详见[隐私政策](https://pitwall.oasislab.dev/privacy.html)。

查看已记录的内容：

```sh
~/.pitwall/bin/pitwall-events tail -f
```

其他命令：`status`、`summary`、`hooks`（各 Agent 登记了哪些 hook、脚本记录什么）和 `doctor`（检查登记情况、Codex 信任状态和各 Agent 最近一次事件）。每个字段的含义见 [docs/event-format.md](docs/event-format.md)（英文）。

## 接入新的 Agent

新 Agent 的接入从采集器开始。请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)（英文），并在动手前开一个 Issue，一起确认该 Agent 的哪些事件代表“开始”“等待”和“结束”。

## 反馈

问题反馈和新 Agent 请求请提交到 [Issues](https://github.com/JasonHZS/pitwall-collector/issues)。App 设置页的“复制诊断信息”会把版本、来源健康状况、数量和设置复制到剪贴板。Issue 是公开的，粘贴前请检查一遍。

## 许可

本仓库中的代码以 [MIT](LICENSE) 许可证发布。Pitwall 名称、图标以及 Releases 中的 App 二进制不在此许可范围内。
