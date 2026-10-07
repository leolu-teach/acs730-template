#!/usr/bin/env bash
#
# session-start.sh
#
# The start-of-session ritual, in one place. Run this first, every time
# you sit down to work on ACS730. It checks the things that silently
# break a lab session, and tells you what still needs doing.
#
# It changes nothing on its own except, if you say yes, refreshing your
# GitHub Actions credentials.
#
# Usage:  ./scripts/session-start.sh

set -uo pipefail

ok()   { echo "  [ok]    $*"; }
warn() { echo "  [todo]  $*"; }
bad()  { echo "  [STOP]  $*"; }

echo ""
echo "ACS730 session check"
echo ""

# ---------- 1. Are we even in the repo? ----------
if [ ! -d .git ]; then
  bad "this is not a git repository. cd into your course repo first."
  exit 1
fi
REPO_SLUG="$(git remote get-url origin 2>/dev/null \
             | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
ok "repository: ${REPO_SLUG:-unknown}"

# ---------- 2. AWS identity ----------
# On the workstation your credentials come from the attached instance
# profile, so they never expire mid-session and there is nothing to paste.
# If this shows a plain IAM user, you are almost certainly on your laptop.
echo ""
echo "AWS"
if ! command -v aws >/dev/null 2>&1; then
  bad "the AWS CLI is not installed. Are you on the workstation?"
else
  ARN="$(aws sts get-caller-identity --query Arn --output text 2>&1)"
  if [ $? -ne 0 ]; then
    bad "AWS call failed: $ARN"
    warn "click Start Lab on the Vocareum page, wait for the green circle, then re-run this."
  elif echo "$ARN" | grep -q 'assumed-role'; then
    ok "identity comes from the instance profile: $ARN"
  else
    warn "identity is $ARN -- that is not an instance-profile role."
    warn "everything in this course is meant to run on the Week 1 workstation."
  fi
fi

# ---------- 3. Repo freshness ----------
echo ""
echo "Git"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
ok "on branch $BRANCH"
if [ -n "$(git status --porcelain)" ]; then
  warn "you have uncommitted changes:"
  git status --short | sed 's/^/          /'
else
  ok "working tree is clean"
fi
if git fetch --quiet 2>/dev/null; then
  BEHIND="$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)"
  if [ "${BEHIND:-0}" -gt 0 ]; then
    warn "$BEHIND commit(s) behind the remote -- run: git pull"
  else
    ok "up to date with the remote"
  fi
fi

# ---------- 4. Helper scripts present ----------
echo ""
echo "Helper scripts"
for s in refresh-gha-creds.sh install-lab-tools.sh check-lab.sh cleanup-check.sh; do
  if [ -f "scripts/$s" ]; then
    [ -x "scripts/$s" ] || chmod +x "scripts/$s" 2>/dev/null
    ok "scripts/$s"
  else
    warn "scripts/$s is missing -- see Start Here, Helper Scripts on Blackboard"
  fi
done

# ---------- 5. GitHub Actions credentials ----------
# Needed from Week 3 on, because the pipeline deploys to your Academy
# account from a GitHub-hosted runner, which has no instance profile.
# Academy session credentials expire with the lab session, so these go
# stale every single time.
echo ""
echo "GitHub Actions credentials"
if [ ! -d lab3 ] && [ ! -d lab5 ] && [ ! -d assignment1 ]; then
  ok "not needed yet (Week 3 onward)"
elif ! command -v gh >/dev/null 2>&1; then
  warn "the GitHub CLI is not installed or not on PATH"
else
  echo "  Your Actions secrets go stale every time the lab session restarts."
  printf "  Refresh them now? [y/N] "
  read -r ANS
  case "${ANS:-N}" in
    y|Y) ./scripts/refresh-gha-creds.sh "$REPO_SLUG" ;;
    *)   warn "skipped -- run ./scripts/refresh-gha-creds.sh $REPO_SLUG before you push" ;;
  esac
fi

# ---------- 6. Kubernetes, from Lab 7 on ----------
# lab7 = Weeks 9-10, Kubernetes Fundamentals and CI/CD to Kubernetes.
# The kind cluster lives in Docker on this workstation, so a reset or a
# stop/start of the instance takes it with it.
if [ -d lab7 ] && [ -n "$(ls -A lab7 2>/dev/null | grep -v README.md)" ]; then
  echo ""
  echo "Kubernetes (Lab 7)"
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker is missing -- kind needs it. ./scripts/install-lab-tools.sh lab4"
  elif ! docker info >/dev/null 2>&1; then
    warn "the docker daemon is not reachable. sudo systemctl start docker, and if it still fails, log out and back in."
  else
    ok "docker daemon is up"
  fi
  if command -v kind >/dev/null 2>&1; then
    CLUSTERS="$(kind get clusters 2>/dev/null)"
    if [ -n "$CLUSTERS" ]; then ok "kind cluster(s): $(echo "$CLUSTERS" | tr '\n' ' ')"
    else warn "no kind cluster -- recreate it, see the Lab 7 handout"; fi
  else
    warn "kind is not installed. ./scripts/install-lab-tools.sh lab7"
  fi
  if command -v gh >/dev/null 2>&1 && [ -n "${REPO_SLUG:-}" ]; then
    RUNNERS="$(gh api "repos/$REPO_SLUG/actions/runners" --jq '.runners[] | select(.status=="online") | .name' 2>/dev/null)"
    if [ -n "$RUNNERS" ]; then ok "self-hosted runner online: $(echo "$RUNNERS" | tr '\n' ' ')"
    else warn "no self-hosted runner is online -- restart it, see the Lab 7 handout"; fi
  fi
fi

echo ""
echo "Done. Anything marked [todo] is yours to fix before you start."
echo ""
