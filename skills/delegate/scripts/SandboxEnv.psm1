#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Sandbox.psm1') -DisableNameChecking


function Get-SandboxTomlLines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    return @($Text -split "`r?`n")
}

function Test-SandboxTomlCommentLine([string]$Line) {
    $t = $Line.TrimStart()
    return $t.StartsWith('#')
}

function Get-SandboxTomlValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [AllowEmptyString()][Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    $lines = Get-SandboxTomlLines $Text
    $inSection = [string]::IsNullOrEmpty($Section)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*"([^"]*)"\s*$'

    foreach ($line in $lines) {
        if (Test-SandboxTomlCommentLine $line) { continue }
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]\s*$') {
            $header = $Matches[1].Trim()
            if ([string]::IsNullOrEmpty($Section)) { break }
            $inSection = ($header -ceq $Section)
            continue
        }
        if (-not $inSection) { continue }
        if ($trim -match $pattern) { return $Matches[1] }
    }
    return $null
}

function Test-SandboxTomlSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [AllowEmptyString()][Parameter(Mandatory)][string]$Section
    )

    $target = "[$Section]"
    foreach ($line in (Get-SandboxTomlLines $Text)) {
        if (Test-SandboxTomlCommentLine $line) { continue }
        if ($line.Trim() -ceq $target) { return $true }
    }
    return $false
}

function Get-SandboxLicenseFileFromPyproject([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $lines = Get-SandboxTomlLines $Text
    $inProject = $false
    $pattern = '^\s*license\s*=\s*\{\s*file\s*=\s*"([^"]+)"\s*\}'

    foreach ($line in $lines) {
        if (Test-SandboxTomlCommentLine $line) { continue }
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]\s*$') {
            $inProject = ($Matches[1].Trim() -ceq 'project')
            continue
        }
        if (-not $inProject) { continue }
        if ($trim -match $pattern) { return $Matches[1] }
    }
    return $null
}

function Convert-SandboxRequiresPythonClause([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return $null }
    $c = ($Clause -replace '\s', '')
    if ($c -match '^>=(\d+)\.(\d+)(?:\.\d+)?$') { return "$($Matches[1]).$($Matches[2])" }
    if ($c -match '^~=(\d+)\.(\d+)$') { return "$($Matches[1]).$($Matches[2])" }
    if ($c -match '^==(\d+)\.(\d+)\.\*$') { return "$($Matches[1]).$($Matches[2])" }
    if ($c -match '^==(\d+)\.(\d+)\.\d+$') { return "$($Matches[1]).$($Matches[2])" }
    if ($c -match '^>(\d+)\.(\d+)$') {
        $minor = [int]$Matches[2] + 1
        return "$($Matches[1]).$minor"
    }
    return $null
}

function Get-SandboxInterpreterRequest {
    param(
        [string]$Kind,
        [string]$PyprojectText,
        [string]$UvLockText,
        [string]$DotPythonVersionText
    )

    if (-not [string]::IsNullOrWhiteSpace($DotPythonVersionText)) {
        $line = @($DotPythonVersionText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($line) { return $line.Trim() }
    }

    $spec = $null
    # A requirements-only project has no pyproject.toml text; an empty text means no requires-python.
    if ($Kind -eq 'lock') {
        if (-not [string]::IsNullOrEmpty($UvLockText)) { $spec = Get-SandboxTomlValue -Text $UvLockText -Section '' -Key 'requires-python' }
    } else {
        if (-not [string]::IsNullOrEmpty($PyprojectText)) { $spec = Get-SandboxTomlValue -Text $PyprojectText -Section 'project' -Key 'requires-python' }
    }
    if ([string]::IsNullOrWhiteSpace($spec)) { return $null }

    foreach ($clause in ($spec -split ',')) {
        $req = Convert-SandboxRequiresPythonClause $clause
        if ($null -ne $req) { return $req }
    }
    return $null
}


function Get-SandboxGitTreeMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Commit
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $null = $psi.ArgumentList.Add('-C')
    $null = $psi.ArgumentList.Add($Repo)
    $null = $psi.ArgumentList.Add('ls-tree')
    $null = $psi.ArgumentList.Add('-r')
    $null = $psi.ArgumentList.Add('-z')
    $null = $psi.ArgumentList.Add('--full-tree')
    $null = $psi.ArgumentList.Add($Commit)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $raw = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "sandbox: cannot read $Commit in $Repo" }
    } finally { $proc.Dispose() }

    $map = @{}
    if ([string]::IsNullOrEmpty($raw)) { return $map }

    foreach ($entry in ($raw -split "`0")) {
        if ([string]::IsNullOrEmpty($entry)) { continue }
        $tab = $entry.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $meta = $entry.Substring(0, $tab)
        $path = $entry.Substring($tab + 1) -replace '\\', '/'
        $parts = $meta -split '\s+', 4
        if ($parts.Count -lt 3) { continue }
        $map[$path] = $parts[2]
    }
    return $map
}

function Get-SandboxGitFileText {
    param([string]$Repo, [string]$Commit, [string]$Path)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $null = $psi.ArgumentList.Add('-C')
    $null = $psi.ArgumentList.Add($Repo)
    $null = $psi.ArgumentList.Add('show')
    $null = $psi.ArgumentList.Add("${Commit}:${Path}")
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { return $null }
        return $stdout
    } finally { $proc.Dispose() }
}

function Get-SandboxProjectFolder([string]$RepoRelativeFile) {
    $path = $RepoRelativeFile -replace '\\', '/'
    $idx = $path.LastIndexOf('/')
    if ($idx -lt 0) { return '.' }
    return $path.Substring(0, $idx)
}

