$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$rendered = Join-Path ([System.IO.Path]::GetTempPath()) "techx-chart-$PID.yaml"
$domainRendered = Join-Path ([System.IO.Path]::GetTempPath()) "techx-chart-domain-$PID.yaml"
$localRendered = Join-Path ([System.IO.Path]::GetTempPath()) "techx-chart-local-$PID.yaml"

try {
  helm lint $root -f (Join-Path $root 'values-staging.yaml')
  if ($LASTEXITCODE -ne 0) { throw 'helm lint failed.' }
  $manifest = helm template techx $root -f (Join-Path $root 'values-staging.yaml')
  if ($LASTEXITCODE -ne 0) { throw 'helm template failed.' }
  $manifest | Set-Content -LiteralPath $rendered -Encoding utf8
  python (Join-Path $root 'tests/assert_manifests.py') $rendered baseline
  if ($LASTEXITCODE -ne 0) { throw 'Manifest assertions failed.' }

  helm lint $root -f (Join-Path $root 'values-staging.yaml') -f (Join-Path $root 'values-domain-vpn.yaml')
  if ($LASTEXITCODE -ne 0) { throw 'domain/VPN helm lint failed.' }
  $domainManifest = helm template techx $root -f (Join-Path $root 'values-staging.yaml') -f (Join-Path $root 'values-domain-vpn.yaml')
  if ($LASTEXITCODE -ne 0) { throw 'domain/VPN helm template failed.' }
  $domainManifest | Set-Content -LiteralPath $domainRendered -Encoding utf8
  python (Join-Path $root 'tests/assert_manifests.py') $domainRendered domainVpn
  if ($LASTEXITCODE -ne 0) { throw 'Domain/VPN manifest assertions failed.' }

  $localManifest = helm template techx $root -f (Join-Path $root 'values-local.yaml')
  if ($LASTEXITCODE -ne 0) { throw 'local helm template failed.' }
  $localManifest | Set-Content -LiteralPath $localRendered -Encoding utf8
  $localDocs = Get-Content -Raw -LiteralPath $localRendered
  foreach ($marker in @(
      'value: "http://dynamodb-local.techx-local-dependencies.svc.cluster.local:8000"',
      'kubernetes.io/metadata.name: techx-local-dependencies',
      'app: dynamodb-local',
      'port: 8000'
    )) {
    if (-not $localDocs.Contains($marker, [System.StringComparison]::Ordinal)) {
      throw "Local DynamoDB manifest is missing: $marker"
    }
  }
  if ($localDocs.Contains('port: 443', [System.StringComparison]::Ordinal)) {
    throw 'Local profile must not render Order API HTTPS egress.'
  }

  $negativeCases = @(
    @('--set-string', 'workloads.frontend.image.tag=latest'),
    @('--set-string', 'workloads.frontend.image.tag='),
    @('--set-string', 'workloads.catalog-api.port=80'),
    @('--set-string', 'workloads.order-api.resources.limits.memory=invalid')
  )

  foreach ($arguments in $negativeCases) {
    $output = & helm template invalid $root @arguments 2>&1
    if ($LASTEXITCODE -eq 0) {
      throw "Expected schema rejection for: $($arguments -join ' ')"
    }
  }

  Write-Host 'Chart lint, render, schema-negative, manifest, and GitOps tests passed.'
}
finally {
  Remove-Item -LiteralPath $rendered -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $domainRendered -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $localRendered -Force -ErrorAction SilentlyContinue
}
