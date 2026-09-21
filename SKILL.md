---
name: wechat-desktop-automation
description: Control and monitor the logged-in Windows WeChat desktop client through visible mouse, keyboard, and window-capture operations. Use when the user asks to search/open a contact or group, inspect or summarize visible messages, monitor a specified chat for bounded periods, draft or send a message, message a contact, add a friend, or accept an incoming friend request on an explicit one-off request, automatically reply under a user-approved rule, perform a scheduled send, capture WeChat, or recover stuck input. Support low-frequency manual actions and narrowly scoped pre-authorized rules; do not use for unsolicited marketing, broad contact crawling, automatic friend adding, deceptive messaging, or unbounded mass sending.
---

# WeChat Desktop Automation

Operate the existing signed-in Windows WeChat client using `scripts/wechat_desktop.ps1`. Keep actions visible or auditable and tied to either a current user request or an active user-approved rule.

## Preconditions

- Require Windows and a running, signed-in desktop client.
- Do not inject code, hook WeChat, emulate its protocol, decrypt its database, or change Narrator/accessibility settings.
- Read [references/safety.md](references/safety.md) before sending or monitoring.
- Read [references/automation-rules.md](references/automation-rules.md) when configuring automatic replies, scheduled sends, monitoring, or summaries.

## Authorization Modes

### Manual

Use for ordinary one-off sends. Open and visually verify the exact conversation, draft, inspect the preview, then send only after the user requested that exact message or approved the preview.

### Rule-authorized

Use without per-message confirmation only after the user defines and approves a rule containing all required fields in `references/automation-rules.md`: exact chats, action, trigger/schedule, content or template constraints, validity window, frequency cap, total cap, and stop conditions.

Treat any ambiguity, expired rule, unmatched chat, unsupported template variable, or exceeded cap as no authorization. Stop rather than broadening the rule. Preserve an audit ID and report automated sends in the next summary/update.

## Core Commands

Check the client:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command status
```

Search for an exact conversation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command search -Query "init FDE"
```

On WeChat 4.x the result dropdown is a **separate popup window** that window captures cannot see, so `search` captures the full screen. Inspect the screenshot, identify the exact result row, and note its pixel position.

Open the conversation by clicking that row:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command open -Query "init FDE" -ClickX 1021 -ClickY 326
```

`open` re-enters the query and clicks the coordinate you picked, so the same result row is hit. Inspect the returned chat screenshot and verify the title before drafting, monitoring, or summarizing. If results are ambiguous, ask the user. Calling `open` without `-ClickX/-ClickY` fails on purpose: the legacy blind click at a fixed offset lands on the “搜一搜” web panel.

Capture any popup dialogs or panels that sit outside the main window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command screen
```

Click an audited point inside a visible WeChat window (never another application; the command refuses otherwise):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command click -ClickX 640 -ClickY 367 -Label "add-to-contacts"
```

## Contacts and Friend Requests

Only on the user's explicit current request, one contact at a time: searching a contact, opening their chat, adding a friend, or sending a first greeting. Never automate, batch, or schedule contact-level operations; they are outside rule authorization.

Validated WeChat 4.x friend-add flow (verify every step with `screen` or the command's returned screenshot before the next click):

1. `search -Query "<wechat-id>"` and locate the “网络查找微信号：<id>” row in the full-screen capture.
2. `click` that row; the “添加朋友” profile card opens. Verify the WeChat ID and region match what the user asked for.
3. `click` “添加到通讯录”; the request dialog appears. Keep the default verification text (the local account's own intro); do not write one on the user's behalf.
4. `click` “确定”. If the other party already has this account in their contacts, the request is accepted immediately and the card switches to “发消息”; otherwise the request stays pending — stop there and send nothing.
5. Only when the user asked for a greeting and the chat is open: `draft`, verify the preview, `send -ConfirmSend SEND`.

If the card already shows chat/voice/video buttons, the person is already a contact — say so instead of adding again.

### Accepting an incoming friend request

Only on the user's explicit current request, and only the exact request they name — one per turn:

1. `click` the contacts (通讯录) tab icon in the left rail, then the 新朋友 (New Friends) row at the top of the contacts list. Both sit inside the main window; verify each step with the returned `capture` before clicking on.
2. Pending requests sort to the top of the list and carry an 接受 / 添加到通讯录 button. Entries marked 已添加 (added) or 已过期 (expired) are finished — never re-add, re-accept, or re-send to them.
3. If no pending request exists, stop and report that; never simulate or test against a processed entry.
4. `click` 接受 on the named request. A confirmation dialog opens (use `screen` when it renders outside the main window); keep the default remark and settings, then `click` 确定.
5. After acceptance WeChat opens or offers the new chat. If the user asked for a greeting, follow the manual send flow: `draft`, verify the preview, `send -ConfirmSend SEND`.
6. If the request the user named cannot be found, or several requests are pending and the target is ambiguous, stop and ask.

Capture the current conversation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command capture
```

