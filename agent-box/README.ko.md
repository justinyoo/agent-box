# Agent Box

[English](README.md) | **한국어**

[저장소 템플릿 안내](../README.md)

Agent Box는 Bastion Developer로 접속하고 NAT Gateway를 사용하는 Windows 11 Enterprise 개발 VM을 배포합니다. Microsoft Foundry 계정과 프로젝트를 만들고 `MAI-Image-2.7`도 배포합니다. 도구 설치와 사용자 로그인은 직접 진행합니다.

## 기본 구성

| 항목 | 값 |
| --- | --- |
| 이미지 | `microsoftwindowsdesktop:windows-11:win11-26h2-ent:latest` |
| VM | `Standard_D64ds_v7` |
| OS 디스크 | Premium SSD, 127 GiB |
| 부팅 보안 | Trusted Launch, Secure Boot, vTPM |
| Windows 로그인 | 기본 `.\agentboxuser`, 로컬 관리자 |
| 접속 | Azure portal의 Bastion Developer. VM 공용 IP와 공용 RDP 규칙 없음 |
| 네트워크 | NAT Gateway를 통해 인터넷 접속 |
| 자동 종료 | 매일 한국 시간 00:00 |

VM과 Foundry의 리전은 각각 별도로 설정합니다. Foundry 리전은 `eastus`, `swedencentral`, `westeurope`, `westus`로 제한합니다. 이 리전은 2026-11-21에 확인한 이미지 모델 카탈로그와 Speech 모델의 사용 가능 리전이 겹치는 곳입니다. 이 정보는 배포 또는 로컬 추론을 보장하지 않습니다. 프로비저닝 전에 현재 모델 사용 가능 여부와 할당량을 확인합니다.

## 사전 준비

