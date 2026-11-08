# Search files (native Windows client)

A native WPF application (`SearchApp.exe`, .NET Framework 4.8, no installer, no extra DLLs) that is a client for the existing
search-web server API. It does everything the web page does and, because it is a real Windows program, it opens results with the
default Windows application (an `.eml` opens in Outlook, a PDF in the PDF viewer, ...).

## Build and deploy (on the Linux host)

    ./deploy.sh        # dotnet build -c Release -o out, copies out/SearchApp.exe to %USERPROFILE%\SearchApp\ through `ssh wsl`

The Windows user name is detected once and cached in `~/.config/search-win/pc.env` on the Linux host (not in the repo; write
`PC_USER=<name>` there if detection is ambiguous). A running exe is renamed aside, so deploying never needs the app closed.

Source is plain C# with no XAML (the UI is built in code), so the Linux SDK cross-compiles it.

## Pin it for Win+1

Start `%USERPROFILE%\SearchApp\SearchApp.exe`, right-click its taskbar icon, "Pin to taskbar", then drag the icon to the first
slot. Win+1 now starts it (or switches to it).

## Config (`%APPDATA%\SearchApp\config.json`)

    {"server":"http://127.0.0.1:8795",
     "pathMap":[["/mnt/share/","S:\\"]],
     "thumb":16, "cw":{}, "window":{...}, "lastQuery":"", "dangerousExt":["exe","bat",...]}

This file lives only on the PC and is never part of the repo; it is where private, per-machine settings go. With no file the
app uses the server above and an empty drive map (every file is then downloaded before it opens).

* `pathMap`: results whose server path starts with the first value are opened in place through the Windows drive. Everything
  else is downloaded through the API to `%TEMP%\SearchApp` (copies older than 7 days are removed at start) and then opened.
* `dangerousExt`: opening one of these asks for confirmation first.

## Testing without a visible window

All on the PC, through `ssh wsl`, nothing is shown or launched:

    tools/pcrun.sh st.txt --selftest --golden '<profile>\\SearchApp\\out\\golden.json' --live --ui --term report --narrow minutes
    tools/shot.sh name --query "report minutes" --size 1300x800 [--light] [--thumb 320] [--select 1] [--do settings|hist|cp|menu|busy]

* `node tools/golden.js ...` records the web page's own query-language functions on a corpus; `--selftest --golden` compares the
  C# port (zero diffs). `--term` should be a word with more than 200 hits, `--narrow` one that cuts it below 1000. `golden.json` is built from the user's history and is git-ignored.
* `--shot` renders the whole UI offscreen to a PNG (see `shots/`, git-ignored).

## Keys

Same as the web page: Alt+D focus query, Enter search, Up/Down/Ctrl+J/K history, Ctrl+R or F4 history popup, Tab or Ctrl+Space
completion, Down into the list, arrows/Ctrl+J,K,H,L/PageUp/PageDown/Home/End, Enter or double-click opens, Ctrl+C copies the path,
Ctrl+wheel and Ctrl +/-/0/9 zoom, Ctrl+P settings, Ctrl+N new window, Ctrl+W close, Ctrl+Shift+R restart into an updated exe. New: right-click or Menu key for the context menu (Open, Open
with, Show in folder, Copy path, Copy Windows path, Save a copy, Open in browser) and dragging a result out onto Explorer,
Outlook or Teams. Esc cancels a running download.