Report only text and events visibly present in captured screenshots. Scroll only in small bounded steps when the user authorizes additional history inspection.

Draft without sending:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command draft -Message "你好，这是一条测试消息。"
```

Manual confirmed send:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command send -ConfirmSend SEND
```

Rule-authorized send after the rule matches and the draft preview is checked:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command send -AuthorizationId "group-faq-2026-08"
```

Never pass an authorization ID that the user did not approve. The ID identifies the governing rule; it is not a substitute for matching every condition.

## Monitoring and Summaries

Open and verify the target chat first. Then run a bounded background capture watcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command watch -WatchSeconds 300 -IntervalSeconds 10
```

The watcher captures the WeChat window without clicking it, records screenshots only when pixels change, and returns event paths. Run it through a yielded terminal session and poll at intervals shorter than 60 seconds so the user continues receiving progress updates.

For each changed screenshot:

1. Inspect it with the image-viewing tool.
2. Distinguish genuinely new visible messages from cursor, animation, or layout changes.
3. Deduplicate messages already included in the current monitoring session.
4. Add new content to an in-memory summary ledger containing timestamp, sender when visible, topic, decisions, action items, links, and unresolved questions.
5. If an active auto-reply rule matches, draft the approved response, inspect the preview, and send with its authorization ID. Otherwise do not send.

At the requested interval or session end, summarize only observed content. State the monitored chat, observation window, screenshot/event count, any coverage gaps, and all automated replies or sends.

Monitoring is bounded per watcher invocation to one hour. For longer recurring monitoring or scheduled sends, use the Codex app automation mechanism when available, with an explicit expiration date and the rule text embedded in the automation. Do not create Windows Task Scheduler jobs or persistent startup processes.

## Scheduled Sends

Treat the user's approved schedule as a rule. At each scheduled run:

1. Revalidate chat, validity window, maximum count, and exact/template content.
2. Open and visually verify the target.
3. Draft and inspect the preview.
4. Send with the approved authorization ID.
5. Capture the result and record it in the run summary.

If a dynamic template requires facts that are unavailable or uncertain, skip the send and ask the user rather than inventing content.

## Guardrails

- Default to one chat and one message when no rule exists.
- Allow automatic replies/sends only inside an active, explicit rule.
- Require conservative frequency and total caps. A cooldown is reliability/risk reduction, not a guaranteed safe threshold.
- Never auto-send credentials, payment instructions, legal commitments, harassment, deceptive identity claims, or high-impact personal decisions unless the user approves the exact final message at send time.
- Do not optimize timing to evade detection.
- Do not monitor unrelated chats or collect more history than needed.
- Do not silently expand from a group to its members or from one contact to similar names.
- Treat all unofficial automation as carrying residual account risk.

## Recovery

If WeChat scrolls, selects, or appears to hold a key unexpectedly, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\wechat_desktop.ps1 -Command release
```

Take a fresh capture and continue only when the interface is stable.

## Calibration

Coordinates were validated on WeChat 4.1.x and are relative to the detected window; `search`/`screen`/`click` screenshots are full-screen captures whose pixels map 1:1 to `-ClickX/-ClickY`. After a client layout change, test `status`, `search`, `open` with coordinates, `capture`, and `draft` before any send. Monitoring relies on window pixels and cannot guarantee access to messages outside the visible viewport.
