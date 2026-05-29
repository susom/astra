# Data Apps Module Specification

**Status:** Draft — ideation and architecture
**Date:** 2026-05-29
**Scope:** New workspace-level entity type for persistent, interactive, chat-built applications that compose data, agent actions, and user controls into reusable tools.

## Goal

Add a **Data Apps** module to ASTRA so users can create persistent, interactive mini-applications inside their workspaces. Data Apps are built through natural-language chat, render as native SwiftUI views, and wire into the existing capability layer (connectors, skills, local tools, query adapters, agent tasks).

Today, ASTRA's workspace primitives are ephemeral: a task runs, produces output, and finishes. Data Apps fill the gap between one-shot agent work and the external tools users context-switch to — dashboards, lookup forms, pipeline monitors, report generators. They turn the output of agent work into a durable, reusable surface.

## Product Principles

- **Chat-built, not code-built.** Users describe what they want in natural language. The AI generates and iterates the app specification. No drag-and-drop editor, no visual node graph, no coding required.
- **Declarative composition.** Apps are defined as a tree of typed widgets with data bindings. ASTRA renders them natively. No arbitrary code execution inside an app.
- **Capability-native.** Apps inherit the workspace's connectors, skills, and tools. A BigQuery connection configured for tasks is immediately available to apps. No separate configuration.
- **Task-integrated.** Apps can spawn tasks, display task output, and respond to task events. Apps are the entry point to agent work, not a separate silo.
- **Governance-aware.** Apps inherit ASTRA's existing capability governance: risk levels, approval status, data access policies, and credential management. An app that reads patient data carries the same compliance metadata as a task that does.

## Core Concept

A Data App is a workspace entity that sits alongside tasks. The workspace home adds a second creation path:

```
Workspace Home
  ├── [+ New Task]        ← existing
  └── [+ New Data App]    ← new
```

Apps appear in the workspace sidebar in their own section, below (or alongside) tasks. Each app has a name, icon, and description. Opening an app shows its interactive view. Opening its editor reopens the chat conversation that built it.

## App Archetypes

Data Apps span a spectrum from pure display to pure automation. Five archetypes cover the primary value patterns. These are not separate types — they are points on a continuum. A single app can combine dashboard widgets with pipeline steps and action buttons.

### 1. Dashboard

**User intent:** "Show me X over time."

Static or auto-refreshing display of data from one or more sources. Stat cards, charts, and tables arranged in a grid. No user input beyond optional filter controls.

**Examples:**
- BigQuery cost dashboard with daily/weekly/monthly breakdown by project
- REDCap enrollment tracker with site-by-site comparison charts
- CI/CD build health board showing pass/fail rates across repositories

**Primary widgets:** Stat Card, Chart, Data Table, Filter Bar

**Value:** Replaces the manual pull-data → paste-into-Sheets → share loop.

### 2. Lookup Tool

**User intent:** "Search for X and show me everything about it."

A form input drives a query or connector call. Results render in a detail view. The user interacts repeatedly — search, browse, search again.

**Examples:**
- Patient lookup: enter MRN, fetch REDCap record, show demographics + recent labs
- Dependency checker: enter package name, query registry, show version tree + CVEs
- Ticket finder: enter Jira key, show status, assignee, linked PRs, comments

**Primary widgets:** Form, Data Table, Markdown Block, Action Button

**Value:** Eliminates context-switching across multiple systems for common lookups.

### 3. Action Panel

**User intent:** "Let me trigger common operations."

A set of buttons and controls that execute actions: spawn tasks, call APIs, run scripts. The panel shows action status and results. It's a custom control surface for operations the user runs repeatedly.

**Examples:**
- Deployment panel: buttons for staging/production deploy, rollback, log tail
- Data refresh: one-click to re-materialize a BigQuery view, with status indicator
- Report generator: select date range, click generate, preview and send

**Primary widgets:** Action Button, Status Indicator, Form, Markdown Block

**Value:** Turns multi-step agent tasks into one-click operations.

### 4. Monitor

**User intent:** "Watch X and tell me when something changes."

An auto-refreshing view with threshold-based status indicators. Optionally triggers agent actions or notifications when conditions are met.

**Examples:**
- Error rate monitor: polls logs, shows rate over time, turns red above 5%
- SLA tracker: checks response times, shows green/yellow/red per endpoint
- Budget watcher: queries cloud billing, alerts when projected spend exceeds limit

