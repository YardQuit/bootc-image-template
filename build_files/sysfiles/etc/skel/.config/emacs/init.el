;;; init.el --- bootstrap only; edit config.el instead -*- lexical-binding: t; -*-

;; Seeded from /etc/skel into every user account created on this system.
;;
;; This directory is Emacs' XDG configuration location (~/.config/emacs).
;; Emacs 27+ picks it as `user-emacs-directory' only when ~/.emacs.d does
;; not exist - and then everything Emacs writes (packages, auto-save-list,
;; eln-cache) lands here too, so ~/.emacs.d is never created. Creating
;; ~/.emacs, ~/.emacs.el or ~/.emacs.d by hand would take precedence over
;; this directory and effectively disable it; see "(emacs) Find Init".
;;
;; Layout:
;;   init.el   - this file. Bootstrap only, plus the custom-set-variables /
;;               custom-set-faces blocks that Customize writes at the end.
;;               `custom-file' is deliberately left unset: that makes
;;               Customize save into the init file, keeping its
;;               machine-written forms out of config.el.
;;   config.el - your configuration. Edit that, not this.
;;   donkey/   - the donkey package (donkey/donkey.el, where its README
;;               expects it), fetched into /etc/skel by build.sh at image
;;               build time; loaded and enabled from config.el.

(let ((config (expand-file-name "config.el" user-emacs-directory)))
  (when (file-exists-p config)
    (load config nil t)))

;; Customize writes its custom-set-variables/custom-set-faces blocks below.

;;; init.el ends here
