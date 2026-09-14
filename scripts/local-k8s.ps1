param(
  [ValidateSet('Test', 'Cleanup')]
  [string]$Action = 'Test',
  [string]$Profile = 'techx-local',
  [string]$DiagnosticLog = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$namespace = 'techx-staging'
$dynamoNamespace = 'techx-local-dependencies'
$dynamoService = 'dynamodb-local'
$dynamoPod = 'dynamodb-local-0'
$dynamoImage = 'amazon/dynamodb-local:2.6.1'
$awsCliImage = 'amazon/aws-cli:2.17.50'

function Write-Diagnostic([string]$Message) {
  if ($DiagnosticLog) { "$(Get-Date -Format o) $Message" | Add-Content -LiteralPath $DiagnosticLog -Encoding utf8 }
}

function Assert-PodHttpAllowed {
  param([Parameter(Mandatory)][string]$Deployment, [Parameter(Mandatory)][string]$Url)
  kubectl --context $Profile --namespace $namespace exec "deployment/$Deployment" -- node -e "fetch('$Url',{signal:AbortSignal.timeout(4000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
  if ($LASTEXITCODE -ne 0) { throw "Expected $Deployment to reach $Url." }
}

function Assert-PodHttpDenied {
  param([Parameter(Mandatory)][string]$Deployment, [Parameter(Mandatory)][string]$Url)
  kubectl --context $Profile --namespace $namespace exec "deployment/$Deployment" -- node -e "fetch('$Url',{signal:AbortSignal.timeout(3000)}).then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>$null
  if ($LASTEXITCODE -eq 0) { throw "NetworkPolicy unexpectedly allowed $Deployment to reach $Url." }
}

if ($Action -eq 'Cleanup') {
  helm uninstall techx --namespace $namespace --ignore-not-found
  kubectl delete namespace $namespace --ignore-not-found --wait=true --timeout=120s
  kubectl delete namespace $dynamoNamespace --ignore-not-found --wait=true --timeout=120s
  minikube delete --profile $Profile
  exit 0
}

$status = minikube status --profile $Profile --output=json 2>$null | ConvertFrom-Json
if (-not $status -or $status.Host -ne 'Running') {
  minikube start --profile $Profile --driver=docker --cni=calico --kubernetes-version=v1.35.0 --cpus=2 --memory=4096
}
Write-Diagnostic 'cluster-ready'

kubectl --context "${Profile}" create namespace $namespace --dry-run=client -o yaml | kubectl --context "${Profile}" apply -f -
kubectl --context "${Profile}" create namespace $dynamoNamespace --dry-run=client -o yaml | kubectl --context "${Profile}" apply -f -
kubectl --context "${Profile}" label namespace $namespace pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted --overwrite
kubectl --context "${Profile}" create secret generic techx-staging-secrets --namespace $namespace --from-literal=order-api-key='local-k8s-demo-key' --dry-run=client -o yaml | kubectl --context "${Profile}" apply -f -

@"
apiVersion: v1
kind: Service
metadata:
  name: $dynamoService
  namespace: $dynamoNamespace
spec:
  selector:
    app: $dynamoService
  ports:
    - name: http
      port: 8000
      targetPort: 8000
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $dynamoService
  namespace: $dynamoNamespace
spec:
  serviceName: $dynamoService
  replicas: 1
  selector:
    matchLabels:
      app: $dynamoService
  template:
    metadata:
      labels:
        app: $dynamoService
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10000
        runAsGroup: 10000
        fsGroup: 10000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: dynamodb-local
          image: $dynamoImage
          args: ["-jar", "DynamoDBLocal.jar", "-sharedDb", "-inMemory"]
          ports:
            - containerPort: 8000
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
"@ | kubectl --context $Profile apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Failed to create DynamoDB Local.' }
kubectl --context $Profile --namespace $dynamoNamespace rollout status statefulset/$dynamoService --timeout=180s
if ($LASTEXITCODE -ne 0) { throw 'DynamoDB Local did not become ready.' }
kubectl --context $Profile --namespace $dynamoNamespace run dynamodb-bootstrap --rm --attach --restart=Never --image=$awsCliImage --env=AWS_ACCESS_KEY_ID=local --env=AWS_SECRET_ACCESS_KEY=local --env=AWS_DEFAULT_REGION=us-east-1 -- aws dynamodb create-table --endpoint-url "http://${dynamoService}:8000" --table-name techx-orders-local --attribute-definitions AttributeName=pk,AttributeType=S --key-schema AttributeName=pk,KeyType=HASH --billing-mode PAY_PER_REQUEST
if ($LASTEXITCODE -ne 0) { throw 'Failed to bootstrap the local DynamoDB table.' }
kubectl --context $Profile --namespace $dynamoNamespace run dynamodb-ttl-bootstrap --rm --attach --restart=Never --image=$awsCliImage --env=AWS_ACCESS_KEY_ID=local --env=AWS_SECRET_ACCESS_KEY=local --env=AWS_DEFAULT_REGION=us-east-1 -- aws dynamodb update-time-to-live --endpoint-url "http://${dynamoService}:8000" --table-name techx-orders-local --time-to-live-specification Enabled=true,AttributeName=ttlEpochSeconds
if ($LASTEXITCODE -ne 0) { throw 'Failed to enable TTL on the local DynamoDB table.' }
Write-Diagnostic 'namespace-secret-dynamodb-ready'

foreach ($image in @('techx/frontend:local', 'techx/catalog:local', 'techx/order:local')) {
  if (-not (docker image inspect $image 2>$null)) {
    throw "Missing local image $image. Complete Phase 4 image build first."
  }
  $loadedImages = minikube image ls --profile $Profile
  if ($loadedImages -notcontains "docker.io/$image") {
    minikube image load $image --profile $Profile
    if ($LASTEXITCODE -ne 0) { throw "Failed to load $image into Minikube." }
  }
}
Write-Diagnostic 'images-ready'

helm upgrade --install techx $root --namespace $namespace -f (Join-Path $root 'values-local.yaml') --kube-context $Profile --atomic --wait --timeout 5m
kubectl --context $Profile --namespace $namespace wait --for=condition=Available deployment --all --timeout=180s
Write-Diagnostic 'helm-ready'

$forwardLog = Join-Path ([System.IO.Path]::GetTempPath()) "techx-port-forward-$PID.log"
$forward = Start-Process kubectl -ArgumentList @('--context', $Profile, '--namespace', $namespace, 'port-forward', 'service/frontend', '18080:3000') -WindowStyle Hidden -PassThru -RedirectStandardOutput $forwardLog -RedirectStandardError "$forwardLog.err"
try {
  $ready = $false
  foreach ($attempt in 1..30) {
    try {
      $health = Invoke-RestMethod -Uri 'http://127.0.0.1:18080/healthz' -TimeoutSec 2
      if ($health.status -eq 'ok') { $ready = $true; break }
    }
    catch { Start-Sleep -Milliseconds 500 }
  }
  if (-not $ready) { throw 'Frontend port-forward did not become ready.' }
  Write-Diagnostic 'port-forward-ready'

  $products = Invoke-RestMethod -Uri 'http://127.0.0.1:18080/api/products' -TimeoutSec 10
  $product = if ($products.products) { $products.products[0] } else { $products[0] }
  if (-not $product.id) { throw 'Catalog response contained no product.' }
  $body = @{
    items = @(@{ productId = $product.id; quantity = 1 })
    customer = @{ name = 'Local Kubernetes'; email = 'local-k8s@example.com' }
    shippingAddress = @{
      line1 = '100 Kubernetes Street'
      city = 'Seattle'
      region = 'WA'
      postalCode = '98101'
      countryCode = 'US'
    }
    shippingMethod = 'standard'
  } | ConvertTo-Json -Depth 6
  $order = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:18080/api/orders' -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = "local-k8s-$PID" } -Body $body -TimeoutSec 10
  if (-not $order.order.id) { throw 'Order response contained no order ID.' }
  Write-Diagnostic 'business-flow-ready'

  Assert-PodHttpAllowed -Deployment 'frontend' -Url 'http://catalog-api:3001/healthz'
  Assert-PodHttpAllowed -Deployment 'frontend' -Url 'http://order-api:3002/healthz'
  Assert-PodHttpAllowed -Deployment 'order-api' -Url 'http://catalog-api:3001/healthz'
  Assert-PodHttpDenied -Deployment 'catalog-api' -Url 'http://order-api:3002/healthz'
  Assert-PodHttpDenied -Deployment 'order-api' -Url 'http://frontend:3000/healthz'
  Assert-PodHttpDenied -Deployment 'frontend' -Url 'http://example.com/'
  Write-Diagnostic 'workload-network-matrix-ready'

  $denyPodOverrides = @{
    apiVersion = 'v1'
    spec = @{
      securityContext = @{ seccompProfile = @{ type = 'RuntimeDefault' } }
      containers = @(@{
        name = 'network-deny-check'
        image = 'techx/frontend:local'
        imagePullPolicy = 'Never'
        securityContext = @{
          allowPrivilegeEscalation = $false
          capabilities = @{ drop = @('ALL') }
          runAsNonRoot = $true
        }
      })
    }
  } | ConvertTo-Json -Depth 8 -Compress
  kubectl --context $Profile --namespace $namespace run network-deny-check --image=techx/frontend:local --image-pull-policy=Never --restart=Never --overrides=$denyPodOverrides --command -- node -e 'setTimeout(() => {}, 300000)'
  if ($LASTEXITCODE -ne 0) { throw 'Failed to create the restricted untrusted NetworkPolicy test pod.' }
  kubectl --context $Profile --namespace $namespace wait --for=condition=Ready pod/network-deny-check --timeout=120s
  if ($LASTEXITCODE -ne 0) { throw 'The untrusted NetworkPolicy test pod did not become Ready.' }
  foreach ($url in @('http://frontend:3000/healthz', 'http://catalog-api:3001/healthz', 'http://order-api:3002/healthz')) {
    kubectl --context $Profile --namespace $namespace exec network-deny-check -- node -e "fetch('$url',{signal:AbortSignal.timeout(3000)}).then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>$null
    if ($LASTEXITCODE -eq 0) { throw "NetworkPolicy unexpectedly allowed untrusted pod to reach $url." }
  }
  Write-Diagnostic 'untrusted-network-deny-ready'

  kubectl --context $Profile --namespace $namespace rollout restart deployment/catalog-api
  kubectl --context $Profile --namespace $namespace rollout status deployment/catalog-api --timeout=180s
  $productsAfterRestart = Invoke-RestMethod -Uri 'http://127.0.0.1:18080/api/products' -TimeoutSec 10
  if (-not $productsAfterRestart) { throw 'Business flow did not recover after Catalog rollout.' }

  foreach ($deployment in @('order-api', 'frontend')) {
    kubectl --context $Profile --namespace $namespace rollout restart "deployment/$deployment"
    kubectl --context $Profile --namespace $namespace rollout status "deployment/$deployment" --timeout=180s
    $healthAfterRestart = Invoke-RestMethod -Uri 'http://127.0.0.1:18080/healthz' -TimeoutSec 10
    if ($healthAfterRestart.status -ne 'ok') { throw "Frontend did not recover after $deployment rollout." }
  }
  $persistedOrder = Invoke-RestMethod -Uri "http://127.0.0.1:18080/api/orders/$($order.order.id)" -TimeoutSec 10
  if ($persistedOrder.order.id -ne $order.order.id) { throw 'Order did not survive the Order API rollout.' }
  $replay = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:18080/api/orders' -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = "local-k8s-$PID" } -Body $body -TimeoutSec 10
  if ($replay.order.id -ne $order.order.id -or -not $replay.idempotentReplay) { throw 'Idempotency replay did not survive the Order API rollout.' }
  Write-Diagnostic 'rollouts-persistence-ready'

  helm upgrade techx $root --namespace $namespace -f (Join-Path $root 'values-local.yaml') --set global.minReadySeconds=6 --kube-context $Profile --atomic --wait --timeout 5m
  if ($LASTEXITCODE -ne 0) { throw 'Helm upgrade failed.' }
  helm rollback techx 1 --namespace $namespace --kube-context $Profile --wait --timeout 5m
  if ($LASTEXITCODE -ne 0) { throw 'Helm rollback failed.' }
  Write-Diagnostic 'upgrade-rollback-ready'

  $pods = kubectl --context $Profile --namespace $namespace get pods -l app.kubernetes.io/instance=techx -o json | ConvertFrom-Json
  foreach ($pod in $pods.items) {
    foreach ($status in $pod.status.containerStatuses) {
      if ($status.restartCount -ne 0) { throw "$($pod.metadata.name) restarted unexpectedly during resource smoke test." }
      if ($status.lastState.terminated.reason -eq 'OOMKilled') { throw "$($pod.metadata.name) was OOMKilled." }
    }
  }
  Write-Diagnostic 'resource-smoke-ready'

  Write-Host "Local Kubernetes E2E passed with order $($order.order.id); DynamoDB-backed lookup/replay survived the Order API restart, and the full allow/deny matrix, upgrade/rollback, probes, Secret, and no-restart/OOM resource smoke were verified."
}
catch {
  Write-Diagnostic "ERROR: $($_.Exception.Message) at $($_.ScriptStackTrace)"
  throw
}
finally {
  if ($forward -and -not $forward.HasExited) { Stop-Process -Id $forward.Id -Force }
  kubectl --context $Profile --namespace $namespace delete pod network-deny-check --ignore-not-found --wait=false 2>$null
  Remove-Item -LiteralPath $forwardLog, "$forwardLog.err" -Force -ErrorAction SilentlyContinue
  helm uninstall techx --namespace $namespace --kube-context $Profile --ignore-not-found
  kubectl --context $Profile delete namespace $namespace --ignore-not-found --wait=true --timeout=120s
  kubectl --context $Profile delete namespace $dynamoNamespace --ignore-not-found --wait=true --timeout=120s
  Write-Diagnostic "cleanup-complete lastExit=$LASTEXITCODE"
}
