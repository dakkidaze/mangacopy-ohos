# CopyManga Flutter 发版工作流（AI Agent Workflow）

这是一份写给 AI Agent / 维护者的 **Flutter 版**发版 SOP。当你被要求「发布 Flutter 新版本」或「执行 Flutter 发版工作流」时，严格按本文操作。

> **注意**：Kotlin 原生版有另一份独立 SOP：`../copymanga-src/workflow.md`。两套流程不要混用。

---

## ⛔ 0.-1 目录沙箱（先读；违反即停）

本 SOP **只允许**操作下列路径，保护 Kotlin 工程不被误删/覆盖：

| 允许 | 路径 |
|------|------|
| 日常开发 | **仅** `d:\vibe coding\rebuild_copymanga\copymanga_flutter\` |
| 发版 git | **仅** `d:\vibe coding\rebuild_copymanga\_flutter_wt\`（`commit`/`push origin flutter`/`tag`） |
| 签名密钥（只读引用） | 工作区根 `..\keystore.jks` |
| 同源脚本（唯一跨项目写） | 改 `assets/js/i.js`/`h.js` 时可同步复制到 `..\copymanga-src\app\src\main\assets\`（**只动这两文件**） |

**绝对禁止：**

- 对 `..\copymanga-src\` 执行删除、清空、写空文件、整树覆盖、`gradlew clean`（除非用户明确只要清 Kotlin）、改 `app/build.gradle` 等
- 在 `copymanga_flutter` 里直接 `git commit` / `git push`（该目录通常不是 flutter 工作树；乱操作曾清空源文件）
- robocopy **反向**（`_flutter_wt` → `copymanga_flutter`）或任何方向把 Flutter 文件拷进 `copymanga-src`
- 推送 Tag `v*`（无 `flutter-` 前缀）、上传 `copymanga_x.y.z.apk`（那是 Kotlin SOP）
- 删除或截断本工程 / worktree 的 `pubspec.yaml`、`workflow.md`、`lib/**`、`.gitignore` 等骨架文件

发版前除 §0.2 本侧完整性检查外，再确认 Kotlin 侧仍在：

```powershell
$kt = "d:\vibe coding\rebuild_copymanga\copymanga-src"
if (-not (Test-Path "$kt\app\build.gradle") -or (Get-Item "$kt\app\build.gradle").Length -lt 50) {
  throw "ABORT: Kotlin 工程疑似被破坏，先恢复 copymanga-src 再继续 Flutter 发版"
}
```

工作区总览沙箱条款见 `..\AGENTS.md`「目录沙箱」。

---

## 0. 项目基本事实（先读，避免踩坑）

| 项 | 值 |
|----|-----|
| 本地工程路径 | `d:\vibe coding\rebuild_copymanga\copymanga_flutter` |
| 工作区根 | `d:\vibe coding\rebuild_copymanga` |
| Git 远程（与 Kotlin **同一仓库**） | `https://github.com/jimytao/copymanga.git` |
| **Git 分支** | **`flutter`**（orphan：仓库根 = 本 Flutter 工程） |
| Kotlin 分支（勿推错） | `re_build` |
| Application ID | `top.fumiama.copymanga_flutter` |
| 版本号唯一源 | `pubspec.yaml` 的 `version:` |
| 当前版本 | `1.0.13+14`（versionName=`1.0.13`，versionCode=`14`） |
| **Git Tag 格式** | **`flutter-vX.Y.Z`**（例：`flutter-v1.0.0`） |
| Kotlin Tag 格式（勿混用） | `vX.Y.Z`（例：`v1.5.13`） |
| 签名密钥库 | 工作区根 `keystore.jks`（与 Kotlin 共用，**不入库**） |
| 签名配置 | `android/app/signing.properties`（**不入库**） |

### 本地目录 ↔ GitHub 映射

```
本地开发目录:  rebuild_copymanga/copymanga_flutter/**   ← 日常改代码只动这里
                     ↓  发版时 robocopy 同步（见 §4）
flutter worktree:  rebuild_copymanga/_flutter_wt/**      ← 唯一允许 git commit/push 到 flutter 的目录
                     ↓  git push origin flutter
远程:  jimytao/copymanga.git  分支 flutter  的仓库根 /**
```

Kotlin 代码在本地的 `copymanga-src/`（分支 `re_build`）。除「同源 `i.js`/`h.js` 双向同步」外，**视其为只读外务**——详见上方 **§0.-1 目录沙箱**。

另禁止：

- 在 `copymanga-src`（`re_build`）里提交 Flutter 文件
- 在 `copymanga_flutter` 里直接 `git commit`（该目录通常不是 flutter 分支工作树；乱操作曾导致源文件被清空）
- 用空文件 / 错误方向的拷贝覆盖任一目录的源码

### 0.2 关键文件：禁止删除、禁止截断为空（必读）

以下文件是工程骨架，**任何脚本/同步/清理步骤都不得 Delete、不得写成 0 字节、不得用空内容覆盖**：

| 路径 | 作用 |
|------|------|
| `pubspec.yaml` / `pubspec.lock` | 版本与依赖唯一源 |
| `workflow.md` / `CHANGELOG.md` / `README.md` / `AGENTS.md`（若有） | 发版 SOP 与说明 |
| `lib/**/*.dart`（尤其 `main.dart`、`browser_page.dart`、`reader_page.dart`、`system_ui.dart`、`splash_page.dart`） | 应用逻辑 |
| `assets/**`、`tool/**` | 资源与辅助脚本 |
| `android/**`、`ios/**`、`.github/**`（除签名隐私文件外） | 平台工程与 CI |

**发版前完整性检查**（在 `copymanga_flutter` 执行，任一项失败则中止发版）：

```powershell
$root = "d:\vibe coding\rebuild_copymanga\copymanga_flutter"
$must = @(
  'pubspec.yaml','workflow.md','CHANGELOG.md',
  'lib\main.dart','lib\browser_page.dart','lib\reader_page.dart',
  'lib\splash_page.dart','lib\system_ui.dart'
)
$bad = @()
foreach ($f in $must) {
  $p = Join-Path $root $f
  if (-not (Test-Path $p) -or (Get-Item $p).Length -lt 50) { $bad += $f }
}
if ($bad.Count -gt 0) { throw "CRITICAL: empty/missing files: $($bad -join ', '). Restore from _flutter_wt or git before release." }
```

若本地被清空：优先从 `_flutter_wt`（已提交的 flutter 分支）或 `git show origin/flutter:路径` **恢复到 `copymanga_flutter`**，再继续开发；**不要**把空文件 robocopy 进 worktree。

### 签名如何生效（Android）

1. `android/app/signing.properties` → `STORE_FILE=../../../keystore.jks` + 密码/别名。
2. `android/app/build.gradle.kts` 读取后配置 `signingConfigs.release`。
3. `flutter build apk --release --split-per-abi` 自动签名（发版强制 split）。

```properties
STORE_FILE=../../../keystore.jks
STORE_PASSWORD=<本地保管，勿写入将要 push 的文件>
KEY_ALIAS=copymanga
KEY_PASSWORD=<本地保管>
```

### 隐私文件（不得 push）

- `android/app/signing.properties`
- 任意 `*.jks` / `*.keystore`（含工作区根 `keystore.jks`）
- 本机 `android/local.properties`、`build/`、`.dart_tool/`
- 可选：本文件若含密码则勿提交；当前正文只用占位符，**可以**随 `flutter` 分支入库供 Agent 查阅

---

## 0.1 分支 / Tag / Release 总表（必读）

| | Kotlin（原生） | Flutter（本工程） |
|--|----------------|-------------------|
| 工作分支 | `re_build` | **`flutter`** |
| 推送 | `git push origin re_build` | `git push origin flutter` |
| Tag | `v1.5.14` | **`flutter-v1.0.3`** |
| 打 Tag | 在 `re_build` 的提交上 | 在 **`flutter`** 的提交上 |
| GitHub Release | Kotlin APK | Flutter APK（本地上传）+ **IPA（Actions 自动挂）** |
| 激活 IPA CI | 无（不要用 `v*` 触发 iOS） | 推送 tag **`flutter-v*`** → `.github/workflows/build-ios.yml` |

**为什么 Tag 必须带 `flutter-` 前缀？**

1. 与 Kotlin 的 `v1.5.x` 不会撞名。
2. Actions 只监听 `flutter-v*`，Kotlin 发版不会误跑 macOS / 误产 IPA。
3. Release 列表里一眼能分清「原生版」和「Flutter 版」。

---

## 1. 滚动版本号

除非用户指定，默认 Patch +1，且 **`+` 后的 versionCode 必须 +1**：

| 场景 | `pubspec.yaml` |
|------|----------------|
| 小修 | `1.0.1+2` → `1.0.2+3` |
| 小功能 | → `1.1.0+4` |
| 大改 | → `2.0.0+5` |

对应 Git Tag：`flutter-v1.0.3`（Tag **不包含** `+code`，只含 versionName）。

---

## 2. 更新文档

1. **`CHANGELOG.md`**：顶部追加 `## YYYY-MM-DD — vX.X.X：…`
2. **`README.md`**：用户可感知功能变更时更新
3. 改了 `assets/js/i.js` / `h.js`：同步到 `../copymanga-src/app/src/main/assets/`，并在两边 CHANGELOG 写一笔

---

## 3. 编译已签名 Android APK（本地）— **必须 split**

> ⛔ **硬性规定**：凡上传 GitHub Release / 给用户安装的 APK，**必须**带 `--split-per-abi`。  
> ⛔ **禁止** `flutter build apk --release`（不带 split）——那是多 ABI 胖包（~55MB），不得发版。

```powershell
cd "d:\vibe coding\rebuild_copymanga\copymanga_flutter"
flutter build apk --release --split-per-abi
```

产物（示例体积约 19–23MB / 个）：

| 文件 | 适用 |
|------|------|
| `build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk` | 较老 32 位机 |
| `build\app\outputs\flutter-apk\app-arm64-v8a-release.apk` | **绝大多数真机（优先推荐）** |
| `build\app\outputs\flutter-apk\app-x86_64-release.apk` | 模拟器 |

发版重命名（`X.Y.Z` = versionName）：

```powershell
$ver = "X.Y.Z"
Copy-Item build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk "CopyManga-flutter-$ver-armeabi-v7a.apk"
Copy-Item build\app\outputs\flutter-apk\app-arm64-v8a-release.apk   "CopyManga-flutter-$ver-arm64-v8a.apk"
Copy-Item build\app\outputs\flutter-apk\app-x86_64-release.apk      "CopyManga-flutter-$ver-x86_64.apk"
```

真机安装（以 arm64 为例）：

```powershell
adb uninstall top.fumiama.copymanga_flutter   # 签名不一致时
adb install -r "CopyManga-flutter-$ver-arm64-v8a.apk"
```

---

## 4. 同步到 worktree → 提交并推送 `flutter` 分支

日常开发只改 `copymanga_flutter/`。该目录**本身通常没有**指向 `flutter` 分支的 `.git`；提交必须在 worktree 里做。

### 4.1 准备 / 刷新 worktree

```powershell
cd "d:\vibe coding\rebuild_copymanga\copymanga-src"
git fetch origin flutter
# 若尚无 worktree：
# git worktree add "..\_flutter_wt" flutter
# 若已有：保持 checkout 在 flutter 即可
git -C "..\_flutter_wt" status -sb
```

### 4.2 单向同步（只允许 开发目录 → worktree）

先做 §0.2 完整性检查。再 robocopy（**排除**构建与签名；**禁止**反向拷贝）：

```powershell
$src = "d:\vibe coding\rebuild_copymanga\copymanga_flutter"
$dst = "d:\vibe coding\rebuild_copymanga\_flutter_wt"
robocopy $src $dst /E /NFL /NDL /NJH /NJS /nc /ns /np `
  /XD build .dart_tool .idea .git android\.gradle android\app\build ios\Pods ios\.symlinks ios\Flutter\ephemeral `
  /XF signing.properties local.properties *.iml .flutter-plugins-dependencies .flutter-plugins
Remove-Item -Force -ErrorAction SilentlyContinue "$dst\android\app\signing.properties"
Remove-Item -Force -ErrorAction SilentlyContinue "$dst\android\local.properties"
```

同步后在 `$dst` 再跑一遍「关键文件 Length ≥ 50」检查；失败则 **不要 commit**，从 `origin/flutter` 恢复。

### 4.3 提交推送

```powershell
cd "d:\vibe coding\rebuild_copymanga\_flutter_wt"
git status
git add -A
# 确认没有 signing.properties / keystore / 0 字节关键文件
git commit -m "feat: Flutter vX.Y.Z <短标题>"
git push origin flutter
```

---

## 5. 打 Tag → 触发 iOS IPA → 上传 APK → **清理本地编译产物**

假设版本为 `X.Y.Z`（与 `pubspec.yaml` 的 versionName 一致）。

### 5.1 推送 Tag（触发 Actions 编 IPA）

```powershell
git tag flutter-vX.Y.Z
git push origin flutter-vX.Y.Z
```

- Actions：**Build unsigned iOS IPA** → 产出 `CopyManga-flutter-X.Y.Z-unsigned.ipa` 并尝试挂到 Release。
- 仓库需允许 Actions 写 `contents`（workflow 已声明 `permissions: contents: write`）。
- 也可手动 `workflow_dispatch`（只出 artifact，不建 Release）。

### 5.2 准备 Android split APK 文件名

先完成 §3 的 **`flutter build apk --release --split-per-abi`**，再重命名三份（见 §3 表格）。  
**不要**准备或上传无 ABI 后缀的胖包 `CopyManga-flutter-X.Y.Z.apk`。

### 5.3 创建 / 更新 GitHub Release 并上传 APK（+ IPA）

**首次发版**（推荐本地写好简介）：

```powershell
gh release create flutter-vX.Y.Z `
  -t "Flutter vX.Y.Z — <短标题>" `
  -F release_notes.md `
  CopyManga-flutter-X.Y.Z-armeabi-v7a.apk `
  CopyManga-flutter-X.Y.Z-arm64-v8a.apk `
  CopyManga-flutter-X.Y.Z-x86_64.apk `
  --repo jimytao/copymanga
```

**Release 已存在时（补传 / 覆盖 split APK）：**

```powershell
# 若仍残留旧的胖包，先删掉
gh release delete-asset flutter-vX.Y.Z CopyManga-flutter-X.Y.Z.apk --repo jimytao/copymanga --yes 2>$null

gh release upload flutter-vX.Y.Z `
  CopyManga-flutter-X.Y.Z-armeabi-v7a.apk `
  CopyManga-flutter-X.Y.Z-arm64-v8a.apk `
  CopyManga-flutter-X.Y.Z-x86_64.apk `
  --repo jimytao/copymanga --clobber
```

**IPA**（Actions 产出或 artifact 下载后）：

```powershell
gh run download <RUN_ID> --repo jimytao/copymanga --name CopyManga-unsigned-ipa --dir .
gh release upload flutter-vX.Y.Z CopyManga-flutter-X.Y.Z-unsigned.ipa --repo jimytao/copymanga --clobber
```

**侧载**：Sideloadly 等对 unsigned IPA 重签后装到 iPhone（免费账号约 7 天重签）。

### 5.4 上传确认后：删除本地无用编译产物（必做）

发版资产已在 GitHub 上即可删掉本机大文件，避免工作区堆积。

> ⚠ **清理范围仅限本 Flutter 目录**；禁止 `Remove-Item` / `clean` 指向 `..\copymanga-src`。

```powershell
cd "d:\vibe coding\rebuild_copymanga\copymanga_flutter"

# 1) 删发版用的临时重命名包（仅本目录）
Remove-Item -Force -ErrorAction SilentlyContinue .\CopyManga-flutter-*.apk
Remove-Item -Force -ErrorAction SilentlyContinue .\CopyManga-flutter-*-unsigned.ipa

# 2) 清 Flutter/Android 构建缓存与产物（可再 flutter build 重建）
flutter clean
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\build
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\android\.gradle
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\android\app\build

# 3) 仅删本侧临时目录（不要删 copymanga-src）
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "..\_release_tmp"
```

> **不要删**：`keystore.jks`、`android/app/signing.properties`、源码与 `assets/`、**整个 `..\copymanga-src`**。  
> `flutter clean` 后下次发版需重新 `flutter build apk --release --split-per-abi`（正常）。

核验 Release 资产：

```powershell
gh release view flutter-vX.Y.Z --repo jimytao/copymanga
```

---

## 6. iOS CI 说明（怎么弄的）

| 项 | 说明 |
|----|------|
| 工作流文件 | `.github/workflows/build-ios.yml`（位于 **flutter 分支仓库根**） |
| Runner | `macos-latest`（无本地 Mac 时的唯一出包手段） |
| 签名 | `--no-codesign`，不在 CI 放苹果证书 |
| 触发 | `push` tags=`flutter-v*`，或手动 `workflow_dispatch` |
| 产物 | unsigned IPA artifact + Release 附件 |

不需要在 Xcode 里改版本号；以 `pubspec.yaml` 为准。

更换品牌图标时：把源图放到 `assets/icon/ic_launcher.png`，再跑 `python tool/gen_ios_icons.py`（会写 `AppIcon` + `LaunchImage`）；LaunchScreen 背景色与 Splash 一致为 `#FFCC7F`。

---

## 7. 与 Kotlin 发版对照（防串台）

| 步骤 | Kotlin | Flutter |
|------|--------|---------|
| 改版本 | `app/build.gradle` | `pubspec.yaml` |
| 编译 | `gradlew assembleRelease` | **`flutter build apk --release --split-per-abi`（强制）** |
| 推分支 | `origin re_build` | `origin flutter` |
| 打 Tag | `v1.5.14` | `flutter-v1.0.3` |
| Release 资产名 | `copymanga_1.5.14.apk` | `CopyManga-flutter-…-{abi}.apk`（三份）+ `…-unsigned.ipa` |
| SOP | `../copymanga-src/workflow.md` | **本文件** |

---

## 8. 首次：从零建立 `flutter` orphan 分支（仅初始化时）

仓库原本只有 Kotlin（`re_build`）。Flutter 本地在仓库**外**的兄弟目录。初始化时：

1. 在 `copymanga-src`（git root）执行 `git checkout --orphan flutter`，清空索引后把 `../copymanga_flutter` 的内容拷到仓库根并提交。
2. `git push -u origin flutter`。
3. **立刻** `git checkout re_build`，恢复 Kotlin 工作树。
4. 建议：`git worktree add <某路径> flutter`，以后只在 worktree 里改 Flutter。

日常不要在 `re_build` 工作树上直接覆盖 Flutter 文件。

---

## 9. 日常开发（非发版）

```powershell
flutter run
flutter analyze
flutter test
```

---

## 10. 汇报模板

版本号（Name + Code）、分支、Tag、APK 是否已装真机、IPA Actions 链接 / Release 链接、侧载注意（7 天重签）。
