;;; isqlm.el --- Interactive SQL Mode for MySQL  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Hadley Wang
;; URL: https://github.com/swida/isqlm
;; Keywords: sql, mysql, database, tools
;; Version: 2.1
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; ISQLM provides an interactive SQL console for MySQL, modeled after
;; Eshell's architecture — no external processes, no comint.  The mode
;; manages its own buffer, markers, prompt, and I/O directly.
;;
;; Features:
;;   - Eshell-style self-managed buffer (no comint, no external process)
;;   - Custom commands prefixed with `\' (e.g. \connect, \help)
;;   - Tabular and vertical (\G) result display
;;   - Ring-based input history with persistent file storage
;;   - Multi-line SQL input (terminated by `;' or `\G')
;;   - SQL keyword font-locking
;;
;; To start: M-x isqlm, then: \connect HOST USER PASSWORD DATABASE PORT
;; Or: M-x isqlm-connect
;; Type `\help' at the prompt for built-in commands.

;;; Code:

(require 'cl-lib)
(require 'ring)

;; ============================================================
;; Customization
;; ============================================================

(defgroup isqlm nil
  "Interactive SQL mode for MySQL."
  :group 'sql
  :group 'processes)

(defcustom isqlm-prompt "SQL> "
  "Prompt string for ISQLM."
  :type 'string :group 'isqlm)

(defcustom isqlm-prompt-continue "  -> "
  "Continuation prompt for multi-line SQL input."
  :type 'string :group 'isqlm)

(defcustom isqlm-prompt-read-only t
  "If non-nil, the ISQLM prompt is read-only."
  :type 'boolean :group 'isqlm)

(defcustom isqlm-noisy t
  "If non-nil, ISQLM will beep on errors."
  :type 'boolean :group 'isqlm)

(defcustom isqlm-history-file-name
  (locate-user-emacs-file "isqlm-history")
  "File to read/write ISQLM input history, or nil to disable."
  :type '(choice (const :tag "Disable" nil) file) :group 'isqlm)

(defcustom isqlm-history-size 512
  "Maximum number of entries in the ISQLM history ring."
  :type 'integer :group 'isqlm)

(defcustom isqlm-default-host "127.0.0.1"
  "Default MySQL host." :type 'string :group 'isqlm)

(defcustom isqlm-default-port 3306
  "Default MySQL port." :type 'integer :group 'isqlm)

(defcustom isqlm-default-user "root"
  "Default MySQL user." :type 'string :group 'isqlm)

(defcustom isqlm-default-database ""
  "Default MySQL database." :type 'string :group 'isqlm)

(defcustom isqlm-prompt-password nil
  "Whether to prompt for password when connecting.
When non-nil, `\\connect' always asks for a password via the echo area.
When nil, an empty password is used (useful for passwordless local connections)."
  :type 'boolean :group 'isqlm)

(defcustom isqlm-auto-reconnect t
  "Whether to automatically reconnect when the connection is lost.
When non-nil, if a SQL execution fails due to a lost connection,
isqlm will attempt to reconnect using the last connection parameters
and re-execute the failed SQL statement."
  :type 'boolean :group 'isqlm)

(defcustom isqlm-max-column-width 0
  "Maximum column width in result tables.
0 means no artificial limit — columns will be as wide as needed,
up to the current window width minus table borders."
  :type 'integer :group 'isqlm)

(defcustom isqlm-table-style 'unicode
  "Table border style for result display.
`ascii'   — classic MySQL style using +, -, |
`unicode' — box-drawing characters ┌┬┐├┼┤└┴┘│─"
  :type '(choice (const :tag "ASCII (+, -, |)" ascii)
                 (const :tag "Unicode box-drawing" unicode))
  :group 'isqlm)

(defcustom isqlm-max-rows 1000
  "Maximum rows to display.  0 = unlimited."
  :type 'integer :group 'isqlm)

(defcustom isqlm-null-string "NULL"
  "String for SQL NULL values." :type 'string :group 'isqlm)

(defcustom isqlm-mode-hook nil
  "Hook run when entering `isqlm-mode'."
  :type 'hook :group 'isqlm)

;; ============================================================
;; Faces
;; ============================================================

(defface isqlm-prompt-face
  '((default :weight bold)
    (((class color) (background light)) :foreground "DarkBlue")
    (((class color) (background dark))  :foreground "LightSkyBlue"))
  "Face for the ISQLM prompt." :group 'isqlm)

(defface isqlm-error-face
  '((default :weight bold)
    (((class color) (background light)) :foreground "Red")
    (((class color) (background dark))  :foreground "OrangeRed"))
  "Face for error messages." :group 'isqlm)

(defface isqlm-info-face
  '((default :slant italic)
    (((class color) (background light)) :foreground "DarkGreen")
    (((class color) (background dark))  :foreground "LightGreen"))
  "Face for info messages." :group 'isqlm)

(defface isqlm-table-header-face
  '((default :weight bold)
    (((class color) (background light)) :foreground "DarkCyan")
    (((class color) (background dark))  :foreground "Cyan"))
  "Face for table column headers." :group 'isqlm)

(defface isqlm-null-face
  '((default :slant italic)
    (((class color) (background light)) :foreground "Gray50")
    (((class color) (background dark))  :foreground "Gray60"))
  "Face for NULL values." :group 'isqlm)

;; ============================================================
;; Internal variables
;; ============================================================

(defvar-local isqlm-connection nil)
(defvar-local isqlm-connection-info nil)
(defvar-local isqlm-pending-input "")
(defvar-local isqlm-prompt-internal nil)
(defvar-local isqlm-last-query nil
  "The last SQL query executed, for use by \\gset.")
(defvar-local isqlm-last-result nil
  "The last SELECT query result as (COLUMNS . ROWS), for use by \\gset.")
