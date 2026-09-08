<!-- Product and protocol names do not have useful acronym expansions here. -->
<!-- vale Google.Acronyms = NO -->
<!-- vale Microsoft.Acronyms = NO -->
<!-- Technical names do not measure prose reading difficulty. -->
<!-- Reading difficulty comes from required protocol and command names. -->
<!-- vale Readability.FleschReadingEase = NO -->
# Screen mode

Connect to a host, then tap **GNU Screen sessions** in the terminal toolbar.
If the host has one session, the app opens it directly.
Otherwise, choose a session, including one already attached elsewhere.
Your shell stays open. Screen uses its own terminal channel.

The bottom window strip scrolls sideways. Tap a tab to choose a window.
The Screens icon closes Screen mode and returns to your original terminal.
The toolbar also provides AI commands and port forward controls.
AI commands run in the selected Screen window.
Use the window list to search by number or title.
A bell icon marks a background window that received a bell.
A blue dot marks activity in a window with monitoring enabled.
Screen clears these flags when you visit the window.
The app checks for changes while the Screen controls are visible.
Background checks update the controls only when the window state changes.
Badges update while this view is open. They do not count each event.

Use **Add Screen window** to create a window.
Touch and hold a tab for window actions.
Use `Monitor activity` to watch for new output.
The app asks before closing a window. Closing stops its running program.
Closing the last window ends the Screen session.

Drag down to read older output in Screen's native copy mode.
Drag up to move toward newer output.
Reaching the bottom exits copy mode and resumes live output.
The keyboard and controls stay hidden.
The terminal keeps its colors and layout while you scroll.
You can also use **Browse Screen history** to start scrolling.
Scrolling hides the keyboard, window tabs, and controls.
Tap the up arrow beside **Refresh Screen** to hide these controls at any time.
A floating down arrow at the top right shows them again.
Tap and release to return to live input and show only the keyboard.
The Screen controls stay hidden until you tap the floating down arrow.
Scrolling starts after the keyboard finishes hiding.
Rotating the phone during scrolling returns to live input.
Typing or pressing a keyboard arrow also returns to live input first.
The app installs Screen key bindings for entry, movement, and exit.
Only copy mode receives the scroll keys.
After a resize, these keys enter copy mode. They do not send text to the program.
The bindings reserve `Ctrl-A Ctrl-_` followed by `gterm-scroll;0~` through `gterm-scroll;3~`.
This mode expects the standard Screen command prefix, Ctrl-A.
Both Screen key maps use these keys without a timeout.
They stay in the session after detach. The app reuses them on the next connection.
Custom Screen keys can change how scrolling works.
Screen shares copy-mode scrolling with other displays showing the same window.
Before scrolling, the app counts stored history lines using a temporary snapshot
on the host. It deletes the snapshot after reading the count.
This count limits scrolling to stored output.
Turning on history in Screen retains future output.
It cannot recover unsaved output.

When the keyboard opens, the view scrolls up only enough to keep the cursor
and the following row clear of the keyboard. Earlier output stays in view.
Closing the keyboard restores the full view.
The remote terminal keeps its size and contents.

Hold Backspace on the system keyboard to keep deleting text. Release it to stop.
Tap **alt**, then Backspace on the system keyboard, to send the word-delete shortcut.
The remote app controls how this shortcut works. Alt clears after the key press.

Tap another position on the cursor's current row to move left or right.
Links and applications that handle mouse input take priority.
Hold a word to highlight it, then release your finger.
Drag the native iOS selection handles to extend or shorten the highlight.
Choose **Copy** from the system menu.
Changes to these rows or the terminal size clear the highlight.

Use **Detach** to return to the session picker.
Use the Screens icon to return to your original shell.
Both actions close only the app's terminal channel.
Other attached displays stay connected.

## Host requirements

Run Screen as the same user on the same host.
Screen must support quiet queries with `-Q @echo -p`.
This mode does not attach to sessions through nested SSH or `sudo`.
The app uses `screen -x` to share sessions with other displays.
Window groups and tmux are outside this version.

If a query fails, the app shows the error and disables window actions.
Use **Refresh Screen** to retry.

## Tests

Generate the project and run the focused tests on a Mac:

```sh
xcodegen generate
xcodebuild -project gterm.xcodeproj -scheme ScreenValidation \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Tests cover window data, stale state, history, and failed SSH commands.
On the phone, check the keyboard, tabs, bells, and history.
Then detach and check that the shell still works.