function Test-SandboxAncestorLockProject {
    param([string]$Folder, [System.Collections.Generic.HashSet[string]]$LockFolders)

    if ($Folder -eq '.') { return $false }
    foreach ($lf in $LockFolders) {
        if ($lf -eq '.') { continue }   # a root lock does not cover separate projects in subfolders
        if ($Folder -eq $lf -or $Folder.StartsWith("$lf/", [StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Get-SandboxProjectDepth([string]$Project) {
    if ($Project -eq '.') { return 0 }
    return @($Project -split '/').Count
}

function Get-SandboxHashRelativePath {
    param([string]$Project, [string]$RepoPath)

    $repoPath = $RepoPath -replace '\\', '/'
    $project = $Project -replace '\\', '/'
    if ($project -eq '.') { return $repoPath }
    $prefix = "$project/"
    if ($repoPath.StartsWith($prefix, [StringComparison]::Ordinal)) {
        return $repoPath.Substring($prefix.Length)
    }
    $depth = Get-SandboxProjectDepth $project
    $up = if ($depth -eq 0) { '' } else { ('../' * $depth) }
    return "${up}$repoPath"
}

function Get-SandboxProjectHash {
    param([string[]]$InputPaths, [hashtable]$TreeMap, [string]$Project)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $InputPaths) {
        $norm = $p -replace '\\', '/'
        if (-not $TreeMap.ContainsKey($norm)) { continue }
        $rel = Get-SandboxHashRelativePath -Project $Project -RepoPath $norm
        $lines.Add("$rel`t$($TreeMap[$norm])")
    }
    $lines.Sort([StringComparer]::Ordinal)
    $text = ($lines | ForEach-Object { "$_`n" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
    } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Find-SandboxDotPythonVersionPath {
    param([string]$Project, [hashtable]$TreeMap)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Project -eq '.') {
        $candidates.Add('.python-version')
    } else {
        $parts = @($Project -split '/')
        for ($i = $parts.Count; $i -ge 0; $i--) {
            if ($i -eq 0) { $candidates.Add('.python-version') }
            else {
                $prefix = ($parts[0..($i - 1)] -join '/')
                $candidates.Add("$prefix/.python-version")
            }
        }
    }
    foreach ($c in $candidates) {
        if ($TreeMap.ContainsKey($c)) { return $c }
    }
    return $null
}


function Test-SandboxTestDataPath([string]$Path) {
    foreach ($seg in ($Path -split '/')) {
        if (@('fixtures', 'testdata', 'test_data', '__fixtures__') -contains $seg.ToLowerInvariant()) { return $true }
    }
    return $false
}

function Get-SandboxEnvProjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Commit
    )

    $tree = Get-SandboxGitTreeMap -Repo $Repo -Commit $Commit
    # Test data is not a project: skip anything under a fixtures/testdata folder.
    $paths = @($tree.Keys | Where-Object { -not (Test-SandboxTestDataPath $_) })

    $lockFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($p in $paths) {
        if ((Split-Path -Leaf $p) -ceq 'uv.lock') {
            [void]$lockFolders.Add((Get-SandboxProjectFolder $p))
        }
    }

    $projectFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($lf in $lockFolders) { [void]$projectFolders.Add($lf) }

    foreach ($p in $paths) {
        $folder = Get-SandboxProjectFolder $p
        if ($projectFolders.Contains($folder)) { continue }
        $leaf = Split-Path -Leaf $p
        $isPyproject = ($leaf -ceq 'pyproject.toml')
        $isReq = ($leaf.ToLowerInvariant() -match '^requirements.*\.txt$')
        if (-not $isPyproject -and -not $isReq) { continue }
        if (Test-SandboxAncestorLockProject -Folder $folder -LockFolders $lockFolders) { continue }
        [void]$projectFolders.Add($folder)
    }
    $sortedList = [System.Collections.Generic.List[string]]::new()
    foreach ($pf in $projectFolders) { $sortedList.Add([string]$pf) }
    $sortedList.Sort([StringComparer]::Ordinal)
    $sortedProjects = $sortedList.ToArray()

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($project in $sortedProjects) {
        $kind = if ($lockFolders.Contains($project)) { 'lock' } else { 'resolve' }

        $inputs = [System.Collections.Generic.List[string]]::new()
        $candidates = if ($project -eq '.') {
            @('uv.lock', 'pyproject.toml', 'uv.toml')
        } else {
            @("$project/uv.lock", "$project/pyproject.toml", "$project/uv.toml")
        }
        foreach ($c in $candidates) {
            if ($tree.ContainsKey($c)) { $inputs.Add($c) }
        }

        foreach ($p in $paths) {
            if ((Get-SandboxProjectFolder $p) -cne $project) { continue }
            $leaf = Split-Path -Leaf $p
            if ($leaf.ToLowerInvariant() -match '^requirements.*\.txt$') { $inputs.Add($p) }
        }

        $pyPath = if ($project -eq '.') { 'pyproject.toml' } else { "$project/pyproject.toml" }
        $pyprojectText = $null
        if ($tree.ContainsKey($pyPath)) {
            $pyprojectText = Get-SandboxGitFileText -Repo $Repo -Commit $Commit -Path $pyPath
            $readme = Get-SandboxTomlValue -Text $pyprojectText -Section 'project' -Key 'readme'
            if ($readme) {
                $readmePath = if ($project -eq '.') { $readme } else { "$project/$readme" }
                if ($tree.ContainsKey($readmePath)) { $inputs.Add($readmePath) }
            }
            $licenseFile = Get-SandboxLicenseFileFromPyproject -Text $pyprojectText
            if ($licenseFile) {
                $licensePath = if ($project -eq '.') { $licenseFile } else { "$project/$licenseFile" }
                if ($tree.ContainsKey($licensePath)) { $inputs.Add($licensePath) }
            }
        }

        $dotPyPath = Find-SandboxDotPythonVersionPath -Project $project -TreeMap $tree
        $dotPyText = $null
        if ($dotPyPath) {
            $inputs.Add($dotPyPath)
            $dotPyText = Get-SandboxGitFileText -Repo $Repo -Commit $Commit -Path $dotPyPath
        }

        $inputArr = [System.Collections.Generic.List[string]]::new()
        foreach ($inputPath in $inputs) { $inputArr.Add([string]$inputPath) }
        $inputArr.Sort([StringComparer]::Ordinal)
        $inputArr = $inputArr.ToArray()

        $uvLockPath = if ($project -eq '.') { 'uv.lock' } else { "$project/uv.lock" }
        $uvLockText = $null
        if ($tree.ContainsKey($uvLockPath)) {
            $uvLockText = Get-SandboxGitFileText -Repo $Repo -Commit $Commit -Path $uvLockPath
        }

        $hash = Get-SandboxProjectHash -InputPaths $inputArr -TreeMap $tree -Project $project
        $request = Get-SandboxInterpreterRequest -Kind $kind -PyprojectText $pyprojectText `
            -UvLockText $uvLockText -DotPythonVersionText $dotPyText

        $status = $null
        $reason = $null
        if ($pyprojectText -and (Test-SandboxTomlSection -Text $pyprojectText -Section 'tool.uv.workspace')) {
            $status = 'unsupported'
            $reason = 'workspace'
        } elseif ($null -eq $request) {
            $status = 'unsupported'
            $reason = 'python-version-unknown'
        }

        $results.Add([pscustomobject]@{
                project = $project
                kind    = $kind
                status  = $status
                reason  = $reason
                hash    = $hash
                request = $request
                inputs  = $inputArr
            })
    }
    return @($results)
}

function Get-SandboxUvPath {
    if (-not [string]::IsNullOrWhiteSpace($env:XAGENT_UV_PATH)) { return $env:XAGENT_UV_PATH }
    $cmds = @(Get-Command uv -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmds.Count -eq 0) { return $null }
    return [string]$cmds[0].Source
}

function Invoke-SandboxUv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory,
        [hashtable]$Environment
    )

    $uvPath = Get-SandboxUvPath
    if ($null -eq $uvPath) { throw 'sandbox: uv not found' }

    $saved = @{}
    if ($null -ne $Environment) {
        foreach ($key in @($Environment.Keys)) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key)
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
        }
    }

    $stderrFile = [IO.Path]::GetTempFileName()
    $pushed = $false
    try {
        if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory; $pushed = $true }
        $stdout = & $uvPath @Arguments 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $stderr = @()
        if (Test-Path -LiteralPath $stderrFile) {
            $rawErr = Get-Content -LiteralPath $stderrFile -ErrorAction SilentlyContinue
            if ($null -ne $rawErr) {
                $stderr = if ($rawErr -is [string]) { @([string]$rawErr) } else { @($rawErr | ForEach-Object { [string]$_ }) }
            }
        }
        $stdoutArr = [string[]]@()
        if ($null -ne $stdout) {
            if ($stdout -is [System.Array]) {
                $stdoutArr = [string[]]@($stdout | ForEach-Object { [string]$_ })
            } else {
                $stdoutArr = [string[]]@([string]$stdout)
            }
        }
        $stderr = [string[]]$stderr
        return @{ exitCode = $exitCode; stdout = $stdoutArr; stderr = $stderr }
    } finally {
        if ($pushed) { Pop-Location }
        foreach ($key in @($saved.Keys)) {
            $old = $saved[$key]
            if ($null -eq $old) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
            else { [Environment]::SetEnvironmentVariable($key, $old, 'Process') }
        }
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-SandboxEnvsRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo
    )
    $full = [IO.Path]::GetFullPath($Repo).TrimEnd('\', '/')
    $parent = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full
    return Join-Path $parent "$leaf.xagent\.envs"
}

function New-SandboxEmptyEnvsIndex {
    return @{
        version   = $null
        approved  = $null
        uv        = $null
        uvVersion = $null
        pythons   = @{}
        envs      = @{}
        failed    = @{}
    }
}

function Read-SandboxEnvsIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvsRoot
    )

    $path = Join-Path $EnvsRoot 'envs.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ index = (New-SandboxEmptyEnvsIndex); warning = $null }
    }

    try {
        $raw = [IO.File]::ReadAllText($path)
        $parsed = $raw | ConvertFrom-Json -AsHashtable
        if ($null -eq $parsed -or $parsed -isnot [hashtable]) {
            return @{ index = (New-SandboxEmptyEnvsIndex); warning = 'envs.json unreadable; rebuilding on -Apply' }
        }
    } catch {
        return @{ index = (New-SandboxEmptyEnvsIndex); warning = 'envs.json unreadable; rebuilding on -Apply' }
    }

    $index = New-SandboxEmptyEnvsIndex
    foreach ($key in @('version', 'approved', 'uv', 'uvVersion')) {
        if ($parsed.ContainsKey($key)) { $index[$key] = $parsed[$key] }
    }
    foreach ($mapKey in @('pythons', 'envs', 'failed')) {
        $val = $parsed[$mapKey]
        if ($val -is [hashtable]) { $index[$mapKey] = $val } else { $index[$mapKey] = @{} }
    }
    return @{ index = $index; warning = $null }
}

function Get-SandboxEnvName {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Request,
        [Parameter(Mandatory)][string]$Hash
    )
    if ([string]::IsNullOrWhiteSpace($Request)) { return $null }
    if ($Request -notmatch '^(\d+)\.(\d+)') { return $null }
    $majorMinor = "$($Matches[1]).$($Matches[2])"
    $short = if ($Hash.Length -ge 12) { $Hash.Substring(0, 12) } else { $Hash }
    return "py$majorMinor-$short"
}

function Get-SandboxEnvIndexEnvEntry {
    param([hashtable]$Index, [string]$Hash)
    if (-not $Index.envs.ContainsKey($Hash)) { return $null }
    $entry = $Index.envs[$Hash]
    if ($entry -isnot [hashtable]) { return $null }
    $name = $entry['name']
    if ($name -isnot [string]) { return $null }
    return $entry
}

function Get-SandboxEnvIndexFailedEntry {
    param([hashtable]$Index, [string]$Hash)
    if (-not $Index.failed.ContainsKey($Hash)) { return $null }
    $entry = $Index.failed[$Hash]
    if ($entry -isnot [hashtable]) { return $null }
    return $entry
}

function Test-SandboxProjectStale {
    param([string]$Project, [string]$Hash, [hashtable]$Index)

    foreach ($key in @($Index.envs.Keys)) {
        if ($key -ceq $Hash) { continue }
        $entry = $Index.envs[$key]
        if ($entry -is [string] -or $entry -isnot [System.Collections.IDictionary]) { continue }
        $projs = $entry['projects']
        if ($projs -isnot [System.Array]) { continue }
        foreach ($p in $projs) {
            if ([string]$p -ceq $Project) { return $true }
        }
    }
    return $false
}

function Get-SandboxEnvStatuses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Projects,
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)][string]$EnvsRoot,
        [AllowNull()][string]$UvPath
    )

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($proj in $Projects) {
        $project = [string]$proj.project
        $kind = [string]$proj.kind
        $hash = [string]$proj.hash
        $request = $proj.request
        $python = $request
        $env = $null
        $status = $null
        $reason = $null

        if ([string]::IsNullOrEmpty($UvPath)) {
            $status = 'unsupported'
            $reason = 'uv-missing'
        } elseif ($null -ne $proj.status -and $proj.status -ceq 'unsupported') {
            $status = 'unsupported'
            $reason = [string]$proj.reason
        } else {
            $env = Get-SandboxEnvName -Request $request -Hash $hash
            $envEntry = Get-SandboxEnvIndexEnvEntry -Index $Index -Hash $hash
            $ready = $false
            if ($null -ne $envEntry) {
                $pyExe = Join-Path $EnvsRoot (Join-Path $envEntry['name'] 'Scripts\python.exe')
                if (Test-Path -LiteralPath $pyExe) { $ready = $true }
            }
            if ($ready) {
                $status = 'ready'
                $reason = $null
            } else {
                $failedEntry = Get-SandboxEnvIndexFailedEntry -Index $Index -Hash $hash
                if ($null -ne $failedEntry) {
                    $status = 'install-failed'
                    $err = $failedEntry['error']
                    $reason = if ($err -is [string]) { $err } else { [string]$err }
                } elseif (Test-SandboxProjectStale -Project $project -Hash $hash -Index $Index) {
                    $status = 'stale'
                    $reason = $null
                } else {
                    $status = 'missing'
                    $reason = $null
                }
            }
        }

        if ($status -ceq 'unsupported') { $env = $null }

        $results.Add([ordered]@{
                project = $project
                kind    = $kind
                status  = $status
                reason  = $reason
                env     = $env
                python  = $python
                hash    = $hash
            })
    }
    return @($results)
}

function Get-SandboxWheelTags {
    param([string]$FileName)

    if (-not $FileName.EndsWith('.whl', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $base = $FileName.Substring(0, $FileName.Length - 4)
    if ($base -match '-(?<py>cp\d+|py\d+(?:\.py\d+)?)-(?<abi>[^-]+)-(?<plat>[^-]+)$') {
        return @{ python = $Matches['py']; abi = $Matches['abi']; platform = $Matches['plat'] }
    }
    if ($base -match '-(?<py>cp\d+)-(?<plat>win_amd64)$') {
        return @{ python = $Matches['py']; abi = 'none'; platform = $Matches['plat'] }
    }
    return $null
}

function Test-SandboxWheelMatches {
    param(
        [string]$FileName,
        [string]$Request
    )

    $tags = Get-SandboxWheelTags -FileName $FileName
    if ($null -eq $tags) { return $false }
    if ($tags.platform -cne 'win_amd64' -and $tags.platform -cne 'any') { return $false }

    if ($tags.python -ceq 'py3' -or $tags.python -ceq 'py2.py3') { return $true }
    if ($tags.abi -ceq 'abi3') { return $true }
    if ($Request -match '^(\d+)\.(\d+)') {
        $want = "cp$($Matches[1])$($Matches[2])"
        if ($tags.python -ceq $want) { return $true }
    }
    return $false
}

function Split-SandboxUvLockPackages {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = @($Text -split "`r?`n")
    $blocks = [System.Collections.Generic.List[string]]::new()
    $current = [System.Collections.Generic.List[string]]::new()
    $inPackage = $false
    foreach ($line in $lines) {
        if ($line.Trim() -ceq '[[package]]') {
            if ($current.Count -gt 0) {
                $blocks.Add(($current -join "`n"))
                $current.Clear()
            }
            $inPackage = $true
            continue
        }
        if ($inPackage) { $current.Add($line) }
    }
    if ($current.Count -gt 0) { $blocks.Add(($current -join "`n")) }
    return @($blocks)
}

function Test-SandboxSkipUvLockPackage {
    param([string]$Block)

    foreach ($line in ($Block -split "`r?`n")) {
        if ($line -match '^\s*source\s*=\s*\{') {
            if ($line -match 'editable|virtual|directory') { return $true }
        }
    }
    return $false
}

function Get-SandboxUvLockPackageWheels {
    param([string]$Block)

    # A wheel entry has a url; size is optional (the PyTorch index records none).
    $wheels = [System.Collections.Generic.List[hashtable]]::new()
    $inWheels = $false
    foreach ($line in ($Block -split "`r?`n")) {
        $trim = $line.Trim()
        if ($trim -match '^wheels\s*=\s*\[') { $inWheels = $true; continue }
        if ($inWheels) {
            if ($trim -eq ']') { break }
            if ($line -match '\{' -and $line -match 'url\s*=\s*"([^"]+)"') {
                $url = $Matches[1]
                $size = $null
                if ($line -match 'size\s*=\s*(\d+)') { $size = [long]$Matches[1] }
                $seg = ($url -split '/')[-1]
                $wheels.Add(@{ file = $seg; size = $size })
            }
        }
    }
    return @($wheels)
}

function Measure-SandboxUvLockEstimate {
    param(
        [string]$LockText,
        [string]$Request
    )

    # Returns $null when the lock cannot be read, else @{ bytes; unknown }. bytes sums the
    # recorded download sizes; unknown lists packages whose size the lock does not record.
    if ([string]::IsNullOrEmpty($LockText)) { return $null }
    $sum = [long]0
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($block in (Split-SandboxUvLockPackages $LockText)) {
        if (Test-SandboxSkipUvLockPackage $block) { continue }
        $name = if ($block -match '(?m)^\s*name\s*=\s*"([^"]+)"') { $Matches[1] } else { '?' }
        $wheels = @(Get-SandboxUvLockPackageWheels $block)
        if ($wheels.Count -eq 0) {
            # Source only: count the source download.
            if ($block -match '(?m)^\s*sdist\s*=\s*\{[^}]*size\s*=\s*(\d+)') { $sum += [long]$Matches[1] }
            else { $unknown.Add($name) }
            continue
        }
        $matching = @($wheels | Where-Object { Test-SandboxWheelMatches -FileName $_.file -Request $Request })
        if ($matching.Count -eq 0) { continue }   # not installed on Windows
        $sized = @($matching | Where-Object { $null -ne $_.size })
        if ($sized.Count -eq 0) { $unknown.Add($name); continue }
        $best = [long]0
        foreach ($w in $sized) { if ($w.size -gt $best) { $best = $w.size } }
        $sum += $best
    }
    return @{ bytes = $sum; unknown = @($unknown) }
}

function Get-SandboxEnvMajorMinor {
    param([string]$Request)
    if ([string]::IsNullOrWhiteSpace($Request)) { return $null }
    if ($Request -match '^(\d+)\.(\d+)') { return "$($Matches[1]).$($Matches[2])" }
    return $null
}

function Test-SandboxInterpreterInstalled {
    param([hashtable]$Index, [string]$MajorMinor)

    foreach ($key in @($Index.pythons.Keys)) {
        if ([string]$key -ceq $MajorMinor) { return $true }
        if ([string]$key.StartsWith("$MajorMinor.", [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-SandboxEnvEstimate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][object[]]$Statuses,
        [Parameter(Mandatory)][hashtable]$Index
    )

    $seenHash = @{}
    $envNames = [System.Collections.Generic.List[string]]::new()
    $majMins = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    $estimateSum = [long]0
    $bytesKnown = $true

    foreach ($st in $Statuses) {
        if ($st.status -cnotin @('missing', 'stale', 'install-failed')) { continue }
        $hash = [string]$st.hash
        if ($seenHash.ContainsKey($hash)) { continue }
        $seenHash[$hash] = $true
        if (-not [string]::IsNullOrEmpty($st.env)) { $envNames.Add([string]$st.env) }

        $majMin = Get-SandboxEnvMajorMinor -Request $st.python
        if ($majMin -and -not $majMins.Contains($majMin)) { $majMins.Add($majMin) }

        if ($st.kind -ceq 'resolve') { $bytesKnown = $false; continue }

        $lockPath = if ($st.project -ceq '.') { 'uv.lock' } else { "$($st.project)/uv.lock" }
        $lockText = Get-SandboxGitFileText -Repo $Repo -Commit $Commit -Path $lockPath
        $m = Measure-SandboxUvLockEstimate -LockText $lockText -Request $st.python
        if ($null -eq $m) { $bytesKnown = $false; continue }
        $estimateSum += $m.bytes
        foreach ($u in $m.unknown) { if (-not $unknown.Contains($u)) { $unknown.Add($u) } }
    }

    $newInterpreters = [System.Collections.Generic.List[string]]::new()
    foreach ($mm in $majMins) {
        if (-not (Test-SandboxInterpreterInstalled -Index $Index -MajorMinor $mm)) { $newInterpreters.Add($mm) }
    }
    $newInterpreters.Sort([StringComparer]::Ordinal)
    $unknown.Sort([StringComparer]::Ordinal)

    $bytes = $null
    $seconds = $null
    if ($bytesKnown) {
        $bytes = [long][math]::Round($estimateSum * 2.5) + ($newInterpreters.Count * 100000000)
        $seconds = [int][math]::Ceiling(30 + ($bytes / 20000000.0))
    }
    return @{
        bytes        = $bytes
        seconds      = $seconds
        interpreters = @($newInterpreters)
        envs         = @($envNames)
        unknown      = @($unknown)
    }
}

function Test-SandboxEnvNeedsApproval {
    param(
        $Approved,
        $EstimateBytes
    )
    if ($null -eq $Approved) { return $true }
    if ($null -ne $EstimateBytes -and $EstimateBytes -gt 5000000000) { return $true }
    return $false
}

function Get-SandboxEnvProposalText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvsRoot,
        [Parameter(Mandatory)][int]$EnvCount,
        [Parameter(Mandatory)][string[]]$Projects,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Interpreters,
        [AllowEmptyCollection()][string[]]$Unknown = @(),
        $Bytes,
        $Seconds,
        [Parameter(Mandatory)][long]$EnvsBytes
    )

    if ($EnvCount -eq 0) { return '' }
    $envWord = if ($EnvCount -eq 1) { 'environment' } else { 'environments' }
    $projList = ($Projects -join ', ')

    $interpPart = ''
    if ($Interpreters.Count -gt 0) {
        $m = $Interpreters.Count
        $iWord = if ($m -eq 1) { 'interpreter' } else { 'interpreters' }
        $interpPart = " and $m $iWord ($($Interpreters -join ', '))"
    }

    if ($null -eq $Bytes) {
        $estPart = 'size and time unknown'
    } else {
        $gb = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', $Bytes / 1000000000.0)
        $min = [int][math]::Ceiling($Seconds / 60.0)
        $minWord = if ($min -eq 1) { 'minute' } else { 'minutes' }
        $estPart = "about $gb GB and $min $minWord"
        if ($Unknown.Count -gt 0) {
            $estPart = "$estPart, plus $($Unknown -join ', ') (size not recorded in uv.lock)"
        }
    }

    $envsGb = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', $EnvsBytes / 1000000000.0)
    return "Build $EnvCount $envWord ($projList)$interpPart in ${EnvsRoot}: $estPart; .envs is now $envsGb GB."
}

function Get-SandboxGitCommit {
    param([string]$Repo, [string]$Ref)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $null = $psi.ArgumentList.Add('-C')
    $null = $psi.ArgumentList.Add($Repo)
    $null = $psi.ArgumentList.Add('rev-parse')
    $null = $psi.ArgumentList.Add('--verify')
    $null = $psi.ArgumentList.Add("${Ref}^{commit}")
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $proc.StandardOutput.ReadToEnd().Trim()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            throw "sandbox: cannot read $Ref in $Repo"
        }
        return $stdout
    } finally { $proc.Dispose() }
}

