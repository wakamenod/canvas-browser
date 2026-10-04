;;; canvas-browser-cdp-tests.el --- tests of the protocol client -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'canvas-browser-cdp)

(defvar canvas-browser-test--sent nil
  "What Emacs sent to chromium, newest first.")

(defmacro canvas-browser-test--with-stub (&rest body)
  "Run BODY with the websocket and the process stubbed.
`canvas-browser-test--sent' holds what Emacs sent, newest first."
  (declare (indent 0))
  `(let ((canvas-browser-test--sent nil)
         (canvas-browser-cdp--socket 'stub)
         (canvas-browser-cdp--process 'stub))
     (cl-letf (((symbol-function 'websocket-send-text)
                (lambda (_socket text)
                  (push (json-parse-string text :object-type 'plist :array-type 'list)
                        canvas-browser-test--sent)))
               ((symbol-function 'canvas-browser-cdp--socket-live-p) (lambda (_socket) t)))
       ,@body)))

;;;; The process and its port

(ert-deftest canvas-browser-cdp-start-needs-chromium ()
  ;; GIVEN no chromium on the path
  ;; WHEN the client starts
  ;; THEN it is a user error that names what to install
  (let ((canvas-browser-cdp--socket nil)
        (canvas-browser-headless t)
        (system-type 'gnu/linux))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (let ((error-text (error-message-string
                         (should-error (canvas-browser-cdp-start) :type 'user-error))))
        (should (string-search "snap install chromium" error-text))))))

(ert-deftest canvas-browser-cdp-a-mac-without-chromium-is-told-to-install-chrome ()
  ;; GIVEN a Mac with no chromium
  ;; WHEN the client starts
  ;; THEN the user error names the cask of Chrome, since there is no snap
  (let ((canvas-browser-cdp--socket nil)
        (canvas-browser-headless t)
        (system-type 'darwin))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (should (string-search "brew install --cask google-chrome"
                             (error-message-string
                              (should-error (canvas-browser-cdp-start) :type 'user-error)))))))

(ert-deftest canvas-browser-cdp-finds-chrome-inside-its-mac-bundle ()
  ;; GIVEN a Mac whose only chromium is Google Chrome in /Applications
  ;; WHEN the chromium to run is looked for
  ;; THEN the executable inside the bundle is found by its full name
  (let ((chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name) (and (equal name chrome) name))))
      (should (equal (canvas-browser-cdp--executable) chrome)))))

(ert-deftest canvas-browser-cdp-reads-the-address-from-the-port-file ()
  ;; GIVEN a profile directory holding a DevToolsActivePort file
  ;; WHEN the address of the browser is read
  ;; THEN it is the websocket address of that port and path
  (let* ((directory (make-temp-file "canvas-browser-test-" t))
         (canvas-browser-profile-directory directory))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "DevToolsActivePort" directory)
            (insert "45678\n/devtools/browser/abc-123\n"))
          (should (equal (canvas-browser-cdp--address)
                         "ws://127.0.0.1:45678/devtools/browser/abc-123")))
      (delete-directory directory t))))

(ert-deftest canvas-browser-cdp-waits-for-the-port-file ()
  ;; GIVEN a profile directory without the file
  ;; WHEN the address is read
  ;; THEN it is an error that says chromium did not open a port
  (let* ((directory (make-temp-file "canvas-browser-test-" t))
         (canvas-browser-profile-directory directory)
         (canvas-browser-cdp-timeout 0.2))
    (unwind-protect
        (should (string-search "did not open"
                               (error-message-string
                                (should-error (canvas-browser-cdp--address)))))
      (delete-directory directory t))))

;;;; The commands and the events

(ert-deftest canvas-browser-cdp-send-numbers-its-commands ()
  ;; GIVEN the client connected to a stub
  ;; WHEN two commands are sent
  ;; THEN each carries its own id, its method and its parameters
  (canvas-browser-test--with-stub
    (canvas-browser-cdp-send "Page.enable" nil)
    (canvas-browser-cdp-send "Page.navigate" '(:url "https://example.org"))
    (let ((sent (nreverse canvas-browser-test--sent)))
      (should (equal (plist-get (nth 0 sent) :method) "Page.enable"))
      (should (equal (plist-get (nth 1 sent) :method) "Page.navigate"))
      (should (< (plist-get (nth 0 sent) :id) (plist-get (nth 1 sent) :id)))
      (should (equal (plist-get (plist-get (nth 1 sent) :params) :url) "https://example.org")))))

(ert-deftest canvas-browser-cdp-an-answer-reaches-the-waiting-call ()
  ;; GIVEN a command sent with a function for its answer
  ;; WHEN the answer of that id arrives, and then a second answer of the
  ;;      same id
  ;; THEN the function has the first result only
  (canvas-browser-test--with-stub
    (let ((answers nil))
      (canvas-browser-cdp-send "Target.createTarget" '(:url "about:blank")
                               (lambda (result) (push result answers)))
      (let ((id (plist-get (car canvas-browser-test--sent) :id)))
        (canvas-browser-cdp--receive (json-encode `(:id ,id :result (:targetId "T1"))))
        (canvas-browser-cdp--receive (json-encode `(:id ,id :result (:targetId "T2")))))
      (should (equal (mapcar (lambda (result) (plist-get result :targetId)) answers) '("T1"))))))

(ert-deftest canvas-browser-cdp-an-error-of-chromium-reaches-the-reader ()
  ;; GIVEN a command that chromium refuses
  ;; WHEN its answer arrives
  ;; THEN the message of chromium is said, AND the waiting function is
  ;;      called with nothing: a caller that put something aside while it
  ;;      waited, as the frames of a page are, gets to put it back
  (canvas-browser-test--with-stub
    (let ((said nil) (answered 'nothing))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq said (apply #'format format args)))))
        (canvas-browser-cdp-send "Page.navigate" '(:url "nonsense")
                                 (lambda (result) (setq answered result)))
        (let ((id (plist-get (car canvas-browser-test--sent) :id)))
          (canvas-browser-cdp--receive
           (json-encode `(:id ,id :error (:code -32000 :message "Cannot navigate"))))))
      (should (string-search "Cannot navigate" said))
      (should-not answered))))

(ert-deftest canvas-browser-cdp-events-reach-the-session-that-listens ()
  ;; GIVEN two sessions, each listening for a method
  ;; WHEN an event of one session arrives
  ;; THEN only that session's function has it, with the parameters
  (canvas-browser-test--with-stub
    (let ((first nil) (second nil))
      (canvas-browser-cdp-listen "S1" "Page.screencastFrame" (lambda (params) (push params first)))
      (canvas-browser-cdp-listen "S2" "Page.screencastFrame" (lambda (params) (push params second)))
      (canvas-browser-cdp--receive
       (json-encode '(:method "Page.screencastFrame" :sessionId "S1" :params (:data "AAA"))))
      (should (equal (mapcar (lambda (params) (plist-get params :data)) first) '("AAA")))
      (should-not second))))

(ert-deftest canvas-browser-cdp-forgetting-a-session-drops-its-listeners ()
  ;; GIVEN a session that listens
  ;; WHEN the session is forgotten and its event arrives
  ;; THEN nothing is called
  (canvas-browser-test--with-stub
    (let ((seen nil))
      (canvas-browser-cdp-listen "S1" "Page.loadEventFired" (lambda (_params) (setq seen t)))
      (canvas-browser-cdp-forget "S1")
      (canvas-browser-cdp--receive (json-encode '(:method "Page.loadEventFired" :sessionId "S1")))
      (should-not seen))))

;;;; Starting and stopping

(ert-deftest canvas-browser-cdp-a-display-of-its-own-is-named-by-its-socket ()
  ;; GIVEN the names an X display goes by
  ;; WHEN its socket is worked out
  ;; THEN the screen after the dot is left off, because one socket
  ;;      serves every screen of a display
  (should (equal (canvas-browser-cdp--display-socket ":98") "/tmp/.X11-unix/X98"))
  (should (equal (canvas-browser-cdp--display-socket ":98.0") "/tmp/.X11-unix/X98")))

(ert-deftest canvas-browser-cdp-a-display-is-started-only-when-there-is-none ()
  ;; GIVEN a display nothing listens on, and then one that is up
  ;; WHEN chromium is about to be given a display
  ;; THEN Xvfb is started the first time and left alone the second
  (let ((started nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (name) (concat "/usr/bin/" name)))
              ((symbol-function 'make-process)
               (lambda (&rest args) (setq started (plist-get args :command)) 'process))
              ((symbol-function 'canvas-browser-cdp--display-live-p)
               (lambda (_display) nil))
              ((symbol-function 'canvas-browser-cdp--wait-for-display) #'ignore))
      (canvas-browser-cdp--ensure-display)
      (should (equal (car started) "Xvfb"))
      (should (member canvas-browser-display started)))
    (setq started nil)
    (cl-letf (((symbol-function 'canvas-browser-cdp--display-live-p) (lambda (_display) t))
              ((symbol-function 'make-process)
               (lambda (&rest args) (setq started (plist-get args :command)) 'process)))
      (canvas-browser-cdp--ensure-display)
      (should-not started))))

(ert-deftest canvas-browser-cdp-a-missing-xvfb-says-what-to-install ()
  ;; GIVEN a machine without Xvfb
  ;; WHEN chromium is about to be given a display of its own
  ;; THEN the reader is told what to install, and what to set instead
  (cl-letf (((symbol-function 'executable-find) (lambda (_name) nil))
            ((symbol-function 'canvas-browser-cdp--display-live-p) (lambda (_display) nil)))
    (let ((raised (should-error (canvas-browser-cdp--ensure-display) :type 'user-error)))
      (should (string-search "xvfb" (cadr raised)))
      (should (string-search "canvas-browser-window-strategy" (cadr raised))))))

(ert-deftest canvas-browser-cdp-a-chromium-with-a-window-is-not-headless ()
  ;; GIVEN the setting for a chromium with a window of its own
  ;; WHEN its command line is made
  ;; THEN it is not headless, it is not throttled for a window nobody
  ;;      looks at, AND it is told the display to draw on
  (cl-letf (((symbol-function 'executable-find) (lambda (name) (concat "/usr/bin/" name))))
    (let* ((canvas-browser-headless nil)
           (canvas-browser-window-strategy 'xvfb)
           (command (canvas-browser-cdp--command-line))
           (environment (canvas-browser-cdp--environment)))
      (should-not (member "--headless=new" command))
      (should (member "--disable-backgrounding-occluded-windows" command))
      (should (member "--disable-renderer-backgrounding" command))
      (should (member "--disable-background-timer-throttling" command))
      ;; The reader drives this browser by hand: the flag that says a
      ;; robot does, and the missing WebGL of a machine without a card,
      ;; are both answers this browser would give wrongly.
      (should (member "--disable-blink-features=AutomationControlled" command))
      (should (member "--enable-unsafe-swiftshader" command))
      (should (member (format "DISPLAY=%s" canvas-browser-display) environment)))))

(ert-deftest canvas-browser-cdp-a-headless-chromium-keeps-your-display-out-of-it ()
  ;; GIVEN the setting for a headless chromium
  ;; WHEN its command line and environment are made
  ;; THEN it is headless and says nothing about a display: there is none
  (cl-letf (((symbol-function 'executable-find) (lambda (name) (concat "/usr/bin/" name))))
    (let* ((canvas-browser-headless t)
           (command (canvas-browser-cdp--command-line)))
      (should (member "--headless=new" command))
      ;; Nothing is put in front of the environment it inherits: a
      ;; headless chromium is given no display of its own.
      (should (equal (canvas-browser-cdp--environment) process-environment)))))

(ert-deftest canvas-browser-cdp-the-old-headless-setting-still-counts ()
  ;; GIVEN `canvas-browser-headless' set, as before the window strategy
  ;; WHEN the strategy is left at the default of Linux or of macOS, and
  ;;      then chosen
  ;; THEN the old setting makes it headless, AND a strategy chosen wins
  (dolist (system '((gnu/linux . xvfb) (darwin . offscreen)))
    (let ((system-type (car system))
          (canvas-browser-headless t)
          (canvas-browser-window-strategy (cdr system)))
      (should (eq (canvas-browser-cdp-window-strategy) 'headless))))
  (let ((system-type 'gnu/linux)
        (canvas-browser-headless t)
        (canvas-browser-window-strategy 'offscreen))
    (should (eq (canvas-browser-cdp-window-strategy) 'offscreen)))
  (let ((system-type 'gnu/linux)
        (canvas-browser-headless nil)
        (canvas-browser-window-strategy 'xvfb))
    (should (eq (canvas-browser-cdp-window-strategy) 'xvfb))))

(ert-deftest canvas-browser-cdp-macos-keeps-its-window-off-screen-by-default ()
  ;; GIVEN macOS, where chromium draws on no X display, and then Linux
  ;; WHEN nothing is set
  ;; THEN the window goes off screen on macOS, AND Linux keeps Xvfb
  (let ((system-type 'darwin))
    (should (eq (canvas-browser-cdp--default-window-strategy) 'offscreen)))
  (let ((system-type 'gnu/linux))
    (should (eq (canvas-browser-cdp--default-window-strategy) 'xvfb))))

(ert-deftest canvas-browser-cdp-a-chromium-off-screen-needs-no-display ()
  ;; GIVEN windows off screen, as on macOS
  ;; WHEN chromium is started
  ;; THEN it has a window, unthrottled, but none at the start, AND no
  ;;      Xvfb is started, no DISPLAY is given, and WebGL is left to the
  ;;      graphics card
  (let ((started nil) (xvfb nil)
        (canvas-browser-headless nil)
        (canvas-browser-window-strategy 'offscreen)
        (canvas-browser-cdp--socket nil)
        (canvas-browser-cdp--process nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (name) (concat "/usr/bin/" name)))
              ((symbol-function 'canvas-browser-cdp--ensure-display) (lambda () (setq xvfb t)))
              ((symbol-function 'make-process)
               (lambda (&rest args) (setq started (plist-get args :command)) 'process))
              ((symbol-function 'canvas-browser-cdp--address) (lambda () "ws://127.0.0.1:1/x"))
              ((symbol-function 'websocket-open) (lambda (&rest _) 'socket))
              ((symbol-function 'canvas-browser-cdp--socket-live-p) (lambda (_socket) t))
              ((symbol-function 'canvas-browser-cdp--open-p) (lambda (_socket) t)))
      (canvas-browser-cdp-start)
      (should-not xvfb)
      (should-not (member "--headless=new" started))
      (should (member "--no-startup-window" started))
      (should (member "--disable-backgrounding-occluded-windows" started))
      (should (member "--disable-blink-features=AutomationControlled" started))
      (should-not (member "--enable-unsafe-swiftshader" started))
      (should (equal (canvas-browser-cdp--environment) process-environment)))))

(ert-deftest canvas-browser-cdp-a-page-off-screen-opens-a-window-out-of-sight ()
  ;; GIVEN windows off screen, and then on Xvfb
  ;; WHEN a page is to open, in a window of its own or not
  ;; THEN off screen it always opens a window of its own, made far past
  ;;      the corner, AND on Xvfb it does so only when asked
  (let ((canvas-browser-headless nil)
        (canvas-browser-window-strategy 'offscreen))
    (dolist (new-window '(nil t))
      (let ((window (canvas-browser-cdp-target-window new-window)))
        (should (eq (plist-get window :newWindow) t))
        (should (> (plist-get window :left) 10000))
        (should (> (plist-get window :top) 10000)))))
  (let ((canvas-browser-headless nil)
        (canvas-browser-window-strategy 'xvfb))
    (should-not (canvas-browser-cdp-target-window nil))
    (should (equal (canvas-browser-cdp-target-window t) '(:newWindow t)))))

(defun canvas-browser-cdp-test--put-away (state)
  "Put the window of T1 away, its window being in STATE; what was sent.
The answer about the window comes at once."
  (canvas-browser-cdp-put-away-window "T1")
  (let ((asked (car canvas-browser-test--sent)))
    (should (equal (plist-get asked :method) "Browser.getWindowForTarget"))
    (should (equal (plist-get (plist-get asked :params) :targetId) "T1"))
    (canvas-browser-cdp--receive
     (json-encode (list :id (plist-get asked :id)
                        :result (list :windowId 7 :bounds (list :windowState state)))))
    (cdr (member asked (reverse canvas-browser-test--sent)))))

(ert-deftest canvas-browser-cdp-a-window-goes-off-screen-only-when-asked ()
  ;; GIVEN a page T1 in a window of its normal state, then one the reader
  ;;       has minimized, with windows off screen, and then on Xvfb
  ;; WHEN its window is to be put away
  ;; THEN the normal window is moved far past the corner, AND the other
  ;;      is left as it is, AND on Xvfb, where nobody sees the window,
  ;;      nothing is sent
  (canvas-browser-test--with-stub
    (let ((canvas-browser-headless nil)
          (canvas-browser-window-strategy 'offscreen))
      (let ((moved (canvas-browser-cdp-test--put-away "normal")))
        (should (equal (mapcar (lambda (sent) (plist-get sent :method)) moved)
                       '("Browser.setWindowBounds")))
        (should (equal (plist-get (car moved) :params)
                       (list :windowId 7 :bounds canvas-browser-cdp--offscreen))))
      (setq canvas-browser-test--sent nil)
      (should-not (canvas-browser-cdp-test--put-away "minimized")))
    (setq canvas-browser-test--sent nil)
    (let ((canvas-browser-headless nil)
          (canvas-browser-window-strategy 'xvfb))
      (canvas-browser-cdp-put-away-window "T1")
      (should-not canvas-browser-test--sent))))

(ert-deftest canvas-browser-cdp-emacs-takes-the-focus-back-from-a-window ()
  ;; GIVEN windows off screen, and a frame of Emacs on macOS
  ;; WHEN chromium has opened a window, which takes the focus
  ;; THEN the frame of Emacs takes it back, AND a frame on a terminal,
  ;;      where chromium takes nothing, is left alone
  (canvas-browser-test--with-stub
    (let ((canvas-browser-headless nil)
          (canvas-browser-window-strategy 'offscreen)
          (focused nil))
      (cl-letf (((symbol-function 'select-frame-set-input-focus)
                 (lambda (frame &rest _) (push frame focused))))
        (cl-letf (((symbol-function 'framep) (lambda (_frame) 'ns)))
          (canvas-browser-cdp-test--put-away "normal"))
        (should (equal focused (list (selected-frame))))
        (setq focused nil)
        (cl-letf (((symbol-function 'framep) (lambda (_frame) t)))
          (canvas-browser-cdp-test--put-away "normal"))
        (should-not focused)))))

(ert-deftest canvas-browser-cdp-start-runs-chromium-headless-once ()
  ;; GIVEN a stubbed process and websocket
  ;; WHEN the client starts twice and then stops
  ;; THEN chromium runs once, headless, with its own profile and port,
  ;;      AND stopping closes the socket and kills the process
  (let ((started nil) (closed nil) (killed nil)
        (canvas-browser-headless t)
        (canvas-browser-cdp--socket nil)
        (canvas-browser-cdp--process nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (name) (concat "/usr/bin/" name)))
              ((symbol-function 'make-process)
               (lambda (&rest args) (setq started (plist-get args :command)) 'process))
              ((symbol-function 'canvas-browser-cdp--address) (lambda () "ws://127.0.0.1:1/x"))
              ((symbol-function 'websocket-open) (lambda (&rest _) 'socket))
              ((symbol-function 'canvas-browser-cdp--socket-live-p)
               (lambda (socket) (eq socket 'socket)))
              ((symbol-function 'canvas-browser-cdp--open-p) (lambda (_socket) t))
              ((symbol-function 'websocket-close) (lambda (_socket) (setq closed t)))
              ((symbol-function 'delete-process) (lambda (_process) (setq killed t))))
      (canvas-browser-cdp-start)
      (canvas-browser-cdp-start)
      (should (canvas-browser-cdp-running-p))
      (should (member "--headless=new" started))
      (should (member "--remote-debugging-port=0" started))
      (should (cl-some (lambda (word) (string-prefix-p "--user-data-dir=" word)) started))
      (canvas-browser-cdp-stop)
      (should closed)
      (should killed)
      (should-not (canvas-browser-cdp-running-p)))))

;;;; Extensions

(defmacro canvas-browser-cdp-test--with-extensions (directory &rest body)
  "Run BODY with DIRECTORY bound to a fresh extension directory in use."
  (declare (indent 1))
  `(let* ((,directory (make-temp-file "canvas-browser-extensions" t))
          (canvas-browser-extension-directory ,directory))
     (unwind-protect
         (cl-letf (((symbol-function 'executable-find) (lambda (name) (concat "/usr/bin/" name))))
           ,@body)
       (delete-directory ,directory t))))

(defun canvas-browser-cdp-test--extension (directory name)
  "Make an unpacked extension called NAME in DIRECTORY; its directory."
  (let ((extension (expand-file-name name directory)))
    (make-directory extension t)
    (with-temp-file (expand-file-name "manifest.json" extension)
      (insert "{\"manifest_version\": 3}"))
    extension))

(defun canvas-browser-cdp-test--load-flags ()
  "The flags of the command line that load extensions."
  (seq-filter (lambda (word) (string-prefix-p "--load-extension" word))
              (canvas-browser-cdp--command-line)))

(ert-deftest canvas-browser-cdp-loads-each-unpacked-extension ()
  ;; GIVEN an extension directory with two extensions, a directory with no
  ;;       manifest, and a hidden one that is still being unpacked
  ;; WHEN chromium's command line is made
  ;; THEN one flag loads the two extensions, AND nothing else
  (canvas-browser-cdp-test--with-extensions directory
    (let ((one (canvas-browser-cdp-test--extension directory "one"))
          (two (canvas-browser-cdp-test--extension directory "two")))
      (make-directory (expand-file-name "empty" directory))
      (canvas-browser-cdp-test--extension directory ".unpacking-1")
      (should (equal (list (concat "--load-extension=" one "," two))
                     (canvas-browser-cdp-test--load-flags))))))

(ert-deftest canvas-browser-cdp-loads-no-extension-without-any ()
  ;; GIVEN an extension directory that does not exist
  ;; WHEN chromium's command line is made
  ;; THEN it loads no extension
  (canvas-browser-cdp-test--with-extensions directory
    (delete-directory directory)
    (should-not (canvas-browser-cdp-test--load-flags))))

(ert-deftest canvas-browser-cdp-refuses-an-extension-with-a-comma ()
  ;; GIVEN an extension whose directory name holds a comma
  ;; WHEN chromium's command line is made
  ;; THEN it is an error that names it, since the flag lists the
  ;;      extensions with commas
  (canvas-browser-cdp-test--with-extensions directory
    (canvas-browser-cdp-test--extension directory "one,two")
    (should (string-search "one,two"
                           (error-message-string
                            (should-error (canvas-browser-cdp--command-line)))))))

(ert-deftest canvas-browser-cdp-a-snap-keeps-its-extensions-where-it-reads ()
  ;; GIVEN a chromium that is a snap, and then one that is not
  ;; WHEN the extension directory is chosen
  ;; THEN the snap gets a directory under ~/snap, which it may read,
  ;;      AND the other one a directory for the data of the user
  (should (string-search "/snap/chromium/common/"
                         (canvas-browser-cdp--extensions-for "/snap/bin/chromium")))
  (let ((process-environment (cons "XDG_DATA_HOME=/data" process-environment)))
    (should (equal "/data/canvas-browser/extensions"
                   (canvas-browser-cdp--extensions-for "/usr/bin/chromium")))))

;;;; Where the profile goes

(ert-deftest canvas-browser-cdp-a-snap-keeps-its-profile-out-of-a-hidden-directory ()
  ;; GIVEN a chromium that is a snap, and then one that is not
  ;; WHEN the profile directory is chosen
  ;; THEN the snap gets a directory under ~/snap, which it may write in,
  ;;      AND the other one gets the cache directory
  (should (string-search "/snap/chromium/common/"
                         (canvas-browser-cdp--profile-for "/snap/bin/chromium")))
  (should-not (string-search "/snap/" (canvas-browser-cdp--profile-for "/usr/bin/chromium"))))

(ert-deftest canvas-browser-cdp-start-waits-until-the-socket-is-open ()
  ;; GIVEN a websocket that is still shaking hands, and opens shortly after
  ;; WHEN the client starts
  ;; THEN it waits for the open state before it gives the socket back
  (let ((asked 0)
        (canvas-browser-headless t)
        (canvas-browser-cdp--socket nil)
        (canvas-browser-cdp--process nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (name) (concat "/usr/bin/" name)))
              ((symbol-function 'make-process) (lambda (&rest _) 'process))
              ((symbol-function 'canvas-browser-cdp--address) (lambda () "ws://127.0.0.1:1/x"))
              ((symbol-function 'websocket-open) (lambda (&rest _) 'socket))
              ((symbol-function 'canvas-browser-cdp--socket-live-p) (lambda (_socket) t))
              ((symbol-function 'canvas-browser-cdp--open-p)
               (lambda (_socket) (> (cl-incf asked) 2)))
              ((symbol-function 'accept-process-output) #'ignore))
      (canvas-browser-cdp-start)
      (should (> asked 2))
      (should (canvas-browser-cdp-running-p)))))

(ert-deftest canvas-browser-cdp-says-when-another-chromium-holds-the-profile ()
  ;; GIVEN a chromium that exits at once, as one does when another chromium
  ;;       already uses the profile
  ;; WHEN the client waits for its port
  ;; THEN the error names the profile and says that chromium exited
  (let* ((directory (make-temp-file "canvas-browser-test-" t))
         (canvas-browser-profile-directory directory)
         (canvas-browser-cdp--process 'process)
         (canvas-browser-cdp-timeout 1))
    (unwind-protect
        (cl-letf (((symbol-function 'process-live-p) (lambda (_process) nil)))
          (let ((text (error-message-string (should-error (canvas-browser-cdp--address)))))
            (should (string-search "exited" text))
            (should (string-search directory text))))
      (delete-directory directory t))))

(ert-deftest canvas-browser-cdp-a-socket-whose-chromium-died-is-not-running ()
  ;; GIVEN a websocket left behind by a chromium that has gone, whose
  ;;       connection is no process at all
  ;; WHEN the client is asked whether it runs, and asked to send
  ;; THEN it answers no and says so as a user error, rather than letting
  ;;      a type error out of the websocket library into whatever ran the
  ;;      command, which in a post-command hook is a mess
  (let ((canvas-browser-cdp--socket
         (websocket-inner-create :conn nil :url "ws://nowhere" :accept-string "")))
    (should-not (canvas-browser-cdp-running-p))
    (should-error (canvas-browser-cdp-send "Page.enable" nil) :type 'user-error)))

(ert-deftest canvas-browser-cdp-stopping-a-dead-socket-says-nothing ()
  ;; GIVEN a websocket left behind by a chromium that has gone
  ;; WHEN the client is stopped
  ;; THEN the socket is dropped without being closed: closing it reaches
  ;;      for a process that is no longer there, and the type error comes
  ;;      out of whatever killed the buffer
  (let ((canvas-browser-cdp--socket
         (websocket-inner-create :conn nil :url "ws://nowhere" :accept-string ""))
        (canvas-browser-cdp--process nil)
        (closed nil))
    (cl-letf (((symbol-function 'websocket-close) (lambda (_socket) (setq closed t))))
      (canvas-browser-cdp-stop))
    (should-not closed)
    (should-not canvas-browser-cdp--socket)))
