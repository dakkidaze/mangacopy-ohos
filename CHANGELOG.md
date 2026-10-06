# CopyManga Flutter 变更记录

> 本文件只记录 **Flutter 版**（分支 `flutter` / Tag `flutter-v*`）。  
> Kotlin 原生版见 `../copymanga-src/CHANGELOG.md`（分支 `re_build` / Tag `v*`）。

---

## 2026-08-22 — v1.0.19：域名更新与 2026copy.com 恢复

- **源站清理与域名核验**：对网络上各类备选域名进行自动化 HTTP/HTML 实测核验。
- **保留与新增有效源**：保留确认可正常打开拷贝漫画主页的 `copy3000.com`（`https://www.copy3000.com`）、`2026copy.com`（`https://www.2026copy.com`）、官方公告的大陆无障碍地址 `copy4000.com`（`https://www.copy4000.com`）与 `mangacopy.com`（`https://www.mangacopy.com`）。
- **移除失效源**：移除连接被重置/失效的 `copymanga.site`，以及广告/域名停靠类无效页面。

---

## 2026-08-14 — v1.0.18：修复 v1.0.17 条漫高度锁定引入的两处缺陷

> v1.0.17 的条漫高度锁定方向正确但实现有缺陷，本版修复。**建议直接从 v1.0.16 升到本版，跳过 v1.0.17。**

- **修复 setState-during-build 异常（v1.0.17 引入）**：`RetryNetworkImage` 在 `initState` 挂 `ImageStream` 监听探测原始尺寸，而图片已在 `ImageCache` 时 `addListener` 是**同步回调**——`initState` 又运行在 `itemBuilder` 内，于是 `setState` 在 build 期间被调用，抛 `setState() called during build` 并打断当前帧。`_preloadAround` 主动 precache 后 3 张，这条同步路径在条漫中几乎必然被高频触发，反复破坏 v1.0.17 本身的回跳修复。现抽出 `FrameSafeRebuild`：build 期间的重建请求延到帧后执行，并将一帧内多张图的尺寸上报合并为一次重建（此前每张图触发一次全量 `setState`）。
- **修复条漫图片被裁切（v1.0.17 引入）**：v1.0.17 对比例未知的 item 也无条件套 `AspectRatio` 并用 3:4 兜底。`AspectRatio` 给子控件的是紧约束，配合 `BoxFit.fitWidth` 会把比兜底比例更长的图**裁掉下半截**；而离线下载章节走 `Image.file` 分支、当时未接尺寸探测，比例永远学不到，导致条漫模式下**下载的章节被永久裁成 3:4**。现改为比例未知时不加任何约束（即 v1.0.17 之前的自然高度行为），学到真实比例后才锁定——不削弱修复效果，因为回跳来自被回收后**重建**的 item，它们必然已显示过一次、比例已知。
- **离线章节同享高度锁定**：尺寸探测抽为通用组件 `ImageIntrinsicSizeListener`，在线（`CachedNetworkImageProvider`）与离线（`FileImage`）走同一套机制。探测用的 provider 与显示用的 provider 相等，共用同一条 `ImageCache` 记录，不产生额外下载或解码。
- **修复断点续读的异步竞态（历史遗留）**：`_initChapter` 先 `_jumpTo(1)`，再 `await SharedPreferences`（慢机上可达数百毫秒），然后无条件 `_jumpTo(saved)`。此前只校验章节代数、未校验用户是否已开始阅读，导致用户滑了几页后被凭空甩到断点位置。现检测到手指拖拽（仅认 `dragDetails != null`，程序化跳转与惯性滚动不计）后即放弃跳转，改为仅提示「上次读到第 N 页」。
- **测试**：新增 `frame_safe_rebuild_test.dart`（build 期同步回调不抛异常、一帧内多次请求合并为一次重建、帧外请求立即执行）与 `webtoon_item_layout_test.dart`（比例未知不加约束、已知锁定为真实比例、并保留「兜底比例会把长图压到 400」的反例防止回归）。已验证去掉守卫后相应用例全部失败，确认测试有效。120 项测试全绿；`flutter analyze` 无 error/warning。
- **版本**：`1.0.18+19`。

## 2026-08-14 — v1.0.17：修复条漫滚动回跳与单页章节无法切章，新增缓存上限

