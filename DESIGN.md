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
│  │  mysql-open / mysql-open-poll /       │  │
│  │  mysql-query / mysql-query-poll /     │  │
│  │  mysql-close                          │  │
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

`:varname` and `::varname` references are expanded inside SQL statements before execution, via `isqlm--expand-sql-variables`. The function scans the SQL character by character, tracking quote and comment context to avoid expanding inside strings, identifiers, or comments.

**`:varname`** — value expansion (strings are quoted):

| Variable type | Expansion |
|--------------|-----------|
| string | `'value'` (single-quoted, internal `'` escaped as `''`) |
| integer | literal (e.g. `123`) |
| float | literal (e.g. `3.14`) |
| nil | `NULL` |

**`::varname`** — raw expansion (no quoting, for identifiers):

| Variable type | Expansion |
|--------------|-----------|
| string | raw text (e.g. `users`) |
| number | literal |
| nil | `NULL` |

This expansion happens after statement splitting and before `isqlm--execute-sql`.

**Implemented commands:**

| User input | Function | Description |
|------------|----------|-------------|
| `\help` | `isqlm/help` | Show help |
| `\connect` | `isqlm/connect` | Connect (password via echo area) |
| `\connections` | `isqlm/connections` | List `sql-connection-alist` entries |
| `\disconnect` | `isqlm/disconnect` | Disconnect |
| `\reconnect` | `isqlm/reconnect` | Reconnect with last params |
| `\password` | `isqlm/password` | Toggle password prompting |
| `\use` | `isqlm/use` | Switch database |
| `\status` | `isqlm/status` | Show connection status |
| `\style` | `isqlm/style` | Toggle/set table border style |
| `\eval` | `isqlm/eval` | Evaluate arbitrary Elisp expression |
| `\echo` | `isqlm/echo` | Output text with variable expansion |
| `\for` | `isqlm--for-start` | Loop over values with `{ body }` |
| `\if` | `isqlm/if` | Begin conditional block |
| `\elif` | `isqlm/elif` | Else-if branch |
| `\else` | `isqlm/else` | Else branch |
| `\endif` | `isqlm/endif` | End conditional block |
| `\gset` | `isqlm/gset` | Store last query result as variables |
| `\i`/`\include` | `isqlm/i` | Execute SQL from file (`-` for script editor) |
| `\clear` | `isqlm/clear` | Clear buffer |
| `\history` | `isqlm/history` | Show history |
| `\quit`/`\exit` | `isqlm/quit` `isqlm/exit` | Quit |

Aliases: `\?` = `\h` = `\help`, `\q` = `\quit`, `\u` = `\use`, `\.` = `\i`

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

## 4.2 For Loops (`\for VAR in V1 V2 ... { body }`)

**State**: `isqlm-for-stack` — a stack of plists, each with:
- `:var` — loop variable symbol
- `:values` — list of values to iterate
- `:body` — collected body lines (in reverse during collection)
- `:brace` — whether the opening `{` has been seen
- `:depth` — nested `{}` depth counter

**Three syntax forms**:
1. **Inline**: `\for db in a b { \u :db; show tables; }` — parsed and executed immediately
2. **Brace on same line**: `\for i in 1 2 3 {` — body collected on subsequent lines until `}`
3. **Brace on next line**: `\for i in 1 2 3` → `{` → body → `}`

