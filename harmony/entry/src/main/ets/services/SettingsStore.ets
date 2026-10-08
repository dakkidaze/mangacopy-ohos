/**
 * 全局设置持久化（规格 C 偏好 Key 总表）。
 * key 与 Dart AppSettings 严格一致；preferences 里统一存字符串/数字，
 * bool 用 '1'/'0' 字符串（@ohos preferences 原生支持 boolean，此处按原生类型存取）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREFS_NAME: string = 'copymanga_arkts_prefs';

export const KEY_API_TOKEN: string = 'api_token';
export const KEY_API_COOKIES: string = 'api_cookies';
export const KEY_ACTIVE_URL: string = 'active_url';
export const KEY_MANUAL_URL: string = 'manual_url';
export const KEY_READ_MODE: string = 'readMode';
/**
 * 阅读方向：'left' = 左开本（默认；点左半边/向右滑 = 下一页，Swiper 走 RTL），
 * 'right' = 右开本（点右半边/向左滑 = 下一页，动画原生方向）。
 * 只对「横向翻页」生效；纵向与条漫恒定不受它影响。
 * 旧的布尔 KEY_R2L('r2l') 已废弃删除（设置页/阅读器都不再读写）。
 */
export const KEY_READ_DIRECTION: string = 'readDirection';
export const KEY_SHOW_PAGE_NUM: string = 'showPageNum';
export const KEY_SOURCE_PROFILE: string = 'sourceProfile';
export const KEY_VOL_TURN: string = 'volTurn';
export const KEY_CHAPTER_SOURCE: string = 'chapterSource';
export const KEY_CHAPTER_END_COMMENTS: string = 'chapterEndComments';
export const KEY_BROWSE_SOURCE: string = 'browseSource';
export const KEY_DARK_MODE: string = 'darkMode';
/** 主题模式：system（跟随系统）/ light / dark。取代旧的布尔 KEY_DARK_MODE。 */
export const KEY_THEME_MODE: string = 'themeMode';
/** 深色模式下的 AMOLED 纯黑背景；仅深色生效。 */
export const KEY_AMOLED_BLACK: string = 'amoledBlack';
export const KEY_HIDE_STATUS_BAR: string = 'hideStatusBar';
export const KEY_IMAGE_CACHE_LIMIT_MB: string = 'imageCacheLimitMb';

function ctx(): common.UIAbilityContext {
  const c = AppStorage.get<common.UIAbilityContext>('abilityContext');
  if (c === undefined) {
    throw new Error('abilityContext not ready');
  }
  return c;
}

async function store(): Promise<preferences.Preferences> {
  return preferences.getPreferences(ctx(), { name: PREFS_NAME });
}

export class SettingsStore {
  async getString(key: string, def: string): Promise<string> {
    const prefs = await store();
    return (await prefs.get(key, def)) as string;
  }

  async putString(key: string, value: string): Promise<void> {
    const prefs = await store();
    await prefs.put(key, value);
    await prefs.flush();
  }

  async remove(key: string): Promise<void> {
    const prefs = await store();
    await prefs.delete(key);
    await prefs.flush();
  }

  async getBool(key: string, def: boolean): Promise<boolean> {
    const prefs = await store();
    return (await prefs.get(key, def)) as boolean;
  }

  async putBool(key: string, value: boolean): Promise<void> {
    const prefs = await store();
    await prefs.put(key, value);
    await prefs.flush();
  }

  async getInt(key: string, def: number): Promise<number> {
    const prefs = await store();
    return (await prefs.get(key, def)) as number;
  }

  async putInt(key: string, value: number): Promise<void> {
    const prefs = await store();
    await prefs.put(key, value);
    await prefs.flush();
  }

  // ---- 便捷读写（默认值按规格 C）----

  async readMode(): Promise<string> {
    return this.getString(KEY_READ_MODE, 'h');
  }

  async sourceProfile(): Promise<string> {
    return this.getString(KEY_SOURCE_PROFILE, 'fast');
  }

  async chapterSource(): Promise<string> {
    return this.getString(KEY_CHAPTER_SOURCE, 'api');
  }

  async browseSource(): Promise<string> {
    return this.getString(KEY_BROWSE_SOURCE, 'api');
  }

  async imageCacheLimitMb(): Promise<number> {
    return this.getInt(KEY_IMAGE_CACHE_LIMIT_MB, 1024);
  }

  /**
   * 主题模式：system / light / dark。
   * 迁移：从未写过新 key 时，沿用旧的布尔 darkMode —— true → dark，false/缺失 → system。
   * 这样老用户升级后不会丢掉「已开夜间模式」的偏好。
   */
  async themeMode(): Promise<string> {
    const raw = await this.getString(KEY_THEME_MODE, '');
    if (raw === 'light' || raw === 'dark' || raw === 'system') {
      return raw;
    }
    const legacy = await this.getBool(KEY_DARK_MODE, false);
    return legacy ? 'dark' : 'system';
  }

  async amoledBlack(): Promise<boolean> {
    return this.getBool(KEY_AMOLED_BLACK, false);
  }
}

export const settingsStore: SettingsStore = new SettingsStore();