function Get-SandboxEnvsBytesTotal {
    param([hashtable]$Index)

    $sum = [long]0
    foreach ($key in @($Index.envs.Keys)) {
        $entry = $Index.envs[$key]
        if ($entry -is [string] -or $entry -isnot [System.Collections.IDictionary]) { continue }
        $b = $entry['bytes']
        if ($b -is [int] -or $b -is [long] -or $b -is [double] -or $b -is [decimal]) {
            $sum += [long]$b
        }
    }
    return $sum
}

function Get-SandboxEnvReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Ref
    )

    $commit = Get-SandboxGitCommit -Repo $Repo -Ref $Ref
    $uvPath = Get-SandboxUvPath
    $envsRoot = Get-SandboxEnvsRoot -Repo $Repo
    $read = Read-SandboxEnvsIndex -EnvsRoot $envsRoot
    $index = $read.index

    $discovered = @(Get-SandboxEnvProjects -Repo $Repo -Commit $commit); if ($null -eq $discovered) { $discovered = @() }
    if ($discovered.Count -eq 0) { $statuses = @() } else { $statuses = @(Get-SandboxEnvStatuses -Projects $discovered -Index $index -EnvsRoot $envsRoot -UvPath $uvPath) }

    $projectOut = [System.Collections.Generic.List[object]]::new()
    foreach ($st in $statuses) {
        $projectOut.Add([ordered]@{
                project = $st.project
                kind    = $st.kind
                status  = $st.status
                reason  = $st.reason
                env     = $st.env
                python  = $st.python
            })
    }

    $toBuild = @($statuses | Where-Object { $_.status -cin @('missing', 'stale', 'install-failed') })
    $proposal = $null
    if ($toBuild.Count -gt 0) {
        $est = Get-SandboxEnvEstimate -Repo $Repo -Commit $commit -Statuses $statuses -Index $index
        $distinctProjects = [System.Collections.Generic.List[string]]::new()
        $seenProj = @{}
        foreach ($st in $statuses) {
            if ($st.status -cnotin @('missing', 'stale', 'install-failed')) { continue }
            if (-not $seenProj.ContainsKey($st.project)) {
                $seenProj[$st.project] = $true
                $distinctProjects.Add([string]$st.project)
            }
        }
        $needsApproval = Test-SandboxEnvNeedsApproval -Approved $index.approved -EstimateBytes $est.bytes
        $envsBytes = Get-SandboxEnvsBytesTotal -Index $index
        $text = Get-SandboxEnvProposalText -EnvsRoot $envsRoot -EnvCount @($est.envs).Count -Projects @($distinctProjects) `
            -Interpreters @($est.interpreters) -Unknown @($est.unknown) -Bytes $est.bytes -Seconds $est.seconds -EnvsBytes $envsBytes
        $proposal = [ordered]@{
            needsApproval   = $needsApproval
            interpreters    = @($est.interpreters)
            envs            = @($est.envs)
            estimateBytes   = $est.bytes
            estimateSeconds = $est.seconds
            unknownSize     = @($est.unknown)
            text            = $text
        }
    }

    $report = [ordered]@{
        ok        = $true
        repo      = $Repo
        ref       = $Ref
        uv        = $uvPath
        envsBytes = Get-SandboxEnvsBytesTotal -Index $index
        approved  = ($null -ne $index.approved)
        projects  = @($projectOut)
        proposal  = $proposal
    }
    if ($null -ne $read.warning) { $report['warning'] = $read.warning }
    return $report
}

function Get-SandboxEnvsLockName {
    param([Parameter(Mandatory)][string]$EnvsRoot)

    $full = [IO.Path]::GetFullPath($EnvsRoot).TrimEnd('\', '/').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full))
    } finally { $sha.Dispose() }
    $hex = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    return "Local\xagent-envs-$($hex.Substring(0, 12))"
}

function Add-SandboxEnvWarningText {
    param(
        [AllowNull()][string]$Existing,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]::IsNullOrEmpty($Existing)) { return $Message }
    return "$Existing; $Message"
}

function Remove-SandboxEnvPath {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-SandboxDirectoryLength {
    param([Parameter(Mandatory)][string]$Path)

    $sum = [long]0
    if (-not (Test-Path -LiteralPath $Path)) { return $sum }
    $dirs = [System.Collections.Generic.Stack[string]]::new()
    $dirs.Push($Path)
    while ($dirs.Count -gt 0) {
        $dir = $dirs.Pop()
        foreach ($file in [IO.Directory]::GetFiles($dir)) {
            $sum += [IO.FileInfo]::new($file).Length
        }
        foreach ($sub in [IO.Directory]::GetDirectories($dir)) { $dirs.Push($sub) }
    }
    return $sum
}

function Get-SandboxUtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-SandboxUvStreamError {
    param($Result)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($Result.stderr)) { $lines.Add([string]$line) }
    foreach ($line in @($Result.stdout)) { $lines.Add([string]$line) }
    if ($lines.Count -eq 0) { return '' }
    $start = $lines.Count - 20
    if ($start -lt 0) { $start = 0 }
    $take = [System.Collections.Generic.List[string]]::new()
    for ($i = $start; $i -lt $lines.Count; $i++) { $take.Add($lines[$i]) }
    return ($take -join "`n")
}

