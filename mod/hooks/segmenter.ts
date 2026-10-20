// Turns the model's reply, as it streams in pieces, into segments worth speaking: whole sentences,
// whole markdown lines, and whole fenced code blocks (which Avatar announces rather than
// reads). The first sentence goes out on its own so the voice starts quickly; after that sentences
// are gathered to about `batchChars`, so the speech flows rather than pausing after every one.
//
// Lines stay lines inside a segment (Avatar reads markdown line by line), and a blank line
// ends a paragraph's segment.

/** Words whose trailing period doesn't end a sentence. */
const ABBREVIATIONS = new Set([
  'e.g', 'i.e', 'etc', 'vs', 'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'no', 'fig', 'approx', 'cf',
])

export type SegmenterOptions = {
  /** Characters to gather before a sentence boundary ends a later segment. */
  batchChars?: number
}

export class Segmenter {
  /** Text not yet sorted into sentences: the rest of the current line. */
  private pending = ''
  /** Finished sentences waiting to be spoken together. */
  private gathered = ''
  /** Whether `gathered` ends in the middle of a line (join with a space, not a newline). */
  private midLine = false
  /** The lines of a code block that is still open. */
  private fence: string[] | null = null
  private emitted = 0
  private readonly batchChars: number

  constructor(options: SegmenterOptions = {}) {
    this.batchChars = options.batchChars ?? 160
  }

  /** Feeds a piece of the reply; returns the segments it completed. */
  push(text: string): string[] {
    const out: string[] = []
    this.pending += text
    let newline: number
    while ((newline = this.pending.indexOf('\n')) >= 0) {
      const line = this.pending.slice(0, newline)
      this.pending = this.pending.slice(newline + 1)
      this.line(line, out)
    }
    // Finished sentences of an unfinished line, unless the line might be a fence.
    if (this.fence === null && !/^\s*[`~]/.test(this.pending)) {
      this.pending = this.sentences(this.pending, out)
    }
    return out
  }

  /** The reply has ended: whatever is left. */
  flush(): string[] {
    const out: string[] = []
    if (this.pending.length > 0) {
      const rest = this.pending
      this.pending = ''
      this.line(rest, out)
    }
    if (this.fence !== null) {
      // A block the reply never closed is still a block.
      this.emit(this.fence.join('\n'), out)
      this.fence = null
    }
    this.emitGathered(out)
    return out
  }

  /** A complete line (what is left of it, if its first sentences went out already). */
  private line(line: string, out: string[]): void {
    const isFence = /^\s*(```|~~~)/.test(line)
    if (this.fence !== null) {
      this.fence.push(line)
      if (isFence) {
        this.emit(this.fence.join('\n'), out)
        this.fence = null
      }
      return
    }
    if (isFence) {
      // What came before the block is spoken first; the block is one segment of its own.
      this.emitGathered(out)
      this.fence = [line]
      return
    }
    if (line.trim().length === 0) {
      // A paragraph ends.
      this.emitGathered(out)
      return
    }
    const rest = this.sentences(line, out)
    if (rest.trim().length > 0) this.add(rest, out)
    // The line is over: what comes next starts a new one.
    this.midLine = false
  }

  /** Adds each finished sentence in `text`; returns what follows the last one. */
  private sentences(text: string, out: string[]): string {
    const boundary = /[.!?…]+["')\]]*(?=\s)/g
    let start = 0
    let match: RegExpExecArray | null
    while ((match = boundary.exec(text)) !== null) {
      const end = match.index + match[0].length
      const sentence = text.slice(start, end)
      if (isAbbreviation(sentence)) continue
      this.add(sentence, out)
      start = end
    }
    return text.slice(start)
  }

  /** Gathers a sentence (or a line's unterminated rest), emitting when there is enough. */
  private add(sentence: string, out: string[]): void {
    const words = this.midLine ? sentence.trim() : sentence.trimEnd()
    if (words.trim().length === 0) return
    if (this.gathered.length === 0) this.gathered = words.trimStart()
    else this.gathered += (this.midLine ? ' ' : '\n') + words
    this.midLine = true
    if (this.emitted === 0 || this.gathered.length >= this.batchChars) this.emitGathered(out)
  }

  private emitGathered(out: string[]): void {
    this.emit(this.gathered, out)
    this.gathered = ''
  }

  private emit(segment: string, out: string[]): void {
    const text = segment.trim()
    if (text.length === 0) return
    out.push(text)
    this.emitted += 1
  }
}

function isAbbreviation(sentence: string): boolean {
  if (!sentence.endsWith('.')) return false
  const word = /(\S+)\.$/.exec(sentence.trimEnd())?.[1]?.toLowerCase().replace(/^[("']+/, '')
  if (word === undefined) return false
  // "1." of a numbered line, a decimal or a version: never the end of a sentence on its own.
  if (/^\d+$/.test(word)) return true
  return ABBREVIATIONS.has(word) || /^[a-z]$/.test(word)
}
