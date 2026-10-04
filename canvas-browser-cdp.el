;;; canvas-browser-cdp.el --- The DevTools protocol of a headless chromium -*- lexical-binding: t -*-

;; Copyright (C) 2026 canvas-browser contributors

;; Author: Daskeladden
;; Version: 0.1.0
;; Keywords: hypermedia, tools
;; URL: https://github.com/Daskeladden/canvas-browser

;;; Commentary:
;; Emacs speaks the DevTools protocol itself: it starts one headless
;; chromium, connects to its websocket, sends commands with an id each,
;; and hands the answers and the events to the page buffers.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'websocket)

(defgroup canvas-browser nil
  "A web browser in an Emacs buffer, drawn on a canvas."
  :group 'applications
  :prefix "canvas-browser-")

(defcustom canvas-browser-chromium
  '("chromium" "chromium-browser" "google-chrome"
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
  "The names of the chromium to run, in the order they are looked for.
An absolute file name is taken as it is.  On macOS chromium lives inside
its application bundle, which is on no path, so the bundles are named
in full."
  :type '(repeat string)
  :group 'canvas-browser)

(defun canvas-browser-cdp--snap-executable-p (executable)
  "Whether the chromium EXECUTABLE is a snap."
  (string-prefix-p "/snap/" executable))

(defun canvas-browser-cdp-snap-home ()
  "The directory of the home that a snap chromium has for its own."
  (expand-file-name "snap/chromium/common" "~"))

(defun canvas-browser-cdp-snap-p ()
  "Whether the chromium in use is a snap."
  (canvas-browser-cdp--snap-executable-p (canvas-browser-cdp--executable)))

(defun canvas-browser-cdp--profile-for (executable)
  "Where the chromium EXECUTABLE keeps its profile.
A snap may write only outside the hidden directories of the home, so its
profile goes under ~/snap, where the snap has a place of its own."
  (if (canvas-browser-cdp--snap-executable-p executable)
      (expand-file-name "canvas-browser-profile" (canvas-browser-cdp-snap-home))
    (expand-file-name "canvas-browser/profile"
                      (or (getenv "XDG_CACHE_HOME") (expand-file-name "~/.cache")))))

(defcustom canvas-browser-profile-directory nil
  "Where chromium keeps its profile, so that a site stays logged in.
Nil lets `canvas-browser-cdp--profile-for' choose by the chromium found."
  :type '(choice (const :tag "By the chromium found" nil) directory)
  :group 'canvas-browser)

(defun canvas-browser-cdp--extensions-for (executable)
  "Where the chromium EXECUTABLE finds the extensions it loads.
A snap reads nothing in the hidden directories of the home, so its
extensions go under ~/snap, as its profile does."
  (if (canvas-browser-cdp--snap-executable-p executable)
      (expand-file-name "canvas-browser-extensions" (canvas-browser-cdp-snap-home))
    (expand-file-name "canvas-browser/extensions"
                      (or (getenv "XDG_DATA_HOME") (expand-file-name "~/.local/share")))))

(defcustom canvas-browser-extension-directory nil
  "The directory of the unpacked extensions chromium loads.
Each directory in it that holds a manifest.json is an extension, and
chromium loads every one when it starts.  Nil lets
`canvas-browser-cdp--extensions-for' choose by the chromium found.
`canvas-browser-install-ublock' puts uBlock Origin Lite there."
  :type '(choice (const :tag "By the chromium found" nil) directory)
  :group 'canvas-browser)

(defcustom canvas-browser-cdp-timeout 10
  "Seconds to wait for chromium to open its port."
  :type 'number
  :group 'canvas-browser)

(defvar canvas-browser-cdp--process nil
  "The chromium process, or nil.")

(defvar canvas-browser-cdp--socket nil
  "The websocket to chromium, or nil.")

(defun canvas-browser-cdp--executable ()
  "The chromium to run, or a user error that says what to install."
  (or (cl-some #'executable-find canvas-browser-chromium)
      (user-error (if (eq system-type 'darwin)
                      "canvas-browser: no chromium; run `brew install --cask google-chrome'"
                    "canvas-browser: no chromium; run `sudo snap install chromium'"))))

(defun canvas-browser-cdp--profile ()
  "The profile directory in use."
  (or canvas-browser-profile-directory
      (canvas-browser-cdp--profile-for (canvas-browser-cdp--executable))))

(defun canvas-browser-cdp-extension-directory ()
  "The extension directory in use."
  (or canvas-browser-extension-directory
      (canvas-browser-cdp--extensions-for (canvas-browser-cdp--executable))))

