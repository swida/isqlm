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
| `isqlm-delimiter` | string | Current statement delimiter (default `";"`) |

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

When the cursor is in the history area (before `isqlm-last-output-end`), pressing `RET` extracts the text of the current line, strips any prompt prefix (`SQL> ` or `  -> `), copies it to the current input area, and executes it. Past input lines are **not** read-only (only the trailing newline is), so the user can edit them in place before pressing `RET` — this mirrors Eshell behavior. Output and prompt regions remain read-only.

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
| `\linestyle` | `isqlm/linestyle` | Set/cycle line-drawing style (ascii/unicode/none) |
| `\timing` | `isqlm/timing` | Toggle/set query execution timing display |
| `\delimiter` / `DELIMITER` | `isqlm/delimiter` | Set statement delimiter for stored programs |
| `\l[x+]` / `\list[x+]` | `isqlm/l` etc. | List databases (x=expanded, +=detail with sizes) |
| `\d` | `isqlm/d` | List tables/views or describe a table |
| `\d+` | `isqlm/d+` | Same with extra detail (engine, size, CREATE TABLE, partition info) |
| `\dt` / `\dv` / `\di` | `isqlm/dt` etc. | List tables / views / indexes |
| `\df[np][S][+]` | `isqlm/df` etc. | List functions / procedures |
| `\ef [NAME[(types)]]` | `isqlm/ef` | Edit function/procedure definition |
| `\eval` | `isqlm/eval` | Evaluate arbitrary Elisp expression |
| `\echo` | `isqlm/echo` | Output text with variable expansion |
| `\for` | `isqlm--for-start` | Loop over values with `{ body }` |
| `\if` | `isqlm/if` | Begin conditional block |
| `\elif` | `isqlm/elif` | Else-if branch |
| `\else` | `isqlm/else` | Else branch |
| `\endif` | `isqlm/endif` | End conditional block |
| `\gset` | `isqlm/gset` | Store last query result as variables |
| `\genddl` | `isqlm/genddl` | Generate DDL+DML for tables referenced in SQL |
| `\placement` | `isqlm/placement` | View/change table/partition node placement (TDSQL 3) |
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

## 4.3 Listing Databases (`\l` / `\list`)

Inspired by PostgreSQL's `\l` meta-command. Lists databases in the server from `INFORMATION_SCHEMA.SCHEMATA`.

**Syntax**: `\l[x][+] [PATTERN]` or `\list[x][+] [PATTERN]`

**Modifier letters** (parsed by `isqlm--l-parse-modifiers`):

| Letter | Meaning |
|--------|---------|
| `x` | Expanded display (vertical mode, one field per line) |
| `+` | Verbose mode — show additional columns (size, tablespace) |

**Output columns**:

| Mode | Columns |
|------|---------|
| Normal | Name, Encoding, Collation, Access privileges |
| Verbose (`+`) | Name, Encoding, Collation, Size, Tablespace, Access privileges |

**Pattern filtering**: If PATTERN is specified, only databases whose names match are listed. Wildcards: `*` → `%`, `?` → `_` (SQL LIKE pattern).

**Expanded mode** (`x`): Results are displayed in vertical format (one field per line, like `\G`), useful for wide output.

**MySQL adaptation notes**:
- PostgreSQL's "Owner" maps loosely to MySQL's grant system — we show `GRANTEE` from `INFORMATION_SCHEMA.SCHEMA_PRIVILEGES` as access privileges
- "Encoding" shows `DEFAULT_CHARACTER_SET_NAME`
- "Collation" shows `DEFAULT_COLLATION_NAME`
- "Size" (verbose mode) is computed as `SUM(DATA_LENGTH + INDEX_LENGTH)` from `INFORMATION_SCHEMA.TABLES` for all tables in that schema
- "Tablespace" is shown as empty (MySQL does not have per-database default tablespaces like PostgreSQL)

**Implementation**:

