import { useState, useEffect, useCallback } from 'react'
import { useNUIVisibility, useNUIEvent } from './hooks/useNUI'
import { fetchNUI } from './utils/nui'
import Sidebar from './components/Sidebar/Sidebar'
import Home from './components/Home/Home'
import DiceGame from './components/Dice/DiceGame'
import MinesGame from './components/Mines/MinesGame'
import ChickenGame from './components/Chicken/ChickenGame'
import CrashGame from './components/Crash/CrashGame'
import PlinkoGame from './components/Plinko/PlinkoGame'
import SportsView from './components/Sports/SportsView'
import BetSlip from './components/BetSlip/BetSlip'
import MyBets from './components/MyBets/MyBets'

export default function App() {
  const visible = useNUIVisibility()
  const [page, setPage] = useState('home')
  const [categories, setCategories] = useState([])
  const [casinoConfig, setCasinoConfig] = useState({})
  const [betSlip, setBetSlip] = useState([])
  const [slipMode, setSlipMode] = useState('single')
  const [balance, setBalance] = useState(0)

  useNUIEvent('categories', (data) => {
    setCategories(data.categories || [])
    setCasinoConfig(data.casino || {})
  })

  useNUIEvent('balance', (data) => {
    setBalance(data.balance || 0)
  })

  useEffect(() => {
    if (visible) {
      fetchNUI('getCategories')
      fetchNUI('getBalance')
    }
  }, [visible])

  useEffect(() => {
    const handleKey = (e) => {
      if (e.key === 'Escape' && visible) {
        fetchNUI('closeUI')
      }
    }
    window.addEventListener('keydown', handleKey)
    return () => window.removeEventListener('keydown', handleKey)
  }, [visible])

  const addToSlip = useCallback((selection) => {
    setBetSlip(prev => {
      if (prev.find(s => s.id === selection.id)) return prev
      return [...prev, selection]
    })
  }, [])

  const removeFromSlip = useCallback((id) => {
    setBetSlip(prev => prev.filter(s => s.id !== id))
  }, [])

  const clearSlip = useCallback(() => setBetSlip([]), [])

  if (!visible) return null

  const renderPage = () => {
    switch (page) {
      case 'home':
        return <Home setPage={setPage} />
      case 'dice':
        return <DiceGame config={casinoConfig.Dice} balance={balance} />
      case 'mines':
        return <MinesGame config={casinoConfig.Mines} balance={balance} />
      case 'chicken':
        return <ChickenGame config={casinoConfig.Chicken} balance={balance} />
      case 'crash':
        return <CrashGame config={casinoConfig.Crash} balance={balance} />
      case 'plinko':
        return <PlinkoGame config={casinoConfig.Plinko} balance={balance} />
      case 'mybets':
        return <MyBets />
      default:
        if (page.startsWith('sport:')) {
          return (
            <SportsView
              sportKey={page.replace('sport:', '')}
              categories={categories}
              addToSlip={addToSlip}
            />
          )
        }
        return <Home setPage={setPage} />
    }
  }

  return (
    <div className="steak-app">
      <Sidebar
        page={page}
        setPage={setPage}
        categories={categories}
        balance={balance}
      />
      <main className="steak-main">
        {renderPage()}
      </main>
      <BetSlip
        selections={betSlip}
        slipMode={slipMode}
        setSlipMode={setSlipMode}
        removeFromSlip={removeFromSlip}
        clearSlip={clearSlip}
        balance={balance}
      />
    </div>
  )
}