(defun canvas-browser-cdp--extensions ()
  "The directories of the extensions chromium loads, in the order of their names.
A hidden directory is left out: an extension is unpacked into one
before it takes its place."
  (let ((directory (canvas-browser-cdp-extension-directory)))
    (and (file-directory-p directory)
         (seq-filter (lambda (extension)
                       (file-exists-p (expand-file-name "manifest.json" extension)))
                     (directory-files directory t "\\`[^.]")))))

(defun canvas-browser-cdp--extension-flags ()
  "The flags that load the extensions, or nil when there are none.
The flag lists the directories with commas, so a directory whose name
holds one is an error rather than two wrong ones."
  (when-let* ((extensions (canvas-browser-cdp--extensions)))
    (dolist (extension extensions)
      (when (string-search "," extension)
        (error "canvas-browser: an extension's directory holds a comma: %s" extension)))
    (list (concat "--load-extension=" (string-join extensions ",")))))

(defun canvas-browser-cdp--port-file ()
  "The file in which chromium writes its port."
  (expand-file-name "DevToolsActivePort" (canvas-browser-cdp--profile)))

(defun canvas-browser-cdp--no-port-error ()
  "Say why no port file came, and signal it.
A chromium that exits at once handed its work to a chromium that already
uses the profile, and that one alone listens."
  (if (and canvas-browser-cdp--process (not (process-live-p canvas-browser-cdp--process)))
      (error "canvas-browser: chromium exited; another chromium uses the profile %s"
             (canvas-browser-cdp--profile))
    (error "canvas-browser: chromium did not open a port in %s seconds"
           canvas-browser-cdp-timeout)))

(defun canvas-browser-cdp--wait-for-port ()
  "Wait until chromium has written its port file, or signal an error."
  (let ((deadline (+ (float-time) canvas-browser-cdp-timeout)))
    (while (and (not (file-exists-p (canvas-browser-cdp--port-file)))
                (< (float-time) deadline))
      (sleep-for 0.05))
    (unless (file-exists-p (canvas-browser-cdp--port-file))
      (canvas-browser-cdp--no-port-error))))

(defun canvas-browser-cdp--address ()
  "The websocket address of the browser, once chromium has opened its port."
  (canvas-browser-cdp--wait-for-port)
  (with-temp-buffer
    (insert-file-contents (canvas-browser-cdp--port-file))
    (let ((port (string-trim (buffer-substring (point-min) (line-end-position))))
          (path (string-trim (buffer-substring (line-beginning-position 2) (point-max)))))
      (format "ws://127.0.0.1:%s%s" port path))))

;;;; The commands, their answers and the events

(defvar canvas-browser-cdp--id 0
  "The id of the last command sent.")

