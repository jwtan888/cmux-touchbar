# Codex showing Idle while running

Observed 2026-09-07: both live cmux Codex hook records said `agentLifecycle=idle`, while their corresponding transcripts ended in uncompleted `task_started` turns followed by ongoing tool/reasoning events. The helper treated that stale hook field as authoritative.

Fix: use incrementally read Codex task lifecycle events for status, with matching turn IDs so a late completion cannot clear a newer task. Keep cmux hook records for session discovery and process ancestry checks. Missing transcript state is Unknown. Other providers are unchanged.

Validation: lifecycle regression and file-read tests pass; live sessions now show Running; logo decoding and layout/display-mode tests pass. The Touch Bar uses blue for Running and gray for Idle.
