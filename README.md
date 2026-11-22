# Agent Box and App Modernisation Workshop

This repository contains two independent Azure Developer CLI (`azd`) projects for Windows development VMs:

| Template | Default VM | Local administrator | Additional resources |
| --- | --- | --- | --- |
| Agent Box | `Standard_D64ds_v7`, Windows 11 Enterprise 26H2 | `agentboxuser` | Bastion Developer, NAT Gateway, Microsoft Foundry MAI image deployment and Speech endpoint |
| App Modernisation Workshop | `Standard_D8s_v5`, Windows 11 Enterprise 26H2 | `appmoduser` | Bastion Developer, NAT Gateway, original workshop tool installer |

Each project has its own `azure.yaml`, infrastructure, and azd environments. Both use Bastion for access and leave tool installation to the signed-in user.

Each project's `infra/scripts/preprovision` hook handles its own settings and calls its local `package-user-scripts` script. Regional availability checks and hook message formatting are shared under `shared/`. Status messages use the same colors as the VM installers on terminals; `NO_COLOR`, `CI`, `TERM=dumb`, and redirected output disable those colors. PowerShell errors use the host's error formatting.
VM tool installers live separately in each project's `scripts/` directory; App Modernisation also includes the Build Tools configuration there.

## Deploy

Choose a project directory before running azd. Use different environment names if provisioning both projects in the same subscription, because both use `rg-{environmentName}`.

```console
cd agent-box
# Or: cd appmod-box
azd auth login
az login
azd env new <environment-name> --location <azure-region>
azd up
```

Each project's initial azd region picker uses a maintained snapshot of [Bastion Developer](https://learn.microsoft.com/azure/bastion/bastion-sku-comparison#regional-availability) and default VM image availability checked on 2026-11-22. Agent Box further limits candidates to regions where its default VM size appeared in a SKU lookup, including subscription-restricted entries, without filtering by zone. The snapshot uses one subscription and may omit other supported regions. Before provisioning, the hook checks the chosen image and size in the selected subscription; Agent Box selects the lowest unrestricted availability zone unless `VM_ZONE` is set. Missing or restricted zones stop provisioning, and an existing VM's zone is retained. The Azure CLI must be signed in to the same subscription as azd; an inaccessible subscription or failed lookup stops provisioning. These checks do not guarantee quota or capacity. To choose another listed region, run `azd env set AZURE_LOCATION <region>` and retry. Review the `location` allowlists in each project's `infra/main.bicep` when Azure availability changes.

Agent Box limits the separate Foundry region selection to `eastus`, `swedencentral`, `westeurope`, and `westus`. These regions overlap the image model catalog and Speech model availability checked on 2026-11-21; verify current availability and quota before provisioning.

After confirming Windows client virtualization eligibility, set `azd env config set infra.parameters.confirmWindowsClientLicense true` for CI or another non-interactive context. The former `CONFIRM_WINDOWS_CLIENT_LICENSE` environment variable is no longer used. Agent Box also requires `MAI_FOUNDRY_REGION`. Supply `VM_ADMIN_PASSWORD` through a secret store. Each project's local administrator defaults to the name in the table above and can be changed before deployment with `azd env set VM_ADMIN_USERNAME <username>`. If azd automatically enables no-prompt mode in an AI-agent environment but you want an interactive first run, set `AZD_NON_INTERACTIVE=false` for that azd invocation. Do not rely on an implicit default.

Provisioning prompts for the secure Windows administrator password and creates billable Azure resources. Neither project installs tools during deployment: sign in through Azure Bastion and run the selected project's installer manually. See [Agent Box setup](agent-box/README.md) or the [workshop VM guide](appmod-box/README.md).

## Important notes

- Both VMs have no public IP. Use **Azure portal > VM > Connect > Bastion**. Bastion Developer is available only in supported regions and has fewer connection features than the dedicated Bastion tiers.
- Both templates default to automatic VM shutdown at **00:00 Korea Standard Time**. The workshop time can be changed with `APP_MOD_AUTO_SHUTDOWN_TIME` in `HHmm` format. A stopped VM can still incur charges for disks, NAT Gateway, public IP, and other retained resources.
- Agent Box's WSL2 and Docker Desktop behavior must be verified manually after deployment. Docker Desktop is installed with the WSL2 backend; its first launch and terms acceptance are manual.
- Docker Desktop is free for personal use, education, non-commercial open source, and qualifying small businesses. Commercial use in organizations with 250 or more employees **or** more than USD 10 million in annual revenue requires a paid subscription. See [Docker Desktop licensing](https://www.docker.com/legal/docker-subscription-service-agreement/).
- Agent Box deploys `MAI-Image-2.7`; `MAI-Voice-2.1` and `MAI-Transcribe-2` are exposed as Speech API model identifiers, not separate model deployments. No keys are emitted as deployment outputs.
- Run `azd down --environment <environment-name>` from the corresponding project directory to delete that environment's resources. Back up VM data before cleanup.

## Local validation

```console
python3 tests/validate.py
```

The checks require `azd`, Azure CLI with Bicep support, Python 3, Bash, and PowerShell 7. They compile and inspect the templates and exercise packaging, both azd hook platforms in temporary projects, and script syntax. They do not deploy to Azure or verify actual Windows, WSL2, Docker, Bastion, Speech, or model availability.
