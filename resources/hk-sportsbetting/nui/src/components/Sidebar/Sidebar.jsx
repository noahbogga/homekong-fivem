import { formatMoney } from '../../utils/helpers'
import './Sidebar.css'

const casinoGames = [
  { id: 'dice', label: 'Dice', icon: '🎲' },
  { id: 'mines', label: 'Mines', icon: '💎' },
  { id: 'chicken', label: 'Chicken Road', icon: '🐔' },
  { id: 'crash', label: 'Crash', icon: '📈' },
  { id: 'plinko', label: 'Plinko', icon: '⚪' },
]

export default function Sidebar({ page, setPage, categories, balance }) {
  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <h1 className="sidebar-brand">STEAK</h1>
        <span className="sidebar-balance">{formatMoney(balance)}</span>
      </div>

      <nav className="sidebar-nav">
        <button
          className={`nav-item ${page === 'home' ? 'active' : ''}`}
          onClick={() => setPage('home')}
        >
          <span className="nav-icon">🏠</span>
          <span>Home</span>
        </button>

        <div className="nav-section">Casino</div>
        {casinoGames.map(game => (
          <button
            key={game.id}
            className={`nav-item ${page === game.id ? 'active' : ''}`}
            onClick={() => setPage(game.id)}
          >
            <span className="nav-icon">{game.icon}</span>
            <span>{game.label}</span>
          </button>
        ))}

        <div className="nav-section">Sports</div>
        {categories.map(cat => (
          <div key={cat.id}>
            <div className="nav-category">{cat.label}</div>
            {cat.sports.map(sport => (
              <button
                key={sport.key}
                className={`nav-item nav-sub ${page === `sport:${sport.key}` ? 'active' : ''}`}
                onClick={() => setPage(`sport:${sport.key}`)}
              >
                <span>{sport.label}</span>
              </button>
            ))}
          </div>
        ))}

        <div className="nav-section">Account</div>
        <button
          className={`nav-item ${page === 'mybets' ? 'active' : ''}`}
          onClick={() => setPage('mybets')}
        >
          <span className="nav-icon">📋</span>
          <span>My Bets</span>
        </button>
      </nav>
    </aside>
  )
}
