Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSCommandPath
$RepoRoot = Split-Path -Parent $ScriptRoot

$BaselinePath   = Join-Path $RepoRoot 'config\baseline.json'
$ScopePath      = Join-Path $RepoRoot 'config\scope.json'
$StatusPath     = Join-Path $RepoRoot 'config\policy_status.json'
$InitiativePath = Join-Path $RepoRoot 'policy-set\storage-initiative.json'
$ReportPath     = Join-Path $RepoRoot 'reports\latest-report.md'
$EnvPath        = Join-Path $RepoRoot '.env'
$GitHubApi      = 'https://api.github.com'

$Headers = @{
    Accept       = 'application/vnd.github+json'
    'User-Agent' = 'PowerShell-AzurePolicyDeltaReport'
}

function Import-DotEnvFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $map = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }

        $parts = $trimmed -split '=', 2
        if ($parts.Count -ne 2) { continue }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()

        if (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $map[$key] = $value
    }

    return $map
}

$envVars = Import-DotEnvFile -Path $EnvPath
if ($envVars.ContainsKey('GITHUB_TOKEN') -and -not [string]::IsNullOrWhiteSpace([string]$envVars['GITHUB_TOKEN'])) {
    $Headers['Authorization'] = "Bearer $($envVars['GITHUB_TOKEN'])"
}

function ConvertTo-Hashtable {
    param(
        [Parameter(ValueFromPipeline)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) {
            $hash[$key] = ConvertTo-Hashtable -InputObject $InputObject[$key]
        }
        return $hash
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-Hashtable -InputObject $item)
        }
        return $items
    }

    if ($InputObject -is [pscustomobject] -or $InputObject.GetType().Name -eq 'PSCustomObject') {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-Hashtable -InputObject $prop.Value
        }
        return $hash
    }

    return $InputObject
}

function Copy-Data {
    param(
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    return ($InputObject | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 | ConvertTo-Hashtable)
}

function Import-JsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        $Default = $null
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $(if ($null -ne $Default) { $Default } else { @{} })
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $(if ($null -ne $Default) { $Default } else { @{} })
    }

    try {
        $parsed = $raw | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Ungültiges JSON in Datei '$Path': $($_.Exception.Message)"
    }

    return (ConvertTo-Hashtable -InputObject $parsed)
}

function Export-JsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        $Data
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $Data | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.Encoding]::UTF8)

}

function Invoke-GitHubGet {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    try {
        return (Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -TimeoutSec 30 | ConvertTo-Hashtable)
    }
    catch {
        $message = $_.Exception.Message
        $statusCode = $null

        try {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        catch {}

        if ($null -ne $statusCode) {
            throw "GitHub GET failed ($statusCode): $Url`n$message"
        }

        throw "GitHub GET failed: $Url`n$message"
    }
}

function Get-GitHubRepo {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo
    )

    return Invoke-GitHubGet -Url "$GitHubApi/repos/$Owner/$Repo"
}

function Get-GitHubBranch {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch
    )

    return Invoke-GitHubGet -Url "$GitHubApi/repos/$Owner/$Repo/branches/$Branch"
}

function Get-GitHubCompare {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Head
    )

    return Invoke-GitHubGet -Url "$GitHubApi/repos/$Owner/$Repo/compare/$Base...$Head"
}

function Get-GitHubTreeRecursive {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$TreeSha
    )

    if (-not $TreeSha) {
        throw "TreeSha is empty."
    }

    $url = "$GitHubApi/repos/$Owner/$Repo/git/trees/$($TreeSha)?recursive=1"
    return Invoke-GitHubGet -Url $url
}

