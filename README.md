# 微信桌面自动化 Skill

这是一个面向 Codex 的 Windows 微信桌面自动化 Skill。它通过正常的窗口截图、鼠标和键盘操作，帮助 Codex 搜索联系人或群聊、读取当前可见消息、发送消息、按预先批准的规则自动回复，以及对指定群聊进行阶段性总结。

> 本项目不是微信官方工具，不注入微信进程、不模拟微信协议、不解密聊天数据库。任何非官方自动化都可能存在账号限制风险，请使用低频、明确授权的规则，并优先在非关键账号上测试。

## 功能

- 搜索并打开指定联系人或群聊
- 截取当前微信窗口，读取屏幕上可见的消息
- 填写消息并在发送前生成预览
- 经用户逐条确认后发送消息
- 按用户提前批准的规则自动回复
- 按规定时间向指定会话发送固定消息或模板消息
- 在限定时间内监控指定聊天窗口的画面变化
- 汇总群聊话题、结论、待办事项、链接和未解决问题
- 保存自动发送的规则 ID、时间及结果截图，便于审计
- 释放异常按键或鼠标状态，处理持续滚动、误选中等问题

## 工作原理

Skill 使用 Windows PowerShell 和系统 API：

1. 查找已登录的微信桌面窗口。
2. 根据窗口位置计算搜索框、消息输入框和发送按钮坐标。
3. 使用前台鼠标键盘事件完成搜索、输入和发送。
4. 使用 `PrintWindow` 截取微信窗口，用于预览、结果确认和变化检测。
5. 监控时仅保存画面发生变化的截图，由 Codex 识别新增的可见消息并生成总结。

它不会直接访问微信服务器或完整聊天记录。被折叠、未加载、超出当前可见区域或监控间隔内快速刷过的消息，可能无法被纳入总结。

## 环境要求

- Windows 10 或 Windows 11
- 已安装并登录微信桌面客户端
- Windows PowerShell 5.1 或更高版本
- Codex 桌面端或支持个人 Skills 的 Codex 环境

坐标流程已在微信 4.1.x 上验证。微信界面升级后，应先测试搜索、截图和草稿预览，再进行真实发送。

## 安装

### 通过 Git 克隆

在 PowerShell 中运行：

```powershell
git clone git@github.com:JuneYaooo/wechat-desktop-automation.git "$env:USERPROFILE\.codex\skills\wechat-desktop-automation"
```

如果没有配置 GitHub SSH，也可以使用 HTTPS：

```powershell
git clone https://github.com/JuneYaooo/wechat-desktop-automation.git "$env:USERPROFILE\.codex\skills\wechat-desktop-automation"
```

安装后新建一个 Codex 任务，使 Codex 重新发现 Skill。更新时进入该目录执行：

```powershell
git pull
```

## 如何启动

通常不需要手动运行脚本，直接在 Codex 中用自然语言描述任务即可。以下表达会触发本 Skill：

```text
用微信桌面自动化打开 June，读取目前屏幕上能看到的消息。
```

```text
用微信 Skill 给 June 填写“今晚八点见”，先给我看预览，不要直接发送。
```

```text
用微信 Skill 监控 init FDE 群 30 分钟，每 10 分钟总结一次新消息。
```

也可以显式指定 Skill：

```text
$wechat-desktop-automation 打开 init FDE 群并总结当前可见消息。
```

## 普通发送流程

普通消息默认逐条确认：

1. 用户指定联系人或群聊。
2. Codex 搜索并截图确认会话名称。
3. Codex填写消息但不发送。
4. 用户检查预览并确认。
5. Codex 点击发送并截图检查结果。

示例：

```text
给 June 发“机器人测试完成”，先预览，等我确认再发。
```

## 自动回复和自动发送

如果不希望每条消息都确认，需要提前批准一条有限规则。规则至少应包含：

- 精确的联系人或群聊名称
- 自动回复、定时发送或监控总结中的一种动作
- 关键词、@提醒或明确的执行时间
- 固定回复内容或允许使用的模板变量
- 生效时间和失效时间
- 最小发送间隔、每小时上限和总次数上限
- 安静时段和停止条件

规则示例：

