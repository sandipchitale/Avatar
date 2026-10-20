import { describe, expect, test } from 'claude-code/testing'
import { Segmenter } from './segmenter'

/** Feeds `pieces` one by one, then flushes: every segment, in order. */
function segments(pieces: string[], batchChars?: number): string[] {
  const segmenter = new Segmenter({ batchChars })
  const out: string[] = []
  for (const piece of pieces) out.push(...segmenter.push(piece))
  out.push(...segmenter.flush())
  return out
}

describe('Segmenter', () => {
  test('the first sentence goes out on its own, as soon as it ends', async () => {
    const segmenter = new Segmenter()
    expect(segmenter.push('Hello there. This')).toEqual(['Hello there.'])
    expect(segmenter.push(' is more.')).toEqual([])
    expect(segmenter.flush()).toEqual(['This is more.'])
  })

  test('sentences split across pieces are joined, not cut', async () => {
    expect(segments(['The bu', 'ild pas', 'sed. All ', 'good.'])).toEqual(['The build passed.', 'All good.'])
  })

  test('later sentences are gathered up to the batch size', async () => {
    const out = segments(['One. Two is here. Three is here. Four is here.'], 20)
    expect(out[0]).toBe('One.')
    expect(out.join(' ')).toBe('One. Two is here. Three is here. Four is here.')
    expect(out.length).toBeGreaterThan(1)
  })

  test('abbreviations, numbered lines and decimals do not end a sentence', async () => {
    expect(segments(['Use e.g. this one. Done.'])).toEqual(['Use e.g. this one.', 'Done.'])
    expect(segments(['Version 2.5 is out. Yes.'])).toEqual(['Version 2.5 is out.', 'Yes.'])
  })

  test('a fenced code block is one segment, even when it arrives in pieces', async () => {
    const out = segments(['Here is code:\n``', '`swift\nlet a = 1\n', 'let b. = 2\n```\nAfter it.'])
    expect(out).toEqual(['Here is code:', '```swift\nlet a = 1\nlet b. = 2\n```', 'After it.'])
  })

  test('a block the reply never closed is still flushed whole', async () => {
    expect(segments(['```\nline one\nline two'])).toEqual(['```\nline one\nline two'])
  })

  test('a blank line ends a paragraph', async () => {
    const out = segments(['First line. Second\n\nNew paragraph.'], 500)
    expect(out).toEqual(['First line.', 'Second', 'New paragraph.'])
  })
})
