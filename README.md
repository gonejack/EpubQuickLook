# EPUB Quick Look

Finder에서 `.epub` 파일을 **스페이스바로 바로 읽을 수 있게** 해주는 macOS Quick Look 확장입니다.
아이콘에는 책 표지가 표시됩니다.

- 📖 **본문 미리보기** — 표지·제목·지은이·출판사와 목차, 그리고 본문을 이어서 보여줍니다
- 🖼 **표지 썸네일** — Finder 아이콘이 책 표지가 됩니다
- 🌗 **다크 모드 지원** — 밝은 배경을 전제로 만들어진 EPUB도 어둡게 보정합니다
- 🔒 **안전** — JavaScript 실행, 외부 링크 이동, 원격 이미지 요청을 모두 차단합니다
- 📦 **의존성 없음** — ZIP 해제와 EPUB(OPF/NCX/nav) 파싱을 직접 구현했습니다. EPUB 2·3 모두 지원

<br>

## 설치 (릴리스 파일 사용)

1. [Releases](../../releases/latest)에서 `EPUB-Quick-Look.zip`을 내려받아 압축을 풉니다.
2. `EPUB Quick Look.app`을 **응용 프로그램 폴더**(또는 `~/Applications`)로 옮깁니다.
3. 터미널에서 격리 속성을 제거합니다. 이 앱은 Apple 공증(notarization)을 받지 않았기 때문에 이 단계가 필요합니다.

   ```bash
   xattr -dr com.apple.quarantine "/Applications/EPUB Quick Look.app"
   ```

4. 앱을 **한 번 실행**합니다. 이때 시스템에 Quick Look 확장이 등록됩니다.
   (실행 후 앱은 종료해도 됩니다. 확장은 계속 동작합니다.)
5. Finder에서 `.epub` 파일을 선택하고 **스페이스바**를 눌러보세요.

미리보기가 바로 보이지 않으면:

```bash
qlmanage -r && qlmanage -r cache && killall Finder
```

확장이 켜져 있는지는 **시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램 › 훑어보기(Quick Look)** 에서 확인할 수 있습니다.

> **`"손상되었기 때문에 열 수 없습니다"` 라고 나온다면** 3번의 `xattr` 명령을 실행하지 않은 것입니다.
> 브라우저로 내려받은 파일에 macOS가 격리 딱지를 붙여 생기는 현상이며, 앱 자체 문제가 아닙니다.

<br>

## 직접 빌드하기

Xcode 명령줄 도구만 있으면 됩니다. 별도 프로젝트 파일이나 패키지 매니저는 필요 없습니다.

```bash
git clone https://github.com/Oein/epubQuickLook.git
cd epubQuickLook

./build.sh            # build/EPUB Quick Look.app 생성
./build.sh install    # 빌드 후 ~/Applications 에 설치하고 Quick Look 캐시 갱신
./build.sh uninstall  # 설치 제거
```

빌드 결과물은 arm64 + x86_64 유니버설 바이너리이며, ad-hoc 서명됩니다.

<br>

## 구조

```
Sources/
  EPUBKit/                 세 타깃이 공유하는 코어 (외부 의존성 없음)
    ZipArchive.swift       Compression 프레임워크 기반 ZIP 리더 (store/deflate, ZIP64)
    EPUBDocument.swift     container.xml → OPF 파싱, 메타데이터·spine·표지·목차
    PreviewHTMLBuilder.swift  spine을 이어붙인 단일 HTML 미리보기 문서 생성
  PreviewExtension/        QLPreviewingController — WKWebView 렌더링
  ThumbnailExtension/      QLThumbnailProvider — 표지 썸네일
  App/                     호스트 앱 (확장 등록 + 내장 뷰어)
Resources/                 Info.plist 3종, entitlements 2종
build.sh                   빌드 · 서명 · 설치 스크립트
```

### 동작 방식

미리보기 확장은 EPUB을 샌드박스 임시 디렉터리에 풀고, spine 순서대로 각 XHTML의 `<body>`를 모아
하나의 HTML 문서로 합칩니다. 이 과정에서

- 이미지·스타일시트의 상대 경로를 풀어낸 파일의 절대 경로로 바꾸고,
- 미리보기에 포함된 다른 챕터를 가리키는 링크는 문서 내부 앵커(`#ql-ch-N`)로 바꾸며,
- `<script>`·`<iframe>`과 원격 리소스 참조는 제거합니다.

### 구현 메모

같은 문제로 시간을 쓰지 않도록 남겨 둡니다.

- **샌드박스 앱의 `WKWebView`에는 `com.apple.security.network.client` 권한이 필요합니다.**
  이 권한이 없으면 로컬 `file://` 문서조차 로드되지 않고, `didFail` 콜백조차 오지 않습니다.
- **`allowingReadAccessTo:` 에는 심볼릭 링크를 푼 실제 경로를 넘겨야 합니다.**
  `NSTemporaryDirectory()`는 `/var/folders/...`를 돌려주는데, Foundation의
  `resolvingSymlinksInPath()`는 `/private` 접두어를 다시 떼어내므로 `realpath(3)`를 씁니다.
- 앱 확장은 `main` 대신 `NSExtensionMain`이 진입점이라 링크할 때
  `-Xlinker -e -Xlinker _NSExtensionMain`을 지정합니다.

<br>

## 제한 사항

- DRM이 걸린 EPUB은 열 수 없습니다.
- 미리보기는 앞부분 최대 100개 문서(약 300만 자)까지만 표시합니다.
- 고정 레이아웃(fixed-layout) EPUB은 원본 배치 그대로 재현되지 않을 수 있습니다.

<br>

## 라이선스

MIT
