#!/usr/bin/env bash
#
# check-lab.sh
#
# Runs the same categories of check the grading pipeline runs, against one
# deliverable folder, and lists the files that deliverable is required to
# contain. Green here is a strong sign you will be green in grading.
#
# It does NOT award a grade and it does not judge quality -- it reports
# PASS / FAIL / MISSING on the mechanical things only.
#
# Usage:  ./scripts/check-lab.sh lab2

set -uo pipefail

DIR="${1:-}"
if [ -z "$DIR" ]; then
  echo "Usage: $0 <lab1|lab2|...|lab8|assignment1|assignment2|final-project>" >&2
  exit 1
fi

if [ ! -d "$DIR" ]; then
  echo "FAIL: folder '$DIR' does not exist. Run this from the root of your repo." >&2
  exit 1
fi

PASS=0; FAIL=0; MISS=0

ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
miss() { echo "  MISSING  $*"; MISS=$((MISS+1)); }
note() { echo "  ....  $*"; }

run() {  # label, command...
  local label="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then ok "$label"
  else
    bad "$label"
    echo "$out" | sed 's/^/        /' | tail -12
  fi
}

# ---------- required files, per deliverable ----------
# Mirrors each Blackboard item's "What to hand in" list. Paths are relative to
# the repository root; a trailing /* means "at least one file in that folder".
required_files() {
  case "$1" in
    lab1) echo "lab1/scripts/create-instance.sh lab1/scripts/create-security-group.sh lab1/scripts/delete-instance.sh lab1/scripts/delete-security-group.sh lab1/README.md .gitignore" ;;
    lab2) echo "lab2/scripts/deploy-web.sh lab2/acs730-web.service lab2/README.md" ;;
    lab3) echo "lab3/main.tf lab3/README.md .github/workflows/lab3-ci.yml .github/workflows/lab3-deploy.yml scripts/refresh-gha-creds.sh" ;;
    lab4) echo "lab4/app.py lab4/requirements.txt lab4/requirements-dev.txt lab4/tests/test_app.py lab4/Dockerfile lab4/Dockerfile.naive lab4/.dockerignore lab4/README.md .github/workflows/lab4-ci.yml .github/workflows/docker-build.yml .github/actions/python-deps/action.yml" ;;
    lab5) echo "lab5/versions.tf lab5/providers.tf lab5/variables.tf lab5/network.tf lab5/compute.tf lab5/outputs.tf lab5/localstack.tfvars lab5/README.md .github/workflows/lab5-ci.yml" ;;
    lab6) echo "lab6/terraform/main.tf lab6/ansible/ansible.cfg lab6/ansible/site.yml lab6/ansible/inventory/lab6.aws_ec2.yml lab6/ansible/roles/webserver/tasks/main.yml lab6/packer/web.pkr.hcl lab6/scripts/boot-to-ready.sh lab6/README.md .github/workflows/lab6-configure.yml" ;;
    lab7) echo "lab7/kind-cluster.yaml lab7/scripts/create-cluster.sh lab7/k8s/namespace.yaml lab7/k8s/configmap.yaml lab7/k8s/secret.yaml lab7/k8s/deployment.yaml lab7/k8s/service.yaml lab7/README.md .github/workflows/lab7-ci.yml" ;;
    lab8) echo "lab8/main.tf lab8/policies/lab8-deploy-policy.json lab8/README.md .github/workflows/lab8-policy.yml" ;;
    assignment1) echo "assignment1/REPORT.md" ;;
    assignment2) echo "assignment2/REPORT.md assignment2/packer/*.pkr.hcl" ;;
    final-project) echo "final-project/REPORT.md" ;;
    *)    echo "$1/README.md" ;;
  esac
}

# Folders that must exist and contain at least one file.
required_dirs() {
  case "$1" in
    lab[1-8]) echo "$1/evidence" ;;
    assignment1) echo "assignment1/terraform/modules assignment1/terraform/dev assignment1/terraform/staging assignment1/terraform/prod assignment1/evidence" ;;
    assignment2) echo "assignment2/terraform assignment2/ansible/roles assignment2/evidence" ;;
    final-project) echo "final-project/terraform final-project/k8s final-project/evidence" ;;
    *) echo "" ;;
  esac
}

# Files that belong to the second week of a two-week lab. Reported as a note,
# not a failure, so a correct end-of-first-week run does not go red.
later_week_files() {
  case "$1" in
    lab4) echo "lab4/evidence/ci-graph.png lab4/evidence/ghcr-package.png lab4/evidence/required-check.png" ;;
    lab7) echo "lab7/k8s/rbac.yaml .github/workflows/lab7-deploy.yml" ;;
    *) echo "" ;;
  esac
}

echo ""
echo "Checking $DIR"
echo ""
echo "Required files"
for f in $(required_files "$DIR"); do
  if compgen -G "$f" >/dev/null; then ok "$f"; else miss "$f"; fi
done
for d in $(required_dirs "$DIR"); do
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then ok "$d/ (not empty)"
  else miss "$d/ with at least one file in it"; fi
done
for f in $(later_week_files "$DIR"); do
  if compgen -G "$f" >/dev/null; then ok "$f (second-week item)"
  else note "$f is not there yet -- it belongs to the second week of this lab, so this is fine until then"; fi
done

echo ""
echo "Mechanical checks"

matched=0

