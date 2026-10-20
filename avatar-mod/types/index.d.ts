declare module 'claude-code' {
  interface PluginState {
    avatar: {
      /** Replies are spoken in this session (`/avatar on|off`). */
      voice: boolean
      /** The mic is on for this session (`/avatar mic on|off`, or Avatar's Mic button). */
      mic: boolean
      /** How the ears are: listening, preparing, off, or why not. */
      ears: string
      /** What is being heard now (interim), for the band above the prompt. */
      hearing: string | null
    }
  }
}
