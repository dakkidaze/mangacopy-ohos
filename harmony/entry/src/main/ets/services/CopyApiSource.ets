/**
 * 拷贝漫画 API 图源实现（规格 A.5 全部端点）。
 * 对应 Dart copy_manga_api_source.dart。
 */
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ApiException, ApiClient } from './ApiClient';
import { isHotDomain } from './ApiHeaders';
import { authStore } from './AuthStore';
import { MangaSummary, Chapter, MangaDetail, Comment, listOfResults } from '../model/Models';

const K_POS: string = '3200102';

function buildQuery(pairs: Record<string, string>): Record<string, string> {
  return pairs;
}

export class CopyApiSource {
  private readonly client: ApiClient;
  private readonly defaultGroup: string;

  constructor(client: ApiClient, defaultGroup: string = 'default') {
    this.client = client;
    this.defaultGroup = defaultGroup;
  }

  private summaries(results: Object | null): MangaSummary[] {
    const list = listOfResults(results);
    const out: MangaSummary[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(MangaSummary.fromJson(list[i]));
    }
    return out;
  }

  private comments(results: Object | null): Comment[] {
    const list = listOfResults(results);
    const out: Comment[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(Comment.fromJson(list[i]));
    }
    return out;
  }

  /** 1. 热门推荐。 */
  async popular(offset: number): Promise<MangaSummary[]> {
    const r = await this.client.getJson('/api/v3/recs',
      buildQuery({ 'pos': K_POS, 'limit': '21', 'offset': String(offset) }));
    return this.summaries(r);
  }

  /** 2. 最新更新。 */
  async latest(offset: number): Promise<MangaSummary[]> {
    const r = await this.client.getJson('/api/v3/update/newest',
      buildQuery({ 'limit': '21', 'offset': String(offset) }));
    return this.summaries(r);
  }

  /** 3. 搜索。 */
  async search(query: string, offset: number): Promise<MangaSummary[]> {
    const r = await this.client.getJson('/api/v3/search/comic',
      buildQuery({ 'limit': '21', 'offset': String(offset), 'q': query, '_update': 'true' }));
    return this.summaries(r);
  }

  /** 4. 筛选（排序/地区/题材/收费）。 */
  async filter(ordering: string, region: string, theme: string, freeType: string,
    offset: number): Promise<MangaSummary[]> {
    const r = await this.client.getJson('/api/v3/comics', buildQuery({
      'limit': '21',
      'offset': String(offset),
      'ordering': ordering.length > 0 ? ordering : '-datetime_updated',
      'top': region,
      'theme': theme,
      'free_type': freeType,
      '_update': 'true'
    }));
    return this.summaries(r);
  }

  /** 5. 详情。 */
  async detail(id: string): Promise<MangaDetail | null> {
    const r = await this.client.getJson('/api/v3/comic2/' + id, buildQuery({}));
    const rec = r as Record<string, Object>;
    const comic = rec['comic'];
    if (comic === undefined || comic === null) {
      return null;
    }
    return MangaDetail.fromJson(comic);
  }

  /** 6. 章节列表。 */
  async chapters(id: string, group: string): Promise<Chapter[]> {
    const g = group.length > 0 ? group : this.defaultGroup;
    const r = await this.client.getJson('/api/v3/comic/' + id + '/group/' + g + '/chapters',
      buildQuery({ 'limit': '500', 'offset': '0', '_update': 'true' }));
    const list = listOfResults(r);
    const out: Chapter[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(Chapter.fromJson(list[i]));
    }
    return out;
  }

