import adminHtml from "../../support_logs_admin.html";

const MAX_BODY_BYTES = 8 * 1024 * 1024;
const MAX_ADMIN_BODY_BYTES = 16 * 1024;
const MAX_LOG_CHARS = 200_000;
const MAX_ISSUE_CHARS = 2_000;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const RETENTION_SECONDS = 30 * 24 * 60 * 60;

type ReportStatus = "new" | "review" | "resolved";

type UploadPayload = {
  platform?: unknown;
  appVersion?: unknown;
  osVersion?: unknown;
  createdAt?: unknown;
  issue?: unknown;
  includeLogs?: unknown;
  logs?: unknown;
  image?: unknown;
};

type StoredImage = {
  key: string;
  fileName: string;
  mimeType: string;
  size: number;
};

type StoredReport = {
  code: string;
  platform: string;
  appVersion: string;
  osVersion: string;
  createdAt: string;
  receivedAt: string;
  updatedAt: string;
  issue: string;
  status: ReportStatus;
  logs: string;
  hasLogs: boolean;
  image?: StoredImage;
  hasImage: boolean;
  trackingTokenHash?: string;
};

type ReportSummary = Omit<StoredReport, "logs" | "trackingTokenHash" | "image">;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (request.method === "POST" && url.pathname === "/v1/feedback") {
        return await createFeedback(request, env, true);
      }
      if (request.method === "POST" && url.pathname === "/v1/logs") {
        return await createFeedback(request, env, false);
      }
      const publicMatch = url.pathname.match(/^\/v1\/feedback\/([A-Fa-f0-9]{10})$/);
      if (request.method === "GET" && publicMatch) {
        return await feedbackStatus(request, publicMatch[1], env);
      }
      if (url.pathname === "/admin" || url.pathname.startsWith("/admin/logs")) {
        if (!(await isAdmin(request, env.ADMIN_TOKEN))) return adminChallenge();
        if (url.pathname === "/admin") {
          if (request.method !== "GET") return methodNotAllowed("GET");
          return adminConsole();
        }
        if (url.pathname === "/admin/logs") {
          if (request.method !== "GET") return methodNotAllowed("GET");
          return await listReports(url, env);
        }
        const imageMatch = url.pathname.match(/^\/admin\/logs\/([A-Fa-f0-9]{10})\/image$/);
        if (imageMatch) {
          if (request.method !== "GET") return methodNotAllowed("GET");
          return await getReportImage(imageMatch[1], url, env);
        }
        const code = url.pathname.slice("/admin/logs/".length);
        if (request.method === "GET") return await getReport(code, env);
        if (request.method === "PATCH") return await updateReport(code, request, env);
        return methodNotAllowed("GET, PATCH");
      }
      if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });
      if (request.method === "GET" && url.pathname === "/v1/logs") {
        return json({ error: "method_not_allowed", message: "Submit feedback from the Interview Assistant app." }, 405, { Allow: "POST" });
      }
      return json({ error: "not_found" }, 404);
    } catch (error) {
      console.error(JSON.stringify({ event: "request_failed", message: errorMessage(error) }));
      return json({ error: "internal_error" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function createFeedback(request: Request, env: Env, requireIssue: boolean): Promise<Response> {
  const payload = await readJson<UploadPayload>(request, MAX_BODY_BYTES);
  if (payload instanceof Response) return payload;
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const rateLimit = await env.UPLOAD_RATE_LIMITER.limit({ key: ip });
  if (!rateLimit.success) return json({ error: "rate_limited" }, 429, { "Retry-After": "60" });

  const platform = shortText(payload.platform, 32);
  const appVersion = shortText(payload.appVersion, 64);
  const osVersion = shortText(payload.osVersion, 160);
  const createdAt = shortText(payload.createdAt, 64);
  const issue = redact(shortText(payload.issue, MAX_ISSUE_CHARS))
    || (requireIssue ? "" : "Diagnostic log uploaded from an earlier app version");
  const includeLogs = payload.includeLogs !== false;
  const rawLogs = includeLogs && typeof payload.logs === "string" ? payload.logs : "";
  if (!platform || !appVersion || !osVersion || !createdAt || !issue) {
    return json({ error: "missing_required_fields" }, 400);
  }

  const code = await uniqueCode(env.REPORTS);
  const trackingToken = secureToken(24);
  const now = new Date().toISOString();
  const logs = rawLogs ? redact(rawLogs.slice(-MAX_LOG_CHARS)) : "";
  const decodedImage = decodeImage(payload.image);
  if (decodedImage instanceof Response) return decodedImage;
  let image: StoredImage | undefined;
  if (decodedImage) {
    const extension = decodedImage.mimeType === "image/png" ? "png"
      : decodedImage.mimeType === "image/webp" ? "webp" : "jpg";
    const key = `feedback/${code}.${extension}`;
    await env.REPORTS.put(key, decodedImage.bytes, {
      expirationTtl: RETENTION_SECONDS,
      metadata: {
        reportCode: code,
        contentType: decodedImage.mimeType,
        fileName: decodedImage.fileName,
      },
    });
    image = {
      key,
      fileName: decodedImage.fileName,
      mimeType: decodedImage.mimeType,
      size: decodedImage.bytes.byteLength,
    };
  }
  const report: StoredReport = {
    code,
    platform,
    appVersion,
    osVersion,
    createdAt,
    receivedAt: now,
    updatedAt: now,
    issue,
    status: "new",
    logs,
    hasLogs: logs.length > 0,
    image,
    hasImage: image !== undefined,
    trackingTokenHash: await sha256Hex(trackingToken),
  };
  try {
    await putReport(env.REPORTS, report);
  } catch (error) {
    if (image) await env.REPORTS.delete(image.key);
    throw error;
  }
  console.log(JSON.stringify({ event: "feedback_created", code, platform, hasLogs: report.hasLogs, hasImage: report.hasImage, logBytes: logs.length, imageBytes: image?.size ?? 0 }));
  return json({ code, trackingToken, status: report.status, updatedAt: report.updatedAt, hasImage: report.hasImage, expiresInDays: 30 }, 201);
}

async function feedbackStatus(request: Request, rawCode: string, env: Env): Promise<Response> {
  const code = normalizeCode(rawCode);
  const suppliedToken = request.headers.get("X-Feedback-Token") ?? "";
  if (!suppliedToken) return json({ error: "tracking_token_required" }, 401);
  const raw = await env.REPORTS.get(`report:${code}`, "json");
  if (raw === null) return json({ error: "not_found" }, 404);
  const report = normalizeReport(raw, code);
  if (!report.trackingTokenHash || !(await timingSafeEqual(await sha256Hex(suppliedToken), report.trackingTokenHash))) {
    return json({ error: "not_found" }, 404);
  }
  return json({ code: report.code, issue: report.issue, status: report.status, createdAt: report.createdAt, updatedAt: report.updatedAt, hasLogs: report.hasLogs, hasImage: report.hasImage });
}

async function uniqueCode(reports: KVNamespace): Promise<string> {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const code = secureToken(5);
    if ((await reports.get(`report:${code}`)) === null) return code;
  }
  throw new Error("Could not allocate report code");
}

async function putReport(reports: KVNamespace, report: StoredReport): Promise<void> {
  await reports.put(`report:${report.code}`, JSON.stringify(report), {
    expirationTtl: RETENTION_SECONDS,
    metadata: {
      code: report.code,
      platform: report.platform,
      appVersion: report.appVersion,
      receivedAt: report.receivedAt,
      updatedAt: report.updatedAt,
      issue: report.issue.slice(0, 240),
      status: report.status,
      hasLogs: report.hasLogs,
      hasImage: report.hasImage,
    },
  });
}

async function listReports(url: URL, env: Env): Promise<Response> {
  const listed = await env.REPORTS.list({ prefix: "report:", limit: 100 });
  const q = (url.searchParams.get("q") ?? "").trim().toLowerCase().slice(0, 200);
  const requestedStatus = url.searchParams.get("status") ?? "all";
  const status = isStatus(requestedStatus) ? requestedStatus : null;
  const reports = (await Promise.all(listed.keys.map(async key => {
    const raw = await env.REPORTS.get(key.name, "json");
    return raw === null ? null : normalizeReport(raw, key.name.slice("report:".length));
  }))).filter((report): report is StoredReport => report !== null);
  const counts = {
    total: reports.length,
    new: reports.filter(report => report.status === "new").length,
    review: reports.filter(report => report.status === "review").length,
    resolved: reports.filter(report => report.status === "resolved").length,
  };
  const filtered = reports
    .filter(report => status === null || report.status === status)
    .filter(report => !q || [report.code, report.issue, report.logs, report.platform, report.appVersion]
      .some(value => value.toLowerCase().includes(q)))
    .sort((left, right) => right.receivedAt.localeCompare(left.receivedAt))
    .map(toSummary);
  return json({ reports: filtered, counts, cursor: listed.list_complete ? null : listed.cursor });
}

async function getReport(rawCode: string, env: Env): Promise<Response> {
  const code = normalizeCode(rawCode);
  if (!code) return json({ error: "invalid_code" }, 400);
  const raw = await env.REPORTS.get(`report:${code}`, "json");
  if (raw === null) return json({ error: "not_found" }, 404);
  const report = normalizeReport(raw, code);
  return json({
    ...report,
    trackingTokenHash: undefined,
    image: report.image ? {
      fileName: report.image.fileName,
      mimeType: report.image.mimeType,
      size: report.image.size,
      url: `/admin/logs/${report.code}/image`,
    } : undefined,
  });
}

async function getReportImage(rawCode: string, url: URL, env: Env): Promise<Response> {
  const code = normalizeCode(rawCode);
  const raw = await env.REPORTS.get(`report:${code}`, "json");
  if (raw === null) return json({ error: "not_found" }, 404);
  const report = normalizeReport(raw, code);
  if (!report.image) return json({ error: "image_not_found" }, 404);
  const body = await env.REPORTS.get(report.image.key, "stream");
  if (body === null) return json({ error: "image_not_found" }, 404);
  const headers = new Headers({
    "Cache-Control": "private, no-store",
    "X-Content-Type-Options": "nosniff",
  });
  headers.set("Content-Type", report.image.mimeType);
  headers.set(
    "Content-Disposition",
    `${url.searchParams.get("download") === "1" ? "attachment" : "inline"}; filename="${report.image.fileName}"`
  );
  return new Response(body, { headers });
}

async function updateReport(rawCode: string, request: Request, env: Env): Promise<Response> {
  const code = normalizeCode(rawCode);
  if (!code) return json({ error: "invalid_code" }, 400);
  const payload = await readJson<{ status?: unknown }>(request, MAX_ADMIN_BODY_BYTES);
  if (payload instanceof Response) return payload;
  if (!isStatus(payload.status)) return json({ error: "invalid_status" }, 400);
  const raw = await env.REPORTS.get(`report:${code}`, "json");
  if (raw === null) return json({ error: "not_found" }, 404);
  const report = normalizeReport(raw, code);
  report.status = payload.status;
  report.updatedAt = new Date().toISOString();
  await putReport(env.REPORTS, report);
  console.log(JSON.stringify({ event: "feedback_status_updated", code, status: report.status }));
  return json(toSummary(report));
}

function normalizeReport(value: unknown, fallbackCode: string): StoredReport {
  const item = typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  const receivedAt = shortText(item.receivedAt, 64) || new Date(0).toISOString();
  const logs = typeof item.logs === "string" ? item.logs : "";
  const rawImage = typeof item.image === "object" && item.image !== null
    ? item.image as Record<string, unknown> : null;
  const imageKey = shortText(rawImage?.key, 300);
  const imageMimeType = shortText(rawImage?.mimeType, 80);
  const image = imageKey && isImageMimeType(imageMimeType) ? {
    key: imageKey,
    fileName: safeFileName(shortText(rawImage?.fileName, 160) || `${fallbackCode}.jpg`),
    mimeType: imageMimeType,
    size: typeof rawImage?.size === "number" && Number.isFinite(rawImage.size) ? rawImage.size : 0,
  } : undefined;
  return {
    code: normalizeCode(item.code) || fallbackCode,
    platform: shortText(item.platform, 32) || "Unknown",
    appVersion: shortText(item.appVersion, 64) || "Unknown",
    osVersion: shortText(item.osVersion, 160) || "Unknown",
    createdAt: shortText(item.createdAt, 64) || receivedAt,
    receivedAt,
    updatedAt: shortText(item.updatedAt, 64) || receivedAt,
    issue: shortText(item.issue, MAX_ISSUE_CHARS) || "Diagnostic log upload",
    status: isStatus(item.status) ? item.status : "new",
    logs,
    hasLogs: typeof item.hasLogs === "boolean" ? item.hasLogs : logs.length > 0,
    image,
    hasImage: image !== undefined,
    trackingTokenHash: shortText(item.trackingTokenHash, 128) || undefined,
  };
}

function toSummary(report: StoredReport): ReportSummary {
  const { logs: _logs, trackingTokenHash: _trackingTokenHash, image: _image, ...summary } = report;
  return summary;
}

function decodeImage(value: unknown): { bytes: Uint8Array; fileName: string; mimeType: string } | Response | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object") return json({ error: "invalid_image" }, 400);
  const item = value as Record<string, unknown>;
  const mimeType = shortText(item.mimeType, 80).toLowerCase();
  const base64 = typeof item.base64 === "string" ? item.base64 : "";
  if (!isImageMimeType(mimeType) || !base64) return json({ error: "invalid_image" }, 400);
  if (base64.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4 + 8) return json({ error: "image_too_large" }, 413);
  try {
    const binary = atob(base64);
    if (binary.length < 1 || binary.length > MAX_IMAGE_BYTES) return json({ error: "image_too_large" }, 413);
    const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
    return {
      bytes,
      fileName: safeFileName(shortText(item.fileName, 160) || "feedback-image.jpg"),
      mimeType,
    };
  } catch {
    return json({ error: "invalid_image_encoding" }, 400);
  }
}

function isImageMimeType(value: string): boolean {
  return value === "image/jpeg" || value === "image/png" || value === "image/webp";
}

function safeFileName(value: string): string {
  const cleaned = value.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 120);
  return cleaned || "feedback-image.jpg";
}

