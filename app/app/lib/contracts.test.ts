import { beforeEach, describe, expect, it } from 'vitest'
import {
  CONTRACT_IDS,
  DEFAULT_ASSET,
  TIF,
  crossMarginKey,
  generateNote,
  proofJsonToScVal,
  randomCommitment,
} from './contracts'

const HEX64 = /^[0-9a-f]{64}$/
const STELLAR_CONTRACT_ID = /^C[A-Z2-7]{55}$/

describe('note generation', () => {
  it('produces three distinct 32-byte hex values', () => {
    const note = generateNote()

    for (const value of [note.secret, note.commitment, note.nullifier]) {
      expect(value).toMatch(HEX64)
    }
    expect(new Set([note.secret, note.commitment, note.nullifier]).size).toBe(3)
  })

  it('does not repeat across calls', () => {
    const commitments = new Set(Array.from({ length: 32 }, () => randomCommitment()))
    expect(commitments.size).toBe(32)
  })
})

describe('crossMarginKey', () => {
  beforeEach(() => {
    localStorage.clear()
  })

  it('derives a stable per-wallet key', () => {
    const first = crossMarginKey('GABC')
    expect(first).toMatch(HEX64)
    expect(crossMarginKey('GABC')).toBe(first)
  })

  it('uses a different key per wallet', () => {
    expect(crossMarginKey('GABC')).not.toBe(crossMarginKey('GXYZ'))
  })
})

describe('proofJsonToScVal', () => {
  it('maps a TEE proof into the on-chain Groth16Proof shape', () => {
    const proof = JSON.stringify({
      a: '00'.repeat(64),
      b: '11'.repeat(128),
      c: '22'.repeat(64),
    })

    const entries = proofJsonToScVal(proof).map()
    expect(entries).not.toBeNull()
    expect(entries).toHaveLength(3)

    const byKey = Object.fromEntries(
      entries!.map((e) => [e.key().sym().toString(), e.val().bytes().length])
    )
    // The contract expects Bytes(64) / Bytes(128) / Bytes(64).
    expect(byKey).toEqual({ a: 64, b: 128, c: 64 })
  })

  it('rejects malformed proof JSON', () => {
    expect(() => proofJsonToScVal('nope')).toThrow()
  })
})

describe('protocol constants', () => {
  it('keeps TimeInForce in sync with the contract repr(u32)', () => {
    expect(TIF).toEqual({ GTC: 0, IOC: 1, FOK: 2, GTD: 3 })
  })

  it('uses a 32-byte zero default asset', () => {
    expect(DEFAULT_ASSET).toMatch(/^0{64}$/)
  })

  it('resolves every contract id to a valid Stellar contract address', () => {
    for (const [name, id] of Object.entries(CONTRACT_IDS)) {
      expect(id, `${name} is not a valid contract id`).toMatch(STELLAR_CONTRACT_ID)
    }
  })
})
