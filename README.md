# Agent Box

This repository contains two Azure Developer CLI (`azd`) projects for Windows development VMs:

- [Agent Box](agent-box/README.md): A development VM with Microsoft Foundry resources.
- [App Modernisation Workshop](appmod-box/README.md): A development VM with tools for the app modernisation workshop.

Each project has its own azd environment. If you deploy both projects in the same subscription, use different environment names: both create a resource group named `rg-{environmentName}`.