async function readJson<T>(request: Request, maximumBytes: number): Promise<T | Response> {
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    return json({ error: "content_type_must_be_json" }, 415);
  }
  const contentLength = Number(request.headers.get("content-length"));
  if (!Number.isFinite(contentLength) || contentLength < 1) return json({ error: "content_length_required" }, 411);
  if (contentLength > maximumBytes) return json({ error: "report_too_large" }, 413);
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength > maximumBytes) return json({ error: "report_too_large" }, 413);
  try {
    return JSON.parse(new TextDecoder().decode(bytes)) as T;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
}

async function isAdmin(request: Request, expected: string | undefined): Promise<boolean> {
  if (!expected) return false;
  const authorization = request.headers.get("authorization") ?? "";
  let supplied = "";
  if (authorization.startsWith("Bearer ")) supplied = authorization.slice(7);
  else if (authorization.startsWith("Basic ")) {
    try {
      const decoded = atob(authorization.slice(6));
      supplied = decoded.slice(decoded.indexOf(":") + 1);
    } catch {
      return false;
    }
  }
  return await timingSafeEqual(supplied, expected);
}

async function timingSafeEqual(left: string, right: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  return leftBytes.byteLength === rightBytes.byteLength
    && crypto.subtle.timingSafeEqual(leftBytes, rightBytes);
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

function secureToken(byteCount: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteCount));
  return Array.from(bytes, value => value.toString(16).padStart(2, "0")).join("").toUpperCase();
}

