;;; dashy.el --- Browse Dash.app docsets via eww  -*- lexical-binding: t; -*-

;; Author: Łukasz Korecki <lukasz@korecki.me>
;; Maintainer: Łukasz Korecki <lukasz@korecki.me>
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: tools, docs, help
;; URL: https://github.com/lukaszkorecki/dashy

;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; Talks to Dash.app's local HTTP API (Dash must be running with the
;; API server enabled) to list docsets and search documentation,
;; rendering selected entries in eww.
;;
;; Entry points:
;;   `M-x dashy'          opens a transient menu.
;;   `M-x dashy-search'   prompts for a query.
;;   `M-x dashy-at-point' searches for the symbol at point.

;;; Code:

(require 'url)
(require 'url-util)
(require 'json)
(require 'eww)
(require 'transient)
(require 'subr-x)
(require 'seq)
(require 'thingatpt)

(defgroup dashy nil
  "Browse Dash.app docsets from Emacs."
  :group 'tools)

(defcustom dashy-status-file
  (expand-file-name "Library/Application Support/Dash/.dash_api_server/status.json" "~")
  "Path to the Dash local API status file."
  :type 'file
  :group 'dashy)

(defcustom dashy-request-timeout 10
  "Seconds to wait for a Dash API response."
  :type 'integer
  :group 'dashy)

(defvar dashy--docsets nil
  "Cached docsets: list of (NAME . IDENTIFIER) pairs.")

(defvar dashy--filter nil
  "Active docset identifier filter, a list of identifier strings.
At least one docset is required — Dash's API errors on empty filters.")

(defun dashy--port ()
  "Read the Dash API port from the status file."
  (unless (file-exists-p dashy-status-file)
    (user-error "Dash status file not found at %s — is Dash running with the API enabled?"
                dashy-status-file))
  (with-temp-buffer
    (insert-file-contents dashy-status-file)
    (goto-char (point-min))
    (let ((data (json-parse-buffer :object-type 'alist)))
      (or (alist-get 'port data)
          (user-error "No `port' field in Dash status file")))))

(defun dashy--url (endpoint &optional query)
  "Build a URL for Dash API ENDPOINT with optional QUERY alist."
  (let ((base (format "http://127.0.0.1:%d%s" (dashy--port) endpoint)))
    (if query
        (concat base "?" (url-build-query-string query))
      base)))

(defun dashy--get-json (endpoint &optional query)
  "GET ENDPOINT (with optional QUERY) and return parsed JSON as alists."
  (let* ((url (dashy--url endpoint query))
         (url-show-status nil)
         (buf (condition-case err
                  (url-retrieve-synchronously url t t dashy-request-timeout)
                (error
                 (user-error "Dash request failed: %s" (error-message-string err))))))
    (unless buf
      (user-error "No response from Dash at %s" url))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (unless (re-search-forward "\n\n" nil t)
            (user-error "Malformed HTTP response from Dash"))
          (json-parse-buffer :object-type 'alist
                             :array-type 'list
                             :null-object nil))
      (kill-buffer buf))))

