# ISQLM Design & Implementation

> Interactive SQL Mode for MySQL — an Emacs built-in MySQL interactive client

## 1. Architecture Overview

ISQLM adopts an **Eshell-style architecture**: no dependency on `comint-mode`, no external processes. Elisp directly manages the buffer, markers, prompt, and I/O. SQL execution goes through the `mysql-el` dynamic module (C FFI to libmysqlclient).

```
┌─────────────────────────────────────────────┐
│              isqlm-mode buffer              │
│  ┌───────────────────────────────────────┐  │
│  │ [read-only] Welcome / past output     │  │
│  │ [read-only] SQL> <user input area>    │  │
│  └───────────────────────────────────────┘  │
│          ↕ insert-before-markers            │
│  ┌───────────────────────────────────────┐  │
│  │   isqlm--execute-sql / isqlm/CMD      │  │
│  │   (command dispatch + SQL execution)   │  │
│  └───────────────┬───────────────────────┘  │
│                  ↓                           │
│  ┌───────────────────────────────────────┐  │
│  │  mysql-el dynamic module (C FFI)      │  │
│  │  mysql-open / mysql-select /          │  │
│  │  mysql-execute / mysql-close          │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

### Comparison with the Old comint Architecture

| Aspect | Old (comint) | New (eshell-style) |
|--------|-------------|-------------------|
| Base mode | `comint-mode` | `fundamental-mode` |
| Processes | Requires `cat`/`hexl` pseudo-process | **Zero processes** |
| Output | `comint-output-filter` | Direct `insert-before-markers` |
| Prompt | Managed by comint | Self-managed (text properties) |
| History | `comint-input-ring` | Custom `ring` + file persistence |

## 2. Core Data Structures

### 2.1 Buffer-local Variables

| Variable | Type | Description |
|----------|------|-------------|
| `isqlm-connection` | mysql-el connection object | Current MySQL connection handle |
| `isqlm-connection-info` | plist | `:host :port :user :password :database` |
| `isqlm-pending-input` | string | Accumulation buffer for multi-line input |
| `isqlm-prompt-internal` | string | Current prompt string |
| `isqlm-history-ring` | ring | Input history ring buffer |
| `isqlm-history-index` | integer/nil | Current history navigation position |
| `isqlm-input-saved` | string/nil | Saved user input before history navigation |

### 2.2 Four Key Markers

```
Buffer layout:

  [welcome text read-only] ... [past output read-only]
  ↑ last-output-start           ↑ last-output-end = end of prompt
  [previous input read-only]
  ↑ last-input-start  ↑ last-input-end
  SQL> |<cursor, user typing here>
       ↑ last-output-end (also serves as the start boundary of current input)
```

- `isqlm-last-input-start` / `isqlm-last-input-end` — range of the last submitted input
- `isqlm-last-output-start` / `isqlm-last-output-end` — range of the last output; `last-output-end` doubles as the end of the current prompt / start boundary of user input

## 3. Input Processing Flow

`isqlm-send-input` is the sole input entry point (bound to `RET`):

```
User presses RET
  │
  ├─ Point in history area (before current prompt)?
  │     → Copy that line (strip prompt prefix) to current input area
  │     → Fall through to normal handling below
  │
  ├─ Read text between last-output-end → point-max
  ├─ Mark that region as read-only (field=input)
  ├─ Append to isqlm-pending-input
  │
  ├─ Empty input? → emit-prompt directly
  │
  ├─ No pending input & starts with `\` matching isqlm/CMD?
  │     → Execute built-in command → emit-prompt
  │
  ├─ SQL incomplete (no `;` or `\G`)? → set pending, emit continuation prompt "  -> "
  │
  └─ SQL complete → split into statements → execute each → output results → emit-prompt
```

### History Re-execution

When the cursor is in the history area (before `isqlm-last-output-end`), pressing `RET` extracts the text of the current line, strips any prompt prefix (`SQL> ` or `  -> `), copies it to the current input area, and proceeds with normal execution. This mirrors Eshell and sql-mode behavior.