| Function | Description |
|----------|-------------|
| `isqlm--l-parse-modifiers` | Parse modifier letters from command name (e.g. `"lx+"` → `(:expanded t :verbose t)`) |
| `isqlm--l-dispatch` | Build and execute the `INFORMATION_SCHEMA.SCHEMATA` query with appropriate columns and WHERE clause |
| `isqlm/l`, `isqlm/lx`, `isqlm/l+`, `isqlm/lx+` | Entry points for `\l` variants |
| `isqlm/list`, `isqlm/listx`, `isqlm/list+`, `isqlm/listx+` | Entry points for `\list` variants |

**Examples**:

```
SQL> \l
┌────────────────────┬──────────┬────────────────────┬───────────────────┐
│ Name               │ Encoding │ Collation          │ Access privileges │
├────────────────────┼──────────┼────────────────────┼───────────────────┤
│ information_schema │ utf8mb3  │ utf8mb3_general_ci │                   │
│ mydb               │ utf8mb4  │ utf8mb4_0900_ai_ci │                   │
│ test               │ utf8mb4  │ utf8mb4_0900_ai_ci │                   │
└────────────────────┴──────────┴────────────────────┴───────────────────┘

SQL> \l+ my*
┌──────┬──────────┬────────────────────┬─────────┬────────────┬───────────────────┐
│ Name │ Encoding │ Collation          │ Size    │ Tablespace │ Access privileges │
├──────┼──────────┼────────────────────┼─────────┼────────────┼───────────────────┤
│ mydb │ utf8mb4  │ utf8mb4_0900_ai_ci │ 1.25 MB │            │                   │
└──────┴──────────┴────────────────────┴─────────┴────────────┴───────────────────┘

SQL> \lx test
*************************** 1. row ***************************
              Name: test
          Encoding: utf8mb4
         Collation: utf8mb4_0900_ai_ci
 Access privileges:
```

## 4.4 Listing Functions/Procedures (`\df`)

Inspired by PostgreSQL's `\df` meta-command. Lists stored functions and procedures from `INFORMATION_SCHEMA.ROUTINES`.

**Syntax**: `\df[np][S][+] [PATTERN [ARG_PATTERN ...]]`

**Modifier letters** (parsed by `isqlm--df-parse-modifiers`):

| Letter | Meaning |
|--------|---------|
| `n` | Show only normal functions (`ROUTINE_TYPE = 'FUNCTION'`) |
| `p` | Show only procedures (`ROUTINE_TYPE = 'PROCEDURE'`) |
| `S` | Include system routines (all schemas, not just `DATABASE()`) |
| `+` | Verbose mode — show additional columns |

Without `n` or `p`, both functions and procedures are shown.

**Output columns**:

| Mode | Columns |
|------|---------|
| Normal | Name, Result, Arguments, Type |
| Verbose (`+`) | Name, Result, Arguments, Type, Volatility, Owner, Security, Description |
| With `S` | Prepends `Schema` column |

**Type mapping** (MySQL → psql-style):

| MySQL `ROUTINE_TYPE` | Displayed as |
|----------------------|-------------|
| `FUNCTION` | `normal` |
| `PROCEDURE` | `procedure` |

MySQL does not have aggregate, trigger, or window function types in `INFORMATION_SCHEMA.ROUTINES`, so only `normal` and `procedure` are shown.

**Argument type filtering**: Additional arguments after PATTERN are matched against parameter types via `INFORMATION_SCHEMA.PARAMETERS`:

- `\df * int` — routines whose 1st parameter type matches `int`
- `\df * int varchar` — 1st param is `int`, 2nd is `varchar`
- `\df * int -` — exactly one parameter, of type `int` (the `-` sentinel constrains the total parameter count)

**Implementation**:

| Function | Description |
|----------|-------------|
| `isqlm--df-parse-modifiers` | Parse modifier letters from the command name (e.g. `"dfnS+"` → `(:types (function) :verbose t :system t)`) |
| `isqlm--df-dispatch` | Build and execute the `INFORMATION_SCHEMA.ROUTINES` query with appropriate WHERE clauses |
| `isqlm/df`, `isqlm/dfn`, `isqlm/dfp`, etc. | Entry points for the command dispatcher — each calls `isqlm--df-dispatch` with the raw command name |

