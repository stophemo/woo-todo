import { LIMITS } from "./protocol.ts";

export interface ErrorDetails {
  [key: string]: unknown;
}

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details?: ErrorDetails;

  constructor(
    status: number,
    code: string,
    message: string,
    details?: ErrorDetails,
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

const BASE_HEADERS: Record<string, string> = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
  "x-content-type-options": "nosniff",
};

export function jsonResponse(
  data: unknown,
  requestId: string,
  status = 200,
): Response {
  return new Response(JSON.stringify({ ok: true, data, requestId }), {
    status,
    headers: { ...BASE_HEADERS, "x-request-id": requestId },
  });
}

export function errorResponse(error: ApiError, requestId: string): Response {
  return new Response(
    JSON.stringify({
      ok: false,
      error: {
        code: error.code,
        message: error.message,
        ...(error.details ? { details: error.details } : {}),
      },
      requestId,
    }),
    {
      status: error.status,
      headers: { ...BASE_HEADERS, "x-request-id": requestId },
    },
  );
}

export async function readJsonBody(request: Request): Promise<unknown> {
  const contentType = request.headers.get("content-type")
    ?.split(";", 1)[0]
    .trim()
    .toLowerCase() ?? "";
  if (contentType !== "application/json" && !contentType.endsWith("+json")) {
    throw new ApiError(
      415,
      "UNSUPPORTED_MEDIA_TYPE",
      "请求体必须使用 application/json",
    );
  }

  const declaredLength = Number(request.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > LIMITS.requestBytes) {
    throw new ApiError(
      413,
      "REQUEST_TOO_LARGE",
      `请求体不得超过 ${LIMITS.requestBytes} 字节`,
    );
  }
  if (!request.body) {
    throw new ApiError(400, "INVALID_JSON", "请求体不能为空");
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    size += value.byteLength;
    if (size > LIMITS.requestBytes) {
      await reader.cancel().catch(() => undefined);
      throw new ApiError(
        413,
        "REQUEST_TOO_LARGE",
        `请求体不得超过 ${LIMITS.requestBytes} 字节`,
      );
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  let source: string;
  try {
    source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new ApiError(400, "INVALID_JSON", "请求体不是有效的 UTF-8 文本");
  }

  try {
    return JSON.parse(source) as unknown;
  } catch {
    throw new ApiError(400, "INVALID_JSON", "请求体不是有效的 JSON");
  }
}
