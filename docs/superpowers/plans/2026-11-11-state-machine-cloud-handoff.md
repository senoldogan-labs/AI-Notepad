# Cloud-agent execution handoff

Execute this assignment in `senoldogan-labs/AI-Notepad`. It is self-contained: no previous chat or temporary audit files are required.

- [Implementation plan: P00–P30](2026-11-11-state-machine-hardening.md)
- [Architecture contract and complete coverage registry](../specs/2026-11-11-state-machine-hardening.md)

## Assignment

Implement the complete state-machine hardening program, following the plan's dependency graph and independently reviewable PR boundaries. Start with P00, then P01a and P02; complete the remaining P01 sub-PRs and other prerequisites before dependent work. Continue through all authorized, unblocked packages. Do not stop after the first implementation or return another plan.

The 175 inventory labels overlap and are architectural observations, not 175 proven defects. Reproduce suspected failures; preserve already explicit models and simple state where the plan calls for a reviewed retain decision. A new enum alone does not provide durable recovery or prove a bug fixed.

Communicate with the owner in Turkish. All code, comments, tests, commits, PR text and repository documentation are English. Read `AGENTS.md`, applicable nested instructions and `REVIEW.md` before changing anything. This assignment does not waive their tests, independent design review or sensitive-change shipping gates.

## Environment preflight

1. Start from the latest default branch containing this handoff and both linked documents. If the documentation PR is still open, fetch its head explicitly and use it as the documented base. Record the actual starting SHA and reread current source: audit line references describe an earlier snapshot.
2. Check available tools, operating system, Swift/Xcode/SDK versions, Node/npm and repository access without printing credentials. Keep existing package locks and toolchain choices.
3. Full execution requires macOS with Xcode/Apple SDKs and the relevant Simulator/hardware access. Linux alone cannot compile or certify SwiftUI, AppKit or Apple-audio adapters. Use an already authorized connected macOS runner if available; otherwise report the specific missing capability and affected package IDs.
4. Before every code-changing work package, run both required baselines: `swift test --package-path Packages/AINotepadCore` and `swift test --package-path Packages/AINotepadWatchLink`. Obtain actual evidence from the authorized Apple runner if local execution is unavailable. If these mandatory checks cannot run, continue useful read-only analysis but do not begin code changes or mark P00 complete.
5. Run domain-specific baselines and checks from the implementation plan. Distinguish passed, failed, skipped, unavailable and not run. Do not substitute mocks, a Linux build or unrelated CI status for a required Apple check.

## Execution loop

For every eligible work package or explicit sub-PR:

1. Read its dependencies, files, interfaces, verification cases and registry labels. Inspect current implementation and existing tests before adding a new abstraction or test.
2. Obtain independent expert review before settling a nontrivial design, as `AGENTS.md` requires. Record agreement, dissent and rationale under the owning task. If independent review cannot be obtained, report that gate; self-review is not independent review.
3. Characterize the suspected failure or missing invariant with the smallest relevant existing test seam. Implement a complete minimal slice. In P01a, use the shared filesystem commit seam and real files; reducer-only tests do not establish private App persistence behavior.
4. Keep decisions pure and IO adapters thin. Preserve existing reducers, parallel processing, typed ownership, receipts, SQL guards, epochs and outboxes. Do not introduce an application-wide FSM framework or turn every Boolean into an enum.
5. Preserve supported OS versions and deployed formats during extraction. A necessary journal, migration or Watch ownership envelope is a separate reviewed compatibility PR. A process epoch cannot replace durable account tags or reconstruct a queued message's missing owner.
6. Run relevant tests/builds/type checks and inspect the diff. Use real local files/D1/R2/KV plus existing fake-upstream/provider fixtures. Respect paid/live environment gates; do not make real payments, phone calls or production deployments to validate a refactor.
7. Update the existing plan checkboxes and registry with PR/commit links, concrete verification, retain decisions and unresolved gates. Do not create a second progress document. Leave missing requirements visibly incomplete.
8. Ship safe passing work using the repository's branch, Conventional Commit, scoped PR and auto-merge rules. Preserve unrelated work and batch fixes. Verify prerequisite merges before starting dependent PRs.
9. Auth, payments, secrets, migrations and production-infrastructure changes must be prepared and checked, then stop/report before shipping under `AGENTS.md`. Preserve their concrete results on identified isolated local branches/checkouts. Continue unrelated authorized safe work when dependencies allow; do not push/merge sensitive changes merely because the assignment covers the full program.

Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` when installed. In a cloud environment without those local skills, the explicit execution loop here is the portable workflow and replaces skill invocation mechanics only. Repository instructions and all architecture, verification, review and shipping gates remain binding. Do not claim to have invoked an unavailable skill. If a higher-priority instruction requires a particular unavailable skill, report that concrete blocker.

## Parallel work and continuation

Parallelize only independent packages with separate file ownership and authorized isolated checkouts. Serialize edits to `App/AppModel.swift`, `App/Hosted/HostedAccount.swift`, `iOS/PhoneRecorder.swift` and `iOS/AINotepadiOSApp.swift`. Do not overwrite another worker's work or start dependents against an assumed merge.

At durable checkpoints, record branch/commit, completed package, verification and next eligible task in the existing task evidence. After restart or context loss, read that evidence and inspect the current worktree. Verify whether an interrupted mutation already took effect before repeating it. Resume external effects only with the applicable idempotency/receipt evidence.

## Completion and handback

The target is P00–P30 and closure evidence for every numbered and unnumbered inventory boundary, including P30 cross-layer acceptance. Do not report full completion while required hardware checks, baselines, independent reviews, durability guarantees or owner shipping checkpoints remain unresolved.

Simulator/pure tests cannot certify real iPhone dictation, paired-Watch file delivery or device-only ScreenCaptureKit capture. Complete these checks when the affected adapter and plan require them; otherwise state the precise hardware blocker.

Finish with a Turkish report containing completed package IDs and PR/commit links, merged versus pending/local status, concrete regressions fixed, reviewed retain decisions, checks actually run, and exact incomplete package IDs with blocker evidence and the minimal owner/environment action needed. If a time/context limit intervenes, preserve a resumable checkpoint and say the program is incomplete. Do not stop voluntarily while further authorized, unblocked work remains.