**Verbose columns** (from `INFORMATION_SCHEMA.ROUTINES`):

| Column | Source |
|--------|--------|
| Volatility | `SQL_DATA_ACCESS` (e.g. `CONTAINS SQL`, `NO SQL`, `READS SQL DATA`) |
| Owner | `DEFINER` |
| Security | `SECURITY_TYPE` (`DEFINER` or `INVOKER`) |
| Description | `ROUTINE_COMMENT` |

## 4.4 Editing Functions/Procedures (`\ef`)

Inspired by PostgreSQL's `\ef`. Fetches a stored function/procedure definition and opens it in an editing buffer.

**Syntax**: `\ef [NAME[(type1, type2, ...)]]`

**Workflow**:

1. **No argument**: Opens a blank `CREATE FUNCTION` template
2. **With name**: Queries `INFORMATION_SCHEMA.ROUTINES` to determine type (FUNCTION/PROCEDURE), then `SHOW CREATE FUNCTION/PROCEDURE` to fetch the definition
3. **With argument types**: Uses `INFORMATION_SCHEMA.PARAMETERS` to disambiguate overloaded names
4. Opens `*isqlm-ef*` buffer with `sql-mode` + `isqlm-ef-mode` (C-c C-c / C-c C-k)
5. Strips `DEFINER=...` clause for cleaner editing
6. On C-c C-c: executes the definition immediately (auto-appends `;` if missing)
7. On C-c C-k → discards changes

**No DELIMITER needed**: The definition is sent as a single statement directly to `mysql-query`, bypassing the statement splitter entirely.

**Key difference from `\i -`**: The `\ef` editing buffer executes its content as a single SQL statement (not as a multi-line script). This means `;` inside `BEGIN...END` blocks does not cause splitting issues.

**Implementation**:

| Function | Description |
|----------|-------------|
| `isqlm/ef` | Entry point: parse name/types, dispatch to fetch or template |
| `isqlm--ef-fetch-and-edit` | Query INFORMATION_SCHEMA + SHOW CREATE, open editor |
| `isqlm--ef-prepare-sql` | Strip DEFINER clause from CREATE statement |
| `isqlm--ef-open-editor` | Create `*isqlm-ef*` buffer with `sql-mode` + `isqlm-ef-mode` |
| `isqlm-ef-finish` | C-c C-c: execute or place in input area |
| `isqlm-ef-abort` | C-c C-k: discard |

**Command dispatch note**: `\ef` receives the raw rest of the line (not tokenized), same as `\eval`. This allows function names with parentheses like `foo(integer, text)` to be passed intact.

## 4.6 Generate DDL/DML from SQL (`\genddl`)

Generates `CREATE TABLE` and `INSERT INTO` statements for all tables referenced in a SQL query. Useful for creating minimal reproducible test cases.

**Requires a live database connection.**

**Syntax**: `\genddl SQL-STATEMENT`

Without an argument, uses the last executed SQL (`isqlm-last-query`).

**Example**:

```
SQL> \genddl select sum(b) over (partition by(a)) from t3 t
CREATE TABLE `t3` (
  `a` int DEFAULT NULL,
  `b` int DEFAULT NULL,
  `c` int DEFAULT NULL,
  KEY `a` (`a`,`b`)
) ENGINE=ROCKSDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

INSERT INTO `t3` (`a`, `b`, `c`) VALUES
(1, 2, 3),
(4, 5, 6);
```

**How it works**:

1. **Table extraction via SQL parsing** (`isqlm--genddl-extract-tables-from-sql`): Parses the SQL text directly, extracting table names that follow `FROM`, `JOIN`, `UPDATE`, `INTO`, `STRAIGHT_JOIN` keywords. Handles backtick-quoted names, `schema.table` notation, implicit/explicit aliases (which are skipped), comma-separated table lists, and subqueries (balanced parenthesis skipping). This avoids the EXPLAIN approach where MySQL reports aliases instead of physical table names.

