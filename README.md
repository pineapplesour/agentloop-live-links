# Agentloop Live Links

Cloudflare quick tunnel 주소가 바뀌어도 사용자가 항상 같은 GitHub Pages 주소에서 최신 작업물을 열 수 있게 하는 정적 링크 허브입니다.

## 현재 포함 링크

- 랄피 Live 최신 CareBridge
- 랄피 디자인 비교 보드
- 디자인 후보 개별 링크 4개

## 터널 URL 갱신

```bash
node scripts/update-links.mjs --base https://새터널.trycloudflare.com --commit
```

이 명령은 `links.json`의 모든 trycloudflare 링크를 새 base로 갱신하고 커밋/푸시합니다.

## 주의

- 이 repo에는 API 키나 민감정보를 넣지 않습니다.
- 실제 앱은 로컬 서버와 Cloudflare tunnel에서 동작합니다.
- CareBridge는 `20260626-native-live-audio` 어댑터가 붙어야 하며, 옛 챗봇 어댑터가 보이면 서버/터널을 재시작하고 `links.json`을 다시 갱신합니다.