**Primary widgets:** Status Indicator, Chart, Stat Card, Step List (for alert pipeline)

**Value:** Proactive visibility without setting up Grafana/PagerDuty/Datadog.

### 5. Pipeline

**User intent:** "Run this multi-step process, possibly on a schedule."

An ordered sequence of steps that fetch, transform, decide, and deliver. Steps can include deterministic gates (expression-based) and agent gates (LLM-decided). The app surface shows step status, run history, and manual controls.

**Examples:**
- Weekly enrollment report: pull REDCap → calculate trends → generate summary → email PI
- Data quality check: query warehouse → validate constraints → agent: classify violations → route alerts
- Incident triage: detect anomaly → agent: assess severity → create ticket or log

**Primary widgets:** Step List, Run History, Run Button, Step Output, Schedule Badge

**Value:** Codifies repeatable multi-step workflows with AI judgment at decision points.

## Widget Catalog

Apps are composed from a fixed catalog of typed widgets. Each widget has a defined set of properties, data bindings, and rendering behavior. The catalog is extensible over time but starts constrained for safety and predictability.

### V1 Widgets

#### Data Table

Rows and columns from a data source. Supports sorting, column selection, row click actions, copy, and CSV/JSON export.

```
DataTable {
  dataSource: DataSourceRef          // named query, connector call, or step output
  columns: [ColumnDef]               // name, type, width, sortable, format
  rowLimit: Int                      // max rows to display (default 100)
  onRowClick: ActionRef?             // optional action when a row is clicked
  emptyState: String                 // message when no data
  refreshOn: RefreshTrigger?         // manual, interval, or data-source change
}
```

#### Chart

Line, bar, scatter, or pie chart from tabular data. Auto-suggests chart type based on column types but allows user override.

```
Chart {
  dataSource: DataSourceRef
  chartType: line | bar | scatter | pie
  xColumn: String
  yColumns: [String]
  groupBy: String?                   // optional series grouping
  title: String?
  height: compact | standard | tall
}
```

#### Stat Card

Single prominent number with label, optional trend indicator, and optional sparkline.

```
StatCard {
  dataSource: DataSourceRef          // must resolve to a scalar or single-row result
  value: ColumnRef                   // which column/field to display
  label: String
  format: number | currency | percentage | duration
  trend: TrendConfig?               // compare to previous period
  thresholds: [Threshold]?          // color changes at value boundaries
}
```

#### Form

Input fields that feed into data source parameters or action inputs. Supports text, number, date, select, and toggle field types.

```
Form {
  fields: [FormField]               // name, label, type, default, required, options
  submitLabel: String                // button text
  onSubmit: ActionRef               // action to trigger with field values
  layout: vertical | horizontal | grid
}
```

#### Action Button

A button that triggers an action when clicked. Shows loading state during execution and result preview on completion.

```
ActionButton {
  label: String
  icon: String?
  style: primary | secondary | destructive
  action: ActionRef                  // task spawn, script run, connector call, pipeline trigger
  confirmationMessage: String?       // if set, shows confirmation dialog before executing
  showResultPreview: Bool            // show action output inline
}
```

#### Filter Bar

A row of controls (dropdowns, date pickers, text search) that parameterize data sources. Filter values are bound to data source parameters.

```
FilterBar {
  filters: [FilterControl]          // name, label, type, options, default
  target: [DataSourceRef]           // which data sources to re-query when filters change
  layout: horizontal | wrap
}
```

#### Markdown Block

Static or template-rendered rich text. Can include data bindings for dynamic content (e.g., "Last updated: {{lastRefresh}}").

```
MarkdownBlock {
  content: String                    // markdown with optional {{binding}} placeholders
  bindings: [String: DataSourceRef]  // resolve placeholders from data sources
  style: body | callout | caption
}
```

#### Status Indicator

Traffic-light style health indicator. Evaluates a data source value against thresholds.

```
StatusIndicator {
  dataSource: DataSourceRef
  value: ColumnRef
  thresholds: [Threshold]            // green/yellow/red boundaries
  label: String
  showValue: Bool                    // display the raw value alongside the indicator
  size: compact | standard
}
```

#### Step List

Ordered list of pipeline steps with status indicators, duration, and expandable output. Specific to pipeline-archetype apps.

```
StepList {
  steps: [StepRef]                   // references to the app's pipeline step definitions
  showDuration: Bool
  showOutput: Bool                   // expandable step output preview
  layout: linear | tree              // tree for branching pipelines
}
```

