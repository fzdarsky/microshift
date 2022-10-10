#!/bin/bash
#
# This script automates the VM configuration steps described in the "MicroShift Development Environment on RHEL 8" document.
# See https://github.com/openshift/microshift/blob/main/docs/devenv_rhel8.md
#
set -eo pipefail

ENABLE_DEV_REPO="false"
OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
OS_VERSION=$(grep -oP '(?<=VERSION_ID=).+' /etc/os-release | tr -d '"')
OS_VERSION_MAJOR=$(echo ${OS_VERSION} | cut -f1 -d'.')
OS_VERSION_MINOR=$(echo ${OS_VERSION} | cut -f2 -d'.')
OCP_VERSION_MINOR="12"
OCP_RPM_REPO="rhocp-4.11-for-rhel-${OS_VERSION_MAJOR}-$(uname -i)-rpms"
[ "${OS_VERSION_MAJOR}" -gt "8" ] && OCP_RPM_REPO=""

function usage() {
    echo "Usage: $(basename $0) [--enable-dev-repo] <openshift-pull-secret-file>"
    echo ""
    echo "Optional arguments:"
    echo "  --enable-dev-repo"
    echo "          Enable the developer repos with pre-release RPMs (Red Hat VPN required)"
    [ ! -z "$1" ] && echo -e "\nERROR: $1"
    exit 1
}

case "${OS_ID}" in
    "rhel") ;;
    *)      usage "This script does not support running on '${OS_ID}'." ;;
esac

# Parse the command line
[ $# -lt 1 ] && usage "Missing argument."
while [ $# -gt 1 ] ; do
    case $1 in
    --enable-dev-repo)
        ENABLE_DEV_REPO="true"
        shift
        ;;
    *)
        usage "Invalid argument '$1'."
        ;;
    esac
done

[ "${OS_VERSION_MAJOR}" -gt "8" ] && [ "${ENABLE_DEV_REPO}" == "false" ] && usage "Must enable dev repo if running on RHEL > 8."

OCP_PULL_SECRET=$(realpath $1)
[ ! -f "${OCP_PULL_SECRET}" ] && usage "OpenShift pull secret ${OCP_PULL_SECRET} does not exist or is not a regular file."

if [ "$(whoami)" != "microshift" ] ; then
    echo "This script should be run from 'microshift' user account"
    exit 1
fi

# Check the subscription status and register if necessary
if ! sudo subscription-manager status >& /dev/null ; then
   sudo subscription-manager register
fi

# Create Development Virtual Machine > Configuring VM
# https://github.com/openshift/microshift/blob/main/docs/devenv_rhel8.md#configuring-vm
echo -e 'microshift\tALL=(ALL)\tNOPASSWD: ALL' | sudo tee /etc/sudoers.d/microshift
sudo dnf update -y
sudo dnf install -y git cockpit make golang selinux-policy-devel rpm-build bash-completion
sudo systemctl enable --now cockpit.socket

# Build MicroShift
# https://github.com/openshift/microshift/blob/main/docs/devenv_rhel8.md#build-microshift
if [ ! -e ~/microshift ] ; then 
    git clone https://github.com/openshift/microshift.git ~/microshift
fi
cd ~/microshift

# Build MicroShift > RPM Packages
# https://github.com/openshift/microshift/blob/main/docs/devenv_rhel8.md#rpm-packages
make rpm 
make srpm

# Run MicroShift Executable > Runtime Prerequisites
# https://github.com/openshift/microshift/blob/main/docs/devenv_rhel8.md#runtime-prerequisites
if [[ "${ENABLE_DEV_REPO}" == "true" ]]; then
    if curl --output /dev/null --silent --head --fail "http://download.lab.bos.redhat.com"; then
        echo -e "\E[32mSuccessfully reached http://download.lab.bos.redhat.com, configuring prerelease repo.\E[00m"
        sudo tee "/etc/yum.repos.d/internal-rhocp-4.${OCP_VERSION_MINOR}-for-rhel-${OS_VERSION_MAJOR}-rpms.repo" >/dev/null <<EOF
[internal-rhocp-4.${OCP_VERSION_MINOR}-for-rhel-${OS_VERSION_MAJOR}-rpms]
name=Puddle of the rhocp-4.${OCP_VERSION_MINOR} RPMs for RHEL${OS_VERSION_MAJOR}
baseurl=http://download.lab.bos.redhat.com/rcm-guest/puddles/RHAOS/plashets/4.${OCP_VERSION_MINOR}-el${OS_VERSION_MAJOR}/building/\$basearch/os/
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
    else
        echo -e "\E[31mERROR: '--enable-dev-repo' specified, but could not reach http://download.lab.bos.redhat.com (not on VPN?), aborting.\E[00m"
        exit 1
    fi
fi
[ -n "${OCP_RPM_REPO}" ] && sudo subscription-manager repos --enable "${OCP_RPM_REPO}"
sudo subscription-manager repos --enable fast-datapath-for-rhel-${OS_VERSION_MAJOR}-$(uname -i)-rpms
sudo dnf localinstall -y ~/microshift/_output/rpmbuild/RPMS/*/*.rpm

sudo cp -f ${OCP_PULL_SECRET} /etc/crio/openshift-pull-secret
sudo chmod 600                /etc/crio/openshift-pull-secret

# Run MicroShift Executable > Installing Clients
# https://github.com/openshift/microshift/blob/main/docs/devenv_rhel8.md#installing-clients
sudo dnf install -y openshift-clients

# Run MicroShift Executable > Configuring MicroShift > Firewalld
# https://github.com/openshift/microshift/blob/main/docs/howto_firewall.md#firewalld
sudo dnf install -y firewalld
sudo systemctl enable firewalld --now
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 
sudo firewall-cmd --permanent --zone=trusted --add-source=169.254.169.1
sudo firewall-cmd --reload

# Run MicroShift Executable > Configuring MicroShift
# https://github.com/openshift/microshift/blob/main/docs/devenv_rhel8.md#configuring-microshift
sudo systemctl enable crio
sudo systemctl start microshift

echo ""
echo "The configuration phase completed. Run the following commands to:"
echo " - Wait until all MicroShift pods are running"
echo " - Clean up MicroShift service configuration"
echo ""
echo "watch sudo $(which oc) --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig get pods -A"
echo "echo 1 | /usr/bin/cleanup-all-microshift-data"
echo ""
echo "Done"
