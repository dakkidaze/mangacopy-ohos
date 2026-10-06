/**
 * 轻量请求节流（规格 A.4）：限制并发 + 最小间隔，避免"非人"的匀速猛打。
 * 数值保真：maxConcurrent=2、minInterval=300ms、jitter 未启用。
 */
export class ApiThrottle {
  private readonly maxConcurrent: number;
  private readonly minIntervalMs: number;
  private running: number = 0;
  private lastStart: number = 0;

  constructor(maxConcurrent: number = 2, minIntervalMs: number = 300) {
    this.maxConcurrent = maxConcurrent;
    this.minIntervalMs = minIntervalMs;
  }

  async run<T>(task: () => Promise<T>): Promise<T> {
    while (this.running >= this.maxConcurrent) {
      await delay(50);
    }
    if (this.lastStart > 0) {
      const wait = this.minIntervalMs - (Date.now() - this.lastStart);
      if (wait > 0) {
        await delay(wait);
      }
    }
    this.running++;
    try {
      return await task();
    } finally {
      this.lastStart = Date.now();
      this.running--;
    }
  }
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: (v: void) => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}
