#!/usr/bin/env bash
#
# install-lab-tools.sh
#
# Installs the tools a given lab needs, at the versions the handouts
# assume, on the Amazon Linux 2023 workstation.
#
# Run it once per lab -- and again after any lab reset, because a reset
# wipes the workstation. Re-running is safe: every install is skipped if
# the tool is already present at the pinned version.
#
# Usage:
#   ./scripts/install-lab-tools.sh lab3     # Terraform
#   ./scripts/install-lab-tools.sh lab4     # Docker
#   ./scripts/install-lab-tools.sh lab5     # Terraform (same as lab3)
#   ./scripts/install-lab-tools.sh lab6     # Ansible + Packer + SSM plugin
#   ./scripts/install-lab-tools.sh lab7     # kubectl + kind   (Kubernetes)
#   ./scripts/install-lab-tools.sh lab8     # tfsec + gitleaks (Security)
#   ./scripts/install-lab-tools.sh all      # everything above

set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "Usage: $0 <lab3|lab4|lab5|lab6|lab7|lab8|all>" >&2
  exit 1
fi

# Pinned so that everyone in the class sees the same output and the same
# error messages. Bumping a version here is a deliberate act, not a
# surprise that arrives because upstream shipped on a Tuesday.
TERRAFORM_VERSION="1.10.3"
PACKER_VERSION="1.11.2"
KUBECTL_VERSION="v1.31.1"
KIND_VERSION="v0.24.0"
TFSEC_VERSION="v1.28.14"
GITLEAKS_VERSION="8.21.2"
KUBECONFORM_VERSION="v0.8.0"

ARCH="amd64"
BIN="/usr/local/bin"

have() { command -v "$1" >/dev/null 2>&1; }

say() { echo ""; echo "==> $*"; }

fetch_zip_bin() {   # url, binary-name-inside-zip
  local url="$1" name="$2" tmp
  tmp="$(mktemp -d)"
  curl -sSfL --retry 5 --retry-delay 3 --retry-all-errors -o "$tmp/pkg.zip" "$url"
  ( cd "$tmp" && unzip -oq pkg.zip )
  sudo install -m 0755 "$tmp/$name" "$BIN/$name"
  rm -rf "$tmp"
}

fetch_raw_bin() {   # url, destination-name
  local url="$1" name="$2" tmp
  tmp="$(mktemp)"
  curl -sSfL --retry 5 --retry-delay 3 --retry-all-errors -o "$tmp" "$url"
  sudo install -m 0755 "$tmp" "$BIN/$name"
  rm -f "$tmp"
}

ensure_base() {
  # unzip and tar are not guaranteed on a bare AL2023 image, and every
  # install path below needs one of them.
  if ! have unzip; then sudo dnf -y install unzip; fi
  if ! have tar;   then sudo dnf -y install tar;   fi
}

install_terraform() {
  if have terraform && terraform version | head -1 | grep -q "$TERRAFORM_VERSION"; then
    echo "terraform $TERRAFORM_VERSION already installed"; return
  fi
  say "Installing Terraform $TERRAFORM_VERSION"
  fetch_zip_bin \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" \
    terraform
  terraform version | head -1
}

install_docker() {
  if have docker; then
    echo "docker already installed"
  else
    say "Installing Docker"
    sudo dnf -y install docker
  fi
  sudo systemctl enable docker
  sudo systemctl start docker
  # Without this you get "permission denied while trying to connect to the
  # Docker daemon socket" on every command. The group change only takes
  # effect in a NEW login shell, which is why the message below matters.
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    sudo usermod -aG docker "$USER"
    echo ""
    echo "!! You were added to the 'docker' group."
    echo "!! Log out and SSH back in before running docker, or 'docker ps'"
    echo "!! will still say permission denied."
  fi
  docker --version
}

