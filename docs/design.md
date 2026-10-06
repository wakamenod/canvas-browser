# How canvas-browser works

This is how canvas-browser does what the [README](../README.md) says it
does, and why. You need none of it to use it.

## The hints

A hint goes only where a click in the middle of what shows of a thing
reaches it, or reaches its label. Whatever lies outside the window,
under a dialog, or around something else that can be clicked, as a link
around a button does, gets none. On the front page of Reddit that took
the hints from 388 to 35, and with the login dialog open the page under
it gets none at all. A click is followed up through the slot a web
component puts its text in, so a link built that way, as Reddit's
"Continue with Phone Number" is, counts.

A role counts only where it says the thing does something, as Vimium has
it: an icon or a heading marked as only looking takes no hint, and
inside a button it would crowd the button. Nor does a thing of a few
pixels, as a tracker is. A frame the size of a button counts, since a
click in it reaches what it holds, as Google's button to sign in is,
and a taller one is an advertisement and does not. On the page of a
subreddit that took 9 of 69 labels away, among them the five crowded
onto the bar that sorts the posts. Past the hints of two letters come
hints of three, so no box is left without one.

A region the page shows the pointer over counts too, since a script
that listens for clicks marks one so: the outermost element of it,
unless it fills half the window. A picture in a post of Reddit opens
this way, and so does a heading that opens a list. And a thing covered
by another thing that can be clicked gives its place to that one: the
link over a post of Reddit covers its title, and takes its hint there.
Finding the regions costs about 7 ms on the front page of Reddit, whose
web components hold 13,538 elements, because the search stops inside
anything that already counts.

A label goes at the top left corner of its box. When two would meet
there, as a post of Reddit that is a link meets the link of its author,
the small box keeps the corner and the label of the large one goes in
its middle, where a click on it lands anyway.

A picture is cut in Emacs, with cairo, from a picture of the whole
window, as much of the block as shows, and goes to the clipboard through
kill-ring-images. Chromium can cut a part itself, but it does so by
moving the view of the page to the part, and the view stays moved for a
while after: every frame and every picture of that while shows the page
shifted into a corner, or a part of it repeated across the window.

## Keys sent to the page

A letter goes to the page as a key that types, so it reaches whatever
has the focus, as a key pressed in a browser does. Text put in without a
key lands at the caret instead, and the caret stays behind in a field
that the focus has left.

A key reaches chromium with the number Windows gives it as well as its
name, because chromium edits a field by that number: sent by its name
alone, backspace arrives as an event that deletes nothing.

The buffer is writable while insert state lasts, since the input method
of macOS gives the keys of a read-only buffer straight to Emacs. The
picture itself stays read-only, so a key of Emacs that edits a buffer
cannot change it.

The search paints every hit in the page itself, with the highlight API of
CSS, and scrolls to the one you are on. `window.find` answers in a
headless chromium but leaves nothing to see.

## While it moves, and once it stops

A page that is moving is painted from the JPEG frames of chromium's
screencast, which are cheap to make and show their workings around
small text. `canvas-browser-crisp-delay` after the last key or click the
window is asked for a still picture as a PNG, which loses nothing, and
that is what you read. Remote desktops do the same thing under the name
of a lossless refresh.

The keys decide the moment, not the frames. A page with a spinner on it
never falls quiet, and waiting for quiet would leave it lossy for as long
as you looked at it; waiting on the keys instead means the page is crisp
about four tenths of a second after you stop scrolling, measured at 0.39
and 0.43 seconds on a GitHub Actions page. A still picture costs chromium
a fifth of a second, so none is taken while you are working the keys, one
asked for before a key and arriving after it is dropped as a picture of
the page as it was, and no more than one is taken every
`canvas-browser-live-interval`.