2. **Real DDL fetch** (`isqlm--genddl-fetch-create-table`): Issues `SHOW CREATE TABLE` for each table. Uses the real DDL verbatim.

3. **Column parsing** (`isqlm--genddl-parse-columns-from-ddl`): Extracts column name/type pairs from the real DDL for DML generation.

4. **Real data fetch** (`isqlm--genddl-fetch-data`): Issues `SELECT ... LIMIT 2` to get actual rows. Values are formatted type-aware via `isqlm--genddl-format-value` — numeric types (`int`, `decimal`, etc.) are unquoted, strings are single-quoted with proper escaping, NULLs output as `NULL`. If the table is empty, no INSERT statement is generated.

**Implementation**:

| Function | Description |
|----------|-------------|
| `isqlm/genddl` | Entry point: require connection, parse SQL, fetch DDL+data, output |
| `isqlm--genddl-extract-tables-from-sql` | Extract table names by parsing SQL text |
| `isqlm--genddl-fetch-create-table` | Fetch real DDL via `SHOW CREATE TABLE` |
| `isqlm--genddl-parse-columns-from-ddl` | Parse column name/type from DDL string |
| `isqlm--genddl-fetch-data` | Fetch real rows via `SELECT ... LIMIT` for DML |
| `isqlm--genddl-format-value` | Format a value for INSERT — type-aware quoting |

## 4.7 View/Change Node Placement (`\placement`) — TDSQL 3

View which node a table or partition is stored on, or split its region so that future inserts go to a new node.  Uses TDSQL 3 SQL interface (`ALTER INSTANCE SPLIT` / `MIGRATE` / `TRANSFER LEADER`) — no MC REST API calls needed.

**Syntax**:

| Form | Description |
|------|-------------|
| `\placement` | Show usage + list available cluster nodes |
| `\placement TARGET` | Show current node for TARGET |
| `\placement TARGET NODE` | Split region + place new RG's leader on NODE so future writes go there |

**TARGET format**: `[db.]table[.partition]`

| Input | Interpretation |
|-------|---------------|
| `t1` | Current database, table `t1` |
| `test.t1` | Database `test`, table `t1` |
| `test.t1.p0` | Database `test`, table `t1`, partition `p0` |
| `t1.p0` | Current database, table `t1`, partition `p0` (detected by `p` + digit prefix) |

**NODE**: Exact node name, 0-based index, or suffix match.

### Workflow (when NODE is given)

The table must have a PRIMARY KEY.

**Step 0 — Split range block** at the split key:

```sql
-- Check if range block boundary exists at split key
SELECT range_block_id FROM information_schema.TDSTORE_RANGE_BLOCK_INFO
  WHERE start_key = '<split_key>';

-- If not, split the range block (required before region split)
CALL dbms_admin.launch_range_block_job(1, 0, '<prefix>', '<split_key>');

-- Poll information_schema.TDSTORE_RANGE_BLOCK_INFO until boundary appears
```

Region split in TDStore requires the split key to align with a **range block boundary**.  Range blocks are the internal fine-grained units within a region; each manages a contiguous key range with its own transaction lock unit.  If no range block boundary exists at the split key, the region split will be rejected with `EC_TDS_INVALID_ARGUMENT`.

**Step 1 — Split region** at `MAX(pk)`:

```sql
-- Get storage prefix (hex)
SELECT LPAD(HEX(tindex_id),8,'0') FROM information_schema.tables
  WHERE table_schema='<db>' AND table_name='<table>';
-- For partitioned tables:
SELECT TINDEX_ID_STORAGE_FORMAT FROM information_schema.PARTITION_INDEXES
  WHERE ... AND index_name='PRIMARY';

-- Get encoded key for MAX(pk)
SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(MYROCK_ENCODE(),';',1),':',-1)
  FROM <db>.<table> FORCE INDEX(PRIMARY) WHERE <pk> = MAX(<pk>);

-- split_key = prefix + encoded_key
-- Split the region
ALTER INSTANCE SPLIT REGION <region_id> IN RG <rg_id> AT KEY '<split_key>' FORCE;

-- Poll META_CLUSTER_REGIONS until new region appears
```