function redact(value: string): string {
  return value
    .replace(/(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,;]+/gi, "$1<redacted>")
    .replace(/((?:api[-_ ]?key|access[-_ ]?token|secret|password)\s*[:=]\s*)[^\s,;]+/gi, "$1<redacted>")
    .replace(/\bsk-[A-Za-z0-9_-]{12,}\b/g, "<redacted-api-key>")
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "<redacted-email>")
    .replace(/(?:\/Users\/|[A-Z]:\\Users\\)[^/\\\s]+/gi, match => match.replace(/[^/\\]+$/, "<user>"));
}

function shortText(value: unknown, maximum: number): string {
  return typeof value === "string" ? value.trim().slice(0, maximum) : "";
}

function normalizeCode(value: unknown): string {
  const code = typeof value === "string" ? value.trim().toUpperCase() : "";
  return /^[A-F0-9]{10}$/.test(code) ? code : "";
}

function isStatus(value: unknown): value is ReportStatus {
  return value === "new" || value === "review" || value === "resolved";
}

function adminConsole(): Response {
  return new Response(adminHtml, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "Cache-Control": "no-store",
    },
  });
}

function adminChallenge(): Response {
  return new Response("Authentication required", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="Interview Assistant Support", charset="UTF-8"' },
  });
}

function json(value: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return Response.json(value, { status, headers: { "Cache-Control": "no-store", ...extraHeaders } });
}

function methodNotAllowed(allow: string): Response {
  return json({ error: "method_not_allowed" }, 405, { Allow: allow });
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
