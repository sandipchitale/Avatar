// Presence: talk with Claude Code through the Avatar app.
//
// Avatar (a menu bar app) is the face, the voice and the ears, with its own controls (Play/Pause,
// Stop, Mic, Man/Woman, Pin, and the speech bubble on a click of the head, with a caret to play
// from). This mod drives it: replies are spoken as they are written, the face follows the turn,
// and with the mic on, between turns, what you say goes into Claude Code's prompt box, where you
// can edit it by keyboard or by voice ("scratch that", "clear") and send it ("send it").

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { appendText, earsTrouble, parseUtterance, withoutLast, type EarsEvent } from './ears'
import { applyEdit, EditHistory, parseEdit } from './editing'
import { EventLines, requestBody, type AvatarEvent } from './link'
import { Segmenter } from './segmenter'

const COMMAND = 'presence'
const COMPOSE_SECTION = 'presence:spoken-replies'

const voiceAtom = atom({ plugin: 'presence', key: 'voice' } as const, true)
const micAtom = atom({ plugin: 'presence', key: 'mic' } as const, false)
const earsAtom = atom({ plugin: 'presence', key: 'ears' } as const, 'off')
const hearingAtom = atom({ plugin: 'presence', key: 'hearing' } as const, null as string | null)

const SPOKEN_REPLIES = [
  'The user is listening to your replies: everything you write outside code blocks is read aloud by an avatar as you write it.',
  'Open with a one-sentence answer, then the detail. Write for the ear: short sentences, no tables for prose.',
  'Code, commands and long output belong in fenced code blocks; they are shown, and announced rather than read.',
  "You can set the avatar's mood with a cue such as [happy] or [concerned] before a sentence; it is not spoken.",
  'Do not call any speak tool to say your reply: it is already spoken.',
].join(' ')

/** The options its manifest's `userConfig` declares. */
export type Options = { sendPhrase: string; linkPath: string; socket: string }

export function readOptions(raw: Record<string, unknown>): Options {
  const text = (value: unknown, fallback: string) =>
    typeof value === 'string' && value.trim().length > 0 ? value.trim() : fallback
  return {
    sendPhrase: text(raw.sendPhrase, 'send it'),
    linkPath: text(raw.linkPath, '/Applications/Avatar.app/Contents/MacOS/avatar-link'),
    socket: typeof raw.socket === 'string' ? raw.socket.trim() : '',
  }
}

// MARK: Session state (module variables: a reload starts afresh and attaches anew)

let options: Options = readOptions({})
/** Someone is at this session (the terminal's REPL, or the desktop app attached): it attaches to Avatar. */
let started = false
let sessionName = ''
let socketPath = ''
let attached = false
let face = 'male'
let turnRunning = false
/** The reply id of the running turn (Avatar numbers each reply's segments). */
let replyId = ''
/** The text the last dictated phrase appended to the prompt box, for "scratch that". */
let lastAppended = ''
/** The prompt box's voice edits, for "undo that" and "redo that". */
const history = new EditHistory()
/** Everything sent to Avatar, in order: each request waits for the one before it. */
let chain: Promise<unknown> = Promise.resolve()
/** Bumped by Stop: speech queued before it is dropped, and the reply being written goes quiet. */
let speechGeneration = 0
/**
 * The sentences of a reply written before Avatar was attached, said once it is: the desktop app
 * starts the session with its first prompt, so its first reply is written while the session attaches.
 */
let unsaid: { reply: string; segments: string[]; endedAt: number | null } | null = null
/** How long after its turn ended a reply nobody heard is still said when Avatar attaches. */
const UNSAID_FOR_MS = 60_000

type Answer = { ok: boolean; status: number; body: Record<string, unknown> }

