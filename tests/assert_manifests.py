from __future__ import annotations

import collections
import pathlib
import sys

import yaml


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


rendered = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig")
profile = sys.argv[2] if len(sys.argv) > 2 else "baseline"
docs = [doc for doc in yaml.safe_load_all(rendered) if doc]
by_kind = collections.defaultdict(list)
for doc in docs:
    by_kind[doc["kind"]].append(doc)

require(len(by_kind["Deployment"]) == 3, "expected exactly three Deployments")
require(len(by_kind["Service"]) == 3, "expected exactly three Services")
require(len(by_kind["ServiceAccount"]) == 3, "expected exactly three ServiceAccounts")
require(len(by_kind["Ingress"]) == 1, "expected exactly one Ingress")
require(not by_kind["Secret"], "chart must not render a Secret")

expected = {"frontend", "catalog-api", "order-api"}
for kind in ("Deployment", "Service", "ServiceAccount"):
    require({item["metadata"]["name"] for item in by_kind[kind]} == expected, f"unexpected {kind} set")

for service in by_kind["Service"]:
    require(service["spec"]["type"] == "ClusterIP", "all Services must remain ClusterIP")

ingress = by_kind["Ingress"][0]
paths = ingress["spec"]["rules"][0]["http"]["paths"]
require(len(paths) == 1, "Ingress must expose one route")
require(paths[0]["path"] == "/", "Ingress must only expose the root prefix")
require(paths[0]["backend"]["service"]["name"] == "frontend", "Ingress must only target frontend")
require(ingress["spec"]["ingressClassName"] == "alb", "staging Ingress must use ALB")
annotations = ingress["metadata"]["annotations"]
if profile == "baseline":
    require(annotations["alb.ingress.kubernetes.io/scheme"] == "internet-facing", "baseline ALB must be public")
    require(annotations["alb.ingress.kubernetes.io/listen-ports"] == '[{"HTTP":80}]', "baseline listener mismatch")
else:
    require("alb.ingress.kubernetes.io/scheme" not in annotations, "Argo ingress must own the shared ALB scheme")
    require(annotations["alb.ingress.kubernetes.io/group.name"] == "techx-private", "shared IngressGroup mismatch")
    require(annotations["alb.ingress.kubernetes.io/group.order"] == "20", "frontend must follow the Argo path rule")
    require(annotations["alb.ingress.kubernetes.io/listen-ports"] == '[{"HTTP":80},{"HTTPS":443}]', "domain/VPN listeners mismatch")
    require("alb.ingress.kubernetes.io/inbound-cidrs" not in annotations, "domain/VPN ingress must not open a CIDR")

service_accounts = {item["metadata"]["name"]: item for item in by_kind["ServiceAccount"]}
role_annotation = "eks.amazonaws.com/role-arn"
expected_role = "arn:aws:iam::058114477594:role/techx-staging-order-api"
for name, service_account in service_accounts.items():
    expected_token = name == "order-api"
    require(service_account["automountServiceAccountToken"] is expected_token, f"{name} ServiceAccount token setting mismatch")
    annotations = service_account["metadata"].get("annotations", {})
    if name == "order-api":
        require(annotations.get(role_annotation) == expected_role, "Order API IRSA role mismatch")
        require(annotations.get("eks.amazonaws.com/sts-regional-endpoints") == "true", "Order API regional STS annotation missing")
    else:
        require(role_annotation not in annotations, f"{name} must not receive an IRSA role")

for deployment in by_kind["Deployment"]:
    name = deployment["metadata"]["name"]
    spec = deployment["spec"]
    pod = spec["template"]["spec"]
    container = pod["containers"][0]
    require(pod["automountServiceAccountToken"] is (name == "order-api"), f"{name} pod token setting mismatch")
    require(pod["securityContext"]["runAsNonRoot"] is True, f"{name} must run non-root")
    require(container["securityContext"]["readOnlyRootFilesystem"] is True, f"{name} root fs must be read-only")
    require(container["securityContext"]["capabilities"]["drop"] == ["ALL"], f"{name} must drop all capabilities")
    require(container["startupProbe"]["httpGet"]["path"] == "/healthz", f"{name} startup probe mismatch")
    require(container["livenessProbe"]["httpGet"]["path"] == "/healthz", f"{name} liveness probe mismatch")
    require(container["readinessProbe"]["httpGet"]["path"] == "/readyz", f"{name} readiness probe mismatch")
    require(container["resources"]["requests"] and container["resources"]["limits"], f"{name} resources missing")
    require(spec["strategy"]["type"] == ("Recreate" if name == "order-api" else "RollingUpdate"), f"{name} rollout strategy mismatch")
    env = {item["name"]: item.get("value") for item in container["env"] if "value" in item}
    if name == "order-api":
        expected_env = {
            "AWS_REGION": "us-east-1",
            "AWS_STS_REGIONAL_ENDPOINTS": "regional",
            "ORDER_TABLE_NAME": "techx-staging-orders",
            "ORDER_STORE_TTL_MS": "2592000000",
            "ORDER_IDEMPOTENCY_TTL_MS": "86400000",
        }
        for key, value in expected_env.items():
            require(env.get(key) == value, f"Order API {key} mismatch")
    for forbidden in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "DYNAMODB_ENDPOINT"):
        require(forbidden not in env, f"{name} must not configure {forbidden}")

policies = {item["metadata"]["name"]: item for item in by_kind["NetworkPolicy"]}
require(set(policies) == {"default-deny", "allow-dns", "frontend-ingress", "frontend-egress", "catalog-ingress", "order-ingress", "order-egress"}, "NetworkPolicy matrix mismatch")
order_egress = policies["order-egress"]["spec"]["egress"]
require(any(rule.get("ports") == [{"protocol": "TCP", "port": 443}] and "to" not in rule for rule in order_egress), "Order API HTTPS egress missing")
require(not any(port.get("port") == 8000 for rule in order_egress for port in rule.get("ports", [])), "AWS profile must not allow DynamoDB Local egress")
for policy_name in ("frontend-egress",):
    require(not any(port.get("port") == 443 for rule in policies[policy_name]["spec"]["egress"] for port in rule.get("ports", [])), f"{policy_name} must not allow HTTPS egress")
require("replace-with" not in rendered, "placeholder secret leaked into rendered YAML")
require("kind: LoadBalancer" not in rendered and "type: NodePort" not in rendered, "backend public endpoint rendered")

app_path = pathlib.Path(__file__).parents[1] / "gitops" / "clusters" / "staging" / "application.yaml"
app = yaml.safe_load(app_path.read_text(encoding="utf-8"))
require(app["metadata"]["name"] == "techx-staging", "Argo Application name mismatch")
require(app["spec"]["destination"]["namespace"] == "techx-staging", "Argo namespace mismatch")
require(app["spec"]["source"]["helm"]["valueFiles"] == ["values-staging.yaml", "values-domain-vpn.yaml"], "Argo value file mismatch")
require(app["spec"]["syncPolicy"]["automated"] == {"prune": True, "selfHeal": True, "allowEmpty": False}, "Argo automated sync mismatch")
require("resources-finalizer.argocd.argoproj.io" in app["metadata"]["finalizers"], "Argo finalizer missing")
require("CreateNamespace=true" in app["spec"]["syncPolicy"]["syncOptions"], "Argo namespace creation missing")

print("Helm manifest and Argo CD assertions passed.")
