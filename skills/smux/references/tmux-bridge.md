---
name: tmux-bridge
description: Agent-agnostic CLI for cross-pane communication — type text, send keys, read output, and interact between tmux panes.
metadata:
  { "openclaw": { "emoji": "🌉", "os": ["darwin", "linux"], "requires": { "bins": ["tmux", "tmux-bridge"] } } }
---

# tmux-bridge

A single CLI that lets any AI agent (Claude Code, Codex, Gemini CLI, etc.) interact with any other tmux pane. Works via plain bash — any tool that can run shell commands can use it.

Every command is **atomic**: `type` types text (no Enter), `keys` sends special keys, `read` captures pane content. There is no compound "send" command — you control each step and verify between them.

## DO NOT WAIT OR POLL — EVER

**Other panes have agents that will reply to you via tmux-bridge.** When you send a message to another agent, their reply will appear directly in YOUR pane as a `[tmux-bridge from:...]` message. You do NOT need to:

- Sleep or wait after sending
- Poll the target pane for a response
- Read the target pane to check if they replied
- Loop or retry to see output

**Type your message, press Enter, and move on.** The other agent will type their reply back into your pane. You'll see it arrive.

The ONLY time you need to read a target pane is:
- **Before** interacting with it (enforced — see Read Guard below)
- **After typing** to verify your text landed correctly before pressing Enter
- When interacting with a **non-agent pane** (plain shell, running process) where there's no agent to reply back

## Read Guard — Enforced by CLI

The CLI **enforces** read-before-act. You cannot `type` or `keys` to a pane unless you have read it first.

**How it works:**
1. `tmux-bridge read <target>` marks the pane as "read"
2. `tmux-bridge type/keys <target>` checks for that mark — **errors if you haven't read**
3. After a successful `type`/`keys`, the mark is **cleared** — you must read again before the next interaction

This enforces the **read-act-read** cycle at the CLI level. If you skip the read, the command fails:

```
$ tmux-bridge type codex 'hello'
error: must read the pane before interacting. Run: tmux-bridge read codex
```

## When to Use

**USE this skill when:**

- Sending messages to another agent running in a tmux pane
- Reading output from another pane
- Labeling and discovering panes by name
- Any cross-pane interaction between agents

## When NOT to Use

**DON'T use this skill when:**

- Running one-off shell commands in the current pane
- Tasks that don't involve other tmux panes
- You need raw tmux commands → use the `tmux` skill directly

## Input Modes

`type` and `message` accept text via three mechanisms, in precedence order: `--stdin` > `--base64` > piped stdin auto-detect > argv text.

**Agent path (robust default) — safe shell transport:**
```bash
printf '%s' "$msg" | tmux-bridge message codex --stdin
```

**Human one-liners — simple messages with no embedded quotes:**
```bash
tmux-bridge message codex 'review src/auth.ts'
```

**Advanced transport — tool calls, JSON, hostile shell contexts:**
```bash
# Base64 via stdin (safe, no line-wrapping issues)
printf '%s' "$msg" | tmux-bridge message codex --stdin --base64
# Single-arg base64 (portable: tr -d '\n' strips base64 line wrapping)
b64=$(printf '%s' "$msg" | base64 | tr -d '\n')
tmux-bridge message codex --base64 "$b64"
```

`--base64` accepts exactly one argv token. Multi-token `--base64` input is rejected — use `--stdin --base64` for complex payloads.

If text is omitted entirely and stdin is piped (non-TTY), stdin is auto-read.

Shell quoting is fundamentally fragile for AI-generated text. Single quotes (`'...'`) work for simple human messages but fail when the message itself contains `'`. Double quotes (`"..."`) expose `$` and `!` to shell expansion. For agents, always prefer stdin.

`--stdin` and `--base64` only protect the shell-to-`tmux-bridge` transport. `tmux-bridge` still types into a live terminal pane, so the target pane must be in normal input mode. If the target is in tmux copy-mode, search, jump, or another tmux prompt, `type`, `message`, and `keys` fail instead of injecting text into the wrong mode. Press `Escape` or `q` in that pane, then retry.

