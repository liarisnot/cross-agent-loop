#Requires -Version 7.4

param(
    [Parameter(Position = 0)]
    [string]$Subcommand,
    [string]$Repo,
    [string]$Name,
    [string]$Cwd,
    [string]$To,
    [string]$Reason,
    [string]$Gate,
    [string]$Quote,
    [string]$Checkin,
    [string]$Kind,
    [string]$Text,
    [string]$Phase,
    [string]$Section,
    [string]$Message,
    [string]$Mode,
    [string]$PlanFile,
    [string]$Task,
    [string]$Status,
    [string]$SessionId,
    [string]$ResultFile,
    [string]$Worktree,
    [string]$BaseSha,
    [string]$TimeoutSec
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$script:Stages = @('design', 'design-review', 'plan', 'build', 'signoff')
$script:StageExitGate = @{
    'design-review' = 'design-locked'
    'plan'          = 'plan-approved'
    'signoff'       = 'signed-off'
}
$script:DecisionKinds = @('decision', 'gate', 'stage', 'round', 'council', 'fix-up', 'dismiss', 'stop', 'resume')
$script:SkillDir = Split-Path $PSScriptRoot -Parent
$script:SchemaFeature = Join-Path $script:SkillDir 'schemas/feature.schema.json'
$script:SchemaPlan = Join-Path $script:SkillDir 'schemas/plan.schema.json'
$script:SchemaState = Join-Path $script:SkillDir 'schemas/state.schema.json'
$script:SchemaVerify = Join-Path $script:SkillDir 'schemas/verify.schema.json'
$script:TaskStatuses = @('pending', 'preflight', 'running', 'in-review', 'merged', 'failed')
$script:ModelsPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../delegate/models.json'))
$script:TemplateDecisions = Join-Path $script:SkillDir 'templates/decisions.md'
$script:LockHeld = $false
$script:LockPath = $null

function Out-FeatureOk([hashtable]$h) {
    $h['ok'] = $true
    $h | ConvertTo-Json -Compress -Depth 10
    exit 0
}

function Out-FeatureFail([string]$msg) {
    @{ ok = $false; error = $msg } | ConvertTo-Json -Compress
    exit 1
}

function Invoke-GitRepo {
    param(
        [string]$Repository,
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$GitArgs
    )
    $out = & git -C $Repository @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' '): $out" }
    return $out
}

function Ensure-XagentExclude([string]$Repository) {
    $commonDir = @(Invoke-GitRepo $Repository 'rev-parse' '--git-common-dir')[0]
    if (-not [IO.Path]::IsPathRooted($commonDir)) { $commonDir = Join-Path $Repository $commonDir }
    $exclude = Join-Path $commonDir 'info/exclude'
    New-Item -ItemType Directory -Force (Split-Path $exclude) | Out-Null
    if (-not (Test-Path -LiteralPath $exclude) -or -not (Select-String -LiteralPath $exclude -SimpleMatch '.xagent/' -Quiet)) {
        [IO.File]::AppendAllText($exclude, ".xagent/`n", [Text.UTF8Encoding]::new($false))
    }
}

function Assert-DelegateFiles {
    $modelsPath = Join-Path $PSScriptRoot '../../delegate/models.json'
    $modelsPath = [IO.Path]::GetFullPath($modelsPath)
    if (-not (Test-Path -LiteralPath $modelsPath)) { throw "missing delegate files at $modelsPath" }
}

