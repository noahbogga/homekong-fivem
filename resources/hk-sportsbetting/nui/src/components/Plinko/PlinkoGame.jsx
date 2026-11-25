import { useState, useCallback, useRef, useEffect } from 'react'
import Matter from 'matter-js'
import { fetchNUI } from '../../utils/nui'
import { useNUIEvent } from '../../hooks/useNUI'
import { formatMoney } from '../../utils/helpers'
import './PlinkoGame.css'

const ROWS = 12
const BUCKET_MULTIPLIERS = [10, 5, 3, 1.5, 1, 0.5, 0.3, 0.5, 1, 1.5, 3, 5, 10]

export default function PlinkoGame({ config, balance }) {
  const [betAmount, setBetAmount] = useState(100)
  const [risk, setRisk] = useState('medium')
  const [lastResult, setLastResult] = useState(null)
  const [history, setHistory] = useState([])
  const canvasRef = useRef(null)
  const engineRef = useRef(null)
  const renderRef = useRef(null)
  const runnerRef = useRef(null)
  const ballsRef = useRef([])

  const getMultipliers = () => {
    if (risk === 'low') return [5, 2, 1.5, 1.2, 1, 0.5, 0.3, 0.5, 1, 1.2, 1.5, 2, 5]
    if (risk === 'high') return [50, 10, 5, 3, 1.5, 0.5, 0.2, 0.5, 1.5, 3, 5, 10, 50]
    return BUCKET_MULTIPLIERS
  }

  useEffect(() => {
    if (!canvasRef.current) return

    const { Engine, Render, Runner, Bodies, Composite, Events } = Matter

    const engine = Engine.create({ gravity: { x: 0, y: 1.2 } })
    engineRef.current = engine

    const canvas = canvasRef.current
    const width = 560
    const height = 450

    const render = Render.create({
      canvas,
      engine,
      options: {
        width,
        height,
        background: 'transparent',
        wireframes: false,
        pixelRatio: 2,
      },
    })
    renderRef.current = render

    const pegs = []
    const pegRadius = 4
    const startY = 50
    const rowSpacing = (height - 120) / ROWS
    const centerX = width / 2

    for (let row = 0; row < ROWS; row++) {
      const cols = row + 3
      const rowWidth = cols * 35
      for (let col = 0; col < cols; col++) {
        const x = centerX - rowWidth / 2 + col * 35 + 17.5
        const y = startY + row * rowSpacing
        const peg = Bodies.circle(x, y, pegRadius, {
          isStatic: true,
          restitution: 0.5,
          render: { fillStyle: '#4a6577' },
        })
        pegs.push(peg)
      }
    }

    const walls = [
      Bodies.rectangle(0, height / 2, 10, height, { isStatic: true, render: { visible: false } }),
      Bodies.rectangle(width, height / 2, 10, height, { isStatic: true, render: { visible: false } }),
      Bodies.rectangle(width / 2, height + 20, width, 40, { isStatic: true, render: { visible: false } }),
    ]

    const buckets = []
    const bucketCount = ROWS + 1
    const bucketWidth = (width - 60) / bucketCount
    for (let i = 0; i <= bucketCount; i++) {
      const x = 30 + i * bucketWidth
      const divider = Bodies.rectangle(x, height - 25, 3, 30, {
        isStatic: true,
        render: { fillStyle: '#2f4553' },
      })
      buckets.push(divider)
    }

    Composite.add(engine.world, [...pegs, ...walls, ...buckets])

    Events.on(engine, 'afterUpdate', () => {
      ballsRef.current = ballsRef.current.filter(ball => {
        if (ball.position.y > height - 40) {
          const bucketIndex = Math.floor((ball.position.x - 30) / bucketWidth)
          const clampedIndex = Math.max(0, Math.min(bucketCount - 1, bucketIndex))
          Composite.remove(engine.world, ball)

          const mults = getMultipliers()
          const mult = mults[clampedIndex] || 1
          setLastResult({ bucket: clampedIndex, multiplier: mult })
          setHistory(prev => [mult, ...prev].slice(0, 15))
          return false
        }
        return true
      })
    })

    Render.run(render)
    const runner = Runner.create()
    Runner.run(runner, engine)
    runnerRef.current = runner

    return () => {
      Render.stop(render)
      Runner.stop(runner)
      Engine.clear(engine)
    }
  }, [])

  useNUIEvent('plinkoResult', (data) => {
    setLastResult(data)
    setHistory(prev => [data.multiplier, ...prev].slice(0, 15))
  })

  const dropBall = useCallback(() => {
    if (betAmount > balance || !engineRef.current) return

    const { Bodies, Composite } = Matter
    const offsetX = (Math.random() - 0.5) * 20
    const ball = Bodies.circle(280 + offsetX, 10, 8, {
      restitution: 0.6,
      friction: 0.1,
      density: 0.002,
      render: { fillStyle: '#00c8ff' },
    })

    ballsRef.current.push(ball)
    Composite.add(engineRef.current.world, ball)

    fetchNUI('casinoBet', {
      game: 'plinko',
      amount: betAmount,
      risk: risk,
    })
  }, [betAmount, balance, risk])

  const multipliers = getMultipliers()

  return (
    <div className="game-container">
      <div className="game-controls">
        <div className="input-group">
          <label>Bet Amount</label>
          <input
            type="number"
            value={betAmount}
            onChange={e => setBetAmount(Math.max(0, Number(e.target.value)))}
          />
          <div className="bet-actions">
            <button onClick={() => setBetAmount(prev => Math.max(100, Math.floor(prev / 2)))}>½</button>
            <button onClick={() => setBetAmount(prev => Math.min(100000, prev * 2))}>2×</button>
          </div>
        </div>

        <div className="input-group">
          <label>Risk Level</label>
          <div className="dice-mode-toggle">
            <button className={risk === 'low' ? 'active' : ''} onClick={() => setRisk('low')}>Low</button>
            <button className={risk === 'medium' ? 'active' : ''} onClick={() => setRisk('medium')}>Med</button>
            <button className={risk === 'high' ? 'active' : ''} onClick={() => setRisk('high')}>High</button>
          </div>
        </div>

        <button
          className="btn-green bet-button"
          onClick={dropBall}
          disabled={betAmount > balance}
        >
          Drop Ball
        </button>

        {lastResult && (
          <div className="plinko-last-result">
            <span>Last: </span>
            <span className={`multiplier-badge ${lastResult.multiplier >= 2 ? 'good' : 'bad'}`}>
              {lastResult.multiplier}× ({formatMoney(betAmount * lastResult.multiplier)})
            </span>
          </div>
        )}

        <div className="crash-history">
          {history.map((h, i) => (
            <span key={i} className={`crash-history-item ${h >= 2 ? 'good' : 'bad'}`}>
              {h}×
            </span>
          ))}
        </div>
      </div>

      <div className="game-area plinko-area">
        <canvas ref={canvasRef} className="plinko-canvas" />
        <div className="plinko-buckets">
          {multipliers.map((m, i) => (
            <div
              key={i}
              className={`plinko-bucket ${m >= 5 ? 'high' : m >= 1.5 ? 'med' : 'low'} ${lastResult?.bucket === i ? 'hit anim-pop' : ''}`}
            >
              {m}×
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
