$ErrorActionPreference = 'Stop'

foreach ($path in @('.gitignore', 'LICENSE', 'README.md')) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing required bootstrap file: $path"
  }
}

$phase9Script = Join-Path $PSScriptRoot 'aws-acceptance.ps1'
if (-not (Test-Path -LiteralPath $phase9Script)) {
  throw 'Missing Phase 9 AWS acceptance script.'
}
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($phase9Script, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors) {
  throw "Phase 9 AWS acceptance script has syntax errors: $($parseErrors.Message -join '; ')"
}
$phase9Content = Get-Content -Raw -LiteralPath $phase9Script
foreach ($marker in @(
    "'Baseline'", "'Resilience'", "'SelfHeal'", "'WaitRevision'",
    "'domainVpn'", "'Public'", "'Private'", 'cloudfront',
    'describe-client-vpn-endpoints', '/argocd/api/v1/session?probe=1',
    'Idempotency-Key', 'NetworkPolicy', 'ORDER_PERSISTENCE_AFTER_RESTART'
  )) {
  if (-not $phase9Content.Contains($marker, [System.StringComparison]::Ordinal)) {
    throw "Phase 9 AWS acceptance script is missing required coverage marker: $marker"
  }
}

& (Join-Path $PSScriptRoot 'test-chart.ps1')
& (Join-Path $PSScriptRoot 'evidence-audit.ps1')
& (Join-Path $PSScriptRoot 'test-local-cleanup.ps1')

$forbidden = git ls-files | Select-String -Pattern '(^|/)(\.env$|rendered/)|\.(tfstate|tfplan)$'
if ($forbidden) {
  throw "Forbidden generated or sensitive path is tracked: $($forbidden -join ', ')"
}

Write-Host 'techx-chart verification passed.'