function Resolve-Repository {
    if ($Repo) {
        return ([IO.Path]::GetFullPath($Repo)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    $cwdPath = if ($Cwd) { $Cwd } else { (Get-Location).Path }
    $top = @(Invoke-GitRepo $cwdPath 'rev-parse' '--show-toplevel')[0]
    return $top.TrimEnd('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
}

function Test-FeatureName([string]$n) {
    return ($n -cmatch '^[a-z0-9][a-z0-9-]{0,30}$')
}

function Assert-OneLine([string]$label, [string]$value) {
    if ($null -ne $value -and $value -match "`r|`n") { throw "$label must be a single line" }
}

function Get-UtcDecisionTime {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Format-DecisionLine {
    param([string]$Kind, [string]$Body, [string]$Time)
    $t = if ($Time) { $Time } else { Get-UtcDecisionTime }
    return "- $t [$Kind] $Body"
}

function Get-DecisionCommitSuffix([string]$line) {
    if ($line -match '^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \[([^\]]+)\] (.*)$') {
        return "[$($Matches[1])] $($Matches[2])"
    }
    throw 'invalid decision line'
}

function Limit-CommitMessage([string]$msg) {
    if ($msg.Length -le 72) { return $msg }
    return $msg.Substring(0, 72)
}

function Write-TextLf {
    param([string]$Path, [string]$Text)
    $norm = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $norm.EndsWith("`n")) { $norm += "`n" }
    [IO.File]::WriteAllText($Path, $norm, [Text.UTF8Encoding]::new($false))
}

function Append-TextLf {
    param([string]$Path, [string]$Text)
    $norm = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $norm.EndsWith("`n")) { $norm += "`n" }
    [IO.File]::AppendAllText($Path, $norm, [Text.UTF8Encoding]::new($false))
}

function Test-FeatureJsonSchema([string]$json) {
    if (-not (Test-Json -Json $json -SchemaFile $script:SchemaFeature -ErrorAction SilentlyContinue)) {
        throw 'feature.json does not validate against schema'
    }
}

function Write-FeatureJsonFile {
    param([string]$Path, [object]$Feature)
    if ($Feature.gates -and $Feature.gates.PSObject.Properties) {
        foreach ($prop in $Feature.gates.PSObject.Properties) {
            $atP = $prop.Value.PSObject.Properties['at']
            if ($null -eq $atP) { continue }
            $atP.Value = ([datetime]$atP.Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }
    $json = $Feature | ConvertTo-Json -Depth 10
    $json = $json -replace '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.\d+Z', '$1Z'
    $json = $json -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    Test-FeatureJsonSchema $json
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-FeatureJsonFromRef {
    param([string]$Repository, [string]$Ref, [string]$FeatureName)
    $path = "docs/features/$FeatureName/feature.json"
    try {
        $text = (Invoke-GitRepo $Repository 'show' "${Ref}:$path") -join "`n"
        return $text | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-FeatureBranchNames([string]$Repository) {
    $lines = @(Invoke-GitRepo $Repository 'for-each-ref' '--format=%(refname:short)' 'refs/heads/feature/')
    return @($lines | ForEach-Object { if ($_ -match '^feature/(.+)$') { $Matches[1] } })
}

function Test-MergeBaseIsAncestor {
    param(
        [string]$Repository,
        [string]$Ancestor,
        [string]$Descendant = 'main'
    )
    & git -C $Repository show-ref --verify --quiet "refs/heads/$Descendant" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    & git -C $Repository merge-base --is-ancestor $Ancestor $Descendant 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($LASTEXITCODE -eq 1) { return $false }
    throw "git merge-base --is-ancestor $Ancestor $Descendant"
}

function Get-EffectiveStage {
    param(
        [string]$Repository,
        [string]$BranchName,
        [object]$Feature
    )
    if (-not $Feature) { return $null }
    $stored = [string]$Feature.stage
    if ($stored -eq 'abandoned') { return 'abandoned' }
    $branch = "feature/$BranchName"
    $isAncestor = Test-MergeBaseIsAncestor $Repository $branch 'main'
    if ($null -eq $isAncestor) { return $stored }   # no main branch: nothing can be done yet
    if ($isAncestor -and $Feature.gates.PSObject.Properties['signed-off']) {
        return 'done'
    }
    return $stored
}

function Get-FeatureList([string]$Repository) {
    $result = @()
    foreach ($n in Get-FeatureBranchNames $Repository) {
        $feat = Get-FeatureJsonFromRef $Repository "feature/$n" $n
        if ($feat) {
            $eff = Get-EffectiveStage $Repository $n $feat
            $stage = if ($null -ne $eff) { $eff } else { [string]$feat.stage }
            $result += [pscustomobject]@{
                name  = $n
                stage = $stage
            }
        }
    }
    return $result
}

function Get-InProgressFeatures([string]$Repository) {
    return @(Get-FeatureList $Repository | Where-Object { $_.stage -ne 'done' -and $_.stage -ne 'abandoned' })
}

function Resolve-FeatureName {
    param([string]$Repository)
    if ($Name) {
        if (-not (Test-FeatureName $Name)) { throw 'invalid feature name' }
        return $Name
    }
    $selRepo = if ($Cwd) { @(Invoke-GitRepo $Cwd 'rev-parse' '--show-toplevel')[0] } else { $Repository }
    $branch = @(Invoke-GitRepo $selRepo 'rev-parse' '--abbrev-ref' 'HEAD')[0]
    if ($branch -match '^feature/(.+)$') {
        $bn = $Matches[1]
        $feat = Get-FeatureJsonFromRef $Repository $branch $bn
        if ($feat) {
            $st = Get-EffectiveStage $Repository $bn $feat
            if ($st -ne 'done' -and $st -ne 'abandoned') { return $bn }
        }
    }
    $inProg = @(Get-InProgressFeatures $Repository)
    if ($inProg.Count -eq 1) { return $inProg[0].name }
    throw 'no feature selected; name one with -Name'
}

function Test-TreeClean([string]$Repository) {
    $porcelain = @(Invoke-GitRepo $Repository 'status' '--porcelain' '--untracked-files=no')
    return (@($porcelain).Count -eq 0)
}

function Test-PathHasChanges {
    param([string]$Repository, [string]$PathSpec)
    $porcelain = @(Invoke-GitRepo $Repository 'status' '--porcelain' '--untracked-files=all' '--' $PathSpec)
    return (@($porcelain).Count -gt 0)
}

function Assert-OnFeatureBranch {
    param([string]$Repository, [string]$FeatureName)
    $head = @(Invoke-GitRepo $Repository 'rev-parse' '--abbrev-ref' 'HEAD')[0]
    if ($head -ne "feature/$FeatureName") { throw "check out feature/$FeatureName first" }
}

function Get-HeadFeatureState {
    param([string]$Repository, [string]$FeatureName)
    $featPath = Join-Path $Repository "docs/features/$FeatureName/feature.json"
    $decPath = Join-Path $Repository "docs/features/$FeatureName/decisions.md"
    $featText = (Invoke-GitRepo $Repository 'show' "HEAD:docs/features/$FeatureName/feature.json") -join "`n"
    $decText = @(Invoke-GitRepo $Repository 'show' "HEAD:docs/features/$FeatureName/decisions.md") -join "`n"
    if (-not $decText.EndsWith("`n")) { $decText += "`n" }
    return @{
        Feature    = $featText | ConvertFrom-Json
        FeatureRaw = $featText
        Decisions  = $decText
        FeatPath   = $featPath
        DecPath    = $decPath
    }
}

function Test-StopOpen([string]$decisionsText) {
    $lastStop = -1
    $lastResume = -1
    $i = 0
    foreach ($line in ($decisionsText -split "`n")) {
        if ($line -match '^- \S+ \[stop\] ') { $lastStop = $i }
        if ($line -match '^- \S+ \[resume\] ') { $lastResume = $i }
        $i++
    }
    if ($lastStop -lt 0) { return $false }
  return ($lastResume -lt $lastStop)
}

function Remove-GateKeys {
    param([object]$Feature, [string[]]$Keys)
    foreach ($k in $Keys) {
        if ($Feature.gates.PSObject.Properties[$k]) {
            $Feature.gates.PSObject.Properties.Remove($k)
        }
    }
}

function Get-StageIndex([string]$stage) {
    $idx = [array]::IndexOf($script:Stages, $stage)
    if ($idx -lt 0) { throw "unknown stage $stage" }
    return $idx
}

function Get-ExitGatesFromIndex([int]$fromIndex) {
    $keys = @()
    for ($i = $fromIndex; $i -lt $script:Stages.Count; $i++) {
        $s = $script:Stages[$i]
        if ($script:StageExitGate[$s]) { $keys += $script:StageExitGate[$s] }
    }
    return $keys
}

function Enter-FeatureLock {
    param([string]$Repository, [string]$FeatureName)
    $dir = Join-Path $Repository ".xagent/features/$FeatureName"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $script:LockPath = Join-Path $dir '.lock'
    $myStart = (Get-Process -Id $PID).StartTime.ToUniversalTime()
    $take = $true
    if (Test-Path -LiteralPath $script:LockPath) {
        $take = $true
        try {
            $raw = [IO.File]::ReadAllText($script:LockPath)
            $obj = $raw | ConvertFrom-Json
            if ($null -eq $obj.pid -or $null -eq $obj.startTime) {
                $take = $true
            } else {
                $theirIso = ([datetime]$obj.startTime).ToUniversalTime().ToString('o')
                $lockLive = $false
                try {
                    $proc = Get-Process -Id ([int]$obj.pid) -ErrorAction Stop
                    $procIso = $proc.StartTime.ToUniversalTime().ToString('o')
                    $lockLive = ($procIso -eq $theirIso)
                } catch { $lockLive = $false }
                if ($lockLive) {
                    throw 'another session is working on this feature'
                }
                $take = $true
            }
        } catch {
            if ($_.Exception.Message -eq 'another session is working on this feature') { throw }
            $take = $true
        }
    }
    if ($take) {
        $body = (@{ pid = $PID; startTime = $myStart.ToString('o') } | ConvertTo-Json -Compress)
        [IO.File]::WriteAllText($script:LockPath, $body, [Text.UTF8Encoding]::new($false))
    }
    $script:LockHeld = $true
}

function Exit-FeatureLock {
    if ($script:LockHeld -and $script:LockPath -and (Test-Path -LiteralPath $script:LockPath)) {
        Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue
    }
    $script:LockHeld = $false
    $script:LockPath = $null
}

function Invoke-FeatureCommit {
    param(
        [string]$Repository,
        [string]$Message,
        [string[]]$Paths
    )
    Invoke-GitRepo $Repository 'add' '--' @Paths | Out-Null
    $msg = Limit-CommitMessage $Message
    Invoke-GitRepo $Repository 'commit' '-m' $msg '--' @Paths | Out-Null
    return @(Invoke-GitRepo $Repository 'rev-parse' 'HEAD')[0]
}

function Invoke-NewFeature {
    param([string]$Repository)
    if (-not $Name) { throw 'feature name required' }
    if (-not (Test-FeatureName $Name)) { throw 'invalid feature name' }
    if (-not (Test-TreeClean $Repository)) { throw 'working tree is not clean' }
    & git -C $Repository show-ref --verify --quiet "refs/heads/feature/$Name" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "branch feature/$Name already exists" }
    if (@(Get-InProgressFeatures $Repository).Count -gt 0) { throw 'another feature is in progress' }

    Enter-FeatureLock $Repository $Name
    try {
        Invoke-GitRepo $Repository 'switch' '-c' "feature/$Name" 'main' | Out-Null
        $featDir = Join-Path $Repository "docs/features/$Name"
        New-Item -ItemType Directory -Force $featDir | Out-Null
        $designDoc = "docs/designs/$Name.md"
        $feature = [ordered]@{
            name      = $Name
            stage     = 'design'
            checkin   = 'on-problems'
            designDoc = $designDoc
            gates     = @{}
        }
        $featPath = Join-Path $featDir 'feature.json'
        Write-FeatureJsonFile $featPath $feature
        $tpl = [IO.File]::ReadAllText($script:TemplateDecisions, [Text.UTF8Encoding]::new($false))
        $tpl = $tpl -replace '<name>', $Name
        Write-TextLf (Join-Path $featDir 'decisions.md') $tpl
        $rel = "docs/features/$Name"
        $null = Invoke-FeatureCommit $Repository "feature($Name): start" @($rel)
        Out-FeatureOk @{ name = $Name; branch = "feature/$Name" }
    } finally {
        Exit-FeatureLock
    }
}

function Invoke-StageFeature {
    param([string]$Repository, [string]$FeatureName)
    if (-not $To) { throw '-To is required' }
    $allowedTo = @($script:Stages + 'abandoned')
    if ($allowedTo -notcontains $To) { throw "invalid stage $To" }
    Assert-OneLine 'Reason' $Reason

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $state = Get-HeadFeatureState $Repository $FeatureName
        $feat = $state.Feature
        $from = [string]$feat.stage
        if ($from -eq 'abandoned') { throw 'cannot move out of abandoned' }
        if ($To -eq 'done') { throw 'cannot move to done' }
        if ($To -eq $from) { throw 'already at that stage' }

        if ($To -eq 'abandoned') {
            $body = if ($Reason) { $Reason } else { "$from -> abandoned" }
            $line = Format-DecisionLine -Kind 'stage' -Body $body
            $feat.stage = 'abandoned'
            Write-FeatureJsonFile $state.FeatPath $feat
            Append-TextLf $state.DecPath $line.TrimEnd("`n")
            $rel = "docs/features/$FeatureName"
            $suffix = Get-DecisionCommitSuffix $line
            $null = Invoke-FeatureCommit $Repository "feature($FeatureName): $suffix" @($rel)
            $switched = $false
            if (Test-TreeClean $Repository) {
                Invoke-GitRepo $Repository 'switch' 'main' | Out-Null
                $switched = $true
            }
            Out-FeatureOk @{ name = $FeatureName; from = $from; to = 'abandoned' }
        }

        $fromIdx = Get-StageIndex $from
        $toIdx = if ($To -eq 'abandoned') { -1 } else { Get-StageIndex $To }

        if ($toIdx -eq $fromIdx + 1) {
            $exitGate = $script:StageExitGate[$from]
            if ($exitGate -and -not $feat.gates.PSObject.Properties[$exitGate]) {
                throw "stage $from requires gate $exitGate"
            }
        } elseif ($toIdx -lt $fromIdx) {
            $keys = Get-ExitGatesFromIndex $toIdx
            Remove-GateKeys $feat $keys
        } elseif ($toIdx -gt $fromIdx + 1) {
            throw "can only advance one stage at a time"
        } else {
            throw 'invalid stage transition'
        }

        $body = if ($Reason) { $Reason } else { "$from -> $To" }
        $line = Format-DecisionLine -Kind 'stage' -Body $body
        $feat.stage = $To
        Write-FeatureJsonFile $state.FeatPath $feat
        Append-TextLf $state.DecPath $line.TrimEnd("`n")
        $rel = "docs/features/$FeatureName"
        $suffix = Get-DecisionCommitSuffix $line
        $null = Invoke-FeatureCommit $Repository "feature($FeatureName): $suffix" @($rel)
        Out-FeatureOk @{ name = $FeatureName; from = $from; to = $To }
    } finally {
        Exit-FeatureLock
    }
}

function Invoke-GateFeature {
    param([string]$Repository, [string]$FeatureName)
    Assert-OneLine 'Quote' $Quote
    if (-not $Gate) { throw '-Gate is required' }
    if (-not $Quote) { throw '-Quote is required' }
    if ($Checkin -and $Checkin -notin @('on-problems', 'every-phase')) { throw 'invalid checkin mode' }

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $state = Get-HeadFeatureState $Repository $FeatureName
        $feat = $state.Feature
        $stage = [string]$feat.stage
        $expected = $script:StageExitGate[$stage]
        if (-not $expected -or $Gate -ne $expected) { throw "gate $Gate is not valid for stage $stage" }
        if ($feat.gates.PSObject.Properties[$Gate]) { throw "$Gate is already recorded" }
        if ($Checkin -and $Gate -ne 'plan-approved') { throw '-Checkin is only allowed with plan-approved' }

        $branch = "feature/$FeatureName"
        $sha = @(Invoke-GitRepo $Repository 'rev-parse' $branch)[0]

        $gateTime = Get-UtcDecisionTime
        $gateRec = [ordered]@{
            at    = $gateTime
            quote = $Quote
            sha   = $sha
        }
        if ($Gate -eq 'design-locked') {
            $doc = [string]$feat.designDoc
            try {
                $blob = @(Invoke-GitRepo $Repository 'rev-parse' "${branch}:$doc")[0]
            } catch {
                throw 'design doc is not committed'
            }
            $gateRec['designBlob'] = $blob
        }

        if (-not $feat.gates) { $feat | Add-Member -NotePropertyName gates -NotePropertyValue ([pscustomobject]@{}) }
        $feat.gates | Add-Member -NotePropertyName $Gate -NotePropertyValue ([pscustomobject]$gateRec) -Force

        $gateLine = Format-DecisionLine -Kind 'gate' -Body "$Gate`: `"$Quote`"" -Time $gateTime
        $lines = @($gateLine.TrimEnd("`n"))
        if ($Checkin) {
            $feat.checkin = $Checkin
            $chkLine = Format-DecisionLine -Kind 'decision' -Body "checkin: $Checkin" -Time $gateTime
            $lines += $chkLine.TrimEnd("`n")
        }

        Write-FeatureJsonFile $state.FeatPath $feat
        foreach ($ln in $lines) { Append-TextLf $state.DecPath $ln }

        $rel = "docs/features/$FeatureName"
        $suffix = Get-DecisionCommitSuffix $gateLine
        $null = Invoke-FeatureCommit $Repository "feature($FeatureName): $suffix" @($rel)

        Out-FeatureOk @{ name = $FeatureName; gate = $Gate; sha = $sha }
    } finally {
        Exit-FeatureLock
    }
}

function Invoke-DecisionFeature {
    param([string]$Repository, [string]$FeatureName)
    Assert-OneLine 'Text' $Text
    if (-not $Kind) { throw '-Kind is required' }
    if ($script:DecisionKinds -notcontains $Kind) { throw "invalid kind $Kind" }
    if (-not $Text) { throw '-Text is required' }

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $state = Get-HeadFeatureState $Repository $FeatureName
        if ($Kind -eq 'resume' -and -not (Test-StopOpen $state.Decisions)) { throw 'no open stop to resume' }
        if ($Kind -eq 'stop' -and (Test-StopOpen $state.Decisions)) { throw 'stop is already open' }

        $line = Format-DecisionLine -Kind $Kind -Body $Text
        Append-TextLf $state.DecPath $line.TrimEnd("`n")
        $rel = "docs/features/$FeatureName"
        $suffix = Get-DecisionCommitSuffix $line
        $null = Invoke-FeatureCommit $Repository "feature($FeatureName): $suffix" @($rel)
        Out-FeatureOk @{ name = $FeatureName; line = $line.TrimEnd("`n") }
    } finally {
        Exit-FeatureLock
    }
}

function Invoke-ReauditFeature {
    param([string]$Repository, [string]$FeatureName)
    $parsed = 0
    if (-not [int]::TryParse($Phase, [ref]$parsed)) { throw 'Phase must be an integer' }
    if ($parsed -lt 1) { throw 'Phase must be at least 1' }

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $state = Get-HeadFeatureState $Repository $FeatureName
        $stage = [string]$state.Feature.stage
        if ($stage -notin @('design-review', 'plan')) { throw "reaudit not allowed in stage $stage" }

        $prefix = if ($stage -eq 'design-review') { 'd' } else { 'p' }
        $pattern = if ($stage -eq 'design-review') { 'design-' } else { 'plan-' }
        $branch = "feature/$FeatureName"
        $treeLines = @(Invoke-GitRepo $Repository 'ls-tree' '-r' '--name-only' $branch "--" "docs/features/$FeatureName/reviews/")
        $count = @($treeLines | Where-Object { $_ -match "/reviews/$pattern.*\.md$" }).Count
        $n = 1 + $count
        $body = "${prefix}${n}: phase $parsed"
        $line = Format-DecisionLine -Kind 'reaudit' -Body $body
        Append-TextLf $state.DecPath $line.TrimEnd("`n")
        $rel = "docs/features/$FeatureName"
        $suffix = Get-DecisionCommitSuffix $line
        $null = Invoke-FeatureCommit $Repository "feature($FeatureName): $suffix" @($rel)
        Out-FeatureOk @{ name = $FeatureName; line = $line.TrimEnd("`n") }
    } finally {
        Exit-FeatureLock
    }
}

function Invoke-CommitDesign {
    param([string]$Repository, [string]$FeatureName)
    Assert-OneLine 'Section' $Section
    if (-not $Section) { throw '-Section is required' }

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $state = Get-HeadFeatureState $Repository $FeatureName
        $doc = [string]$state.Feature.designDoc
        if (-not (Test-PathHasChanges $Repository $doc)) { throw 'no changes to design doc' }
        $msg = Limit-CommitMessage "feature($FeatureName): design – $Section"
        $sha = Invoke-FeatureCommit $Repository $msg @($doc)
        Out-FeatureOk @{ name = $FeatureName; commit = $sha }
    } finally {
        Exit-FeatureLock
    }
}

function Invoke-CommitRecords {
    param([string]$Repository, [string]$FeatureName)
    Assert-OneLine 'Message' $Message
    if (-not $Message) { throw '-Message is required' }

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $rel = "docs/features/$FeatureName"
        if (-not (Test-PathHasChanges $Repository $rel)) { throw 'no changes under feature records' }
        $msg = Limit-CommitMessage "feature($FeatureName): $Message"
        $sha = Invoke-FeatureCommit $Repository $msg @($rel)
        Out-FeatureOk @{ name = $FeatureName; commit = $sha }
    } finally {
        Exit-FeatureLock
    }
}

