;;; -*- lexical-binding: t -*-
;;; Author: ywatanabe
;;; Time-stamp: <2024-11-01 02:20:39 (ywatanabe)>
;;; File: ./python-import-manager/python-import-manager.el
;; Copyright (C) 2024 ywatanabe

;; Author: Yusuke Watanabe (ywatanabe@alumni.u-tokyo.ac.jp)
;; Version: 1.0.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: languages, tools, python
;; URL: https://github.com/ywatanabe/python-import-manager

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Python Import Manager (PIM) automatically manages Python imports in your code.
;; It can detect unused imports and add missing ones based on actual usage.

;;; Code:
(require 'async)
(require 'json)
(unless (fboundp 'json-read)
  (require 'json-mode))
(require 'seq)
(require 'python)

(defgroup python-import-manager nil
  "Management of Python imports."
  :group 'tools
  :prefix "pim-")

(define-minor-mode pim-auto-mode
  "Minor mode to automatically fix imports on save."
  :lighter " PIM"
  (if pim-auto-mode
      (add-hook 'before-save-hook #'pim-fix-imports nil t)
    (remove-hook 'before-save-hook #'pim-fix-imports t)))

(defcustom pim-python-path
  (or python-shell-interpreter
      (executable-find "python3"))
  "Path to python executable."
  :type 'string
  :group 'python-import-manager)
      
(defcustom pim-flake8-path
  (executable-find "flake8")
  "Path to flake8 executable."
  :type 'string
  :group 'python-import-manager)

(defcustom pim-flake8-args
  '("--max-line-length=100" "--select=F401,F821" "--isolated")
  "Arguments to pass to flake8."
  :type '(repeat string)
  :group 'python-import-manager)

(defcustom pim-isort-path
  (executable-find "isort")
  "Path to isort executable."
  :type 'string
  :group 'python-import-manager)

(defcustom pim-isort-args
  '("--profile" "black" "--line-length" "100")
  "Arguments to pass to isort."
  :type '(repeat string)
  :group 'python-import-manager)

(defcustom pim-import-aliases
  '(("numpy" . "np")
    ("pandas" . "pd")
    ("matplotlib.pyplot" . "plt")
    ("seaborn" . "sns"))
  "Alist of package names and their preferred aliases."
  :type '(alist :key-type string :value-type string)
  :group 'python-import-manager)


(defun pim--find-flake8 ()
  "Find flake8 executable."
  (or pim-flake8-path
      (executable-find "flake8")
      (user-error "Cannot find flake8. Please install it or set pim-flake8-path")))

(defun pim--copy-contents-as-temp-file ()
  "Copy current buffer to temp file and return the filename."
  (let ((temp-file (make-temp-file "pim-")))
    (write-region (point-min) (point-max) temp-file)
    temp-file))

(defun pim--get-flake8-output (temp-file &optional args)
  "Run flake8 on TEMP-FILE with optional ARGS and return output."
  (let ((flake8-path (pim--find-flake8)))
    (with-temp-buffer
      (apply #'call-process flake8-path nil t nil
             (append (or args pim-flake8-args) (list temp-file)))
      (buffer-string))))

(defun pim--find-undefined ()
  "Find undefined names from flake8 output."
  (interactive)
  (when (= (point-min) (point-max))
    (user-error "Buffer is empty"))
  (let* ((temp-file (pim--copy-contents-as-temp-file))
         (undefined-list '())
         (output (pim--get-flake8-output temp-file '("--select=F821"))))
    (with-temp-buffer
      (insert output)
      (goto-char (point-min))
      (while (re-search-forward "F821 undefined name '\\([^']+\\)'" nil t)
        (push (match-string 1) undefined-list)))
    (delete-file temp-file)
    undefined-list))

;; (defun pim--find-unused-modules ()
;;   "Find unused modules from flake8 output."
;;   (let* ((temp-file (pim--copy-contents-as-temp-file))
;;          (output (pim--get-flake8-output temp-file '("--select=F401")))
;;          modules)
;;     (with-temp-buffer
;;       (insert output)
;;       (goto-char (point-min))
;;       (while (re-search-forward "F401 '\\([^']+\\)' imported but unused" nil t)
;;         (push (car (last (split-string (match-string 1) "\\."))) modules)))
;;     (delete-file temp-file)
;;     modules))

;; (defun pim--find-unused-modules ()
;;   "Find unused modules from flake8 output."
;;   (let* ((temp-file (pim--copy-contents-as-temp-file))
;;          (output (pim--get-flake8-output temp-file '("--select=F401")))
;;          modules)
;;     (with-temp-buffer
;;       (insert output)
;;       (goto-char (point-min))
;;       (while (re-search-forward "F401 '\\([^']+\\)' imported but unused" nil t)
;;         (push (match-string 1) modules)))
;;     (delete-file temp-file)
;;     modules))
(defun pim--find-unused-modules ()
  "Find unused modules from flake8 output."
  (let* ((temp-file (pim--copy-contents-as-temp-file))
         (output (pim--get-flake8-output temp-file '("--select=F401")))
         modules)
    (with-temp-buffer
      (insert output)
      (goto-char (point-min))
      (while (re-search-forward "F401 '\\([^']+\\)' imported but unused" nil t)
        (let ((module (match-string 1)))
          (push (if (string-match "\\([^.]+\\)$" module)
                    (match-string 1 module)
                  module)
                modules))))
    (delete-file temp-file)
    modules))


(defun pim--remove-module (module)
  "Remove specific MODULE from import lines."
  (save-excursion
    (goto-char (point-min))
    ;; Remove 'import module' lines
    (while (re-search-forward "^import .*$" nil t)
      (when (string-match-p (format "\\b%s\\b" module) 
                           (match-string 0))
        (kill-whole-line)))
    ;; Remove 'from ... import' lines
    (goto-char (point-min))
    (while (re-search-forward "^from .* import.*$" nil t)
      (let* ((line (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position)))
             (imports (when (string-match "import \\(.+\\)" line)
                       (split-string (match-string 1 line) "," t "[\s\t]+")))
             (new-imports (remove module imports)))
        (when (and imports (not (equal imports new-imports)))
          (delete-region (line-beginning-position) (line-end-position))
          (if new-imports
              (insert (format "from %s import %s"
                            (progn (string-match "from \\([^ ]+\\) import" line)
                                   (match-string 1 line))
                            (string-join new-imports ", ")))
            (kill-whole-line)))))))

(defun pim--cleanup-imports ()
  "Remove empty import lines."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^from .* import *$" nil t)
      (kill-whole-line))))

;;;###autoload
(defun pim-delete-unused ()
  "Remove unused imports."
  (interactive)
  (let ((unused-modules (pim--find-unused-modules)))
    (dolist (module unused-modules)
      (pim--remove-module module))
    (pim--cleanup-imports)))

;;;###autoload
(defun pim-insert-missed ()
  "Insert missing imports."
  (interactive)
  (let ((undefined-names (pim--find-undefined)))
    (when undefined-names
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^import\\|^from" nil t)
          (beginning-of-line)
          (dolist (name undefined-names)
            (let* ((module (rassoc name pim-import-aliases))
                   (import-line
                    (if module
                        (format "import %s as %s\n" (car module) (cdr module))
                      (format "from %s import %s\n" (downcase name) name))))
              (insert import-line))))))))

;;;###autoload
(defun pim-delete-duplicated ()
  "Remove duplicate import statements."
  (interactive)
  (save-excursion
    (let ((imports (make-hash-table :test 'equal)))
      (goto-char (point-min))
      (while (re-search-forward "^\\(from .* import .*\\|import .*\\)$" nil t)
        (let ((line (match-string 0)))
          (if (gethash line imports)
              (kill-whole-line)
            (puthash line t imports)))))))

;; isort
(defun pim--find-isort ()
  "Find isort executable."
  (interactive)
  (or pim-isort-path
      (executable-find "isort")
      (user-error "Cannot find isort. Please install it or set pim-isort-path")))

(defun pim--get-isort-output (temp-file &optional args)
  "Run isort on TEMP-FILE with optional ARGS and return output."
  (let ((isort-path (pim--find-isort)))
    (with-temp-buffer
      (apply #'call-process isort-path nil t nil
             (append (or args pim-isort-args) (list temp-file)))
      (buffer-string))))

(defun pim-isort ()
  "Sort imports using isort."
  (interactive)
  (let* ((temp-file (pim--copy-contents-as-temp-file)))
    (pim--get-isort-output temp-file)
    (erase-buffer)
    (insert-file-contents temp-file)
    (delete-file temp-file)))

;;;###autoload
(defun pim-fix-imports ()
  "Fix imports in current buffer."
  (interactive)
  (let ((original-point (point)))
    (pim-delete-unused)
    (pim-insert-missed)
    (pim-delete-duplicated) 
    (pim-isort)
    (goto-char original-point)))

;;;###autoload
(defalias 'pim 'pim-fix-imports)

(provide 'python-import-manager)

;;; python-import-manager.el ends here


(message "%s was loaded." (file-name-nondirectory (or load-file-name buffer-file-name)))