function Get-GitHubJsonFile {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Ref
    )

    $rawUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Ref/$Path"

    try {
        return (Invoke-RestMethod -Uri $rawUrl -Headers $Headers -Method Get -TimeoutSec 30 | ConvertTo-Hashtable)
    }
    catch {
        $apiUrl = "$GitHubApi/repos/$Owner/$Repo/contents/$Path?ref=$Ref"

        try {
            $payload = Invoke-RestMethod -Uri $apiUrl -Headers $Headers -Method Get -TimeoutSec 30 | ConvertTo-Hashtable
        }
        catch {
            $statusCode = $null
            try {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }
            catch {}

            if ($statusCode -eq 404) {
                return $null
            }

            throw
        }

        if ($payload['encoding'] -eq 'base64' -and $payload['content']) {
            $bytes = [Convert]::FromBase64String(($payload['content'] -replace '\s', ''))
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            return ($text | ConvertFrom-Json -Depth 100 | ConvertTo-Hashtable)
        }

        if ($payload['download_url']) {
            return (Invoke-RestMethod -Uri $payload['download_url'] -Headers $Headers -Method Get -TimeoutSec 30 | ConvertTo-Hashtable)
        }

        return $null
    }
}

function Initialize-StatusData {
    param(
        $StatusData
    )

    $data = if ($null -ne $StatusData) { Copy-Data -InputObject $StatusData } else { @{} }

    if (-not ($data -is [System.Collections.IDictionary])) {
        $data = @{}
    }

    if (-not $data.ContainsKey('policies') -or -not ($data['policies'] -is [System.Collections.IDictionary])) {
        $data['policies'] = @{}
    }

    return $data
}

function Test-PolicyPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $pathLower = $Path.ToLowerInvariant()
    return $pathLower.EndsWith('.json') -and $pathLower.Contains('built-in-policies')
}

function Test-PathInScope {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Scope
    )

    $pathLower = $Path.ToLowerInvariant()

    foreach ($category in @($Scope['categories'])) {
        if ($pathLower.Contains(([string]$category).ToLowerInvariant())) {
            return $true
        }
    }

    return $false
}

function Get-AllPolicyFiles {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)]$BranchInfo,
        [Parameter(Mandatory)]$Scope
    )

    $treeSha = $BranchInfo['commit']['commit']['tree']['sha']
    $tree = Get-GitHubTreeRecursive -Owner $Owner -Repo $Repo -TreeSha $treeSha

    $policyFiles = @()

    foreach ($item in @($tree['tree'])) {
        $path = [string]$item['path']

        if ($item['type'] -ne 'blob') { continue }
        if (-not (Test-PolicyPath -Path $path)) { continue }
        if (-not (Test-PathInScope -Path $path -Scope $Scope)) { continue }

        $policyFiles += @{
            filename = $path
            status   = 'full_scan'
        }
    }

    return $policyFiles
}

function Get-NormalizedPolicyId {
    param(
        [Parameter(Mandatory)]
        $Doc
    )

    if ($Doc['id'] -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Doc['id'])) {
        return ([string]$Doc['id']).ToLowerInvariant()
    }

    if ($Doc['name'] -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Doc['name'])) {
        return "/providers/microsoft.authorization/policydefinitions/$($Doc['name'])".ToLowerInvariant()
    }

    return $null
}

function Get-PolicyEffects {
    param(
        $Node
    )

    $effects = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Find-Effects {
        param($Current, $EffectSet)

        if ($null -eq $Current) { return }

        if ($Current -is [System.Collections.IDictionary]) {
            if ($Current.Contains('effect') -and $Current['effect'] -is [string]) {
                [void]$EffectSet.Add([string]$Current['effect'])
            }

            foreach ($value in $Current.Values) {
                Find-Effects -Current $value -EffectSet $EffectSet
            }
            return
        }

        if ($Current -is [System.Collections.IEnumerable] -and -not ($Current -is [string])) {
            foreach ($item in $Current) {
                Find-Effects -Current $item -EffectSet $EffectSet
            }
        }
    }

    Find-Effects -Current $Node -EffectSet $effects
    return @($effects | Sort-Object)
}

function Get-ResourceProviders {
    param(
        $Node
    )

    $providers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Find-Providers {
        param($Current, $ProviderSet)

        if ($null -eq $Current) { return }

        if ($Current -is [System.Collections.IDictionary]) {
            foreach ($key in $Current.Keys) {
                $value = $Current[$key]

                if (
                    (($key.ToString().ToLowerInvariant()) -in @('field', 'source')) -and
                    ($value -is [string]) -and
                    (-not $value.StartsWith('type')) -and
                    $value.StartsWith('Microsoft.') -and
                    $value.Contains('/')
                ) {
                    [void]$ProviderSet.Add(($value -split '/')[0])
                }

                Find-Providers -Current $value -ProviderSet $ProviderSet
            }
            return
        }

        if ($Current -is [System.Collections.IEnumerable] -and -not ($Current -is [string])) {
            foreach ($item in $Current) {
                Find-Providers -Current $item -ProviderSet $ProviderSet
            }
        }
    }

    Find-Providers -Current $Node -ProviderSet $providers
    return @($providers | Sort-Object)
}

