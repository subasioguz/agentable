# Plan

## Product

One app, two doors to the same connections:

- **People** browse, filter, edit and review in a native macOS app (SwiftUI shell, AppKit grid).
- **Agents** use the `agentable` CLI and an MCP server. They address connections by name, never see
  passwords, get compact results marked as data, and route writes through the review queue.

People and agents work in the same place: agent reads, highlights and proposals show up in the
table the person is looking at, and the person's edits and the agent's proposals go through one
review step.

## Decisions

- Open source, Apache-2.0, copyright Oğuzhan Subaşı.
- Native Swift: SwiftPM package, macOS first. Core, CLI and MCP server share one Swift module.
- Engines: SQLite (done), PostgreSQL (next, PostgresNIO), MySQL after that.
- Filters in the app: chips with a value picker for daily use, "Advanced" condition rows (and/or,
  groups) for complex cases, a WHERE editor for SQL users. Typing filters as text comes later (⌘F).
- Visual direction: neutral gray light theme by default, dark theme, you = blue, agent = orange.

## Safety model

Layered, so a bug in one layer is not a breach:

1. Database role: agents can run as a SELECT-only role (Postgres milestone adds a setup helper).
2. Engine-level read-only sessions (SQLite: read-only open, `query_only`, `sqlite3_stmt_readonly`;
   Postgres: `BEGIN READ ONLY`, extended protocol so one statement per call, `statement_timeout`).
3. `AgentPolicy`: one statement per call, access levels, hidden tables, production capped at propose.
4. Masking of configured columns, including computed columns that mention them.
5. Proposals: trial run in a rolled-back transaction, applied only after device-owner authentication.
6. Audit log of every agent request, including denials.

Known limits: the classifier reads text, so side-effecting functions inside a `SELECT` are only
stopped by layers 1 and 2. Hidden-table checks match names, so they can refuse a query that merely
mentions a column with the same name.

## Roadmap

1. **Core + CLI** (done): profiles, Keychain, SQL analysis, policy, masking, SQLite engine, audit
   log, proposals and review, CLI.
2. **PostgreSQL** (session done): PostgresNIO session with read-only transactions, cursors for row
   limits, server-side timeouts, source-column masking and the `agent_ro` role helper with
   separate agent credentials (done). SSH tunnels go through the system's OpenSSH (see 5). Still to
   do: text rendering for less common types (interval, inet, arrays).
3. **MCP server** (done): `agentable mcp` over stdio with six tools, eight since step 5 (connections, schema_search,
   describe, query, explain, propose_change); `agentable init` prints agent setup. Writing agent
   configs directly belongs to the app's first-launch flow.
