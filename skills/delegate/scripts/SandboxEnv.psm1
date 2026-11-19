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
    if ($Kind -eq 'lock') {
        $spec = Get-SandboxTomlValue -Text $UvLockText -Section '' -Key 'requires-python'
    } else {
        $spec = Get-SandboxTomlValue -Text $PyprojectText -Section 'project' -Key 'requires-python'
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
        if ($lf -eq '.') { continue }
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


function Get-SandboxEnvProjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Commit
    )

    $tree = Get-SandboxGitTreeMap -Repo $Repo -Commit $Commit
    $paths = @($tree.Keys)

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
        if ($isPyproject -and (Test-SandboxAncestorLockProject -Folder $folder -LockFolders $lockFolders)) { continue }
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
        if ($entry -isnot [hashtable]) { continue }
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
        if ($entry -isnot [hashtable]) { continue }
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

    $discovered = Get-SandboxEnvProjects -Repo $Repo -Commit $commit
    $statuses = Get-SandboxEnvStatuses -Projects $discovered -Index $index -EnvsRoot $envsRoot -UvPath $uvPath

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

Export-ModuleMember -Function Get-SandboxEnvProjects, Get-SandboxUvPath, Invoke-SandboxUv, Get-SandboxEnvReport

