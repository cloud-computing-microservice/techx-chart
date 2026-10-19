$ErrorActionPreference = 'Stop'
$cleanupTest = @{ calls = [Collections.Generic.List[object]]::new(); failHelm = $false }
function helm {
  $cleanupTest.calls.Add(@{ tool = 'helm'; arguments = @($args) })
  $global:LASTEXITCODE = if ($cleanupTest.failHelm) { 1 } else { 0 }
}
function kubectl {
  $cleanupTest.calls.Add(@{ tool = 'kubectl'; arguments = @($args) })
  $global:LASTEXITCODE = 0
}
function minikube {
  $cleanupTest.calls.Add(@{ tool = 'minikube'; arguments = @($args) })
  $global:LASTEXITCODE = 0
}
& (Join-Path $PSScriptRoot 'local-k8s.ps1') -Action Cleanup -Profile techx-local-regression
if ($cleanupTest.calls.Count -ne 4) { throw 'Local cleanup did not execute the expected four scoped operations.' }
foreach ($call in $cleanupTest.calls) {
  $contextFlag = switch ($call.tool) { helm { '--kube-context' } kubectl { '--context' } minikube { '--profile' } }
  $index = [array]::IndexOf($call.arguments, $contextFlag)
  if ($index -lt 0 -or $call.arguments[$index + 1] -ne 'techx-local-regression') { throw "Unscoped local cleanup command: $($call.tool)" }
}
$cleanupTest.calls.Clear()
$cleanupTest.failHelm = $true
$rejected = $false
try { & (Join-Path $PSScriptRoot 'local-k8s.ps1') -Action Cleanup } catch { $rejected = $_ -match 'uninstall' }
if (-not $rejected -or $cleanupTest.calls.Count -ne 1) { throw 'Cleanup must stop before namespace removal when Helm fails.' }
Write-Host 'Local cleanup context isolation and failure regression tests passed (all commands mocked).'
