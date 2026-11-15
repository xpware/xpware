-- xpware usage tracker: run once with
--   npx wrangler d1 execute xpware-stats --remote --file=schema.sql

CREATE TABLE IF NOT EXISTS players (
	id         TEXT PRIMARY KEY,   -- SHA-256 of the Roblox UserId + salt, never the raw id
	first_seen INTEGER NOT NULL,   -- unix seconds
	last_seen  INTEGER NOT NULL,   -- bumped by every exec and heartbeat
	last_exec  INTEGER NOT NULL,   -- for the re-run cooldown
	runs       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS players_last_seen ON players (last_seen);

-- running totals, so reading the stats is 2 rows instead of a scan of every player
CREATE TABLE IF NOT EXISTS totals (
	k TEXT PRIMARY KEY,
	v INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO totals (k, v) VALUES ('players', 0), ('executions', 0);
