# Wapo Heartbeat Checklist

## Recurring Background Duties

- [ ] Check pending task queue
- [ ] Monitor designated email inboxes
- [ ] Review calendar for upcoming conflicts
- [ ] Check watched file system paths for changes
- [ ] Poll active tmux panes for completed tasks
- [ ] Review MCP server health
- [ ] Check Composio integration status
- [ ] Evaluate notification escalation queue

## Escalation Protocol

If a critical issue is detected and the user has not responded to text-based
notifications within the configured threshold (default: 10 minutes), the agent
is authorized to escalate via Twilio voice call.

Priority levels:
1. **P0 — Critical**: Immediate voice call (security breach, data loss risk)
2. **P1 — Urgent**: Voice call after 10min non-response (calendar conflicts, email deadlines)
3. **P2 — Normal**: Text notification only (routine updates, task completions)
4. **P3 — Low**: Batch in next heartbeat summary (informational, non-actionable)

## Last Heartbeat

- (awaiting first heartbeat)