function Test-Deprecated {
    param(
        [Parameter(Mandatory)]
        $Doc
    )

    $deprecated = $null

    if ($Doc -is [System.Collections.IDictionary] -and $Doc.ContainsKey('properties')) {
        $props = $Doc['properties']
        if ($props -is [System.Collections.IDictionary] -and $props.ContainsKey('metadata')) {
            $metadata = $props['metadata']
            if ($metadata -is [System.Collections.IDictionary] -and $metadata.ContainsKey('deprecated')) {
                $deprecated = $metadata['deprecated']
            }
        }
    }

    return [bool]$deprecated
}

function ConvertTo-PolicyInfo {
    param(
        [Parameter(Mandatory)]$Doc,
        [Parameter(Mandatory)][string]$Path
    )

    $props = @{}
    if ($Doc -is [System.Collections.IDictionary] -and $Doc.ContainsKey('properties') -and $Doc['properties'] -is [System.Collections.IDictionary]) {
        $props = $Doc['properties']
    }

    $metadata = @{}
    if ($props.ContainsKey('metadata') -and $props['metadata'] -is [System.Collections.IDictionary]) {
        $metadata = $props['metadata']
    }

    $definitionType = if ($props.ContainsKey('policyDefinitions')) { 'initiative' } else { 'policy' }

    $policyRule = @{}
    if ($props.ContainsKey('policyRule') -and $null -ne $props['policyRule']) {
        $policyRule = $props['policyRule']
    }

    $policyRefs = @()
    if ($definitionType -eq 'initiative' -and $props.ContainsKey('policyDefinitions') -and $null -ne $props['policyDefinitions']) {
        $policyRefs = @($props['policyDefinitions'])
    }

    return @{
        id                   = Get-NormalizedPolicyId -Doc $Doc
        name                 = $Doc['name']
        displayName          = $(if ($props.ContainsKey('displayName') -and $props['displayName']) { $props['displayName'] } elseif ($Doc['name']) { $Doc['name'] } else { $Path })
        category             = $(if ($metadata.ContainsKey('category') -and $metadata['category']) { $metadata['category'] } else { 'Unknown' })
        version              = $(if ($metadata.ContainsKey('version') -and $metadata['version']) { $metadata['version'] } else { 'unknown' })
        policyType           = $(if ($props.ContainsKey('policyType') -and $props['policyType']) { $props['policyType'] } else { 'Unknown' })
        mode                 = $(if ($props.ContainsKey('mode') -and $null -ne $props['mode']) { $props['mode'] } else { '' })
        definitionType       = $definitionType
        effects              = $(if ($definitionType -eq 'policy') { @(Get-PolicyEffects -Node $policyRule) } else { @() })
        resourceProviders    = $(if ($definitionType -eq 'policy') { @(Get-ResourceProviders -Node $policyRule) } else { @() })
        policyReferenceCount = @($policyRefs).Count
        path                 = $Path
        deprecated           = Test-Deprecated -Doc $Doc
    }
}

