// Harbor shutdown D: push local-only Watchlist entries to the Stremio
// library, so the desktop Harbor and Stremio see them once harbor.site is gone.
//
// lib/watchlist.ts syncWithStremio already writes a bookmark whenever a title is added with a
// Stremio sign-in. Three things leave an entry only in `harbor.watchlist.v1.<profile>`:
//   - added while the profile had no Stremio sign-in,
//   - the bookmark write failed (swallowed with a console.warn),
//   - an id cloudWriteId could not map yet (a tmdb id whose tt id was unknown).
// This pass reads the library once, writes the missing bookmarks through upstream's own
// saveStremioBookmark and checks each one landed. It is idempotent (a per-profile record of the
// ids Stremio is known to hold makes a repeat run a no-op without a request), never removes or
// changes anything else in Stremio, and never overrides a removal made elsewhere.
//
// Which store and which account: lib/watchlist.ts reads the store of the profile that owns the
// Stremio sign-in (`shareStremioWith` resolved), and readActiveStremioAuthKey is that same
// profile's key, so a profile that shares another's Stremio pushes that profile's entries to
// that one account, as the desktop does.
import { readLocalEntries, type LocalEntry } from "@/lib/watchlist";
import { cloudWriteId, invalidateLibraryCache, library, libraryGetOneStrict, saveStremioBookmark, type LibraryItem } from "@/lib/stremio";
import { refreshWatchlist } from "./cards";

const PROFILES_KEY = "harbor.profiles.v1";
const AUTH_PREFIX = "harbor.auth.";
/** Per-profile record; the prefix is in profilesRoom.PROFILE_KEY_PREFIXES so a deleted profile takes it along. */
export const PUSHED_PREFIX = "harbor.watchlist.stremioPush.v1.";

/** Entries written per run; a longer list finishes on the next trigger. */
const MAX_PUSH_PER_RUN = 100;
/** Foreground / profile triggers re-check at most this often; launch and sign-in always run. */
const RECHECK_MS = 10 * 60_000;
const RETRY_MS = 60_000;
const MAX_RETRIES = 3;

export type PushReason = "launch" | "signin" | "foreground" | "profile" | "retry";

export type PushResult = {
  status: "no-session" | "up-to-date" | "busy" | "throttled" | "done" | "partial" | "error";
  reason: PushReason;
  /** Written to Stremio by this run. */
  pushed: number;
  /** Already live in Stremio (nothing written). */
  present: number;
  /** Ids cloudWriteId cannot map; they stay local. */
  unmapped: number;
  /** Removed in Stremio after the entry was added here; left removed. */
  removedElsewhere: number;
  /** A write or its check failed; retried on a later trigger. */
  failed: number;
  /** Left for the next run (per-run cap). */
  remaining: number;
};

type Record_ = { user: string; ids: string[]; at: number };
type Blob = { activeId?: string | null; profiles?: Array<{ id?: string; shareStremioWith?: string | null }> };

function sourceProfileId(): string {
  try {
    const raw = localStorage.getItem(PROFILES_KEY);
    const blob = raw ? (JSON.parse(raw) as Blob) : null;
    const profiles = Array.isArray(blob?.profiles) ? blob!.profiles! : [];
    const active = profiles.find((p) => p.id === blob?.activeId) ?? null;
    if (!active?.id) return "";
    const shared = active.shareStremioWith;
    return shared && profiles.some((p) => p.id === shared) ? shared : active.id;
  } catch {
    return "";
  }
}

function session(profileId: string): { authKey: string; user: string } | null {
  try {
    const raw = localStorage.getItem(AUTH_PREFIX + profileId);
    const s = raw ? (JSON.parse(raw) as { authKey?: unknown; user?: { _id?: unknown; email?: unknown } }) : null;
    if (!s || typeof s.authKey !== "string" || !s.authKey || !s.user) return null;
    const user = typeof s.user._id === "string" && s.user._id ? s.user._id : typeof s.user.email === "string" ? s.user.email : "";
    return user ? { authKey: s.authKey, user } : null;
  } catch {
    return null;
  }
}

function readRecord(profileId: string, user: string): Set<string> {
  try {
    const raw = localStorage.getItem(PUSHED_PREFIX + profileId);
    const r = raw ? (JSON.parse(raw) as Partial<Record_>) : null;
    // A different Stremio account starts over: its library knows none of these.
    if (!r || r.user !== user || !Array.isArray(r.ids)) return new Set();
    return new Set(r.ids.filter((v): v is string => typeof v === "string"));
  } catch {
    return new Set();
  }
}

function writeRecord(profileId: string, user: string, ids: Set<string>, entries: LocalEntry[]): void {
  // Keep only ids that still have a local entry, so the record cannot grow without bound.
  const live = new Set(entries.map((e) => e.id));
  const keep = Array.from(ids).filter((id) => live.has(id));
  try {
    localStorage.setItem(PUSHED_PREFIX + profileId, JSON.stringify({ user, ids: keep, at: Date.now() } satisfies Record_));
  } catch { /* storage full: the next run re-checks */ }
}

/** The id lib/watchlist.ts syncWithStremio writes for this entry (same arguments), or null. */
function writeIdFor(e: LocalEntry): string | null {
  return cloudWriteId(e.id, e.imdbId ?? null, !!e.imdbId);
}

const isLive = (i: LibraryItem | undefined): boolean => !!i && !i.removed && !i.temp;

