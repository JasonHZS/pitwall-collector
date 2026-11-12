# Pitwall

在 Mac 菜单栏监督你已经在跑的 Coding Agent。Pitwall 在本机统一查看 Codex、Claude Code、Cursor、Pi、OpenCode、Devin、Kimi Code、DeepSeek Harness、Qoder CN 和 ZCode 的会话：谁已完成、失败或需要处理，并在能定位时返回原会话。Cursor 没有可靠的等待信号。不需要账号，采集的数据只留在你的 Mac 上。

[官网](https://pitwall.oasislab.dev) · [下载](https://github.com/JasonHZS/pitwall-collector/releases/latest) · [English](README.md)

## 这个仓库包含什么

| | 许可 |
| --- | --- |
| `collector/`：在你的 Mac 上记录 Agent 事件的 hook、Pi 扩展与 OpenCode 插件 | [MIT](LICENSE) |
| [Releases](https://github.com/JasonHZS/pitwall-collector/releases) 中的 `Pitwall.app`：读取这些事件的菜单栏 App | 专有软件，见[使用条款](https://pitwall.oasislab.dev/terms.html) |

采集器开源，方便你核对它究竟记录了什么，也方便社区贡献新 Agent 的接入。App 不开源。

## 安装

需要 macOS 15 或更新版本，Apple 芯片。

```sh
brew install --cask jasonhzs/tap/pitwall
pitwall-collector install
```

第二条命令为要监督的 Agent 安装事件采集；安装器随 App 附带，修改各 Agent 的 hook 配置前会自动备份（Pitwall 自有的 Pi 扩展与 OpenCode 插件文件不备份）。不带参数会为所有支持的 Agent 安装，只装其中几个时在后面列出，例如 `pitwall-collector install codex claude-code opencode`。升级用 `brew upgrade --cask pitwall`。

Kimi Code 的状态直接读它自己的本地日志，不必安装 hook。审批和提问可以显示为等待，但不能在 Pitwall 里作答；返回会话只打开应用，不用会新建对话的链接。

DeepSeek Harness 的状态也直接读本地日志，不必为采集安装插件。提问和审批只能在 Harness 里回答。可选的本地导航插件要在 Pitwall 里同意后才安装，并已在 0.2.1-rc.3 与 rc.5 上核对过按会话 ID 跳转；拒绝、未安装或失败时只打开应用并说明原因。

也可以从 [Releases](https://github.com/JasonHZS/pitwall-collector/releases/latest) 下载 `Pitwall.dmg`，拖进“应用程序”。不用 Homebrew 时没有 `pitwall-collector` 命令，改为按路径运行 App 内附带的安装器（Pitwall 设置页里列出了每个 Agent 对应的命令）：

```sh
sh /Applications/Pitwall.app/Contents/Resources/collector/install.sh install
```

从本仓库安装则运行 `sh collector/install.sh install`。

**Codex 需要手动信任一次新 hook。** 打开 Codex CLI，输入 `/hooks`，信任 pitwall 的 hook。新开的 Agent 会话生效；已打开的 Pi 会话可运行 `/reload`。OpenCode 会监视插件目录并自动加载 Pitwall 插件。

移除 Pitwall 的 hook 和插件（事件文件与备份会保留）：

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
| Devin | Devin for Terminal | 不显示为等待。审批期间是状态未知。交互会话有审批通知 | 按 tty 选中终端标签。桌面会话只打开应用 |
| OpenCode | 2.x 终端 TUI 与 `opencode run` | 权限与表单提示；权限可在 Pitwall 回答，表单需回到 OpenCode | 切换到打开该会话的 OpenCode 客户端所在的 Otty、终端或 iTerm 标签页并显示该会话；否则使用 `opencode -s <sessionID>` 重新打开 |
| Kimi Code | 桌面版。只读自己的日志，不必装 hook | 审批和提问可以显示为等待。不能在 Pitwall 中作答 | 只打开应用。不用会新建对话的链接 |
| Qoder CN | 独立桌面版 0.5.3；用户级 hooks | 原生提问已实测；新增在 Pitwall 批准 / 拒绝命令与回答问题（60 秒），接管交互待验收 | 只打开应用，未验证精准定位 |
| DeepSeek Harness | 桌面版。状态只读本地日志，不必为采集装插件。可选导航插件已在 0.2.1-rc.3 与 rc.5 核对 | 命令审批与提问显示为等待。只能在 Harness 中回答 | 同意后，可选插件按会话 ID 跳转。否则只打开应用并说明原因 |
| ZCode | 桌面版 3.17.2 内置原生 Agent；状态直接读本机记录 | 安装可选交互 hooks 后，在 Pitwall 中批准 / 拒绝工具请求和回答受支持的问题 | 只打开 ZCode |

在 Pitwall 里批准或拒绝覆盖 Claude Code、Codex、Devin、Pi、OpenCode、Qoder CN 和 ZCode；Qoder CN 的接管交互待真实验收。Cursor、Kimi Code 和 DeepSeek Harness 的审批不能在 Pitwall 里作答。

精准返回标签页支持终端、iTerm2 和 Otty，条件是原进程仍占着那个 tty。tmux 要能定位唯一的本机客户端。Ghostty 1.3.1 没有 tty 接口，只打开应用。没有可靠信号时，Pitwall 不会猜测 Agent 正在等你。本机 Homebrew 的 `codex` 命令无法运行，不支持。

## 采集器如何工作

Claude Code、Codex、Cursor 与 Devin 通过官方 hook 调用 `collector/bin/pitwall-hook`。Pi 使用 `collector/pi/pitwall.ts`；OpenCode 使用 `collector/opencode/pitwall/` 插件：`server.ts` 走 V2 Promise 插件 API，`tui.ts` 在每个终端客户端中报告所显示的会话。采集器只保留状态字段与简短摘录，向 `~/.pitwall/events/<agent>.jsonl` 追加一行 JSON，不发起网络请求。

Claude Code 另登记了 `collector/bin/pitwall-approval`（`PermissionRequest`），让你可以在 Pitwall App 里批准或拒绝请求。Claude Code 同时照常显示自己的审批框，先回答的一方生效。这个 hook 只在你于 Pitwall 中点击“批准”或“拒绝”时作答；Pitwall 没在运行时它立即无输出退出。等待期间，请求只保存在本机的 `~/.pitwall/approvals/`，回答或撤回后删除；用于显示的工具输入 JSON 超过 4000 字符时截断。终端先回答时，有调用 ID 就按 ID 撤回，否则按完整输入的唯一指纹匹配。同一会话曾多次请求相同输入且没有调用 ID 时，保留请求到 hook 退出、轮次 / 会话结束或超时，不按工具名猜测撤回。本机关联标记保留到会话结束，避免迟到事件撤回重复的新请求。请求格式为内部接口，可能随版本变化。

Codex 也在 `PermissionRequest` 登记 `pitwall-approval codex`。重装采集器后，在 Codex `/hooks` 或钩子设置中信任新 hook。只接管当前 rollout 轮次明确 `approvals_reviewer = "user"` 的请求；自动审查、缺失或未知 metadata 立即交回 Codex。Codex 会先等待 hook，再显示原审批框：60 秒内可在 Pitwall 批准 / 拒绝，或从通知横幅批准。未回答、Pitwall 退出或停止监听时无输出回落到原审批流程。请求按 Agent、会话与轮次隔离，中断与结束仅撤回对应轮。hook 最多读取 rollout 末尾 1 MiB 判断 reviewer，不保存正文；待批文件临时保存用于显示的输入，事件 spool 仍不记录 Codex 工具参数。

Devin 也在 `PermissionRequest` 登记 `pitwall-approval devin`。与 Codex 一样，Devin 等 hook 返回后才显示原审批框：60 秒内可在 Pitwall 批准 / 拒绝，或从通知横幅批准；未回答时无输出退出，Devin 随即显示原审批框。打印模式（`devin -p`）没有人能回答，立即交回 Devin。Devin 的 payload 不带工作目录，请求记录 `DEVIN_PROJECT_DIR`。`Stop` 只撤回本轮请求，`SessionEnd` 清理整个会话。

Pi 没有审批 hook，审批框来自命令守卫等其它扩展。Pitwall 监听时，`collector/pi/pitwall.ts` 把 Agent 运行中弹出的允许 / 拒绝提示按同一请求格式交给 Pitwall：选项里恰好有一个“允许”和一个“拒绝”的选择框，或确认框。终端选择框照常显示，先回答的一方生效；在 Pitwall 回答会关闭终端选择框，并把对应选项交还给弹框的扩展。审批卡片显示选择框的标题或确认框的标题与正文，不推断工具归属。除下文的提问工具外，扩展不读取或保留工具参数；事件 spool 仍只记录标题的前 120 字。

OpenCode V2 插件在服务端订阅权限事件。Pitwall 可回复一次性允许或拒绝，同时 OpenCode 自己的审批提示保持打开；表单只显示等待状态，仍需回到 OpenCode 回答。服务端插件看不到终端；由 `tui.ts` 报告各终端客户端显示的会话，Pitwall 据此返回原会话。

**提问。** Agent 向你提问时，Pitwall 把题目和选项显示为表单，全部回答后发送。请求带 `answer_format: "answers-v1"`；不带这一标记的旧采集器只提示回到 Agent 回答。提问的输入完整保留、不截断；每道题都有非空回答才会回传。

- Claude Code `AskUserQuestion`（`PermissionRequest`）：终端同时显示原生提问，先回答的一方生效；Pitwall 的回答作为 `updatedInput.answers` 返回。
- Codex `request_user_input`、Devin `ask_user_question`：安装器在 `PreToolUse` 上为这两个工具单独登记 `pitwall-approval`。两者都等 hook 返回才显示原生提问，请在 60 秒内回答，否则照常显示原生提问。这两个工具的输入不接受回答，所以 hook 阻止这次调用，把你的回答写进模型读到的原因；终端会显示调用被拒绝，后面是你的回答。重新安装后需在 Codex 里信任新 hook。
- Qoder CN `AskUserQuestion`：精确匹配的 `PreToolUse` hook 最多等 60 秒，然后阻止调用并把用户回答写进模型反馈；命令审批走 `PermissionRequest` allow / deny。更新 / 修复接入后新开任务生效；真实桌面接管交互待验收。
- Codex Desktop 用 `request_user_input_async` 提问：它立即返回、Agent 继续工作，所以 Pitwall 不拦截，只把会话显示为等待中并附第一题题目首行，直到你在 Codex 里回答。
- Pi：Agent 运行中其它扩展弹出的普通选择框（只能选给定选项）与输入框，与审批一样和终端同时等待。Pi 示例中的 `question` / `questionnaire` 工具自绘界面，`tool_call` 先把题目交给 Pitwall 最多 60 秒，作答后以你的回答为原因阻止调用，否则照常显示工具自己的界面。
- 不支持 Cursor 与 Kimi Code：Cursor 的提问工具尚未与 hook 联调验证，Kimi Code 的 hook 不等待回答。

Cursor 不支持：它没有只在需要你确认时触发的 hook，`before*` hook 对每条拟执行命令都会触发。

**记录：** 事件名、时间、会话与轮次 ID、工作目录、transcript 路径、工具名、状态与结束原因、截断的错误信息、请求首行（最多 80 字），以及用于返回原会话的终端线索（tty、`TERM_PROGRAM`、tmux pane 与本机 socket 路径）。Claude Code、Pi、OpenCode 和 Qoder CN 额外记录待审批内容标题（最多 120 字）和最后一条回复的前 160 字；Codex Desktop 额外记录异步提问第一题题目的首行（最多 120 字）以及每条回答所答题目的 ID，用于在看板上显示“在等什么”和“结果如何”。

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

## Qoder CN

用 `sh collector/install.sh install qoder-cn` 接入，`sh collector/install.sh uninstall qoder-cn` 卸载。修改 `~/.qoder-cn/settings.json` 前备份，保留其它设置与 hooks，重复安装不改顺序。新开任务生效；必要时重启 Qoder CN。卸载不删除采集事件与备份。

独立桌面版 0.5.3 已验证开始、完成、中断、原生提问与前台子 Agent。`Stop` 只作回复预览，最终结果由 `QueryEnd` 确认；原生等待通知按工具调用 ID 关联，避免并发工具返回误清等待。另登记同步审批与提问 hook，可在 Pitwall 中于 60 秒内批准 / 拒绝或回答，否则不输出决定并交回 Qoder 原生流程。未监听、不支持的提问、无效决定也交回原生流程；子 Agent 不接管。权限卡片、接管交互和致命错误尚待真实验证。IDE、CLI 与国际版不继承结论。

请求 / 等待 / 回复摘要分别最多 80 / 120 / 160 字；采集器不把完整工具 payload 或审批文件复制到事件，App 不扫描 Qoder CN 的项目聊天文件。待批输入（显示 JSON 超过 4000 字符截断）、完整题目与选项、回答暂存在 `~/.pitwall/approvals/`，处理 / 撤回 / 超时后删除；输入指纹标记保留到会话结束。回答会交给模型，模型可能在回复中复述答案，使其进入事件的回复摘录及 App 任务历史；删除审批文件不会清除这些摘录。已有只观察安装需更新 / 修复，以登记两个决策 hook。

## ZCode

ZCode 桌面版 3.17.2 的内置原生 Agent 可直接监控运行状态，无需安装 hooks。要在 Pitwall 中处理权限请求和提问，在设置的 ZCode 详情里安装交互 hooks，或运行：

```sh
pitwall-collector install zcode
```

从本仓库安装时，用 `sh collector/install.sh install zcode`。安装器备份 `~/.zcode/cli/config.json`，保留其它 hooks。安装后新开一个 ZCode 任务。CLI、自动化和子 Agent 不在支持范围内。

安装后可在 Pitwall 中批准或拒绝工具请求，以及回答支持的单选、多选和自定义问题。ZCode 原生界面同时可用，先回答的一方生效。Pitwall 未监听、等待超过 60 秒、问题包含选项预览或格式未知时，由 ZCode 原生界面处理。答案通过原生 `PermissionRequest` 的 `updatedInput` 回传，不写入 Pitwall 的事件文件或任务历史。

用 `pitwall-collector uninstall zcode` 移除交互 hooks（从本仓库运行 `sh collector/install.sh uninstall zcode`）。如果安装器曾开启 hooks 总开关，卸载时会恢复原值；期间新增了其它 hooks 时保持开启。