(defvar-local isqlm-last-input-start nil)
(defvar-local isqlm-last-input-end nil)
(defvar-local isqlm-last-output-start nil)
(defvar-local isqlm-last-output-end nil)
(defvar-local isqlm-history-ring nil)
(defvar-local isqlm-history-index nil)
(defvar-local isqlm-input-saved nil)
(defvar-local isqlm-cond-stack nil
  "Stack for \\if/\\elif/\\else/\\endif conditional flow.
Each element is a plist (:satisfied BOOL :active BOOL :depth-skip INT).
:satisfied — whether any branch in this \\if chain has been true.
:active    — whether the current branch should execute.
:depth-skip — nested \\if depth to skip when inactive (0 when active).")

(defvar-local isqlm-for-stack nil
  "Stack for \\for loops.  Each element is a plist:
:var      — variable name (symbol)
:values   — list of remaining values to iterate
:body     — list of body lines collected so far (in reverse)
:brace    — whether we've seen the opening `{' yet")

(defvar-local isqlm--async-state nil
  "Non-nil when an asynchronous query is in progress.
Plist with keys:
  :phase    — \\='query or \\='store (which async step we are in)
  :sql      — the original SQL string
  :query    — the stripped query (no terminator)
  :mode     — terminator mode (nil, t for \\G, or (:gset PREFIX))
  :timer    — the polling timer
  :stmts    — remaining statements to execute (for multi-statement)
  :callback — function to call when all statements are done")

(defvar-local isqlm--async-busy nil
  "Non-nil when an async query is running.  Used to block new input.")

;; ============================================================
;; Font-lock
;; ============================================================

(defvar isqlm-font-lock-keywords
  (list
   (cons (concat "\\<"
                 (regexp-opt
                  '("SELECT" "FROM" "WHERE" "INSERT" "INTO" "VALUES"
                    "UPDATE" "SET" "DELETE" "CREATE" "DROP" "ALTER"
                    "TABLE" "DATABASE" "INDEX" "VIEW" "TRIGGER"
                    "AND" "OR" "NOT" "IN" "IS" "NULL" "LIKE"
                    "BETWEEN" "EXISTS" "HAVING" "GROUP" "BY"
                    "ORDER" "ASC" "DESC" "LIMIT" "OFFSET"
                    "JOIN" "LEFT" "RIGHT" "INNER" "OUTER" "CROSS"
                    "ON" "AS" "DISTINCT" "ALL" "UNION" "EXCEPT"
                    "INTERSECT" "CASE" "WHEN" "THEN" "ELSE" "END"
                    "IF" "BEGIN" "COMMIT" "ROLLBACK" "TRANSACTION"
                    "START" "PRIMARY" "KEY" "FOREIGN" "REFERENCES"
                    "SHOW" "DESCRIBE" "EXPLAIN" "USE"
                    "COUNT" "SUM" "AVG" "MAX" "MIN"
                    "GRANT" "REVOKE" "TRUNCATE" "RENAME" "REPLACE"
                    "TRUE" "FALSE")
                  t)
                 "\\>")
         'font-lock-keyword-face)
   '("'[^']*'" . font-lock-string-face)
   '("\\b[0-9]+\\(\\.[0-9]+\\)?\\b" . font-lock-constant-face)
   '("\\(--\\|#\\).*$" . font-lock-comment-face))
  "Font-lock keywords for ISQLM buffers.")

;; ============================================================
;; Keymap
;; ============================================================

(defvar-keymap isqlm-mode-map
  :doc "Keymap for ISQLM mode."
  "RET"     #'isqlm-send-input
  "M-RET"   #'newline
  "C-c C-c" #'isqlm-interrupt
  "C-c C-q" #'isqlm-disconnect
  "C-c C-r" #'isqlm-reconnect
  "C-c C-n" #'isqlm-connect
  "C-c C-l" #'isqlm-clear-buffer
  "C-c C-u" #'isqlm-show-databases
  "C-c C-t" #'isqlm-show-tables
  "C-c C-d" #'isqlm-describe-table
  "M-p"     #'isqlm-previous-input
  "M-n"     #'isqlm-next-input
  "C-a"     #'isqlm-bol)

(easy-menu-define isqlm-menu isqlm-mode-map
  "ISQLM mode menu."
  '("ISQLM"
    ["Connect"        isqlm-connect t]
    ["Disconnect"     isqlm-disconnect t]
    ["Reconnect"      isqlm-reconnect t]
    "---"
    ["Show Databases" isqlm-show-databases t]
    ["Show Tables"    isqlm-show-tables t]
    ["Describe Table" isqlm-describe-table t]
    "---"
    ["Clear Buffer"   isqlm-clear-buffer t]))

;; ============================================================
;; Module loading
;; ============================================================

(defun isqlm--ensure-module ()
  "Ensure the mysql-el dynamic module is loaded."
  (unless (fboundp 'mysql-available-p)
    (condition-case err
        (require 'mysql-el)
      (error
       (error "Cannot load mysql-el module: %s" (isqlm--error-message err)))))
  (unless (mysql-available-p)
    (error "mysql-el module loaded but mysql-available-p returned nil")))

;; ============================================================
;; Error message extraction
;; ============================================================

;; mysql-el signals `mysql-error' with structured data: (ERRNO SQLSTATE ERRMSG).
;; In a `condition-case' handler, ERR is (mysql-error ERRNO SQLSTATE ERRMSG).
;; For generic `error' signals, ERR is (error . "message") or (error FORMAT ARGS...).

(defun isqlm--mysql-error-p (err)
  "Return non-nil if ERR is a `mysql-error' signal."
  (eq (car err) 'mysql-error))

(defun isqlm--mysql-error-errno (err)
  "Extract the MySQL error code (integer) from a `mysql-error' ERR."
  (nth 1 err))

(defun isqlm--mysql-error-sqlstate (err)
  "Extract the SQLSTATE string from a `mysql-error' ERR."
  (nth 2 err))

(defun isqlm--mysql-error-errmsg (err)
  "Extract the error message string from a `mysql-error' ERR."
  (nth 3 err))

(defun isqlm--error-message (err)
  "Extract a human-readable error message from ERR.
For `mysql-error' signals, format as \"ERROR <errno> (<sqlstate>): <msg>\".
For generic `error' signals, extract the message string."
  (if (isqlm--mysql-error-p err)
      (format "ERROR %d (%s): %s"
              (isqlm--mysql-error-errno err)
              (isqlm--mysql-error-sqlstate err)
              (isqlm--mysql-error-errmsg err))
    (let ((data (cdr err)))
      (cond
       ((stringp data) data)
       ((and (consp data) (stringp (car data)))
        (apply #'format (car data) (cdr data)))
       (t (error-message-string err))))))

(defun isqlm--output-mysql-error (&optional err)
  "Output a MySQL error in mysql-client format.
If ERR is a `mysql-error' signal, format its structured data as
\"ERROR <errno> (<sqlstate>): <message>\".  If ERR is a generic
`error' signal, output as \"*** Error *** <message>\".
If ERR is nil, output \"*** Error *** Unknown error\"."
  (if err
      (isqlm--output-error
       (concat (isqlm--error-message err) "\n"))
    (isqlm--output-error "*** Error *** Unknown error\n")))

(defun isqlm--warning-count-string (&optional result-plist)
  "Return a string like \", 2 warnings\" if there are warnings, else \"\".
If RESULT-PLIST is given, extract :warning-count from it.
Otherwise, query the connection with `mysql-warning-count'."
  (let ((wc (if result-plist
                (or (plist-get result-plist :warning-count) 0)
              (if (and isqlm-connection
                       (condition-case nil (mysqlp isqlm-connection) (error nil))
                       (fboundp 'mysql-warning-count))
                  (condition-case nil
                      (mysql-warning-count isqlm-connection)
                    (error 0))
                0))))
    (if (and (integerp wc) (> wc 0))
        (format ", %d %s" wc (if (= wc 1) "warning" "warnings"))
      "")))

;; ============================================================
;; Connection helpers
;; ============================================================

(defun isqlm--connected-p ()
  "Return non-nil if this buffer has a live MySQL connection."
  (and isqlm-connection
       (condition-case nil (mysqlp isqlm-connection) (error nil))))

(defun isqlm--connection-lost-p (err)
  "Return non-nil if ERR indicates a lost MySQL connection.
Checks for common MySQL error messages indicating server disconnect."
  (let ((msg (downcase (isqlm--error-message err))))
    (or (string-match-p "lost connection" msg)
        (string-match-p "server has gone away" msg)
        (string-match-p "connection was killed" msg)
        (string-match-p "closed database" msg)
        (string-match-p "can't connect" msg)
        ;; Also detect when mysqlp fails (handle invalidated)
        (not (isqlm--connected-p)))))

(defun isqlm--try-auto-reconnect ()
  "Attempt to reconnect using the last connection parameters.
Returns non-nil if reconnection succeeded."
  (when (and isqlm-auto-reconnect isqlm-connection-info)
    (let* ((info isqlm-connection-info)
           (host     (plist-get info :host))
           (user     (plist-get info :user))
           (password (plist-get info :password))
           (database (plist-get info :database))
           (port     (plist-get info :port)))
      (isqlm--output-info "Lost connection. Trying to reconnect...\n")
      ;; Close old connection silently
      (condition-case nil
          (when isqlm-connection (mysql-close isqlm-connection))
        (error nil))
      (setq isqlm-connection nil)
      (condition-case err
          (progn
            (setq isqlm-connection
                  (mysql-open host user (or password "")
                              (if (string= database "") nil database) port))
            (setq isqlm-connection-info
                  (list :host host :port port :user user
                        :password password :database database))
            (setq mode-line-process
                  (list (format " [%s]" (isqlm--format-connection-info))))
            (force-mode-line-update)
            (isqlm--output-info
             (format "Reconnected to %s\nCurrent database: %s\n\n"
                     (isqlm--format-connection-info)
                     (if (string= database "") "(none)" database)))
            t)
        (error
         (isqlm--output-error
          (format "*** Reconnection failed *** %s\n" (isqlm--error-message err)))
         nil)))))

(defun isqlm--format-connection-info ()
  "Return a human-readable connection description string."
  (if isqlm-connection-info
      (format "%s@%s:%d/%s"
              (plist-get isqlm-connection-info :user)
              (plist-get isqlm-connection-info :host)
              (plist-get isqlm-connection-info :port)
              (let ((db (plist-get isqlm-connection-info :database)))
                (if (or (null db) (string= db "")) "(none)" db)))
    "(not connected)"))

;; ============================================================
;; Output (eshell-style: direct buffer insertion, no process)
;; ============================================================

(defun isqlm--output (string)
  "Insert STRING into the ISQLM buffer as output at `isqlm-last-output-end'."
  (when (and string (> (length string) 0))
    (let ((inhibit-read-only t))
      (goto-char isqlm-last-output-end)
      (set-marker isqlm-last-output-start (point))
      (insert-before-markers string)
      (add-text-properties isqlm-last-output-start isqlm-last-output-end
                           '(rear-nonsticky t field output
                             inhibit-line-move-field-capture t
                             read-only t))
      (goto-char isqlm-last-output-end))))

(defun isqlm--output-error (msg)
  "Output MSG as error text."
  (isqlm--output (propertize msg 'font-lock-face 'isqlm-error-face)))

(defun isqlm--output-info (msg)
  "Output MSG as info text."
  (isqlm--output (propertize msg 'font-lock-face 'isqlm-info-face)))

;; ============================================================
;; Prompt (eshell-style: direct insertion with text properties)
;; ============================================================

(defun isqlm--emit-prompt ()
  "Insert a new prompt at `isqlm-last-output-end'."
  (let ((prompt (if (string= isqlm-pending-input "")
                    isqlm-prompt-internal
                  isqlm-prompt-continue))
        (inhibit-read-only t))
    (goto-char isqlm-last-output-end)
    (let ((start (point)))
      (insert prompt)
      (add-text-properties
       start (point)
       (list 'read-only      isqlm-prompt-read-only
             'field           'prompt
             'front-sticky    '(read-only field font-lock-face)
             'rear-nonsticky  '(read-only field font-lock-face)
             'font-lock-face  'isqlm-prompt-face
             'inhibit-line-move-field-capture t))
      (set-marker isqlm-last-output-end (point))
      (goto-char (point-max)))))

;; ============================================================
;; History
;; ============================================================

(defun isqlm--history-init ()
  "Initialize history ring and load from file."
  (setq isqlm-history-ring (make-ring isqlm-history-size))
  (setq isqlm-history-index nil)
  (setq isqlm-input-saved nil)
  (when (and isqlm-history-file-name
             (file-readable-p isqlm-history-file-name))
    (let ((lines (with-temp-buffer
                   (insert-file-contents isqlm-history-file-name)
                   (split-string (buffer-string) "\n" t))))
      (dolist (line (nreverse lines))
        (ring-insert isqlm-history-ring line)))))

(defun isqlm--history-save ()
  "Save history ring to file."
  (when (and isqlm-history-file-name isqlm-history-ring
             (> (ring-length isqlm-history-ring) 0))
    (let ((ring isqlm-history-ring)
          (file isqlm-history-file-name))
      (with-temp-file file
        (let ((len (ring-length ring)))
          (dotimes (i len)
            (insert (ring-ref ring (- len 1 i)) "\n")))))))

(defun isqlm--add-to-history (input)
  "Add INPUT to history ring if non-empty and not duplicate of last."
  (let ((trimmed (string-trim input)))
    (when (and (> (length trimmed) 0)
               (or (ring-empty-p isqlm-history-ring)
                   (not (string= trimmed (ring-ref isqlm-history-ring 0)))))
      (ring-insert isqlm-history-ring trimmed))))

(defun isqlm--get-current-input ()
  "Return current input text (from prompt end to point-max)."
  (buffer-substring-no-properties isqlm-last-output-end (point-max)))

(defun isqlm--replace-current-input (text)
  "Replace current input with TEXT."
  (let ((inhibit-read-only t))
    (delete-region isqlm-last-output-end (point-max))
    (goto-char isqlm-last-output-end)
    (insert text)))

(defun isqlm-previous-input ()
  "Navigate to previous history entry."
  (interactive)
  (when (and isqlm-history-ring (not (ring-empty-p isqlm-history-ring)))
    (when (null isqlm-history-index)
      (setq isqlm-input-saved (isqlm--get-current-input))
      (setq isqlm-history-index -1))
    (let ((new-idx (1+ isqlm-history-index)))
      (when (< new-idx (ring-length isqlm-history-ring))
        (setq isqlm-history-index new-idx)
        (isqlm--replace-current-input
         (ring-ref isqlm-history-ring isqlm-history-index))))))

(defun isqlm-next-input ()
  "Navigate to next history entry, or restore saved input."
  (interactive)
  (when isqlm-history-index
    (let ((new-idx (1- isqlm-history-index)))
      (cond
       ((>= new-idx 0)
        (setq isqlm-history-index new-idx)
        (isqlm--replace-current-input
         (ring-ref isqlm-history-ring isqlm-history-index)))
       (t
        (setq isqlm-history-index nil)
        (isqlm--replace-current-input (or isqlm-input-saved "")))))))

(defun isqlm-bol ()
  "Move to beginning of input line, skipping prompt."
  (interactive)
  (let ((input-start (marker-position isqlm-last-output-end)))
    (if (and (= (line-number-at-pos) (line-number-at-pos input-start))
             (> (point) input-start))
        (goto-char input-start)
      (beginning-of-line))))

;; ============================================================
;; SQL parsing
;; ============================================================

(defun isqlm--sql-complete-p (sql)
  "Return non-nil if SQL is a complete statement.
Complete if it ends with `;', `\\G', or `\\gset [PREFIX]'."
  (let ((trimmed (string-trim-right sql)))
    (or (string-suffix-p ";" trimmed)
        (string-suffix-p "\\G" trimmed)
        (string-match-p "\\\\gset\\(?:\\s-+\\S-+\\)?\\s-*$" trimmed)
        (string= trimmed ""))))

(defun isqlm--strip-terminator (sql)
  "Remove trailing terminator from SQL.
Return (BODY . MODE) where MODE is:
  nil       — normal (terminated by `;')
  t         — vertical display (terminated by `\\G')
  (:gset PREFIX) — store result as variables (terminated by `\\gset [PREFIX]')"
  (let ((trimmed (string-trim-right sql)))
    (cond
     ((string-match "\\\\gset\\(?:\\s-+\\(\\S-+\\)\\)?\\s-*$" trimmed)
      (let* ((prefix (or (match-string 1 trimmed) ""))
             (body (string-trim-right (substring trimmed 0 (match-beginning 0)))))
        ;; Also strip trailing ; (supports "stmt;\gset prefix")
        (when (string-suffix-p ";" body)
          (setq body (string-trim-right (substring body 0 -1))))
        (cons body (list :gset prefix))))
     ((string-suffix-p "\\G" trimmed)
      (cons (string-trim-right (substring trimmed 0 -2)) t))
     ((string-suffix-p ";" trimmed)
      (cons (string-trim-right (substring trimmed 0 -1)) nil))
     (t (cons trimmed nil)))))

(defun isqlm--expand-sql-variables (sql)
  "Expand `:varname' references in SQL string to variable values.
Skips expansion inside single-quoted strings, double-quoted strings,
backtick identifiers, and comments.  Variable values are formatted as:
  string → single-quoted (with internal quotes escaped)
  number → literal
  nil    → NULL
  other  → single-quoted via `format'"
  (let ((len (length sql))
        (i 0)
        (result nil)
        (in-sq nil) (in-dq nil) (in-bt nil)
        (in-lc nil) (in-bc nil))
    (while (< i len)
      (let ((ch (aref sql i)))
        (cond
         ;; Line comment
         (in-lc
          (push ch result)
          (when (= ch ?\n) (setq in-lc nil)))
         ;; Block comment
         (in-bc
          (push ch result)
          (when (and (= ch ?*) (< (1+ i) len) (= (aref sql (1+ i)) ?/))
            (push ?/ result)
            (cl-incf i)
            (setq in-bc nil)))
         ;; Single quote
         (in-sq
          (push ch result)
          (when (= ch ?')
            (if (and (< (1+ i) len) (= (aref sql (1+ i)) ?'))
                (progn (push ?' result) (cl-incf i))
              (setq in-sq nil))))
         ;; Double quote
         (in-dq
          (push ch result)
          (when (= ch ?\") (setq in-dq nil)))
         ;; Backtick
         (in-bt
          (push ch result)
          (when (= ch ?`) (setq in-bt nil)))
         ;; Normal context
         (t
          (cond
           ((= ch ?') (setq in-sq t) (push ch result))
           ((= ch ?\") (setq in-dq t) (push ch result))
           ((= ch ?`) (setq in-bt t) (push ch result))
           ((and (= ch ?-) (< (1+ i) len) (= (aref sql (1+ i)) ?-))
            (setq in-lc t) (push ch result))
           ((= ch ?#) (setq in-lc t) (push ch result))
           ((and (= ch ?/) (< (1+ i) len) (= (aref sql (1+ i)) ?*))
            (setq in-bc t) (push ch result) (push ?* result) (cl-incf i))
           ;; ::varname — raw expansion (no quoting, for identifiers)
           ;; :varname  — value expansion (strings quoted)
           ((and (= ch ?:)
                 (< (1+ i) len)
                 (let ((nc (aref sql (1+ i))))
                   (or (and (>= nc ?a) (<= nc ?z))
                       (and (>= nc ?A) (<= nc ?Z))
                       (= nc ?_)
                       (= nc ?:))))  ; :: prefix
            (let* ((raw-p (and (< (1+ i) len) (= (aref sql (1+ i)) ?:)))
                   (start (if raw-p (+ i 2) (1+ i)))
                   (j start))
              (while (and (< j len)
                          (let ((c (aref sql j)))
                            (or (and (>= c ?a) (<= c ?z))
                                (and (>= c ?A) (<= c ?Z))
                                (and (>= c ?0) (<= c ?9))
                                (= c ?_) (= c ?-))))
                (cl-incf j))
              (let* ((name (substring sql start j))
                     (sym (intern-soft name))
                     (val (if (and sym (boundp sym))
                              (symbol-value sym)
                            (user-error "Void variable in SQL: %s%s"
                                        (if raw-p "::" ":") name)))
                     (replacement
                      (if raw-p
                          ;; Raw: no quoting
                          (cond
                           ((null val) "NULL")
                           ((stringp val) val)
                           (t (format "%s" val)))
                        ;; Value: strings get quoted
                        (cond
                         ((null val) "NULL")
                         ((integerp val) (number-to-string val))
                         ((floatp val) (format "%g" val))
                         ((stringp val)
                          (concat "'" (replace-regexp-in-string "'" "''" val) "'"))
                         (t (concat "'"
                                    (replace-regexp-in-string
                                     "'" "''" (format "%s" val))
                                    "'"))))))
                (dolist (c (append replacement nil))
                  (push c result))
                (setq i (1- j)))))
           (t (push ch result))))))
      (cl-incf i))
    (apply #'string (nreverse result))))

(defun isqlm--split-statements (sql)
  "Split SQL into a list of individual statements.
Each element is a complete statement including its terminator (`;' or `\\G').
Handles quoted strings and comments to avoid splitting inside them."
  (let ((len (length sql))
        (i 0)
        (start 0)
        (statements nil)
        (in-single-quote nil)
        (in-double-quote nil)
        (in-backtick nil)
        (in-line-comment nil)
        (in-block-comment nil))
    (while (< i len)
      (let ((ch (aref sql i)))
        (cond
         ;; Line comment ends at newline
         (in-line-comment
          (when (= ch ?\n)
            (setq in-line-comment nil)))
         ;; Block comment: check for */
         (in-block-comment
          (when (and (= ch ?*) (< (1+ i) len) (= (aref sql (1+ i)) ?/))
            (setq in-block-comment nil)
            (cl-incf i)))
         ;; Inside single quote
         (in-single-quote
          (when (= ch ?')
            (if (and (< (1+ i) len) (= (aref sql (1+ i)) ?'))
                (cl-incf i)  ; escaped quote ''
              (setq in-single-quote nil))))
         ;; Inside double quote
         (in-double-quote
          (when (= ch ?\")
            (setq in-double-quote nil)))
         ;; Inside backtick
         (in-backtick
          (when (= ch ?`)
            (setq in-backtick nil)))
         ;; Normal context
         (t
          (cond
           ((= ch ?') (setq in-single-quote t))
           ((= ch ?\") (setq in-double-quote t))
           ((= ch ?`) (setq in-backtick t))
           ;; -- line comment
           ((and (= ch ?-) (< (1+ i) len) (= (aref sql (1+ i)) ?-))
            (setq in-line-comment t) (cl-incf i))
           ;; # line comment
           ((= ch ?#)
            (setq in-line-comment t))
           ;; /* block comment
           ((and (= ch ?/) (< (1+ i) len) (= (aref sql (1+ i)) ?*))
            (setq in-block-comment t) (cl-incf i))
           ;; \gset [PREFIX] terminator — must check before \G
           ((and (= ch ?\\) (< (+ i 4) len)
                 (string-match-p "\\`\\\\gset\\(?:\\s-\\|$\\)"
                                 (substring sql i (min len (+ i 20)))))
            ;; Find end of \gset [prefix]: scan to end of line or string
            (let ((j (+ i 5)))  ; skip past "\gset"
              ;; Skip optional whitespace + prefix
              (while (and (< j len)
                          (not (memq (aref sql j) '(?\n ?\; ?\\))))
                (cl-incf j))
              (let ((stmt (string-trim (substring sql start j))))
                (when (> (length stmt) 0)
                  (push stmt statements)))
              (setq i (1- j))
              (setq start j)))
           ;; \G terminator (but NOT \gset)
           ((and (= ch ?\\) (< (1+ i) len)
                 (memq (aref sql (1+ i)) '(?G ?g))
                 (or (>= (+ i 2) len)
                     (not (memq (aref sql (+ i 2)) '(?s ?S)))))
            (let ((stmt (string-trim (substring sql start (+ i 2)))))
              (when (> (length stmt) 0)
                (push stmt statements)))
            (cl-incf i)
            (setq start (1+ i)))
           ;; ; terminator — but check if \gset follows
           ((= ch ?\;)
            ;; Look ahead: skip whitespace, check for \gset
            (let ((peek (1+ i)))
              (while (and (< peek len) (memq (aref sql peek) '(?\s ?\t)))
                (cl-incf peek))
              (if (and (< (+ peek 4) len)
                       (string-match-p "\\`\\\\gset\\(?:\\s-\\|$\\)"
                                       (substring sql peek (min len (+ peek 20)))))
                  ;; ;\gset [prefix] — consume through end of \gset
                  (let ((j (+ peek 5))) ; skip past \gset
                    (while (and (< j len)
                                (not (memq (aref sql j) '(?\n ?\;))))
                      (cl-incf j))
                    (let ((stmt (string-trim (substring sql start j))))
                      (when (> (length stmt) 0)
                        (push stmt statements)))
                    (setq i (1- j))
                    (setq start j))
                ;; Normal ; terminator
                (let ((stmt (string-trim (substring sql start (1+ i)))))
                  (when (> (length stmt) 0)
                    (push stmt statements)))
                (setq start (1+ i)))))))))
      (cl-incf i))
    ;; Remainder (no terminator)
    (let ((rest (string-trim (substring sql start))))
      (when (> (length rest) 0)
        (push rest statements)))
    (nreverse statements)))

;; ============================================================
;; Result formatting
;; ============================================================

(defun isqlm--display-width (str)
  "Return the display width of single-line STR.
For multi-line strings, return the width of the longest line."
  (if (string-match-p "\n" str)
      (apply #'max (mapcar #'length (split-string str "\n")))
    (length str)))

(defun isqlm--truncate-string (str max-width)
  "Truncate single-line STR to MAX-WIDTH with `...' if needed."
  (if (> (length str) max-width)
      (concat (substring str 0 (max 0 (- max-width 3))) "...")
    str))

(defun isqlm--value-to-string (val)
  "Convert VAL to display string."
  (cond
   ((null val) isqlm-null-string)
   ((stringp val) val)
   ((integerp val) (number-to-string val))
   ((floatp val) (format "%g" val))
   (t (format "%S" val))))

(defconst isqlm--table-chars-ascii
  '(:top-left    "+" :top-mid    "+" :top-right    "+"
    :mid-left    "+" :mid-mid    "+" :mid-right    "+"
    :bot-left    "+" :bot-mid    "+" :bot-right    "+"
    :horizontal  "-" :vertical   "|")
  "ASCII table drawing characters.")

(defconst isqlm--table-chars-unicode
  '(:top-left    "┌" :top-mid    "┬" :top-right    "┐"
    :mid-left    "├" :mid-mid    "┼" :mid-right    "┤"
    :bot-left    "└" :bot-mid    "┴" :bot-right    "┘"
    :horizontal  "─" :vertical   "│")
  "Unicode box-drawing table characters.")

(defun isqlm--table-chars ()
  "Return the active table character set based on `isqlm-table-style'."
  (if (eq isqlm-table-style 'unicode)
      isqlm--table-chars-unicode
    isqlm--table-chars-ascii))

(defun isqlm--make-separator (widths left mid right horiz)
  "Build a separator line: LEFT───MID───MID───RIGHT\\n."
  (let ((h (aref horiz 0)))
    (concat left
            (mapconcat (lambda (w) (make-string (+ w 2) h))
                       widths mid)
            right "\n")))

(defun isqlm--format-table (columns rows)
  "Format COLUMNS and ROWS as a textual table string.
Handles multi-line cell values (containing newlines) by splitting
each data row into multiple display lines."
  (let* ((ncols (length columns))
         (chars (isqlm--table-chars))
         (h  (plist-get chars :horizontal))
         (v  (plist-get chars :vertical))
         (str-rows (mapcar (lambda (row)
                             (mapcar #'isqlm--value-to-string row))
                           rows))
         (widths (make-list ncols 0)))
    ;; Compute column widths from headers
    (dotimes (i ncols)
      (setf (nth i widths)
            (max (nth i widths) (length (nth i columns)))))
    ;; Compute column widths from data (using display-width for multi-line)
    (dolist (row str-rows)
      (dotimes (i (min ncols (length row)))
        (setf (nth i widths)
              (max (nth i widths) (isqlm--display-width (nth i row))))))
    ;; Apply max-column-width limit (0 = no limit)
    (when (and isqlm-max-column-width (> isqlm-max-column-width 0))
      (dotimes (i ncols)
        (setf (nth i widths)
              (min isqlm-max-column-width (nth i widths)))))
    (let* ((top-sep (isqlm--make-separator
                     widths
                     (plist-get chars :top-left)
                     (plist-get chars :top-mid)
                     (plist-get chars :top-right) h))
           (mid-sep (isqlm--make-separator
                     widths
                     (plist-get chars :mid-left)
                     (plist-get chars :mid-mid)
                     (plist-get chars :mid-right) h))
           (bot-sep (isqlm--make-separator
                     widths
                     (plist-get chars :bot-left)
                     (plist-get chars :bot-mid)
                     (plist-get chars :bot-right) h))
           (header (concat v " "
                           (mapconcat
                            (lambda (pair)
                              (let ((name (car pair)) (w (cdr pair)))
                                (isqlm--truncate-string
                                 (format (format "%%-%ds" w) name) w)))
                            (cl-mapcar #'cons columns widths)
                            (concat " " v " "))
                           " " v "\n"))
           (data-lines
            (mapconcat
             (lambda (row)
               (isqlm--format-table-row row widths ncols v))
             str-rows "")))
      (concat top-sep
              (propertize header 'font-lock-face 'isqlm-table-header-face)
              mid-sep data-lines bot-sep))))

(defun isqlm--format-table-row (row widths ncols vertical)
  "Format a single ROW into one or more display lines.
ROW is a list of string cell values.  WIDTHS is the list of column widths.
NCOLS is the number of columns.  VERTICAL is the vertical bar character.
Cells containing newlines are split across multiple display lines."
  (let* ((cells (append row (make-list (max 0 (- ncols (length row))) "")))
         (cell-lines (cl-mapcar
                      (lambda (val w)
                        (mapcar (lambda (line)
                                  (isqlm--truncate-string line w))
                                (split-string val "\n")))
                      cells widths))
         (nlines (apply #'max 1 (mapcar #'length cell-lines))))
    (mapconcat
     (lambda (line-idx)
       (concat vertical " "
               (mapconcat
                (lambda (pair)
                  (let* ((lines (car pair))
                         (w (cdr pair))
                         (line (or (nth line-idx lines) ""))
                         (truncated (isqlm--truncate-string line w)))
                    (format (format "%%-%ds" w) truncated)))
                (cl-mapcar #'cons cell-lines widths)
                (concat " " vertical " "))
               " " vertical "\n"))
     (number-sequence 0 (1- nlines)) "")))

(defun isqlm--format-vertical (columns row)
  "Format a single ROW vertically with COLUMNS."
  (let ((max-col-len (apply #'max (mapcar #'length columns))))
    (mapconcat
     (lambda (pair)
       (format (format "%%%ds: %%s" max-col-len)
               (car pair) (isqlm--value-to-string (cdr pair))))
     (cl-mapcar #'cons columns row) "\n")))

;; ============================================================
;; SQL Execution
;; ============================================================

(defun isqlm--execute-sql (sql)
  "Execute SQL and return formatted output string.
Handles terminator parsing, USE side-effects, and result formatting.
Connection check and auto-reconnect are delegated to `isqlm-execute-string'."
  (setq isqlm-last-query sql)
  (let* ((parsed (isqlm--strip-terminator sql))
         (query (car parsed))
         (mode (cdr parsed))
         (upper (upcase (string-trim-left query))))
    (when (string= query "")
      (error "Empty query"))
    ;; USE: execute + update connection-info and mode-line
    (if (string-prefix-p "USE" upper)
        (progn
          (isqlm-execute-string query)
          (let ((db-name (string-trim
                          (replace-regexp-in-string "\\`USE\\s-+" "" query))))
            (setq db-name (replace-regexp-in-string "[`'\"]" "" db-name))
            (plist-put isqlm-connection-info :database db-name)
            (setq mode-line-process
                  (list (format " [%s]" (isqlm--format-connection-info))))
            (force-mode-line-update)
            (propertize (format "Database changed to: %s\n" db-name)
                        'font-lock-face 'isqlm-info-face)))
      ;; All other SQL
      (let ((result (isqlm-execute-string query)))
        (isqlm--format-result-string result mode)))))

(defun isqlm-execute-string (sql)
  "Execute SQL on the current ISQLM connection, return a result plist.

This is the public API for programmatic SQL execution.  It abstracts
the underlying database module so that callers do not depend on
`mysql-el' directly.

The query is sent asynchronously and polled with `sit-for', so Emacs
remains responsive even for slow queries.

The returned plist has one of the following shapes:

  SELECT: (:type select :columns (\"col\" ...)
           :rows ((val ...) ...) :warning-count N)
  DML:    (:type dml :affected-rows N :warning-count N)

Signals `mysql-error' (or `error') on failure.
Auto-reconnect is attempted if `isqlm-auto-reconnect' is non-nil."
  (unless (or (isqlm--connected-p) isqlm-connection-info)
    (error "Not connected.  Use `\\connect' or M-x isqlm-connect"))
  (when (and (not (isqlm--connected-p)) isqlm-connection-info)
    (unless (isqlm--try-auto-reconnect)
      (error "Not connected.  Use `\\connect' or M-x isqlm-connect")))
  (condition-case err
      (isqlm--query-with-poll sql)
    (error
     (if (and isqlm-auto-reconnect
              isqlm-connection-info
              (isqlm--connection-lost-p err))
         (if (isqlm--try-auto-reconnect)
             (isqlm--query-with-poll sql)
           (signal (car err) (cdr err)))
       (signal (car err) (cdr err))))))

(defun isqlm--query-with-poll (sql)
  "Execute SQL via async `mysql-query' and poll until complete.
Returns the result plist.  Uses `sit-for' so Emacs stays responsive."
  (let ((result (mysql-query isqlm-connection sql t)))
    (while (eq result 'not-ready)
      (sit-for 0.02)
      (setq result (mysql-query-poll isqlm-connection)))
    result))

;; ============================================================
;; Async SQL Execution (non-blocking, via mysql-query / mysql-query-poll)
;; ============================================================

(defun isqlm--async-execute-statements (statements buffer)
  "Execute STATEMENTS asynchronously one by one in BUFFER.
Each statement is expanded, executed via the async API, and the
result is output.  When all statements finish, emit a prompt."
  (if (null statements)
      ;; All done
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq isqlm--async-busy nil)
          (isqlm--emit-prompt)))
    ;; Execute the next statement
    (let* ((stmt (car statements))
           (rest (cdr statements))
           (expanded (isqlm--expand-sql-variables stmt)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (isqlm--async-execute-one
           expanded buffer
           (lambda ()
             (isqlm--async-execute-statements rest buffer))))))))

(defun isqlm--async-run-statements (statements buffer callback)
  "Execute STATEMENTS asynchronously, then call CALLBACK.
Like `isqlm--async-execute-statements' but does not manage
`isqlm--async-busy' or emit a prompt.  Used by scripts, for-loops,
and other internal callers that chain multiple lines."
  (if (null statements)
      (when callback (funcall callback))
    (let* ((stmt (car statements))
           (rest (cdr statements))
           (expanded (isqlm--expand-sql-variables stmt)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (isqlm--async-execute-one
           expanded buffer
           (lambda ()
             (isqlm--async-run-statements rest buffer callback))))))))

(defun isqlm--async-execute-one (sql buffer callback)
  "Execute a single SQL statement asynchronously.
SQL is the expanded statement.  BUFFER is the isqlm buffer.
CALLBACK is called (with no args) when this statement completes."
  (with-current-buffer buffer
    (catch 'done
      (let* ((parsed (isqlm--strip-terminator sql))
             (query (car parsed))
             (mode (cdr parsed))
             (upper (upcase (string-trim-left query))))
        (setq isqlm-last-query sql)
        (when (string= query "")
          (isqlm--output-error "*** Error *** Empty query\n")
          (funcall callback)
          (throw 'done nil))
        ;; Start async query via mysql-query (including USE)
        (condition-case err
            (let ((result (mysql-query isqlm-connection query t)))
              (if (not (eq result 'not-ready))
                  ;; Completed immediately — process result
                  (progn
                    (isqlm--async-handle-result result sql query mode
                                               upper buffer callback)
                    (funcall callback))
                ;; Not ready — poll with timer
                (setq isqlm--async-state
                      (list :phase 'query :sql sql :query query
                            :mode mode :upper upper :callback callback
                            :timer (run-with-timer
                                    0.02 0.02
                                    #'isqlm--poll-query buffer)))))
          (error
           ;; Connection lost? Try auto-reconnect + retry async
           (if (and isqlm-auto-reconnect
                    isqlm-connection-info
                    (isqlm--connection-lost-p err))
               (if (isqlm--try-auto-reconnect)
                   ;; Retry the query asynchronously after reconnect
                   (condition-case err2
                       (let ((result (mysql-query isqlm-connection query t)))
                         (if (not (eq result 'not-ready))
                             (progn
                               (isqlm--async-handle-result
                                result sql query mode upper buffer callback)
                               (funcall callback))
                           (setq isqlm--async-state
                                 (list :phase 'query :sql sql :query query
                                       :mode mode :upper upper
                                       :callback callback
                                       :timer (run-with-timer
                                               0.02 0.02
                                               #'isqlm--poll-query buffer)))))
                     (error
                      (when isqlm-noisy (ding))
                      (isqlm--output-mysql-error err2)
                      (funcall callback)))
                 ;; Reconnect failed
                 (when isqlm-noisy (ding))
                 (isqlm--output-mysql-error err)
                 (funcall callback))
             ;; Not a connection-lost error
             (when isqlm-noisy (ding))
             (isqlm--output-mysql-error err)
             (funcall callback))))))))

(defun isqlm--async-handle-result (result sql query mode upper
                                          _buffer _callback)
  "Handle a completed async RESULT for QUERY.
SQL is the original statement with terminator.  UPPER is the uppercased
query.  MODE is the terminator mode.
Handles USE side-effects; for other statements, formats and
outputs the result."
  (if (string-prefix-p "USE" upper)
      ;; USE: update connection-info + mode-line
      (let ((db-name (string-trim
                      (replace-regexp-in-string "\\`USE\\s-+" "" query))))
        (setq db-name (replace-regexp-in-string "[`'\"]" "" db-name))
        (plist-put isqlm-connection-info :database db-name)
        (setq mode-line-process
              (list (format " [%s]" (isqlm--format-connection-info))))
        (force-mode-line-update)
        (isqlm--output
         (propertize (format "Database changed to: %s\n" db-name)
                     'font-lock-face 'isqlm-info-face)))
    ;; Normal result
    (isqlm--format-and-output-result result sql mode)))

(defun isqlm--poll-query (buffer)
  "Timer callback: poll async query progress via mysql-query-poll."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when isqlm--async-state
        (condition-case err
            (let ((result (mysql-query-poll isqlm-connection)))
              (unless (eq result 'not-ready)
                ;; Query complete — cancel timer and process result
                (let ((timer (plist-get isqlm--async-state :timer))
                      (sql (plist-get isqlm--async-state :sql))
                      (query (plist-get isqlm--async-state :query))
                      (mode (plist-get isqlm--async-state :mode))
                      (upper (plist-get isqlm--async-state :upper))
                      (callback (plist-get isqlm--async-state :callback)))
                  (when timer (cancel-timer timer))
                  (setq isqlm--async-state nil)
                  (isqlm--async-handle-result result sql query mode
                                              upper buffer callback)
                  (when callback (funcall callback)))))
          (error
           (let ((timer (plist-get isqlm--async-state :timer))
                 (callback (plist-get isqlm--async-state :callback)))
             (when timer (cancel-timer timer))
             (setq isqlm--async-state nil)
             (setq isqlm--async-busy nil)
             (when isqlm-noisy (ding))
             (isqlm--output-mysql-error err)
             (when callback (funcall callback)))))))))

(defun isqlm--format-result-string (result mode)
  "Format RESULT plist from `mysql-query' into a string.
MODE is the terminator mode from `isqlm--strip-terminator'.
Returns the formatted string, or \"\" for \\gset."
  (let* ((type (plist-get result :type))
         (gset-p (and (listp mode) (eq (car mode) :gset)))
         (gset-prefix (and gset-p (cadr mode)))
         (vertical (and (not gset-p) (eq mode t)))
         (ws (isqlm--warning-count-string result)))
    (pcase type
      ('select
       (let ((columns (plist-get result :columns))
             (rows (plist-get result :rows)))
         (setq isqlm-last-result
               (when columns (cons columns rows)))
         (if gset-p
             ;; \gset: store result as variables
             (cond
              ((null rows)
               (error "Query returned no results"))
              ((/= (length rows) 1)
               (error "\\gset requires exactly 1 row, got %d" (length rows)))
              (t
               (let ((row (car rows)))
                 (dotimes (i (length columns))
                   (set (intern (concat (or gset-prefix "") (nth i columns)))
                        (nth i row)))
                 "")))
           ;; Normal SELECT display
           (if (null rows)
               (propertize (format "Empty set (0 rows)%s\n" ws)
                           'font-lock-face 'isqlm-info-face)
             (let* ((nrows (length rows))
                    (truncated nil))
               (when (and (> isqlm-max-rows 0) (> nrows isqlm-max-rows))
                 (setq rows (seq-take rows isqlm-max-rows))
                 (setq truncated t))
               (concat
                (if vertical
                    (let ((n 0))
                      (mapconcat
                       (lambda (row)
                         (cl-incf n)
                         (concat (format "*************************** %d. row ***************************\n" n)
                                 (isqlm--format-vertical columns row) "\n"))
                       rows ""))
                  (isqlm--format-table columns rows))
                (propertize
                 (if truncated
                     (format "%d rows in set%s (truncated from %d)\n" (length rows) ws nrows)
                   (format "%d %s in set%s\n" nrows (if (= nrows 1) "row" "rows") ws))
                 'font-lock-face 'isqlm-info-face)))))))
      ('dml
       (let ((affected (plist-get result :affected-rows)))
         (propertize
          (if (and (integerp affected) (>= affected 0))
              (format "Query OK, %d %s affected%s\n"
                      affected (if (= affected 1) "row" "rows") ws)
            (format "Query OK%s\n" ws))
          'font-lock-face 'isqlm-info-face)))
      (_ (error "Unknown result type")))))

(defun isqlm--format-and-output-result (result _sql mode)
  "Format RESULT plist from `mysql-query' and output to buffer.
_SQL is the original statement (unused), MODE is the terminator mode."
  (let ((str (condition-case err
                 (isqlm--format-result-string result mode)
               (error
                (isqlm--output-error
                 (format "*** Error *** %s\n" (isqlm--error-message err)))
                nil))))
    (when (and str (not (string= str "")))
      (isqlm--output str))))

(defun isqlm--async-cancel ()
  "Cancel any in-progress async query."
  (when isqlm--async-state
    (let ((timer (plist-get isqlm--async-state :timer)))
      (when timer (cancel-timer timer)))
    (setq isqlm--async-state nil))
  (setq isqlm--async-busy nil))

(defun isqlm/help (&rest _args)
  "Display available ISQLM commands."
  (isqlm--output-info
   (concat
    "General\n"
    "  \\gset [PREFIX]         execute query, store result as variables\n"
    "  \\use DATABASE          switch database\n"
    "  \\help                  show this help\n"
    "  \\quit / \\exit          kill ISQLM buffer\n"
    "\n"
    "Connection\n"
    "  \\connect [NAME | [HOST] [USER] [DB] [PORT]]\n"
    "                         connect to MySQL server\n"
    "  \\connections           list connections from sql-connection-alist\n"
    "  \\disconnect            disconnect from server\n"
    "  \\reconnect             reconnect with last parameters\n"
    "  \\password              toggle password prompting on connect\n"
    "  \\status                show connection status\n"
    "\n"
    "Input/Output\n"
    "  \\i FILE / \\include FILE\n"
    "                         execute commands from file\n"
    "  \\echo TEXT...          output text\n"
    "  \\clear                 clear buffer\n"
    "  \\history               show input history\n"
    "  \\style [ascii|unicode] toggle/set table border style\n"
    "\n"
    "Control Flow\n"
    "  \\if EXPR               begin conditional block\n"
    "  \\elif EXPR             alternative within conditional block\n"
    "  \\else                  final alternative within conditional block\n"
    "  \\endif                 end conditional block\n"
    "  \\for VAR in V1 V2 ... { body }\n"
    "                         loop over values\n"
    "\n"
    "Variables & Elisp\n"
    "  \\setq VAR VALUE        set an Emacs variable\n"
    "  \\eval EXPR             evaluate Elisp expression\n"
    "  :varname               reference variable (quoted in SQL)\n"
    "  ::varname              reference variable (raw in SQL)\n"
    "  \\CMD ARGS...           call Emacs Lisp function CMD\n"
    "\n"
    "Aliases: \\? = \\h = \\help, \\q = \\quit, \\u = \\use, \\. = \\i\n"
    "\n"
    "SQL statements must end with a terminator:\n"
    "  ;              execute and display results\n"
    "  \\G             execute and display results vertically\n"
    "  \\gset [PREFIX] execute and store results as variables\n"
    "Press M-RET for a literal newline.  C-c C-c to abort input.\n")))

(defun isqlm--resolve-sql-connection (name)
  "Look up NAME in `sql-connection-alist'.
Return a plist (:host :user :password :database :port) or nil."
  (when (boundp 'sql-connection-alist)
    (let* ((entry (assoc-string name sql-connection-alist t))
           (params (cdr entry)))
      (when params
        (let ((host     (cadr (assq 'sql-server   params)))
              (user     (cadr (assq 'sql-user     params)))
              (password (cadr (assq 'sql-password params)))
              (database (cadr (assq 'sql-database params)))
              (port     (cadr (assq 'sql-port     params))))
          (list :host     (or host isqlm-default-host)
                :user     (or user isqlm-default-user)
                :password password
                :database (or database isqlm-default-database)
                :port     (or port isqlm-default-port)))))))

(defun isqlm/connections (&rest _args)
  "List available connections from `sql-connection-alist'."
  (if (or (not (boundp 'sql-connection-alist))
          (null sql-connection-alist))
      (isqlm--output-info "No connections defined in sql-connection-alist.\n")
    (let ((lines (list "Available connections (from sql-connection-alist):\n")))
      (dolist (entry sql-connection-alist)
        (let* ((name (car entry))
               (params (cdr entry))
               (host (or (cadr (assq 'sql-server params)) ""))
               (user (or (cadr (assq 'sql-user params)) ""))
               (db   (or (cadr (assq 'sql-database params)) ""))
               (port (or (cadr (assq 'sql-port params)) "")))
          (push (format "  %-20s %s@%s:%s/%s\n"
                        name user host port db)
                lines)))
      (isqlm--output-info (apply #'concat (nreverse lines))))))

(defun isqlm/connect (&rest args)
  "Connect to MySQL.

Usage:
  \\connect NAME              — connect using sql-connection-alist entry
  \\connect [HOST] [USER] [DB] [PORT] — connect with explicit parameters
                                 (all optional, defaults applied)
  \\connect                   — use all defaults

Password is never specified on the command line.
When `isqlm-prompt-password' is non-nil (default), password is prompted
via the echo area.  Set it to nil with:
  \\password                  — toggle password prompting"
  (isqlm--ensure-module)
  (when (isqlm--connected-p)
    (isqlm--output-info "Disconnecting current session...\n")
    (isqlm/disconnect))
  ;; Check if first arg matches a sql-connection-alist entry
  (let ((conn-info (and (= (length args) 1)
                        (isqlm--resolve-sql-connection (car args)))))
    (if conn-info
        ;; Connect from sql-connection-alist
        (let ((host     (plist-get conn-info :host))
              (user     (plist-get conn-info :user))
              (password (or (plist-get conn-info :password)
                            (if isqlm-prompt-password
                                (read-passwd "Password: ")
                              "")))
              (database (plist-get conn-info :database))
              (port     (plist-get conn-info :port)))
          (isqlm--do-connect host user password database port))
      ;; Connect with explicit positional args; all optional, defaults applied
      (let* ((host     (or (nth 0 args) isqlm-default-host))
             (user     (or (nth 1 args) isqlm-default-user))
             (database (or (nth 2 args) isqlm-default-database))
             (port     (or (and (nth 3 args) (string-to-number (nth 3 args)))
                           isqlm-default-port))
             (password (if isqlm-prompt-password
                           (read-passwd "Password: ")
                         "")))
        (isqlm--do-connect host user password database port)))))

(defun isqlm--do-connect (host user password database port)
  "Perform the actual MySQL connection (async when available).
HOST, USER, PASSWORD, DATABASE, PORT are connection parameters."
  (condition-case err
      (let ((db-arg (if (string= database "") nil database)))
        (setq isqlm-connection
              (mysql-open host user password db-arg port t))
        (setq isqlm-connection-info
              (list :host host :port port :user user
                    :password password :database database))
        ;; Poll until connected
        (isqlm--output-info "Connecting...\n")
        (setq isqlm--async-state
              (list :phase 'connect
                    :timer (run-with-timer
                            0.02 0.02
                            #'isqlm--poll-connect (current-buffer)))))
    (error
     (isqlm--output-mysql-error err))))

(defun isqlm--poll-connect (buffer)
  "Timer callback: poll async connect progress."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (condition-case err
          (pcase (mysql-open-poll isqlm-connection)
            ('not-ready nil)
            ('complete
             (when (plist-get isqlm--async-state :timer)
               (cancel-timer (plist-get isqlm--async-state :timer)))
             (setq isqlm--async-state nil)
             (setq mode-line-process
                   (list (format " [%s]" (isqlm--format-connection-info))))
             (force-mode-line-update)
             (let ((ver (condition-case nil (mysql-version) (error "unknown"))))
               (isqlm--output-info
                (format "Connected to %s (MySQL client library: %s)\n"
                        (isqlm--format-connection-info) ver)))
             (setq isqlm-pending-input "")
             (isqlm--emit-prompt)))
        (error
         (when (and isqlm--async-state (plist-get isqlm--async-state :timer))
           (cancel-timer (plist-get isqlm--async-state :timer)))
         (setq isqlm--async-state nil)
         (isqlm--output-mysql-error err)
         (isqlm--emit-prompt))))))

(defun isqlm/password (&rest _args)
  "Toggle whether \\connect prompts for a password.
When enabled, \\connect will ask for password via echo area.
When disabled, empty password is used."
  (setq isqlm-prompt-password (not isqlm-prompt-password))
  (isqlm--output-info
   (format "Password prompting: %s\n"
           (if isqlm-prompt-password "ON" "OFF"))))

(defun isqlm/disconnect (&rest _args)
  "Disconnect from MySQL."
  (if (not isqlm-connection)
      (isqlm--output-info "Not connected.\n")
    (condition-case nil (mysql-close isqlm-connection) (error nil))
    (setq isqlm-connection nil)
    (setq isqlm-pending-input "")
    (setq mode-line-process '(" [disconnected]"))
    (force-mode-line-update)
    (isqlm--output-info "Disconnected.\n")))

(defun isqlm/reconnect (&rest _args)
  "Reconnect with last connection parameters."
  (if (not isqlm-connection-info)
      (isqlm--output-error "No previous connection info.  Use `\\connect' instead.\n")
    (let ((info isqlm-connection-info))
      (isqlm/disconnect)
      (isqlm--do-connect (plist-get info :host)
                         (plist-get info :user)
                         (or (plist-get info :password) "")
                         (plist-get info :database)
                         (plist-get info :port)))))

(defun isqlm/use (&rest args)
  "Switch to a different database.  ARGS: DATABASE-NAME."
  (let ((db (car args)))
    (cond
     ((not db)
      (isqlm--output-error "Usage: \\use DATABASE\n"))
     ((not (isqlm--connected-p))
      (isqlm--output-error "Not connected.\n"))
     (t
      (condition-case err
          (progn
            (mysql-execute isqlm-connection (format "USE `%s`" db))
            (plist-put isqlm-connection-info :database db)
            (setq mode-line-process
                  (list (format " [%s]" (isqlm--format-connection-info))))
            (force-mode-line-update)
            (isqlm--output-info (format "Database changed to: %s\n" db)))
        (error
         (isqlm--output-mysql-error err)))))))

(defun isqlm/status (&rest _args)
  "Show connection status and configuration."
  (isqlm--output-info
   (concat
    (if (isqlm--connected-p)
        (format "Connected: %s\n" (isqlm--format-connection-info))
      "Not connected.\n")
    (format "Auto-reconnect: %s\n" (if isqlm-auto-reconnect "on" "off"))
    (format "Table style: %s\n" isqlm-table-style)
    (format "Password prompt: %s\n" (if isqlm-prompt-password "on" "off")))))

(defun isqlm/style (&rest args)
  "Toggle or set table style.  ARGS: [ascii|unicode].
Without argument, toggle between ascii and unicode."
  (let ((arg (car args)))
    (cond
     ((null arg)
      (setq isqlm-table-style
            (if (eq isqlm-table-style 'unicode) 'ascii 'unicode))
      (isqlm--output-info
       (format "Table style: %s\n" isqlm-table-style)))
     ((string= (downcase arg) "ascii")
      (setq isqlm-table-style 'ascii)
      (isqlm--output-info "Table style: ascii\n"))
     ((string= (downcase arg) "unicode")
      (setq isqlm-table-style 'unicode)
      (isqlm--output-info "Table style: unicode\n"))
     (t
      (isqlm--output-error "Usage: \\style [ascii|unicode]\n")))))

(defun isqlm/eval (&rest args)
  "Evaluate an Elisp expression.  ARGS are joined and read as a sexp.
Examples:
  \\eval (+ 1 2)
  \\eval (dotimes (i 3) (isqlm--quick-sql (format \"SELECT %d;\" (1+ i))))
  \\eval (format \"hello %s\" user-login-name)"
  (if (not args)
      (isqlm--output-error "Usage: \\eval EXPRESSION\n")
    (let ((expr-str (string-join args " ")))
      (condition-case err
          (let ((result (eval (read expr-str) t)))
            (when result
              (isqlm--output
               (concat (if (stringp result) result (pp-to-string result))
                       "\n"))))
        (error
         (isqlm--output-error
          (format "*** Eval Error *** %s\n" (isqlm--error-message err))))))))

(defun isqlm--execute-line (line &optional callback)
  "Execute LINE as if typed at the prompt.
Handles built-in commands, complete SQL, and multi-statement input.
When CALLBACK is non-nil, it is called after execution completes
\(used by script and for-loop execution to chain lines)."
  (let ((trimmed (string-trim line))
        (buf (current-buffer)))
    (if (= (length trimmed) 0)
        (when callback (funcall callback))
      (cond
       ;; Built-in command
       ((string-prefix-p "\\" trimmed)
        (isqlm--try-builtin-command trimmed)
        (when callback (funcall callback)))
       ;; Complete SQL — execute asynchronously
       ((isqlm--sql-complete-p trimmed)
        (let ((statements (isqlm--split-statements trimmed)))
          (isqlm--async-run-statements
           statements buf
           (or callback #'ignore))))
       ;; Incomplete SQL — warning
       (t
        (isqlm--output-error
         (format "Incomplete statement: %s\n" trimmed))
        (when callback (funcall callback)))))))

(defun isqlm--execute-script (text)
  "Execute TEXT as a script asynchronously.
Multi-line SQL is accumulated until a terminator is found.
Respects \\if/\\elif/\\else/\\endif conditional flow.
Each SQL statement is executed via the async pipeline."
  (let ((lines (split-string text "\n"))
        (buf (current-buffer)))
    (isqlm--script-process-lines lines "" buf)))

(defun isqlm--script-process-lines (lines pending buf)
  "Process LINES from a script with PENDING accumulated input in BUF.
Async: when a SQL statement is found, execute it and continue
processing remaining lines in the callback."
  (if (null lines)
      ;; End of script — check for unterminated input
      (when (> (length (string-trim pending)) 0)
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when (isqlm--cond-active-p)
              (isqlm--output-error
               (format "Unterminated statement at end of script: %s\n"
                       (string-trim pending)))))))
    (let* ((line (car lines))
           (rest (cdr lines))
           (new-pending (concat pending
                                (if (string= pending "") "" "\n")
                                line))
           (trimmed (string-trim new-pending)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (cond
           ;; Built-in command on its own line (no multi-line pending)
           ((and (not (string-match-p "\n" new-pending))
                 (string-prefix-p "\\" trimmed))
            (cond
             ;; Conditional flow commands — always process, then continue
             ((isqlm--cond-flow-command-p trimmed)
              (isqlm--process-cond-flow trimmed)
              (isqlm--script-process-lines rest "" buf))
             ;; Other commands — only when active (async via callback)
             ((isqlm--cond-active-p)
              (isqlm--execute-line
               new-pending
               (lambda ()
                 (isqlm--script-process-lines rest "" buf))))
             ;; Inactive — skip command, continue
             (t
              (isqlm--script-process-lines rest "" buf))))
           ;; Complete SQL — execute only when active
           ((isqlm--sql-complete-p new-pending)
            (if (isqlm--cond-active-p)
                (let ((statements (isqlm--split-statements new-pending)))
                  (isqlm--async-run-statements
                   statements buf
                   (lambda ()
                     (isqlm--script-process-lines rest "" buf))))
              (isqlm--script-process-lines rest "" buf)))
           ;; Incomplete — accumulate and continue
           (t
            (isqlm--script-process-lines rest new-pending buf))))))))

;; Minor mode for \i - editing buffer
(defvar-local isqlm--script-target nil
  "The ISQLM buffer to send the script to when finished editing.")

(defvar isqlm-script-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'isqlm-script-finish)
    (define-key map (kbd "C-c C-k") #'isqlm-script-abort)
    map)
  "Keymap for `isqlm-script-mode'.")

(define-minor-mode isqlm-script-mode
  "Minor mode for editing an ISQLM script.
\\<isqlm-script-mode-map>
\\[isqlm-script-finish] to execute the script.
\\[isqlm-script-abort] to abort."
  :lighter " ISQLM-Script"
  :keymap isqlm-script-mode-map)

(defun isqlm-script-finish ()
  "Execute the script in this buffer and close it."
  (interactive)
  (let ((text (buffer-substring-no-properties (point-min) (point-max)))
        (target isqlm--script-target)
        (buf (current-buffer)))
    (quit-window)
    (kill-buffer buf)
    (when (and target (buffer-live-p target))
      (with-current-buffer target
        (isqlm--execute-script text)
        (isqlm--emit-prompt)))))

(defun isqlm-script-abort ()
  "Abort the script editing."
  (interactive)
  (let ((buf (current-buffer)))
    (quit-window)
    (kill-buffer buf)
    (message "Script aborted.")))

(defun isqlm/i (&rest args)
  "Read and execute SQL from a file (à la psql \\i / \\include).
ARGS: FILENAME.
If FILENAME is `-', open a temporary buffer for script editing.
Press C-c C-c to execute, C-c C-k to abort."
  (let ((filename (car args)))
    (cond
     ((not filename)
      (isqlm--output-error "Usage: \\i FILENAME  (use - for interactive script)\n"))
     ;; Interactive mode: open editing buffer
     ((string= filename "-")
      (let ((target (current-buffer))
            (buf (generate-new-buffer "*isqlm-script*")))
        (pop-to-buffer buf)
        (sql-mode)
        (isqlm-script-mode 1)
        (setq isqlm--script-target target)
        (setq header-line-format
              "Edit SQL script.  C-c C-c to execute, C-c C-k to abort.")
        (message "Edit script, then C-c C-c to execute or C-c C-k to abort.")))
     ;; File mode
     (t
      (let ((path (expand-file-name filename)))
        (if (not (file-readable-p path))
            (isqlm--output-error (format "Cannot read file: %s\n" path))
          (isqlm--execute-script
           (with-temp-buffer
             (insert-file-contents path)
             (buffer-string)))))))))

(defalias 'isqlm/include #'isqlm/i
  "Alias for `isqlm/i'.  Read and execute SQL from a file.")

(defun isqlm/clear (&rest _args)
  "Clear the ISQLM buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq isqlm-last-input-start (point-min-marker))
    (setq isqlm-last-input-end (point-min-marker))
    (setq isqlm-last-output-start (point-min-marker))
    (setq isqlm-last-output-end (point-min-marker))))

(defun isqlm/history (&rest _args)
  "Show input history."
  (if (or (null isqlm-history-ring) (ring-empty-p isqlm-history-ring))
      (isqlm--output-info "History is empty.\n")
    (let ((len (ring-length isqlm-history-ring))
          (lines nil))
      (dotimes (i len)
        (push (format "  %3d  %s\n" (1+ i)
                      (ring-ref isqlm-history-ring (- len 1 i)))
              lines))
      (isqlm--output (apply #'concat (nreverse lines))))))

(defun isqlm/quit (&rest _args)
  "Quit ISQLM."
  (isqlm/exit))

(defun isqlm/exit (&rest _args)
  "Exit ISQLM — disconnect and kill the buffer.
Returns symbol `killed' so the caller knows not to touch the buffer."
  (when isqlm-connection
    (condition-case nil (mysql-close isqlm-connection) (error nil)))
  (isqlm--history-save)
  (let ((buf (current-buffer)))
    (quit-window)
    (kill-buffer buf))
  'killed)

;; ============================================================
;; Conditional flow (\if / \elif / \else / \endif)
;; ============================================================

(defun isqlm--cond-active-p ()
  "Return non-nil if the current conditional context is active.
When `isqlm-cond-stack' is empty, always active."
  (or (null isqlm-cond-stack)
      (plist-get (car isqlm-cond-stack) :active)))

(defun isqlm--cond-falsy-value-p (v)
  "Return non-nil if V is a \"falsy\" value for conditional checks.
Falsy: nil, 0, empty string, or strings \"0\"/\"false\"/\"no\"/\"nil\"/\"off\"."
  (or (null v)
      (eq v 0)
      (equal v 0.0)
      (and (stringp v)
           (member (downcase v) '("" "0" "false" "no" "nil" "off")))))

(defun isqlm--expand-expr-variables (expr)
  "Expand `:varname' references in EXPR string to variable values.
Replaces `:name' with the variable's value (as a Lisp literal) for
use in Elisp expressions.  Does not expand `::' (keyword symbols)."
  (replace-regexp-in-string
   ":\\([a-zA-Z_][a-zA-Z0-9_-]*\\)"
   (lambda (match)
     (let* ((name (match-string 1 match))
            (sym (intern-soft name)))
       (if (and sym (boundp sym))
           (let ((val (symbol-value sym)))
             (cond
              ((null val) "nil")
              ((stringp val) (format "%S" val))
              (t (format "%s" val))))
         match)))  ; leave unchanged if not bound
   expr t t))

(defun isqlm--cond-truthy-p (val)
  "Return non-nil if VAL is \"truthy\" for \\if/\\elif conditions.
VAL is a string from the command line.  Supported forms:
  :varname     — look up Emacs variable, check its value
  (elisp-expr) — evaluate, check result; :varname expanded inside
  literal      — check against falsy list"
  (cond
   ((null val) nil)
   ((string= val "") nil)
   ;; Elisp expression — expand :var references first
   ((string-prefix-p "(" val)
    (condition-case nil
        (let ((expanded (isqlm--expand-expr-variables val)))
          (not (isqlm--cond-falsy-value-p (eval (read expanded) t))))
      (error nil)))
   ;; Variable reference with :
   ((string-prefix-p ":" val)
    (let ((sym (intern-soft (substring val 1))))
      (and sym (boundp sym)
           (not (isqlm--cond-falsy-value-p (symbol-value sym))))))
   ;; Literal false values
   ((member (downcase val) '("0" "false" "no" "nil" "off")) nil)
   ;; Everything else is truthy
   (t t)))

(defun isqlm/if (&rest args)
  "Begin a conditional block.  ARGS: CONDITION.
CONDITION can be:
  - :varname     — true if variable is bound and non-nil
  - (elisp-expr) — true if expression evaluates to non-nil
  - literal      — true unless \"0\", \"false\", \"no\", \"nil\", \"\""
  (let* ((condition (string-join args " "))
         (result (isqlm--cond-truthy-p condition)))
    (push (list :satisfied result :active result) isqlm-cond-stack)))

(defun isqlm/elif (&rest args)
  "Add an elif branch to current \\if block.  ARGS: CONDITION."
  (if (not isqlm-cond-stack)
      (isqlm--output-error "\\elif without \\if\n")
    (let* ((frame (car isqlm-cond-stack))
           (already-satisfied (plist-get frame :satisfied))
           (condition (string-join args " "))
           (result (and (not already-satisfied)
                        (isqlm--cond-truthy-p condition))))
      (setcar isqlm-cond-stack
              (list :satisfied (or already-satisfied result)
                    :active result)))))

(defun isqlm/else (&rest _args)
  "Add an else branch to current \\if block."
  (if (not isqlm-cond-stack)
      (isqlm--output-error "\\else without \\if\n")
    (let* ((frame (car isqlm-cond-stack))
           (already-satisfied (plist-get frame :satisfied)))
      (setcar isqlm-cond-stack
              (list :satisfied t
                    :active (not already-satisfied))))))

(defun isqlm/endif (&rest _args)
  "End a conditional block."
  (if isqlm-cond-stack
      (pop isqlm-cond-stack)
    (isqlm--output-error "\\endif without \\if\n")))

(defun isqlm/echo (&rest args)
  "Output ARGS as text.  Supports :varname expansion."
  (let ((parts (mapcar (lambda (a)
                         (let ((expanded (isqlm--expand-arg a)))
                           (if (stringp expanded)
                               expanded
                             (format "%s" expanded))))
                       args)))
    (isqlm--output (concat (string-join parts " ") "\n"))))

(defun isqlm/gset (&rest args)
  "Store the last query result into Emacs variables (à la psql \\gset).
Usage: first run a SELECT, then \\gset [PREFIX].
The last query must have returned exactly one row."
  (let ((prefix (or (car args) "")))
    (cond
     ((not isqlm-last-result)
      (isqlm--output-error "No previous query result.  Run a SELECT first.\n"))
     ((/= (length (cdr isqlm-last-result)) 1)
      (isqlm--output-error
       (format "\\gset requires exactly 1 row, got %d.\n"
               (length (cdr isqlm-last-result)))))
     (t
      (let ((columns (car isqlm-last-result))
            (row (cadr isqlm-last-result)))
        (dotimes (i (length columns))
          (set (intern (concat prefix (nth i columns)))
               (nth i row))))))))

;; ============================================================
;; For loop (\for var in val1 val2 ... { body })
;; ============================================================

(defun isqlm--for-collecting-p ()
  "Return non-nil if we are currently collecting for-loop body lines."
  (and isqlm-for-stack (plist-get (car isqlm-for-stack) :brace)))

(defun isqlm--for-start (input)
  "Parse `\\for var in val1 val2 ...' and push a for-loop frame.
INPUT is the full line.  Supports three forms:
  \\for VAR in V1 V2 { body lines... }  — inline (single line)
  \\for VAR in V1 V2 {                  — brace on same line, body follows
  \\for VAR in V1 V2                    — brace expected on next line
Values can also be an Elisp expression: \\for i in (number-sequence 1 10) { ... }"
  (let* ((trimmed (string-trim input))
         (after-for (string-trim (substring trimmed (length "\\for"))))
         (brace-open (string-match "{" after-for))
         (brace-close (and brace-open (string-match "}[[:space:]]*$" after-for)))
         (header (string-trim (if brace-open
                                  (substring after-for 0 brace-open)
                                after-for)))
         (header-parts (isqlm--parse-command-line header))
         (var-name (nth 0 header-parts))
         (in-kw (nth 1 header-parts))
         (values-raw (nthcdr 2 header-parts)))
    (if (not (and var-name in-kw (string= (downcase in-kw) "in") values-raw))
        (isqlm--output-error "Usage: \\for VAR in VAL1 VAL2 ... { body }\n")
      ;; Resolve values
      (let* ((values-str (string-trim
                          (substring header
                                     (+ (length var-name) 1 (length in-kw) 1))))
             (values
              (if (string-prefix-p "(" values-str)
                  (condition-case err
                      (let ((result (eval (read values-str) t)))
                        (mapcar (lambda (v)
                                  (if (stringp v) v (format "%s" v)))
                                (if (listp result) result (list result))))
                    (error
                     (isqlm--output-error
                      (format "*** Eval Error in \\for values *** %s\n"
                              (isqlm--error-message err)))
                     nil))
                (mapcar (lambda (v)
                          (let ((expanded (isqlm--expand-arg v)))
                            (if (stringp expanded) expanded
                              (format "%s" expanded))))
                        values-raw))))
        (when values
          (cond
           ;; Inline: { body } all on one line
           ((and brace-open brace-close)
            (let* ((body-str (string-trim
                              (substring after-for (1+ brace-open)
                                         (match-beginning 0))))
                   (body-lines (split-string body-str ";" t "[ \t\n]+")))
              (setq body-lines
                    (mapcar (lambda (l)
                              (let ((s (string-trim l)))
                                (if (and (> (length s) 0)
                                         (not (string-prefix-p "\\" s))
                                         (not (string-suffix-p ";" s))
                                         (not (string-suffix-p "\\G" s)))
                                    (concat s ";")
                                  s)))
                            body-lines))
              (isqlm--for-execute-body (intern var-name) values body-lines)))
           ;; Brace on same line, body follows on subsequent lines
           (brace-open
            (push (list :var (intern var-name)
                        :values values
                        :body nil
                        :brace t
                        :depth 0)
                  isqlm-for-stack))
           ;; No brace yet, expect { on next line
           (t
            (push (list :var (intern var-name)
                        :values values
                        :body nil
                        :brace nil
                        :depth 0)
                  isqlm-for-stack))))))))
(defun isqlm--for-collect-line (input)
  "Collect INPUT as a body line for the current for-loop.
Handle nested { } and detect the closing }."
  (let* ((trimmed (string-trim input))
         (frame (car isqlm-for-stack)))
    (cond
     ;; Opening { on its own line (first line after \for without {)
     ((and (not (plist-get frame :brace))
           (string= trimmed "{"))
      (plist-put frame :brace t))
     ;; Not yet seen opening brace — error
     ((not (plist-get frame :brace))
      (isqlm--output-error "Expected `{' after \\for\n")
      (pop isqlm-for-stack))
     ;; Closing } at depth 0 — execute
     ((and (string= trimmed "}")
           (= (plist-get frame :depth) 0))
      (let ((var (plist-get frame :var))
            (values (plist-get frame :values))
            (body (nreverse (plist-get frame :body))))
        (pop isqlm-for-stack)
        (isqlm--for-execute-body var values body)))
     ;; Nested { — track depth
     ((string= trimmed "{")
      (plist-put frame :depth (1+ (plist-get frame :depth)))
      (plist-put frame :body (cons input (plist-get frame :body))))
     ;; Nested } — track depth
     ((string= trimmed "}")
      (plist-put frame :depth (1- (plist-get frame :depth)))
      (plist-put frame :body (cons input (plist-get frame :body))))
     ;; Normal body line
     (t
      (plist-put frame :body (cons input (plist-get frame :body)))))))

(defun isqlm--for-execute-body (var values body)
  "Execute BODY lines for each value in VALUES, binding VAR.
Each line is executed asynchronously via `isqlm--execute-line'."
  (isqlm--for-iterate var values body))

(defun isqlm--for-iterate (var values body)
  "Iterate: bind VAR to (car VALUES), run BODY lines, then recurse."
  (if (null values)
      nil  ; done
    (set var (car values))
    (isqlm--for-run-lines
     body var (cdr values) body)))

(defun isqlm--for-run-lines (lines var remaining-values all-body)
  "Run LINES one by one (async), then iterate to next value."
  (if (null lines)
      ;; This iteration done — proceed to next value
      (isqlm--for-iterate var remaining-values all-body)
    (isqlm--execute-line
     (car lines)
     (lambda ()
       (isqlm--for-run-lines
        (cdr lines) var remaining-values all-body)))))

(defconst isqlm--cond-flow-commands '("if" "elif" "else" "endif")
  "List of conditional flow command names.")

(defun isqlm--cond-flow-command-p (input)
  "Return non-nil if INPUT is a conditional flow command."
  (let* ((trimmed (string-trim input))
         (parts (split-string trimmed "[ \t]+" t))
         (first (car parts)))
    (and first
         (string-prefix-p "\\" first)
         (> (length first) 1)
         (member (downcase (substring first 1)) isqlm--cond-flow-commands))))

(defun isqlm--process-cond-flow (input)
  "Process a conditional flow command in INPUT.
Dispatches to isqlm/if, isqlm/elif, isqlm/else, or isqlm/endif.
When in an inactive branch, only \\if (to track nesting) and
\\endif/\\elif/\\else (to manage the stack) are fully processed."
  (let* ((trimmed (string-trim input))
         (parts (isqlm--parse-command-line trimmed))
         (first (car parts))
         (cmd (downcase (substring first 1)))
         (args (cdr parts)))
    (cond
     ;; \if — always push a new frame; if parent is inactive, push inactive
     ((string= cmd "if")
      (if (isqlm--cond-active-p)
          (isqlm/if (string-join args " "))
        ;; Nested \if in inactive branch: push unconditionally inactive frame
        (push (list :satisfied t :active nil) isqlm-cond-stack)))
     ;; \elif — only evaluate if in an active parent context
     ((string= cmd "elif")
      (when isqlm-cond-stack
        ;; Check if the *parent* (one level up) is active
        (let ((parent-active (or (null (cdr isqlm-cond-stack))
                                 (plist-get (cadr isqlm-cond-stack) :active))))
          (if parent-active
              (apply #'isqlm/elif args)
            ;; In inactive parent: keep current frame inactive
            nil))))
     ;; \else — same logic as \elif
     ((string= cmd "else")
      (when isqlm-cond-stack
        (let ((parent-active (or (null (cdr isqlm-cond-stack))
                                 (plist-get (cadr isqlm-cond-stack) :active))))
          (if parent-active
              (isqlm/else)
            nil))))
     ;; \endif — always pop
     ((string= cmd "endif")
      (isqlm/endif)))))

;; ============================================================
;; Command dispatch (eshell-style)
;; ============================================================

(defvar isqlm-command-aliases
  '(("?" . "help")
    ("h" . "help")
    ("q" . "quit")
    ("u" . "use")
    ("." . "i"))
  "Alist mapping command aliases to canonical command names.
E.g. \\? and \\h both map to \\help.")

(defun isqlm--try-numeric (str)
  "If STR looks like a number, return the number; otherwise return STR."
  (if (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]*\\)?\\'" str)
      (string-to-number str)
    str))

(defun isqlm--expand-arg (arg)
  "Expand ARG: if it starts with `:' treat as a variable reference.
`:varname' expands to the value of varname.  Otherwise return ARG
as-is (with numeric coercion)."
  (if (and (stringp arg) (string-prefix-p ":" arg) (> (length arg) 1))
      (let ((sym (intern-soft (substring arg 1))))
        (if (and sym (boundp sym))
            (symbol-value sym)
          (user-error "Void variable: %s" (substring arg 1))))
    (isqlm--try-numeric arg)))

(defun isqlm--parse-command-line (str)
  "Parse STR into a list of tokens, respecting double-quoted strings.
E.g. `\\message \"hello world\"' → (\"\\\\message\" \"hello world\")."
  (let ((i 0) (len (length str)) tokens current)
    (while (< i len)
      (let ((ch (aref str i)))
        (cond
         ;; Whitespace outside quotes: flush current token
         ((memq ch '(?\s ?\t))
          (when current
            (push (apply #'string (nreverse current)) tokens)
            (setq current nil)))
         ;; Double quote: read until closing quote
         ((= ch ?\")
          (cl-incf i)
          (while (and (< i len) (/= (aref str i) ?\"))
            (push (aref str i) current)
            (cl-incf i)))
         ;; Normal character
         (t (push ch current))))
      (cl-incf i))
    (when current
      (push (apply #'string (nreverse current)) tokens))
    (nreverse tokens)))

(defun isqlm--try-builtin-command (input)
  "Try to dispatch INPUT as a built-in command.
Built-in commands start with `\\'.  E.g. `\\connect', `\\help'.
Lookup order:
  1. isqlm/CMD (built-in isqlm command)
  2. CMD as an Emacs Lisp function (à la Eshell)
Return t if handled, `killed' if the buffer was killed,
nil if it should be treated as SQL."
  (let* ((trimmed (string-trim input))
         (parts (isqlm--parse-command-line trimmed))
         (first (car parts)))
    (when (and first (string-prefix-p "\\" first) (> (length first) 1))
      ;; Skip \G — it's a SQL terminator, not a command
      (unless (string= (upcase first) "\\G")
        (let* ((raw-cmd (downcase (substring first 1)))
               (cmd (or (cdr (assoc raw-cmd isqlm-command-aliases)) raw-cmd))
               ;; For \eval, pass the raw rest of the line (not tokenized)
               (args (if (string= cmd "eval")
                         (let ((rest (string-trim
                                      (substring trimmed (length first)))))
                           (and (> (length rest) 0) (list rest)))
                       (cdr parts)))
               (isqlm-func (intern-soft (concat "isqlm/" cmd)))
               (elisp-func (intern-soft cmd)))
          (cond
           ;; 1. isqlm built-in command
           ((and isqlm-func (fboundp isqlm-func))
            (let* ((expanded-args (mapcar #'isqlm--expand-arg args))
                   ;; isqlm commands expect string args, convert back
                   (str-args (mapcar (lambda (a)
                                       (if (stringp a) a (format "%s" a)))
                                     expanded-args))
                   (ret (apply isqlm-func str-args)))
              (if (eq ret 'killed) 'killed t)))
           ;; 2. Emacs Lisp function (interactive or not)
           ((and elisp-func (fboundp elisp-func))
            (condition-case err
                (let* ((expanded-args
                        (if (eq elisp-func 'setq)
                            ;; setq is a special form; use `set' instead
                            (if (< (length args) 2)
                                (user-error "Usage: \\setq VARIABLE VALUE")
                              (let ((val (isqlm--expand-arg (nth 1 args))))
                                (set (intern (car args)) val)
                                (when val
                                  (isqlm--output
                                   (concat (if (stringp val) val (pp-to-string val))
                                           "\n")))
                                nil))  ; nil so the outer `when result' is skipped
                          (mapcar #'isqlm--expand-arg args)))
                       (result (and expanded-args
                                    (apply elisp-func expanded-args))))
                  (when result
                    (isqlm--output
                     (concat (if (stringp result)
                                 result
                               (pp-to-string result))
                             "\n"))))
              (error
               (isqlm--output-error
                (format "*** Lisp Error *** %s\n" (isqlm--error-message err)))))
            t)
           ;; 3. Unknown
           (t
            (isqlm--output-error
             (format "Unknown command: %s.  Type \\help for help.\n" first))
            t)))))))

;; ============================================================
;; Input handling (eshell-style: read from buffer, no process)
;; ============================================================

(defun isqlm-send-input ()
  "Read current input and execute it.
If point is in the history area (before the current prompt), copy
the current line to the input area and execute it — similar to
Eshell and sql-mode behavior.
If the input is a built-in command, dispatch it.
If it is SQL and complete (ends with `;' or `\\G'), execute it.
Otherwise, insert a continuation prompt for multi-line input."
  (interactive)
  ;; Block input while async query is running
  (if isqlm--async-busy
      (message "Query in progress... (C-c C-c to cancel)")
  ;; Normal input handling
  (progn
  ;; If point is before the current input area, grab the line and
  ;; copy it to the input area, then execute from there.
  (when (< (point) (marker-position isqlm-last-output-end))
    (let ((line (string-trim (buffer-substring-no-properties
                              (line-beginning-position)
                              (line-end-position)))))
      ;; Strip any prompt prefix that may be on the line
      (when (string-prefix-p isqlm-prompt-internal line)
        (setq line (substring line (length isqlm-prompt-internal))))
      (when (string-prefix-p isqlm-prompt-continue line)
        (setq line (substring line (length isqlm-prompt-continue))))
      (setq line (string-trim line))
      (when (> (length line) 0)
        ;; Replace current input with the grabbed line
        (isqlm--replace-current-input line)
        (goto-char (point-max)))))
  ;; Now proceed with normal input handling
  (let ((isqlm-buf (current-buffer))
        (input (buffer-substring-no-properties
                isqlm-last-output-end (point-max))))
    ;; Record input markers
    (set-marker isqlm-last-input-start (marker-position isqlm-last-output-end))
    (set-marker isqlm-last-input-end (point-max))
    ;; Move past input (insert newline to "submit" it)
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert "\n")
      ;; Make the submitted input read-only
      (add-text-properties isqlm-last-input-start (point)
                           '(read-only t rear-nonsticky t field input)))
    ;; Update output-end to current position
    (set-marker isqlm-last-output-end (point))
    ;; Reset history navigation
    (setq isqlm-history-index nil)
    (setq isqlm-input-saved nil)
    ;; Build accumulated input
    (let ((accumulated (concat isqlm-pending-input
                               (if (string= isqlm-pending-input "") "" "\n")
                               input)))
      (cond
       ;; Empty input
       ((string= (string-trim accumulated) "")
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; Collecting for-loop body lines
       ((isqlm--for-collecting-p)
        (isqlm--for-collect-line accumulated)
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; \for — start a new for-loop (may have { on same line)
       ((and (string= isqlm-pending-input "")
             (let ((first (car (split-string (string-trim accumulated) "[ \t]+" t))))
               (and first (string-prefix-p "\\" first)
                    (string= (downcase (substring first 1)) "for"))))
        (isqlm--for-start accumulated)
        (isqlm--add-to-history accumulated)
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; Waiting for opening { of a for-loop
       ((and isqlm-for-stack (not (plist-get (car isqlm-for-stack) :brace)))
        (isqlm--for-collect-line accumulated)
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; Conditional flow commands — always processed, even in inactive branches
       ((and (string= isqlm-pending-input "")
             (isqlm--cond-flow-command-p accumulated))
        (isqlm--process-cond-flow accumulated)
        (isqlm--add-to-history accumulated)
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; In inactive conditional branch — skip everything else
       ((not (isqlm--cond-active-p))
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; If no pending input, try builtin command first
       ((and (string= isqlm-pending-input "")
             (isqlm--try-builtin-command accumulated))
        (when (buffer-live-p isqlm-buf)
          (with-current-buffer isqlm-buf
            (isqlm--add-to-history accumulated)
            (setq isqlm-pending-input "")
            (isqlm--emit-prompt))))

       ;; Incomplete SQL (no terminator yet)
       ((not (isqlm--sql-complete-p accumulated))
        (setq isqlm-pending-input accumulated)
        (isqlm--emit-prompt))

       ;; Complete SQL — execute (possibly multiple statements)
       (t
        (isqlm--add-to-history accumulated)
        (setq isqlm-pending-input "")
        (let ((statements (isqlm--split-statements accumulated)))
          (setq isqlm--async-busy t)
          (isqlm--async-execute-statements statements isqlm-buf)))))))))

;; ============================================================
;; Interactive commands (for keybindings / M-x)
;; ============================================================

(defun isqlm-connect (&optional host user database port)
  "Connect to MySQL interactively or from Lisp.
When called interactively:
  - If `sql-connection-alist' is non-empty, prompt for a connection name
    (like `isqlm-sql-connect').
  - Otherwise, use default parameters.
Ensures an ISQLM buffer exists before connecting.
PASSWORD is prompted via echo area when `isqlm-prompt-password' is non-nil."
  (interactive)
  (if (and (called-interactively-p 'any)
           (boundp 'sql-connection-alist)
           sql-connection-alist)
      ;; Prompt for connection name
      (let ((name (completing-read "Connection: "
                                   (mapcar #'car sql-connection-alist) nil t)))
        (isqlm-sql-connect name))
    ;; Positional args or defaults
    (unless (derived-mode-p 'isqlm-mode)
      (isqlm))
    (let ((args nil))
      (when port (push (number-to-string port) args))
      (when database (push database args))
      (when user (push user args))
      (when host (push host args))
      (apply #'isqlm/connect args))))

(defun isqlm-disconnect ()
  "Disconnect from MySQL."
  (interactive)
  (isqlm/disconnect)
  (isqlm--emit-prompt))

(defun isqlm-reconnect ()
  "Reconnect to MySQL."
  (interactive)
  (isqlm/reconnect)
  (isqlm--emit-prompt))

(defun isqlm-clear-buffer ()
  "Clear the ISQLM buffer."
  (interactive)
  (isqlm/clear)
  (isqlm--emit-prompt))

(defun isqlm-interrupt ()
  "Abort the current (possibly multi-line) input and show a fresh prompt.
If an async query is in progress, cancel it."
  (interactive)
  ;; Cancel any async query
  (when isqlm--async-busy
    (isqlm--async-cancel)
    (isqlm--output-error "Query cancelled.\n"))
  ;; Discard any pending multi-line input
  (setq isqlm-pending-input "")
  ;; Make the current input line read-only so it stays visible as context
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert "\n")
    (add-text-properties isqlm-last-output-end (point)
                         '(read-only t rear-nonsticky t field input))
    (set-marker isqlm-last-output-end (point)))
  ;; Reset history navigation
  (setq isqlm-history-index nil)
  (setq isqlm-input-saved nil)
  ;; Show fresh prompt
  (isqlm--emit-prompt))

(defun isqlm-show-databases ()
  "Execute SHOW DATABASES."
  (interactive)
  (isqlm--quick-sql "SHOW DATABASES;"))

(defun isqlm-show-tables ()
  "Execute SHOW TABLES."
  (interactive)
  (isqlm--quick-sql "SHOW TABLES;"))

(defun isqlm-describe-table (table)
  "Execute DESCRIBE TABLE."
  (interactive "sTable name: ")
  (isqlm--quick-sql (format "DESCRIBE `%s`;" table)))

(defun isqlm--quick-sql (sql)
  "Execute SQL directly via the async path, showing the command and result."
  (unless (isqlm--connected-p)
    (user-error "Not connected to MySQL"))
  (isqlm--output (concat sql "\n"))
  (setq isqlm--async-busy t)
  (isqlm--async-execute-statements
   (isqlm--split-statements sql) (current-buffer)))

;; ============================================================
;; Send from external buffers (à la sql-send-string)
;; ============================================================

(defvar isqlm-buffer nil
  "The ISQLM buffer to send SQL to.
Set this to direct `isqlm-send-string', `isqlm-send-region', etc.
to a specific ISQLM session.  Can also be set buffer-locally.")

(defun isqlm--target-buffer ()
  "Return the ISQLM buffer to send SQL to.
Check `isqlm-buffer' (buffer-local), then fall back to any live
`*isqlm*' buffer."
  (or (and isqlm-buffer
           (get-buffer isqlm-buffer)
           (buffer-live-p (get-buffer isqlm-buffer))
           (get-buffer isqlm-buffer))
      (let ((buf (get-buffer "*isqlm*")))
        (and buf (buffer-live-p buf) buf))
      (user-error "No ISQLM buffer found.  Start one with M-x isqlm")))

(defun isqlm-send-string (str)
  "Send STR as SQL to the ISQLM process buffer and display the result.
The target buffer is determined by `isqlm-buffer' or defaults to `*isqlm*'.
If STR does not end with `;' or `\\G', a `;' is appended automatically."
  (interactive "sSQL: ")
  (let* ((s (string-trim str))
         (buf (isqlm--target-buffer)))
    (when (string= s "")
      (user-error "Empty SQL string"))
    ;; Auto-append terminator if missing
    (unless (or (string-suffix-p ";" s)
                (string-suffix-p "\\G" s))
      (setq s (concat s ";")))
    (with-current-buffer buf
      (unless (isqlm--connected-p)
        (user-error "ISQLM buffer %s is not connected" (buffer-name buf)))
      (isqlm--quick-sql s))
    ;; Display the ISQLM buffer
    (display-buffer buf)))

(defun isqlm-send-region (start end)
  "Send the region between START and END to the ISQLM process buffer."
  (interactive "r")
  (isqlm-send-string (buffer-substring-no-properties start end)))

(defun isqlm-send-paragraph ()
  "Send the current paragraph to the ISQLM process buffer."
  (interactive)
  (let ((start (save-excursion (backward-paragraph) (point)))
        (end   (save-excursion (forward-paragraph) (point))))
    (isqlm-send-string (buffer-substring-no-properties start end))))

(defun isqlm-send-buffer ()
  "Send the entire buffer to the ISQLM process buffer."
  (interactive)
  (isqlm-send-string (buffer-substring-no-properties (point-min) (point-max))))

;; ============================================================
;; Execute SQL and display in a separate buffer
;; ============================================================

(defun isqlm-execute (sql &optional buf-name)
  "Execute SQL and display the result in a separate buffer.
BUF-NAME defaults to \"*isqlm-output*\".  The buffer uses `special-mode'
so that `q' dismisses it.

For SELECT results, the output is formatted as a table (or vertical
if SQL ends with `\\G').  For DML, the affected-rows summary is shown.

Returns the result plist from `isqlm-execute-string', so callers can
further process the data or post-process the output buffer.

This function must be called from an ISQLM buffer (or with the
ISQLM buffer current) so that `isqlm-execute-string' can find
the connection."
  (interactive "sSQL: ")
  (let* ((result (isqlm-execute-string sql))
         (parsed (isqlm--strip-terminator sql))
         (mode (cdr parsed))
         (text (isqlm--format-result-string result mode))
         (buf (get-buffer-create (or buf-name "*isqlm-output*"))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min)))
      (special-mode))
    (display-buffer buf)
    result))

;; ============================================================
;; Major mode (eshell-style: derived from fundamental-mode)
;; ============================================================

(define-derived-mode isqlm-mode fundamental-mode "ISQLM"
  "Major mode for interactively executing MySQL SQL statements.
No external processes — buffer, markers, prompt, and I/O are
managed directly, in the style of Eshell.

\\<isqlm-mode-map>
\\[isqlm-send-input] sends current input for execution.
SQL statements must end with `;' or `\\\\G'.
\\[newline] (M-RET) inserts a literal newline for multi-line input.

\\[isqlm-connect] connects to a MySQL server.
\\[isqlm-disconnect] disconnects.
\\[isqlm-reconnect] reconnects with last parameters.

\\[isqlm-previous-input] / \\[isqlm-next-input] navigate history.
\\[isqlm-clear-buffer] clears the buffer.
\\[isqlm-show-databases] / \\[isqlm-show-tables] / \\[isqlm-describe-table] for quick info.

Type `\\help' at the prompt for built-in commands.

\\{isqlm-mode-map}"
  :group 'isqlm
  ;; Prompt
  (setq isqlm-prompt-internal (or isqlm-prompt "SQL> "))
  (setq isqlm-pending-input "")
  (setq mode-line-process '(" [disconnected]"))
  (setq truncate-lines t)
  ;; Markers
  (setq isqlm-last-input-start  (point-min-marker))
  (setq isqlm-last-input-end    (point-min-marker))
  (setq isqlm-last-output-start (point-min-marker))
  (setq isqlm-last-output-end   (point-min-marker))
  ;; Font-lock (case-insensitive)
  (setq-local font-lock-defaults '(isqlm-font-lock-keywords nil t))
  ;; History
  (isqlm--history-init)
  ;; Kill buffer hook
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when isqlm-connection
                (condition-case nil (mysql-close isqlm-connection) (error nil)))
              (isqlm--history-save))
            nil t)
  ;; Save history on Emacs exit
  (let ((buf (current-buffer)))
    (add-hook 'kill-emacs-hook
              (lambda ()
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (isqlm--history-save))))))
  ;; Welcome header
  (let ((inhibit-read-only t))
    (insert (substitute-command-keys
             "*** Welcome to ISQLM — Interactive SQL Mode for MySQL ***\n\
Type \\[describe-mode] for help.\n\
Use `\\=\\connect' or \\[isqlm-connect] to connect.\n\
SQL statements must end with `;' or `\\=\\G'.  Press RET to execute.\n\
Type `\\=\\help' for built-in commands.\n\
Query mode: async (non-blocking)\n\n"))
    (add-text-properties (point-min) (point)
                         '(read-only t rear-nonsticky t field output
                           inhibit-line-move-field-capture t))
    (set-marker isqlm-last-output-end (point)))
  ;; Emit initial prompt
  (isqlm--emit-prompt))

;; ============================================================
;; Entry point
;; ============================================================

;;;###autoload
(defun isqlm (&optional buf-name)
  "Start an interactive SQL session for MySQL.
Switches to buffer BUF-NAME (`*isqlm*' by default) or creates it."
  (interactive)
  (isqlm--ensure-module)
  (let* ((buf-name (or buf-name "*isqlm*"))
         (buf (get-buffer buf-name)))
    (unless (and buf (buffer-live-p buf))
      (setq buf (get-buffer-create buf-name))
      (with-current-buffer buf
        (isqlm-mode)))
    (setq isqlm-buffer buf)
    (pop-to-buffer-same-window buf)))

;;;###autoload
(defun isqlm-connect-and-run (&optional host user database port)
  "Start ISQLM and immediately connect."
  (interactive)
  (isqlm)
  (isqlm-connect host user database port))

;;;###autoload
(defun isqlm-sql-connect (connection)
  "Start ISQLM and connect using CONNECTION from `sql-connection-alist'.
When called interactively, prompt with completion for the connection name."
  (interactive
   (list
    (let ((names (and (boundp 'sql-connection-alist)
                      (mapcar #'car sql-connection-alist))))
      (unless names
        (user-error "sql-connection-alist is empty or not defined"))
      (completing-read "Connection: " names nil t))))
  (isqlm (format "*isqlm:%s*" connection))
  (unless (isqlm--connected-p)
    (isqlm/connect connection)
    (isqlm--emit-prompt)))

(provide 'isqlm)

;;; isqlm.el ends here