### Multi-line Input

`M-RET` inserts a literal newline. When `RET` is pressed, the current line is appended to `isqlm-pending-input`. If the accumulated SQL does not end with `;` or `\G`, the continuation prompt `  -> ` is displayed.

### Multi-statement Execution

When the accumulated input contains multiple statements (e.g. `select 1; select 2;`), `isqlm--split-statements` splits them into individual statements. Each statement is executed separately via `isqlm--execute-sql`, and results are displayed sequentially. The splitter is quote-aware and comment-aware — it won't split on `;` inside strings, backtick identifiers, or comments.

## 4. Command Dispatch

Built-in commands are prefixed with `\` (following the MySQL client convention of `\G`, `\q`, etc.) and implemented as `isqlm/NAME` functions. When the user types `\connect`, the dispatcher strips the `\` prefix and looks up `isqlm/connect`.

**Lookup order** (`isqlm--try-builtin-command`):

1. **Alias resolution**: check `isqlm-command-aliases` (e.g. `"?"` → `"help"`)
2. **isqlm/CMD**: look up `(intern-soft "isqlm/CMD")` — built-in command
3. **Emacs Lisp function**: look up `(intern-soft "CMD")` — if `fboundp`, call it with args
4. **Unknown**: output error message

```elisp
;; User input: "\message \"hello world\""
;; → cmd = "message", args = ("hello world")
;; → isqlm/message not found
;; → (fboundp 'message) → t
;; → (apply #'message expanded-args)
```

**Special cases**:
- `\G` is NOT treated as a command — it is the SQL vertical display terminator
- `\setq` is a special form, so it's handled via `set` internally
- `\eval` receives the raw rest of the input line (not tokenized), so Elisp expressions with parentheses and quotes are preserved intact

**Command aliases**: The `isqlm-command-aliases` alist maps shorthand names to canonical names. Aliases are resolved before function lookup, allowing names that aren't valid Elisp identifiers.

### Argument Parsing

`isqlm--parse-command-line` splits the input into tokens respecting double-quoted strings. E.g. `\message "hello world"` → `("\\message" "hello world")`.

### Variable References

Arguments prefixed with `:` are expanded to the value of the corresponding Emacs variable via `isqlm--expand-arg`:

```
:user-login-name  →  (symbol-value 'user-login-name)  →  "hadleywang"
```

This applies to both isqlm built-in commands and Elisp function calls. For isqlm commands, expanded values are converted back to strings. For Elisp calls, native types are preserved.

Numeric strings are auto-coerced: `"42"` → `42`.

### SQL Variable Expansion

`:varname` references are also expanded inside SQL statements before execution, via `isqlm--expand-sql-variables`. The function scans the SQL character by character, tracking quote and comment context to avoid expanding inside strings, identifiers, or comments.

| Variable type | Expansion |
|--------------|-----------|
| string | `'value'` (single-quoted, internal `'` escaped as `''`) |
| integer | literal (e.g. `123`) |
| float | literal (e.g. `3.14`) |
| nil | `NULL` |

This expansion happens after statement splitting and before `isqlm--execute-sql`.

**Implemented commands:**

| User input | Function | Description |
|------------|----------|-------------|
| `\help` | `isqlm/help` | Show help |
| `\connect` | `isqlm/connect` | Connect (prompts for missing args) |
| `\connections` | `isqlm/connections` | List `sql-connection-alist` entries |
| `\disconnect` | `isqlm/disconnect` | Disconnect |
| `\reconnect` | `isqlm/reconnect` | Reconnect with last params |
| `\use` | `isqlm/use` | Switch database |
| `\status` | `isqlm/status` | Show connection status |
| `\style` | `isqlm/style` | Toggle/set table border style |
| `\eval` | `isqlm/eval` | Evaluate arbitrary Elisp expression |
| `\echo` | `isqlm/echo` | Output text with variable expansion |
| `\if` | `isqlm/if` | Begin conditional block |
| `\elif` | `isqlm/elif` | Else-if branch |
| `\else` | `isqlm/else` | Else branch |
| `\endif` | `isqlm/endif` | End conditional block |
| `\clear` | `isqlm/clear` | Clear buffer |
| `\history` | `isqlm/history` | Show history |
| `\quit`/`\exit` | `isqlm/quit` `isqlm/exit` | Quit |

Aliases: `\?` = `\h` = `\help`, `\q` = `\quit`, `\u` = `\use`

Unknown `\` commands that are not Emacs Lisp functions produce an error message.

### Extending with New Commands

Define an `isqlm/NAME` function and it is auto-discovered; the user invokes it via `\NAME`:

```elisp
(defun isqlm/tables (&rest _args)
  "Show tables in current database."
  (isqlm--quick-sql "SHOW TABLES;"))
;; User types \tables at the prompt
```

Add aliases via:

```elisp
(push '("t" . "tables") isqlm-command-aliases)
```

## 4.1 Conditional Flow (`\if`/`\elif`/`\else`/`\endif`)

Inspired by PostgreSQL's `psql` meta-commands. Uses a stack-based approach:

**State**: `isqlm-cond-stack` — a stack of plists, each with:
- `:satisfied` — whether any branch in this `\if` chain has been true
- `:active` — whether the current branch should execute

**Processing order** in `isqlm-send-input`:
1. Conditional flow commands (`\if`/`\elif`/`\else`/`\endif`) are **always** processed, even in inactive branches (to track nesting depth)
2. All other input is skipped when `(isqlm--cond-active-p)` returns nil

**Nesting**: When a `\if` is encountered inside an inactive branch, an unconditionally inactive frame `(:satisfied t :active nil)` is pushed. `\elif`/`\else` only evaluate conditions when the parent frame is active.

**Condition evaluation** (`isqlm--cond-truthy-p`):
- `:varname` — true if the Emacs variable is bound and non-nil
- `(elisp-expr)` — true if the expression evaluates to non-nil
- Falsy literals: `"0"`, `"false"`, `"no"`, `"nil"`, `""`, `"off"`
- Everything else is truthy

## 5. SQL Execution Layer

`isqlm--execute-sql` routes by SQL type:

| SQL prefix | Call | Return handling |
|-----------|------|-----------------|
| SELECT/SHOW/DESCRIBE/EXPLAIN | `mysql-select conn sql nil 'full` | Table or vertical formatting |
| USE | `mysql-execute` | Update connection-info and mode-line |
| Other (INSERT/UPDATE/DDL…) | `mysql-execute` | Display affected rows |

### Multi-statement Splitting

`isqlm--split-statements` parses the input character by character, tracking:
- Single quotes, double quotes, backticks (to skip `;` inside identifiers/strings)
- `--` and `#` line comments
- `/* */` block comments
- `\G` as an alternative statement terminator

Each complete statement (including its terminator) is returned as a list element.

### Error Message Extraction

`mysql-el` signals errors via `env->non_local_exit_signal(env, 'error, "string")` where data is a plain string, not the usual `(format-string . args)` list. This causes Emacs's `error-message-string` to return `"peculiar error"`. The function `isqlm--error-message` handles this by checking if `(cdr err)` is a string and returning it directly.

### mysql-el API Summary

| Function | Signature | Return value |
|----------|-----------|--------------|
| `mysql-open` | `(host user pass db port)` | Connection object |
| `mysql-close` | `(conn)` | nil |
| `mysql-select` | `(conn sql &optional types full)` | full mode: `(columns . rows)` |
| `mysql-execute` | `(conn sql)` | Affected rows (integer) |
| `mysql-version` | `()` | Version string |
| `mysqlp` | `(obj)` | Whether it's a valid connection |
| `mysql-available-p` | `()` | Whether the module is available |

## 6. Output System

All output is written to the buffer through three functions:

- `isqlm--output` — `insert-before-markers` at `last-output-end`, sets `read-only` + `field=output`
- `isqlm--output-error` — output with `isqlm-error-face`
- `isqlm--output-info` — output with `isqlm-info-face`

### Result Formatting

- **Table mode** (`isqlm--format-table`): Classic MySQL table with configurable border style (ASCII `+--|` or Unicode `┌┬┐├┼┤└┴┘│─`), auto-adaptive column widths, multi-line cell value support
- **Vertical mode** (`isqlm--format-vertical`): Triggered when SQL ends with `\G`, one field per line
- Row count capped by `isqlm-max-rows` (0 = unlimited)

### Table Styles

Controlled by `isqlm-table-style` (toggle via `\style` command):

| Style | Characters | Example |
|-------|-----------|---------|
| `ascii` (default) | `+ - \|` | `+----+------+` |
| `unicode` | `┌┬┐├┼┤└┴┘│─` | `┌────┬──────┐` |

Character sets are defined in `isqlm--table-chars-ascii` and `isqlm--table-chars-unicode`.

### Multi-line Cell Values

When a cell value contains `\n`, the table renderer splits it into multiple display lines. Column width is computed from the longest sub-line. Shorter sub-lines are padded with spaces. This correctly handles outputs like `EXPLAIN FORMAT=TREE`.

## 7. Prompt System

`isqlm--emit-prompt` inserts a prompt at `last-output-end` with these text properties:

```elisp
'(read-only t  field prompt  front-sticky (read-only field font-lock-face)
  rear-nonsticky (read-only field font-lock-face)  font-lock-face isqlm-prompt-face)
```

- `front-sticky` prevents insertion before the prompt
- `rear-nonsticky` ensures user input after the prompt does not inherit read-only
- `field=prompt` works with `isqlm-bol` so that `C-a` jumps to input start, not line start

## 8. History System

- Storage: `ring` data structure, capacity controlled by `isqlm-history-size` (default 512)
- Persistence: `isqlm-history-file-name` (default `~/.emacs.d/isqlm-history`), one entry per line
- Deduplication: consecutive identical inputs are not recorded
- Navigation: `M-p` / `M-n`; current input is saved to `isqlm-input-saved` on entry
- Auto-save: via `kill-buffer-hook` and `kill-emacs-hook`

**Important**: `isqlm--history-save` captures `isqlm-history-ring` (buffer-local) into a `let` binding before entering `with-temp-file`, since the macro switches to a temp buffer where buffer-local variables are nil.

## 9. Key Bindings

| Key | Command | Description |
|-----|---------|-------------|
| `RET` | `isqlm-send-input` | Submit input; or re-execute line under cursor |
| `M-RET` | `newline` | Insert literal newline |
| `C-c C-c` | `isqlm-interrupt` | Abort current (multi-line) input |
| `C-c C-q` | `isqlm-disconnect` | Disconnect |
| `C-c C-r` | `isqlm-reconnect` | Reconnect |
| `C-c C-n` | `isqlm-connect` | New connection |
| `C-c C-l` | `isqlm-clear-buffer` | Clear buffer |
| `C-c C-u` | `isqlm-show-databases` | SHOW DATABASES |
| `C-c C-t` | `isqlm-show-tables` | SHOW TABLES |
| `C-c C-d` | `isqlm-describe-table` | DESCRIBE TABLE |
| `M-p` / `M-n` | History navigation | Previous / next history |
| `C-a` | `isqlm-bol` | Jump to input start |

## 10. Customization Options (defcustom)

All options belong to the `isqlm` customize group:

| Option | Default | Description |
|--------|---------|-------------|
| `isqlm-prompt` | `"SQL> "` | Main prompt |
| `isqlm-prompt-continue` | `"  -> "` | Continuation prompt |
| `isqlm-prompt-read-only` | `t` | Whether prompt is read-only |
| `isqlm-noisy` | `t` | Beep on errors |
| `isqlm-table-style` | `ascii` | Table border style (`ascii` / `unicode`) |
| `isqlm-history-file-name` | `~/.emacs.d/isqlm-history` | History file |
| `isqlm-history-size` | `512` | History capacity |
| `isqlm-default-host` | `"127.0.0.1"` | Default host |
| `isqlm-default-port` | `3306` | Default port |
| `isqlm-default-user` | `"root"` | Default user |
| `isqlm-default-database` | `""` | Default database |
| `isqlm-max-column-width` | `0` | Max column width (0 = auto/window width) |
| `isqlm-max-rows` | `1000` | Max rows displayed |
| `isqlm-null-string` | `"NULL"` | Display string for NULL |

## 11. Faces

| Face | Usage |
|------|-------|
| `isqlm-prompt-face` | Prompt text |
| `isqlm-error-face` | Error messages |
| `isqlm-info-face` | Info messages (row counts, connection status, etc.) |
| `isqlm-table-header-face` | Table column headers |
| `isqlm-null-face` | NULL values (defined, available for extensions) |

## 12. Entry Points

- `M-x isqlm` — Create/switch to `*isqlm*` buffer
- `M-x isqlm-sql-connect` — Select from `sql-connection-alist` with completion, open `*isqlm:NAME*`
- `M-x isqlm-connect-and-run` — Start and immediately connect
- `\connect NAME` at the prompt — Connect using a `sql-connection-alist` entry
- `\connect HOST USER PASS DB PORT` at the prompt — Connect with explicit parameters

## 12.1 Sending SQL from External Buffers

| Function | Description |
|----------|-------------|
| `isqlm-send-string` | Send a SQL string to the ISQLM session |
| `isqlm-send-region` | Send the active region |
| `isqlm-send-paragraph` | Send the current paragraph |
| `isqlm-send-buffer` | Send the entire buffer |

The target buffer is determined by the global variable `isqlm-buffer`, automatically set when an ISQLM session is opened. For multiple sessions, set `isqlm-buffer` to the desired buffer name (e.g. `"*isqlm:mydb*"`).

## 13. Development Guide

### Adding a New Built-in Command

```elisp
(defun isqlm/mycommand (&rest args)
  "My custom command. ARGS: ARG1 ARG2."
  ;; args is a list of strings (user input split by whitespace)
  (isqlm--output-info "Hello from mycommand!\n"))
;; User types \mycommand at the prompt to invoke it
```

No registration needed — `isqlm--try-builtin-command` auto-discovers `\`-prefixed commands via `intern-soft`.

### Adding a New Interactive Command (M-x / key binding)

```elisp
(defun isqlm-my-action ()
  "My interactive action."
  (interactive)
  ;; perform action...
  (isqlm--emit-prompt))  ;; don't forget to emit prompt

;; Bind a key (in isqlm-mode-map)
```

### Key Implementation Notes

1. **All buffer writes must use `(let ((inhibit-read-only t)) ...)`** — past output is read-only
2. **Output must go through `isqlm--output` family** — they correctly maintain markers and text properties
3. **Call `isqlm--emit-prompt` after command execution** — unless `isqlm-send-input` handles it
4. **Pass `'full` as the 4th arg to `mysql-select`** — otherwise column names are not returned
5. **Update `mode-line-process` after connection state changes** — call `force-mode-line-update`
6. **`isqlm--history-save` must capture buffer-locals before `with-temp-file`** — the macro switches buffers
7. **`\quit`/`\exit` kills the buffer** — `isqlm-send-input` checks `(buffer-live-p isqlm-buf)` afterward to avoid operating on a dead buffer
8. **Multi-statement input is split by `isqlm--split-statements`** — it's quote/comment-aware; each statement is executed individually via `isqlm--execute-sql`
9. **Use `isqlm--error-message` instead of `error-message-string`** — mysql-el signals errors with a plain string data, which `error-message-string` cannot parse
