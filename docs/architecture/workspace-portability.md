# Workspace Portability Contract

ASTRA treats the workspace folder as the portable package and the SwiftData store
as the local index. A clean install should be able to recover useful workspace
and task history from the files under the workspace without copying App Support.

## Portable Package

- `.astra-workspace.json` is the durable workspace recovery config.
- `.astra/workspace_manifest.json` records package contents and local-only
  exclusions.
- `.astra/tasks/<task-id-prefix>/task_manifest.json` records the redacted task
  snapshot exported for recovery and inspection.
- Task-local state files remain in `.astra/tasks/<task-id-prefix>/`, including
  `current_state.json`, `current_state.md`, `session_history.md`, `outputs/`,
  diagnostics, validation evidence, and generated artifacts.
- Artifact references inside the workspace are exported as workspace-relative
  paths so the metadata can be relocated when the workspace is imported from a
  different path.

## Local-Only State

These values must not be treated as portable workspace state:

- Keychain secrets, credential values, OAuth/cookie state, and SSH private keys.
- Provider session identifiers on `AgentTask` or `TaskRun`.
- Draft composer state and unread/sidebar presentation state.
- Runtime helper binaries and caches such as `.runtime-bin`.
- Absolute artifact references outside the workspace.
- Channel-specific App Support stores, logs, capability approvals, and UI
  preferences.

## Recovery Boundary

`WorkspaceConfigManager` owns export/import of portable workspace metadata.
`WorkspaceRecoveryService` rebuilds missing SwiftData workspace rows from
`.astra-workspace.json`. The portable manifests are written next to that config
so humans and future recovery code can inspect what is expected to travel with
the workspace and what was intentionally excluded.

## Startup Backfill

`WorkspacePortablePackageBackfillService` runs from deferred startup work after
workspace recovery. It exports the canonical `.astra-workspace.json` and
portable manifests for existing SwiftData workspaces whose primary folder still
exists. The backfill is idempotent and gated by the exported workspace schema
version in `UserDefaults`.

Unavailable primary paths are counted and skipped without creating folders or
rewriting user paths. Real write failures leave the completion marker unset so
the app retries on the next launch after permissions or filesystem state are
fixed.
