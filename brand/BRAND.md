# Cabinet brand

The rules for the Cabinet mark, name, color, type and words, written for people and for agents. This file is the source of truth; when it and anything else disagree, this file wins.

| File | What it is |
|---|---|
| `brand/BRAND.md` | These rules, each with its status. |
| `brand/tokens.json` | The same decisions as data: colors, status colors, fonts, the mark's geometry, motion. |
| `brand/assets/` | Every logo file, built from `tokens.json` by `tools/build-brand.js`. Never edit one by hand. |
| `brand/index.html` | The visual guide: every rule shown, for people. Open it in a browser. |
| `brand/motion.html` | The logo animation and its variants, moving. |
| `brand/promo/`, `brand/demo/` | The promo and demo films, their sources and music; `brand/render-film.js` renders them again. |

To give a project's agents these rules, copy this file to the workspace's `guides/brand.md` and add a row for it in the "Guides" table in `AGENTS.md`.

**Status.** Each rule is marked:

- **Approved:** the owner decided it. Follow it.
- **Draft:** proposed, not reviewed yet. Follow it too, but before anything public relies on a draft rule, ask the owner.

## What Cabinet believes (Approved)

Cabinet is a productivity kit that makes one person a whole team. It does not replace people; it multiplies them. Every rule below follows from these.

- **People amplified, not replaced.** Every person becomes a whole team, or a whole company. Agents bring the skills and the hours; the person brings vision, judgment, and the final say.
- **More output per person, not more headcount.**
- **A small company, not a corporate org chart.** Every piece of work has exactly one owner, and nothing is done twice.
- **People decide, agents do the work.** Agents recommend; you sign off on anything irreversible, public or costly, and you always know what is happening.
- **For anyone.** One person or a team of any size, building anything (code, apps and websites, design, writing, marketing, music, finance), working their own way.

The tagline: **One person, a whole team. Build anything with AI agents, and stay in charge.** (Approved)

## 1. The idea (Approved)

- The mark is a table seen from above: eight places in a ring.
- Seven places are filled. They are the agents, each deciding within its own authority.
- The eighth place, on the right, is left open. It belongs to the owner, who signs off on what is irreversible, public or costs money. The gap is also what turns the ring into a C.

## 2. The mark

- **(Approved)** One mark for every size, from 16px up: eight places every 45 degrees on a ring of radius 36 units, seats 19 units wide, on a 100 unit grid, the place at 0 degrees (right) left open. There is no simplified small version.
- **(Approved)** One color: dark seats (ink) on light backgrounds, light seats (mist) on dark ones.
- **(Approved)** On its own light tile (paper, corner radius 22 units, the mark at 66%) where the page can be light or dark and you cannot choose the file, such as a README. No border.
- **(Draft)** Clear space: one seat's width on every side. Nothing else enters it, including the name.

### Loading (Approved, timings Draft)

- The team at work: the seven seats stay in place and light up one at a time, counterclockwise from the top, like a word passed around the table. The open place is a rest beat: nothing lights there, and the brass outline never appears, because loading is not the owner's moment.
- Timing: one beat every 150 ms, eight beats a turn (1.2 s), the open place included. The lit seat is at full color and fades back to 30% over two beats, eased out. Seats at rest are at 30%.
- Done: every seat comes up to full color over 400 ms, so it always ends on the mark. If it fails, it ends on the mark too, and the message says what went wrong.
- Only opacity changes: nothing turns, moves, grows or changes color. Ink on light, mist on dark, at any size from 16px.
- Show it only after 400 ms, so a short wait never flashes. Use it for a wait of unknown length; when the progress is known, show the progress.
- One at a time on a screen, never the header logo, never in the README, slides or print. It says "Loading" to screen readers (`role="status"`); past a few seconds, a line in words says what is happening.
- With reduced motion: the plain mark, still, with the word "Loading..." beside it.
- The one motion without the owner: it loops while you wait, at any size, even under 48px where the outline blurs. A wait that opens something, such as an app's launch screen, plays the logo animation instead, which starts with the owner.

### The logo in motion (Approved, timings Draft)

**One becomes a team.** Everything starts with the owner: the seed the team grows from. About 3.4 seconds, played once. `brand/motion.html` shows it moving, with every variant below.

