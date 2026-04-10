# ISQLM — Interactive SQL Mode for MySQL

An Emacs major mode providing an interactive MySQL console, modeled after
Eshell's architecture — **no external processes, no comint**. The mode manages
its own buffer, markers, prompt, and I/O directly, communicating with MySQL
through the [`mysql-el`](https://github.com/hadleywang/mysql-el) dynamic module (C FFI to libmysqlclient).

## Features

- **Zero external processes** — no shell, no `mysql` CLI, no comint; pure Elisp + C module
- **Built-in commands** prefixed with `\` (e.g. `\connect`, `\help`, `\style`)
- **`sql-connection-alist` integration** — reuse Emacs's standard connection definitions
- **Multi-statement execution** — `select 1; select 2;` executes each statement and shows all results
- **Tabular result display** with ASCII or Unicode box-drawing borders
- **Vertical display** — end SQL with `\G` for row-per-field output
- **Conditional flow** — `\if`/`\elif`/`\else`/`\endif` with nesting support
- **Multi-line SQL input** — press `M-RET` for literal newlines; `RET` submits
- **Multi-line cell values** — newlines inside column values render correctly
- **History re-execution** — move cursor to any previous input line and press `RET` to re-run it
- **Input interrupt** — `C-c C-c` aborts current (multi-line) input
- **Send SQL from external buffers** — `isqlm-send-region`, `isqlm-send-paragraph`, etc.
- **Ring-based input history** with file persistence (`M-p` / `M-n`)
- **SQL keyword font-locking**
- **Auto-adaptive column widths** based on window size
- **Command aliases** — extensible shorthand mappings (`\?` = `\help`, etc.)
- **Elisp function dispatch** — `\CMD` falls back to Emacs Lisp functions (à la Eshell)
- **Variable references** — use `:varname` in command args to reference Emacs variables
- **Improved error messages** — correctly extracts MySQL error details from `mysql-el`

## Requirements

- Emacs 29+ (with dynamic module support)
- [`mysql-el`](https://github.com/swida/mysql-el) — Emacs dynamic module wrapping libmysqlclient

## Installation

1. Build and install `mysql-el` so that `(require 'mysql-el)` works.
2. Add `isqlm.el` to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/isqlm")
(autoload 'isqlm "isqlm" "Interactive SQL Mode for MySQL." t)
(autoload 'isqlm-sql-connect "isqlm" "Connect via sql-connection-alist." t)
```

## Quick Start

### Option 1: Connect with explicit parameters

```
M-x isqlm
```

Then at the `SQL>` prompt:

```
SQL> \connect 127.0.0.1 root mypassword mydb 3306
Connected to root@127.0.0.1:3306/mydb (MySQL client library: 8.0.36)
SQL> SELECT * FROM users LIMIT 2;
+----+-------+-------------------+
| id | name  | email             |
+----+-------+-------------------+
| 1  | Alice | alice@example.com |
| 2  | Bob   | bob@example.com   |
+----+-------+-------------------+
2 rows in set
```

### Option 2: Connect via `sql-connection-alist`

Define connections in your Emacs config (the standard `sql.el` variable):

```elisp
(setq sql-connection-alist
  '(("mydb"
     (sql-server "127.0.0.1")
     (sql-user "root")
     (sql-password "secret")
     (sql-database "testdb")
     (sql-port 3306))
    ("prod"
     (sql-server "db.example.com")
     (sql-user "admin")
     (sql-database "production")
     (sql-port 3306))))
```

Then connect by name — either from the minibuffer or the prompt:

```
M-x isqlm-sql-connect RET mydb RET     ← with completion
```

```
SQL> \connect mydb
Connected to root@127.0.0.1:3306/testdb (MySQL client library: 8.0.36)
```

List available connections:

```
SQL> \connections
Available connections (from sql-connection-alist):
  mydb                 root@127.0.0.1:3306/testdb
  prod                 admin@db.example.com:3306/production
```

If `sql-password` is omitted from a connection entry, you will be prompted for it.

### Option 3: Connect from Lisp

```elisp
(isqlm-connect-and-run "127.0.0.1" "root" "password" "mydb" 3306)
```

### Table Styles

Toggle between ASCII and Unicode box-drawing borders:

```
SQL> \style unicode
Table style: unicode
SQL> SELECT * FROM users LIMIT 2;
┌────┬───────┬───────────────────┐
│ id │ name  │ email             │
├────┼───────┼───────────────────┤
│ 1  │ Alice │ alice@example.com │
│ 2  │ Bob   │ bob@example.com   │
└────┴───────┴───────────────────┘
2 rows in set
```

## Built-in Commands

All built-in commands are prefixed with `\`:

| Command | Description |
|---------|-------------|
| `\connect [NAME]` | Connect using a `sql-connection-alist` entry |
| `\connect HOST USER PASS DB PORT` | Connect with explicit parameters |
| `\connect` | Connect interactively (prompts for each parameter) |
| `\connections` | List available connections from `sql-connection-alist` |
| `\disconnect` | Disconnect |
| `\reconnect` | Reconnect with last parameters |
| `\use DATABASE` | Switch database |
| `\status` | Show connection status |
| `\style [ascii\|unicode]` | Toggle or set table border style |
| `\eval EXPRESSION` | Evaluate an Elisp expression |
| `\clear` | Clear buffer |
| `\history` | Show input history |
| `\echo TEXT...` | Output text (supports `:varname` expansion) |
| `\if CONDITION` | Begin conditional block |
| `\elif CONDITION` | Else-if branch |
| `\else` | Else branch |
| `\endif` | End conditional block |
| `\eval EXPRESSION` | Evaluate Elisp expression |
| `\for VAR in V1 V2 ... { body }` | Loop over values |
| `\gset [PREFIX]` | Store last query result as variables |
| `\i FILE` / `\include FILE` | Execute SQL from file (`-` for interactive editor) |
| `\help` | Show help |
| `\quit` / `\exit` | Disconnect and kill buffer |

**Aliases:** `\?` = `\h` = `\help`, `\q` = `\quit`, `\u` = `\use`, `\.` = `\i`

### Elisp Functions & Variables

Any `\CMD` that isn't a built-in isqlm command is looked up as an Emacs Lisp function:

```
SQL> \message "hello world"
hello world
SQL> \buffer-name
*isqlm*
SQL> \+ 1 2
3
SQL> \emacs-version
29.1
```

Use `:varname` to reference Emacs variables in command arguments:

```
SQL> \setq mydb "testdb"
testdb
SQL> \u :mydb
Database changed to: testdb
SQL> \message :user-login-name
hadleywang
```

Variables are also expanded in SQL statements:

- `:varname` — **value** expansion (strings are single-quoted)
- `::varname` — **raw** expansion (no quoting, for identifiers like table/column names)

```
SQL> \setq cid 123
SQL> SELECT * FROM customer WHERE customer_id = :cid;
-- expands to: SELECT * FROM customer WHERE customer_id = 123;

SQL> \setq name "O'Brien"
SQL> SELECT * FROM users WHERE name = :name;
-- expands to: SELECT * FROM users WHERE name = 'O''Brien';

SQL> \setq tbl "users"
SQL> SELECT * FROM ::tbl WHERE id = 1;
-- expands to: SELECT * FROM users WHERE id = 1;
```

Expansion rules: strings → `'quoted'`, numbers → literal, nil → `NULL`.
Variables inside quotes and comments are not expanded.

Use `\eval` to run arbitrary Elisp expressions (loops, conditionals, etc.):

```
SQL> \eval (+ 1 2 3)
6
SQL> \eval (dotimes (i 3) (isqlm--quick-sql (format "SELECT %d;" (1+ i))))
SQL> \eval (if (isqlm--connected-p) "connected" "disconnected")
connected
```

### Conditional Flow

Inspired by PostgreSQL's `psql`, supports `\if`/`\elif`/`\else`/`\endif` with nesting:

```
SQL> \setq is_customer true
SQL> \if :is_customer
SQL>     SELECT * FROM customer WHERE customer_id = 123;
SQL> \elif :is_employee
SQL>     \echo 'is an employee'
SQL>     SELECT * FROM employee WHERE employee_id = 456;
SQL> \else
SQL>     \echo 'unknown role'
SQL> \endif
```

Conditions can be:
- `:varname` — true if the Emacs variable is bound and non-nil
- `(elisp-expr)` — true if the expression evaluates to non-nil
- Literal — true unless `"0"`, `"false"`, `"no"`, `"nil"`, or empty

### For Loops

Loop over a list of values:

```
SQL> \for db in test mtr { \u :db; show tables; }
```

Multi-line form:

```
SQL> \for i in 1 2 3
{
select * from t1 where a = :i;
}
```

Body supports SQL statements (with `:varname` expansion) and `\` commands.

### Storing Query Results (`\gset`)

Like psql's `\gset`, store a single-row query result into Emacs variables.

**As a SQL terminator** (no result displayed):

```
SQL> SELECT 'hello' AS var1, 10 AS var2\gset
SQL> \echo :var1 :var2
hello 10

SQL> SELECT COUNT(*) AS cnt FROM users;\gset user_
SQL> \echo :user_cnt
42
```

**As a standalone command** (after executing a query):

```
SQL> SELECT * FROM t1 LIMIT 1;
+---+---+
| a | b |
+---+---+
| 1 | 1 |
+---+---+
1 row in set
SQL> \gset p
SQL> \echo :pa :pb
1 1
```

Each column becomes a variable named `PREFIX` + column name. The query must return exactly 1 row.

### Script Editing (`\i -`)

Use `\i -` to open an interactive script editor:

```
SQL> \i -
```

A `*isqlm-script*` buffer opens with `sql-mode` syntax highlighting. Write your script, then:
- `C-c C-c` — execute the script and return to ISQLM
- `C-c C-k` — abort without executing

## Key Bindings

| Key | Action |
|-----|--------|
| `RET` | Submit input; or re-execute line under cursor (in history area) |
| `M-RET` | Insert literal newline (multi-line SQL) |
| `C-c C-c` | Abort current input (interrupt) |
| `C-c C-n` | Connect |
| `C-c C-q` | Disconnect |
| `C-c C-r` | Reconnect |
| `C-c C-l` | Clear buffer |
| `C-c C-u` | `SHOW DATABASES` |
| `C-c C-t` | `SHOW TABLES` |
| `C-c C-d` | `DESCRIBE TABLE` |
| `M-p` / `M-n` | Navigate history |
| `C-a` | Move to beginning of input (skip prompt) |

## Entry Points

| Command | Description |
|---------|-------------|
| `M-x isqlm` | Open `*isqlm*` buffer |
| `M-x isqlm-sql-connect` | Select from `sql-connection-alist` with completion, open `*isqlm:NAME*` |
| `M-x isqlm-connect-and-run` | Open buffer and connect with Lisp arguments |

## Customization

All options are in the `isqlm` customize group (`M-x customize-group RET isqlm`):

| Variable | Default | Description |
|----------|---------|-------------|
| `isqlm-prompt` | `"SQL> "` | Main prompt string |
| `isqlm-prompt-continue` | `"  -> "` | Continuation prompt |
| `isqlm-table-style` | `ascii` | Table borders: `ascii` or `unicode` |
| `isqlm-max-column-width` | `0` | Max column width (0 = auto/window width) |
| `isqlm-max-rows` | `1000` | Max rows displayed (0 = unlimited) |
| `isqlm-null-string` | `"NULL"` | Display string for NULL values |
| `isqlm-history-size` | `512` | History ring capacity |
| `isqlm-history-file-name` | `~/.emacs.d/isqlm-history` | History file path |
| `isqlm-default-host` | `"127.0.0.1"` | Default host |
| `isqlm-default-port` | `3306` | Default port |
| `isqlm-default-user` | `"root"` | Default user |
| `isqlm-noisy` | `t` | Beep on errors |

## Extending with Custom Commands

Define a function named `isqlm/NAME` and it becomes available as `\NAME`:

```elisp
(defun isqlm/tables (&rest _args)
  "Show tables in current database."
  (isqlm--quick-sql "SHOW TABLES;"))

;; Now \tables works at the prompt
```

Add aliases via `isqlm-command-aliases`:

```elisp
(push '("t" . "tables") isqlm-command-aliases)
;; Now \t works as \tables
```

## Sending SQL from External Buffers

Similar to `sql-send-string` in `sql.el`, you can send SQL from any buffer to an ISQLM session:

| Command | Description |
|---------|-------------|
| `isqlm-send-string` | Send a SQL string (prompts in minibuffer) |
| `isqlm-send-region` | Send the active region |
| `isqlm-send-paragraph` | Send the current paragraph |
| `isqlm-send-buffer` | Send the entire buffer |

The target ISQLM buffer is determined by the global variable `isqlm-buffer`, which is automatically set when you open an ISQLM session. For multiple sessions, set it explicitly:

```elisp
(setq isqlm-buffer "*isqlm:mydb*")

;; Or set buffer-locally in a SQL source file:
;; -*- isqlm-buffer: "*isqlm:mydb*" -*-
```

## Architecture

See [DESIGN.md](DESIGN.md) for detailed design and implementation documentation.

## License

GPL-3.0-or-later
