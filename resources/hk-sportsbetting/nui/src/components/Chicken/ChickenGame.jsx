import { useState, useCallback } from 'react'
import { fetchNUI } from '../../utils/nui'
import { useNUIEvent } from '../../hooks/useNUI'
import { formatMoney } from '../../utils/helpers'
import './ChickenGame.css'

const COLS = 4
const ROWS = 10

export default function ChickenGame({ config, balance }) {
  const [betAmount, setBetAmount] = useState(config?.minBet || 100)
  const [gameActive, setGameActive] = useState(false)
  const [currentRow, setCurrentRow] = useState(-1)
  const [revealed, setRevealed] = useState({})
  const [chickenCol, setChickenCol] = useState(null)
  const [gameOver, setGameOver] = useState(false)
  const [won, setWon] = useState(false)
  const [currentMultiplier, setCurrentMultiplier] = useState(1)
  const [bonePositions, setBonePositions] = useState([])

  const getMultiplier = (row) => {
    const edge = config?.houseEdge || 0.03
    return ((COLS / (COLS - 1)) ** (row + 1) * (1 - edge)).toFixed(2)
  }

  useNUIEvent('chickenResult', (data) => {
    if (data.hit) {
      setRevealed(prev => ({ ...prev, [`${data.row}-${data.col}`]: 'bone' }))
      setBonePositions(data.bones || [])
      setGameOver(true)
      setGameActive(false)
      setWon(false)
    } else {
      setRevealed(prev => ({ ...prev, [`${data.row}-${data.col}`]: 'safe' }))
      setCurrentRow(data.row)
      setChickenCol(data.col)
      setCurrentMultiplier(data.multiplier)
    }
  })

  useNUIEvent('chickenCashout', (data) => {
    setGameOver(true)
    setGameActive(false)
    setWon(true)
    setBonePositions(data.bones || [])
  })

  const startGame = useCallback(() => {
    if (gameActive || betAmount > balance) return
    setRevealed({})
    setGameOver(false)
    setWon(false)
    setBonePositions([])
    setCurrentRow(-1)
    setChickenCol(null)
    setCurrentMultiplier(1)
    setGameActive(true)
    fetchNUI('casinoBet', {
      game: 'chicken',
      action: 'start',
      amount: betAmount,
    })
  }, [gameActive, betAmount, balance])

  const pickColumn = useCallback((col) => {
    if (!gameActive || gameOver) return
    const nextRow = currentRow + 1
    if (nextRow >= ROWS) return
    fetchNUI('casinoBet', {
      game: 'chicken',
      action: 'pick',
      col: col,
    })
  }, [gameActive, gameOver, currentRow])

  const cashout = useCallback(() => {
    if (!gameActive || currentRow < 0) return
    fetchNUI('casinoBet', {
      game: 'chicken',
      action: 'cashout',
    })
  }, [gameActive, currentRow])

  const payout = (betAmount * currentMultiplier).toFixed(0)
  const nextRow = currentRow + 1

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

        {gameActive && currentRow >= 0 && (
          <div className="mines-profit">
            <div className="mines-profit-label">Row {currentRow + 1} / {ROWS}</div>
            <div className="mines-profit-value">
              {currentMultiplier.toFixed(2)}× ({formatMoney(payout)})
            </div>
          </div>
        )}

        {!gameActive ? (
          <button
            className="btn-green bet-button"
            onClick={startGame}
            disabled={betAmount > balance}
          >
            Start Crossing
          </button>
        ) : (
          <button
            className="btn-primary bet-button"
            onClick={cashout}
            disabled={currentRow < 0}
          >
            Cashout {formatMoney(payout)}
          </button>
        )}

        <div className="chicken-multipliers">
          {Array.from({ length: ROWS }, (_, i) => (
            <div key={i} className={`chicken-mult-row ${i <= currentRow ? 'cleared' : ''} ${i === nextRow ? 'next' : ''}`}>
              <span>Row {i + 1}</span>
              <span className="multiplier-badge">{getMultiplier(i)}×</span>
            </div>
          )).reverse()}
        </div>
      </div>

      <div className="game-area">
        <div className="chicken-grid">
          {Array.from({ length: ROWS }, (_, row) => (
            <div key={row} className={`chicken-row ${row <= currentRow ? 'cleared' : ''} ${row === nextRow && gameActive ? 'active-row' : ''}`}>
              {Array.from({ length: COLS }, (_, col) => {
                const key = `${row}-${col}`
                const state = revealed[key]
                const isChicken = row === currentRow && col === chickenCol
                const isBone = gameOver && bonePositions[row] === col && !state
                const isNextRow = row === nextRow && gameActive && !gameOver

                return (
                  <button
                    key={col}
                    className={`chicken-tile ${state || ''} ${isChicken ? 'chicken-here' : ''} ${isBone ? 'bone-reveal' : ''} ${isNextRow ? 'pickable' : ''}`}
                    onClick={() => isNextRow && pickColumn(col)}
                    disabled={!isNextRow}
                  >
                    {isChicken && <span className="chicken-sprite anim-pop">🐔</span>}
                    {state === 'bone' && <span className="bone-sprite anim-pop">🦴</span>}
                    {state === 'safe' && !isChicken && <span className="footprint">🐾</span>}
                    {isBone && <span className="bone-sprite anim-pop">🦴</span>}
                  </button>
                )
              })}
            </div>
          )).reverse()}
        </div>

        {gameOver && (
          <div className={`chicken-result ${won ? 'win' : 'loss'} anim-fade`}>
            {won ? `Cashed Out ${formatMoney(payout)}!` : 'Hit a bone! Game Over'}
          </div>
        )}
      </div>
    </div>
  )
}
