// xpware usage tracker — Cloudflare Worker + D1
//
//   POST /hit    {"uid": "123456", "kind": "exec" | "ping", "v": "1.16.0"}
//                exec = the script was just run, ping = still running (every 3 min)
//   GET  /stats  {"online": n, "players": n, "executions": n}
//   GET  /       small live page with the same numbers

const ONLINE_WINDOW = 6 * 60 // seen in the last 6 min = online (2 missed pings of slack)
const EXEC_COOLDOWN = 20     // re-running inside 20s counts once, so spam-executing doesn't inflate it

const json = (body, status = 200) =>
	new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
	})

async function hashId(uid, salt) {
	const data = new TextEncoder().encode(salt + ":" + uid)
	const buf = await crypto.subtle.digest("SHA-256", data)
	return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("")
}

async function readStats(db) {
	const now = Math.floor(Date.now() / 1000)
	const [totals, online] = await db.batch([
		db.prepare("SELECT k, v FROM totals"),
		db.prepare("SELECT COUNT(*) AS n FROM players WHERE last_seen > ?").bind(now - ONLINE_WINDOW),
	])
	const t = Object.fromEntries(totals.results.map((r) => [r.k, r.v]))
	return { online: online.results[0].n, players: t.players ?? 0, executions: t.executions ?? 0 }
}

async function hit(req, env) {
	let body
	try { body = await req.json() } catch { return json({ error: "bad json" }, 400) }
	const uid = String(body?.uid ?? "")
	const kind = body?.kind
	// Roblox UserIds are plain positive integers; anything else is junk
	if (!/^[1-9][0-9]{0,19}$/.test(uid) || (kind !== "exec" && kind !== "ping")) {
		return json({ error: "bad request" }, 400)
	}

	const db = env.DB
	const id = await hashId(uid, env.SALT || "")
	const now = Math.floor(Date.now() / 1000)
	const row = await db.prepare("SELECT last_exec FROM players WHERE id = ?").bind(id).first()

	if (!row) {
		// first time we've seen this player (a ping from an unknown player means the DB was
		// wiped mid-session: count them as a player but not as an execution)
		const ran = kind === "exec" ? 1 : 0
		await db.batch([
			db.prepare("INSERT OR IGNORE INTO players (id, first_seen, last_seen, last_exec, runs) VALUES (?, ?, ?, ?, ?)")
				.bind(id, now, now, now, ran),
			db.prepare("UPDATE totals SET v = v + 1 WHERE k = 'players'"),
			db.prepare("UPDATE totals SET v = v + ? WHERE k = 'executions'").bind(ran),
		])
	} else if (kind === "exec" && now - row.last_exec >= EXEC_COOLDOWN) {
		await db.batch([
			db.prepare("UPDATE players SET last_seen = ?, last_exec = ?, runs = runs + 1 WHERE id = ?").bind(now, now, id),
			db.prepare("UPDATE totals SET v = v + 1 WHERE k = 'executions'"),
		])
	} else {
		await db.prepare("UPDATE players SET last_seen = ? WHERE id = ?").bind(now, id).run()
	}

	// only execs get the numbers back (the script shows them in Settings > About);
	// pings stay a single write to keep well inside the free tier
	return kind === "exec" ? json(await readStats(db)) : json({ ok: true })
}

const PAGE = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>xpware stats</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#ece9d8;font:14px Tahoma,Verdana,sans-serif;color:#000}
.win{width:min(360px,calc(100vw - 32px));border:1px solid #0831d9;border-radius:8px 8px 0 0;background:#ece9d8;box-shadow:2px 2px 8px #0005}
.bar{padding:6px 10px;border-radius:7px 7px 0 0;color:#fff;font-weight:bold;background:linear-gradient(#0a5fd8,#0447c0 60%,#0a3faa)}
.body{padding:14px;display:grid;gap:8px}
.row{display:flex;justify-content:space-between;padding:8px 10px;background:#fff;border:1px solid #7f9db9}
.row b{font-size:18px}
small{color:#555;text-align:right}
</style>
<div class="win"><div class="bar">xpware stats</div><div class="body">
<div class="row">Online now <b id="online">…</b></div>
<div class="row">Players (all time) <b id="players">…</b></div>
<div class="row">Executions (all time) <b id="executions">…</b></div>
<small id="at"></small></div></div>
<script>
async function load(){
  try{
    const s=await (await fetch("/stats")).json()
    for(const k of ["online","players","executions"]) document.getElementById(k).textContent=s[k].toLocaleString()
    document.getElementById("at").textContent="updated "+new Date().toLocaleTimeString()
  }catch{document.getElementById("at").textContent="couldn't reach the server"}
}
load();setInterval(load,30000)
</script>`

export default {
	async fetch(req, env) {
		const { pathname } = new URL(req.url)
		try {
			if (req.method === "POST" && pathname === "/hit") return await hit(req, env)
			if (req.method === "GET" && pathname === "/stats") return json(await readStats(env.DB))
			if (req.method === "GET" && pathname === "/") return new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } })
			return json({ error: "not found" }, 404)
		} catch (e) {
			return json({ error: "server error" }, 500)
		}
	},
}
