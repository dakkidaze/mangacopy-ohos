/**
 * 登录态持久化（规格 C / A.3）：token（`Authorization: Token`）与网页会话 Cookie。
 *
 * 网页登录通常只给 Cookie、不给 token，所以两者都要落盘，否则重启即掉登录。
 * prefs key：`api_token`、`api_cookies`（JSON Map）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export interface CookieEntry {
  key: string;
  value: string;
}

const PREFS_NAME: string = 'copymanga_arkts_prefs';
const KEY_TOKEN: string = 'api_token';
const KEY_COOKIES: string = 'api_cookies';

function ctx(): common.UIAbilityContext {
  const c = AppStorage.get<common.UIAbilityContext>('abilityContext');
  if (c === undefined) {
    throw new Error('abilityContext not ready');
  }
  return c;
}

export class AuthStore {
  private token: string = '';
  private cookies: Map<string, string> = new Map<string, string>();

  getToken(): string {
    return this.token;
  }

  getCookieEntries(): CookieEntry[] {
    const out: CookieEntry[] = [];
    this.cookies.forEach((value: string, key: string) => {
      out.push({ key: key, value: value });
    });
    return out;
  }

  hasSavedSession(): boolean {
    return this.token.length > 0 || this.cookies.size > 0;
  }

  /** 启动时恢复。无持久化内容时保持空。 */
  async load(): Promise<void> {
    const prefs = await preferences.getPreferences(ctx(), { name: PREFS_NAME });
    this.token = (await prefs.get(KEY_TOKEN, '')) as string;
    this.cookies = new Map<string, string>();
    const raw = (await prefs.get(KEY_COOKIES, '')) as string;
    if (raw.length > 0) {
      try {
        const parsed = JSON.parse(raw) as Record<string, Object>;
        const keys = Object.keys(parsed);
        for (let i = 0; i < keys.length; i++) {
          this.cookies.set(keys[i], String(parsed[keys[i]]));
        }
      } catch (error) {
        this.cookies = new Map<string, string>();
      }
    }
  }

  /** 保存/清除整个会话（token + Cookie）。 */
  async saveSession(token: string, cookies: Map<string, string>): Promise<void> {
    this.token = token;
    this.cookies = cookies;
    const prefs = await preferences.getPreferences(ctx(), { name: PREFS_NAME });
    if (token.length === 0) {
      await prefs.delete(KEY_TOKEN);
    } else {
      await prefs.put(KEY_TOKEN, token);
    }
    if (cookies.size === 0) {
      await prefs.delete(KEY_COOKIES);
    } else {
      const obj: Record<string, Object> = {};
      cookies.forEach((value: string, key: string) => {
        obj[key] = value;
      });
      await prefs.put(KEY_COOKIES, JSON.stringify(obj));
    }
    await prefs.flush();
  }

  async clear(): Promise<void> {
    await this.saveSession('', new Map<string, string>());
  }
}

export const authStore: AuthStore = new AuthStore();
