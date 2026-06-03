import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// GitHub Pages deployment lives at https://biliboss.github.io/agent-tts/
// Override with the SITE / BASE env vars for staging or custom domains.
const SITE = process.env.SITE || 'https://biliboss.github.io';
const BASE = process.env.BASE || '/agent-tts';

export default defineConfig({
  site: SITE,
  base: BASE,
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'agent-tts',
      description: 'Global Zig CLI for Pt-BR TTS on macOS. KPI: time-to-first-audio.',
      customCss: ['./src/styles/custom.css'],
      social: {
        github: 'https://github.com/biliboss/agent-tts',
      },
      editLink: {
        baseUrl: 'https://github.com/biliboss/agent-tts/edit/main/',
      },
      sidebar: [
        { label: 'Overview', link: '/' },
        { label: 'Architecture', link: '/arquitetura/' },
        { label: 'TTS engine', link: '/motor/' },
        { label: 'Roadmap', link: '/roadmap/' },
        { label: 'Changelog', link: '/changelog/' },
      ],
    }),
  ],
});
