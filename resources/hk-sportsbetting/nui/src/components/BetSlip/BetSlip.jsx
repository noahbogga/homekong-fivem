import { useState, useCallback } from 'react'
import { fetchNUI } from '../../utils/nui'
import { formatMoney, formatOdds } from '../../utils/helpers'
import './BetSlip.css'

export default function BetSlip({ selections, slipMode, setSlipMode, removeFromSlip, clearSlip, balance }) {
  const [stakes, setStakes] = useState({})
  const [multiStake, setMultiStake] = useState(100)

  const setStake = (id, amount) => {
    setStakes(prev => ({ ...prev, [id]: amount }))
  }

  const totalOdds = selections.reduce((acc, s) => acc * s.odds, 1)
  const multiPayout = (multiStake * totalOdds).toFixed(0)

  const placeSingleBets = useCallback(() => {
    selections.forEach(sel => {
      const stake = stakes[sel.id] || 100
      if (stake > 0 && stake <= balance) {
        fetchNUI('placeBet', {
          type: 'single',
          eventId: sel.eventId,
          sportKey: sel.sportKey,
          match: sel.match,
          market: sel.market,
          selection: sel.selection,
          odds: sel.odds,
          point: sel.point,
          amount: stake,
        })
      }
    })
    clearSlip()
    setStakes({})
  }, [selections, stakes, balance, clearSlip])

  const placeMultiBet = useCallback(() => {
    if (selections.length < 2 || multiStake > balance) return
    fetchNUI('placeBet', {
      type: 'multi',
      selections: selections.map(s => ({
        eventId: s.eventId,
        sportKey: s.sportKey,
        match: s.match,
        market: s.market,
        selection: s.selection,
        odds: s.odds,
        point: s.point,
      })),
      amount: multiStake,
    })
    clearSlip()
  }, [selections, multiStake, balance, clearSlip])

  if (selections.length === 0) {
    return (
      <aside className="betslip empty">
        <div className="betslip-header">
          <h3>Bet Slip</h3>
        </div>
        <div className="betslip-empty">
          <p>Select odds to add to slip</p>
        </div>
      </aside>
    )
  }

  return (
    <aside className="betslip">
      <div className="betslip-header">
        <h3>Bet Slip ({selections.length})</h3>
        <button className="betslip-clear" onClick={clearSlip}>Clear</button>
      </div>

      <div className="betslip-mode-toggle">
        <button className={slipMode === 'single' ? 'active' : ''} onClick={() => setSlipMode('single')}>Single</button>
        <button className={slipMode === 'multi' ? 'active' : ''} onClick={() => setSlipMode('multi')} disabled={selections.length < 2}>
          Multi ({selections.length})
        </button>
      </div>

      <div className="betslip-selections">
        {selections.map(sel => (
          <div key={sel.id} className="betslip-item">
            <div className="betslip-item-header">
              <span className="betslip-item-sel">{sel.selection}</span>
              <button className="betslip-item-remove" onClick={() => removeFromSlip(sel.id)}>×</button>
            </div>
            <div className="betslip-item-match">{sel.match}</div>
            <div className="betslip-item-odds">{formatOdds(sel.odds)}</div>
            {slipMode === 'single' && (
              <input
                type="number"
                className="betslip-stake"
                value={stakes[sel.id] || ''}
                onChange={e => setStake(sel.id, Number(e.target.value))}
                placeholder="Stake"
              />
            )}
          </div>
        ))}
      </div>

      {slipMode === 'multi' && selections.length >= 2 && (
        <div className="betslip-multi">
          <div className="betslip-multi-odds">
            <span>Total Odds</span>
            <span className="multiplier-badge">{formatOdds(totalOdds)}</span>
          </div>
          <input
            type="number"
            className="betslip-stake"
            value={multiStake}
            onChange={e => setMultiStake(Number(e.target.value))}
            placeholder="Multi stake"
          />
          <div className="betslip-payout">Payout: {formatMoney(multiPayout)}</div>
        </div>
      )}

      <button
        className="btn-green betslip-place"
        onClick={slipMode === 'single' ? placeSingleBets : placeMultiBet}
      >
        Place {slipMode === 'single' ? 'Bets' : 'Multi Bet'}
      </button>
    </aside>
  )
}
