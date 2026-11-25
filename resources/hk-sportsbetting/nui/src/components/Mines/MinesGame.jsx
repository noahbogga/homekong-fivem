import { useState, useCallback } from 'react'
import { fetchNUI } from '../../utils/nui'
import { useNUIEvent } from '../../hooks/useNUI'
import { formatMoney } from '../../utils/helpers'
import './MinesGame.css'

export default function MinesGame({ config, balance }) {
  const [betAmount, setBetAmount] = useState(config?.minBet || 100)
  const [mineCount, setMineCount] = useState(3)
  const [gameActive, setGameActive] = useState(false)
  const [revealed, setRevealed] = useState({})
  const [currentMultiplier, setCurrentMultiplier] = useState(1)
  const [gemsFound, setGemsFound] = useState(0)
  const [gameOver, setGameOver] = useState(false)
  const [minePositions, setMinePositions] = useState([])

  useNUIEvent('minesResult', (data) => {
    if (data.hit) {
      setRevealed(prev => ({ ...prev, [data.index]: 'mine' }))
      setMinePositions(data.mines || [])
      setGameOver(true)
      setGameActive(false)
    } else {
      setRevealed(prev => ({ ...prev, [data.index]: 'gem' }))
      setCurrentMultiplier(data.multiplier)
      setGemsFound(prev => prev + 1)
    }
  })

  useNUIEvent('minesCashout', (data) => {
    setGameOver(true)
    setGameActive(false)
    setMinePositions(data.mines || [])
  })

  const startGame = useCallback(() => {
    if (gameActive || betAmount > balance) return
    setRevealed({})
    setGameOver(false)
    setMinePositions([])
    setCurrentMultiplier(1)
    setGemsFound(0)
    setGameActive(true)
    fetchNUI('casinoBet', {
      game: 'mines',
      action: 'start',
      amount: betAmount,
      mines: mineCount,
    })
  }, [gameActive, betAmount, balance, mineCount])

  const revealTile = useCallback((index) => {
    if (!gameActive || revealed[index] || gameOver) return
    fetchNUI('casinoBet', {
      game: 'mines',
      action: 'reveal',
      index: index,
    })
  }, [gameActive, revealed, gameOver])

  const cashout = useCallback(() => {
    if (!gameActive || gemsFound === 0) return
    fetchNUI('casinoBet', {
      game: 'mines',
      action: 'cashout',
    })
  }, [gameActive, gemsFound])

  const payout = (betAmount * currentMultiplier).toFixed(0)

  return (
    <div className="game-container">
      <div className="game-controls">
        <div className="input-group">
          <label>Bet Amount</label>
          <input
            type="number"
            value={betAmount}
            onChange={e => setBetAmount(Math.max(0, Number(e.target.value)))}
            disabled={gameActive}
          />
          <div className="bet-actions">
            <button disabled={gameActive} onClick={() => setBetAmount(prev => Math.max(config?.minBet || 100, Math.floor(prev / 2)))}>½</button>
            <button disabled={gameActive} onClick={() => setBetAmount(prev => Math.min(config?.maxBet || 50000, prev * 2))}>2×</button>
          </div>
        </div>

        <div className="input-group">
          <label>Mines ({mineCount})</label>
          <input
            type="range"
            min="1"
            max="24"
            value={mineCount}
            onChange={e => setMineCount(Number(e.target.value))}
            disabled={gameActive}
            className="dice-slider"
          />
        </div>

        {gameActive && (
          <div className="mines-profit">
            <div className="mines-profit-label">Current Profit</div>
            <div className="mines-profit-value">
              {formatMoney(payout)} ({currentMultiplier.toFixed(2)}×)
            </div>
          </div>
        )}

        {!gameActive ? (
          <button
            className="btn-green bet-button"
            onClick={startGame}
            disabled={betAmount > balance}
          >
            Start Game
          </button>
        ) : (
          <button
            className="btn-primary bet-button"
            onClick={cashout}
            disabled={gemsFound === 0}
          >
            Cashout {formatMoney(payout)}
          </button>
        )}
      </div>

      <div className="game-area">
        <div className="mines-grid">
          {Array.from({ length: 25 }, (_, i) => {
            const state = revealed[i]
            const isMine = minePositions.includes(i)
            const showMine = gameOver && isMine && !state

            return (
              <button
                key={i}
                className={`mines-tile ${state || ''} ${showMine ? 'mine-reveal' : ''} ${!state && gameActive ? 'clickable' : ''}`}
                onClick={() => revealTile(i)}
                disabled={!gameActive || !!state || gameOver}
              >
                {state === 'gem' && (
                  <svg className="gem-icon anim-pop" viewBox="0 0 24 24" width="28" height="28">
                    <path d="M12 2L2 9l10 13 10-13L12 2z" fill="var(--accent)" />
                    <path d="M12 2L7 9h10L12 2z" fill="#00e5ff" opacity="0.7" />
                    <path d="M7 9l5 13 5-13H7z" fill="var(--accent)" opacity="0.8" />
                  </svg>
                )}
                {(state === 'mine' || showMine) && (
                  <svg className="bomb-icon anim-pop" viewBox="0 0 24 24" width="28" height="28">
                    <circle cx="12" cy="13" r="8" fill="#1a1a2e" />
                    <circle cx="12" cy="13" r="6" fill="#2d2d44" />
                    <rect x="11" y="2" width="2" height="5" rx="1" fill="#666" />
                    <circle cx="12" cy="2" r="2" fill="var(--red)" />
                    <circle cx="9" cy="11" r="1.5" fill="rgba(255,255,255,0.3)" />
                  </svg>
                )}
              </button>
            )
          })}
        </div>
      </div>
    </div>
  )
}
