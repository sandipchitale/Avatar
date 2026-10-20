// Editing the prompt box by voice, for a box whose cursor a mod can't place. So every command works
// on the text itself: at its end ("delete last word"), or on the last place a phrase occurs
// ("replace cat with dog").
// Pure functions: the text in, the text out (or why not), so each command is tested on its own.

export type Edit =
  | { kind: 'replace'; find: string; with: string }
  | { kind: 'insert'; text: string; where: 'before' | 'after'; anchor: string }
  | { kind: 'delete'; find: string }
  | { kind: 'deleteLast'; unit: Unit; count: number }
  | { kind: 'case'; find: string; to: 'capitalize' | 'upper' | 'lower' }
  | { kind: 'append'; text: string }
  | { kind: 'undo' }
  | { kind: 'redo' }

const COUNTS: Record<string, number> = {
  a: 1, an: 1, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17,
  eighteen: 18, nineteen: 19, twenty: 20,
}

function count(word: string | undefined): number | null {
  if (word === undefined) return 1
  if (/^\d+$/.test(word)) return Number(word)
  return COUNTS[word] ?? null
}

/** A phrase as spoken, without the recogniser's closing punctuation or quotes. */
function phrase(text: string): string {
  return text.trim().replace(/^["“'‘]+|["”'’.,!?;:…]+$/g, '').trim()
}

/** Lowercase, single spaces, no punctuation at the ends: how a command's words are compared. */
function words(text: string): string {
  return text.toLowerCase().replace(/\s+/g, ' ').replace(/^[\s"“'‘]+|[\s"”'’.,!?;:…]+$/g, '')
}

type Unit = 'character' | 'word' | 'sentence' | 'line'

const UNITS: Record<string, Unit> = {
  character: 'character', characters: 'character', letter: 'character', letters: 'character',
  word: 'word', words: 'word', sentence: 'sentence', sentences: 'sentence', line: 'line', lines: 'line',
}

/**
 * The edit a finished phrase asks for, or null when it is just words to type. Only a whole phrase is
 * a command: "please replace the tires" is dictated, "replace tires with wheels" is an edit.
 */
export function parseEdit(spoken: string, now: () => Date = () => new Date()): Edit | null {
  // The recogniser may punctuate after the command's first word ("Type, send it."): that comma is not
  // part of the command.
  const original = spoken.trim().replace(/^([A-Za-z]+)[,:;.]\s+/, '$1 ')
  const said = words(original)

  if (said === 'undo that' || said === 'undo') return { kind: 'undo' }
  if (said === 'redo that' || said === 'redo') return { kind: 'redo' }
  if (said === 'new line' || said === 'press return' || said === 'press return key') return { kind: 'append', text: '\n' }
  if (said === 'new paragraph') return { kind: 'append', text: '\n\n' }
  if (said === 'insert date' || said === 'insert the date') {
    return { kind: 'append', text: now().toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' }) }
  }

  // "type <phrase>": exactly as spoken, never a command.
  const typed = /^type\s+(.+)$/is.exec(original)
  if (typed) return { kind: 'append', text: phrase(typed[1]!) }

  // "delete [the] [last|previous] [<count>] <unit>"
  const last = /^(?:delete|remove)\s+(?:the\s+)?(?:last|previous)?\s*(\w+)?\s*(characters?|letters?|words?|sentences?|lines?)$/.exec(said)
  if (last) {
    const n = count(last[1])
    const unit = UNITS[last[2]!]
    if (n !== null && n > 0 && unit !== undefined) return { kind: 'deleteLast', unit, count: n }
  }

  // "replace <phrase> with <phrase>": split on the last " with ".
  const replace = /^replace\s+(.+)$/is.exec(original)
  if (replace) {
    const rest = replace[1]!
    const split = rest.toLowerCase().lastIndexOf(' with ')
    if (split > 0) {
      const find = phrase(rest.slice(0, split))
      const replacement = phrase(rest.slice(split + 6))
      if (find.length > 0) return { kind: 'replace', find, with: replacement }
    }
  }

  // "insert <phrase> before|after <phrase>": split on the last " before " / " after ".
  const insert = /^insert\s+(.+)$/is.exec(original)
  if (insert) {
    const rest = insert[1]!
    const lower = rest.toLowerCase()
    const before = lower.lastIndexOf(' before ')
    const after = lower.lastIndexOf(' after ')
    const at = Math.max(before, after)
    if (at > 0) {
      const where = at === before ? 'before' : 'after'
      const text = phrase(rest.slice(0, at))
      const anchor = phrase(rest.slice(at + where.length + 2))
      if (text.length > 0 && anchor.length > 0) return { kind: 'insert', text, where, anchor }
    }
  }

  // "capitalize|uppercase|lowercase <phrase>"
  const caseChange = /^(capitali[sz]e|upper\s?case|lower\s?case)\s+(.+)$/is.exec(original)
  if (caseChange) {
    const verb = caseChange[1]!.toLowerCase().replace(/\s/g, '')
    const to = verb.startsWith('capital') ? 'capitalize' : verb === 'uppercase' ? 'upper' : 'lower'
    const find = phrase(caseChange[2]!)
    if (find.length > 0) return { kind: 'case', find, to }
  }

  // "delete|remove <phrase>" (after the unit forms above, and never "delete that"/"delete all").
  const remove = /^(?:delete|remove)\s+(.+)$/is.exec(original)
  if (remove && !['that', 'all', 'everything'].includes(words(remove[1]!))) {
    const find = phrase(remove[1]!)
    if (find.length > 0) return { kind: 'delete', find }
  }

  return null
}

/** Where `find` last occurs in `text`, ignoring case; -1 if it doesn't. */
function lastIndexOf(text: string, find: string): number {
  return text.toLowerCase().lastIndexOf(find.toLowerCase())
}

/** The text with `edit` applied, or a sentence saying why it can't be. Undo and redo are the caller's. */
export function applyEdit(text: string, edit: Edit): { text: string } | { error: string } {
  switch (edit.kind) {
    case 'append': {
      if (edit.text.startsWith('\n')) return { text: text.replace(/[ \t]+$/, '') + edit.text }
      const space = text.length === 0 || /\s$/.test(text) ? '' : ' '
      return { text: text + space + edit.text }
    }
    case 'replace': {
      const at = lastIndexOf(text, edit.find)
      if (at < 0) return { error: `Couldn't find “${edit.find}”` }
      return { text: text.slice(0, at) + edit.with + text.slice(at + edit.find.length) }
    }
    case 'insert': {
      const at = lastIndexOf(text, edit.anchor)
      if (at < 0) return { error: `Couldn't find “${edit.anchor}”` }
      if (edit.where === 'before') return { text: text.slice(0, at) + edit.text + ' ' + text.slice(at) }
      const end = at + edit.anchor.length
      return { text: text.slice(0, end) + ' ' + edit.text + text.slice(end) }
    }
    case 'delete': {
      const at = lastIndexOf(text, edit.find)
      if (at < 0) return { error: `Couldn't find “${edit.find}”` }
      const before = text.slice(0, at).replace(/[ \t]+$/, '')
      const after = text.slice(at + edit.find.length)
      const joined = before.length > 0 && after.length > 0 && !/^[\s.,!?;:]/.test(after) ? before + ' ' + after.replace(/^[ \t]+/, '') : before + after
      return { text: joined }
    }
    case 'case': {
      const at = lastIndexOf(text, edit.find)
      if (at < 0) return { error: `Couldn't find “${edit.find}”` }
      const found = text.slice(at, at + edit.find.length)
      const changed = edit.to === 'upper' ? found.toUpperCase()
        : edit.to === 'lower' ? found.toLowerCase()
          : found.replace(/(^|\s)(\S)/g, (_, space: string, letter: string) => space + letter.toUpperCase())
      return { text: text.slice(0, at) + changed + text.slice(at + edit.find.length) }
    }
    case 'deleteLast': {
      let rest = text.replace(/\s+$/, '')
      if (rest.length === 0) return { error: 'Nothing to delete' }
      for (let i = 0; i < edit.count && rest.length > 0; i++) {
        switch (edit.unit) {
          case 'character':
            rest = rest.slice(0, -1)
            break
          case 'word':
            rest = rest.replace(/\S+\s*$/, '').replace(/\s+$/, '')
            break
          case 'sentence':
            rest = withoutLastSentence(rest)
            break
          case 'line':
            rest = rest.includes('\n') ? rest.slice(0, rest.lastIndexOf('\n')) : ''
            break
        }
      }
      return { text: rest }
    }
    case 'undo':
    case 'redo':
      return { error: 'Undo and redo are kept by the caller' }
  }
}

/** `text` without its last sentence: back to the end of the one before, a line break, or the start. */
function withoutLastSentence(text: string): string {
  // The last sentence's own closing punctuation isn't a boundary.
  const body = text.replace(/[.!?…]+["”’']*$/, '')
  let end = 0
  for (const match of body.matchAll(/[.!?…]+["”’']*\s+|\n/g)) end = (match.index ?? 0) + match[0].length
  return text.slice(0, end).replace(/\s+$/, '')
}

/** The box's voice edits, for "undo that" and "redo that". */
export class EditHistory {
  private undos: string[] = []
  private redos: string[] = []

  /** The box held `before` when a voice edit changed it. */
  record(before: string): void {
    this.undos.push(before)
    if (this.undos.length > 50) this.undos.shift()
    this.redos = []
  }

  /** The text to go back to (the box holds `current`), or null. */
  undo(current: string): string | null {
    const previous = this.undos.pop()
    if (previous === undefined) return null
    this.redos.push(current)
    return previous
  }

  redo(current: string): string | null {
    const next = this.redos.pop()
    if (next === undefined) return null
    this.undos.push(current)
    return next
  }

  clear(): void {
    this.undos = []
    this.redos = []
  }
}
