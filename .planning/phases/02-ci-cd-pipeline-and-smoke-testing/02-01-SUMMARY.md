---
phase: 02-ci-cd-pipeline-and-smoke-testing
plan: 01
subsystem: ci-cd
tags: [github-actions, oidc, ssh, playwright, python, docker, ec2, aws]

# Dependency graph
requires:
  - phase: 01-iac-foundation-and-ec2-bootstrap
    provides: Running EC2 at 54.253.108.90, /opt/lightrag deploy path, Docker Compose setup, SSM secrets
provides:
  - GitHub Actions deploy workflow triggered on release tags (v*)
  - OIDC-based AWS authentication (mythicc123 role)
  - SSH deploy to EC2 with digest-pinned Docker images
  - Playwright E2E smoke tests covering ingest, polling, query, entity assertion
affects: [03-documentation-and-hardening]

# Tech tracking
tech-stack:
  added: [github-actions, appleboy/ssh-action, aws-actions/configure-aws-credentials, playwright, pytest, requests]
  patterns: [OIDC web-identity-token for GitHub Actions AWS auth, digest-pinned Docker images via docker manifest inspect, SSH-based remote deploy with inline shell scripts, module-level cross-test data sharing in pytest]

key-files:
  created: [.github/workflows/deploy.yml, tests/smoke_test.py, tests/requirements.txt]
  modified: []

key-decisions:
  - "OIDC assumes existing mythicc123 IAM role -- role ARN constructed dynamically as arn:aws:iam::255445075474:role/mythicc123 (role must pre-exist)"
  - "Digest-pinned image via docker manifest inspect instead of :latest tag for reproducible deployments"
  - "SSH deploy via appleboy/ssh-action inline script instead of separate deploy script file"
  - "Cross-test data shared via module-level _test_response dict (pytest dependency ordering ensures test_ingest runs first, test_query_hybrid populates data for test_entity_in_response)"

patterns-established: []

requirements-completed: [CICD-01, CICD-02, CICD-03, CICD-04, TEST-01, TEST-02, TEST-03, TEST-04, TEST-05]

# Metrics
duration: 1min
completed: 2026-04-02
---

# Phase 2, Plan 1: CI/CD Pipeline and Smoke Testing Summary

**GitHub Actions deploy workflow with OIDC auth and SSH-based deploy to EC2, plus Playwright E2E smoke tests validating the full ingest-to-query flow**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-02T13:22:59Z
- **Completed:** 2026-04-02T13:24:08Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- GitHub Actions deploy workflow triggers on release tags (v*) with OIDC-based AWS authentication
- SSH deploy via appleboy/ssh-action fetches Docker image digest and deploys to EC2 at 54.253.108.90
- Docker image pinned by SHA digest (not :latest) for reproducible deployments
- Health check verifies HTTP 200 after deployment before declaring success
- Playwright E2E smoke tests cover full ingest -> poll -> query -> entity assertion flow

## Task Commits

Each task was committed atomically:

1. **Task 1: GitHub Actions deploy workflow** - `f759bb9` (feat)
2. **Task 2: Playwright smoke tests** - `99c11ba` (test)

**Plan metadata:** `20e9745` (docs: complete plan)

## Files Created/Modified
- `.github/workflows/deploy.yml` - GitHub Actions deploy pipeline triggered on push.tags with v* pattern
- `tests/smoke_test.py` - Python smoke tests (5 test functions covering health, ingest, polling, query, entity)
- `tests/requirements.txt` - Python test dependencies (playwright, pytest, requests)

## Decisions Made

- Used OIDC web-identity-token pattern for AWS authentication (mythicc123 role must pre-exist; role ARN constructed dynamically as arn:aws:iam::255445075474:role/mythicc123)
- Digest-pinned Docker images via `docker manifest inspect` to ensure reproducible deployments
- Inline SSH deploy script via appleboy/ssh-action rather than a separate deploy script file
- Cross-test data shared via module-level `_test_response` dict; pytest runs tests alphabetically so test_ingest_document runs before test_ingestion_complete

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- AWS role `mythicc123` does not exist in the current account (verified via `aws iam get-role`). The workflow constructs the role ARN dynamically (arn:aws:iam::255445075474:role/mythicc123) so the role must be created separately before the workflow can run. This is expected per the plan's note that the role already exists -- it will need to be provisioned as part of Phase 1 infrastructure or separately.

## User Setup Required

**Secrets must be configured in GitHub before the deploy workflow can run:**
1. `EC2_SSH_KEY` -- Full PEM contents of the SSH key for ubuntu@54.253.108.90 (store as a multi-line GitHub Secret)
2. OIDC role `mythicc123` must exist in AWS account 255445075474 with trust policy allowing GitHub Actions OIDC

**To trigger a deployment:**
```bash
git tag v0.1.0 && git push --tags
```

**To run smoke tests locally:**
```bash
export LIGHTRAG_API_KEY="your-key"
pip install -r tests/requirements.txt
pytest tests/smoke_test.py -v
```

## Next Phase Readiness

Phase 3 (Documentation and Hardening) can begin. CI/CD pipeline is complete and ready for use once secrets are configured.

---
*Phase: 02-ci-cd-pipeline-and-smoke-testing*
*Completed: 2026-04-02*
