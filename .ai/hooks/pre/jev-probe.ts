// jev-probe — PRD-0106 M2 graceful-degradation pre-hook (OMP hooks/pre).
// Fail-open optional Jev/XERJ probe (<100ms). Structural triage always uses
// local `.aco/graph.db`. Active when JEV_URL/XERJ_URL set; JEV_DISABLED=1
// forces local-only. OMP loads default export from hooks/pre/*.ts.
// SELF-TEST: node --experimental-strip-types --no-warnings .ai/hooks/pre/jev-probe.self-test.ts

export const PROBE_TIMEOUT_MS = 100
export const PROBE_PATH = '/_memory'

const TRUTHY = new Set(['1', 'true', 'yes', 'on'])

export type JevProbeReason =
  | 'ok'
  | 'disabled'
  | 'not-opted-in'
  | 'timeout'
  | 'network'
  | 'http-error'
  | 'invalid-url'

export type JevProbeResult = {
  reachable: boolean
  optedIn: boolean
  disabled: boolean
  url: string | null
  latencyMs: number | null
  reason: JevProbeReason
  checkedAt: string
}

export type AcoJevState = JevProbeResult & {
  mode: 'local-only' | 'jev-available'
  baseline: '.aco/graph.db'
  optionalEnrichment: 'jev/xerj'
}

export type ProbeOptions = {
  env?: NodeJS.ProcessEnv
  timeoutMs?: number
  fetchImpl?: typeof fetch
  path?: string
}

/** Resolve optional enrichment base URL. Empty = not opted-in. */
export function resolveJevBaseUrl(env: NodeJS.ProcessEnv = process.env): string | null {
  const raw = (env.JEV_URL ?? env.XERJ_URL ?? '').trim()
  if (raw.length === 0) {
    return null
  }
  return raw.replace(/\/+$/, '')
}

export function isJevDisabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const raw = (env.JEV_DISABLED ?? '').trim().toLowerCase()
  return TRUTHY.has(raw)
}

export function makeResult(
  partial: Omit<JevProbeResult, 'checkedAt'> & { checkedAt?: string }
): JevProbeResult {
  return {
    checkedAt: partial.checkedAt ?? new Date().toISOString(),
    reachable: partial.reachable,
    optedIn: partial.optedIn,
    disabled: partial.disabled,
    url: partial.url,
    latencyMs: partial.latencyMs,
    reason: partial.reason
  }
}

/**
 * Fail-open probe. NEVER throws to callers that use probeJevSafe.
 * Uses AbortSignal + short timeout; no retries.
 */
export async function probeJev(options: ProbeOptions = {}): Promise<JevProbeResult> {
  const env = options.env ?? process.env
  const timeoutMs = Math.min(Math.max(1, options.timeoutMs ?? PROBE_TIMEOUT_MS), PROBE_TIMEOUT_MS)
  const fetchImpl = options.fetchImpl ?? globalThis.fetch
  const path = options.path ?? PROBE_PATH

  if (isJevDisabled(env)) {
    return makeResult({
      reachable: false,
      optedIn: false,
      disabled: true,
      url: null,
      latencyMs: null,
      reason: 'disabled'
    })
  }

  const base = resolveJevBaseUrl(env)
  if (base === null) {
    return makeResult({
      reachable: false,
      optedIn: false,
      disabled: false,
      url: null,
      latencyMs: null,
      reason: 'not-opted-in'
    })
  }

  let url: string
  try {
    url = new URL(path, `${base}/`).toString()
  } catch {
    return makeResult({
      reachable: false,
      optedIn: true,
      disabled: false,
      url: base,
      latencyMs: null,
      reason: 'invalid-url'
    })
  }

  if (typeof fetchImpl !== 'function') {
    return makeResult({
      reachable: false,
      optedIn: true,
      disabled: false,
      url,
      latencyMs: null,
      reason: 'network'
    })
  }

  const started = Date.now()
  const ac = new AbortController()
  const timer = setTimeout(() => ac.abort(), timeoutMs)

  try {
    const res = await fetchImpl(url, {
      method: 'GET',
      signal: ac.signal,
      headers: { accept: 'application/json, text/plain;q=0.9, */*;q=0.8' }
    })
    const latencyMs = Date.now() - started
    if (!res.ok) {
      return makeResult({
        reachable: false,
        optedIn: true,
        disabled: false,
        url,
        latencyMs,
        reason: 'http-error'
      })
    }
    return makeResult({
      reachable: true,
      optedIn: true,
      disabled: false,
      url,
      latencyMs,
      reason: 'ok'
    })
  } catch (err: unknown) {
    const latencyMs = Date.now() - started
    let name = ''
    if (err && typeof err === 'object' && 'name' in err) {
      const candidate = err.name
      if (typeof candidate === 'string') {
        name = candidate
      }
    }
    const reason: JevProbeReason =
      name === 'AbortError' || latencyMs >= timeoutMs ? 'timeout' : 'network'
    return makeResult({
      reachable: false,
      optedIn: true,
      disabled: false,
      url,
      latencyMs,
      reason
    })
  } finally {
    clearTimeout(timer)
  }
}

