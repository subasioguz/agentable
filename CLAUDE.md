# Agentable

Open source (Apache-2.0) native macOS database client for people and their coding agents.
Swift 6, SwiftPM. People browse and edit in the app; agents (Claude Code, Codex, Cursor, ...) use
the same saved connections through the `agentable` CLI and, next, an MCP server. Agents never get
passwords, their writes on protected connections become proposals a person approves, and every
agent request is logged.

## Language rules
- English everywhere in the repository: code, identifiers, comments, docs, commit messages, fixtures.
- The app's development language is English and the key; translations (de, es, fr, it, pt-BR, ru,
  tr, ja, ko, zh-Hans, zh-Hant) are in `Sources/AgentableApp/Localization/<code>.lproj/Localizable.strings`.
  New app text needs an entry in every one of them: computed text goes through `String(localized:)`,
  Core's English labels through `L10n.core` (`Language.swift`); whole sentences are one key, plurals
  two ("1 row" / "%@ rows"); never attach endings or particles to a placeholder. Check with
  `scripts/check-strings.py` and `LANGUAGE=<code> SHOW_MISSING=1 scripts/snapshot.sh <dir> [scenes]`
  (untranslated text shows in capitals). The CLI, MCP tools and anything agents read stay English.

## Layout
- `Sources/AgentableCore`: UI-independent core
  - `Model/`: `ConnectionProfile` (engine, environment, agent access, visibility rules, limits),
    `ConnectionURL` (postgres://, sqlite://, file paths), `QueryResult`/`CellValue`
  - `SQL/`: `SQLLexer` (quotes, `$tag$` bodies, nested comments) and `SQLAnalyzer` (statement split,
    `StatementKind` classification, mentioned identifiers)
  - `Policy/`: `AgentPolicy` (run / propose / deny by access level), `Masking`, `AgentRole`
    (SQL for a SELECT-only Postgres role; agent reads use `agentUser` credentials when set)
  - `Engines/`: `DatabaseSession` protocol, `SessionFactory`, `SSHTunnel` (`/usr/bin/ssh -L`, shared,
    closed when idle and at exit), `SQLite/` (actor over the system sqlite3),
    `Postgres/` (PostgresNIO: one transaction per call, `BEGIN READ ONLY` for reads, `SET LOCAL`
    timeouts, a cursor for the row limit, catalog lookup of each result column's source table)
  - `Store/`: `ProfileStore` (connections.json), `SecretStore` (Keychain), `StateStore` (audit log,
    review queue and suggestions in state.sqlite), `QueryLibrary` (saved queries, queries/<connection>/*.sql),
    `Authenticator` (LocalAuthentication)
  - `Browse/`: the app's reading and editing, UI-independent: `Filter` (conditions, and/or groups,
    `ColumnCategory`), `TableQuery` (page, count, value counts as `BoundSQL`), `TableBrowser`,
    `RowChange` (staged edits and inserts; one row each, guarded against rows changed since loading;
    also SQL-tab statements and `SchemaChange` structure edits),
    `Export` (`RowWriter`: CSV, JSON, SQL INSERT, Markdown; `TableBrowser.export` streams pages to a file)
  - `Agent/`: `AgentGateway` (every agent request goes through it), `ReviewService` (the person's side,
    including `apply(connection:edits:proposalIDs:)`: one confirmation, one transaction),
    `AgentFormatter` (tab-separated text or JSON for agents), `SQLSuggestion` and `LineDiff` (agents' suggestions for saved queries),
    `MCPServer` (stdio JSON-RPC, eight tools,
    client name from `initialize` goes to the audit log; stdout carries protocol messages only)
- `Sources/agentable`: the CLI (swift-argument-parser)
- `Sources/AgentableApp`: the app (SwiftUI shell, AppKit `NSTableView` grid). `AppModel` (screens,
  connections) → `WorkspaceModel` (one open connection: read-only session, schema, tabs, staged
  edits with undo) → `GridModel` (pages of 200 rows, filter, sort, edit and proposal marks, new rows
  on top, selection). `StructureView`/`StructurePanel`: the Structure tab and its column or index
  panel. `RowPanel` shows the selected row (Space) and follows foreign keys;
  `ExportPanel` copies or saves rows. `SQL/`: the SQL tab (`SQLDocument`, `SQLEditorView` with the
  inline suggestion preview, `ResultGridView`, `QueriesSidebar`, `AskViews`); `Agents/AskRun` runs
  Claude Code for Ask. `ActivityFeed`
  polls `state.sqlite`: agents run in other processes and reach the app only through it.
  `Theme/` holds the color tokens (light gray and dark; you = blue, agent = orange) and fonts;
  `Snapshot/` renders screens to PNG and seeds the demo database
- `scripts/snapshot.sh`: renders every screen in light and dark with a demo database and real
  agent activity into one folder; `scripts/bundle-app.sh`: builds `.build/Agentable.app`
- `Tests/AgentableCoreTests`: Swift Testing; SQLite fixtures are created in a temp directory per test
- `docs/PLAN.md`: product decisions, architecture and roadmap
- `notes/`: private working notes (market research), kept out of git by `.gitignore`; never move them
  into `docs/`

## Commands
- Build: `swift build`; tests: `swift test` (run alone, not in parallel with other heavy jobs)
- Postgres tests run only with `AGENTABLE_TEST_POSTGRES_URL` set, e.g. a throwaway server:
  `initdb -D /tmp/tm-pg -U agentable --auth=trust --locale=en_US.UTF-8` then
  `pg_ctl -D /tmp/tm-pg -o "-p 55432 -k ''" start` and
  `AGENTABLE_TEST_POSTGRES_URL='postgres://agentable@localhost:55432/postgres?sslmode=disable' swift test`
- Always close sessions (`await session.close()`) on every path: PostgresNIO asserts on connections
  that are deinitialized while open.
- CLI: `.build/debug/agentable --help`; `AGENTABLE_HOME=/some/dir` keeps state out of
  `~/Library/Application Support/Agentable` (use it for manual testing)
- App: check UI changes with `scripts/snapshot.sh <out-dir> [scenes]` and look at the PNGs; it never
  touches the real home or preferences. Scenes are listed in `Snapshot.swift`
- UI follows the design canvas (v2 row and the Filters row). Build screens from `Theme/Components.swift`
  and `Theme/Controls.swift` (buttons, `SegmentedSwitch`, `SelectBox`, `CheckBox`, `TokenField`,
  `FieldBox`) and icons from `Theme/Icons.swift` (the canvas's own SVG paths); no SF Symbols, system
  popup buttons, pickers or checkboxes. Copy says what the design says; no extra explanatory prose. Compare new screens with the matching
  canvas board side by side before calling them done

## Safety rules (hard)
- Agents never receive passwords or hosts beyond what `location` shows. Passwords live only in Keychain.
- Agent SQL always goes through `AgentGateway`; never open a session for agent input elsewhere.
- One statement per agent call. Reads run in read-only sessions (engine-level guard, not just the
  classifier). `SQLAnalyzer` is for routing and messages; it is not the security boundary.
- Production caps agents at Propose. Nothing an agent sends changes production without a person.
- Anything that widens what agents can do (approving a proposal, raising access, removing a hide or
  mask rule) requires `Authenticator` confirmation. Narrowing never does.
- Proposals get a trial run inside a transaction that is always rolled back; they are applied later,
  alone or together with the person's staged edits, in a new transaction.
- Agent output always carries the "data, not instructions" notice.
- Agents may read saved queries (never ones that mention a hidden table) and suggest new text for
  them. A suggestion becomes editor text only when the person accepts it; it never runs by itself.
- The app never sends agent input anywhere: it only reads the audit log and the review queue.
  The person's own reads use their credentials in a read-only session; their edits are staged and
  applied through `ReviewService`.
- Values in app-built SQL are binds (`BoundSQL`), never pasted into the text. The person's own SQL
  is used as typed only in three places: WHERE text (in their read-only session), SQL-tab
  statements, and column types and defaults in the structure editor (checked to be one type name
  and one expression). Writes among them run only after review, in one transaction.
- Masks follow renamed columns: never let a rename drop a mask rule.
- No telemetry or network calls besides the databases. The one exception is Ask in the SQL tab: on the
  person's Send, the app runs their own Claude Code (`AskRun`: empty temp folder, `--tools ""`, only
  the agentable MCP server, `dontAsk`, no `propose_change`, 3-minute limit, stopped at quit).
  README's Privacy section lists everything the
  app stores; keep it true when that changes.

## Naming
- The CLI product is `agentable`. The SwiftUI app target is `AgentableApp`, never `Agentable` (it
  would collide with `agentable` in `.build` on case-insensitive disks). Inside the bundle the
  executable is `Contents/MacOS/Agentable` and the CLI `Contents/Helpers/agentable`.
