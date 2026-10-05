# canvas-browser

A web browser in an Emacs buffer, drawn on a canvas. A headless chromium
lays out the page, and Emacs speaks its DevTools protocol itself: no
helper process stands between them. Each page is a buffer of its own, so
your buffer keys are the tabs.

![A page with its hint labels, in an Emacs frame](screenshots/hints.png)

## Why

My Emacs runs on a remote machine, and I reach it over X. A link that I
open there must open there too: in a buffer, with the keys of Emacs, and
logged in to the sites I use. And I like to do as much as I can in
Emacs.

That includes the web applications of work, such as Outlook, Teams and
Confluence. They need JavaScript and a login, which eww cannot give
them, and here they are buffers.

## Other browsers in Emacs

eww draws the HTML as text in the buffer and runs no JavaScript. Use eww
where it is enough.

xwidget-webkit puts a WebKitGTK widget in the window. It needs an Emacs
that was built with xwidgets, which only the GTK build and the macOS
build can be.

EAF runs a Python process that draws the page with QtWebEngine in a Qt
window, and keeps that window over the Emacs window. The page is a
window of another program.

canvas-browser works in any build of Emacs 32 that has modules, and no
process stands between Emacs and chromium. The page is an image in the
buffer, which Emacs paints. So Emacs draws the hint labels on it, cuts a
part of it to copy a picture, and shows a page inside another buffer.

## What it needs

