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
export const KEY_R2L: string = 'r2l';
export const KEY_SHOW_PAGE_NUM: string = 'showPageNum';
export const KEY_SOURCE_PROFILE: string = 'sourceProfile';
export const KEY_VOL_TURN: string = 'volTurn';
export const KEY_CHAPTER_SOURCE: string = 'chapterSource';
export const KEY_CHAPTER_END_COMMENTS: string = 'chapterEndComments';
export const KEY_BROWSE_SOURCE: string = 'browseSource';
export const KEY_DARK_MODE: string = 'darkMode';
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
}

export const settingsStore: SettingsStore = new SettingsStore();
