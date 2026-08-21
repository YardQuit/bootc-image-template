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

;;; config.el ends here
