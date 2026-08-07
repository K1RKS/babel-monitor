# Plan: WireGuard live KPIs + detail tables (incl. WG-Mobile)

**Status:** implemented in 0.1.70 · **Ring buffer:** unchanged · **Depends on:** existing `store.wg` KPIs; sibling package [`wireguard-mobile`](https://github.com/K1RKS/wireguard-mobile) (`wgm*` / UCI `wireguard_mobile`)

## Goal

Extend babel-monitor’s optional WireGuard surface the same way AREDN status tiles work:

1. **KPI strip** — add optional **WG Mobile** (`live/active/total`), same pattern as **WG Server Tunnels** / **WG Server Clients**.
2. **Exactly two bottom live tables** (each only if that config exists on the node):
   - **WireGuard** — original node↔node tunnels (servers + clients together) from `/etc/config.mesh/wireguard`
   - **WireGuard Mobile** — phone/desktop peers from `/etc/config/wireguard_mobile`
3. Each table has its own **Enabled only** filter (default **on**, separate `localStorage` keys).
4. Columns include name, last heard, lifetime RX/TX, **RX/TX rate**, **MTU**, **contact/notes**, and (WG-M only) **established** as a filled/unfilled icon.
5. **Not in the sample ring** — live snapshot only (like `live_neighbors`).

## Background (sources of truth)

| Kind | UCI | Ifaces | Display name | Live match |
|------|-----|--------|--------------|------------|
| Server tunnels (node is server) | `wireguard` type `client` | `wgc*` | UCI `name` | peer pubkey in `key` + handshake ≤300s |
| Client tunnels (node is client) | `wireguard` type `server` | `wgs*` | UCI `name` | same |
| WG-Mobile | `wireguard_mobile` type `client` | `wgm{client_id}` | `CallSign-DeviceName` | peer `public_key` + handshake ≤300s |

Existing babel-monitor already aggregates SC as `store.wg.server_tunnels` / `store.wg.clients` in `sample.uc` (`readWgTunnelStats`) and shows KPIs only when `total > 0`. Mobile is absent today.

WG-Mobile package: optional sibling APK; babel-monitor must degrade cleanly when UCI/package missing (empty totals → no KPI / no section).

## Architecture

```
collectSample()
  ├─ pushSample(sample)          ← ring UNCHANGED (no WG detail fields)
  ├─ store.live_neighbors = …    ← existing
  ├─ store.last.wg_xfer = {…}    ← scratch for rate Δ only (not ring)
  └─ store.wg = {                ← expand live-only object
       server_tunnels: {live,active,total},
       clients: {live,active,total},
       mobile: {live,active,total},   ← NEW KPI
       sc: [ … ],                     ← original WG tunnels (servers+clients)
       mobile_peers: [ … ]            ← WG-M peers
     }

api=live → includes store.wg (already)
UI: KPI pushWg("WG Mobile", …)
    + two sections after Routing events (hidden when empty)
```

**API:** bump `API_VERSION` (live `wg` shape grows). **Do not** bump `SCHEMA_VERSION` / `SAMPLE_WIDTH`.

**Cost:** prefer a single `wg show all dump` parse per sample for handshake + transfer + endpoint. Cap row count if needed (e.g. 64) so a misconfigured node cannot balloon RAM.

## Data collection (`sample.uc`)

Refactor `readWgTunnelStats()` → `readWgLive(store)` that returns summaries + row arrays and updates `store.last.wg_xfer` for rates.

### Peer runtime map (from `wg`)

Parse once per sample:

- `iface`, `peer_pubkey`, `latest_handshake` (unix), `rx_bytes`, `tx_bytes`, `endpoint` (optional)

### Rate (v1, not in ring)

Keep previous sample’s transfer counters keyed by peer pubkey (or `iface|pubkey`) in `store.last.wg_xfer`:

- `rx_rate_bps` / `tx_rate_bps` = max(0, Δbytes) / Δt over the sample interval
- First sample after boot / peer appear: rates null/0 until a prior point exists
- Peer restart that resets counters: clamp Δ to ≥0 (same pattern as iface packet deltas)

### MTU

- **SC:** from UCI `/etc/config.mesh/wireguard` `@network[0].mtu` when per-tunnel MTU is absent; else network iface MTU / UCI if available
- **WG-M:** resolved client MTU (per-client fixed/auto/default → effective value from UCI `last_mtu` / `mtu_fixed` / main default when known; else iface sysfs `/sys/class/net/wgmN/mtu`)

Expose numeric `mtu` on each row (0/null → show “—”).

### SC rows (`/etc/config.mesh` package `wireguard`)

For each `client` and `server` section (one combined table, Role column):

| Field | Source |
|-------|--------|
| `role` | `server_tunnel` (`client` UCI) / `client` (`server` UCI) |
| `name` | UCI `name` |
| `enabled` | UCI `enabled === "1"` |
| `iface` | best-effort (`wgc*` / `wgs*`) when known |
| `port` | UCI `port` |
| `contact` | UCI `contact` (column) |
| `mtu` | see MTU above |
| `last_handshake` | matched peer handshake unix (0 = never) |
| `live` | handshake within 300s |
| `rx_bytes` / `tx_bytes` | matched peer transfer (lifetime) |
| `rx_rate_bps` / `tx_rate_bps` | from `store.last.wg_xfer` Δ |
| `endpoint` | matched peer endpoint when present |

### Mobile rows (`/etc/config` package `wireguard_mobile`)

Skip entirely if cursor/package unavailable.

| Field | Source |
|-------|--------|
| `name` | `CallSign-DeviceName` (fallback section name) |
| `enabled` | client `enabled !== "0"` |
| `iface` | `wgm{client_id}` |
| `address` | UCI client address (`172.29.N.2`) |
| `port` | UCI listen port |
| `notes` | UCI `notes` (column) |
| `mtu` | resolved effective MTU |
| `established` | UCI `wg_established` (or legacy `wg_connected`) === `"1"` — **first-claim flag, not live** |
| `last_handshake` / `live` / `rx_bytes` / `tx_bytes` / rates / `endpoint` | via pubkey match |

Summaries:

- `total` = configured sections  
- `active` = enabled  
- `live` = recent handshake  

Match existing KPI semantics (and WG-M tile: active/enabled/allocated).

## UI (`index.html`)

### KPI strip

```text
pushWg("WG Server Tunnels", wg.server_tunnels);
pushWg("WG Server Clients", wg.clients);
pushWg("WG Mobile", wg.mobile);   // NEW — only if total > 0
```

Tooltip unchanged: `live/active/total`.

### Bottom sections (after **Routing events**) — exactly two tables

1. **WireGuard** — if `sc.length > 0` (original tunnels: servers + clients)
2. **WireGuard Mobile** — if `mobile_peers.length > 0`

Each section header:

- Title  
- Own checkbox **Enabled only** (default checked; independent keys `bm_wg_sc_enabled_only`, `bm_wg_m_enabled_only`)

### Table columns (v1)

**WireGuard (original tunnels)**

| Column | Notes |
|--------|--------|
| Name | UCI tunnel name |
| Role | Server tunnel / Client |
| Last heard | relative (“12s ago”, “never”) + title with absolute time |
| Status | Live / Quiet / Never |
| RX / TX | lifetime MiB (tooltip: since iface/peer up) |
| RX/TX rate | e.g. `12.4 / 3.1 KB/s` from sample Δ |
| MTU | numeric value |
| Contact | UCI contact/notes |
| Port | compact |

**WireGuard Mobile**

| Column | Notes |
|--------|--------|
| Name | CallSign-DeviceName |
| Est. | Filled icon when `established`; unfilled when not. Tooltip: “First claim used — not live connection” |
| Last heard | same |
| Status | same |
| RX / TX | lifetime MiB |
| RX/TX rate | same formatting |
| MTU | numeric |
| Notes | UCI notes |
| Address | client `/32` |
| Port | UDP |

**Established icon:** simple CSS/SVG circle or check glyph — filled = established, outline/empty = not. Must not be confused with Live status (separate column).

Hide whole `<section>` when that config is empty; if Enabled-only hides all rows, show empty state (“No enabled tunnels” / “No enabled mobile clients”).

Refresh from existing `refreshLive()` path — no extra CGI.

## Bytes / rates vs “last 24 hours”

- **Lifetime RX/TX** from `wg` dump — label *since iface/peer up*.
- **RX/TX rate** from daemon scratch deltas — not ring history.
- True rolling **24h** totals would need ring or flash — **out of scope**.

## Suggested extras (still optional / later)

| Metric | Why |
|--------|-----|
| Endpoint | Where peer dials from |
| Allowed IPs | Routing/NAT debug |
| Keepalive | Cellular tuning |
| Aggregate live bytes on KPI | Sum across live peers |

## Explicit non-goals

- No WG fields in sample ring / series / history charts  
- No flash writes for WG metrics  
- No dependency on installing `wireguard-mobile`  
- No CRUD / admin of tunnels (status only)  
- No 24h rolling byte totals without a future ring design  
- No third table (servers and clients stay in one WireGuard table)

## Implementation todos

1. Expand `readWg*` in `sample.uc` + `store.wg` / `store.last.wg_xfer`; keep ring push untouched  
2. Expose via existing `api=live`; bump `API_VERSION`  
3. KPI: **WG Mobile**  
4. Two bottom tables, each with Enabled-only toggle; columns including rate, MTU, contact/notes, WG-M established icon  
5. README note; bump package version per revision rule when implementing  
6. Manual check: SC only; WG-M only; neither; per-table enabled filter; established icon states  

## Confirmed decisions

- **Two tables only:** original WireGuard (clients + servers) and WG-Mobile — each with its own Enabled-only filter.  
- **v1 columns include** RX/TX rate, MTU value, contact/notes, WG-M established filled/unfilled icon.  
- **Lifetime** RX/TX labeled “since iface up”; rates from sample-interval deltas.  
- Sections sit **below Routing events**.  
