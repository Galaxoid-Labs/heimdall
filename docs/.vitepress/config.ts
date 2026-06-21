import { defineConfig } from 'vitepress'

// If deploying to https://<user>.github.io/heimdall/, keep base = '/heimdall/'.
// For a custom domain or <user>.github.io root, set base = '/'.
export default defineConfig({
  base: '/heimdall/',
  title: 'Heimdall',
  description: 'Native desktop apps with an Odin backend and a web frontend.',
  cleanUrls: true,
  lastUpdated: true,

  // NOTE: favicon href includes the base path — keep it in sync with `base`.
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/heimdall/favicon.svg' }],
    ['meta', { name: 'theme-color', content: '#e8b339' }],
  ],

  markdown: {
    // Shiki has no Odin grammar; Go is the closest C-family fallback so our
    // ```odin blocks still get comment/string/keyword highlighting.
    languageAlias: { odin: 'go' },
  },

  themeConfig: {
    logo: '/logo.svg',

    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Reference', link: '/reference/cli' },
      { text: 'Contributing', link: '/internals' },
    ],

    sidebar: {
      '/': [
        {
          text: 'Guide',
          items: [
            { text: 'Introduction', link: '/guide/introduction' },
            { text: 'Getting Started', link: '/guide/getting-started' },
            { text: 'Commands (invoke)', link: '/guide/commands' },
            { text: 'Events (emit / on)', link: '/guide/events' },
            { text: 'Window', link: '/guide/window' },
            { text: 'Menus', link: '/guide/menus' },
            { text: 'Deep linking', link: '/guide/deep-linking' },
            { text: 'Configuration', link: '/guide/configuration' },
            { text: 'Packaging & Signing', link: '/guide/packaging' },
            { text: 'CI / GitHub Actions', link: '/ci' },
          ],
        },
        {
          text: 'Reference',
          items: [{ text: 'CLI', link: '/reference/cli' }],
        },
        {
          text: 'Contributing',
          items: [
            { text: 'Internals', link: '/internals' },
            { text: 'Platform Notes', link: '/platform_notes' },
          ],
        },
      ],
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/galaxoid-labs/heimdall' },
    ],

    search: { provider: 'local' },

    editLink: {
      pattern: 'https://github.com/galaxoid-labs/heimdall/edit/main/docs/:path',
    },
  },
})
