/**
 * 主题状态与背景色解析。
 *
 * 资源限定符只有 base / dark 两套，AMOLED 纯黑没法再靠限定符表达；同时
 * 「跟随系统」需要知道系统当前到底是亮还是暗，才能决定 AMOLED 是否生效。
 * 因此这里维护一份全局响应式状态（AppStorageV2），页面只把**背景类** token
 * 换成 theme.background(...)，文字/强调色继续走 $r('app.color.*')。
 */
import { AppStorageV2 } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';

/** 主题模式取值。 */
export const THEME_SYSTEM: string = 'system';
export const THEME_LIGHT: string = 'light';
export const THEME_DARK: string = 'dark';

/** AMOLED 纯黑下的背景层次：纯黑底 + 极深表面，保留层次区分。 */
const AMOLED_PAGE: string = '#000000';
const AMOLED_SURFACE: string = '#0B0F12';
const AMOLED_SURFACE_VARIANT: string = '#14191D';
const AMOLED_FIELD: string = '#14191D';
const AMOLED_NAV: string = '#E60B0F12';

/**
 * 深色下底部导航条的**不透明**底色。
 *
 * 原色板里 dark 的 nav_surface 是带 alpha 的（#D91A2429）。它单独用时没问题，
 * 但叠上 backgroundBlurStyle(COMPONENT_THICK) 后，厚材质会在其上再叠一层偏亮
 * 的毛玻璃，实测把底栏整体提亮到 #454B50 以上，未选中的 secondary_text 对比度
 * 掉到 4.25 / 3.29 —— 就是"主页看不清"的成因。
 *
 * 这里不改任何既有色值，只是深色下改用与主题一致的**不透明深色**承载，
 * 让厚材质无处可提亮。取值沿用色板里已有的深色层次（surface #182126），
 * 不引入新色系。
 */
const DARK_NAV_OPAQUE: string = '#182126';
const AMOLED_NAV_OPAQUE: string = '#0B0F12';

/** 背景类 token 名，AMOLED 只覆盖这些；文字/强调色一律不动。 */
export type BackgroundToken =
  'page_background' | 'surface' | 'surface_variant' | 'field_background' | 'nav_surface';

/** 全局主题状态：改了它所有引用处立即重绘。 */
@ObservedV2
export class ThemeState {
  @Trace themeMode: string = THEME_SYSTEM;
  @Trace amoledBlack: boolean = false;
  /** 系统当前是否为深色（仅 themeMode=system 时参与判定）。 */
  @Trace systemDark: boolean = false;
  /**
   * 每次应用主题都自增。背景色解析里会读它，从而把"主题变了"变成一次
   * 确定的重绘，而不只依赖系统资源限定符刷新——切换必须立刻可见。
   */
  @Trace themeRevision: number = 0;

  get isDark(): boolean {
    if (this.themeMode === THEME_DARK) {
      return true;
    }
    if (this.themeMode === THEME_LIGHT) {
      return false;
    }
    return this.systemDark;
  }

  /** AMOLED 只在深色下生效。 */
  get amoledActive(): boolean {
    return this.amoledBlack && this.isDark;
  }
}

/**
 * 背景类 token → 实际颜色。
 * 非 AMOLED 时返回资源引用（base/dark 限定符自动切换），AMOLED 时返回纯黑层次。
 * $r() 不接受动态参数，只能逐个 case 写死；范围严格限制在背景类。
 */
export function themeBackground(token: BackgroundToken, amoled: boolean, revision: number): ResourceColor {
  // 读 revision 建立依赖：主题一切换这里必然重算，切换结果立刻可见
  if (revision < 0) {
    return $r('app.color.page_background');
  }
  if (amoled) {
    switch (token) {
      case 'page_background':
        return AMOLED_PAGE;
      case 'surface':
        return AMOLED_SURFACE;
      case 'surface_variant':
        return AMOLED_SURFACE_VARIANT;
      case 'field_background':
        return AMOLED_FIELD;
      case 'nav_surface':
        return AMOLED_NAV;
      default:
        return $r('app.color.page_background');
    }
  }
  switch (token) {
    case 'page_background':
      return $r('app.color.page_background');
    case 'surface':
      return $r('app.color.surface');
    case 'surface_variant':
      return $r('app.color.surface_variant');
    case 'field_background':
      return $r('app.color.field_background');
    case 'nav_surface':
      return $r('app.color.nav_surface');
    default:
      return $r('app.color.page_background');
  }
}

