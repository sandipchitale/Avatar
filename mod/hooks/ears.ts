// The ears: what the avatar hears, turned into edits of Claude Code's prompt box. The pieces here
// need no engine, so they are tested on their own; register.tsx does the listening and the editing.

/** The avatar's `ears.state` event. */
export type EarsEvent = {
  type: 'state' | 'volatile' | 'final'
  text?: string
  state?: 'idle' | 'preparing' | 'listening' | 'denied' | 'unavailable' | 'taken'
}

/** What a finished phrase means. */
export type Utterance =
  | { kind: 'send' }
  | { kind: 'scratch' }
  | { kind: 'clear' }
  | { kind: 'stop' }
  | { kind: 'replay' }
  | { kind: 'micOff' }
  | { kind: 'dictate'; text: string }

/** Lowercase, no punctuation, single spaces: how a spoken command is compared. */
export function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[“”"'’.,!?;:…]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/**
 * A command only when it is the whole phrase, so the same words inside a sentence are dictated as
 * words: "send it" sends, "please send it to Bob" is typed.
 */
export function parseUtterance(text: string, sendPhrase: string): Utterance {
  const said = normalize(text)
  if (said.length === 0) return { kind: 'dictate', text: '' }
  if (said === normalize(sendPhrase) || said === 'send prompt') return { kind: 'send' }
  if (said === 'scratch that' || said === 'delete that') return { kind: 'scratch' }
  if (['clear', 'clear prompt', 'clear all', 'delete all', 'delete everything'].includes(said)) return { kind: 'clear' }
  if (said === 'stop' || said === 'stop talking' || said === 'be quiet') return { kind: 'stop' }
  if (said === 'replay' || said === 'say that again' || said === 'repeat that') return { kind: 'replay' }
  if (said === 'mic off' || said === 'stop listening') return { kind: 'micOff' }
  return { kind: 'dictate', text: text.trim() }
}

/** What to append to the box for a dictated phrase: a space between it and what is there. */
export function appendText(box: string, phrase: string): string {
  if (box.length === 0 || /\s$/.test(box)) return phrase
  return ' ' + phrase
}

/**
 * The box without the last dictated phrase, or null when the box no longer ends with it (it was
 * edited by hand since): "scratch that" never deletes what it didn't write.
 */
export function withoutLast(box: string, appended: string): string | null {
  if (appended.length === 0 || !box.endsWith(appended)) return null
  return box.slice(0, box.length - appended.length).replace(/\s+$/, '')
}

/** Why the ears aren't listening, said in a few words for the band; null when listening is fine. */
export function earsTrouble(event: EarsEvent): string | null {
  switch (event.state) {
    case 'taken': return 'another Claude Code session has the microphone'
    case 'denied': return 'Avatar has no microphone access (System Settings → Privacy & Security → Microphone)'
    case 'unavailable': return event.text ?? 'Avatar cannot listen'
    default: return null
  }
}
