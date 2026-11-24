# Codemagic API 用法（3105 出未签名 IPA）

GitHub Actions 的 macOS runner 排队太慢，改用 Codemagic 的 Mac 机器出包。

## 0. 前置（一次性）

1. 登录 https://codemagic.io/ ，用 GitHub 账号授权。
2. `Add application` → 选 `jixui666/jsq-baseline-ocrfix` → 分支 `main`
   （Codemagic 会自动读取仓库根目录的 `codemagic.yaml`）。
3. 拿到 **App ID**：应用页 URL 里的那串，例如
   `https://codemagic.io/app/66f0cxxxxx.../build` → App ID = `66f0cxxxxx...`
4. 拿 **API token**：右上角头像 → `User settings` → `Integrations` → `Codemagic API` → `Generate token`
   （token 只在创建时显示一次）

## 1. 触发构建

```bash
export CM_API_TOKEN="你的 token"
export CM_APP_ID="你的 app id"

curl -s -X POST https://api.codemagic.io/builds \
  -H "Content-Type: application/json" \
  -H "x-auth-token: $CM_API_TOKEN" \
  -d '{
        "appId": "'"$CM_APP_ID"'",
        "workflowId": "ios-ipa",
        "branch": "main"
      }'
```

返回示例：

```json
{"buildId":"66f0d1e5c6a3b2a1d4f0c9b8"}
```

## 2. 查询构建状态

```bash
curl -s -H "x-auth-token: $CM_API_TOKEN" \
  https://api.codemagic.io/builds/$BUILD_ID
```

看 `build.status`：`queued` → `preparing` → `building` → `finished`（失败是 `failed` / `canceled`）。

## 3. 取产物（IPA 下载链接）

```bash
curl -s -H "x-auth-token: $CM_API_TOKEN" \
  https://api.codemagic.io/builds/$BUILD_ID \
| python -c "import sys,json; d=json.load(sys.stdin)['build']; print(json.dumps(d['artifacts'], indent=2))"
```

`artifacts` 里每项形如：

```json
{ "name": "JSQ-unsigned.ipa", "type": "ipa",
  "url": "https://api.codemagic.io/artifacts/....ipa" }
```

直接下载该 url（带 `x-auth-token` 请求头）：

```bash
curl -L -H "x-auth-token: $CM_API_TOKEN" \
  -o JSQ-unsigned.ipa "<artifacts[0].url>"
```

## 4. 不需要的可选项

| 变量 | 作用 |
|---|---|
| `SECRETS_JSON` | 想让 CI 用新配置重新生成 `Secrets.generated.swift` 时设置（内容 = 本地 `tools/secrets.json` 全文）。不设则用仓库里已提交那份 |
| `INTEGRITY_PRIVATE_KEY_PEM` | Ed25519 私钥 PEM。设置后会自动跑 `keygen.py` + `integrity_pack.py` 给包签名并内嵌完整性清单；不设则跳过（测试包已用 `INTEGRITY_DISABLED` 编译，不会被 `IntegrityGuard` 杀掉进程） |

在 Codemagic：`App settings` → `Environment variables` 里加，勾选 **Secure**。
