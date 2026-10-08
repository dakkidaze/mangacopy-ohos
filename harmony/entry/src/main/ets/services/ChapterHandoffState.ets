export class ChapterHandoffState {
  private serial: number = 0;
  private currentId: number = 0;
  private startedAt: number = 0;
  private lastGesture: string = '';
  private seen: string[] = [];
  private active: boolean = false;
  private mounted: boolean = false;

  setMounted(value: boolean): void {
    this.mounted = value;
    if (!value) {
      this.invalidate();
    }
  }

  setActive(value: boolean): void {
    this.active = value;
    if (!value) {
      this.invalidate();
    }
  }

  invalidate(): void {
    this.serial++;
    this.currentId = 0;
    this.startedAt = 0;
  }

  expire(now: number): boolean {
    if (this.currentId > 0 && now - this.startedAt >= 15000) {
      this.invalidate();
      return true;
    }
    return false;
  }

  begin(gestureId: string, now: number): number {
    this.expire(now);
    if (!this.mounted || !this.active || gestureId.length === 0 || this.seen.indexOf(gestureId) >= 0) {
      return 0;
    }
    this.serial++;
    this.currentId = this.serial;
    this.startedAt = now;
    this.lastGesture = gestureId;
    this.seen.push(gestureId);
    if (this.seen.length > 64) {
      this.seen.shift();
    }
    return this.currentId;
  }

  owns(id: number): boolean {
    return this.mounted && this.active && id > 0 && this.currentId === id;
  }

  finish(id: number): void {
    if (this.currentId === id) {
      this.currentId = 0;
      this.startedAt = 0;
    }
  }

  hasRequest(): boolean {
    return this.currentId > 0;
  }
}