function Test-PolicyRelevance {
    param(
        [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)]$Scope
    )

    $reasons = @()

    if ($Info['policyType'] -ne 'BuiltIn') {
        return @{
            IsRelevant = $false
            Reasons    = @()
        }
    }

    $excludeDeprecated = $true
    if ($Scope -is [System.Collections.IDictionary] -and $Scope.ContainsKey('excludeDeprecated')) {
        $excludeDeprecated = [bool]$Scope['excludeDeprecated']
    }

    if ($excludeDeprecated -and [bool]$Info['deprecated']) {
        return @{
            IsRelevant = $false
            Reasons    = @()
        }
    }

    $categories = @($Scope['categories'] | ForEach-Object { [string]$_ })
    $allowedEffects = @($Scope['allowedEffects'] | ForEach-Object { [string]$_ })
    $infoEffects = @($Info['effects'] | ForEach-Object { [string]$_ })

    if ($categories -contains [string]$Info['category']) {
        $reasons += "Kategorie passt: $($Info['category'])"
    }

    $matchedEffects = @(
        $infoEffects | Where-Object { $allowedEffects -contains $_ } | Sort-Object -Unique
    )

    if (@($matchedEffects).Count -gt 0) {
        $reasons += "Effekt passt: $($matchedEffects -join ', ')"
    }

    if ($Info['definitionType'] -eq 'initiative' -and ($categories -contains [string]$Info['category'])) {
        $reasons += 'Initiative in relevanter Kategorie'
    }

    return @{
        IsRelevant = (@($reasons).Count -gt 0)
        Reasons    = @($reasons)
    }
}

function Get-FileChangeType {
    param(
        [Parameter(Mandatory)]
        $FileEntry
    )

    $status = [string]$FileEntry['status']
    $previousFilename = $FileEntry['previous_filename']

    switch ($status) {
        'added'    { return 'neu' }
        'modified' { return 'geändert' }
        'removed'  { return 'entfernt' }
        'renamed'  { return $(if ($previousFilename) { "umbenannt (früher: $previousFilename)" } else { 'renamed' }) }
        default    { return $(if ($status) { $status } else { 'unbekannt' }) }
    }
}

function Get-ExistingPolicyIds {
    param(
        [Parameter(Mandatory)]
        $Initiative
    )

    $result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not ($Initiative -is [System.Collections.IDictionary])) {
        return $result
    }

    $refs = $Initiative['memberDefinitions']

    if ($refs -is [System.Collections.IDictionary]) {
        foreach ($entry in $refs.GetEnumerator()) {
            $item = $entry.Value
            if ($item -is [System.Collections.IDictionary] -and $item['id'] -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$item['id'])) {
                [void]$result.Add(([string]$item['id']).ToLowerInvariant())
            }
        }
    }
    else {
        foreach ($item in @($refs)) {
            if ($item -is [System.Collections.IDictionary] -and $item['id'] -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$item['id'])) {
                [void]$result.Add(([string]$item['id']).ToLowerInvariant())
            }
        }
    }

    return $result
}

function Get-StatusEntry {
    param(
        [Parameter(Mandatory)]$StatusData,
        [Parameter(Mandatory)][string]$PolicyId
    )

    $key = $PolicyId.ToLowerInvariant()

    if ($StatusData['policies'].ContainsKey($key)) {
        return $StatusData['policies'][$key]
    }

    return $null
}

function Set-StatusEntry {
    param(
        [Parameter(Mandatory)]$StatusData,
        [Parameter(Mandatory)][string]$PolicyId,
        [Parameter(Mandatory)]$Entry
    )

    $StatusData['policies'][$PolicyId.ToLowerInvariant()] = $Entry
}

function Get-TodayIsoDate {
    return (Get-Date).ToString('yyyy-MM-dd')
}

function New-CandidateStatus {
    param(
        [Parameter(Mandatory)]
        $Info
    )

    return @{
        status          = 'candidate'
        firstSeenDate   = Get-TodayIsoDate
        lastSeenDate    = Get-TodayIsoDate
        lastSeenVersion = $Info['version']
        displayName     = $Info['displayName']
        category        = $Info['category']
        path            = $Info['path']
    }
}

function Update-SeenMetadata {
    param(
        $ExistingEntry,
        [Parameter(Mandatory)]$Info
    )

    $updated = if ($null -ne $ExistingEntry) { Copy-Data -InputObject $ExistingEntry } else { @{} }

    if (-not ($updated -is [System.Collections.IDictionary])) {
        $updated = @{}
    }

    $updated['lastSeenDate'] = Get-TodayIsoDate
    $updated['lastSeenVersion'] = $Info['version']
    $updated['displayName'] = $Info['displayName']
    $updated['category'] = $Info['category']
    $updated['path'] = $Info['path']

    return $updated
}

