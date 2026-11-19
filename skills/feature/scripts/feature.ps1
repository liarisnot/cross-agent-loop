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
    [string]$TimeoutSec,
    [string]$DesignDoc
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
        $full = ([IO.Path]::GetFullPath($Repo)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $top = & git -C $full 'rev-parse' '--show-toplevel' 2>$null
        if ($LASTEXITCODE -eq 0 -and $top) {
            return $top.TrimEnd('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
        }
        return $full
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


function Test-DesignDocGiven([string]$DesignDoc) {
    return (-not [string]::IsNullOrWhiteSpace($DesignDoc))
}

function Normalize-DesignDocPath([string]$DesignDoc) {
    $p = $DesignDoc.Trim()
    $p = $p -replace '\\', '/'
    if ($p.StartsWith('./', [StringComparison]::Ordinal)) { $p = $p.Substring(2) }
    return $p
}

function Assert-RepoRelativeDesignDoc([string]$Normalized) {
    if ($Normalized.StartsWith('/', [StringComparison]::Ordinal)) { throw '-DesignDoc must be a repo-relative path' }
    foreach ($seg in $Normalized.Split('/', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($seg -ceq '..') { throw '-DesignDoc must be a repo-relative path' }
    }
}

function Resolve-NewFeatureDesignDoc {
    param(
        [string]$Repository,
        [string]$FeatureName,
        [string]$DesignDocInput
    )
    if (Test-DesignDocGiven $DesignDocInput) {
        Assert-OneLine '-DesignDoc' $DesignDocInput
        $trimmed = $DesignDocInput.Trim()
        if ([IO.Path]::IsPathRooted($trimmed)) { throw '-DesignDoc must be a repo-relative path' }
        $designDoc = Normalize-DesignDocPath $DesignDocInput
        Assert-RepoRelativeDesignDoc $designDoc
        if (-not $designDoc.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) {
            throw '-DesignDoc must be a .md file'
        }
    } else {
        $designDoc = "docs/designs/$FeatureName.md"
        $defaultFull = Join-Path $Repository $designDoc
        if (Test-Path -LiteralPath $defaultFull) {
            throw "design doc docs/designs/$FeatureName.md already exists; pass -DesignDoc to adopt it, or choose another name"
        }
    }
    $designDocFull = Join-Path $Repository $designDoc
    $designDocExists = Test-Path -LiteralPath $designDocFull
    return @{ designDoc = $designDoc; designDocExists = $designDocExists }
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
    $head72 = $msg.Substring(0, 72)
    $lastSpace = -1
    for ($i = 40; $i -lt 72; $i++) {
        if ($head72[$i] -eq ' ') { $lastSpace = $i }
    }
    if ($lastSpace -ge 40) {
        $result = $head72.Substring(0, $lastSpace)
    } else {
        $result = $msg.Substring(0, 71)
    }
    $result = $result -replace '[ ,;:\-\u2013]+$', ''
    return $result + [char]0x2026
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
    $fromBranch = @{}
    foreach ($n in Get-FeatureBranchNames $Repository) {
        $feat = Get-FeatureJsonFromRef $Repository "feature/$n" $n
        if ($feat) {
            $eff = Get-EffectiveStage $Repository $n $feat
            $stage = if ($null -ne $eff) { $eff } else { [string]$feat.stage }
            $result += [pscustomobject]@{
                name  = $n
                stage = $stage
            }
            $fromBranch[$n] = $true
        }
    }
    & git -C $Repository show-ref --verify --quiet 'refs/heads/main' 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $treeLines = @(& git -C $Repository 'ls-tree' '--name-only' 'main' 'docs/features/' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $treeLines.Count -gt 0) {
            $fromMain = @()
            foreach ($line in $treeLines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $leaf = $line.TrimEnd('/')
                if ($leaf -match '^docs/features/(.+)$') { $leaf = $Matches[1] }
                $n = ($leaf -split '/')[ -1]
                if (-not (Test-FeatureName $n)) { continue }
                if ($fromBranch.ContainsKey($n)) { continue }
                $feat = Get-FeatureJsonFromRef $Repository 'main' $n
                if (-not $feat) { continue }
                if (-not $feat.PSObject.Properties['gates']) { continue }
                if ([string]$feat.stage -eq 'abandoned') { continue }
                if (-not $feat.gates.PSObject.Properties['signed-off']) { continue }
                $fromMain += [pscustomobject]@{ name = $n; stage = 'done' }
            }
            if ($fromMain.Count -gt 0) {
                $result += @($fromMain | Sort-Object { $_.name })
            }
        }
    }
    return $result
}

function Get-InProgressFeatures([string]$Repository) {
    return @(Get-FeatureList $Repository | Where-Object { $_.stage -ne 'done' -and $_.stage -ne 'abandoned' })
}

function Select-FeatureName {
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
    return $null
}

function Resolve-FeatureName {
    param([string]$Repository)
    $picked = Select-FeatureName $Repository
    if ($null -eq $picked) { throw 'no feature selected; name one with -Name' }
    return $picked
}

function Get-ReviewNumber {
    param(
        [string]$Repository,
        [string]$FeatureName,
        [ValidateSet('design', 'plan')]
        [string]$Kind
    )
    $pattern = if ($Kind -eq 'design') { 'design-' } else { 'plan-' }
    $branch = "feature/$FeatureName"
    $treeLines = @(Invoke-GitRepo $Repository 'ls-tree' '-r' '--name-only' $branch "--" "docs/features/$FeatureName/reviews/")
    $count = @($treeLines | Where-Object { $_ -notmatch '/reviews/raw/' -and $_ -match "/reviews/$pattern.*\.md$" }).Count
    return 1 + $count
}

function Assert-FeatureExists {
    param([string]$Repository, [string]$FeatureName)
    & git -C $Repository show-ref --verify --quiet "refs/heads/feature/$FeatureName" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "no feature $FeatureName" }
    $feat = Get-FeatureJsonFromRef $Repository "feature/$FeatureName" $FeatureName
    if (-not $feat) { throw "no feature $FeatureName" }
}

function Get-StatusModelsRoot {
    $text = [IO.File]::ReadAllText($script:ModelsPath, [Text.UTF8Encoding]::new($false))
    return $text | ConvertFrom-Json
}

function Get-StatusStandardsMap {
    $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../delegate/personas/standards.json'))
    $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))
    $obj = $text | ConvertFrom-Json
    $map = @{}
    foreach ($prop in $obj.PSObject.Properties) {
        $map[$prop.Name] = if ($null -eq $prop.Value) { $null } else { [string]$prop.Value }
    }
    return $map
}

function Get-StatusPersonaModel {
    param([string]$Persona, $ModelsRoot)
    $grok = [string]$ModelsRoot.seats.judgement[0]
    $glm = [string]$ModelsRoot.seats.judgement[1]
    $deepseek = [string]$ModelsRoot.seats.readiness
    $composer = [string]$ModelsRoot.profiles.review.model
    switch ($Persona) {
        'zoom_out' { return $grok }
        'inventive_catalyst' { return $glm }
        'comprehension' { return $composer }
        'design_critic' { return $glm }
        'structural' { return $grok }
        'style' { return $glm }
        'implementation_readiness' { return $deepseek }
        'codebase_details' { return $grok }
        'drift_report' { return $grok }
        default { throw "unknown review persona $Persona" }
    }
}

function Get-StatusReviewBaseDefinitions {
    param([ValidateSet('design', 'plan', 'signoff')][string]$Kind)
    if ($Kind -eq 'signoff') {
        return ,@(
            @{ phase = $null; persona = 'drift_report'; code = 'dr' }
        )
    }
    if ($Kind -eq 'plan') {
        return ,@(
            @{ phase = $null; persona = 'comprehension'; code = 'cm' },
            @{ phase = $null; persona = 'implementation_readiness'; code = 'ir' }
        )
    }
    return ,@(
        @{ phase = 5; persona = 'zoom_out'; code = 'zo' },
        @{ phase = 5; persona = 'inventive_catalyst'; code = 'ic' },
        @{ phase = 6; persona = 'comprehension'; code = 'cm' },
        @{ phase = 7; persona = 'design_critic'; code = 'dc' },
        @{ phase = 7; persona = 'structural'; code = 'st' },
        @{ phase = 7; persona = 'style'; code = 'sy' },
        @{ phase = 8; persona = 'zoom_out'; code = 'zo' },
        @{ phase = 9; persona = 'implementation_readiness'; code = 'ir' },
        @{ phase = 9; persona = 'codebase_details'; code = 'cd' },
        @{ phase = 9; persona = 'style'; code = 'sy' }
    )
}