#### Run History

Table of past pipeline executions with timestamp, status, duration, and output summary.

```
RunHistory {
  maxEntries: Int                    // how many past runs to show (default 20)
  showOutput: Bool                   // expandable output per run
}
```

#### Run Button

Manual pipeline trigger with optional parameter inputs. Shows execution state.

```
RunButton {
  label: String                      // default: "Run"
  parameters: [FormField]?           // optional inline parameter inputs
  confirmationMessage: String?
}
```

#### Schedule Badge

Displays the app's refresh or pipeline schedule. Shows next fire time, frequency, and enable/disable toggle.

```
ScheduleBadge {
  editable: Bool                     // allow user to change schedule from the badge
}
```

## Layout System

Widgets are arranged in a grid layout with rows and columns. The layout is defined as a tree:

```
Layout {
  sections: [
    Section {
      title: String?                 // optional section header
      columns: 1 | 2 | 3 | 4        // column count for this section
      widgets: [WidgetPlacement]     // widget ref + column span + row span
    }
  ]
}
```

Sections stack vertically. Within a section, widgets flow into a column grid. A widget can span multiple columns (e.g., a full-width chart in a 2-column layout). This is simple enough for chat-based iteration ("make the chart full-width", "put the stats in a 3-column row") while supporting useful layouts.

## Data Source Layer

Every widget that displays data references a named **DataSource**. Data sources are defined at the app level and shared across widgets. A filter bar modifies data source parameters; multiple widgets can bind to the same source.

### Data Source Types

#### Query

A SQL query executed against a database connection (BigQuery, Postgres, DuckDB, etc. via the existing `DatabaseAdapter` protocol).

```
QueryDataSource {
  id: String                         // unique name within the app
  connectionID: UUID                 // reference to a workspace Connector
  sql: String                        // SQL with optional {{parameter}} placeholders
  parameters: [ParameterDef]         // name, type, default — bound from filter bars or form fields
  refreshInterval: TimeInterval?     // auto-refresh (nil = manual only)
  cacheSeconds: Int                  // how long to cache results (default 60)
}
```

#### Connector Call

An API call to a workspace connector (Jira, GitHub, Slack, REDCap, REST, etc.).

```
ConnectorDataSource {
  id: String
  connectorID: UUID                  // reference to a workspace Connector
  endpoint: String                   // API path or method name
  method: String                     // HTTP method (for REST connectors)
  parameters: [ParameterDef]
  responseMapping: JSONPath?         // extract a subset of the response
  refreshInterval: TimeInterval?
  cacheSeconds: Int
}
```

#### Script Output

Output from a local tool execution (CLI command or script).

```
ScriptDataSource {
  id: String
  toolID: UUID                       // reference to a workspace LocalTool
  arguments: [String]                // with optional {{parameter}} placeholders
  outputFormat: json | csv | text    // how to parse the output
  refreshInterval: TimeInterval?
}
```

#### Step Output

In pipeline apps, a data source that resolves to the output of a specific pipeline step. Used to wire step results into display widgets.

```
StepOutputDataSource {
  id: String
  stepID: String                     // reference to a pipeline step
  outputPath: JSONPath?              // extract a subset of the step output
}
```

#### Static

Hardcoded data for prototyping, labels, or configuration. No external dependency.

```
StaticDataSource {
  id: String
  data: JSON                         // inline JSON data
}
```

## Pipeline Engine

Pipeline-archetype apps define an ordered sequence of steps with control flow. The pipeline engine executes steps, manages state, and handles branching and looping.

### Step Types

#### Action Step

Executes an operation and produces output.

```
ActionStep {
  id: String
  name: String
  action: StepAction                 // see below
  inputs: [String: Binding]          // bind inputs from previous step outputs or app parameters
  timeout: TimeInterval?             // max execution time
  retryCount: Int                    // retries on failure (default 0)
  retryDelay: TimeInterval           // delay between retries
}
```

**StepAction variants:**

```
StepAction =
  | QueryAction { connectionID, sql, parameters }
  | ConnectorAction { connectorID, endpoint, method, body }
  | ScriptAction { toolID, arguments }
  | AgentAction { prompt, model?, tokenBudget?, skillIDs? }
```

The `AgentAction` is critical — it spawns an ASTRA agent task inline. The agent receives the step inputs as context, executes its prompt, and returns structured output. This is how apps leverage AI reasoning within a pipeline.