- **条漫滚动回跳修复**：条漫 item 此前没有任何高度约束，占位符（loading 圈）高度接近 0。图片被 `ImageCache` 淘汰或 item 滑出 `cacheExtent` 被回收后重建时，item 会先塌成零高再弹回真实高度，列表总高度随之抖动，`ScrollablePositionedList` 重新对齐锚点，表现为「滑着滑着闪一下往回跳一段」。现新增 `WebtoonAspectCache`（进程内 LRU，上限 3000 条）记录每张图的宽高比，item 外套 `AspectRatio`，占位符与真实图片共用同一高度，加载 / 回收 / 重下载全程高度恒定。尺寸未知时用 3:4 兜底。
- **内存缓存调优**：`ImageCache` 上限由默认 100MB 提到 320MB、条数压到 80（条漫长图单张解码后可达 20–40MB，默认值几张就撑爆 LRU，把视口附近的图挤掉，正是回跳的诱因）；`_preloadAround` 预载窗口 5 → 3，避免预载反噬。低内存机型（如小米 6X + 第三方 ROM）症状最明显。
- **单页章节无法切章修复（Android 独有）**：章节只有一页且不满一屏时 `minScrollExtent == maxScrollExtent`，默认 `ScrollPhysics.shouldAcceptUserOffset` 返回 false，Android 的 `ClampingScrollPhysics` 直接吞掉拖拽——`ScrollUpdateNotification` 与 `OverscrollNotification` 两条兜底通知全断，条漫切章无从触发。现为条漫列表显式指定 `AlwaysScrollableScrollPhysics`（恒返回 true）。iOS 的 `BouncingScrollPhysics` 本就恒返回 true，故该 bug 仅在 Android 出现。
- **新增图片缓存上限（设置 → 存储 → 缓存上限）**：可选 256MB / 512MB / 1GB（默认）/ 2GB / 4GB / 不限制。达到上限后按最后访问时间 LRU 淘汰最旧的图片，一次性削减到上限的 80%（而非只删到刚好等于上限，避免每存一张新图就重扫目录拖慢滑动）。触发时机：冷启动一次、阅读中预载时按需触发（最小间隔 45s）、改设置后立即执行。`atime` 在部分 noatime 挂载的 Android ROM 上不更新，故取 `accessed` 与 `modified` 中较晚者。已下载到本地的漫画不受影响。
- **独立 CacheManager**：图片改用独立 key `copymangaImageCache`，与其他缓存目录分开，清理时不误伤；残留 db 行由 `maxNrOfCacheObjects: 20000` 回收。「清理缓存」同步走 `AppImageCache.clear()`，缓存大小显示支持 GB 单位。
- **测试**：新增 `webtoon_aspect_cache_test.dart`（兜底比例、高度稳定性、重复上报去重、非法尺寸防护、LRU 刷新）；114 项测试全绿；`flutter analyze` 无新增 error/warning。
- **版本**：`1.0.17+18`。

## 2026-08-11 — v1.0.16：修复条漫短末页无法切换下一章

- **条漫短末页修复**：最后一张图片高度较小时，前一张仍可露在视口内，阅读页码会错误停在倒数第二页，导致底部滑动不被判定为“下一章”边界。现末图底部进入视口即记为最后页，保证页码、音量键和连续滑动切章一致。
- **测试**：新增短末图到底、末图未到底与普通可见区的阅读进度回归用例。
- **版本**：`1.0.16+17`。

## 2026-08-11 — v1.0.15：修复条漫末尾二次滑动无法切章

- **条漫末尾二次滑动修复**：正式手势模式下，`ScrollUpdateNotification` 的条漫兜底路径此前仍调用旧 `ChapterEdgeGuard`，而 `OverscrollNotification` 调用新 `ChapterEdgeFsm`。不同 Android 对两类通知的投递顺序不同，可能造成第一划提示后第二划被另一套状态机重新当作首次操作。现两条路径统一进入 `ChapterEdgeFsm`，保证二次确认状态连续。
- **测试**：补充条漫“首划 ScrollUpdate 兜底、二划 Overscroll”共享同一 FSM 的回归用例；本机 Flutter 测试命令环境无输出超时，待真机与 CI 复核。
- **版本**：`1.0.15+16`。

## 2026-08-05 — v1.0.14：修复 Android 发布包末页单次滑动同时触发提示与换章

