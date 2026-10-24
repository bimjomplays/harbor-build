// Trakt, MAL and AniList traded their OAuth codes and refresh tokens through
// Harbor's token proxies, which are gone. A direct exchange needs the tracker app's client secret, and secrets
// never go into this public repo, so there is no way to sign in or to refresh a token from the TV. Upstream's
// refresh then called setSession(null), so the first expired token signed the tracker out for good.
// bundle-config.mjs patches trakt/client.ts, mal/auth.ts and mal/validate.ts to keep the session and route every
// refresh through `guardRefresh`: it marks the service "reconnect needed" and makes no request at all (the
// stored tokens stay, and work until the tracker itself rejects them). Sign-in asks `signInBlocked` first and
// always gets the "unavailable" line, so the panels never show a code that can never be approved.

export type TokenService = "trakt" | "mal" | "anilist";

const LABEL: Record<TokenService, string> = { trakt: "Trakt", mal: "MyAnimeList", anilist: "AniList" };

const reconnect = new Set<TokenService>();

export function reconnectNeeded(service: TokenService): boolean {
  return reconnect.has(service);
}

/** A new session came in (a sign-in that worked): the flag goes. */
export function clearReconnect(service: TokenService): void {
  reconnect.delete(service);
}

/** Replaces upstream's refreshAccessToken: the token proxy it called is gone, so it is never called. The
 *  caller gets null ("no new session"), which the patched callers read as "keep the old one". */
export function guardRefresh<T>(service: TokenService, _upstream: () => Promise<T | null>): () => Promise<T | null> {
  return async () => {
    reconnect.add(service);
    return null;
  };
}

/** The line the sign-in panel shows; sign-in can no longer go ahead for any tracker. */
export async function signInBlocked(service: TokenService): Promise<string | null> {
  return unavailableMessage(service);
}

export function unavailableMessage(service: TokenService): string {
  return `${LABEL[service]} sign-in is unavailable: Harbor's sign-in server has shut down.`;
}
