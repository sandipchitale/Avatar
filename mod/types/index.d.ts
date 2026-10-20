declare module 'claude-code' {
  interface PluginState {
    presence: {
      /** Replies are spoken in this session (`/presence on|off`). */
      voice: boolean
      /** The mic is on for this session (`/presence mic on|off`, or Avatar's Mic button). */
      mic: boolean
      /** How the ears are: listening, preparing, off, or why not. */
      ears: string
      /** What is being heard now (interim), for the band above the prompt. */
      hearing: string | null
    }
  }
}
