;;; config.el --- your Emacs configuration -*- lexical-binding: t; -*-

;; Put your configuration in this file. init.el loads it at startup and is
;; otherwise reserved for bootstrap and for the custom-set-variables blocks
;; Customize writes there - keeping those machine-written forms out of the
;; configuration you maintain by hand.

;; Donkey (https://github.com/YardQuit/donkey) - modal editing, enabled by
;; default. The image build fetches donkey.el to donkey/donkey.el in this
;; directory, where its README expects it. Set donkey options before this
;; block; delete the block to disable it.
(let ((donkey-path (expand-file-name "donkey/donkey.el" user-emacs-directory)))
  (if (file-exists-p donkey-path)
      (progn
        (load donkey-path nil t)
        (donkey-mode 1))
    (message "WARNING: Donkey modal module not found at %s." donkey-path)))

;; Enabling donkey-mode during init misses one buffer: the graphical
;; startup screen (*GNU Emacs*). It is created after init - late enough
;; that even window-setup-hook runs before it exists - and in
;; fundamental-mode, which never runs after-change-major-mode-hook, the
;; hook Donkey uses to set up new buffers. The result is a first launch
;; where the mode looks enabled but keys are dead until it is toggled by
;; hand. This one-shot idle timer fires once startup is fully finished
;; and redoes the toggle, exactly like the manual fix.
(run-with-idle-timer 0.1 nil
  (lambda ()
    (when (bound-and-true-p donkey-mode)
      (donkey-mode -1)
      (donkey-mode 1))))

;;; config.el ends here
