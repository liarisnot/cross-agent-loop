# AppContainer feasibility probe (2026-11-13)

Throwaway scripts behind the `worker-sandbox` design decision (`../worker-sandbox.md`). They are kept because `SandboxNative.cs` is built from the launcher in `probe5.ps1`, and because the debugging steps below took hours to find. They are not part of the skill. Run them only from a non-elevated PowerShell 7.

## Files

| File | What it does |
|---|---|
| `probe5.ps1` | The outer probe. It creates the AppContainer profile (C# class `AC`: `CreateAppContainerProfile`, then `CreateProcessW` with `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES` = `0x00020009` and `internetClient` = `S-1-15-3-1`), plants canaries in `%USERPROFILE%` and `D:\`, grants the container its work folder `D:\xagent-ac-probe`, maps the Cursor install to `T:` and the work folder to `W:` with `subst`, and runs `inner*.ps1` inside the container. Its `finally` block removes everything: letters, grants, canaries and profile. Edit the `inner*.ps1` name on the `Copy-Item` line to pick which inner script runs. |
| `inner2.ps1` | Isolation checks (canaries, profile, `~\.ssh`, other repos, `D:\`) and tool checks (git, Pester, child processes, kill, internet, node). |
| `inner5.ps1` | A full Cursor CLI run inside the container on the patched `node.exe`, told to read the canaries. |
| `inner7.ps1` | `localhost` inside the container, and Node `realpathSync`/`require` under a `D:\` path. |
| `trace.js` | A Node `-r` preload that logs fs, child_process, net, dns, native add-on loads and a heartbeat to `$XTRACE_LOG`. It has a re-entry guard: `appendFileSync` calls the wrapped `writeFileSync`. |
| `stack.ps1` | Dumps the native stacks of every thread of another process with `dbghelp.dll` (export symbols only). **Never run it on its own process**: suspending its own threads deadlocks the shell. |

`probe5.ps1` expects `nodelocal\node.exe` next to it: a copy of Cursor's `node.exe` with the pipe-name patch. The patch is one equal-length byte replacement of `\\?\pipe\uv\%llu-%lu` with `\\?\pipe\LOCAL\%llu` plus a null byte (found at file offset `0x55df524` in Cursor `2026.11.11-043ef28`). `Sandbox.psm1` will do this step. For a manual run, read the bytes, check that the pattern occurs once, overwrite it, and write the copy.

## Findings not in the design doc

*   **Windows PowerShell 5.1 does not start inside an AppContainer.** It fails with "Cannot find drive Microsoft.PowerShell.Core\FileSystem". `delegate.ps1` today launches the Cursor CLI through `powershell.exe -File cursor-agent.ps1`, so the sandboxed launch must start `node.exe index.js` directly. PowerShell 7 works.
*   **A `subst` drive does not hide the real path from git.** The first try mapped a work folder under `%TEMP%` (inside the user profile) to `W:`. git resolved `W:` back to `C:\Users\...` and failed with "cannot lock ref 'HEAD': unable to create directory" when it stat-ed `C:\Users`. Moving the work folder to `D:\xagent-ac-probe` fixed git: git checks every parent folder but never the drive root. So worktrees must not live under the user profile.
*   **Node does check the drive root.** `fs.realpathSync`, and so `require`, fail with `EPERM: lstat 'D:\'` for any normal path. `subst` makes the target a drive root, which works. Cursor's own workspace handling uses the native `fs.promises.realpath` and does not hit this.
*   **How the Cursor hang was found.**
    *   No child process was started, and the JS tracer stopped right after `os.availableParallelism()` in `local-exec`.
    *   An inspector `Debugger.pause` from a worker thread never landed, which meant the main thread was in native code.
    *   A `dbghelp` stack dump showed `uv_spawn` → `uv_pipe` → `CreateNamedPipeA`, spinning.
    *   Searching that symptom found libuv#5178.
    *   Spawning with `stdio: 'ignore'` or `'inherit'` works; only `'pipe'` hangs.
*   **`taskkill.exe` hangs inside the container,** even against the container's own child. `Process.Kill($true)` and `Stop-Process` work.
*   **`cscript.exe` fails inside the container** with "Loading your settings failed (Access is denied)". Outside the container, Cursor runs `cscript //E:jscript identity.js` (WMI) at startup to check its `.running` markers. Inside the container that check fails quietly and the run still works. Stale `.running` markers may build up in the runtime cache. `Sandbox.psm1` can clear them when no run is live.
*   **Cursor prints a warning to stdout after its JSON result** when `LOCALAPPDATA` differs from the real one: "Could not add the install directory to the user PATH: … reg.exe add HKCU\Environment … Access is denied". The container blocks the registry write, which is the wanted result. `delegate.ps1` reads the last stdout line that starts with `{`, so parsing is unaffected, but `stdout.json` is not pure JSON.
*   **Pester's TestRegistry** has to be off inside the container (`TestRegistry.Enabled = $false`).
*   **Pester under `OneDrive\Documents` is unreadable** to the container. Installing Pester for all users (`Install-Module Pester -RequiredVersion 6.2.0 -Scope AllUsers -SkipPublisherCheck`, admin) puts it in `C:\Program Files\PowerShell\Modules`, which containers can read with no grant. `-SkipPublisherCheck` is needed because Windows ships Pester 3.4.0 signed by a different certificate.
*   **`localhost` works inside one container,** both in-process and to a child server process. No loopback exemption is needed for that.
*   **The host's `localhost` is blocked from a container, and an admin loopback exemption opens it** (`loopback.ps1`, run 2026-11-14).
    *   The probe started a node HTTP server on the host at `127.0.0.1:47614`.
    *   From the container, requests to `127.0.0.1` and to `localhost` timed out.
    *   The user then ran `CheckNetIsolation LoopbackExempt -a -p=<container SID>` (admin, printed "OK."). Both requests then succeeded.
    *   After `CheckNetIsolation LoopbackExempt -d -p=<SID>`, both were blocked again.
    *   The exemption belongs to one container identity and opens every host port, so it is how ComfyUI or Ollama on the host can be reached. `ac-native.ps1` holds the `AC` launcher class that `loopback.ps1` loads.
