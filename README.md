# ISQLM — Interactive SQL Mode for MySQL

An Emacs major mode providing an interactive MySQL console, modeled after
Eshell's architecture — **no external processes, no comint**. The mode manages
its own buffer, markers, prompt, and I/O directly, communicating with MySQL
through the [`mysql-el`](https://github.com/hadleywang/mysql-el) dynamic module (C FFI to libmysqlclient).

## Features

- **Zero external processes** — no shell, no `mysql` CLI, no comint; pure Elisp + C module
- **Built-in commands** prefixed with `\` (e.g. `\connect`, `\help`, `\style`)
- **`sql-connection-alist` integration** — reuse Emacs's standard connection definitions
- **Tabular result display** with ASCII or Unicode box-drawing borders
- **Vertical display** — end SQL with `\G` for row-per-field output
- **Multi-line SQL input** — press `M-RET` for literal newlines; `RET` submits
- **Multi-line cell values** — newlines inside column values render correctly
- **Input interrupt** — `C-c C-c` aborts current (multi-line) input
- **Ring-based input history** with file persistence (`M-p` / `M-n`)
- **SQL keyword font-locking**
- **Auto-adaptive column widths** based on window size
- **Command aliases** — extensible shorthand mappings (`\?` = `\help`, etc.)

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
| `\clear` | Clear buffer |
| `\history` | Show input history |
| `\help` | Show help |
| `\quit` / `\exit` | Disconnect and kill buffer |

**Aliases:** `\?` = `\h` = `\help`, `\q` = `\quit`

## Key Bindings

| Key | Action |
|-----|--------|
| `RET` | Submit input |
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

## Architecture

See [DESIGN.md](DESIGN.md) for detailed design and implementation documentation.

## License

GPL-3.0-or-later
