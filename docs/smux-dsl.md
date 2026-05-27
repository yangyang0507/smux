# smux DSL Specification

Authoritative specification for the `.smux` file format. Covers syntax, parser behavior, error conditions, and edge cases.

## 1. File Structure

A `.smux` file has two sections:
1. **Layout line** (required): defines tmux pane arrangement
2. **Pipeline block** (optional): defines automated agent workflow

```
.smux file = layout line + optional pipeline block

layout:    LABEL CMD | LABEL CMD , LABEL CMD | LABEL CMD
pipeline:  pipeline: NAME
             steps:
               FROM -> TO PROMPT
```

## 2. Lexical Rules

### 2.1 Line Processing

Each line is read and processed independently:

1. Strip inline comments: `#` outside double quotes starts a comment; everything after is removed
2. Trim leading/trailing whitespace from the result
3. If empty after comment stripping, skip the line

### 2.2 Inline Comments

- `#` outside double quotes starts a comment that extends to end of line
- `#` inside `"..."` is literal content, not a comment
- Backslash `\` outside quotes is a literal character — `\#` is literal `\` followed by comment `#`
- Backslash inside quotes prevents the next char from being treated as structural during tokenization (`\"` is not a closing quote, `\#` is literal, `\\` is literal `\`). During command unquoting, **only** `\"` → `"` and `\\` → `\` are processed; other `\X` sequences (including `\#` , `\|` , `\,`) keep the backslash.

Examples:

| Input | After comment strip | Notes |
|-------|-------------------|-------|
| `cmd # comment` | `cmd ` | Basic comment |
| `"hello # world"` | `"hello # world"` | `#` inside quotes preserved |
| `trailing \#` | `trailing \` | `\#` outside quotes → `\` then comment |
| `"he\"llo"` | `"he\"llo"` | Escaped quote (prevents structural `"`) |
| `# full line` | (empty) | Full-line comment |

### 2.3 Quote Handling

Double quotes `"..."` serve two purposes:
- **Delimiter protection**: `|` , `,` , `#` inside quotes are literal, not structural. Backslash `\` before a structural character prevents it from being structural.
- **Command unquoting**: Layout commands wrapped in outer `"..."` have outer quotes stripped. Then `\"` → `"` and `\\` → `\` are unescaped. Other `\X` sequences keep the backslash.

Pipeline prompts only strip outer quotes; inner escapes are not processed.

### 2.4 Whitespace

- Leading/trailing whitespace on each line is trimmed after comment stripping
- Spaces within bare commands are preserved: `a echo hello world` → label=`a`, cmd=`echo hello world`
- Indented lines (starting with space/tab) in pipeline blocks are step lines

## 3. Layout Syntax

### 3.1 Column Split

The layout line is split by `|` (quote-aware). Each segment becomes a column.

```
a cmd | b test          → 2 columns: (a cmd) | (b test)
a | b | c               → 3 empty-shell columns
```

### 3.2 Pane Split

Each column is split by `,` (quote-aware). Each segment becomes a pane within that column.

```
a cmd, b test           → 2 panes in same column
a, b | c                → column 1: panes a,b; column 2: pane c
```

### 3.3 Pane Anatomy

A pane cell has format: `LABEL COMMAND`

- **Label**: Required. First whitespace-delimited token. Must match `[A-Za-z0-9_.-]+`.
- **Command**: Optional. Everything after the label, trimmed. May contain spaces.
- If only a label is given, the pane opens an empty shell at the project root.

### 3.4 Label Rules

Valid label characters: `A-Z`, `a-z`, `0-9`, `_`, `.`, `-`

```
my-app.staging   valid
test_runner      valid
bad-label!       invalid — ! not in character set
```

### 3.5 Quoted Commands

Commands wrapped in `"..."` have outer quotes stripped and `\"` / `\\` unescaped:

```
a "echo \"hello\""     → cmd: echo "hello"
a "path\\to\\bin"      → cmd: path\to\bin
a "echo | pipe"        → cmd: echo | pipe  (pipe literal, not structural)
a "echo , comma"       → cmd: echo , comma (comma literal, not structural)
a "echo \| pipe"       → cmd: echo \| pipe (backslash NOT unescaped for \|)
a "echo \# hash"       → cmd: echo \# hash (backslash NOT unescaped for \#)
```

Only `\"` and `\\` are unescaped. Other `\X` sequences retain the backslash.
Bare commands (no surrounding quotes) are taken literally with no escape processing.

## 4. Pipeline Syntax

### 4.1 Structure

```
pipeline: <name>
steps:
  <from> -> <to> <prompt>
  <from> -> <to> <prompt>
```

### 4.2 Pipeline Name

- After `pipeline:` marker, trimmed whitespace
- Surrounded double quotes are stripped (legacy xargs behavior)
- Empty name is an error
- Multiple `pipeline:` declarations are an error

### 4.3 Step Lines

Each step line under `steps:` is indented and has format:

```
FROM -> TO PROMPT
```

- **FROM**: Agent label (must match `[A-Za-z0-9_.-]+`)
- **TO**: Agent label
- **PROMPT**: Everything after `TO LABEL`. If double-quoted, outer quotes are stripped. Inner escapes are NOT processed.

### 4.4 Pipeline Block Detection

Lines matching `^pipeline:` or `^steps:` (after trimming) mark the pipeline block. Indented lines following `steps:` are step lines.

## 5. Error Conditions

| Error | Trigger | Message |
|-------|---------|---------|
| Empty column | `\|` with nothing between pipes | `Empty column in .smux layout: ...` |
| Empty pane | `,,` with nothing between commas | `Empty pane in .smux layout: ...` |
| Invalid label | Label contains invalid characters | `Invalid label '...'. Labels must match [A-Za-z0-9_.-]+` |
| Unclosed quote | `"` without matching `"` | `Unclosed quote in .smux layout: ...` |
| Multiple layouts | More than one layout line | `.smux has multiple layout lines.` |
| Empty file | No layout line found | `.smux is empty. .smux requires exactly one layout line.` |
| Missing pipeline name | Steps without `pipeline:` | `Steps found without a 'pipeline:' name` |
| Empty pipeline name | `pipeline:` with no name | `Pipeline name is empty` |

## 6. Grammar

```bnf
smux-file       = { comment-line | blank-line } layout-line
                  { comment-line | blank-line | pipeline-block }

layout-line     = column { "|" column }
column          = pane { "," pane }
pane            = LABEL [ SP command ]
LABEL           = LABEL_CHAR { LABEL_CHAR }
LABEL_CHAR      = ALPHA | DIGIT | "_" | "." | "-"
command         = quoted-cmd | bare-cmd
quoted-cmd      = '"' { qchar } '"'
bare-cmd        = { any-char-except-unquoted-pipe-comma-hash }
qchar           = escape | any-char-except-quote
escape          = '\\' ( '"' | '\\' )

comment-line    = [ SP ] "#" any-char-to-eol | blank-line
blank-line      = [ SP ]

pipeline-block  = "pipeline:" SP NAME newline
                  INDENT "steps:" newline
                  { INDENT step-line newline }
step-line       = LABEL SP "->" SP LABEL SP prompt
prompt          = '"' { any-char } '"' | { any-char-to-eol }

ALPHA           = "A"..."Z" | "a"..."z"
DIGIT           = "0"..."9"
SP              = " " | TAB
INDENT          = " " | TAB
```

## 7. Behavioral Reference

| Scenario | Behavior |
|----------|----------|
| Bare command with spaces | `a echo hello world` → label=`a`, cmd=`echo hello world` |
| `\#` outside quotes | `trailing \#` → `trailing \` (backslash literal, `#` comment) |
| `#` inside quotes | `"hello # world"` → literal `hello # world` |
| Quoted pipeline name | `pipeline: "review-flow"` → name=`review-flow` (quotes stripped) |
| Pipeline prompt (quoted) | `a -> b "do the thing"` → prompt=`do the thing` |
| Pipeline prompt (bare) | `a -> b do the thing` → prompt=`do the thing` |
| Pipeline prompt escapes | `\"` in prompt → literal `\"` (NOT unescaped) |
| Comma in quoted cmd | `a "echo , comma"` → cmd=`echo , comma` |
| `\"` in quoted cmd | `a "echo \"hello\""` → cmd=`echo "hello"` |
| `\\` in quoted cmd | `a "path\\to"` → cmd=`path\to` |
| `\#` in quoted cmd | `a "echo \# hash"` → cmd=`echo \# hash` (backslash kept) |

Quoted command unquoting details (only `\"` and `\\` are unescaped):

```
Input                  |  unquote_command() output
a "echo | pipe"        |  echo | pipe
a "echo , comma"       |  echo , comma
a "echo \"hello\""     |  echo "hello"
a "path\\to"           |  path\to
a "echo \# hash"       |  echo \# hash
a "echo \| pipe"       |  echo \| pipe
```
