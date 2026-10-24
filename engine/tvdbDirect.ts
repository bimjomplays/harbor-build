// tvdb-cast.ts and tvdb-collections.ts only knew Harbor's /api/tvdb/v4 proxy,
// which sends the project's TVDB key. bundle-config.mjs repoints their single v4() fetch here: the same
// calls go straight to api4.thetvdb.com with the bearer token tvdb.ts already logs in for (settings.tvdbKey,
// cached under harbor.tvdb.token.v1). Without a key there is nothing to send: the call rejects, the callers
// treat that as "TVDB did not answer", and no request is made.
import { safeFetch } from "@/lib/safe-fetch";
import { loadStoredSettings } from "@/lib/settings/load";
import { __tvdbToken } from "@/lib/providers/tvdb";

const V4 = "https://api4.thetvdb.com/v4";

export async function tvdbV4(rel: string): Promise<Response> {
  const key = (loadStoredSettings().tvdbKey ?? "").trim();
  const token = await (__tvdbToken as (k: string) => Promise<string | null>)(key);
  if (!token) throw new Error("TVDB: no key set");
  return safeFetch(`${V4}${rel}`, { headers: { authorization: `Bearer ${token}`, accept: "application/json" } });
}
