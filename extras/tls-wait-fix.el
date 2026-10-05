;;; tls-wait-fix.el --- Keep a wait from spinning on a TLS handshake  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs 32.0.50, the master of October 2026, has a bug that can freeze
;; it at 100% CPU.  While a TLS connection is still shaking hands, a
;; call to (accept-process-output PROC SECONDS) for another process
;; never returns once it has read output from PROC, and SECONDS is not
;; kept.  Emacs does not go on with the handshake while it waits for
;; another process, so the socket stays readable but nothing is read
;; from it, and the loop that waits goes round on it without end.
;;
;; canvas-browser opens such connections: a tab fetches the icon of its
;; page with `url-retrieve'.  Its own waits pass JUST-THIS-ONE, which
;; keeps them out of the bug.  Other packages wait the same way, migemo,
;; emacsql and pdf-tools among them, and can freeze while a tab fetches
;; its icon.  This advice passes JUST-THIS-ONE for them as well, and
;; only while another network process is connecting.  JUST-THIS-ONE is
;; t and not a number, so timers still run while it waits.
;;
;; Load it before the other packages, and remove it once Emacs is fixed.

;;; Code:

(require 'seq)

(defun tls-wait-fix--connecting-p (except)
  "Whether a network process other than EXCEPT is connecting."
  (seq-some (lambda (process)
              (and (not (eq process except))
                   (eq (process-type process) 'network)
                   (eq (process-status process) 'connect)))
            (process-list)))

(defun tls-wait-fix--args (args)
  "ARGS of `accept-process-output', with JUST-THIS-ONE t where needed."
  (let ((process (nth 0 args)))
    (if (and (processp process)
             (not (nth 3 args))
             (tls-wait-fix--connecting-p process))
        (list process (nth 1 args) (nth 2 args) t)
      args)))

(advice-add 'accept-process-output :filter-args #'tls-wait-fix--args)

(provide 'tls-wait-fix)
;;; tls-wait-fix.el ends here
