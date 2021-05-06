;;; parsebib.el --- A library for parsing bib files  -*- lexical-binding: t -*-

;; Copyright (c) 2014-2017 Joost Kremers
;; All rights reserved.

;; Author: Joost Kremers <joostkremers@fastmail.fm>
;; Maintainer: Joost Kremers <joostkremers@fastmail.fm>
;; Created: 2014
;; Version: 2.4
;; Keywords: text bibtex
;; URL: https://github.com/joostkremers/parsebib
;; Package-Requires: ((emacs "25.1"))

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;;
;; 1. Redistributions of source code must retain the above copyright
;;    notice, this list of conditions and the following disclaimer.
;; 2. Redistributions in binary form must reproduce the above copyright
;;    notice, this list of conditions and the following disclaimer in the
;;    documentation and/or other materials provided with the distribution.
;; 3. The name of the author may not be used to endorse or promote products
;;    derived from this software without specific prior written permission.
;;
;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
;; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
;; OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
;; IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
;; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
;; NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES ; LOSS OF USE,
;; DATA, OR PROFITS ; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
;; THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;;; Commentary:

;;

;;; Code:

(require 'bibtex)
(require 'cl-lib)
(eval-when-compile (require 'subr-x)) ; for `string-join'.
(eval-and-compile (unless (fboundp 'json-parse-buffer)
                    (require 'json)
                    (defvar json-object-type)))

(defvar parsebib-hashid-fields nil
  "List of fields used to create a hash id for each entry.
The hash id is stored in the entry in the special field `=hashid='.")

(defvar parsebib--biblatex-inheritances '(("all"
					   "all"
					   (("ids" . none)
					    ("crossref" . none)
					    ("xref" . none)
					    ("entryset" . none)
					    ("entrysubtype" . none)
					    ("execute" . none)
					    ("label" . none)
					    ("options" . none)
					    ("presort" . none)
					    ("related" . none)
					    ("relatedoptions" . none)
					    ("relatedstring" . none)
					    ("relatedtype" . none)
					    ("shorthand" . none)
					    ("shorthandintro" . none)
					    ("sortkey" . none)))

					  ("mvbook, book"
					   "inbook, bookinbook, suppbook"
					   (("author" . "author")
					    ("author" . "bookauthor")))

					  ("mvbook"
					   "book, inbook, bookinbook, suppbook"
					   (("title" . "maintitle")
					    ("subtitle" . "mainsubtitle")
					    ("titleaddon" . "maintitleaddon")
					    ("shorttitle" . none)
					    ("sorttitle" . none)
					    ("indextitle" . none)
					    ("indexsorttitle" . none)))

					  ("mvcollection, mvreference"
					   "collection, reference, incollection, inreference, suppcollection"
					   (("title" . "maintitle")
					    ("subtitle" . "mainsubtitle")
					    ("titleaddon" . "maintitleaddon")
					    ("shorttitle" . none)
					    ("sorttitle" . none)
					    ("indextitle" . none)
					    ("indexsorttitle" . none)))

					  ("mvproceedings"
					   "proceedings, inproceedings"
					   (("title" . "maintitle")
					    ("subtitle" . "mainsubtitle")
					    ("titleaddon" . "maintitleaddon")
					    ("shorttitle" . none)
					    ("sorttitle" . none)
					    ("indextitle" . none)
					    ("indexsorttitle" . none)))

					  ("book"
					   "inbook, bookinbook, suppbook"
					   (("title" . "booktitle")
					    ("subtitle" . "booksubtitle")
					    ("titleaddon" . "booktitleaddon")
					    ("shorttitle" . none)
					    ("sorttitle" . none)
					    ("indextitle" . none)
					    ("indexsorttitle" . none)))

					  ("collection, reference"
					   "incollection, inreference, suppcollection"
					   (("title" . "booktitle")
					    ("subtitle" . "booksubtitle")
					    ("titleaddon" . "booktitleaddon")
					    ("shorttitle" . none)
					    ("sorttitle" . none)
					    ("indextitle" . none)
					    ("indexsorttitle" . none)))

					  ("proceedings"
					   "inproceedings"
					   (("title" . "booktitle")
					    ("subtitle" . "booksubtitle")
					    ("titleaddon" . "booktitleaddon")
					    ("shorttitle" . none)
					    ("sorttitle" . none)
					    ("indextitle" . none)
					    ("indexsorttitle" . none)))

					  ("periodical"
					   "article, suppperiodical"
					   (("title" . "journaltitle")
					    ("subtitle" . "journalsubtitle")
					    ("shorttitle" . none)
					    ("sorttitle" . none)
					    ("indextitle" . none)
					    ("indexsorttitle" . none))))
  "Inheritance scheme for BibLaTeX cross-referencing.
Inheritances are specified for pairs of source and target entry
type, where the target is the cross-referencing entry and the
source the cross-referenced entry.  Each pair specifies the
fields in the source and the fields in the target that they
correspond with.

Inheritances valid for all entry types are defined by specifying
the entry type as \"all\".  The entry type may also be a
comma-separated list of entry types.

If no inheritance rule is set up for a given entry type+field
combination, the field inherits from the same-name field in the
cross-referenced entry.  If no inheritance should take place, the
target field is set to the symbol `none'.")

;; Regexes describing BibTeX identifiers and keys.  Note that while $ ^ & are
;; valid in BibTeX keys, they may nonetheless be problematic, because they are
;; special for TeX.  The difference between `parsebib--bibtex-identifier' and
;; `parsebib--key-regexp' are the parentheses (), which are valid in keys.  It may in
;; fact not be necessary (or desirable) to distinguish the two, but until
;; someone complains, I'll keep it this way.
(defconst parsebib--bibtex-identifier "[^\"@\\#%',={}() \t\n\f]+" "Regexp describing a licit BibTeX identifier.")
(defconst parsebib--key-regexp        "[^\"@\\#%',={} \t\n\f]+" "Regexp describing a licit key.")
(defconst parsebib--entry-start "^[ \t]*@" "Regexp describing the start of an entry.")

(define-error 'parsebib-entry-type-error "Illegal entry type" 'error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; matching and parsing stuff ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun parsebib--looking-at-goto-end (str &optional match)
  "Like `looking-at' but move point to the end of the matching string STR.
MATCH acts just like the argument to MATCH-END, and defaults to
0. Comparison is done case-insensitively."
  (or match (setq match 0))
  (let ((case-fold-search t))
    (if (looking-at str)
        (goto-char (match-end match)))))

(defun parsebib--match-paren-forward ()
  "Move forward to the closing paren matching the opening paren at point.
This function handles parentheses () and braces {}.  Return t if
a matching parenthesis was found.  This function puts point
immediately after the matching parenthesis."
  (cond
   ((eq (char-after) ?\{)
    (parsebib--match-brace-forward))
   ((eq (char-after) ?\()
    (bibtex-end-of-entry))))

(defun parsebib--match-delim-forward ()
  "Move forward to the closing delimiter matching the delimiter at point.
This function handles braces {} and double quotes \"\". Return t
if a matching delimiter was found."
  (let ((result (cond
                 ((eq (char-after) ?\{)
                  (parsebib--match-brace-forward))
                 ((eq (char-after) ?\")
                  (parsebib--match-quote-forward)))))
    result))

(defun parsebib--match-brace-forward ()
  "Move forward to the closing brace matching the opening brace at point."
  (with-syntax-table bibtex-braced-string-syntax-table
    (forward-sexp 1)
    ;; if forward-sexp does not result in an error, we want to return t
    t))

(defun parsebib--match-quote-forward ()
  "Move to the closing double quote matching the quote at point."
  (with-syntax-table bibtex-quoted-string-syntax-table
    (forward-sexp 1)
    ;; if forward-sexp does not result in an error, we want to return t
    t))

(defun parsebib--parse-value (limit &optional strings)
  "Parse value at point.
A value is either a field value or a @String expansion.  Return
the value as a string.  No parsing is done beyond LIMIT, but note
that parsing may stop well before LIMIT.

STRINGS, if non-nil, is a hash table of @String definitions.
@String abbrevs in the value to be parsed are then replaced with
their expansions.  Additionally, newlines in field values are
removed, white space is reduced to a single space and braces or
double quotes around field values are removed."
  (let (res)
    (while (and (< (point) limit)
                (not (looking-at-p ",")))
      (cond
       ((looking-at-p "[{\"]")
        (let ((beg (point)))
          (parsebib--match-delim-forward)
          (push (buffer-substring-no-properties beg (point)) res)))
       ((looking-at parsebib--bibtex-identifier)
        (push (buffer-substring-no-properties (point) (match-end 0)) res)
        (goto-char (match-end 0)))
       ((looking-at "[[:space:]]*#[[:space:]]*")
        (goto-char (match-end 0)))
       (t (forward-char 1)))) ; so as not to get stuck in an infinite loop.
    (if strings
        (string-join (parsebib--expand-strings (nreverse res) strings))
      (string-join (nreverse res) " # "))))

;;;;;;;;;;;;;;;;;;;;;
;; expanding stuff ;;
;;;;;;;;;;;;;;;;;;;;;

(defun parsebib--expand-strings (strings abbrevs)
  "Expand strings in STRINGS using expansions in ABBREVS.
STRINGS is a list of strings.  If a string in STRINGS has an
expansion in hash table ABBREVS, replace it with its expansion.
Otherwise, if the string is enclosed in braces {} or double
quotes \"\", remove the delimiters.  In addition, newlines and
multiple spaces in the string are replaced with a single space."
  (mapcar (lambda (str)
            (setq str (replace-regexp-in-string "[ \t\n\f]+" " " str))
            (cond
             ((gethash str abbrevs))
             ((string-match "\\`[\"{]\\(.*?\\)[\"}]\\'" str)
              (match-string 1 str))
             (t str)))
          strings))

(defun parsebib-expand-xrefs (entries inheritance)
  "Expand cross-referencing items in ENTRIES.
BibTeX entries in ENTRIES that have a `crossref' field are
expanded with the fields in the cross-referenced entry.  ENTRIES
is a hash table with entries.  This hash table is updated with
the new fields.  The return value of this function is always nil.

INHERITANCE indicates the inheritance schema.  It can be a symbol
`BibTeX' or `biblatex', or it can be an explicit inheritance
schema.  See the variable `parsebib--biblatex-inheritances' for
details on the structure of such an inheritance schema."
  (maphash (lambda (key fields)
             (let ((xref (cdr (assoc-string "crossref" fields))))
               (when xref
                 (if (string-match-p (concat "\\b[\"{]" parsebib--key-regexp "[\"}]\\b") xref)
                     (setq xref (substring xref 1 -1)))
                 (let* ((source (gethash xref entries))
                        (updated-entry (parsebib--get-xref-fields fields source inheritance)))
                   (when updated-entry
                     (puthash key updated-entry entries))))))
           entries))

(defun parsebib--get-xref-fields (target-entry source-entry inheritance)
  "Return TARGET-ENTRY supplemented with fields inherited from SOURCE-ENTRY.
TARGET-ENTRY and SOURCE-ENTRY are entry alists.  Fields in
SOURCE-ENTRY for which TARGET-ENTRY has no value are added to
TARGET-ENTRY.  Return value is the modified TARGET-ENTRY.

INHERITANCE is an inheritance schema.  It can either be one of
the symbols `BibTeX' or `biblatex', or it can be an explicit
inheritance schema.  See the variable
`parsebib--biblatex-inheritances' for details on the structure of
such an inheritance schema."
  (when (and target-entry source-entry)
    (when (eq inheritance 'biblatex)
      (setq inheritance parsebib--biblatex-inheritances))
    (let* ((inheritable-fields (unless (eq inheritance 'BibTeX)
                                 (append (cl-third (cl-find-if (lambda (elem)
                                                                 (and (string-match-p (concat "\\b" (cdr (assoc-string "=type=" source-entry)) "\\b") (cl-first elem))
                                                                      (string-match-p (concat "\\b" (cdr (assoc-string "=type=" target-entry)) "\\b") (cl-second elem))))
                                                               inheritance))
                                         (cl-third (assoc-string "all" inheritance)))))
           (new-fields (delq nil (mapcar (lambda (field)
                                           (let ((target-field (parsebib--get-target-field (car field) inheritable-fields)))
                                             (if (and target-field
                                                      (not (assoc-string target-field target-entry 'case-fold)))
                                                 (cons target-field (cdr field)))))
                                         source-entry))))
      (append target-entry new-fields))))

(defun parsebib--get-target-field (source-field inheritances)
  "Return the target field for inheritance from SOURCE-FIELD.
Inheritance is determined by INHERITANCES, which is an alist of
source/target pairs.  If no inheritance should take place for
SOURCE-FIELD, the target in the relevant item in INHERITANCES is
the symbol `none'.  If there is no item for SOURCE-FIELD in
INHERITANCES, SOURCE-FIELD is returned.  Note that it is valid
for INHERITANCES to be nil."
  ;; Note: the argument INHERITANCES differs from the INHERITANCE argument in
  ;; the previous two functions.  It is a simple alist of (source-field
  ;; . target-field) pairs.
  (let ((target-field (cdr (assoc-string source-field inheritances 'case-fold))))
    (cond
     ((null target-field)
      source-field)
     ((eq target-field 'none)
      nil)
     (t target-field))))

;;;;;;;;;;;;;;;;;;;
;; low-level API ;;
;;;;;;;;;;;;;;;;;;;

(defun parsebib-find-next-item (&optional pos)
  "Find the first (potential) BibTeX item following POS.
This function simply searches for an @ at the start of a line,
possibly preceded by spaces or tabs, followed by a string of
characters as defined by `parsebib--bibtex-identifier'.  When
successful, point is placed right after the item's type, i.e.,
generally on the opening brace or parenthesis following the entry
type, \"@Comment\", \"@Preamble\" or \"@String\".

The return value is the name of the item as a string, either
\"Comment\", \"Preamble\" or \"String\", or the entry
type (without the @). If an item name is found that includes an
illegal character, an error of type `parsebib-entry-type-error'
is raised. If no item is found, nil is returned and point is left
at the end of the buffer.

POS can be a number or a marker and defaults to point."
  (when pos (goto-char pos))
  (when (re-search-forward parsebib--entry-start nil 0)
    (if (parsebib--looking-at-goto-end (concat "\\(" parsebib--bibtex-identifier "\\)" "[[:space:]]*[\(\{]?") 1)
        (match-string-no-properties 1)
      (signal 'parsebib-entry-type-error (list (point))))))

(defun parsebib-read-comment (&optional pos)
  "Read the @Comment beginning at the line POS is on.
Return value is the text of the @Comment including the braces.
For comments that last until the end of the line (i.e., comments
that are not delimited by braces), the return value includes the
whitespace between `@comment' and the actual comment text.

If no comment could be found, return nil.

POS can be a number or a marker.  It does not have to be at the
beginning of a line, but the @Comment entry must start at the
beginning of the line POS is on.  If POS is nil, it defaults to
point."
  (when pos (goto-char pos))
  (beginning-of-line)
  (when (parsebib--looking-at-goto-end (concat parsebib--entry-start "\\(comment\\)[[:space:]]*[\(\{]?") 1)
    (let ((beg (point)))
      (if (looking-at-p "[[:space:]]*[\(\{]")
          (progn (skip-chars-forward "[:space:]")
                 (parsebib--match-paren-forward))
        (goto-char (point-at-eol)))
      (buffer-substring-no-properties beg (point)))))

(defun parsebib-read-string (&optional pos strings)
  "Read the @String definition beginning at the line POS is on.
If a proper abbreviation and expansion are found, they are
returned as a cons cell (<abbrev> . <expansion>).  Otherwise, nil
is returned.

POS can be a number or a marker.  It does not have to be at the
beginning of a line, but the @String entry must start at the
beginning of the line POS is on.  If POS is nil, it defaults to
point.

If STRINGS is provided it should be a hash table with string
abbreviations, which are used to expand abbrevs in the string's
expansion."
  (when pos (goto-char pos))
  (beginning-of-line)
  (when (parsebib--looking-at-goto-end (concat parsebib--entry-start "\\(string[[:space:]]*\\)[\(\{]") 1)
    (let ((limit (save-excursion
                   (parsebib--match-paren-forward)
                   (point))))
      (parsebib--looking-at-goto-end (concat "[({]\\(" parsebib--bibtex-identifier "\\)[[:space:]]*=[[:space:]]*"))
      (let ((abbr (match-string-no-properties 1)))
        (when (and abbr (> (length abbr) 0))            ; if we found an abbrev
          (let ((expansion (parsebib--parse-value limit strings)))
            (goto-char limit)
            (cons abbr expansion)))))))

(defun parsebib-read-preamble (&optional pos)
  "Read the @Preamble definition at the line POS is on.
Return the preamble as a string (including the braces surrounding
the preamble text), or nil if no preamble was found.

POS can be a number or a marker.  It does not have to be at the
beginning of a line, but the @Preamble must start at the
beginning of the line POS is on.  If POS is nil, it defaults to
point."
  (when pos (goto-char pos))
  (beginning-of-line)
  (when (parsebib--looking-at-goto-end (concat parsebib--entry-start "\\(preamble[[:space:]]*\\)[\(\{]") 1)
    (let ((beg (point)))
      (when (parsebib--match-paren-forward)
        (buffer-substring-no-properties beg (point))))))

(defun parsebib--get-hashid-string (fields)
  "Create a string from the contents of FIELDS to compute a hash id."
  (cl-loop
   for field in parsebib-hashid-fields
   collect (or
            ;; remove braces {}
            (replace-regexp-in-string "^{\\|}\\'" "" (cdr (assoc-string field fields 'case-fold)))
            "")
   into hashid-fields
   finally return (mapconcat #'identity hashid-fields "")))

(defun parsebib-read-entry (type &optional pos strings)
  "Read a BibTeX entry of type TYPE at the line POS is on.
TYPE should be a string and should not contain the @
sign.  The return value is the entry as an alist of (<field> .
<contents>) cons pairs, or nil if no entry was found.  In this
alist, the entry key is provided in the field \"=key=\" and the
entry type in the field \"=type=\".

If `parsebib-hashid-fields' is non-nil, a hash ID is added in the
field \"=hashid=\".  The hash is computed on the basis of the
contents of the fields listed in `parsebib-hashid-fields' using
the function `secure-hash' and the `sha256' algorithm.

POS can be a number or a marker.  It does not have to be at the
beginning of a line, but the entry must start at the beginning of
the line POS is on.  If POS is nil, it defaults to point.

ENTRY should not be \"Comment\", \"Preamble\" or \"String\", but
is otherwise not limited to any set of possible entry types. If
so required, the calling function has to ensure that the entry
type is valid.

If STRINGS is provided, it should be a hash table with string
abbreviations, which are used to expand abbrevs in the entry's
fields."
  (unless (member-ignore-case type '("comment" "preamble" "string"))
    (when pos (goto-char pos))
    (beginning-of-line)
    (when (parsebib--looking-at-goto-end (concat parsebib--entry-start type "[[:space:]]*[\(\{]"))
      ;; find the end of the entry and the beginning of the entry key
      (let* ((limit (save-excursion
                      (backward-char)
                      (parsebib--match-paren-forward)
                      (point)))
             (beg (progn
                    (skip-chars-forward " \n\t\f") ; note the space!
                    (point)))
             (key (when (parsebib--looking-at-goto-end (concat "\\(" parsebib--key-regexp "\\)[ \t\n\f]*,") 1)
                    (buffer-substring-no-properties beg (point)))))
        (or key (setq key "")) ; if no key was found, we pretend it's empty and try to read the entry anyway
        (skip-chars-forward "^," limit) ; move to the comma after the entry key
        (let ((fields (cl-loop for field = (parsebib--find-bibtex-field limit strings)
                               while field collect field)))
          (push (cons "=type=" type) fields)
          (push (cons "=key=" key) fields)
          (if parsebib-hashid-fields
              (push (cons "=hashid=" (secure-hash 'sha256 (parsebib--get-hashid-string fields))) fields))
          (nreverse fields))))))

(defun parsebib--find-bibtex-field (limit &optional strings)
  "Find the field after point.
Do not search beyond LIMIT (a buffer position).  Return a
cons (FIELD . VALUE), or nil if no field was found.

If STRINGS is provided it should be a hash table with string
abbreviations, which are used to expand abbrevs in the field's
value."
  (skip-chars-forward "\"#%'(),={} \n\t\f" limit) ; move to the first char of the field name
  (unless (>= (point) limit)                      ; if we haven't reached the end of the entry
    (let ((beg (point)))
      (if (parsebib--looking-at-goto-end (concat "\\(" parsebib--bibtex-identifier "\\)[[:space:]]*=[[:space:]]*") 1)
          (let ((field-type (buffer-substring-no-properties beg (point))))
            (let ((field-contents (parsebib--parse-value limit strings)))
              (cons field-type field-contents)))))))

;;;;;;;;;;;;;;;;;;;;
;; high-level API ;;
;;;;;;;;;;;;;;;;;;;;

(defun parsebib-collect-preambles ()
  "Collect all @Preamble definitions in the current buffer.
Return a list of strings, each string a separate @Preamble."
  (save-excursion
    (goto-char (point-min))
    (let (res)
      (cl-loop for item = (parsebib-find-next-item)
               while item do
               (when (cl-equalp item "preamble")
                 (push (parsebib-read-preamble) res)))
      (nreverse res))))

(defun parsebib-collect-comments ()
  "Collect all @Comment definitions in the current buffer.
Return a list of strings, each string a separate @Comment."
  (save-excursion
    (goto-char (point-min))
    (let (res)
      (cl-loop for item = (parsebib-find-next-item)
               while item do
               (when (cl-equalp item "comment")
                 (push (parsebib-read-comment) res)))
      (nreverse (delq nil res)))))

(defun parsebib-collect-strings (&optional hash expand-strings)
  "Collect all @String definitions in the current buffer.
Return value is a hash with the abbreviations as keys and the
expansions as values.  If HASH is a hash table with test function
`equal', it is used to store the @String definitions.  If
EXPAND-STRINGS is non-nil, @String expansions are expanded
themselves using the @String definitions already stored in HASH."
  (or (and (hash-table-p hash)
           (eq 'equal (hash-table-test hash)))
      (setq hash (make-hash-table :test #'equal)))
  (save-excursion
    (goto-char (point-min))
    (cl-loop with string = nil
             for item = (parsebib-find-next-item)
             while item do
             (when (cl-equalp item "string")
               (setq string (parsebib-read-string nil (if expand-strings hash)))
               (puthash (car string) (cdr string) hash)))
    hash))

(defun parsebib-collect-entries (&optional hash strings inheritance)
  "Collect all entries in the current buffer.
Return value is a hash table containing the entries.  If HASH is
a hash table, with test function `equal', it is used to store the
entries.  If STRINGS is non-nil, it should be a hash table of
string definitions, which are used to expand abbreviations used
in the entries.

If INHERITANCE is non-nil, cross-references in the entries are
resolved: if the crossref field of an entry points to an entry
already in HASH, the fields of the latter that do not occur in
the entry are added to it.  INHERITANCE indicates the inheritance
schema used for determining which fields inherit from which
fields.  It can be a symbol `BibTeX' or `biblatex', or it can be
an explicit inheritance schema.  (See the variable
`parsebib--biblatex-inheritances' for details on the structure of
such an inheritance schema.)  It can also be the symbol t, in
which case the local variable block is checked for a
dialect (using the variable `bibtex-dialect'), or, if no such
local variable is found, the value of the variable
`bibtex-dialect'."
  (or (and (hash-table-p hash)
           (eq 'equal (hash-table-test hash)))
      (setq hash (make-hash-table :test #'equal)))
  (if (eq inheritance t)
      (setq inheritance (or (parsebib-find-bibtex-dialect)
                            bibtex-dialect
                            'BibTeX)))
  (save-excursion
    (goto-char (point-min))
    (cl-loop with entry = nil
             for entry-type = (parsebib-find-next-item)
             while entry-type do
             (unless (member-ignore-case entry-type '("preamble" "string" "comment"))
               (setq entry (parsebib-read-entry entry-type nil strings))
               (if entry
                   (puthash (cdr (assoc-string "=key=" entry)) entry hash))))
    (when inheritance
      (parsebib-expand-xrefs hash inheritance))
    hash))

(defun parsebib-find-bibtex-dialect ()
  "Find the BibTeX dialect of a file if one is set.
This function looks for a local value of the variable
`bibtex-dialect' in the local variable block at the end of the
file.  Return nil if no dialect is found."
  (save-excursion
    (goto-char (point-max))
    (let ((case-fold-search t))
      (when (re-search-backward (concat parsebib--entry-start "comment") (- (point-max) 3000) t)
        (let ((comment (parsebib-read-comment)))
          (when (and comment
                     (string-match-p "\\`{[ \n\t\r]*Local Variables:" comment)
                     (string-match-p "End:[ \n\t\r]*}\\'" comment)
                     (string-match (concat "bibtex-dialect: " (regexp-opt (mapcar #'symbol-name bibtex-dialect-list) t)) comment))
            (intern (match-string 1 comment))))))))

(defun parsebib-parse-buffer (&optional entries strings expand-strings inheritance)
  "Parse the current buffer and return all BibTeX data.
Return list of five elements: a hash table with the entries, a
hash table with the @String definitions, a list of @Preamble
definitions, a list of @Comments and the BibTeX dialect, if
present in the file.

If ENTRIES is a hash table with test function `equal', it is used
to store the entries.  Any existing entries with identical keys
are overwritten.  Similarly, if STRINGS is a hash table with test
function `equal', the @String definitions are stored in it.

If EXPAND-STRINGS is non-nil, abbreviations in the entries and
@String definitions are expanded using the @String definitions
already in STRINGS.

If INHERITANCE is non-nil, cross-references in the entries are
resolved: if the crossref field of an entry points to an entry
already in ENTRIES, the fields of the latter that do not occur in
the entry are added to it.  INHERITANCE indicates the inheritance
schema used for determining which fields inherit from which
fields.  It can be a symbol `BibTeX' or `biblatex', which means
to use the default inheritance schema for either dialect, or it
can be an explicit inheritance schema.  (See the variable
`parsebib--biblatex-inheritances' for details on the structure of
such an inheritance schema.)  It can also be the symbol t, in
which case the local variable block is checked for a
dialect (using the variable `bibtex-dialect'), or, if no such
local variable is found, the value of the variable
`bibtex-dialect'."
  (save-excursion
    (goto-char (point-min))
    (or (and (hash-table-p entries)
             (eq (hash-table-test entries) 'equal))
        (setq entries (make-hash-table :test #'equal)))
    (or (and (hash-table-p strings)
             (eq (hash-table-test strings) 'equal))
        (setq strings (make-hash-table :test #'equal)))
    (let ((dialect (or (parsebib-find-bibtex-dialect)
                       bibtex-dialect
                       'BibTeX))
          preambles comments)
      (cl-loop for item = (parsebib-find-next-item)
               while item do
               (cond
                ((cl-equalp item "string") ; `cl-equalp' compares strings case-insensitively.
                 (let ((string (parsebib-read-string nil (if expand-strings strings))))
                   (if string
                       (puthash (car string) (cdr string) strings))))
                ((cl-equalp item "preamble")
                 (push (parsebib-read-preamble) preambles))
                ((cl-equalp item "comment")
                 (push (parsebib-read-comment) comments))
                ((stringp item)
                 (let ((entry (parsebib-read-entry item nil (if expand-strings strings))))
                   (when entry
                     (puthash (cdr (assoc-string "=key=" entry)) entry entries))))))
      (when inheritance (parsebib-expand-xrefs entries (if (eq inheritance t) dialect inheritance)))
      (list entries strings (nreverse preambles) (nreverse comments) dialect))))

;;;;;;;;;;;;;;;;;;
;; CSL-JSON API ;;
;;;;;;;;;;;;;;;;;;

(defun parsebib-parse-json-buffer (&optional entries stringify)
  "Parse the current buffer and return all CSL-JSON data.
The return value is a hash table containing all the elements.
The hash table's keys are the \"id\" values of the entries, the
hash table's values are alists as returned by `json-parse-buffer'
or `json-read'

If ENTRIES is a hash table with test function `equal', it is used
to store the entries.  Any existing entries with identical keys
are overwritten.

If STRINGIFY is non-nil, JSON values that are not
strings (notably name and date fields) are converted to
strings.

If a JSON object is encountered that does not have an \"id\"
field, a `parsebib-entry-type-error' is raised."
  (or (and (hash-table-p entries)
           (eq (hash-table-test entries) 'equal))
      (setq entries (make-hash-table :test #'equal)))
  (save-excursion
    (goto-char (point-min))
    (let ((entry-vector (if (fboundp 'json-parse-buffer)
                            (json-parse-buffer :object-type 'alist)
                          (let ((json-object-type 'alist))
                            (json-read)))))
      (mapc (lambda (entry)
              (let ((id (alist-get "id" entry nil nil #'string=)))
                (if id
                    (puthash id (if stringify
                                    (parsebib-stringify-json entry)
                                  entry)
                             entries)
                  (signal 'parsebib-entry-type-error (list entry)))))
            entry-vector)))
  entries)

(defun parsebib-stringify-json (entry)
  "Return ENTRY with all non-string values converted to strings.
ENTRY is a CSL-JSON entry in the form of an alist.  ENTRY is
modified in place.  Return value is ENTRY."
  entry)

(defvar parsebib-json-name-fields  '(author
                                     collection-editor
                                     composer
                                     container-author
                                     director
                                     editor
                                     editorial-director
                                     illustrator
                                     interviewer
                                     original-author
                                     recipient
                                     reviewed-author
                                     translator))

(defvar parsebib-json-date-fields '(accessed
                                    container
                                    event-date
                                    issued
                                    original-date
                                    submitted))

(defvar parsebib-json-number-fields '(chapter-number
                                      collection-number
                                      edition
                                      issue
                                      number
                                      number-of-pages
                                      number-of-volumes
                                      volume))

(defvar parsebib-json-name-field-template "{non-dropping-particle }{family, }{given}{ dropping-particle}{, suffix}{literal}"
  "Template used to display name fields.")

(defvar parsebib-json-name-field-separator " and "
  "Separator used to concatenate names in a name field.")

(defvar parsebib-json-field-separator ", "
  "Separator used to concatenate items of array fields.")

(defun parsebib--process-template (template items)
  "Process TEMPLATE and return a formatted string.
ITEMS is an alist, the keys of which may occur in TEMPLATE.
Braced occurrences of the keys in ITEMS are replaced with the
corresponding values.  Note that the keys in ITEMS should be
symbols."
  (cl-flet ((create-replacements (match)
                                 (save-match-data
                                   (string-match "{\\([^A-Za-z]*\\)\\([A-Za-z][A-za-z-]+\\)\\([^A-Za-z]*\\)}" match)
                                   (let* ((pre (match-string 1 match))
                                          (key (match-string 2 match))
                                          (post (match-string 3 match))
                                          (value (alist-get (intern key) items)))
                                     (if value
                                         (format "%s%s%s" pre value post)
                                       "")))))
    (replace-regexp-in-string "{.*?}" #'create-replacements template nil t)))

(defun parsebib-stringify-json-field (field)
  "Return the value of FIELD as a string.
FIELD is a cons cell that constitutes a CSL-JSON field-value
pair.  The car is the key, the cdr the value.  If the value is a
string, return it unchanged.  Otherwise, convert it into a
string."
  (let ((key (car field))
        (value (cdr field)))
    (cond
     ((stringp value)
      value)
     ((numberp value)
      (format "%s" value))
     ((memq key parsebib-json-name-fields)
      (parsebib--json-stringify-name-field value))
     ((memq key parsebib-json-date-fields)
      (parsebib--json-stringify-date-field value))
     ((arrayp value)
      (mapconcat #'parsebib-stringify-json-field value parsebib-json-field-separator))
     (t (replace-regexp-in-string "\n" " " (format "%s" value))))))

(defun parsebib--json-stringify-name-field (names)
  "Convert NAMES to a string.
NAMES is the value of a CSL-JSON name field, a vector of alists.
Conversion is done on the basis of
`parsebib-json-name-field-template': each field in this template
is replaced with the value of the field in NAME.  Fields that
have no value in NAME are ignored."
  (mapconcat (lambda (name)
               (parsebib--process-template parsebib-json-name-field-template name))
             names
             parsebib-json-name-field-separator))

(defun parsebib--json-stringify-date-field (date &optional short)
  "Convert DATE to a string.
DATE is the value of a CSL-JSON date field.  If SHORT is non-nil,
try to return only a year (in a date range, just the year of the
first date)."
  (if short
      (if-let ((date-parts (alist-get 'date-parts date))
               (first-date (aref date-parts 0))
               (year (aref first-date 0)))
          (format "%s" year)
        "XXXX")

    ;; Work with a copy of the original alist.
    (setq date (copy-sequence date))

    ;; Set start-date and end-date.
    (when-let ((date-parts (alist-get 'date-parts date)))
      (let* ((start-date (aref date-parts 0))
             (end-date (if (= (length date-parts) 2)
                           (aref date-parts 1))))
        (setf (alist-get 'date-parts date nil :remove) nil)
        (setf (alist-get 'start-date date)
              (parsebib--json-stringify-date-part start-date))
        (if end-date (setf (alist-get 'end-date date)
                           (parsebib--json-stringify-date-part end-date)))))

    ;; Set season.
    (when-let ((season (alist-get 'season date)))
      (if (numberp season)
          (setf (alist-get 'season date)
                (aref ["Spring" "Summer" "Autumn" "Winter"] (1- season)))))

    ;; Set circa.
    (when-let ((circa (alist-get 'circa date)))
      (setf (alist-get 'circa date) "ca."))

    ;; Now convert the date.
    (parsebib--process-template "{circa}{season}{start-date}{/end-date}{literal}{raw}"
                                date)))

(defun parsebib--json-stringify-date-part (date-parts)
  "Convert DATE-PARTS into a string.
DATE-PARTS is a sequence with up to three numeric elements: a
year, a month and a day."
  (parsebib--process-template "{year}{-month}{-day}"
                              (seq-mapn #'cons '(year month day) date-parts)))

(provide 'parsebib)

;;; parsebib.el ends here
