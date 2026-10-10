;;; config.el --- your Emacs configuration -*- lexical-binding: t; -*-

;; Put your configuration in this file. init.el loads it at startup and is
;; otherwise reserved for bootstrap and for the custom-set-variables blocks
;; Customize writes there - keeping those machine-written forms out of the
;; configuration you maintain by hand.

;;; The YardQuit packages the image ships
;;
;; Donkey (modal editing), Ao (a dark and a light theme) and Garamond
;; (sentence spacing) are not in any package archive. The image build
;; fetches their source into donkey/, ao/ and garamond/ inside this
;; directory - section 1a of build.sh - and each is installed below the
;; way its README installs from a clone: a `use-package' block whose
;; `:init' byte-compiles the file and loads the compiled copy, with
;; `:load-path' and the compile step reading one directory variable so
;; the two cannot drift apart.
;;
;; A package archive byte-compiles what it installs. A file fetched into
;; a directory is not, and none of these compiles itself, so
;; `my-compile-and-load' does - on the first Emacs start, and again
;; whenever the .el turns out to be newer than the .elc beside it, which
;; is what dropping in a newer release leaves behind. Compiled matters:
;; Donkey works from `post-command-hook' and Garamond from
;; `post-self-insert-hook', so an interpreted copy is paid for on every
;; keystroke, and a .elc is what Emacs's native compiler picks up in the
;; background when `native-comp-jit-compilation' is on - a .el loaded
;; from source never is. Emacs prefers a .elc to the .el whenever both
;; are on the load path, which makes a stale .elc the copy `require'
;; would take; loading the current file explicitly sidesteps that, and
;; by the time `use-package' runs its own `require' the feature is
;; already provided, so that does nothing.
;;
;; The echo area says which copy you got - "loaded compiled", or "loaded
;; from source (interpreted)" - and how long a recompile took when there
;; was one. If a compile fails the package loads from source and says
;; so; a file that will not compile must not stop Emacs from starting.
;; The reason is not shown, so run M-x byte-compile-file on the .el when
;; you want to see it.
;;
;; To drop one of the three, delete its `use-package' block here and its
;; skel_fetch line(s) in build.sh.

(defun my-compile-if-stale (dir name)
  "Byte-compile NAME.el in DIR when NAME.elc beside it is missing or older.
Return the seconds the compile took, or nil when nothing was compiled
or the compile failed."
  (let ((src (expand-file-name (concat name ".el") dir))
        (elc (expand-file-name (concat name ".elc") dir)))
    (when (file-newer-than-file-p src elc)
      (require 'bytecomp)
      (let ((start (current-time)))
        (and (ignore-errors (byte-compile-file src))
             (float-time (time-since start)))))))

(defun my-compile-and-load (dir name &optional version)
  "Compile NAME.el in DIR if it is stale, then load the current copy.
The .elc is loaded when it is current, the .el otherwise. VERSION, when
given, is a function returning the version string to report."
  (let ((src (expand-file-name (concat name ".el") dir)))
    (if (not (file-exists-p src))
        (message "WARNING: %s not found under %s - see section 1a of build.sh"
                 (file-name-nondirectory src) dir)
      (let* ((recompiled (my-compile-if-stale dir name))
             (elc (expand-file-name (concat name ".elc") dir))
             (compiled (and (file-exists-p elc)
                            (not (file-newer-than-file-p src elc)))))
        (load (if compiled elc src) nil t)
        (message "%s%s loaded %s%s"
                 name
                 (if (and version (fboundp version))
                     (format " %s" (funcall version))
                   "")
                 (if compiled "compiled" "from source (interpreted)")
                 (if recompiled
                     (format ", recompiled in %.2fs" recompiled)
                   ""))))))

;; Donkey (https://github.com/YardQuit/donkey) - modal editing, enabled by
;; default. Set donkey options before this block. Whatever Donkey does not
;; bind is yours: put your own keys in :config, after the load - see
;; "Making it yours" in its README, for example
;;   (keymap-set donkey-normal-mode-map "F" #'delete-other-windows)
;;   (keymap-set donkey-leader-map "b" '("switch buffer" . switch-to-buffer))
(defvar my-donkey-dir (expand-file-name "donkey" user-emacs-directory)
  "Where donkey.el lives. Read by both :load-path and the compile step.")

(use-package donkey
  :load-path my-donkey-dir
  :init
  (my-compile-and-load my-donkey-dir "donkey" #'donkey-version)
  :config
  (donkey-mode 1))

;; Ao (https://github.com/YardQuit/ao) - a dark and a light theme built from
;; one palette. The dark variant is loaded by default; M-x ao-theme-toggle
;; switches to the light one and back, and ao-theme-load-light here makes
;; light the default instead. Its four appearance options
;; (ao-theme-bold-constructs and friends) are read when a variant loads, so
;; set them before this block. Three files: ao-theme.el holds the palettes
;; and the faces, the two ao-*-theme.el files are the deftheme for each
;; variant, found by load-theme through custom-theme-load-path.
(defvar my-ao-dir (expand-file-name "ao" user-emacs-directory)
  "Where the Ao theme files live. Read by both :load-path and the compile step.")

(use-package ao-theme
  :load-path my-ao-dir
  :init
  (add-to-list 'custom-theme-load-path my-ao-dir)
  (my-compile-and-load my-ao-dir "ao-theme")
  ;; The variants require ao-theme, so they compile after it has loaded.
  (dolist (variant '("ao-dark-theme" "ao-light-theme"))
    (my-compile-if-stale my-ao-dir variant))
  :config
  (ao-theme-load-dark))

;; Garamond (https://github.com/YardQuit/garamond) - one or two spaces after
;; a sentence, declared in the document rather than in your config. The one
;; line of setup is in :config; the knobs beside it are optional.
(defvar my-garamond-dir (expand-file-name "garamond" user-emacs-directory)
  "Where garamond.el lives. Read by both :load-path and the compile step.")

(use-package garamond
  :load-path my-garamond-dir
  :init
  (my-compile-and-load my-garamond-dir "garamond" #'garamond-version)
  :config
  ;; Read the spacing that documents declare.
  (garamond-follow-declarations-mode 1)
  ;; (setq garamond-extra-abbreviations   '("Ph.D." "et al." "Inc.")
  ;;       garamond-removed-abbreviations '("St." "No.")
  ;;       garamond-double-space-on-typing t   ; nil: declare, never type
  ;;       garamond-lighter                t)  ; nil: place it yourself
  )

;;; config.el ends here