function Test-StatusReviewRawDone {
    param([string]$Repository, [string]$FeatureName, [string]$RunId)
    $ref = "feature/${FeatureName}:docs/features/$FeatureName/reviews/raw/$RunId.md"
    & git -C $Repository cat-file -e $ref 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function New-StatusReviewRunRow {
    param(
        [string]$Repository,
        [string]$FeatureName,
        [string]$Prefix,
        [string]$KindLetter,
        [int]$ReviewN,
        $Def,
        $ModelsRoot,
        $StandardsMap
    )
    $phase = $Def.phase
    $code = [string]$Def.code
    $persona = [string]$Def.persona
  $id = if ($KindLetter -eq 's') {
        "${Prefix}-s1-$code"
    }
    elseif ($null -eq $phase) {
        "${Prefix}-${KindLetter}${ReviewN}-$code"
    }
    else {
        "${Prefix}-${KindLetter}${ReviewN}-$code-p$phase"
    }
    $standard = if ($StandardsMap.ContainsKey($persona)) { $StandardsMap[$persona] } else { $null }
    return [ordered]@{
        id       = $id
        phase    = $phase
        persona  = $persona
        model    = Get-StatusPersonaModel $persona $ModelsRoot
        standard = $standard
        done     = (Test-StatusReviewRawDone $Repository $FeatureName $id)
    }
}

function Add-StatusReviewRunsForDefs {
    param(
        [System.Collections.Generic.List[object]]$Runs,
        [string]$Repository,
        [string]$FeatureName,
        [string]$Prefix,
        [string]$KindLetter,
        [int]$ReviewN,
        [object[]]$Defs,
        $ModelsRoot,
        $StandardsMap,
        [string]$Suffix = ''
    )
    foreach ($def in $Defs) {
        $row = New-StatusReviewRunRow $Repository $FeatureName $Prefix $KindLetter $ReviewN $def $ModelsRoot $StandardsMap
        if ($Suffix) { $row.id = [string]$row.id + $Suffix }
        if ($null -eq $row.phase) { $row.phase = $null }
        $Runs.Add([pscustomobject]$row) | Out-Null
    }
}

function Get-StatusReviewRuns {
    param(
        [string]$Repository,
        [string]$FeatureName,
        [string]$Stage,
        [string]$DecisionsText
    )
    $runs = [System.Collections.Generic.List[object]]::new()
    $stage = [string]$Stage
    if ($stage -notin @('design-review', 'plan', 'signoff')) { return ,@() }

    $prefix = Get-DelegateNamePrefix $FeatureName
    $modelsRoot = Get-StatusModelsRoot
    $standardsMap = Get-StatusStandardsMap

    if ($stage -eq 'signoff') {
        $defs = Get-StatusReviewBaseDefinitions 'signoff'
        Add-StatusReviewRunsForDefs $runs $Repository $FeatureName $prefix 's' 1 $defs $modelsRoot $standardsMap | Out-Null
        return ,@($runs)
    }

    $kind = if ($stage -eq 'design-review') { 'design' } else { 'plan' }
    $letter = if ($stage -eq 'design-review') { 'd' } else { 'p' }
    $reviewN = Get-ReviewNumber $Repository $FeatureName $kind
    $baseDefs = Get-StatusReviewBaseDefinitions $kind
    $baseRuns = [System.Collections.Generic.List[object]]::new()
    Add-StatusReviewRunsForDefs $baseRuns $Repository $FeatureName $prefix $letter $reviewN $baseDefs $modelsRoot $standardsMap | Out-Null

    $reauditRuns = [System.Collections.Generic.List[object]]::new()
    $reauditCounts = @{}
    foreach ($line in ($DecisionsText -split "`n")) {
        if ($line -notmatch '^- \S+ \[reaudit\] (.+)$') { continue }
        $body = $Matches[1]
        if ($stage -eq 'design-review') {
            if ($body -notmatch "^d${reviewN}: phase (\d+)$") { continue }
            $phaseN = [int]$Matches[1]
            $key = "${reviewN}:$phaseN"
            $reauditCounts[$key] = 1 + $(if ($reauditCounts.ContainsKey($key)) { $reauditCounts[$key] } else { 0 })
            $k = $reauditCounts[$key]
            $phaseDefs = @($baseDefs | Where-Object { $_.phase -eq $phaseN })
            Add-StatusReviewRunsForDefs $reauditRuns $Repository $FeatureName $prefix $letter $reviewN $phaseDefs $modelsRoot $standardsMap "-r$k" | Out-Null
        }
        else {
            if ($body -notmatch "^p${reviewN}: phase \d+$") { continue }
            $key = "$reviewN"
            $reauditCounts[$key] = 1 + $(if ($reauditCounts.ContainsKey($key)) { $reauditCounts[$key] } else { 0 })
            $k = $reauditCounts[$key]
            Add-StatusReviewRunsForDefs $reauditRuns $Repository $FeatureName $prefix $letter $reviewN $baseDefs $modelsRoot $standardsMap "-r$k" | Out-Null
        }
    }

    if ($reauditRuns.Count -gt 0 -and -not (@($baseRuns | Where-Object { $_.done }).Count)) {
        return ,@($reauditRuns)
    }
    foreach ($r in $reauditRuns) { $baseRuns.Add($r) | Out-Null }
    return ,@($baseRuns)
}

function Get-TaskDecisionCounts {
    param([string]$DecisionsText, [string]$TaskId)
    $lines = @($DecisionsText -split "`n")
    $escaped = [Regex]::Escape($TaskId)
    $lastCouncilIdx = -1
    $councils = 0
    $rounds = 0
    for ($i = 0; $i -lt @($lines).Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match "^- \S+ \[council\] ${escaped}:") {
            $councils++
            $lastCouncilIdx = $i
        }
    }
    for ($i = 0; $i -lt @($lines).Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match "^- \S+ \[round\] ${escaped}:") {
            if ($i -gt $lastCouncilIdx) { $rounds++ }
        }
    }
    return @{ councils = $councils; rounds = $rounds }
}

function Get-StatusOpenStopText([string]$DecisionsText) {
    if (-not (Test-StopOpen $DecisionsText)) { return $null }
    $text = $null
    foreach ($line in ($DecisionsText -split "`n")) {
        if ($line -match '^- \S+ \[stop\] (.+)$') { $text = $Matches[1] }
    }
    return $text
}

function Get-StatusLastDecisions([string]$DecisionsText) {
    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($DecisionsText -split "`n")) {
        if ($line.StartsWith('- ')) { $hits.Add($line) | Out-Null }
    }
    $all = @($hits)
    if (@($all).Count -eq 0) { return ,@() }
    $take = [Math]::Min(3, @($all).Count)
    return ,@($all[(@($all).Count - $take)..(@($all).Count - 1)])
}

function Get-StatusTaskStatusMap {
    param([string]$Repository, [string]$FeatureName, $StateObj)
    $merged = @{}
    foreach ($mid in @(Get-XagentMergedTaskIds $Repository $FeatureName)) { $merged[$mid] = $true }
    $map = @{}
    foreach ($key in $StateObj.tasks.Keys) {
        if ($merged.ContainsKey($key)) {
            $map[$key] = 'merged'
        }
        else {
            $rec = $StateObj.tasks[$key]
            $st = 'pending'
            if ($rec -is [System.Collections.IDictionary]) {
                if ($rec.Contains('status') -and $null -ne $rec['status']) { $st = [string]$rec['status'] }
            }
            elseif ($null -ne $rec.PSObject.Properties['status'] -and $null -ne $rec.status) {
                $st = [string]$rec.status
            }
            $map[$key] = $st
        }
    }
    foreach ($mid in $merged.Keys) {
        if (-not $map.ContainsKey($mid)) { $map[$mid] = 'merged' }
    }
    return $map
}

function Get-StatusPhaseInfo {
    param($Feature, $StatusMap)
    if ($null -eq $Feature.PSObject.Properties['phases'] -or $null -eq $Feature.phases -or @($Feature.phases).Count -eq 0) {
        return $null
    }
    $phases = @($Feature.phases | Sort-Object { [int]$_.n })
    $total = @($phases).Count
    $current = $total
    foreach ($phase in $phases) {
        $open = $false
        foreach ($task in @($phase.tasks)) {
            $tid = [string]$task.id
            $st = if ($StatusMap.ContainsKey($tid)) { $StatusMap[$tid] } else { 'pending' }
            if ($st -ne 'merged') { $open = $true; break }
        }
        if ($open) {
            $current = [int]$phase.n
            break
        }
    }
    return @{ current = $current; total = $total }
}

function Get-StatusTasksList {
    param(
        [string]$Repository,
        [string]$FeatureName,
        $Feature,
        $StateObj,
        [string]$DecisionsText
    )
    $statusMap = Get-StatusTaskStatusMap $Repository $FeatureName $StateObj
    $tasksOut = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Feature.PSObject.Properties['phases'] -or $null -eq $Feature.phases) { return ,@() }
    foreach ($phase in @($Feature.phases | Sort-Object { [int]$_.n })) {
        foreach ($task in @($phase.tasks)) {
            $tid = [string]$task.id
            $counts = Get-TaskDecisionCounts $DecisionsText $tid
            $failures = 0
            if ($StateObj.tasks.ContainsKey($tid)) {
                $tr = $StateObj.tasks[$tid]
                if ($tr -is [System.Collections.IDictionary] -and $tr.Contains('failures') -and $null -ne $tr['failures']) {
                    $failures = [int]$tr['failures']
                }
                elseif ($null -ne $tr.PSObject.Properties['failures'] -and $null -ne $tr.failures) {
                    $failures = [int]$tr.failures
                }
            }
            $st = if ($statusMap.ContainsKey($tid)) { $statusMap[$tid] } else { 'pending' }
            $tasksOut.Add([ordered]@{
                    id             = $tid
                    delegateTaskId = [string]$task.delegateTaskId
                    status         = $st
                    rounds         = $counts.rounds
                    councils       = $counts.councils
                    failures       = $failures
                }) | Out-Null
        }
    }
    return ,@($tasksOut)
}