/** POSTs to one of Avatar's routes; never rejects. */
async function post($: EngineInterface, route: string, fields: Record<string, unknown> = {}): Promise<Answer> {
  if (!attached) return { ok: false, status: 0, body: {} }
  try {
    const response = await $.http.fetch(`http://avatar${route}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: requestBody(sessionName, fields),
      socketPath,
    })
    let body: Record<string, unknown> = {}
    try {
      body = JSON.parse(response.text) as Record<string, unknown>
    } catch {
      body = {}
    }
    return { ok: response.ok, status: response.status, body }
  } catch {
    return { ok: false, status: 0, body: {} }
  }
}

/** Runs `work` after everything sent before it, so the voice keeps the reply's order. */
function inOrder(work: () => Promise<unknown>): Promise<unknown> {
  chain = chain.then(work, work)
  return chain
}

/** Replies are spoken: Avatar is running and voice is on for this session. */
async function speaks($: EngineInterface): Promise<boolean> {
  return started && attached && (await read($, voiceAtom))
}

/** Says one sentence of reply `reply`, after what came before. */
function say($: EngineInterface, text: string, reply: string): Promise<unknown> {
  const generation = speechGeneration
  return inOrder(async () => {
    if (generation === speechGeneration) await post($, '/say', { reply, text })
  })
}

/** Says a sentence now, or keeps it for when Avatar is attached. */
function sayOrKeep($: EngineInterface, text: string, reply: string): void {
  if (attached) {
    void say($, text, reply)
    return
  }
  if (unsaid?.reply !== reply) unsaid = { reply, segments: [], endedAt: null }
  unsaid.segments.push(text)
}

/** Avatar has just attached: says what was kept of the reply, and ends it if its turn has. */
async function sayUnsaid($: EngineInterface): Promise<void> {
  const kept = unsaid
  unsaid = null
  if (kept === null) return
  if (kept.endedAt !== null && (await $.clock.now()) - kept.endedAt > UNSAID_FOR_MS) return
  for (const segment of kept.segments) void say($, segment, kept.reply)
  if (kept.endedAt !== null) void inOrder(() => post($, '/reply/end', { reply: kept.reply }))
}

/** Silence: drops what is queued, stops what is being said. */
async function stopSpeaking($: EngineInterface): Promise<void> {
  unsaid = null
  speechGeneration += 1
  chain = Promise.resolve()
  await post($, '/stop')
}

async function setFace($: EngineInterface, presence: 'listening' | 'thinking' | 'none', turn?: 'running' | 'idle'): Promise<void> {
  await post($, '/state', { presence, turn })
}

/** Between turns: listening if the mic is on, else nothing. */
async function idleFace($: EngineInterface): Promise<void> {
  await setFace($, (await read($, micAtom)) ? 'listening' : 'none', 'idle')
}

/** Which face speaks, as Avatar last said. The band above the prompt shows it, so draw it again. */
function setFaceName($: EngineInterface, name: string | undefined): void {
  if (name === undefined || name === face) return
  face = name
  $.ui.invalidate('ui.render')
}

async function setMic($: EngineInterface, on: boolean): Promise<void> {
  await update($, micAtom, () => on)
  await post($, '/listen', { on })
  if (!on) {
    await update($, hearingAtom, () => null)
    await update($, earsAtom, () => 'off')
  }
  if (!turnRunning) await idleFace($)
}

// MARK: Attaching (the session's `avatar-link attach` child)

/** Keeps a child attached for the session's life: retried while Avatar isn't running. */
async function attachLoop($: EngineInterface): Promise<void> {
  for (;;) {
    let wasAttached = false
    try {
      const child = $.process.spawn({ argv: [options.linkPath, 'attach', sessionName] })
      const lines = new EventLines()
      for await (const piece of child) {
        if (piece.stream !== 'stdout') continue
        for (const event of lines.push(piece.text)) {
          if (event.type === 'attached') wasAttached = true
          await received($, event)
        }
      }
    } catch {
      // No avatar-link (Avatar not installed): try again later.
    }
    attached = false
    // The band above the prompt reads `attached`, which isn't one of its atoms: draw it again.
    $.ui.invalidate('ui.render')
    await update($, hearingAtom, () => null)
    await $.clock.sleep(wasAttached ? 2_000 : 15_000)
  }
}

async function received($: EngineInterface, event: AvatarEvent): Promise<void> {
  switch (event.type) {
    case 'attached':
      attached = true
      $.ui.invalidate('ui.render')
      setFaceName($, event.face)
      // A reattach (Avatar relaunched) picks up where the session is.
      if (await read($, micAtom)) await post($, '/listen', { on: true })
      if (turnRunning) await setFace($, 'thinking', 'running')
      else await idleFace($)
      await sayUnsaid($)
      return
    case 'face':
      setFaceName($, event.face)
      return
    case 'mic':
      // Avatar's own Mic button.
      await update($, micAtom, () => event.state === 'on')
      if (event.state !== 'on') {
        await update($, hearingAtom, () => null)
        await update($, earsAtom, () => 'off')
      }
      if (!turnRunning) await idleFace($)
      return
    case 'ears.state': {
      const trouble = earsTrouble({ type: 'state', state: event.state as EarsEvent['state'], text: event.text })
      await update($, earsAtom, () => trouble ?? event.state ?? 'off')
      return
    }
    case 'ears.volatile':
      await update($, hearingAtom, () => event.text ?? null)
      return
    case 'ears.final':
      await update($, hearingAtom, () => null)
      // Never while Claude is working (Avatar itself drops what it hears while it speaks).
      if (!turnRunning) await act($, event.text ?? '')
      return
  }
}

/** Puts `text` in the prompt box for a voice edit, remembering what it held for "undo that". */
async function setBox($: EngineInterface, before: string, text: string): Promise<void> {
  history.record(before)
  await $.prompt.fill({ text, mode: 'replace' })
}

/** A finished phrase: a command, an edit of the prompt box, or words for it. */
async function act($: EngineInterface, text: string): Promise<void> {
  const said = parseUtterance(text, options.sendPhrase)
  switch (said.kind) {
    case 'dictate': {
      if (said.text.length === 0) return
      const box = await $.prompt.read()
      const edit = parseEdit(said.text)
      if (edit !== null) {
        lastAppended = ''
        if (edit.kind === 'undo' || edit.kind === 'redo') {
          const previous = edit.kind === 'undo' ? history.undo(box.text) : history.redo(box.text)
          if (previous === null) $.ui.toast(edit.kind === 'undo' ? 'Nothing to undo' : 'Nothing to redo')
          else await $.prompt.fill({ text: previous, mode: 'replace' })
          return
        }
        const result = applyEdit(box.text, edit)
        if ('error' in result) $.ui.toast(result.error)
        else await setBox($, box.text, result.text)
        return
      }
      // Into an empty (or blank) box, the phrase is the whole text: no stray leading space.
      const blank = box.text.trim().length === 0
      const added = blank ? said.text : appendText(box.text, said.text)
      const filled = await $.prompt.fill({ text: added, mode: blank ? 'replace' : 'append' })
      if (filled.isFilled) {
        history.record(box.text)
        lastAppended = added
      } else {
        $.ui.toast(`Heard while the prompt box was busy: “${said.text}”`)
      }
      return
    }
    case 'send': {
      const box = await $.prompt.read()
      const prompt = box.text.trim()
      if (prompt.length === 0) {
        $.ui.toast('Nothing to send yet')
        return
      }
      lastAppended = ''
      history.clear()
      await $.prompt.fill({ text: '', mode: 'replace' })
      void $.prompt.submit({ text: prompt, asUser: true })
      return
    }
    case 'scratch': {
      const box = await $.prompt.read()
      const rest = withoutLast(box.text, lastAppended)
      lastAppended = ''
      if (rest === null) $.ui.toast('Nothing to scratch')
      else await setBox($, box.text, rest)
      return
    }
    case 'clear': {
      const box = await $.prompt.read()
      lastAppended = ''
      await setBox($, box.text, '')
      return
    }
    case 'stop':
      await stopSpeaking($)
      return
    case 'replay':
      await post($, '/replay')
      return
    case 'micOff':
      await setMic($, false)
      return
  }
}

// MARK: The command

async function command($: EngineInterface, args: string): Promise<{ text: string }> {
  const words = args.trim().toLowerCase().replace(/\s+/g, ' ')
  switch (words) {
    case 'mic on':
    case 'mic off':
      await setMic($, words === 'mic on')
      return { text: words === 'mic on' ? `The mic is on: between turns, what you say goes into the prompt; say “${options.sendPhrase}” to send it.` : 'The mic is off.' }
    case 'face male':
    case 'face female': {
      const chosen = words.slice(5)
      await post($, '/face', { face: chosen })
      setFaceName($, chosen)
      return { text: `The ${chosen === 'female' ? 'woman' : 'man'} speaks.` }
    }
    case 'stop':
      await stopSpeaking($)
      return { text: 'Stopped.' }
    case 'replay':
      await post($, '/replay')
      return { text: 'Saying the last reply again.' }
    case 'on':
    case 'off':
      await update($, voiceAtom, () => words === 'on')
      if (words === 'off') await stopSpeaking($)
      return { text: words === 'on' ? 'Replies are spoken again.' : 'Replies are not spoken in this session.' }
    case '':
    case 'status': {
      const where = attached ? `Avatar is attached, the ${face === 'female' ? 'woman' : 'man'} speaking` : 'Avatar is not running'
      const voice = (await read($, voiceAtom)) ? 'replies are spoken' : 'replies are not spoken'
      const mic = (await read($, micAtom)) ? `the mic is on (${await read($, earsAtom)})` : 'the mic is off'
      return { text: `${where}; ${voice}; ${mic}.` }
    }
    default:
      return { text: `Usage: /${COMMAND} [status|mic on|mic off|face male|face female|stop|replay|on|off]` }
  }
}

// MARK: The hooks

/** Attaches the session to Avatar, once, when someone is at it. */
async function start($: EngineInterface): Promise<void> {
  if (started) return
  started = true
  const home = (await $.env.get('HOME').catch(() => undefined)) ?? ''
  socketPath = options.socket.length > 0 ? options.socket : `${home}/Library/Application Support/Avatar/avatar.sock`
  const id = await $.session.id().catch(() => 'session')
  sessionName = `${id}-${Math.random().toString(36).slice(2, 8)}`
  // It ends only with the session (a reload, or the engine going away beneath it).
  void attachLoop($).catch(() => undefined)
  await $.command.register({
    name: COMMAND,
    description: 'Presence: talk with Claude Code through the Avatar app',
    argumentHint: '[status|mic on|mic off|face male|face female|stop|replay|on|off]',
  }).catch(() => undefined)
}

export const register: Register = (on, rawOptions) => {
  options = readOptions(rawOptions as Record<string, unknown>)

  // Only a session someone is at attaches: the terminal's REPL at its start, or one the desktop app
  // (or another surface) attaches to later. A headless run (`claude -p`, a script on the SDK) never
  // speaks or takes the microphone.
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    if (e.isInteractive || e.surface !== null) await start($)
    return result
  })

  on('session.attach', async ($, e, next) => {
    const result = await next(e)
    await start($)
    return result
  })

  on('command.run', { command: 'presence' }, ($, e) => command($, e.args))

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (!(await speaks($))) return composed
    return { sections: [...composed.sections, { id: COMPOSE_SECTION, text: SPOKEN_REPLIES, scope: 'session' as const }] }
  })

  on('prompt.submit', async ($, e, next) => {
    lastAppended = ''
    history.clear()
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    turnRunning = true
    replyId = e.turnId
    // Every turn, however it was sent (typed, or "send it", which prompt.submit doesn't see): Avatar
    // keeps the microphone shut until it is over, even in the pauses while the reply is written.
    if (attached) {
      await stopSpeaking($)
      await setFace($, 'thinking', 'running')
    }
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    // Not `speaks()`: a reply begun before Avatar attached is kept and said once it has.
    const speaking = e.agentId === undefined && started && (await read($, voiceAtom))
    if (!speaking) return yield* next(e)
    const reply = replyId || e.turnId
    const generation = speechGeneration
    // One sentence at a time, so the bubble's highlight follows the voice.
    const segmenter = new Segmenter({ batchChars: 1 })
    const stream = next(e)
    let step = await stream.next()
    while (step.done !== true) {
      const chunk = step.value
      yield chunk
      // After Stop, the rest of what is being written isn't said.
      if (chunk.kind === 'text' && generation === speechGeneration) {
        for (const segment of segmenter.push(chunk.text)) sayOrKeep($, segment, reply)
      }
      step = await stream.next()
    }
    if (generation === speechGeneration) for (const segment of segmenter.flush()) sayOrKeep($, segment, reply)
    return step.value
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId !== undefined) return done
    turnRunning = false
    const reply = replyId
    if (e.isAborted) await stopSpeaking($)
    if (attached) {
      void inOrder(() => post($, '/reply/end', { reply }))
      // Avatar opens the microphone itself once the reply has been said.
      void inOrder(() => idleFace($))
    } else if (unsaid?.reply === reply) {
      unsaid.endedAt = await $.clock.now()
    }
    return done
  })

  // A row above the prompt while Avatar is attached: a button that turns the mic on or off, buttons
  // for the man's and the woman's face (the one speaking dim), and with the mic on, what is being
  // heard or that it is listening. Other plugins' rows (and the engine's)
  // stay, below it.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || !started || !attached) return next(e)
    const [mic, hearing, ears, beneath] = await Promise.all([
      read($, micAtom), read($, hearingAtom), read($, earsAtom), next(e),
    ])
    const { Box, Button, Text } = $.ui.resolve(e)
    // The button names what a press does.
    const toggle = <Button key="presence-mic" plain label={mic ? '🎙  Mic off' : '🎙  Mic on'} onPress={() => setMic($, !mic)} />
    const faceButton = (name: 'male' | 'female', label: string) => (
      <Button key={`presence-${name}`} plain dimColor={face === name} label={label}
        onPress={() => post($, '/face', { face: name }).then(() => setFaceName($, name))} />
    )
    const room = Math.max(20, (e.props.bodyColumns ?? 80) - 30)
    const line = !mic ? ''
      : hearing !== null ? hearing
        : e.props.isWorking ? 'waits while Claude works'
          : ears === 'listening' ? `listening · say “${options.sendPhrase}” to send` : ears
    const row = line.length === 0
      ? <Box flexDirection="row" gap={2}>{toggle}{faceButton('male', 'Man')}{faceButton('female', 'Woman')}</Box>
      : (
        <Box flexDirection="row" gap={2}>
          {toggle}
          {faceButton('male', 'Man')}
          {faceButton('female', 'Woman')}
          <Text dimColor={hearing === null} wrap="truncate-end">{line.length > room ? line.slice(0, room - 1) + '…' : line}</Text>
        </Box>
      )
    return (
      <Box flexDirection="column">
        {row}
        {beneath}
      </Box>
    )
  })
}
