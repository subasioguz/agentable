# Brand

Agentable is a native macOS database client where you and your coding agents work in the same
table.

## Voice

1. **Say what happens.** Describe the result in plain words, not the feature.
   - Do: "They apply together in one transaction. Nothing is written until you apply."
   - Don't: "Seamlessly sync every change with powerful one-click transactions."
2. **State facts, make no promises.** If it cannot be checked, leave it out. No hype words.
   - Do: "Agents never see your passwords. They stay in your Keychain."
   - Don't: "Bank-grade, AI-proof security for the agent era."
3. **Name who acts.** "You" is the person; an agent is called by its name or "the agent". Agents
   are tools: they read, propose and get refused; they don't think, help or get excited.
   - Do: "Claude Code wants to change 2 rows in orders."
   - Don't: "Your AI teammate has some great ideas for your data!"

## Color

| Token  | Light     | Dark      | Use                                   |
|--------|-----------|-----------|---------------------------------------|
| you    | `#2F5BFF` | `#86A2FF` | the person: selection, edits          |
| agent  | `#F0561D` | `#FF7A45` | agents: cursor, proposals, activity   |
| text   | `#16181D` | `#ECEDEF` | text, primary buttons                 |
| window | `#FCFCFD` | `#141518` | content background                    |
| side   | `#F3F4F6` | `#18191D` | sidebars, rails                       |
| line   | `#E2E4E9` | `#2A2C31` | rules, borders                        |

The full set, including tints and status colors, is in
`Sources/AgentableApp/Theme/Palette.swift`. The interface is neutral cool gray; color is for
meaning, not decoration.

### You are blue, the agent is orange

Blue always means the person and orange always means an agent: your selection and staged edits
are blue; an agent's cursor, the rows it wants to change and its proposed values (in dashed boxes)
are orange. Don't use either color as a generic accent. Buttons are ink, and status (ok, warning,
error, production) has its own tokens.

## Typography

- **Instrument Sans** for interface text and the wordmark (SemiBold).
- **Spline Sans Mono** for data: cell values, SQL, table and column names, CLI output.

Both are under the SIL Open Font License and ship inside the app
(`Sources/AgentableApp/Resources/Fonts`); nothing is fetched to draw text.

## Logo

The mark is the app icon without the shadow under its tile: a cobalt tile in the ODBS house look, a
diagonal gradient from `#7394FF` through `#2F5BFF` (the "you" blue) to `#1A34C4` with soft light
from the top left, and a white table on it: a header bar over four cells, with a soft shadow in a
deep shade of the tile. The bottom-right cell is orange: the agent's cell, a change it proposed
that waits for you.

| File | Use |
|------|-----|
| `docs/brand/mark.svg` | the mark on its own (tile and table, no shadow under the tile) |
| `docs/brand/wordmark.svg`, `wordmark-dark.svg` | mark and name, on light and on dark backgrounds |
| `docs/brand/icon.svg`, `icon-small.svg`, `icon-1024.png` | app icon artwork (macOS grid, with shadow) |
| `Sources/AgentableApp/Resources/AppIcon.icns` | the app icon, built with `iconutil` |

The icon's 16 and 32 px sizes (and their @2x) use `icon-small.svg`, which draws the header bar
over one row of two cells, a white one and the orange one, with wider gaps so they stay apart.
Larger sizes use `icon.svg`.

- **Clear space:** keep at least a quarter of the mark's height free on every side.
- **Minimum size:** mark 16 px; wordmark 24 px tall. Below that, use the mark alone.
- The name is set in Instrument Sans SemiBold and is outlined in the wordmark files. Write it as
  "Agentable" in text; the CLI is `agentable`.

Don't:

- recolor the tile or the table, or make the orange cell blue; there is one orange cell and it
  stays bottom right;
- add cells, rows, text or other shapes to the table;
- take the table off its tile or put it on another background;
- stretch, rotate or crop the mark, or retype the wordmark in another font;
- pair the mark with robots, sparkles, brains or database cylinders.