- **根因**：`ChapterEdgeFsm` 的同手势去重依赖 `gestureSessionId`，而该值由 `ReaderGestureDiagnostics.currentGestureSessionId()` 提供。该方法仅在 `kDebugMode=true` 时有效，**Release APK** 中始终返回 `null`，导致 FSM 的 `sameGestureSessionAsArm` 保护被完全绕过——一次手势内的 overscroll 辅助信号与主路径信号叠加后直接触发换章。
- **修复**：`_ReaderPageState` 新增静态序列号生成器 `_newGestureSessionId()`（`gs-1, gs-2...`），每次 `onPointerDown` 自主生成唯一 session ID，完全不依赖诊断模块。Release/Profile/Debug 构建行为一致。
- **调试保留**：Debug 模式下额外调用 `_diag.onGestureSessionIdAssigned()` 将 session ID 同步给日志系统，不影响逻辑。
- **iOS 音量键优化**：修复 `resettingVolume` 重置音量滑块窗口期间按键被静默丢弃的问题（新增 `pendingKeyDirection` 缓冲机制，重置完立即补发）；提前同步初始 `lastVolume` 避免 `captureAndArm` 把设锚点误判为按键；初次搜索滑块死区从 120ms 缩短至 30ms。
- **测试**：新增 `chapter_edge_fsm_release_mode_test.dart`，覆盖相同/不同/null session ID 场景；105 项测试全绿；`flutter analyze` 无新增 error/warning。
- **版本**：`1.0.14+15`。

## 2026-08-04 — v1.0.13：修复日漫横向章节边界方向映射

- **根因**：`ReaderReadingDirection` 写死「左滑=下一页」且忽略 `r2l`，与日漫（右滑=下一页）及 `PageView.reverse` 不一致；末页右滑无法武装下一章，左滑误提示且可能 `pageChanged` 清掉 armed。
- **修复**：物理滑动映射纳入 `r2l`（日漫右=next / 左开左=next）；overscroll 走滚动轴空间、不二次反转；首划/二划/诊断共用同一 `resolve`。
- **测试**：方向映射、FSM 集成、Widget 级日漫双滑用例。
- **版本**：`1.0.13+14`。

## 2026-08-04 — v1.0.12：正式手势仲裁 + 章节边界双滑状态机

- **横滑根因修复**：未缩放时不再挂载 `InteractiveViewer`；由 `ReaderGestureCoordinator` 统一仲裁单指翻页 / 双指缩放 / 放大平移，避免 Scale 识别器与 PageView 竞争（Android 快滑约 43% 无 scrollStart 的主因）。
- **章节双滑**：新增 `ChapterEdgeFsm`，以独立 swipe 为主输入、overscroll 为辅助；同 `gestureSessionId` 去重，带 `chapterRequestId`。
- **方向映射**：`ReaderReadingDirection` 集中处理物理滑动 ↔ 页/章意图（r2l/reverse）。
- **回滚**：`--dart-define=READER_LEGACY_GESTURE_ROUTING=true` 恢复旧 InteractiveViewer + ChapterEdgeGuard 路径。
- **文档**：`docs/reader_gesture_architecture.md`、`docs/reader_gesture_implementation_report.md`。
- **版本**：`1.0.12+13`。

## 2026-08-01 — v1.0.11：修复边界滑动与 iOS 音量键偶发失效

- **滑动换章哑火**：指针改用 id 集合跟踪，每次 `pointerDown` 重新武装 `EdgeGestureGate`，避免漏收 up/cancel 后 gate 永久不放行。
- **旧机要滑三次**：越界计数改为先确认章节边界与方向，再消耗手势配额，避免方向抖动白吞一次；越界阈值略降（8→6）。
- **翻页锁死**：无活动指针时强制解除 `_multiTouch`；切章/切模式重置指针跟踪；按 pointer 时间戳清理 >1s 未更新的幽灵 id（避免误锁 PageView，且不误伤慢速双指捏合）。
- **iOS 音量键**：进入时保存用户音量，阅读中在可检测锚点（钳位到 15%–85%）工作，按键后拉回锚点而非固定 50%；退到后台时主线程同步还原（适配回桌面再划掉 App），回前台再重新武装；关闭功能时亦还原。缩短重置忽略窗并重试查找 UISlider。
- **版本**：`1.0.11+12`。

## 2026-07-31 — v1.0.10：边界换章音量键二次确认 + 滑动手势加固

- **音量键换章**：横/纵/条漫在首末页时，同方向再按两次对应音量键即可换章（与热区共用二次确认；文案「再次按下加载上/下一章」）。
- **滑动二次确认加固**：越界计数改为「一次 pointer 手势只计一次」，避免连滑过快被旧 600ms 防抖误吞；横/纵/条漫均适用。
- **无邻章统一**：点击 / 滑动 / 音量在无邻章 URL 时第一次即提示「已经到头了~」。
- **版本**：`1.0.10+11`。

## 2026-07-29 — v1.0.9：源站 sticky 调优与阅读器全模式自由缩放