function Get-Outcome {
    param(
        [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)]$ExistingPolicyIds,
        [Parameter(Mandatory)]$StatusData
    )

    $policyId = $Info['id']

    if (-not $policyId) {
        return @{
            Outcome          = 'unknown'
            StatusEntryToWrite = $null
            Explanation      = 'Keine normalisierte Policy-ID verfügbar'
        }
    }

    if ($ExistingPolicyIds.Contains($policyId)) {
        $existingEntry = Get-StatusEntry -StatusData $StatusData -PolicyId $policyId
        if (-not $existingEntry) { $existingEntry = @{} }

        $newEntry = Update-SeenMetadata -ExistingEntry $existingEntry -Info $Info

        if ($newEntry['status'] -ne 'accepted') {
            $newEntry['status'] = 'accepted'
            $newEntry['decisionDate'] = $(if ($newEntry['decisionDate']) { $newEntry['decisionDate'] } else { Get-TodayIsoDate })
            $newEntry['reason'] = $(if ($newEntry['reason']) { $newEntry['reason'] } else { 'In Initiative enthalten' })
            $newEntry['lastReviewedVersion'] = $Info['version']
        }

        return @{
            Outcome            = 'in_initiative'
            StatusEntryToWrite = $newEntry
            Explanation        = 'Bereits in Initiative enthalten'
        }
    }

    $statusEntry = Get-StatusEntry -StatusData $StatusData -PolicyId $policyId

    if (-not $statusEntry) {
        return @{
            Outcome            = 'new_candidate'
            StatusEntryToWrite = (New-CandidateStatus -Info $Info)
            Explanation        = 'Neu erkannt und noch nicht entschieden'
        }
    }

    $updatedEntry = Update-SeenMetadata -ExistingEntry $statusEntry -Info $Info
    $currentStatus = [string]$(if ($updatedEntry['status']) { $updatedEntry['status'] } else { 'candidate' })
    $reviewedVersion = [string]$(if ($updatedEntry['lastReviewedVersion']) { $updatedEntry['lastReviewedVersion'] } else { '' })

    if ($currentStatus -in @('rejected', 'deferred', 'accepted')) {
        if ($reviewedVersion.Trim() -and $reviewedVersion -ne [string]$Info['version']) {
            $updatedEntry['status'] = 'changed_since_decision'
            $updatedEntry['changedSinceDecisionDate'] = Get-TodayIsoDate

            return @{
                Outcome            = 'changed_since_decision'
                StatusEntryToWrite = $updatedEntry
                Explanation        = "Version geändert seit letzter Entscheidung ($reviewedVersion -> $($Info['version']))"
            }
        }

        return @{
            Outcome            = $currentStatus
            StatusEntryToWrite = $updatedEntry
            Explanation        = "Bereits entschieden: $currentStatus"
        }
    }

    if ($currentStatus -eq 'changed_since_decision') {
        return @{
            Outcome            = 'changed_since_decision'
            StatusEntryToWrite = $updatedEntry
            Explanation        = 'Bereits als geändert seit Entscheidung markiert'
        }
    }

    return @{
        Outcome            = 'known_candidate'
        StatusEntryToWrite = $updatedEntry
        Explanation        = 'Bereits als Kandidat bekannt'
    }
}

function Add-ReportSection {
    param(
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$Builder,

        [Parameter(Mandatory)]
        [string]$Title,

        $Items = @()
    )

    $Items = @($Items)

    [void]$Builder.AppendLine("## $Title")
    [void]$Builder.AppendLine()

    if ($Items.Count -eq 0) {
        [void]$Builder.AppendLine("Keine Einträge.")
        [void]$Builder.AppendLine()
        return
    }

    foreach ($item in ($Items | Sort-Object { $_['displayName'].ToString().ToLowerInvariant() })) {
        [void]$Builder.AppendLine("### $($item['displayName'])")
        [void]$Builder.AppendLine("- Policy ID: ``$($item['id'])``")
        [void]$Builder.AppendLine("- Typ: $($item['definitionType'])")
        [void]$Builder.AppendLine("- Änderung im Upstream: $($item['changeType'])")
        [void]$Builder.AppendLine("- Kategorie: $($item['category'])")
        [void]$Builder.AppendLine("- Version: $($item['version'])")
        [void]$Builder.AppendLine("- Status: $($item['outcome'])")
        [void]$Builder.AppendLine("- Pfad: ``$($item['path'])``")

        if (@($item['effects']).Count -gt 0) {
            [void]$Builder.AppendLine("- Effekte: $(@($item['effects']) -join ', ')")
        }
        if (@($item['resourceProviders']).Count -gt 0) {
            [void]$Builder.AppendLine("- Resource Provider: $(@($item['resourceProviders']) -join ', ')")
        }
        if (@($item['relevanceReasons']).Count -gt 0) {
            [void]$Builder.AppendLine("- Relevanz: $(@($item['relevanceReasons']) -join '; ')")
        }
        if ($item['statusExplanation']) {
            [void]$Builder.AppendLine("- Entscheidungslogik: $($item['statusExplanation'])")
        }
        if ($item['statusReason']) {
            [void]$Builder.AppendLine("- Begründung: $($item['statusReason'])")
        }

        [void]$Builder.AppendLine()
    }
}

