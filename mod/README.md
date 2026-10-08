# Presence (Claude Code mod)

Talk with Claude Code through the [Avatar](../README.md) app: replies spoken as they are written by a
face with lip sync, and your voice into the prompt box. Avatar's own window has the controls.

## Install

Avatar must be installed in `/Applications` (it is the face, the voice and the ears). Then load this
folder as a plugin:

```sh
claude --plugin-dir /path/to/Avatar/mod
```

or from GitHub: `/plugin marketplace add sandipchitale/Avatar` and `/plugin install presence@presence`.

## Use

Replies are spoken whenever Avatar is running (silent otherwise). Turn the mic on (the 🎙 button above the
prompt, Avatar's Mic button, or `/presence mic on`) and, between turns, what you say goes into the prompt box: edit it there with
the keyboard or by voice ("scratch that", "clear"), and say "send it" to send it. See the
[Avatar README](../README.md#using-it) for every command.

It works the same in the Claude desktop app's Code tab, with the desktop's own prompt box. A reply
written before Avatar attached (the desktop app starts its session with the first prompt) is spoken
once it attaches. Headless runs (`claude -p`, the Agent SDK) stay silent: Presence attaches only when
the terminal's REPL starts or a surface attaches.

## Options

| Option | Default | |
|---|---|---|
| `sendPhrase` | `send it` | Said on its own, sends the prompt box |
| `linkPath` | `/Applications/Avatar.app/Contents/MacOS/avatar-link` | Avatar's session handle |
| `socket` | (Avatar's) | Avatar's command socket |

## Development

`claude plugin validate .`, `claude plugin test .` (segmenter, voice commands, event parsing).
`hooks/register.tsx` is the module: attaching, speaking as replies stream, the face's state, and the
ears.