function Get-SandboxDictValue {
    param($Object, [string]$Key)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Key] }
    $prop = $Object.PSObject.Properties[$Key]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-SandboxEnvNameClash {
    param($Index, [string]$Name, [string]$Hash)

    foreach ($key in @($Index.envs.Keys)) {
        if ([string]::Equals([string]$key, $Hash, [StringComparison]::Ordinal)) { continue }
        $entryName = Get-SandboxDictValue -Object $Index.envs[$key] -Key 'name'
        if ($entryName -is [string] -and [string]::Equals($entryName, $Name, [StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Get-SandboxGroupProjectPaths {
    param($Projects)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($Projects)) { $names.Add([string]$p.project) }
    $arr = $names.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return @{ paths = $arr }
}

function Get-SandboxRequirementInputs {
    param($Inputs)

    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($inputPath in @($Inputs)) {
        if ([string]::IsNullOrWhiteSpace([string]$inputPath)) { continue }
        $norm = ([string]$inputPath) -replace '\\', '/'
        $leaf = [IO.Path]::GetFileName($norm)
        if ($leaf.ToLowerInvariant() -match '^requirements.*\.txt$') { $list.Add($norm) }
    }
    $arr = $list.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return @{ paths = $arr }
}

function Test-SandboxInputsHavePyproject {
    param($Inputs)

    foreach ($inputPath in @($Inputs)) {
        $norm = ([string]$inputPath) -replace '\\', '/'
        if ([string]::Equals($norm, 'pyproject.toml', [StringComparison]::Ordinal)) { return $true }
        if ($norm.EndsWith('/pyproject.toml', [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-SandboxEnvWorkDir {
    param([string]$WorkRoot, [string]$Project)

    if ([string]::Equals($Project, '.', [StringComparison]::Ordinal)) { return $WorkRoot }
    return Join-Path $WorkRoot ($Project -replace '/', [IO.Path]::DirectorySeparatorChar)
}

function Get-SandboxPthRoot {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)]$TreeMap
    )

    $project = $Project -replace '\\', '/'
    if ([string]::Equals($project, '.', [StringComparison]::Ordinal)) {
        $hasSrc = $false
        foreach ($key in @($TreeMap.Keys)) {
            if ([string]$key.StartsWith('src/', [StringComparison]::Ordinal)) { $hasSrc = $true; break }
        }
        $root = if ($hasSrc) { 'src' } else { '.' }
    } else {
        $prefix = "$project/src/"
        $hasSrc = $false
        foreach ($key in @($TreeMap.Keys)) {
            if ([string]$key.StartsWith($prefix, [StringComparison]::Ordinal)) { $hasSrc = $true; break }
        }
        $root = if ($hasSrc) { "$project/src" } else { $project }
    }
    return ($root -replace '/', '\')
}

function Write-SandboxEnvInputs {
    param(
        [string]$Repo,
        [string]$Commit,
        [string]$WorkRoot,
        $Inputs
    )

    Remove-SandboxEnvPath -Path $WorkRoot
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    foreach ($inputPath in @($Inputs)) {
        if ([string]::IsNullOrWhiteSpace([string]$inputPath)) { continue }
        $text = Get-SandboxGitFileText -Repo $Repo -Commit $Commit -Path ([string]$inputPath)
        if ($null -eq $text) { continue }
        $dest = Join-Path $WorkRoot (([string]$inputPath) -replace '/', [IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $dest
        if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        [IO.File]::WriteAllText($dest, $text, [Text.UTF8Encoding]::new($false))
    }
}

function Get-SandboxPythonProbe {
    param([Parameter(Mandatory)][string]$PythonPath)

    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        $stdout = & $PythonPath -c "import platform; print(platform.python_version())" 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $stderr = @()
        if (Test-Path -LiteralPath $stderrFile) {
            $rawErr = Get-Content -LiteralPath $stderrFile -ErrorAction SilentlyContinue
            if ($null -ne $rawErr) {
                $stderr = if ($rawErr -is [string]) { @([string]$rawErr) } else { @($rawErr | ForEach-Object { [string]$_ }) }
            }
        }
        $stdoutArr = [string[]]@()
        if ($null -ne $stdout) {
            if ($stdout -is [System.Array]) { $stdoutArr = [string[]]@($stdout | ForEach-Object { [string]$_ }) }
            else { $stdoutArr = [string[]]@([string]$stdout) }
        }
        if ($null -eq $exitCode) { $exitCode = 0 }
        return @{ exitCode = $exitCode; stdout = $stdoutArr; stderr = [string[]]$stderr }
    } catch {
        return @{ exitCode = 1; stdout = [string[]]@(); stderr = [string[]]@([string]$_.Exception.Message) }
    } finally {
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Write-SandboxEnvPthFiles {
    param(
        [string]$Repo,
        [string]$Commit,
        [string]$EnvDir,
        $Projects,
        $TreeMap
    )

    $paths = (Get-SandboxGroupProjectPaths -Projects $Projects).paths
    $n = 0
    $site = Join-Path $EnvDir 'Lib\site-packages'
    foreach ($project in @($paths)) {
        $pyPath = if ([string]::Equals([string]$project, '.', [StringComparison]::Ordinal)) {
            'pyproject.toml'
        } else {
            "$(([string]$project) -replace '\\', '/')/pyproject.toml"
        }
        $text = Get-SandboxGitFileText -Repo $Repo -Commit $Commit -Path $pyPath
        if ([string]::IsNullOrEmpty($text)) { continue }
        if (-not (Test-SandboxTomlSection -Text $text -Section 'build-system')) { continue }
        $n++
        if (-not (Test-Path -LiteralPath $site)) {
            New-Item -ItemType Directory -Force -Path $site | Out-Null
        }
        $root = Get-SandboxPthRoot -Project ([string]$project) -TreeMap $TreeMap
        $line = "import os, sys; w = os.environ.get('XAGENT_WORKTREE'); w and sys.path.append(os.path.join(w, r'$root'))"
        $pth = Join-Path $site "_xagent_$n.pth"
        [IO.File]::WriteAllText($pth, ($line + "`n"), [Text.UTF8Encoding]::new($false))
    }
}

function Write-SandboxEnvsIndex {
    param(
        [Parameter(Mandatory)][string]$EnvsRoot,
        [Parameter(Mandatory)]$Index
    )

    $payload = [ordered]@{
        version   = 1
        approved  = $Index.approved
        uv        = $Index.uv
        uvVersion = $Index.uvVersion
        pythons   = $Index.pythons
        envs      = $Index.envs
        failed    = $Index.failed
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 8
    $tmp = Join-Path $EnvsRoot 'envs.json.tmp'
    $dest = Join-Path $EnvsRoot 'envs.json'
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $dest -Force
}

function New-SandboxObjectArray {
    param([AllowNull()]$Items)

    if ($null -eq $Items) { return ,@() }
    $arr = [object[]]::new($Items.Count)
    for ($i = 0; $i -lt $Items.Count; $i++) { $arr[$i] = $Items[$i] }
    return ,$arr
}

function Add-SandboxEnvBuildFailure {
    param(
        $Index,
        $FailedNow,
        [string]$Hash,
        [string]$Name,
        [string[]]$Projects,
        [string]$ErrorText,
        [string]$EnvsRoot,
        [bool]$DeleteFolder
    )

    if ($DeleteFolder) { Remove-SandboxEnvPath -Path (Join-Path $EnvsRoot $Name) }
    $Index.failed[$Hash] = [ordered]@{
        at    = (Get-SandboxUtcStamp)
        error = $ErrorText
    }
    $FailedNow.Add([ordered]@{
            env      = $Name
            projects = $Projects
            error    = $ErrorText
        })
}


function Get-SandboxEnvBuiltTime {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return [DateTimeOffset]::MinValue }
    try {
        return [DateTimeOffset]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return [DateTimeOffset]::MinValue
    }
}

function Get-SandboxEnvLinkedStampTime {
    param([string]$StampPath)

    if (-not (Test-Path -LiteralPath $StampPath)) { return [DateTimeOffset]::MinValue }
    $item = Get-Item -LiteralPath $StampPath -Force
    return [DateTimeOffset]::new($item.LastWriteTimeUtc, [TimeSpan]::Zero)
}

function Get-SandboxEnvPruneReferenceTime {
    param(
        [string]$EnvsRoot,
        [string]$EnvName,
        [hashtable]$Entry
    )

    $stampPath = Join-Path (Join-Path $EnvsRoot 'linked') $EnvName
    $builtText = Get-SandboxDictValue -Object $Entry -Key 'built'
    if ($builtText -is [DateTimeOffset]) {
        $built = $builtText
    } elseif ($builtText -is [DateTime]) {
        $built = [DateTimeOffset]::new($builtText.ToUniversalTime(), [TimeSpan]::Zero)
    } else {
        $built = Get-SandboxEnvBuiltTime -Text $(if ($builtText -is [string]) { $builtText } else { $null })
    }
    $linked = Get-SandboxEnvLinkedStampTime -StampPath $stampPath
    if ($linked -gt $built) { return $linked }
    return $built
}

function Test-SandboxEnvPruneOld {
    param([DateTimeOffset]$Reference)

    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-14)
    return ($Reference -lt $cutoff)
}

function Get-SandboxEnvCurrentHashes {
    param([object[]]$Projects)

    $set = @{}
    foreach ($p in @($Projects)) {
        $h = Get-SandboxDictValue -Object $p -Key 'hash'
        if ($h -is [string] -and -not [string]::IsNullOrEmpty($h)) { $set[$h] = $true }
    }
    return $set
}

function Get-SandboxEnvPythonVersionsInUse {
    param([hashtable]$Index)

    $used = @{}
    foreach ($key in @($Index.envs.Keys)) {
        $entry = $Index.envs[$key]
        if ($entry -is [string] -or $entry -isnot [System.Collections.IDictionary]) { continue }
        $py = Get-SandboxDictValue -Object $entry -Key 'python'
        if ($py -is [string] -and -not [string]::IsNullOrEmpty($py)) { $used[$py] = $true }
    }
    return $used
}

function Invoke-SandboxEnvPrune {
    param(
        [hashtable]$Index,
        [string]$EnvsRoot,
        [object[]]$Projects,
        [AllowNull()][string]$Warning
    )

    $current = Get-SandboxEnvCurrentHashes -Projects $Projects
    $prunedList = [System.Collections.Generic.List[object]]::new()

    foreach ($hash in @($Index.envs.Keys)) {
        if ($current.ContainsKey($hash)) { continue }
        $entry = $Index.envs[$hash]
        if ($entry -is [string] -or $entry -isnot [System.Collections.IDictionary]) { continue }
        $name = Get-SandboxDictValue -Object $entry -Key 'name'
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) { continue }

        $refTime = Get-SandboxEnvPruneReferenceTime -EnvsRoot $EnvsRoot -EnvName $name -Entry $entry
        if (-not (Test-SandboxEnvPruneOld -Reference $refTime)) { continue }

        $bytesVal = Get-SandboxDictValue -Object $entry -Key 'bytes'
        $bytes = [long]0
        if ($bytesVal -is [int] -or $bytesVal -is [long] -or $bytesVal -is [double] -or $bytesVal -is [decimal]) {
            $bytes = [long]$bytesVal
        }

        $deleteFailed = $false
        foreach ($path in @(
                (Join-Path $EnvsRoot $name),
                (Join-Path (Join-Path $EnvsRoot 'work') $name),
                (Join-Path (Join-Path $EnvsRoot 'linked') $name)
            )) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            try {
                Remove-SandboxEnvPath -Path $path
                if (Test-Path -LiteralPath $path) { $deleteFailed = $true }
            } catch {
                $deleteFailed = $true
            }
        }

        [void]$Index.envs.Remove($hash)
        $prunedList.Add([ordered]@{ env = $name; bytes = $bytes })
        if ($deleteFailed) {
            $Warning = Add-SandboxEnvWarningText -Existing $Warning -Message "environment $name could not be fully removed"
        }
    }

    foreach ($hash in @($Index.failed.Keys)) {
        if (-not $current.ContainsKey($hash)) { [void]$Index.failed.Remove($hash) }
    }

    $inUse = Get-SandboxEnvPythonVersionsInUse -Index $Index
    foreach ($ver in @($Index.pythons.Keys)) {
        if ($inUse.ContainsKey($ver)) { continue }
        $folder = $Index.pythons[$ver]
        if ($folder -isnot [string] -or [string]::IsNullOrWhiteSpace($folder)) { continue }
        Remove-SandboxEnvPath -Path $folder
        [void]$Index.pythons.Remove($ver)
    }

    return @{
        pruned  = $prunedList
        warning = $Warning
    }
}

function Test-SandboxEnvProjectBlocks {
    param(
        [string]$Status,
        [AllowNull()][string]$Reason
    )

    if ($Status -ceq 'missing' -or $Status -ceq 'stale' -or $Status -ceq 'install-failed') { return $true }
    if ($Status -ceq 'unsupported' -and $Reason -ceq 'uv-missing') { return $true }
    return $false
}

function Get-SandboxEnvReadyMessageStatus {
    param(
        [string]$Status,
        [AllowNull()][string]$Reason,
        [bool]$UvCopyMissing
    )

    if ($UvCopyMissing) { return 'uv-copy-missing' }
    return $Status
}

function Test-SandboxEnvReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Commit
    )

    $report = Get-SandboxEnvReport -Repo $Repo -Ref $Commit
    $envsRoot = Get-SandboxEnvsRoot -Repo $Repo
    $uvExe = Join-Path (Join-Path $envsRoot 'bin') 'uv.exe'
    $uvCopyMissing = $false
    $hasReady = $false
    foreach ($p in @($report.projects)) {
        if ([string]$p.status -ceq 'ready') { $hasReady = $true; break }
    }
    if ($hasReady -and -not (Test-Path -LiteralPath $uvExe)) { $uvCopyMissing = $true }

    $projectsOut = [System.Collections.Generic.List[object]]::new()
    $blockers = [System.Collections.Generic.List[object]]::new()
    foreach ($p in @($report.projects)) {
        $status = [string]$p.status
        $reason = $p.reason
        $blocks = Test-SandboxEnvProjectBlocks -Status $status -Reason $reason
        $uvBlock = $false
        if ($uvCopyMissing -and $status -ceq 'ready') {
            $blocks = $true
            $uvBlock = $true
        }
        $outStatus = Get-SandboxEnvReadyMessageStatus -Status $status -Reason $reason -UvCopyMissing $uvBlock
        $projectsOut.Add([ordered]@{
                project = [string]$p.project
                kind    = [string]$p.kind
                status  = $outStatus
                reason  = $reason
                env     = $p.env
                python  = $p.python
            })
        if ($blocks) {
            $blockers.Add([ordered]@{ project = [string]$p.project; status = $outStatus })
        }
    }

    $ready = ($blockers.Count -eq 0)
    $message = $null
    if (-not $ready) {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($b in $blockers) { $parts.Add("$($b.project) ($($b.status))") }
        $base = "sandbox: environment not ready: $($parts -join ', '); run -SandboxEnv -Repo $Repo -Base $Commit -Apply."
        $propText = $null
        if ($null -ne $report.proposal) {
            $propText = Get-SandboxDictValue -Object $report.proposal -Key 'text'
        }
        if ($propText -is [string] -and -not [string]::IsNullOrEmpty($propText)) {
            $message = "$base $propText"
        } else {
            $message = $base
        }
    }

    return [ordered]@{
        ready     = $ready
        projects  = @($projectsOut)
        message   = $message
        proposal  = $report.proposal
    }
}

function Get-SandboxEnvProjectLinkPath {
    param(
        [string]$Worktree,
        [string]$Project
    )

    if ([string]::Equals($Project, '.', [StringComparison]::Ordinal)) {
        return Join-Path $Worktree '.venv'
    }
    $rel = $Project -replace '/', [IO.Path]::DirectorySeparatorChar
    return Join-Path (Join-Path $Worktree $rel) '.venv'
}

function Test-SandboxEnvLinkItemIsJunction {
    param([string]$LinkPath)

    # Get-Item -Force also finds a junction whose target is gone; Test-Path would not.
    $item = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return ($item.LinkType -ceq 'Junction')
}

function Set-SandboxEnvLinkedStamp {
    param(
        [string]$EnvsRoot,
        [string]$EnvName
    )

    $linkedDir = Join-Path $EnvsRoot 'linked'
    if (-not (Test-Path -LiteralPath $linkedDir)) {
        New-Item -ItemType Directory -Force -Path $linkedDir | Out-Null
    }
    $stamp = Join-Path $linkedDir $EnvName
    if (-not (Test-Path -LiteralPath $stamp)) {
        New-Item -ItemType File -Force -Path $stamp | Out-Null
    }
    (Get-Item -LiteralPath $stamp -Force).LastWriteTimeUtc = [DateTime]::UtcNow
}

function Get-SandboxEnvIndexEntryByName {
    param(
        [hashtable]$Index,
        [string]$EnvName
    )

    foreach ($key in @($Index.envs.Keys)) {
        $entry = $Index.envs[$key]
        if ($entry -is [string] -or $entry -isnot [System.Collections.IDictionary]) { continue }
        $name = Get-SandboxDictValue -Object $entry -Key 'name'
        if ($name -is [string] -and [string]::Equals($name, $EnvName, [StringComparison]::Ordinal)) {
            return @{ hash = $key; entry = $entry }
        }
    }
    return $null
}

function Add-SandboxEnvLinksCore {
    param(
        [string]$Repo,
        [string]$Worktree,
        [object[]]$Projects,
        [string]$EnvsRoot
    )

    $read = Read-SandboxEnvsIndex -EnvsRoot $EnvsRoot
    $index = $read.index
    $notes = [System.Collections.Generic.List[string]]::new()
    $linkedEnvs = [System.Collections.Generic.List[object]]::new()
    $seenEnv = @{}

    foreach ($p in @($Projects)) {
        if ([string]$p.status -cne 'ready') { continue }
        $project = [string]$p.project
        $envName = [string]$p.env
        if ([string]::IsNullOrWhiteSpace($envName)) { continue }

        Set-SandboxEnvLinkedStamp -EnvsRoot $EnvsRoot -EnvName $envName

        $projectDir = if ([string]::Equals($project, '.', [StringComparison]::Ordinal)) {
            $Worktree
        } else {
            Join-Path $Worktree ($project -replace '/', [IO.Path]::DirectorySeparatorChar)
        }
        if (-not (Test-Path -LiteralPath $projectDir)) {
            $notes.Add("$project is not in the worktree; environment not linked")
            continue
        }

        $target = Join-Path $EnvsRoot $envName
        if (-not (Test-Path -LiteralPath $target)) {
            $notes.Add("$project environment $envName is missing; environment not linked")
            continue
        }

        $link = Get-SandboxEnvProjectLinkPath -Worktree $Worktree -Project $project
        $linkParent = Split-Path -Parent $link
        if (-not (Test-Path -LiteralPath $linkParent)) {
            New-Item -ItemType Directory -Force -Path $linkParent | Out-Null
        }

        if (Test-Path -LiteralPath $link) {
            if (Test-SandboxEnvLinkItemIsJunction -LinkPath $link) {
                try { [IO.Directory]::Delete($link, $false) } catch { $notes.Add("$project junction could not be replaced; environment not linked"); continue }
            } else {
                $notes.Add(".venv in $project is a real folder; environment not linked")
                continue
            }
        }

        try {
            $null = New-Item -ItemType Junction -Path $link -Target $target -Force
        } catch {
            $notes.Add("$project junction could not be created; environment not linked")
            continue
        }

        if (-not $seenEnv.ContainsKey($envName)) {
            $seenEnv[$envName] = $true
            $linkedEnvs.Add([ordered]@{ env = $envName; project = $project })
        }
    }

    $envPaths = [System.Collections.Generic.List[object]]::new()
    $seenInterp = @{}
    foreach ($le in $linkedEnvs) {
        $envName = [string]$le.env
        $envPaths.Add([ordered]@{ path = (Join-Path $EnvsRoot $envName); project = [string]$le.project })
        $found = Get-SandboxEnvIndexEntryByName -Index $index -EnvName $envName
        if ($null -eq $found) { continue }
        $pyVer = Get-SandboxDictValue -Object $found.entry -Key 'python'
        if ($pyVer -isnot [string] -or [string]::IsNullOrEmpty($pyVer)) { continue }
        if (-not $index.pythons.ContainsKey($pyVer)) { continue }
        $interpFolder = [string]$index.pythons[$pyVer]
        if ([string]::IsNullOrWhiteSpace($interpFolder)) { continue }
        if ($seenInterp.ContainsKey($interpFolder)) { continue }
        $seenInterp[$interpFolder] = $true
        $envPaths.Add([ordered]@{ path = $interpFolder; project = $null })
    }
    $envPaths.Add([ordered]@{ path = (Join-Path $envsRoot 'bin'); project = $null })

    return [ordered]@{
        envPaths   = @($envPaths)
        pathSuffix = @($envsRoot + '\bin')
        extraEnv   = @{
            UV_FROZEN              = '1'
            UV_NO_SYNC             = '1'
            UV_PYTHON_DOWNLOADS    = 'never'
        }
        notes      = @($notes)
    }
}

function Add-SandboxEnvLinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][object[]]$Projects
    )

    $hasReady = $false
    foreach ($p in @($Projects)) {
        if ([string]$p.status -ceq 'ready') { $hasReady = $true; break }
    }
    if (-not $hasReady) {
        return [ordered]@{
            envPaths   = @()
            pathSuffix = @()
            extraEnv   = @{}
            notes      = @()
        }
    }

    $envsRoot = Get-SandboxEnvsRoot -Repo $Repo
    $lockName = Get-SandboxEnvsLockName -EnvsRoot $envsRoot
    $timeoutMessage = "sandbox: timed out waiting for -SandboxEnv -Apply to finish on $envsRoot"
    return Invoke-SandboxLocked -Name $lockName -TimeoutSec 60 -TimeoutMessage $timeoutMessage -ScriptBlock {
        Add-SandboxEnvLinksCore -Repo $Repo -Worktree $Worktree -Projects $Projects -EnvsRoot $envsRoot
    }
}

function Remove-SandboxEnvLinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path $Worktree '.venv'))
    try {
        $commit = Get-SandboxGitCommit -Repo $Worktree -Ref 'HEAD'
        foreach ($p in @(Get-SandboxEnvProjects -Repo $Worktree -Commit $commit)) {
            $candidates.Add((Get-SandboxEnvProjectLinkPath -Worktree $Worktree -Project ([string]$p.project)))
        }
    } catch {
    }

    $removed = 0
    foreach ($path in $candidates) {
        if (-not (Test-SandboxEnvLinkItemIsJunction -LinkPath $path)) { continue }
        try {
            [IO.Directory]::Delete($path, $false)
            $removed++
        } catch {
            continue
        }
    }
    return $removed
}