- Emacs 32 with canvas images and with modules.
- The `canvas-cairo` module. It is a part of
  [canvas-diagram](https://github.com/Daskeladden/canvas-diagram) and
  no package of its own. You compile it on your machine, against cairo
  and pango.
- [canvas-keys](https://github.com/Daskeladden/canvas-keys), the keys
  that every canvas buffer shares.
- The `websocket` package, and `transient` for the menu.
- Chromium. On Ubuntu that is `sudo snap install chromium`. On macOS,
  Google Chrome or Chromium in `/Applications` is found as it is.
- `Xvfb`, the X server that chromium draws on, out of sight. On Ubuntu
  that is `sudo apt install xvfb`. macOS needs none, but a small
  program of canvas-browser instead, which you build: see
  [On macOS](#on-macos).

A snap writes only outside the hidden directories of your home, so the
profile of a snap chromium goes to
`~/snap/chromium/common/canvas-browser-profile`.
Another chromium keeps its profile under your cache directory. The
profile holds the cookies, so a site stays logged in between sessions.
A snap also has a `/tmp` of its own and reads no hidden directory of your
home, so a local file it cannot read, such as a page another package
wrote to `/tmp` or a file you attach to a mail, is copied to
`~/snap/chromium/common/canvas-browser-files` first. Only that file is
copied.

## Install

No archive carries canvas-browser. Clone it and the two canvas packages
it needs, and build the module of canvas-diagram. The README of
canvas-diagram says what that build needs.

The build makes `canvas-cairo.so` in the directory of canvas-diagram.
Emacs loads the module from there. If Emacs cannot open the load file
`canvas-cairo`, the module is not built, or that directory is not on the
load path.

```sh
git clone https://github.com/Daskeladden/canvas-keys.git
git clone https://github.com/Daskeladden/canvas-diagram.git
git clone https://github.com/Daskeladden/canvas-browser.git
make -C canvas-diagram        # builds canvas-cairo.so
make -C canvas-browser display  # on macOS: builds canvas-browser-display
```

Install `websocket` from an archive, with `M-x package-install`. Then
put the three directories on the load path, here with the clones in
`~/src`:

```elisp
(dolist (name '("canvas-keys" "canvas-diagram" "canvas-browser"))
  (add-to-list 'load-path (expand-file-name name "~/src")))
(autoload 'canvas-browser "canvas-browser" "Open a URL in a page buffer." t)
(autoload 'canvas-browser-browse-url "canvas-browser")
```

### Setting up on macOS

The macOS support lives in the fork at
`https://github.com/wakamenod/canvas-browser`. These are the steps on a
Mac with Homebrew, from nothing.

1. **An Emacs with canvas images.** They are in the master branch of
   Emacs since 2026-08-16, and the NS build draws them too. With
   emacs-plus that is `brew install emacs-plus@32`, at a revision of
   that day or later. `(image-type-available-p 'canvas)` says `t` when
   it is right.
2. **The libraries of the module.** canvas-diagram builds its module
   with pango and cairo, and reads icons with librsvg and gdk-pixbuf:

   ```sh
   brew install pkg-config pango cairo librsvg gdk-pixbuf
   xcode-select --install    # clang, and the Swift of the display
   ```

3. **The packages.** This configuration fetches and builds the three
   with package-vc, and has Brave for the browser as step 4 says:

   ```elisp
   ;; package-vc runs :make and :shell-command only for the packages
   ;; named here.
   (setq package-vc-allow-build-commands '(canvas-diagram canvas-browser))

   ;; canvas-keys and canvas-diagram are in no archive, so they come
   ;; before canvas-browser.
   (use-package canvas-keys
     :vc (:url "https://github.com/Daskeladden/canvas-keys")
     :defer t)

   (use-package canvas-diagram
     ;; The Makefile looks for emacs-module.h in /usr/local/include only,
     ;; so name the include directory of Homebrew too.
     :vc (:url "https://github.com/Daskeladden/canvas-diagram"
          :shell-command "make CFLAGS='-O2 -Wall -Wextra -std=gnu11 -fPIC -I/opt/homebrew/include'")
     :defer t)

   (use-package canvas-browser
     :vc (:url "https://github.com/wakamenod/canvas-browser" :make "display")
     :commands (canvas-browser
                canvas-browser-browse-url
                canvas-browser-switch-tab
                canvas-browser-open-bookmark-or-url
                canvas-browser-install-ublock
                canvas-browser-restart-chromium)
     :custom
     ;; The default on macOS, named here to show it.  Without the virtual
     ;; display it falls back to offscreen, which leaves 40 pixels of
     ;; chromium at the bottom right corner of the screen.
     (canvas-browser-window-strategy 'virtual-display)
     ;; Brave, in /Applications or in ~/Applications.
     (canvas-browser-chromium
      (list "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
            (expand-file-name
             "~/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")))
     ;; A profile of its own, apart from that of Chrome.
     (canvas-browser-profile-directory
      (expand-file-name "~/.cache/canvas-browser/profile-brave"))
     (browse-url-browser-function #'canvas-browser-browse-url))

   ;; canvas-keys copies a picture, as M-w in a page does, through
   ;; kill-ring-images, which hands it to other programs only on X.  On
   ;; macOS this function of the same name puts it on the clipboard.
   (unless (or (fboundp 'kill-ring-images-copy)
               (locate-library "kill-ring-images"))
     (defun kill-ring-images-copy (type bytes)
       "Put BYTES, an image of TYPE, on the macOS clipboard.
   Only image/png is taken, which is what canvas-keys copies."
       (unless (eq type 'image/png)
         (user-error "Only a PNG can go on the clipboard here, not %s" type))
       (let ((file (make-temp-file "canvas-picture-" nil ".png")))
         (unwind-protect
             (progn
               (let ((coding-system-for-write 'binary))
                 (write-region bytes nil file nil 'silent))
               (unless (zerop (call-process
                               "osascript" nil nil nil "-e"
                               (format "set the clipboard to (read (POSIX file %S) as «class PNGf»)"
                                       file)))
                 (error "osascript could not put the picture on the clipboard")))
           (delete-file file)))))
   ```

   On an Intel Mac, Homebrew is in `/usr/local`, where the Makefile of
   canvas-diagram looks already, so `:make "all"` does in place of its
   `:shell-command`. To use clones as in [Install](#install) instead,
   take canvas-browser from the fork, build canvas-diagram with
   `make CFLAGS="-O2 -Wall -Wextra -std=gnu11 -fPIC -I$(brew --prefix)/include"`,
   and put `:load-path` in place of each `:vc`.

4. **A browser.** Google Chrome and Brave both work. Brave blocks ads
   by itself; Google Chrome no longer loads an extension from the command
   line, so `canvas-browser-install-ublock` does nothing for it. Give
   Brave a profile of its own, since a profile of Chrome keeps its
   cookies under another key; the configuration of step 3 names both.
   A new profile of Brave fetches its lists of ads a little after it
   first starts, so ads show until chromium is next started.
5. **Extensions from the Chrome Web Store.** Its dialog that adds an
   extension is drawn by the browser on the display nobody sees, so it
   cannot be clicked from a page. Add the extension to the profile of
   canvas-browser in a browser on your own screen instead:

   1. Stop the browser of canvas-browser with
      `M-x eval-expression RET (canvas-browser-cdp-stop)`, or by quitting
      Emacs. `canvas-browser-restart-chromium` starts it again at once,
      so it will not do.
   2. Start Brave on your screen with the same profile:

      ```sh
      open -na "Brave Browser" --args \
        --user-data-dir="$HOME/.cache/canvas-browser/profile-brave" \
        "https://chromewebstore.google.com/"
      ```

   3. Add the extension, and sign in to it if it asks.
   4. Quit that Brave with `Cmd-Q`. Closing its window is not enough:
      while a Brave holds the profile, canvas-browser cannot start its
      own, and pages are not read.
   5. Open a page in canvas-browser. Brave starts with the extension.

   Brave opens again the pages it had open when it was quit, out of
   sight, so close them before you quit it.

   What an extension draws in the page works, and what it draws in the
   window of the browser does not. With 1Password the menu that comes
   up in a field of a login page shows on the canvas, and a click on it
   fills the field; the button of the toolbar, its popup, its keyboard
   shortcuts and the dialogs of passkeys belong to the window, out of
   sight.

## Use

`M-x canvas-browser` asks for a URL and opens it in a buffer. The page is
laid out for the window, and chromium sends a picture whenever the page
changes. The picture is a JPEG, painted on the canvas. A page that stops
answering for a few seconds says so in the echo area, and `r` reads it
again.

### As the browser of Emacs

To have every link Emacs opens open here, from any package, set:

```elisp
(setq browse-url-browser-function #'canvas-browser-browse-url)
```

Where no canvas can show a page, as in a terminal frame, the URL goes to
`canvas-browser-fallback-browser`, which is eww unless you set it.

### A page in another buffer

`canvas-browser-embed` opens a page whose picture shows inside another
buffer, such as a video in the description of an issue. It returns the
text to insert there. The page is drawn while a window shows that buffer.
A click on the picture reaches the page, and `RET` clicks its middle,
which starts or stops a video. The page goes when the buffer is killed,
or once the buffer no longer holds the text.

If the page goes fullscreen, as a video does from its fullscreen button,
the page fills a fullscreen frame of its own. When the page leaves
fullscreen, the frame goes and the picture is back in the buffer. If you
delete the frame, the page leaves fullscreen.

### Bookmarks

A page is an Emacs bookmark. `B` keeps the page as one, named by its
title, which stands in the field for you to keep or edit, and `J` picks
one of the pages you kept and opens it. The names come as bookmarks, so marginalia, consult
and embark treat them as they treat any bookmark. `C-x r m`,
`bookmark-jump` and the bookmark list work with pages too. In
`consult-bookmark` the pages are in the Web group, next to those of
eww, so `w SPC` narrows to them. A bookmark of a page that a buffer
shows already goes to that buffer.

`M-x canvas-browser-open-bookmark-or-url` offers the pages you kept as
`J` does, and opens what matches none of them as a URL, so one command
serves for both. Words, or a word with no dot, become a search. It
opens a page buffer of its own, and works outside a page buffer too, so
you can bind it to a key of your own.

### Attaching a file

When you attach a file to a mail, the page asks for the file. A dired
buffer then opens in the other window, in the directory you last took a
file from. Mark the files there and press `C-c C-c`, or press it on one
file. `C-c C-k` tells the page that nothing was chosen. While a page
waits, the two keys are there in every dired buffer, so you can go to
another directory first.

### Embark

`embark-act` in a page buffer acts on the address of the page, as on
any URL. You can open it in another browser or in eww, copy it, or
download it. While the caret marks text, the text is the first target.
The address is the second, and `embark-cycle` reaches it. On marked
text, `s` searches for it in a page buffer of its own.

### Blocking ads

`M-x canvas-browser-install-ublock` downloads the newest uBlock Origin
Lite from its releases on GitHub and installs it for canvas-browser. Run
it again to update. It blocks ads and trackers with the lists of uBlock
Origin, and it swaps a blocked ad script for a harmless stand-in, so a
page that waits for the script still works. It needs `unzip`.

Chromium loads extensions only when it starts. If chromium runs, the
command offers a restart, and `M-x canvas-browser-restart-chromium` does
the same at any time. The restart opens again every page that a window
shows, and the other pages open again when they are next shown.

Every directory with a `manifest.json` in
`canvas-browser-extension-directory` is an unpacked extension, which
chromium loads. By default that is
`~/snap/chromium/common/canvas-browser-extensions` for a snap chromium,
which can read no hidden directory of your home, and
`~/.local/share/canvas-browser/extensions` for another chromium.

## The keys

Normal state keeps the keys of Emacs:

| key | what it does |
|---|---|
| `o` | opens a page you kept, a URL, or a search for the words you type, in this buffer |
| `e` | edits the address of this page, and goes to what you make of it |
| `t` | opens a page you kept, a URL, or a search, in a new tab, as the `+` of the tabs does |
| `B`, `J` | keep this page as a bookmark, and open a page you kept |
| `b` | lists the bookmarks, where `r` renames one, `d` and `x` delete, and `q` goes back |
| `y` | copies the address of this page, as `f y` copies the address of a link |
| `C-<next>`, `C-<prior>` | go to the next and the previous tab, in insert state as well |
| `C-c C-t` | choose a tab by its title or address, from a list with the icons |
| `x` | closes this tab, and shows the one to its right |
| `X` | opens again the tab closed last, in its place among the tabs |
| `r` | reads the page again, as `g` does |
| `M-p`, `M-n` | go back and forward in the history |
| `j`, `k` | scroll a line further down and back |
| `d`, `u` | scroll a screen further down and back |
| `C-v`, `M-v`, the arrows | scroll a screen and a line |
| `<prior>`, `<next>` | scroll a screen back and further down |
| `<home>`, `<end>`, `C-<home>`, `C-<end>`, `M-<`, `M->` | go to the top and the foot of the page |
| `f` | labels what a click can reach, fields inside web components included, and clicks the one you name; the labels stay until you name one or press `ESC` |
| `M-w` | labels the blocks of the page, and copies the picture of the one you name; `C-u M-w` copies the whole window |
| `S` | labels the parts of the page that scroll on their own, and sends the scroll keys to the one you name |
| `v` | moves a caret through the text of the page with the motions of Emacs |
| `M-j` | puts the caret on text you type, as `avy-goto-char-timer` puts point |
| `TAB`, `S-TAB` | go to the next and the previous field, and type there |
| `C-s`, `C-r` | search the page, and step to the next hit and the one before |
| `i` | sends the keys to the page, as a click in a field does |
| `T` | puts the text of the page in an ordinary buffer |
| `M-s M-l` | searches that text with `consult-line` |
| a click | clicks the page at that pixel, and types there if it is a field |
| a drag | marks what lies between its two ends, once the button is let go |
| the wheel | scrolls what lies under the pointer, over a link as well, up and down and across; the keys held go with it, so Figma moves across with Shift and zooms with Control |
| a pinch | zooms the page, as Control and the wheel do, and leaves the text of Emacs at its size |
| a click on a tab, its `×`, the `+` | shows that page, kills it, and opens a new page in this window |

The scroll keys move the page itself, which happens at once. The wheel
goes to the page as a wheel, at the pixel the pointer is over, so that it
scrolls the part of the page that lies there, as it does in any browser.

A page is often more than one thing that scrolls: a list beside the text,
a pane of its own. `S` hands the scroll keys to one of them, the way
`ace-window` hands the keys to the window you name. The whole page
carries the first letter itself, in the top corner, so the keys go back
to it by a letter as well as by `ESC`; so does a part that the page has
thrown away, which it says when it happens. A page that does not scroll
as a whole, as Notion does not, has its largest such part scrolled
without `S`.

The menu shows how the settings stand, with a star for a value that a
fresh Emacs would not have, and `C-x C-s` in the menu keeps the starred
ones through Customize.

The common canvas keys come from canvas-keys: `SPC` opens the menu,
`q` buries the buffer, `m` shows and hides the map, `W` writes the
picture, `M-w` copies it, `C` opens Customize, and `+`, `-` and `0` zoom
the page. The pointer becomes
a hand over anything that can be clicked.

Insert state sends every key to the page, so that you can type in a
form. A click in a box you can type in enters it by itself, and a click
anywhere else leaves it, so a form works as it does in any browser.
`ESC` comes back to normal state, and `C-g` as well, since another
package may have taken `ESC`. The header line says `insert` while it
lasts. A field inside a web component, as on the login page of Reddit,
counts as a field: the focus is followed into the component.

The input method of macOS works in insert state, so Japanese and other
languages it writes can be typed into the page. With the
[inline patch](https://github.com/takaxp/ns-inline-patch) of the input
method, the text you are still converting shows in the field of the
page, underlined as in any browser, instead of at the point of the
buffer, which is out of sight past the picture. Its list of candidates
still opens at the top right of the window, where Emacs has its cursor.

A hint goes only to what a click in it would reach and what does
something: whatever lies outside the window or under a dialog gets none,
and neither does an icon that only looks, or a tracker of a few pixels.
[docs/design.md](docs/design.md#the-hints) says what counts, and why.

A key pressed before the letters of a hint picks what the hint does, as
the dispatch keys of avy do, and the prompt names it:

| key | the hint then |
|---|---|
| none | clicks it, or with `M-w` copies its picture |
| `y` | copies its address |
| `w` | copies its text |
| `c` | copies its picture, as much of it as shows |
| `o` | opens its address in a page buffer of its own |
| `e` | opens its address in eww |

`?` before the letters lists these keys in the prompt, as it does in
avy.

`f` labels what can be clicked, and `M-w` labels the blocks of the page:
a header, a sidebar, an article, a dialog, a table, a piece of code, a
picture. So `f y` and a hint copies the address of a link, and `M-w w`
and a hint copies the text of an article. None of these keys is a letter
of the hints, and the code refuses one that is.

When a click or a tab moves the focus of the page, smear-cursor flies
its cursor from the box that had the focus to the box that has it, as it
flies when point moves in text: from the name to the password of a form,
say. `canvas-browser-focus-function` names what flies, and nil turns it
off; without smear-cursor nothing flies.

Whatever a hint copies pulses: smear-cursor plays its copy effect over
the box of the address, the text or the picture, as it does over text
copied anywhere in Emacs. `canvas-browser-pulse-function` names what
pulses, and nil turns it off; without smear-cursor nothing pulses.

The editing keys of Emacs edit the field, as the Emacs key theme of GTK
and the insert mode of Surfingkeys have them do:

| key | in the field |
|---|---|
| `C-a`, `C-e` | the start and the end of the line |
| `C-f`, `C-b`, `C-n`, `C-p` | a character right and left, a line down and up |
| `M-f`, `M-b`, `C-<right>`, `C-<left>` | a word right and left |
| `C-<up>`, `C-<down>`, `M-{`, `M-}` | a paragraph up and down |
| `C-v`, `M-v` | a page down and up |
| Shift with an arrow, `<home>` or `<end>` | mark while you move, as in a browser |
| `M-<`, `M->` | the start and the end of the field |
| `DEL`, `C-d` | delete the character before and after the cursor |
| `M-DEL`, `M-d`, `C-<backspace>`, `C-<delete>` | delete the word before and after the cursor |
| `C-k` | kill to the end of the line, and at its end the line break |
| `C-y`, `S-<insert>`, the middle button | type the newest kill of Emacs |
| `C-/`, `C-x u`, `C-?` | undo, and do again |
| `S-<return>` | a line break where Enter alone sends, as in a chat |
| `C-<return>` | Control and Enter, which send many a form |
| `TAB`, `S-TAB` | the next and the previous field |
| `C-SPC` | set the mark: the motions after it mark a region of the field |
| `C-x h` | mark all of the field |
| `M-w`, `C-w` | copy the region, and cut it |
| `C-g` | drop the mark, and then give the keys back to Emacs |

A form is filled from the keyboard: `f` and the hint of the first field,
the text, `TAB`, the next text, and `RET`. `TAB` goes from field to
field only, as the `gi` of Vimium does, because a page puts buttons
between its fields: Reddit puts the one that shows the password between
the name and the password, and a tab of the browser's own stops there.
The first and the last field follow one another. A button is reached
with `f`.

The search paints every hit in the page itself, and scrolls to the one
you are on.

The buffer that `T` fills is an ordinary buffer, so isearch,
`consult-line` and the kill ring work on the text of the page. `T` goes
to it, and `q` leaves it and goes back to the page, as in a help buffer.

## The caret of the page

A drag of the mouse over the text of a page marks it and copies
nothing, as a drag in a buffer does. The caret then has the keys, with
the text as its region: `M-w` copies it, and `C-g` drops the mark. If
you set `mouse-drag-copy-region`, the drag copies here as well. In a
field the keys stay with the field, and its own `M-w` copies the mark.

`v` gives the page a caret, a point that the motions of Emacs move
through its text: `C-f` and `C-b` a character, `M-f` and `M-b` a word,
`C-n` and `C-p` a line, `C-a` and `C-e` to the ends of the line, `M-<`
and `M->` to the ends of the page, and the arrows as well. `C-SPC` sets
the mark and the motions then mark a region, which chromium draws as it
draws any selection; `M-w` copies it and pulses it. `C-g` drops the mark,
and then leaves the caret, as `ESC` and `v` do.

The caret starts after what has the focus, so that from a field you go
on reading where you were: `C-g` gives the keys back, and `v` starts
there. With nothing focused it starts at the first text in view, as the
caret mode of Vimium does. The page scrolls to keep the caret in view,
and smear-cursor flies from each place it stands to the next.

The caret is the selection of the page, moved as the Selection API of
the browser moves it, a character, a word or a line at a time. A page
that takes no typing draws no caret of its own, so a bar stands where it
is: the colour of the cursor of Emacs, with an edge of black or white,
whichever stands out, since a white bar alone vanishes on a white page.

## Jumping to text

The key that runs `avy-goto-char-timer` does what `M-j` does in a page,
even when `bind-key*` binds it. You type until you pause for `avy-timeout-seconds`, or for 0.5
seconds without avy. `RET` ends the text at once, `DEL` takes a
character back, and `ESC` gives up. Every place in view that shows the
text then takes a label, drawn and named as the labels of `f` are.
Naming a label puts the caret there, and smear-cursor flies to it.

A single place takes no label, as `avy-single-candidate-jump` has it.
Text in lower case matches either case, and text with a capital matches
only itself, as in avy. With the mark set, the region reaches to the
place instead, so `C-SPC` and a second `M-j` mark from one word to
another. From normal state, `M-j` also starts the caret.

A place counts only where its text shows. Invisible text takes no
label, and neither does text that a clipping box cuts off, such as a
heading kept for screen readers only. Text under something that paints,
such as the veil of a dialog or a banner, takes no label either. A clear
link that a page lays over a card paints nothing, so the title of a
Reddit post under it takes a label. Text that runs across two elements,
into a bold word for example, is not found, and neither is text inside a
frame.

## The name of a page buffer

A page buffer is named after the address it shows, and takes the new
one whenever the page moves, by a link, by `o` or by the page itself, so
that `C-x b` says what each buffer holds. The header line and the tab
show the title the page gives itself once it has loaded: until then chromium
names a page after its file. A page embedded in another buffer keeps the
name its host gave it, since the host finds it by that name.

## Windows a page opens

A window a page opens gets a page buffer of its own, shown beside the
page that opened it, as a browser shows a new window: the buttons to
sign in with Google or with Apple open one, and so does a link that
opens a tab. When such a window closes itself, as the one to sign in
does once you have, its buffer goes with it. Chromium tells of every
page that opens and closes, and a frame or a worker is left alone.

A link you open in another program goes to your default browser. When
that is the chromium canvas-browser runs, as Brave or Chrome may be,
the page opens there, on a display nobody sees. It comes to Emacs as a
tab of its own instead, and the frame that shows it is raised; a blank
page, a page of the browser's own and a page of an extension are left
alone. `canvas-browser-show-strays` turns this off, and
`M-x canvas-browser-show-hidden-pages` brings to tabs the pages that
opened so while it was off.

## Tabs

Each page is a buffer of its own, and so is each window a page opens.
A page buffer shows a line of tabs above its header line, one for each
page, as Chrome does: tab-line, which comes with Emacs, draws it in the
buffers of pages alone, so other buffers and the tabs of `tab-bar-mode`
are left as they are. The tabs keep the order the pages were opened in.
A tab shows the icon and the title of its page, cut to
`canvas-browser-tab-width` characters, and its address until the page
has given a title. As more pages open, the tabs narrow so that all of
them fit in the window, as in Chrome, down to the icon alone.

A click on a tab shows its page in that window. Its `×` kills the page,
and a window that showed it shows the tab to its right, or to its left
for the last tab. The `+` offers the pages you kept, and opens the one
you pick, or the URL you type, in this window.
`C-<next>` and `C-<prior>` are Control with Page Down and Page Up of a
browser; `C-TAB` stays with `tab-bar-mode`. An embedded page has no tab: it belongs to the buffer it
is in.

The icon is the one the page names in its head, or the one at
`/favicon.ico` of its site. Chromium fetches it, from its cache where it
can; where a page's rules forbid that, Emacs fetches it, without
waiting. An ICO, which Emacs cannot read, is turned into a PNG by
canvas-cairo, which reads it with gdk-pixbuf. Each icon is fetched once
and kept while Emacs runs, so a page of a site you opened before shows
the icon at once. A page with no icon, or whose icon has not come yet,
shows a globe.

The faces `canvas-browser-tab-line`, `canvas-browser-tab` and
`canvas-browser-tab-current` are laid over tab-line's own in a page
buffer, in the grey and white of Chrome, so the tabs of pages do not
look like the tabs of `tab-bar-mode`; customize them to change that.
Set `canvas-browser-tabs` to nil to have no line of tabs in the pages
opened after; the keys still go from page to page. The line is on by
default because it shows only in the buffers of pages. The line takes a
line of the window, and the page is laid out for what is left.

### The tabs of the last session

The tabs are kept when Emacs ends, and as they come, go or change, a
moment after, so that an Emacs that crashes keeps them as well. For
each tab, the file holds its address, its title and the address of its
icon, in the order of the tabs, and which tab you were in last. The
file is `canvas-browser-tabs.eld` in `user-emacs-directory`, or
`canvas-browser-tabs-file`. An embedded page is not kept.

The tabs come back the first time you open a page in the next session,
with `M-x canvas-browser`, a link through `canvas-browser-browse-url`
or a bookmark, and not when Emacs starts, so canvas-browser is still
loaded only when you use it. They come back to the left of the page you
open. A tab that comes back shows its title and its icon, which Emacs
fetches itself, and nothing more: no window opens for it, and neither
chromium nor its page is started. Its page is read when you show the
tab, by a click, `C-c C-t`, `C-<next>` or any other way. Closing a tab
that was never read starts nothing either.

`M-x canvas-browser-restore-tabs` brings the tabs back without opening
a page, and shows the tab you were in last; that tab alone is read. The
tabs come back once in a session.

Set `canvas-browser-keep-tabs` to nil to keep no tabs. It is on by
default, as a browser keeps its tabs: a tab costs nothing until you
show it, and the file is written only in a session that has used
canvas-browser, so a session that has not keeps the tabs of the last
one. `canvas-browser-restore-tabs` works with it off as well, from the
file a session with it on kept.

## The map of canvas-minimap

No map opens beside a page: canvas-browser puts `canvas-browser-mode`
in `canvas-minimap-exclude-modes`. A page is a picture, not lines of
text, and a map of it told the reader nothing the window does not. Take
the mode out of that list to have the strip back, as an empty block.

## A window of its own

Chromium runs with a window, on an X display of its own: `Xvfb` is
started on `canvas-browser-display` (`:98` by default) the first time a
page is opened, and nothing is ever shown there. The page is read
through the screencast, so none of it travels to your own display, which
matters when that display is forwarded over ssh. With a window, the
sites see the Chrome they see anywhere, and pass a bot check that
catches a headless one; [docs/design.md](docs/design.md#why-chromium-has-a-window)
has the numbers.

A page that is moving is painted from the JPEG frames of chromium, and
`canvas-browser-crisp-delay` after the last key or click it is drawn
again as a PNG, which loses nothing.

`canvas-browser-window-strategy` says how chromium gets its window:
`xvfb`, the default on Linux, is the display of its own above;
`headless` is no window at all, for a machine with no X server; and
`virtual-display`, the default on macOS, and `offscreen` are below.
`canvas-browser-headless`, the older setting, still means `headless`
while the strategy is left at its default.

### On macOS

Chromium on macOS draws on no X display, so `Xvfb` cannot hide it.
macOS can make a display of its own instead, one that no screen shows,
and chromium draws its windows there. `canvas-browser-display` makes
that display. It is a program of 150 lines in Swift, which you build
next to canvas-browser with the Swift of the Xcode command line tools:

    make display

The display touches your main display at its bottom right corner and
nowhere else, and each page opens in a window of its own on it, so
nothing of chromium comes into view, not even a window a page opens to
sign in. The sites see the same Chrome as with a window on `Xvfb`, with
the WebGL of the graphics card. A pointer moved toward that corner stops
there as at a wall. The program uses classes of macOS that are not
public, as DeskPad does, so a macOS to come may break it.

Without the program, or when it fails, canvas-browser says why, once,
and uses `offscreen`: each window goes past the bottom right corner of
your screen. macOS keeps a part of every window on the screen, so a
corner of about 40 pixels shows there; it is out of sight behind any
window that covers the corner, such as a large Emacs frame, and the page
goes on drawing behind it. A window a page opens shows where chromium
puts it for a few hundredths of a second before it goes to the corner.
Set the strategy to `offscreen` to have this without the program.

Chrome comes to the front with each window it opens, wherever the
window is, and Emacs takes the focus back at once. Chrome is in the Dock
and in `Cmd-Tab` while it runs. A tiling window manager such as Amethyst
arranges the windows on the virtual display too, where nobody sees
them, so it does no harm there; with `offscreen` it may pull the
windows into view, so leave this Chrome out of it. Using Chromium or
Chrome for Testing here keeps it apart from the Chrome you browse with.

## Settings

| setting | default | what it is |
|---|---|---|
| `canvas-browser-chromium` | chromium, chromium-browser, google-chrome, and the apps of Chromium and Google Chrome on macOS | the names looked for |
| `canvas-browser-profile-directory` | by the chromium found | where the profile goes |
| `canvas-browser-window-strategy` | virtual-display on macOS, else xvfb | how chromium gets its window: xvfb, headless, virtual-display or offscreen |
| `canvas-browser-display` | :98 | the X display chromium draws its window on |
| `canvas-browser-quality` | 70 | the quality of a moving frame, from 1 to 100 |
| `canvas-browser-crisp-delay` | 0.4 | seconds of quiet before the page is drawn again without loss |
| `canvas-browser-pulse-function` | smear-cursor's copy effect | what draws the eye to what a hint copied, or nil |
| `canvas-browser-focus-function` | smear-cursor's flight | what draws the eye from the old focus to the new, or nil |
| `canvas-browser-hint-keys` | asdfghjkl | the letters a hint is made of |
| `canvas-browser-hint-font` | Sans Bold 11 | the font a hint is written in |
| `canvas-browser-line-height` | 40 | pixels that `j` and `k` scroll |
| `canvas-browser-search-url` | DuckDuckGo | where words are searched for |
| `canvas-browser-tabs` | t | whether a page buffer shows a line of tabs |
| `canvas-browser-tab-width` | 20 | the most characters of a title a tab shows |
| `canvas-browser-keep-tabs` | t | whether the tabs are kept, and come back in the next session |

The others, such as how often a moving page is drawn, are in Customize:
`C` in a page buffer, or `M-x customize-group RET canvas-browser`.

## Emacs that stops answering

Emacs 32.0.50, the master of October 2026, can freeze at 100% CPU while
a TLS connection is still shaking hands: a call to
`accept-process-output` for another process, without JUST-THIS-ONE,
never returns. A tab opens such a connection when it fetches the icon of
its page, so migemo, emacsql, pdf-tools and other packages that wait so
can freeze then. `extras/tls-wait-fix.el` works around the bug. Load it
before those packages, and remove it once Emacs is fixed:

```elisp
(load (expand-file-name "canvas-browser/extras/tls-wait-fix" "~/src"))
```

## What it does not do

- Video and animation: a frame reaches the screen after what you do, and
  a full frame costs about 3.5 MB on a display without shared memory.
- Downloads, printing and developer tools.
- A second engine.

## The tests

`make test` runs against a stubbed websocket and needs no chromium.
`make live` opens `tests/fixtures/page.html` in a real chromium, waits
for a picture, and reads the text of the page.
