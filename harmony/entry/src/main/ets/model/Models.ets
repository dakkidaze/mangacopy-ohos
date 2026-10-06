/**
 * 拷贝漫画 API 数据模型（规格 B）。
 *
 * 字段名对应 `/api/v3` 实测返回；列表项可能是「扁平项」，也可能包一层 `comic`
 * （Dart `_unwrapComic`），fromJson 统一兼容两种形态。
 */

/** author 字段兼容：数组取首元素；对象取 name；其余原样字符串。 */
export interface AuthorRef {
  name?: string;
}

function unwrapComic(raw: Record<string, Object>): Record<string, Object> {
  const inner = raw['comic'];
  if (inner !== null && inner !== undefined && typeof inner === 'object' && !Array.isArray(inner)) {
    return inner as Record<string, Object>;
  }
  return raw;
}

function str(v: Object | undefined | null): string {
  if (v === null || v === undefined) {
    return '';
  }
  return String(v);
}

/** author：数组 → 首元素 name；对象 → name；字符串 → 原样。 */
export function authorName(v: Object | undefined | null): string {
  if (Array.isArray(v)) {
    if (v.length === 0) {
      return '';
    }
    return authorName(v[0] as Object);
  }
  if (v !== null && v !== undefined && typeof v === 'object') {
    const rec = v as Record<string, string>;
    return str(rec['name']);
  }
  return str(v);
}

/** status/region 等：对象取 display，字符串原样。 */
export function displayValue(v: Object | undefined | null): string {
  if (v !== null && v !== undefined && typeof v === 'object' && !Array.isArray(v)) {
    return str((v as Record<string, Object>)['display']);
  }
  return str(v);
}

export class MangaSummary {
  readonly id: string; // path_word
  readonly title: string; // name
  readonly cover: string;
  readonly author: string;

  constructor(id: string, title: string, cover: string, author: string) {
    this.id = id;
    this.title = title;
    this.cover = cover;
    this.author = author;
  }

  static fromJson(raw: Object): MangaSummary {
    const m = unwrapComic(raw as Record<string, Object>);
    return new MangaSummary(
      str(m['path_word']),
      str(m['name']),
      str(m['cover']),
      authorName(m['author'])
    );
  }
}

export class Chapter {
  readonly id: string; // uuid
  readonly name: string;
  readonly index: number;
  readonly size: number;

  constructor(id: string, name: string, index: number, size: number) {
    this.id = id;
    this.name = name;
    this.index = index;
    this.size = size;
  }

  static fromJson(raw: Object): Chapter {
    const m = raw as Record<string, Object>;
    return new Chapter(
      str(m['uuid']),
      str(m['name']),
      toInt(m['index']),
      toInt(m['size'])
    );
  }
}

export class MangaDetail {
  readonly id: string; // path_word
  readonly title: string;
  readonly cover: string;
  readonly author: string;
  readonly description: string; // brief ?? description
  readonly status: string; // status.display
  readonly uuid: string; // 供总评接口使用
  readonly region: string; // region.display
  readonly genres: string[]; // theme[]（元素取 name 或原值）

  constructor(id: string, title: string, cover: string, author: string, description: string,
    status: string, uuid: string, region: string, genres: string[]) {
    this.id = id;
    this.title = title;
    this.cover = cover;
    this.author = author;
    this.description = description;
    this.status = status;
    this.uuid = uuid;
    this.region = region;
    this.genres = genres;
  }

  static fromJson(raw: Object): MangaDetail {
    const m = unwrapComic(raw as Record<string, Object>);
    const genres: string[] = [];
    const theme = m['theme'];
    if (Array.isArray(theme)) {
      for (let i = 0; i < theme.length; i++) {
        const e = theme[i] as Object;
        let name = '';
        if (e !== null && e !== undefined && typeof e === 'object' && !Array.isArray(e)) {
          name = str((e as Record<string, Object>)['name']);
        } else {
          name = str(e);
        }
        if (name.length > 0) {
          genres.push(name);
        }
      }
    }
    const description = m['brief'] !== undefined && m['brief'] !== null && str(m['brief']).length > 0
      ? str(m['brief'])
      : str(m['description']);
    return new MangaDetail(
      str(m['path_word']),
      str(m['name']),
      str(m['cover']),
      authorName(m['author']),
      description,
      displayValue(m['status']),
      str(m['uuid']),
      displayValue(m['region']),
      genres
    );
  }
}

export class Comment {
  readonly id: string;
  readonly user: string; // user_name
  readonly content: string; // comment
  readonly createdAt: string; // create_at

  constructor(id: string, user: string, content: string, createdAt: string) {
    this.id = id;
    this.user = user;
    this.content = content;
    this.createdAt = createdAt;
  }

  static fromJson(raw: Object): Comment {
    const m = raw as Record<string, Object>;
    return new Comment(
      str(m['id']),
      str(m['user_name']),
      str(m['comment']),
      str(m['create_at'])
    );
  }
}

/** 数字字段兼容：数值直接取，字符串 parseInt。 */
export function toInt(v: Object | undefined | null): number {
  if (typeof v === 'number') {
    return Math.trunc(v);
  }
  if (typeof v === 'string') {
    const n = parseInt(v, 10);
    return isNaN(n) ? 0 : n;
  }
  return 0;
}

/** 从 results 提取列表：`{list: [...]}` 或直接数组。 */
export function listOfResults(results: Object | undefined | null): Object[] {
  if (results === null || results === undefined) {
    return [];
  }
  if (Array.isArray(results)) {
    return results as Object[];
  }
  const list = (results as Record<string, Object>)['list'];
  if (Array.isArray(list)) {
    return list as Object[];
  }
  return [];
}
