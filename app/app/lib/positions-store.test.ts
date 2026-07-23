import { beforeEach, describe, expect, it } from 'vitest'
import { positionsStore, type StoredPosition } from './positions-store'

const position = (commitment: string): StoredPosition => ({
  commitment,
  symbol: 'BTC-PERP',
  side: 0,
  leverage: 10,
  openedAt: 1_700_000_000_000,
})

describe('positionsStore', () => {
  beforeEach(() => {
    localStorage.clear()
  })

  it('starts empty', () => {
    expect(positionsStore.all()).toEqual([])
  })

  it('persists an added position', () => {
    positionsStore.add(position('a'.repeat(64)))
    expect(positionsStore.all()).toHaveLength(1)
    expect(positionsStore.all()[0].symbol).toBe('BTC-PERP')
  })

  it('is idempotent for the same commitment', () => {
    positionsStore.add(position('b'.repeat(64)))
    positionsStore.add(position('b'.repeat(64)))
    expect(positionsStore.all()).toHaveLength(1)
  })

  it('removes only the matching commitment', () => {
    positionsStore.add(position('c'.repeat(64)))
    positionsStore.add(position('d'.repeat(64)))
    positionsStore.remove('c'.repeat(64))

    const remaining = positionsStore.all()
    expect(remaining).toHaveLength(1)
    expect(remaining[0].commitment).toBe('d'.repeat(64))
  })

  it('survives corrupted storage instead of throwing', () => {
    localStorage.setItem('cerp_positions', '{not json')
    expect(positionsStore.all()).toEqual([])
  })

  it('returns every local position for any wallet', () => {
    positionsStore.add(position('e'.repeat(64)))
    expect(positionsStore.forWallet('GABC')).toHaveLength(1)
  })
})