function Get-StatusWaitingOn {
    param(
        $Feature,
        [string]$DecisionsText,
        $TasksList,
        [string]$Stage
    )
    $stopText = Get-StatusOpenStopText $DecisionsText
    if ($null -ne $stopText) { return @{ stop = $stopText } }
    $running = [System.Collections.Generic.List[string]]::new()
    $block = @('preflight', 'running', 'in-review')
    foreach ($t in @($TasksList)) {
        if ($block -contains [string]$t.status) {
            $running.Add([string]$t.delegateTaskId) | Out-Null
        }
    }
    if (@($running).Count -gt 0) { return @{ running = [string[]]@($running) } }
    if ($Stage -in @('design-review', 'plan', 'signoff')) {
        $gate = $script:StageExitGate[$Stage]
        $hasGate = $null -ne $Feature.gates -and $null -ne $Feature.gates.PSObject.Properties[$gate]
        if (-not $hasGate) { return @{ gate = $gate } }
    }
    return $null
}

function Test-StatusAllTasksMerged {
    param($TasksList)
    if (@($TasksList).Count -eq 0) { return $false }
    foreach ($t in @($TasksList)) {
        if ([string]$t.status -ne 'merged') { return $false }
    }
    return $true
}

function Get-StatusNextAction {
    param(
        [string]$Stage,
        $WaitingOn,
        $Feature,
        $TasksList,
        [bool]$IsDone
    )
    if ($IsDone) { return 'Nothing to do: the feature is done and merged into main.' }
    if ($null -ne $WaitingOn -and $WaitingOn.ContainsKey('stop')) {
        return 'Resolve the problem stop with the user, then record a resume decision.'
    }
    if ($null -ne $WaitingOn -and $WaitingOn.ContainsKey('running')) {
        return 'Wait for the running tasks to finish, then reconcile.'
    }
    $hasPhases = $null -ne $Feature.PSObject.Properties['phases'] -and $null -ne $Feature.phases -and @($Feature.phases).Count -gt 0
    switch ($Stage) {
        'design' { return 'Draft the next design section and get it approved.' }
        'design-review' {
            if ($null -eq $Feature.gates -or $null -eq $Feature.gates.PSObject.Properties['design-locked']) {
                return 'Run the review lenses, write the synthesis, then ask the user to lock the design.'
            }
            return 'Move to the plan stage.'
        }
        'plan' {
            if (-not $hasPhases) { return 'Write the plan and import it with plan.' }
            if ($null -eq $Feature.gates -or $null -eq $Feature.gates.PSObject.Properties['plan-approved']) {
                return 'Run the plan review, then ask the user to approve the plan.'
            }
            return 'Move to the build stage.'
        }
        'build' {
            if (Test-StatusAllTasksMerged $TasksList) {
                return 'Run the phase tests, then move to signoff.'
            }
            return 'Run the next ready tasks from schedule.'
        }
        'signoff' {
            if ($null -eq $Feature.gates -or $null -eq $Feature.gates.PSObject.Properties['signed-off']) {
                return 'Run the full tests and the drift check, then ask the user to sign off.'
            }
            return 'Run finish to merge into main.'
        }
        'abandoned' { return 'Nothing to do: the feature is abandoned.' }
        default { return 'Run the next ready tasks from schedule.' }
    }
}

function Get-StatusDiffTouchesRuleFiles {
    param([string]$Repository, [string]$FeatureName)
    & git -C $Repository show-ref --verify --quiet 'refs/heads/main' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    $paths = @(Invoke-GitRepo $Repository 'diff' '--name-only' "main...feature/$FeatureName")
    foreach ($p in $paths) {
        if ($p -match '(^|/)(AGENTS\.md|CLAUDE\.md|GEMINI\.md|\.cursorrules)$') { return $true }
        if ($p -match '(^|/)(\.cursor|\.agents)/') { return $true }
    }
    return $false
}

function Get-StatusTokens {
    param(
        [string]$FeatureName,
        [System.Collections.Generic.List[string]]$Warnings
    )
    $folder = if ($env:XAGENT_LOG_DIR) { $env:XAGENT_LOG_DIR } else { Join-Path $env:LOCALAPPDATA 'xagent' }
    try {
        $folder = [IO.Path]::GetFullPath($folder)
    }
    catch {
        $Warnings.Add("usage log not readable: $folder") | Out-Null
        return $null
    }
    if (-not (Test-Path -LiteralPath $folder)) {
        $Warnings.Add("usage log not readable: $folder") | Out-Null
        return $null
    }
    $file = Join-Path $folder 'runs.jsonl'
    if (-not (Test-Path -LiteralPath $file)) {
        return @{ input = 0; output = 0; reasoning = 0; cacheRead = 0; total = 0 }
    }
    [long]$inTok = 0
    [long]$outTok = 0
    [long]$reaTok = 0
    [long]$cacheTok = 0
    try {
        foreach ($line in [IO.File]::ReadAllLines($file, [Text.UTF8Encoding]::new($false))) {
            if (-not $line.Trim()) { continue }
            try {
                $obj = $line | ConvertFrom-Json
            }
            catch { continue }
            if ($null -eq $obj.PSObject.Properties['feature'] -or [string]$obj.feature -cne $FeatureName) { continue }
            if ($null -eq $obj.PSObject.Properties['usage'] -or $null -eq $obj.usage) { continue }
            $u = $obj.usage
            if ($null -ne $u.PSObject.Properties['input']) { $inTok += [long]$u.input }
            if ($null -ne $u.PSObject.Properties['output']) { $outTok += [long]$u.output }
            if ($null -ne $u.PSObject.Properties['reasoning']) { $reaTok += [long]$u.reasoning }
            if ($null -ne $u.PSObject.Properties['cacheRead']) { $cacheTok += [long]$u.cacheRead }
        }
    }
    catch {
        $Warnings.Add("usage log not readable: $folder") | Out-Null
        return $null
    }
    $total = $inTok + $outTok + $reaTok + $cacheTok
    return @{ input = $inTok; output = $outTok; reasoning = $reaTok; cacheRead = $cacheTok; total = $total }
}

