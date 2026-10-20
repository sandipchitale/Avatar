import { describe, expect, test } from 'claude-code/testing'
import { EventLines, requestBody } from './link'

describe('EventLines', () => {
  test('splits avatar-link output into events, across pieces', async () => {
    const lines = new EventLines()
    expect(lines.push('{"type":"attached","face":"male"}\n{"type":"segment.st')).toEqual([{ type: 'attached', face: 'male' }])
    expect(lines.push('arted","reply":"t1","segment":1}\n')).toEqual([{ type: 'segment.started', reply: 't1', segment: 1 }])
  })

  test('skips blank lines, non-JSON and objects without a type', async () => {
    expect(new EventLines().push('\nnope\n{"reply":"t1"}\n{"type":"face","face":"female"}\n'))
      .toEqual([{ type: 'face', face: 'female' }])
  })
})

describe('requests', () => {
  test('requestBody names the session and drops undefined fields', async () => {
    expect(JSON.parse(requestBody('s1', { text: 'Hi', mood: undefined }))).toEqual({ session: 's1', text: 'Hi' })
  })

})
