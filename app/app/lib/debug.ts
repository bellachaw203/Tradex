/**
 * Development-only tracing.
 *
 * The order-flow path (TEE → proof → contract invoke) is hard to debug without
 * a trace, but those logs must never ship: they run in the user's browser and
 * echo commitments and note material. `debug()` compiles down to a no-op call
 * in production builds, and `no-console` in eslint.config.js keeps raw
 * `console.log` out of the codebase.
 */
export function debug(...args: unknown[]): void {
  if (import.meta.env.DEV) {
    // eslint-disable-next-line no-console
    console.log(...args)
  }
}
