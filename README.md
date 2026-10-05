# Fuji San

설치해서 사용하는 **FUJIFILM X100VI 레시피 관리 앱**. Flutter로 Windows,
macOS, Android, iOS 화면을 공유하고 각 OS의 네이티브 USB API로 연결합니다.
브라우저, WebUSB, 계정, 서버가 필요하지 않습니다.

![Desktop recipe workspace](docs/desktop.png)

<img src="docs/mobile.png" alt="Mobile recipe library" width="300" />

화면 예시의 레시피는 UI 검토용 데이터이며 앱에 기본 제공되는 검증된 레시피가 아닙니다.

> **Experimental 0.2.5 — Windows 실기기 읽기 확인, 쓰기 미검증.** 레시피 관리, 네이티브 USB 연결 코드,
> 백업 및 검증을 포함한 일괄 쓰기가 구현되어 있습니다. 빌드 성공은 실제
> 카메라 호환성 검증을 의미하지 않습니다. 아직 모든 OS에서 전송이 검증된
> 완성품으로 배포하지 않습니다.

## 기능

- 한국어 네이티브 UI: 데스크톱 3열 / 모바일 하단 탐색
- 필름 시뮬레이션, WB, 톤, 그레인 등 레시피 편집 및 로컬 저장
- 레시피 카드 드래그 앤 드롭으로 라이브러리 순서 변경 (터치 화면은 길게 누른 뒤 끌기)
- 공개 레시피 540개 내장: 필름 시뮬레이션 탭, DR·컬러 크롬·FX Blue 태그 필터, 설정값 정렬, 검색으로 찾아 설정·원문을 확인하고 라이브러리에 추가 (제작자·출처 표시, X-Trans IV/V용)
- 자체 JSON v1 가져오기 / 클립보드 내보내기 (OFR·FP1 호환 아님)
- C1–C7 레시피 배치 및 선택 슬롯 일괄 적용
- 연결 시 카메라에 저장된 C1–C7 이름·필름·상세 설정 자동 조회, 수동 새로고침
- 카메라 현재 레시피와 전송 대기 레시피를 별도로 표시
- C1–C7 카드를 눌러 현재 이름·설정을 직접 수정하고 해당 슬롯에 저장. 변경 항목만 백업 후 전송·읽기 검증하며, 다른 레시피 배치는 별도 교체 버튼으로 제공
- 시작 시 및 6시간마다 GitHub 새 버전 자동 확인, Windows 다운로드·검증·교체·재시작
- 쓰기 전 해당 슬롯의 알려진 레시피 필드 백업을 디스크에 저장
- 카메라 속성 설명 또는 검증된 기종별 설정 범위 확인 및 쓰기 후 읽기 검증
- 실패 시 즉시 중단, 원본 백업을 통한 수동 복원
- 이미지 크기·화질 등 미확인 속성은 쓰지 않음

카드의 색상 띠는 장식이며 사진 결과를 시뮬레이션하지 않습니다.
백업은 앱이 다루는 레시피 설정 및 이름만 포함하며 카메라 전체 백업이 아닙니다.
사진, Wi-Fi, Bluetooth, RAW 렌더링, 커뮤니티 서버는 이 버전에 포함하지 않습니다.

## 플랫폼 및 연결

| 플랫폼 | 네이티브 연결 | 요구 사항 | 실기기 검증 |
|---|---|---|---|
| Windows | 기본 WPD/MTP + WinUSB 대체 경로 | Windows 기본 드라이버 사용 | X100VI 1.32 연결·읽기 확인, 쓰기 미검증 |
| macOS | ImageCaptureCore | 카메라 접근 권한 | 미검증 |
| Android | USB Host API | OTG/USB Host, USB 접근 권한 | 미검증 |
| iOS / iPadOS 15.2+ | ImageCaptureCore | 카메라 제어 권한, 데이터 케이블/어댑터 | 미검증 |

1. X100VI USB 모드를 **USB RAW CONV./BACKUP RESTORE**로 설정합니다.
2. X RAW STUDIO, 사진 가져오기 등 다른 카메라 프로그램을 종료합니다.
3. 데이터 케이블로 연결하고 앱에서 **카메라 연결**을 누릅니다.
4. **카메라 전체 백업**으로 C1–C7의 레시피 설정을 먼저 보관합니다.
5. 테스트용 한 슬롯으로 쓰기·읽기·복원을 확인한 뒤 여러 슬롯으로 확장합니다.

Windows는 기본 `wpdmtp.inf` 드라이버를 그대로 사용합니다. **WinUSB로 드라이버를
교체할 필요가 없습니다.** 기존에 WinUSB를 사용하는 장치는 대체 경로로 연결됩니다.

X100VI 펌웨어 1.32에서 장치 정보, 현재 슬롯 및 레시피 속성 읽기를 확인했습니다.
이 펌웨어는 `GetDevicePropDesc`를 지원 목록에 표시하지만 실제로 `0x2002`를
반환합니다. 이 조합에 한해 문서화된 X100VI 설정 범위로 검증하고 쓰기 후 값을
다시 읽습니다. 다른 펌웨어의 설명 요청 오류를 무조건 무시하지 않습니다.

한 번에 적용은 순차 작업이며 원자적 트랜잭션이 아닙니다. 전송 중 케이블이
분리되면 현재 슬롯이 부분 변경되고 앞선 슬롯은 완료되었을 수 있습니다.
재연결 후 백업 메뉴에서 복원하세요. 자동 롤백은 수행하지 않습니다.

