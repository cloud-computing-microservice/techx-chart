"""Cloud-free default-branch notification; no PR code or artifacts are loaded."""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.request import HTTPRedirectHandler, Request, build_opener

CHART = "cloud-computing-microservice/techx-chart"
INFRA = "cloud-computing-microservice/techx-infra"
WORKFLOW = ".github/workflows/post-deploy.yml"
SOURCE_PATHS = {
    "pull_request": ".github/workflows/verify.yml",
    "push": ".github/workflows/verify.yml",
    "workflow_dispatch": ".github/workflows/verify.yml",
    "pull_request_review": ".github/workflows/chart-review-event.yml",
}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None


def api(repository, token, path, payload=None):
    if (repository not in (CHART, INFRA) or not token or not re.fullmatch(r"[A-Za-z0-9_./-]+", path)
            or ".." in path or path.startswith("/")
            or payload is not None and (repository != INFRA or path != "actions/workflows/staging-orchestrate.yml/dispatches")):
        raise ValueError("Only fixed read paths and the infra notification endpoint are allowed")
    request = Request(f"https://api.github.com/repos/{repository}/{path}",
        data=json.dumps(payload).encode() if payload is not None else None,
        method="POST" if payload is not None else "GET", headers={
            "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
            "Content-Type": "application/json", "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "techx-chart-notify"})
    with build_opener(NoRedirect()).open(request, timeout=30) as response:
        body = response.read(2 * 1024 * 1024 + 1)
        if response.status != 200 or response.headers.get("Link") or len(body) > 2 * 1024 * 1024:
            raise ValueError("Incomplete notification evidence; never retry an uncertain POST")
    return json.loads(body)


def number(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", value):
        raise ValueError("An actual numeric workflow run is required")
    return int(value)


def verified_source(get, *, run_id, source_sha, source_run_id):
    number(run_id)
    number(source_run_id)
    if not isinstance(source_sha, str) or not re.fullmatch(r"[a-f0-9]{40}", source_sha):
        raise ValueError("A full protected callback source SHA is required")
    own = get(f"actions/runs/{run_id}")
    if (own.get("id") != int(run_id) or own.get("status") != "in_progress" or own.get("event") != "workflow_run"
            or type(own.get("run_attempt")) is not int or own["run_attempt"] != 1
            or own.get("head_branch") != "main" or own.get("head_sha") != source_sha
            or own.get("path") not in (WORKFLOW, WORKFLOW + "@main")
            or any(own.get(key, {}).get("full_name") != CHART for key in ("repository", "head_repository"))
            or get("git/ref/heads/main").get("object", {}).get("sha") != source_sha):
        raise ValueError("Notification requires actual first-attempt protected chart main code")
    source = get(f"actions/runs/{source_run_id}")
    path = SOURCE_PATHS.get(source.get("event"))
    if (source.get("id") != int(source_run_id) or source.get("status") != "completed" or not path
            or type(source.get("run_attempt")) is not int or source["run_attempt"] < 1
            or source.get("path") not in (path, path + "@main")
            or any(source.get(key, {}).get("full_name") != CHART for key in ("repository", "head_repository"))):
        return None
    # Run metadata is only a hint. Infra reads its current private proposal,
    # session and actual latest CI/reviews; no sender verdict can authorize work.
    return int(source_run_id)


def notify(get, send, *, run_id, source_sha, source_run_id):
    source = verified_source(get, run_id=run_id, source_sha=source_sha, source_run_id=source_run_id)
    if source is None: return dict(waiting="UNRELATED_CHART_RUN")
    response = send(dict(ref="main", inputs=dict(chart_run_id=str(source))))
    created = response.get("workflow_run_id")
    if (set(response) != {"workflow_run_id", "run_url", "html_url"} or type(created) is not int or created < 1
            or response["run_url"] != f"https://api.github.com/repos/{INFRA}/actions/runs/{created}"
            or response["html_url"] != f"https://github.com/{INFRA}/actions/runs/{created}"):
        raise ValueError("Notification response is unverified; never repeat its POST")
    return response


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "send"))
    args = parser.parse_args()
    if (os.environ.get("GITHUB_REPOSITORY") != CHART or os.environ.get("GITHUB_REF") != "refs/heads/main"
            or os.environ.get("GITHUB_EVENT_NAME") != "workflow_run" or os.environ.get("GITHUB_RUN_ATTEMPT") != "1"):
        raise ValueError("Run notification only from actual default-branch callback code")
    path = Path(os.environ["GITHUB_EVENT_PATH"])
    if path.stat().st_size > 1024 * 1024: raise ValueError("Callback payload exceeds policy")
    source = json.loads(path.read_bytes()).get("workflow_run", {}).get("id")
    if type(source) is not int or source < 1: raise ValueError("Completed source run ID is missing")
    options = dict(run_id=os.environ["GITHUB_RUN_ID"], source_sha=os.environ["GITHUB_SHA"], source_run_id=str(source))
    get = lambda endpoint: api(CHART, os.environ["GITHUB_TOKEN"], endpoint)
    if args.mode == "prepare":
        result = verified_source(get, **options)
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                output.write("notify=" + ("true" if result is not None else "false") + "\n")
        return
    result = notify(get, lambda payload: api(INFRA, os.environ["LIFECYCLE_APP_TOKEN"],
        "actions/workflows/staging-orchestrate.yml/dispatches", payload), **options)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__": main()