#### Gate Step

A decision point that evaluates a condition and routes to one of multiple paths. Gates come in two types:

**Expression Gate** — deterministic, evaluated by the app runtime:

```
ExpressionGate {
  id: String
  name: String
  condition: String                  // evaluable expression over step outputs
                                     // e.g., "steps.fetch.result.rowCount > 0"
                                     //       "steps.check.result.status == 'failed'"
  paths: {
    "true": StepID,
    "false": StepID
  }
}
```

Expression gates are fast, free, and deterministic. Use for data presence checks, threshold comparisons, error handling, and type routing.

The expression language is a safe, sandboxed subset — comparison operators, boolean logic, numeric arithmetic, string matching, and property access on step output objects. No function calls, no side effects, no arbitrary code.

**Agent Gate** — LLM-decided, with governance:

```
AgentGate {
  id: String
  name: String
  prompt: String                     // judgment question with context bindings
                                     // e.g., "Look at these enrollment numbers.
                                     //        Is this trend concerning enough to
                                     //        alert the PI?"
  inputBindings: [String: Binding]   // step outputs injected into prompt context
  options: [GateOption]              // named choices the agent can pick
  model: String?                     // model override (default: workspace default)
  policy: autonomous | review | locked
}

GateOption {
  name: String                       // e.g., "escalate", "log_only", "retry"
  description: String                // guidance for the agent
  nextStep: StepID                   // where to route if this option is chosen
}
```

Agent gates are the unique capability that differentiates ASTRA Data Apps from every other pipeline tool. No pipeline tool today lets you put an AI at a decision point with governance controls.

**Policy modes for agent gates:**

| Policy | Behavior |
|--------|----------|
| **Autonomous** | Agent decides, pipeline continues automatically. Best for low-risk triage and classification. |
| **Review** | Agent recommends, pipeline pauses, user sees the reasoning and approves or overrides. Best for escalation decisions and compliance-sensitive branching. |
| **Locked** | Agent is not allowed to decide; always pauses and routes to the user. Compliance backstop for high-risk paths. |

When an agent gate has `policy: review`, the app surface shows:

```
┌──────────────────────────────────────────────────┐
│  ⏸  Step 4: Escalate?              AWAITING YOU  │
│  ┌────────────────────────────────────────────┐  │
│  │ Agent recommendation: ESCALATE             │  │
│  │                                            │  │
│  │ "Found 3 access attempts from outside      │  │
│  │  the VPN that don't match any known        │  │
│  │  researcher patterns."                     │  │
│  │                                            │  │
│  │  [✓ Approve escalation]                    │  │
│  │  [✗ Override: log only]                    │  │
│  │  [→ Ask agent for more detail]             │  │
│  └────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

#### Loop Step

Repeats a sequence of steps until a condition is met.

```
LoopStep {
  id: String
  name: String
  body: [StepID]                     // steps to repeat each iteration
  condition: LoopCondition           // when to stop
  maxIterations: Int                 // safety cap (required, default 10)
  delayBetween: TimeInterval?        // pause between iterations
}
```

**LoopCondition variants:**

```
LoopCondition =
  | UntilExpression { expression: String }      // e.g., "steps.check.result.status != 'pending'"
  | UntilAgent { prompt: String, policy: ... }  // agent decides when to stop
  | ForEach { collection: Binding, itemVar: String }  // iterate over a list
```

The `ForEach` variant enables fan-out patterns: process each item in a list through the loop body. Items can run serially or with a configurable concurrency limit.

### Pipeline Execution State

The pipeline runtime maintains execution state for each run:

```
PipelineRunState {
  runID: UUID
  status: pending | running | paused | completed | failed | cancelled
  startedAt: Date?
  completedAt: Date?
  currentStepID: String?
  stepStates: [String: StepState]    // per-step status, output, error, duration
  iterationCount: Int                // for loops
  gateDecisions: [GateDecision]      // audit log of every gate evaluation
}

StepState {
  status: pending | running | completed | failed | skipped
  output: JSON?                      // step result
  error: String?
  startedAt: Date?
  completedAt: Date?
  duration: TimeInterval?
  agentTaskID: UUID?                 // if this step spawned an agent task
}

