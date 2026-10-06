import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// iOS 无公开音量键 API；通过 MPVolumeView + outputVolume 观察实现翻页（阅读类 App 常用做法）。
///
/// 策略：进入时记下用户音量；阅读中把工作点钳在 [0.15, 0.85] 以便总能检测到按键；
/// 每次按键后拉回工作点；退到后台/关掉功能时立刻还原（适配「回桌面再划掉后台」）。
///
/// 修复：resettingVolume 期间的按键不再丢弃，用 pendingKeyDirection 暂存，
/// 重置完成后立即补发，解决「大部分时候不工作」问题。
private final class IOSVolumeKeyHandler: NSObject {
  private let channel: FlutterMethodChannel
  private var enabled = false
  private var volumeView: MPVolumeView?
  private var observing = false
  private var lastVolume: Float = 0.5
  private var resettingVolume = false
  private var resetWorkItem: DispatchWorkItem?

  /// 进入阅读器时的系统音量，退出/进后台时还原
  private var savedUserVolume: Float = 0.5
  /// 阅读中用于检测按键的锚点（避免顶/底无 delta）
  private var anchorVolume: Float = 0.5
  /// 是否曾真正开启过（避免未开启时 disable 误改系统音量）
  private var didCaptureVolume = false
  /// 已因进后台还原过，前台再重新武装
  private var suspendedForBackground = false

  /// resettingVolume 期间捕获的待补发方向（+1=up / -1=down / 0=无）
  private var pendingKeyDirection: Int = 0

  private let minAnchor: Float = 0.15
  private let maxAnchor: Float = 0.85

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "cm/volkeys", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "setEnabled":
        let on = call.arguments as? Bool ?? false
        self.setEnabled(on)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  private func setEnabled(_ on: Bool) {
    if on {
      enabled = true
      suspendedForBackground = false
      captureAndArm(from: AVAudioSession.sharedInstance().outputVolume)
    } else {
      enabled = false
      suspendedForBackground = false
      pendingKeyDirection = 0
      if didCaptureVolume {
        didCaptureVolume = false
        // 先还原用户音量，再拆观察
        resetVolume(to: savedUserVolume, immediate: true, teardownAfter: true)
      } else {
        stopObserving()
      }
    }
  }

  private func captureAndArm(from current: Float) {
    savedUserVolume = current
    didCaptureVolume = true
    anchorVolume = min(max(current, minAnchor), maxAnchor)
    // 关键修复：先设定 lastVolume = anchorVolume，再开始观察。
    // 这样 captureAndArm 触发的初始 resetVolume 把音量调到锚点时，
    // observeValue 不会把这次系统音量变化误判为一次用户按键。
    lastVolume = anchorVolume
    startObserving()
    resetVolume(to: anchorVolume, immediate: true, teardownAfter: false)
  }

  /// 回桌面 / 进多任务：立刻还原音量。之后即使用户划掉 App，音量也已是进入前的值。
  @objc private func appWillResignActive() {
    guard enabled, didCaptureVolume, !suspendedForBackground else { return }
    suspendedForBackground = true
    pendingKeyDirection = 0
    // 同步写回，避免「回桌面后立刻划掉」时 async 还原来不及执行
    resetVolume(to: savedUserVolume, immediate: true, teardownAfter: false, preferSync: true)
  }

  /// 回到前台且仍开着音量翻页：按当前系统音量重新武装锚点。
  @objc private func appDidBecomeActive() {
    guard enabled, didCaptureVolume, suspendedForBackground else { return }
    suspendedForBackground = false
    captureAndArm(from: AVAudioSession.sharedInstance().outputVolume)
  }

