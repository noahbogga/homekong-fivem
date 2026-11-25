export function fetchNUI(eventName, data = {}) {
  return fetch(`https://hk-sportsbetting/${eventName}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  }).then(resp => resp.json())
}

export function onNUIMessage(handler) {
  const listener = (event) => handler(event.data)
  window.addEventListener('message', listener)
  return () => window.removeEventListener('message', listener)
}

export function closeNUI() {
  fetchNUI('closeUI')
}
