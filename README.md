# MangaCopyOHOS

拷贝漫画（mangacopy.com）的 **HarmonyOS NEXT** 第三方客户端。

基于 [jimytao/copymanga](https://github.com/jimytao/copymanga) 的 `flutter` 分支二次开发
（其上游为 [fumiama/copymanga](https://github.com/fumiama/copymanga)），新增鸿蒙平台支持与若干功能。
技术栈：**Flutter（CPF-Flutter ohos fork）+ ArkWeb**。

> ⚠️ 本项目与「拷贝漫画」官方**没有任何关系**，仅供个人学习研究。详见文末**免责声明**。

---

## 功能现状

### 浏览（两种方式，设置里切换）
- **网页版**：套壳网页版 H5（保留登录页等站内功能）
- **原生界面**：发现（热门/最新）、搜索、筛选、漫画详情；
  详情页章节为**一行一章**，每章右侧带**下载**按钮（下载中可**取消**）
- 多线路自动切换；可在设置中自定义 API 域名

### 阅读
- **自带原生阅读器**：横向 / 纵向 / 条漫三种模式，双击捏合缩放、音量键翻页、
  断点续读、原地切章 + 下一章预取、页码跳转
- **点击章节 → 直接进原生阅读器再加载**（不再出现网页阅读器）
- **章节图片两种取数方式**（设置 → 章节图源，切换立即生效）：
  - **网页收图（默认）**
  - **API 取图**：直连官方 `/api/v3` 取章节图片

### 吐槽（评论）
- 章末吐槽 + 漫画总评（官方 `/api/v3`，**免登录可读**）
- 两种入口：
  - 阅读器工具栏 **「吐槽」按钮** → 弹窗（章末吐槽 + 总评）
  - 章节**最后一页之后的「吐槽」虚拟页**（横/纵/条漫皆有，仅章末吐槽，可在设置关闭）
- **离线章节也能读吐槽**（下载时写入章节元数据）

### 下载 / 离线
- 阅读器内单章下载；原生详情页**逐章下载**（可取消）
- 离线阅读与下载管理（"更多 → 我的下载"）

### 账号
- **原生登录**；登录状态会保留，下次打开仍是登录态
- 收藏书架、浏览历史（原生界面「更多」内；未登录会提示先登录）

### 其它
- 深色模式、隐藏状态栏、图片磁盘缓存上限

### 暂不实现
- **轻小说**：官方服务端对小说做了锁定（仅第一章可读），非客户端可绕过
- **发布吐槽**：官方未提供公开写接口，需另行逆向

---

## HarmonyOS 构建

- 工具链：CPF-Flutter 的 `flutter_flutter`（ohos fork） + HarmonyOS CommandLine Tools。
- 依赖了 ohos 适配的插件（见 `pubspec_overrides.yaml`）：
  `shared_preferences` / `path_provider` / `connectivity_plus` / `sqflite` / `flutter_inappwebview`
  分别指向 CPF-Flutter 的对应适配仓库（约束相应下调为 `shared_preferences ^2.5.4`、
  `connectivity_plus ^7.0.0`、`path_provider ^2.1.5`）。
- 构建未签名 HAP：

  ```bash
  # 构建脚本不入库（在本地工具目录 ~/ohos-tools/ 下运行）
  ```

  产物：`ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`
  （CPF-Flutter 在 hvigor 成功后仍会因缺少签名配置报错退出，属预期；脚本按产物判定成功。）
- **签名 / 安装**：产物为**未签名 HAP**，用 **「小白调试助手」** 或 **「HoKit」** 等工具签名后安装即可；
  也可用 DevEco Studio 在 `ohos/build-profile.json5` 配 `signingConfigs`。

---

## 许可与来源

本项目以 **GPL-3.0** 发布，见 [`LICENSE`](LICENSE)、[`NOTICE`](NOTICE)。

- 代码 fork 自 `jimytao/copymanga`（GPL-3.0），上游为 `fumiama/copymanga`（GPL-3.0）。
- API 调用逻辑系依据公开信息**自行实现**，编写时参考了 `LittleSurvival/copymanga-copy20`
  与 `DaLongZhuaZi/manxia-extensions-source` 的公开接口信息；上述仓库未附许可证，
  本项目**未复制其源代码或配置文件**。
- 应用图标为本项目原创。

---

## 免责声明 / Disclaimer

- 本项目为**个人学习与技术研究**用途的开源项目，**与「拷贝漫画」（mangacopy.com）及其运营方没有任何关系**：
  非官方、未获授权、未获认可，也不代表其立场。
- 本项目**不提供、不存储、不分发**任何漫画内容；所有内容均来自第三方站点，版权归各自权利人所有。
- 本项目仅供**学习交流**，请勿用于商业用途。请于获取后 **24 小时内删除**，并支持正版。
- 使用者需自行承担使用本软件的风险与由此产生的任何法律责任。
- 若权利人认为本项目侵犯其权益，请通过 issue 联系，我们会及时处理（移除相关内容或仓库）。