1. **You.** The owner's brass outline alone, in the middle.
2. **A whole team.** From 800 ms, the seven seats fan out of the owner to their places on the table, each from 30% of its size, fading in over the first third, 900 ms, eased out. The seat facing the owner (180 degrees) leaves first; the others follow 45 ms apart outward from it, the two beside the open place last.
3. **Your place.** From 1000 ms, the owner moves right into the open place, 900 ms, eased in and out. It passes through the gap and never crosses a seat.
4. **Cabinet.** At 2500 ms the outline fades out over 400 ms; the mark slides left over 700 ms to make room, and the name fades in over 500 ms, ending on the side-by-side lockup.

- Where the owner is the subject (onboarding, a welcome page, the brief), it ends on step 3: the outlined mark, no name.
- The other ending, for the logo animation or any variant: the name comes out of the owner's place, revealed from beside the open place outward over 750 ms, instead of fading in. Cabinet comes from you. The fade is the default.
- Every animation of the mark that tells its story (this one, the variants and the chairs) starts with the owner in the middle and ends with the owner in the open place. Loading, a loop while you wait, is the one without the owner.
- In these animations the seats and the outline may move and grow; nothing else does. Nothing turns, no seat ever takes the open place, and brass is only the owner's outline. The one exception is "Echo", where copies of the owner's outline travel out and become the seats: they are the owner's, so brass still means the owner.
- Use it: video intros and end cards, an app's launch screen, a website's first visit, onboarding. Once; never in a loop, on every page load, with anything else moving, in the README, npm, slides or print, or under 64px.
- With reduced motion: the last frame, still.

**Variants**, each for its own use, never as the logo animation:

| Variant | What happens | Use |
|---|---|---|
| Take your seats | The faint table appears; the seats come in from outside and sit down, counterclockwise from the top; the table fades. | Explaining the team: slides and docs about how a Cabinet works. |
| You, then the table | The owner in the middle; the seats come in from outside as the owner moves to the open place and the faint table appears where the owner was. | Onboarding and welcome pages. |
| You, multiplied, at the table | The seats fan out of the owner while the faint table spreads under them; the owner moves to the open place. | A website's opening picture. |
| Ripple | The owner beats once; a faint ring spreads out and the seats form where it reaches the table. | Short and calm: a splash screen, the first launch of an app. |
| Setting the table | The owner walks around the table counterclockwise, leaving a seat at each place, and arrives at the open place. | Setup: the end of setting up a workspace, explainers about building the team. |
| Pull back | A close-up on the owner's outline; the view pulls back as the team appears. | Video: intros, the opening of a talk or a launch film. |
| Roll call | "you" in the middle; each seat arrives with its role's name; the names fade. | Onboarding and explainers, with the project's own roles. |
| Pull up a chair | The owner's brass chair in the middle; the chairs slide in, then turn into the mark. The chairs' own sequence (see "The chairs"). | Illustration and video, at 96px or more. |
| Your circle | The owner's outline grows into the table's ring, the seats appear on it, and it draws back into the open place. | Talks and slides about vision. |
| Echo | Copies of the owner's outline travel out one at a time and turn into the seats. The one place brass leaves the open seat, because the copies are the owner's. | Marketing about amplification: every agent carries the owner's intent. |


## 3. The open seat in brass

- **(Approved)** A brass outline in the gap marks the owner's place. It is an accent, not a second logo.
- **(Approved)** Use it where the owner acts: the daily brief, the sign-off queue, onboarding and welcome pages, slides about how the owner signs off, and the app icon or headers at 48px or more in full color.
- **(Approved)** Use the plain mark everywhere else: under 48px, in one color (terminal, print, stickers), and next to the name.
- **(Approved)** The outline is never filled, and never any color but brass (`#A06F17` on light, `#D7A54B` on dark).
- **(Approved)** On hover: where the mark can be pointed at or clicked (a website or docs header linking home, a page only the owner opens), the outline may fade in on hover and keyboard focus. Onboarding may play it once when the owner arrives. Never where nothing can respond (README, npm, social previews, slides, print), and on one logo per page at most.
- **(Draft)** The fade takes 400 ms, and only the outline's opacity changes. With reduced motion it appears without the fade. Touch screens show the plain mark.

## 4. The chairs (Approved)

