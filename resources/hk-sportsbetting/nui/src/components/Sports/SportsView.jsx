import { useState, useEffect } from 'react'
import { fetchNUI } from '../../utils/nui'
import { useNUIEvent } from '../../hooks/useNUI'
import { formatOdds, formatDate } from '../../utils/helpers'
import './SportsView.css'

export default function SportsView({ sportKey, categories, addToSlip }) {
  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)

  useNUIEvent('sportOdds', (data) => {
    if (data.sportKey === sportKey) {
      setEvents(data.events || [])
      setLoading(false)
    }
  })

  useEffect(() => {
    setLoading(true)
    setEvents([])
    fetchNUI('getSportOdds', { sportKey })
  }, [sportKey])

  const sportLabel = (() => {
    for (const cat of categories) {
      const sport = cat.sports.find(s => s.key === sportKey)
      if (sport) return sport.label
    }
    return sportKey
  })()

  const handleOddClick = (event, marketKey, outcome) => {
    addToSlip({
      id: `${event.id}_${marketKey}_${outcome.name}`,
      eventId: event.id,
      sportKey: event.sportKey,
      match: `${event.homeTeam} vs ${event.awayTeam}`,
      market: marketKey,
      selection: outcome.name,
      odds: outcome.price,
      point: outcome.point,
    })
  }

  if (loading) {
    return (
      <div className="sports-loading">
        <div className="spinner" />
        <span>Loading odds...</span>
      </div>
    )
  }

  if (events.length === 0) {
    return (
      <div className="sports-empty">
        <p>No events available for {sportLabel}</p>
      </div>
    )
  }

  return (
    <div className="sports-view">
      <h2 className="sports-title">{sportLabel}</h2>
      <div className="events-list">
        {events.map(event => (
          <div key={event.id} className="event-card anim-fade">
            <div className="event-header">
              <span className="event-teams">{event.homeTeam} vs {event.awayTeam}</span>
              <span className="event-time">{formatDate(event.startTime)}</span>
            </div>
            <div className="event-markets">
              {event.markets.h2h && (
                <div className="market-group">
                  <span className="market-label">Winner</span>
                  <div className="market-outcomes">
                    {event.markets.h2h.map((outcome, i) => (
                      <button
                        key={i}
                        className="outcome-btn"
                        onClick={() => handleOddClick(event, 'h2h', outcome)}
                      >
                        <span className="outcome-name">{outcome.name}</span>
                        <span className="outcome-odds">{formatOdds(outcome.price)}</span>
                      </button>
                    ))}
                  </div>
                </div>
              )}
              {event.markets.spreads && (
                <div className="market-group">
                  <span className="market-label">Spread</span>
                  <div className="market-outcomes">
                    {event.markets.spreads.map((outcome, i) => (
                      <button
                        key={i}
                        className="outcome-btn"
                        onClick={() => handleOddClick(event, 'spreads', outcome)}
                      >
                        <span className="outcome-name">{outcome.name} {outcome.point > 0 ? '+' : ''}{outcome.point}</span>
                        <span className="outcome-odds">{formatOdds(outcome.price)}</span>
                      </button>
                    ))}
                  </div>
                </div>
              )}
              {event.markets.totals && (
                <div className="market-group">
                  <span className="market-label">Total</span>
                  <div className="market-outcomes">
                    {event.markets.totals.map((outcome, i) => (
                      <button
                        key={i}
                        className="outcome-btn"
                        onClick={() => handleOddClick(event, 'totals', outcome)}
                      >
                        <span className="outcome-name">{outcome.name} {outcome.point}</span>
                        <span className="outcome-odds">{formatOdds(outcome.price)}</span>
                      </button>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
