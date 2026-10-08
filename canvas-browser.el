;;; canvas-browser.el --- A web browser in a buffer, drawn on a canvas -*- lexical-binding: t -*-

;; Copyright (C) 2026 canvas-browser contributors

;; Author: Daskeladden
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0.50") (websocket "1.15") (transient "0.7.0") (canvas-keys "0.1.0") (canvas-diagram "0.1.0"))
;; Keywords: hypermedia, tools
;; URL: https://github.com/Daskeladden/canvas-browser

;;; Commentary:
;; A page of a headless chromium, drawn on a canvas in an Emacs buffer.
;; Emacs speaks the DevTools protocol itself; see canvas-browser-cdp.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'canvas-cairo)
(require 'canvas-keys)
(require 'transient)
(require 'url-util)
(require 'tab-line)
(require 'canvas-browser-cdp)

(defcustom canvas-browser-quality 70
  "The quality of a screencast frame, from 1 to 100.
It holds for the frames of a page that is moving, which are JPEGs.  The
still picture of a page that has stopped is a PNG and loses nothing, so
this does not reach it."
  :type 'integer
  :group 'canvas-browser)

(defvar-local canvas-browser--session nil "The session of this buffer's page.")
(defvar-local canvas-browser--target nil "The target of this buffer's page.")
(defvar-local canvas-browser--canvas nil "The canvas image of this buffer.")
(defvar-local canvas-browser--context nil "The cairo context of that canvas.")
(defvar-local canvas-browser--size nil "(W . H) of the canvas, in pixels.")
(defvar-local canvas-browser--url nil "The URL of this buffer's page.")
(defvar-local canvas-browser--title nil "The title of this buffer's page.")
(defvar-local canvas-browser--host nil
  "The buffer this page's picture is embedded in, or nil for a page of its own.")
(defvar-local canvas-browser--frames 0 "How many frames this buffer painted.")

(defvar canvas-browser--buffers (make-hash-table :test #'eq :weakness 'key)
  "The buffer of each canvas, so that a thumbnail finds its page.")

(defvar-local canvas-browser--last-frame nil "The file of the last frame painted.")

(defvar-local canvas-browser--painted-mark nil
  "The md5 of the picture the canvas holds, to know the same one again.")

(defvar-local canvas-browser--live-boxes nil
  "The boxes of the parts of this page that keep moving.
While there are any, the canvas holds a still picture of the page and a
frame is drawn inside these boxes alone.")

(defvar-local canvas-browser--live-timer nil
  "The timer that draws a page with moving parts afresh now and then.")

(defvar-local canvas-browser--crisp nil
  "Whether the canvas holds the still picture of a page that has stopped.
A page that moves is painted from the JPEGs of the screencast, and one
that has stopped is painted from a PNG, which loses nothing.")

;;;; The canvas and its frames

(defun canvas-browser--host-of (buffer)
  "The live buffer BUFFER's page is embedded in, or nil."
  (let ((host (buffer-local-value 'canvas-browser--host buffer)))
    (and (buffer-live-p host) host)))

(defun canvas-browser--showing-windows (buffer)
  "The windows that show BUFFER's page: its own, and those of its host."
  (append (get-buffer-window-list buffer nil t)
          (when-let* ((host (canvas-browser--host-of buffer)))
            (get-buffer-window-list host nil t))))

(defun canvas-browser--shown-p (&optional buffer)
  "Whether a window shows the page of BUFFER, or of this buffer.
An embedded page is shown while a window shows the buffer it is in, or
the page itself, as it is while fullscreen."
  (let* ((buffer (or buffer (current-buffer)))
         (host (canvas-browser--host-of buffer)))
    (and (or (get-buffer-window buffer t)
             (and host (get-buffer-window host t)))
         t)))

(defun canvas-browser--make-canvas (width height)
  "A canvas image WIDTH by HEIGHT, at its own pixel size."
  (list 'image :type 'canvas :id (make-symbol "canvas-browser")
        :data-width width :data-height height :scale 1.0))

(defconst canvas-browser--least-size 200
  "The smallest page chromium is asked to lay out, in pixels.
A window reports no size until the display has laid its frame out, and a
page of no width paints nothing: chromium answers a picture of it with
\"Cannot take screenshot with 0 width\".")

(defun canvas-browser--adopt (width height)
  "Give this buffer a canvas WIDTH by HEIGHT, and show it.
A window with no size yet gets a page of `canvas-browser--least-size\=',
which the next window change makes right."
  (setq width (max width canvas-browser--least-size)
        height (max height canvas-browser--least-size))
  (when canvas-browser--context
    (canvas-cairo-destroy canvas-browser--context))
  (setq canvas-browser--canvas (canvas-browser--make-canvas width height)
        canvas-browser--context (canvas-cairo-context canvas-browser--canvas)
        canvas-browser--size (cons width height)
        ;; The new canvas is empty, so the picture that was painted is
        ;; not the picture it holds, and must be painted again.
        canvas-browser--painted-mark nil
        canvas-browser--crisp nil)
  (canvas-browser--forget-live)
  (puthash canvas-browser--canvas (current-buffer) canvas-browser--buffers)
  (let ((inhibit-read-only t))
    (erase-buffer)
    ;; `propertize' keeps the spec `eq': the canvas is keyed on it.
    (insert (propertize "#" 'display canvas-browser--canvas
                        ;; Insert state leaves the buffer writable, for
                        ;; the input method's sake; the picture is kept
                        ;; from the keys of Emacs that edit a buffer, at
                        ;; either side of it.
                        'read-only t 'front-sticky '(read-only)))))

(defvar-local canvas-browser--number nil
  "What tells this page's files from the files of every other page.")

(defvar canvas-browser--opened-pages 0
  "How many page buffers have been made, so that each knows its place.")

(defvar-local canvas-browser--opened nil
  "The place of this page among the tabs: the number it was made with.")

(defvar canvas-browser--pages 0
  "How many pages have been opened, so that each one names its files.")

(defconst canvas-browser--png-signature
  (unibyte-string #x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A)
  "The eight bytes that every PNG begins with.")

(defconst canvas-browser--suffixes '("jpg" "png")
  "The suffixes a page writes its pictures with.")

(defun canvas-browser--suffix (bytes)
  "The suffix BYTES deserve: a PNG says what it is in its first bytes."
  (if (string-prefix-p canvas-browser--png-signature bytes) "png" "jpg"))

(defun canvas-browser--file (name suffix)
  "The file this page writes NAME to as SUFFIX, no page sharing a name."
  (unless canvas-browser--number
    (setq canvas-browser--number (cl-incf canvas-browser--pages)))
  (expand-file-name (format "canvas-browser-%s-%d-%s.%s"
                            (emacs-pid) canvas-browser--number name suffix)
                    (if (file-writable-p "/dev/shm")
                        "/dev/shm"
                      temporary-file-directory)))

(defun canvas-browser--write (data name)
  "Write DATA, the base64 of a picture, to this page's NAME; that file."
  (canvas-browser--write-bytes (base64-decode-string data) name))

(defun canvas-browser--write-bytes (bytes name)
  "Write BYTES, a picture, to this page's NAME; that file.
The suffix says what the picture is: a frame of a page that moves is a
JPEG, and the still picture of one that has stopped is a PNG."
  (let ((file (canvas-browser--file name (canvas-browser--suffix bytes)))
        (coding-system-for-write 'binary))
    (write-region bytes nil file nil 'silent)
    file))

(defun canvas-browser--frame-file (data)
  "DATA, the base64 of a frame, written to a file; that file."
  (canvas-browser--write data "frame"))


(defconst canvas-browser--jpeg-frame-markers
  '(#xC0 #xC1 #xC2 #xC3 #xC5 #xC6 #xC7 #xC9 #xCA #xCB #xCD #xCE #xCF)
  "The JPEG markers that carry the size of the picture.")

(defun canvas-browser--be16 (position)
  "The two bytes at POSITION of this buffer, as one number."
  (+ (* 256 (char-after position)) (char-after (1+ position))))

(defun canvas-browser--be32 (position)
  "The four bytes at POSITION of this buffer, as one number."
  (+ (* 65536 (canvas-browser--be16 position))
     (canvas-browser--be16 (+ position 2))))

(defun canvas-browser--jpeg-size ()
  "The (W . H) of the JPEG in this buffer, or nil when it says nothing."
  (when (and (> (buffer-size) 4)
             (eq (char-after 1) #xFF) (eq (char-after 2) #xD8))
    (let ((position 3)
          (size nil))
      (while (and (not size) (< (+ position 9) (point-max)))
        (cond ((not (eq (char-after position) #xFF))
               (setq position (1+ position)))
              ((memq (char-after (1+ position)) canvas-browser--jpeg-frame-markers)
               (setq size (cons (canvas-browser--be16 (+ position 7))
                                (canvas-browser--be16 (+ position 5)))))
              (t (setq position (+ position 2 (canvas-browser--be16 (+ position 2)))))))
      size)))

(defun canvas-browser--png-size ()
  "The (W . H) of the PNG in this buffer, or nil when it is no PNG.
The IHDR chunk comes first in every PNG, and carries the two numbers."
  (when (and (> (buffer-size) 24)
             (equal (buffer-substring 1 9) canvas-browser--png-signature))
    (cons (canvas-browser--be32 17) (canvas-browser--be32 21))))

(defun canvas-browser--picture-size (picture)
  "The (W . H) of PICTURE, a string of bytes, or nil when it says nothing.
A frame of the screencast is a JPEG and a still picture is a PNG, and
both are drawn to the canvas, so both are measured here."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (substring picture 0 (min (length picture) 65536)))
    (or (canvas-browser--jpeg-size) (canvas-browser--png-size))))

(defconst canvas-browser--shape-tolerance 0.1
  "How far a frame's shape may differ from the canvas's and still be it.")

(defun canvas-browser--another-shape-p (picture)
  "Whether PICTURE, a string of bytes, is of another shape than this canvas.
Chromium draws the whole page to take a picture of it and sends that
draw as a frame, which is the page smeared over the window."
  (when-let* ((size (canvas-browser--picture-size picture))
              (ours canvas-browser--size))
    (let ((theirs (/ (float (car size)) (max 1 (cdr size))))
          (mine (/ (float (car ours)) (max 1 (cdr ours)))))
      (> (abs (- theirs mine)) (* canvas-browser--shape-tolerance mine)))))

(defun canvas-browser--paint (data)
  "Paint DATA, the base64 of a frame, on the canvas of this buffer.
A picture that cannot be read leaves the one before it on the canvas.
So does a picture the canvas already holds: chromium sends a frame after
every picture asked of it, that picture being a draw like any other, and
painting it again would have the still and the frame take turns on the
canvas for ever, which the reader sees as a pulse.

A frame is drawn over the whole canvas, unless the canvas holds a still
picture of the page and the parts that move on it are known.  Then the
frame goes inside those parts alone, and the text around them stays as
crisp as the still picture left it."
  (let* ((bytes (base64-decode-string data))
         (mark (md5 bytes))
         (still (equal (canvas-browser--suffix bytes) "png"))
         ;; Whether the canvas holds a picture of this page at all: a new
         ;; canvas is blank, and drawing into its moving parts alone
         ;; would leave the rest of it blank.
         (held (and canvas-browser--painted-mark t))
         (file (unless (or (equal mark canvas-browser--painted-mark)
                           (canvas-browser--another-shape-p bytes))
                 (canvas-browser--write-bytes bytes "frame"))))
    (when file
      (setq canvas-browser--last-frame file
            canvas-browser--painted-mark mark))
    (condition-case error
        (when file
          (let ((parts (and (not still) held canvas-browser--live-boxes)))
            (if parts
                (canvas-browser--paint-boxes file parts)
              ;; The canvas's own size, not the page's: a window that has
              ;; just changed leaves the two apart for a moment, and a
              ;; frame drawn to the wrong size is sheared across it.
              (canvas-cairo-image canvas-browser--context file 0 0
                                  (plist-get (cdr canvas-browser--canvas) :data-width)
                                  (plist-get (cdr canvas-browser--canvas) :data-height)))
            (setq canvas-browser--crisp (or still (and parts t)))
            (canvas-refresh canvas-browser--canvas)
            (cl-incf canvas-browser--frames)
            (force-window-update (current-buffer))
            (when-let* ((host (canvas-browser--host-of (current-buffer))))
              (force-window-update host))
            ;; A page that moved will stop moving: ask for the still
            ;; picture then.  A still picture asks for nothing, or the
            ;; two would follow one another without end, and a page whose
            ;; moving parts are known has a clock of its own.
            (unless (or canvas-browser--crisp canvas-browser--live-boxes)
              (canvas-browser--crisp-soon))))
      (error (message "canvas-browser: %s" (error-message-string error))))))

(defcustom canvas-browser-live-interval 2.0
  "Seconds between two still pictures while a part of the page keeps moving.
Between them the frames are drawn inside the moving parts alone, so the
rest of the window keeps the still picture it was given."
  :type 'number
  :group 'canvas-browser)

(defcustom canvas-browser-crisp-delay 0.4
  "Seconds of quiet before the page is drawn again without loss.
Every frame of the screencast is a JPEG, which is cheap to make and shows
its workings around small text.  A page that has stopped moving is read
rather than watched, so once the frames stop for this long the window is
asked for a still picture, which loses nothing."
  :type 'number
  :group 'canvas-browser)

(defvar-local canvas-browser--crisp-timer nil
  "The timer that draws this page again without loss once it is quiet.")

(defvar-local canvas-browser--crisp-when nil
  "When this page was last asked for a still picture of itself.")

(defvar-local canvas-browser--commanded nil
  "When a command last ran in this buffer.
A page that is being scrolled or typed in is not asked for a still
picture: each costs chromium a fifth of a second that it owes the keys.")

(defvar-local canvas-browser--commands 0
  "How many commands have run in this buffer.
A still picture asked for before a command and arriving after it shows
the page as it was, and painting it would take the window backwards.")

(defconst canvas-browser--crisp-least 0.05
  "The shortest wait before a still picture, in seconds.")

(defun canvas-browser--crisp-wait (now)
  "Seconds to wait before the still picture, NOW being the time.
The picture waits `canvas-browser-crisp-delay\=' after the last command, so
that scrolling and typing are never interrupted by one, and
`canvas-browser-live-interval\=' after the last picture, so that a page
which never stops moving is drawn afresh at a steady rate rather than at
every frame.  The frames themselves do not put it off: a page with a
spinner on it never falls quiet, and waiting for quiet would leave it
lossy for as long as the reader looked at it."
  (let ((after-key (+ (or canvas-browser--commanded 0) canvas-browser-crisp-delay))
        (after-picture (+ (or canvas-browser--crisp-when 0)
                          canvas-browser-live-interval)))
    (max canvas-browser--crisp-least (- (max after-key after-picture) now))))

(defun canvas-browser--crisp-soon ()
  "Draw this page again without loss once the frames have stopped.
Each frame puts the picture off, so a page that keeps moving is never
held up by one, and a page that settles is crisp a moment later."
  (when (timerp canvas-browser--crisp-timer)
    (cancel-timer canvas-browser--crisp-timer))
  (setq canvas-browser--crisp-timer
        (run-with-timer (canvas-browser--crisp-wait (float-time)) nil
                        #'canvas-browser--paint-crisp (current-buffer))))

(defun canvas-browser--paint-crisp (buffer)
  "Ask BUFFER\'s window for a still picture of itself, which loses nothing.
What keeps moving on the page is measured with it: between two still
pictures the frames are drawn into those parts alone."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq canvas-browser--crisp-timer nil)
      (when (canvas-browser--may-ask-p buffer)
        (setq canvas-browser--crisp-when (float-time))
        (canvas-browser--paint-window)
        (canvas-browser--measure-live)))))

(defcustom canvas-browser-live-share 0.3
  "How much of the window may move and still count as parts of it.
A page whose movement covers more than this share is a moving page, and
its frames belong on the whole canvas."
  :type 'number
  :group 'canvas-browser)

(defcustom canvas-browser-live-pad 4
  "Pixels a moving part grows by before the frames are drawn into it.
A thing that turns reaches past the box it is measured in."
  :type 'integer
  :group 'canvas-browser)

(defconst canvas-browser--live-most 32
  "The most moving parts a page may have before it counts as a moving page.")

(defconst canvas-browser--live-script
  "(function () {
     const boxes = [];
     const add = e => {
       if (!e || !e.getBoundingClientRect) return;
       const r = e.getBoundingClientRect();
       if (r.width <= 0 || r.height <= 0) return;
       if (r.bottom < 0 || r.top > innerHeight) return;
       if (r.right < 0 || r.left > innerWidth) return;
       boxes.push({x: Math.floor(r.x), y: Math.floor(r.y),
                   w: Math.ceil(r.width), h: Math.ceil(r.height)});
     };
     for (const a of document.getAnimations()) {
       if (a.playState === 'running' && a.effect && a.effect.target) add(a.effect.target);
     }
     document.querySelectorAll('video, canvas, img[src$=\".gif\"]').forEach(add);
     return boxes;
   })()"
  "The JavaScript that gives the boxes of everything moving on the page.
A page that is otherwise still moves where an animation runs, where a
video or a canvas draws itself, and where a GIF turns.")

(defun canvas-browser--measure-live ()
  "Ask the page which of its parts keep moving, and take them."
  (let ((buffer (current-buffer)))
    (canvas-browser--evaluate
     canvas-browser--live-script
     (lambda (boxes)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (canvas-browser--took-live boxes)))))))

(defun canvas-browser--grow-box (box)
  "BOX grown by `canvas-browser-live-pad\=', and kept inside the window."
  (let* ((pad canvas-browser-live-pad)
         (x (max 0 (- (plist-get box :x) pad)))
         (y (max 0 (- (plist-get box :y) pad))))
    (list :x x :y y
          :w (min (- (car canvas-browser--size) x) (+ (plist-get box :w) pad pad))
          :h (min (- (cdr canvas-browser--size) y) (+ (plist-get box :h) pad pad)))))

(defun canvas-browser--box-area (box)
  "The pixels BOX covers."
  (* (plist-get box :w) (plist-get box :h)))

(defun canvas-browser--boxes-area (boxes)
  "The pixels BOXES cover, counting an overlap twice, which is near enough."
  (cl-loop for box in boxes sum (canvas-browser--box-area box)))

(defun canvas-browser--took-live (boxes)
  "Keep BOXES as the moving parts of this page, if they are parts at all.
Too many of them, or too much of the window, means a page that moves
rather than a page with something moving on it."
  (let* ((grown (mapcar #'canvas-browser--grow-box boxes))
         (window (* (car canvas-browser--size) (cdr canvas-browser--size)))
         (parts (and grown
                     (<= (length grown) canvas-browser--live-most)
                     (< (canvas-browser--boxes-area grown)
                        (* canvas-browser-live-share window)))))
    (if (not parts)
        (canvas-browser--drop-live)
      (setq canvas-browser--live-boxes grown)
      (unless canvas-browser--live-timer
        (setq canvas-browser--live-timer
              (run-with-timer canvas-browser-live-interval canvas-browser-live-interval
                              #'canvas-browser--paint-crisp (current-buffer)))))))

(defun canvas-browser--drop-live ()
  "Draw the whole window again from every frame.
A page whose parts are forgotten is painted as it was before there were
any.  While there were parts, the frames went into them alone, so the
rest of the canvas is as old as the last still picture.  The canvas
therefore no longer counts as the still picture of the page, and the
freshness check asks for one if none comes."
  (when canvas-browser--live-timer
    (cancel-timer canvas-browser--live-timer)
    (setq canvas-browser--live-timer nil))
  (when canvas-browser--live-boxes
    (setq canvas-browser--live-boxes nil
          canvas-browser--crisp nil)
    ;; A frame held for the pace of the moving parts is drawn at the
    ;; pace of the whole window now.
    (canvas-browser--paint-pending-soon)))

(defun canvas-browser--forget-live ()
  "Draw the whole window again from every frame, and put the still off.
Any command may have changed the page anywhere.  A page being worked on
is left to its frames: the still picture waits for the quiet after the
last key, and one asked for before the command is dropped.  A page that
says nothing moves on it is no command, and takes `canvas-browser--drop-live'."
  (cl-incf canvas-browser--commands)
  (setq canvas-browser--commanded (float-time))
  ;; The frames held are answered now, so that chromium may send the one
  ;; the command makes as soon as it is drawn, not after them.
  (canvas-browser--answer-frame t)
  (canvas-browser--drop-live))

(defun canvas-browser--paint-boxes (file boxes)
  "Draw FILE, a picture of the whole window, inside BOXES alone.
All the boxes make one clip, and the picture is drawn once: reading a
frame costs about four milliseconds, and reading it once for each box
costs more than drawing the whole window would."
  (let ((context canvas-browser--context))
    (canvas-cairo-save context)
    (canvas-cairo-new-path context)
    (dolist (box boxes)
      (canvas-cairo-rectangle context (plist-get box :x) (plist-get box :y)
                              (plist-get box :w) (plist-get box :h)))
    (canvas-cairo-clip context)
    (canvas-cairo-image context file 0 0
                        (plist-get (cdr canvas-browser--canvas) :data-width)
                        (plist-get (cdr canvas-browser--canvas) :data-height))
    (canvas-cairo-restore context)))

(defvar-local canvas-browser--pending nil
  "The newest frame this buffer has not painted yet.")

(defvar-local canvas-browser--paint-timer nil
  "The timer that paints the newest frame.")

(defvar-local canvas-browser--painted 0
  "When this buffer last painted a frame.")

(defcustom canvas-browser-frame-interval 0.08
  "The shortest time between two drawings of the page, in seconds.
An advertisement that moves makes chromium send frames without stopping,
and Emacs has other work than drawing every one of them."
  :type 'number
  :group 'canvas-browser)

(defcustom canvas-browser-hidden-interval 2.0
  "The shortest time between two drawings of a page no window shows.
The page is kept in mind for the map and for the moment you come back to
it, and takes hardly any of the time of the page you are reading."
  :type 'number
  :group 'canvas-browser)

(defcustom canvas-browser-live-frame-interval 0.25
  "The shortest time between two drawings while only parts of the page move.
A spinner beside a running job turns in a box of a few pixels, and every
frame of it is the whole window, read and drawn in full: four a second
turn it as well as twelve, at a third of the cost.  A key or a click
draws the page at `canvas-browser-frame-interval\=' again."
  :type 'number
  :group 'canvas-browser)

(defun canvas-browser--paint-delay ()
  "How long this buffer waits before it draws the frame it holds."
  (let ((interval (cond ((not (canvas-browser--shown-p)) canvas-browser-hidden-interval)
                        (canvas-browser--live-boxes canvas-browser-live-frame-interval)
                        (t canvas-browser-frame-interval))))
    (max 0 (- interval (- (float-time) canvas-browser--painted)))))

(defun canvas-browser--paint-pending-soon ()
  "Draw the frame held at the pace that holds now, not the one it was held for."
  (when (timerp canvas-browser--paint-timer)
    (cancel-timer canvas-browser--paint-timer)
    (setq canvas-browser--paint-timer
          (run-with-timer (canvas-browser--paint-delay) nil
                          #'canvas-browser--paint-pending (current-buffer)))))

(defvar-local canvas-browser--hinting nil
  "Whether the hints are on the canvas, waiting to be named.
A frame painted then would paint over them.")

(defvar-local canvas-browser--unanswered nil
  "The screencast sessions of the frames not answered yet, one for each.
Chromium holds back the next frame while frames it sent are not
answered.  A frame painted answers one of them, so that chromium sends
one more for each frame drawn, and a command answers them all, so that
the frame it makes is not held back.")

(defun canvas-browser--frame (params)
  "Take PARAMS of a screencast frame: paint it, and answer it once painted.
Chromium sends the next frame when a frame is answered.  Answered as it
arrives, a frame brings sixty a second while a spinner turns, and all but
the few painted are read for nothing; answered as it is painted, it
brings no more than are drawn.  Under the hints nothing is painted, so a
frame is answered at once, or the page would stand still after them."
  (push (plist-get params :sessionId) canvas-browser--unanswered)
  (canvas-browser--paint-soon (plist-get params :data))
  (when canvas-browser--hinting
    (canvas-browser--answer-frame t))
  (canvas-browser--schedule-spots))

(defun canvas-browser--answer-frame (&optional all)
  "Tell chromium a frame is taken, or with ALL every one, so that it sends more.
The frames of a chromium that has gone are forgotten, not answered: an
answer told the page would bring it back, and start chromium again for
nothing the reader asked."
  (if (not (and canvas-browser--session (canvas-browser-cdp-running-p)))
      (setq canvas-browser--unanswered nil)
    (dotimes (_ (if all (length canvas-browser--unanswered)
                  (min 1 (length canvas-browser--unanswered))))
      (canvas-browser-cdp-send "Page.screencastFrameAck"
                               (list :sessionId (pop canvas-browser--unanswered))
                               nil canvas-browser--session))))

(defun canvas-browser--paint-soon (data)
  "Paint DATA, the base64 of a frame, once Emacs has a moment for it.
A smooth scroll and a page that animates send frames faster than they
can be drawn; only the newest of them is worth drawing, and no faster
than `canvas-browser-frame-interval\=' allows."
  (setq canvas-browser--pending data)
  (unless (or canvas-browser--hinting canvas-browser--paint-timer)
    (setq canvas-browser--paint-timer
          (run-with-timer (canvas-browser--paint-delay) nil
                          #'canvas-browser--paint-pending (current-buffer)))))

(defun canvas-browser--paint-pending (buffer)
  "Paint the frame BUFFER is waiting to draw."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq canvas-browser--paint-timer nil)
      ;; Answered before it is painted, so that chromium draws the next
      ;; frame while Emacs draws this one.
      (canvas-browser--answer-frame)
      (when-let* (((not canvas-browser--hinting))
                  (data canvas-browser--pending))
        (setq canvas-browser--pending nil
              canvas-browser--painted (float-time))
        (canvas-browser--paint data)))))

;;;; The page

(defvar-local canvas-browser--opening nil
  "Whether this page waits for chromium to give it a session.
A page asked for something meanwhile is not opened a second time.")

(defvar canvas-browser--reconnecting nil
  "Whether Emacs is connecting to chromium again for every page.
Starting chromium waits, and timers run while it does; a page that asks
for something then is left to the connection on its way.")

(defun canvas-browser--page-buffers ()
  "Every page buffer: those of their own, and those embedded elsewhere."
  (seq-filter (lambda (buffer)
                (eq (buffer-local-value 'major-mode buffer) 'canvas-browser-mode))
              (buffer-list)))

(defvar canvas-browser--screencast)
(defvar canvas-browser--focused)
(defvar canvas-browser--waiting)

(defun canvas-browser--lose-session ()
  "Forget the session of this page, but not its target.
A session belongs to one connection to chromium, and a connection made
again knows none of the old ones; the target, the page itself, stays
while chromium runs, and is attached to again."
  (when canvas-browser--session
    (canvas-browser-cdp-forget canvas-browser--session))
  (setq canvas-browser--session nil
        canvas-browser--screencast nil
        canvas-browser--focused nil
        canvas-browser--opening nil))

(defun canvas-browser--reconnect (&optional connect-only except)
  "Connect to chromium again, and bring back the pages a window shows.
A chromium that still runs is connected to again and keeps its pages,
which are attached to again; one that is gone is started anew, and the
pages are opened afresh.  This is done once for every page, so pages
that find the connection gone together start one chromium between them.
A page no window shows comes back when it is next shown or asked.
With CONNECT-ONLY a chromium that is gone is not started.  EXCEPT, a
page buffer, is left to whoever is opening it."
  (let* ((canvas-browser--reconnecting t)
         (how (canvas-browser-cdp-start connect-only)))
    (when how
      (message (if (eq how 'connected)
                   "canvas-browser: the connection to chromium was lost; connected again"
                 "canvas-browser: chromium is gone; starting it again"))
      (dolist (page (canvas-browser--page-buffers))
        (with-current-buffer page
          (canvas-browser--lose-session)
          ;; A new chromium has none of the old pages.
          (when (eq how 'started)
            (setq canvas-browser--target nil))))
      (canvas-browser--watch-targets)
      (dolist (page (canvas-browser--page-buffers))
        (when (and (canvas-browser--shown-p page) (not (eq page except)))
          (with-current-buffer page
            ;; A buffer whose page is being made has nothing to revive.
            (when (canvas-browser--page-p)
              (canvas-browser--revive))))))))

(defun canvas-browser--connect ()
  "Have chromium connected for this page, which is being opened.
The other pages are told when the connection is new: each of them holds
a session no new connection knows.  This page is left out, since it is
opened by whoever called."
  (unless (or (canvas-browser-cdp-running-p) canvas-browser--reconnecting)
    (canvas-browser--reconnect nil (current-buffer))))

(defun canvas-browser--revive ()
  "Bring this page back after it lost its session.
Its target is attached to again if chromium still has it, and the page
stays where it was; otherwise the page is opened afresh at its address."
  (if canvas-browser--target
      (canvas-browser--attach nil #'canvas-browser--reopen)
    (canvas-browser--reopen)))

(defun canvas-browser--page-p ()
  "Whether this buffer is a page that can be opened again.
It has an address and a size.  Any other buffer has nothing to open,
and a command of a page run in it must not try."
  (and (derived-mode-p 'canvas-browser-mode) canvas-browser--url canvas-browser--size t))

(defun canvas-browser--bring-back ()
  "Have this page answer again, for a command that found no session.
The connection to chromium is made again when it is gone, and the page
attached or opened again when it alone lost its session.  The command
itself is dropped: it was meant for the page as it was."
  (cond
   ;; A tab of the last session is read once it is asked for.
   ((and canvas-browser--waiting (canvas-browser--shown-p))
    (canvas-browser--load-tab))
   ((not (canvas-browser--page-p))
    (user-error "canvas-browser: this buffer shows no page"))
   (canvas-browser--reconnecting nil)
   ;; The connection comes first: a page that waited for an answer when
   ;; it went will never have one.
   ((not (canvas-browser-cdp-running-p))
    (canvas-browser--reconnect)
    ;; A page no window shows is not among those brought back.
    (when (and (canvas-browser-cdp-running-p)
               (not canvas-browser--session)
               (not canvas-browser--opening))
      (canvas-browser--revive)))
   (canvas-browser--opening nil)
   (t (canvas-browser--revive))))

(defun canvas-browser--connection-lost ()
  "Connect to chromium again as soon as the connection is lost.
Only a chromium that still runs is connected to: one that has gone is
started again when a page next asks for it, not because it went."
  (when (and (not canvas-browser--reconnecting)
             (not (canvas-browser-cdp-running-p))
             (canvas-browser-cdp-alive-p)
             (seq-some #'canvas-browser--shown-p (canvas-browser--page-buffers)))
    ;; Emacs may not have heard yet that a chromium which was killed has
    ;; gone, and finds out only when its port refuses.
    (with-demoted-errors "canvas-browser: %S"
      (canvas-browser--reconnect 'connect-only))))

(add-hook 'canvas-browser-cdp-lost-hook #'canvas-browser--connection-lost)

(defun canvas-browser--session-lost (session)
  "Bring back the page of SESSION, which chromium no longer knows."
  (when-let* ((page (seq-find (lambda (buffer)
                                (equal (buffer-local-value 'canvas-browser--session buffer)
                                       session))
                              (canvas-browser--page-buffers))))
    (with-current-buffer page
      (canvas-browser--lose-session)
      (when (canvas-browser--shown-p)
        (canvas-browser--revive)))))

(add-hook 'canvas-browser-cdp-session-lost-functions #'canvas-browser--session-lost)

(defun canvas-browser--reopen ()
  "Open this buffer's page afresh, at its address and size.
The page gets a new canvas, so a host it is embedded in is given that
one to show."
  (canvas-browser--open canvas-browser--url
                        (car canvas-browser--size) (cdr canvas-browser--size))
  (when (canvas-browser--host-of (current-buffer))
    (canvas-browser--show-in-host)))

(defun canvas-browser--tell (method params &optional answer)
  "Send METHOD with PARAMS in the session of this buffer.
ANSWER, when given, is called with chromium's answer.  A command without
a session reaches no page: the page is brought back instead, see
`canvas-browser--bring-back\='."
  (if (and canvas-browser--session (canvas-browser-cdp-running-p))
      (canvas-browser-cdp-send method params answer canvas-browser--session)
    (canvas-browser--bring-back)))

(defun canvas-browser--resize (width height &optional then)
  "Lay the page out for WIDTH by HEIGHT pixels, at the zoom of this buffer.
THEN is called once chromium has laid it out."
  (setq canvas-browser--size (cons width height))
  ;; `:json-false' is what `json-encode' writes as false; the keyword
  ;; `:false' would go as a string, and chromium answers "Invalid
  ;; parameters" to that.  `canvas-browser--apply-zoom' writes it.
  (canvas-browser--apply-zoom then))

(defvar-local canvas-browser--screencast nil
  "Whether chromium sends frames of this page.")

(defcustom canvas-browser-fresh-interval 2.0
  "Seconds between two looks at whether the window is still fresh.
A frame can be missed or dropped: a window that painted nothing since
the last look is asked for a picture of itself."
  :type 'number
  :group 'canvas-browser)

(defvar-local canvas-browser--fresh-frames 0
  "The count of frames at the last look at this window.")

(defvar-local canvas-browser--fresh-timer nil
  "The timer that looks whether this window is still fresh.")

(defconst canvas-browser--quiet-looks 4
  "Looks at a window that painted nothing before the reader is told.")

(defvar-local canvas-browser--quiet 0
  "How many looks in a row have found this window painting nothing.")

(defvar-local canvas-browser--focused nil
  "Whether this page has been told it has the focus.")

(defun canvas-browser--awaken (focus)
  "Tell this page it is active, and whether it has the FOCUS.
Chromium draws the tab that is in front and throttles the ones behind
it, down to freezing them; a page of its own buffer is in front of
nothing, and would stop drawing and stop answering.  The focus goes to
the page you are looking at alone: with several pages claiming it,
chromium sends the keys and the wheel to none of them."
  (unless (eq (and focus t) canvas-browser--focused)
    (setq canvas-browser--focused (and focus t))
    (canvas-browser--tell "Emulation.setFocusEmulationEnabled"
                          (list :enabled (if focus t :json-false))))
  (canvas-browser--tell "Page.setWebLifecycleState" (list :state "active")))

(defun canvas-browser--wake (focus)
  "Draw this page again: it is shown once more.
FOCUS is as in `canvas-browser--awaken\='."
  (canvas-browser--awaken focus)
  (unless canvas-browser--screencast
    (canvas-browser--start-screencast)))

(defun canvas-browser--sleep ()
  "Let this page be: no window shows it.
Chromium is left to throttle it as it throttles any tab behind another,
which keeps a handful of news sites from fighting for the machine."
  (canvas-browser--stop-screencast))

(defun canvas-browser--follow-windows (&rest _)
  "Fit the pages that are shown to their windows, and let the others be.
Nothing is done while chromium is gone: the windows change as buffers
are killed, and a window change is no reason to start a browser."
  (when (canvas-browser-cdp-running-p)
    (canvas-browser--follow-shown-windows)))

(defun canvas-browser--follow-shown-windows ()
  "Wake the pages a window shows, and let the others be."
  (let* ((here (window-buffer (selected-window)))
         ;; The window you are in may hold the map, the minibuffer or
         ;; anything else while the windows are being changed, and a page
         ;; that lost the focus then would stop answering the keys.
         (page (and (buffer-live-p here)
                    (with-current-buffer here
                      (derived-mode-p 'canvas-browser-mode))
                    here)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        ;; A page that lost its session comes back once it is shown.
        (when (and (derived-mode-p 'canvas-browser-mode)
                   (not canvas-browser--session)
                   (not canvas-browser--opening)
                   (canvas-browser--page-p)
                   (canvas-browser--shown-p))
          (canvas-browser--revive))
        (when (and (derived-mode-p 'canvas-browser-mode) canvas-browser--session)
          (cond
           ;; A window of its own comes first: an embedded page has one
           ;; while it is fullscreen.
           ((get-buffer-window buffer t)
            (canvas-browser--window-change (get-buffer-window buffer t))
            (canvas-browser--wake (if page (eq buffer page) canvas-browser--focused)))
           ((canvas-browser--host-of buffer)
            ;; An embedded page keeps the size it was given, and the keys
            ;; stay with its host.
            (if (canvas-browser--shown-p) (canvas-browser--wake nil) (canvas-browser--sleep)))
           (t (canvas-browser--sleep))))))))

(add-hook 'window-configuration-change-hook #'canvas-browser--follow-windows)
;; The size hook is called with the frame, not with a window, and its
;; buffer-local values are not run at all, so it is taken globally too.
(add-hook 'window-size-change-functions #'canvas-browser--follow-windows)

(defun canvas-browser--stop-screencast ()
  "Stop the frames of this page until they are asked for again."
  (when canvas-browser--screencast
    (canvas-browser--tell "Page.stopScreencast" nil)
    (setq canvas-browser--screencast nil)))

(defun canvas-browser--start-screencast ()
  "Ask chromium for a frame whenever the page changes.
A screencast that runs is stopped first, because chromium answers a
second one with an error that it is active already."
  (canvas-browser--stop-screencast)
  ;; A new screencast counts its frames afresh.
  (setq canvas-browser--unanswered nil)
  (canvas-browser--tell "Page.startScreencast"
                        (list :format "jpeg" :quality canvas-browser-quality
                              :maxWidth (car canvas-browser--size)
                              :maxHeight (cdr canvas-browser--size)))
  (setq canvas-browser--screencast t))

(defun canvas-browser--listen ()
  "Take the events of this buffer's session."
  (let ((buffer (current-buffer)))
    (canvas-browser-cdp-listen
     canvas-browser--session "Page.screencastFrame"
     (lambda (params)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (canvas-browser--frame params)))))
    (canvas-browser-cdp-listen
     canvas-browser--session "Inspector.detached"
     (lambda (params)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (canvas-browser--detached params)))))
    (canvas-browser-cdp-listen
     canvas-browser--session "Page.loadEventFired"
     (lambda (params)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (canvas-browser--loaded params)))))
    (canvas-browser-cdp-listen
     canvas-browser--session "Page.frameNavigated"
     (lambda (params)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (canvas-browser--frame-navigated params)))))
    (canvas-browser-cdp-listen
     canvas-browser--session "Page.fileChooserOpened"
     (canvas-browser--here #'canvas-browser--file-chooser-opened))
    (canvas-browser-cdp-listen
     canvas-browser--session "Inspector.targetCrashed"
     (lambda (params)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (canvas-browser--crashed params)))))))

(defcustom canvas-browser-crash-retries 2
  "Times a page that crashed is read again before it is left to you.
The count starts afresh each time the page loads."
  :type 'integer
  :group 'canvas-browser)

(defvar-local canvas-browser--asked-url nil
  "The address this page was last sent to, whether or not it got there.")

(defvar-local canvas-browser--crashes 0
  "How many times this page crashed since it last loaded.")

(defun canvas-browser--crashed (_params)
  "Read the page again, which crashed before or after it loaded.
The process that draws a page can die at the start of a navigation, as
it does at times for a link of Notion.  The page is then blank, and every
picture asked of it is refused with \"Internal error\".  A navigation
starts a new process, so the address that was asked for is gone to again:
the page itself may know no address yet, if it died before it had one."
  (let ((url (if (and canvas-browser--url
                      (not (member canvas-browser--url '("" "about:blank"))))
                 canvas-browser--url
               canvas-browser--asked-url)))
    (if (and url (< canvas-browser--crashes canvas-browser-crash-retries))
        (progn
          (cl-incf canvas-browser--crashes)
          (message "canvas-browser: the page crashed; reading it again")
          ;; The screencast of the dead process is gone with it, and one
          ;; asked for before the new process is up is refused as
          ;; \"Target crashed\": it is asked for once the navigation
          ;; has started.
          (let ((buffer (current-buffer)))
            (canvas-browser--tell
             "Page.navigate" (list :url url)
             (lambda (_result)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq canvas-browser--screencast nil)
                   (canvas-browser--start-screencast)))))))
      (message "canvas-browser: the page crashed; r reads it again"))))

(defun canvas-browser--frame-navigated (params)
  "Take PARAMS of the event that says a frame of this page navigated.
Chromium restores a page from its back and forward cache without the
dark it forces on a page that has no dark of its own, though the page
still hears that the reader prefers dark.  So the dark is told again
after a restore of the page itself.  A navigation to a new page keeps it."
  (when (and (null (plist-get (plist-get params :frame) :parentId))
             (equal (plist-get params :type) "BackForwardCacheRestore"))
    (canvas-browser--apply-dark)))

(defun canvas-browser--loaded (_params)
  "Ask the page that has loaded for its title and its icon, for the tabs.
Chromium names a page after its file until the page changes address
again, whatever the page calls itself."
  (setq canvas-browser--crashes 0)
  (let ((buffer (current-buffer)))
    (canvas-browser--evaluate
     "document.title"
     (lambda (title)
       (when (and (buffer-live-p buffer) (stringp title) (not (string-empty-p title)))
         (with-current-buffer buffer
           (setq canvas-browser--title title)
           (canvas-browser--tabs-changed))))))
  (canvas-browser--find-icon))

(defun canvas-browser--detached (params)
  "Take PARAMS of the event that says chromium has let this page go.
The session is forgotten: chromium answers every command sent in it with
\"Not attached to an active page\", and the page is opened afresh when
something is next asked of it."
  (ignore params)
  (canvas-browser--forget-page))

(defun canvas-browser--forget-page ()
  "Forget the session of this buffer's page, which is opened afresh when
something is next asked of it."
  (canvas-browser--lose-session)
  (setq canvas-browser--target nil))

(defun canvas-browser--attach (&optional url otherwise)
  "Attach to this buffer's target, size it, and go to URL.
Without URL the page stays where it is, as a window another page opened
does: it was opened at its address.  OTHERWISE, when given, is called in
this buffer if chromium has no such target; the refusal is then kept
quiet, since it is looked for."
  (let ((buffer (current-buffer)))
    (setq canvas-browser--opening t)
    (funcall
     (if otherwise #'canvas-browser-cdp-send-quietly #'canvas-browser-cdp-send)
     "Target.attachToTarget" (list :targetId canvas-browser--target :flatten t)
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq canvas-browser--opening nil)
           (if-let* ((session (plist-get result :sessionId)))
               (canvas-browser--attached session url)
             (setq canvas-browser--target nil)
             (when otherwise (funcall otherwise)))))))))

(defun canvas-browser--attached (session url)
  "Take SESSION, the new session of this page, and go to URL if there is one."
  (setq canvas-browser--session session)
  (canvas-browser--listen)
  (canvas-browser--tell "Page.enable" nil)
  ;; Chromium's own file dialog opens on a display that nobody sees, so
  ;; the page hands the choice to Emacs.
  (canvas-browser--tell "Page.setInterceptFileChooserDialog" (list :enabled t))
  ;; A page embedded in another buffer leaves the keys to the page you
  ;; browse.
  (canvas-browser--awaken (not canvas-browser--host))
  (canvas-browser--apply-dark)
  (canvas-browser--fit-shown-window)
  (canvas-browser--resize (car canvas-browser--size) (cdr canvas-browser--size))
  (when canvas-browser--host
    (canvas-browser--watch-fullscreen))
  (when url
    (setq canvas-browser--asked-url url)
    (canvas-browser--tell "Page.navigate" (list :url url)))
  (canvas-browser--start-screencast))

(defun canvas-browser--fit-shown-window ()
  "Make the canvas the size of the window that shows this page, if one does.
A window is measured before Emacs has drawn it, and Emacs guesses the
height of a line of tabs it has not drawn yet from its font alone, not
from the icons and the box it is drawn with.  The window has its true
size once it is drawn, but a change of size heard before the page was
attached was no news to it.  An embedded page keeps the size it was given."
  (when-let* (((not canvas-browser--host))
              (window (get-buffer-window (current-buffer) t))
              ((window-live-p window)))
    (let ((width (max (window-body-width window t) canvas-browser--least-size))
          (height (max (window-body-height window t) canvas-browser--least-size)))
      (unless (equal canvas-browser--size (cons width height))
        (canvas-browser--adopt width height)))))

(defun canvas-browser--buffer-of-target (target)
  "The page buffer that shows TARGET, or nil."
  (and target
       (seq-find (lambda (buffer)
                   (and (eq (buffer-local-value 'major-mode buffer) 'canvas-browser-mode)
                        (equal (buffer-local-value 'canvas-browser--target buffer) target)))
                 (buffer-list))))

(defcustom canvas-browser-show-strays t
  "Whether a page that no page of Emacs opened is shown in a tab.
A link opened in another program goes to the default browser, and when
that is the chromium canvas-browser runs, the page opens there, on a
display nobody sees.  On, it comes to Emacs as a tab of its own, and the
frame that shows it is raised.  `canvas-browser-show-hidden-pages\='
brings the pages that opened so before."
  :type 'boolean
  :group 'canvas-browser)

(defvar canvas-browser--let-go (make-hash-table :test #'equal)
  "The targets whose buffers closed them, which are no strays to show.
Chromium may tell of such a page once more before it is gone.")

(defun canvas-browser--stray-p (info)
  "Whether INFO is of a page of the web that no buffer shows.
A blank page, a page of chromium's own, as its new tab, and a page of an
extension are no pages to show."
  (let ((target (plist-get info :targetId))
        (url (plist-get info :url)))
    (and (equal (plist-get info :type) "page")
         (stringp url)
         (string-match-p "\\`\\(https?\\|file\\):" url)
         (not (gethash target canvas-browser--let-go))
         (not (canvas-browser--buffer-of-target target)))))

(defun canvas-browser--show-stray (info &optional raise)
  "Show the page of INFO, which no page of Emacs opened, in a tab; its buffer.
With RAISE the frame that shows it is raised, since a link opened in
another program is a page you want to see now."
  (let ((buffer (save-current-buffer
                  (canvas-browser--show-window (plist-get info :targetId)
                                               (plist-get info :url) nil))))
    (when-let* ((raise)
                (window (get-buffer-window buffer t)))
      (select-frame-set-input-focus (window-frame window)))
    buffer))

(defun canvas-browser-show-hidden-pages ()
  "Show in tabs the pages of chromium that no buffer shows.
They are the pages that links from other programs opened while
`canvas-browser-show-strays\=' was off, or before it was there."
  (interactive)
  (unless (canvas-browser-cdp-running-p)
    (user-error "canvas-browser: chromium is not running"))
  (canvas-browser-cdp-send
   "Target.getTargets" nil
   (lambda (result)
     (let ((strays (seq-filter #'canvas-browser--stray-p
                               (append (plist-get result :targetInfos) nil))))
       (dolist (info strays)
         (canvas-browser-cdp-put-away-window (plist-get info :targetId))
         (canvas-browser--show-stray info))
       (message "canvas-browser: %s"
                (if strays
                    (format "%d hidden pages are in tabs now" (length strays))
                  "no page is hidden"))))))

(defun canvas-browser--watch-targets ()
  "Hear of the pages chromium opens and closes.
A button to sign in with Google or Apple opens a window of its own, and
a link may open a tab: each is a page of chromium's, which would else
open on a display nobody sees."
  (canvas-browser-cdp-listen nil "Target.targetCreated" #'canvas-browser--target-created)
  (canvas-browser-cdp-listen nil "Target.targetDestroyed" #'canvas-browser--target-destroyed)
  (canvas-browser-cdp-listen nil "Target.targetInfoChanged" #'canvas-browser--target-changed)
  (canvas-browser-cdp-send "Target.setDiscoverTargets" (list :discover t)))

(defun canvas-browser--target-changed (params)
  "Keep the address and the title of the page PARAMS names, if it is ours.
A page buffer takes the name of the address it shows, so that `C-x b\='
says what each page is; an embedded page keeps the name its host gave
it, since the host finds it by that name."
  (let* ((info (plist-get params :targetInfo))
         (buffer (canvas-browser--buffer-of-target (plist-get info :targetId)))
         (url (plist-get info :url))
         (title (plist-get info :title)))
    ;; A page opened from elsewhere may start blank and get its address
    ;; only now.
    (when (and (not buffer) canvas-browser-show-strays (canvas-browser--stray-p info))
      (canvas-browser--show-stray info t))
    (when buffer
      (with-current-buffer buffer
        ;; Chromium names a page after its file until it moves again, so
        ;; its title stands only for a new address, until the page has
        ;; loaded and given its own.
        (unless (equal url canvas-browser--url)
          ;; A page of another site has another icon, which is known
          ;; if the site was opened before.
          (unless (equal (canvas-browser--origin url)
                         (canvas-browser--origin canvas-browser--url))
            (canvas-browser--icon-of-site url))
          (setq canvas-browser--url url
                canvas-browser--title (and (stringp title) (not (string-empty-p title)) title)))
        (unless canvas-browser--host
          (let ((name (canvas-browser--buffer-name canvas-browser--url)))
            ;; A name made unique with <2> is the name already.
            (unless (string-prefix-p name (buffer-name))
              (rename-buffer name t))))
        (canvas-browser--tabs-changed)))))

(defun canvas-browser--target-created (params)
  "Show the page of PARAMS in a buffer of its own, if one of ours opened it.
A page of the web that no page of Emacs opened, as a link from another
program, is shown too, while `canvas-browser-show-strays\=' is on.  A
frame or a worker is left alone, but the window of any page is put out
of sight when `canvas-browser-window-strategy\=' says so."
  (let* ((info (plist-get params :targetInfo))
         (target (plist-get info :targetId))
         (opener (canvas-browser--buffer-of-target (plist-get info :openerId))))
    (when (equal (plist-get info :type) "page")
      (canvas-browser-cdp-put-away-window target))
    (cond ((and opener
                (equal (plist-get info :type) "page")
                (not (canvas-browser--buffer-of-target target)))
           (canvas-browser--show-window target (plist-get info :url) opener))
          ((and (not opener) canvas-browser-show-strays (canvas-browser--stray-p info))
           (canvas-browser--show-stray info t)))))

(defun canvas-browser--show-window (target url opener)
  "Show TARGET, a window the page of OPENER opened at URL; its buffer.
It is laid out at the size of the page that opened it, or of another
page when no page of Emacs opened it, until a window of Emacs shows it
and it is fitted to that."
  (let* ((buffer (canvas-browser--page-buffer url))
         (like (or opener
                   (seq-find (lambda (other)
                               (and (not (eq other buffer))
                                    (eq (buffer-local-value 'major-mode other) 'canvas-browser-mode)
                                    (buffer-local-value 'canvas-browser--size other)))
                             (buffer-list))))
         (size (or (and like (buffer-local-value 'canvas-browser--size like))
                   '(800 . 600))))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (canvas-browser--adopt (car size) (cdr size))
      (setq canvas-browser--url url
            canvas-browser--target target)
      (canvas-browser--attach))
    buffer))

(defun canvas-browser--target-destroyed (params)
  "Take the buffer of the page PARAMS names away: the page closed itself.
A window to sign in closes itself once you have, and a browser takes its
window away then.  The page is gone, so chromium is not asked to close
it again."
  (when-let* ((buffer (canvas-browser--buffer-of-target (plist-get params :targetId))))
    (with-current-buffer buffer
      (setq canvas-browser--target nil))
    (kill-buffer buffer)))

(defun canvas-browser--open (url width height)
  "Open URL in this buffer, on a canvas WIDTH by HEIGHT; URL."
  (canvas-browser--connect)
  (canvas-browser--watch-targets)
  (canvas-browser--adopt width height)
  (setq canvas-browser--url url
        canvas-browser--opening t)
  ;; A new tab is one more to keep for the next session.
  (canvas-browser--keep-tabs-soon)
  (let ((buffer (current-buffer)))
    (canvas-browser-cdp-send
     "Target.createTarget"
     ;; A tab behind another is hidden, and chromium stops drawing its
     ;; video.  A page embedded elsewhere is in no window of Emacs that
     ;; brings it to the front, so it gets a window of its own.  Off
     ;; your screen every page does.
     (cons :url (cons "about:blank"
                      (canvas-browser-cdp-target-window canvas-browser--host)))
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if-let* ((target (plist-get result :targetId)))
               (progn
                 (setq canvas-browser--target target)
                 (canvas-browser--attach url))
             ;; A page chromium would not open may be asked again.
             (setq canvas-browser--opening nil)))))))
  url)

(defvar canvas-browser--chooser)

(defun canvas-browser--release ()
  "Close this buffer's target and forget its session.
A choice of files that this page waited for is forgotten with it."
  (when (eq (plist-get canvas-browser--chooser :buffer) (current-buffer))
    (canvas-browser--attach-finish))
  (setq canvas-browser--screencast nil)
  (when canvas-browser--session
    (canvas-browser-cdp-forget canvas-browser--session))
  (when (and canvas-browser--target (canvas-browser-cdp-running-p))
    (puthash canvas-browser--target t canvas-browser--let-go)
    (canvas-browser-cdp-send "Target.closeTarget"
                             (list :targetId canvas-browser--target)))
  (when canvas-browser--context
    (canvas-cairo-destroy canvas-browser--context)
    (setq canvas-browser--context nil))
  (when canvas-browser--fresh-timer
    (cancel-timer canvas-browser--fresh-timer)
    (setq canvas-browser--fresh-timer nil))
  (when canvas-browser--crisp-timer
    (cancel-timer canvas-browser--crisp-timer)
    (setq canvas-browser--crisp-timer nil))
  (canvas-browser--forget-live)
  (canvas-browser--forget-files)
  ;; Every window with tabs loses this page's tab.
  (canvas-browser--tabs-changed))

(defun canvas-browser--forget-files ()
  "Delete the pictures this page wrote, now that nobody reads them."
  (when canvas-browser--number
    (dolist (suffix canvas-browser--suffixes)
      (let ((file (canvas-browser--file "frame" suffix)))
        (when (file-exists-p file)
          (delete-file file))))
    (setq canvas-browser--last-frame nil)))

;;;; The keyboard and the mouse

(defvar-local canvas-browser--insert nil
  "Whether the keys of this buffer go to the page.")

(defconst canvas-browser--keys
  '(("Enter" 13 "\r") ("Tab" 9) ("Backspace" 8) ("Delete" 46) ("Escape" 27)
    ("ArrowLeft" 37) ("ArrowUp" 38) ("ArrowRight" 39) ("ArrowDown" 40)
    ("Home" 36) ("End" 35) ("PageUp" 33) ("PageDown" 34)
    ("a" 65 nil "KeyA") ("z" 90 nil "KeyZ"))
  "The keys chromium is sent: the name, the number Windows gives the key,
the text it types, if any, and its code where that is not its name.
Chromium edits a field by that number: a key sent by its name alone
reaches the page as an event that deletes and moves nothing.")

(defconst canvas-browser--modifier-keys '((control . 2) (shift . 8))
  "The bits of the modifiers DevTools knows, by their name in Emacs.")

(defconst canvas-browser--insert-keys
  '(("RET" "Enter") ("DEL" "Backspace") ("<backspace>" "Backspace")
    ("<deletechar>" "Delete") ("<delete>" "Delete")
    ("<up>" "ArrowUp") ("<down>" "ArrowDown")
    ("<left>" "ArrowLeft") ("<right>" "ArrowRight")
    ("<home>" "Home") ("<end>" "End") ("<prior>" "PageUp") ("<next>" "PageDown")
    ;; The editing keys of Emacs, as a field of a browser knows them.
    ("C-a" "Home") ("C-e" "End") ("C-f" "ArrowRight") ("C-b" "ArrowLeft")
    ("C-n" "ArrowDown") ("C-p" "ArrowUp")
    ("M-f" "ArrowRight" control) ("M-b" "ArrowLeft" control)
    ("M-<" "Home" control) ("M->" "End" control)
    ("C-<home>" "Home" control) ("C-<end>" "End" control)
    ("C-d" "Delete") ("M-d" "Delete" control) ("M-DEL" "Backspace" control)
    ;; The keys of a browser itself.  Emacs binds them to the same
    ;; motions and deletions, in the buffer, where a page has no text.
    ("C-<right>" "ArrowRight" control) ("C-<left>" "ArrowLeft" control)
    ("M-<right>" "ArrowRight" control) ("M-<left>" "ArrowLeft" control)
    ("C-<up>" "ArrowUp" control) ("C-<down>" "ArrowDown" control)
    ("C-<backspace>" "Backspace" control) ("C-<delete>" "Delete" control)
    ;; Shift with a motion marks, as it does in a browser.
    ("S-<left>" "ArrowLeft" shift) ("S-<right>" "ArrowRight" shift)
    ("S-<up>" "ArrowUp" shift) ("S-<down>" "ArrowDown" shift)
    ("S-<home>" "Home" shift) ("S-<end>" "End" shift)
    ("C-S-<left>" "ArrowLeft" control shift) ("C-S-<right>" "ArrowRight" control shift)
    ("C-S-<home>" "Home" control shift) ("C-S-<end>" "End" control shift)
    ;; A chat sends on Enter and breaks the line on Shift and Enter, and
    ;; many a form is sent with Control and Enter.
    ("S-<return>" "Enter" shift) ("C-<return>" "Enter" control) ("C-j" "Enter")
    ("C-v" "PageDown")
    ("M-{" "ArrowUp" control) ("M-}" "ArrowDown" control))
  "The keys of insert state that go to the page as a key rather than text.
Each is the key in Emacs, the name of the key it is in a browser, and
the modifiers held with it: a browser moves and deletes a word with
Control where Emacs does it with Meta, and goes to the ends of a field
with Control and Home or End.")

(defun canvas-browser--modifiers (names)
  "The DevTools bits of the modifiers NAMES."
  (cl-loop for name in names
           sum (or (alist-get name canvas-browser--modifier-keys)
                   (error "canvas-browser: no modifier named %S" name))))

(defun canvas-browser--key (key &optional modifiers answer)
  "Send KEY, a DevTools key name, to the page, down and up.
MODIFIERS, a list such as (shift), are held with it.  A key with a text
goes down as a key that types, unless Control is held with it: a page
that sends its form on Control and Enter must not get a line break as
well.  Any other key goes down as a raw key.  ANSWER, when given, is
called once chromium has handled the key's release."
  (pcase-let* ((`(,_ ,number ,text ,code)
                (or (assoc key canvas-browser--keys)
                    (error "canvas-browser: no key named %S" key)))
               (text (and (not (memq 'control modifiers)) text))
               (event (list :key key :code (or code key)
                            :windowsVirtualKeyCode number :nativeVirtualKeyCode number
                            :modifiers (canvas-browser--modifiers modifiers))))
    (canvas-browser--tell "Input.dispatchKeyEvent"
                          (append (if text
                                      (list :type "keyDown" :text text :unmodifiedText text)
                                    (list :type "rawKeyDown"))
                                  event))
    (canvas-browser--tell "Input.dispatchKeyEvent" (cons :type (cons "keyUp" event))
                          answer)))

(defun canvas-browser--character-number (character)
  "The number Windows gives the key of CHARACTER, or nil for none.
Letters, digits and the space have one; a page may look at it."
  (cond ((<= ?a character ?z) (upcase character))
        ((or (<= ?A character ?Z) (<= ?0 character ?9) (= character ?\s)) character)))

(defun canvas-browser--type-character (character)
  "Type CHARACTER into whatever has the focus of the page, as a key does.
Text put in without a key lands at the caret, and the caret stays behind
in a field the focus has moved on from: a letter typed on a button would
land in the field before it."
  (let* ((text (string character))
         (number (canvas-browser--character-number character))
         (event (append (list :key text)
                        (when number
                          (list :windowsVirtualKeyCode number :nativeVirtualKeyCode number)))))
    (canvas-browser--tell "Input.dispatchKeyEvent"
                          (append (list :type "keyDown" :text text :unmodifiedText text) event))
    (canvas-browser--tell "Input.dispatchKeyEvent" (append (list :type "keyUp") event))))

(defvar canvas-browser--focus-box)

(defvar-local canvas-browser--field-mark nil
  "Whether a region is being marked in the field that has the focus.")

(defconst canvas-browser--motion-keys
  '("ArrowLeft" "ArrowRight" "ArrowUp" "ArrowDown" "Home" "End" "PageUp" "PageDown")
  "The keys that move the caret of a field; held with Shift, they mark.")

(defconst canvas-browser--field-region-js
  "(function (collapse) {
     let e = document.activeElement;
     while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
     if (!e) return '';
     let start = null;
     try { start = e.selectionStart; } catch (other) { start = null; }
     if (typeof start === 'number' && typeof e.value === 'string') {
       const text = e.value.substring(e.selectionStart, e.selectionEnd);
       if (collapse) {
         const at = e.selectionDirection === 'backward' ? e.selectionStart : e.selectionEnd;
         e.setSelectionRange(at, at);
       }
       return text;
     }
     const root = e.getRootNode && e.getRootNode();
     const s = root && root.getSelection ? root.getSelection() : getSelection();
     const text = s ? s.toString() : '';
     if (collapse && s && s.focusNode) s.collapse(s.focusNode, s.focusOffset);
     return text;
   })(%s)"
  "The JavaScript that gives the text marked in the field with the focus.
With true, the mark is dropped as well, and the caret stays where it
was, as it does after `M-w\=' in a buffer.")

(defun canvas-browser-field-set-mark ()
  "Set the mark in the field, so that the motions after it mark a region.
Pressed again, it drops the mark."
  (interactive)
  (if canvas-browser--field-mark
      (canvas-browser--field-drop-mark)
    (setq canvas-browser--field-mark t)
    (message "Mark set")))

(defun canvas-browser-field-mark-whole ()
  "Mark all of the field, as `C-x h\=' marks all of a buffer.
Control and A go to the page, which is how a browser marks all of a
field, so an editor that a page built itself takes it as well."
  (interactive)
  (canvas-browser--key "a" '(control))
  (setq canvas-browser--field-mark t))

(defun canvas-browser-field-undo ()
  "Undo the last change of the field, as a browser does on Control and Z."
  (interactive)
  (canvas-browser--key "z" '(control)))

(defun canvas-browser-field-redo ()
  "Do again what was undone in the field."
  (interactive)
  (canvas-browser--key "z" '(control shift)))

(defun canvas-browser--field-drop-mark ()
  "Drop the mark of the field, and the region it marks."
  (setq canvas-browser--field-mark nil)
  (canvas-browser--evaluate (format canvas-browser--field-region-js "true") #'ignore))

(defun canvas-browser--field-take (collapse then)
  "Put the region of the field in the kill ring, pulse the field, and THEN.
With COLLAPSE the region is dropped as well; THEN is called in this
buffer with the text."
  (let ((buffer (current-buffer))
        (box canvas-browser--focus-box))
    (setq canvas-browser--field-mark nil)
    (canvas-browser--evaluate
     (format canvas-browser--field-region-js (if collapse "true" "false"))
     (lambda (text)
       (if (and (stringp text) (not (string-empty-p text)))
           (progn (kill-new text)
                  (when box (canvas-browser--pulse buffer box))
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer (funcall then text))))
         (message "canvas-browser: nothing is marked in the field"))))))

(defun canvas-browser-field-copy ()
  "Copy the region of the field to the kill ring."
  (interactive)
  (canvas-browser--field-take
   t (lambda (text) (message "canvas-browser: copied %d characters" (length text)))))

(defun canvas-browser-field-cut ()
  "Move the region of the field to the kill ring."
  (interactive)
  (canvas-browser--field-take nil (lambda (_text) (canvas-browser--key "Backspace"))))

(defun canvas-browser-insert-quit ()
  "Drop the mark of the field when it is set, else give the keys back to Emacs.
This is `C-g\=' while typing into the page, as it is in a buffer: a
region goes first, and the second `C-g\=' leaves."
  (interactive)
  (if canvas-browser--field-mark
      (canvas-browser--field-drop-mark)
    (canvas-browser-normal-mode)))

(defun canvas-browser-self-insert ()
  "Type the key that called this command into the page.
The key is the last event, never the keys of the command: letters read
while a hint was chosen count among those, and would be typed with it."
  (interactive)
  (cl-assert (characterp last-command-event) nil
             "canvas-browser: %S types no text" last-command-event)
  ;; A letter takes the place of the region, which is gone with the mark.
  (setq canvas-browser--field-mark nil)
  (canvas-browser--type-character last-command-event))

(defun canvas-browser-send-key ()
  "Send the key that called this command to the page, as a browser knows it."
  (interactive)
  (let* ((keys (key-description (vector last-command-event)))
         (entry (or (assoc keys canvas-browser--insert-keys)
                    (error "canvas-browser: %s is no key of insert state" keys)))
         (key (nth 1 entry))
         (modifiers (nthcdr 2 entry)))
    ;; With the mark set a motion marks, as it does in a buffer, and any
    ;; other key, a deletion say, is done with the region.
    (if (and canvas-browser--field-mark (member key canvas-browser--motion-keys))
        (setq modifiers (cl-adjoin 'shift modifiers))
      (setq canvas-browser--field-mark nil))
    (canvas-browser--key key modifiers)))

(defconst canvas-browser--selection-change-js
  "new Promise(resolve => {
     let done = false;
     const finish = how => {
       if (done) return;
       done = true;
       document.removeEventListener('selectionchange', onChange, true);
       resolve(how);
     };
     const onChange = () => finish('changed');
     document.addEventListener('selectionchange', onChange, true);
     setTimeout(() => finish('unchanged'), 100);
   })"
  "The JavaScript of a promise that the next change of the selection keeps.
The page tells its listeners of a change in the order they were added,
so an editor that listens is told before this promise is kept.  When
nothing changes within a tenth of a second, the promise is kept as well.")

(defun canvas-browser--here (function)
  "A function that calls FUNCTION with its arguments in this buffer.
It does nothing once the buffer is gone."
  (let ((buffer (current-buffer)))
    (lambda (&rest arguments)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (apply function arguments))))))

(defun canvas-browser--after-selection-change (then)
  "Call THEN in this buffer once the page has told of a selection change.
Call this before the key that changes the selection is sent.  An editor
that keeps a selection of its own, as the one of Reddit does, learns of
a new selection a moment after the key that made it.  A second key sent
right after the first reaches it before that, and acts on the old
selection."
  (canvas-browser-cdp-send
   "Runtime.evaluate"
   (list :expression canvas-browser--selection-change-js :awaitPromise t :returnByValue t)
   (canvas-browser--here (lambda (_result) (funcall then)))
   canvas-browser--session))

(defconst canvas-browser--field-length-js
  "(function () {
     let e = document.activeElement;
     while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
     if (!e) return 0;
     return (typeof e.value === 'string' ? e.value : e.innerText || '').length;
   })()"
  "The JavaScript that gives the length of the text of the field with the focus.")

(defun canvas-browser--kill-text (text append)
  "Put TEXT in the kill ring, at the end of the newest kill if APPEND."
  (if append (kill-append text nil) (kill-new text)))

(defun canvas-browser--field-length (then)
  "Call THEN in this buffer with the length of the text of the field."
  (canvas-browser--evaluate canvas-browser--field-length-js (canvas-browser--here then)))

(defun canvas-browser--kill-line-break (append)
  "Delete forward in the field, and kill a newline if a line break went.
The field tells that by its text, which is shorter after the key.  At
the end of the field nothing goes, and nothing is killed.  APPEND is as
in `canvas-browser--kill-text\='."
  (canvas-browser--field-length
   (lambda (before)
     (canvas-browser--key
      "Delete" nil
      (canvas-browser--here
       (lambda (_result)
         (canvas-browser--field-length
          (lambda (after)
            (when (< after before)
              (canvas-browser--kill-text "\n" append))))))))))

(defun canvas-browser--kill-marked (append)
  "Kill what is marked in the field, or the line break if nothing is.
APPEND is as in `canvas-browser--kill-text\='."
  (canvas-browser--evaluate
   (format canvas-browser--field-region-js "false")
   (canvas-browser--here
    (lambda (text)
      (if (and (stringp text) (not (string-empty-p text)))
          (progn (canvas-browser--kill-text text append)
                 (canvas-browser--key "Delete"))
        (canvas-browser--kill-line-break append))))))

(defun canvas-browser-kill-line ()
  "Kill from the cursor to the end of the line of the field.
At the end of a line, the line break goes, as with `C-k\=' in a buffer,
and two of them in a row make one kill.  Shift and End mark the rest of
the line, and Delete follows once the page has told of the mark."
  (interactive)
  (let ((append (eq last-command 'kill-region)))
    ;; The name by which Emacs knows a kill, so that the next kill adds
    ;; to this one, whichever command makes it.
    (setq this-command 'kill-region)
    (canvas-browser--after-selection-change
     (lambda () (canvas-browser--kill-marked append)))
    (canvas-browser--key "End" '(shift))))

(defun canvas-browser-yank ()
  "Type the newest kill of Emacs into the field."
  (interactive)
  (canvas-browser--tell "Input.insertText" (list :text (current-kill 0))))

(defun canvas-browser-copy-url ()
  "Copy the address of this page to the kill ring.
The key is `y\=', which copies the address of a link after `h\=' as well.
`w\=', the key of eww, is a key of every canvas buffer."
  (interactive)
  (unless canvas-browser--url
    (user-error "canvas-browser: this page has no address yet"))
  (kill-new canvas-browser--url)
  (message "canvas-browser: copied %s" canvas-browser--url))

(defun canvas-browser--wheel (x y delta &optional across modifiers)
  "Turn the wheel DELTA pixels at the page pixel X Y, down for a positive one.
ACROSS turns it as many pixels to the right, or to the left for a
negative one, and MODIFIERS, the bits of `canvas-browser--modifier-bits\=',
are the keys held.  Chromium sends the turn to whatever lies under that
pixel, so a part of the page that scrolls on its own scrolls when the
pointer is over it, and a page that draws on a canvas, as Figma, moves
it as it likes: Shift and the wheel across, Control and the wheel zoom."
  (canvas-browser--tell "Input.dispatchMouseEvent"
                        (list :type "mouseWheel" :x x :y y
                              :deltaX (or across 0) :deltaY delta
                              :modifiers (or modifiers 0))))

(defun canvas-browser--modifier-bits (modifiers)
  "The bits chromium reads for MODIFIERS, the modifiers of an event of Emacs.
Chromium counts Alt as 1, Control as 2, Meta, which is Command on a Mac,
as 4, and Shift as 8.  On a Mac Emacs names Command and Option as
`ns-command-modifier\=' and `ns-option-modifier\=' say; elsewhere meta is
Alt and super is the Meta of chromium."
  (let* ((command (if (boundp 'ns-command-modifier) ns-command-modifier 'super))
         (option (if (boundp 'ns-option-modifier) ns-option-modifier 'meta))
         (bits 0))
    (dolist (modifier modifiers bits)
      (setq bits (logior bits
                         (cond ((eq modifier 'shift) 8)
                               ((eq modifier 'control) 2)
                               ((eq modifier command) 4)
                               ((eq modifier option) 1)
                               (t 0)))))))

(defvar-local canvas-browser--scroller nil
  "The place of the part of the page the scroll keys move, or nil for all of it.
The page holds the parts themselves in an array of its own, and this is
the place of one of them there.")

(defconst canvas-browser--scroll-page-script
  "(function (mode, value) {
     const root = document.scrollingElement || document.documentElement;
     const shut = e => !!e && ['hidden', 'clip'].includes(getComputedStyle(e).overflowY);
     if (root.scrollHeight > innerHeight + 1 &&
         !shut(document.documentElement) && !shut(document.body)) { %s; return; }
     let best = null, most = 0;
     for (const e of document.querySelectorAll('*')) {
       if (e.scrollHeight <= e.clientHeight + 1) continue;
       if (!['auto', 'scroll', 'overlay'].includes(getComputedStyle(e).overflowY)) continue;
       const r = e.getBoundingClientRect();
       const area = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0)) *
                    Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
       if (area > most) { most = area; best = e; }
     }
     if (!best) return;
     if (mode === 'by') best.scrollBy(0, value);
     else if (mode === 'end') best.scrollTo(0, best.scrollHeight);
     else best.scrollTo(0, value);
   })('%s', %d)"
  "The JavaScript that scrolls the page, by the expression it is given.
A page that does not scroll as a whole, such as Notion, scrolls a part
of itself instead, and the scroll keys move the largest part in view
that scrolls, as `S\=' would have them move it.")

(defun canvas-browser--scroll (mode value expression)
  "Scroll the picked part of the page, or all of it.
MODE and VALUE say how the part moves, and EXPRESSION is the JavaScript
that moves the whole page instead, when no part is picked.  The page
scrolls itself: chromium animates a wheel event and swallows a small one,
and a key that does nothing for a second reads as a key that does nothing
at all."
  (if canvas-browser--scroller
      (canvas-browser--scroll-part mode value)
    (canvas-browser--tell "Runtime.evaluate"
                          (list :expression (format canvas-browser--scroll-page-script
                                                    expression mode value)))))


(defun canvas-browser--scroll-by (delta)
  "Scroll DELTA pixels, further down for a positive DELTA."
  (canvas-browser--scroll "by" delta (format "window.scrollBy(0, %d)" delta)))

(defun canvas-browser-scroll-up ()
  "Scroll the page one screen further down."
  (interactive)
  (canvas-browser--scroll-by (- (cdr canvas-browser--size) 60)))

(defun canvas-browser-scroll-down ()
  "Scroll the page one screen back."
  (interactive)
  (canvas-browser--scroll-by (- 60 (cdr canvas-browser--size))))

(defun canvas-browser-beginning-of-page ()
  "Go to the top of the page, or of the part picked."
  (interactive)
  (canvas-browser--scroll "to" 0 "window.scrollTo(0, 0)"))

(defun canvas-browser-end-of-page ()
  "Go to the foot of the page, or of the part picked, as far as it reaches."
  (interactive)
  (canvas-browser--scroll "end" 0 "window.scrollTo(0, document.body.scrollHeight)"))

(defcustom canvas-browser-line-height 40
  "Pixels that one scroll of a line moves the page."
  :type 'integer
  :group 'canvas-browser)

(defun canvas-browser-scroll-line-up ()
  "Scroll the page one line further down."
  (interactive)
  (canvas-browser--scroll-by canvas-browser-line-height))

(defun canvas-browser-scroll-line-down ()
  "Scroll the page one line back."
  (interactive)
  (canvas-browser--scroll-by (- canvas-browser-line-height)))

(defcustom canvas-browser-wheel-step 60
  "Pixels that one turn of the wheel moves the page."
  :type 'integer
  :group 'canvas-browser)

(defun canvas-browser--event-page-window (event)
  "The window EVENT, an event of the mouse, happened in, if it shows a page.
Emacs looks the event up in the keys of that window, but runs the
command in the window you are in, which may hold any other buffer.  An
embedded page is clicked through its host, whose window shows no page,
and is left to the command."
  (let ((window (posn-window (event-start event))))
    (and (window-live-p window)
         (eq (buffer-local-value 'major-mode (window-buffer window)) 'canvas-browser-mode)
         window)))

(defun canvas-browser--event-buffer (event)
  "The page buffer EVENT happened over, or else this buffer."
  (let ((window (canvas-browser--event-page-window event)))
    (if window (window-buffer window) (current-buffer))))

(defun canvas-browser--select-event-window (event)
  "Select the page window EVENT, a click or a drag on a page, happened in.
A click on the page of another window goes there, as a click does in
any window of Emacs, so that what you type next reaches that page."
  (when-let* ((window (canvas-browser--event-page-window event)))
    (select-window window)))

(defun canvas-browser-wheel (event)
  "Scroll where EVENT, a turn of the wheel over the canvas, points.
The turn goes to the page at that very pixel, so the part under the
pointer scrolls, as it does in a window of chromium\='s own.  Emacs reports
a fast turn as a double or a triple event, and each one scrolls
`canvas-browser-wheel-step\' pixels.
The page under the pointer scrolls, though another window is selected."
  (interactive "e")
  (let ((turn (event-basic-type event)))
    (cl-assert (memq turn '(wheel-up wheel-down wheel-left wheel-right)) nil
               "canvas-browser: %S is not a turn of the wheel" turn)
    (let ((at (posn-object-x-y (event-start event)))
          (step canvas-browser-wheel-step))
      (with-current-buffer (canvas-browser--event-buffer event)
        (canvas-browser--wheel (car at) (cdr at)
                               (pcase turn ('wheel-up (- step)) ('wheel-down step) (_ 0))
                               (pcase turn ('wheel-left (- step)) ('wheel-right step) (_ 0))
                               (canvas-browser--modifier-bits (event-modifiers event)))))))

(defvar-local canvas-browser--pinch-scale 1.0
  "The scale the pinch had at its last event, since its fingers came down.")

(defun canvas-browser-pinch (event)
  "Zoom the page under EVENT, a pinch of the trackpad, as a browser does.
A browser hands a pinch to the page as a turn of the wheel with Control
held, and a page as Figma zooms by it; the text of Emacs keeps its size.
The pinch says its scale since the fingers came down, so each event
turns the wheel by the change since the one before."
  (interactive "e")
  (let* ((scale (nth 4 event))
         (start (and (zerop (nth 2 event)) (zerop (nth 3 event)) (zerop (nth 5 event))))
         (at (posn-object-x-y (event-start event))))
    (with-current-buffer (canvas-browser--event-buffer event)
      (when start
        (setq canvas-browser--pinch-scale 1.0))
      (when (and (numberp scale) (> scale 0) (/= scale canvas-browser--pinch-scale))
        (canvas-browser--wheel (car at) (cdr at)
                               (* -100 (log (/ scale canvas-browser--pinch-scale)))
                               0 2)
        (setq canvas-browser--pinch-scale scale)))))

(defconst canvas-browser--takes-typing-js
  "const takesTyping = e => !!e && (e.isContentEditable || e.tagName === 'TEXTAREA' ||
     (e.tagName === 'INPUT' &&
      !['button', 'submit', 'reset', 'checkbox', 'radio', 'file', 'image',
        'range', 'color', 'hidden'].includes((e.type || 'text').toLowerCase())));"
  "The JavaScript of `takesTyping\=', whether an element is a field to type in.")

(defconst canvas-browser--focus-script
  (concat "(function () {" canvas-browser--takes-typing-js "
     var e = document.activeElement, ox = 0, oy = 0;
     while (e) {
       if (e.shadowRoot && e.shadowRoot.activeElement) {
         e = e.shadowRoot.activeElement;
         continue;
       }
       if (e.tagName === 'IFRAME') {
         var inner = null;
         try { inner = e.contentDocument && e.contentDocument.activeElement; }
         catch (other) { inner = null; }
         if (inner && inner !== e.contentDocument.body) {
           var frame = e.getBoundingClientRect();
           ox += frame.left; oy += frame.top;
           e = inner;
           continue;
         }
       }
       break;
     }
     var box = null;
     if (e && e !== document.body && e !== document.documentElement) {
       var r = e.getBoundingClientRect();
       var left = Math.max(r.left + ox, 0), top = Math.max(r.top + oy, 0);
       var right = Math.min(r.right + ox, innerWidth), bottom = Math.min(r.bottom + oy, innerHeight);
       if (right - left >= 1 && bottom - top >= 1)
         box = [Math.round(left), Math.round(top), Math.round(right - left), Math.round(bottom - top)];
     }
     return {typing: takesTyping(e), box: box};
   })()")
  "The JavaScript that tells what has the focus: whether it takes typing,
and the box of it in the window, or null when nothing shows it.
The focus of a document is the web component that holds the field, or
the frame; the field itself is the focus of the component\'s shadow root,
or of the frame\'s document, so the script follows it down, and a frame
moves the box by where the frame stands.  A frame of another site cannot
be looked into, and `i\=' sends the keys there.")

(defun canvas-browser--click (x y)
  "Click the page at the pixel X Y, and type there if it takes typing.
The page is asked what has the focus once chromium has handled the
click: asked sooner, it names what had the focus before it."
  (canvas-browser--tell "Input.dispatchMouseEvent"
                        (list :type "mousePressed" :x x :y y
                              :button "left" :clickCount 1))
  (canvas-browser--tell "Input.dispatchMouseEvent"
                        (list :type "mouseReleased" :x x :y y
                              :button "left" :clickCount 1)
                        (canvas-browser--follow-focus-later)))

(defun canvas-browser--drag (x1 y1 x2 y2)
  "Drag the mouse over the page from the pixel X1 Y1 to X2 Y2.
The page gets a press, a move with the left button held, and a release,
so it marks what lies between as it does in any browser.  The focus is
followed as after a click: a drag in a field types there.  Text marked
outside a field goes to the caret of the page."
  (let ((left (list :button "left" :clickCount 1)))
    (canvas-browser--tell "Input.dispatchMouseEvent"
                          (append (list :type "mousePressed" :x x1 :y y1) left))
    (canvas-browser--tell "Input.dispatchMouseEvent"
                          (list :type "mouseMoved" :x x2 :y y2 :button "left" :buttons 1))
    (canvas-browser--tell "Input.dispatchMouseEvent"
                          (append (list :type "mouseReleased" :x x2 :y y2) left)
                          (canvas-browser--here #'canvas-browser--after-drag))))

(defun canvas-browser--after-drag (&rest _)
  "Follow the focus as after a click, and give marked text to the caret.
The page is asked for the text once it has said what has the focus, so
the caret knows whether the drag was in a field."
  (canvas-browser--follow-focus)
  (canvas-browser--evaluate-here "getSelection().toString()"
                                 #'canvas-browser--caret-take-region))

(defun canvas-browser--follow-focus-later ()
  "A function that follows the focus of this page when chromium answers.
Asked before chromium has handled a click or a tab, the page names what
had the focus before it."
  (let ((buffer (current-buffer)))
    (lambda (_result)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (canvas-browser--follow-focus))))))

(defconst canvas-browser--next-field-script
  (concat "(function (step) {" canvas-browser--takes-typing-js "
     const fields = [];
     const counts = e => takesTyping(e) && !e.disabled && !e.readOnly &&
       !(e.parentElement && e.parentElement.isContentEditable) &&
       e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0;
     const walk = root => root.querySelectorAll('*').forEach(e => {
       if (counts(e)) fields.push(e);
       if (e.shadowRoot) walk(e.shadowRoot);
     });
     walk(document);
     if (!fields.length) return false;
     let focus = document.activeElement;
     while (focus && focus.shadowRoot && focus.shadowRoot.activeElement)
       focus = focus.shadowRoot.activeElement;
     const here = fields.indexOf(focus);
     const next = here < 0 ? (step > 0 ? 0 : fields.length - 1)
                           : (here + step + fields.length) %% fields.length;
     fields[next].focus();
     return true;
   })(%d)")
  "The JavaScript that focuses the field STEP fields on from the focus.
The fields are taken in the order of the page, web components included,
and the first and the last follow one another.")

(defun canvas-browser--go-to-field (step)
  "Focus the field STEP fields on from the one with the focus, and type there.
Only fields count, as with the `gi\=' of Vimium: a page puts buttons
between its fields, as Reddit puts the one that shows the password
between the name and the password, and a tab of the browser's own stops
at every one."
  (canvas-browser--tell "Runtime.evaluate"
                        (list :expression (format canvas-browser--next-field-script step))
                        (canvas-browser--follow-focus-later)))

(defun canvas-browser-next-field ()
  "Go to the next field of the page, and type there."
  (interactive)
  (canvas-browser--go-to-field 1))

(defun canvas-browser-previous-field ()
  "Go to the field before, and type there."
  (interactive)
  (canvas-browser--go-to-field -1))

(defun canvas-browser--follow-focus ()
  "Send the keys to the page while a box you can type in has the focus.
A click in a field is how a reader says they want to type there, and a
click anywhere else is how they say they have finished.  The eye is
drawn from where the focus was to where it is."
  (let ((buffer (current-buffer)))
    (canvas-browser--evaluate
     canvas-browser--focus-script
     (lambda (focus)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if (eq (plist-get focus :typing) t)
               (unless canvas-browser--insert (canvas-browser-insert-mode))
             (when canvas-browser--insert (canvas-browser-normal-mode)))
           (canvas-browser--focus-moved (plist-get focus :box))))))))

(defvar-local canvas-browser--focus-box nil
  "The box of what had the focus of this page when last asked, or nil.")

(defcustom canvas-browser-focus-function #'canvas-browser--fly-focus
  "Function that draws the eye from where the focus was to where it is.
It is called in the page buffer with the two boxes, plists of x, y, w
and h in the pixels of the page, when a click or a tab moves the focus,
and when the caret of the page moves.
The default flies smear-cursor\='s cursor from one to the other while
smear-cursor is on, and with it off does nothing.  nil never flies."
  :type '(choice (const nil) function)
  :group 'canvas-browser)

(defun canvas-browser--box-of (box)
  "BOX, (X Y W H) as the page gives it, as a plist; nil for anything else.
The page gives null for a box that nothing shows."
  (and (consp box)
       (list :x (nth 0 box) :y (nth 1 box) :w (nth 2 box) :h (nth 3 box))))

(defun canvas-browser--fly (from to)
  "Draw the eye from FROM to TO, boxes of this page, when both are known."
  (when (and from to canvas-browser-focus-function (not (equal from to)))
    (funcall canvas-browser-focus-function from to)))

(defun canvas-browser--focus-moved (box)
  "Keep BOX, (X Y W H) or not a list, as the focus, and fly to it.
A focus the reader cannot see is forgotten, so that the next one is not
flown to from a place out of sight."
  (let ((to (canvas-browser--box-of box)))
    (canvas-browser--fly canvas-browser--focus-box to)
    (setq canvas-browser--focus-box to)))

(defun canvas-browser-click (event)
  "Click the page where EVENT, a click on the canvas, points."
  (interactive "e")
  (canvas-browser--select-event-window event)
  (let ((at (posn-object-x-y (event-start event))))
    (canvas-browser--click (car at) (cdr at))))

(defun canvas-browser--page-pixel (position)
  "The pixel of the page that POSITION, a mouse position, is on, as (X . Y).
Nil when the position is on something else in the window."
  (and (posn-image position) (posn-object-x-y position)))

(defun canvas-browser-drag (event)
  "Drag the mouse over the page as EVENT, a drag on the canvas, did.
The page marks the text between the two ends.  In a field, `M-w\=' then
copies it."
  (interactive "e")
  (canvas-browser--select-event-window event)
  (let ((from (canvas-browser--page-pixel (event-start event)))
        (to (canvas-browser--page-pixel (event-end event))))
    (unless (and from to)
      (user-error "canvas-browser: the drag ended off the page"))
    (canvas-browser--drag (car from) (cdr from) (car to) (cdr to))))

(defun canvas-browser-back ()
  "Go back in the history of the page."
  (interactive)
  (canvas-browser--tell "Runtime.evaluate" (list :expression "history.back()")))

(defun canvas-browser-forward ()
  "Go forward in the history of the page."
  (interactive)
  (canvas-browser--tell "Runtime.evaluate" (list :expression "history.forward()")))

(defcustom canvas-browser-search-url "https://duckduckgo.com/?q=%s"
  "Where words that are not a URL are searched for."
  :type 'string
  :group 'canvas-browser)

(defconst canvas-browser--local-host "\\`\\(localhost\\|127\\.0\\.0\\.1\\|\\[::1\\]\\)\\([:/]\\|\\'\\)"
  "How an address of this machine starts, which http serves.")

(defun canvas-browser--url-of (text)
  "TEXT as a URL: its own scheme, else one that fits, else a search.
A local address gets http, since a server on this machine rarely has a
certificate, and a host gets https.  Words, or a word with no dot, are
searched for, as a browser does; a host with no dot needs its scheme."
  (let ((text (string-trim text)))
    (cond ((string-match-p canvas-browser--local-host text) (concat "http://" text))
          ;; A port is no scheme: localhost:8080 is a host, mailto:a@b is not.
          ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:\\(//\\|[^0-9]\\)" text) text)
          ((or (string-match-p "[ \t]" text) (not (string-search "." text)))
           (format canvas-browser-search-url (url-hexify-string text)))
          (t (concat "https://" text)))))

(defun canvas-browser--snap-can-read-p (file)
  "Whether a snap chromium can read FILE: a file of the home, in no hidden
directory of it."
  (let ((relative (file-relative-name (expand-file-name file) (expand-file-name "~"))))
    (not (or (string-prefix-p "../" relative)
             (string-match-p "\\(\\`\\|/\\)\\." relative)))))

(defun canvas-browser--copy-for-snap (file)
  "Copy FILE where a snap chromium can read it; return the copy."
  (let ((directory (expand-file-name "canvas-browser-files" (canvas-browser-cdp-snap-home))))
    (make-directory directory t)
    (let ((copy (expand-file-name (file-name-nondirectory file) directory)))
      (copy-file file copy t)
      copy)))

(defun canvas-browser--readable-url (url)
  "URL as the chromium in use can read it.
A snap chromium has a /tmp of its own and reads no hidden directory of
the home.  So a local file elsewhere, such as a page another package
wrote to /tmp, is copied to the snap's own directory first.  Only the
file is copied, so a page that loads files beside it finds none."
  (let* ((parsed (and (string-prefix-p "file://" url) (url-generic-parse-url url)))
         (file (and parsed (url-unhex-string (url-filename parsed)))))
    (if (and file (canvas-browser-cdp-snap-p) (not (canvas-browser--snap-can-read-p file)))
        (concat "file://" (canvas-browser--copy-for-snap file)
                (if (url-target parsed) (concat "#" (url-target parsed)) ""))
      url)))

(defun canvas-browser--reachable-url (text)
  "TEXT as a URL the chromium in use can reach; see `canvas-browser--url-of'."
  (canvas-browser--readable-url (canvas-browser--url-of text)))

(defvar canvas-browser--url-history nil
  "The addresses edited with `canvas-browser-edit-url\='.")

(defun canvas-browser-edit-url (url)
  "Go to URL in this buffer, asked for as the address of this page to edit.
Words become a search, as with `canvas-browser-open-url\='."
  (interactive
   (list (read-string "URL: " canvas-browser--url 'canvas-browser--url-history)))
  (canvas-browser-open-url url))

(defun canvas-browser-open-url (url)
  "Go to URL in this buffer.
A URL without a scheme gets one, and words become a search.  Asked
for, the bookmarks of pages are offered, and the one picked is gone to
in this buffer; what matches none of them is taken as a URL."
  (interactive (list (canvas-browser--read-page-or-url)))
  (when (string-blank-p url)
    (user-error "canvas-browser: no page or URL given"))
  (setq canvas-browser--url (canvas-browser--reachable-url url)
        canvas-browser--asked-url canvas-browser--url)
  (canvas-browser--tell "Page.navigate" (list :url canvas-browser--url)))

;;;; Link hints

(defcustom canvas-browser-hint-keys "asdfghjkl"
  "The letters that a hint is made of."
  :type 'string
  :group 'canvas-browser)

(defconst canvas-browser--reach-js
  "const walk = (root, selector, visit) => {
     root.querySelectorAll(selector).forEach(visit);
     root.querySelectorAll('*').forEach(e => { if (e.shadowRoot) walk(e.shadowRoot, selector, visit); });
   };
   const up = n => n.assignedSlot || n.parentNode || n.host;
   const hit = (x, y) => {
     let e = document.elementFromPoint(x, y);
     while (e && e.shadowRoot) {
       const inner = e.shadowRoot.elementFromPoint(x, y);
       if (!inner || inner === e) break;
       e = inner;
     }
     return e;
   };
   const shown = e => {
     const r = e.getBoundingClientRect();
     const left = Math.max(r.left, 0), top = Math.max(r.top, 0);
     const right = Math.min(r.right, innerWidth), bottom = Math.min(r.bottom, innerHeight);
     return {x: Math.round(left), y: Math.round(top),
             w: Math.round(right - left), h: Math.round(bottom - top)};
   };
   const middle = box => [box.x + box.w / 2, box.y + box.h / 2];"
  "The JavaScript both sets of hints are found with.
`walk\\=' looks into the open shadow root of every web component, since
`querySelectorAll\\=' stops at one, and the fields of a login form may sit
inside.  `up\\=' goes to the parent a click passes through, the slot a web
component puts the page\\='s own text in included.  `hit\\=' is what a click
at a point reaches, inside web components too, and `shown\\=' is the part
of an element inside the window.")

(defconst canvas-browser--boxes-script
  (concat "(function () {" canvas-browser--reach-js "
     const found = new Set();
     walk(document, 'a,button,input,select,textarea,iframe,[onclick],' +
          '[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],' +
          '[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],' +
          '[role=option],[role=combobox],[role=textbox],[role=searchbox],' +
          '[role=slider],[role=spinbutton],[role=treeitem]',
          e => { if (e.tagName !== 'IFRAME' || e.getBoundingClientRect().height <= 100) found.add(e); });
     const pointer = e => getComputedStyle(e).cursor === 'pointer';
     const half = innerWidth * innerHeight / 2;
     const pointerRoots = (e, parentPointer) => {
       if (found.has(e)) return;
       const here = pointer(e);
       if (here && !parentPointer && e !== document.body) {
         const box = shown(e);
         if (box.w >= 5 && box.h >= 5 && box.w * box.h <= half) found.add(e);
         return;
       }
       if (e.shadowRoot) for (const child of e.shadowRoot.children) pointerRoots(child, here);
       for (const child of e.children) pointerRoots(child, here);
     };
     pointerRoots(document.documentElement, false);
     const owner = e => {
       for (let n = e; n; n = up(n)) if (found.has(n)) return n;
       return null;
     };
     const reached = e => {
       const box = shown(e);
       if (box.w < 5 || box.h < 5) return null;
       const [x, y] = middle(box);
       const h = hit(x, y);
       if (!h) return null;
       const label = h.closest && h.closest('label');
       return {box, owner: label && label.control === e ? e : owner(h)};
     };
     const places = new Map();
     const covered = [];
     found.forEach(e => {
       const at = reached(e);
       if (!at) return;
       if (at.owner === e) places.set(e, at.box);
       else covered.push(at);
     });
     covered.forEach(at => {
       if (at.owner && !places.has(at.owner)) places.set(at.owner, at.box);
     });
     window.__canvasBrowserTargets = Array.from(places.keys());
     return Array.from(places.values());
   })()")
  "The JavaScript that gives the boxes of everything a click can reach.
A region the page shows the pointer over counts as well, as a script
that listens for clicks marks one: the outermost element of it, unless
it fills half the window.  A picture of Reddit opens so.
A thing counts where a click in the middle of what shows of it reaches
it, or reaches its label.  A thing covered there by another thing that
can be clicked gives its place to that one, which a click there reaches:
the link over a post of Reddit covers its title, and the title is where
that link takes its hint.  Otherwise what lies outside the window, under a
dialog, or around something else that can be clicked, as a link around
a button does, takes no hint.  A hint spent on those is a hint the
things that can be clicked go without.  A role counts only where it says
the thing does something, as Vimium has it: an icon or a heading that
says it only looks takes none, and inside a button it would crowd the
button.  Nor does a thing of a few pixels, as a tracker is.  A frame the
size of a button counts, since a click in it reaches what it holds, as
with Google\\='s button to sign in; a larger one is an advertisement.  The
things are kept in the page, in the order of their boxes, so that the
action of a hint can ask for the address or the text of one.")

(defconst canvas-browser--blocks-script
  (concat "(function () {" canvas-browser--reach-js "
     const blocks = 'header,nav,main,aside,footer,article,section,form,dialog,table,pre,' +
       'figure,img,video,canvas,blockquote,iframe,[role=dialog],[role=article],' +
       '[role=region],[role=main],[role=navigation],[role=complementary],' +
       '[role=banner],[role=contentinfo],[role=feed]';
     const inside = (outer, e) => { for (let n = e; n; n = up(n)) if (n === outer) return true; return false; };
     const same = (a, b) => Math.abs(a.x - b.x) < 3 && Math.abs(a.y - b.y) < 3 &&
                            Math.abs(a.w - b.w) < 3 && Math.abs(a.h - b.h) < 3;
     const targets = [], boxes = [];
     walk(document, blocks, e => {
       const box = shown(e);
       if (box.w < 40 || box.h < 20) return;
       const [x, y] = middle(box);
       const h = hit(x, y);
       if (!h || !inside(e, h)) return;
       if (boxes.some(other => same(other, box))) return;
       targets.push(e);
       boxes.push(box);
     });
     window.__canvasBrowserTargets = targets;
     return boxes;
   })()")
  "The JavaScript that gives the boxes of the blocks of a page, to copy.
A block is a part the page itself marks as one: a header, a sidebar, an
article, a dialog, a table, a piece of code, a picture.  Only what shows
counts, so a block under a dialog takes no hint, and a block whose box
is that of one taken already is the same picture and takes none.")

(defun canvas-browser--evaluate (script answer)
  "Run SCRIPT in the page, and call ANSWER with the value it gives."
  (canvas-browser-cdp-send
   "Runtime.evaluate"
   (list :expression script :returnByValue t)
   (lambda (result) (funcall answer (plist-get (plist-get result :result) :value)))
   canvas-browser--session))

(defun canvas-browser--evaluate-here (script answer)
  "Run SCRIPT in the page, and call ANSWER in this buffer with its value.
Chromium answers in whichever buffer is current when its answer comes,
and a buffer killed before then gets none."
  (let ((buffer (current-buffer)))
    (canvas-browser--evaluate
     script
     (lambda (value)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (funcall answer value)))))))

(defun canvas-browser--boxes (answer)
  "Call ANSWER with the boxes of the page, each a plist of x, y, w and h."
  (canvas-browser--evaluate canvas-browser--boxes-script answer))

(defun canvas-browser--hint-letters (count)
  "COUNT hints of `canvas-browser-hint-keys\=', all of one length.
The length is the shortest that names COUNT boxes, so no hint is the
start of another, and a box past the last hint of two letters gets one
of three rather than none."
  (let* ((keys (mapcar #'char-to-string canvas-browser-hint-keys))
         (hints keys))
    (cl-assert (> (length keys) 1) nil
               "canvas-browser: `canvas-browser-hint-keys' needs two letters at least")
    (while (< (length hints) count)
      (setq hints (cl-loop for hint in hints
                           append (mapcar (lambda (key) (concat hint key)) keys))))
    (seq-take hints count)))

(defun canvas-browser--box-middle (box)
  "The middle of BOX, a plist of x, y, w and h, as (X . Y).
The client parses JSON into plists, so a box is one too."
  (cons (+ (plist-get box :x) (/ (plist-get box :w) 2))
        (+ (plist-get box :y) (/ (plist-get box :h) 2))))

(defcustom canvas-browser-hint-font "Sans Bold 11"
  "The font a hint is written in, as pango describes a font."
  :type 'string
  :group 'canvas-browser)

(defconst canvas-browser--hint-colour #xFFFFD633
  "The colour a hint is written on, as ARGB32.")

(defun canvas-browser--hint-size (hint)
  "The (W . H) of the label of HINT on the canvas of this buffer."
  (let ((size (canvas-cairo-text-size canvas-browser--context hint canvas-browser-hint-font)))
    (cons (+ 6 (car size)) (+ 4 (cdr size)))))

(defun canvas-browser--rects-meet-p (a b)
  "Whether the rectangles A and B, each (X Y W H), overlap."
  (pcase-let ((`(,ax ,ay ,aw ,ah) a)
              (`(,bx ,by ,bw ,bh) b))
    (and (< ax (+ bx bw)) (< bx (+ ax aw)) (< ay (+ by bh)) (< by (+ ay ah)))))

(defun canvas-browser--hint-places (boxes sizes)
  "Where the label of each of BOXES goes, as (X . Y), in their order.
SIZES are the (W . H) of the labels.  A label goes at the top left corner
of its box.  The small boxes are placed first, and a label whose corner a
label placed before it covers goes in the middle of its box instead,
where a click on it lands anyway: two labels at one corner hide one, as
a post of Reddit that is a link hides under the link of its author."
  (let ((places (make-vector (length boxes) nil))
        (taken nil))
    (dolist (place (sort (number-sequence 0 (1- (length boxes)))
                         (lambda (i j) (< (canvas-browser--box-area (nth i boxes))
                                          (canvas-browser--box-area (nth j boxes))))))
      (let* ((box (nth place boxes))
             (size (nth place sizes))
             (corner (cons (plist-get box :x) (plist-get box :y)))
             (at (if (cl-some (lambda (rect)
                                (canvas-browser--rects-meet-p
                                 (list (car corner) (cdr corner) (car size) (cdr size)) rect))
                              taken)
                     (let ((middle (canvas-browser--box-middle box)))
                       (cons (- (car middle) (/ (car size) 2))
                             (- (cdr middle) (/ (cdr size) 2))))
                   corner)))
        (aset places place at)
        (push (list (car at) (cdr at) (car size) (cdr size)) taken)))
    (append places nil)))

(defun canvas-browser--draw-hints (boxes hints)
  "Draw HINTS over BOXES on the canvas of this buffer."
  (cl-loop for at in (canvas-browser--hint-places boxes (mapcar #'canvas-browser--hint-size hints))
           for hint in hints
           do (canvas-browser--draw-hint (car at) (cdr at) hint))
  (canvas-refresh canvas-browser--canvas)
  (force-window-update (current-buffer)))

(defun canvas-browser--set-colour (context colour)
  "Have CONTEXT draw in COLOUR, an ARGB32."
  (canvas-cairo-set-color context
                          (/ (ash (logand colour #xFF0000) -16) 255.0)
                          (/ (ash (logand colour #xFF00) -8) 255.0)
                          (/ (logand colour #xFF) 255.0)
                          (/ (ash (logand colour #xFF000000) -24) 255.0)))

(defun canvas-browser--draw-hint (x y hint)
  "Draw HINT at X Y: its letters on a box of the hint's colour."
  (let ((context canvas-browser--context)
        (size (canvas-browser--hint-size hint)))
    (canvas-browser--set-colour context canvas-browser--hint-colour)
    (canvas-cairo-rectangle context x y (car size) (cdr size))
    (canvas-cairo-fill context)
    (canvas-cairo-set-color context 0 0 0 1)
    (canvas-cairo-text context (+ x 3) (+ y 2) hint canvas-browser-hint-font)))

(defun canvas-browser--check-actions (actions)
  "Signal an error when a key of ACTIONS, or `?', is a letter of the hints.
A key that is both would pick an action or name a hint, and nobody could
say which; avy refuses such a key as well.  `?' lists the actions."
  (when actions
    (when (seq-contains-p canvas-browser-hint-keys ??)
      (error "canvas-browser: `?' is a hint letter, and it lists the actions of a hint"))
    (when-let* ((clash (seq-find (lambda (action)
                                   (seq-contains-p canvas-browser-hint-keys (car action)))
                                 actions)))
      (error "canvas-browser: `%c' is a hint letter and the key of %s too"
             (car clash) (nth 1 clash)))))

(defun canvas-browser--hint-prompt (typed action help actions)
  "The prompt for a hint: the letters TYPED so far, and ACTION if chosen.
With HELP it lists ACTIONS, each key and what it does; with ACTIONS it
says that `?' lists them."
  (format "Hint%s: %s"
          (cond (action (concat ", " (nth 1 action)))
                (help (concat " (" (mapconcat (lambda (entry)
                                                (format "%c %s" (car entry) (nth 1 entry)))
                                              actions ", ")
                              ")"))
                (actions ", ? for actions")
                (t ""))
          typed))

(defun canvas-browser--read-hint (hints &optional actions)
  "Read letters until they name one of HINTS; (PLACE . ACTION), or nil.
Before the first letter, a key of ACTIONS picks what the hint does, as
the dispatch of avy does, and the prompt then names it; ACTION is that
entry, or nil for none.  `?\=' lists the actions in the prompt, as it
does in avy.  `ESC\\=' gives nil.  The hints are read while
chromium's answer is handled, between two commands, and Emacs counts
keys read there among the keys of the next one; they are forgotten as
such once read, and kept in the record of keys that `view-lossage\\='
shows."
  (canvas-browser--check-actions actions)
  (let ((typed "") (action nil) (help nil))
    (prog1
        (catch 'done
          (while t
            (let ((key (read-key (canvas-browser--hint-prompt typed action help actions))))
              (cond ((eq key ?\e) (throw 'done nil))
                    ((and actions (string-empty-p typed) (eq key ??))
                     (setq help t))
                    ((and (string-empty-p typed) (assq key actions))
                     (setq action (assq key actions)))
                    (t
                     (setq typed (concat typed (char-to-string key)))
                     (when-let* ((place (cl-position typed hints :test #'equal)))
                       (throw 'done (cons place action)))
                     (unless (cl-some (lambda (hint) (string-prefix-p typed hint)) hints)
                       (throw 'done nil)))))))
      (clear-this-command-keys t))))

(defun canvas-browser--choose-box (boxes &optional actions)
  "Label BOXES on the canvas; (PLACE . ACTION) of the one named, or nil.
ACTIONS are the keys that may pick what the hint does first.
The labels are drawn over the page, so the page is asked for a picture of
itself afterwards, which takes them off again."
  (let ((hints (canvas-browser--hint-letters (length boxes))))
    (canvas-browser--draw-hints boxes hints)
    (setq canvas-browser--hinting t)
    (unwind-protect
        (canvas-browser--read-hint hints actions)
      (setq canvas-browser--hinting nil)
      (canvas-browser--paint-window))))

(defconst canvas-browser--hint-actions
  '((?y "copy address" canvas-browser--copy-address)
    (?w "copy text" canvas-browser--copy-text)
    (?c "copy picture" canvas-browser--copy-picture)
    (?o "open" canvas-browser--open-target)
    (?e "eww" canvas-browser--eww-target))
  "What a hint may do, each on a key pressed before its letters.
The key, the words the prompt shows, and the function, called with the
place of the thing named and its box.  None of these keys may be a
letter of the hints.")

(defun canvas-browser--act (chosen boxes default)
  "Do to the box CHOSEN names, of BOXES, what its action says, or DEFAULT.
CHOSEN is the (PLACE . ACTION) of `canvas-browser--read-hint\'."
  (funcall (or (nth 2 (cdr chosen)) default) (car chosen) (nth (car chosen) boxes)))

(defun canvas-browser--on-target (place script answer)
  "Run SCRIPT, a function of one element, on the thing at PLACE; to ANSWER.
The things are those the last hints were put on, kept in the page."
  (canvas-browser--evaluate
   (format "(%s)(window.__canvasBrowserTargets[%d])" script place) answer))

(defconst canvas-browser--address-js
  "e => { const link = e.closest ? e.closest('a[href]') : null;
          return (link && link.href) || e.href || e.src || ''; }"
  "The JavaScript function that gives the address of an element, or \"\".")

(defun canvas-browser--with-address (place then)
  "Call THEN with the address of the thing at PLACE, or say it has none."
  (canvas-browser--on-target
   place canvas-browser--address-js
   (lambda (address)
     (if (and (stringp address) (not (string-empty-p address)))
         (funcall then address)
       (message "canvas-browser: that has no address")))))

(defcustom canvas-browser-pulse-function #'canvas-browser--pulse-box
  "Function that draws the eye to what a hint copied, or nil for none.
It is called in the page buffer with the box of the thing copied, a
plist of x, y, w and h in the pixels of the page.  The default plays
smear-cursor's copy effect over the box while smear-cursor is on, and
with it off does nothing, as the pulse of canvas-diagram does."
  :type '(choice (const nil) function)
  :group 'canvas-browser)

(declare-function smear-cursor-flash-in-picture "smear-cursor"
                  (occasion pos rects &optional window))
(defvar smear-cursor-mode)
(defvar canvas-browser--zoom)

(defun canvas-browser--in-picture (box)
  "BOX of the page, a plist of x, y, w and h, as [X Y W H] in the picture.
The page is one glyph, the picture of the canvas, drawn at the zoom of
the page."
  (vector (* canvas-browser--zoom (plist-get box :x))
          (* canvas-browser--zoom (plist-get box :y))
          (* canvas-browser--zoom (plist-get box :w))
          (* canvas-browser--zoom (plist-get box :h))))

(defun canvas-browser--smear-window (function)
  "The window showing this page, when smear-cursor is on and has FUNCTION."
  (and (bound-and-true-p smear-cursor-mode)
       (fboundp function)
       (get-buffer-window (current-buffer) t)))

(defun canvas-browser--pulse-box (box)
  "Flash BOX of this page with smear-cursor's copy effect, if it is on."
  (when-let* ((window (canvas-browser--smear-window 'smear-cursor-flash-in-picture)))
    (smear-cursor-flash-in-picture 'copy (point-min)
                                   (list (canvas-browser--in-picture box)) window)))

(declare-function smear-cursor-fly-in-picture "smear-cursor"
                  (pos from to &optional window))

(defun canvas-browser--fly-focus (from to)
  "Fly smear-cursor's cursor from FROM to TO, boxes of this page, if it is on."
  (when-let* ((window (canvas-browser--smear-window 'smear-cursor-fly-in-picture)))
    (smear-cursor-fly-in-picture (point-min)
                                 (canvas-browser--in-picture from)
                                 (canvas-browser--in-picture to)
                                 window)))

(defun canvas-browser--pulse (buffer box)
  "Draw the eye to BOX of BUFFER's page, which was just copied."
  (when (and canvas-browser-pulse-function (buffer-live-p buffer))
    (with-current-buffer buffer
      (funcall canvas-browser-pulse-function box))))

(defun canvas-browser--click-target (_place box)
  "Click the middle of BOX."
  (let ((middle (canvas-browser--box-middle box)))
    (canvas-browser--click (car middle) (cdr middle))))

(defun canvas-browser--copy-address (place box)
  "Put the address of the thing at PLACE in the kill ring, and pulse BOX."
  (let ((buffer (current-buffer)))
    (canvas-browser--with-address
     place (lambda (address)
             (kill-new address)
             (canvas-browser--pulse buffer box)
             (message "canvas-browser: copied %s" address)))))

(defun canvas-browser--copy-text (place box)
  "Put the text of the thing at PLACE in the kill ring, and pulse BOX."
  (let ((buffer (current-buffer)))
    (canvas-browser--on-target
     place "e => (e.innerText || e.value || e.textContent || '').trim()"
     (lambda (text)
       (if (and (stringp text) (not (string-empty-p text)))
           (progn (kill-new text)
                  (canvas-browser--pulse buffer box)
                  (message "canvas-browser: copied %d characters" (length text)))
         (message "canvas-browser: that has no text"))))))

(defconst canvas-browser--shown-part-js
  "e => { const r = e.getBoundingClientRect();
          const left = Math.max(r.left, 0), top = Math.max(r.top, 0);
          const right = Math.min(r.right, innerWidth), bottom = Math.min(r.bottom, innerHeight);
          return [left, top, right - left, bottom - top, innerWidth]; }"
  "The JavaScript function that gives the part of an element in the window.
It answers with its place in the window, its size, and the width of the
window, all in the pixels of the page, which is what a picture of the
window is cut by.")

(defun canvas-browser--copy-picture (place _box)
  "Copy the picture of the thing at PLACE, as much of it as shows, as a PNG."
  (let ((buffer (current-buffer)))
    (canvas-browser--on-target
     place canvas-browser--shown-part-js
     (lambda (part)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (canvas-browser--capture-part part)))))))

(defun canvas-browser--crop-png (png x y width height)
  "The part of PNG, a string of bytes, WIDTH by HEIGHT at X Y, as a PNG."
  (let* ((size (or (canvas-browser--picture-size png)
                   (error "canvas-browser: that is no picture to cut")))
         (whole (make-temp-file "canvas-browser-whole-" nil ".png"))
         (part (make-temp-file "canvas-browser-part-" nil ".png"))
         (context (canvas-cairo-context
                   (list 'image :type 'canvas :id (make-symbol "canvas-browser-part")
                         :data-width width :data-height height))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (write-region png nil whole nil 'silent))
          (canvas-cairo-image context whole (- x) (- y) (car size) (cdr size))
          (canvas-cairo-write-png context part)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally part)
            (buffer-string)))
      (canvas-cairo-destroy context)
      (delete-file whole)
      (delete-file part))))

(defun canvas-browser--capture-part (part)
  "Copy PART of the window, (X Y WIDTH HEIGHT VIEW-WIDTH), as a PNG.
The part is cut in Emacs from a picture of the whole window, in its own
pixels, which are VIEW-WIDTH across the window.  Chromium cuts a part by
moving the view of the page to it for a while, and every frame and every
picture of that while shows the page shifted into the corner of the
window, or a part of it repeated across the window."
  (pcase-let ((`(,x ,y ,width ,height ,view) part)
              (buffer (current-buffer)))
    (canvas-browser-cdp-send
     "Page.captureScreenshot"
     (list :format "png")
     (lambda (result)
       (if-let* ((data (plist-get result :data)))
           (let* ((whole (base64-decode-string data))
                  (scale (/ (float (car (canvas-browser--picture-size whole))) view)))
             (canvas-keys-copy-png
              (canvas-browser--crop-png whole
                                        (round (* x scale)) (round (* y scale))
                                        (round (* width scale)) (round (* height scale))))
             (canvas-browser--pulse buffer (list :x x :y y :w width :h height))
             (message "canvas-browser: copied a picture of %d by %d"
                      (round width) (round height)))
         (message "canvas-browser: chromium took no picture of that")))
     canvas-browser--session)))

(defun canvas-browser--open-target (place _box)
  "Open the address of the thing at PLACE in a page buffer of its own."
  (canvas-browser--with-address place #'canvas-browser))

(defun canvas-browser--eww-target (place _box)
  "Open the address of the thing at PLACE in eww."
  (canvas-browser--with-address place #'eww))

(defun canvas-browser-hints ()
  "Label everything that can be clicked, and click the one you name.
A key of `canvas-browser--hint-actions\' pressed before the letters does
something else with it: copy its address, its text or its picture, or
open it in a buffer of its own or in eww."
  (interactive)
  (canvas-browser--boxes
   (lambda (boxes)
     (if (null boxes)
         (message "canvas-browser: nothing to click on this page")
       (when-let* ((chosen (canvas-browser--choose-box boxes canvas-browser--hint-actions)))
         (canvas-browser--act chosen boxes #'canvas-browser--click-target))))))

(defun canvas-browser--blocks (answer)
  "Call ANSWER with the boxes of the blocks of the page."
  (canvas-browser--evaluate canvas-browser--blocks-script answer))

(defun canvas-browser-copy-block ()
  "Label the blocks of the page, and copy the picture of the one you name.
A key of `canvas-browser--hint-actions\' pressed before the letters
copies something else of it, such as its text with `w\'.  This is what
`M-w\' does in a page; with a prefix it copies the whole window."
  (interactive)
  (canvas-browser--blocks
   (lambda (boxes)
     (if (null boxes)
         (message "canvas-browser: nothing on this page to copy")
       (when-let* ((chosen (canvas-browser--choose-box boxes canvas-browser--hint-actions)))
         (canvas-browser--act chosen boxes #'canvas-browser--copy-picture))))))

;;;; The part of the page that scrolls on its own

(defconst canvas-browser--scrollers-script
  "(function () {
     const parts = Array.from(document.querySelectorAll('*')).filter(e => {
       if (e.scrollHeight <= e.clientHeight + 4) return false;
       const overflow = getComputedStyle(e).overflowY;
       if (overflow !== 'auto' && overflow !== 'scroll') return false;
       const r = e.getBoundingClientRect();
       return r.width > 40 && r.height > 40 && r.top < innerHeight && r.bottom > 0;
     });
     window.__canvasBrowserScrollers = parts;
     return parts.map(e => {
       const r = e.getBoundingClientRect();
       return {x: Math.round(Math.max(r.x, 0)), y: Math.round(Math.max(r.y, 0)),
               w: Math.round(r.width), h: Math.round(r.height)};
     });
   })()"
  "The JavaScript that gives the boxes of the parts that scroll on their own.
It keeps the parts in the page as well, so that a scroll key can move one
of them by the place it has there.")

(defun canvas-browser--scrollers (answer)
  "Call ANSWER with the boxes of the parts that scroll on their own."
  (canvas-browser--evaluate canvas-browser--scrollers-script answer))

(defconst canvas-browser--scroll-part-script
  "(function (i, mode, value) {
     const parts = window.__canvasBrowserScrollers;
     const part = parts && parts[i];
     if (!part || !document.contains(part)) return false;
     if (mode === 'by') part.scrollBy(0, value);
     else if (mode === 'end') part.scrollTo(0, part.scrollHeight);
     else part.scrollTo(0, value);
     return true;
   })(%d, '%s', %d)"
  "The JavaScript that scrolls the part picked.
It answers false when that part has gone, which a new page or a page that
drew itself again both do.")

(defun canvas-browser--scroll-part (mode value)
  "Scroll the part picked: MODE is `by\=', `to\=' or `end\=', by or to VALUE.
A part the page has thrown away is forgotten, and the keys go back to the
whole page: a key that silently does nothing reads as a broken key."
  (let ((buffer (current-buffer)))
    (canvas-browser--evaluate
     (format canvas-browser--scroll-part-script canvas-browser--scroller mode value)
     (lambda (there)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (unless (eq there t) (canvas-browser--forget-scroller))))))))

(defun canvas-browser--forget-scroller ()
  "Scroll the whole page again, and say why."
  (setq canvas-browser--scroller nil)
  (message "canvas-browser: that part has gone; the keys scroll the whole page again"))

(defun canvas-browser--took-scroller (place)
  "Send the scroll keys to the part at PLACE, or to the whole page for nil."
  (setq canvas-browser--scroller place)
  (message (if place
               "canvas-browser: the scroll keys move that part of the page"
             "canvas-browser: the scroll keys move the whole page")))

(defun canvas-browser--page-box ()
  "A box for the whole page, in the top corner, where few parts begin.
The page is labelled along with its parts, so that the keys go back to it
by a letter as well, the way every window `ace-window\=' labels carries
one, whether the keys are in it or not."
  (list :x (max 0 (- (car canvas-browser--size) 30)) :y 0 :w 30 :h 24))

(defun canvas-browser-pick-scroller ()
  "Label the parts of the page that scroll on their own, and pick one.
The scroll keys then move the part you name, the way `ace-window\=' hands
the keys to the window you name.  The whole page carries the first letter,
and `ESC\=' gives the keys back to it as well.  The wheel needs none of
this: it scrolls whatever the pointer is over."
  (interactive)
  (canvas-browser--scrollers
   (lambda (boxes)
     (if (null boxes)
         (message "canvas-browser: nothing here scrolls on its own")
       (let ((place (car (canvas-browser--choose-box
                          (cons (canvas-browser--page-box) boxes)))))
         (canvas-browser--took-scroller (and place (> place 0) (1- place))))))))

;;;; Find in page, and the text of a page

(defvar-local canvas-browser--last-search nil
  "The last string searched for in this page.")

(defvar-local canvas-browser--find-index 0
  "Which hit of the last search the page shows.")

(defconst canvas-browser--find-script "
(function (text, index) {
  const style = 'canvas-browser-find-style';
  if (!document.getElementById(style)) {
    const sheet = document.createElement('style');
    sheet.id = style;
    sheet.textContent = '::highlight(canvas-browser-find) { background: #ffd54f; color: #000; }';
    document.documentElement.appendChild(sheet);
  }
  if (!text) { CSS.highlights.delete('canvas-browser-find'); return {count: 0, index: 0}; }
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const ranges = [];
  const wanted = text.toLowerCase();
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const line = node.textContent.toLowerCase();
    for (let at = line.indexOf(wanted); at !== -1; at = line.indexOf(wanted, at + wanted.length)) {
      const range = document.createRange();
      range.setStart(node, at);
      range.setEnd(node, at + text.length);
      if (range.getBoundingClientRect().width > 0) ranges.push(range);
    }
  }
  if (ranges.length === 0) { CSS.highlights.delete('canvas-browser-find'); return {count: 0, index: 0}; }
  const at = ((index %% ranges.length) + ranges.length) %% ranges.length;
  CSS.highlights.set('canvas-browser-find', new Highlight(...ranges));
  const rect = ranges[at].getBoundingClientRect();
  window.scrollBy(0, rect.top - innerHeight / 2);
  return {count: ranges.length, index: at};
})(%s, %d)"
  "The JavaScript that finds a string, paints every hit and scrolls to one.
`window.find\=' answers in a headless chromium but leaves nothing to see,
so the page paints the hits itself, with the highlight API of CSS.")

(defun canvas-browser--find (string index)
  "Search the page for STRING and show the hit at INDEX."
  (unless (and string (not (string-empty-p string)))
    (user-error "canvas-browser: nothing has been searched for yet"))
  (setq canvas-browser--last-search string
        canvas-browser--find-index index)
  (canvas-browser-cdp-send
   "Runtime.evaluate"
   (list :expression (format canvas-browser--find-script (json-encode string) index)
         :returnByValue t)
   #'canvas-browser--found
   canvas-browser--session))

(defun canvas-browser--found (result)
  "Say what RESULT, the answer of the search, found."
  (let* ((value (plist-get (plist-get result :result) :value))
         (count (or (plist-get value :count) 0)))
    (if (zerop count)
        (message "canvas-browser: no hit for %s" canvas-browser--last-search)
      (message "canvas-browser: hit %d of %d" (1+ (plist-get value :index)) count))))

(defun canvas-browser-find (string)
  "Search the page for STRING, and paint every hit."
  (interactive (list (read-string "Find in page: " nil nil canvas-browser--last-search)))
  (canvas-browser--find string 0))

(defun canvas-browser-find-next ()
  "Show the next hit of the last search."
  (interactive)
  (canvas-browser--find canvas-browser--last-search (1+ canvas-browser--find-index)))

(defun canvas-browser-find-previous ()
  "Show the hit before this one."
  (interactive)
  (canvas-browser--find canvas-browser--last-search (1- canvas-browser--find-index)))

;;;; Dark mode

(defcustom canvas-browser-dark nil
  "Whether a page is shown dark.
`canvas-browser-toggle-dark\=' sets it, and `C-x C-s\=' in the menu keeps
it, so that the pages you open after it are shown the same way."
  :type 'boolean
  :group 'canvas-browser)

(defun canvas-browser-toggle-dark ()
  "Turn dark mode on for this page, or off again.
The page hears that the reader prefers dark, and chromium darkens a page
that carries no dark of its own."
  (interactive)
  (setq canvas-browser-dark (not canvas-browser-dark))
  (canvas-browser--apply-dark)
  (message "canvas-browser: dark mode is %s" (if canvas-browser-dark "on" "off")))

(defun canvas-browser--apply-dark ()
  "Tell the page whether it is shown dark.
It is told again after a picture of the whole page: chromium draws that
picture with its own dark turned off, and leaves the page that way."
  (canvas-browser--tell "Emulation.setEmulatedMedia"
                        (list :features (vector (list :name "prefers-color-scheme"
                                                      :value (if canvas-browser-dark
                                                                 "dark" "light")))))
  (canvas-browser--tell "Emulation.setAutoDarkModeOverride"
                        (list :enabled (if canvas-browser-dark t :json-false))))

(defun canvas-browser-search-text ()
  "Put the text of the page in a buffer and search it with `consult-line\='.
Without consult, isearch takes over in that buffer."
  (interactive)
  (canvas-browser--fill-text #'display-buffer)
  (with-current-buffer (canvas-browser--text-buffer)
    (if (fboundp 'consult-line)
        (call-interactively 'consult-line)
      (call-interactively 'isearch-forward))))

(defun canvas-browser--text-buffer ()
  "The buffer that holds the text of this page.
It is read only, and `q' quits its window, as in a help buffer."
  (let ((buffer (get-buffer-create (format "*canvas-browser-text: %s*"
                                           (or canvas-browser--title canvas-browser--url)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    buffer))

(defun canvas-browser-text ()
  "Put the text of the page in a buffer, where the keys of Emacs work.
The buffer is selected; `q' leaves it and goes back to the page."
  (interactive)
  (canvas-browser--fill-text #'pop-to-buffer))

(defun canvas-browser--fill-text (show)
  "Put the text of the page in its buffer, and call SHOW with that buffer."
  (let ((target (canvas-browser--text-buffer)))
    (canvas-browser-cdp-send
     "Runtime.evaluate" (list :expression "document.body.innerText" :returnByValue t)
     (lambda (result)
       (with-current-buffer target
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (or (plist-get (plist-get result :result) :value) ""))
           (goto-char (point-min))))
       (funcall show target))
     canvas-browser--session)))

;;;; The zoom and the picture

(defcustom canvas-browser-zoom-step 1.2
  "How much one zoom key changes the scale of the page."
  :type 'number
  :group 'canvas-browser)

(defvar-local canvas-browser--zoom 1.0
  "The scale of this page: 1.0 is its natural size.")

(defun canvas-browser--apply-zoom (&optional then)
  "Lay the page out for the zoom of this buffer, and scale it to the canvas.
THEN is called in this buffer once chromium has laid the page out: a
picture asked for before that is of the layout the page had."
  (let ((buffer (current-buffer)))
    (canvas-browser-cdp-send
     "Emulation.setDeviceMetricsOverride"
     (list :width (round (/ (car canvas-browser--size) canvas-browser--zoom))
           :height (round (/ (cdr canvas-browser--size) canvas-browser--zoom))
           :deviceScaleFactor canvas-browser--zoom
           :mobile :json-false)
     (when then
       (lambda (_result)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (funcall then)))))
     canvas-browser--session)))

(defun canvas-browser--zoom-by-key (direction)
  "Zoom the page: DIRECTION is `in\=', `out\=' or `reset\='.
It is this buffer's `canvas-keys-zoom-function\='."
  (setq canvas-browser--zoom
        (pcase direction
          ('in (min 5.0 (* canvas-browser--zoom canvas-browser-zoom-step)))
          ('out (max 0.25 (/ canvas-browser--zoom canvas-browser-zoom-step)))
          ('reset 1.0)
          ('fit (user-error "canvas-browser: a page has nothing whole to fit"))
          (other (error "canvas-browser: %S is no zoom" other))))
  (canvas-browser--apply-zoom))

(defun canvas-browser-write-picture (file)
  "Write the last frame of this page to FILE."
  (interactive "FWrite the picture to: ")
  (unless canvas-browser--last-frame
    (user-error "canvas-browser: this page has drawn nothing yet"))
  (copy-file canvas-browser--last-frame (expand-file-name file) t)
  (message "canvas-browser: wrote %s" file))

(defun canvas-browser-refresh (&rest _)
  "Read the page again; this buffer's `revert-buffer-function\='."
  (interactive)
  (canvas-browser--tell "Page.reload" nil))

;;;; A picture of the window

(defun canvas-browser--paint-window ()
  "Ask chromium for a picture of the window, and paint it.
The screencast sends a frame when the page changes, and a page that has
settled changes no more: after the draw of a whole page the window would
else keep the frame it had before that draw.  The picture is a PNG: a
page that has stopped moving is read rather than watched, and the JPEG of
a frame shows its workings around small text.  It costs about a fifth of
a second to make, which is far too slow for a frame and nothing for a
page that is standing still."
  (let ((buffer (current-buffer))
        (commands canvas-browser--commands))
    (canvas-browser-cdp-send
     "Page.captureScreenshot"
     (list :format "png")
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when-let* (((= commands canvas-browser--commands))
                       (data (plist-get result :data)))
             (canvas-browser--paint-soon data)))))
     canvas-browser--session)))

;;;; The pointer over a link

(defcustom canvas-browser-spots-delay 0.3
  "Seconds of quiet before the pointer areas of the page are read again."
  :type 'number
  :group 'canvas-browser)

(defvar-local canvas-browser--spots-timer nil
  "The timer that reads the pointer areas of this page.")

(defun canvas-browser--hot-spots (boxes)
  "The image map of BOXES: a rectangle each, under a hand pointer."
  (mapcar (lambda (box)
            (let ((x (plist-get box :x))
                  (y (plist-get box :y)))
              `((rect . ((,x . ,y) . (,(+ x (plist-get box :w))
                                      . ,(+ y (plist-get box :h)))))
                canvas-browser-link
                (pointer hand))))
          boxes))

(defun canvas-browser--flush-image ()
  "Drop this buffer's canvas from the image cache, through a frame that shows it.
`image-flush' with FRAME t frees the image through a hidden child frame,
and the frame that draws the canvas then keeps a line that points at the
freed image.  canvas-diagram carries the same lesson."
  (let ((frames (seq-filter #'display-graphic-p
                            (delete-dups (mapcar #'window-frame
                                                 (canvas-browser--showing-windows
                                                  (current-buffer)))))))
    (if frames
        (progn (image-flush canvas-browser--canvas (car frames))
               (mapc #'redraw-frame (cdr frames)))
      (image-flush canvas-browser--canvas t))))

(defun canvas-browser--put-spots (boxes)
  "Make the hot spots of BOXES the map of this buffer's canvas.
An equal map stays, since a new map is a new image-cache key, and its
flush redraws the frame."
  (let ((spots (canvas-browser--hot-spots boxes)))
    (unless (equal spots (plist-get (cdr canvas-browser--canvas) :map))
      (canvas-browser--flush-image)
      (plist-put (cdr canvas-browser--canvas) :map spots))))


(defun canvas-browser--sync-spots (buffer)
  "Read the boxes of BUFFER's page, and put their hot spots on its canvas."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq canvas-browser--spots-timer nil)
      ;; The connection may have gone since the timer was set, and an
      ;; error of a timer is printed over whatever the reader is doing.
      (when (and canvas-browser--session (canvas-browser-cdp-running-p))
        (canvas-browser--boxes
         (lambda (boxes)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (canvas-browser--put-spots boxes)))))))))

(defun canvas-browser--schedule-spots ()
  "Read the pointer areas of this page once it has been quiet for a moment."
  (when canvas-browser--spots-timer
    (cancel-timer canvas-browser--spots-timer))
  (setq canvas-browser--spots-timer
        (run-with-idle-timer canvas-browser-spots-delay nil
                             #'canvas-browser--sync-spots (current-buffer))))

;;;; The menu

(canvas-keys-define-menu canvas-browser-menu
    "The menu of a page buffer.
Its own columns stand in the first row, a word for each entry, and the
row every canvas menu carries comes below them: the zoom, the picture,
and the settings.  The widths line the columns of the two rows up."
  :column-widths '(13 13 24)
  ["Go"
   ("o" "open" canvas-browser-open-url)
   ("e" "edit URL" canvas-browser-edit-url)
   ("t" "new tab" canvas-browser-new-tab)
   ("x" "close" canvas-browser-close-tab)
   ("X" "reopen" canvas-browser-reopen-tab)
   ("r" "reload" canvas-browser-refresh)
   ("b" "back" canvas-browser-back)
   ("f" "forward" canvas-browser-forward)
   ("B" "bookmark" canvas-browser-bookmark)
   ("J" "bookmarks" canvas-browser-open-bookmark)
   ("l" "edit bookmarks" canvas-browser-list-bookmarks)]
  ["Page"
   ("h" "hints" canvas-browser-hints)
   ("M-j" "jump" canvas-browser-caret-jump)
   ("TAB" "field" canvas-browser-next-field)
   ("s" "find" canvas-browser-find)
   ("T" "text" canvas-browser-text)
   ("L" "lines" canvas-browser-search-text)
   ("y" "copy URL" canvas-browser-copy-url)]
  ["Modes"
   ("i" canvas-browser-insert-mode
    :description (lambda () (canvas-keys-setting "typing" 'canvas-browser--insert)))
   ("v" canvas-browser-caret-mode
    :description (lambda () (canvas-keys-setting "caret" 'canvas-browser--caret)))
   ("S" canvas-browser-pick-scroller
    :description (lambda ()
                   (canvas-keys-describe "scroll" (if canvas-browser--scroller "part" "page"))))])

(defvar canvas-browser-mode-map
  (define-keymap :parent (make-composed-keymap canvas-keys-mode-map special-mode-map))
  "Keymap of a page buffer in normal state.
The common canvas keys come from canvas-keys: `SPC\=' opens the menu,
`q\=' quits, `W\=' writes the picture, `C\=' customizes, and the zoom
keys zoom the page.  `r\=' reads the page again; `g\=' is no
`revert-buffer\=' here, since `g g\=' goes to the top of the page and
`G\=' to its foot, as in Vimium.")

;; The keys are bound here and not where the map is made.  A variable
;; keeps its value when its file is loaded again, so keys bound there
;; would never reach a running Emacs.
(define-keymap :keymap canvas-browser-mode-map
  "b" #'canvas-browser-back
  "f" #'canvas-browser-forward
  "M-p" #'canvas-browser-back
  "M-n" #'canvas-browser-forward
  "o" #'canvas-browser-open-url
  "e" #'canvas-browser-edit-url
  "r" #'canvas-browser-refresh
  "y" #'canvas-browser-copy-url
  "B" #'canvas-browser-bookmark
  "J" #'canvas-browser-open-bookmark
  "v" #'canvas-browser-caret-mode
  "M-j" #'canvas-browser-caret-jump
  ;; The key of avy jumps in the page, wherever it is bound, and even
  ;; from a map that beats this one, as `bind-key*' puts it.
  "<remap> <avy-goto-char-timer>" #'canvas-browser-caret-jump
  "i" #'canvas-browser-insert-mode
  "h" #'canvas-browser-hints
  "S" #'canvas-browser-pick-scroller
  "TAB" #'canvas-browser-next-field
  "<backtab>" #'canvas-browser-previous-field
  "C-s" #'canvas-browser-find
  "C-r" #'canvas-browser-find-previous
  "j" #'canvas-browser-scroll-line-up
  "k" #'canvas-browser-scroll-line-down
  "d" #'canvas-browser-scroll-up
  "u" #'canvas-browser-scroll-down
  "t" #'canvas-browser-new-tab
  "T" #'canvas-browser-text
  "M-s M-l" #'canvas-browser-search-text
  "z" #'canvas-keys-zoom-fit
  "<remap> <scroll-up-command>" #'canvas-browser-scroll-up
  "<remap> <scroll-down-command>" #'canvas-browser-scroll-down
  ;; A line key scrolls a line, as it moves a line in any other buffer.
  "<remap> <next-line>" #'canvas-browser-scroll-line-up
  "<remap> <previous-line>" #'canvas-browser-scroll-line-down
  "<remap> <beginning-of-buffer>" #'canvas-browser-beginning-of-page
  "<remap> <end-of-buffer>" #'canvas-browser-end-of-page
  ;; `pixel-scroll-precision-mode' takes the page keys for itself, and
  ;; its commands scroll a buffer, which a page is not.
  "<remap> <pixel-scroll-interpolate-down>" #'canvas-browser-scroll-up
  "<remap> <pixel-scroll-interpolate-up>" #'canvas-browser-scroll-down
  "<next>" #'canvas-browser-scroll-up
  "<prior>" #'canvas-browser-scroll-down
  "<home>" #'canvas-browser-beginning-of-page
  "<end>" #'canvas-browser-end-of-page
  ;; The ends of the page as Vimium has them.
  "g g" #'canvas-browser-beginning-of-page
  "G" #'canvas-browser-end-of-page
  ;; The tab keys of a browser; `C-TAB' stays with `tab-bar-mode'.
  "C-<next>" #'tab-line-switch-to-next-tab
  "C-<prior>" #'tab-line-switch-to-prev-tab
  "C-c C-t" #'canvas-browser-switch-tab
  "x" #'canvas-browser-close-tab
  "X" #'canvas-browser-reopen-tab)

;;;; The caret of the page

(defvar-local canvas-browser--caret nil
  "Whether the caret of the page has the keys.")

(defvar-local canvas-browser--caret-mark nil
  "Whether the caret of the page marks a region.")

(defvar-local canvas-browser--caret-box nil
  "Where the caret of the page stands, as a box, or nil.")

(defvar-local canvas-browser--caret-text nil
  "The text that the caret of the page marks, as the page last told it.")

(defconst canvas-browser--caret-js
  (concat "(function () {
     const version = 3;
     if ((window.__canvasBrowserCaret || {}).version === version) return;" canvas-browser--reach-js "
     const barId = '__canvas-browser-caret';
     let colour = '#ff8c00', edge = '#000000';
     let places = [];
     const paint = (c, e) => { if (c) colour = c; if (e) edge = e; };
     const leaveFocus = () => {
       const focus = document.activeElement;
       if (!focus || focus === document.body || focus === document.documentElement) return null;
       if (focus.blur) focus.blur();
       return focus;
     };
     const bar = () => {
       let b = document.getElementById(barId);
       if (!b) {
         b = document.createElement('div');
         b.id = barId;
         b.style.cssText = 'position:absolute;width:2px;pointer-events:none;' +
                           'z-index:2147483647;display:none';
         document.documentElement.appendChild(b);
       }
       b.style.background = colour;
       b.style.boxShadow = '0 0 0 1px ' + edge;
       return b;
     };
     const caretRect = s => {
       if (!s.focusNode) return null;
       const r = document.createRange();
       try { r.setStart(s.focusNode, s.focusOffset); } catch (other) { return null; }
       r.collapse(true);
       const rects = r.getClientRects();
       let rect = rects.length ? rects[0] : null;
       if (!rect || rect.height === 0) {
         const el = s.focusNode.nodeType === 1 ? s.focusNode : s.focusNode.parentElement;
         const e = el && el.getBoundingClientRect();
         rect = e && {left: e.left, top: e.top, height: Math.min(e.height, 24),
                      bottom: e.top + Math.min(e.height, 24)};
       }
       return rect;
     };
     const report = () => {
       const s = getSelection();
       let rect = caretRect(s);
       const b = bar();
       if (rect && rect.height > 0) {
         if (rect.top < 0 || rect.bottom > innerHeight) {
           window.scrollBy(0, rect.top < 0 ? rect.top - innerHeight / 3
                                           : rect.bottom - innerHeight * 2 / 3);
           rect = caretRect(s);
         }
         b.style.left = (rect.left + scrollX) + 'px';
         b.style.top = (rect.top + scrollY) + 'px';
         b.style.height = rect.height + 'px';
         b.style.display = 'block';
       } else {
         b.style.display = 'none';
       }
       let region = null;
       if (s.rangeCount && !s.isCollapsed) {
         const r = s.getRangeAt(0).getBoundingClientRect();
         region = [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)];
       }
       return {box: rect && rect.height > 0
                    ? [Math.round(rect.left), Math.round(rect.top), 2, Math.round(rect.height)]
                    : null,
               text: s.toString(), region: region};
     };
     const firstTextInView = () => {
       for (let y = 8; y < innerHeight; y += 16)
         for (const x of [8, innerWidth / 4, innerWidth / 2, innerWidth * 3 / 4]) {
           const r = document.caretRangeFromPoint(x, y);
           if (r && r.startContainer.nodeType === 3 && r.startContainer.textContent.trim()) {
             r.setStart(r.startContainer, 0);
             r.collapse(true);
             return r;
           }
         }
       return null;
     };
     const inView = s => { const r = caretRect(s); return r && r.top >= 0 && r.bottom <= innerHeight; };
     const textRoots = () => {
       const roots = [document];
       walk(document, '*', e => { if (e.shadowRoot) roots.push(e.shadowRoot); });
       return roots;
     };
     const matchBox = (node, offset, length) => {
       const r = document.createRange();
       r.setStart(node, offset);
       r.setEnd(node, offset + length);
       const rect = r.getClientRects()[0];
       if (!rect || rect.width === 0 || rect.height === 0 || rect.left < 0 || rect.top < 0 ||
           rect.right > innerWidth || rect.bottom > innerHeight) return null;
       return {x: Math.round(rect.left), y: Math.round(rect.top),
               w: Math.round(rect.width), h: Math.round(rect.height)};
     };
     const inside = (outer, e) => { for (let n = e; n; n = up(n)) if (n === outer) return true; return false; };
     const alpha = colour => {
       if (colour === 'transparent') return 0;
       const m = colour.match(/^rgba?\\(([^)]*)\\)$/);
       if (!m) return 1;
       const parts = m[1].split(/[\\s,\\/]+/).filter(Boolean);
       return parts.length > 3 ? parseFloat(parts[3]) : 1;
     };
     const paints = e => {
       if (/^(IMG|VIDEO|CANVAS|IFRAME)$/.test(e.tagName)) return true;
       const s = getComputedStyle(e);
       return s.backgroundImage !== 'none' || alpha(s.backgroundColor) > 0.5;
     };
     const stack = (root, x, y) => root.elementsFromPoint(x, y)
       .filter(e => e.getRootNode() === root)
       .flatMap(e => e.shadowRoot ? [...stack(e.shadowRoot, x, y), e] : [e]);
     const uncovered = (parent, box) => {
       const [x, y] = middle(box);
       for (const e of stack(document, x, y)) {
         if (inside(e, parent) || inside(parent, e)) return true;
         if (paints(e)) return false;
       }
       return false;
     };
     const hidesAll = s => s.clip === 'rect(0px, 0px, 0px, 0px)' || /^inset\\(50%/.test(s.clipPath);
     const clipsAll = s => s.clip !== 'auto' || s.clipPath !== 'none';
     const shownArea = e => {
       let left = 0, top = 0, right = innerWidth, bottom = innerHeight, escape = 'static';
       for (let n = e; n; n = up(n)) {
         if (n.nodeType !== 1 || n === document.body || n === document.documentElement) continue;
         const s = getComputedStyle(n);
         if (hidesAll(s)) return null;
         const positioned = s.position !== 'static';
         const overflows = s.overflow !== 'visible' &&
                           (escape === 'static' || (escape === 'absolute' && positioned));
         if (overflows || clipsAll(s)) {
           const r = n.getBoundingClientRect();
           left = Math.max(left, r.left); top = Math.max(top, r.top);
           right = Math.min(right, r.right); bottom = Math.min(bottom, r.bottom);
         }
         if (escape === 'fixed' || s.position === 'fixed') escape = 'fixed';
         else if (s.position === 'absolute') escape = 'absolute';
         else if (positioned) escape = 'static';
       }
       return left < right && top < bottom ? {left, top, right, bottom} : null;
     };
     const within = (box, area) => {
       const [x, y] = middle(box);
       return x >= area.left && x <= area.right && y >= area.top && y <= area.bottom;
     };
     const seen = e => e.checkVisibility({opacityProperty: true, visibilityProperty: true,
                                          checkOpacity: true, checkVisibilityCSS: true});
     const nearView = e => {
       const r = e.getBoundingClientRect();
       return r.bottom >= 0 && r.top <= innerHeight && r.right >= 0 && r.left <= innerWidth;
     };
     const matchesIn = (node, text, fold) => {
       const lower = node.data.toLowerCase();
       const haystack = fold && lower.length === node.data.length ? lower : node.data;
       if (haystack.indexOf(text) < 0) return [];
       const parent = node.parentElement || (node.parentNode && node.parentNode.host);
       if (!parent || !nearView(parent) || !seen(parent)) return [];
       const area = shownArea(parent);
       if (!area) return [];
       const matches = [];
       for (let i = haystack.indexOf(text); i >= 0; i = haystack.indexOf(text, i + text.length)) {
         const box = matchBox(node, i, text.length);
         if (box && within(box, area) && uncovered(parent, box)) matches.push({node, offset: i, box});
       }
       return matches;
     };
     window.__canvasBrowserCaret = {
       version,
       colours(c, e) { paint(c, e); return this; },
       start(c, e) {
         paint(c, e);
         const s = getSelection();
         const focus = leaveFocus();
         if (focus) {
           const r = document.createRange();
           r.setStartAfter(focus);
           r.collapse(true);
           s.removeAllRanges();
           s.addRange(r);
         } else if (!(s.rangeCount && inView(s))) {
           const r = firstTextInView();
           if (r) { s.removeAllRanges(); s.addRange(r); }
         }
         return report();
       },
       move(alter, direction, granularity) {
         getSelection().modify(alter, direction, granularity);
         return report();
       },
       collapse() {
         const s = getSelection();
         if (s.focusNode) s.collapse(s.focusNode, s.focusOffset);
         return report();
       },
       find(text) {
         if (!text) throw new Error('canvas-browser: a jump needs text to look for');
         const fold = text === text.toLowerCase();
         places = [];
         for (const root of textRoots()) {
           const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
           for (let node = walker.nextNode(); node; node = walker.nextNode())
             places.push(...matchesIn(node, text, fold));
         }
         return places.map(place => place.box);
       },
       jump(i, extend) {
         const place = places[i];
         if (!place) throw new Error('canvas-browser: no place ' + i + ' to jump to');
         const s = getSelection();
         if (extend && s.rangeCount) s.extend(place.node, place.offset);
         else { leaveFocus(); s.collapse(place.node, place.offset); }
         return report();
       },
       report,
       stop() {
         const b = document.getElementById(barId);
         if (b) b.remove();
         return {box: null, text: ''};
       }
     };
   })();")
  "The JavaScript of the caret of a page, `window.__canvasBrowserCaret\\='.
The caret is the selection of the page: a collapsed one is the caret, and
one that is not is the region, which chromium draws itself.  A page that
takes no typing draws no caret, so a bar of the colour of the cursor of
Emacs stands where it is.  Every call answers where the caret stands,
what the region holds, and the box of the region.  It is put in every
time it is used, since a new page has none, and replaces a caret of
another version that a page holds from before.
`find\\=' gives the boxes of the places in view that show a text, and
keeps them for `jump\\=', which puts the caret on one, or marks to it.
A place counts where its text shows: it is not invisible, no box that
clips it cuts it off, as a heading for screen readers only is cut, and
nothing that paints lies over its middle.  A clear link laid over a
card, as over a post of Reddit, paints nothing, while the veil of a
dialog does.  A text that runs across two elements, into a bold word
say, is not found.")

(defun canvas-browser--caret-script (call)
  "The script that runs CALL, a method of the caret of the page."
  (concat canvas-browser--caret-js "window.__canvasBrowserCaret." call))

(defun canvas-browser--caret-call (call &optional then)
  "Run CALL, a method of the caret of the page, and follow where it moves.
THEN, when given, is called in this buffer with the answer."
  (canvas-browser--evaluate-here
   (canvas-browser--caret-script call)
   (lambda (report)
     (let ((to (canvas-browser--box-of (plist-get report :box))))
       (canvas-browser--fly canvas-browser--caret-box to)
       (setq canvas-browser--caret-box to
             canvas-browser--caret-text (plist-get report :text)))
     (when then (funcall then report)))))

(defun canvas-browser--caret-colours ()
  "The colours of the caret of the page, as (FILL EDGE) in CSS.
The fill is the colour of the cursor of Emacs, and the edge black or
white, whichever stands out from it: a white bar alone vanishes on a
white page, and a black one on a black page."
  (let* ((rgb (or (color-name-to-rgb (or (face-background 'cursor nil t) "orange"))
                  '(1.0 0.55 0.0)))
         (light (> (+ (* 0.299 (nth 0 rgb)) (* 0.587 (nth 1 rgb)) (* 0.114 (nth 2 rgb))) 0.5)))
    (list (apply #'color-rgb-to-hex (append rgb '(2)))
          (if light "#000000" "#ffffff"))))

(defun canvas-browser--with-colours (method)
  "A call of METHOD of the caret of the page, given the colours of the caret."
  (apply #'format (concat method "(%S, %S)") (canvas-browser--caret-colours)))

(defconst canvas-browser--caret-motions
  '(("C-f" "forward" "character") ("<right>" "forward" "character")
    ("C-b" "backward" "character") ("<left>" "backward" "character")
    ("M-f" "forward" "word") ("M-b" "backward" "word")
    ("C-n" "forward" "line") ("<down>" "forward" "line")
    ("C-p" "backward" "line") ("<up>" "backward" "line")
    ("C-a" "backward" "lineboundary") ("<home>" "backward" "lineboundary")
    ("C-e" "forward" "lineboundary") ("<end>" "forward" "lineboundary")
    ("M-<" "backward" "documentboundary") ("M->" "forward" "documentboundary"))
  "The motions of Emacs, as the selection of a page makes them.
Each is the key, the direction, and how far a step goes.")

(defvar canvas-browser-caret-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map canvas-browser-mode-map)
    (dolist (motion canvas-browser--caret-motions)
      (define-key map (kbd (car motion)) #'canvas-browser-caret-move))
    (define-key map (kbd "C-SPC") #'canvas-browser-caret-set-mark)
    (define-key map (kbd "C-@") #'canvas-browser-caret-set-mark)
    (define-key map (kbd "M-w") #'canvas-browser-caret-copy)
    (define-key map (kbd "C-g") #'canvas-browser-caret-quit)
    (define-key map (kbd "<escape>") #'canvas-browser-caret-leave)
    (define-key map (kbd "v") #'canvas-browser-caret-leave)
    map)
  "Keymap of a page buffer while the caret of the page has the keys.
The motions of Emacs move the caret, and every other key is the page's.")

(defun canvas-browser-caret-mode ()
  "Move a caret through the text of the page with the motions of Emacs.
The caret starts after what has the focus, a field you typed in say, or
at the first text in view.  `C-SPC\\=' marks a region, `M-w\\=' copies it,
and `C-g\\=' drops the mark, and then leaves, as `ESC\\=' does."
  (interactive)
  (canvas-browser--caret-enter)
  (canvas-browser--caret-call (canvas-browser--with-colours "start")))

(defun canvas-browser--caret-enter ()
  "Give the keys to the caret of the page, which has no mark and no place yet."
  (setq canvas-browser--caret t
        canvas-browser--caret-mark nil
        canvas-browser--caret-box nil)
  (use-local-map canvas-browser-caret-map)
  (canvas-browser--keep-modal-state)
  (force-mode-line-update)
  (message "canvas-browser: the caret moves with the keys of Emacs; C-SPC marks, M-w copies"))

(defun canvas-browser--caret-take-region (text)
  "Give the keys to the caret, with TEXT as its region.
TEXT is what a drag of the mouse marked on the page.  Nothing is copied,
as nothing is after a drag in a buffer: `M-w\=' copies the region and
`C-g\=' drops it.  One who set `mouse-drag-copy-region\=' gets the copy
here as well.  In a field the keys are the page's, and the field copies
its own mark."
  (when (and (stringp text) (not (string-empty-p text)) (not canvas-browser--insert))
    (unless canvas-browser--caret (canvas-browser--caret-enter))
    (setq canvas-browser--caret-mark t)
    (canvas-browser--caret-call
     (concat (canvas-browser--with-colours "colours") ".report()"))
    (when mouse-drag-copy-region (kill-new text))))

(defun canvas-browser-caret-move ()
  "Move the caret as the key that called this command moves point.
With the mark set it marks, as a motion after `C-SPC\\=' does."
  (interactive)
  (let* ((keys (key-description (vector last-command-event)))
         (motion (or (cdr (assoc keys canvas-browser--caret-motions))
                     (error "canvas-browser: %s is no motion of the caret" keys))))
    (canvas-browser--caret-call
     (format "move('%s', '%s', '%s')"
             (if canvas-browser--caret-mark "extend" "move") (car motion) (cadr motion)))))

(defun canvas-browser-caret-set-mark ()
  "Set the mark at the caret, or drop it when it is set."
  (interactive)
  (if canvas-browser--caret-mark
      (canvas-browser--caret-drop-mark)
    (setq canvas-browser--caret-mark t)
    (message "Mark set")))

(defun canvas-browser--caret-drop-mark ()
  "Drop the mark of the caret, and the region it marks."
  (setq canvas-browser--caret-mark nil)
  (canvas-browser--caret-call "collapse()"))

(defun canvas-browser-caret-copy ()
  "Copy the region of the caret to the kill ring, pulse it, and drop the mark."
  (interactive)
  (let ((buffer (current-buffer)))
    (canvas-browser--caret-call
     "report()"
     (lambda (report)
       (let ((text (plist-get report :text)))
         (if (and (stringp text) (not (string-empty-p text)))
             (progn (kill-new text)
                    (when-let* ((region (canvas-browser--box-of (plist-get report :region))))
                      (canvas-browser--pulse buffer region))
                    (message "canvas-browser: copied %d characters" (length text)))
           (message "canvas-browser: nothing is marked")))
       (canvas-browser--caret-drop-mark)))))

(defun canvas-browser-caret-quit ()
  "Drop the mark of the caret when it is set, else leave the caret."
  (interactive)
  (if canvas-browser--caret-mark
      (canvas-browser--caret-drop-mark)
    (canvas-browser-caret-leave)))

(defun canvas-browser-caret-leave ()
  "Give the keys back to Emacs, and take the caret off the page."
  (interactive)
  (canvas-browser--caret-call "stop()")
  (setq canvas-browser--caret nil
        canvas-browser--caret-mark nil)
  (use-local-map canvas-browser-mode-map)
  (canvas-browser--keep-modal-state)
  (force-mode-line-update))

;;;; Jumping to text, as avy does

(defvar avy-timeout-seconds)
(defvar avy-single-candidate-jump)

(defun canvas-browser--jump-timeout ()
  "How long a pause ends the text of a jump: avy\='s pause, once avy is loaded."
  (if (boundp 'avy-timeout-seconds) avy-timeout-seconds 0.5))

(defun canvas-browser--read-jump-text ()
  "Read the text of a jump until a pause, as `avy-goto-char-timer\=' reads it.
`DEL\=' takes the last character back, `RET\=' ends at once, and `ESC\=' gives
up.  The text, or nil when given up or empty."
  (let ((text (catch 'done
                (let ((text ""))
                  (while t
                    (setq text (canvas-browser--jump-text-key text)))))))
    (and text (not (string-empty-p text)) text)))

(defun canvas-browser--jump-text-key (text)
  "Read one key of the text of a jump, which holds TEXT so far; the new text.
The first key is waited for; after it, a pause ends the text."
  (let ((key (read-char (format "Jump to: %s" text) t
                        (and (not (string-empty-p text)) (canvas-browser--jump-timeout)))))
    (cond ((memq key '(nil ?\r)) (throw 'done text))
          ((eq key ?\e) (throw 'done nil))
          ((memq key '(?\d ?\b)) (substring text 0 (max 0 (1- (length text)))))
          (t (concat text (char-to-string key))))))

(defun canvas-browser-caret-jump ()
  "Put the caret on text in view that you type, as `avy-goto-char-timer\=' does.
Type until you pause; every place in view that shows the text takes a
hint, and naming one puts the caret there, or marks to it when the mark
is set.  From normal state the caret starts there.  Text in lower case
matches either case, and a single place takes no hint, as in avy."
  (interactive)
  (when-let* ((text (canvas-browser--read-jump-text)))
    (canvas-browser--evaluate-here
     (canvas-browser--caret-script (format "find(%s)" (json-encode text)))
     (lambda (boxes) (canvas-browser--jump-to-one text boxes)))))

(defun canvas-browser--jump-to-one (text boxes)
  "Put the caret on the place named of BOXES, the places of TEXT in view."
  (cond ((null boxes) (message "canvas-browser: no %S in view" text))
        ((and (null (cdr boxes)) (canvas-browser--single-jump-p))
         (canvas-browser--caret-jump-to 0))
        (t (when-let* ((chosen (canvas-browser--choose-box boxes)))
             (canvas-browser--caret-jump-to (car chosen))))))

(defun canvas-browser--single-jump-p ()
  "Whether a single place is jumped to without a hint, as avy has it."
  (or (not (boundp 'avy-single-candidate-jump)) avy-single-candidate-jump))

(defun canvas-browser--caret-jump-to (place)
  "Put the caret on PLACE of the last jump, or mark to it with the mark set."
  (let ((extend canvas-browser--caret-mark))
    (unless canvas-browser--caret
      (canvas-browser--caret-enter))
    (canvas-browser--caret-call
     (format "%s.jump(%d, %s)" (canvas-browser--with-colours "colours")
             place (if extend "true" "false")))))

;;;; The window and the header line

(defun canvas-browser--window-resized (width height)
  "Lay the page out for WIDTH by HEIGHT, and ask for frames of that size."
  (unless (equal canvas-browser--size (cons width height))
    (canvas-browser--adopt width height)
    (canvas-browser--start-screencast)
    (canvas-browser--resize width height #'canvas-browser--fill-window)))

(defcustom canvas-browser-second-try 0.5
  "Seconds before a window still empty is asked for its picture again."
  :type 'number
  :group 'canvas-browser)

(defun canvas-browser--fill-window ()
  "Ask for a picture of the window, now and once more if it stays empty.
The canvas of a window that has just changed size holds nothing, and a
page that has settled sends no frame of its own; the first picture may
also come before chromium has laid the page out for the new window."
  (canvas-browser--paint-window)
  (let ((buffer (current-buffer))
        (frames canvas-browser--frames))
    (run-with-timer canvas-browser-second-try nil
                    #'canvas-browser--paint-if-quiet buffer frames)))

(defun canvas-browser--watch-freshness ()
  "Look every now and then whether this window is still being painted."
  (unless canvas-browser--fresh-timer
    (setq canvas-browser--fresh-timer
          (run-with-timer canvas-browser-fresh-interval canvas-browser-fresh-interval
                          #'canvas-browser--keep-fresh (current-buffer)))))

(defun canvas-browser--may-ask-p (buffer)
  "Whether BUFFER\='s page can be asked for a picture of itself now.
No session, no chromium, hints waiting to be named, or no window showing
the buffer: each of them means no."
  (and canvas-browser--session
       (canvas-browser-cdp-running-p)
       (not canvas-browser--hinting)
       (canvas-browser--shown-p buffer)))

(defun canvas-browser--keep-fresh (buffer)
  "Ask BUFFER's window for a picture of itself if it painted nothing.
An embedded page whose host no longer holds its picture goes instead."
  (cond
   ((not (buffer-live-p buffer)) nil)
   ((canvas-browser--embed-gone-p buffer) (kill-buffer buffer))
   (t
    (with-current-buffer buffer
      (when (get-buffer-window buffer t)
        (canvas-browser--keep-modal-state))
      (when (canvas-browser--may-ask-p buffer)
        ;; A canvas that holds the still picture of this page holds the
        ;; page as it is, and a page whose moving parts are known has a
        ;; clock of its own: asking for another picture here would have
        ;; chromium draw for nobody.
        (if (or canvas-browser--crisp
                canvas-browser--live-boxes
                (/= canvas-browser--frames canvas-browser--fresh-frames))
            (setq canvas-browser--fresh-frames canvas-browser--frames
                  canvas-browser--quiet 0)
          (canvas-browser--paint-window)
          (cl-incf canvas-browser--quiet)
          (when (= canvas-browser--quiet canvas-browser--quiet-looks)
            (message (concat "canvas-browser: the page has stopped answering;"
                             " r reads it again")))))))))

(defun canvas-browser--paint-if-quiet (buffer frames)
  "Ask BUFFER for a picture of its window if it has painted none since FRAMES."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= canvas-browser--frames frames)
        (canvas-browser--paint-window)))))

(defun canvas-browser--window-change (window)
  "Fit the page of WINDOW's buffer to WINDOW."
  (when (and canvas-browser--session (window-live-p window))
    (canvas-browser--window-resized (window-body-width window t)
                                    (window-body-height window t))))

(defun canvas-browser--header ()
  "The header line: the title, the URL, and the state of the keyboard."
  (string-join (delq nil (list (or canvas-browser--title "…")
                               canvas-browser--url
                               (when canvas-browser--insert "insert")
                               (when canvas-browser--caret "caret")))
               " · "))

(defvar canvas-browser-insert-map (make-sparse-keymap)
  "Keymap of a page buffer in insert state: every key goes to the page.")

(defun canvas-browser--bind-insert-keys (map)
  "Bind the keys of insert state in MAP.
A variable keeps its value when its file is loaded again, so keys bound
where the map is made would never reach a running Emacs.  They are bound
here, on every load."
  (define-key map [remap self-insert-command] #'canvas-browser-self-insert)
  (dolist (key canvas-browser--insert-keys)
    (define-key map (kbd (car key)) #'canvas-browser-send-key))
  (define-key map (kbd "C-k") #'canvas-browser-kill-line)
  (define-key map (kbd "C-y") #'canvas-browser-yank)
  ;; Command-V of a browser, where Command is Meta.
  (define-key map (kbd "M-v") #'canvas-browser-yank)
  (define-key map (kbd "S-<insert>") #'canvas-browser-yank)
  (define-key map [mouse-2] #'canvas-browser-yank)
  (dolist (key '("C-/" "C-_" "C-x u"))
    (define-key map (kbd key) #'canvas-browser-field-undo))
  (dolist (key '("C-?" "C-M-_"))
    (define-key map (kbd key) #'canvas-browser-field-redo))
  (define-key map (kbd "TAB") #'canvas-browser-next-field)
  (define-key map (kbd "<backtab>") #'canvas-browser-previous-field)
  (define-key map (kbd "<escape>") #'canvas-browser-normal-mode)
  ;; Another package may have taken `ESC' for itself, as meow does.
  (define-key map (kbd "C-g") #'canvas-browser-insert-quit)
  (define-key map (kbd "C-SPC") #'canvas-browser-field-set-mark)
  (define-key map (kbd "C-@") #'canvas-browser-field-set-mark)
  (define-key map (kbd "C-x h") #'canvas-browser-field-mark-whole)
  (define-key map (kbd "M-w") #'canvas-browser-field-copy)
  (define-key map (kbd "C-w") #'canvas-browser-field-cut)
  (define-key map (kbd "C-<next>") #'tab-line-switch-to-next-tab)
  (define-key map (kbd "C-<prior>") #'tab-line-switch-to-prev-tab)
  (define-key map (kbd "C-c C-t") #'canvas-browser-switch-tab))

(canvas-browser--bind-insert-keys canvas-browser-insert-map)

(declare-function eww "eww" (url &optional arg))

(defun canvas-browser-insert-mode ()
  "Send every key to the page until `ESC'.
The buffer is writable meanwhile: the input method of macOS hands the
keys of a read-only buffer to Emacs one by one, so Japanese could not be
typed into the page.  The picture itself stays read-only."
  (interactive)
  (setq canvas-browser--insert t
        buffer-read-only nil)
  (use-local-map canvas-browser-insert-map)
  (canvas-browser--keep-modal-state)
  (message "canvas-browser: what you type goes to the page; ESC or C-g stops"))

(defvar meow--current-state)
(defvar meow-mode-state-list)
(declare-function meow--switch-state "meow-core" (state))

(defun canvas-browser--keep-modal-state ()
  "Ask for the modal state this mode was given, if something changed it.
`ESC\=' leaves the typing state of a page, and meow takes that key for
its own state, which would leave the buffer in a state where `SPC\=' is
meow's keypad rather than the menu of the page."
  (when (and (fboundp 'meow--switch-state)
             (boundp 'meow-mode-state-list)
             (boundp 'meow--current-state))
    (when-let* ((state (alist-get 'canvas-browser-mode meow-mode-state-list)))
      (unless (eq meow--current-state state)
        (meow--switch-state state)))))

(defun canvas-browser-normal-mode ()
  "Keep the keys of Emacs again."
  (interactive)
  (canvas-browser--stop-composing)
  (setq canvas-browser--insert nil
        canvas-browser--field-mark nil
        buffer-read-only t)
  (use-local-map canvas-browser-mode-map)
  (canvas-browser--keep-modal-state)
  (message "canvas-browser: the keys are Emacs's again"))

;;;; The input method of macOS

;; The NS port with the inline patch of macOS's input method draws the
;; text being composed at point, and point is past the picture, out of
;; sight.  In insert state the text goes to the field of the page
;; instead, which shows it underlined, as a browser does.

(defvar ns-working-text)

(defvar-local canvas-browser--composing nil
  "Whether the page shows text the input method has not committed yet.")

(defun canvas-browser--composing-here-p ()
  "Whether text being composed in this buffer belongs to the page."
  (and (derived-mode-p 'canvas-browser-mode) canvas-browser--insert))

(defun canvas-browser--utf16-length (text)
  "The length of TEXT as JavaScript counts it, in UTF-16 units.
DevTools places the caret of a composition by that count, which is
more than the count of characters for a character outside the BMP."
  (/ (string-bytes (encode-coding-string text 'utf-16le)) 2))

(defun canvas-browser--compose (text from to)
  "Show TEXT in the field of the page as text being composed.
FROM and TO, counted in characters, mark the part the input method is
converting, or the caret when they are equal."
  (setq canvas-browser--composing (not (string-empty-p text)))
  (canvas-browser--tell
   "Input.imeSetComposition"
   (list :text text
         :selectionStart (canvas-browser--utf16-length (substring text 0 from))
         :selectionEnd (canvas-browser--utf16-length (substring text 0 to)))))

(defun canvas-browser--stop-composing ()
  "Take the text being composed out of the field, if there is any.
The input method types the text it commits as keys, after this: with
the composition still there, the field would hold the text twice."
  (when canvas-browser--composing
    (canvas-browser--compose "" 0 0)))

(defun canvas-browser--ime-marked-text (insert from length)
  "Compose `ns-working-text' in the page, or call INSERT with FROM and LENGTH.
This goes around `ns-insert-marked-text', which shows the text in an
overlay; FROM and LENGTH mark the part being converted."
  (if (canvas-browser--composing-here-p)
      (let ((to (+ from length)))
        (when (<= to (length ns-working-text))
          (canvas-browser--compose ns-working-text from to)))
    (funcall insert from length)))

(defun canvas-browser--ime-working-text (insert)
  "Compose `ns-working-text' in the page, or call INSERT.
This goes around `ns-insert-working-text', which shows the text in an
overlay; the caret goes at the end of the text."
  (if (canvas-browser--composing-here-p)
      (let ((end (length ns-working-text)))
        (canvas-browser--compose ns-working-text end end))
    (funcall insert)))

(defun canvas-browser--ime-unput (&rest _)
  "Take the text being composed out of the page, when this is a page buffer.
This runs before `ns-unput-working-text', which the input method calls
when the text is committed or given up."
  (when (derived-mode-p 'canvas-browser-mode)
    (canvas-browser--stop-composing)))

(defun canvas-browser--watch-input-method ()
  "Have the input method of macOS compose in the page rather than at point.
An Emacs without the inline patch of the input method has none of
these functions, and is left as it is."
  (when (fboundp 'ns-insert-marked-text)
    (advice-add 'ns-insert-marked-text :around #'canvas-browser--ime-marked-text))
  (when (fboundp 'ns-insert-working-text)
    (advice-add 'ns-insert-working-text :around #'canvas-browser--ime-working-text))
  (when (fboundp 'ns-unput-working-text)
    (advice-add 'ns-unput-working-text :before #'canvas-browser--ime-unput)))

(with-eval-after-load 'ns-win (canvas-browser--watch-input-method))

(defun canvas-browser--bind-clicks (map click)
  "Bind the clicks of the mouse in MAP to CLICK, a command.
An area of the image map puts `canvas-browser-link\=' before the event,
so that id takes a map of its own, whose parent is MAP: a click over a
link runs the same command, and an event that nothing binds is ignored,
rather than telling the reader that it is undefined."
  (define-key map [down-mouse-1] #'ignore)
  (dolist (event '([mouse-1] [double-mouse-1] [triple-mouse-1]
                   [double-down-mouse-1] [triple-down-mouse-1]))
    (define-key map event click))
  (let ((link (make-sparse-keymap)))
    (set-keymap-parent link map)
    (define-key link [t] #'ignore)
    (define-key map [canvas-browser-link] link))
  map)

(defun canvas-browser--bind-mouse (map)
  "Bind the mouse in MAP.
A click reaches the page, a drag marks in it, and the wheel scrolls it,
up and down and across, with the keys held: a page as Figma reads Shift
or Control with it.  Emacs reports a fast wheel turn as a double or
triple event."
  (dolist (held '("" "S-" "C-" "M-" "s-" "A-" "C-S-" "M-S-"))
    (dolist (turn '("" "double-" "triple-"))
      (dolist (direction '("down" "up" "left" "right"))
        (define-key map (vector (intern (format "%s%swheel-%s" held turn direction)))
                    #'canvas-browser-wheel))))
  (define-key map [pinch] #'canvas-browser-pinch)
  (define-key map [drag-mouse-1] #'canvas-browser-drag)
  (canvas-browser--bind-clicks map #'canvas-browser-click))

(canvas-browser--bind-mouse canvas-browser-mode-map)
;; The mouse works while you type in the page as well: the state is about
;; the keys, and a click over a link would else say it is undefined.
(canvas-browser--bind-mouse canvas-browser-insert-map)

(defvar canvas-minimap-exclude-modes)

(defun canvas-browser--leave-out-of-map ()
  "Tell canvas-minimap to leave a page buffer alone.
A page is a picture, not lines of text, and a map of it told the reader
nothing the window does not.  Take the mode out of
`canvas-minimap-exclude-modes\=' to have the strip back."
  (add-to-list 'canvas-minimap-exclude-modes 'canvas-browser-mode))

(with-eval-after-load 'canvas-minimap (canvas-browser--leave-out-of-map))

(define-derived-mode canvas-browser-mode special-mode "Browser"
  "Major mode of a buffer that shows a web page on a canvas."
  (setq cursor-type nil
        truncate-lines t
        canvas-browser--opened (cl-incf canvas-browser--opened-pages))
  ;; The canvas is as wide as the window, so point at the end of the line
  ;; sits just past its right edge.  In a window without fringes there is
  ;; nowhere to show the cursor there, and Emacs would scroll the page
  ;; sideways to bring it into view.
  (setq-local auto-hscroll-mode nil)
  (setq header-line-format '(:eval (canvas-browser--header)))
  (canvas-browser--show-tabs)
  ;; `revert-buffer-function' is not buffer-local by itself: a plain setq
  ;; would make every other buffer read a page again.
  (setq-local revert-buffer-function #'canvas-browser-refresh)
  (setq-local bookmark-make-record-function #'canvas-browser-bookmark-make-record)
  (setq canvas-keys-menu-command #'canvas-browser-menu
        canvas-keys-write-command #'canvas-browser-write-picture
        canvas-keys-copy-function #'canvas-browser-copy-block
        canvas-keys-group 'canvas-browser
        canvas-keys-zoom-function #'canvas-browser--zoom-by-key
        canvas-keys-redraw-function #'canvas-browser-refresh)
  (add-hook 'kill-buffer-hook #'canvas-browser--remember-closed nil t)
  (add-hook 'kill-buffer-hook #'canvas-browser--release nil t)
  ;; Any command may change the page anywhere, so what was moving before
  ;; it says nothing about the page after it.
  (add-hook 'pre-command-hook #'canvas-browser--forget-live nil t)
  (canvas-browser--embark-here)
  (canvas-browser--watch-freshness))

(defun canvas-browser--buffer-name (url)
  "The name of the page buffer that shows URL."
  (format "*canvas-browser: %s*" url))

(defun canvas-browser--page-buffer (url)
  "A new page buffer for URL.
The tabs of the last session come back first, the first time a page is
made in this one, so that they stand to the left of the new page."
  (canvas-browser--restore-tabs-once)
  (canvas-browser--make-page-buffer url))

(defun canvas-browser--make-page-buffer (url)
  "A new page buffer for URL, which nothing shows yet."
  (let ((buffer (generate-new-buffer (canvas-browser--buffer-name url))))
    (with-current-buffer buffer (canvas-browser-mode))
    buffer))

;;;###autoload
(defun canvas-browser (url)
  "Open URL in a page buffer of its own.
A tab of the last session that waits at URL is shown instead, and read
then: a page opened in every session would else come back once more each
time."
  (interactive "sURL: ")
  (let ((url (canvas-browser--reachable-url url)))
    (canvas-browser--restore-tabs-once)
    (if-let* ((waiting (canvas-browser--waiting-tab-at url)))
        (progn (pop-to-buffer waiting) waiting)
      (let ((buffer (canvas-browser--page-buffer url)))
        (pop-to-buffer buffer)
        (with-current-buffer buffer
          (let ((window (get-buffer-window buffer)))
            (canvas-browser--open url
                                  (window-body-width window t)
                                  (window-body-height window t))))
        buffer))))

;;;; The tabs of the pages

(defcustom canvas-browser-tabs t
  "Whether a page buffer shows a line of tabs, one for each page.
Each page is a buffer of its own, and a window a page opens is another,
so the tabs of a browser are there already; the line shows them and
switches between them.  It is on by default because it is shown only in
the buffers of pages, and leaves every other buffer, and `tab-bar-mode\=',
alone.  It takes effect in the pages opened after it is changed."
  :type 'boolean
  :group 'canvas-browser)

(defcustom canvas-browser-tab-icons t
  "Whether a tab shows the icon of its page.
The icon is fetched once for each address it has, and kept while Emacs
runs."
  :type 'boolean
  :group 'canvas-browser)

(defcustom canvas-browser-tab-width 20
  "The most characters of a page's title that its tab shows.
With `canvas-browser-tabs-fit\=' on, a tab shows fewer when the tabs
would not all fit in the window otherwise."
  :type 'integer
  :group 'canvas-browser)

(defcustom canvas-browser-tabs-fit t
  "Whether the tabs narrow so that all of them fit in the window.
Each tab then shows as much of its title as the width of the window
leaves it, up to `canvas-browser-tab-width\=', and at the narrowest its
icon alone, as the tabs of a browser do.  Off, every tab shows the whole
`canvas-browser-tab-width\=' and the line scrolls."
  :type 'boolean
  :group 'canvas-browser)

(defvar canvas-browser--measuring-tab nil
  "Whether a tab is drawn to be measured, which shows no title then.")

(defvar canvas-browser--title-width nil
  "The width last worked out for the titles of a line of tabs, as (KEY . WIDTH).
tab-line names the tabs of a line one by one, and they all take the same
width, which is worked out once.")

(defun canvas-browser--tab-title (buffer)
  "The title of BUFFER's page, whole, or its address while it has said none."
  (with-current-buffer buffer
    (string-trim (replace-regexp-in-string
                  "[\n\t]+" " " (or canvas-browser--title canvas-browser--url (buffer-name))))))

(defun canvas-browser--cut-title (title width)
  "TITLE cut to WIDTH columns, with an ellipsis where it is cut."
  (truncate-string-to-width title (max width 1) nil nil t))

(defun canvas-browser--tab-pixels (string)
  "The pixels STRING takes on the line of tabs of this buffer."
  (string-pixel-width string (current-buffer)))

(defun canvas-browser--title-pixels (title)
  "The pixels TITLE takes in a tab.
It is measured in the face of a tab as this buffer draws it, which takes
the height of `tab-line\=' as well as that of `canvas-browser-tab-line\='."
  (canvas-browser--tab-pixels (propertize title 'face 'tab-line-tab-inactive)))

(defun canvas-browser--fit-titles (buffers titles most)
  "The most columns, up to MOST, that TITLES of BUFFERS show with all their
tabs in the window, or 0 when even two columns would not fit.
A tab is measured as tab-line draws it, with no title, so that its
spaces, its icon, its `×\=' and the gap before it are counted as they
are; the `+\=' of the line is taken from the room first."
  (let* ((separator (or tab-line-separator (if (window-system) " " "|")))
         (frame (let ((canvas-browser--measuring-tab t))
                  (canvas-browser--tab-pixels
                   (concat separator
                           (funcall tab-line-tab-name-format-function (car buffers) buffers)))))
         ;; A tab with an icon puts a space between it and the title.
         (space (if canvas-browser-tab-icons (canvas-browser--title-pixels " ") 0))
         (room (- (window-pixel-width) (window-scroll-bar-width) (window-right-divider-width)
                  (canvas-browser--tab-pixels
                   (concat separator (or (and tab-line-new-button-show tab-line-new-button) "")))
                  ;; Room for a column the measuring missed.
                  (canvas-browser--title-pixels "n")))
         (fits (lambda (width)
                 (<= (cl-loop for title in titles
                              sum (+ frame space
                                     (canvas-browser--title-pixels
                                      (canvas-browser--cut-title title width))))
                     room))))
    (if (funcall fits most)
        most
      ;; LOW fits, or is 1, which shows no title; HIGH does not fit.
      (let ((low 1) (high most))
        (while (> (- high low) 1)
          (let ((middle (/ (+ low high) 2)))
            (if (funcall fits middle) (setq low middle) (setq high middle))))
        (if (< low 2) 0 low)))))

(defun canvas-browser--tab-title-width (buffers)
  "How many columns of its title each tab of BUFFERS shows.
As many as the window has room for, up to `canvas-browser-tab-width\=',
with every tab measured as tab-line draws it: a title shorter than that
leaves the room it does not use to the others, as the tabs of a browser
do.  At 0 a tab with an icon shows the icon alone."
  (let ((most canvas-browser-tab-width))
    (cond
     (canvas-browser--measuring-tab 0)
     ((not (and canvas-browser-tabs-fit buffers)) most)
     (t
      (let* ((titles (mapcar #'canvas-browser--tab-title buffers))
             (key (list (window-pixel-width) (default-font-width) most
                        canvas-browser-tab-icons titles)))
        (if (equal (car canvas-browser--title-width) key)
            (cdr canvas-browser--title-width)
          (let ((width (canvas-browser--fit-titles buffers titles most)))
            (setq canvas-browser--title-width (cons key width))
            width)))))))

(defface canvas-browser-tab-line
  '((((class color) (min-colors 88) (background light))
     :background "#dee1e6" :foreground "#3c4043" :height 0.85)
    (((class color) (min-colors 88) (background dark))
     :background "#202124" :foreground "#bdc1c6" :height 0.85)
    (t :inherit tab-line :height 0.85))
  "The line of tabs of a page buffer, behind the tabs.
It is laid over `tab-line\=' in a page buffer alone, so that the tabs of
pages do not look like the tabs of `tab-bar-mode\='."
  :group 'canvas-browser)

(defface canvas-browser-tab
  '((((class color) (min-colors 88) (background light))
     :background "#dee1e6" :foreground "#5f6368"
     :box (:line-width (1 . 2) :style flat-button))
    (((class color) (min-colors 88) (background dark))
     :background "#202124" :foreground "#9aa0a6"
     :box (:line-width (1 . 2) :style flat-button))
    (t :inherit tab-line-tab-inactive))
  "The tab of a page that is not the one shown."
  :group 'canvas-browser)

(defface canvas-browser-tab-current
  '((((class color) (min-colors 88) (background light))
     :background "#ffffff" :foreground "#202124"
     :box (:line-width (1 . 2) :style flat-button))
    (((class color) (min-colors 88) (background dark))
     :background "#3c4043" :foreground "#e8eaed"
     :box (:line-width (1 . 2) :style flat-button))
    (t :inherit tab-line-tab-current))
  "The tab of the page a window shows."
  :group 'canvas-browser)

(defvar-local canvas-browser--icon nil
  "The image of this page's icon, or nil while there is none.")

(defvar-local canvas-browser--icon-url nil
  "The address of the icon this page names, or nil.")

(defvar canvas-browser--icons (make-hash-table :test #'equal)
  "The icon of each icon address: an image, `none\=' for one that could
not be had, or (loading BUFFER...) while it is fetched for the BUFFERs.")

(defvar canvas-browser--site-icons (make-hash-table :test #'equal)
  "The icon address each origin named last.
A page of a site shows the icon of the site as soon as it is opened,
rather than after it has loaded.")

(defconst canvas-browser--icon-limit (* 512 1024)
  "The most bytes an icon may have; anything larger is no icon.")

(defconst canvas-browser--icon-pixels 32
  "The pixels each side of an icon is drawn with when it is turned to PNG.
A tab shows it at the height of a line, which is about this on a
display of two pixels to the point.")

(defconst canvas-browser--blank-icon-svg
  "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' width='16' height='16'>
<g fill='none' stroke='#8a8f98' stroke-width='1.2'>
<circle cx='8' cy='8' r='6.4'/><ellipse cx='8' cy='8' rx='2.8' ry='6.4'/>
<path d='M1.6 8h12.8M2.6 4.8h10.8M2.6 11.2h10.8'/></g></svg>"
  "A globe, the icon of a page that has none of its own, or none yet.
A grey stroke shows on a light line and on a dark one.")

(defun canvas-browser--tab-p (buffer)
  "Whether BUFFER is a page of its own, which has a tab.
An embedded page has a name that begins with a space, and belongs to
the buffer it is in rather than to the tabs."
  (and (buffer-live-p buffer)
       (eq (buffer-local-value 'major-mode buffer) 'canvas-browser-mode)
       (not (string-prefix-p " " (buffer-name buffer)))
       (not (buffer-local-value 'canvas-browser--host buffer))))

(defun canvas-browser--tab-buffers ()
  "The page buffers, in the order they were opened, as a browser keeps them.
The order of `buffer-list\=' changes whenever a buffer is shown, and tabs
that jumped about under the pointer could not be clicked."
  (sort (seq-filter #'canvas-browser--tab-p (buffer-list))
        (lambda (a b)
          (< (or (buffer-local-value 'canvas-browser--opened a) 0)
             (or (buffer-local-value 'canvas-browser--opened b) 0)))))

(defvar canvas-browser--blank-icon nil
  "The image of `canvas-browser--blank-icon-svg\=', once it is made.")

(defun canvas-browser--tab-icon ()
  "The icon of this page as text for its tab, or the globe while it has none."
  (let ((image (or canvas-browser--icon
                   (and (image-type-available-p 'svg)
                        (with-memoization canvas-browser--blank-icon
                          (canvas-browser--icon-spec canvas-browser--blank-icon-svg 'svg))))))
    (if image (propertize " " 'display image) "")))

(defun canvas-browser--tab-name (buffer &optional buffers)
  "The name of BUFFER's tab: the icon and the title of its page.
A page that has not said its title yet is named by its address.  The
title is cut so that the tabs of BUFFERS all fit in the window; see
`canvas-browser-tabs-fit\='.  At the narrowest a tab with an icon shows
the icon alone."
  (let ((width (canvas-browser--tab-title-width buffers)))
    (with-current-buffer buffer
      (let* ((icon (and canvas-browser-tab-icons (canvas-browser--tab-icon)))
             (shown (cond (canvas-browser--measuring-tab "")
                          ((and (< width 2) icon (not (string-empty-p icon))) "")
                          (t (canvas-browser--cut-title (canvas-browser--tab-title buffer)
                                                        width)))))
        (concat " "
                (when icon (concat icon (unless (string-empty-p shown) " ")))
                shown
                " ")))))

(defun canvas-browser--tab-cache-key (tabs)
  "What tab-line keeps the line of TABS for, with what names each tab.
Tab-line draws the line again when the buffers change, but the title of
a page and its icon change in a buffer that stays.  The default keys
come first, since tab-line reads two of them by their place."
  (append (tab-line-cache-key-default tabs)
          (list (window-pixel-width))
          (list (mapcar (lambda (buffer)
                          (with-current-buffer buffer
                            (list canvas-browser--title canvas-browser--url
                                  canvas-browser--icon-url (and canvas-browser--icon t))))
                        tabs))))

(defun canvas-browser--tabs-changed ()
  "Draw the tabs of every window again: a tab changed its name or its icon.
A window that shows another page shows this page's tab as well.  The
tabs are kept for the next session soon after, since a tab came, went,
or changed."
  (force-mode-line-update t)
  (canvas-browser--keep-tabs-soon))

(defun canvas-browser--close-tab (buffer)
  "Close the tab of BUFFER: kill the page.
A window that showed it shows the tab to its right, or to its left when
it was the last, as a browser does, rather than whatever buffer Emacs
would pick."
  (let* ((tabs (canvas-browser--tab-buffers))
         (next (or (cadr (memq buffer tabs))
                   (cadr (memq buffer (reverse tabs))))))
    (when next
      (dolist (window (get-buffer-window-list buffer nil t))
        (set-window-buffer window next)))
    (kill-buffer buffer)))

(defun canvas-browser-close-tab ()
  "Close the tab of this page, as `x' closes a tab in Vimium.
A window that showed it shows the tab to its right, as the `×' of the
tab does."
  (interactive)
  (unless (derived-mode-p 'canvas-browser-mode)
    (user-error "canvas-browser: this buffer is no page"))
  (canvas-browser--close-tab (current-buffer)))

(defconst canvas-browser--closed-tabs-limit 25
  "The most closed tabs that `canvas-browser-reopen-tab\=' keeps.")

(defvar canvas-browser--closed-tabs nil
  "The tabs closed in this session, the one closed last first.
Each is a plist of :url, :title, :icon, the address of its icon, and
:place, its `canvas-browser--opened\=', which puts it back where it was.")

(defun canvas-browser--remember-closed ()
  "Keep this tab among the closed ones, so that `X\=' can open it again.
It runs as the buffer is killed, so a tab closed by its `×\=', by `x\=' or
by `kill-buffer\=' is kept alike.  An embedded page is no tab."
  (when (and canvas-browser--url (canvas-browser--tab-p (current-buffer)))
    (push (list :url canvas-browser--url
                :title canvas-browser--title
                :icon canvas-browser--icon-url
                :place canvas-browser--opened)
          canvas-browser--closed-tabs)
    (when (> (length canvas-browser--closed-tabs) canvas-browser--closed-tabs-limit)
      (setcdr (nthcdr (1- canvas-browser--closed-tabs-limit) canvas-browser--closed-tabs)
              nil))))

(defun canvas-browser-reopen-tab ()
  "Open again the tab closed last, in its place among the tabs, as `X\=' does
in Vimium.  From a page it opens in the same window, as a new tab does.
Its title and icon show at once; the page itself is read again."
  (interactive)
  (let* ((tab (or (pop canvas-browser--closed-tabs)
                  (user-error "canvas-browser: no tab was closed in this session")))
         (display-buffer-overriding-action
          (if (derived-mode-p 'canvas-browser-mode)
              '(display-buffer-same-window)
            display-buffer-overriding-action))
         (buffer (canvas-browser (plist-get tab :url))))
    (with-current-buffer buffer
      (when (plist-get tab :place)
        (setq canvas-browser--opened (plist-get tab :place)))
      (unless canvas-browser--title
        (setq canvas-browser--title (plist-get tab :title)))
      (when (and canvas-browser-tab-icons (stringp (plist-get tab :icon)))
        (canvas-browser--take-icon-url (plist-get tab :icon)))
      (canvas-browser--tabs-changed))
    buffer))

(defun canvas-browser-new-tab ()
  "Open a page you kept, a URL or a search in a new tab, in this window.
`t' and the `+' of the tabs do this, as `t' of Vimium opens a tab; see
`canvas-browser-open-bookmark-or-url'."
  (interactive)
  (canvas-browser--let-go-of-the-click)
  (let ((display-buffer-overriding-action '(display-buffer-same-window)))
    (call-interactively #'canvas-browser-open-bookmark-or-url)))

(defun canvas-browser--let-go-of-the-click ()
  "Take the release of the button that this command was pressed with.
tab-line runs `+' as the button goes down, so the release would come
to the minibuffer as a click on the tabs, select the page's window, and
leave the question."
  (when (memq 'down (event-modifiers last-input-event))
    (while (when-let* ((event (read-event nil nil 1)))
             (not (seq-intersection '(click drag) (event-modifiers event)))))))

(defun canvas-browser--tab-choices ()
  "The tabs as choices to read, each its title and address, with its buffer.
Two pages of one title and one address are told apart by a number, since
a reader of choices keeps one of two that are the same."
  (let ((seen (make-hash-table :test #'equal)))
    (mapcar (lambda (buffer)
              (with-current-buffer buffer
                (let* ((title (string-trim
                               (replace-regexp-in-string
                                "[\n\t]+" " " (or canvas-browser--title canvas-browser--url
                                                  (buffer-name)))))
                       (choice (if canvas-browser--url
                                   (format "%s  %s" title canvas-browser--url)
                                 title))
                       (count (cl-incf (gethash choice seen 0))))
                  (cons (if (> count 1) (format "%s <%d>" choice count) choice)
                        buffer))))
            (canvas-browser--tab-buffers))))

(defun canvas-browser-switch-tab ()
  "Read a tab by its title or address, with its icon, and show its page.
The tabs keep the order they were opened in, as the line of tabs does."
  (interactive)
  (let* ((choices (or (canvas-browser--tab-choices)
                      (user-error "canvas-browser: no page is open")))
         (current (current-buffer))
         (affix (lambda (names)
                  (mapcar (lambda (name)
                            (let ((buffer (cdr (assoc name choices))))
                              (list name
                                    (concat (if (eq buffer current) "* " "  ")
                                            (if (and canvas-browser-tab-icons
                                                     (buffer-live-p buffer))
                                                (with-current-buffer buffer
                                                  (concat (canvas-browser--tab-icon) " "))
                                              ""))
                                    "")))
                          names)))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata (category . canvas-browser-tab)
                                 (affixation-function . ,affix)
                                 (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action choices string predicate))))
         (choice (completing-read "Tab: " table nil t)))
    (switch-to-buffer (cdr (assoc choice choices)))))

(defun canvas-browser--show-tabs ()
  "Give this page buffer its line of tabs.
The tabs are set up in every page, so that the keys that switch them
work even with the line turned off; the line itself is shown where
`canvas-browser-tabs\=' says so.  The faces are laid over tab-line's in
this buffer alone."
  (setq-local tab-line-tabs-function #'canvas-browser--tab-buffers
              tab-line-tab-name-function #'canvas-browser--tab-name
              tab-line-close-tab-function #'canvas-browser--close-tab
              tab-line-new-tab-choice #'canvas-browser-new-tab
              ;; Every page is a buffer of no file, which tab-line
              ;; would set in italics.
              tab-line-tab-face-functions nil
              tab-line-cache-key-function #'canvas-browser--tab-cache-key)
  (when (and canvas-browser-tabs (not (string-prefix-p " " (buffer-name))))
    (dolist (face '(tab-line tab-line-active tab-line-inactive))
      (face-remap-add-relative face 'canvas-browser-tab-line))
    (face-remap-add-relative 'tab-line-tab-inactive 'canvas-browser-tab)
    (dolist (face '(tab-line-tab tab-line-tab-current))
      (face-remap-add-relative face 'canvas-browser-tab-current))
    (tab-line-mode 1)))

;; Tab-line shows its `+' only for the functions it knows.
(add-to-list 'tab-line-new-button-functions #'canvas-browser--tab-buffers)

;;;; The icons of the pages

(defconst canvas-browser--icon-script
  "(() => {
  if (!/^https?:$/.test(location.protocol)) return null;
  const score = l => {
    const type = (l.type || '').toLowerCase(), sizes = l.sizes ? l.sizes.value : '';
    if (/(^|\\s)(16x16|32x32)(\\s|$)/.test(sizes)) return 3;
    if (type.includes('svg') || /\\.svg([?#]|$)/i.test(l.href)) return 2;
    return 1; };
  let best = null, top = 0;
  for (const l of document.querySelectorAll('link[rel~=\"icon\" i][href]')) {
    if (l.media && !matchMedia(l.media).matches) continue;
    const s = score(l);
    if (s > top) { best = l; top = s; } }
  return best ? best.href : new URL('/favicon.ico', location.origin).href; })()"
  "The JavaScript that answers with the address of the page's icon.
An icon of a tab's size comes first, then a drawing, which fits any
size, then the first the page names; a page that names none has the
icon of its site at /favicon.ico, where browsers look for it.  A page of
no site, such as a file, has none.")

(defun canvas-browser--origin (url)
  "The scheme, host and port of URL, or nil for an address of no site."
  (when-let* ((parsed (and (stringp url) (url-generic-parse-url url)))
              ((member (url-type parsed) '("http" "https")))
              (host (url-host parsed)))
    (format "%s://%s:%s" (url-type parsed) host (url-port parsed))))

(defun canvas-browser--icon-of-site (url)
  "Show the icon the site of URL named last, if it is known."
  (let* ((icon-url (gethash (canvas-browser--origin url) canvas-browser--site-icons))
         (icon (and icon-url (gethash icon-url canvas-browser--icons))))
    (setq canvas-browser--icon-url icon-url
          canvas-browser--icon (and (eq (car-safe icon) 'image) icon))))

(defun canvas-browser--find-icon ()
  "Ask the page for the address of its icon, and show that icon.
It is asked when the page has loaded, as its title is: the page names
its icon in its head, which may change as it runs."
  (when canvas-browser-tab-icons
    (canvas-browser--evaluate-here canvas-browser--icon-script
                                   #'canvas-browser--take-icon-url)))

(defun canvas-browser--take-icon-url (icon-url)
  "Show the icon at ICON-URL in this page's tab, fetching it if need be.
An icon is fetched once, for every page that names it.  An address of
the web or of data names an icon; anything else is no icon to fetch."
  (when (and (stringp icon-url)
             (string-match-p "\\`\\(?:https?\\|data\\):" icon-url))
    (when-let* ((origin (canvas-browser--origin canvas-browser--url)))
      (puthash origin icon-url canvas-browser--site-icons))
    (setq canvas-browser--icon-url icon-url)
    (let ((known (gethash icon-url canvas-browser--icons)))
      (pcase known
        ('none (setq canvas-browser--icon nil))
        (`(loading . ,_) (setcdr known (cons (current-buffer) (cdr known))))
        (`(image . ,_) (setq canvas-browser--icon known))
        (_ (puthash icon-url (list 'loading (current-buffer)) canvas-browser--icons)
           (canvas-browser--fetch-icon
            icon-url (lambda (bytes) (canvas-browser--icon-arrived icon-url bytes))))))
    (canvas-browser--tabs-changed)))

(defun canvas-browser--icon-arrived (icon-url bytes)
  "Show the icon at ICON-URL, BYTES or nil, in the tabs that wait for it."
  (let* ((image (and bytes (canvas-browser--icon-image bytes)))
         (known (gethash icon-url canvas-browser--icons))
         (waiting (and (eq (car-safe known) 'loading) (cdr known))))
    (puthash icon-url (or image 'none) canvas-browser--icons)
    (dolist (buffer waiting)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (equal canvas-browser--icon-url icon-url)
            (setq canvas-browser--icon image)))))
    (canvas-browser--tabs-changed)))

(defun canvas-browser--data-url-bytes (url)
  "The bytes a data URL holds, or nil if URL is none."
  (when (string-match "\\`data:\\([^,]*\\),\\(\\(?:.\\|\n\\)*\\)" url)
    (let ((meta (match-string 1 url))
          (data (match-string 2 url)))
      (if (string-suffix-p ";base64" meta)
          (ignore-errors (base64-decode-string (url-unhex-string data)))
        (encode-coding-string (url-unhex-string data) 'utf-8)))))

(defun canvas-browser--fetch-icon (icon-url then)
  "Fetch ICON-URL, and call THEN with its bytes, or with nil.
An icon written in its data URL is read from it.  Chromium fetches any
other first, as the page would, from its cache and with the page's
address; a page whose rules forbid that has it fetched by Emacs
instead.  Neither waits: the page is drawn and typed in meanwhile."
  (let ((session canvas-browser--session))
    (cond
     ((string-prefix-p "data:" icon-url)
      (funcall then (canvas-browser--data-url-bytes icon-url)))
     ((not (and session canvas-browser--target (canvas-browser-cdp-running-p)))
      (canvas-browser--fetch-icon-directly icon-url then))
     (t
      (canvas-browser-cdp-send-quietly
       "Network.loadNetworkResource"
       ;; The target of a page is the id of its main frame as well.
       (list :frameId canvas-browser--target :url icon-url
             :options (list :disableCache :json-false :includeCredentials :json-false))
       (lambda (result)
         (let* ((resource (plist-get result :resource))
                (stream (plist-get resource :stream)))
           (cond
            ((and stream (equal (plist-get resource :httpStatusCode) 200))
             (canvas-browser--read-stream stream session then))
            ;; The server answered, and has no icon there.
            ((eq (plist-get resource :success) t)
             (when stream
               (canvas-browser-cdp-send-quietly "IO.close" (list :handle stream) nil session))
             (funcall then nil))
            (t (canvas-browser--fetch-icon-directly icon-url then)))))
       session)))))

(defun canvas-browser--read-stream (stream session then &optional chunks size)
  "Read the rest of STREAM in SESSION, and call THEN with all its bytes.
CHUNKS are the bytes read so far, newest first, SIZE bytes in all.  A
stream larger than `canvas-browser--icon-limit\=' is no icon, and gives nil."
  (canvas-browser-cdp-send-quietly
   "IO.read" (list :handle stream :size 65536)
   (lambda (result)
     (let* ((data (plist-get result :data))
            (bytes (and (stringp data)
                        (if (eq (plist-get result :base64Encoded) t)
                            (base64-decode-string data)
                          (encode-coding-string data 'utf-8))))
            (chunks (and bytes (cons bytes chunks)))
            (size (+ (or size 0) (length bytes))))
       (if (and bytes (not (eq (plist-get result :eof) t))
                (<= size canvas-browser--icon-limit))
           (canvas-browser--read-stream stream session then chunks size)
         (canvas-browser-cdp-send-quietly "IO.close" (list :handle stream) nil session)
         (funcall then (and bytes (<= size canvas-browser--icon-limit)
                            (apply #'concat (nreverse chunks)))))))
   session))

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

(defun canvas-browser--fetch-icon-directly (icon-url then)
  "Fetch ICON-URL in Emacs, and call THEN with its bytes, or with nil.
No cookie goes with it, and none is kept: an icon is the same for all."
  (condition-case nil
      (url-retrieve
       icon-url
       (lambda (status)
         (let ((bytes (and (not (plist-get status :error))
                           (boundp 'url-http-response-status)
                           (eql url-http-response-status 200)
                           (markerp url-http-end-of-headers)
                           (< (- (point-max) url-http-end-of-headers) canvas-browser--icon-limit)
                           (buffer-substring-no-properties
                            (1+ url-http-end-of-headers) (point-max)))))
           (kill-buffer)
           (funcall then (and bytes (encode-coding-string bytes 'binary)))))
       nil t t)
    (error (funcall then nil))))

(defun canvas-browser--icon-type (bytes)
  "The type of the picture in BYTES, `ico\=' among them, or nil.
Emacs knows the others by their first bytes, but not the icon format of
Windows, which most sites still serve at /favicon.ico."
  (if (string-prefix-p (unibyte-string 0 0 1 0) bytes)
      'ico
    (ignore-errors (image-type-from-data bytes))))

(defun canvas-browser--icon-spec (bytes type)
  "An image of BYTES, of TYPE, as high as the text of the tab around it."
  (create-image bytes type t :height '(1 . em) :ascent 'center))

(defun canvas-browser--icon-image (bytes)
  "An image of the icon in BYTES, or nil if Emacs cannot show it.
A picture Emacs cannot read itself, as an ICO, is drawn on a canvas by
canvas-cairo, which reads it with gdk-pixbuf, and written as a PNG."
  (when-let* ((type (canvas-browser--icon-type bytes)))
    (if (and (not (eq type 'ico)) (image-type-available-p type))
        (canvas-browser--icon-spec bytes type)
      (when-let* ((png (ignore-errors (canvas-browser--picture-to-png bytes))))
        (canvas-browser--icon-spec png 'png)))))

(defun canvas-browser--picture-to-png (bytes)
  "BYTES, a picture of any type gdk-pixbuf reads, as a square PNG.
Its side is `canvas-browser--icon-pixels\='; an icon is square."
  (let* ((side canvas-browser--icon-pixels)
         (picture (make-temp-file "canvas-browser-icon-"))
         (png (make-temp-file "canvas-browser-icon-" nil ".png"))
         (context (canvas-cairo-context
                   (list 'image :type 'canvas :id (make-symbol "canvas-browser-icon")
                         :data-width side :data-height side))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (write-region bytes nil picture nil 'silent))
          (canvas-cairo-image context picture 0 0 side side)
          (canvas-cairo-write-png context png)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally png)
            (buffer-string)))
      (canvas-cairo-destroy context)
      (delete-file picture)
      (delete-file png))))

;;;; The tabs, kept for the next session

(defcustom canvas-browser-keep-tabs t
  "Whether the tabs are kept when Emacs ends, and come back in the next session.
They come back the first time a page is opened in the next session, to
the left of that page, and not when Emacs starts: canvas-browser is not
loaded until it is used.  A tab that comes back is not read until it is
shown, so neither chromium nor the pages of the other tabs start for it.
`canvas-browser-restore-tabs' brings them back without opening a page.

It is on by default, as a browser keeps its tabs: a tab costs nothing
until it is shown, and the file is written only once canvas-browser has
been used."
  :type 'boolean
  :group 'canvas-browser)

(defcustom canvas-browser-tabs-file
  (locate-user-emacs-file "canvas-browser-tabs.eld")
  "The file the tabs are kept in for the next session.
It holds the address, the title and the address of the icon of each
tab, in their order, as an S-expression."
  :type 'file
  :group 'canvas-browser)

(defconst canvas-browser--keep-tabs-delay 2
  "Seconds to wait, after a tab changed, before the tabs are written.
A page that loads changes its address and its title several times, and
one write after them all is enough.")

(defvar canvas-browser--tabs-restored nil
  "Whether the tabs of the last session have been looked for in this one.
They are looked for once.  Until then nothing is written, so that a
session that has opened no page keeps the tabs of the last one.")

(defvar canvas-browser--kept-tabs nil
  "What was last written to `canvas-browser-tabs-file\=', to write it only
when it changes.")

(defvar canvas-browser--keep-tabs-timer nil
  "The timer that writes the tabs a moment after they changed, or nil.")

(defvar-local canvas-browser--waiting nil
  "Whether this tab came back from the last session and has not been read.
It has an address, a title and an icon, and no canvas: it is read at
the size of the window that first shows it.")

(defvar canvas-browser--load-timer nil
  "The timer that reads the waiting tabs a window shows, or nil.")

(defun canvas-browser--tabs-to-keep ()
  "The tabs as they are kept: a plist of their order and the tab shown last.
:tabs holds a plist of :url, :title and :icon for each tab, in their
order, and :current the place of the tab shown last among them.  A tab
of no address yet has nothing to come back to, and is left out."
  (let* ((tabs (seq-filter (lambda (buffer) (buffer-local-value 'canvas-browser--url buffer))
                           (canvas-browser--tab-buffers)))
         ;; `buffer-list' has the buffer shown last first.
         (current (seq-find (lambda (buffer) (memq buffer tabs)) (buffer-list))))
    (list :version 1
          :current (seq-position tabs current)
          :tabs (mapcar (lambda (buffer)
                          (with-current-buffer buffer
                            (list :url canvas-browser--url
                                  :title canvas-browser--title
                                  :icon canvas-browser--icon-url)))
                        tabs))))

(defun canvas-browser--write-tabs ()
  "Write the tabs to `canvas-browser-tabs-file\=', if they changed.
An error is told and not raised: this runs as Emacs ends, and a file
that cannot be written must not keep Emacs from ending."
  (when canvas-browser--keep-tabs-timer
    (cancel-timer canvas-browser--keep-tabs-timer)
    (setq canvas-browser--keep-tabs-timer nil))
  (when (and canvas-browser-keep-tabs canvas-browser--tabs-restored)
    (let ((tabs (canvas-browser--tabs-to-keep)))
      (unless (equal tabs canvas-browser--kept-tabs)
        (with-demoted-errors "canvas-browser: the tabs were not kept: %S"
          (make-directory (file-name-directory canvas-browser-tabs-file) t)
          (let ((print-length nil)
                (print-level nil)
                (coding-system-for-write 'utf-8-unix))
            (with-temp-file canvas-browser-tabs-file
              (insert ";; The tabs of canvas-browser, kept for the next session.\n")
              (prin1 tabs (current-buffer))
              (insert "\n")))
          (setq canvas-browser--kept-tabs tabs))))))

(defun canvas-browser--keep-tabs-soon ()
  "Write the tabs in a moment, once with every change made meanwhile.
They are written as they change, and not only as Emacs ends, so that an
Emacs that crashes keeps them as well."
  (when (and canvas-browser-keep-tabs canvas-browser--tabs-restored
             (not canvas-browser--keep-tabs-timer))
    (setq canvas-browser--keep-tabs-timer
          (run-with-timer canvas-browser--keep-tabs-delay nil #'canvas-browser--write-tabs))))

(add-hook 'kill-emacs-hook #'canvas-browser--write-tabs)

(defun canvas-browser--read-tabs ()
  "The tabs kept in `canvas-browser-tabs-file\=', as written, or nil.
A file that cannot be read is told, and leaves no tabs to bring back."
  (when (file-readable-p canvas-browser-tabs-file)
    (condition-case err
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix))
            (insert-file-contents canvas-browser-tabs-file))
          (let ((tabs (read (current-buffer))))
            (and (plist-get tabs :tabs) tabs)))
      (error (message "canvas-browser: %s could not be read: %s"
                      canvas-browser-tabs-file (error-message-string err))
             nil))))

(defun canvas-browser--waiting-tab (tab)
  "A tab for TAB, a plist of a kept tab, which waits to be shown; its buffer.
It is not shown, so that a rule of `display-buffer-alist\=' opens no
window for it.  Its icon is fetched by Emacs, as no page asks for it."
  (let ((url (plist-get tab :url))
        (title (plist-get tab :title))
        (icon (plist-get tab :icon)))
    (when (stringp url)
      (let ((buffer (canvas-browser--make-page-buffer url)))
        (with-current-buffer buffer
          (setq canvas-browser--url url
                canvas-browser--title (and (stringp title) title)
                canvas-browser--waiting t)
          (when (stringp icon)
            (if canvas-browser-tab-icons
                (canvas-browser--take-icon-url icon)
              (setq canvas-browser--icon-url icon))))
        buffer))))

(defun canvas-browser--restore-tabs ()
  "Bring the tabs of the last session back, waiting to be shown.
The tabs are now looked for, whether or not there were any.  Return the
tab that was shown last, or the last tab, or nil when none came back."
  (setq canvas-browser--tabs-restored t)
  (let* ((kept (canvas-browser--read-tabs))
         ;; The file holds the tabs as they are now, and need not be
         ;; written again until they change.
         (_ (setq canvas-browser--kept-tabs kept))
         (current (plist-get kept :current))
         (buffers (mapcar #'canvas-browser--waiting-tab (plist-get kept :tabs))))
    (or (and (natnump current) (nth current buffers))
        (car (last (delq nil buffers))))))

(defun canvas-browser--waiting-tab-at (url)
  "The tab of the last session that waits at URL, not read yet, or nil."
  (seq-find (lambda (buffer)
              (and (buffer-local-value 'canvas-browser--waiting buffer)
                   (equal (buffer-local-value 'canvas-browser--url buffer) url)))
            (canvas-browser--tab-buffers)))

(defun canvas-browser--restore-tabs-once ()
  "Bring the tabs of the last session back, if that is wanted and not done."
  (when (and canvas-browser-keep-tabs (not canvas-browser--tabs-restored))
    (canvas-browser--restore-tabs)))

;;;###autoload
(defun canvas-browser-restore-tabs ()
  "Bring back the tabs of the last session, and show the one shown last.
That tab alone is read; each of the others is read when it is shown.
The tabs come back once a session: the first page opened brings them
back too, when `canvas-browser-keep-tabs\=' is on."
  (interactive)
  (if canvas-browser--tabs-restored
      (message "canvas-browser: the tabs of the last session are back already")
    (if-let* ((shown (canvas-browser--restore-tabs)))
        (pop-to-buffer shown)
      (message "canvas-browser: no tabs were kept from the last session"))))

(defun canvas-browser--load-tab ()
  "Read this waiting tab, at the size of the window that shows it.
A tab no window shows has no size to be read at, and waits on."
  (when-let* ((window (get-buffer-window (current-buffer) t)))
    (setq canvas-browser--waiting nil)
    (canvas-browser--open canvas-browser--url
                          (window-body-width window t)
                          (window-body-height window t))))

(defun canvas-browser--load-shown-tabs ()
  "Read the waiting tabs that a window shows."
  (setq canvas-browser--load-timer nil)
  (dolist (buffer (canvas-browser--tab-buffers))
    (when (and (buffer-local-value 'canvas-browser--waiting buffer)
               (canvas-browser--shown-p buffer))
      (with-current-buffer buffer
        (canvas-browser--load-tab)))))

(defun canvas-browser--follow-waiting-tabs (&rest _)
  "Have a waiting tab read once a window shows it, as the tab is clicked,
switched to or shown by any other means.
It is read just after the windows change, not while they do: starting
chromium waits for it, and Emacs is drawing the windows meanwhile."
  (when (and (not canvas-browser--load-timer)
             (seq-some (lambda (buffer)
                         (and (buffer-local-value 'canvas-browser--waiting buffer)
                              (canvas-browser--shown-p buffer)))
                       (canvas-browser--tab-buffers)))
    (setq canvas-browser--load-timer
          (run-with-timer 0 nil #'canvas-browser--load-shown-tabs))))

(add-hook 'window-configuration-change-hook #'canvas-browser--follow-waiting-tabs)

;;;; As the browser of Emacs

(defcustom canvas-browser-fallback-browser #'eww-browse-url
  "The browser `canvas-browser-browse-url' hands a URL to where no canvas shows.
It is called as `browse-url' calls a browser: with the URL and the
arguments `browse-url' passed on."
  :type 'function
  :group 'canvas-browser)

(defun canvas-browser-can-show-p ()
  "Return non-nil when the selected frame can show a page on a canvas.
A terminal frame cannot, and nor can an Emacs without canvas images."
  (and (display-graphic-p) (image-type-available-p 'canvas)))

;;;###autoload
(defun canvas-browser-browse-url (url &rest args)
  "Open URL in a page buffer of its own, as `browse-url' asks a browser to.
Set `browse-url-browser-function' to this, and every link Emacs opens
opens here.  ARGS, such as the new-window flag, do not matter: every
page is a buffer of its own.  Where no canvas can show the page, the URL
and ARGS go to `canvas-browser-fallback-browser' instead.  Return the
page buffer, or what the fallback returns."
  (if (canvas-browser-can-show-p)
      (canvas-browser url)
    (apply canvas-browser-fallback-browser url args)))

;;;; A file for a page, picked in dired

(declare-function dired-get-marked-files "dired"
                  (&optional localp arg filter distinguish-one-marked error))
(declare-function dired-other-window "dired" (dirname &optional switches))
(declare-function dired-get-file-for-visit "dired" ())
(declare-function dired-find-file "dired" ())

(defvar canvas-browser--attach-directory nil
  "The directory that a file was last given to a page from, or nil.")

(defvar canvas-browser--chooser nil
  "The choice of files that a page waits for, or nil.
A plist: :buffer is the page buffer, :node the field of the page that
asked, and :multiple whether the field takes several files.")

(defvar canvas-browser-attach-mode-map (make-sparse-keymap)
  "Keymap of a dired buffer while a page waits for files.")

;; Bound here and not where the map is made, so that a second load of
;; this file brings a new key to a running Emacs.
(keymap-set canvas-browser-attach-mode-map "C-c C-c" #'canvas-browser-attach-send)
(keymap-set canvas-browser-attach-mode-map "C-c C-k" #'canvas-browser-attach-cancel)
(keymap-set canvas-browser-attach-mode-map "<remap> <dired-find-file>"
            #'canvas-browser-attach-open)

(defun canvas-browser--attach-header ()
  "The line over a dired buffer that says what a page waits for."
  (format "%s wants %s: C-c C-c sends what is marked, or the file at point; C-c C-k cancels"
          (buffer-name (plist-get canvas-browser--chooser :buffer))
          (if (plist-get canvas-browser--chooser :multiple) "files" "a file")))

(define-minor-mode canvas-browser-attach-mode
  "Pick in this dired buffer the files that a page asked for.
Mark them and press `C-c C-c\=', or press it on one file.  `C-c C-k\='
tells the page that nothing was chosen."
  :lighter " Attach"
  :keymap canvas-browser-attach-mode-map
  (if canvas-browser-attach-mode
      (setq-local header-line-format '(:eval (canvas-browser--attach-header)))
    (kill-local-variable 'header-line-format)))

(defun canvas-browser--attach-watch ()
  "Give this new dired buffer the keys of the choice that a page waits for."
  (when canvas-browser--chooser
    (canvas-browser-attach-mode 1)))

(defun canvas-browser--file-chooser-opened (params)
  "Take PARAMS of the event that says this page asks for files.
A dired buffer opens, in the directory a file was last taken from, and
the files are picked there."
  (canvas-browser--attach-finish)
  (setq canvas-browser--chooser
        (list :buffer (current-buffer)
              :node (plist-get params :backendNodeId)
              :multiple (equal (plist-get params :mode) "selectMultiple")))
  (add-hook 'dired-mode-hook #'canvas-browser--attach-watch)
  (dired-other-window (or canvas-browser--attach-directory "~/"))
  (canvas-browser-attach-mode 1))

(defun canvas-browser--attach-finish ()
  "Forget the choice of files that a page waits for, in every dired buffer."
  (setq canvas-browser--chooser nil)
  (remove-hook 'dired-mode-hook #'canvas-browser--attach-watch)
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'canvas-browser-attach-mode buffer)
      (with-current-buffer buffer (canvas-browser-attach-mode -1)))))

(defun canvas-browser--attach-files ()
  "The files chosen in this dired buffer for the page that waits.
They are the marked files, or the file at point when none is marked."
  (let ((files (dired-get-marked-files nil nil nil nil t)))
    (when-let* ((directory (seq-find #'file-directory-p files)))
      (user-error "canvas-browser: %s is a directory" (file-name-nondirectory directory)))
    (when (and (cdr files) (not (plist-get canvas-browser--chooser :multiple)))
      (user-error "canvas-browser: the page takes one file, and %d are marked"
                  (length files)))
    files))

(defun canvas-browser--file-for-chromium (file)
  "FILE, or a copy of it where the chromium in use can read it.
A snap chromium reads no hidden directory of the home and no /tmp but
its own."
  (if (and (canvas-browser-cdp-snap-p) (not (canvas-browser--snap-can-read-p file)))
      (canvas-browser--copy-for-snap file)
    file))

(defun canvas-browser--attach-leave (page)
  "Bury this dired buffer, and go back to the window of PAGE if it has one."
  (quit-window)
  (when-let* ((window (get-buffer-window page t)))
    (select-window window)))

(defun canvas-browser--attach-give (files)
  "Give FILES to the page that waits, and end the choice."
  (let ((page (plist-get canvas-browser--chooser :buffer))
        (node (plist-get canvas-browser--chooser :node)))
    (setq canvas-browser--attach-directory default-directory)
    (with-current-buffer page
      (canvas-browser--tell
       "DOM.setFileInputFiles"
       (list :files (vconcat (mapcar #'canvas-browser--file-for-chromium files))
             :backendNodeId node)))
    (canvas-browser--attach-finish)
    (canvas-browser--attach-leave page)
    (message "canvas-browser: gave the page %d file%s"
             (length files) (if (cdr files) "s" ""))))

(defun canvas-browser-attach-send ()
  "Give the page that waits the marked files, or the file at point."
  (interactive)
  (unless canvas-browser--chooser
    (user-error "canvas-browser: no page waits for a file"))
  (canvas-browser--attach-give (canvas-browser--attach-files)))

(defun canvas-browser-attach-open ()
  "Go into the directory at point, or give the file at point to the page.
This is `RET\=' while a page waits for a file.  Without it, `RET\=' on a
file opens the file in a buffer, where the keys of the choice are not."
  (interactive)
  (let ((file (dired-get-file-for-visit)))
    (if (file-directory-p file)
        (dired-find-file)
      (unless canvas-browser--chooser
        (user-error "canvas-browser: no page waits for a file"))
      (canvas-browser--attach-give (list file)))))

(defun canvas-browser-attach-cancel ()
  "Tell the page that waits that no file was chosen.
The field that asked gets a cancel event, as it does when a file dialog
is closed."
  (interactive)
  (unless canvas-browser--chooser
    (user-error "canvas-browser: no page waits for a file"))
  (let ((page (plist-get canvas-browser--chooser :buffer))
        (node (plist-get canvas-browser--chooser :node)))
    (with-current-buffer page
      (canvas-browser--tell
       "DOM.resolveNode" (list :backendNodeId node)
       (canvas-browser--here
        (lambda (result)
          (canvas-browser--tell
           "Runtime.callFunctionOn"
           (list :objectId (plist-get (plist-get result :object) :objectId)
                 :functionDeclaration
                 "function () { this.dispatchEvent(new Event('cancel', {bubbles: true})); }"))))))
    (canvas-browser--attach-finish)
    (canvas-browser--attach-leave page)
    (message "canvas-browser: no file for the page")))

;;;; The targets of embark

(defun canvas-browser--marked-text ()
  "The text that the caret of this page marks, or nil when it marks none."
  (and canvas-browser--caret
       (stringp canvas-browser--caret-text)
       (not (string-empty-p canvas-browser--caret-text))
       canvas-browser--caret-text))

(defun canvas-browser-embark-target ()
  "The targets of embark in a page buffer.
The text that the caret marks comes first, and the address of the page
after it, as a URL.  Embark acts on the first, and cycles to the other."
  (when (derived-mode-p 'canvas-browser-mode)
    (append (when-let* ((text (canvas-browser--marked-text)))
              (list (cons 'canvas-browser-text text)))
            (when canvas-browser--url
              (list (cons 'url canvas-browser--url))))))

(defvar canvas-browser-embark-text-map (make-sparse-keymap)
  "The actions of embark on the text that the caret of a page marks.
Its parent holds the actions that embark has for any target.")

;; Bound here and not where the map is made, so that a second load of
;; this file brings a new key to a running Emacs.
(keymap-set canvas-browser-embark-text-map "s" #'canvas-browser)

(defvar embark-target-finders)
(defvar embark-keymap-alist)
(defvar embark-general-map)

(defun canvas-browser--embark-here ()
  "Have embark find its targets in this page buffer with one finder alone.
That is `canvas-browser-embark-target\='.  The buffer holds one character,
which shows the picture of the page.  A finder that reads text takes
that character as its target, and embark shows the picture in its
prompt when it cycles to it."
  (setq-local embark-target-finders (list #'canvas-browser-embark-target)))

(defun canvas-browser--embark-setup ()
  "Tell embark of the targets of a page buffer, also of those open already.
`s\=' on marked text opens a page buffer that searches for it."
  (set-keymap-parent canvas-browser-embark-text-map embark-general-map)
  (setf (alist-get 'canvas-browser-text embark-keymap-alist)
        '(canvas-browser-embark-text-map))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'canvas-browser-mode)
        (canvas-browser--embark-here)))))

(with-eval-after-load 'embark
  (canvas-browser--embark-setup))

;;;; Bookmarks
;;
;; A page is an Emacs bookmark, so `bookmark-set' keeps it and
;; `bookmark-jump', `consult-bookmark' and the bookmark list open it.

(defvar consult-bookmark-narrow)
(declare-function bookmark-prop-get "bookmark" (bookmark prop))
(declare-function bookmark-get-handler "bookmark" (bookmark))
(declare-function bookmark-jump "bookmark" (bookmark &optional display-func))
(declare-function bookmark-maybe-load-default-file "bookmark")
(defvar bookmark-alist)

(defun canvas-browser-bookmark-make-record ()
  "A bookmark record of this buffer's page, named by its title.
It is the `bookmark-make-record-function' of a page buffer."
  (unless canvas-browser--url
    (error "canvas-browser: this page has no address to keep"))
  `(,(or canvas-browser--title canvas-browser--url)
    (location . ,canvas-browser--url)
    (handler . canvas-browser-bookmark-jump)
    (defaults . ,(delete-dups (delq nil (list canvas-browser--title canvas-browser--url))))))

(defun canvas-browser--buffer-showing (url)
  "The page buffer that shows URL, or nil."
  (seq-find (lambda (buffer)
              (and (eq (buffer-local-value 'major-mode buffer) 'canvas-browser-mode)
                   (equal (buffer-local-value 'canvas-browser--url buffer) url)))
            (buffer-list)))

;;;###autoload
(defun canvas-browser-bookmark-jump (bookmark)
  "Open the page of BOOKMARK, in the page buffer that shows it if there is one.
The tabs of the last session come back first, so that a tab of the page
among them is shown rather than a second one opened."
  (canvas-browser--restore-tabs-once)
  (let ((url (bookmark-prop-get bookmark 'location)))
    (set-buffer (or (canvas-browser--buffer-showing url)
                    (canvas-browser url)))))

(put 'canvas-browser-bookmark-jump 'bookmark-handler-type "Web")

(defun canvas-browser-bookmark (name)
  "Keep this page as a bookmark called NAME.
Asked for, NAME starts as the title of the page, to keep or to edit;
`M-n' offers the address instead.  A bookmark of that name already is
replaced, as `bookmark-set' replaces it."
  (interactive
   (progn
     (require 'bookmark)
     (let ((defaults (bookmark-prop-get (canvas-browser-bookmark-make-record) 'defaults)))
       (list (read-string "Bookmark: " (car defaults) nil defaults)))))
  (require 'bookmark)
  (when (string-blank-p name)
    (user-error "canvas-browser: a bookmark needs a name"))
  (bookmark-set name))

(declare-function bookmark-bmenu-list "bookmark")

(defun canvas-browser-list-bookmarks ()
  "Show the list of bookmarks, where they are renamed and deleted.
`r\=' renames the one on the line, `d\=' and `x\=' delete, and `q\='
goes back to the page.  The address of a page is changed by keeping it
again under the same name with `B\='."
  (interactive)
  (require 'bookmark)
  (bookmark-bmenu-list))

(defun canvas-browser--bookmark-names ()
  "The names of the bookmarks of pages, in the order of the bookmark list."
  (mapcar #'car (seq-filter (lambda (bookmark)
                              (eq (bookmark-get-handler bookmark) 'canvas-browser-bookmark-jump))
                            bookmark-alist)))

(defun canvas-browser-open-bookmark ()
  "Pick a bookmark of a page, and open it.
The names are offered as bookmarks, so that marginalia, consult and
embark treat them as they treat any bookmark."
  (interactive)
  (require 'bookmark)
  (bookmark-maybe-load-default-file)
  (let ((names (or (canvas-browser--bookmark-names)
                   (user-error "canvas-browser: no page is bookmarked yet; B keeps this one"))))
    (bookmark-jump (canvas-browser--read-bookmark "Page: " names t))))

(defun canvas-browser--read-page-or-url ()
  "Read a bookmark of a page, a URL or words to search for.
A bookmark is read as its address; anything else as it is typed."
  (require 'bookmark)
  (bookmark-maybe-load-default-file)
  (let* ((names (canvas-browser--bookmark-names))
         (text (canvas-browser--read-bookmark "Page, URL or words: " names nil)))
    (if (member text names) (bookmark-prop-get text 'location) text)))

(defun canvas-browser--read-bookmark (prompt names require-match)
  "Read one of NAMES, the bookmarks of pages, with PROMPT.
REQUIRE-MATCH is as in `completing-read'."
  (completing-read prompt
                   (lambda (string predicate action)
                     (if (eq action 'metadata)
                         '(metadata (category . bookmark))
                       (complete-with-action action names string predicate)))
                   nil require-match))

;;;###autoload
(defun canvas-browser-open-bookmark-or-url (text)
  "Open the page of the bookmark called TEXT, or else the page at TEXT.
The bookmarks of pages are offered, and what matches none of them is
taken as a URL; a URL without a scheme gets one, and words become a
search.  A page that a buffer shows already goes to that buffer."
  (interactive
   (progn
     (require 'bookmark)
     (bookmark-maybe-load-default-file)
     (list (canvas-browser--read-bookmark "Page, URL or words: "
                                          (canvas-browser--bookmark-names) nil))))
  (when (string-blank-p text)
    (user-error "canvas-browser: no page or URL given"))
  (require 'bookmark)
  (bookmark-maybe-load-default-file)
  (if (member text (canvas-browser--bookmark-names))
      (bookmark-jump text)
    (canvas-browser--restore-tabs-once)
    (let ((shown (canvas-browser--buffer-showing (canvas-browser--reachable-url text))))
      (if shown (pop-to-buffer shown) (canvas-browser text)))))

(defun canvas-browser--join-consult-web-group ()
  "Put the bookmarks of pages in the Web group of `consult-bookmark'."
  (setq consult-bookmark-narrow
        (mapcar (lambda (group)
                  (if (and (eq (car group) ?w)
                           (not (memq 'canvas-browser-bookmark-jump (cddr group))))
                      (append group '(canvas-browser-bookmark-jump))
                    group))
                consult-bookmark-narrow)))

(with-eval-after-load 'consult
  (canvas-browser--join-consult-web-group))

;;;; Extensions, and uBlock Origin Lite

(defconst canvas-browser--ublock-release
  "https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest"
  "Where GitHub says which release of uBlock Origin Lite is the newest.")

(defconst canvas-browser--ublock-name "ublock-origin-lite"
  "The directory of uBlock Origin Lite, among the extensions.")

(defun canvas-browser--ublock-asset (release)
  "The (NAME . URL) of the chromium zip of RELEASE, as GitHub describes it."
  (let ((asset (seq-find (lambda (asset)
                           (string-match-p "\\.chromium\\.zip\\'" (alist-get 'name asset)))
                         (alist-get 'assets release))))
    (unless asset
      (error "canvas-browser: release %s of uBlock Origin Lite has no chromium zip"
             (alist-get 'tag_name release)))
    (cons (alist-get 'name asset) (alist-get 'browser_download_url asset))))

(defvar url-automatic-caching)

(defmacro canvas-browser--fresh (&rest body)
  "Run BODY with url.el asking for a fresh answer, and keeping no copy.
url.el sends If-Modified-Since for any URL it has a cached copy of, as
long as the request has no Pragma header that says no-cache, whatever
`url-automatic-caching' says.  The server then answers 304 with no body,
and url.el does not put the cached copy in its place.  Another package
may turn the caching on for all of Emacs."
  `(let ((url-automatic-caching nil)
         (url-request-extra-headers '(("Pragma" . "no-cache"))))
     ,@body))

(defun canvas-browser--read-json-url (url)
  "The JSON that URL answers with, its objects as alists."
  (let ((buffer (or (canvas-browser--fresh (url-retrieve-synchronously url t t 30))
                    (error "canvas-browser: no answer from %s" url))))
    (with-current-buffer buffer
      (unwind-protect
          (progn
            (unless (equal 200 (bound-and-true-p url-http-response-status))
              (error "canvas-browser: %s answered %s" url
                     (bound-and-true-p url-http-response-status)))
            (goto-char (point-min))
            (re-search-forward "\r?\n\r?\n")
            (json-parse-buffer :object-type 'alist :array-type 'list))
        (kill-buffer buffer)))))

(defun canvas-browser--unpack (zip directory)
  "Unpack ZIP, an extension, into DIRECTORY."
  (unless (executable-find "unzip")
    (user-error "canvas-browser: no unzip; run `sudo apt install unzip'"))
  (make-directory directory t)
  (unless (zerop (call-process "unzip" nil nil nil "-q" zip "-d" directory))
    (error "canvas-browser: unzip failed on %s" zip))
  (unless (file-exists-p (expand-file-name "manifest.json" directory))
    (error "canvas-browser: %s holds no manifest.json" zip)))

(defun canvas-browser--put-extension (unpacked name)
  "Make UNPACKED the extension NAME, in place of an older one; its directory."
  (let ((target (expand-file-name name (canvas-browser-cdp-extension-directory))))
    (when (file-exists-p target)
      (delete-directory target t))
    (rename-file unpacked target)
    target))

(defun canvas-browser--install-extension (url name)
  "Fetch the zip of an extension from URL and install it as NAME.
It is unpacked into a hidden directory beside the extensions, which
chromium leaves alone, and takes its place only once it is whole."
  (let* ((home (canvas-browser-cdp-extension-directory))
         (zip (make-temp-file "canvas-browser-extension" nil ".zip"))
         (unpacked (progn (make-directory home t)
                          (make-temp-name (expand-file-name ".unpacking-" home)))))
    (unwind-protect
        (progn
          (canvas-browser--fresh (url-copy-file url zip t))
          (canvas-browser--unpack zip unpacked)
          (canvas-browser--put-extension unpacked name))
      (delete-file zip)
      (when (file-exists-p unpacked)
        (delete-directory unpacked t)))))

;;;###autoload
(defun canvas-browser-install-ublock ()
  "Install the newest uBlock Origin Lite for canvas-browser, or update it.
It blocks ads and trackers with the lists of uBlock Origin, and chromium
loads it from `canvas-browser-extension-directory' when it starts.  A
chromium that runs is offered a restart, which opens the pages again."
  (interactive)
  (let* ((asset (canvas-browser--ublock-asset
                 (canvas-browser--read-json-url canvas-browser--ublock-release))))
    (canvas-browser--install-extension (cdr asset) canvas-browser--ublock-name)
    (message "canvas-browser: installed %s" (car asset))
    (when (and (canvas-browser-cdp-running-p)
               (y-or-n-p "Restart chromium, so that it loads uBlock Origin Lite? "))
      (canvas-browser-restart-chromium))))

(defun canvas-browser-restart-chromium ()
  "Stop chromium, and open the pages that a window shows in a new one.
Chromium reads its extensions only when it starts.  A page no window
shows opens again when it is next shown."
  (interactive)
  (let ((pages (seq-filter (lambda (buffer)
                             (with-current-buffer buffer
                               ;; A tab still waiting to be shown has no
                               ;; page to open again.
                               (and (derived-mode-p 'canvas-browser-mode) canvas-browser--url
                                    (not canvas-browser--waiting))))
                           (buffer-list))))
    ;; The virtual display stays for the new chromium.
    (canvas-browser-cdp-stop 'keep-display)
    (dolist (page pages)
      (with-current-buffer page
        (canvas-browser--forget-page)))
    ;; Chromium is started here, before any page asks: a page that found
    ;; it gone would bring back every shown page, and say it had gone.
    (when (seq-some #'canvas-browser--shown-p pages)
      (canvas-browser-cdp-start)
      (canvas-browser--watch-targets))
    (dolist (page pages)
      (when (canvas-browser--shown-p page)
        (with-current-buffer page
          (unless (or canvas-browser--session canvas-browser--opening)
            (canvas-browser--reopen)))))))

;;;; A page embedded in another buffer

(defun canvas-browser--embed-at (position)
  "The page embedded at POSITION of this buffer, or a user error."
  (or (get-text-property position 'canvas-browser-embed)
      (user-error "canvas-browser: no page here")))

(defun canvas-browser-embed-click (event)
  "Click the embedded page where EVENT, a click on its picture, points."
  (interactive "e")
  (let* ((start (event-start event))
         (page (with-current-buffer (window-buffer (posn-window start))
                 (canvas-browser--embed-at (posn-point start)))))
    (with-current-buffer page
      (canvas-browser-click event))))

(defun canvas-browser-embed-click-middle ()
  "Click the middle of the page embedded at point.
A video starts or stops at a click on it."
  (interactive)
  (with-current-buffer (canvas-browser--embed-at (point))
    (canvas-browser--click (/ (car canvas-browser--size) 2)
                           (/ (cdr canvas-browser--size) 2))))

(defvar canvas-browser-embed-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'canvas-browser-embed-click-middle)
    (define-key map [return] #'canvas-browser-embed-click-middle)
    (canvas-browser--bind-clicks map #'canvas-browser-embed-click))
  "The keys of the picture of an embedded page, in the buffer it is in.
The wheel is left to that buffer, which it scrolls.")

(defun canvas-browser--embed-gone-p (buffer)
  "Whether BUFFER holds an embedded page its host has let go of.
The host has, once it is killed or holds the page's picture no more, as
after it is drawn again."
  (let ((host (buffer-local-value 'canvas-browser--host buffer)))
    (and host
         (or (not (buffer-live-p host))
             (with-current-buffer host
               (not (text-property-any (point-min) (point-max)
                                       'canvas-browser-embed buffer)))))))

(declare-function x-window-property "xfns.c")

(defconst canvas-browser--fullscreen-binding "canvasBrowserFullscreen"
  "The function an embedded page calls to say it went fullscreen or back.")

(defconst canvas-browser--fullscreen-script
  (format "document.addEventListener('fullscreenchange', () =>
  window.%s(document.fullscreenElement ? 'on' : 'off'));"
          canvas-browser--fullscreen-binding)
  "The script that tells Emacs when a page goes fullscreen, and back.")

(defvar-local canvas-browser--fullscreen-frame nil
  "The frame this embedded page fills while it is fullscreen, or nil.")

(defvar-local canvas-browser--embed-size nil
  "The size this embedded page has in its host, kept while it is fullscreen.")

(defun canvas-browser--watch-fullscreen ()
  "Hear when this embedded page goes fullscreen, and when it comes back.
Fullscreen fills the page, which is only as large as its picture in the
host, so Emacs gives the page a frame of its own to fill instead.
The script goes in before the page loads, and the binding is kept for
every page the tab loads later."
  (let ((buffer (current-buffer)))
    (canvas-browser-cdp-listen
     canvas-browser--session "Runtime.bindingCalled"
     (lambda (params)
       (when (and (buffer-live-p buffer)
                  (equal (plist-get params :name) canvas-browser--fullscreen-binding))
         (with-current-buffer buffer
           (canvas-browser--fullscreen-changed (equal (plist-get params :payload) "on")))))))
  (canvas-browser--tell "Runtime.enable" nil)
  (canvas-browser--tell "Runtime.addBinding" (list :name canvas-browser--fullscreen-binding))
  (canvas-browser--tell "Page.addScriptToEvaluateOnNewDocument"
                        (list :source canvas-browser--fullscreen-script)))

(defun canvas-browser--fullscreen-changed (on)
  "Fill a frame with this embedded page if ON, else put it back in its host."
  (if on
      (canvas-browser--enter-fullscreen)
    (canvas-browser--leave-fullscreen)))

(defun canvas-browser--wm-fullscreen-p (frame)
  "Whether the window manager of FRAME can make a frame fullscreen.
On X, Emacs asks the window manager for it, and without one that says it
can, Emacs stretches the frame over the whole X screen, which spans every
monitor.  These are the two things Emacs reads on the root window."
  (or (not (eq (window-system frame) 'x))
      (and (x-window-property "_NET_SUPPORTING_WM_CHECK" frame "WINDOW" 0 nil t)
           (seq-contains-p (x-window-property "_NET_SUPPORTED" frame "ATOM" 0 nil t)
                           '_NET_WM_STATE_FULLSCREEN)
           t)))

(defun canvas-browser--frame-offset (position)
  "POSITION as a frame parameter counts it: a negative one from the left too.
A plain negative number counts from the right or bottom edge instead."
  (if (< position 0) (list '+ position) position))

(defun canvas-browser--frame-place (frame)
  "The frame parameters that open a new frame where FRAME is, at its size."
  (let ((position (frame-position frame)))
    `((left . ,(canvas-browser--frame-offset (car position)))
      (top . ,(canvas-browser--frame-offset (cdr position)))
      (width . (text-pixels . ,(frame-text-width frame)))
      (height . (text-pixels . ,(frame-text-height frame)))
      (user-position . t)
      (user-size . t))))

(defun canvas-browser--fullscreen-parameters (frame)
  "The parameters of the frame a fullscreen page fills, over FRAME.
It opens where FRAME is, so a window manager makes it fullscreen on the
monitor you look at.  Where it cannot go fullscreen it keeps FRAME\\='s
place and size, because the monitors may not be known: an X server can
report a single screen for two monitors."
  (append (when (canvas-browser--wm-fullscreen-p frame)
            '((fullscreen . fullboth)))
          (canvas-browser--frame-place frame)))

(defun canvas-browser--host-frame ()
  "The frame that shows this page\\='s host, or else the selected frame."
  (let ((window (get-buffer-window canvas-browser--host 'visible)))
    (if window (window-frame window) (selected-frame))))

(defun canvas-browser--enter-fullscreen ()
  "Show this embedded page in a fullscreen frame of its own.
The window changes that follow lay the page out for that frame."
  (unless (frame-live-p canvas-browser--fullscreen-frame)
    (setq canvas-browser--embed-size canvas-browser--size)
    (let ((window (display-buffer
                   (current-buffer)
                   `(display-buffer-pop-up-frame
                     (pop-up-frame-parameters
                      . ,(canvas-browser--fullscreen-parameters (canvas-browser--host-frame)))))))
      (setq canvas-browser--fullscreen-frame (window-frame window))
      (select-frame-set-input-focus canvas-browser--fullscreen-frame))))

(defun canvas-browser--leave-fullscreen ()
  "Delete the fullscreen frame of this embedded page, and put it back in its host."
  (let ((frame canvas-browser--fullscreen-frame))
    (setq canvas-browser--fullscreen-frame nil)
    (when (frame-live-p frame)
      (delete-frame frame)))
  (canvas-browser--back-in-host))

(defun canvas-browser--back-in-host ()
  "Give this page its size in its host again, and show it there.
Nothing is done for a page that is not fullscreen, so the page saying it
left fullscreen after Emacs made it leave does no harm."
  (when-let* ((size canvas-browser--embed-size))
    (setq canvas-browser--embed-size nil)
    (canvas-browser--window-resized (car size) (cdr size))
    (canvas-browser--show-in-host)))

(defun canvas-browser--show-in-host ()
  "Show this page's canvas where its host holds the picture of it.
A page of a new size has a new canvas, and the host still shows the old one."
  (let ((page (current-buffer))
        (canvas canvas-browser--canvas))
    (with-current-buffer canvas-browser--host
      (with-silent-modifications
        (let ((start (point-min)))
          (while (setq start (text-property-any start (point-max) 'canvas-browser-embed page))
            (let ((end (next-single-property-change start 'canvas-browser-embed nil (point-max))))
              (put-text-property start end 'display canvas)
              (setq start end))))))))

(defun canvas-browser--fullscreen-frame-deleted (frame)
  "Take the embedded page that fills FRAME, which is going, out of fullscreen.
Quitting the window of that page deletes the frame, and the page is then
told to leave fullscreen too."
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'canvas-browser--fullscreen-frame buffer) frame)
      (with-current-buffer buffer
        (setq canvas-browser--fullscreen-frame nil)
        (canvas-browser--tell "Runtime.evaluate" (list :expression "document.exitFullscreen()"))
        (canvas-browser--back-in-host)))))

(add-hook 'delete-frame-functions #'canvas-browser--fullscreen-frame-deleted)

(defun canvas-browser--kill-embeds ()
  "Kill the pages embedded in this buffer, which is going."
  (let ((host (current-buffer)))
    (dolist (buffer (buffer-list))
      (when (eq (buffer-local-value 'canvas-browser--host buffer) host)
        (kill-buffer buffer)))))

;;;###autoload
(defun canvas-browser-embed (url width height host)
  "Open URL in a page WIDTH by HEIGHT whose picture shows in HOST, a buffer.
Each side is at least `canvas-browser--least-size'.  Return the text to
insert in HOST, or nil where no canvas can show it.
The page lives in a hidden buffer of its own, and is drawn while a
window shows HOST.  A click on the picture goes to the page, and RET
clicks its middle.  The page goes when HOST is killed, and once HOST
holds the text no more."
  (when (canvas-browser-can-show-p)
    (let* ((url (canvas-browser--reachable-url url))
           (page (generate-new-buffer (format " *canvas-browser embed: %s*" url))))
      (with-current-buffer page
        (canvas-browser-mode)
        (setq canvas-browser--host host)
        (canvas-browser--open url width height))
      (with-current-buffer host
        (add-hook 'kill-buffer-hook #'canvas-browser--kill-embeds nil t))
      (propertize "#" 'display (buffer-local-value 'canvas-browser--canvas page)
                  'canvas-browser-embed page
                  'keymap canvas-browser-embed-map
                  'pointer 'hand
                  'help-echo "A click reaches the page; RET clicks its middle"))))

(provide 'canvas-browser)
;;; canvas-browser.el ends here
