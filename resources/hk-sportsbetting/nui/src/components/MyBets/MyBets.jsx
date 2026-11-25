import { useState, useEffect } from 'react'
import { fetchNUI } from '../../utils/nui'
import { useNUIEvent } from '../../hooks/useNUI'
import { formatMoney } from '../../utils/helpers'
import './MyBets.css'

export default function MyBets() {
  const [tab, setTab] = useState('sports')
  const [stats, setStats] = useState(null)
  const [loading, setLoading] = useState(true)

  useNUIEvent('myStats', (data) => {
    setStats(data)
    setLoading(false)
  })

  useEffect(() => {
    fetchNUI('getMyStats')
  }, [])

  const clearStats = () => {
    fetchNUI('clearStats')
    setStats(prev => prev ? { ...prev, totalWagered: 0, totalWon: 0, sportsBets: [], casinoBets: [] } : null)
  }

  if (loading) {
    return <div className="sports-loading"><div className="spinner" /><span>Loading stats...</span></div>
  }

  const vip = stats?.vip || {}
  const vipProgress = vip.nextXP ? ((vip.xp - vip.currentXP) / (vip.nextXP - vip.currentXP) * 100) : 100

  return (
    <div className="mybets">
      <div className="mybets-vip panel">
        <div className="vip-header">
          <span className="vip-level" style={{ color: vip.color }}>{vip.name || 'Bronze III'}</span>
          <span className="vip-xp">{(vip.xp || 0).toLocaleString()} XP</span>
        </div>
        <div className="vip-bar">
          <div className="vip-bar-fill" style={{ width: `${vipProgress}%`, background: vip.color || '#cd7f32' }} />
        </div>
        {vip.nextName && (
          <div className="vip-next">Next: {vip.nextName} ({(vip.nextXP || 0).toLocaleString()} XP)</div>
        )}
      </div>

      <div className="mybets-tabs">
        <button className={tab === 'sports' ? 'active' : ''} onClick={() => setTab('sports')}>Sports</button>
        <button className={tab === 'casino' ? 'active' : ''} onClick={() => setTab('casino')}>Casino</button>
        <button className={tab === 'stats' ? 'active' : ''} onClick={() => setTab('stats')}>Stats</button>
      </div>

      {tab === 'stats' && (
        <div className="mybets-stats panel">
          <div className="stats-grid">
            <div className="stat-card">
              <span className="stat-label">Total Wagered</span>
              <span className="stat-value">{formatMoney(stats?.totalWagered || 0)}</span>
            </div>
            <div className="stat-card">
              <span className="stat-label">Total Won</span>
              <span className="stat-value text-green">{formatMoney(stats?.totalWon || 0)}</span>
            </div>
            <div className="stat-card">
              <span className="stat-label">Sports Bets</span>
              <span className="stat-value">{stats?.sportsBetCount || 0}</span>
            </div>
            <div className="stat-card">
              <span className="stat-label">Casino Bets</span>
              <span className="stat-value">{stats?.casinoBetCount || 0}</span>
            </div>
            <div className="stat-card">
              <span className="stat-label">Net Profit</span>
              <span className={`stat-value ${(stats?.totalWon || 0) - (stats?.totalWagered || 0) >= 0 ? 'text-green' : 'text-red'}`}>
                {formatMoney((stats?.totalWon || 0) - (stats?.totalWagered || 0))}
              </span>
            </div>
            <div className="stat-card">
              <span className="stat-label">Win Rate</span>
              <span className="stat-value">{stats?.winRate || '0'}%</span>
            </div>
          </div>
          <button className="btn-clear-stats" onClick={clearStats}>Clear Stats</button>
        </div>
      )}

      {tab === 'sports' && (
        <div className="mybets-list">
          {(stats?.sportsBets || []).length === 0 ? (
            <div className="mybets-empty">No sports bets yet</div>
          ) : (
            (stats?.sportsBets || []).map((bet, i) => (
              <div key={i} className={`bet-item ${bet.status}`}>
                <div className="bet-item-match">{bet.match}</div>
                <div className="bet-item-sel">{bet.selection} @ {formatOdds(bet.odds)}</div>
                <div className="bet-item-footer">
                  <span>{formatMoney(bet.amount)}</span>
                  <span className={`bet-status ${bet.status}`}>{bet.status}</span>
                </div>
              </div>
            ))
          )}
        </div>
      )}

      {tab === 'casino' && (
        <div className="mybets-list">
          {(stats?.casinoBets || []).length === 0 ? (
            <div className="mybets-empty">No casino bets yet</div>
          ) : (
            (stats?.casinoBets || []).map((bet, i) => (
              <div key={i} className={`bet-item ${bet.won ? 'won' : 'lost'}`}>
                <div className="bet-item-match">{bet.game}</div>
                <div className="bet-item-footer">
                  <span>Stake: {formatMoney(bet.amount)}</span>
                  <span className={bet.won ? 'text-green' : 'text-red'}>
                    {bet.won ? `+${formatMoney(bet.payout)}` : `-${formatMoney(bet.amount)}`}
                  </span>
                </div>
              </div>
            ))
          )}
        </div>
      )}
    </div>
  )
}

function formatOdds(n) {
  return Number(n).toFixed(2)
}
