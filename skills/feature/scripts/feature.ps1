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
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Stages = @('design', 'design-review', 'plan', 'build', 'signoff')
$script:StageExitGate = @{
    'design-review' = 'design-locked'
    'plan'          = 'plan-approved'
    'signoff'       = 'signed-off'
}
$script:DecisionKinds = @('decision', 'gate', 'stage', 'round', 'council', 'fix-up', 'dismiss', 'stop', 'resume')
$script:SkillDir = Split-Path $PSScriptRoot -Parent
$script:SchemaFeature = Join-Path $script:SkillDir 'schemas/feature.schema.json'
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
        default { throw "unknown subcommand $Subcommand" }
    }
} catch {
    $msg = $_.Exception.Message
    if ($_.Exception.InnerException) { $msg = $_.Exception.Message }
    Out-FeatureFail $msg
}