**Step 2 — Split RG** to move the new region into a separate RG:

```sql
ALTER INSTANCE SPLIT RG <rg_id> BY 'manual-assigned'
  SET 'right_regions' = '<new_region_id>';
```

**Step 3 — Place the new RG's leader on the target node.**

`SPLIT RG` returns OK only means the job was *submitted*; the new RG's replicas
and snapshot are populated asynchronously.  Moreover, `MIGRATE` only moves a
*replica* — it does **not** move the raft leader.  To make future writes land on
the target node, the new RG's **leader** must be on it.  The implementation
therefore:

1. **Wait for the new RG to become working** (leader elected, split synced) by
   polling `rep_group_state` for `L_Working`.
2. **Ensure the target node has a replica.**  In a cluster where the number of
   nodes equals the replica count (e.g. 3 nodes / 3 replicas), every RG already
   has a replica on every node, so this is a no-op.  Otherwise, migrate one
   there (retrying while the parent-RG snapshot condition is not yet met):

   ```sql
   ALTER INSTANCE MIGRATE RG <new_rg_id> TO '<target_node>';
   ```

3. **Transfer leadership to the target node**, retrying until the follower is
   working (the new follower may briefly be in `RG_STATE_F_ONLINE`) and the
   leader is confirmed on the target:

   ```sql
   ALTER INSTANCE TRANSFER LEADER RG <new_rg_id> TO '<target_node>';
   ```

   After each attempt, `leader_node_name` from `META_CLUSTER_RGS` is checked to
   confirm the leader has actually moved.

**Step 4 — Flush route**:

```sql
CALL dbms_admin.flush_route();
```

After this, all subsequent inserts with `pk > MAX(pk)` at split time go to the new node.

### Information Schema Tables Used

| Table | Purpose |
|-------|---------|
| `information_schema.meta_cluster_nodes` | List all cluster node names |
| `information_schema.META_CLUSTER_TABLE_LOCATION` | Table → RG → leader node mapping |
| `information_schema.META_CLUSTER_REGIONS` | Region → RG mapping, start/end keys |
| `information_schema.META_CLUSTER_RGS` | RG members, leader, quorum |
| `information_schema.TDSTORE_RANGE_BLOCK_INFO` | Range block boundaries within regions |
| `information_schema.tables` | `tindex_id` for non-partitioned tables |
| `information_schema.PARTITION_INDEXES` | `TINDEX_ID_STORAGE_FORMAT` for partitioned tables |
| `INFORMATION_SCHEMA.STATISTICS` | Primary key column names |

### SQL Commands Used

| Step | SQL | Description |
|------|-----|-------------|
| 0 | `CALL dbms_admin.launch_range_block_job(1, 0, start, split)` | Split range block at split key |
| 1 | `ALTER INSTANCE SPLIT REGION ... IN RG ... AT KEY ... FORCE` | Split region at split key |
| 2 | `ALTER INSTANCE SPLIT RG ... BY 'manual-assigned' SET 'right_regions' = ...` | Move new region to new RG |
| 3a | `ALTER INSTANCE MIGRATE RG ... TO ...` | Add a replica on the target node (only when it has none) |
| 3b | `ALTER INSTANCE TRANSFER LEADER RG ... TO ...` | Move the new RG's leader to the target node (retried) |
| 4 | `CALL dbms_admin.flush_route()` | Refresh routing table |

### Implementation

