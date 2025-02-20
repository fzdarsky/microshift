# MicroShift CNI Plugin Overview

> **IMPORTANT!** The default CNI configuration is intended to match the developer environment described in [MicroShift Development Environment](./devenv_setup.md).

MicroShift uses Red Hat OpenShift Networking CNI driver, based on [ovn-kubernetes](https://github.com/ovn-org/ovn-kubernetes.git).

## Design

### Systemd Services

#### OpenvSwitch

OpenvSwitch is a core component to ovn-kubernetes CNI plugin, it runs as a systemd service on the MicroShift node.
OpenvSwitch rpm package is installed as a dependency to microshift-networking rpm package.

By default, three performance optimizations are applied to openvswitch services to minimize the resource consumption:

1. CPU affinity to ovs-vswitchd.service and ovsdb-server.service
2. No-mlockall to openvswitch.service
3. Limit handler and revalidator threads to ovs-vswitchd.service

OpenvSwitch service is enabled and started immediately after installing microshift-networking package.

#### NetworkManager

NetworkManager is required by ovn-kubernetes to setup initial gateway bridge on the MicroShift node.
NetworkManager and NetworkManager-ovs rpm packages are installed as dependencies to microshift-networking rpm.
NetworkManager is configured to use `keyfile` plugin and is restarted immediately after installing microshift-networking package to take in the config change.

#### microshift-ovs-init

microshift-ovs-init.service is installed by microshift-networking rpm as oneshot systemd service.
microshift-ovs-init.service executes configure-ovs.sh script which uses NetworkManager commands to setup OVS gateway bridge.

### OVN Containers

Ovn-kubernetes cluster manifests can be found in [microshift/assets/components/ovn](../assets/components/ovn).

Two ovn-kubernetes daemonsets are rendered and applied by MicroShift binary.

1. ovnkube-master: includes northd, nbdb, sbdb and ovnkube-master containers
2. ovnkube-node: includes ovn-controller container

Ovn-kubernetes daemonsets are deployed in the `openshift-ovn-kubernetes` namespace, after MicroShift boots.

## Packaging

Ovn-kubernetes manifests and startup logic are built into MicroShift main binary (microshift rpm).
Systemd services and configurations are included in microshift-networking rpm package:
1. microshift-nm.conf for NetworkManager.service
2. microshift-cpuaffinity.conf for ovs-vswitchd.service
3. microshift-cpuaffinity.conf for ovsdb-server.service
4. microshift-ovs-init.service
5. configure-ovs.sh for microshift-ovs-init.service
6. configure-ovs-microshift.sh for microshift-ovs-init.service

## Configurations

### Configuring ovn-kubernetes

The user provided ovn-kubernetes config should be written to `/etc/microshift/ovn.yaml`.
MicroShift will assume default ovn-kubernetes config values if ovn-kubernetes config file is not provided.

The following configs are supported in ovn-kubernetes config file:

|Field                            |Required |Type    |Default |Description                                                       |Example|
|:--------------------------------|:--------|:-------|:-------|:-----------------------------------------------------------------|:------|
|ovsInit.disableOVSInit           |N        |bool    |false   |Skip configuring OVS bridge "br-ex" in microshift-ovs-init.service|true   |
|ovsInit.gatewayInterface         |N        |string  |""      |Interface to be added in OVS gateway bridge "br-ex"               |eth0   |
|ovsInit.externalGatewayInterface |N        |string  |""      |Interface to be added in external OVS gateway bridge "br-ex1"     |eth1   |
|mtu                              |N        |uint32  |1400    |MTU value to be used for the Pods                                 |1300   |

> When `disableOVSInit` is true, OVS bridge "br-ex" needs to be configured manually. This OVS bridge is required by ovn-kubernetes CNI. See section [OVS bridge](#ovs-bridge) for guidance on configuring the OVS gateway bridge manually.

Below is an example of `ovn.yaml`:

```yaml
ovsInit:
  disableOVSInit: true
  gatewayInterface: eth0
  externalGatewayInterface: eth1
mtu: 1300
```
**NOTE:* The change of `mtu` configuration in `ovn.yaml` requires node reboot to take effect. <br>

### Configuring Host

#### OVS bridge

When `disableOVSInit` is set to true in ovn-kubernetes CNI config file, OVS bridge "br-ex" needs to be manually configured:

```bash
nmcli con add type ovs-bridge con-name br-ex conn.interface br-ex 802-3-ethernet.mtu 1500 connection.autoconnect no
nmcli con add type ovs-port conn.interface enp1s0 master br-ex con-name ovs-port-phys0 connection.autoconnect no
nmcli con add type ovs-port conn.interface br-ex master br-ex con-name ovs-port-br-ex connection.autoconnect no

nmcli con add type 802-3-ethernet conn.interface enp1s0 master ovs-port-phys0 con-name ovs-if-phys0 \
	connection.autoconnect-priority 100 802-3-ethernet.mtu 1500 connection.autoconnect no

ovs_port_conn=$(nmcli -g connection.uuid conn show ovs-port-br-ex)
iface_mac=$(<"/sys/class/net/enp1s0/address")

nmcli con add type ovs-interface slave-type ovs-port conn.interface br-ex master "$ovs_port_conn" con-name \
	ovs-if-br-ex 802-3-ethernet.mtu 1500 802-3-ethernet.cloned-mac-address ${iface_mac} \
	ipv4.route-metric 48 ipv6.route-metric 48 connection.autoconnect no

nmcli con up ovs-if-phys0
nmcli con up ovs-if-br-ex
nmcli con mod ovs-if-phys0 connection.autoconnect yes
nmcli con mod ovs-if-br-ex connection.autoconnect yes
```

Replace `enp1s0` with the network interface name where node IP address is assigned to. <br>
Replace `1500` with the actual MTU on the network interface. <br>

**NOTE:* Copy the above NetworkManager command in a script and execute them at once. <br>
**NOTE:* Execution of the above commands will cause transient network disconnection from the node IP. <br>

[comment]: # (TODO: replace OVS commands with nmcli which can be easily installed under /etc)

## Network Features

A wide range of networking features are available with MicroShift and ovn-kubernetes, including but not limited to:

* Network policy
* Dynamic node IP
* Custom gateway interface
* Second gateway interface

### Network Policy

Network Policy restricts network traffic to and/or from kubernetes pods.
The ovn-kubernetes implementation of network policy supports pod, namespace and ipBlock based identifiers as well as Ingress and Egress isolation types.
See [ovn-kubernetes network policy](https://github.com/ovn-org/ovn-kubernetes/blob/master/docs/network-policy.md) doc for detailed design and configurations.

### Dynamic node IP

MicroShift is able to detect node IP change and restarts itself to take in the new IP address.
Upon restarting, it recreates ovnkube-master daemonset with updated IP address in openshift-ovn-kubernetes namespace.

### Custom gateway interface

microshift-ovs-init.service is able to use user specified host interface for cluster network.
This is done by specifying the `gatewayInterface` in the CNI config file `/etc/microshift/ovn.yaml`.
The specified interface will be added in OVS bridge `br-ex` which acts as gateway bridge for ovn-kubernetes CNI network.

### Second gateway interface

microshift-ovs-init.service is able to setup one additional host interface for cluster ingress/egress traffic.
This is done by specifying the `externalGatewayInterface` in the CNI config file `/etc/microshift/ovn.yaml`.
The external gateway interface will be added in a second OVS bridge `br-ex1`. Cluster pod traffic destinated to additional host subnet will be routed through `br-ex1`.

## Known Issues

* Firewall reload flushes iptable rules

ovn-kubernetes makes use of iptable rules for some traffic flows (such as nodePort service), these iptable rules are generated and inserted by ovn-kubernetes (ovnkube-master container), but can be removed by reloading firewall rules, which in turn breaks the traffic flows. To avoid such situation, make sure to execute firewall commands before starting ovn-kubernetes pods. If firewall commands have to be executed after ovn-kubernetes pods have started, manually restart the ovnkube-master pod to trigger the reinsertion of ovn-kubernetes iptable rules. See section [NodePort Service](#external-to-nodeportservice) for details on the iptable rules.