function Invoke-StatusFeature {
    param([string]$Repository)
    $selected = Select-FeatureName $Repository
    if ($null -eq $selected) {
        $list = @(Get-FeatureList $Repository)
        $features = @($list | ForEach-Object { @{ name = $_.name; stage = [string]$_.stage } })
        Out-FeatureOk @{ selected = $null; features = $features }
        return
    }

    if ($Name) { Assert-FeatureExists $Repository $selected }
    else {
        & git -C $Repository show-ref --verify --quiet "refs/heads/feature/$selected" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "no feature $selected" }
    }

    $branchRef = "feature/$selected"
    $feat = Get-FeatureJsonFromRef $Repository $branchRef $selected
    if (-not $feat) { throw "no feature $selected" }
    $decPath = "docs/features/$selected/decisions.md"
    $decText = (Invoke-GitRepo $Repository 'show' "${branchRef}:$decPath") -join "`n"
    if (-not $decText.EndsWith("`n")) { $decText += "`n" }

    $effStage = Get-EffectiveStage $Repository $selected $feat
    $isDone = ($effStage -eq 'done')
    $storedStage = [string]$feat.stage
    $warnings = [System.Collections.Generic.List[string]]::new()

    if ($isDone) { $warnings.Add("feature $selected is done") | Out-Null }

    $stateObj = Get-FeatureStateObject -Repository $Repository -FeatureName $selected
    $tasksList = Get-StatusTasksList $Repository $selected $feat $stateObj $decText
    $waitingOn = if ($isDone) { $null } else { Get-StatusWaitingOn $feat $decText $tasksList $storedStage }
    $phaseInfo = Get-StatusPhaseInfo $feat (Get-StatusTaskStatusMap $Repository $selected $stateObj)
    $reviewRuns = if ($isDone) { ,@() } else { Get-StatusReviewRuns $Repository $selected $storedStage $decText }
    $tokens = Get-StatusTokens $selected $warnings
    $lastDecisions = Get-StatusLastDecisions $decText
    $nextAction = Get-StatusNextAction $storedStage $waitingOn $feat $tasksList $isDone
    $branchLines = @(Invoke-GitRepo $Repository 'branch' '--show-current')
    $currentBranch = ''
    if (@($branchLines).Count -gt 0 -and $branchLines[0]) { $currentBranch = [string]$branchLines[0] }

    $out = @{
        selected              = $selected
        stage                 = $storedStage
        phase                 = $phaseInfo
        checkin               = [string]$feat.checkin
        designDoc             = [string]$feat.designDoc
        branch                = [string]$currentBranch
        treeClean             = (Test-TreeClean $Repository)
        tasks                 = $tasksList
        waitingOn             = $waitingOn
        reviewRuns            = $reviewRuns
        diffTouchesRuleFiles  = (Get-StatusDiffTouchesRuleFiles $Repository $selected)
        tokens                = $tokens
        lastDecisions         = $lastDecisions
        nextAction            = $nextAction
        warnings              = [string[]]@($warnings)
        features              = @()
    }
    Out-FeatureOk $out
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

    $designInfo = Resolve-NewFeatureDesignDoc -Repository $Repository -FeatureName $Name -DesignDocInput $DesignDoc
    $designDoc = $designInfo.designDoc
    $designDocExists = $designInfo.designDocExists

    Enter-FeatureLock $Repository $Name
    try {
        Invoke-GitRepo $Repository 'switch' '-c' "feature/$Name" 'main' | Out-Null
        $featDir = Join-Path $Repository "docs/features/$Name"
        New-Item -ItemType Directory -Force $featDir | Out-Null
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
        Out-FeatureOk @{
            name            = $Name
            branch          = "feature/$Name"
            designDoc       = $designDoc
            designDocExists = $designDocExists
        }
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
            $body = if ($Reason) { "$from -> abandoned: $Reason" } else { "$from -> abandoned" }
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

        $body = if ($Reason) { "$from -> $To`: $Reason" } else { "$from -> $To" }
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
        $kind = if ($stage -eq 'design-review') { 'design' } else { 'plan' }
        $n = Get-ReviewNumber $Repository $FeatureName $kind
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
    # Only this feature's own task merges: first-parent history since 'feature(<name>): start'. A plain log
    # also reads earlier features' merges (ancestors through main) and tasks merged in with main.
    $range = $branch
    $startSubject = "feature($FeatureName): start"
    foreach ($ln in @(Invoke-GitRepo $Repository 'log' '--first-parent' '--format=%H %P%x09%s' $branch)) {
        $parts = ([string]$ln).Split("`t", 2)
        if ($parts.Count -eq 2 -and $parts[1] -ceq $startSubject) {
            $shas = $parts[0].Split(' ')
            if ($shas.Count -ge 2 -and $shas[1]) { $range = "$($shas[1])..$branch" }
            break
        }
    }
    $lines = @(Invoke-GitRepo $Repository 'log' '--first-parent' $range '--format=%(trailers:key=Xagent-Task,valueonly)')
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

function Get-HeadPhasesByN([object]$Feature) {
    $map = @{}
    if (-not $Feature.PSObject.Properties['phases'] -or $null -eq $Feature.phases) { return $null }
    foreach ($phase in @($Feature.phases)) {
        $map[[int]$phase.n] = $phase
    }
    return $map
}

function Get-PlanPhasesByN([object]$Plan) {
    $map = @{}
    foreach ($phase in @($Plan.phases)) {
        $map[[int]$phase.n] = $phase
    }
    return $map
}

function Test-HeadFileCoversNewFile([string]$OldKey, [string]$NewKey) {
    if ([string]$OldKey -ceq [string]$NewKey) { return $true }
    if ([string]$OldKey -ceq '') { return $true }
    if ([string]$NewKey -ceq '') { return $false }
    if ($OldKey.EndsWith('/')) {
        return $NewKey.StartsWith($OldKey, [StringComparison]::Ordinal)
    }
    return $false
}

function Get-PlanTaskEffectiveStatus {
    param(
        [string]$TaskId,
        [string[]]$MergedIds,
        [hashtable]$StateStatuses
    )
    if ($MergedIds -contains $TaskId) { return 'merged' }
    if ($StateStatuses.ContainsKey($TaskId)) { return [string]$StateStatuses[$TaskId] }
    return 'pending'
}

function Assert-BuildStagePlanRestrictions {
    param(
        [string]$Repository,
        [string]$FeatureName,
        [object]$HeadFeature,
        [object]$NewPlan
    )
    $headByN = Get-HeadPhasesByN $HeadFeature
    if ($null -eq $headByN -or $headByN.Count -eq 0) {
        throw 'in stage build, there is no plan to change'
    }

    $newByN = Get-PlanPhasesByN $NewPlan
    $headNums = @($headByN.Keys | Sort-Object)
    $newNums = @($newByN.Keys | Sort-Object)
    if ($headNums.Count -ne $newNums.Count) {
        throw 'in stage build, the phases must stay unchanged'
    }
    for ($i = 0; $i -lt $headNums.Count; $i++) {
        if ($headNums[$i] -ne $newNums[$i]) {
            throw 'in stage build, the phases must stay unchanged'
        }
    }
    foreach ($n in $headNums) {
        $hp = $headByN[$n]
        $np = $newByN[$n]
        if (-not ([string]$hp.rationale -ceq [string]$np.rationale) -or -not ([string]$hp.test -ceq [string]$np.test)) {
            throw "in stage build, phase $n must stay unchanged"
        }
    }

    $mergedIds = @(Get-XagentMergedTaskIds $Repository $FeatureName)
    $stateStatuses = Get-FeatureStateTaskStatuses $Repository $FeatureName
    $newById = Get-PlanTasksById $NewPlan
    $protected = @('merged', 'preflight', 'running', 'in-review')

    foreach ($n in $headNums) {
        foreach ($task in @($headByN[$n].tasks)) {
            $id = [string]$task.id
            $status = Get-PlanTaskEffectiveStatus -TaskId $id -MergedIds $mergedIds -StateStatuses $stateStatuses
            if ($protected -notcontains $status) { continue }
            if (-not $newById.ContainsKey($id)) {
                throw "task $id is $status and must stay unchanged"
            }
            $newEntry = $newById[$id]
            if ($newEntry.PhaseN -ne [int]$n) {
                throw "task $id is $status and must stay unchanged"
            }
            if (-not (Test-PlanTaskFieldsEqual $newEntry.Task $task)) {
                throw "task $id is $status and must stay unchanged"
            }
        }
    }

    foreach ($n in $headNums) {
        $headKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($task in @($headByN[$n].tasks)) {
            foreach ($entry in (Get-JsonPropertyStringArray $task 'files')) {
                $headKeys.Add((Get-OverlapKey ([string]$entry)))
            }
        }
        foreach ($task in @($newByN[$n].tasks)) {
            $id = [string]$task.id
            foreach ($entry in (Get-JsonPropertyStringArray $task 'files')) {
                $newKey = Get-OverlapKey ([string]$entry)
                $covered = $false
                foreach ($hk in $headKeys) {
                    if (Test-HeadFileCoversNewFile $hk $newKey) {
                        $covered = $true
                        break
                    }
                }
                if (-not $covered) {
                    throw "task $id file $entry is outside phase $n's declared files"
                }
            }
        }
    }
}

function Invoke-PlanFeature {
    param([string]$Repository, [string]$FeatureName)
    if (-not $PlanFile) { throw '-PlanFile is required' }

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $state = Get-HeadFeatureState $Repository $FeatureName
        $stage = [string]$state.Feature.stage
        if ($stage -ne 'plan' -and $stage -ne 'build') { throw 'plan is only allowed in stage plan or build' }

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
        if ($stage -eq 'build') {
            Assert-BuildStagePlanRestrictions -Repository $Repository -FeatureName $FeatureName -HeadFeature $state.Feature -NewPlan $planObj
        }

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
        Out-FeatureOk @{ name = $FeatureName; phases = @($phases).Count; tasks = $taskCount; stage = $stage }
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

function Get-PlanTasksInOrder {
    param([object]$Feature)
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not $Feature.PSObject.Properties['phases'] -or $null -eq $Feature.phases) { return @() }
    foreach ($phase in @($Feature.phases | Sort-Object { [int]$_.n })) {
        foreach ($task in @($phase.tasks)) {
            $result.Add($task) | Out-Null
        }
    }
    return @($result)
}

function Test-FeatureStateFileValid {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $raw = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    try {
        $null = $raw | ConvertFrom-Json
    } catch {
        return $false
    }
    return (Test-Json -Json $raw -SchemaFile $script:SchemaState -ErrorAction SilentlyContinue)
}

function Test-ProcessStartTimeMatch {
    param([int]$ProcessId, $StartTime)
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $expected = if ($StartTime -is [datetime]) {
            $StartTime.ToUniversalTime()
        } else {
            ([datetime]([string]$StartTime)).ToUniversalTime()
        }
        return ($proc.StartTime.ToUniversalTime() -eq $expected)
    } catch {
        return $false
    }
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    try {
        $p = [Diagnostics.Process]::GetProcessById($ProcessId)
    } catch [ArgumentException] {
        return
    }
    try {
        $p.Kill($true)
    } catch [InvalidOperationException] {
    }
    $null = $p.WaitForExit(10000)
}

function Get-DelegateRunDirs {
    param([string]$Repository, [string]$DelegateTaskId)
    $runsRoot = Join-Path $Repository '.xagent/runs'
    if (-not (Test-Path -LiteralPath $runsRoot)) { return [string[]]@() }
    $dirs = [System.Collections.Generic.List[string]]::new()
    $exact = Join-Path $runsRoot $DelegateTaskId
    if (Test-Path -LiteralPath $exact) { $dirs.Add($exact) | Out-Null }
    foreach ($suffix in @('-pc', '-pr')) {
        $p = Join-Path $runsRoot ($DelegateTaskId + $suffix)
        if (Test-Path -LiteralPath $p) { $dirs.Add($p) | Out-Null }
    }
    $esc = [regex]::Escape($DelegateTaskId)
    foreach ($child in Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue) {
        if ($child.Name -match "^$esc-c\d+$") {
            $dirs.Add($child.FullName) | Out-Null
        }
    }
    return [string[]]@($dirs)
}

function Get-DelegateRunPidFiles {
    param([string]$Repository, [string]$DelegateTaskId)
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($dir in (Get-DelegateRunDirs $Repository $DelegateTaskId)) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.pid' -File -ErrorAction SilentlyContinue) {
            $files.Add($f) | Out-Null
        }
    }
    return @($files)
}

function Get-NewestStdoutJsonPathInDirs {
    param([string[]]$Dirs)
    $bestStamp = $null
    $bestPath = $null
    foreach ($dir in $Dirs) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.stdout.json' -File -ErrorAction SilentlyContinue) {
            if ($f.Name -match '^(\d{8}-\d{6})-') {
                $stamp = $Matches[1]
                if ($null -eq $bestStamp -or $stamp -gt $bestStamp) {
                    $bestStamp = $stamp
                    $bestPath = $f.FullName
                }
            }
        }
    }
    return $bestPath
}

