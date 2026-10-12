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
| Codex | 桌面版、内置 CLI、Chrome 插件 | 暂无可靠信号 | 桌面会话，或终端标签页 |
| Cursor | IDE 与后台 Agent | 没有可靠信号 | 打开 Cursor |
| Pi | 终端版 | 支持：扩展请求输入时 | 终端标签页 |
| Devin | Devin for Terminal | 暂无可靠信号 | 终端标签页 |

精准返回标签页支持终端、iTerm2 和 Otty。没有可靠信号时，Pitwall 不会猜测 Agent 正在等你。

## 采集器如何工作

各 Agent 通过官方 hook 调用 `collector/bin/pitwall-hook`（Pi 通过扩展 API 加载 `collector/pi/pitwall.ts`）。hook 只保留状态字段与简短摘录，向 `~/.pitwall/events/<agent>.jsonl` 追加一行 JSON。它永远不写 stdout、永远以 0 退出，因此不会批准或拒绝任何操作、不会阻塞请求，也不会向 Agent 注入内容。它不发起任何网络请求。

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
