# Shared by live acceptance and isolated regression tests.
function Get-ReleaseArtifacts([string]$Tag) {
  $manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../releases/staging.json') | ConvertFrom-Json
  if ($manifest.commit -notmatch '^[a-f0-9]{40}$' -or $manifest.tag -ne "staging-$($manifest.commit.Substring(0, 12))" -or $manifest.tag -ne $Tag) {
    throw 'Release manifest does not identify the expected source/tag.'
  }
  $components = @('frontend', 'catalog', 'order')
  if ($manifest.images.Count -ne 3 -or (@($manifest.images.component | Sort-Object -Unique) -join ',') -ne 'catalog,frontend,order') {
    throw 'Release manifest must contain exactly three distinct components.'
  }
  $entries = @{}
  foreach ($entry in $manifest.images) {
    $expected = "058114477594.dkr.ecr.us-east-1.amazonaws.com/techx/$($entry.component):$Tag"
    if ($entry.image -ne $expected -or $entry.digest -notmatch '^sha256:[a-f0-9]{64}$') {
      throw 'Release manifest repository or digest is invalid.'
    }
    $name = switch ($entry.component) { 'catalog' { 'catalog-api' } 'order' { 'order-api' } default { 'frontend' } }
    $entries[$name] = $entry
  }
  return $entries
}

function Assert-ImageTag([string]$Tag) {
  if (-not $Tag) { return }
  $artifacts = Get-ReleaseArtifacts $Tag
  $deployments = Invoke-KubectlJson @('-n', $Namespace, 'get', 'deployments')
  if ($deployments.items.Count -ne 3 -or (@($deployments.items.metadata.name | Sort-Object -Unique) -join ',') -ne 'catalog-api,frontend,order-api') {
    throw 'Expected exactly the three TechX Deployments.'
  }
  foreach ($deployment in $deployments.items) {
    $entry = $artifacts[$deployment.metadata.name]
    $images = @($deployment.spec.template.spec.containers.image)
    $pinned = ($entry.image -replace ':[^:]+$', '') + '@' + $entry.digest
    if ($images.Count -ne 1 -or $images[0] -notin @($entry.image, $pinned)) {
      throw "$($deployment.metadata.name) does not run the expected immutable artifact."
    }
  }
}

function Assert-EcrArtifacts([string]$Tag) {
  if (-not $Tag) { return }
  Assert-ImageTag $Tag
  $artifacts = Get-ReleaseArtifacts $Tag
  foreach ($name in @('frontend', 'catalog-api', 'order-api')) {
    $entry = $artifacts[$name]
    $repository = 'techx/' + $entry.component
    $repositoryDetails = Invoke-AwsJson @('ecr', 'describe-repositories', '--repository-names', $repository)
    if ($repositoryDetails.repositories.Count -ne 1 -or $repositoryDetails.repositories[0].imageTagMutability -ne 'IMMUTABLE') {
      throw "ECR repository $repository is not immutable."
    }
    $details = Invoke-AwsJson @('ecr', 'describe-images', '--repository-name', $repository, '--image-ids', "imageTag=$Tag")
    if ($details.imageDetails.Count -ne 1 -or $details.imageDetails[0].imageDigest -ne $entry.digest) {
      throw "ECR digest does not match release manifest for $repository."
    }
    $scan = Invoke-AwsJson @('ecr', 'describe-image-scan-findings', '--repository-name', $repository, '--image-id', "imageTag=$Tag")
    if ($scan.imageScanStatus.status -ne 'COMPLETE' -or [int]($scan.imageScanFindings.findingSeverityCounts.CRITICAL ?? 0) -ne 0 -or [int]($scan.imageScanFindings.findingSeverityCounts.HIGH ?? 0) -ne 0) {
      throw "ECR scan is not COMPLETE with zero HIGH/CRITICAL findings for $repository."
    }
    $pods = Invoke-KubectlJson @('-n', $Namespace, 'get', 'pods', '-l', "app.kubernetes.io/component=$name")
    $activePods = @($pods.items | Where-Object { -not $_.metadata.deletionTimestamp })
    $imageIds = @($activePods.status.containerStatuses.imageID)
    if ($activePods.Count -lt 1 -or $imageIds.Count -ne $activePods.Count -or @($imageIds | Where-Object { -not $_ -or -not $_.EndsWith("@$($entry.digest)", [StringComparison]::Ordinal) }).Count -gt 0) {
      throw "$name runtime image digest does not match the release artifact."
    }
    Write-Host "$name artifact verified: $repository@$($entry.digest)"
  }
}