function Get-JsonStringArray {
    param($Value)
    if ($null -eq $Value) { return ,[string[]]@() }
    if ($Value -is [string]) { return ,[string[]]@($Value) }
    return ,[string[]]@($Value | ForEach-Object { [string]$_ })
}

function Get-JsonPropertyStringArray {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return ,[string[]]@() }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return ,[string[]]@() }
    return Get-JsonStringArray $p.Value
}

function Get-DelegateNamePrefix([string]$FeatureName) {
    $cut = if ($FeatureName.Length -gt 12) { $FeatureName.Substring(0, 12) } else { $FeatureName }
    return $cut.TrimEnd('-')
}

function Test-PlanJsonSchema([string]$Json) {
    if (-not (Test-Json -Json $Json -SchemaFile $script:SchemaPlan -ErrorAction SilentlyContinue)) {
        throw 'plan does not match plan.schema.json'
    }
}

function Get-PlanTasksById([object]$Plan) {
    $map = @{}
    foreach ($phase in @($Plan.phases)) {
        foreach ($task in @($phase.tasks)) {
            $map[[string]$task.id] = @{ Task = $task; PhaseN = [int]$phase.n }
        }
    }
    return $map
}

function Test-StringArrayEqual {
    param($A, $B)
    $aa = @($A)
    $bb = @($B)
    if ($aa.Count -ne $bb.Count) { return $false }
    for ($i = 0; $i -lt $aa.Count; $i++) {
        if (-not ([string]$aa[$i] -ceq [string]$bb[$i])) { return $false }
    }
    return $true
}

