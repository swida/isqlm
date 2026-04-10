;;; isqlm.el --- Interactive SQL Mode for MySQL  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Hadley Wang
;; Keywords: sql, mysql, database
;; Version: 2.0

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

(defcustom isqlm-max-column-width 0
  "Maximum column width in result tables.
0 means no artificial limit — columns will be as wide as needed,
up to the current window width minus table borders."
  :type 'integer :group 'isqlm)

(defcustom isqlm-table-style 'ascii
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

(defun isqlm--error-message (err)
  "Extract a human-readable error message from ERR.
ERR is the value bound by `condition-case'.  mysql-el signals errors
as (error . \"message-string\") where the cdr is a plain string rather
than the usual (format-string . args) list, which causes
`error-message-string' to return \"peculiar error\".  This function
handles both formats."
  (let ((data (cdr err)))
    (cond
     ((stringp data) data)
     ((and (consp data) (stringp (car data)))
      (apply #'format (car data) (cdr data)))
     (t (error-message-string err)))))

;; ============================================================
;; Connection helpers
;; ============================================================

(defun isqlm--connected-p ()
  "Return non-nil if this buffer has a live MySQL connection."
  (and isqlm-connection
       (condition-case nil (mysqlp isqlm-connection) (error nil))))

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
  "Return non-nil if SQL is a complete statement (ends with `;' or `\\G')."
  (let ((trimmed (string-trim-right sql)))
    (or (string-suffix-p ";" trimmed)
        (string-suffix-p "\\G" trimmed)
        (string= trimmed ""))))

(defun isqlm--strip-terminator (sql)
  "Remove trailing `;'/`\\G' from SQL.  Return (BODY . VERTICAL-P)."
  (let ((trimmed (string-trim-right sql)))
    (cond
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
           ;; :varname — expand if followed by word chars
           ((and (= ch ?:)
                 (< (1+ i) len)
                 (let ((nc (aref sql (1+ i))))
                   (or (and (>= nc ?a) (<= nc ?z))
                       (and (>= nc ?A) (<= nc ?Z))
                       (= nc ?_))))
            (let ((start (1+ i))
                  (j (1+ i)))
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
                            (user-error "Void variable in SQL: :%s" name)))
                     (replacement
                      (cond
                       ((null val) "NULL")
                       ((integerp val) (number-to-string val))
                       ((floatp val) (format "%g" val))
                       ((stringp val)
                        (concat "'" (replace-regexp-in-string "'" "''" val) "'"))
                       (t (concat "'"
                                  (replace-regexp-in-string
                                   "'" "''" (format "%s" val))
                                  "'")))))
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
           ;; \G terminator
           ((and (= ch ?\\) (< (1+ i) len)
                 (memq (aref sql (1+ i)) '(?G ?g)))
            (let ((stmt (string-trim (substring sql start (+ i 2)))))
              (when (> (length stmt) 0)
                (push stmt statements)))
            (cl-incf i)
            (setq start (1+ i)))
           ;; ; terminator
           ((= ch ?\;)
            (let ((stmt (string-trim (substring sql start (1+ i)))))
              (when (> (length stmt) 0)
                (push stmt statements)))
            (setq start (1+ i)))))))
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
    ;; Apply max-column-width limit (0 = no limit, use window width as fallback)
    (let ((effective-max (if (and isqlm-max-column-width
                                 (> isqlm-max-column-width 0))
                            isqlm-max-column-width
                          (max 20 (- (window-width) (* ncols 3) 2)))))
      (dotimes (i ncols)
        (setf (nth i widths)
              (min effective-max (nth i widths)))))
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
  "Execute SQL and return formatted output string."
  (unless (isqlm--connected-p)
    (error "Not connected.  Use `\\connect' or M-x isqlm-connect"))
  (let* ((parsed (isqlm--strip-terminator sql))
         (query (car parsed))
         (vertical (cdr parsed))
         (upper (upcase (string-trim-left query))))
    (when (string= query "")
      (error "Empty query"))
    (cond
     ;; SELECT-like queries
     ((or (string-prefix-p "SELECT" upper)
          (string-prefix-p "SHOW" upper)
          (string-prefix-p "DESCRIBE" upper)
          (string-prefix-p "DESC " upper)
          (string-prefix-p "EXPLAIN" upper))
      (let ((result (mysql-select isqlm-connection query nil 'full)))
        (if (null result)
            (propertize "Empty set (0 rows)\n" 'font-lock-face 'isqlm-info-face)
          (let* ((columns (car result))
                 (rows (cdr result))
                 (nrows (length rows))
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
                  (format "%d rows in set (truncated from %d)\n" (length rows) nrows)
                (format "%d %s in set\n" nrows (if (= nrows 1) "row" "rows")))
              'font-lock-face 'isqlm-info-face))))))
     ;; USE
     ((string-prefix-p "USE" upper)
      (mysql-execute isqlm-connection query)
      (let ((db-name (string-trim
                      (replace-regexp-in-string "\\`USE\\s-+" "" query))))
        (setq db-name (replace-regexp-in-string "[`'\"]" "" db-name))
        (plist-put isqlm-connection-info :database db-name)
        (setq mode-line-process
              (list (format " [%s]" (isqlm--format-connection-info))))
        (force-mode-line-update)
        (propertize (format "Database changed to: %s\n" db-name)
                    'font-lock-face 'isqlm-info-face)))
     ;; DML/DDL
     (t
      (let ((affected (mysql-execute isqlm-connection query)))
        (propertize
         (if (integerp affected)
             (format "Query OK, %d %s affected\n"
                     affected (if (= affected 1) "row" "rows"))
           "Query OK\n")
         'font-lock-face 'isqlm-info-face))))))

;; ============================================================
;; Custom commands (\NAME dispatched to isqlm/NAME functions)
;; ============================================================

(defun isqlm/help (&rest _args)
  "Display available ISQLM commands."
  (isqlm--output-info
   (concat
    "Built-in commands (prefixed with \\):\n"
    "  \\connect [NAME | HOST USER PASS DB PORT]     — Connect to MySQL\n"
    "  \\connections                                 — List sql-connection-alist\n"
    "  \\disconnect                                 — Disconnect\n"
    "  \\reconnect                                  — Reconnect with last params\n"
    "  \\use DATABASE                               — Switch database\n"
    "  \\status                                     — Show connection status\n"
    "  \\style [ascii|unicode]                       — Toggle/set table style\n"
    "  \\clear                                      — Clear buffer\n"
    "  \\history                                    — Show input history\n"
    "  \\echo TEXT...                                — Output text\n"
    "  \\if CONDITION                                — Begin conditional block\n"
    "  \\elif CONDITION                              — Else-if branch\n"
    "  \\else                                        — Else branch\n"
    "  \\endif                                       — End conditional block\n"
    "  \\for VAR in V1 V2 ... { body }               — Loop over values\n"
    "  \\help                                       — Show this help\n"
    "  \\quit / \\exit                               — Kill ISQLM buffer\n"
    "\n"
    "Aliases: \\? = \\h = \\help, \\q = \\quit, \\u = \\use\n"
    "\n"
    "Or type any SQL statement ending with `;' or `\\G'.\n"
    "Press M-RET for a literal newline (multi-line input).\n"
    "\n"
    "\\CMD also works for Emacs Lisp functions, e.g. \\message hello\n"
    "Use :varname to reference Emacs variables, e.g. \\message :user-login-name\n"
    "Use \\setq to set variables, e.g. \\setq myvar \"hello world\"\n"
    "Use \\eval to run Elisp, e.g. \\eval (+ 1 2)\n")))

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
  \\connect HOST USER PASS DB PORT — connect with explicit parameters
  \\connect                   — prompt for all parameters interactively"
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
                            (read-passwd "Password: ")))
              (database (plist-get conn-info :database))
              (port     (plist-get conn-info :port)))
          (condition-case err
              (progn
                (setq isqlm-connection
                      (mysql-open host user password
                                  (if (string= database "") nil database) port))
                (setq isqlm-connection-info
                      (list :host host :port port :user user
                            :password password :database database))
                (setq mode-line-process
                      (list (format " [%s]" (isqlm--format-connection-info))))
                (force-mode-line-update)
                (let ((ver (condition-case nil (mysql-version) (error "unknown"))))
                  (isqlm--output-info
                   (format "Connected to %s (MySQL client library: %s)\n"
                           (isqlm--format-connection-info) ver)))
                (setq isqlm-pending-input ""))
            (error
             (isqlm--output-error
              (format "*** Connection Error *** %s\n" (isqlm--error-message err))))))
      ;; Connect with explicit args or prompts
      (let* ((host     (or (nth 0 args) (read-string (format "Host (default %s): " isqlm-default-host) nil nil isqlm-default-host)))
             (user     (or (nth 1 args) (read-string (format "User (default %s): " isqlm-default-user) nil nil isqlm-default-user)))
             (password (or (nth 2 args) (read-passwd "Password: ")))
             (database (or (nth 3 args) (read-string (format "Database (default %s): " isqlm-default-database) nil nil isqlm-default-database)))
             (port     (or (and (nth 4 args) (string-to-number (nth 4 args)))
                           (read-number "Port: " isqlm-default-port))))
        (condition-case err
            (progn
              (setq isqlm-connection
                    (mysql-open host user password
                                (if (string= database "") nil database) port))
              (setq isqlm-connection-info
                    (list :host host :port port :user user
                          :password password :database database))
              (setq mode-line-process
                    (list (format " [%s]" (isqlm--format-connection-info))))
              (force-mode-line-update)
              (let ((ver (condition-case nil (mysql-version) (error "unknown"))))
                (isqlm--output-info
                 (format "Connected to %s (MySQL client library: %s)\n"
                         (isqlm--format-connection-info) ver)))
              (setq isqlm-pending-input ""))
          (error
           (isqlm--output-error
            (format "*** Connection Error *** %s\n" (isqlm--error-message err)))))))))

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
      (isqlm/connect (plist-get info :host)
                     (plist-get info :user)
                     (plist-get info :password)
                     (plist-get info :database)
                     (number-to-string (plist-get info :port))))))

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
         (isqlm--output-error
          (format "*** Error *** %s\n" (isqlm--error-message err)))))))))