GateDecision {
  gateID: String
  type: expression | agent
  input: JSON                        // what the gate evaluated
  decision: String                   // which option was chosen
  reasoning: String?                 // agent's reasoning (for agent gates)
  approvedBy: user | agent           // who made the final call
  timestamp: Date
}
```

The `GateDecision` audit trail is important for governance. Every agent decision in the pipeline is recorded with its inputs, reasoning, and whether a human approved it.

### Pipeline Visual Representation

Pipeline steps render as an indented tree in the Step List widget, without requiring a visual DAG editor:

```
Steps:
 1. Fetch enrollment data
 2. New patients? (expression)
    ├─ Yes
    │   3. Analyze trends (agent)
    │   4. Alert needed? (agent · requires approval)
    │   ├─ Yes → 5. Email PI + log
    │   └─ No  → 6. Save to dashboard
    └─ No
        7. Log: no new data
```

For loops:

```
Steps:
 1. Trigger deploy
 2. Check build status
 3. ↻ Repeat step 2 every 5m until status ≠ pending (max 12×)
 4. Deploy result? (expression)
    ├─ Passed → 5. Notify: success
    └─ Failed → 6. Agent: diagnose + create ticket
```

This is readable, compact, and editable through chat. The chat builder understands commands like "add a step after step 3" or "make step 4 require my approval."

## Data Model

### SwiftData Entity: DataApp

```swift
@Model
final class DataApp {
    var id: UUID
    var name: String
    var icon: String
    var appDescription: String

    // App definition — the full specification
    var layoutJSON: String             // widget tree, sections, bindings
    var dataSourcesJSON: String        // named data sources
    var pipelineJSON: String           // pipeline steps, gates, loops (empty for non-pipeline apps)
    var stateJSON: String              // persisted user state: filter values, last refresh, cached results

    // Chat builder state
    var draftMessagesJSON: String      // conversation history used to build/edit this app

    // Scheduling (for auto-refresh or pipeline schedules)
    var refreshScheduleID: UUID?       // reference to a TaskSchedule for auto-refresh

    // Execution state (for pipeline apps)
    var lastRunJSON: String            // most recent PipelineRunState
    var runHistoryJSON: String         // array of past PipelineRunState summaries

    // Audit
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?

    // Relationships
    var workspace: Workspace?

    @Relationship
    var skills: [Skill] = []           // capabilities this app uses
}
```

### Workspace Relationship

Add to the `Workspace` model:

```swift
@Relationship(deleteRule: .cascade, inverse: \DataApp.workspace)
var dataApps: [DataApp] = []
```

### Schema Migration

This adds one new entity (`DataApp`) and one new relationship on `Workspace`. This is a V6 schema migration — additive only, no field changes on existing entities.

## Chat Builder

### Entry Point

From the workspace home or sidebar, user clicks **+ New Data App**. The chat panel opens in **App Builder** mode — visually distinguished from task chat by a header badge and different accent color.

### Builder Flow

1. **Describe.** User describes what they want in natural language.
2. **Generate.** AI generates an app specification (layout + data sources + optional pipeline). The spec is written as JSON into the `DataApp` entity.
3. **Preview.** A live preview renders alongside the chat, showing the app as it will appear. Initially with placeholder/sample data; once data sources are connected, with live data.
4. **Iterate.** User refines through conversation: "add a date filter", "make the chart a bar chart", "add a step that emails the results." Each iteration updates the spec and re-renders the preview.
5. **Save.** User accepts the app. It appears in the workspace sidebar, ready to use.

### Editing Existing Apps

Reopening an app's builder loads the original conversation. The user can continue the conversation to modify the app. The AI sees the current spec as context and applies incremental changes.

### Slash Command

In addition to the button, a `/app` slash command in the chat panel enters app builder mode:

```
/app                    → new app, open-ended
/app cost dashboard     → new app with initial description
```

### Capability Auto-Detection

When the user describes their app, the builder should automatically identify which workspace capabilities are needed:

- "Show me BigQuery costs" → links the BigQuery connector data source
- "Search patients in REDCap" → links the REDCap connector
- "Run a shell script" → links the relevant local tool

If a required capability is not configured in the workspace, the builder should prompt: "This app needs a BigQuery connection. Would you like to set one up now?"

## Actions

Actions are operations that widgets can trigger. They bridge the app surface to ASTRA's execution layer.

### Action Types

```
Action =
  | SpawnTask { goal, skillIDs?, model?, tokenBudget? }
  | RunScript { toolID, arguments }
  | CallConnector { connectorID, endpoint, method, body }
  | RunQuery { connectionID, sql, parameters }
  | RunPipeline { }                              // trigger this app's pipeline
  | RefreshDataSource { dataSourceID }            // re-fetch a specific data source
  | OpenURL { url }
  | CopyToClipboard { content }
  | ShowNotification { title, body }