function New-ReportText {
    param(
        [Parameter(Mandatory)][string]$UpstreamRepo,
        [Parameter(Mandatory)][string]$BaseRef,
        [Parameter(Mandatory)][string]$HeadSha,
        [Parameter(Mandatory)]$Results
    )

    $builder = [System.Text.StringBuilder]::new()

    [void]$builder.AppendLine('# Azure Policy Delta Report')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("- Upstream-Repo: ``$UpstreamRepo``")
    [void]$builder.AppendLine("- Verglichen: ``$BaseRef`` ... ``$HeadSha``")
    [void]$builder.AppendLine()

    Add-ReportSection -Builder $builder -Title 'Neu erkannte Kandidaten' -Items $Results['new_candidate']
    Add-ReportSection -Builder $builder -Title 'Bereits bekannte Kandidaten' -Items $Results['known_candidate']
    Add-ReportSection -Builder $builder -Title 'Geändert seit letzter Entscheidung' -Items $Results['changed_since_decision']
    Add-ReportSection -Builder $builder -Title 'Bereits verworfen' -Items $Results['rejected']
    Add-ReportSection -Builder $builder -Title 'Zurückgestellt' -Items $Results['deferred']
    Add-ReportSection -Builder $builder -Title 'Bereits übernommen oder in Initiative enthalten' -Items $Results['in_initiative']
    Add-ReportSection -Builder $builder -Title 'Nicht relevant oder gefiltert' -Items $Results['ignored']

    return $builder.ToString().TrimEnd()
}

