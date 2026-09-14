param(
  [ValidateSet('Baseline', 'Resilience', 'SelfHeal', 'WaitRevision')]
  [string]$Action = 'Baseline',
  [ValidateSet('baseline', 'domainVpn')]
  [string]$ExposureProfile = 'baseline',
  [ValidateSet('Public', 'Private')]
  [string]$NetworkView = 'Public',
  [string]$PublicUrl = '',
  [string]$ExpectedRevision = '',
  [string]$ExpectedImageTag = '',
  [string]$Context = '',
  [string]$Region = 'us-east-1',
  [string]$Namespace = 'techx-staging',
  [string]$Application = 'techx-staging',
  [int]$TimeoutSeconds = 360
)

$ErrorActionPreference = 'Stop'
$kubectlContext = if ($Context) { @('--context', $Context) } else { @() }

function Invoke-KubectlJson([string[]]$Arguments) {
  $raw = & kubectl @kubectlContext @Arguments -o json
  if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($Arguments -join ' ')" }
  return $raw | ConvertFrom-Json
}

function Invoke-AwsJson([string[]]$Arguments) {
  $raw = & aws @Arguments --region $Region --output json
  if ($LASTEXITCODE -ne 0) { throw "aws failed: $($Arguments -join ' ')" }
  return $raw | ConvertFrom-Json
}

function Assert-UrlContract {
  if (-not $PublicUrl) { throw 'PublicUrl is required.' }
  $uri = [uri]$PublicUrl
  if ($ExposureProfile -eq 'baseline' -and $uri.Scheme -ne 'http') {
    throw 'The baseline profile requires the approved temporary HTTP ALB URL.'
  }
  if ($ExposureProfile -eq 'domainVpn' -and $uri.Scheme -ne 'https') {
    throw 'The domainVpn profile requires an HTTPS custom-domain URL.'
  }
  if ($ExposureProfile -eq 'domainVpn' -and $uri.Host -ne 'shop.dinhminhkhoa.id.vn') {
    throw "The domainVpn URL must use shop.dinhminhkhoa.id.vn, received '$($uri.Host)'."
  }
}

