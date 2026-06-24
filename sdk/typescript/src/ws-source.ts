const RECONNECT_INITIAL_MS = 1_000;
const RECONNECT_MAX_MS = 30_000;

export interface WsSourceOptions {
  /** How long the first call waits for a frame (default 5000ms). */
  firstFrameTimeoutMs?: number;
  /**
   * Close the socket after this long without a call (default 30000ms), so an
   * idle source never keeps the process alive; the next call reconnects
   * transparently. `0` closes right after each call, `Infinity` keeps the
   * stream open until `close()`.
   */
  idleTimeoutMs?: number;
}

/**
 * Shared WebSocket infrastructure for snapshot sources.
 *
 * Handles lazy connection, exponential-backoff reconnection, idle teardown, and
 * first-frame waiting. Subclasses supply three hooks:
 * - {@link name} — label used in error messages
 * - {@link applyFrame} — parse a raw string frame and update the internal snapshot
 * - {@link copySnapshot} — return a caller-safe copy of the current snapshot
 */
export abstract class WsSource<T> {
  private readonly url: string;
  private ws?: WebSocket;
  private closed = false;
  private reconnectAttempts = 0;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private idleTimer?: ReturnType<typeof setTimeout>;

  private hasFrame = false;
  private frameWaiters: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];

  protected readonly firstFrameTimeoutMs: number;
  protected readonly idleTimeoutMs: number;

  protected abstract get name(): string;
  protected abstract applyFrame(data: string): void;
  protected abstract copySnapshot(): T;

  constructor(url: string, options: WsSourceOptions) {
    this.url = url;
    this.firstFrameTimeoutMs = options.firstFrameTimeoutMs ?? 5_000;
    this.idleTimeoutMs = options.idleTimeoutMs ?? 30_000;
  }

  protected async getSnapshot(): Promise<T> {
    if (this.closed) {
      throw new Error(`${this.name} source is closed`);
    }
    try {
      this.connect();
      if (!this.hasFrame) {
        await this.waitForFirstFrame();
      }
      return this.copySnapshot();
    } finally {
      this.armIdleTimer();
    }
  }

  close(): void {
    this.closed = true;
    this.clearTimer("reconnectTimer");
    this.clearTimer("idleTimer");
    this.ws?.close();
    this.ws = undefined;
    this.failWaiters(new Error(`${this.name} source closed while waiting for the first frame`));
  }

  private connect(): void {
    if (this.ws || this.reconnectTimer || this.closed) return;
    if (typeof WebSocket === "undefined") {
      throw new Error("no global WebSocket available (Node >= 22 or a browser is required)");
    }

    const ws = new WebSocket(this.url);
    this.ws = ws;

    ws.addEventListener("open", () => {
      this.reconnectAttempts = 0;
    });
    ws.addEventListener("message", (event) => {
      this.handleFrame(event.data);
    });
    ws.addEventListener("error", () => {
      // The paired "close" event drives reconnection.
    });
    ws.addEventListener("close", () => {
      if (this.ws !== ws) return;
      this.ws = undefined;
      this.scheduleReconnect();
    });
  }

  private scheduleReconnect(): void {
    if (this.closed || this.reconnectTimer) return;
    const delay = Math.min(RECONNECT_INITIAL_MS * 2 ** this.reconnectAttempts, RECONNECT_MAX_MS);
    this.reconnectAttempts += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      this.connect();
    }, delay);
    unrefTimer(this.reconnectTimer);
  }

  /** (Re)start the idle countdown; unref'd so it never pins the process. */
  private armIdleTimer(): void {
    this.clearTimer("idleTimer");
    if (this.closed || !Number.isFinite(this.idleTimeoutMs)) return;
    this.idleTimer = setTimeout(() => {
      this.idleTimer = undefined;
      this.idleClose();
    }, this.idleTimeoutMs);
    unrefTimer(this.idleTimer);
  }

  /**
   * Idle teardown: drop the socket (and any reconnection backoff) until the
   * next call. `hasFrame` resets so the next call waits for a fresh frame
   * instead of serving a stale snapshot.
   */
  private idleClose(): void {
    if (this.frameWaiters.length > 0) {
      this.armIdleTimer();
      return;
    }
    this.clearTimer("reconnectTimer");
    this.reconnectAttempts = 0;
    const ws = this.ws;
    this.ws = undefined; // cleared first so the close handler doesn't reconnect
    ws?.close();
    this.hasFrame = false;
  }

  private clearTimer(name: "reconnectTimer" | "idleTimer"): void {
    if (this[name] !== undefined) {
      clearTimeout(this[name]);
      this[name] = undefined;
    }
  }

  private handleFrame(data: unknown): void {
    if (typeof data !== "string") return;
    try {
      this.applyFrame(data);
    } catch {
      return; // skip undecodable frames
    }
    this.hasFrame = true;
    const waiters = this.frameWaiters;
    this.frameWaiters = [];
    for (const waiter of waiters) waiter.resolve();
  }

  private async waitForFirstFrame(): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.frameWaiters = this.frameWaiters.filter((w) => w !== waiter);
        reject(new Error(`no ${this.name} frame received within ${this.firstFrameTimeoutMs}ms`));
      }, this.firstFrameTimeoutMs);
      const waiter = {
        resolve: () => {
          clearTimeout(timer);
          resolve();
        },
        reject: (error: Error) => {
          clearTimeout(timer);
          reject(error);
        },
      };
      this.frameWaiters.push(waiter);
    });
  }

  private failWaiters(error: Error): void {
    const waiters = this.frameWaiters;
    this.frameWaiters = [];
    for (const waiter of waiters) waiter.reject(error);
  }
}

// In Node, unref'd timers don't keep the event loop (and thus the process)
// alive; browsers have no such concept, so the call is a no-op there.
function unrefTimer(timer: ReturnType<typeof setTimeout>): void {
  (timer as { unref?: () => void }).unref?.();
}