function Test-PlanTaskFieldsEqual([object]$A, [object]$B) {
    if (-not ([string]$A.id -ceq [string]$B.id)) { return $false }
    if (-not ([string]$A.title -ceq [string]$B.title)) { return $false }
    if (-not (Test-StringArrayEqual (Get-JsonPropertyStringArray $A 'dependsOn') (Get-JsonPropertyStringArray $B 'dependsOn'))) { return $false }
    if (-not (Test-StringArrayEqual (Get-JsonPropertyStringArray $A 'files') (Get-JsonPropertyStringArray $B 'files'))) { return $false }
    if (-not ([string]$A.test -ceq [string]$B.test)) { return $false }
    if (-not ([string]$A.profile -ceq [string]$B.profile)) { return $false }
    if (-not ([string]$A.brief -ceq [string]$B.brief)) { return $false }
    return $true
}

function Get-HeadPlanTaskById {
    param([object]$Feature, [string]$TaskId)
    if (-not $Feature.PSObject.Properties['phases']) { return $null }
    foreach ($phase in @($Feature.phases)) {
        foreach ($task in @($phase.tasks)) {
            if ([string]$task.id -ceq $TaskId) { return $task }
        }
    }
    return $null
}

function Assert-PlanBusinessRules([object]$Plan) {
    $byId = Get-PlanTasksById $Plan
    $seen = @{}
    foreach ($phase in @($Plan.phases)) {
        foreach ($task in @($phase.tasks)) {
            $id = [string]$task.id
            if ($seen.ContainsKey($id)) { throw "duplicate task id $id" }
            $seen[$id] = $true
        }
    }
    foreach ($phase in @($Plan.phases)) {
        $taskPhase = [int]$phase.n
        foreach ($task in @($phase.tasks)) {
            $id = [string]$task.id
            foreach ($dep in (Get-JsonPropertyStringArray $task 'dependsOn')) {
                $depId = [string]$dep
                if (-not $byId.ContainsKey($depId)) { throw "unknown dependency $depId in $id" }
                if ($byId[$depId].PhaseN -gt $taskPhase) {
                    throw "$id depends on $depId in a later phase"
                }
            }
        }
    }
    $phaseNums = @($Plan.phases | ForEach-Object { [int]$_.n })
    $unique = @($phaseNums | Select-Object -Unique)
    if ($unique.Count -ne $phaseNums.Count) { throw 'phases must be numbered 1..N' }
    $sorted = @($unique | Sort-Object)
    if ($sorted.Count -eq 0) { throw 'phases must be numbered 1..N' }
    $expected = 1
    foreach ($n in $sorted) {
        if ($n -ne $expected) { throw 'phases must be numbered 1..N' }
        $expected++
    }
    $visiting = @{}
    $done = @{}
    function Visit([string]$nodeId) {
        if ($done[$nodeId]) { return }
        if ($visiting[$nodeId]) { throw "dependency cycle involving $nodeId" }
        $visiting[$nodeId] = $true
        $t = $byId[$nodeId].Task
        foreach ($dep in (Get-JsonPropertyStringArray $t 'dependsOn')) {
            Visit ([string]$dep)
        }
        $visiting.Remove($nodeId) | Out-Null
        $done[$nodeId] = $true
    }
    foreach ($id in $byId.Keys) { Visit $id }
}

function Get-XagentMergedTaskIds {
    param([string]$Repository, [string]$FeatureName)
    $branch = "feature/$FeatureName"
    & git -C $Repository show-ref --verify --quiet "refs/heads/$branch" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return @() }
    $lines = @(Invoke-GitRepo $Repository 'log' $branch '--format=%(trailers:key=Xagent-Task,valueonly)')
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in $lines) {
        $t = ([string]$ln).Trim()
        if ($t) { $ids.Add($t) }
    }
    return @($ids | Select-Object -Unique)
}

function Escape-PlanMdCell([string]$Text) {
    return ([string]$Text) -replace '\|', '\|'
}

function Format-PlanDependsOn([object]$Task) {
    $deps = Get-JsonPropertyStringArray $Task 'dependsOn'
    if (@($deps).Length -eq 0) { return [char]0x2014 }
    return ($deps -join ', ')
}

function Format-PlanFilesCell([object]$Task) {
    $files = Get-JsonPropertyStringArray $Task 'files'
    return (Escape-PlanMdCell ($files -join '<br>'))
}

function New-PlanMdText {
    param([string]$FeatureName, [object]$Feature, [object]$Plan)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Plan: $FeatureName")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine([string]$Plan.summary)
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Check-in mode: $([string]$Feature.checkin)")
    $phases = @($Plan.phases | Sort-Object { [int]$_.n })
    foreach ($phase in $phases) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("## Phase $($phase.n)")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine([string]$phase.rationale)
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("Test: ``$([string]$phase.test)``")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Id | Title | Depends on | Files | Profile | Test |')
        [void]$sb.AppendLine('|---|---|---|---|---|---|')
        foreach ($task in @($phase.tasks)) {
            $depCell = Escape-PlanMdCell (Format-PlanDependsOn $task)
            $filesCell = Format-PlanFilesCell $task
            $titleCell = Escape-PlanMdCell ([string]$task.title)
            $testCell = Escape-PlanMdCell ([string]$task.test)
            [void]$sb.AppendLine("| $($task.id) | $titleCell | $depCell | $filesCell | $($task.profile) | ``$testCell`` |")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("**$($task.id).** $([string]$task.brief)")
        }
    }
    return $sb.ToString()
}