function Assert-DomainVpnExposure {
  $publicHost = ([uri]$PublicUrl).Host
  $frontendIngress = Invoke-KubectlJson @('-n', $Namespace, 'get', 'ingress', 'frontend')
  $argoIngresses = Invoke-KubectlJson @('-n', 'argocd', 'get', 'ingresses')
  if ($argoIngresses.items.Count -ne 1) { throw "Expected one Argo CD Ingress, found $($argoIngresses.items.Count)." }
  $argoIngress = $argoIngresses.items[0]

  foreach ($ingress in @($frontendIngress, $argoIngress)) {
    if ($ingress.metadata.annotations.'alb.ingress.kubernetes.io/group.name' -ne 'techx-private') {
      throw "$($ingress.metadata.namespace)/$($ingress.metadata.name) is not in the techx-private IngressGroup."
    }
  }
  if ($argoIngress.metadata.annotations.'alb.ingress.kubernetes.io/group.order' -ne '10' -or
      $frontendIngress.metadata.annotations.'alb.ingress.kubernetes.io/group.order' -ne '20') {
    throw 'Argo CD must have group order 10 before the frontend catch-all order 20.'
  }
  $frontendBackends = @($frontendIngress.spec.rules.http.paths.backend.service.name | Sort-Object -Unique)
  if (($frontendBackends -join ',') -ne 'frontend') { throw 'The workload Ingress must expose only frontend.' }
  $argoBackends = @($argoIngress.spec.rules.http.paths.backend.service.name | Sort-Object -Unique)
  if ($argoBackends -notcontains 'argocd-server') { throw 'The private Ingress does not route /argocd to argocd-server.' }

  $frontendAlbHost = [string]$frontendIngress.status.loadBalancer.ingress[0].hostname
  $argoAlbHost = [string]$argoIngress.status.loadBalancer.ingress[0].hostname
  if (-not $frontendAlbHost -or $frontendAlbHost -ne $argoAlbHost) {
    throw 'Frontend and Argo CD do not share exactly one ALB.'
  }
  $loadBalancers = Invoke-AwsJson @('elbv2', 'describe-load-balancers')
  $loadBalancer = @($loadBalancers.LoadBalancers | Where-Object { $_.DNSName -eq $frontendAlbHost })
  if ($loadBalancer.Count -ne 1 -or $loadBalancer[0].Scheme -ne 'internal' -or $loadBalancer[0].State.Code -ne 'active') {
    throw 'The shared IngressGroup does not resolve to one active internal ALB.'
  }
  $listeners = Invoke-AwsJson @('elbv2', 'describe-listeners', '--load-balancer-arn', $loadBalancer[0].LoadBalancerArn)
  $listenerContract = @($listeners.Listeners | ForEach-Object { "$($_.Protocol):$($_.Port)" } | Sort-Object)
  if (($listenerContract -join ',') -ne 'HTTP:80,HTTPS:443') {
    throw "The internal ALB listener contract is invalid: $($listenerContract -join ', ')."
  }
  $targetGroups = Invoke-AwsJson @('elbv2', 'describe-target-groups', '--load-balancer-arn', $loadBalancer[0].LoadBalancerArn)
  if ($targetGroups.TargetGroups.Count -lt 2) { throw 'The shared ALB must have frontend and Argo CD target groups.' }
  foreach ($targetGroup in $targetGroups.TargetGroups) {
    $targetHealth = Invoke-AwsJson @('elbv2', 'describe-target-health', '--target-group-arn', $targetGroup.TargetGroupArn)
    if ($targetHealth.TargetHealthDescriptions.Count -lt 1 -or
        @($targetHealth.TargetHealthDescriptions | Where-Object { $_.TargetHealth.State -ne 'healthy' }).Count -gt 0) {
      throw "ALB target group $($targetGroup.TargetGroupName) is not fully healthy."
    }
  }

  $distributions = Invoke-AwsJson @('cloudfront', 'list-distributions')
  $distribution = @($distributions.DistributionList.Items | Where-Object { $_.Aliases.Items -contains $publicHost })
  if ($distribution.Count -ne 1 -or $distribution[0].Status -ne 'Deployed' -or -not $distribution[0].Enabled) {
    throw "Expected one enabled, Deployed CloudFront distribution for $publicHost."
  }
  $distributionConfig = Invoke-AwsJson @('cloudfront', 'get-distribution-config', '--id', $distribution[0].Id)
  if (-not $distributionConfig.DistributionConfig.Origins.Items[0].VpcOriginConfig.VpcOriginId) {
    throw 'CloudFront does not use a VPC origin.'
  }
  if ($distributionConfig.DistributionConfig.DefaultCacheBehavior.FunctionAssociations.Quantity -lt 1) {
    throw 'CloudFront has no viewer-request function to block the Argo CD path.'
  }

  $vpn = Invoke-AwsJson @('ec2', 'describe-client-vpn-endpoints')
  $endpoints = @($vpn.ClientVpnEndpoints | Where-Object { $_.Status.Code -eq 'available' -and $_.DnsName })
  if ($endpoints.Count -ne 1) { throw "Expected one available Client VPN endpoint, found $($endpoints.Count)." }
  if (@($endpoints[0].DnsServers) -notcontains '10.52.0.2' -or -not $endpoints[0].SplitTunnel) {
    throw 'Client VPN must use split tunnel and the VPC resolver at 10.52.0.2.'
  }
  $associations = Invoke-AwsJson @('ec2', 'describe-client-vpn-target-networks', '--client-vpn-endpoint-id', $endpoints[0].ClientVpnEndpointId)
  if ($associations.ClientVpnTargetNetworks.Count -ne 1 -or $associations.ClientVpnTargetNetworks[0].Status.Code -ne 'associated') {
    throw 'Client VPN must have exactly one associated target network.'
  }
  $authorizations = Invoke-AwsJson @('ec2', 'describe-client-vpn-authorization-rules', '--client-vpn-endpoint-id', $endpoints[0].ClientVpnEndpointId)
  $vpcAuthorization = @($authorizations.AuthorizationRules | Where-Object {
      $_.DestinationCidr -eq '10.52.0.0/16' -and $_.AccessAll -eq $true -and $_.Status.Code -eq 'active'
    })
  if ($vpcAuthorization.Count -ne 1) { throw 'Client VPN does not have the expected active VPC authorization rule.' }
  $zones = Invoke-AwsJson @('route53', 'list-hosted-zones-by-name', '--dns-name', $publicHost)
  $privateZones = @($zones.HostedZones | Where-Object {
      $_.Name.TrimEnd('.') -eq $publicHost -and $_.Config.PrivateZone -eq $true
    })
  if ($privateZones.Count -ne 1) { throw "Expected one private hosted zone for $publicHost." }

  if ($NetworkView -eq 'Public') {
    $resolved = @(Resolve-DnsName -Name $publicHost -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
    if ($resolved.Count -lt 1 -or @($resolved | Where-Object { $_ -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' }).Count -gt 0) {
      throw "Public DNS unexpectedly returned a private address: $($resolved -join ', ')."
    }
    foreach ($path in @('/argocd', '/argocd/', '/argocd/api/v1/session?probe=1')) {
      $blocked = Invoke-WebRequest -Uri "https://$publicHost$path" -TimeoutSec 15 -SkipHttpErrorCheck
      if ($blocked.StatusCode -ne 403) { throw "Public $path returned $($blocked.StatusCode), expected 403." }
    }
  }
  else {
    $resolved = @(Resolve-DnsName -Name $publicHost -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
    if ($resolved.Count -lt 1 -or @($resolved | Where-Object { $_ -notmatch '^10\.52\.' }).Count -gt 0) {
      throw "VPN split-view DNS did not return private VPC addresses: $($resolved -join ', ')."
    }
    $argo = Invoke-WebRequest -Uri "https://$publicHost/argocd/" -MaximumRedirection 0 -TimeoutSec 15 -SkipHttpErrorCheck
    if ($argo.StatusCode -notin @(200, 301, 302, 307, 308)) {
      throw "Private Argo CD path returned $($argo.StatusCode)."
    }
  }
}

function Get-Application {
  return Invoke-KubectlJson @('-n', 'argocd', 'get', 'application', $Application)
}

function Assert-ArgoHealthy([object]$App) {
  if ($App.status.sync.status -ne 'Synced' -or $App.status.health.status -ne 'Healthy') {
    throw "Argo CD is $($App.status.sync.status)/$($App.status.health.status), expected Synced/Healthy."
  }
}

function Wait-Argo([string]$RevisionPrefix = '') {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $app = Get-Application
    $revisionMatches = -not $RevisionPrefix -or ([string]$app.status.sync.revision).StartsWith($RevisionPrefix)
    if ($app.status.sync.status -eq 'Synced' -and $app.status.health.status -eq 'Healthy' -and $revisionMatches) {
      return $app
    }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $deadline)
  throw "Argo CD did not converge to Synced/Healthy revision '$RevisionPrefix' within $TimeoutSeconds seconds."
}

function Assert-ImageTag([string]$Tag) {
  if (-not $Tag) { return }
  $deployments = Invoke-KubectlJson @('-n', $Namespace, 'get', 'deployments')
  foreach ($deployment in $deployments.items) {
    $images = @($deployment.spec.template.spec.containers.image)
    if ($images.Count -ne 1 -or $images[0] -notmatch ":$([regex]::Escape($Tag))$") {
      throw "$($deployment.metadata.name) does not run expected immutable tag $Tag."
    }
  }
}

function Assert-EcrArtifacts([string]$Tag) {
  if (-not $Tag) { return }
  $deployments = Invoke-KubectlJson @('-n', $Namespace, 'get', 'deployments')
  foreach ($deployment in $deployments.items) {
    $image = [string]$deployment.spec.template.spec.containers[0].image
    if ($image -notmatch '^[0-9]+\.dkr\.ecr\.[^.]+\.amazonaws\.com/([^:]+):(.+)$') {
      throw "$($deployment.metadata.name) does not use an ECR tag reference."
    }
    $repository = $Matches[1]
    $actualTag = $Matches[2]
    if ($actualTag -ne $Tag) { throw "$($deployment.metadata.name) tag $actualTag does not match $Tag." }
    $repositoryDetails = Invoke-AwsJson @('ecr', 'describe-repositories', '--repository-names', $repository)
    if ($repositoryDetails.repositories.Count -ne 1 -or $repositoryDetails.repositories[0].imageTagMutability -ne 'IMMUTABLE') {
      throw "ECR repository $repository is not immutable."
    }
    $details = Invoke-AwsJson @('ecr', 'describe-images', '--repository-name', $repository, '--image-ids', "imageTag=$Tag")
    if ($details.imageDetails.Count -ne 1 -or -not $details.imageDetails[0].imageDigest) {
      throw "ECR did not return one immutable digest for ${repository}:$Tag."
    }
    $digest = [string]$details.imageDetails[0].imageDigest
    $scan = Invoke-AwsJson @('ecr', 'describe-image-scan-findings', '--repository-name', $repository, '--image-id', "imageTag=$Tag")
    if ($scan.imageScanStatus.status -ne 'COMPLETE' -or [int]($scan.imageScanFindings.findingSeverityCounts.CRITICAL ?? 0) -ne 0) {
      throw "ECR scan is not COMPLETE with zero CRITICAL findings for ${repository}:$Tag."
    }
    $pods = Invoke-KubectlJson @('-n', $Namespace, 'get', 'pods', '-l', "app.kubernetes.io/component=$($deployment.metadata.name)")
    $imageIds = @($pods.items.status.containerStatuses.imageID)
    if ($imageIds.Count -lt 1 -or @($imageIds | Where-Object { $_ -notmatch '@sha256:[0-9a-f]{64}$' }).Count -gt 0) {
      throw "$($deployment.metadata.name) did not report immutable runtime image IDs."
    }
    Write-Host "$($deployment.metadata.name) artifact verified: ${repository}:$Tag ECR=$digest runtime=$($imageIds -join ',')"
  }
}

function Wait-Deployment([string]$Name) {
  & kubectl @kubectlContext -n $Namespace wait --for=condition=Available "deployment/$Name" --timeout="${TimeoutSeconds}s"
  if ($LASTEXITCODE -ne 0) { throw "$Name did not become Available." }
}

function Wait-NewReadyPod([string]$Selector, [string]$PreviousName) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $podList = Invoke-KubectlJson @('-n', $Namespace, 'get', 'pods', '-l', $Selector)
    foreach ($pod in $podList.items) {
      $ready = @($pod.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 1
      if ($pod.metadata.name -ne $PreviousName -and $ready) { return $pod.metadata.name }
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "No replacement Ready pod appeared for selector '$Selector'."
}

function Get-PublicOrderFixture([string]$Url) {
  $catalog = Invoke-RestMethod -Uri "$($Url.TrimEnd('/'))/api/products" -TimeoutSec 15
  $product = $catalog.products | Where-Object { $_.availability -ne 'out_of_stock' } | Select-Object -First 1
  if (-not $product.id) { throw 'Public Catalog returned no orderable product.' }
  return @{
    items = @(@{ productId = $product.id; quantity = 1 })
    customer = @{ name = 'AWS Acceptance'; email = 'aws-acceptance@example.com' }
    shippingAddress = @{
      line1 = '100 Acceptance Street'
      city = 'Seattle'
      region = 'WA'
      postalCode = '98101'
      countryCode = 'US'
    }
    shippingMethod = 'standard'
  } | ConvertTo-Json -Depth 6 -Compress
}

function Assert-PodHttp([string]$Deployment, [string]$Url, [bool]$Allowed) {
  & kubectl @kubectlContext -n $Namespace exec "deployment/$Deployment" -- node -e "fetch('$Url',{signal:AbortSignal.timeout(4000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>$null
  $succeeded = $LASTEXITCODE -eq 0
  if ($succeeded -ne $Allowed) {
    $expectation = if ($Allowed) { 'reach' } else { 'be denied from' }
    throw "Expected $Deployment to $expectation $Url."
  }
}

if ($Action -eq 'Baseline') {
  Assert-UrlContract
  $app = Wait-Argo
  Assert-ArgoHealthy $app

  $namespaceObject = Invoke-KubectlJson @('get', 'namespace', $Namespace)
  foreach ($mode in @('enforce', 'warn', 'audit')) {
    if ($namespaceObject.metadata.labels."pod-security.kubernetes.io/$mode" -ne 'restricted') {
      throw "Namespace Pod Security $mode is not restricted."
    }
  }

  $deployments = Invoke-KubectlJson @('-n', $Namespace, 'get', 'deployments')
  $names = @($deployments.items.metadata.name | Sort-Object)
  if (($names -join ',') -ne 'catalog-api,frontend,order-api') {
    throw "Unexpected deployment set: $($names -join ', ')."
  }
  foreach ($deployment in $deployments.items) {
    if ($deployment.status.availableReplicas -ne 1 -or $deployment.status.readyReplicas -ne 1) {
      throw "$($deployment.metadata.name) is not exactly one ready/available replica."
    }
  }
  $nodes = Invoke-KubectlJson @('get', 'nodes')
  if ($nodes.items.Count -ne 1 -or $nodes.items[0].status.nodeInfo.operatingSystem -ne 'linux' -or
      $nodes.items[0].status.nodeInfo.architecture -ne 'amd64') {
    throw 'The scoped staging environment must run on exactly one linux/amd64 node.'
  }
  foreach ($deployment in $deployments.items) {
    $pods = Invoke-KubectlJson @('-n', $Namespace, 'get', 'pods', '-l', "app.kubernetes.io/component=$($deployment.metadata.name)")
    if ($pods.items.Count -ne 1) { throw "$($deployment.metadata.name) does not own exactly one pod." }
    foreach ($pod in $pods.items) {
      if ($pod.spec.securityContext.runAsNonRoot -ne $true -or $pod.spec.securityContext.seccompProfile.type -ne 'RuntimeDefault') {
        throw "$($pod.metadata.name) does not use the required pod security context."
      }
      foreach ($container in $pod.spec.containers) {
        if ($container.securityContext.allowPrivilegeEscalation -ne $false -or
            $container.securityContext.readOnlyRootFilesystem -ne $true -or
            $container.securityContext.capabilities.drop -notcontains 'ALL') {
          throw "$($pod.metadata.name)/$($container.name) is not runtime hardened."
        }
      }
    }
  }

  $services = Invoke-KubectlJson @('-n', $Namespace, 'get', 'services')
  foreach ($service in $services.items) {
    if ($service.spec.type -ne 'ClusterIP') { throw "$($service.metadata.name) is publicly typed as $($service.spec.type)." }
  }
  if ($ExposureProfile -eq 'domainVpn') {
    Assert-DomainVpnExposure
  }
  else {
    $ingresses = Invoke-KubectlJson @('-n', $Namespace, 'get', 'ingresses')
    if ($ingresses.items.Count -ne 1) { throw "Expected one Ingress, found $($ingresses.items.Count)." }
    $backends = @($ingresses.items[0].spec.rules.http.paths.backend.service.name | Sort-Object -Unique)
    if (($backends -join ',') -ne 'frontend') { throw "Ingress exposes unexpected backend(s): $($backends -join ', ')." }
    $ingressHost = [string]$ingresses.items[0].status.loadBalancer.ingress[0].hostname
    $publicHost = ([uri]$PublicUrl).Host
    if (-not $ingressHost -or $ingressHost -ne $publicHost) {
      throw "PublicUrl host '$publicHost' does not match Ingress host '$ingressHost'."
    }
    $loadBalancers = Invoke-AwsJson @('elbv2', 'describe-load-balancers')
    $loadBalancer = @($loadBalancers.LoadBalancers | Where-Object { $_.DNSName -eq $ingressHost })
    if ($loadBalancer.Count -ne 1 -or $loadBalancer[0].Scheme -ne 'internet-facing' -or $loadBalancer[0].State.Code -ne 'active') {
      throw 'Ingress does not resolve to exactly one active internet-facing ALB.'
    }
    $listeners = Invoke-AwsJson @('elbv2', 'describe-listeners', '--load-balancer-arn', $loadBalancer[0].LoadBalancerArn)
    if ($listeners.Listeners.Count -ne 1 -or $listeners.Listeners[0].Port -ne 80 -or $listeners.Listeners[0].Protocol -ne 'HTTP') {
      throw 'The public ALB must have exactly one HTTP:80 listener.'
    }
    $targetGroups = Invoke-AwsJson @('elbv2', 'describe-target-groups', '--load-balancer-arn', $loadBalancer[0].LoadBalancerArn)
    if ($targetGroups.TargetGroups.Count -ne 1) { throw 'The public ALB must have exactly one target group.' }
    $targetHealth = Invoke-AwsJson @('elbv2', 'describe-target-health', '--target-group-arn', $targetGroups.TargetGroups[0].TargetGroupArn)
    if ($targetHealth.TargetHealthDescriptions.Count -lt 1 -or
        @($targetHealth.TargetHealthDescriptions | Where-Object { $_.TargetHealth.State -ne 'healthy' }).Count -gt 0) {
      throw 'The frontend ALB target group is not fully healthy.'
    }
  }

  $response = Invoke-WebRequest -Uri $PublicUrl -TimeoutSec 15
  if ($response.StatusCode -ne 200) { throw "Public frontend returned $($response.StatusCode)." }
  foreach ($header in @('Content-Security-Policy', 'Permissions-Policy', 'Referrer-Policy', 'X-Content-Type-Options')) {
    if (-not $response.Headers[$header]) { throw "Public response is missing $header." }
  }

  $requestId = "phase9-$([guid]::NewGuid())"
  $catalogResponse = Invoke-WebRequest -Uri "$($PublicUrl.TrimEnd('/'))/api/products" -Headers @{ 'x-request-id' = $requestId } -TimeoutSec 15
  if ($catalogResponse.StatusCode -ne 200 -or $catalogResponse.Headers['x-request-id'] -ne $requestId) {
    throw 'Public Catalog request did not preserve the request ID.'
  }
  Start-Sleep -Seconds 2
  $catalogLogs = & kubectl @kubectlContext -n $Namespace logs deployment/catalog-api --since=2m
  if ($LASTEXITCODE -ne 0 -or ($catalogLogs -join "`n") -notmatch [regex]::Escape($requestId)) {
    throw 'Catalog logs did not contain the propagated request ID.'
  }

  $canAdmin = & kubectl @kubectlContext auth can-i '*' '*' --as="system:serviceaccount:${Namespace}:frontend" -n $Namespace
  # kubectl intentionally exits 1 when the authorization answer is "no".
  if (($canAdmin -join '').Trim() -ne 'no') {
    throw 'Frontend ServiceAccount unexpectedly has Kubernetes API permissions.'
  }
  Write-Host "Phase 9 AWS baseline passed at $(Get-Date -Format o); profile=$ExposureProfile; view=$NetworkView; revision=$($app.status.sync.revision); exposure and request-ID correlation verified."
  exit 0
}

if ($Action -eq 'Resilience') {
  Assert-UrlContract
  $app = Wait-Argo
  Assert-ArgoHealthy $app
  $baseUrl = $PublicUrl.TrimEnd('/')
  $body = Get-PublicOrderFixture $baseUrl
  $requestPrefix = "phase9-resilience-$([guid]::NewGuid())"
  $idempotencyKey = "phase9-double-$([guid]::NewGuid())"

  $doubleSubmit = 1..2 | ForEach-Object -Parallel {
    Invoke-WebRequest -Method Post -Uri "$using:baseUrl/api/orders" `
      -Headers @{ 'Idempotency-Key' = $using:idempotencyKey; 'x-request-id' = "$using:requestPrefix-$_" } `
      -ContentType 'application/json' -Body $using:body -TimeoutSec 15 -SkipHttpErrorCheck
  } -ThrottleLimit 2
  $doubleStatuses = @($doubleSubmit.StatusCode | Sort-Object)
  if (($doubleStatuses -join ',') -ne '200,201') {
    throw "AWS double-submit expected 200/201; received $($doubleStatuses -join ', ')."
  }
  $orders = @($doubleSubmit | ForEach-Object { ($_.Content | ConvertFrom-Json).order })
  if ($orders.Count -ne 2 -or $orders[0].id -ne $orders[1].id) {
    throw 'AWS double-submit did not converge to one order ID.'
  }
  $orderId = $orders[0].id

  Start-Sleep -Seconds 2
  $orderLogs = & kubectl @kubectlContext -n $Namespace logs deployment/order-api --since=2m
  if ($LASTEXITCODE -ne 0 -or ($orderLogs -join "`n") -notmatch [regex]::Escape($requestPrefix)) {
    throw 'Order logs did not contain the Phase 9 request-ID prefix.'
  }

  $burst = 1..25 | ForEach-Object -Parallel {
    Invoke-WebRequest -Method Post -Uri "$using:baseUrl/api/orders" `
      -Headers @{ 'Idempotency-Key' = "phase9-burst-$([guid]::NewGuid())" } `
      -ContentType 'application/json' -Body $using:body -TimeoutSec 15 -SkipHttpErrorCheck
  } -ThrottleLimit 10
  $unexpected = @($burst.StatusCode | Where-Object { $_ -notin @(201, 429) })
  if ($unexpected.Count -gt 0 -or @($burst.StatusCode | Where-Object { $_ -eq 429 }).Count -lt 1) {
    throw "AWS order burst did not produce only 201/429 with at least one 429: $($burst.StatusCode -join ', ')."
  }
  foreach ($path in @('/healthz', '/api/products')) {
    $healthy = Invoke-WebRequest -Uri "$baseUrl$path" -TimeoutSec 15
    if ($healthy.StatusCode -ne 200) { throw "$path failed after the controlled rate-limit burst." }
  }

  Assert-PodHttp 'frontend' 'http://catalog-api:3001/healthz' $true
  Assert-PodHttp 'frontend' 'http://order-api:3002/healthz' $true
  Assert-PodHttp 'order-api' 'http://catalog-api:3001/healthz' $true
  Assert-PodHttp 'catalog-api' 'http://order-api:3002/healthz' $false

  $frontend = Invoke-KubectlJson @('-n', $Namespace, 'get', 'deployment', 'frontend')
  $testImage = $frontend.spec.template.spec.containers[0].image
  $denyOverrides = @{
    apiVersion = 'v1'
    spec = @{
      securityContext = @{ runAsNonRoot = $true; seccompProfile = @{ type = 'RuntimeDefault' } }
      containers = @(@{
        name = 'network-deny-check'
        image = $testImage
        securityContext = @{
          allowPrivilegeEscalation = $false
          readOnlyRootFilesystem = $true
          capabilities = @{ drop = @('ALL') }
        }
      })
    }
  } | ConvertTo-Json -Depth 8 -Compress
  & kubectl @kubectlContext -n $Namespace delete pod phase9-network-deny --ignore-not-found --wait=false *> $null
  try {
    & kubectl @kubectlContext -n $Namespace run phase9-network-deny --image=$testImage --restart=Never --overrides=$denyOverrides --command -- node -e 'setTimeout(() => {}, 300000)'
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the restricted untrusted test pod.' }
    & kubectl @kubectlContext -n $Namespace wait --for=condition=Ready pod/phase9-network-deny --timeout="${TimeoutSeconds}s"
    if ($LASTEXITCODE -ne 0) { throw 'The restricted untrusted test pod did not become Ready.' }
    foreach ($url in @('http://catalog-api:3001/healthz', 'http://order-api:3002/healthz')) {
      & kubectl @kubectlContext -n $Namespace exec phase9-network-deny -- node -e "fetch('$url',{signal:AbortSignal.timeout(4000)}).then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>$null
      if ($LASTEXITCODE -eq 0) { throw "NetworkPolicy allowed the untrusted pod to reach $url." }
    }
  }
  finally {
    & kubectl @kubectlContext -n $Namespace delete pod phase9-network-deny --ignore-not-found --wait=false *> $null
  }

  & kubectl @kubectlContext -n $Namespace scale deployment/catalog-api --replicas=0
  if ($LASTEXITCODE -ne 0) { throw 'Could not introduce the controlled Catalog outage.' }
  $failure = $null
  $failureDeadline = (Get-Date).AddSeconds(30)
  do {
    $candidate = Invoke-WebRequest -Uri "$baseUrl/api/products" -TimeoutSec 15 -SkipHttpErrorCheck
    if ($candidate.StatusCode -eq 503) { $failure = $candidate; break }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $failureDeadline)
  & kubectl @kubectlContext -n argocd annotate application $Application argocd.argoproj.io/refresh=hard --overwrite *> $null
  $app = Wait-Argo
  Wait-Deployment 'catalog-api'
  if (-not $failure) { throw 'Controlled Catalog outage did not expose the expected bounded public 503.' }
  $recovered = Invoke-WebRequest -Uri "$baseUrl/api/products" -TimeoutSec 15
  if ($recovered.StatusCode -ne 200) { throw 'Catalog did not recover after Argo reconciliation.' }

  $oldOrderPod = (Invoke-KubectlJson @('-n', $Namespace, 'get', 'pods', '-l', 'app.kubernetes.io/component=order-api')).items[0].metadata.name
  & kubectl @kubectlContext -n $Namespace delete pod $oldOrderPod --wait=true --timeout="${TimeoutSeconds}s"
  if ($LASTEXITCODE -ne 0) { throw 'Could not restart the Order pod.' }
  $newOrderPod = Wait-NewReadyPod 'app.kubernetes.io/component=order-api' $oldOrderPod
  Wait-Deployment 'order-api'
  $lookup = Invoke-WebRequest -Uri "$baseUrl/api/orders/$orderId" -TimeoutSec 15 -SkipHttpErrorCheck
  $lookupBody = $lookup.Content | ConvertFrom-Json
  if ($lookup.StatusCode -ne 404 -or $lookupBody.error.code -ne 'ORDER_NOT_FOUND') {
    throw 'Order restart did not exhibit the documented in-memory ORDER_NOT_FOUND behavior.'
  }
  Write-Host "Phase 9 AWS resilience passed at $(Get-Date -Format o); double-submit, 429, request-ID, network allow/deny, Catalog 503/recovery, and Order restart verified."
  exit 0
}

if ($Action -eq 'SelfHeal') {
  $before = Wait-Argo
  Assert-ArgoHealthy $before
  & kubectl @kubectlContext -n $Namespace scale deployment/frontend --replicas=2
  if ($LASTEXITCODE -ne 0) { throw 'Could not introduce the controlled replica drift.' }
  & kubectl @kubectlContext -n argocd annotate application $Application argocd.argoproj.io/refresh=hard --overwrite
  if ($LASTEXITCODE -ne 0) { throw 'Could not request an Argo CD refresh.' }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $frontend = Invoke-KubectlJson @('-n', $Namespace, 'get', 'deployment', 'frontend')
    $app = Get-Application
    if ($frontend.spec.replicas -eq 1 -and $frontend.status.readyReplicas -eq 1 -and
        $app.status.sync.status -eq 'Synced' -and $app.status.health.status -eq 'Healthy') {
      Write-Host "Argo CD self-heal passed at $(Get-Date -Format o); controlled frontend replica drift converged 2 -> 1."
      exit 0
    }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $deadline)
  throw 'Argo CD did not self-heal frontend replicas back to one.'
}

if (-not $ExpectedRevision) { throw 'WaitRevision requires ExpectedRevision (full SHA or unique prefix).' }
$app = Wait-Argo $ExpectedRevision
Assert-ImageTag $ExpectedImageTag
Assert-EcrArtifacts $ExpectedImageTag
Write-Host "Argo CD revision gate passed at $(Get-Date -Format o); revision=$($app.status.sync.revision); imageTag=$ExpectedImageTag."