function Invoke-SandboxEnvApplyCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$EnvsRoot,
        [Parameter(Mandatory)][string]$UvPath,
        [AllowEmptyString()][string]$RebuildProject,
        [bool]$HasRebuild
    )

    $read = Read-SandboxEnvsIndex -EnvsRoot $EnvsRoot
    $index = $read.index
    $warning = $read.warning

    $ver = Invoke-SandboxUv -Arguments @('--version')
    $versionLine = $null
    if ($ver.exitCode -eq 0) {
        foreach ($line in @($ver.stdout)) {
            $trimmed = ([string]$line).Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $versionLine = $trimmed; break }
        }
    }
    if ($null -eq $versionLine) {
        $warning = Add-SandboxEnvWarningText -Existing $warning -Message 'uv --version failed; kept the old copy'
    } else {
        $same = $false
        if ($null -ne $index.uvVersion) {
            $same = [string]::Equals([string]$index.uvVersion, $versionLine, [StringComparison]::Ordinal)
        }
        if (-not $same) {
            try {
                $binDir = Join-Path $EnvsRoot 'bin'
                if (-not (Test-Path -LiteralPath $binDir)) {
                    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
                }
                $dest = Join-Path $binDir 'uv.exe'
                Copy-Item -LiteralPath $UvPath -Destination $dest -Force
                $index.uv = $dest
                $index.uvVersion = $versionLine
            } catch {
                $warning = Add-SandboxEnvWarningText -Existing $warning -Message 'uv.exe could not be replaced (in use); kept the old copy'
            }
        }
    }

    $projects = @(Get-SandboxEnvProjects -Repo $Repo -Commit $Commit)
    $statuses = @(Get-SandboxEnvStatuses -Projects $projects -Index $index -EnvsRoot $EnvsRoot -UvPath $UvPath)

    if ($HasRebuild) {
        $match = $null
        foreach ($st in $statuses) {
            if ([string]::Equals([string]$st['project'], $RebuildProject, [StringComparison]::Ordinal)) {
                $match = $st
                break
            }
        }
        if ($null -eq $match) { throw "-Rebuild: no project $RebuildProject at $Ref" }
        if ([string]::Equals([string]$match['status'], 'unsupported', [StringComparison]::Ordinal)) {
            throw "-Rebuild: $RebuildProject is unsupported ($($match['reason']))"
        }
        $hash = [string]$match['hash']
        if ($index.envs.ContainsKey($hash)) {
            $envName = Get-SandboxDictValue -Object $index.envs[$hash] -Key 'name'
            if ($envName -is [string] -and -not [string]::IsNullOrWhiteSpace($envName)) {
                Remove-SandboxEnvPath -Path (Join-Path $EnvsRoot $envName)
                Remove-SandboxEnvPath -Path (Join-Path (Join-Path $EnvsRoot 'work') $envName)
                Remove-SandboxEnvPath -Path (Join-Path (Join-Path $EnvsRoot 'linked') $envName)
            }
            [void]$index.envs.Remove($hash)
            if ($index.failed.ContainsKey($hash)) { [void]$index.failed.Remove($hash) }
        }
        $statuses = @(Get-SandboxEnvStatuses -Projects $projects -Index $index -EnvsRoot $EnvsRoot -UvPath $UvPath)
    }

    $byProject = @{}
    foreach ($p in $projects) { $byProject[[string]$p.project] = $p }

    $groupList = [System.Collections.Generic.List[object]]::new()
    $groupByHash = @{}
    foreach ($st in $statuses) {
        $status = [string]$st['status']
        if ($status -cne 'missing' -and $status -cne 'stale' -and $status -cne 'install-failed') { continue }
        $hash = [string]$st['hash']
        if (-not $groupByHash.ContainsKey($hash)) {
            $g = @{
                hash     = $hash
                env      = [string]$st['env']
                projects = [System.Collections.Generic.List[object]]::new()
            }
            $groupByHash[$hash] = $g
            $groupList.Add($g)
        }
        $groupByHash[$hash].projects.Add($byProject[[string]$st['project']])
    }

    $treeMap = Get-SandboxGitTreeMap -Repo $Repo -Commit $Commit
    $builtList = [System.Collections.Generic.List[object]]::new()
    $failedList = [System.Collections.Generic.List[object]]::new()

    foreach ($g in $groupList) {
        $hash = [string]$g.hash
        $name = [string]$g.env
        $projPaths = (Get-SandboxGroupProjectPaths -Projects $g.projects).paths
        $first = $byProject[[string]$projPaths[0]]
        $request = [string]$first.request
        if ($index.failed.ContainsKey($hash)) { [void]$index.failed.Remove($hash) }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $envDir = Join-Path $EnvsRoot $name
        if ((Test-Path -LiteralPath $envDir) -and (Test-SandboxEnvNameClash -Index $index -Name $name -Hash $hash)) {
            Add-SandboxEnvBuildFailure -Index $index -FailedNow $failedList -Hash $hash -Name $name -Projects $projPaths -ErrorText 'name-clash' -EnvsRoot $EnvsRoot -DeleteFolder $false
            continue
        }
        if (Test-Path -LiteralPath $envDir) { Remove-SandboxEnvPath -Path $envDir }

        $workRoot = Join-Path (Join-Path $EnvsRoot 'work') $name
        Write-SandboxEnvInputs -Repo $Repo -Commit $Commit -WorkRoot $workRoot -Inputs @($first.inputs)
        $work = Get-SandboxEnvWorkDir -WorkRoot $workRoot -Project ([string]$first.project)
        if (-not (Test-Path -LiteralPath $work)) {
            New-Item -ItemType Directory -Force -Path $work | Out-Null
        }

        $uvEnvironment = @{
            UV_PROJECT_ENVIRONMENT = $envDir
            UV_PYTHON_INSTALL_DIR  = (Join-Path $EnvsRoot 'python')
            UV_PYTHON_PREFERENCE   = 'only-managed'
        }

        $failed = $false
        $errorText = $null
        $py = $null
        $exact = $null

        $install = Invoke-SandboxUv -Arguments @('python', 'install', $request) -WorkingDirectory $work -Environment $uvEnvironment
        if ($install.exitCode -ne 0) {
            $failed = $true
            $errorText = Get-SandboxUvStreamError $install
        }

        if (-not $failed) {
            $find = Invoke-SandboxUv -Arguments @('python', 'find', $request) -WorkingDirectory $work -Environment $uvEnvironment
            if ($find.exitCode -ne 0) {
                $failed = $true
                $errorText = Get-SandboxUvStreamError $find
            } else {
                if (@($find.stdout).Count -gt 0) { $py = ([string]@($find.stdout)[0]).Trim() }
                if ([string]::IsNullOrWhiteSpace($py)) {
                    $failed = $true
                    $errorText = Get-SandboxUvStreamError $find
                }
            }
        }

        if (-not $failed) {
            $probe = Get-SandboxPythonProbe -PythonPath $py
            if ($probe.exitCode -ne 0) {
                $failed = $true
                $errorText = Get-SandboxUvStreamError $probe
            } else {
                if (@($probe.stdout).Count -gt 0) { $exact = ([string]@($probe.stdout)[0]).Trim() }
                if ([string]::IsNullOrWhiteSpace($exact)) {
                    $failed = $true
                    $errorText = Get-SandboxUvStreamError $probe
                } else {
                    # uv python find returns the minor-version junction (cpython-3.12-...); record the real folder,
                    # which pyvenv.cfg's home names and which a sandbox grant must cover.
                    $interpDir = Split-Path -Parent $py
                    $interpItem = Get-Item -LiteralPath $interpDir -Force -ErrorAction SilentlyContinue
                    if ($null -ne $interpItem -and $interpItem.LinkType) {
                        $resolved = [IO.Directory]::ResolveLinkTarget($interpDir, $true)
                        if ($null -ne $resolved) { $interpDir = $resolved.FullName }
                    }
                    $index.pythons[$exact] = $interpDir
                }
            }
        }

        if (-not $failed) {
            if ([string]::Equals([string]$first.kind, 'lock', [StringComparison]::Ordinal)) {
                $sync = Invoke-SandboxUv -Arguments @('sync', '--frozen', '--no-install-project', '--python', $exact) -WorkingDirectory $work -Environment $uvEnvironment
                if ($sync.exitCode -ne 0) {
                    $failed = $true
                    $errorText = Get-SandboxUvStreamError $sync
                }
            } elseif (Test-SandboxInputsHavePyproject -Inputs @($first.inputs)) {
                $lockStep = Invoke-SandboxUv -Arguments @('lock', '--python', $exact) -WorkingDirectory $work -Environment $uvEnvironment
                if ($lockStep.exitCode -ne 0) {
                    $failed = $true
                    $errorText = Get-SandboxUvStreamError $lockStep
                } else {
                    $sync = Invoke-SandboxUv -Arguments @('sync', '--frozen', '--no-install-project', '--python', $exact) -WorkingDirectory $work -Environment $uvEnvironment
                    if ($sync.exitCode -ne 0) {
                        $failed = $true
                        $errorText = Get-SandboxUvStreamError $sync
                    }
                }
            } else {
                $venv = Invoke-SandboxUv -Arguments @('venv', '--python', $py, $envDir) -WorkingDirectory $work -Environment $uvEnvironment
                if ($venv.exitCode -ne 0) {
                    $failed = $true
                    $errorText = Get-SandboxUvStreamError $venv
                } else {
                    $pyExe = Join-Path $envDir 'Scripts\python.exe'
                    foreach ($req in @((Get-SandboxRequirementInputs -Inputs @($first.inputs)).paths)) {
                        if ([string]::IsNullOrWhiteSpace([string]$req)) { continue }
                        $normReq = ([string]$req) -replace '\\', '/'
                        $leaf = [IO.Path]::GetFileName($normReq)
                        $reqFull = Join-Path $work $leaf
                        $pip = Invoke-SandboxUv -Arguments @('pip', 'install', '--python', $pyExe, '-r', $reqFull) -WorkingDirectory $work -Environment $uvEnvironment
                        if ($pip.exitCode -ne 0) {
                            $failed = $true
                            $errorText = Get-SandboxUvStreamError $pip
                            break
                        }
                    }
                }
            }
        }

        if ($failed) {
            Add-SandboxEnvBuildFailure -Index $index -FailedNow $failedList -Hash $hash -Name $name -Projects $projPaths -ErrorText $errorText -EnvsRoot $EnvsRoot -DeleteFolder $true
            continue
        }

        Write-SandboxEnvPthFiles -Repo $Repo -Commit $Commit -EnvDir $envDir -Projects $g.projects -TreeMap $treeMap
        $bytes = [long](Get-SandboxDirectoryLength -Path $envDir)
        $sw.Stop()
        $index.envs[$hash] = [ordered]@{
            name     = $name
            projects = $projPaths
            kind     = [string]$first.kind
            python   = $exact
            bytes    = $bytes
            built    = (Get-SandboxUtcStamp)
        }
        $builtList.Add([ordered]@{
                env      = $name
                projects = $projPaths
                bytes    = $bytes
                seconds  = [int][math]::Round($sw.Elapsed.TotalSeconds)
            })
    }

    $pruneResult = Invoke-SandboxEnvPrune -Index $index -EnvsRoot $EnvsRoot -Projects $projects -Warning $warning
    $warning = $pruneResult.warning
    $prunedArr = New-SandboxObjectArray -Items $pruneResult.pruned

    if ($null -eq $index.approved -and $builtList.Count -gt 0) {
        $index.approved = Get-SandboxUtcStamp
    }
    $index.version = 1
    Write-SandboxEnvsIndex -EnvsRoot $EnvsRoot -Index $index

    $builtArr = New-SandboxObjectArray -Items $builtList
    $failedArr = New-SandboxObjectArray -Items $failedList
    return [ordered]@{
        built     = $builtArr
        failedNow = $failedArr
        pruned    = $prunedArr
        warning   = $warning
    }}

