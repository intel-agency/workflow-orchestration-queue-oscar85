#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates each model listed under the providers section of opencode.json by invoking
    a test prompt and checking the response and exit code.

.PARAMETER ConfigFile
    Path to opencode.json. Defaults to opencode.json in the script's parent directory.

.PARAMETER Prompt
    Test prompt to send to each model. Defaults to "Reply with only the word PASS."

.PARAMETER TimeoutSeconds
    Per-model timeout in seconds. Defaults to 60.

.PARAMETER Provider
    If specified, only test models under this provider (e.g. "google", "openai").

.PARAMETER Model
    If specified, only test this single model id (e.g. "gemini-3.1-pro-preview").

.PARAMETER FailedFile
    Path to a failed_models.json produced by a previous run. When supplied, only the models
    listed in that file are tested (all other filters still apply).

.PARAMETER FailedOutputFile
    Path to write the failed_models.json output. Defaults to failed_models.json in the
    script's parent directory. Always overwritten on every run.

.EXAMPLE
    ./scripts/validate-models.ps1
    ./scripts/validate-models.ps1 -Provider google
    ./scripts/validate-models.ps1 -Provider openai -Model gpt-5.4
#>
param(
    [string] $ConfigFile    = (Join-Path $PSScriptRoot ".." "opencode.json"),
    [string] $Prompt        = "Reply with only the word PASS.",
    [int]    $TimeoutSeconds = 60,
    [string] $Provider      = "",
    [string] $Model              = "",
    [string] $StartAt            = "",
    [string] $FailedFile         = "",
    [string] $FailedOutputFile   = (Join-Path $PSScriptRoot ".." "failed_models.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"   # keep going after individual model failures

# ── helpers ──────────────────────────────────────────────────────────────────

function Write-Pass   { param([string]$msg) Write-Host "  [PASS] $msg" -ForegroundColor Green  }
function Write-Fail   { param([string]$msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red    }
function Write-Skip   { param([string]$msg) Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }
function Write-Header { param([string]$msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan  }

# ── load config ──────────────────────────────────────────────────────────────

$configPath = Resolve-Path $ConfigFile -ErrorAction Stop
$config     = Get-Content -Raw $configPath | ConvertFrom-Json

if (-not $config.provider) {
    Write-Error "No 'provider' key found in $configPath"
    exit 1
}

# ── collect models to test ───────────────────────────────────────────────────

$toTest = [System.Collections.Generic.List[hashtable]]::new()

foreach ($providerName in $config.provider.PSObject.Properties.Name) {
    if ($Provider -and $providerName -ne $Provider) { continue }

    $providerObj = $config.provider.$providerName
    if (-not $providerObj.models) { continue }

    foreach ($modelId in $providerObj.models.PSObject.Properties.Name) {
        if ($Model -and $modelId -ne $Model) { continue }

        $friendlyName = $providerObj.models.$modelId.name
        $toTest.Add(@{
            Provider     = $providerName
            ModelId      = $modelId
            FriendlyName = $friendlyName
            FullId       = "$providerName/$modelId"
        })
    }
}

if ($toTest.Count -eq 0) {
    Write-Warning "No models matched the specified filters."
    exit 0
}

# ── apply -FailedFile filter ────────────────────────────────────────────────

if ($FailedFile) {
    $failedFilePath = Resolve-Path $FailedFile -ErrorAction Stop
    $failedJson     = Get-Content -Raw $failedFilePath | ConvertFrom-Json
    $failedIds      = @($failedJson.failed_models | ForEach-Object { $_.full_id })
    if ($failedIds.Count -eq 0) {
        Write-Warning "-FailedFile '$FailedFile' contains no failed models — nothing to re-test."
        exit 0
    }
    $toTest = [System.Collections.Generic.List[hashtable]]($toTest | Where-Object { $failedIds -contains $_.FullId })
    Write-Host "Re-testing $($toTest.Count) model(s) from failed file: $failedFilePath" -ForegroundColor Yellow
    if ($toTest.Count -eq 0) {
        Write-Warning "None of the failed models were found in $configPath."
        exit 0
    }
}

# ── apply -StartAt filter ────────────────────────────────────────────────────

if ($StartAt) {
    $startIdx = -1
    for ($i = 0; $i -lt $toTest.Count; $i++) {
        $e = $toTest[$i]
        if ($e.FullId.Contains($StartAt) -or $e.FriendlyName.Contains($StartAt)) {
            $startIdx = $i
            break
        }
    }
    if ($startIdx -lt 0) {
        Write-Warning "-StartAt '$StartAt' did not match any model — running all models."
    } else {
        if ($startIdx -gt 0) {
            Write-Host "Skipping $startIdx model(s) before '$($toTest[$startIdx].FullId)' (-StartAt '$StartAt')" -ForegroundColor Yellow
        }
        $toTest = [System.Collections.Generic.List[hashtable]]($toTest | Select-Object -Skip $startIdx)
    }
}

Write-Host "`nValidating $($toTest.Count) model(s) from $configPath" -ForegroundColor Cyan
Write-Host "Prompt : `"$Prompt`""
Write-Host "Timeout: ${TimeoutSeconds}s per model`n"

# ── run tests ────────────────────────────────────────────────────────────────

$results = [System.Collections.Generic.List[hashtable]]::new()

foreach ($entry in $toTest) {
    $fullId = $entry.FullId
    Write-Header "$fullId  ($($entry.FriendlyName))"

    $passed    = $false
    $output    = ""
    $errMsg    = ""
    $errOutput = ""
    $exitCode  = -1

    try {
        # Run opencode from the repo root so it picks up opencode.json
        $repoRoot = Split-Path $configPath -Parent
        $cmdDisplay = "opencode run --model $fullId --message `"$Prompt`""
        Write-Host "  $cmdDisplay ..."
        $job = Start-Job -ScriptBlock {
            Set-Location $using:repoRoot
            $out = opencode run --model $using:fullId --message $using:Prompt 2>&1
            [pscustomobject]@{ Output = $out -join "`n"; ExitCode = $LASTEXITCODE }
        }

        $remaining = $TimeoutSeconds
        $completed = $null
        while ($remaining -ge 0) {
            Write-Host "`r  [$remaining s remaining]  " -NoNewline
            $completed = Wait-Job $job -Timeout 1
            if ($completed) { break }
            $remaining--
        }
        Write-Host ""
        if (-not $completed) {
            Stop-Job  $job
            Remove-Job $job -Force
            throw "Timed out after ${TimeoutSeconds}s"
        }

        $result  = Receive-Job $job
        Remove-Job $job -Force
        $output  = $result.Output
        $exitCode = $result.ExitCode

        # Print truncated output for review
        $preview = ($output -split "`n" | Select-Object -Last 5) -join "`n"
        Write-Host "  Output (last 5 lines):`n$preview"

        if ($exitCode -ne 0) {
            throw "opencode exited with code $exitCode"
        }
        if ($output -match 'Error:|error:|exception|Payment Required|Unauthorized|401|403|deactivated') {
            throw "Response contains error indicator"
        }
        if ([string]::IsNullOrWhiteSpace($output)) {
            throw "Empty response"
        }

        $passed = $true
        Write-Pass "$fullId responded successfully (exit 0)"

    } catch {
        $errMsg    = $_.Exception.Message
        $errOutput = $output
        Write-Fail "$fullId — $errMsg"
    }

    $results.Add(@{
        FullId     = $fullId
        Provider   = $entry.Provider
        ModelId    = $entry.ModelId
        Name       = $entry.FriendlyName
        Passed     = $passed
        ExitCode   = if ($passed) { 0 } else { $exitCode }
        Error      = $errMsg
        ErrOutput  = $errOutput
    })
}

# ── summary ──────────────────────────────────────────────────────────────────

$passed = @($results | Where-Object { $_.Passed })
$failed = @($results | Where-Object { -not $_.Passed })

Write-Host "`n$('─' * 60)" -ForegroundColor DarkGray
Write-Host "RESULTS: $($passed.Count) passed, $($failed.Count) failed out of $($results.Count) total" -ForegroundColor Cyan

if ($failed.Count -gt 0) {
    Write-Host "`nFailed models:" -ForegroundColor Red
    foreach ($f in $failed) {
        Write-Host "  ✗ $($f.FullId)  — $($f.Error)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($f.ErrOutput)) {
            # Extract the most relevant error line (first line containing 'Error' or 'error', else last non-empty line)
            $errLines  = ($f.ErrOutput -split "`n") | Where-Object { $_.Trim() -ne '' }
            $errorLine = $errLines | Where-Object { $_ -match 'Error|error|detail|failed' } | Select-Object -First 1
            if (-not $errorLine) { $errorLine = $errLines | Select-Object -Last 1 }
            if ($errorLine) {
                Write-Host "    $($errorLine.Trim())" -ForegroundColor DarkRed
            }
        }
    }
}

if ($passed.Count -gt 0) {
    Write-Host "`nPassed models:" -ForegroundColor Green
    foreach ($p in $passed) {
        Write-Host "  ✓ $($p.FullId)" -ForegroundColor Green
    }
}

# ── write failed_models.json ─────────────────────────────────────────────────

$failedObjs = $failed | ForEach-Object {
    [ordered]@{
        provider       = $_.Provider
        model_id       = $_.ModelId
        full_id        = $_.FullId
        friendly_name  = $_.Name
        exit_code      = $_.ExitCode
        error_message  = $_.Error
        error_response = $_.ErrOutput
    }
}
$failedDoc = [ordered]@{ failed_models = @($failedObjs) }
$outPath   = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FailedOutputFile)
$failedDoc | ConvertTo-Json -Depth 5 | Set-Content -Path $outPath -Encoding utf8

Write-Host ""
exit ($failed.Count -gt 0 ? 1 : 0)
