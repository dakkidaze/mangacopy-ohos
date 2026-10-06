# MangaCopyOHOS — ArkTS 原生移植工程（`harmony/`）

本目录是 Copymanga 的**纯 ArkTS** HarmonyOS 工程，与仓库根部的 Flutter 工程（`lib/`、`ohos/` 等）**完全独立**，
仅将 Flutter 侧 Dart 代码作为移植参考。两个应用 bundleName 不同（`.arkts` 后缀），可在真机上共存对比。

## 工程约定（后续所有代码必须遵循）

### 状态管理
- 所有 ArkUI 组件统一使用状态管理 V2：`@ComponentV2`、`@Local`、`@Param`、`@Event`、`@Once`。
- 需要观察对象内部变化时，数据类使用 `@ObservedV2`，可变字段使用 `@Trace`；派生联动使用 `@Monitor`。
- 禁止在同一个组件内混用 V1（`@Component` / `@State` / `@Prop` / `@Link` 等）与 V2 装饰器。
- 全局仅通过 `AppStorage` 传递 `abilityContext`；业务状态与设置不放入 `AppStorage`。`EntryAbility.onCreate` 负责 `AppStorage.setOrCreate('abilityContext', this.context)`。
- 不引入第三方状态库。

### 路由
- **单一 `@Entry` 页面 + 内部路由枚举 + `Stack` 条件渲染**（照搬 Ehviewer_OHOS 的 `Index.ets` 模式）。
- **不引入 `Navigation` / `router`**；`main_pages.json` 只注册 `pages/Index`。
- 根页面负责页面枚举、返回行为和挂载；各场景保持独立 V2 组件，通过 `@Param` 接收值、通过 `@Event` 回传操作。
- 新页面接入时扩展内部枚举和 `Stack` 分支，不另建 `@Entry` 页面。

### 网络
- 只用 `@kit.NetworkKit` 的 `http`。
- 自建：请求节流、失败重试（指数退避）、Cookie 头管理（登录态 Cookie 自己拼进 `header`）。
- 不使用 `@ohos.net.http` 以外的网络库，不引入三方依赖。

### 存储
- 设置 / 登录态：`@kit.ArkData` 的 `preferences`（通过 `AppStorage` 里的 `abilityContext` 取 context）。
- 下载 / 缓存文件：`@kit.CoreFileKit` 的 `fileIo`。

### Web
- 需要内嵌网页（如登录验证）时用 `@kit.ArkWeb` 的 `Web` 组件 + `javaScriptProxy`。

### 配色
- 全部颜色资源放 `entry/src/main/resources/base/element/color.json`，深色模式用 `dark/element/color.json` **同名覆盖**；新增颜色必须同时补齐两套资源。
- 代码中一律 `$r('app.color.xxx')`，禁止硬编码色值。
- `darkMode=true` 时固定深色资源；关闭时将颜色模式还给系统，跟随系统明暗。页面不要自行维护另一套色值。

### 图标
- 只使用本工程自带的原创占位 PNG（`base/media/`），**禁止**复用 copymanga 上游图标资源。

### 阅读器
- **阅读器暂不实现**（后续单独立项，届时再定方案）。

## 构建

前置：本机已装 command-line-tools（含 `ohpm`、`hvigorw`、SDK）。需要：

```bash
export DEVECO_SDK_HOME=/home/dakki/command-line-tools/command-line-tools/sdk
export PATH=/home/dakki/command-line-tools/command-line-tools/bin:$PATH
```

或直接用仓库根脚本：

```bash
./tool/build_arkts_hap.sh
```

手动构建：

```bash
cd harmony
ohpm install --all
./hvigorw assembleHap --mode module -p product=default -p module=entry@default --no-daemon
```

（工程自带 `hvigorw` / `hvigorw.bat` 薄包装脚本，默认委托本机 command-line-tools 自带的
hvigor 引导器（6.26.8），可用环境变量 `HVIGOR_CLI` 覆盖；也可直接用 PATH 里的 `hvigorw`。）

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（未签名；`signingConfigs` 留空）。

## SDK 版本

- `compileSdkVersion` / `targetSdkVersion`: `26.0.0`（本机 command-line-tools SDK）
- `compatibleSdkVersion`: `5.0.5(17)`（与 Flutter HAP 一致，保证真机可装）
- `runtimeOS`: `HarmonyOS`；`oh-package.json5` 的 `modelVersion`: `26.0.0`

## 依赖

`dependencies` 恒为空：一切能力用系统 `@kit.*`。本机网络不稳，**禁止引入 ohpm 三方包**。
