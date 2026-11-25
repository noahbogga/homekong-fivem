export function generateClientSeed() {
  const chars = 'abcdef0123456789'
  let seed = ''
  for (let i = 0; i < 32; i++) {
    seed += chars[Math.floor(Math.random() * chars.length)]
  }
  return seed
}

export function formatMoney(amount) {
  return '$' + Number(amount).toLocaleString('en-US')
}

export function formatOdds(price) {
  return Number(price).toFixed(2)
}

export function formatDate(dateStr) {
  const d = new Date(dateStr)
  const now = new Date()
  const diff = d - now
  const hours = Math.floor(diff / 3600000)
  if (hours < 0) return 'Live'
  if (hours < 24) return `${hours}h`
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}