function Get-NewestStdoutJsonPath {
    param([string]$Repository, [string]$DelegateTaskId)
    return (Get-NewestStdoutJsonPathInDirs -Dirs (Get-DelegateRunDirs $Repository $DelegateTaskId))
}

function Test-TaskStateStringFieldEmpty {
    param([object]$Rec, [string]$Name)
    if ($Rec -is [System.Collections.IDictionary]) {
        if (-not $Rec.Contains($Name)) { return $true }
        $v = $Rec[$Name]
    } else {
        $p = $Rec.PSObject.Properties[$Name]
        if ($null -eq $p) { return $true }
        $v = $p.Value
    }
    if ($null -eq $v) { return $true }
    return ([string]$v).Length -eq 0
}

function Get-ReconcileDelegateWorktreePath {
    param([string]$Repository, [string]$DelegateTaskId)
    $repoName = Split-Path $Repository -Leaf
    $parent = Split-Path $Repository -Parent
    return (Join-Path (Join-Path $parent "$repoName.xagent") $DelegateTaskId)
}

function Get-ReconcileInReviewFields {
    param(
        [string]$Repository,
        [string]$DelegateTaskId,
        [object]$Rec,
        [string]$StdoutPath
    )
    $fields = @{}
    if ($StdoutPath -and (Test-Path -LiteralPath $StdoutPath)) {
        try {
            $raw = [IO.File]::ReadAllText($StdoutPath, [Text.UTF8Encoding]::new($false)).Trim()
            if ($raw.Length -gt 0) {
                $obj = $raw | ConvertFrom-Json
                if ($null -ne $obj.PSObject.Properties['session_id']) {
                    $sid = [string]$obj.session_id
                    if ($sid.Length -gt 0 -and (Test-TaskStateStringFieldEmpty $Rec 'sessionId')) {
                        $fields['sessionId'] = $sid
                    }
                }
            }
        } catch { }
    }
    if (-not (Test-TaskStateStringFieldEmpty $Rec 'worktree')) {
        return $fields
    }
    $wt = Get-ReconcileDelegateWorktreePath -Repository $Repository -DelegateTaskId $DelegateTaskId
    if (-not (Test-Path -LiteralPath $wt)) {
        return $fields
    }
    $fields['worktree'] = $wt.Replace('\', '/')
    $basePath = Join-Path $wt '.xagent/base.sha'
    if ((Test-TaskStateStringFieldEmpty $Rec 'baseSha') -and (Test-Path -LiteralPath $basePath)) {
        $sha = [IO.File]::ReadAllText($basePath, [Text.UTF8Encoding]::new($false)).Trim()
        if ($sha -match '^[0-9a-f]{40}$') {
            $fields['baseSha'] = $sha
        }
    }
    $resultPath = Join-Path $wt '.xagent/result.json'
    if ((Test-TaskStateStringFieldEmpty $Rec 'resultFile') -and (Test-Path -LiteralPath $resultPath)) {
        $fields['resultFile'] = $resultPath.Replace('\', '/')
    }
    return $fields
}

function Test-StdoutJsonFinished {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $raw = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)).Trim()
    return ($raw.Length -gt 0)
}

function Update-ReconcileInFlightTask {
    param(
        [string]$Repository,
        [string]$DelegateTaskId,
        [object]$Rec
    )
    $taskStatus = if ($Rec -is [System.Collections.IDictionary]) { [string]$Rec['status'] } else { [string]$Rec.status }
    $pidFiles = Get-DelegateRunPidFiles -Repository $Repository -DelegateTaskId $DelegateTaskId
    foreach ($pf in $pidFiles) {
        $obj = $null
        try {
            $raw = [IO.File]::ReadAllText($pf.FullName, [Text.UTF8Encoding]::new($false))
            $obj = $raw | ConvertFrom-Json
        } catch { continue }
        if ($null -eq $obj.PSObject.Properties['pid'] -or $null -eq $obj.PSObject.Properties['startTime']) { continue }
        if (Test-ProcessStartTimeMatch -ProcessId ([int]$obj.pid) -StartTime $obj.startTime) {
            return @{ changed = $false; becameFailed = $false; incrementFailures = $false }
        }
    }
    $orphanKilled = $false
    foreach ($pf in $pidFiles) {
        $obj = $null
        try {
            $raw = [IO.File]::ReadAllText($pf.FullName, [Text.UTF8Encoding]::new($false))
            $obj = $raw | ConvertFrom-Json
        } catch { continue }
        if ($null -eq $obj.PSObject.Properties['childPid'] -or $null -eq $obj.PSObject.Properties['childStartTime']) { continue }
        $childPid = [int]$obj.childPid
        if (-not (Test-ProcessStartTimeMatch -ProcessId $childPid -StartTime $obj.childStartTime)) { continue }
        $parentLive = $false
        if ($null -ne $obj.PSObject.Properties['pid'] -and $null -ne $obj.PSObject.Properties['startTime']) {
            $parentLive = (Test-ProcessStartTimeMatch -ProcessId ([int]$obj.pid) -StartTime $obj.startTime)
        }
        if ($parentLive) { continue }
        Stop-ProcessTree -ProcessId $childPid
        $orphanKilled = $true
    }
    $runsRoot = Join-Path $Repository '.xagent/runs'
    if ($taskStatus -ceq 'preflight') {
        $preflightDirs = @(
            (Join-Path $runsRoot ($DelegateTaskId + '-pc')),
            (Join-Path $runsRoot ($DelegateTaskId + '-pr'))
        )
        $stdoutPath = Get-NewestStdoutJsonPathInDirs -Dirs $preflightDirs
        if (-not $orphanKilled -and (Test-StdoutJsonFinished $stdoutPath)) {
            return @{ changed = $true; newStatus = 'pending'; becameFailed = $false; incrementFailures = $false }
        }
        return @{ changed = $true; newStatus = 'failed'; becameFailed = $true; incrementFailures = $true }
    }
    $workerDir = Join-Path $runsRoot $DelegateTaskId
    $stdoutPath = Get-NewestStdoutJsonPathInDirs -Dirs @($workerDir)
    if (-not $orphanKilled -and (Test-StdoutJsonFinished $stdoutPath)) {
        $fields = Get-ReconcileInReviewFields -Repository $Repository -DelegateTaskId $DelegateTaskId -Rec $Rec -StdoutPath $stdoutPath
        return @{
            changed           = $true
            newStatus         = 'in-review'
            becameFailed      = $false
            incrementFailures = $false
            fields            = $fields
        }
    }
    return @{ changed = $true; newStatus = 'failed'; becameFailed = $true; incrementFailures = $true }
}