install_ansible() {
  if have ansible; then
    echo "ansible already installed"
  else
    say "Installing Ansible"
    sudo dnf -y install ansible-core
    # amazon.aws gives you the dynamic EC2 inventory plugin the lab uses.
    ansible-galaxy collection install amazon.aws --force
  fi
  ansible --version | head -1

  if have packer && packer version | grep -q "$PACKER_VERSION"; then
    echo "packer $PACKER_VERSION already installed"
  else
    say "Installing Packer $PACKER_VERSION"
    fetch_zip_bin \
      "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${ARCH}.zip" \
      packer
  fi
  packer version

  if have session-manager-plugin; then
    echo "session-manager-plugin already installed"
  else
    say "Installing the AWS SSM Session Manager plugin"
    local tmp; tmp="$(mktemp -d)"
    curl -sSfL --retry 5 --retry-delay 3 --retry-all-errors \
      -o "$tmp/ssm.rpm" \
      "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm"
    sudo dnf -y install "$tmp/ssm.rpm"
    rm -rf "$tmp"
  fi
}

install_kubernetes() {
  if have kubectl && kubectl version --client 2>/dev/null | grep -q "${KUBECTL_VERSION}"; then
    echo "kubectl ${KUBECTL_VERSION} already installed"
  else
    say "Installing kubectl ${KUBECTL_VERSION}"
    fetch_raw_bin \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
      kubectl
  fi
  kubectl version --client | head -1

  if have kind && kind --version | grep -q "${KIND_VERSION#v}"; then
    echo "kind ${KIND_VERSION} already installed"
  else
    say "Installing kind ${KIND_VERSION}"
    fetch_raw_bin \
      "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" \
      kind
  fi
  kind --version

  # kubeconform is what the GRADING pipeline validates manifests with. Install
  # it here too, so "check-lab.sh lab7" runs the same check locally instead of
  # falling back to a plain YAML parse that passes on manifests grading rejects.
  if have kubeconform && kubeconform -v 2>/dev/null | grep -q "${KUBECONFORM_VERSION#v}"; then
    echo "kubeconform ${KUBECONFORM_VERSION} already installed"
  else
    say "Installing kubeconform ${KUBECONFORM_VERSION}"
    local tmp; tmp="$(mktemp -d)"
    curl -sSfL --retry 5 --retry-delay 3 --retry-all-errors \
      -o "$tmp/kubeconform.tar.gz" \
      "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz"
    ( cd "$tmp" && tar xzf kubeconform.tar.gz )
    sudo install -m 0755 "$tmp/kubeconform" "$BIN/kubeconform"
    rm -rf "$tmp"
  fi
  kubeconform -v

  # kind runs the cluster nodes as containers, so Docker has to be there
  # first. This is the single most common "kind create cluster" failure.
  if ! have docker; then
    echo ""
    echo "!! kind needs Docker. Run: $0 lab4"
  fi
}

install_security() {
  if have tfsec && tfsec --version 2>/dev/null | grep -q "${TFSEC_VERSION#v}"; then
    echo "tfsec ${TFSEC_VERSION} already installed"
  else
    say "Installing tfsec ${TFSEC_VERSION}"
    fetch_raw_bin \
      "https://github.com/aquasecurity/tfsec/releases/download/${TFSEC_VERSION}/tfsec-linux-${ARCH}" \
      tfsec
  fi
  tfsec --version

  if have gitleaks && gitleaks version 2>/dev/null | grep -q "${GITLEAKS_VERSION}"; then
    echo "gitleaks ${GITLEAKS_VERSION} already installed"
  else
    say "Installing gitleaks ${GITLEAKS_VERSION}"
    local tmp; tmp="$(mktemp -d)"
    curl -sSfL --retry 5 --retry-delay 3 --retry-all-errors \
      -o "$tmp/gitleaks.tar.gz" \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
    ( cd "$tmp" && tar xzf gitleaks.tar.gz )
    sudo install -m 0755 "$tmp/gitleaks" "$BIN/gitleaks"
    rm -rf "$tmp"
  fi
  gitleaks version
}

ensure_base

case "$TARGET" in
  lab3|lab5) install_terraform ;;
  lab4)      install_docker ;;
  lab6)      install_ansible ;;
  lab7)      install_kubernetes ;;   # Weeks 9-10, Kubernetes
  lab8)      install_security ;;     # Week 12, Security and Policy as Code
  all)
    install_terraform
    install_docker
    install_ansible
    install_kubernetes
    install_security
    ;;
  *)
    echo "Unknown target: $TARGET" >&2
    echo "Valid: lab3 lab4 lab5 lab6 lab7 lab8 all" >&2
    exit 1
    ;;
esac

say "Done. Tools for $TARGET are installed."
