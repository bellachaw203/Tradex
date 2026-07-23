// Flat ESLint config for the Tradex frontend.
//
// CI runs `npm run lint` which is `eslint . --max-warnings=0`, so every rule
// enabled here is effectively an error. Rules that would require a large
// refactor of existing code are documented and disabled rather than silently
// downgraded to warnings.
import js from '@eslint/js'
import globals from 'globals'
import tseslint from 'typescript-eslint'
import reactHooks from 'eslint-plugin-react-hooks'
import unusedImports from 'eslint-plugin-unused-imports'
import prettier from 'eslint-config-prettier'

export default tseslint.config(
  {
    // Never lint generated or vendored output.
    ignores: [
      'build/**',
      'dist/**',
      '.react-router/**',
      'node_modules/**',
      'public/**',
      'coverage/**',
      'next-env.d.ts',
    ],
  },

  js.configs.recommended,
  ...tseslint.configs.recommended,

  {
    files: ['**/*.{ts,tsx,js,jsx}'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: { ...globals.browser, ...globals.node },
    },
    plugins: {
      'react-hooks': reactHooks,
      'unused-imports': unusedImports,
    },
    rules: {
      // ── Dead code / unused imports ────────────────────────────────
      // The base rules are turned off in favour of the plugin, which can
      // distinguish an unused *import* from an unused *variable*.
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': 'off',
      'unused-imports/no-unused-imports': 'error',
      'unused-imports/no-unused-vars': [
        'error',
        {
          vars: 'all',
          varsIgnorePattern: '^_',
          args: 'after-used',
          argsIgnorePattern: '^_',
          caughtErrors: 'all',
          caughtErrorsIgnorePattern: '^_',
        },
      ],

      // ── React correctness ─────────────────────────────────────────
      'react-hooks/rules-of-hooks': 'error',
      // exhaustive-deps flags a large amount of intentionally-partial
      // dependency lists in the existing trading UI. Left off so the gate
      // stays meaningful; re-enable once those hooks are audited.
      'react-hooks/exhaustive-deps': 'off',

      // ── Lightweight SAST-style rules ──────────────────────────────
      // These catch the JS-side injection primitives that a dedicated SAST
      // tool would flag; Semgrep in security.yml covers the rest.
      'no-eval': 'error',
      'no-implied-eval': 'error',
      'no-new-func': 'error',
      'no-script-url': 'error',
      'no-console': ['error', { allow: ['warn', 'error'] }],
      'no-debugger': 'error',
      'no-alert': 'error',

      // ── TypeScript ergonomics ─────────────────────────────────────
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/ban-ts-comment': [
        'error',
        { 'ts-expect-error': 'allow-with-description' },
      ],
    },
  },

  {
    // Config files and tests run in Node and may log freely.
    files: ['*.config.{ts,js}', '**/*.test.{ts,tsx}', 'tests/**/*'],
    languageOptions: { globals: { ...globals.node } },
    rules: { 'no-console': 'off' },
  },

  // Must stay last: disables every stylistic rule Prettier owns.
  prettier
)
