Kubernetes Installation on vSphere with PowerCLI and CoreOS
===
This guide woks a deployer though lauching a multi-node Kubernetes cluster using VMware vSphere PowerCLI and CoreOS. After compreting this guide, a deployer will be able to interact with the Kubernetes API from their workstation using the `kubectl` CLI tool.

# Install Prerequisites

## Administrative permission

Deployer must own Administrative permission on the workstation in order ton install the several software packages required. 

## Windows Management Framework 5.1

The Powershell modules hardly depends on Windows Powershell 5.O features. 

If WMF version 5.0 or later is not installed.
Navigate to the [Windows Management Framework 5.x downloads page]() and grabe the appropriate package for your system. Install the WMF update before continuing. 

## Chocolatey