- [Azure 구독](https://aka.ms/azure/free)
- [`azd` CLI 1.35.1 이상](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [Azure에서 Windows 클라이언트를 사용할 라이선스 자격](https://learn.microsoft.com/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment)

## 배포

1. `agent-box` 디렉터리로 이동합니다.

   ```bash
   cd agent-box
   ```

1. Copilot app 터미널에서 azd CLI를 실행하는 경우 다음과 같이 환경 변수를 설정합니다.

   ```bash
   # zsh/bash
   export AZD_NON_INTERACTIVE=false
   ```

   ```powershell
   # PowerShell
   $env:AZD_NON_INTERACTIVE = 'false'
   ```

1. Azure에 로그인합니다.

   ```bash
   azd auth login
   az login
   ```

1. 배포를 시작합니다.

   ```bash
   azd up
   ```

   azd에서 보안 Windows 관리자 암호, Windows 클라이언트 라이선스 확인 및 기타 누락된 값을 입력하라는 메시지가 표시됩니다.

## 로그인과 도구 설치

1. `azd provision` 또는 `azd up` 출력에서 Windows 로그인 사용자 이름을 확인합니다. Azure portal에서 VM의 **Connect > Bastion**을 선택하고 해당 로컬 관리자 계정(기본값 `.\agentboxuser`)과 프로비저닝 시 입력한 암호로 로그인합니다.
1. 같은 계정으로 PowerShell을 **관리자 권한으로 실행**합니다.
1. 다음 명령을 실행하고 요청된 항목에 동의합니다.

   ```powershell
   & "$HOME\scripts\install-vm-tools.ps1"
   ```

   기본적으로 설치와 설정 변경 항목마다 동의를 받습니다. `-Yes`를 추가하면 나열된 모든 작업과 패키지 약관에 한 번에 동의합니다.

   ```powershell
   & "$HOME\scripts\install-vm-tools.ps1" -Yes
   ```

1. 재부팅 안내가 나오면 작업을 저장하고 VM을 직접 재부팅한 뒤 같은 명령을 다시 실행합니다.

### 설치 대상

설치기는 다음 순서로 도구를 설치하며 재부팅이 필요하면 중단합니다.

| 그룹 | 도구 | 설치와 확인 방식 |
| --- | --- | --- |
| 1. 설치 사전 요구 사항 | WinGet | App Installer 등록 또는 설치 |
| 1. 설치 사전 요구 사항 | PowerShell | 7.x 정식 버전 |
| 2. Windows 기능 | WSL2 플랫폼 | `wsl.exe --install --no-distribution`으로 배포판 없이 설치. 안내가 나오면 직접 재부팅 |
| 2. Windows 기능 | Ubuntu | WSL2 설치 후 로그인한 관리자 계정에 등록 |
| 3. 런타임 및 SDK | .NET 10 SDK | `Microsoft.DotNet.SDK.10`, 10.x 정식 버전 |
| 3. 런타임 및 SDK | .NET 11 SDK | `Microsoft.DotNet.SDK.11`, 11.x 정식 버전. .NET 10과 함께 설치 |
| 3. 런타임 및 SDK | uv | `astral-sh.uv` |
| 3. 런타임 및 SDK | nvm-windows, Node.js | nvm-windows 2.x 정식 패키지와 설치기 실행 시 사용 가능한 최신 Node.js LTS 정식 버전 |
| 3. 런타임 및 SDK | Python | uv 및 uv에서 사용 가능한 최신 Python 3.14 패치 버전 |
| 4. 컨테이너 | Docker Desktop | WSL2 백엔드로 설치. 최초 실행과 약관 확인은 수동으로 진행 |
| 5. GitHub 도구 | Git | `Git.Git` |
| 5. GitHub 도구 | GitHub CLI | `GitHub.cli`, 2.45.0 이상 |
| 5. GitHub 도구 | GitHub Copilot CLI | `GitHub.Copilot`. `copilot --version`으로 확인 |
| 6. Azure 도구 | Azure CLI | `Microsoft.AzureCLI` |
| 6. Azure 도구 | azd | `Microsoft.Azd` |
| 7. 편집기 및 앱 | VS Code | `Microsoft.VisualStudioCode` |
| 7. 편집기 및 앱 | GitHub Copilot app | 공식 `github/app` x64 MSI. GitHub Authenticode 서명을 확인하고 릴리스 SHA-256 다이제스트가 게시된 경우 함께 확인 |

uv bin에 충돌하는 실행 파일이 없으면 설치기는 다른 Python 명령이 우선하더라도 uv의 실험적인 `--default` 옵션을 사용해 `python.exe`를 만듭니다. 기본 Python 버전에 대해 다음 명령을 실행합니다.

```powershell
uv.exe python install 3.14 --default --no-config --no-progress
```

### 설치 후 수동 작업

1. 안내가 나오면 Windows를 재부팅하고 설치기가 확인에 성공했다고 보고할 때까지 다시 실행합니다.
1. `wsl -d Ubuntu`를 실행해 첫 번째 Linux 사용자를 만듭니다.
1. Docker Desktop을 시작해 최초 실행 설정과 약관 확인을 마치고 Linux 컨테이너를 확인합니다.
1. Copilot app에 로그인하고 필요에 따라 Azure CLI와 GitHub CLI를 인증합니다.

## Foundry 출력

템플릿은 `MAI-Image-2.7` 이미지 모델을 배포합니다. Speech API 모델 식별자도 출력하며 기본값은 `MAI-Voice-2.1`과 `MAI-Transcribe-2`이지만, 해당 모델은 배포하지 않습니다.

유용한 배포 출력은 다음과 같습니다.

| 출력 | 용도 |
| --- | --- |
| `AZURE_RESOURCE_GROUP`, `AZURE_VM_NAME`, `AZURE_VM_ID` | VM 및 리소스 그룹 식별 정보 |
| `AZURE_BASTION_NAME` | Bastion Developer 리소스 |
| `FOUNDRY_ACCOUNT_NAME`, `FOUNDRY_ACCOUNT_ID` | Foundry 계정 식별 정보 |
| `FOUNDRY_PROJECT_NAME`, `FOUNDRY_PROJECT_ENDPOINT` | Foundry 프로젝트 연결 정보 |
| `MAI_IMAGE_ENDPOINT`, `MAI_IMAGE_DEPLOYMENT_NAME` | 이미지 모델 엔드포인트와 배포 |
| `AZURE_SPEECH_ENDPOINT`, `AZURE_SPEECH_REGION` | Speech API 엔드포인트와 리전 |
| `MAI_VOICE_MODEL`, `MAI_TRANSCRIBE_MODEL` | Speech 모델 식별자 |

템플릿은 계정 키를 가져오거나 출력하지 않습니다. 또한 모델 추론 권한을 구성하거나 추론 요청을 테스트하지 않습니다.

## 리소스 정리

먼저 데이터를 백업합니다. `agent-box` 디렉터리에서 원하는 azd 환경만 삭제합니다.

```console
azd down --environment <environment-name>
```
