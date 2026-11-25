import { useState, useEffect, useRef } from 'react'
import { onNUIMessage } from '../utils/nui'

export function useNUIEvent(action, handler) {
  const savedHandler = useRef(handler)
  savedHandler.current = handler

  useEffect(() => {
    return onNUIMessage((data) => {
      if (data.action === action) {
        savedHandler.current(data)
      }
    })
  }, [action])
}

export function useNUIVisibility() {
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    return onNUIMessage((data) => {
      if (data.action === 'show') setVisible(true)
      if (data.action === 'hide') setVisible(false)
    })
  }, [])

  return visible
}