**Processing in `isqlm-send-input`**:
- `\for` detection pushes a frame onto `isqlm-for-stack`
- While `isqlm--for-collecting-p` is true, all input lines are diverted to `isqlm--for-collect-line`
- On `}`, `isqlm--for-execute-body` iterates: for each value, binds the variable with `set`, then processes each body line (dispatching `\` commands or executing SQL with variable expansion)

**Inline parsing**: the body string between `{` and `}` is split on `;`. Non-command lines without terminators get `;` auto-appended.

## 5. SQL Execution Layer

All SQL execution goes through `mysql-query` (the unified sync/async API from `mysql-el`). There are two execution paths:

1. **Interactive prompt** (`isqlm-send-input`) — always uses the **async** path: `mysql-query conn sql t` (ASYNC=t) → `mysql-query-poll` via timer
2. **Scripts, for-loops, quick-sql, send-region** — use the **sync** path: `mysql-query conn sql` (no ASYNC) via `isqlm--execute-sql` → `isqlm--execute-sql-1`

Both paths share `isqlm--format-result-string` for result formatting (table display, vertical display, `\gset`, row counts, warnings), eliminating duplicate formatting logic.

| Function | Role |
|----------|------|
| `isqlm--execute-sql` | Sync entry point: connection check + auto-reconnect wrapper |
| `isqlm--execute-sql-1` | Sync core: `mysql-query` (sync) + `isqlm--format-result-string`; USE handled specially |
| `isqlm--format-result-string` | **Shared**: format result plist into a string (SELECT/DML/\gset) |
| `isqlm--format-and-output-result` | Thin wrapper: calls `isqlm--format-result-string` and outputs to buffer |
| `isqlm--async-execute-one` | Async core: `mysql-query conn sql t` → immediate or poll |
| `isqlm--poll-query` | Timer callback: `mysql-query-poll` → `isqlm--format-and-output-result` |

### Auto-Reconnect

When `isqlm-auto-reconnect` is non-nil (default), `isqlm--execute-sql` wraps execution in a retry loop:

1. Execute the SQL via `isqlm--execute-sql-1`
2. If execution signals an error, check `isqlm--connection-lost-p` — it matches common lost-connection messages (`"lost connection"`, `"server has gone away"`, `"closed database"`, etc.) and also tests `(isqlm--connected-p)`
3. If the connection is lost, call `isqlm--try-auto-reconnect`:
   - Close the old (dead) connection handle silently
   - Re-open with the saved `isqlm-connection-info` (including the last `\use`'d database)
   - Output `"Lost connection. Trying to reconnect..."` and `"Reconnected to ..."`
4. Re-execute the original SQL — if this second attempt also fails, the error propagates normally

This mimics the MySQL CLI's behavior: when the server crashes/restarts, the next query transparently reconnects (preserving the current database) and retries.

### Async (Non-blocking) Execution

`mysql-el` provides the unified `mysql-query` function with an optional `ASYNC` parameter (requires MySQL 8.0.16+ `libmysqlclient` with `_nonblocking` API). Interactive SQL from `isqlm-send-input` always uses the async path — Emacs remains fully responsive during long-running queries.

**Architecture:**

```
User presses RET
  → isqlm--async-execute-statements
    → isqlm--async-execute-one (for each statement)
      → mysql-query conn sql t  (ASYNC=t, non-blocking)
      ├─ returns result plist → immediate: format-and-output-result → callback
      └─ returns 'not-ready → run-with-timer (20ms interval)
           → isqlm--poll-query
             → mysql-query-poll conn
             ├─ 'not-ready → continue polling
             └─ result plist → cancel timer → format-and-output-result → callback
                                              → next statement or emit prompt
```

**Async connect** (used by `isqlm--do-connect`):

```
isqlm--do-connect
  → mysql-open host user pass db port t  (ASYNC=t)
  → run-with-timer (20ms)
    → isqlm--poll-connect
      → mysql-open-poll conn
      ├─ 'not-ready → continue polling
      └─ 'complete → cancel timer → output "Connected to ..." → emit prompt
```

**Key design points:**

1. **Unified sync/async API**: `mysql-query` and `mysql-open` accept an optional `ASYNC` parameter (last arg = `t`). When ASYNC, a single `mysql-query-poll` / `mysql-open-poll` call replaces the old multi-step `start`/`continue`/`store-result` workflow
2. **Result plist**: `mysql-query` / `mysql-query-poll` return a plist — `(:type select :columns (...) :rows (...) :warning-count N)` or `(:type dml :affected-rows N :warning-count N)` — eliminating the need for separate `mysql-async-result` / `mysql-async-affected-rows` / `mysql-async-field-count` calls
3. **Shared result formatting**: `isqlm--format-result-string` handles the result plist for both sync and async paths — sync via `isqlm--execute-sql-1`, async via `isqlm--format-and-output-result` (a thin wrapper)
4. **Timer-based polling**: `run-with-timer` at 20ms intervals calls `mysql-query-poll`, which is a non-blocking C call that returns immediately
5. **Input blocking**: While async query runs, `isqlm--async-busy` is set; `RET` shows "Query in progress... (C-c C-c to cancel)"
6. **C-c C-c cancellation**: `isqlm-interrupt` calls `isqlm--async-cancel` which cancels the polling timer
7. **USE statements**: Handled synchronously in both paths (fast, no result set)
8. **Multi-statement**: Statements are chained via callbacks — each statement's completion triggers the next
9. **Sync path**: Scripts (`\i`), for-loops (`\for`), quick-sql (`C-c C-t`, `isqlm-send-region`), and auto-reconnect retry use `isqlm--execute-sql` → `isqlm--execute-sql-1` (sync `mysql-query`)

**Core functions:**

| Function | Description |
|----------|-------------|
| `isqlm--execute-sql-1` | Sync core: `mysql-query` (sync) → `isqlm--format-result-string`; USE updates mode-line |
| `isqlm--format-result-string` | **Shared formatter**: takes result plist + mode, returns formatted string (SELECT table/vertical/\gset, DML affected-rows) |
| `isqlm--format-and-output-result` | Async output wrapper: calls `isqlm--format-result-string`, outputs to buffer |
| `isqlm--async-execute-one` | Start async query via `mysql-query conn sql t`; if immediate result, format and callback; otherwise set up poll timer |
| `isqlm--poll-query` | Timer callback: call `mysql-query-poll`, on completion format result and invoke callback |

**Async connect functions:**

| Function | Description |
|----------|-------------|
| `isqlm--do-connect` | Call `mysql-open ... t` (ASYNC), set up poll timer |
| `isqlm--poll-connect` | Timer callback: call `mysql-open-poll`, on `'complete` output connection info and emit prompt |

### SQL Terminators

| Terminator | Effect |
|-----------|--------|
| `;` | Normal execution |
| `\G` | Vertical display (one field per line) |
| `\gset [PREFIX]` | Execute query, store 1-row result as variables (no output) |

`\gset` works in two modes:
1. **As a SQL terminator**: `SELECT 1 AS x\gset` or `SELECT 1 AS x;\gset` — executes the query silently and stores results. Recognized by `isqlm--sql-complete-p`, `isqlm--split-statements`, and `isqlm--strip-terminator` (returns `(:gset PREFIX)` mode).
2. **As a standalone command**: `\gset [PREFIX]` after a normal `SELECT ... ;` — uses the cached `isqlm-last-result` (saved by the preceding SELECT execution). Implemented by `isqlm/gset`.

Both modes require exactly 1 row. Each column becomes an Emacs variable named `PREFIX` + column name.

### Script Execution (`\i` / `\include`)

- **File mode** (`\i FILE`): reads file contents and passes to `isqlm--execute-script`
- **Interactive mode** (`\i -`): opens `*isqlm-script*` buffer with `sql-mode` + `isqlm-script-mode` minor mode. `C-c C-c` executes via `isqlm--execute-script`, `C-c C-k` aborts
- `isqlm--execute-script`: shared function that processes text line by line, accumulating multi-line SQL until a terminator is found, dispatching `\` commands immediately

### Multi-statement Splitting

`isqlm--split-statements` parses the input character by character, tracking:
- Single quotes, double quotes, backticks (to skip `;` inside identifiers/strings)
- `--` and `#` line comments
- `/* */` block comments
- `\G` as an alternative statement terminator

Each complete statement (including its terminator) is returned as a list element.

### Error Handling

`mysql-el` signals a dedicated `mysql-error` error symbol (inheriting from `error`) with structured data: `(mysql-error ERRNO SQLSTATE ERRMSG)`. This is modeled after Emacs's built-in `sqlite-error`.

In a `condition-case` handler, `err` is `(mysql-error 1690 "22003" "BIGINT value is out of range...")`.

**Elisp accessors** (in `isqlm.el`):

| Function | Returns |
|----------|---------|
| `isqlm--mysql-error-p` | Non-nil if ERR is a `mysql-error` signal |
| `isqlm--mysql-error-errno` | Integer error code (e.g. `1690`) |
| `isqlm--mysql-error-sqlstate` | SQLSTATE string (e.g. `"22003"`) |
| `isqlm--mysql-error-errmsg` | Error message string |

**`isqlm--error-message`**: For `mysql-error` signals, formats as `"ERROR 1690 (22003): BIGINT value is out of range..."` (MySQL CLI style). For generic `error` signals, extracts the message string as before.

**`isqlm--output-mysql-error`**: Outputs the error using `isqlm--error-message`. No longer needs to re-query the connection handle (which could have been reset).

**Warning count**: `mysql-el` exposes `mysql-warning-count` (wrapping `mysql_warning_count()`). The helper `isqlm--warning-count-string` returns `", 2 warnings"` or `""`. This is appended to all result summary lines (`N rows in set`, `Empty set`, `Query OK, N rows affected`).

### mysql-el API Summary

| Function | Signature | Return value |
|----------|-----------|--------------|
| `mysql-open` | `(host user pass [db] [port] [async])` | Connection object; ASYNC=t for non-blocking connect |
| `mysql-open-poll` | `(conn)` | `'not-ready` or `'complete` |
| `mysql-close` | `(conn)` | nil |
| `mysql-query` | `(conn sql [async])` | Result plist or `'not-ready` (when ASYNC=t) |
| `mysql-query-poll` | `(conn)` | Result plist or `'not-ready` |
| `mysql-select` | `(conn sql [types] [full])` | Convenience sync alias; full: `(columns . rows)` |
| `mysql-execute` | `(conn sql [params])` | Convenience sync alias; affected rows (integer) |
| `mysql-warning-count` | `(conn)` | Warning count (integer) |
| `mysql-version` | `()` | Version string |
| `mysqlp` | `(obj)` | Whether it's a valid connection |
| `mysql-available-p` | `()` | Whether the module is available |

**Result plist format** (returned by `mysql-query` / `mysql-query-poll`):

- SELECT: `(:type select :columns ("col1" ...) :rows ((val1 ...) ...) :warning-count N)`
- DML: `(:type dml :affected-rows N :warning-count N)`

**Error signal**: `mysql-error` symbol with data `(ERRNO SQLSTATE ERRMSG)`.
Prepared statement errors use the same symbol.

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
| `isqlm-table-style` | `unicode` | Table border style (`ascii` / `unicode`) |
| `isqlm-history-file-name` | `~/.emacs.d/isqlm-history` | History file |
| `isqlm-history-size` | `512` | History capacity |
| `isqlm-default-host` | `"127.0.0.1"` | Default host |
| `isqlm-default-port` | `3306` | Default port |
| `isqlm-default-user` | `"root"` | Default user |
| `isqlm-default-database` | `""` | Default database |
| `isqlm-prompt-password` | `nil` | Prompt for password on connect |
| `isqlm-auto-reconnect` | `t` | Auto-reconnect on connection loss |
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
- `\connect [HOST] [USER] [DB] [PORT]` at the prompt — Connect with positional parameters (all optional, defaults applied); password prompted via echo area

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
4. **All SQL goes through `mysql-query`** — both sync (`isqlm--execute-sql-1`) and async (`isqlm--async-execute-one`) use `mysql-query`; result formatting is shared via `isqlm--format-result-string`
5. **Update `mode-line-process` after connection state changes** — call `force-mode-line-update`
6. **`isqlm--history-save` must capture buffer-locals before `with-temp-file`** — the macro switches buffers
7. **`\quit`/`\exit` kills the buffer** — `isqlm-send-input` checks `(buffer-live-p isqlm-buf)` afterward to avoid operating on a dead buffer
8. **Multi-statement input is split by `isqlm--split-statements`** — it's quote/comment-aware; each statement is executed individually via `isqlm--execute-sql`
9. **Use `isqlm--error-message` instead of `error-message-string`** — `mysql-el` signals `mysql-error` with structured data `(ERRNO SQLSTATE ERRMSG)` which `error-message-string` cannot format; `isqlm--error-message` handles both `mysql-error` and generic `error` signals

## 14. Unit Tests

Test file: `isqlm-test.el` — uses Emacs's built-in `ert` (Emacs Regression Testing) framework.

### Running Tests

```bash
emacs -batch -l isqlm.el -l isqlm-test.el -f ert-run-tests-batch-and-exit
```

### Test Infrastructure

**`isqlm-test-with-buffer`** — macro that creates a temporary buffer with all buffer-local variables (`isqlm-pending-input`, `isqlm-cond-stack`, `isqlm-for-stack`, markers, etc.) properly initialized. No MySQL connection or `mysql-el` module required. Used for tests that exercise buffer-level logic (conditional flow stack operations, script execution, etc.).

**`isqlm-test-with-dynvars`** — macro that works around `lexical-binding: t`. Since `let` in lexical-binding mode creates lexical bindings invisible to `symbol-value`/`boundp`, this macro uses `set` to create true dynamic bindings, and `makunbound` to clean up afterward. Used for variable expansion tests where `:varname` references rely on `symbol-value`.

### Test Coverage

| Category | Tests | What is verified |
|----------|-------|-----------------|
| SQL Parsing | `isqlm-test-sql-complete-p`, `isqlm-test-strip-terminator`, `isqlm-test-split-statements` | Statement completeness detection (`;`, `\G`, `\gset`), terminator stripping, multi-statement splitting (quote-aware, comment-aware, `\gset` vs `\G` disambiguation) |
| Conditional Flow — Values | `isqlm-test-cond-falsy-value-p`, `isqlm-test-cond-truthy-p-literal`, `isqlm-test-cond-truthy-p-variable`, `isqlm-test-cond-truthy-p-elisp`, `isqlm-test-cond-truthy-p-elisp-with-varref` | Falsy detection (nil/0/""/"false"/"no"/"off"), truthy literals, `:varname` references, Elisp expressions, `:varname` inside Elisp expressions |
| Conditional Flow — Stack | `isqlm-test-if-else-endif`, `isqlm-test-if-elif`, `isqlm-test-nested-if` | `\if`/`\else`/`\endif` toggling, `\elif` chain (only first true branch active), nested `\if` blocks |
| Conditional Flow — Scripts | `isqlm-test-script-if-else`, `isqlm-test-script-if-elisp-varref` | Regression tests: `\if`/`\else` in `isqlm--execute-script`, `:varname` expansion inside Elisp conditions in scripts |
| Command Parsing | `isqlm-test-parse-command-line` | Tokenization with double-quoted strings |
| Variable Expansion | `isqlm-test-expand-arg`, `isqlm-test-expand-sql-variables`, `isqlm-test-expand-expr-variables` | `:varname` argument expansion, SQL `:var`/`::var` expansion (quoting, escaping, NULL, inside-string immunity), Elisp expression `:varname` expansion |
| Command Aliases | `isqlm-test-command-aliases` | Alias alist entries (`?`→`help`, `h`→`help`, `q`→`quit`, `u`→`use`, `.`→`i`) |
| Conditional Detection | `isqlm-test-cond-flow-command-p` | `isqlm--cond-flow-command-p` correctly identifies `\if`/`\elif`/`\else`/`\endif` and rejects others |
| Display Width | `isqlm-test-display-width` | Multi-line string width calculation for table rendering |
| Error Messages | `isqlm-test-error-message` | `isqlm--error-message` handles `mysql-error` structured signals `(mysql-error ERRNO SQLSTATE ERRMSG)`, generic `(error . "string")`, and standard `(error "fmt" args...)` formats; tests `isqlm--mysql-error-p` predicate and accessor functions |

### Design Principles

1. **No MySQL dependency**: All tests run without a MySQL server or the `mysql-el` module. Buffer-level logic and pure functions are tested in isolation.
2. **Regression-driven**: Key tests were added in response to specific bugs (e.g., `\if` ignored in scripts, `:varname` treated as Elisp keyword in `\if` expressions).
3. **Output capture**: Script execution tests use `cl-letf` to temporarily replace `isqlm--output`/`isqlm--output-info`/`isqlm--output-error` with lambda functions that capture output into a list, enabling assertions on what would have been displayed.