```

### Action Governance

Actions that modify external state (SpawnTask, RunScript, CallConnector with write methods) require confirmation by default. The app spec can mark an action as `requiresConfirmation: true` to always show a dialog, or `requiresConfirmation: false` for read-only operations that the user has pre-approved.

Destructive actions (delete, overwrite) always require confirmation regardless of the app spec setting.

## Relationship to Existing ASTRA Features

### Tasks

- Apps can **spawn tasks** via `SpawnTask` actions. The task inherits the app's workspace context and selected skills.
- Apps can **display task output** by binding a widget to a task's event stream or artifact.
- Pipeline steps can include `AgentAction` which internally creates and runs a task, waits for completion, and captures the output.

### Query Shelf

The Data Query Shelf and Data Apps are complementary, not competing:

- **Query Shelf** = ad-hoc SQL workbench for exploration and one-off queries, tightly bound to a single task.
- **Data Apps** = persistent, multi-source, interactive surfaces with layout and controls.

A natural integration: the query shelf's "Save as App" action could create a Data App from the current query + result grid + chart configuration.

### Templates

Templates define multi-phase task patterns (`before → main → after`). Data Apps subsume this pattern for interactive use cases — a pipeline app with three action steps is effectively a template with a UI. Templates remain valuable for headless task patterns that don't need an interactive surface.

### Schedules

Data Apps reuse the existing `TaskSchedule` entity for auto-refresh and pipeline scheduling. The `refreshScheduleID` on `DataApp` references a workspace schedule. Pipeline apps can have their own schedule that triggers the pipeline automatically.

### Capability Packages

Data Apps should be includable in capability packages for sharing across workspaces. The package format adds an `apps` array alongside `skills`, `connectors`, `localTools`, and `templates`:

```json
{
  "id": "enrollment-dashboard-package",
  "name": "REDCap Enrollment Dashboard",
  "apps": [
    {
      "name": "Enrollment Dashboard",
      "icon": "chart.bar.fill",
      "description": "Real-time enrollment tracking across sites",
      "layoutJSON": "...",
      "dataSourcesJSON": "...",
      "pipelineJSON": ""
    }
  ],
  "connectors": [...],
  "skills": [...]
}
```

This lets Stanford teams share useful apps across workspaces: install the package, connect credentials, and the app is ready.

## Example: End-to-End Pipeline App

**User request:** "I want an app that checks our BigQuery costs every morning. If daily spend is over $500, have Astra analyze what's causing it. If Astra thinks it's a runaway query, kill the job and alert the team on Slack. If it's expected growth, just log it."

**Resulting app spec (simplified):**

```
Name: "BQ Cost Monitor"
Icon: "dollarsign.circle.fill"
Schedule: Daily at 9:00am

Data Sources:
  - costs_query: BigQuery SQL → billing.daily_costs WHERE date = CURRENT_DATE()