function Build-FeaturePhasesWithDelegateIds {
    param(
        [string]$FeatureName,
        [object]$Plan,
        [object]$HeadFeature
    )
    $prefix = Get-DelegateNamePrefix $FeatureName
    $existing = @{}
    if ($HeadFeature.PSObject.Properties['phases'] -and $null -ne $HeadFeature.phases) {
        foreach ($phase in @($HeadFeature.phases)) {
            foreach ($task in @($phase.tasks)) {
                if ($task.PSObject.Properties['delegateTaskId']) {
                    $existing[[string]$task.id] = [string]$task.delegateTaskId
                }
            }
        }
    }
    $outPhases = @()
    foreach ($phase in @($Plan.phases | Sort-Object { [int]$_.n })) {
        $outTasks = @()
        foreach ($task in @($phase.tasks)) {
            $id = [string]$task.id
            $delegateId = if ($existing.ContainsKey($id)) { $existing[$id] } else { "$prefix-$id" }
            $outTasks += [ordered]@{
                id              = $id
                title           = [string]$task.title
                dependsOn       = [string[]](Get-JsonPropertyStringArray $task 'dependsOn')
                files           = [string[]](Get-JsonPropertyStringArray $task 'files')
                test            = [string]$task.test
                profile         = [string]$task.profile
                brief           = [string]$task.brief
                delegateTaskId  = $delegateId
            }
        }
        $outPhases += [ordered]@{
            n         = [int]$phase.n
            rationale = [string]$phase.rationale
            test      = [string]$phase.test
            tasks     = @($outTasks)
        }
    }
    return @($outPhases)
}

function Invoke-PlanFeature {
    param([string]$Repository, [string]$FeatureName)
    if (-not $PlanFile) { throw '-PlanFile is required' }

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $state = Get-HeadFeatureState $Repository $FeatureName
        if ([string]$state.Feature.stage -ne 'plan') { throw 'plan is only allowed in stage plan' }

        $planPath = if ([IO.Path]::IsPathRooted($PlanFile)) { $PlanFile } else { Join-Path (Get-Location).Path $PlanFile }
        if (-not (Test-Path -LiteralPath $planPath)) { throw "plan file not found: $PlanFile" }
        $planText = [IO.File]::ReadAllText($planPath, [Text.UTF8Encoding]::new($false))
        try {
            $planObj = $planText | ConvertFrom-Json
        } catch {
            throw 'plan file is not valid JSON'
        }
        Test-PlanJsonSchema $planText

        $byId = Get-PlanTasksById $planObj
        foreach ($mergedId in @(Get-XagentMergedTaskIds $Repository $FeatureName)) {
            if (-not $byId.ContainsKey($mergedId)) {
                throw "task $mergedId is already merged and must stay unchanged"
            }
            $headTask = Get-HeadPlanTaskById $state.Feature $mergedId
            $newTask = $byId[$mergedId].Task
            if (-not $headTask -or -not (Test-PlanTaskFieldsEqual $newTask $headTask)) {
                throw "task $mergedId is already merged and must stay unchanged"
            }
        }

        Assert-PlanBusinessRules $planObj

        $phases = Build-FeaturePhasesWithDelegateIds -FeatureName $FeatureName -Plan $planObj -HeadFeature $state.Feature
        $feat = $state.Feature
        if ($feat.PSObject.Properties['summary']) {
            $feat.summary = [string]$planObj.summary
        } else {
            $feat | Add-Member -NotePropertyName summary -NotePropertyValue ([string]$planObj.summary) -Force
        }
        $phaseArray = [object[]]@($phases)
        if ($feat.PSObject.Properties['phases']) {
            $feat.phases = $phaseArray
        } else {
            $feat | Add-Member -NotePropertyName phases -NotePropertyValue $phaseArray -Force
        }

        $featDir = Split-Path $state.FeatPath -Parent
        $planMdPath = Join-Path $featDir 'plan.md'
        Write-FeatureJsonFile $state.FeatPath $feat
        Write-TextLf $planMdPath (New-PlanMdText -FeatureName $FeatureName -Feature $feat -Plan $planObj)

        Remove-Item -LiteralPath $planPath -Force
        $rel = "docs/features/$FeatureName"
        if (Test-PathHasChanges $Repository $rel) {
            $null = Invoke-FeatureCommit $Repository "feature($FeatureName): plan" @($rel)
        }

        $taskCount = 0
        foreach ($ph in @($phases)) { $taskCount += @($ph.tasks).Count }
        Out-FeatureOk @{ name = $FeatureName; phases = @($phases).Count; tasks = $taskCount }
    } finally {
        Exit-FeatureLock
    }
}

function Get-OverlapKey([string]$FileEntry) {
    $p = ([string]$FileEntry) -replace '\\', '/'
    $p = $p.ToLowerInvariant()
    if ($p.StartsWith('./', [StringComparison]::Ordinal)) { $p = $p.Substring(2) }
    if ($p -notmatch '[\*\?\[]') { return $p }
    $m = [regex]::Match($p, '[\*\?\[]')
    $before = $p.Substring(0, $m.Index)
    $slash = $before.LastIndexOf('/')
    if ($slash -lt 0) { return '' }
    return $before.Substring(0, $slash + 1)
}

function Test-OverlapKeysOverlap([string]$A, [string]$B) {
    if ($A -eq '' -or $B -eq '') { return $true }
    $aCmp = if ($A.EndsWith('/')) { $A } else { "$A/" }
    $bCmp = if ($B.EndsWith('/')) { $B } else { "$B/" }
    return ($aCmp.StartsWith($bCmp, [StringComparison]::Ordinal) -or $bCmp.StartsWith($aCmp, [StringComparison]::Ordinal))
}

function Test-TaskFileSetsOverlap([string[]]$FilesA, [string[]]$FilesB) {
    $keysA = @($FilesA | ForEach-Object { Get-OverlapKey $_ })
    $keysB = @($FilesB | ForEach-Object { Get-OverlapKey $_ })
    foreach ($ka in $keysA) {
        foreach ($kb in $keysB) {
            if (Test-OverlapKeysOverlap $ka $kb) { return $true }
        }
    }
    return $false
}

function Get-FeatureStateTaskStatuses {
    param([string]$Repository, [string]$FeatureName)
    $path = Join-Path $Repository ".xagent/features/$FeatureName/state.json"
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    $raw = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))
    $obj = $raw | ConvertFrom-Json
    $map = @{}
    if ($null -eq $obj.PSObject.Properties['tasks'] -or $null -eq $obj.tasks) { return $map }
    foreach ($prop in $obj.tasks.PSObject.Properties) {
        $rec = $prop.Value
        $st = 'pending'
        if ($null -ne $rec.PSObject.Properties['status'] -and $null -ne $rec.status) {
            $st = [string]$rec.status
        }
        $map[$prop.Name] = $st
    }
    return $map
}

function Get-LiveDelegateRunCount {
    param([string]$Repository, [string]$FeatureName)
    $runsRoot = Join-Path $Repository '.xagent/runs'
    if (-not (Test-Path -LiteralPath $runsRoot)) { return 0 }
    $count = 0
    foreach ($pidFile in Get-ChildItem -LiteralPath $runsRoot -Recurse -Filter '*.pid' -File -ErrorAction SilentlyContinue) {
        try {
            $raw = [IO.File]::ReadAllText($pidFile.FullName, [Text.UTF8Encoding]::new($false))
            $obj = $raw | ConvertFrom-Json
            if ($null -eq $obj.PSObject.Properties['pid'] -or $null -eq $obj.PSObject.Properties['startTime'] -or $null -eq $obj.PSObject.Properties['feature']) {
                continue
            }
            if ([string]$obj.feature -cne $FeatureName) { continue }
            $expected = ([datetime]$obj.startTime).ToUniversalTime()
            try {
                $proc = Get-Process -Id ([int]$obj.pid) -ErrorAction Stop
                $live = ($proc.StartTime.ToUniversalTime() -eq $expected)
                if ($live) { $count++ }
            } catch { }
        } catch { }
    }
    return $count
}

function Get-DelegateModelsMap {
    $text = [IO.File]::ReadAllText($script:ModelsPath, [Text.UTF8Encoding]::new($false))
    $obj = $text | ConvertFrom-Json
    $map = @{}
    foreach ($prop in $obj.profiles.PSObject.Properties) {
        $mp = $prop.Value.PSObject.Properties['model']
        if ($null -eq $mp) { continue }
        $map[$prop.Name] = [string]$mp.Value
    }
    return $map
}