A page is seldom either moving or still: a spinner beside a running job
turns while the text around it stands. Every still picture is therefore
followed by a question to the page about what is moving on it, which it
answers from `document.getAnimations()` and from its videos, canvases
and GIFs. While those parts cover less than `canvas-browser-live-share`
of the window, each frame is drawn into them alone and the rest of the
canvas keeps the still picture, with a fresh still every
`canvas-browser-live-interval`. Measured on a GitHub Actions page with
five spinners: 77 frames in 8.3 seconds, every one of them drawn into
the spinners alone, and four still pictures in between.

The page may of course change outside those parts, and that change waits
for the next still picture. Any command in the buffer forgets the moving
parts at once, so a scroll, a click or a key draws the whole window
again.

Chromium sends a screencast frame after every picture it is asked for,
the picture being a draw like any other. Painted, that frame would ask
for the next still picture, and the two would take turns on the canvas
for ever, which the reader sees as a pulse around small text. A frame
that is the picture the canvas already holds is therefore dropped, which
is told by the md5 of its bytes.

A frame is answered as it is painted, not as it arrives. Chromium holds
back the next frame while the frames it sent are not answered, so a
frame answered on arrival brought every frame chromium drew, and Emacs
read them all to paint about one in three. A command answers every frame held,
so the frame it makes is not held back behind them. While only parts of
the page move, a frame is drawn every `canvas-browser-live-frame-interval`,
a quarter of a second, rather than every `canvas-browser-frame-interval`:
a spinner turns as well at four frames a second, and each frame is still
the whole window, read in full. Measured with a spinner on a page of
919 by 829 pixels on a Retina screen, twice each: Emacs took a whole core
before, reading 41 frames a second to paint 12, and a quarter of one
after, reading and painting 4. The first frame after a scroll key came
in 66 and 81 ms at the median, against 157 and 124 ms before.

The numbers of one window of 1874 by 921 pixels: a JPEG at quality 70 is
120 kB and takes 0.10 s, the same picture at quality 95 is 235 kB, and
the PNG is 228 kB and takes 0.22 s. The PNG is therefore too slow for
twelve frames a second and cheap for a page standing still. Drawing a
frame into the moving parts costs about three milliseconds, and drawing
the whole window about four, so the parts are clipped in one path and the
picture read once: read once for each of five parts, the same frame cost
sixteen milliseconds.

A window that has just changed size is filled as soon as chromium has
laid the page out for it, and a window that paints nothing for
`canvas-browser-fresh-interval` seconds asks for a picture of itself, so
a window left black by a missed frame fills itself again.

A page that no window shows is left to chromium, which throttles it as
it throttles any tab behind another: its frames are stopped until you
come back to it, and a handful of news sites no longer fight for the
machine.

## Why chromium has a window

This is about what the sites see. A headless chromium says
`HeadlessChrome` in its user agent, keeps `navigator.webdriver` true and
has no WebGL at all, and a site behind a bot check reads all three: it
then asks you to pick out traffic lights rather than to tick a box. With
a window, and with WebGL drawn in software, the same four questions
answer as they do in any Chrome.

It is also faster. On the same page, the time from a scroll key to the
new picture is 5 ms with a window and 26 ms without it, a still picture
costs 0.18 s against 0.22 s, and the memory is the same to within half a
percent, plus 87 MB for `Xvfb`. Software WebGL is for WebGL alone:
drawing the whole window that way, which `--use-angle=swiftshader` does,
cost two whole cores.

## The virtual display on macOS

macOS keeps every display touching another and lets the pointer through
the corner where the virtual display touches yours, so
`canvas-browser-display` puts a pointer that wanders onto the display
back on the nearest point of a display you see. The program hears the
mouse move in any application, which needs no permission for the mouse,
and looks every quarter of a second for a pointer another program moved;
waiting, it takes no time of the processor. Pages take their clicks and
keys from chromium, not from the pointer, so this does not touch them.

The display lasts as long as the program; Emacs starts it with chromium
and stops it after chromium, and when the program ends by itself
chromium is stopped too, since macOS would move its windows onto your
screen.

A window that is minimized, or whose application is hidden, would show
nothing, but a page loaded into it draws nothing either: macOS tells
chromium that the window is not visible. So neither is used.
