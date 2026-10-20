import { describe, expect, test } from 'claude-code/testing'
import { applyEdit, EditHistory, parseEdit, type Edit } from './editing'

/** Parses `spoken` and applies it to `text`. */
function run(text: string, spoken: string): string {
  const edit = parseEdit(spoken)
  if (edit === null) throw new Error(`not a command: ${spoken}`)
  const result = applyEdit(text, edit)
  return 'text' in result ? result.text : `ERROR ${result.error}`
}

describe('parseEdit', () => {
  test('ordinary words are not commands', async () => {
    expect(parseEdit('Please replace the tires.')).toBeNull()
    expect(parseEdit('Fix the login bug.')).toBeNull()
    expect(parseEdit('Delete that.')).toBeNull()      // "scratch that" handles it
    expect(parseEdit('Delete all.')).toBeNull()       // "clear" handles it
  })

  test('commands, however the recogniser punctuated them', async () => {
    expect(parseEdit('Replace cat with dog.')).toEqual({ kind: 'replace', find: 'cat', with: 'dog' })
    expect(parseEdit('Delete the last two words.')).toEqual({ kind: 'deleteLast', unit: 'word', count: 2 })
    expect(parseEdit('Delete previous sentence.')).toEqual({ kind: 'deleteLast', unit: 'sentence', count: 1 })
    expect(parseEdit('Delete 3 characters')).toEqual({ kind: 'deleteLast', unit: 'character', count: 3 })
    expect(parseEdit('Insert quickly after run.')).toEqual({ kind: 'insert', text: 'quickly', where: 'after', anchor: 'run' })
    expect(parseEdit('Capitalize swift.')).toEqual({ kind: 'case', find: 'swift', to: 'capitalize' })
    expect(parseEdit('Uppercase api.')).toEqual({ kind: 'case', find: 'api', to: 'upper' })
    expect(parseEdit('Undo that.')).toEqual({ kind: 'undo' } satisfies Edit)
    expect(parseEdit('New line.')).toEqual({ kind: 'append', text: '\n' })
    expect(parseEdit('Type send it')).toEqual({ kind: 'append', text: 'send it' })
  })

  test('punctuation the recogniser puts after the first word is ignored', async () => {
    expect(parseEdit('Type, send it.')).toEqual({ kind: 'append', text: 'send it' })
    expect(parseEdit('Insert, all after run.')).toEqual({ kind: 'insert', text: 'all', where: 'after', anchor: 'run' })
    expect(parseEdit('Delete, last word.')).toEqual({ kind: 'deleteLast', unit: 'word', count: 1 })
  })

  test('replace splits on the last "with"', async () => {
    expect(parseEdit('Replace with care with carefully.')).toEqual({ kind: 'replace', find: 'with care', with: 'carefully' })
  })
})

describe('applyEdit', () => {
  test('replace, insert and delete the last place a phrase occurs', async () => {
    expect(run('The cat sat. The cat ran.', 'Replace cat with dog.')).toBe('The cat sat. The dog ran.')
    expect(run('Run the tests', 'Insert all after run.')).toBe('Run all the tests')
    expect(run('Run the tests', 'Insert please before run.')).toBe('please Run the tests')
    expect(run('Run the slow tests now', 'Delete slow.')).toBe('Run the tests now')
    expect(run('Run the tests', 'Replace lint with check.')).toBe('ERROR Couldn’t find “lint”'.replace('’', "'"))
  })

  test('delete from the end: characters, words, sentences, lines', async () => {
    expect(run('Fix the bug in main', 'Delete last word.')).toBe('Fix the bug in')
    expect(run('Fix the bug in main', 'Delete the last two words.')).toBe('Fix the bug')
    expect(run('First one. Second one. Third one.', 'Delete last sentence.')).toBe('First one. Second one.')
    expect(run('Only one sentence here', 'Delete sentence.')).toBe('')
    expect(run('line one\nline two', 'Delete last line.')).toBe('line one')
    expect(run('abc', 'Delete 2 characters.')).toBe('a')
  })

  test('case changes and additions', async () => {
    expect(run('use swift ui here', 'Capitalize swift ui.')).toBe('use Swift Ui here')
    expect(run('call the api', 'Uppercase api.')).toBe('call the API')
    expect(run('First', 'New paragraph.')).toBe('First\n\n')
    expect(run('Say', 'Type send it')).toBe('Say send it')
  })
})

describe('EditHistory', () => {
  test('undo and redo walk back and forth over voice edits', async () => {
    const history = new EditHistory()
    history.record('a')
    history.record('a b')
    expect(history.undo('a b c')).toBe('a b')
    expect(history.undo('a b')).toBe('a')
    expect(history.undo('a')).toBeNull()
    expect(history.redo('a')).toBe('a b')
    history.record('a b')               // a new edit forgets what could be redone
    expect(history.redo('x')).toBeNull()
  })
})