function Main {
    $baseline = Import-JsonFile -Path $BaselinePath
    $scope = Import-JsonFile -Path $ScopePath
    $statusData = Initialize-StatusData -StatusData (Import-JsonFile -Path $StatusPath -Default @{ policies = @{} })
    $initiative = Import-JsonFile -Path $InitiativePath

    if ($null -eq $baseline) {
        throw "baseline.json is empty or could not be read: $BaselinePath"
    }

    if (-not ($baseline -is [System.Collections.IDictionary])) {
        $baseline = ConvertTo-Hashtable -InputObject $baseline
    }

    if (-not ($baseline -is [System.Collections.IDictionary])) {
        throw "baseline.json must be a JSON object. Expected e.g.: { `"upstreamRepo`": `"Azure/azure-policy`", `"lastProcessedCommit`": `"`" }. Path: $BaselinePath"
    }

    if (-not ($scope -is [System.Collections.IDictionary])) {
        throw "scope.json must be a JSON object: $ScopePath"
    }

    $upstreamRepo = [string]$(if ($baseline.ContainsKey('upstreamRepo')) { $baseline['upstreamRepo'] } else { '' })
    $upstreamRepo = $upstreamRepo.Trim()

    if ($upstreamRepo -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "baseline.json does not contain a valid upstreamRepo in the format 'owner/repo'. Current value: '$upstreamRepo'"
    }

    $owner, $repo = $upstreamRepo -split '/', 2

    $results = @{
        new_candidate          = @()
        known_candidate        = @()
        changed_since_decision = @()
        rejected               = @()
        deferred               = @()
        accepted               = @()
        in_initiative          = @()
        ignored                = @()
    }

    $repoInfo = Get-GitHubRepo -Owner $owner -Repo $repo
    $defaultBranch = [string]$repoInfo['default_branch']

    $branchInfo = Get-GitHubBranch -Owner $owner -Repo $repo -Branch $defaultBranch
    $currentHeadSha = [string]$branchInfo['commit']['sha']

    $baseRef = [string]$(if ($baseline.ContainsKey('lastProcessedCommit') -and $baseline['lastProcessedCommit']) { $baseline['lastProcessedCommit'] } else { '' })
    $baseRef = $baseRef.Trim()

    if (-not $baseRef) {
        $policyFiles = Get-AllPolicyFiles -Owner $owner -Repo $repo -BranchInfo $branchInfo -Scope $scope
        $compareLabel = 'FULL_SCAN'
    }
    else {
        try {
            $compare = Get-GitHubCompare -Owner $owner -Repo $repo -Base $baseRef -Head $currentHeadSha
            $policyFiles = @(
                foreach ($file in @($compare['files'])) {
                    if (Test-PolicyPath -Path $file['filename']) {
                        $file
                    }
                }
            )
            $compareLabel = $baseRef
        }
        catch {
            Write-Warning "Compare for lastProcessedCommit '$baseRef' failed. A FULL_SCAN will be performed."
            $policyFiles = Get-AllPolicyFiles -Owner $owner -Repo $repo -BranchInfo $branchInfo -Scope $scope
            $compareLabel = 'FULL_SCAN'
        }
    }

    $existingPolicyIds = Get-ExistingPolicyIds -Initiative $initiative

    foreach ($fileEntry in @($policyFiles)) {
        if ($fileEntry['status'] -eq 'removed') {
            continue
        }

        $filename = [string]$fileEntry['filename']
        $doc = Get-GitHubJsonFile -Owner $owner -Repo $repo -Path $filename -Ref $currentHeadSha

        if (-not $doc) {
            continue
        }

        $info = ConvertTo-PolicyInfo -Doc $doc -Path $filename
        $info['changeType'] = Get-FileChangeType -FileEntry $fileEntry

        $relevanceResult = Test-PolicyRelevance -Info $info -Scope $scope
        $relevant = [bool]$relevanceResult['IsRelevant']
        $relevanceReasons = @($relevanceResult['Reasons'])
        $info['relevanceReasons'] = $relevanceReasons

        if (-not $relevant) {
            $info['outcome'] = 'ignored'
            $results['ignored'] += ,$info
            continue
        }

        $outcomeResult = Get-Outcome -Info $info -ExistingPolicyIds $existingPolicyIds -StatusData $statusData
        $outcome = [string]$outcomeResult['Outcome']
        $statusEntryToWrite = $outcomeResult['StatusEntryToWrite']
        $explanation = [string]$outcomeResult['Explanation']

        $info['outcome'] = $outcome
        $info['statusExplanation'] = $explanation

        if ($statusEntryToWrite -and $info['id']) {
            Set-StatusEntry -StatusData $statusData -PolicyId $info['id'] -Entry $statusEntryToWrite
            if ($statusEntryToWrite['reason']) {
                $info['statusReason'] = $statusEntryToWrite['reason']
                
            }
        }
        
        switch ($outcome) {
            'new_candidate'          { $results['new_candidate'] += ,$info }
            'known_candidate'        { $results['known_candidate'] += ,$info }
            'changed_since_decision' { $results['changed_since_decision'] += ,$info }
            'rejected'               { $results['rejected'] += ,$info }
            'deferred'               { $results['deferred'] += ,$info }
            { $_ -in @('accepted', 'in_initiative') } { $results['in_initiative'] += ,$info }
            default                  { $results['ignored'] += ,$info }
        }
    }

    $report = New-ReportText -UpstreamRepo $upstreamRepo -BaseRef $compareLabel -HeadSha $currentHeadSha -Results $results

    $reportDir = Split-Path -Path $ReportPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($ReportPath, $report, [System.Text.Encoding]::UTF8)

    $baseline['lastProcessedCommit'] = $currentHeadSha
    Export-JsonFile -Path $BaselinePath -Data $baseline
    Export-JsonFile -Path $StatusPath -Data $statusData

    return 0
}

exit (Main)