## 개발

### 업데이트

Windows에서는 새 버전이 나오면 상단 업데이트 아이콘 또는 **도구 → 앱 업데이트**에서
**업데이트 후 재시작**을 누릅니다. ZIP 다운로드 크기와 GitHub의 SHA-256 digest를
검증하고, 교체할 폴더를 미리 준비한 뒤 USB 연결을 종료하고 재시작합니다.
카메라 작업 중에는 업데이트를 시작할 수 없습니다. 오프라인이어도 레시피 작업은 가능합니다.
현재 앱 폴더와 그 상위 폴더에 쓰기 권한이 필요합니다. 이전 앱은 같은 상위 폴더의
`.fuji-san-previous-*`에 보관하며 교체 실패 시 복구합니다. 라이브러리·백업은 앱 폴더 밖에 유지됩니다.
0.1.x에는 업데이트 기능이 없고, 0.2.0–0.2.4는 업데이트 도우미 문제로 앱 내 업데이트가 완료되지 않습니다
(0.2.2 이하는 **업데이트 준비 시간 초과**, 0.2.3–0.2.4는 재시작 후에도 이전 버전 유지). 이 버전들에서는
**새 버전 ZIP을 한 번 직접 설치**해야 합니다.

macOS·Android·iOS는 자동 버전 확인과 배포 페이지 열기를 지원하며 **자동 설치는 아직 지원하지 않습니다**.
서명·공증/고정 서명 키/스토어 배포 체계가 준비되지 않은 개발 빌드입니다.
iOS 배포 파일은 여전히 직접 설치 가능한 IPA가 아닙니다.
알파 버전은 공개 prerelease도 확인하고 정식 버전은 정식 릴리스만 확인합니다.
자동 확인은 GitHub에 접속하지만 레시피나 카메라 정보를 전송하지 않습니다.

카메라 슬롯 조회는 C1부터 C7까지 선택해 이름과 알려진 레시피 필드를 읽고 원래 슬롯을
복원·검증합니다. 레시피 값은 쓰지 않습니다. 조회 중 USB가 분리되면 원래 슬롯 복원이
불가능할 수 있으므로 다시 연결해 카메라 선택 슬롯을 확인하세요.

`fuji_san.exe --diagnose-slots result.json`은 같은 경로로 일곱 슬롯을 검사합니다.
결과에는 레시피 이름·설정이 들어가므로 공유 전에 내용을 확인하세요.

### 빌드 도구

Flutter **3.47.6 stable**, Dart 3.13 이상. 플랫폼 빌드 도구는 별도 필요합니다.

```sh
flutter pub get
dart run tool/sync_apple.dart --check
flutter analyze
flutter test
flutter run -d windows   # Windows + Visual Studio C++ 도구
flutter run -d macos     # macOS + Xcode
flutter run             # 연결한 Android/iOS 기기 선택
```

Apple USB 공유 소스는 `native/apple/FujiUsb.swift`입니다. 수정 후
`dart run tool/sync_apple.dart`로 두 Runner 사본을 갱신합니다.

## 빌드 / 설치

[GitHub Actions](https://github.com/reikop/fuji-san/actions)에서 네 플랫폼을 빌드합니다.
성공한 실행의 Artifacts에서 결과를 받을 수 있습니다.

- Windows: ZIP을 폴더에 풀고 `fuji_san.exe` 실행. 나머지 파일도 함께 보관합니다.
  서명되지 않은 빌드이며 Microsoft Visual C++ 런타임이 필요할 수 있습니다.
- Android: 개발용 debug APK. 스토어 배포용 서명 아님.
- macOS: TAR.GZ를 풀어 앱 실행. 실행 권한·심볼릭 링크를 보존하는 압축 파일입니다.
  서명·공증 없는 개발 빌드로 다운로드 후 로컬 서명 등이 필요할 수 있습니다.
- iOS: **서명 없는 컴파일 결과**. 바로 설치하는 IPA가 아니며 실기기 설치에는
  macOS/Xcode에서 개인 또는 개발자 팀 서명이 필요함. 계정 키는 저장소에 없음.

## 구조 및 데이터

`lib/domain` 레시피 검증 · `lib/camera` PTP/백업/일괄 쓰기 · `lib/storage.dart`
영속 저장 · `android` USB Host · `windows/runner/wpd_camera.cpp` WPD · `windows/runner/fuji_usb.cpp` WinUSB/앱 연결 ·
`native/apple` ImageCaptureCore · `test` 프로토콜·실패 경로·화면 테스트.

설정은 애플리케이션 지원 폴더의 `fuji-san` 아래 보관합니다. 백업에는 연결된
카메라 시리얼 번호가 포함됩니다. 앱은 이를 업로드하지 않습니다.

Windows에서 읽기 전용 연결 진단은 `fuji_san.exe --diagnose-camera result.json`으로
실행할 수 있습니다. 앱과 동일한 연결·모델 검사 경로를 사용하며 장치 정보와
현재 슬롯/필름 시뮬레이션만 읽습니다. 슬롯 선택이나 레시피 쓰기는 하지 않습니다.

MIT. 자료 출처 및 라이선스는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
FUJIFILM과 무관한 독립 오픈소스 프로젝트입니다.