function Invoke-ReconcileFeature {
    param([string]$Repository, [string]$FeatureName)
    $branch = "feature/$FeatureName"
    $statePath = Join-Path $Repository ".xagent/features/$FeatureName/state.json"
    & git -C $Repository show-ref --verify --quiet "refs/heads/$branch" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $statePath) {
            Enter-FeatureLock $Repository $FeatureName
            try {
                Out-FeatureOk @{
                    name           = $FeatureName
                    changes        = @()
                    contradictions = @(@{ kind = 'branch-missing'; message = "branch $branch is missing" })
                    lost           = @()
                }
            } finally {
                Exit-FeatureLock
            }
            return
        }
        throw "no feature $FeatureName"
    }

    $feat = Get-FeatureJsonFromRef $Repository $branch $FeatureName
    if (-not $feat) { throw "no feature $FeatureName" }

    $stateMissing = -not (Test-Path -LiteralPath $statePath)
    if (-not $stateMissing) {
        if (-not (Test-FeatureStateFileValid $statePath)) {
            throw 'state.json is not valid; fix it, or delete it so reconcile rebuilds it'
        }
    }

    $decPath = "docs/features/$FeatureName/decisions.md"
    $decText = try {
        (Invoke-GitRepo $Repository 'show' "${branch}:$decPath") -join "`n"
    } catch {
        throw "no feature $FeatureName"
    }
    if (-not $decText.EndsWith("`n")) { $decText += "`n" }

    Enter-FeatureLock $Repository $FeatureName
    try {
        $contradictions = [System.Collections.Generic.List[hashtable]]::new()
        $changes = [System.Collections.Generic.List[hashtable]]::new()
        $lost = [string[]]@()
        $newFailedTasks = [System.Collections.Generic.List[string]]::new()

        $effStage = Get-EffectiveStage $Repository $FeatureName $feat
        $currentBranch = @(Invoke-GitRepo $Repository 'branch' '--show-current')[0]
        if ($effStage -ne 'done' -and $effStage -ne 'abandoned' -and $currentBranch -cne $branch) {
            $cur = if ([string]::IsNullOrEmpty($currentBranch)) { 'detached HEAD' } else { $currentBranch }
            $contradictions.Add(@{
                    kind    = 'wrong-branch'
                    message = "check out $branch to continue; $cur is checked out"
                }) | Out-Null
        }

        if ($currentBranch -ceq 'main') {
            & git -C $Repository rev-parse -q --verify MERGE_HEAD 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $contradictions.Add(@{
                        kind    = 'merge-in-progress'
                        message = 'a merge into main is in progress; finish or abort it'
                    }) | Out-Null
            }
        }

        if (Test-MergeBaseIsAncestor $Repository $branch 'main') {
            $hasSignoff = $false
            if ($feat.PSObject.Properties['gates'] -and $null -ne $feat.gates) {
                $hasSignoff = $null -ne $feat.gates.PSObject.Properties['signed-off']
            }
            if (-not $hasSignoff) {
                $contradictions.Add(@{
                        kind    = 'merged-without-signoff'
                        message = "$branch is merged into main but signed-off is not recorded"
                    }) | Out-Null
            }
        }

        $state = Get-FeatureStateObject -Repository $Repository -FeatureName $FeatureName
        $trailerMerged = @(Get-XagentMergedTaskIds -Repository $Repository -FeatureName $FeatureName)

        if ($stateMissing) {
            $lostList = [System.Collections.Generic.List[string]]::new()
            foreach ($task in (Get-PlanTasksInOrder $feat)) {
                $tid = [string]$task.id
                $state.tasks[$tid] = New-DefaultTaskStateRecord
                if ($trailerMerged -notcontains $tid) {
                    $lostList.Add($tid) | Out-Null
                }
            }
            $lost = [string[]]@($lostList)
        }

        foreach ($task in (Get-PlanTasksInOrder $feat)) {
            $tid = [string]$task.id
            $delegateId = [string]$task.delegateTaskId
            $hadRecord = $state.tasks.ContainsKey($tid)
            $rec = if ($hadRecord) { Copy-TaskStateRecord $state.tasks[$tid] } else { New-DefaultTaskStateRecord }
            $fromStatus = [string]$rec.status
            if (-not $hadRecord) { $fromStatus = 'pending' }

            if ($trailerMerged -contains $tid) {
                if ([string]$rec.status -cne 'merged') {
                    $rec.status = 'merged'
                    $changes.Add(@{ task = $tid; from = $fromStatus; to = 'merged' }) | Out-Null
                }
                $state.tasks[$tid] = $rec
                continue
            }

            if ([string]$rec.status -ceq 'merged') {
                $contradictions.Add(@{
                        kind    = 'merged-without-trailer'
                        message = "task $tid is merged in state.json but has no Xagent-Task merge"
                    }) | Out-Null
                $state.tasks[$tid] = $rec
                continue
            }

            if ([string]$rec.status -cin @('preflight', 'running')) {
                $flight = Update-ReconcileInFlightTask -Repository $Repository -DelegateTaskId $delegateId -Rec $rec
                if (-not $flight.changed) {
                    $state.tasks[$tid] = $rec
                    continue
                }
                $newSt = [string]$flight.newStatus
                $rec.status = $newSt
                if ($flight.incrementFailures) {
                    $rec.failures = [int]$rec.failures + 1
                }
                if ($flight.becameFailed) {
                    $newFailedTasks.Add($tid) | Out-Null
                }
                if ($flight -is [System.Collections.IDictionary] -and $flight.Contains('fields')) {
                    $flightFields = $flight['fields']
                    if ($null -ne $flightFields -and $flightFields -is [hashtable] -and $flightFields.Count -gt 0) {
                        foreach ($fk in $flightFields.Keys) {
                            $cur = $rec[$fk]
                            if ($null -eq $cur -or ([string]$cur).Length -eq 0) {
                                $rec[$fk] = $flightFields[$fk]
                            }
                        }
                    }
                }
                if ($newSt -cne $fromStatus) {
                    $changes.Add(@{ task = $tid; from = $fromStatus; to = $newSt }) | Out-Null
                }
                $state.tasks[$tid] = $rec
                continue
            }

            if ($hadRecord) {
                $state.tasks[$tid] = $rec
            }
        }

        $state.lastReconcile = Get-UtcDecisionTime
        Write-FeatureStateObject -Repository $Repository -FeatureName $FeatureName -State $state

        $stopTasks = @($newFailedTasks | Where-Object {
                $state.tasks[$_].failures -ge 2
            })
        if ($stopTasks.Count -gt 0 -and -not (Test-StopOpen $decText)) {
            $onFeature = ($currentBranch -ceq $branch)
            if ($onFeature) {
                $decFile = Join-Path $Repository $decPath
                $decDir = Split-Path $decFile -Parent
                if (-not (Test-Path -LiteralPath $decDir)) {
                    New-Item -ItemType Directory -Force $decDir | Out-Null
                }
                if (-not (Test-Path -LiteralPath $decFile)) {
                    $tpl = [IO.File]::ReadAllText($script:TemplateDecisions, [Text.UTF8Encoding]::new($false))
                    $tpl = $tpl -replace '<name>', $FeatureName
                    Write-TextLf $decFile $tpl
                }
                $planOrder = @(Get-PlanTasksInOrder $feat | ForEach-Object { [string]$_.id })
                $orderedStop = @($stopTasks | Sort-Object { $planOrder.IndexOf($_) })
                foreach ($sid in $orderedStop) {
                    $line = Format-DecisionLine -Kind 'stop' -Body "${sid}: failed twice"
                    Append-TextLf $decFile $line
                }
                $null = Invoke-FeatureCommit $Repository "feature($FeatureName): stop" @("docs/features/$FeatureName")
            }
            else {
                foreach ($sid in $stopTasks) {
                    $contradictions.Add(@{
                            kind    = 'stop-not-recorded'
                            message = "task $sid failed twice; check out $branch and run reconcile again to record the stop"
                        }) | Out-Null
                }
            }
        }

        Out-FeatureOk @{
            name           = $FeatureName
            changes        = @($changes)
            contradictions = @($contradictions)
            lost           = @($lost)
        }
    } finally {
        Exit-FeatureLock
    }
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