| Function | Description |
|----------|-------------|
| `isqlm/placement` | Meta command entry point |
| `isqlm--placement-parse-target` | Parse `[db.]table[.partition]` string |
| `isqlm--placement-show-info` | Query `META_CLUSTER_TABLE_LOCATION` and display |
| `isqlm--placement-get-nodes` | Query `meta_cluster_nodes` |
| `isqlm--placement-resolve-node` | Resolve node hint (exact/index/suffix) |
| `isqlm--placement-get-region-info` | Get region_id, rg_id from `META_CLUSTER_REGIONS` |
| `isqlm--placement-get-pk-col` | Get PRIMARY KEY column from `STATISTICS` |
| `isqlm--placement-get-storage-prefix` | Get hex prefix from `tindex_id` or `PARTITION_INDEXES` |
| `isqlm--placement-get-encode-key` | Encode key via `MYROCK_ENCODE()` |
| `isqlm--placement-split-range-block` | Step 0: split range block + poll |
| `isqlm--placement-split-region-sql` | Step 1: `ALTER INSTANCE SPLIT REGION` |
| `isqlm--placement-rg-has-node` | Check whether an RG already has a replica on a node |
| `isqlm--placement-wait-rg-working` | Poll `rep_group_state` until `L_Working` |
| `isqlm--placement-rg-leader-is` | Check whether an RG's leader is a given node |
| `isqlm--placement-place-rg-leader` | Step 3: wait-for-working → optional `MIGRATE` → retry `TRANSFER LEADER` until leader confirmed on target |

### Examples

```
SQL> \placement
Usage:
  \placement [db.]table[.partition]         show current node
  \placement [db.]table[.partition] NODE    split + migrate

Available nodes:
  [0] node-1-002
  [1] node-1-003
  [2] node-1-001

SQL> \placement test.t2
test.t2:
  RG 95067 → node-1-002

SQL> \placement test.t2 node-1-001
[placement] test.t2: split at MAX(a)=51190, target → node-1-001
[placement] Step 0: Split range block
[placement] Splitting range block at '000027468000C7F6'...
[placement] CALL dbms_admin.launch_range_block_job(1, 0, '00002746', '000027468000C7F6')
[placement] Range block split done
[placement] Step 1: Split region 373 in RG 95067 at key '000027468000C7F6'
[placement] ALTER INSTANCE SPLIT REGION 373 IN RG 95067 AT KEY '000027468000C7F6' FORCE
[placement] Waiting for region split (C-c C-c to cancel)...
[placement] Region split done (1082)
[placement] Step 2: Split RG 95067 (move region 1082 to new RG)
[placement] ALTER INSTANCE SPLIT RG 95067 BY 'manual-assigned' SET 'right_regions' = '1082'
[placement] Step 3: Place leader of RG 278619 on node-1-001
[placement] ALTER INSTANCE TRANSFER LEADER RG 278619 TO 'node-1-001'
[placement] Leader now on node-1-001
[placement] Route flushed. Done.

SQL> \placement test.t2
test.t2:
  RG 95067 → node-1-002
  RG 278619 → node-1-001
```

## 5. SQL Execution Layer

All SQL execution uses `mysql-query` with `ASYNC=t` (non-blocking).  **No sync `mysql-query` calls remain** — Emacs is never blocked by network I/O.  There are two execution styles:

1. **Timer-based async** (interactive prompt, scripts, for-loops, quick-sql, send-region) — `mysql-query conn sql t` → `mysql-query-poll` via `run-with-timer`, with callback chaining for multi-statement and script execution
2. **Poll-loop async** (`isqlm-execute-string`, `isqlm-execute`) — `mysql-query conn sql t` → `mysql-query-poll` via `sit-for` loop, returning the result plist synchronously to the caller while keeping Emacs responsive

Both paths share `isqlm--format-result-string` for result formatting (table display, vertical display, `\gset`, row counts, warnings), eliminating duplicate formatting logic.

**Public API**: `isqlm-execute-string` executes SQL and returns the raw result plist, abstracting the underlying database module. External code should use this instead of calling `mysql-query` directly, so that future database backends can be swapped transparently.

| Function | Role |
|----------|------|
| `isqlm-execute-string` | **Public API**: execute SQL, return result plist; uses async+poll internally |
| `isqlm--query-with-poll` | async `mysql-query` + `sit-for` poll loop; non-blocking |
| `isqlm--execute-sql` | Internal: terminator parsing + USE side-effects + `isqlm--format-result-string` |
| `isqlm--format-result-string` | **Shared**: format result plist into a string (SELECT/DML/\gset) |
| `isqlm--format-and-output-result` | Thin wrapper: calls `isqlm--format-result-string` and outputs to buffer |
| `isqlm--async-execute-one` | Timer-based async: `mysql-query conn sql t` → immediate or poll timer |
| `isqlm--async-handle-result` | Handle completed result: USE side-effects or format+output |
| `isqlm--poll-query` | Timer callback: `mysql-query-poll` → `isqlm--async-handle-result` |
| `isqlm--async-run-statements` | Chain multiple statements via callbacks (used by scripts/for-loops) |
| `isqlm--script-process-lines` | Async script executor: line-by-line with callback chaining |

