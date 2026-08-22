# Safety and Account-Risk Boundary

This automation uses ordinary Windows window capture plus foreground mouse and keyboard events. It does not use protocol emulation, DLL injection, API hooking, database decryption, or hidden message extraction.

This design reduces technical intrusion but does not make automation officially authorized or risk-free. Tencent/WeChat may restrict unapproved third-party or automated operation, and no public timing threshold guarantees account safety.

Use these defaults:

- Require an exact conversation and explicit message approval for one-off sends.
- Permit automatic replies or sends only under a user-approved rule with a scope, validity window, frequency cap, total cap, and stop conditions.
- Preview each generated message programmatically and visually even when rule-authorized; per-message user confirmation may be omitted only when the final content fits the approved rule.
- Keep the script cooldown and the rule's stricter cap. Never treat either as guaranteed safe.
- Avoid broad crawling, repeated marketing, automatic friend adding, rapid navigation, indefinite monitoring, and unbounded auto-replies.
- Record rule ID, timestamp, action type, and result screenshot without storing message text in the audit log.
- Prefer an official WeCom/WeChat Open Platform interface for sustained business workflows.

If the account is important or business-critical, explain that not automating the personal account is the lowest-risk option.

Official policy references:

- Tencent Service Agreement: https://edu.tencent.com/agreement.html
- Tencent policy index: https://www.tencent.net.cn/zh-cn/policies/