(defun dashy--fetch-docsets ()
  "Fetch the docset list from Dash."
  (let* ((resp (dashy--get-json "/docsets/list"))
         (docsets (alist-get 'docsets resp)))
    (mapcar (lambda (d)
              (cons (alist-get 'name d)
                    (alist-get 'identifier d)))
            docsets)))

(defun dashy--docsets ()
  "Return cached docsets, fetching if needed."
  (or dashy--docsets
      (setq dashy--docsets (dashy--fetch-docsets))))

(defun dashy--search (query &optional docset-ids)
  "Search Dash for QUERY, optionally restricted to DOCSET-IDS."
  (let* ((params `(("query" ,query)))
         (params (if (and docset-ids (seq-some #'identity docset-ids))
                     (append params
                             `(("docset_identifiers" ,(string-join docset-ids ","))))
                   params))
         (resp (dashy--get-json "/search" params)))
    (alist-get 'results resp)))

(defun dashy--filter-names ()
  "Display names of currently filtered docsets."
  (let ((docsets (dashy--docsets)))
    (mapcar (lambda (id)
              (or (car (rassoc id docsets)) id))
            dashy--filter)))

(defun dashy--filter-description ()
  "Human-readable description of the active filter."
  (if dashy--filter
      (format "Docsets: %s" (string-join (dashy--filter-names) ", "))
    "Docsets: (none — required)"))

(defun dashy--pick-result (results)
  "Prompt for one of RESULTS via `completing-read'."
  (when (null results)
    (user-error "No results"))
  (let ((table (make-hash-table :test 'equal))
        cands)
    (dolist (r results)
      (let* ((base (format "%s  [%s]"
                           (alist-get 'name r)
                           (alist-get 'docset r)))
             (key base)
             (n 1))
        (while (gethash key table)
          (setq n (1+ n))
          (setq key (format "%s (%d)" base n)))
        (puthash key r table)
        (push key cands)))
    (let* ((completion-extra-properties
            (list :annotation-function
                  (lambda (cand)
                    (when-let* ((r (gethash cand table))
                                (desc (alist-get 'description r)))
                      (concat "  " (propertize desc 'face 'completions-annotations))))))
           (chosen (completing-read "Result: " (nreverse cands) nil t)))
      (gethash chosen table))))

(defun dashy--search-and-open (query)
  "Search Dash for QUERY using the active filter, open chosen result in eww."
  (when (string-blank-p query)
    (user-error "Empty query"))
  (let* ((results (dashy--search query dashy--filter))
         (chosen (dashy--pick-result results)))
    (eww (alist-get 'load_url chosen))))

;;;###autoload
(defun dashy-refresh-docsets ()
  "Re-fetch the docset list from Dash."
  (interactive)
  (setq dashy--docsets nil)
  (message "Loaded %d Dash docsets" (length (dashy--docsets))))

;;;###autoload
(defun dashy-select-docsets ()
  "Pick one or more docsets to limit subsequent searches to."
  (interactive)
  (let* ((docsets (dashy--docsets))
         (chosen (completing-read-multiple
                  "Docsets (at least one): "
                  (mapcar #'car docsets) nil t)))
    (when (null chosen)
      (user-error "At least one docset is required"))
    (setq dashy--filter
          (delq nil
                (mapcar (lambda (name) (cdr (assoc name docsets))) chosen)))
    (message "%s" (dashy--filter-description))))

;;;###autoload
(defun dashy-clear-docsets ()
  "Clear the docset filter.  The next search will re-prompt."
  (interactive)
  (setq dashy--filter nil)
  (message "Dash filter cleared"))

;;;###autoload
(defun dashy-search (query)
  "Search Dash for QUERY using the active docset filter, open in eww.
Prompts for docsets first if none are selected."
  (interactive
   (progn
     (unless dashy--filter (dashy-select-docsets))
     (list (read-string
            (format "Search Dash (%s): " (dashy--filter-description))))))
  (dashy--search-and-open query))

;;;###autoload
(defun dashy-at-point ()
  "Search Dash for the symbol at point using the active docset filter.
Prompts for docsets first if none are selected."
  (interactive)
  (unless dashy--filter (dashy-select-docsets))
  (let ((symbol (thing-at-point 'symbol t)))
    (unless symbol
      (user-error "No symbol at point"))
    (dashy--search-and-open symbol)))

;;;###autoload (autoload 'dashy "dashy" nil t)
(transient-define-prefix dashy ()
  "Browse Dash.app documentation."
  [:description
   (lambda () (dashy--filter-description))
   ("s" "Search"          dashy-search)
   ("." "Search at point" dashy-at-point)
   ("d" "Select docsets"  dashy-select-docsets :transient t)
   ("c" "Clear docsets"   dashy-clear-docsets  :transient t)
   ("r" "Refresh docsets" dashy-refresh-docsets :transient t)
   ("q" "Quit"            transient-quit-one)])

(provide 'dashy)
;;; dashy.el ends here