(defvar canvas-browser-cdp--waiting (make-hash-table :test #'eql)
  "The function that waits for the answer of each command id.")

(defvar canvas-browser-cdp--listeners (make-hash-table :test #'equal)
  "The functions that wait for an event, keyed by (SESSION . METHOD).")

(defvar canvas-browser-cdp--quiet (make-hash-table :test #'eql)
  "The ids of the commands whose refusal is no news to the reader.")

(defvar canvas-browser-cdp--sessions (make-hash-table :test #'eql)
  "The session each command id was sent in, until its answer comes.")

(defvar canvas-browser-cdp-session-lost-functions nil
  "Functions called with a session that chromium no longer knows.
Chromium answers every command of such a session with an error, so the
page of it would stop answering until it is attached again.")

(defun canvas-browser-cdp-send (method params &optional answer session)
  "Send METHOD with PARAMS to chromium, in SESSION when there is one.
ANSWER, a function of one plist, has the result when it arrives.  The
value is the id of the command, or nil when the connection refused it."
  (unless (canvas-browser-cdp-running-p)
    (user-error "canvas-browser: chromium is not connected"))
  (let* ((id (cl-incf canvas-browser-cdp--id))
         (command (append (list :id id :method method)
                          (when params (list :params params))
                          (when session (list :sessionId session)))))
    (when answer (puthash id answer canvas-browser-cdp--waiting))
    (when session (puthash id session canvas-browser-cdp--sessions))
    (condition-case nil
        (progn
          (websocket-send-text canvas-browser-cdp--socket (json-encode command))
          id)
      ;; A chromium that was killed is gone a moment before Emacs hears of
      ;; it, and its socket refuses what is sent meanwhile.  The command
      ;; is lost with the connection, which is said once, rather than an
      ;; error out of every timer, filter and hook that sends.
      (error
       (remhash id canvas-browser-cdp--waiting)
       (remhash id canvas-browser-cdp--quiet)
       (remhash id canvas-browser-cdp--sessions)
       (canvas-browser-cdp--closed canvas-browser-cdp--socket)
       nil))))

(defun canvas-browser-cdp-send-quietly (method params &optional answer session)
  "Send METHOD as `canvas-browser-cdp-send' does, but keep a refusal quiet.
Some commands are refused often and for nothing the reader can mend, as
a page whose rules forbid fetching its icon refuses it; ANSWER still has
nil then.  The id is put aside before the command goes, since its answer
may come while it is being sent."
  (let ((id (1+ canvas-browser-cdp--id)))
    (puthash id t canvas-browser-cdp--quiet)
    (condition-case failure
        (canvas-browser-cdp-send method params answer session)
      (error (remhash id canvas-browser-cdp--quiet)
             (signal (car failure) (cdr failure))))))

(defun canvas-browser-cdp-listen (session method function)
  "Have FUNCTION called with the parameters of METHOD in SESSION."
  (puthash (cons session method) function canvas-browser-cdp--listeners))

(defun canvas-browser-cdp-forget (session)
  "Drop every listener of SESSION."
  (maphash (lambda (key _function)
             (when (equal (car key) session)
               (remhash key canvas-browser-cdp--listeners)))
           canvas-browser-cdp--listeners))

(defun canvas-browser-cdp--receive (text)
  "Take TEXT, one message of chromium, to whoever waits for it."
  (let* ((message (json-parse-string text :object-type 'plist :array-type 'list))
         (id (plist-get message :id)))
    (if id
        (canvas-browser-cdp--answer id message)
      (canvas-browser-cdp--event message))))

(defun canvas-browser-cdp--answer (id message)
  "Give MESSAGE, the answer of the command ID, to the function that waits."
  (let* ((answer (gethash id canvas-browser-cdp--waiting))
         (failure (plist-get message :error))
         (session (gethash id canvas-browser-cdp--sessions))
         (lost (and failure session
                    (canvas-browser-cdp--session-lost-p (plist-get failure :message))))
         (quiet (or lost (gethash id canvas-browser-cdp--quiet))))
    (remhash id canvas-browser-cdp--waiting)
    (remhash id canvas-browser-cdp--quiet)
    (remhash id canvas-browser-cdp--sessions)
    (when (and failure (not quiet))
      (message "canvas-browser: chromium says: %s" (plist-get failure :message)))
    (when answer
      ;; A refused command answers with nothing, so that a caller which
      ;; put something aside while it waited can put it back.
      (funcall answer (and (not failure) (plist-get message :result))))
    ;; The page of a lost session is brought back rather than left to
    ;; fail at every command; the reader needs no word of it.
    (when lost
      (run-hook-with-args 'canvas-browser-cdp-session-lost-functions session))))

(defun canvas-browser-cdp--session-lost-p (text)
  "Whether TEXT, the message of an error, says chromium knows no such session."
  (and (stringp text) (string-search "Session with given id not found" text) t))

(defun canvas-browser-cdp--event (message)
  "Give MESSAGE, an event, to the listener of its session and method."
  (when-let* ((function (gethash (cons (plist-get message :sessionId)
                                       (plist-get message :method))
                                 canvas-browser-cdp--listeners)))
    (funcall function (plist-get message :params))))

;;;; Starting and stopping

(defun canvas-browser-cdp-running-p ()
  "Whether chromium runs and its websocket is open.
A chromium that has gone leaves a websocket whose connection is no
process, and the websocket library answers such a socket with a type
error rather than with no."
  (and canvas-browser-cdp--socket
       (canvas-browser-cdp--socket-live-p canvas-browser-cdp--socket)))

(defun canvas-browser-cdp--socket-live-p (socket)
  "Whether the connection of SOCKET is a process that lives."
  (let ((process (websocket-conn socket)))
    (and (processp process) (process-live-p process) t)))

(defcustom canvas-browser-headless nil
  "Whether chromium runs without a window of its own.
A headless chromium says so in its user agent, keeps `navigator.webdriver\='
true and has no WebGL at all, and a site behind a bot check reads all
three: it then asks the reader to pick out traffic lights rather than to
tick a box.  A chromium with a window reads as the browser it is.
This is the older name of `canvas-browser-window-strategy\=' set to
`headless\=', and is heard only while that is left at its default; set
that one instead."
  :type 'boolean
  :group 'canvas-browser)

(defun canvas-browser-cdp--default-window-strategy ()
  "The window strategy of this system: `virtual-display\=' on macOS, else `xvfb\='."
  (if (eq system-type 'darwin) 'virtual-display 'xvfb))

(defcustom canvas-browser-window-strategy (canvas-browser-cdp--default-window-strategy)
  "How chromium gets a window that nobody looks at.
`xvfb\=': a window on an X display of its own, `canvas-browser-display\=',
where `Xvfb\=' is started.  This needs an X server, so it is for Linux.
`headless\=': no window at all.  Sites behind a bot check can tell; see
`canvas-browser-headless\='.
`virtual-display\=': a window on a display of macOS that nobody sees,
made by `canvas-browser-virtual-display-program\=' and put past the
corner of your main display.  This is for macOS, where chromium draws
on no X display.  Without the program it is `offscreen\='.
`offscreen\=': a window on your own screen, pushed past its corner.
macOS keeps a corner of each window on the screen, and a window behind
Emacs is out of sight.
Every window a page opens later goes where the first one went.
The default is `virtual-display\=' on macOS and `xvfb\=' elsewhere.
While this is left at its default, a non-nil `canvas-browser-headless\='
means `headless\='."
  :type '(choice (const :tag "A window on an X display of its own" xvfb)
                 (const :tag "No window" headless)
                 (const :tag "A window on a display nobody sees" virtual-display)
                 (const :tag "A window past the corner of your screen" offscreen))
  :group 'canvas-browser)

(defconst canvas-browser-cdp--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "The directory canvas-browser is loaded from.")

(defcustom canvas-browser-virtual-display-program
  (expand-file-name "canvas-browser-display" canvas-browser-cdp--directory)
  "The program that makes the display nobody sees, on macOS.
`make display\=' builds it from canvas-browser-display.swift, next to
this file.  It prints where the display is and keeps it until it ends."
  :type 'file
  :group 'canvas-browser)

(defvar canvas-browser-cdp--fallback nil
  "Why the virtual display did not start, or nil.
Windows go past the corner of the screen instead, until chromium is
started again.")

(defvar canvas-browser-cdp--fallback-told nil
  "Whether the reader has heard why the virtual display did not start.")

(defun canvas-browser-cdp-window-strategy ()
  "The way chromium gets its window, from the settings.
`canvas-browser-headless\=' came first, so a setting of it still counts
until the new setting is changed from its default.  A virtual display
that did not start leaves the windows off screen instead."
  (let ((strategy (if (and canvas-browser-headless
                           (eq canvas-browser-window-strategy
                               (canvas-browser-cdp--default-window-strategy)))
                      'headless
                    canvas-browser-window-strategy)))
    (if (and (eq strategy 'virtual-display) canvas-browser-cdp--fallback)
        'offscreen
      strategy)))

(defun canvas-browser-cdp--hidden-p ()
  "Whether the windows of chromium are on your own screen, kept out of sight.
On macOS a display nobody sees is still one of your screens: chromium
comes to the front with each window it opens there."
  (memq (canvas-browser-cdp-window-strategy) '(virtual-display offscreen)))

(defconst canvas-browser-cdp--offscreen '(:left 20000 :top 20000 :width 100 :height 100)
  "Where a window goes to be out of sight, as far as chromium lets it.
Chromium keeps a window on a screen and no smaller than its least size,
so this puts the window in the far corner with a few pixels showing.
A window that is minimized, or whose application is hidden, would show
nothing, but a page loaded into it draws nothing either and sends no
frame: macOS tells chromium it is not visible.")

(defvar canvas-browser-cdp--virtual-display nil
  "Where the virtual display is, as (:left :top :width :height), or nil.")

(defun canvas-browser-cdp--hidden-bounds ()
  "Where a window goes to be out of sight, as bounds of chromium.
That is the whole virtual display, or else past the corner of the screen."
  (or (and (eq (canvas-browser-cdp-window-strategy) 'virtual-display)
           canvas-browser-cdp--virtual-display)
      canvas-browser-cdp--offscreen))

(defun canvas-browser-cdp-target-window (new-window)
  "The parameters of `Target.createTarget\=' that say where a page opens.
NEW-WINDOW non-nil asks for a window of its own.  Out of sight, every
page gets one, made where it is out of sight, so that no window comes
into view first, and no page is a tab behind another, which chromium
hides."
  (if (canvas-browser-cdp--hidden-p)
      (append '(:newWindow t) (canvas-browser-cdp--hidden-bounds))
    (and new-window '(:newWindow t))))

(defun canvas-browser-cdp--refocus ()
  "Give the focus back to Emacs, which chromium took with a window it opened.
On macOS chromium comes to the front with every window it opens, though
the window is out of sight, and the keys would go to it."
  (when (and (canvas-browser-cdp--hidden-p)
             (eq (framep (selected-frame)) 'ns))
    (select-frame-set-input-focus (selected-frame))))

(defun canvas-browser-cdp-put-away-window (target)
  "Put the window of TARGET, a page, out of sight, when windows are kept so.
A window a page opens to sign in opens where chromium likes, which may
be in view, so it is moved as soon as it is heard of; a window Emacs
opened is there already.  Either way Emacs takes the focus back."
  (when (canvas-browser-cdp--hidden-p)
    (canvas-browser-cdp-send
     "Browser.getWindowForTarget" (list :targetId target)
     (lambda (result)
       (when-let* ((window (plist-get result :windowId))
                   (bounds (plist-get result :bounds))
                   ((canvas-browser-cdp-running-p)))
         ;; A window the reader has minimized or made full by hand takes
         ;; no place; it is left as it is.
         (when (equal (plist-get bounds :windowState) "normal")
           (canvas-browser-cdp-send
            "Browser.setWindowBounds"
            (list :windowId window :bounds (canvas-browser-cdp--hidden-bounds))))
         (canvas-browser-cdp--refocus))))))

;;;; The virtual display

(defvar canvas-browser-cdp--display-process nil
  "The process that keeps the virtual display, or nil.")

(defun canvas-browser-cdp--read-display (text)
  "The place and size of the virtual display that TEXT, its first line, gives.
The line is \"LEFT TOP WIDTH HEIGHT\"; anything else is an error."
  (let ((numbers (mapcar #'string-to-number
                         (split-string (car (split-string text "\n")) " " t))))
    (unless (and (= (length numbers) 4) (> (nth 2 numbers) 0) (> (nth 3 numbers) 0))
      (error "The virtual display said %S" (string-trim text)))
    (list :left (nth 0 numbers) :top (nth 1 numbers)
          :width (nth 2 numbers) :height (nth 3 numbers))))

(defun canvas-browser-cdp--display-ended (process _event)
  "Stop chromium when PROCESS, the one keeping the virtual display, has ended.
macOS moves the windows of a display that goes onto the main display, in
view, so chromium is not left with them."
  (when (and (eq process canvas-browser-cdp--display-process)
             (not (process-live-p process)))
    (setq canvas-browser-cdp--display-process nil
          canvas-browser-cdp--virtual-display nil)
    (when canvas-browser-cdp--process
      (message "canvas-browser: the virtual display went away; chromium is stopped")
      (canvas-browser-cdp-stop))))

(defun canvas-browser-cdp--run-display ()
  "Start the program of the virtual display and read where the display is.
Signal an error that says why, when it cannot."
  (let ((program canvas-browser-virtual-display-program))
    (unless (file-executable-p program)
      (error "No %s" (abbreviate-file-name program)))
    (let* ((buffer (get-buffer-create " *canvas-browser-virtual-display*"))
           (process (progn
                      (with-current-buffer buffer (erase-buffer))
                      (make-process :name "canvas-browser-virtual-display"
                                    :buffer buffer
                                    :noquery t
                                    ;; The program ends when its input
                                    ;; closes, as it does when Emacs does.
                                    :connection-type 'pipe
                                    :command (list program)
                                    :sentinel #'canvas-browser-cdp--display-ended)))
           (deadline (+ (float-time) canvas-browser-cdp-timeout))
           (line-p (lambda ()
                     (with-current-buffer buffer
                       (string-search "\n" (buffer-string))))))
      (setq canvas-browser-cdp--display-process process)
      (while (and (process-live-p process)
                  (not (funcall line-p))
                  (< (float-time) deadline))
        (accept-process-output process 0.05))
      (condition-case failure
          (setq canvas-browser-cdp--virtual-display
                (canvas-browser-cdp--read-display
                 (with-current-buffer buffer (buffer-string))))
        (error
         (setq canvas-browser-cdp--display-process nil)
         (delete-process process)
         (signal (car failure) (cdr failure)))))
    ;; Emacs may end while chromium runs; chromium goes first, so that
    ;; its windows do not come into view.
    (add-hook 'kill-emacs-hook #'canvas-browser-cdp-stop)))

(defun canvas-browser-cdp--ensure-virtual-display ()
  "Have the virtual display, or else keep the windows past the corner.
When the display cannot be had, the reader is told why, once."
  (setq canvas-browser-cdp--fallback nil)
  (unless (and canvas-browser-cdp--display-process
               (process-live-p canvas-browser-cdp--display-process)
               canvas-browser-cdp--virtual-display)
    (condition-case failure
        (canvas-browser-cdp--run-display)
      (error
       (setq canvas-browser-cdp--fallback (error-message-string failure))
       (unless canvas-browser-cdp--fallback-told
         (setq canvas-browser-cdp--fallback-told t)
         (message (concat "canvas-browser: %s; windows go past the corner of the"
                          " screen instead.  Run `make display' in %s to build"
                          " the virtual display")
                  canvas-browser-cdp--fallback
                  (abbreviate-file-name canvas-browser-cdp--directory)))))))

(defun canvas-browser-cdp--stop-display ()
  "Stop the program of the virtual display, which takes the display away."
  (when-let* ((process canvas-browser-cdp--display-process))
    (setq canvas-browser-cdp--display-process nil
          canvas-browser-cdp--virtual-display nil)
    (delete-process process)))

(defcustom canvas-browser-display ":98"
  "The X display chromium draws its window on.
A display of its own is where a window nobody looks at belongs.  The page
is read through the screencast, so nothing of it travels to your own
display, which matters when that display is forwarded over ssh.  `Xvfb\='
is started on this one when nothing listens there yet."
  :type 'string
  :group 'canvas-browser)

(defconst canvas-browser-cdp--screen "2560x1440x24"
  "The screen `Xvfb\=' is given, wide enough for any window of a page.")

(defconst canvas-browser-cdp--window-size "1920,1200"
  "The window chromium opens, which the page layout then overrides.")

(defun canvas-browser-cdp--display-socket (display)
  "The file an X server listens on for DISPLAY.
One socket serves every screen of a display, so the screen after the dot
is left off."
  (let ((number (car (split-string (string-remove-prefix ":" display) "\\."))))
    (format "/tmp/.X11-unix/X%s" number)))

(defun canvas-browser-cdp--display-live-p (display)
  "Whether an X server listens on DISPLAY."
  (file-exists-p (canvas-browser-cdp--display-socket display)))

(defun canvas-browser-cdp--wait-for-display ()
  "Wait until `canvas-browser-display\=' answers, or signal an error."
  (let ((deadline (+ (float-time) canvas-browser-cdp-timeout)))
    (while (and (not (canvas-browser-cdp--display-live-p canvas-browser-display))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless (canvas-browser-cdp--display-live-p canvas-browser-display)
      (error "canvas-browser: Xvfb did not open %s in %s seconds"
             canvas-browser-display canvas-browser-cdp-timeout))))

(defun canvas-browser-cdp--ensure-display ()
  "Have an X server on `canvas-browser-display\=', starting `Xvfb\=' if need be.
The display listens on its socket alone, never on the network."
  (unless (canvas-browser-cdp--display-live-p canvas-browser-display)
    (unless (executable-find "Xvfb")
      (user-error (concat "canvas-browser: no Xvfb; run `sudo apt install xvfb',"
                          " or set `canvas-browser-window-strategy'")))
    (make-process :name "canvas-browser-xvfb"
                  :buffer (get-buffer-create " *canvas-browser-xvfb*")
                  :noquery t
                  :command (list "Xvfb" canvas-browser-display
                                 "-screen" "0" canvas-browser-cdp--screen
                                 "-nolisten" "tcp" "-ac"))
    (canvas-browser-cdp--wait-for-display)))

(defun canvas-browser-cdp--environment ()
  "The environment chromium is started in.
Only a window on `Xvfb\=' is told where to draw; the others draw on no
display or on your own screen."
  (if (eq (canvas-browser-cdp-window-strategy) 'xvfb)
      (cons (format "DISPLAY=%s" canvas-browser-display) process-environment)
    process-environment))

(defun canvas-browser-cdp--command-line ()
  "The command line of chromium, with a window of its own or without one."
  (append (list (canvas-browser-cdp--executable)
                "--remote-debugging-port=0"
                "--remote-allow-origins=*"
                (format "--user-data-dir=%s" (canvas-browser-cdp--profile)))
          (canvas-browser-cdp--extension-flags)
          (if (eq (canvas-browser-cdp-window-strategy) 'headless)
              (list "--headless=new")
            ;; A window nobody looks at is a window chromium would throttle
            ;; or stop drawing, and a page that stops drawing sends no frames.
            ;; On macOS a window off screen drew at full speed with and
            ;; without these flags; they are kept since they cost nothing.
            (append
             (list "--no-first-run"
                   "--no-default-browser-check"
                   "--disable-background-timer-throttling"
                   "--disable-backgrounding-occluded-windows"
                   "--disable-renderer-backgrounding"
                   ;; The reader drives this browser by hand, one key at a
                   ;; time, and the flag that tells a page a robot does is
                   ;; wrong about it.
                   "--disable-blink-features=AutomationControlled"
                   (format "--window-size=%s" canvas-browser-cdp--window-size))
             ;; An X server of its own has no graphics card, so WebGL is
             ;; drawn in software rather than not at all, which is also
             ;; what a page asks it about.  Only WebGL: drawing the whole
             ;; window that way costs two cores.  A window on your own
             ;; screen has the graphics card of the machine, and a WebGL
             ;; that names it reads as any Chrome, where one that names
             ;; SwiftShader would not.
             (when (eq (canvas-browser-cdp-window-strategy) 'xvfb)
               (list "--enable-unsafe-swiftshader"))
             ;; The first window would open in view; each page opens a
             ;; window of its own out of sight instead.
             (when (canvas-browser-cdp--hidden-p)
               (list "--no-startup-window"))))))

(defun canvas-browser-cdp--open-p (socket)
  "Whether SOCKET has finished shaking hands."
  (eq (websocket-ready-state socket) 'open))

(defun canvas-browser-cdp--wait-until-open (socket)
  "Wait until SOCKET has finished shaking hands, or signal an error.
A command sent while it connects reaches nobody."
  (let ((deadline (+ (float-time) canvas-browser-cdp-timeout)))
    (while (and (not (canvas-browser-cdp--open-p socket))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (unless (canvas-browser-cdp--open-p socket)
      (error "canvas-browser: chromium did not answer the websocket in %s seconds"
             canvas-browser-cdp-timeout))
    socket))

(defvar canvas-browser-cdp-lost-hook nil
  "Run when the websocket to chromium closes without Emacs closing it.
Chromium may still run then: only the connection is gone.  The hook
runs from a timer, out of the websocket library's own code.")

(defvar canvas-browser-cdp--why-closed nil
  "What the system said when the connection of the websocket last changed.")

(defun canvas-browser-cdp--closed (socket)
  "Forget SOCKET, which has closed, if it is the websocket in use.
A socket Emacs closed itself is no longer the one in use, so neither it
nor one replaced since then says that the connection was lost.  The
reader is told when, and what the system said: the websocket library
keeps no ping and no time limit, so a lost connection is the system's
or chromium's doing, and the time tells it from a sleep of the machine."
  (when (eq socket canvas-browser-cdp--socket)
    (setq canvas-browser-cdp--socket nil)
    (message "canvas-browser: the connection to chromium closed at %s (%s)"
             (format-time-string "%F %T")
             (or canvas-browser-cdp--why-closed "no reason given"))
    (run-at-time 0 nil #'run-hooks 'canvas-browser-cdp-lost-hook)))

(defun canvas-browser-cdp--hear-why-closed (socket)
  "Keep what the system says when the connection of SOCKET changes.
The websocket library tells its caller that a socket closed, but not why."
  (when-let* (((websocket-p socket))
              (connection (websocket-conn socket))
              ((processp connection)))
    (setq canvas-browser-cdp--why-closed nil)
    (add-function :before (process-sentinel connection)
                  (lambda (_process change)
                    ;; A socket replaced since then says nothing of this one.
                    (when (eq socket canvas-browser-cdp--socket)
                      (setq canvas-browser-cdp--why-closed (string-trim change)))))))

(defun canvas-browser-cdp--connect ()
  "Connect to the browser of the chromium that runs, once it answers."
  (let ((socket (websocket-open
                 (canvas-browser-cdp--address)
                 :on-message (lambda (_socket frame)
                               (canvas-browser-cdp--receive (websocket-frame-text frame)))
                 :on-close #'canvas-browser-cdp--closed)))
    (canvas-browser-cdp--hear-why-closed socket)
    (canvas-browser-cdp--wait-until-open socket)))

(defun canvas-browser-cdp--forget-commands ()
  "Forget the commands and the listeners of a connection that has gone.
Its answers will never come, and its sessions are no longer chromium's."
  (clrhash canvas-browser-cdp--waiting)
  (clrhash canvas-browser-cdp--quiet)
  (clrhash canvas-browser-cdp--sessions)
  (clrhash canvas-browser-cdp--listeners))

(defun canvas-browser-cdp-alive-p ()
  "Whether the chromium Emacs started still runs."
  (and (processp canvas-browser-cdp--process)
       (process-live-p canvas-browser-cdp--process)
       t))

(defun canvas-browser-cdp--reconnect ()
  "Connect again to the chromium that runs; whether that worked.
The websocket may close while chromium goes on, and chromium then still
holds the profile: a second one started on it would hand its work to the
first and exit, and nothing would answer.  A chromium that does not
answer is stopped instead, so that a new one can take the profile."
  (when (and (canvas-browser-cdp-alive-p)
             (file-exists-p (canvas-browser-cdp--port-file)))
    (condition-case nil
        (progn
          (canvas-browser-cdp--forget-commands)
          (setq canvas-browser-cdp--socket (canvas-browser-cdp--connect))
          t)
      (error
       (message "canvas-browser: chromium does not answer; stopping it")
       (canvas-browser-cdp-stop 'keep-display)
       nil))))

(defun canvas-browser-cdp--launch ()
  "Start chromium and connect to it."
  ;; The command line names the chromium, and a machine without one
  ;; says so before an X server is started for it.
  (let ((command (canvas-browser-cdp--command-line)))
    (pcase (canvas-browser-cdp-window-strategy)
      ('xvfb (canvas-browser-cdp--ensure-display))
      ('virtual-display (canvas-browser-cdp--ensure-virtual-display)))
    (let ((process-environment (canvas-browser-cdp--environment)))
      (make-directory (canvas-browser-cdp--profile) t)
      (ignore-errors (delete-file (canvas-browser-cdp--port-file)))
      (canvas-browser-cdp--forget-commands)
      (setq canvas-browser-cdp--process
            (make-process :name "canvas-browser-chromium"
                          :buffer (get-buffer-create " *canvas-browser-chromium*")
                          :noquery t
                          :command command)))
    (setq canvas-browser-cdp--socket (canvas-browser-cdp--connect))))

(defun canvas-browser-cdp-start (&optional connect-only)
  "Start chromium and connect to it, unless that has happened already.
A chromium that runs but has lost its websocket is connected to again.
The value says what happened: `connected\=' for a chromium connected to
again, whose pages are all there still, `started\=' for a new one, which
has none, and nil when nothing was done.  With CONNECT-ONLY no chromium
is started: only one that runs is connected to."
  (cond
   ((canvas-browser-cdp-running-p) nil)
   ((canvas-browser-cdp--reconnect) 'connected)
   (connect-only nil)
   (t (canvas-browser-cdp--launch) 'started)))

(defun canvas-browser-cdp--wait-for-exit (process)
  "Wait a moment for PROCESS, which was killed, to be gone from the system.
Emacs forgets a process it kills at once, but the system takes a moment
to end it."
  (when-let* (((processp process))
              (pid (process-id process)))
    (let ((deadline (+ (float-time) 1)))
      (while (and (let ((state (alist-get 'state (process-attributes pid))))
                    (and state (not (equal state "Z"))))
                  (< (float-time) deadline))
        (sleep-for 0.01)))))

(defun canvas-browser-cdp-stop (&optional keep-display)
  "Close the websocket, stop chromium, and then its virtual display.
The display goes last: macOS would move the windows still on it onto
your own screen.  With KEEP-DISPLAY the display stays, for the chromium
started next: each display that comes or goes has ColorSync rebuild the
colour profiles of every display, and one more change while it is at
it has been seen to keep it at that for as long as the display lasts."
  (when-let* ((socket canvas-browser-cdp--socket))
    ;; The socket is forgotten before it is closed, so that its closing
    ;; is not taken for a connection lost.
    (setq canvas-browser-cdp--socket nil)
    ;; A socket whose chromium has gone has no process to close, and
    ;; closing it reaches for one.
    (when (canvas-browser-cdp--socket-live-p socket)
      (websocket-close socket)))
  (when canvas-browser-cdp--process
    (let ((process canvas-browser-cdp--process))
      (setq canvas-browser-cdp--process nil)
      (delete-process process)
      ;; A chromium started next on the profile hands its work to this
      ;; one while it is still there.
      (canvas-browser-cdp--wait-for-exit process)))
  (unless keep-display
    (canvas-browser-cdp--stop-display))
  (canvas-browser-cdp--forget-commands))

(provide 'canvas-browser-cdp)
;;; canvas-browser-cdp.el ends here
