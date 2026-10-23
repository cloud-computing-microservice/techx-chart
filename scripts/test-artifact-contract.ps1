$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'artifact-contract.ps1')
$Namespace = 'techx-staging'
$manifest = Get-Content -Raw (Join-Path $PSScriptRoot '../releases/staging.json') | ConvertFrom-Json
$testState = @{ wrongImage = $false; wrongRuntime = $false; high = 0; scanStatus = 'COMPLETE'; missingDeployment = $false }
function Invoke-KubectlJson([string[]]$Arguments) {
  if ($Arguments -contains 'deployments') {
    $items = foreach ($entry in $manifest.images) {
      $name = switch ($entry.component) { 'catalog' { 'catalog-api' } 'order' { 'order-api' } default { 'frontend' } }
      if ($testState.missingDeployment -and $name -eq 'frontend') { continue }
      $image = ($entry.image -replace ':[^:]+$', '') + '@' + $entry.digest
      if ($testState.wrongImage) { $image = 'other/repo@' + $entry.digest }
      @{ metadata = @{ name = $name }; spec = @{ template = @{ spec = @{ containers = @(@{ image = $image }) } } } }
    }
    return @{ items = @($items) } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  }
  $name = ($Arguments[-1] -split '=')[-1]
  $component = switch ($name) { 'catalog-api' { 'catalog' } 'order-api' { 'order' } default { 'frontend' } }
  $entry = $manifest.images | Where-Object component -EQ $component
  $digest = if ($testState.wrongRuntime) { 'sha256:' + ('0' * 64) } else { $entry.digest }
  return @{ items = @(@{ metadata = @{}; status = @{ containerStatuses = @(@{ imageID = "repo@$digest" }) } }) } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
}
function Invoke-AwsJson([string[]]$Arguments) {
  switch ($Arguments[1]) {
    'describe-repositories' { return @{ repositories = @(@{ imageTagMutability = 'IMMUTABLE' }) } }
    'describe-images' {
      $name = ($Arguments[3] -split '/')[-1]
      return @{ imageDetails = @(@{ imageDigest = ($manifest.images | Where-Object component -EQ $name).digest }) }
    }
    'describe-image-scan-findings' { return @{ imageScanStatus = @{ status = $testState.scanStatus }; imageScanFindings = @{ findingSeverityCounts = @{ HIGH = $testState.high; CRITICAL = 0 } } } }
    default { throw 'Unexpected AWS call in isolated test.' }
  }
}
Assert-EcrArtifacts $manifest.tag
foreach ($field in @('wrongImage', 'wrongRuntime', 'high', 'scanStatus', 'missingDeployment')) {
  $previous = $testState[$field]
  $testState[$field] = switch ($field) { 'high' { 1 } 'scanStatus' { 'IN_PROGRESS' } default { $true } }
  $rejected = $false
  try { Assert-EcrArtifacts $manifest.tag } catch { $rejected = $true }
  if (-not $rejected) { throw "Artifact gate accepted invalid $field." }
  $testState[$field] = $previous
}
Write-Host 'Artifact manifest, ECR scan and runtime digest regression tests passed.'
