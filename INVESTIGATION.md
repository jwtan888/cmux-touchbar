# Codex showing Idle while running

Observed 2026-09-07: both live cmux Codex hook records said `agentLifecycle=idle`, while their corresponding transcripts ended in uncompleted `task_started` turns followed by ongoing tool/reasoning events. The helper treated that stale hook field as authoritative.

Fix: use incrementally read Codex task lifecycle events for status, with matching turn IDs so a late completion cannot clear a newer task. Keep cmux hook records for session discovery and process ancestry checks. Missing transcript state is Unknown. Other providers are unchanged.

Validation: lifecycle regression and file-read tests pass; live sessions now show Running; logo decoding and layout/display-mode tests pass. The Touch Bar uses blue for Running and gray for Idle.

## Current status (2026-10-14)

This investigation records the implementation observed on 2026-09-07. The current helper discovers sessions from cmux hook-session records and matches them to live cmux surface UUIDs. Codex status uses cmux hook events and monitor leases, with session runtime/lifecycle status as a fallback plus process-liveness and stale-state checks. The live status path does not read Codex transcripts.
