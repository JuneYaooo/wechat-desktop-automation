# Automation Rule Contract

Obtain explicit user approval for every required field before enabling automatic replies, scheduled sends, monitoring, or recurring summaries.

Rules may only authorize `auto_reply`, `scheduled_send`, and `monitor_summary` for an already-open chat. Contact-level operations — friend requests, first greetings, searching out new contacts — are never rule-authorizable; each one needs the user's explicit current request and manual step-by-step confirmation.

## Required fields

```yaml
id: unique-stable-rule-id
chats:
  - exact visible contact or group title
action: auto_reply | scheduled_send | monitor_summary
trigger:
  keywords: []          # any/all semantics must be explicit
  mention_required: false
  schedule: null        # timezone-qualified when used
response:
  exact_text: null
  template: null        # list every allowed variable
valid_from: ISO-8601 timestamp
valid_until: ISO-8601 timestamp
limits:
  min_interval_seconds: 30
  max_per_hour: 6
  max_total: 20
quiet_hours: null       # include timezone when used
summary_interval_minutes: null
stop_conditions:
  - user revokes the rule
  - ambiguous conversation or trigger
  - unexpected content or send result
```

Values above illustrate the schema and are not universal defaults. The user must approve actual values. Raise `min_interval_seconds` or lower caps when reasonable; never silently lower safety margins.

## Match procedure

Before each automated action, verify:

1. The exact visible chat title is in `chats`.
2. Current time is inside the validity window and outside quiet hours.
3. The trigger matches exactly as defined.
4. The generated text is exact or uses only approved template variables.
5. Per-hour, total, and minimum-interval limits remain satisfied.
6. No stop condition or sensitive-content exception applies.

If any check fails, do not send. Preserve the screenshot and report the skipped action.

## Suggested patterns

### Group FAQ reply

- Scope one named group.
- Require an @ mention or a narrow keyword set.
- Use one or more exact approved responses.
- Cap consecutive replies and stop when the conversation becomes ambiguous.

### Scheduled announcement

- Scope one named chat.
- Approve exact content and timezone-qualified schedule.
- Set a finite end date and maximum occurrence count.
- Revalidate the conversation title on every run.

### Monitoring summary

- Scope one already-open chat per watcher session.
- Define observation duration and summary cadence.
- Summarize only screenshots captured during that window.
- Record coverage gaps when the chat was minimized, obscured, disconnected, or changed faster than the capture interval.

## Revocation

Natural-language instructions such as “停止自动回复”, “停止监控”, or “取消这个规则” immediately revoke the matching rule. Stop active watcher processes, release input state, and retain only the minimum audit information needed to explain what occurred.