let running = false;
let lastCheckAt = 0;
let retries = 0;
let retryTimer: ReturnType<typeof setTimeout> | null = null;

function scheduleRetry(): void {
  if (retryTimer != null || retries >= MAX_RETRIES) return;
  retries += 1;
  retryTimer = setTimeout(() => {
    retryTimer = null;
    void run("retry");
  }, RETRY_MS);
}

const EMPTY = { pushed: 0, present: 0, unmapped: 0, removedElsewhere: 0, failed: 0, remaining: 0 };

/**
 * One pass for the active profile. `launch` and `signin` always look; `foreground`, `profile`
 * and `retry` are skipped when they ran less than ten minutes ago. Never throws.
 */
export async function run(reason: PushReason = "launch"): Promise<PushResult> {
  const out = (status: PushResult["status"], extra: Partial<PushResult> = {}): PushResult => ({ status, reason, ...EMPTY, ...extra });
  if (running) return out("busy");
  const pid = sourceProfileId();
  const sess = pid ? session(pid) : null;
  if (!pid || !sess) return out("no-session");
  const entries = readLocalEntries();
  const known = readRecord(pid, sess.user);
  const pending: Array<{ entry: LocalEntry; writeId: string }> = [];
  let unmapped = 0;
  for (const e of entries) {
    const writeId = writeIdFor(e);
    if (!writeId) { unmapped++; continue; }
    if (!known.has(e.id)) pending.push({ entry: e, writeId });
  }
  if (!pending.length) {
    if (unmapped) console.log(`[watchlist-push] ${reason}: nothing to push, ${unmapped} local-only entr${unmapped === 1 ? "y" : "ies"} cannot be mapped to a Stremio id`);
    return out("up-to-date", { unmapped });
  }
  const forced = reason === "launch" || reason === "signin";
  if (!forced && Date.now() - lastCheckAt < RECHECK_MS) return out("throttled", { unmapped });

  running = true;
  lastCheckAt = Date.now();
  try {
    let items: LibraryItem[];
    try {
      items = await library(sess.authKey);
    } catch (e) {
      console.warn(`[watchlist-push] ${reason}: library read failed`, e);
      scheduleRetry();
      return out("error", { unmapped, failed: pending.length });
    }
    const byId = new Map(items.map((i) => [i._id, i]));
    let pushed = 0, present = 0, removedElsewhere = 0, failed = 0, remaining = 0;
    for (const { entry, writeId } of pending) {
      const cloud = byId.get(writeId);
      if (isLive(cloud)) { known.add(entry.id); present++; continue; }
      // Removed in Stremio after this entry was added here: that was a decision, not a gap.
      // An entry with no add time (legacy bare ids) is never allowed to undo a removal.
      if (cloud?.removed && (!entry.addedAt || Date.parse(cloud._mtime) >= entry.addedAt)) {
        known.add(entry.id);
        removedElsewhere++;
        continue;
      }
      if (pushed + failed >= MAX_PUSH_PER_RUN) { remaining++; continue; }
      try {
        await saveStremioBookmark(sess.authKey, writeId, { type: entry.type, name: entry.name, poster: entry.poster });
        // saveStremioBookmark returns quietly when it cannot read the item first, so look again.
        const after = await libraryGetOneStrict(sess.authKey, writeId);
        if (isLive(after ?? undefined)) { known.add(entry.id); pushed++; }
        else failed++;
      } catch (e) {
        failed++;
        console.warn(`[watchlist-push] ${reason}: write failed for ${writeId}`, e);
      }
    }
    writeRecord(pid, sess.user, known, entries);
    if (pushed) {
      invalidateLibraryCache();
      // Badges and the Library tab read the aggregate; fold the new bookmarks in at once.
      await refreshWatchlist(sess.authKey).catch(() => 0);
    }
    const status: PushResult["status"] = failed || remaining ? "partial" : "done";
    if (failed || remaining) {
      if (failed) scheduleRetry();
    } else {
      retries = 0;
    }
    console.log(`[watchlist-push] ${reason}: ${pushed} pushed, ${present} already in Stremio, ${removedElsewhere} removed elsewhere (left alone), ${unmapped} unmappable (stay local), ${failed} failed, ${remaining} left for next run`);
    return out(status, { pushed, present, unmapped, removedElsewhere, failed, remaining });
  } finally {
    running = false;
  }
}

/**
 * Swift's setStremioSession writes `harbor.auth.<profile>` through runtime.syncStorage: a new
 * session for the profile that owns the active Stremio sign-in starts a forced pass.
 */
export function storageSynced(key: string, value: string | null): void {
  if (!value || !key.startsWith(AUTH_PREFIX)) return;
  const pid = key.slice(AUTH_PREFIX.length);
  setTimeout(() => {
    // Only the profile whose store this pass reads; another profile's sign-in is picked up when it is active.
    if (pid === sourceProfileId()) void run("signin");
  }, 0);
}

/** Test hook: forget timers and throttle state. */
export function resetForTests(): void {
  if (retryTimer != null) clearTimeout(retryTimer);
  retryTimer = null;
  running = false;
  lastCheckAt = 0;
  retries = 0;
}

// Triggers that need no Swift: coming back to the foreground and a profile change. (Launch is a
// call from Swift's boot; sign-in is wired in entry.ts onto the `harbor.auth.<id>` write.)
if (typeof window !== "undefined") {
  window.addEventListener("harbor:active-profile-changed", () => { void run("profile"); });
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") void run("foreground"); });
}
