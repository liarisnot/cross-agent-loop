# As built: sandbox-verify

1. **Data, "Environment inputs and uncommitted changes".** The task branch is `xagent/<delegateTaskId>`, not `xagent/<task>`: `-SandboxEnv -Base xagent/<delegateTaskId> -Apply` (after-merge fix-up on `build-docs`).
2. **Rules, "One helper"; Data, "Pid file".** `delegate.ps1` runs the readiness gate before calling `Invoke-DelegateSandboxRun` and writes `probe-<hex>.pid` only once the gate is ready. A `-SandboxRun -Feature` that returns `environment-missing` runs nothing, holds no slot and writes no pid file.
3. **Files, `skills/feature/stages/build.md`.** At phase end, a second `sandbox: no free slot` is a problem stop, as for `slot-busy` in `verify` (drift check fix).
