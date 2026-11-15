# 번역 점검 도구

1. `swift build -c release --build-path /tmp/b -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc /tmp/strings`
   → 컴파일러가 실제로 번역 키로 쓰는 문구(.stringsdata)
2. `python3 ../build_strings.py /tmp/strings` → 빠진 번역·형식 지정자 불일치 검사, `en.lproj`·`ko.lproj` 생성
3. 자리마다 번역되는지 (`Text("…")` 처럼 자동인 곳 말고, 일반 `String` 으로 쓰여 번역이 안 되는 곳 찾기):
   `mark.py <작업폴더> mark` 가 소스 복사본의 한글 문구마다 `⟦번호⟧` 를 붙이고, 그 복사본을 1번처럼 빌드한 뒤
   `mark.py <작업폴더> check` 가 키에 안 나온 번호(= 번역 안 되는 자리)를 알려 준다. 그 자리는 `String(localized: "…")` 로 감싼다.
