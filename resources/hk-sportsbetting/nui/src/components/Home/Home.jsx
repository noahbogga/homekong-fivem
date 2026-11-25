import { formatMoney } from '../../utils/helpers'
import './Home.css'

const casinoCards = [
  { id: 'dice', name: 'Dice', desc: 'Roll over or under', color: '#ff6b35' },
  { id: 'mines', name: 'Mines', desc: 'Find the gems', color: '#00c8ff' },
  { id: 'chicken', name: 'Chicken Road', desc: 'Cross the road', color: '#fbbf24' },
  { id: 'crash', name: 'Crash', desc: 'Cash out before bust', color: '#4ade80' },
  { id: 'plinko', name: 'Plinko', desc: 'Drop and win', color: '#a78bfa' },
]

export default function Home({ setPage }) {
  return (
    <div className="home">
      <div className="home-hero">
        <h1 className="home-title">STEAK<span>Casino</span></h1>
        <p className="home-subtitle">Sports betting & casino games</p>
      </div>

      <section className="home-section">
        <h2>Casino Games</h2>
        <div className="home-casino-grid">
          {casinoCards.map(game => (
            <button
              key={game.id}
              className="casino-card"
              onClick={() => setPage(game.id)}
              style={{ '--card-accent': game.color }}
            >
              <div className="casino-card-name">{game.name}</div>
              <div className="casino-card-desc">{game.desc}</div>
            </button>
          ))}
        </div>
      </section>

      <section className="home-section">
        <h2>Popular Sports</h2>
        <div className="home-sport-chips">
          <button className="sport-chip" onClick={() => setPage('sport:soccer_epl')}>Premier League</button>
          <button className="sport-chip" onClick={() => setPage('sport:soccer_spain_la_liga')}>La Liga</button>
          <button className="sport-chip" onClick={() => setPage('sport:soccer_germany_bundesliga')}>Bundesliga</button>
          <button className="sport-chip" onClick={() => setPage('sport:soccer_korea_kleague1')}>K-League</button>
          <button className="sport-chip" onClick={() => setPage('sport:basketball_wnba')}>WNBA</button>
          <button className="sport-chip" onClick={() => setPage('sport:mma_mixed_martial_arts')}>UFC / MMA</button>
        </div>
      </section>
    </div>
  )
}