Keep agent-to-agent messages short and preferably single-line. For long diffs, logs, or reports, use `file` so tmux-bridge stages the content and sends only a shared path:

```bash
tmux-bridge read codex 20
git diff > /tmp/review.diff
tmux-bridge file codex /tmp/review.diff
tmux-bridge read codex 20
tmux-bridge keys codex Enter
```

```bash
git diff | tmux-bridge file codex --stdin --name review.diff
```

`file` truncates staged content by default at 262144 bytes or 2000 lines and appends a truncation notice. Override with `--max-bytes <n>` or `--max-lines <n>`.

## Command Reference

| Command | Description | Example |
|---|---|---|
| `tmux-bridge list` | Show all panes with target, pid, command, size, label | `tmux-bridge list` |
| `tmux-bridge type <target> [flags] [text...]` | Type text without pressing Enter | `printf '%s' "$msg" \| tmux-bridge type codex --stdin` |
| `tmux-bridge message <target> [flags] [text...]` | Type text with auto sender info and reply target | `printf '%s' "$msg" \| tmux-bridge message codex --stdin` |
| `tmux-bridge file <target> [flags] <path>` | Stage file/stdin content and send the shared path | `tmux-bridge file codex ./diff.txt` |
| `tmux-bridge read <target> [lines]` | Read last N lines (default 50) | `tmux-bridge read codex 100` |
| `tmux-bridge keys <target> <key>...` | Send special keys | `tmux-bridge keys codex Enter` |
| `tmux-bridge name <target> <label>` | Label a pane (visible in tmux border) | `tmux-bridge name %3 codex` |
| `tmux-bridge resolve <label>` | Print pane target for a label | `tmux-bridge resolve codex` |
| `tmux-bridge id` | Print this pane's ID | `tmux-bridge id` |

## Target Resolution

Targets can be:
- **tmux native**: `session:window.pane` (e.g. `shared:0.1`), pane ID (`%3`), or window index (`0`)
- **label**: Any string set via `tmux-bridge name` — resolved automatically

This means `tmux-bridge type codex 'hello'` works directly if the pane was labeled `codex`.

## Messaging Convention

The `message` command auto-prepends sender identity and location to every message:

```
[tmux-bridge from:claude pane:%4 at:shared:0.0] Please review src/auth.ts
```

The receiver sees: who sent it (`from`), the exact pane to reply to (`pane`), and the session/window location (`at`).

When you see this header in your pane, reply to the **pane** from the header using `tmux-bridge message`:

```bash
tmux-bridge read %4 20
printf '%s' '87% line coverage. Missing the OAuth refresh token path (lines 142-168).' | tmux-bridge message %4 --stdin
tmux-bridge read %4 20
tmux-bridge keys %4 Enter
```

### Receiving messages — IMPORTANT

**When you see a message prefixed with `[tmux-bridge from:<sender> pane:<id> at:<location>]`, you MUST reply using tmux-bridge:**

```bash
tmux-bridge read <pane-id-from-header> 20
printf '%s' 'your response here' | tmux-bridge message <pane-id-from-header> --stdin
tmux-bridge read <pane-id-from-header> 20
tmux-bridge keys <pane-id-from-header> Enter
```

This sends your reply directly into the sender's pane so they see it immediately. **Do not just respond in your own pane** — the sender won't see it unless you send it back via tmux-bridge.

Keep replies concise (1-3 sentences). They will be typed into the sender's terminal as a single line.

### Example conversation

**Agent A (claude) sends:**
```bash
tmux-bridge read codex 20       # 1. READ — satisfy read guard
printf '%s' 'What is the test coverage for src/auth.ts?' | tmux-bridge message codex --stdin
                                 # 2. MESSAGE — auto-prepends [tmux-bridge from:claude...]
tmux-bridge read codex 20       # 3. READ — verify text landed
tmux-bridge keys codex Enter    # 4. KEYS — press Enter to submit
# Done. Do NOT wait, poll, or read codex for the response.
# Agent B will reply via tmux-bridge and it will appear in your pane.
```