function Invoke-SandboxEnvApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Ref,
        [string]$Rebuild
    )

    $uvPath = Get-SandboxUvPath
    if ([string]::IsNullOrWhiteSpace($uvPath)) {
        return [ordered]@{
            built     = [object[]]@()
            failedNow = [object[]]@()
            pruned    = [object[]]@()
            warning   = 'uv not found; nothing built'
        }
    }

    $commit = Get-SandboxGitCommit -Repo $Repo -Ref $Ref
    $envsRoot = Get-SandboxEnvsRoot -Repo $Repo
    if (-not (Test-Path -LiteralPath $envsRoot)) {
        New-Item -ItemType Directory -Force -Path $envsRoot | Out-Null
    }

    $lockName = Get-SandboxEnvsLockName -EnvsRoot $envsRoot
    $timeoutMessage = "sandbox: timed out waiting for another -SandboxEnv -Apply on $envsRoot"
    $hasRebuild = $PSBoundParameters.ContainsKey('Rebuild')
    $rebuildProject = if ($null -eq $Rebuild) { '' } else { [string]$Rebuild }

    $result = Invoke-SandboxLocked -Name $lockName -TimeoutSec 1800 -TimeoutMessage $timeoutMessage -ScriptBlock {
        Invoke-SandboxEnvApplyCore -Repo $Repo -Ref $Ref -Commit $commit -EnvsRoot $envsRoot -UvPath $uvPath -RebuildProject $rebuildProject -HasRebuild $hasRebuild
    }
    return $result
}
Export-ModuleMember -Function Get-SandboxEnvProjects, Get-SandboxUvPath, Invoke-SandboxUv, Get-SandboxEnvReport, Invoke-SandboxEnvApply, Test-SandboxEnvReady, Add-SandboxEnvLinks, Remove-SandboxEnvLinks

