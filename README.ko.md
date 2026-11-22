# Agent Box

[English](README.md) | **한국어**

이 저장소에는 Windows 개발 VM을 위한 Azure Developer CLI(`azd`) 프로젝트 두 개가 있습니다.

- [Agent Box](agent-box/README.ko.md): Microsoft Foundry 리소스를 포함한 개발 VM입니다.
- [App Modernisation Workshop](appmod-box/README.ko.md): 앱 현대화 워크숍 도구를 포함한 개발 VM입니다.

각 프로젝트는 별도의 azd 환경을 사용합니다. 두 프로젝트를 같은 구독에 배포한다면 환경 이름을 다르게 지정합니다. 두 프로젝트 모두 `rg-{environmentName}`이라는 이름으로 리소스 그룹을 만들기 때문입니다.