  private func startObserving() {
    if observing { return }
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setActive(true)
    } catch {}
    ensureVolumeViewAttached()
    session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
    observing = true
  }

  private func ensureVolumeViewAttached() {
    if volumeView == nil {
      let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
      view.clipsToBounds = true
      view.isUserInteractionEnabled = false
      volumeView = view
    }
    guard let view = volumeView, view.superview == nil else { return }
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: { $0.isKeyWindow })
      ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first
    window?.addSubview(view)
  }

  private func findVolumeSlider(in view: UIView) -> UISlider? {
    if let slider = view as? UISlider { return slider }
    for sub in view.subviews {
      if let found = findVolumeSlider(in: sub) { return found }
    }
    return nil
  }

  private func stopObserving() {
    guard observing else { return }
    resetWorkItem?.cancel()
    resetWorkItem = nil
    AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
    observing = false
    volumeView?.removeFromSuperview()
    volumeView = nil
    resettingVolume = false
    pendingKeyDirection = 0
  }

  override func observeValue(
    forKeyPath keyPath: String?,
    of object: Any?,
    change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    // 挂起后台期间不翻页、不把音量再拉回锚点
    guard enabled, !suspendedForBackground, keyPath == "outputVolume" else { return }
    let newVolume = AVAudioSession.sharedInstance().outputVolume

    if resettingVolume {
      // 修复：重置期间收到按键，不丢弃——记录方向，等重置完后补发。
      // 只保留最后一次方向（连续同向多次：合并为一次；方向反转：以最新为准）。
      if newVolume > lastVolume + 0.001 {
        pendingKeyDirection = 1
      } else if newVolume < lastVolume - 0.001 {
        pendingKeyDirection = -1
      }
      return
    }

    if newVolume > lastVolume + 0.001 {
      channel.invokeMethod("volUp", arguments: nil)
    } else if newVolume < lastVolume - 0.001 {
      channel.invokeMethod("volDown", arguments: nil)
    } else {
      lastVolume = newVolume
      return
    }
    lastVolume = newVolume
    resetVolume(to: anchorVolume, immediate: false, teardownAfter: false)
  }

  private func finishResetWindow(teardownAfter: Bool) {
    lastVolume = AVAudioSession.sharedInstance().outputVolume
    resettingVolume = false
    if teardownAfter {
      stopObserving()
      return
    }
    // 补发重置期间被暂存的按键
    let pending = pendingKeyDirection
    pendingKeyDirection = 0
    if pending == 1 {
      channel.invokeMethod("volUp", arguments: nil)
      resetVolume(to: anchorVolume, immediate: false, teardownAfter: false)
    } else if pending == -1 {
      channel.invokeMethod("volDown", arguments: nil)
      resetVolume(to: anchorVolume, immediate: false, teardownAfter: false)
    }
  }

  private func applySliderValue(_ value: Float, in view: UIView) -> Bool {
    guard let slider = findVolumeSlider(in: view) else { return false }
    slider.value = value
    lastVolume = value
    return true
  }

  private func resetVolume(
    to value: Float,
    immediate: Bool,
    teardownAfter: Bool,
    preferSync: Bool = false
  ) {
    resetWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      // teardown（关闭功能）时允许 enabled==false；后台还原时 enabled 仍为 true
      if !teardownAfter && !self.enabled && !self.suspendedForBackground { return }
      self.ensureVolumeViewAttached()
      guard let view = self.volumeView else {
        if teardownAfter { self.stopObserving() }
        return
      }
      self.resettingVolume = true
      if self.applySliderValue(value, in: view) {
        if preferSync {
          // 进后台路径：立刻结束忽略窗，不依赖后续 async
          self.finishResetWindow(teardownAfter: teardownAfter)
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.finishResetWindow(teardownAfter: teardownAfter)
          }
        }
        return
      }
      if preferSync {
        // 同步路径找不到 slider 时再异步重试一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
          guard let self else { return }
          self.ensureVolumeViewAttached()
          if let v = self.volumeView {
            self.resettingVolume = true
            _ = self.applySliderValue(value, in: v)
          }
          self.finishResetWindow(teardownAfter: teardownAfter)
        }
        return
      }
      // slider 尚未渲染（首次进入时常见）：缩短重试窗口至 30ms（原 120ms），降低死区时长
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
        guard let self else { return }
        if !teardownAfter && !self.enabled && !self.suspendedForBackground { return }
        self.ensureVolumeViewAttached()
        guard let v = self.volumeView else {
          self.finishResetWindow(teardownAfter: teardownAfter)
          return
        }
        self.resettingVolume = true
        _ = self.applySliderValue(value, in: v)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
          self?.finishResetWindow(teardownAfter: teardownAfter)
        }
      }
    }
    resetWorkItem = work
    if preferSync && Thread.isMainThread {
      work.perform()
    } else if immediate {
      DispatchQueue.main.async(execute: work)
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    resetWorkItem?.cancel()
    if observing {
      AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var volumeHandler: IOSVolumeKeyHandler?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IOSVolumeKeyHandler") {
      volumeHandler = IOSVolumeKeyHandler(messenger: registrar.messenger())
    }
  }
}