Pipeline Steps:
  1. fetch_costs (QueryAction → costs_query)
  2. over_budget (ExpressionGate → steps.fetch_costs.result.total > 500)
     ├─ false → 6. log_ok (ScriptAction → echo "Costs normal")
     └─ true  → 3. analyze
  3. analyze (AgentAction → "Analyze these BigQuery costs. Identify the top cost
     drivers. Is there a runaway query, or is this expected growth?")
  4. classify (AgentGate → "Based on your analysis, is this a runaway query or
     expected growth?" options: [runaway, expected], policy: review)
     ├─ runaway → 5a. kill_and_alert
     │   5a.1 kill_job (ScriptAction → bq cancel {{jobId}})
     │   5a.2 alert_slack (ConnectorAction → Slack → post to #eng-alerts)
     └─ expected → 5b. log_growth
         5b. log_with_note (ScriptAction → append to growth_log.csv)

Layout:
  Section "Status" (1 column):
    - ScheduleBadge
    - StatusIndicator (bound to last run status)
  Section "Pipeline" (1 column):
    - StepList (tree layout)
    - RunButton (label: "Run Now")
  Section "History" (1 column):
    - RunHistory (last 20 runs)
  Section "Cost Trend" (1 column):
    - Chart (line, last 30 days of costs_query with date range expanded)
```

## Implementation Phases

### Phase 1: Entity and Shell

- Add `DataApp` SwiftData entity.
- Add V6 schema migration.
- Add `Workspace.dataApps` relationship.
- Add "New Data App" button to workspace home.
- Add Data App section to workspace sidebar.
- Add `DataAppDetailView` shell with name, icon, and placeholder content.

### Phase 2: Widget Renderer

- Implement widget type registry and `WidgetRenderer` protocol.
- Implement V1 widgets: Markdown Block, Stat Card, Data Table, Chart.
- Implement layout engine (sections, column grid, widget placement).
- Render an app from its `layoutJSON` spec.

### Phase 3: Chat Builder

- Add App Builder mode to the chat panel.
- Add `/app` slash command.
- Implement app spec generation from natural-language description.
- Implement live preview split-pane alongside chat.
- Implement iterative spec updates from follow-up messages.
- Save and restore builder conversation in `draftMessagesJSON`.

### Phase 4: Data Source Binding

- Implement `DataSource` resolution: Query, Connector, Script, Static.
- Wire data sources to widget bindings.
- Implement Filter Bar → data source parameter binding.
- Implement manual and auto-refresh.
- Wire to existing `DatabaseAdapter` infrastructure (BigQuery first).

### Phase 5: Actions and Interaction

- Implement Action execution: SpawnTask, RunScript, CallConnector, RunQuery.
- Wire Action Button, Form submit, and row click handlers.
- Implement action confirmation dialogs.
- Implement action result display.

### Phase 6: Pipeline Engine

- Implement `PipelineRuntime`: step sequencing, state management.
- Implement `ActionStep` execution.
- Implement `ExpressionGate` evaluation (safe expression sandbox).
- Implement `AgentGate` execution (agent task spawn, decision capture, policy enforcement).
- Implement `LoopStep` execution with safety caps.
- Implement pipeline-specific widgets: Step List, Run History, Run Button, Schedule Badge.
- Implement `GateDecision` audit trail.

### Phase 7: Scheduling and Persistence

- Wire Data App refresh to existing `TaskSchedule` infrastructure.
- Implement pipeline auto-trigger via schedule.
- Implement persistent run history (capped, per-app).
- Implement app state persistence (filter values, cached results).

### Phase 8: Packaging and Sharing

- Add `apps` array to capability package format.
- Implement app export and import via packages.
- Implement capability auto-detection in the builder.

## Open Design Questions

1. **App limits.** Should there be a per-workspace cap on data apps? Apps with auto-refresh schedules consume resources. A reasonable V1 cap might be 20 apps per workspace, 5 with active auto-refresh.

2. **Versioning.** When a user edits an app, should previous versions be preserved? Version history would let users revert a bad edit, but adds storage complexity. A single "last known good" snapshot might be sufficient for V1.

3. **Offline behavior.** Data apps that depend on external connectors will fail when the network is unavailable. The app should show the last cached result with a "stale" indicator, not an error. How long should cached results persist?

4. **Expression language.** The safe expression subset for ExpressionGates needs a clear specification. Options: a minimal custom language (like JSONPath + comparisons), a subset of JavaScript evaluated in a sandbox, or a Swift expression evaluator. The choice affects what users can express in gate conditions and what the AI generates.

5. **Agent gate cost controls.** Agent gates consume tokens. Should there be per-app or per-pipeline token budgets separate from task budgets? A runaway loop with agent gates could be expensive.

6. **Multi-user.** ASTRA is currently single-user (local macOS app). If workspaces are shared in the future, apps would need access control. Out of scope for V1 but worth considering in the data model.

## Verification

Focused tests:

- DataApp entity creation and persistence.
- Widget rendering from JSON spec.
- Layout engine: sections, column grids, widget placement.
- Data source binding: query, connector, script, static.
- Filter bar → data source re-query.
- Pipeline step sequencing.
- Expression gate evaluation (safe expression sandbox).
- Agent gate → task spawn → decision capture.
- Agent gate policy enforcement (autonomous/review/locked).
- Loop step with max iteration cap.
- GateDecision audit trail serialization.
- App builder chat → spec generation round-trip.
- Capability package export/import with apps.

Manual checks:

- `swift test --filter DataApp`
- `swift test --filter Widget`
- `swift test --filter Pipeline`
- `git diff --check`
- `./script/build_and_run.sh --verify`