**Agent B (codex) sees in their prompt:**
```
[tmux-bridge from:claude pane:%4 at:shared:0.0] What is the test coverage for src/auth.ts?
```

**Agent B replies:**
```bash
tmux-bridge read %4 20          # 1. READ — satisfy read guard (use pane from header)
printf '%s' 'src/auth.ts has 87% line coverage. Missing coverage on the OAuth refresh token path (lines 142-168).' | tmux-bridge message %4 --stdin
                                 # 2. MESSAGE — auto-prepends [tmux-bridge from:codex...]
tmux-bridge read %4 20          # 3. READ — verify text landed
tmux-bridge keys %4 Enter       # 4. KEYS — press Enter to submit
# Done. The reply appears in Agent A's pane automatically.
```

## Read-Act-Read Cycle

Every interaction with another pane MUST follow the **read → act → read** cycle. The CLI enforces this — `type`/`keys` will error if you haven't read first, and each action clears the read mark.

The full cycle for sending a message:

1. **Read** the target pane (satisfies read guard)
2. **Message** or **Type** your text (clears read mark)
3. **Read** again (verify text landed, re-satisfy read guard)
4. **Keys** Enter (submit the message, clears read mark)
5. **Read** again if you need to see the result (non-agent panes only)

### Example: sending a message to an agent

```bash
# 1. READ — check the pane and satisfy read guard
tmux-bridge read codex 20

# 2. MESSAGE — type the message with auto sender info (no Enter)
printf '%s' 'Please review the changes in src/auth.ts' | tmux-bridge message codex --stdin

# 3. READ — verify the text landed correctly
tmux-bridge read codex 20

# 4. KEYS — press Enter to submit
tmux-bridge keys codex Enter

# STOP. Do NOT read codex to check for a reply.
# The other agent will reply via tmux-bridge into YOUR pane.
```

### Example: approving a prompt (non-agent pane)

```bash
# 1. READ — see what the prompt is asking
tmux-bridge read worker 10

# 2. TYPE — type the answer
tmux-bridge type worker 'y'

# 3. READ — verify it landed
tmux-bridge read worker 10

# 4. KEYS — press Enter to submit
tmux-bridge keys worker Enter

# 5. READ — for non-agent panes, you DO need to read to see the result
tmux-bridge read worker 20
```

## Agent-to-Agent Workflow

### Step 1: Label yourself

```bash
tmux-bridge name "$(tmux-bridge id)" claude
```

### Step 2: Discover other panes

```bash
tmux-bridge list
```

### Step 3: Read, message, read, Enter

```bash
tmux-bridge read codex 20
printf '%s' 'Please review the changes in src/auth.ts and suggest improvements' | tmux-bridge message codex --stdin
tmux-bridge read codex 20
tmux-bridge keys codex Enter
# Done. Wait for the reply to appear in your pane.
```

## Tips

- **Read guard is enforced** — you MUST read before every `type`/`keys`. The CLI will error otherwise.
- **Every action clears the read mark** — after `type`/`message`, you must `read` again before `keys`.
- **Never wait or poll** — agent panes reply to you via tmux-bridge. The response appears in YOUR pane.
- **Label panes early** — it makes cross-agent communication much easier than using `%N` IDs
- **Always use `--stdin` for agent messages** — avoids all shell quoting issues
- **Use `file` for long diffs/logs/reports** — it sends a shared temp-file path, not raw content
- **Target panes must be in normal input mode** — copy-mode/search/jump prompts are rejected before sending
- **`type` uses literal mode** — it uses `-l` so special characters are typed as-is
- **`message` auto-prepends sender info** — preferred over `type` for agent-to-agent communication
- **`read` defaults to 50 lines** — pass a higher number for more context
- **Non-agent panes** (shells, processes) are the exception — you DO need to read them to see output