function Test-CachePath([string]$Path) {
    $norm = ([string]$Path) -replace '\\', '/'
    $segments = $norm -split '/'
    $cacheSegs = @('__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache')
    foreach ($seg in $segments) {
        if ($cacheSegs -ccontains $seg) { return $true }
    }
    $leaf = $segments[$segments.Count - 1]
    if ($leaf.EndsWith('.pyc', [StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-IgnoredCachePaths {
    param([string]$WorktreePath)
    $gitBase = @('-c', 'core.quotepath=off', '-C', $WorktreePath)
    $untracked = @(& git @gitBase 'ls-files' '--others' '--exclude-standard' 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files --others failed' }
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($p in @($untracked)) {
        $line = ([string]$p).Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('.xagent/', [StringComparison]::Ordinal)) { continue }
        if (-not (Test-CachePath $line)) { continue }
        [void]$set.Add($line)
    }
    $arr = [string[]]::new($set.Count)
    $set.CopyTo($arr)
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return ,[string[]]$arr
}

function Get-ChangedPaths {
    param([string]$WorktreePath, [string]$BaseSha)
    $gitBase = @('-c', 'core.quotepath=off', '-C', $WorktreePath)
    $diffOut = @(& git @gitBase 'diff' '--name-only' $BaseSha 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "git diff --name-only $BaseSha failed" }
    $untracked = @(& git @gitBase 'ls-files' '--others' '--exclude-standard' 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files --others failed' }
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($p in @($diffOut)) {
        $line = ([string]$p).Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('.xagent/', [StringComparison]::Ordinal)) { continue }
        [void]$set.Add($line)
    }
    foreach ($p in @($untracked)) {
        $line = ([string]$p).Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('.xagent/', [StringComparison]::Ordinal)) { continue }
        if (Test-CachePath $line) { continue }
        [void]$set.Add($line)
    }
    $arr = [string[]]::new($set.Count)
    $set.CopyTo($arr)
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return ,[string[]]$arr
}

function Test-MergeBlockingPorcelainLine([string]$Line) {
    $line = ([string]$Line).TrimEnd("`r")
    if (-not $line) { return $false }
    if ($line.StartsWith('?? ')) {
        $path = $line.Substring(3).Trim()
        if ($path.StartsWith('"') -and $path.EndsWith('"')) {
            $path = $path.Substring(1, $path.Length - 2)
        }
        $path = $path -replace '\\', '/'
        if (Test-CachePath $path) { return $false }
    }
    return $true
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
            Stop-ProcessTree -ProcessId $proc.Id
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

    $ignoredCaches = Get-IgnoredCachePaths -WorktreePath $wt
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
        at            = Get-UtcDecisionTime
        inScope       = $inScope
        changed       = [string[]]@($changed)
        outOfScope    = [string[]]@($outArr)
        ignoredCaches = [string[]]@($ignoredCaches)
        test          = $testResult
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
        name          = $FeatureName
        task          = $Task
        inScope       = $inScope
        changed       = [string[]]@($changed)
        outOfScope    = [string[]]@($outArr)
        ignoredCaches = [string[]]@($ignoredCaches)
        test          = $testResult
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
                $porcelain = @(& git '-c' 'core.quotepath=off' '-C' $wt 'status' '--porcelain' '--untracked-files=all' 2>&1)
                if ($LASTEXITCODE -ne 0) { throw "git status in worktree: $($porcelain -join "`n")" }
                $blocking = @($porcelain | Where-Object { $_ -and (Test-MergeBlockingPorcelainLine $_) })
                if ($blocking.Count -gt 0) {
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

function Out-DoctorResult([hashtable]$h) {
    if (-not $h.ContainsKey('ok')) { $h['ok'] = $true }
    $h | ConvertTo-Json -Compress -Depth 10
    exit 0
}

function Invoke-DoctorCommand {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSec = 30
    )
    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $finished = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $finished) {
            Stop-ProcessTree -ProcessId $proc.Id
            return @{ exitCode = -1; output = ''; timedOut = $true }
        }
        $stdout = [IO.File]::ReadAllText($stdoutFile, [Text.UTF8Encoding]::new($false))
        $stderr = [IO.File]::ReadAllText($stderrFile, [Text.UTF8Encoding]::new($false))
        $output = $stdout + $stderr
        return @{ exitCode = $proc.ExitCode; output = $output; timedOut = $false }
    } finally {
        if (Test-Path -LiteralPath $stdoutFile) { Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $stderrFile) { Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue }
    }
}

function Get-DoctorRequiredModelNames {
    param([string]$ModelsJsonPath)
    $text = [IO.File]::ReadAllText($ModelsJsonPath, [Text.UTF8Encoding]::new($false))
    $root = $text | ConvertFrom-Json
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($pProp in $root.profiles.PSObject.Properties) {
        $pVal = $pProp.Value
        $mProp = $pVal.PSObject.Properties['model']
        if ($null -ne $mProp) {
            $null = $names.Add([string]$mProp.Value)
        }
        $seatsProp = $pVal.PSObject.Properties['seats']
        if ($null -ne $seatsProp) {
            foreach ($sProp in $seatsProp.Value.PSObject.Properties) {
                $null = $names.Add([string]$sProp.Value)
            }
        }
    }
    $rd = $root.seats.PSObject.Properties['readiness']
    if ($null -ne $rd) { $null = $names.Add([string]$rd.Value) }
    $jud = $root.seats.PSObject.Properties['judgement']
    if ($null -ne $jud) {
        foreach ($jm in @($jud.Value)) { $null = $names.Add([string]$jm) }
    }
    return @($names | Sort-Object)
}

function Get-DoctorPermissionRules {
    $featureSkillDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $delegateSkillDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../delegate'))
    $featScript = ($featureSkillDir -replace '\\', '/') + '/scripts/feature.ps1'
    $delScript = ($delegateSkillDir -replace '\\', '/') + '/scripts/delegate.ps1'
    return @(
        "Bash(pwsh -NoProfile -File $featScript *)"
        "Bash(pwsh -NoProfile -File $delScript *)"
    )
}

function Get-DoctorSandboxDetail($Support) {
    $parts = [System.Collections.Generic.List[string]]::new()
    $problems = @($Support.problems)
    if ($null -eq $Support.cursorVersion) {
        $problems = @($problems | Where-Object { $_ -notlike 'Cursor CLI not found at *' })
    }
    if ($problems.Count -gt 0) {
        $parts.Add('problems: ' + ($problems -join ' | '))
    }
    $parts.Add("build $($Support.build)")
    if ($null -eq $Support.cursorVersion) {
        $parts.Add('cursor not found')
    } else {
        $parts.Add("cursor $($Support.cursorVersion)")
    }
    if ($Support.uv) {
        $parts.Add("uv $($Support.uv)")
    }
    if ($null -ne $Support.patternCount) {
        $parts.Add("pattern $($Support.patternCount)")
    }
    $letters = $Support.letters
    if (-not $letters.reserved) {
        $parts.Add('letters not reserved (run delegate.ps1 -SandboxCheck -Reserve with three free letters)')
    } else {
        $runtimeRaw = $letters.runtime
        $slot0Raw = if ($letters.slots -and $letters.slots.Length -gt 0) { $letters.slots[0] } else { $null }
        $slot1Raw = if ($letters.slots -and $letters.slots.Length -gt 1) { $letters.slots[1] } else { $null }
        $runtime = if ([string]::IsNullOrEmpty($runtimeRaw)) { '-' } else { [string]$runtimeRaw.ToUpper() }
        $slot0 = if ([string]::IsNullOrEmpty($slot0Raw)) { '-' } else { [string]$slot0Raw.ToUpper() }
        $slot1 = if ([string]::IsNullOrEmpty($slot1Raw)) { '-' } else { [string]$slot1Raw.ToUpper() }
        $states = $letters.states
        if ($null -eq $states) { $states = @{} }
        function Get-SandboxDoctorLetterState([string]$Raw, [hashtable]$StateMap) {
            if ([string]::IsNullOrEmpty($Raw)) { return '?' }
            if ($StateMap.ContainsKey($Raw)) { return $StateMap[$Raw] }
            return '?'
        }
        $stateText = @(
            "$runtime=$(Get-SandboxDoctorLetterState $runtimeRaw $states)",
            "$slot0=$(Get-SandboxDoctorLetterState $slot0Raw $states)",
            "$slot1=$(Get-SandboxDoctorLetterState $slot1Raw $states)"
        ) -join ', '
        $parts.Add("letters $runtime,$slot0,$slot1 ($stateText)")
    }
    $detail = $parts -join '; '
    if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
    return $detail
}

function Invoke-DoctorFeature {
    $checks = [System.Collections.Generic.List[object]]::new()
    $permissionRules = @()
    try {
        $permissionRules = @(Get-DoctorPermissionRules)

        # powershell
        try {
            $ver = $PSVersionTable.PSVersion
            $psOk = ($ver.Major -gt 7) -or ($ver.Major -eq 7 -and $ver.Minor -ge 4)
            $detail = if ($psOk) { [string]$ver } else { 'need PowerShell 7.4 or later' }
            $checks.Add(@{ name = 'powershell'; ok = $psOk; required = $true; detail = $detail }) | Out-Null
        } catch {
            $checks.Add(@{ name = 'powershell'; ok = $false; required = $true; detail = $_.Exception.Message }) | Out-Null
        }

        # git
        try {
            $gitExe = (Get-Command git -ErrorAction Stop).Source
            $r = Invoke-DoctorCommand -FilePath $gitExe -ArgumentList @('--version')
            if ($r.timedOut) {
                $checks.Add(@{ name = 'git'; ok = $false; required = $true; detail = 'timed out after 30 s' }) | Out-Null
            } elseif ($r.exitCode -ne 0) {
                $checks.Add(@{ name = 'git'; ok = $false; required = $true; detail = $r.output.Trim() }) | Out-Null
            } else {
                $checks.Add(@{ name = 'git'; ok = $true; required = $true; detail = ($r.output -replace "`r`n", ' ').Trim() }) | Out-Null
            }
        } catch {
            $checks.Add(@{ name = 'git'; ok = $false; required = $true; detail = 'git not found' }) | Out-Null
        }

        # delegate
        $delegateOk = $false
        try {
            $delegateDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../delegate'))
            $modelsPath = Join-Path $delegateDir 'models.json'
            $delegateScript = Join-Path $delegateDir 'scripts/delegate.ps1'
            if ((Test-Path -LiteralPath $modelsPath) -and (Test-Path -LiteralPath $delegateScript)) {
                $delegateOk = $true
                $checks.Add(@{ name = 'delegate'; ok = $true; required = $true; detail = $delegateDir }) | Out-Null
            } else {
                $checks.Add(@{ name = 'delegate'; ok = $false; required = $true; detail = "missing delegate files at $modelsPath" }) | Out-Null
            }
        } catch {
            $checks.Add(@{ name = 'delegate'; ok = $false; required = $true; detail = $_.Exception.Message }) | Out-Null
        }

        # cursor-cli
        $launcher = Join-Path $env:LOCALAPPDATA 'cursor-agent\cursor-agent.ps1'
        $cursorCliOk = $false
        try {
            if (Test-Path -LiteralPath $launcher) {
                $cursorCliOk = $true
                $checks.Add(@{ name = 'cursor-cli'; ok = $true; required = $true; detail = $launcher }) | Out-Null
            } else {
                $checks.Add(@{ name = 'cursor-cli'; ok = $false; required = $true; detail = "missing at $launcher" }) | Out-Null
            }
        } catch {
            $checks.Add(@{ name = 'cursor-cli'; ok = $false; required = $true; detail = $_.Exception.Message }) | Out-Null
        }

        # cursor-login
        $loginOk = $false
        try {
            if (-not $cursorCliOk) {
                $checks.Add(@{ name = 'cursor-login'; ok = $false; required = $true; detail = 'cursor CLI missing' }) | Out-Null
            } else {
                $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher, 'status')
                $r = Invoke-DoctorCommand -FilePath $exe -ArgumentList $args
                if ($r.timedOut) {
                    $checks.Add(@{ name = 'cursor-login'; ok = $false; required = $true; detail = 'timed out after 30 s' }) | Out-Null
                } elseif ($r.output -match 'Logged in') {
                    $loginOk = $true
                    $checks.Add(@{ name = 'cursor-login'; ok = $true; required = $true; detail = 'logged in' }) | Out-Null
                } else {
                    $checks.Add(@{ name = 'cursor-login'; ok = $false; required = $true; detail = 'not logged in: run agent login' }) | Out-Null
                }
            }
        } catch {
            $checks.Add(@{ name = 'cursor-login'; ok = $false; required = $true; detail = $_.Exception.Message }) | Out-Null
        }

        # models
        try {
            if (-not $cursorCliOk) {
                $checks.Add(@{ name = 'models'; ok = $false; required = $true; detail = 'cursor CLI missing' }) | Out-Null
            } elseif (-not $delegateOk) {
                $checks.Add(@{ name = 'models'; ok = $false; required = $true; detail = 'models.json missing' }) | Out-Null
            } elseif (-not $loginOk) {
                $checks.Add(@{ name = 'models'; ok = $false; required = $true; detail = 'not logged in' }) | Out-Null
            } else {
                $delegateDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../delegate'))
                $modelsPath = Join-Path $delegateDir 'models.json'
                $required = @(Get-DoctorRequiredModelNames $modelsPath)
                $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher, '--list-models')
                $r = Invoke-DoctorCommand -FilePath $exe -ArgumentList $args
                if ($r.timedOut) {
                    $checks.Add(@{ name = 'models'; ok = $false; required = $true; detail = 'timed out after 30 s' }) | Out-Null
                } else {
                    $lineFirstWords = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    foreach ($line in ($r.output -split "`n")) {
                        $t = $line.Trim()
                        if (-not $t) { continue }
                        $fw = ($t -split '\s+', 2)[0]
                        if ($fw) { $null = $lineFirstWords.Add($fw) }
                    }
                    $missing = @($required | Where-Object { -not $lineFirstWords.Contains($_) })
                    if ($missing.Count -eq 0) {
                        $checks.Add(@{ name = 'models'; ok = $true; required = $true; detail = "all $($required.Count) models available" }) | Out-Null
                    } else {
                        $checks.Add(@{ name = 'models'; ok = $false; required = $true; detail = ('missing: ' + ($missing -join ', ')) }) | Out-Null
                    }
                }
            }
        } catch {
            $checks.Add(@{ name = 'models'; ok = $false; required = $true; detail = $_.Exception.Message }) | Out-Null
        }

        # pester
        try {
            $mod = Get-Module -ListAvailable Pester | Sort-Object { $_.Version } -Descending | Select-Object -First 1
            $pestOk = $false
            $detail = 'Pester 5.5 or later not installed'
            if ($mod) {
                $v = $mod.Version
                $pestOk = ($v.Major -gt 5) -or ($v.Major -eq 5 -and $v.Minor -ge 5)
                $detail = if ($pestOk) { "$($v.Major).$($v.Minor).$($v.Build)" } else { 'need Pester 5.5 or later' }
            }
            $checks.Add(@{ name = 'pester'; ok = $pestOk; required = $false; detail = $detail }) | Out-Null
        } catch {
            $checks.Add(@{ name = 'pester'; ok = $false; required = $false; detail = $_.Exception.Message }) | Out-Null
        }

        # python
        try {
            $pyOk = $false
            $detail = 'python not found'
            foreach ($cmd in @('python', 'py')) {
                try {
                    $pyExe = (Get-Command $cmd -ErrorAction Stop).Source
                    $r = Invoke-DoctorCommand -FilePath $pyExe -ArgumentList @('--version')
                    if (-not $r.timedOut -and $r.exitCode -eq 0) {
                        $pyOk = $true
                        $detail = ($r.output -replace "`r`n", ' ').Trim()
                        break
                    }
                } catch { }
            }
            $checks.Add(@{ name = 'python'; ok = $pyOk; required = $false; detail = $detail }) | Out-Null
        } catch {
            $checks.Add(@{ name = 'python'; ok = $false; required = $false; detail = $_.Exception.Message }) | Out-Null
        }

        # log-dir
        try {
            $logDir = if ($env:XAGENT_LOG_DIR) { $env:XAGENT_LOG_DIR } else { Join-Path $env:LOCALAPPDATA 'xagent' }
            if (-not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            }
            $tmp = Join-Path $logDir (".doctor-write-{0}.tmp" -f [guid]::NewGuid())
            [IO.File]::WriteAllText($tmp, 'ok', [Text.UTF8Encoding]::new($false))
            Remove-Item -LiteralPath $tmp -Force
            $checks.Add(@{ name = 'log-dir'; ok = $true; required = $true; detail = $logDir }) | Out-Null
        } catch {
            $checks.Add(@{ name = 'log-dir'; ok = $false; required = $true; detail = $_.Exception.Message }) | Out-Null
        }

        # sandbox
        try {
            $sandboxModule = Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../delegate'))) 'scripts/Sandbox.psm1'
            $null = Import-Module $sandboxModule -Force -ErrorAction Stop -WarningAction SilentlyContinue
            $support = Test-SandboxSupport
            $sandboxOk = $support.ok -and $support.letters.reserved
            $sandboxDetail = Get-DoctorSandboxDetail $support
            $checks.Add(@{ name = 'sandbox'; ok = $sandboxOk; required = $false; detail = $sandboxDetail }) | Out-Null
        } catch {
            $sandboxDetail = 'sandbox: ' + $_.Exception.Message
            if ($sandboxDetail.Length -gt 300) { $sandboxDetail = $sandboxDetail.Substring(0, 300) }
            $checks.Add(@{ name = 'sandbox'; ok = $false; required = $false; detail = $sandboxDetail }) | Out-Null
        }

        $ready = $true
        foreach ($c in $checks) {
            if ($c.required -and -not $c.ok) { $ready = $false; break }
        }
        Out-DoctorResult @{
            ready             = $ready
            checks            = @($checks.ToArray())
            permissionRules   = @($permissionRules)
        }
    } catch {
        $checks.Add(@{ name = 'doctor'; ok = $false; required = $true; detail = $_.Exception.Message }) | Out-Null
        Out-DoctorResult @{
            ok                = $false
            ready             = $false
            checks            = @($checks.ToArray())
            permissionRules   = @()
        }
    }
}