(defun isqlm/status (&rest _args)
  "Show connection status."
  (if (isqlm--connected-p)
      (isqlm--output-info
       (format "Connected: %s\n" (isqlm--format-connection-info)))
    (isqlm--output-info "Not connected.\n")))

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

(defun isqlm--cond-truthy-p (val)
  "Return non-nil if VAL is \"truthy\" for \\if/\\elif conditions.
VAL is a string from the command line.  Supported forms:
  :varname     — look up Emacs variable, check its value
  (elisp-expr) — evaluate, check result
  literal      — check against falsy list"
  (cond
   ((null val) nil)
   ((string= val "") nil)
   ;; Elisp expression
   ((string-prefix-p "(" val)
    (condition-case nil
        (not (isqlm--cond-falsy-value-p (eval (read val) t)))
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
Each line is processed as if typed at the prompt."
  (dolist (val values)
    (set var val)
    (dolist (line body)
      (let ((trimmed (string-trim line)))
        (when (> (length trimmed) 0)
          (cond
           ;; Built-in command
           ((string-prefix-p "\\" trimmed)
            (isqlm--try-builtin-command trimmed))
           ;; SQL (may need terminator)
           ((isqlm--sql-complete-p trimmed)
            (let ((statements (isqlm--split-statements trimmed)))
              (dolist (stmt statements)
                (condition-case err
                    (let* ((expanded (isqlm--expand-sql-variables stmt))
                           (result (isqlm--execute-sql expanded)))
                      (isqlm--output result))
                  (error
                   (when isqlm-noisy (ding))
                   (isqlm--output-error
                    (format "*** Error *** %s\n"
                            (isqlm--error-message err))))))))
           ;; Incomplete SQL — just output warning
           (t
            (isqlm--output-error
             (format "Incomplete statement in \\for body: %s\n" trimmed)))))))))

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
    ("u" . "use"))
  "Alist mapping command aliases to canonical command names.
E.g. \\? and \\h both map to \\help.")

(defun isqlm--try-numeric (str)
  "If STR looks like a number, return the number; otherwise return STR."
  (if (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]*\\)?\\'" str)
      (string-to-number str)
    str))

(defun isqlm--expand-arg (arg)
  "Expand ARG: if it starts with `:' treat it as an Emacs variable reference.
`:varname' → value of varname.  Otherwise return ARG as-is (with numeric coercion)."
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
          (isqlm--add-to-history accumulated)
          (setq isqlm-pending-input "")
          (isqlm--emit-prompt)))

       ;; Incomplete SQL (no terminator yet)
       ((not (isqlm--sql-complete-p accumulated))
        (setq isqlm-pending-input accumulated)
        (isqlm--emit-prompt))

       ;; Complete SQL — execute (possibly multiple statements)
       (t
        (isqlm--add-to-history accumulated)
        (setq isqlm-pending-input "")
        (let ((statements (isqlm--split-statements accumulated)))
          (dolist (stmt statements)
            (condition-case err
                (let* ((expanded (isqlm--expand-sql-variables stmt))
                       (result (isqlm--execute-sql expanded)))
                  (isqlm--output result))
              (error
               (when isqlm-noisy (ding))
               (isqlm--output-error
                (format "*** Error *** %s\n" (isqlm--error-message err)))))))
        (isqlm--emit-prompt))))))

;; ============================================================
;; Interactive commands (for keybindings / M-x)
;; ============================================================

(defun isqlm-connect (&optional host user password database port)
  "Connect to MySQL interactively or from Lisp."
  (interactive)
  (isqlm/connect host user password database
                 (and port (number-to-string port))))

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
  "Abort the current (possibly multi-line) input and show a fresh prompt."
  (interactive)
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
  "Execute SQL directly, showing both the command and result."
  (unless (isqlm--connected-p)
    (user-error "Not connected to MySQL"))
  (isqlm--output (concat sql "\n"))
  (condition-case err
      (isqlm--output (isqlm--execute-sql sql))
    (error
     (isqlm--output-error
      (format "*** Error *** %s\n" (isqlm--error-message err)))))
  (isqlm--emit-prompt))

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
Use `\\\\connect' or \\[isqlm-connect] to connect.\n\
SQL statements must end with `;' or `\\\\G'.  Press RET to execute.\n\
Type `\\\\help' for built-in commands.\n\n"))
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
(defun isqlm-connect-and-run (&optional host user password database port)
  "Start ISQLM and immediately connect."
  (interactive)
  (isqlm)
  (isqlm-connect host user password database port))

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
