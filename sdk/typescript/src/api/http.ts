/**
 * Minimal JSON-over-HTTP client for the backend REST API.
 *
 * Domain-specific endpoints should be built on top of `ApiClient.get` /
 * `ApiClient.post` in their own modules.
 */

export type QueryParams = Record<string, string | number | boolean | undefined>;

export interface ApiClientOptions {
  /** Base URL of the API, e.g. `http://localhost:4000/api/v1`. */
  baseUrl: string;
  /** Extra headers sent with every request. */
  headers?: Record<string, string>;
  /** Custom fetch implementation (defaults to the global `fetch`). */
  fetch?: typeof fetch;
}

/** Thrown when the server responds with a non-2xx status. */
export class ApiError extends Error {
  readonly status: number;
  readonly body: unknown;

  constructor(status: number, body: unknown) {
    super(`API request failed with status ${status}`);
    this.name = "ApiError";
    this.status = status;
    this.body = body;
  }
}

export class ApiClient {
  private readonly baseUrl: string;
  private readonly headers: Record<string, string>;
  private readonly fetchFn: typeof fetch;

  constructor(options: ApiClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, "");
    this.headers = options.headers ?? {};
    this.fetchFn = options.fetch ?? fetch;
  }

  async get<T>(path: string, query?: QueryParams): Promise<T> {
    return this.request<T>("GET", path, { query });
  }

  async post<T>(path: string, body?: unknown, query?: QueryParams): Promise<T> {
    return this.request<T>("POST", path, { query, body });
  }

  private async request<T>(
    method: string,
    path: string,
    options: { query?: QueryParams; body?: unknown } = {},
  ): Promise<T> {
    const url = this.buildUrl(path, options.query);

    const response = await this.fetchFn(url, {
      method,
      headers: {
        Accept: "application/json",
        ...(options.body !== undefined && { "Content-Type": "application/json" }),
        ...this.headers,
      },
      ...(options.body !== undefined && { body: JSON.stringify(options.body) }),
    });

    const responseBody: unknown = await response.json().catch(() => undefined);

    if (!response.ok) {
      throw new ApiError(response.status, responseBody);
    }

    return responseBody as T;
  }

  private buildUrl(path: string, query?: QueryParams): string {
    const url = new URL(`${this.baseUrl}/${path.replace(/^\/+/, "")}`);
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value !== undefined) {
        url.searchParams.set(key, String(value));
      }
    }
    return url.toString();
  }
}
