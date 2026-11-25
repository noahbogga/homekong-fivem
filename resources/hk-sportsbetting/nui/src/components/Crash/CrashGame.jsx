import { useState, useCallback, useRef, useEffect } from 'react'
import { fetchNUI } from '../../utils/nui'
import { useNUIEvent } from '../../hooks/useNUI'
import { formatMoney } from '../../utils/helpers'
import './CrashGame.css'

export default function CrashGame({ config, balance }) {
  const [betAmount, setBetAmount] = useState(100)
  const [autoCashout, setAutoCashout] = useState(2.0)
  const [gameState, setGameState] = useState('idle')
  const [multiplier, setMultiplier] = useState(1.0)
  const [crashPoint, setCrashPoint] = useState(null)
  const [cashedOut, setCashedOut] = useState(false)
  const [cashoutMultiplier, setCashoutMultiplier] = useState(null)
  const [history, setHistory] = useState([])
  const canvasRef = useRef(null)
  const animRef = useRef(null)
  const startTimeRef = useRef(null)
  const crashPointRef = useRef(null)

  useNUIEvent('crashStart', (data) => {
    crashPointRef.current = data.crashPoint
    setCrashPoint(null)
    setCashedOut(false)
    setCashoutMultiplier(null)
    setMultiplier(1.0)
    setGameState('running')
    startTimeRef.current = Date.now()
    animateChart()
  })

  useNUIEvent('crashResult', (data) => {
    setGameState('crashed')
    setCrashPoint(data.crashPoint)
    setMultiplier(data.crashPoint)
    setHistory(prev => [data.crashPoint, ...prev].slice(0, 15))
    if (animRef.current) cancelAnimationFrame(animRef.current)
  })

  useNUIEvent('crashCashout', (data) => {
    setCashedOut(true)
    setCashoutMultiplier(data.multiplier)
  })

  const animateChart = useCallback(() => {
    const draw = () => {
      if (!startTimeRef.current || !canvasRef.current) return
      const elapsed = (Date.now() - startTimeRef.current) / 1000
      const mult = Math.pow(Math.E, 0.05 * elapsed)

      if (crashPointRef.current && mult >= crashPointRef.current) {
        setMultiplier(crashPointRef.current)
        setGameState('crashed')
        setCrashPoint(crashPointRef.current)
        setHistory(prev => [crashPointRef.current, ...prev].slice(0, 15))
        drawChart(crashPointRef.current, true)
        return
      }

      setMultiplier(mult)
      drawChart(mult, false)
      animRef.current = requestAnimationFrame(draw)
    }
    animRef.current = requestAnimationFrame(draw)
  }, [])

  const drawChart = (currentMult, crashed) => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    const w = canvas.width
    const h = canvas.height

    ctx.clearRect(0, 0, w, h)

    ctx.strokeStyle = 'rgba(255,255,255,0.05)'
    ctx.lineWidth = 1
    for (let i = 1; i < 5; i++) {
      const y = h - (h * i / 5)
      ctx.beginPath()
      ctx.moveTo(0, y)
      ctx.lineTo(w, y)
      ctx.stroke()
    }

    const elapsed = startTimeRef.current ? (Date.now() - startTimeRef.current) / 1000 : 1
    const points = []
    const steps = 100
    for (let i = 0; i <= steps; i++) {
      const t = (elapsed * i) / steps
      const m = Math.pow(Math.E, 0.05 * t)
      const x = (i / steps) * w
      const maxMult = Math.max(currentMult, 2)
      const y = h - ((m - 1) / (maxMult - 1)) * (h * 0.85)
      points.push({ x, y: Math.max(20, y) })
    }

    const gradient = ctx.createLinearGradient(0, h, 0, 0)
    if (crashed) {
      gradient.addColorStop(0, 'rgba(248, 113, 113, 0)')
      gradient.addColorStop(1, 'rgba(248, 113, 113, 0.2)')
    } else {
      gradient.addColorStop(0, 'rgba(0, 200, 255, 0)')
      gradient.addColorStop(1, 'rgba(0, 200, 255, 0.15)')
    }

    ctx.beginPath()
    ctx.moveTo(points[0].x, h)
    points.forEach(p => ctx.lineTo(p.x, p.y))
    ctx.lineTo(points[points.length - 1].x, h)
    ctx.closePath()
    ctx.fillStyle = gradient
    ctx.fill()

    ctx.beginPath()
    ctx.moveTo(points[0].x, points[0].y)
    points.forEach(p => ctx.lineTo(p.x, p.y))
    ctx.strokeStyle = crashed ? '#f87171' : '#00c8ff'
    ctx.lineWidth = 3
    ctx.stroke()

    const last = points[points.length - 1]
    ctx.beginPath()
    ctx.arc(last.x, last.y, 5, 0, Math.PI * 2)
    ctx.fillStyle = crashed ? '#f87171' : '#00c8ff'
    ctx.fill()
  }

  useEffect(() => {
    return () => {
      if (animRef.current) cancelAnimationFrame(animRef.current)
    }
  }, [])

  const placeBet = useCallback(() => {
    if (gameState !== 'idle' || betAmount > balance) return
    setGameState('waiting')
    fetchNUI('casinoBet', {
      game: 'crash',
      action: 'bet',
      amount: betAmount,
      autoCashout: autoCashout,
    })
  }, [gameState, betAmount, balance, autoCashout])

  const manualCashout = useCallback(() => {
    if (gameState !== 'running' || cashedOut) return
    fetchNUI('casinoBet', {
      game: 'crash',
      action: 'cashout',
    })
  }, [gameState, cashedOut])

  const payout = cashedOut
    ? (betAmount * cashoutMultiplier).toFixed(0)
    : (betAmount * multiplier).toFixed(0)

  return (
    <div className="game-container">
      <div className="game-controls">
        <div className="input-group">
          <label>Bet Amount</label>
          <input
            type="number"
            value={betAmount}
            onChange={e => setBetAmount(Math.max(0, Number(e.target.value)))}
            disabled={gameState !== 'idle'}
          />
          <div className="bet-actions">
            <button disabled={gameState !== 'idle'} onClick={() => setBetAmount(prev => Math.max(100, Math.floor(prev / 2)))}>½</button>
            <button disabled={gameState !== 'idle'} onClick={() => setBetAmount(prev => Math.min(100000, prev * 2))}>2×</button>
          </div>
        </div>

        <div className="input-group">
          <label>Auto Cashout</label>
          <input
            type="number"
            value={autoCashout}
            onChange={e => setAutoCashout(Math.max(1.01, Number(e.target.value)))}
            step="0.1"
            min="1.01"
            disabled={gameState !== 'idle'}
          />
        </div>

        {gameState === 'idle' && (
          <button
            className="btn-green bet-button"
            onClick={placeBet}
            disabled={betAmount > balance}
          >
            Place Bet
          </button>
        )}

        {gameState === 'running' && !cashedOut && (
          <button className="btn-primary bet-button crash-cashout-btn" onClick={manualCashout}>
            Cashout @ {multiplier.toFixed(2)}×
          </button>
        )}

        {cashedOut && (
          <div className="crash-cashed-out">
            Cashed out at {cashoutMultiplier.toFixed(2)}× — {formatMoney(payout)}
          </div>
        )}

        <div className="crash-history">
          {history.map((h, i) => (
            <span key={i} className={`crash-history-item ${h >= 2 ? 'good' : 'bad'}`}>
              {h.toFixed(2)}×
            </span>
          ))}
        </div>
      </div>

      <div className="game-area crash-area">
        <canvas
          ref={canvasRef}
          width={560}
          height={380}
          className="crash-canvas"
        />
        <div className={`crash-multiplier ${gameState === 'crashed' ? 'crashed' : ''} ${cashedOut ? 'cashed' : ''}`}>
          {gameState === 'crashed'
            ? `${crashPoint?.toFixed(2)}×`
            : gameState === 'running'
            ? `${multiplier.toFixed(2)}×`
            : 'Place a bet'
          }
        </div>
        {gameState === 'crashed' && (
          <div className="crash-bust-label anim-shake">BUSTED</div>
        )}
      </div>
    </div>
  )
}
