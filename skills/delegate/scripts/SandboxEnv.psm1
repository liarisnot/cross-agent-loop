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

Export-ModuleMember -Function Get-SandboxEnvProjects, Get-SandboxUvPath, Invoke-SandboxUv
