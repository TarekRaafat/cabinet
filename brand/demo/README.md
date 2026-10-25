# The demo film

94.4 seconds at 1920 x 1080: from an empty folder to a working team, and the owner's first morning. Seven chapters, each with its card: create the team, set up the machine, check everything, the morning brief, answering in one line, the team at work, and only you push. Cut to its music: the first chapter starts as the drums come in (8.95 s), `cabinet version` on the late entrance (83.75 s), the logo animation on the final section (88.15 s). Not shipped in the package.

What is real and what is an example:

- **Real:** every `cabinet` command and its output, run in a sandbox by `capture.sh` (a temporary HOME, fakes for the schedulers, secret stores and the agent tool, as `test/smoke.sh` does) and kept in `captured.js` with the terminal's colors. The push prompt is the guardrail's own wording.
- **Shown as a person sees it:** the sandbox's home as `/Users/maya`, the agent tool at `/opt/homebrew/bin/claude`.
- **Examples, labeled as the agent's in the film:** the brief, the agent's reply, and git's two lines after "yes". They follow the kit's formats (`CABINET.md`, the sign-off queue; `roles/chief-of-staff.md`, the brief).

| File | What it is |
|---|---|
| `cabinet-demo.mp4`, `.webm` | The film. |
| `demo.html` | The film itself: every frame is `render(t)`. Open it in a browser to watch it (space pauses, the arrows step, r restarts). |
| `captured.js` | The commands' real output, made by `capture.sh`; it also holds `cabinet init` in a project repo, which the website's hero terminal replays. |
| `capture.sh` | Runs the commands in a sandbox (macOS). |
| `music.m4a` | The music, made with Suno. |
| `suno-prompt.md` | The prompt that made it. |

To render it again (about 3 minutes), or capture the commands again first when the kit's output changes:

```sh
node brand/render-film.js demo
node brand/render-film.js demo --capture
node brand/render-film.js demo --stills 50000   # one frame to brand/demo/stills/, to check a change
```

It needs ffmpeg, a network connection for the fonts, and a Chromium headless shell (see `brand/render-film.js`). New music moves the times in `demo.html` (`LENS` and the segments after it).

The film follows `brand/BRAND.md`: night, mist, brass only for the owner; the logo animation at its own timings; the terminal palette (lavender for the program and headings, pink for flags, cyan for quoted text), apart from the status colors, which mean only ok, note and fix.
