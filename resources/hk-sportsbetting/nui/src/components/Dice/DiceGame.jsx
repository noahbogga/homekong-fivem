import { useState, useCallback, useRef } from 'react'
import { fetchNUI } from '../../utils/nui'
import { useNUIEvent } from '../../hooks/useNUI'
import { formatMoney } from '../../utils/helpers'
import './DiceGame.css'

export default function DiceGame({ config, balance }) {
  const [betAmount, setBetAmount] = useState(config?.minBet || 100)
  const [target, setTarget] = useState(50)
  const [mode, setMode] = useState('over')
  const [rolling, setRolling] = useState(false)
  const [result, setResult] = useState(null)
  const [history, setHistory] = useState([])
  const rollRef = useRef(null)

  const multiplier = mode === 'over'
    ? (100 / (100 - target) * (1 - (config?.houseEdge || 0.02))).toFixed(4)
    : (100 / target * (1 - (config?.houseEdge || 0.02))).toFixed(4)

  const winChance = mode === 'over' ? (100 - target) : target
  const payout = (betAmount * multiplier).toFixed(0)

  useNUIEvent('diceResult', (data) => {
    setRolling(false)
    setResult(data)
    setHistory(prev => [data, ...prev].slice(0, 20))
  })

  const placeBet = useCallback(() => {
    if (rolling || betAmount < (config?.minBet || 100)) return
    setRolling(true)
    setResult(null)
    fetchNUI('casinoBet', {
      game: 'dice',
      amount: betAmount,
      target: target,
      mode: mode,
    })
  }, [rolling, betAmount, target, mode, config])

  const getResultPosition = () => {
    if (!result) return null
    return result.roll
  }

  const resultPos = getResultPosition()
  const won = result?.won

  return (
    <div className="game-container">
      <div className="game-controls">
        <div className="input-group">
          <label>Bet Amount</label>
          <input
            type="number"
            value={betAmount}
            onChange={e => setBetAmount(Math.max(0, Number(e.target.value)))}
            min={config?.minBet || 100}
            max={config?.maxBet || 100000}
          />
          <div className="bet-actions">
            <button onClick={() => setBetAmount(prev => Math.max(config?.minBet || 100, Math.floor(prev / 2)))}>½</button>
            <button onClick={() => setBetAmount(prev => Math.min(config?.maxBet || 100000, prev * 2))}>2×</button>
            <button onClick={() => setBetAmount(config?.maxBet || 100000)}>Max</button>
          </div>
        </div>

        <div className="input-group">
          <label>Mode</label>
          <div className="dice-mode-toggle">
            <button
              className={mode === 'over' ? 'active' : ''}
              onClick={() => setMode('over')}
            >
              Over
            </button>
            <button
              className={mode === 'under' ? 'active' : ''}
              onClick={() => setMode('under')}
            >
              Under
            </button>
          </div>
        </div>

        <div className="input-group">
          <label>Target ({mode === 'over' ? '>' : '<'} {target.toFixed(2)})</label>
          <input
            type="range"
            min="2"
            max="98"
            step="1"
            value={target}
            onChange={e => setTarget(Number(e.target.value))}
            className="dice-slider"
          />
        </div>

        <div className="dice-stats">
          <div className="dice-stat">
            <span>Multiplier</span>
            <span className="multiplier-badge">{multiplier}×</span>
          </div>
          <div className="dice-stat">
            <span>Win Chance</span>
            <span>{winChance.toFixed(2)}%</span>
          </div>
          <div className="dice-stat">
            <span>Payout</span>
            <span className="text-green">{formatMoney(payout)}</span>
          </div>
        </div>

        <button
          className="btn-green bet-button"
          onClick={placeBet}
          disabled={rolling || betAmount > balance}
        >
          {rolling ? 'Rolling...' : 'Roll Dice'}
        </button>
      </div>

      <div className="game-area">
        <div className="dice-display">
          <div className="dice-track">
            <div
              className="dice-target-zone"
              style={mode === 'over'
                ? { left: `${target}%`, right: '0%' }
                : { left: '0%', right: `${100 - target}%` }
              }
            />
            <div
              className="dice-target-line"
              style={{ left: `${target}%` }}
            />
            {resultPos !== null && (
              <div
                className={`dice-result-marker ${won ? 'win' : 'loss'} ${rolling ? '' : 'anim-pop'}`}
                style={{ left: `${resultPos}%` }}
                ref={rollRef}
              >
                <span>{resultPos.toFixed(2)}</span>
              </div>
            )}
          </div>
          <div className="dice-track-labels">
            <span>0</span>
            <span>25</span>
            <span>50</span>
            <span>75</span>
            <span>100</span>
          </div>

          {result && !rolling && (
            <div className={`dice-result-banner ${won ? 'win' : 'loss'} anim-fade`}>
              <span className="result-roll">{result.roll.toFixed(2)}</span>
              <span className="result-text">
                {won ? `Won ${formatMoney(result.payout)}` : 'Busted'}
              </span>
            </div>
          )}
        </div>

        <div className="dice-history">
          {history.map((h, i) => (
            <div key={i} className={`dice-history-item ${h.won ? 'win' : 'loss'}`}>
              {h.roll.toFixed(1)}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