function Invoke-FinishFeature {
    param([string]$Repository, [string]$FeatureName)

    Enter-FeatureLock $Repository $FeatureName
    try {
        Assert-OnFeatureBranch $Repository $FeatureName
        $state = Get-HeadFeatureState $Repository $FeatureName
        $feat = $state.Feature

        if (-not $feat.gates.PSObject.Properties['signed-off']) {
            throw 'signed-off is not recorded'
        }
        if (-not (Test-TreeClean $Repository)) {
            throw 'working tree is not clean'
        }
        & git -C $Repository show-ref --verify --quiet 'refs/heads/main' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'no main branch'
        }

        $signSha = [string]$feat.gates.'signed-off'.sha
        $featPrefix = "docs/features/$FeatureName/"
        $diffPaths = @(Invoke-GitRepo $Repository 'diff' '--name-only' $signSha 'HEAD')
        $badPaths = @($diffPaths | Where-Object {
                $p = [string]$_
                -not $p.StartsWith($featPrefix, [StringComparison]::Ordinal)
            })
        if ($badPaths.Count -gt 0) {
            throw ('changed since sign-off: ' + ($badPaths -join ', '))
        }

        $doc = [string]$feat.designDoc
        $dlProp = $feat.gates.PSObject.Properties['design-locked']
        $expectedBlob = $null
        if ($null -ne $dlProp) {
            $blobProp = $dlProp.Value.PSObject.Properties['designBlob']
            if ($null -ne $blobProp) { $expectedBlob = [string]$blobProp.Value }
        }
        $currentBlob = $null
        try {
            $currentBlob = @(Invoke-GitRepo $Repository 'rev-parse' "HEAD:$doc")[0]
        } catch {
            $currentBlob = $null
        }
        if ($null -eq $expectedBlob -or $null -eq $currentBlob -or $currentBlob -cne $expectedBlob) {
            throw 'design changed since design-locked'
        }

        Invoke-GitRepo $Repository 'switch' 'main' | Out-Null
        $featureBranch = "feature/$FeatureName"
        $mergeMsg = "feature($FeatureName): finish"
        $out = & git -C $Repository merge --no-ff -m $mergeMsg $featureBranch 2>&1
        if ($LASTEXITCODE -ne 0) {
            $conflictFiles = @()
            try {
                $conflictFiles = @(Invoke-GitRepo $Repository 'diff' '--name-only' '--diff-filter=U')
            } catch { }

            if ($conflictFiles.Count -gt 0) {
                $filesJoin = $conflictFiles -join ', '
                Invoke-GitRepo $Repository 'merge' '--abort' | Out-Null
                Invoke-GitRepo $Repository 'switch' $featureBranch | Out-Null
                $state2 = Get-HeadFeatureState $Repository $FeatureName
                $feat2 = $state2.Feature
                Remove-GateKeys $feat2 @('signed-off')
                Write-FeatureJsonFile $state2.FeatPath $feat2
                $decLine = Format-DecisionLine -Kind 'decision' -Body "finish: merge conflict in $filesJoin; signed-off cleared"
                Append-TextLf $state2.DecPath $decLine.TrimEnd("`n")
                $rel = "docs/features/$FeatureName"
                $null = Invoke-FeatureCommit $Repository "feature($FeatureName): signed-off cleared" @($rel)
                throw "merge conflict in $filesJoin; signed-off cleared, sign off again after resolving"
            }

            & git -C $Repository rev-parse -q --verify MERGE_HEAD 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                try { Invoke-GitRepo $Repository 'merge' '--abort' | Out-Null } catch { }
            }
            try { Invoke-GitRepo $Repository 'switch' $featureBranch | Out-Null } catch { }
            $msg = ($out | Out-String).Trim()
            throw "git merge failed: $msg"
        }

        $mergeSha = @(Invoke-GitRepo $Repository 'rev-parse' 'HEAD')[0]
        Out-FeatureOk @{ name = $FeatureName; mergeSha = $mergeSha }
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
    if ($Subcommand -eq 'doctor') {
        Invoke-DoctorFeature
        return
    }

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
        'status' {
            Invoke-StatusFeature $repoRoot
        }
        'reconcile' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-ReconcileFeature $repoRoot $fname
        }
        'finish' {
            $fname = Resolve-FeatureName $repoRoot
            Invoke-FinishFeature $repoRoot $fname
        }
        default { throw "unknown subcommand $Subcommand" }
    }
} catch {
    $msg = $_.Exception.Message
    Out-FeatureFail $msg
}