function Invoke-ScheduleFeature {
    param([string]$Repository, [string]$FeatureName)
    $branch = "feature/$FeatureName"
    & git -C $Repository show-ref --verify --quiet "refs/heads/$branch" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "no feature $FeatureName" }

    $feat = Get-FeatureJsonFromRef $Repository $branch $FeatureName
    if (-not $feat) { throw "no feature $FeatureName" }
    $decPath = "docs/features/$FeatureName/decisions.md"
    $decText = try {
        (Invoke-GitRepo $Repository 'show' "${branch}:$decPath") -join "`n"
    } catch {
        throw "no feature $FeatureName"
    }
    if (-not $decText.EndsWith("`n")) { $decText += "`n" }

    $liveRuns = Get-LiveDelegateRunCount -Repository $Repository -FeatureName $FeatureName
    $cap = 2
    $tasksOut = @()

    if (Test-StopOpen $decText) {
        Out-FeatureOk @{ liveRuns = $liveRuns; cap = $cap; tasks = $tasksOut }
        return
    }
    if (-not $feat.PSObject.Properties['phases'] -or $null -eq $feat.phases -or @($feat.phases).Count -eq 0) {
        Out-FeatureOk @{ liveRuns = $liveRuns; cap = $cap; tasks = $tasksOut }
        return
    }
    if ($liveRuns -ge $cap) {
        Out-FeatureOk @{ liveRuns = $liveRuns; cap = $cap; tasks = $tasksOut }
        return
    }

    $statusMap = Get-FeatureStateTaskStatuses -Repository $Repository -FeatureName $FeatureName
    $phases = @($feat.phases | Sort-Object { [int]$_.n })
    $currentPhase = $null
    foreach ($phase in $phases) {
        $hasOpen = $false
        foreach ($task in @($phase.tasks)) {
            $tid = [string]$task.id
            $st = if ($statusMap.ContainsKey($tid)) { $statusMap[$tid] } else { 'pending' }
            if ($st -ne 'merged') { $hasOpen = $true; break }
        }
        if ($hasOpen) { $currentPhase = $phase; break }
    }
    if (-not $currentPhase) {
        Out-FeatureOk @{ liveRuns = $liveRuns; cap = $cap; tasks = $tasksOut }
        return
    }

    $blockStatuses = @('preflight', 'running', 'in-review')
    $blockedFileSets = [System.Collections.Generic.List[string[]]]::new()
    foreach ($phase in $phases) {
        foreach ($task in @($phase.tasks)) {
            $tid = [string]$task.id
            $st = if ($statusMap.ContainsKey($tid)) { $statusMap[$tid] } else { 'pending' }
            if ($blockStatuses -contains $st) {
                $blockedFileSets.Add((Get-JsonPropertyStringArray $task 'files')) | Out-Null
            }
        }
    }

    $models = Get-DelegateModelsMap
    $candidates = @()
    foreach ($task in @($currentPhase.tasks)) {
        $tid = [string]$task.id
        $st = if ($statusMap.ContainsKey($tid)) { $statusMap[$tid] } else { 'pending' }
        if ($st -ne 'pending') { continue }
        $depsOk = $true
        foreach ($dep in (Get-JsonPropertyStringArray $task 'dependsOn')) {
            $depSt = if ($statusMap.ContainsKey([string]$dep)) { $statusMap[[string]$dep] } else { 'pending' }
            if ($depSt -ne 'merged') { $depsOk = $false; break }
        }
        if (-not $depsOk) { continue }
        $candidates += $task
    }

    $chosen = [System.Collections.Generic.List[object]]::new()
    $slots = $cap - $liveRuns
    foreach ($cand in $candidates) {
        if ($chosen.Count -ge $slots) { break }
        $candFiles = Get-JsonPropertyStringArray $cand 'files'
        $blocked = $false
        foreach ($bf in $blockedFileSets) {
            if (Test-TaskFileSetsOverlap $candFiles $bf) { $blocked = $true; break }
        }
        if (-not $blocked) {
            foreach ($prev in $chosen) {
                $prevFiles = Get-JsonPropertyStringArray $prev 'files'
                if (Test-TaskFileSetsOverlap $candFiles $prevFiles) { $blocked = $true; break }
            }
        }
        if ($blocked) { continue }
        $chosen.Add($cand) | Out-Null
        $blockedFileSets.Add($candFiles) | Out-Null
    }

    foreach ($c in $chosen) {
        $profile = [string]$c.profile
        $model = $models[$profile]
        if (-not $model) { throw "unknown profile $profile" }
        $tasksOut += [ordered]@{
            id               = [string]$c.id
            delegateTaskId   = [string]$c.delegateTaskId
            profile          = $profile
            model            = $model
            files            = Get-JsonPropertyStringArray $c 'files'
        }
    }

    Out-FeatureOk @{ liveRuns = $liveRuns; cap = $cap; tasks = @($tasksOut) }
}

function Test-StateJsonSchema([string]$json) {
    if (-not (Test-Json -Json $json -SchemaFile $script:SchemaState -ErrorAction SilentlyContinue)) {
        throw 'state.json does not match state.schema.json'
    }
}

function New-DefaultTaskStateRecord {
    return [ordered]@{
        status     = 'pending'
        failures   = 0
        sessionId  = $null
        resultFile = $null
        worktree   = $null
        baseSha    = $null
        verify     = $null
    }
}

function Copy-TaskStateRecord([object]$Rec) {
    $out = New-DefaultTaskStateRecord
    if ($null -eq $Rec) { return $out }
    if ($Rec -is [System.Collections.IDictionary]) {
        if ($Rec.Contains('status') -and $null -ne $Rec['status']) { $out.status = [string]$Rec['status'] }
        if ($Rec.Contains('failures') -and $null -ne $Rec['failures']) { $out.failures = [int]$Rec['failures'] }
        foreach ($f in @('sessionId', 'resultFile', 'worktree', 'baseSha', 'verify')) {
            if ($Rec.Contains($f)) { $out[$f] = $Rec[$f] }
        }
        return $out
    }
    if ($null -ne $Rec.PSObject.Properties['status'] -and $null -ne $Rec.status) {
        $out.status = [string]$Rec.status
    }
    if ($null -ne $Rec.PSObject.Properties['failures'] -and $null -ne $Rec.failures) {
        $out.failures = [int]$Rec.failures
    }
    foreach ($f in @('sessionId', 'resultFile', 'worktree', 'baseSha')) {
        $p = $Rec.PSObject.Properties[$f]
        if ($null -ne $p) { $out[$f] = $p.Value }
    }
    $vp = $Rec.PSObject.Properties['verify']
    if ($null -ne $vp) { $out.verify = $vp.Value }
    return $out
}