- An illustration of the mark, not a second logo: the same eight places and open place, each seat drawn as a chair with its back to the outside.
- Use it to tell the story, at 96px or more: animation and video, onboarding and empty states, docs and slides that explain the team (a chair may carry a role's name), a website's opening picture, posters.
- Never as the logo: not the favicon, app icon, avatar or README logo, not next to the name, not under 96px, never with more or fewer than eight places, and in no color but ink, mist and the owner's brass.
- The owner's chair: the open place may show an empty chair outlined in brass, where the owner is the subject.
- In motion: like the logo animation, start with the owner in the middle (the brass chair alone) and end on the mark with the owner in the open place; nothing turns; the open place is never taken by an agent's chair, only the owner's; with reduced motion show the last frame.
- **(Draft)** Timing: each step 400 to 800 ms, eased in and out, no bounce. The sequence, the variant "Pull up a chair": the owner's brass chair alone in the middle; the seven chairs slide in from outside to the table, counterclockwise from the top; the brass chair moves to the open place; each chair turns into its dot and the brass chair into the outline; the name may follow.

## 5. The table (Approved)

- For pictures that explain the idea (the guide's first picture, onboarding, an explainer video, a slide about the team, the chairs), never in the mark itself: not the logo, favicon, app icon, README, wordmark or terminal.
- Always faint: the seats' color at 12%, never brass, well inside the ring.

## 6. The name

- **(Approved)** **Cabinet** in sentences and headings, with a capital C. `cabinet` in lowercase only where it is the command, a file or the package (`cabinet init`, `cabinet.env`, `@tarekraafat/cabinet`). Never "CABINET" or "the Cabinet kit".
- **(Approved)** The wordmark stays lowercase: it is the logo, not a sentence.
- **(Draft)** The wordmark is the name in Schibsted Grotesk Bold, tracked -0.035em, as outlines (`wordmark.svg`), so it never depends on the font.
- **(Draft)** Side by side (`lockup.svg`): the mark 1.1 times the type size, 0.32 of the type size from the name, centered on the name's height. Stacked (`lockup-stacked.svg`): the mark 2.25 times the type size over the name, for square spaces.

## 7. Color

- **(Draft)** Ink `#15181E`: seats, text, the name.
- **(Approved)** Paper `#F3F4F6`: backgrounds and the logo tile.
- **(Draft)** White `#FFFFFF`: cards and documents on paper.
- **(Draft)** Night `#101216`: dark backgrounds, slides, the app icon.
- **(Draft)** Mist `#E8EAEE`: seats and text on night.
- **(Draft)** Slate `#5C6370`: secondary text and captions (6:1 on white).
- **(Draft)** Line `#D9DCE2`: borders and dividers on light backgrounds.
- **(Draft)** Brass `#A06F17` on light and `#D7A54B` on dark: the owner's open seat, nothing else. Not for text or links (4.4:1 on white).
- **(Draft)** How much: paper and white about 60%, ink 30%, slate and line 9%, brass at most 1%.

### Status colors (Approved)

| Level | Means | On light | On dark | Terminal |
|---|---|---|---|---|
| `ok` | Nothing to do. | `#2F7D4F` | `#6CC08B` | green |
| `note` | Worth knowing, nothing broken (the warning). | `#2F6FB3` | `#7FB0E8` | blue |
| `fix` | A problem; the message names the command that fixes it. | `#B3261E` | `#F2867D` | red |

- The warning is blue, never amber or yellow, so it is never taken for the owner's brass.
- The word always comes with the color; color never replaces it.
- Status colors only mark status: never buttons, links, headings or decoration. One status color per line.
- In a terminal: the terminal's own red, green and blue, only when the output is a terminal, and none when `NO_COLOR` is set. `cabinet doctor` does this.

## 8. Type (Draft)

- Schibsted Grotesk 700 for the name and headings (headings at -0.02em); 400 for running text, 15 to 17px.
- JetBrains Mono 400 for commands, files and labels.
- Both are free under the SIL Open Font License 1.1, on Google Fonts. On GitHub and npm the site's own fonts apply, and that is fine.

## 9. Writing (Approved)

Cabinet sounds like a capable chief of staff: plain, short, specific, and always clear about who decides.

- Plain words. Say what happens and who does it. Name things the way the owner sees them.
- A message that reports a problem ends with the command that fixes it.
- ASCII punctuation only: no em or en dashes, no curly quotes.
- Dates people read as `18 Oct 2026`, times as `2:30 PM`. Machine formats stay ISO.
- No comparisons with other products. Name other tools only as facts.
- Agents recommend; the owner signs off. Never write as if an agent shipped, merged or published.
- The words: **owner** (not user, admin or boss), **role** (not bot or persona), **handoff** (not ticket or message), **sign-off queue** (not inbox or approvals), **brief** (not report), **guardrails** (not restrictions or blocks).

## 10. Where it goes

| Place | Form | File | Status |
|---|---|---|---|
| README, on GitHub and npm | The tile, 96px, above the title | `logo.svg` (also `docs/logo.svg`) | Approved |
| Terminal (`cabinet version`) | The mark in text: 7 lines, 13 columns, `⬤` (large dots) or `o` without UTF-8 | (printed by the kit) | Approved |
| Favicon | The plain mark, light seats when the browser is dark | `favicon.svg`; `favicon-16/32/48.png` (the tile, for browsers without SVG favicons) | Approved |
| Brief and sign-off queue | The outlined mark | `mark-outlined.svg` | Approved |
| Website or docs header | The plain mark or the side-by-side lockup, with the hover | `mark.svg`, `lockup.svg` | Approved |
| Social preview, 1280 x 640 | Paper, the mark, the name, the tagline | `social-preview.png`, `.svg` | Draft |
| App icon and avatar | The dark tile with the outline, or the light tile plain | `app-icon.svg`, `app-icon-192/512.png`, `apple-touch-icon.png`, `app-icon-light.svg` | Draft |
| Slides | Night, light seats; the outline on a title slide about the owner | `mark-light.svg`, `mark-outlined-light.svg` | Draft |
| Sticker and print | One color on ink or paper, no brass | `mark.svg`, `mark-light.svg` | Draft |
| Intros, end cards, launch screens, onboarding | The logo in motion, once; a variant for its own use | (drawn in code, as in `index.html` and `motion.html`) | Draft |
| Promo film, 32 s, 1920 x 1080 | Night; the logo animation, the team at work, the brief, the guardrails; ends on the lockup and the tagline | `promo/cabinet-promo.mp4` (ends on the address, for sharing), `promo/cabinet-promo-facts.mp4` (ends on what Cabinet is, for the README and the website), and `.webm` of each | Draft |
| Demo film, 94 s, 1920 x 1080 | Night; seven chapters with cards, real commands in a terminal; ends on the logo animation, where to start and the address | `demo/cabinet-demo.mp4`, `.webm` | Draft |
| Loading, in an app or a page | The mark, its seats lit in turn | (drawn in code, as in `index.html`) | Draft |
| Animation, onboarding, posters | The chairs | `chairs.svg`, `chairs-light.svg`, `chairs-owner-light.svg` | Approved |

## 11. Don'ts

- **(Approved)** Don't turn it: the open place is always on the right.
- **(Approved)** Don't fill the open place with a seat, a dot or a symbol; only the owner's brass outline.
- **(Approved)** Don't stretch it; scale it evenly.
- **(Approved)** Don't add seats: eight places, always.
- **(Draft)** Don't use brass anywhere else: not the seats, the name, buttons or links. (The one exception is the "Echo" animation, where the owner's own outline travels out.)
- **(Draft)** Don't put it on a busy background: paper, white, night or the tile.
- **(Approved)** Don't put a table in the logo.
- **(Draft)** Don't add effects: no gradients, shadows, glows or 3D.
- **(Approved)** Don't use the chairs as the logo.

## Files in `brand/assets/`

| File | Use |
|---|---|
| `mark.svg`, `mark-light.svg` | The mark, dark seats and light seats. |
| `mark-outlined.svg`, `mark-outlined-light.svg` | The mark with the owner's open seat in brass. |
| `logo.svg` | The mark on its light tile (the README logo). |
| `wordmark.svg`, `wordmark-light.svg` | The name, as outlines. |
| `lockup.svg`, `lockup-light.svg` | The mark and the name side by side. |
| `lockup-stacked.svg`, `lockup-stacked-light.svg` | The mark over the name. |
| `favicon.svg`, `favicon-16.png`, `favicon-32.png`, `favicon-48.png` | Favicons. |
| `app-icon.svg`, `app-icon-light.svg`, `app-icon-192.png`, `app-icon-512.png`, `apple-touch-icon.svg`, `apple-touch-icon.png` | App icons and avatars. |
| `chairs.svg`, `chairs-light.svg`, `chairs-owner-light.svg` | The chairs illustration. |
| `social-preview.svg`, `social-preview.png` | The social preview, 1280 x 640. |

To change a color or the geometry, edit `tokens.json`, then run `npm run brand` (macOS) and update this file and `index.html`. `npm test` fails when a file is out of date.

The name and the tagline are outlines kept in `text-paths.json`, drawn once from Schibsted Grotesk with its kerning. Changing the name, the tagline or the font means redrawing them with a font shaping tool; the kit has none, so it needs no font tools to build.
