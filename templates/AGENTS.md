<!-- auto-run.nvim managed file: rewritten whenever a newer auto-run.nvim writes into this folder. Put project notes in AGENTS.local.md, which auto-run never touches. -->
# AGENTS.md — scaffolding auto-run.nvim configs

**Written by auto-run.nvim v{{version}}.** The empty file `auto-run.nvim-v{{version}}`
beside this one records that version. auto-run rewrites this file when a newer
release writes into the folder, so don't edit it. **Read `AGENTS.local.md` too,
if it exists**: that's where this project's own notes live.

auto-run.nvim is **declarative**. Once the configs exist, running, testing and
debugging need no agent: the user drives them from the panes and keys in
[§8](#8-doing-it-by-hand-no-agent). An agent's job here is the **first
scaffold**:
1. read the project;
2. write the configs and env files;
3. check them;
4. hand over.

## 1. First-time scaffolding — the procedure

1. **Find the projects.** Look for folders holding a project marker:

   | Marker | Runtime |
   |---|---|
   | `go.mod` | `go` |
   | `Cargo.toml` | `rust` |
   | `package.json` | `node` (programs and scripts), with `jest` / `playwright` for its tests |
   | `pubspec.yaml` | `dart` (Dart and Flutter) |

   A project in a sub-folder gets `cwd` set to that folder in each of its
   configs.
2. **Find the entry points.**
   - Go: `package main` directories (`cmd/<name>`).
   - Rust: the package's `bin` targets.
   - Node: the `scripts` in `package.json` (`dev`, `start`, …) or an entry
     file.
   - Dart: `bin/<name>.dart`.
   - Flutter: `lib/main.dart`, run on a desktop device.
3. **Find the environment each one reads.** Search for `os.Getenv`,
   `std::env::var`, `process.env`, `Platform.environment` and
   `String.fromEnvironment` (Flutter: passed with `--dart-define`), and read
   the README. Note which variables are required.
4. **Write the env file** for what several programs share, and put
   per-program values such as `PORT` in each config's `env`
   ([§5](#5-env-files-and-profiles)). Never put secrets in a tracked file.
5. **Write the configs**: one `debug` (or `run`) config per entry point, plus
   `test` configs only when tests need flags or env
   ([§6](#6-one-worked-config-per-runtime)).
6. **Check:**
   - `:AutoRun doctor` validates every config file;
   - it also lists what each runtime is missing ("Toolchains and
     dependencies": SDK not installed, `npm install` / `pub get` not run,
     Playwright browsers absent, no debug adapter);
   - fix or report every line.
7. **Hand over.** Tell the user:
   - which configs you wrote;
   - which working directory to choose (`<leader>rw`);
   - the keys in §8.

## 2. Where things live

| What | Path | Tracked by git |
|---|---|---|
| Run, debug and test configs | `.auto-run/configs/<name>.json` (repo root) | yes |
| Env profiles | `.auto-run/profiles/<name>.json` | yes |
| Local overrides, picks, breakpoints | the shared tier: `.auto-run/local/` in a plain clone, `<container>/.auto-run/` in a bare-repo + worktrees layout | no |
| Env files | repo root, `.config/`, `.vscode/` or `.auto-run/` | `.auto-run/` ones are tracked; keep secrets out |
| These instructions | `.auto-run/AGENTS.md`, `CLAUDE.md`, the `auto-run.nvim-v*` marker | yes |

- **One config per file.** The file name is `<name>.json`, and `name` inside
  must match.
- **Strict JSON.** No comments, no trailing commas. An unknown key fails
  validation.
- **Never edit `overrides.json` or `state.json` by hand.** The panes write
  them.

## 3. Config fields

Required: `name` and `kind`. Every other field is optional. JSON `null` on a
field removes what a lower layer (`extends`, the tracked tier) set.

{{fields}}

**Substitution tokens** work inside any string field:

| Token | Becomes |
|---|---|
| `${worktree}` (also `${workspaceFolder}`) | the **repo root**, never the folder chosen with `w` |
| `${containerRoot}` | the bare-repo container (in a plain clone, the repo root) |
| `${file}` / `${fileDirname}` | the current buffer / its directory |
| `${env:NAME}` | the environment variable `NAME` of the nvim process |

**The one mistake to avoid:** in a repo with projects in folders,
`${worktree}/cmd/server` does not exist, but `${worktree}/<folder>/cmd/server`
does. auto-run refuses a `program` that does not exist before launching.

## 4. Runtimes registered in this auto-run

What `a` scaffolds for each runtime (the defaults are adjusted to the working
directory when created):

{{runtimes}}

## 5. Env files and profiles

**Env file format** (dotenv):
- one `KEY=VALUE` per line;
- a leading `export ` is allowed;
- surrounding quotes are stripped;
- `#` starts a comment line;
- keys match `[A-Za-z_][A-Za-z0-9_]*`.

A config that references a missing env file fails its launch, on purpose.

**How a variable's final value is chosen**, lowest to highest (later wins):

1. the config's and profile's `env_files`, in order;
2. the **selected** env file (`s` in the Env section): one per repo, applied
   to every run, debug and test;
3. secret manifests;
4. `command_env` / `runtime_env`;
5. the config's own `env`.

**Env profile** (`.auto-run/profiles/<name>.json`) is a named recipe that
configs opt into with `"profile": "<name>"`. Its fields:

{{profile_fields}}

## 6. One worked config per runtime

Paths assume the project lives in `app/`. Drop the folder when it is the repo
root.

**Go** — debug a server:
```json
{ "name": "server", "kind": "debug", "runtime": "go",
  "program": "${worktree}/app/cmd/server", "cwd": "${worktree}/app",
  "env_files": ["${worktree}/.env.local"], "env": { "PORT": "8081" } }
```

**Rust** — Cargo builds it, and codelldb launches it, so there is no `program`:
```json
{ "name": "server", "kind": "debug", "runtime": "rust", "cwd": "${worktree}/app",
  "cargo_package": "app", "cargo_target": "app", "cargo_target_kind": "bin" }
```

**Node** — a `package.json` script, run with the package manager its lockfile
names (npm, pnpm, yarn, bun):
```json
{ "name": "web", "kind": "run", "runtime": "node", "script": "dev", "cwd": "${worktree}/web" }
```
**Node** — an entry file (`.ts` runs through the project's `tsx` when
installed):
```json
{ "name": "api", "kind": "debug", "runtime": "node",
  "program": "${worktree}/api/src/server.js", "args": ["--port", "3000"] }
```

**Jest / React Testing Library / Playwright** — tests run with no config. Add
one only for env or flags, with `runtime` set to `jest` or `playwright`:
```json
{ "name": "e2e", "kind": "test", "runtime": "playwright", "env": { "BASE_URL": "http://localhost:5173" } }
```

**Dart** — a console program (`dart run`):
```json
{ "name": "cli", "kind": "run", "runtime": "dart",
  "program": "${worktree}/tool/bin/tool.dart", "cwd": "${worktree}/tool" }
```

**Flutter desktop** (`flutter run -d linux`). `args` are `flutter run` flags,
such as `--dart-define=API=http://localhost:8081`. Only desktop devices are
supported: no emulators, phones or web.
```json
{ "name": "app", "kind": "debug", "runtime": "dart", "program": "${worktree}/app/lib/main.dart",
  "cwd": "${worktree}/app", "device": "linux", "args": ["--dart-define=API=http://localhost:8081"] }
```

**How a test run picks its config:**
- the runtime's pick (`s` on a test config, `c` in the tests pane);
- otherwise the shared pick;
- otherwise the first `kind: test` config whose `runtime` matches.

A config without a `runtime` applies to every runtime.

## 7. Before you hand over

- `:AutoRun doctor` reports:
  - every config file's validation;
  - the working directory and store tiers;
  - the toolchain / dependency check for each runtime found.
- A launch that is missing something says exactly what, and how to fix it
  (e.g. `dependencies are not installed … — npm install`), before anything
  starts.
- **Agents:** write the JSON files directly, then run the check. Never write
  secrets into a tracked file.

## 8. Doing it by hand (no agent)

1. **Choose the working directory.** Press `<leader>rw`, or `w` in the debug
   or tests pane, and pick a worktree, then a project folder. Tests are
   discovered there, and runs and debugs start there. The editor's cwd
   doesn't move.
2. **Tests** (tests pane):
   - run the test under the cursor: `r`, or `<leader>rt` in the file;
   - debug it: `d`, or `<leader>rT`;
   - rerun the last run: `R`;
   - output: `i`.
3. **An entry point** (debug pane):
   - create one: `a` (kind, runtime, name);
   - show its fields: `o`; unset fields show their help and allowed values;
   - set a field: `e`; fixed sets open a chooser;
   - delete it: `D`.
4. **Env:**
   - new env file: `n`;
   - add `KEY=VALUE`: `a` on a file;
   - select a file for every run: `s`.
5. **Run or debug:**
   - run in a terminal: `r` on the entry point (Flutter: `r` / `R` there for
     hot reload / restart);
   - debug it: `d`, or `<leader>rP` to pick one;
   - again: `<leader>rl` / `<leader>rL`.
6. **While debugging:**
   - breakpoint: `<leader>db`;
   - continue: `F9`;
   - step over / into / out: `F8` / `F7` / `F10`;
   - views: `<leader>dv`;
   - terminate: `<leader>dq`.
7. **Logs:**
   - a debugged program's output is in dap-view's REPL;
   - every session is also journalled to
     `~/.local/state/nvim/auto-run/sessions/`; `o` on a session under Active
     Sessions shows its pid, port, log and a ready `tail -f` command.
