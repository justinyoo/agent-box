# Contributing

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities privately as described in the [security policy](SECURITY.md).

## Development

The repository contains two independent Azure Developer CLI templates. See the [project guides](README.md) for deployment instructions.

Local validation requires Python 3, Bash, PowerShell 7, Azure Developer CLI, and Azure CLI with Bicep installed. Run:

```bash
python3 tests/validate.py
pwsh -NoLogo -NoProfile -File tests/Test-Scripts.ps1
```

These checks do not deploy Azure resources or verify software on a Windows VM. Back up data and review costs before deploying or deleting resources.

## Pull requests

Describe the change and how you verified it. Open an issue for larger changes to discuss the approach before implementation.