- **节点 Sticky 保持调优**：将误切换源阈值调整为相较最快慢 ≥2.5s 且 ≥3 倍（或单次超时 >4000ms），避免几十至上百毫秒的正常网络波动导致域名误切。
- **双击缩小修复**：修复在放大状态下 `InteractiveViewer` 的 `onInteractionStart` 被触发导致双击缩小手势被误拦截的问题；双击缩小可在任意放大比例下精准还原至 1.0x。
- **条漫随心所欲自由缩放**：为条漫模式引入 `ZoomableWebtoonView`，支持 1.0x ~ 4.0x 双指连续捏合自由缩放与双击放大/还原；1.0x 原始大小时锁定横向平移，保证长图纵向滑动的极致流畅。

## 2026-07-26 — v1.0.8：条漫禁用点击翻页 + 纵向分区调整

- **条漫手势**：滑动易误触，条漫模式关闭上下区点击翻页；仍保留中央轻点出/收菜单。手势滚动与音量键翻页不受影响。
- **纵向点击分区**：改为上/中/下三分区（上上一页、下下一页）；菜单仍为居中小矩形，中带左右两侧无效，避免点菜单外侧误翻页。
- **横向**：左/中/右三分区不变。
- **版本**：`1.0.8+9`。

## 2026-07-25 — v1.0.7：阅读器点击翻页 + 缩放手势 + 条漫切章 + 表页历史同步

- **点击分区翻页**：横向左/中/右（右开本左右对调）；纵/条漫为上半上一页、下半下一页、中央点按出菜单；到首末页二次确认切章。
- **缩放与翻页手势**：横/纵支持捏合与双击放大/还原；未放大时关闭平移、点击用原始指针识别，避免抢 PageView；双指按下立刻锁翻页。
- **条漫切章**：滑到底/顶用「手指拖住边界」补检测；以最后一页底部入视口为准，避免长图误切章。
- **表页历史同步**：切章前 `resumeTimers` + 安全点击上下话按钮；隐藏 WebView 仍负责收图。
- **iOS 音量键**：`MPVolumeView` + `outputVolume` 观察实现翻页。
- **版本**：`1.0.7+8`。

## 2026-07-22 — v1.0.6：二次进章修复 + iOS 关阅读器不跳首页

- **根因对齐**：阅读器盖住表页后 i.js `setInterval` 可能假死，退出后点其它章节不再触发 `loadComic`（无加载框、停滞计时也不走）。
- **Dart 进章**：可见 WebView `onUpdateVisitedHistory` / `onLoadStop` 直接识别 `/comicContent/`、`/details/comic/`，不依赖表页定时器。
- **退出收尾**：`_closeReader` / 收图停滞时 `stopLoading` + `about:blank` 中止隐藏 WebView；忽略「已退出且无 pending」的迟到 `setLoadingDialog`。
- **加载反馈**：用户进章时立即弹出收集进度，不再干等 h.js。
- **iOS 关阅读器跳首页**：隐藏 WebView 置顶/还原时曾前插 Stack 槽位，可见页无 Key 被重建并重载 `initialUrl`；现固定槽位 0 占位 + 可见页 `GlobalKey`，关阅读器只关阅读器。
- **版本**：`1.0.6+7`。

## 2026-07-20 — v1.0.5：退出恢复表页 + 详情返回 + 去白闪

- **取消阅读器内 clickClass 同步**：盖住表页时点站内按钮会把可见 H5 打乱（安卓关阅读器像回首页）；切章只走隐藏 WebView / 预取。
- **退出唤醒表页**：`_closeReader` 后 `resumeTimers()`，并把 `invoke.preUrl = location.href`（禁止 reset 成空，否则仍停在章节 URL 时会再次 loadComic、阅读器自动弹回）。
- **详情/章节页网页返回**：`i.js` 捕获 `van-nav-bar__left`，优先 `history.back()`，未动则回落 `lastBrowseUrl`，避免站点 fallback 冲到首页顶部。
- **白闪**：可见/隐藏 WebView 启用 `transparentBackground`，底色跟 App 壳。
- **版本**：`1.0.5+6`。

---

## 2026-07-19 — v1.0.4：撤销表 H5 切章同步

- **切章解耦**：阅读器内上一章/下一章只驱动隐藏 WebView 收图或使用预取数据，不再导航可见 H5。
- **二次进章修复**：移除表页同步使用的 `loadUrl`、五秒抑制标志及相关状态，避免退出阅读器后表页触发链失效。
- **保留收图优化**：继续使用 v1.0.3 的内嵌阅读器、隐藏 WebView 置顶和强制重载机制。
- **版本**：`1.0.4+5`。

