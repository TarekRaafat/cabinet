# The promo film

32 seconds at 1920 x 1080: one person, a whole team, and the owner in charge. It is cut to its music: a hit every 2 bars at 120 BPM (0:04, 0:08, 0:12, 0:16, 0:20, 0:24, 0:28), the roles changing on 0:12 and the team completing in the logo on 0:28. Not shipped in the package.

| File | What it is |
|---|---|
| `cabinet-promo.mp4`, `.webm` | The film, ending on the repository's address: for sharing (a launch post, social, video sites). |
| `cabinet-promo-facts.mp4`, `.webm` | The same film, ending on "Open source. Works with any agent tool that reads AGENTS.md.": for the README and the website, where the address is already known. |
| `video.html` | The film itself: every frame is `render(t)`. Open it in a browser to watch it (space pauses, the arrows step, r restarts). |
| `music.m4a` | The music, made with Suno. |
| `suno-prompt.md` | The prompt that made it, and what was tried before. |

To change the film, edit `video.html` and render it again (about a minute each):

```sh
node brand/render-film.js promo                 # cabinet-promo.mp4 and .webm
node brand/render-film.js promo --end facts     # cabinet-promo-facts.mp4 and .webm
node brand/render-film.js promo --stills 9000   # one frame to brand/promo/stills/, to check a change
```

It needs ffmpeg, a network connection for the fonts, and a Chromium headless shell (see `brand/render-film.js`). New music must keep 120 BPM with its hits on the same bar lines, or the times in `video.html` move with it.

The film follows `brand/BRAND.md`: night background, mist, brass only for the owner; the logo animation (the owner in the middle, the team fanning out, the owner moving to the open place); loading while the team works, without the owner; and the kit's real words (`HANDOFFS.md`, `BRIEF.md`, the sign-off queue, the push guardrail's message).
