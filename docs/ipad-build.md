# iPad 빌드 결과물

Mac에서 Xcode와 iOS SDK, XcodeGen을 준비한 뒤 저장소 루트에서 다음 명령을 실행한다.

```sh
python3 tools/build_ipad_artifact.py
```

일반 앱의 Release/arm64 바이너리를 빌드하고 `.build/ipad-build/ReedlesCanvas-unsigned.ipa`로 묶는다. 시험 앱 소스는 이 기기 빌드에서 제외한다. 원본 커밋, Xcode/SDK, 파일 해시와 서명 여부는 같은 디렉터리의 `device-build.json`에 기록한다. 빌드 로그는 `device-build.log`다. 앱을 실행하거나 테스트·BAZE 호출을 하지 않는다.

IPA는 Apple 인증서나 프로비저닝 프로파일 없이 생성하는 **미서명 결과물**이다. 그대로 iPad에 설치할 수 없으며 기기 설치에는 적절한 Apple 서명과 프로비저닝이 필요하다. [기존 개인 설치 안내](ipad-device-spike.md)를 참고한다. Swift Playgrounds에서 소스를 여는 기존 경로는 `ReedlesCanvas-App.swiftpm.zip`을 사용한다.

GitHub Actions의 `Normal app preview`를 수동 실행하면 시뮬레이터 컴파일과 이 기기 빌드를 수행한다. 브랜치 푸시에서는 `[app-preview] [compile-only] [device-build]` 메시지를 사용한다. 이는 테스트 통과나 보고된 실기기 크래시 해결을 의미하지 않는다.
