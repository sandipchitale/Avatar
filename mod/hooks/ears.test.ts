import { describe, expect, test } from 'claude-code/testing'
import { appendText, earsTrouble, normalize, parseUtterance, withoutLast } from './ears'

describe('parseUtterance', () => {
  test('the send phrase sends, however it was punctuated', async () => {
    expect(parseUtterance('Send it.', 'send it')).toEqual({ kind: 'send' })
    expect(parseUtterance('send prompt!', 'send it')).toEqual({ kind: 'send' })
    expect(parseUtterance('Ship it', 'ship it')).toEqual({ kind: 'send' })
  })

  test('a command only as the whole phrase: the same words in a sentence are dictated', async () => {
    expect(parseUtterance('Please send it to Bob.', 'send it'))
      .toEqual({ kind: 'dictate', text: 'Please send it to Bob.' })
    expect(parseUtterance('Stop the server.', 'send it')).toEqual({ kind: 'dictate', text: 'Stop the server.' })
  })

  test('scratch that, clear, stop, replay and mic off', async () => {
    expect(parseUtterance('Scratch that.', 'send it')).toEqual({ kind: 'scratch' })
    expect(parseUtterance('Clear.', 'send it')).toEqual({ kind: 'clear' })
    expect(parseUtterance('Delete all.', 'send it')).toEqual({ kind: 'clear' })
    expect(parseUtterance('Stop talking.', 'send it')).toEqual({ kind: 'stop' })
    expect(parseUtterance('Say that again.', 'send it')).toEqual({ kind: 'replay' })
    expect(parseUtterance('Mic off.', 'send it')).toEqual({ kind: 'micOff' })
  })

  test('normalize lowercases and drops punctuation', async () => {
    expect(normalize('  “Send   It!”  ')).toBe('send it')
  })
})

describe('the box', () => {
  test('a dictated phrase is spaced from what is there', async () => {
    expect(appendText('', 'Hello.')).toBe('Hello.')
    expect(appendText('Fix the bug', 'In main.')).toBe(' In main.')
    expect(appendText('Fix the bug ', 'In main.')).toBe('In main.')
  })

  test('scratch that removes only the phrase it wrote', async () => {
    expect(withoutLast('Fix the bug In main.', ' In main.')).toBe('Fix the bug')
    expect(withoutLast('Fix the bug In main. edited', ' In main.')).toBeNull()
    expect(withoutLast('anything', '')).toBeNull()
  })
})

describe('earsTrouble', () => {
  test('says why the ears stopped, or nothing when they are fine', async () => {
    expect(earsTrouble({ type: 'state', state: 'taken' })).toBe('another Claude Code session has the microphone')
    expect(earsTrouble({ type: 'state', state: 'unavailable', text: 'No speech transcription languages are installed.' }))
      .toBe('No speech transcription languages are installed.')
    expect(earsTrouble({ type: 'state', state: 'listening' })).toBeNull()
  })
})