# ---------- shell scripts ----------
while IFS= read -r sf; do
  [ -z "$sf" ] && continue
  matched=1
  run "bash -n syntax check ($sf)" bash -n "$sf"
  if [ ! -x "$sf" ]; then
    note "$sf is not executable -- run: chmod +x $sf"
  fi
done < <(find "$DIR" -name '*.sh' 2>/dev/null)

# ---------- Terraform ----------
while IFS= read -r tfd; do
  [ -z "$tfd" ] && continue
  matched=1
  if command -v terraform >/dev/null 2>&1; then
    run "terraform validate ($tfd)" bash -c "cd '$tfd' && terraform init -backend=false -input=false >/dev/null && terraform validate"
  else
    note "terraform is not installed, so this check was skipped here -- grading WILL run it. ./scripts/install-lab-tools.sh lab3"
  fi
  if command -v tfsec >/dev/null 2>&1; then
    if [ "$DIR" = "lab8" ]; then
      # lab8 = Week 12, Security and Policy-as-Code: "tfsec finds nothing
      # HIGH or CRITICAL" is the point of the exercise, so it is a real
      # pass/fail gate here rather than information.
      run "tfsec, no HIGH/CRITICAL ($tfd)" bash -c "tfsec '$tfd' --minimum-severity HIGH"
    else
      note "tfsec findings for $tfd (informational in this lab):"
      tfsec "$tfd" --soft-fail 2>&1 | tail -15 | sed 's/^/        /'
    fi
  elif [ "$DIR" = "lab8" ]; then
    note "tfsec is not installed and lab8 is graded on it. ./scripts/install-lab-tools.sh lab8"
  fi
done < <(find "$DIR" -name '*.tf' -exec dirname {} \; 2>/dev/null | sort -u)

# ---------- Docker ----------
while IFS= read -r df; do
  [ -z "$df" ] && continue
  matched=1
  if command -v docker >/dev/null 2>&1; then
    run "docker build ($df)" docker build -q -f "$df" "$(dirname "$df")"
  else
    note "docker is not installed, so the build was skipped -- grading WILL run it. ./scripts/install-lab-tools.sh lab4"
  fi
done < <(find "$DIR" -iname 'Dockerfile' 2>/dev/null)

# ---------- Ansible ----------
while IFS= read -r ad; do
  [ -z "$ad" ] && continue
  while IFS= read -r pb; do
    [ -z "$pb" ] && continue
    grep -qE '^[[:space:]]*-?[[:space:]]*hosts:' "$pb" || continue
    matched=1
    if command -v ansible-playbook >/dev/null 2>&1; then
      run "ansible-playbook --syntax-check ($pb)" ansible-playbook --syntax-check "$pb"
    else
      note "ansible is not installed. ./scripts/install-lab-tools.sh lab6"
    fi
  done < <(find "$ad" -maxdepth 1 \( -iname '*.yml' -o -iname '*.yaml' \) 2>/dev/null)
done < <(find "$DIR" -type d -iname 'ansible' 2>/dev/null)

# ---------- Kubernetes manifests ----------
while IFS= read -r kd; do
  [ -z "$kd" ] && continue
  while IFS= read -r mf; do
    [ -z "$mf" ] && continue
    matched=1
    if command -v kubeconform >/dev/null 2>&1; then
      run "kubeconform ($mf)" kubeconform -strict -summary "$mf"
    else
      # kubeconform is a CI-side tool; locally, catching invalid YAML early
      # is most of the value.
      run "YAML parses ($mf)" python3 -c "import yaml,sys;yaml.safe_load(open(sys.argv[1]))" "$mf"
    fi
  done < <(find "$kd" \( -iname '*.yaml' -o -iname '*.yml' \) 2>/dev/null)
done < <(find "$DIR" -type d -iname 'k8s' 2>/dev/null)

# ---------- Packer ----------
while IFS= read -r pf; do
  [ -z "$pf" ] && continue
  matched=1
  if command -v packer >/dev/null 2>&1; then
    run "packer validate ($pf)" bash -c "packer init '$pf' >/dev/null 2>&1; packer validate '$pf'"
  else
    note "packer is not installed. ./scripts/install-lab-tools.sh lab6"
  fi
done < <(find "$DIR" -iname '*.pkr.hcl' 2>/dev/null)

if [ "$matched" -eq 0 ]; then
  note "no Terraform / Docker / Ansible / Kubernetes / Packer / shell content found in $DIR -- a human reads this one."
fi

# ---------- repo hygiene ----------
echo ""
echo "Repository hygiene"
HITS="$(git log --all --name-only --pretty=format: 2>/dev/null \
        | grep -E '\.(tfstate|pem)$|(^|/)credentials$' \
        | grep -vE '^(midterm-practice|final-practice)/' | sort -u)"
if [ -n "$HITS" ]; then
  bad "a key, credentials file or tfstate is in your git history:"
  echo "$HITS" | sed 's/^/        /'
  note "deleting it in a new commit does NOT remove it from history."
else
  ok "no .pem, credentials or .tfstate in git history"
fi

if [ -f .gitignore ] && grep -q '\*.pem' .gitignore; then
  ok ".gitignore covers *.pem"
else
  bad ".gitignore is missing or does not list *.pem"
fi

echo ""
echo "Summary for $DIR:  $PASS pass, $FAIL fail, $MISS missing"
echo ""
if [ "$FAIL" -gt 0 ] || [ "$MISS" -gt 0 ]; then exit 1; fi
exit 0
