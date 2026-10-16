// CLI self-test for jev-probe (PRD-0106 M2). No network required for offline path.
//
//   node --experimental-strip-types --no-warnings \
//     .ai/hooks/pre/jev-probe.self-test.ts

import jevProbeHook, {
  PROBE_TIMEOUT_MS,
  probeJev,
  toAcoJevState,
  type Runtime
} from './jev-probe.ts'

async function selfTest(): Promise<void> {
  const failures: string[] = []
  const check = (label: string, ok: boolean, detail = '') => {
    if (ok) {
      console.log(`  PASS  ${label}`)
    } else {
      console.log(`  FAIL  ${label}${detail ? ` — ${detail}` : ''}`)
      failures.push(label)
    }
  }

  console.log('jev-probe self-test')

  check('PROBE_TIMEOUT_MS is 100', PROBE_TIMEOUT_MS === 100)

  const disabled = await probeJev({
    env: { JEV_DISABLED: '1', JEV_URL: 'http://127.0.0.1:9' },
    fetchImpl: async () => {
      throw new Error('fetch must not run when disabled')
    }
  })
  check('disabled forces reachable=false', disabled.reachable === false)
  check('disabled reason', disabled.reason === 'disabled')

  const notOpted = await probeJev({
    env: {},
    fetchImpl: async () => {
      throw new Error('fetch must not run when not opted-in')
    }
  })
  check('unset URL = not opted-in', notOpted.reason === 'not-opted-in')
  check('not opted-in is local-only', notOpted.reachable === false)

  let fetchCalled = false
  const timeout = await probeJev({
    env: { JEV_URL: 'http://127.0.0.1:1' },
    timeoutMs: 20,
    fetchImpl: async (_url, init) => {
      fetchCalled = true
      const { promise, reject } = Promise.withResolvers<Response>()
      const signal = init?.signal
      if (signal?.aborted) {
        const e = new Error('aborted')
        e.name = 'AbortError'
        reject(e)
        return promise
      }
      signal?.addEventListener('abort', () => {
        const e = new Error('aborted')
        e.name = 'AbortError'
        reject(e)
      })
      return promise
    }
  })
  check('opt-in calls fetch', fetchCalled)
  check('timeout/network is fail-open', timeout.reachable === false)
  check(
    'timeout reason is timeout|network',
    timeout.reason === 'timeout' || timeout.reason === 'network',
    timeout.reason
  )

  const ok = await probeJev({
    env: { XERJ_URL: 'http://127.0.0.1:8009' },
    fetchImpl: async () =>
      new Response('{}', {
        status: 200,
        headers: { 'content-type': 'application/json' }
      })
  })
  check('reachable when fetch ok', ok.reachable === true && ok.reason === 'ok')

  const state = toAcoJevState(notOpted)
  check('state baseline is graph.db', state.baseline === '.aco/graph.db')
  check('state mode local-only', state.mode === 'local-only')

  const logs: string[] = []
  const handlers: Record<string, ((...a: unknown[]) => unknown)[]> = {}
  const pi: Runtime = {
    logger: { info: (m) => logs.push(m) },
    on(event, fn) {
      const list = handlers[event] ?? []
      list.push(fn)
      handlers[event] = list
    }
  }
  jevProbeHook(pi)
  for (const fn of handlers.session_start ?? []) {
    const ret = await fn({})
    const blocked = ret && typeof ret === 'object' && 'block' in ret && ret.block === true
    check('session_start does not block', !blocked)
  }
  check('hook set acoJev', pi.acoJev?.baseline === '.aco/graph.db')
  check(
    'hook logged fail-open',
    logs.some((l) => l.includes('fail-open') || l.includes('local-only'))
  )

  if (failures.length > 0) {
    console.error(`\n${failures.length} failure(s)`)
    process.exit(1)
  }
  console.log('\nall passed (fail-open / optional path verified)')
}

selfTest().catch((err: unknown) => {
  console.error(err)
  process.exit(1)
})