function Get-FeatureStateObject {
    param([string]$Repository, [string]$FeatureName)
    $path = Join-Path $Repository ".xagent/features/$FeatureName/state.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return @{
            name  = $FeatureName
            tasks = @{}
        }
    }
    $raw = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))
    $obj = $raw | ConvertFrom-Json
    $tasks = @{}
    if ($null -ne $obj.PSObject.Properties['tasks'] -and $null -ne $obj.tasks) {
        foreach ($prop in $obj.tasks.PSObject.Properties) {
            $tasks[$prop.Name] = Copy-TaskStateRecord $prop.Value
        }
    }
    $state = @{
        name  = $FeatureName
        tasks = $tasks
    }
    $lr = $obj.PSObject.Properties['lastReconcile']
    if ($null -ne $lr -and $null -ne $lr.Value) {
        $state.lastReconcile = ([datetime]$lr.Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return $state
}

function Write-FeatureStateObject {
    param([string]$Repository, [string]$FeatureName, $State)
    $path = Join-Path $Repository ".xagent/features/$FeatureName/state.json"
    $dir = Split-Path $path -Parent
    New-Item -ItemType Directory -Force $dir | Out-Null
    $body = @{
        name  = $FeatureName
        tasks = $State.tasks
    }
    if ($State.ContainsKey('lastReconcile') -and $null -ne $State.lastReconcile) {
        $body['lastReconcile'] = $State.lastReconcile
    }
    $json = $body | ConvertTo-Json -Depth 10
    $json = $json -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    Test-StateJsonSchema $json
    Write-TextLf $path $json.TrimEnd("`n")
}

function Set-FeatureStateTask {
    param(
        [string]$Repository,
        [string]$FeatureName,
        [string]$TaskId,
        [scriptblock]$Update
    )
    $state = Get-FeatureStateObject -Repository $Repository -FeatureName $FeatureName
    $rec = if ($state.tasks.ContainsKey($TaskId)) {
        Copy-TaskStateRecord $state.tasks[$TaskId]
    }
    else {
        New-DefaultTaskStateRecord
    }
    & $Update $rec
    $state.tasks[$TaskId] = $rec
    Write-FeatureStateObject -Repository $Repository -FeatureName $FeatureName -State $state
    return $rec
}

function Get-PlanTaskFromFeature {
    param([string]$Repository, [string]$FeatureName, [string]$TaskId)
    $branch = "feature/$FeatureName"
    & git -C $Repository show-ref --verify --quiet "refs/heads/$branch" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "no feature $FeatureName" }
    $feat = Get-FeatureJsonFromRef $Repository $branch $FeatureName
    if (-not $feat) { throw "no feature $FeatureName" }
    $planTask = Get-HeadPlanTaskById -Feature $feat -TaskId $TaskId
    if (-not $planTask) { throw "unknown task $TaskId" }
    return $planTask
}

function Normalize-ScopePath([string]$Path) {
    $p = ([string]$Path) -replace '\\', '/'
    $p = $p.ToLowerInvariant()
    if ($p.StartsWith('./', [StringComparison]::Ordinal)) { $p = $p.Substring(2) }
    return $p
}

function Convert-ScopeGlobToRegex([string]$Glob) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('^')
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '*' -and ($i + 1) -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
            if (($i + 2) -lt $Glob.Length -and $Glob[$i + 2] -eq '/') {
                [void]$sb.Append('(?:[^/]+/)*')
                $i += 3
            } else {
                [void]$sb.Append('(?s:.*)')
                $i += 2
            }
        } elseif ($c -eq '*') {
            [void]$sb.Append('[^/]*')
            $i++
        } elseif ($c -eq '?') {
            [void]$sb.Append('[^/]')
            $i++
        } else {
            if ($c -match '[\.\+\^\$\{\}\(\)\|\[\]\\]') { [void]$sb.Append('\') }
            [void]$sb.Append($c)
            $i++
        }
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}

function Test-PathInScope {
    param([string]$Path, [string[]]$ScopeFiles)
    $normPath = Normalize-ScopePath $Path
    foreach ($entry in @($ScopeFiles)) {
        $normEntry = Normalize-ScopePath $entry
        if ($normEntry.EndsWith('/')) {
            if ($normPath.StartsWith($normEntry, [StringComparison]::Ordinal)) { return $true }
            continue
        }
        if ($normEntry -notmatch '[\*\?]') {
            if ($normPath -ceq $normEntry) { return $true }
            continue
        }
        $rx = Convert-ScopeGlobToRegex $normEntry
        if ([regex]::IsMatch($normPath, $rx)) { return $true }
    }
    return $false
}

function Get-ChangedPaths {
    param([string]$WorktreePath, [string]$BaseSha)
    $gitBase = @('-c', 'core.quotepath=off', '-C', $WorktreePath)
    $diffOut = @(& git @gitBase 'diff' '--name-only' $BaseSha 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "git diff --name-only $BaseSha failed" }
    $untracked = @(& git @gitBase 'ls-files' '--others' '--exclude-standard' 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files --others failed' }
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($p in (@($diffOut) + @($untracked))) {
        $line = ([string]$p).Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('.xagent/', [StringComparison]::Ordinal)) { continue }
        [void]$set.Add($line)
    }
    $arr = [string[]]::new($set.Count)
    $set.CopyTo($arr)
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return ,[string[]]$arr
}

function Invoke-TaskTestCommand {
    param(
        [string]$WorktreePath,
        [string]$TestCommand,
        [int]$TimeoutSec
    )
    $wrapper = @"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false)
`$ErrorActionPreference = 'Stop'
`$global:LASTEXITCODE = 0
try { & { $TestCommand } 2>&1 | ForEach-Object { "`$_" } } catch { "`$_"; exit 1 }
exit `$LASTEXITCODE
"@
    $bytes = [Text.Encoding]::Unicode.GetBytes($wrapper)
    $encoded = [Convert]::ToBase64String($bytes)
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ("xagent-verify-out-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ("xagent-verify-err-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $exitCode = 0
    $timedOut = $false
    try {
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
        ) -WorkingDirectory $WorktreePath -PassThru -NoNewWindow `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $waited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $waited) {
            $timedOut = $true
            & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
            $proc.WaitForExit(10000) | Out-Null
            $exitCode = -1
        } else {
            $exitCode = $proc.ExitCode
        }
    } finally {
        $stdout = ''
        $stderr = ''
        if (Test-Path -LiteralPath $outFile) {
            $stdout = [IO.File]::ReadAllText($outFile, [Text.UTF8Encoding]::new($false))
        }
        if (Test-Path -LiteralPath $errFile) {
            $stderr = [IO.File]::ReadAllText($errFile, [Text.UTF8Encoding]::new($false))
        }
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in (($stdout -split "`n") + ($stderr -split "`n"))) {
        $lines.Add($ln.TrimEnd("`r"))
    }
    while ($lines.Count -gt 0 -and [string]::IsNullOrEmpty($lines[$lines.Count - 1])) {
        $lines.RemoveAt($lines.Count - 1)
    }
    $take = [Math]::Min(40, $lines.Count)
    $tailLines = if ($take -eq 0) { @() } else { $lines.GetRange($lines.Count - $take, $take) }
    if ($timedOut) {
        $tailLines += "timed out after $TimeoutSec s"
    }
    $tail = ($tailLines -join "`n")
    return @{
        command  = $TestCommand
        passed   = ($exitCode -eq 0)
        exitCode = $exitCode
        tail     = $tail
    }
}