/** 主题模式 → setColorMode 的参数。 */
export function colorModeOf(themeMode: string): ConfigurationConstant.ColorMode {
  if (themeMode === THEME_DARK) {
    return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
  if (themeMode === THEME_LIGHT) {
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }
  return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
}

/**
 * 应用主题到全局并同步到响应式状态，切换后当帧即生效（无需重启 App）。
 * 返回是否真正改了系统色模式：跟随系统这一档依赖系统配置，无法预知，
 * 因此 systemDark 由调用方在 Configuration 回调里补。
 */
export function applyThemeMode(themeMode: string, amoled: boolean): void {
  const state = themeState();
  state.themeMode = validThemeMode(themeMode);
  state.amoledBlack = amoled;
  // 自增放在 setColorMode 之前：状态先变，重绘时拿到的已是新主题
  state.themeRevision++;
  const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
  if (ctx === undefined) {
    return;
  }
  try {
    ctx.getApplicationContext().setColorMode(colorModeOf(state.themeMode));
  } catch (error) {
    // 主题切换失败不阻塞 UI；状态已更新，下次进页面还会再试
  }
}

/**
 * 同步"系统自身的亮/暗偏好"，只供跟随系统档位判定。
 *
 * 关键点：应用强制设为亮/深之后，Configuration.colorMode 反映的是**强制值**
 * 而非系统偏好。若拿它去更新 systemDark，等用户切回"跟随系统"时就会读到
 * 上一次的强制值，跟着系统档位就失真了。因此非跟随系统档位时直接跳过，
 * 只认真正的系统配置变化；启动时（force=true）尚未调用过 setColorMode，
 * 读到的就是系统真实值。
 */
export function syncSystemDark(systemIsDark: boolean, force: boolean = false): void {
  const state = themeState();
  if (!force && state.themeMode !== THEME_SYSTEM) {
    return;
  }
  if (state.systemDark !== systemIsDark) {
    state.systemDark = systemIsDark;
  }
}

/** 合法化主题模式，脏值退回跟随系统。 */
export function validThemeMode(value: string): string {
  if (value === THEME_LIGHT || value === THEME_DARK) {
    return value;
  }
  return THEME_SYSTEM;
}

/**
 * 底部导航条这类悬浮条的底色。
 * 深色/AMOLED 下返回不透明深色，避免厚模糊材质把它整体提亮（见 DARK_NAV_OPAQUE 注释）；
 * 浅色下原样沿用 nav_surface。
 */
export function navBarBackground(dark: boolean, amoled: boolean, revision: number): ResourceColor {
  if (revision < 0) {
    return $r('app.color.nav_surface');
  }
  if (dark) {
    return amoled ? AMOLED_NAV_OPAQUE : DARK_NAV_OPAQUE;
  }
  return $r('app.color.nav_surface');
}

/**
 * 底部导航这类悬浮条的材质样式。
 *
 * 深色下改用 NONE：不透明底色已经足够，再叠任何材质只会把底栏提亮，
 * 把未选中文字的对比度重新压下去。浅色下保留 Thick 维持原有的玻璃层次感。
 */
export function navBlurStyle(dark: boolean): BlurStyle {
  return dark ? BlurStyle.NONE : BlurStyle.Thick;
}

/** 取（必要时创建）全局主题状态。 */
export function themeState(): ThemeState {
  const created = AppStorageV2.connect(ThemeState, 'appThemeState',
    (): ThemeState => new ThemeState());
  return created !== undefined ? created : new ThemeState();
}