### Auto-Reconnect

When `isqlm-auto-reconnect` is non-nil (default), `isqlm-execute-string` wraps execution in a retry loop:

1. Execute the SQL via `mysql-query`
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
3. **Shared result formatting**: `isqlm--format-result-string` handles the result plist for both sync and async paths — sync via `isqlm--execute-sql`, async via `isqlm--format-and-output-result` (a thin wrapper)
4. **Timer-based polling**: `run-with-timer` at 20ms intervals calls `mysql-query-poll`, which is a non-blocking C call that returns immediately
5. **Input blocking**: While async query runs, `isqlm--async-busy` is set; `RET` shows "Query in progress... (C-c C-c to cancel)"
6. **C-c C-c cancellation**: `isqlm-interrupt` calls `isqlm--async-cancel` which cancels the polling timer
7. **USE statements**: Handled synchronously in both paths (fast, no result set)
8. **Multi-statement**: Statements are chained via callbacks — each statement's completion triggers the next
9. **Fully non-blocking**: All paths use `mysql-query` with `ASYNC=t` — scripts, for-loops, quick-sql, send-region all use callback-chained async execution; `isqlm-execute-string` uses `sit-for`-based polling

**Core functions:**

| Function | Description |
|----------|-------------|
| `isqlm-execute-string` | **Public API**: execute SQL, return result plist; connection check + auto-reconnect |
| `isqlm--execute-sql` | Internal: terminator parsing, USE side-effects, result formatting via `isqlm-execute-string` |
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

### Custom Delimiter (`DELIMITER` / `\delimiter`)

MySQL CLI requires `DELIMITER` to change the statement terminator when creating stored programs (procedures, functions, triggers) that contain `;` inside `BEGIN...END` blocks.

