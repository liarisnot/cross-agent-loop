# Decisions: sandbox-env

Append-only. One line per entry: `- <ISO time> [<kind>] <text>`. Written only by feature.ps1.

- 2026-11-18T03:57:09Z [decision] design D1: environments live per repo in <repo>.xagent\.envs\, named py<ver>-<lockhash>; chosen over a shared root (sharing across repos is rare and D: copies anyway)