```yaml
id: init-fde-faq-2026-08
chats:
  - init FDE
action: auto_reply
trigger:
  keywords:
    - 机器人帮助
  mention_required: true
response:
  exact_text: "机器人测试中，请稍候，稍后会有人回复。"
valid_from: 2026-08-22T09:00:00+08:00
valid_until: 2026-08-23T18:00:00+08:00
limits:
  min_interval_seconds: 60
  max_per_hour: 5
  max_total: 20
quiet_hours:
  start: "22:00"
  end: "08:00"
  timezone: Asia/Shanghai
stop_conditions:
  - 用户撤销规则
  - 会话名称或触发条件不明确
  - 发送结果异常
```

使用自然语言也可以建立同样的规则：

```text
接下来到明天下午六点，只监控 init FDE 群。有人 @我并发送“机器人帮助”时，自动回复“机器人测试中，请稍候，稍后会有人回复。”至少间隔 60 秒，每小时最多 5 条，总共最多 20 条。晚上十点到早上八点不要回复。
```

规则过期、次数用完、会话不匹配或消息含义不明确时，Skill 应跳过发送并报告原因。

## 消息监控与群聊总结

监控前，Codex 会先打开并核对目标会话。单次底层监控最长一小时，可分段执行。监控期间只记录画面变化，并从实际捕获的截图中整理：

- 新增消息及可见发送者
- 主要讨论主题
- 已形成的结论或决定
- 待办事项及负责人
- 共享链接和资料
- 未解决的问题
- 自动回复或自动发送记录

示例：

```text
监控 init FDE 群 40 分钟，每 10 分钟给我一份增量总结；只总结，不发送任何群消息。
```

长期或周期性任务应使用 Codex 的自动化能力设置明确的运行周期和结束日期，不建议创建系统启动项或无限运行的后台进程。

## 停止与撤销

可以随时对 Codex 说：

```text
停止监控 init FDE。
停止所有微信自动回复。
取消 init-fde-faq-2026-08 规则。
```

撤销后不应再根据对应规则发送新消息。

## 底层脚本

一般情况下由 Codex 调用脚本。需要排查问题时，可以手动运行：

```powershell
$script = "$env:USERPROFILE\.codex\skills\wechat-desktop-automation\scripts\wechat_desktop.ps1"
```

| 操作 | 示例 |
| --- | --- |
| 检查微信窗口 | `powershell -NoProfile -ExecutionPolicy Bypass -File $script -Command status` |
| 搜索并打开会话 | `powershell -NoProfile -ExecutionPolicy Bypass -File $script -Command open -Query "June"` |
| 截取当前窗口 | `powershell -NoProfile -ExecutionPolicy Bypass -File $script -Command capture` |
| 填写草稿 | `powershell -NoProfile -ExecutionPolicy Bypass -File $script -Command draft -Message "你好"` |
| 手动确认发送 | `powershell -NoProfile -ExecutionPolicy Bypass -File $script -Command send -ConfirmSend SEND` |
| 规则授权发送 | `powershell -NoProfile -ExecutionPolicy Bypass -File $script -Command send -AuthorizationId "rule-id"` |
| 监控五分钟 | `powershell -NoProfile -ExecutionPolicy Bypass -File $script -Command watch -WatchSeconds 300 -IntervalSeconds 10` |
| 释放输入状态 | `powershell -NoProfile -ExecutionPolicy Bypass -File $script -Command release` |

不要绕过草稿步骤直接执行发送。`AuthorizationId` 必须对应用户实际批准且仍然有效的规则。

## 风险和使用边界

- 自动化不等于微信官方授权，也不能保证账号永不受限。
- 不要批量群发、自动加好友、爬取联系人或发送重复营销内容。
- 不要为了规避平台检测而调节操作节奏。
- 涉及付款、密码、法律承诺、身份冒充或高影响决定时，应逐条确认最终消息。
- 重要业务建议优先使用企业微信或微信开放平台的官方接口。
- 截图可能包含私人聊天内容，不要提交到 Git，也不要复制到不必要的位置。

## 目录结构

```text
wechat-desktop-automation/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── references/
│   ├── automation-rules.md
│   └── safety.md
└── scripts/
    └── wechat_desktop.ps1
```

详细执行流程参见 [SKILL.md](SKILL.md)，自动化规则字段参见 [references/automation-rules.md](references/automation-rules.md)。
