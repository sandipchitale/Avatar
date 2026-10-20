// The avatar, as the mod sees it: `avatar-link attach` output split into events, and request bodies.
// The requests themselves (HTTP over the avatar's Unix socket) are made from register.tsx, where `$`
// lives. See Avatar/AvatarServers.swift for the routes.

/** One event `avatar-link attach` prints. */
export type AvatarEvent = {
  type: string
  reply?: string
  segment?: number
  /** The mod's own name for the segment, as it sent it with `/say`. */
  key?: string
  text?: string
  state?: string
  face?: string
}

/** Splits `avatar-link` output (pieces as written, not lines) into events. */
export class EventLines {
  private rest = ''

  push(text: string): AvatarEvent[] {
    this.rest += text
    const lines = this.rest.split('\n')
    this.rest = lines.pop() ?? ''
    const events: AvatarEvent[] = []
    for (const line of lines) {
      if (line.trim().length === 0) continue
      try {
        const event = JSON.parse(line) as unknown
        if (typeof event === 'object' && event !== null && typeof (event as AvatarEvent).type === 'string') {
          events.push(event as AvatarEvent)
        }
      } catch {
        // Not an event: ignore it.
      }
    }
    return events
  }
}

/** A request body: the session's name with the route's fields (undefined ones left out). */
export function requestBody(session: string, fields: Record<string, unknown>): string {
  const body: Record<string, unknown> = { session }
  for (const [key, value] of Object.entries(fields)) {
    if (value !== undefined) body[key] = value
  }
  return JSON.stringify(body)
}