/** Wrapper that cannot throw — last-resort fail-open. */
export async function probeJevSafe(options: ProbeOptions = {}): Promise<JevProbeResult> {
  try {
    return await probeJev(options)
  } catch {
    const env = options.env ?? process.env
    return makeResult({
      reachable: false,
      optedIn: resolveJevBaseUrl(env) !== null,
      disabled: isJevDisabled(env),
      url: resolveJevBaseUrl(env),
      latencyMs: null,
      reason: 'network'
    })
  }
}

export function toAcoJevState(result: JevProbeResult): AcoJevState {
  return {
    ...result,
    mode: result.reachable ? 'jev-available' : 'local-only',
    baseline: '.aco/graph.db',
    optionalEnrichment: 'jev/xerj'
  }
}

export type Runtime = {
  logger?: {
    info?: (m: string) => void
    warn?: (m: string) => void
    debug?: (m: string) => void
  }
  acoJev?: AcoJevState
  on: (event: string, handler: (...args: unknown[]) => unknown) => void
}

function toolNameOf(event: unknown): string {
  if (event && typeof event === 'object' && 'toolName' in event) {
    const candidate = event.toolName
    return typeof candidate === 'string' ? candidate : ''
  }
  return ''
}

function attachState(pi: Runtime, state: AcoJevState): void {
  pi.acoJev = state
  const msg =
    state.mode === 'jev-available'
      ? `jev-probe: enrichment reachable (${state.latencyMs ?? '?'}ms) — structural queries still use .aco/graph.db`
      : `jev-probe: ${state.reason} — fail-open local-only (.aco/graph.db); Jev/XERJ is optional`
  pi.logger?.info?.(msg)
}

/**
 * OMP hook factory. Always fail-open: never returns { block: true }.
 */
export default function jevProbeHook(pi: Runtime): void {
  const run = async () => {
    try {
      attachState(pi, toAcoJevState(await probeJevSafe()))
    } catch {
      attachState(
        pi,
        toAcoJevState(
          makeResult({
            reachable: false,
            optedIn: false,
            disabled: false,
            url: null,
            latencyMs: null,
            reason: 'network'
          })
        )
      )
    }
  }

  pi.on('session_start', async () => {
    await run()
    // Explicitly no block — fail-open.
  })

  // Refresh only when triage tools fire and state is missing; never block.
  pi.on('tool_call', async (event: unknown) => {
    try {
      const tool = toolNameOf(event)
      if (!pi.acoJev && (tool === 'bash' || tool === 'read' || tool === 'skill')) {
        await run()
      }
    } catch {
      // fail-open
    }
  })
}