  /**
   * 7a/7b. 章节图片内容：热辣域 `/chapter`，其余 `/chapter2`（均带 Webp 头，由 ApiClient 头逻辑决定）。
   * contents[] 兼容 url ?? image ?? src。
   */
  async pages(id: string, chapterId: string): Promise<string[]> {
    const seg = isHotDomain(this.client.domains.active) ? 'chapter' : 'chapter2';
    const r = await this.client.getJson('/api/v3/comic/' + id + '/' + seg + '/' + chapterId,
      buildQuery({}));
    let chapter: Object | undefined | null = r;
    const rec = r as Record<string, Object>;
    if (rec['chapter'] !== undefined && rec['chapter'] !== null) {
      chapter = rec['chapter'];
    }
    const chapterRec = chapter as Record<string, Object>;
    const contents = chapterRec['contents'];
    const out: string[] = [];
    if (Array.isArray(contents)) {
      const arr = contents as Object[];
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i] as Record<string, Object>;
        let url = '';
        if (item['url'] !== undefined && item['url'] !== null) {
          url = String(item['url']);
        } else if (item['image'] !== undefined && item['image'] !== null) {
          url = String(item['image']);
        } else if (item['src'] !== undefined && item['src'] !== null) {
          url = String(item['src']);
        }
        if (url.length > 0) {
          out.push(url);
        }
      }
    }
    return out;
  }

  /** 8. 章末吐槽：必须传 chapter_id（传 comic_id 返回 210）。 */
  async chapterComments(chapterId: string): Promise<Comment[]> {
    const r = await this.client.getJson('/api/v3/roasts',
      buildQuery({ 'chapter_id': chapterId, 'limit': '100' }), true);
    return this.comments(r);
  }

  /** 9. 漫画总评。 */
  async comicComments(comicUuid: string): Promise<Comment[]> {
    const r = await this.client.getJson('/api/v3/comments',
      buildQuery({ 'comic_id': comicUuid, 'limit': '20', 'offset': '0' }), true);
    return this.comments(r);
  }

  /**
   * 10. 登录：password = base64(utf8(pass + '-' + salt))，salt = 1000–9999 随机。
   * 成功后取 token ?? access_token → setToken + AuthStore.saveSession(token, cookies)。
   */
  async login(user: string, pass: string): Promise<boolean> {
    const salt = String(1000 + Math.floor(Math.random() * 9000));
    const encoder = util.TextEncoder.create('utf-8');
    const bytes = encoder.encodeInto(pass + '-' + salt);
    const enc = new util.Base64Helper().encodeToStringSync(bytes);
    try {
      const r = await this.client.postForm('/api/v3/login',
        buildQuery({ 'username': user, 'password': enc, 'salt': salt }));
      const rec = r as Record<string, Object>;
      let token = '';
      if (rec['token'] !== undefined && rec['token'] !== null) {
        token = String(rec['token']);
      } else if (rec['access_token'] !== undefined && rec['access_token'] !== null) {
        token = String(rec['access_token']);
      }
      if (token.length > 0) {
        this.client.setToken(token);
      }
      // 整个会话（token + Cookie）落盘，避免重启掉登录。
      await authStore.saveSession(token.length > 0 ? token : this.client.hasSession() ? authStore.getToken() : '',
        this.client.snapshotCookies());
      return token.length > 0 || this.client.hasSession();
    } catch (error) {
      if (error instanceof ApiException) {
        throw (error as ApiException); // 调试页需要原始错误码与文案
      }
      const be = error as BusinessError;
      throw new ApiException(-2, be.message !== undefined ? be.message : String(error));
    }
  }

  /** 11. 收藏（需登录）。 */
  async favorites(offset: number): Promise<MangaSummary[]> {
    const r = await this.client.getJson('/api/v3/member/collect/comics', buildQuery({
      'limit': '30',
      'offset': String(offset),
      'free_type': '1',
      'ordering': '-datetime_modifier'
    }));
    return this.summaries(r);
  }

  /** 12. 历史（需登录）。 */
  async history(offset: number): Promise<MangaSummary[]> {
    const r = await this.client.getJson('/api/kb/web/browses',
      buildQuery({ 'limit': '30', 'offset': String(offset), 'free_type': '1' }));
    return this.summaries(r);
  }
}