## 2026-07-19 — v1.0.3：阅读器切章表 H5 同步 + 下一章收图加速

- **表页进度同步**：阅读器内切章时静默 `loadUrl` 可见 WebView 到目标章（抑制 `loadComic`），退出后详情/历史不再停在首开那一话。
- **下一章收图**：阅读器改为嵌在 `BrowserPage` Stack（不再 `Navigator.push` 全遮罩）；收图/预取时把隐藏 WebView 以 1×1 提到最顶，避免 rAF 被节流。
- **切章稳健性**：用户显式切章强制 `stopLoading` + 重载（不再挂接可能僵死的预取）；隐藏注入加 generation；停滞时清理预取状态。
- **收尾**：退出阅读器取消停滞计时/抑制标志/预取状态；置顶完成后再 `loadUrl`，避免在旧层级启动收图。
- 底栏增加关闭按钮（系统返回同样退出阅读器）。
- **版本**：`1.0.3+4`。

## 2026-07-19 — v1.0.2：暗色启动白闪 + 发版 SOP 加固

- **暗色白闪**：`AT_DOCUMENT_START` UserScript + WebView `underPageBackgroundColor` 黑底 + `onLoadStart` 即刻注入；暗色 Splash 黑底过渡（不再等 `progress>2`）。
- **workflow**：标明 `copymanga_flutter` ↔ `_flutter_wt` 单向同步；关键文件禁止删除/截断为空；发版前完整性检查。
- **版本**：`1.0.2+3`。

## 2026-07-19 — v1.0.1：iOS 全面屏 / 键盘抖动 / 图标启动图

- **全面屏**：iOS 改用 `edgeToEdge`；上界贴刘海下沿；下界读系统 Home 指示条高度（`safeAreaInsets` / `viewPadding.bottom`，会话缓存；读不到时刘海机回退 34pt）。
- **网页外底色**：跟 App 暗色开关（浅白/深黑），`themeMode` 不再跟系统；修好「网页白、壳黑」反差。
- **键盘 / 抖动**：`resizeToAvoidBottomInset: false` + 剥离 `viewInsets`；顶栏 inset 用 `viewPadding`；WKWebView `contentInsetAdjustmentBehavior=NEVER`、关侧滑返回与输入附件条。
- **阅读器回归**：退出不再写回 `manual`；统一 `AppSystemUi`；iOS 藏状态栏用 `immersiveSticky`。
- **图标 / 启动**：补齐 AppIcon + 橙色 LaunchScreen；显示名「拷贝漫画」；Main.storyboard 同色防闪白。
- **版本**：`1.0.1+2`。

## 2026-07-19 — v1.0.0：跨平台首发（正式签名 + GitHub Release）

- **版本**：`1.0.0+1`（Android versionName=1.0.0 / versionCode=1）。
- **签名**：与 Kotlin 版共用工作区根 `keystore.jks`；`flutter build apk --release` 自动签名。
- **发布渠道**：分支 `flutter`；Tag / Release **`flutter-v1.0.0`**（与 Kotlin 的 `v*` 分离）。
- **产物**：按 ABI split 的三份 APK（`armeabi-v7a` / `arm64-v8a` / `x86_64`，约 19–23MB）+ `CopyManga-flutter-1.0.0-unsigned.ipa`；发版禁止上传未 split 胖包。
- **启动**：有缓存源秒开；首次测速显示橙色 Splash；WebView 进程预热。
- **图标 / FAB**：原版同款启动图标；「我的下载」悬浮钮默认可拖至右侧偏上并记住位置。
- **阅读器**：三模式、断点续读（看完清零）、原地切章、80% 预取、翻到头切章、页码跳转、信息栏；窄屏底栏不再溢出。
- **下载**：批量多选下载、分层存储、离线上下章、`.done` 完成标记；设置页亦可进入「我的下载」。
- **源站**：内容校验测速、手动/自动模式、缓存清理、无网引导离线。
- **鲁棒性**：切章 PageController 单例、进度落盘防串章、收图 uuid 校验、旧章 `setLoadingDialog(false)` 不再拆新章加载框等（详见开发期自查）。

### 开发期里程碑（首发前合并叙述）

- 双 WebView 从 Headless 改为内联真实控件，修复 rAF 被节流导致的收图极慢。
- 收图停滞检测替代硬超时；章节切换对齐原生预取/原地换数据逻辑。
- 功能对齐原生：暗色模式、音量键翻页（Android）、JS 弹窗自动确认、双击状态栏、批量下载流水线等。
- 源站列表移除过期 `2025copy.com`，新增 `www.copymanga.site`；测速改为正文特征校验。
