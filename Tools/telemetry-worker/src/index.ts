export interface Env {
  DB: D1Database;
}

const RENDERERS = new Set(["dxmt", "d3dmetal", "dxvk", "wined3d"]);
const VULKAN = new Set(["moltenvk", "kosmickrisp"]);
const SYNCS = new Set(["msync", "esync", "none"]);
const ARCHS = new Set(["x86_64", "arm64"]);
const VERDICTS = new Set(["works", "stopped", "noFrames", "blackScreen"]);
const THERMALS = new Set(["nominal", "fair", "serious", "critical"]);

function validStr(v: unknown, max: number): v is string {
  return typeof v === "string" && v.length > 0 && v.length <= max;
}

function validFPS(v: unknown): number | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > 1000) return NaN;
  return Math.round(v * 10) / 10;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/v1/report") {
      const length = Number(request.headers.get("content-length") || "0");
      if (length > 2048) return new Response("payload too large", { status: 413 });

      let body: Record<string, unknown>;
      try {
        const text = await request.text();
        if (text.length > 2048) return new Response("payload too large", { status: 413 });
        body = JSON.parse(text);
      } catch {
        return new Response("invalid json", { status: 400 });
      }

      const appID = body.steamAppID;
      const ramGB = body.ramGB == null ? null : (typeof body.ramGB === "number" && Number.isInteger(body.ramGB) && body.ramGB >= 4 && body.ramGB <= 512 ? body.ramGB : NaN);
      const avgFPS = validFPS(body.avgFPS);
      const lowFPS = validFPS(body.onePercentLowFPS);
      const codes = Array.isArray(body.crashCodes) ? body.crashCodes.filter((c): c is string => validStr(c, 40)).slice(0, 8) : [];
      const thermal = body.peakThermalState == null ? null : (typeof body.peakThermalState === "string" && THERMALS.has(body.peakThermalState) ? body.peakThermalState : "invalid");

      if (
        body.schema !== 1 ||
        !validStr(body.installID, 64) ||
        typeof appID !== "number" || !Number.isInteger(appID) || appID <= 0 ||
        !validStr(body.renderer, 16) || !RENDERERS.has(body.renderer) ||
        !validStr(body.vulkanDriver, 16) || !VULKAN.has(body.vulkanDriver) ||
        !validStr(body.sync, 16) || !SYNCS.has(body.sync) ||
        !validStr(body.engineID, 80) ||
        !validStr(body.engineArch, 16) || !ARCHS.has(body.engineArch) ||
        !validStr(body.chip, 40) ||
        !validStr(body.macOS, 16) ||
        !validStr(body.verdict, 20) || !VERDICTS.has(body.verdict) ||
        !validStr(body.reportedDay, 16) ||
        Number.isNaN(ramGB) || Number.isNaN(avgFPS) || Number.isNaN(lowFPS) || thermal === "invalid"
      ) {
        return new Response("invalid report", { status: 400 });
      }

      const recipeID = validStr(body.recipeID, 80) ? body.recipeID : null;
      await env.DB.prepare(
        `INSERT INTO lab_reports (
          install_id, steam_app_id, recipe_id, renderer, vulkan_driver, sync_mode,
          engine_id, engine_arch, chip, ram_gb, macos, verdict, avg_fps, one_percent_low_fps,
          peak_thermal, crash_codes, reported_day, updated_at
        ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)
        ON CONFLICT (install_id, steam_app_id, renderer, vulkan_driver, engine_id, chip)
        DO UPDATE SET
          ram_gb = COALESCE(excluded.ram_gb, lab_reports.ram_gb),
          verdict = excluded.verdict,
          avg_fps = COALESCE(excluded.avg_fps, lab_reports.avg_fps),
          one_percent_low_fps = COALESCE(excluded.one_percent_low_fps, lab_reports.one_percent_low_fps),
          peak_thermal = excluded.peak_thermal,
          crash_codes = excluded.crash_codes,
          macos = excluded.macos,
          reported_day = excluded.reported_day,
          updated_at = excluded.updated_at`
      )
        .bind(
          body.installID, appID, recipeID, body.renderer, body.vulkanDriver, body.sync,
          body.engineID, body.engineArch, body.chip, ramGB, body.macOS, body.verdict,
          avgFPS, lowFPS, thermal, JSON.stringify(codes), body.reportedDay, Math.floor(Date.now() / 1000)
        )
        .run();

      return Response.json({ ok: true }, { status: 202 });
    }

    if (request.method === "GET" && url.pathname === "/v1/verdicts.json") {
      const { results } = await env.DB.prepare(
        `SELECT
          steam_app_id AS steamAppID,
          chip,
          ram_gb AS ramGB,
          renderer,
          vulkan_driver AS vulkanDriver,
          engine_arch AS engineArch,
          COUNT(*) AS reports,
          SUM(CASE WHEN verdict = 'works' THEN 1 ELSE 0 END) AS works,
          ROUND(AVG(avg_fps), 1) AS avgFPS,
          ROUND(AVG(one_percent_low_fps), 1) AS onePercentLowFPS
        FROM lab_reports
        GROUP BY steam_app_id, chip, ram_gb, renderer, vulkan_driver, engine_arch`
      ).all();

      return Response.json(
        { schema: 1, updatedAt: new Date().toISOString().slice(0, 10), verdicts: results },
        { headers: { "Cache-Control": "public, max-age=300" } }
      );
    }

    return new Response("not found", { status: 404 });
  },
};
