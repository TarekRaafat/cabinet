# cabinet brand

The rules for the cabinet mark, name, color, type and words, written for people and for agents. This file is the source of truth; when it and anything else disagree, this file wins.

| File | What it is |
|---|---|
| `brand/BRAND.md` | These rules, each with its status. |
| `brand/tokens.json` | The same decisions as data: colors, status colors, fonts, the mark's geometry, motion. |
| `brand/assets/` | Every logo file, built from `tokens.json` by `tools/build-brand.py`. Never edit one by hand. |
| `brand/index.html` | The visual guide: every rule shown, for people. Open it in a browser. |

To give a project's agents these rules, copy this file to the workspace's `guides/brand.md` and add a row for it in the "Guides" table in `AGENTS.md`.

**Status.** Each rule is marked:

- **Approved:** the owner decided it. Follow it.
- **Draft:** proposed, not reviewed yet. Follow it too, but before anything public relies on a draft rule, ask the owner.

## 1. The idea (Approved)

- The mark is a table seen from above: eight places in a ring.
- Seven places are filled. They are the agents, each deciding within its own authority.
- The eighth place, on the right, is left open. It belongs to the owner, who signs off on what is irreversible, public or costs money. The gap is also what turns the ring into a C.

## 2. The mark

- **(Approved)** One mark for every size, from 16px up: eight places every 45 degrees on a ring of radius 36 units, seats 19 units wide, on a 100 unit grid, the place at 0 degrees (right) left open. There is no simplified small version.
- **(Approved)** One color: dark seats (ink) on light backgrounds, light seats (mist) on dark ones.
- **(Approved)** On its own light tile (paper, corner radius 22 units, the mark at 66%) where the page can be light or dark and you cannot choose the file, such as a README. No border.
- **(Draft)** Clear space: one seat's width on every side. Nothing else enters it, including the name.

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
- In motion: start and end on the mark; nothing turns, so the open place stays on the right; the open place is never taken by an agent's chair, only the owner's brass outline appears there; with reduced motion show the last frame.
- **(Draft)** Timing: each step 400 to 800 ms, eased in and out, no bounce. The sequence: the mark; each dot turns into a chair, counterclockwise from the top; the brass chair fades in last; back to the mark, the name may follow.

## 5. The table (Approved)

- For pictures that explain the idea (the guide's first picture, onboarding, an explainer video, a slide about the team, the chairs), never in the mark itself: not the logo, favicon, app icon, README, wordmark or terminal.
- Always faint: the seats' color at 12%, never brass, well inside the ring.

## 6. The name (Draft)

- Always `cabinet`, in lowercase, also at the start of a sentence, the way the command is typed. Never "Cabinet", "CABINET" or "the Cabinet kit".
- The wordmark is the name in Schibsted Grotesk Bold, tracked -0.035em, as outlines (`wordmark.svg`), so it never depends on the font.
- Side by side (`lockup.svg`): the mark 1.1 times the type size, 0.32 of the type size from the name, centered on the name's height. Stacked (`lockup-stacked.svg`): the mark 2.25 times the type size over the name, for square spaces.

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

cabinet sounds like a capable chief of staff: plain, short, specific, and always clear about who decides.

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
| Terminal (`cabinet version`) | The mark in text: 7 lines, 13 columns, `●` or `o` without UTF-8 | (printed by the kit) | Approved |
| Favicon | The plain mark, light seats when the browser is dark | `favicon.svg`; `favicon-16/32/48.png` (the tile, for browsers without SVG favicons) | Approved |
| Brief and sign-off queue | The outlined mark | `mark-outlined.svg` | Approved |
| Website or docs header | The plain mark or the side-by-side lockup, with the hover | `mark.svg`, `lockup.svg` | Approved |
| Social preview, 1280 x 640 | Paper, the mark, the name, the tagline | `social-preview.png`, `.svg` | Draft |
| App icon and avatar | The dark tile with the outline, or the light tile plain | `app-icon.svg`, `app-icon-192/512.png`, `apple-touch-icon.png`, `app-icon-light.svg` | Draft |
| Slides | Night, light seats; the outline on a title slide about the owner | `mark-light.svg`, `mark-outlined-light.svg` | Draft |
| Sticker and print | One color on ink or paper, no brass | `mark.svg`, `mark-light.svg` | Draft |
| Animation, onboarding, posters | The chairs | `chairs.svg`, `chairs-light.svg`, `chairs-owner-light.svg` | Approved |

## 11. Don'ts

- **(Approved)** Don't turn it: the open place is always on the right.
- **(Approved)** Don't fill the open place with a seat, a dot or a symbol; only the owner's brass outline.
- **(Approved)** Don't stretch it; scale it evenly.
- **(Approved)** Don't add seats: eight places, always.
- **(Draft)** Don't use brass anywhere else: not the seats, the name, buttons or links.
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

To change a color or the geometry, edit `tokens.json`, then run `python3 tools/build-brand.py --png` (macOS) and update this file and `index.html`. `npm test` fails when a file is out of date.
