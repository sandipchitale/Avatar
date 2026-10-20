import { describe, expect, mock, test } from 'claude-code/testing'

// What `avatar-link attach` prints: one JSON event per line.
const lines = (...events: object[]) => events.map((event) => JSON.stringify(event) + '\n').join('')

describe('who attaches', () => {
  test('a headless session stays off until a surface attaches, then attaches once', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/someone' })
    const spawned: string[][] = []
    on('process.spawn', async function* ($, e) {
      spawned.push([...e.argv])
      return { value: { code: 3, signal: null } }
    })
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.attach', ($, e) => ({ clientId: e.clientId }))

    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    expect(spawned).toEqual([])

    await $.session.attach({ surface: 'desktop', clientId: 'desktop:default' })
    await clock.settle()
    expect(spawned.length).toBe(1)
    expect(spawned[0]?.[1]).toBe('attach')

    await $.session.attach({ surface: 'mobile', clientId: 'mobile:default' })
    await clock.settle()
    expect(spawned.length).toBe(1)
  })
})

/** A promise and the call that resolves it. */
function gate(): { opened: Promise<void>; open: () => void } {
  let open = () => {}
  const opened = new Promise<void>((resolve) => { open = resolve })
  return { opened, open }
}

describe('a reply written before Avatar attaches', () => {
  test('is said once it does, then ended', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/someone' })
    const avatar = gate()
    const sent: { route: string; body: Record<string, unknown> }[] = []
    on('process.spawn', async function* () {
      await avatar.opened
      yield { stream: 'stdout' as const, text: lines({ type: 'attached', face: 'male' }) }
      await new Promise(() => {})
      return { value: { code: 0, signal: null } }
    })
    on('http.fetch', ($, e) => {
      sent.push({ route: e.url.replace('http://avatar', ''), body: JSON.parse(String(e.init?.body)) as Record<string, unknown> })
      return { value: { status: 200, ok: true, headers: {}, text: '{}' } }
    })
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.attach', ($, e) => ({ clientId: e.clientId }))
    on('turn.start', ($, e) => ({ turnId: e.turnId }))
    on('turn.step', async function* ($, e) {
      yield { kind: 'text' as const, index: 0, text: 'Hello there. This is the first reply.' }
      return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn' as const, usage: null }
    })
    on('turn.complete', ($, e) => ({ text: e.answer }))

    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await $.session.attach({ surface: 'desktop', clientId: 'desktop:default' })
    await $.turn.start({ text: 'hi', turnId: 't1' })
    for await (const _ of $.turn.step({ turnId: 't1', index: 0, model: 'm', messageCount: 1 })) { /* drain */ }
    await $.turn.complete({ turnId: 't1', answer: '', durationMs: 1, isAborted: false, reason: 'answer' })
    expect(sent).toEqual([])

    avatar.open()
    await clock.settle()
    const said = sent.filter((s) => s.route === '/say').map((s) => s.body.text)
    expect(said).toEqual(['Hello there.', 'This is the first reply.'])
    expect(sent.at(-1)?.route).toBe('/reply/end')
  })
})

describe('dictation on the desktop', () => {
  test('goes into the prompt box, and "send it" submits it', async ($, on) => {
    const clock = mock.clock(on)
    mock.env(on, { HOME: '/Users/someone' })
    let box = ''
    const submitted: string[] = []
    on('process.spawn', async function* () {
      yield { stream: 'stdout' as const, text: lines(
        { type: 'attached', face: 'male' },
        { type: 'ears.final', text: 'list the' },
        { type: 'ears.final', text: 'open issues' },
        { type: 'ears.final', text: 'send it' },
      ) }
      await new Promise(() => {})
      return { value: { code: 0, signal: null } }
    })
    on('http.fetch', () => ({ value: { status: 200, ok: true, headers: {}, text: '{}' } }))
    on('prompt.read', () => ({ value: { text: box, cursor: box.length } }))
    on('prompt.fill', ($, e) => {
      box = e.mode === 'append' ? box + e.text : e.text
      return { isFilled: true, text: box, cursor: box.length }
    })
    on('prompt.submit', ($, e) => {
      submitted.push(e.text)
      return { text: e.text }
    })
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('session.attach', ($, e) => ({ clientId: e.clientId }))

    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await $.session.attach({ surface: 'desktop', clientId: 'desktop:default' })
    await clock.settle()

    expect(submitted).toEqual(['list the open issues'])
    expect(box).toBe('')
  })
})
