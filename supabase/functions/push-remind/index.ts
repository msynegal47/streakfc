// Streak reminders. Called every 15 min by pg_cron. Sends at most one push per subscription per local day,
// only after its reminder time, only before 9 PM local, and only if the kid (or a parent's kid) hasn't trained today.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
let CFG: { vapid_public: string; vapid_private: string; cron_key: string } | null = null;   // keys live in Supabase Vault (sfc_push_config, service role only)

function local(tz: string) {
  const f = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  const p = Object.fromEntries(f.formatToParts(new Date()).map((x) => [x.type, x.value]));
  const d = new Date(Date.UTC(+p.year, +p.month - 1, +p.day) - 864e5).toISOString().slice(0, 10);
  return { date: `${p.year}-${p.month}-${p.day}`, hm: `${p.hour}:${p.minute}`, yday: d };
}
const names = (a: string[]) => a.length <= 2 ? a.join(" and ") : a.slice(0, -1).join(", ") + " and " + a[a.length - 1];

Deno.serve(async (req) => {
  if (!CFG) { const { data, error } = await sb.rpc("sfc_push_config"); if (error || !data) return new Response("config", { status: 500 }); CFG = data; webpush.setVapidDetails("mailto:hello@streakfc.app", CFG!.vapid_public, CFG!.vapid_private); }
  const key = req.headers.get("x-cron-key") || "";
  if (!key || key !== CFG!.cron_key) return new Response("no", { status: 401 });
  const url = new URL(req.url), dry = url.searchParams.get("dry") === "1", force = url.searchParams.get("force") || "";
  const { data: subs, error } = await sb.from("sfc_push_subs").select("*");
  if (error) return new Response(error.message, { status: 500 });
  const out: unknown[] = [];
  for (const s of subs || []) {
    const L = local(s.tz || "America/Phoenix"), at = String(s.remind_at).slice(0, 5);
    const isForced = force && (force === s.id || force === s.endpoint);
    if (!isForced) {
      if (s.last_sent === L.date) continue;
      if (L.hm < at || L.hm >= "21:00") continue;
    }
    let msg: { title: string; body: string } | null = null;
    if (s.kind === "kid" && s.player_id) {
      const { data: p } = await sb.from("sfc_players").select("nickname,streak,last_log,archived").eq("id", s.player_id).single();
      if (!p || p.archived) continue;
      if (p.last_log === L.date && !isForced) { await sb.from("sfc_push_subs").update({ last_sent: L.date }).eq("id", s.id); continue; }
      const st = p.last_log === L.yday ? (p.streak || 0) : 0;   // stored streak is stale if they missed yesterday
      msg = st >= 2 ? { title: `🔥 Day ${st + 1} is on the line`, body: `${p.nickname}, your ${st}-day streak ends at midnight. 10 minutes of touches keeps it alive.` }
                    : { title: "⚽ Get your touches in today", body: `${p.nickname}, a quick 10-minute session starts your streak.` };
    } else if (s.kind === "parent" || s.kind === "kid") {   // parent, or a kid device shared by siblings
      const { data: ps } = await sb.from("sfc_players").select("nickname,last_log,streak").eq("family_id", s.family_id).eq("archived", false);
      const left = (ps || []).filter((p) => p.last_log !== L.date).map((p) => ({ ...p, streak: p.last_log === L.yday ? (p.streak || 0) : 0 }));
      if (!left.length && !isForced) { await sb.from("sfc_push_subs").update({ last_sent: L.date }).eq("id", s.id); continue; }
      const top = left.sort((a, b) => (b.streak || 0) - (a.streak || 0))[0];
      msg = s.kind === "kid" ? { title: `🔥 ${names(left.map((p) => p.nickname))}: touches time`, body: top && (top.streak || 0) >= 2 ? `${top.nickname}'s ${top.streak}-day streak ends at midnight. 10 minutes keeps it alive.` : "A quick 10-minute session keeps your streak going." } :
            { title: `⏰ ${names(left.map((p) => p.nickname))} ${left.length === 1 ? "hasn't" : "haven't"} trained today`,
              body: top && (top.streak || 0) >= 2 ? `${top.nickname}'s ${top.streak}-day streak resets at midnight. 10-20 min keeps it alive.` : "Streaks reset at midnight. 10-20 min keeps them alive." };
    }
    if (!msg) continue;
    if (dry) { out.push({ id: s.id, kind: s.kind, msg }); continue; }
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify({ ...msg, url: "/", tag: "streak-" + L.date }), { TTL: 3600 * 4 });
      await sb.from("sfc_push_subs").update({ last_sent: L.date }).eq("id", s.id);
      out.push({ id: s.id, sent: true });
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await sb.from("sfc_push_subs").delete().eq("id", s.id);
      out.push({ id: s.id, error: code || String(e) });
    }
  }
  return new Response(JSON.stringify({ n: out.length, out }), { headers: { "content-type": "application/json" } });
});