function Invoke-TaskFeature {
    param(
        [string]$Repository,
        [string]$FeatureName,
        [hashtable]$Bound
    )
    if (-not $Bound) { $Bound = @{} }
    if (-not $Task) { throw '-Task is required' }
    $null = Get-PlanTaskFromFeature -Repository $Repository -FeatureName $FeatureName -TaskId $Task

    $setStatus = $Bound.ContainsKey('Status')
    $setSession = $Bound.ContainsKey('SessionId')
    $setResult = $Bound.ContainsKey('ResultFile')
    $setWorktree = $Bound.ContainsKey('Worktree')
    $setBaseSha = $Bound.ContainsKey('BaseSha')

    Enter-FeatureLock $Repository $FeatureName
    try {
        $rec = Set-FeatureStateTask -Repository $Repository -FeatureName $FeatureName -TaskId $Task -Update {
            param($r)
            if ($setStatus) {
                if ($Status -eq '') { throw "invalid status $Status" }
                if ($script:TaskStatuses -notcontains $Status) { throw "invalid status $Status" }
                if ($Status -eq 'failed' -and $r.status -cne 'failed') {
                    $r.failures = [int]$r.failures + 1
                }
                $r.status = $Status
            }
            if ($setSession) {
                $r.sessionId = if ($SessionId -eq '') { $null } else { $SessionId }
            }
            if ($setResult) {
                $r.resultFile = if ($ResultFile -eq '') { $null } else { $ResultFile }
            }
            if ($setWorktree) {
                if ($Worktree -eq '') {
                    $r.worktree = $null
                } else {
                    $full = [IO.Path]::GetFullPath($Worktree.Trim())
                    $r.worktree = $full.Replace('\', '/')
                }
            }
            if ($setBaseSha) {
                if ($BaseSha -eq '') {
                    $r.baseSha = $null
                } elseif ($BaseSha -notmatch '^[0-9a-f]{40}$') {
                    throw 'invalid -BaseSha'
                } else {
                    $r.baseSha = $BaseSha
                }
            }
        }
        Out-FeatureOk @{ name = $FeatureName; task = $Task; state = $rec }
    } finally {
        Exit-FeatureLock
    }
}

function Invoke-VerifyFeature {
    param(
        [string]$Repository,
        [string]$FeatureName,
        [hashtable]$Bound
    )
    if (-not $Bound) { $Bound = @{} }
    if (-not $Task) { throw '-Task is required' }
    $planTask = Get-PlanTaskFromFeature -Repository $Repository -FeatureName $FeatureName -TaskId $Task
    $timeout = 900
    if ($Bound.ContainsKey('TimeoutSec')) {
        $parsed = 0
        if (-not [int]::TryParse($TimeoutSec, [ref]$parsed) -or $parsed -le 0) {
            throw 'invalid -TimeoutSec'
        }
        $timeout = $parsed
    }

    $stateObj = Get-FeatureStateObject -Repository $Repository -FeatureName $FeatureName
    if (-not $stateObj.tasks.ContainsKey($Task)) {
        throw "task $Task has no worktree in state.json; set it with task -Worktree -BaseSha"
    }
    $taskRec = $stateObj.tasks[$Task]
    $wt = $taskRec.worktree
    $base = $taskRec.baseSha
    if ($null -eq $wt -or $null -eq $base) {
        throw "task $Task has no worktree in state.json; set it with task -Worktree -BaseSha"
    }
    if (-not (Test-Path -LiteralPath $wt)) {
        throw "worktree not found: $wt"
    }

    $changed = Get-ChangedPaths -WorktreePath $wt -BaseSha $base
    $scopeFiles = Get-JsonPropertyStringArray $planTask 'files'
    $outOfScope = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $changed) {
        if (-not (Test-PathInScope -Path $p -ScopeFiles $scopeFiles)) {
            $outOfScope.Add($p) | Out-Null
        }
    }
    $outArr = @($outOfScope.ToArray())
    $inScope = ($outArr.Count -eq 0)
    $testCmd = [string]$planTask.test
    $testResult = Invoke-TaskTestCommand -WorktreePath $wt -TestCommand $testCmd -TimeoutSec $timeout

    $verifyRec = [ordered]@{
        at          = Get-UtcDecisionTime
        inScope     = $inScope
        changed     = [string[]]@($changed)
        outOfScope  = [string[]]@($outArr)
        test        = $testResult
    }

    Enter-FeatureLock $Repository $FeatureName
    try {
        Set-FeatureStateTask -Repository $Repository -FeatureName $FeatureName -TaskId $Task -Update {
            param($r)
            $r.verify = [pscustomobject]$verifyRec
        } | Out-Null
    } finally {
        Exit-FeatureLock
    }

    Out-FeatureOk @{
        name       = $FeatureName
        task       = $Task
        inScope    = $inScope
        changed    = [string[]]@($changed)
        outOfScope = [string[]]@($outArr)
        test       = $testResult
    }
}

function Invoke-MergeFeature {
    param([string]$Repository, [string]$FeatureName)
    if (-not $Task) { throw '-Task is required' }
    Assert-OneLine 'Message' $Message
    if (-not $Message) { throw '-Message is required' }

    $planTask = Get-PlanTaskFromFeature -Repository $Repository -FeatureName $FeatureName -TaskId $Task
    $delegateTaskId = [string]$planTask.delegateTaskId
    $agentBranch = "xagent/$delegateTaskId"

    Enter-FeatureLock $Repository $FeatureName
    try {
        & git -C $Repository rev-parse -q --verify MERGE_HEAD 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { throw 'a merge is in progress; finish or abort it first' }

        if (-not (Test-TreeClean $Repository)) { throw 'working tree is not clean' }
        Assert-OnFeatureBranch $Repository $FeatureName

        & git -C $Repository show-ref --verify --quiet "refs/heads/$agentBranch" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "no branch $agentBranch" }

        $featureBranch = "feature/$FeatureName"
        if (Test-MergeBaseIsAncestor $Repository $agentBranch $featureBranch) {
            throw "$agentBranch is already merged"
        }

        $stateObj = Get-FeatureStateObject -Repository $Repository -FeatureName $FeatureName
        if ($stateObj.tasks.ContainsKey($Task)) {
            $wt = $stateObj.tasks[$Task].worktree
            if ($null -ne $wt -and (Test-Path -LiteralPath $wt)) {
                $porcelain = & git -C $wt 'status' '--porcelain' '--untracked-files=all' 2>&1
                if ($LASTEXITCODE -ne 0) { throw "git status in worktree: $porcelain" }
                if ((@(@($porcelain) | Where-Object { $_ })).Count -gt 0) {
                    throw "worktree has uncommitted changes; commit them on $agentBranch first"
                }
            }
        }

        $out = & git -C $Repository merge --no-ff -m $Message -m "Xagent-Task: $Task" $agentBranch 2>&1
        if ($LASTEXITCODE -ne 0) {
            $conflictFiles = @()
            try {
                $conflictFiles = @(Invoke-GitRepo $Repository 'diff' '--name-only' '--diff-filter=U')
            } catch { }
            $hasMergeHead = $false
            & git -C $Repository rev-parse -q --verify MERGE_HEAD 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $hasMergeHead = $true }
            if ($hasMergeHead) {
                Invoke-GitRepo $Repository 'merge' '--abort' | Out-Null
            }
            if ($conflictFiles.Count -gt 0) {
                throw ("merge conflict in " + ($conflictFiles -join ', '))
            }
            $msg = ($out | Out-String).Trim()
            throw "git merge failed: $msg"
        }

        $mergeSha = @(Invoke-GitRepo $Repository 'rev-parse' 'HEAD')[0]
        Set-FeatureStateTask -Repository $Repository -FeatureName $FeatureName -TaskId $Task -Update {
            param($r)
            $r.status = 'merged'
        } | Out-Null

        Out-FeatureOk @{
            name     = $FeatureName
            task     = $Task
            branch   = $agentBranch
            mergeSha = $mergeSha
        }
    } finally {
        Exit-FeatureLock
    }
}

function Invoke-CheckinFeature {
    param([string]$Repository, [string]$FeatureName)
    if ($Mode -notin @('on-problems', 'every-phase')) { throw 'invalid checkin mode' }

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $state = Get-HeadFeatureState $Repository $FeatureName
        $feat = $state.Feature
        if ([string]$feat.checkin -eq $Mode) { throw "checkin mode is already $Mode" }
        $feat.checkin = $Mode
        $line = Format-DecisionLine -Kind 'decision' -Body "checkin: $Mode"
        Write-FeatureJsonFile $state.FeatPath $feat
        Append-TextLf $state.DecPath $line.TrimEnd("`n")
        $rel = "docs/features/$FeatureName"
        $suffix = Get-DecisionCommitSuffix $line
        $null = Invoke-FeatureCommit $Repository "feature($FeatureName): $suffix" @($rel)
        Out-FeatureOk @{ name = $FeatureName; mode = $Mode }
    } finally {
        Exit-FeatureLock
    }
}

try {
    Assert-DelegateFiles
    $repoRoot = Resolve-Repository
    Ensure-XagentExclude $repoRoot

    if (-not $Subcommand) { throw 'subcommand required' }

    switch ($Subcommand) {
        'new' {
            Invoke-NewFeature $repoRoot
        }
        'stage' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-StageFeature $repoRoot $fname
        }
        'gate' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-GateFeature $repoRoot $fname
        }
        'decision' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-DecisionFeature $repoRoot $fname
        }
        'reaudit' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-ReauditFeature $repoRoot $fname
        }
        'commit-design' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-CommitDesign $repoRoot $fname
        }
        'commit-records' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-CommitRecords $repoRoot $fname
        }
        'checkin' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-CheckinFeature $repoRoot $fname
        }
        'plan' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-PlanFeature $repoRoot $fname
        }
        'schedule' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-ScheduleFeature $repoRoot $fname
        }
        'task' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-TaskFeature $repoRoot $fname $PSBoundParameters
        }
        'verify' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-VerifyFeature $repoRoot $fname $PSBoundParameters
        }
        'merge' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-MergeFeature $repoRoot $fname
        }
        default { throw "unknown subcommand $Subcommand" }
    }
} catch {
    $msg = $_.Exception.Message
    Out-FeatureFail $msg
}
