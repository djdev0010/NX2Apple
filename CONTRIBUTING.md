# Contributing

Issues and pull requests are welcome. NX2Apple is the launcher (`frontend/`, `frontend-qt/`) and the glue around the [nxnative](https://github.com/seedds/nxnative) engine, which is vendored here and synced from upstream every day. [AGENTS.md](AGENTS.md) describes the engine.

## Where an issue goes

- **Here:** the app, a build or install that fails, and a game that does not run well on your Mac or iPhone or iPad.
- **[seedds/nxnative](https://github.com/seedds/nxnative/issues):** how the engine works, porting a new game, a rendering fault you have traced into the engine itself.

## What a report needs

Pick a form: **Game problem**, **Build problem** or **Launcher problem or idea**. Each asks for what the problem is traced with: the game, its title ID and versions, the target, the device and OS, the NX2Apple version, **Settings > Copy diagnostics**, and the log (a game's log, or the Build log on the Builds page). A report without them gets a request for them first. Where a game's log is: a Mac game in a library folder writes `log/<title ID>.log` beside its app, otherwise `~/Library/Logs/nxnative/<title ID>.log`; on an iPhone or iPad it is `log.txt` in the Files app.

**Never attach keys, game files or anything extracted from a game.** Logs, screenshots, title IDs and build IDs are fine.

## A pull request

- One change per PR, off `main`. Commit messages say what changed and why, in plain English, as `git log` does.
- Fill in the PR template: what and why, what was checked, screenshots for UI changes.
- **`frontend/` and `frontend-qt/` are the fork's own:** change them freely. Run `cd frontend && swift test`; for a UI change also capture the views for visual QA (`NX_LAUNCHER_CAPTURE_DIR`, see [frontend/README.md](frontend/README.md#verification)).
- **`dm/`, `scripts/`, `docs/`, `ref/` and `AGENTS.md` are vendored from upstream.** The daily sync takes them file by file, so an edit there is reverted the next time upstream touches the file. The `pr-scope` check fails a PR that edits one. Send the change to seedds/nxnative first (it comes back with the sync), or ask a maintainer to add a patcher in `scripts/sync_upstream.py`. Files under `.github/` and in the repository root that are not in that list (this file, `CLAUDE.md`, the README) are the fork's.

## For AI agents and other tools

Issue forms and the PR template apply in the browser only. `gh issue create`, the API and MCP tools skip the forms, so follow them yourself:

- **Issues.** Write the body as `###` headings with the same names as the form's fields (for example `### Game, title ID and versions`, `### Copy diagnostics`, `### The game's log`) and fill every required field from [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE). Ask the user for what you cannot read yourself: the Copy diagnostics output, the log, the versions. If a required field is missing, do not open the issue.
- **Pull requests.** Use the sections of [.github/pull_request_template.md](.github/pull_request_template.md): `gh pr create --template .github/pull_request_template.md`, or the same headings in `--body`. A change to a vendored path follows the rule above.
- Never attach or commit keys, game files or data extracted from a game, and do not paste key values into a log or a diagnostics report.
