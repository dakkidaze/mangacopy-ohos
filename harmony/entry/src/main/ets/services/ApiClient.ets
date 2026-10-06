/**
 * 拷贝漫画 API 客户端（规格 A.2/A.3/A.4/A.6）：
 * 统一请求头、业务码判定、Cookie 罐、Token、重试、评论域路由、节流。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiDomainManager } from './ApiDomainManager';
import { apiHeaders, isHotDomain, kDesktopUserAgent } from './ApiHeaders';
import { ApiThrottle } from './ApiThrottle';
import { authStore } from './AuthStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'ApiClient';

export class ApiException extends Error {
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
    this.name = 'ApiException';
  }
}

interface ApiBody {
  code?: Object;
  message?: Object;
  results?: Object;
}

const DEFAULT_RETRIES: number = 2; // 网络类错误重试至共 3 次
const DEFAULT_TIMEOUT_MS: number = 30000;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (v: void) => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

export class ApiClient {
  readonly domains: ApiDomainManager;
  private readonly throttle: ApiThrottle = new ApiThrottle();
  private token: string = '';
  private cookies: Map<string, string> = new Map<string, string>();

  constructor(domains: ApiDomainManager) {
    this.domains = domains;
  }

  setToken(t: string): void {
    this.token = t;
  }

  hasSession(): boolean {
    return this.cookies.size > 0 || this.token.length > 0;
  }

  /** 启动时恢复已持久化的 Cookie 会话。 */
  restoreCookies(saved: Map<string, string>): void {
    this.cookies = new Map<string, string>();
    saved.forEach((value: string, key: string) => {
      this.cookies.set(key, value);
    });
  }

  clearSession(): void {
    this.cookies = new Map<string, string>();
    this.token = '';
  }

  snapshotCookies(): Map<string, string> {
    const out = new Map<string, string>();
    this.cookies.forEach((value: string, key: string) => {
      out.set(key, value);
    });
    return out;
  }

  /**
   * 依据当前域是否为热辣域决定 `Webp` 头，并附 Token/Cookie。
   * `desktopUa=true` 时使用桌面 UA —— 章节图片接口服务端按 UA 限流：
   * 移动 UA 只返回前 5 页，桌面 UA 返回完整章节（实测 5 vs 33）。
   */
  private buildHeaders(desktopUa: boolean = false): Record<string, Object> {
    const h = apiHeaders(isHotDomain(this.domains.active) ? '1' : '0',
      desktopUa ? kDesktopUserAgent : '');
    if (this.token.length > 0) {
      h['Authorization'] = 'Token ' + this.token;
    }
    if (this.cookies.size > 0) {
      const pairs: string[] = [];
      this.cookies.forEach((value: string, key: string) => {
        pairs.push(key + '=' + value);
      });
      h['Cookie'] = pairs.join('; ');
    }
    return h;
  }

  /** 吸收响应里的 Set-Cookie：逐条取首个 name=value（spec A.3）。 */
  private absorbCookies(cookieHeader: string): void {
    if (cookieHeader.length === 0) {
      return;
    }
    const before = this.cookies.size;
    // HttpResponse.cookies 为原始串；多段 cookie 以（可能的）换行/逗号分隔。
    const lines = cookieHeader.split(/\r?\n|,(?=[^;]+?=)/);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const first = line.split(';')[0].trim();
      const eq = first.indexOf('=');
      if (eq > 0) {
        this.cookies.set(first.substring(0, eq).trim(), first.substring(eq + 1).trim());
      }
    }
    // 诊断：只记长度与条数，绝不记 cookie 值。
    hilog.info(DOMAIN, TAG, 'set-cookie 原始=%{public}d 字节，jar %{public}d → %{public}d 条',
      cookieHeader.length, before, this.cookies.size);
  }

  /** 评论请求需路由到支持评论的域（spec A.1）。 */
  private baseFor(comments: boolean): string {
    if (!comments) {
      return this.domains.active;
    }
    if (this.domains.supportsComments(this.domains.active)) {
      return this.domains.active;
    }
    for (let i = 0; i < this.domains.candidates.length; i++) {
      const d = this.domains.candidates[i];
      if (this.domains.supportsComments(d)) {
        return d;
      }
    }
    return this.domains.active;
  }

  async getJson(path: string, query: Record<string, string>, comments: boolean = false,
    retries: number = DEFAULT_RETRIES, timeoutMs: number = DEFAULT_TIMEOUT_MS): Promise<Object> {
    const base = this.baseFor(comments);
    let lastErr = '';
    for (let i = 0; i <= retries; i++) {
      try {
        // 章节图片接口用桌面 UA（服务端按 UA 限流：移动 UA 仅前 5 页）
        const desktopUa = path.indexOf('/chapter2/') >= 0 || path.indexOf('/chapter/') >= 0;
        if (desktopUa) {
          hilog.info(DOMAIN, TAG, 'GET %{public}s 使用桌面 UA（完整章节）', path);
        }
        const res = await this.throttle.run<http.HttpResponse>(
          () => this.doGet(base, path, query, timeoutMs, desktopUa));
        return this.parse(res);
      } catch (error) {
        if (error instanceof ApiException) {
          throw error as ApiException;
        }
        const be = error as BusinessError;
        lastErr = be.message !== undefined ? be.message : String(error);
        hilog.warn(DOMAIN, TAG, 'GET %{public}s try %{public}d failed: %{public}s', path, i, lastErr);
        if (i < retries) {
          await sleep(300 * (i + 1)); // 简单退避
        }
      }
    }
    throw new ApiException(-1, 'network error: ' + lastErr);
  }

  async postForm(path: string, form: Record<string, string>,
    retries: number = DEFAULT_RETRIES, timeoutMs: number = DEFAULT_TIMEOUT_MS): Promise<Object> {
    const base = this.domains.active;
    let lastErr = '';
    for (let i = 0; i <= retries; i++) {
      try {
        const res = await this.throttle.run<http.HttpResponse>(() => this.doPostForm(base, path, form, timeoutMs));
        return this.parse(res);
      } catch (error) {
        if (error instanceof ApiException) {
          throw error as ApiException;
        }
        const be = error as BusinessError;
        lastErr = be.message !== undefined ? be.message : String(error);
        hilog.warn(DOMAIN, TAG, 'POST %{public}s try %{public}d failed: %{public}s', path, i, lastErr);
        if (i < retries) {
          await sleep(300 * (i + 1));
        }
      }
    }
    throw new ApiException(-1, 'network error: ' + lastErr);
  }

  private buildUrl(base: string, path: string, query: Record<string, string>): string {
    let url = base + path;
    const keys = Object.keys(query);
    if (keys.length > 0) {
      const parts: string[] = [];
      for (let i = 0; i < keys.length; i++) {
        parts.push(encodeURIComponent(keys[i]) + '=' + encodeURIComponent(query[keys[i]]));
      }
      url += '?' + parts.join('&');
    }
    return url;
  }

  private async doGet(base: string, path: string, query: Record<string, string>,
    timeoutMs: number, desktopUa: boolean = false): Promise<http.HttpResponse> {
    const request = http.createHttp();
    try {
      const res = await request.request(this.buildUrl(base, path, query), {
        method: http.RequestMethod.GET,
        header: this.buildHeaders(desktopUa),
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs
      });
      this.absorbCookies(res.cookies);
      return res;
    } finally {
      request.destroy();
    }
  }

  private async doPostForm(base: string, path: string, form: Record<string, string>,
    timeoutMs: number): Promise<http.HttpResponse> {
    const request = http.createHttp();
    try {
      const keys = Object.keys(form);
      const parts: string[] = [];
      for (let i = 0; i < keys.length; i++) {
        parts.push(encodeURIComponent(keys[i]) + '=' + encodeURIComponent(form[keys[i]]));
      }
      const header = this.buildHeaders();
      header['Content-Type'] = 'application/x-www-form-urlencoded';
      const res = await request.request(base + path, {
        method: http.RequestMethod.POST,
        header: header,
        extraData: parts.join('&'),
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs
      });
      this.absorbCookies(res.cookies);
      return res;
    } finally {
      request.destroy();
    }
  }

  /**
   * 业务码判定（spec A.6）：HTTP 非 2xx → code=status；
   * 200 但 body.code != 200 → code=body.code（如 210），message 取 body.message；
   * code==200 → 返回 body.results。
   */
  private parse(res: http.HttpResponse): Object {
    const status = Number(res.responseCode);
    if (status < 200 || status >= 300) {
      throw new ApiException(status, 'HTTP ' + status);
    }
    const body = JSON.parse(res.result as string) as ApiBody;
    const codeVal: Object | undefined = body.code;
    const code = typeof codeVal === 'number' ? codeVal as number : -1;
    if (code === 200) {
      const results: Object | undefined = body.results;
      return results !== undefined && results !== null ? results : new Object();
    }
    const messageVal: Object | undefined = body.message;
    const message = typeof messageVal === 'string' ? messageVal as string : '';
    throw new ApiException(code, message);
  }
}

/** 当前 token（供登录后 saveSession 使用）。 */
export function currentToken(): string {
  return authStore.getToken();
}