4. **App MVP** (first version built): connections and first launch (agent setup through each
   agent's own `mcp add`), schema rail, paged NSTableView grid, chip filters with value counts,
   Advanced condition rows and WHERE, staged edits with a stale-row guard, Review & apply in one
   transaction with one Touch ID for proposals, proposal previews in the grid (trial run rows via
   `RETURNING`), agent notes under the rows they change, a read-only Structure tab, session panel
   and live agent cursor from the audit log. Shared controls (select box, checkbox, token field,
   segmented track) keep every screen on the design system; no system popup buttons. Not in it: an in-app
   assistant ("Ask" box, open decision), agent highlights and draft views (need a new MCP tool),
   per-environment default access settings.
5. **Parity and polish**, in the order the November 2026 market research suggested:
   - Copy and export (done): right click copies rows as CSV, JSON, SQL INSERT or Markdown; the
     Export panel copies or saves the selection, the filtered view or the whole table, a page at a
     time on the person's read-only session, with a preview of the first lines. Decimals keep their
     column's scale.
   - New rows and undo (done): ⌘I adds a row on top of the grid (empty cells read required, default
     or NULL), Duplicate copies rows without their keys and generated values, and inserts save
     through the same staged path (`RowChange.insert`, one transaction, production shows the SQL
     first). The pending bar opens into a list of your changes with undo on each; ⌘Z and redo step
     through staged changes until they are saved. Multi-row delete and duplicate act on the selection.
   - Row details and foreign keys (done): Space opens the selected row in place of the session panel
     (wrapped text, indented JSON, edit by double-click); a foreign key cell or the panel's link opens
     the referenced row filtered as a chip, with a way back; "Referenced by" counts the rows of other
     tables pointing at it (`DatabaseSession.references(to:)`, single-column keys).
   - Table layouts (done): each connection's tables remember their sort, column order, hidden
     columns and changed widths (`TableLayout`, kept in user defaults); filters and search are not
     remembered (saved views will cover that). Columns has "Reset layout"; Settings has the default
     order, oldest or newest first by primary key, shown as a sort arrow.
   - SQL tab (done): `SQLDocument` per table, an `NSTextView` editor colored by the SQL lexer
     (`SQLAnalyzer.spans`), line numbers and completion of columns of the tables in the query,
     tables and keywords (aliases resolved). ⌘↩ runs the statement under the cursor
     (`statement(at:)`): reads on the person's read-only session, logged as "you"; writes and DDL get
     a rolled-back trial (`ReviewService.trial`) and wait as `RowChange.sql` with the other staged
     changes. Explain (EXPLAIN / EXPLAIN QUERY PLAN), Format, results capped at 1,000 rows with copy
     and export, messages. The side panel lists saved `.sql` files (queries/<connection>, autosaved)
     and recent statements from the audit log.
   - SSH tunnels and TLS files (done): `SSHSettings` on the profile; `SSHTunnels` runs
     `/usr/bin/ssh -N -L` with BatchMode and StrictHostKeyChecking=yes (keys and agent only, unknown
     hosts refused with a "connect once in Terminal" message), shares a tunnel between sessions and
     closes it 30 s after the last one (and at exit). Values that look like options are refused.
     TLS takes a CA file and a client certificate and key; through a tunnel, TLS still checks the
     real host name. The app and agents (CLI, MCP) use the same tunnel code; agents never see SSH
     settings. Not yet: CLI flags for SSH, a test against a real SSH server in CI.
   - Structure editor (done): the Structure tab follows board 6. `SchemaChange` (add, alter, drop
     column; add, drop index) waits as `RowChange.schema` with the other staged edits and runs in
     the same transaction; PostgreSQL and SQLite both roll DDL back, so a failed batch changes
     nothing. Names are quoted; types and defaults are the person's own SQL, checked to be a plain
     type name and a single expression. A type change adds `USING col::type` and drops a replaced
     default first. SQLite renames saved columns only (type, default and empty values would need a
     table rebuild). No automatic trial run for DDL: on a large production table the trial itself
     would rewrite the table or build the index. Production shows each statement with its lock
     level before it runs. `describe` now reads checks, identity columns, index method, size and
     scans, and the views that use each column (PostgreSQL). The side panel edits a column (Name,
     Type, Default, Allows empty) and shows allowed values from checks, the most common values and
     what uses the column; new indexes pick columns and uniqueness. Masks follow renamed columns:
     `ReviewService.apply` masks the new name before the rename runs. Agents' `CREATE INDEX`
     proposals show in the index list with their reason.
   - Agent suggestions in the SQL tab (done, board 7): two MCP tools, `saved_queries` (list, or
     read one; queries that mention a hidden table are refused) and `suggest_sql` (new text and a
     note for a saved query, or a new name), with the CLI's `queries` and `suggest`. Suggestions live
     in state.sqlite (`SQLSuggestion`; a newer one for the same query replaces the waiting one) and
     every read and suggestion is in the audit log. The editor shows the change in place
     (`LineDiff`): added lines tinted with "+" in the gutter, removed ones struck through, the
     agent's note in a card under the first change; Tab accepts as one undoable edit, Esc dismisses,
     and both are logged as "you". Nothing runs on accept. A suggestion made for an older text says
     so. The sidebar marks queries with a waiting suggestion, and new ones; the header says
     "claude-code is editing with you"; Session lists suggestions with an Open button.
   - Ask (done, boards 13–14): ⌘I opens a box for a request, with quick ones (faster, explain the
     plan, check for mistakes); an unsaved query is saved first. Send runs the person's Claude Code
     (`AskRun`): `claude -p` in an empty temp folder, `--tools ""`, `--strict-mcp-config` with only
     the agentable server, the read and suggest tools allowed, `propose_change` refused, `dontAsk`,
     stream-json read for progress ("read charged-twice.sql · ran a query…"), Stop, 3 minutes at most,
     stopped at quit. A change lands as a suggestion; an answer shows in the card above the editor.
     The request is logged as "you asked claude-code: …". This is the one place the app starts a
     network-using program, so README Privacy says so. Not yet: Codex (`codex exec`), not installed
     here to test. An earlier try that only copied a prompt to paste was dropped as pointless.
   - Connect agents any time (done): the first-launch agents card (`AgentsCard`) also opens from
     the Connections screen's header and the settings menu, as a card over the window.
   - Pages (done, board 15; after looking at TablePlus, DataGrip, Beekeeper, DBeaver, Sequel Ace and
     TablePro, which nearly all page): the grid shows one page (`GridModel.page`, `rowsPerPage`: 10 / 50 /
     100 / 200 / 500 / 1,000 or any typed size up to 10,000, remembered) over the same 200-row chunks; a bar under the table shows the
     range and total ("~" when estimated), ‹ › with ⌘[ ⌘], and a page button that opens jump to page,
     rows per page and Count exactly. An estimate never blocks Next. Filter, search and sort go back
     to page 1; saving keeps the page.
   - Renamed to Agentable (2026-11-19, was Tablemate): app, CLI `agentable`, MCP server
     `agentable`, `AGENTABLE_*` variables, bundle `dev.agentable.app`. The old Application Support
     folder, Keychain items (`dev.tablemate.connection`) and preferences move over on first use;
     connection paths inside the old folder are rewritten. The wordmark SVGs are redrawn, and the
     repository is `agentable`. Still to do: the canvas text (board 13 still says Tablemate).
   - Localization (2026-11-19): English plus German, Spanish, French, Italian, Brazilian
     Portuguese, Russian, Turkish, Japanese, Korean, Simplified and Traditional Chinese, in
     `Sources/AgentableApp/Localization/<code>.lproj/Localizable.strings` (excluded from SwiftPM;
     `bundle-app.sh` copies them into the bundle and lists them in `CFBundleLocalizations`). English
     is the development language and the key, so `en.lproj` holds no entries. The settings menu has
     Language (Match the system, then each language by its own name): it sets `AppleLanguages` for
     the app and offers a restart; a Mac in another language gets English. `Language.swift` holds
     `AppLanguage` (the list, names and regions) and `L10n`: numbers, times, short counts and upper
     case follow the interface language (`L10n.locale`, also the root view's locale), and
     `L10n.core` translates the English labels AgentableCore builds (filter operators, default
     order), with the English text as the key. Core's composed text (filter sentences, schema change
     titles, lock notes, change summaries) is rebuilt in the app (`FilterText`, `ChangeText.swift`).
     Rules: whole sentences are one key, plurals are two keys ("1 row" / "%@ rows"; languages whose
     form depends on the number use "noun: %@"), endings and particles go on a noun, never on a
     name. `scripts/check-strings.py` checks every language has every key with the right format
     specifiers; `LANGUAGE=<code> SHOW_MISSING=1 scripts/snapshot.sh <dir> [scenes]` renders a
     language (untranslated text in capitals). Turkish was checked on every scene, the others on the
     tightest ones. The CLI, MCP tools, the Ask prompt and anything stored in state.sqlite stay
     English. Not yet: right-to-left languages (Arabic, Hebrew) need mirrored layouts; error text
     from the databases and AgentableCore (`DatabaseError`) stays English in every language.
   - Next: cancelling a running query, a real SQL formatter, saved views ("Open as view"), history
     with undo, import from other clients.
   - Later from the same research: XLSX export, agent insert proposals shown as new rows,
     following multi-column foreign keys. For structure: `CREATE INDEX CONCURRENTLY` (it can't run
     inside the apply transaction), table rebuilds for SQLite type changes, foreign keys and checks
     in the editor, and carrying masks over when an agent's own DDL proposal renames a masked column.
6. **Release**: the repository is public (2026-11-21). `scripts/release.sh <version>` builds for
   Apple silicon and Intel, signs the app and its CLI with Developer ID (hardened runtime, no
   entitlements needed), notarizes, staples and zips it for GitHub Releases. The first one is
   v0.1.0 (pre-release, 2026-11-23). Still to do: Sparkle updates, a Homebrew cask, a test of the
   Intel build on an Intel Mac.

## Research notes (November 2026)

- Agent-facing database clients exist (DataGrip 2026.2 agent skills and MCP tools, Tabularis and
  DBX with built-in MCP servers, Beekeeper's AI shell). None combines credential isolation,
  per-connection policy, a shared review queue and an audit log in one native app.
- Read-only flags alone have been bypassed in MCP servers (multi-statement tricks); the database
  role is the real guarantee.
- MCP tool definitions cost context on every turn; keep the tool set small and outputs compact.
- TablePro, DBX and Beekeeper are GPL/AGPL: no code is taken from them.