**Two ways to set**:
- `DELIMITER //` — MySQL CLI compatible (no `\` prefix), recognized in both interactive prompt and scripts
- `\delimiter //` — isqlm command style

**Without argument**: resets to `;`.

**How it works**:

1. `isqlm-delimiter` (buffer-local, default `";"`) stores the current delimiter
2. When delimiter ≠ `;`:
   - `isqlm--sql-complete-p` checks for the custom delimiter instead of `;`/`\G`/`\gset`
   - `isqlm--split-statements` delegates to `isqlm--split-statements-custom` (simple substring scan)
   - `isqlm--strip-terminator` strips the custom delimiter
3. When delimiter = `;`: all standard behavior is preserved (`\G`, `\gset`, etc.)
4. In scripts (`\i FILE`), `isqlm--script-process-lines` recognizes `DELIMITER` directives via `isqlm--delimiter-directive-p`
5. At the interactive prompt, `isqlm-send-input` recognizes `DELIMITER` before command dispatch

**Example** (interactive):

```
SQL> \delimiter //
Delimiter set to: //
SQL> CREATE PROCEDURE p1()
  -> BEGIN
  -> SELECT * FROM t1;
  -> END //
Query OK, 0 rows affected
SQL> \delimiter
Delimiter reset to: ;
```

**Example** (script via `\i -`):

```sql
DELIMITER //
CREATE PROCEDURE p1()
BEGIN
    SELECT * FROM t1;
END //
DELIMITER ;
CALL p1();
```

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

### Line Styles

Controlled by `isqlm-table-style` (set via `\linestyle` command, unique abbreviations allowed):

| Style | Characters | Example |
|-------|-----------|---------|
| `ascii` | `+ - \|` | `+----+------+` |
| `unicode` (default) | `┌┬┐├┼┤└┴┘│─` | `┌────┬──────┐` |
| `none` | (no borders) | ` id  name ` |

Character sets are defined in `isqlm--table-chars-ascii`, `isqlm--table-chars-unicode`, and `isqlm--table-chars-none`.

### Multi-line Cell Values

When a cell value contains `\n`, the table renderer splits it into multiple display lines. Column width is computed from the longest sub-line. Shorter sub-lines are padded with spaces. This correctly handles outputs like `EXPLAIN FORMAT=TREE`.

### Visual Line Wrapping

The ISQLM buffer sets `truncate-lines` to `nil`, so Emacs visually wraps long lines at the window edge. Table content is logically a single line (no inserted newlines), but the display folds at the window boundary. This avoids horizontal scrolling for wide results (e.g. `SELECT @@optimizer_switch`).

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
- Search: `M-r` starts incremental regexp search through history (Eshell-style), using Emacs's isearch framework with custom functions that traverse the history ring and display matches on the command line; `DEL` backtracks, `RET`/`C-g` exits
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
| `M-r` | `isqlm-history-search` | Incremental regexp search through history (isearch-based) |
| `C-a` | `isqlm-bol` | Jump to input start |

## 10. Customization Options (defcustom)

All options belong to the `isqlm` customize group:

| Option | Default | Description |
|--------|---------|-------------|
| `isqlm-prompt` | `"SQL> "` | Main prompt |
| `isqlm-prompt-continue` | `"  -> "` | Continuation prompt |
| `isqlm-prompt-read-only` | `t` | Whether prompt is read-only |
| `isqlm-noisy` | `t` | Beep on errors |
| `isqlm-table-style` | `unicode` | Line style (`ascii` / `unicode` / `none`) |
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
- `M-x isqlm-connect` — Connect: if `sql-connection-alist` is non-empty, prompt for name with completion; otherwise ensure ISQLM buffer and connect with defaults.  From Lisp: `(isqlm-connect HOST USER DB PORT)`
- `M-x isqlm-sql-connect` — Select from `sql-connection-alist` with completion, open `*isqlm:NAME*`
- `M-x isqlm-connect-and-run` — Start and immediately connect
- `\connect NAME` at the prompt — Connect using a `sql-connection-alist` entry
- `\connect [HOST] [USER] [DB] [PORT]` at the prompt — Connect with positional parameters (all optional, defaults applied); password prompted via echo area

## 12.1 Programmatic API

| Function | Description |
|----------|-------------|
| `isqlm-execute-string` | Execute SQL, return result plist; abstracts `mysql-el` for future multi-backend support |
| `isqlm-execute` | Execute SQL, display result in a separate `special-mode` buffer (`q` to dismiss) |

`isqlm-execute-string` is the low-level building block — it returns structured data.  `isqlm-execute` builds on it to provide a quick "run & view" workflow suitable for interactive commands (e.g. show processlist, explain plans, optimizer traces).

## 12.2 Sending SQL from External Buffers

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
4. **All SQL goes through `isqlm-execute-string`** — the public API for programmatic SQL execution; both sync (`isqlm--execute-sql`) and async (`isqlm--async-execute-one`) ultimately call `mysql-query` via this function or directly; result formatting is shared via `isqlm--format-result-string`
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
| DDL/DML Generation | `isqlm-test-genddl-parse-columns-from-ddl`, `isqlm-test-genddl-format-value` | DDL column parsing from `SHOW CREATE TABLE` output, type-aware value formatting (numeric unquoted, strings quoted, NULL handling) |

### Design Principles

1. **No MySQL dependency**: All tests run without a MySQL server or the `mysql-el` module. Buffer-level logic and pure functions are tested in isolation.
2. **Regression-driven**: Key tests were added in response to specific bugs (e.g., `\if` ignored in scripts, `:varname` treated as Elisp keyword in `\if` expressions).
3. **Output capture**: Script execution tests use `cl-letf` to temporarily replace `isqlm--output`/`isqlm--output-info`/`isqlm--output-error` with lambda functions that capture output into a list, enabling assertions on what would have been displayed.
