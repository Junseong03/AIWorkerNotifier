(() => {
  const WATCHER_KEY = '__AI_WORKER_NOTIFIER_CHATGPT_WATCHER_V2__';
  const WATCHER_VERSION = '0.1.2';
  const existing = window[WATCHER_KEY];

  if (existing?.version === WATCHER_VERSION && existing?.active === true) return;
  try { existing?.stop?.(); } catch (_) {}

  const watcherState = {
    version: WATCHER_VERSION,
    active: true,
    stop: null
  };
  window[WATCHER_KEY] = watcherState;

  const CHECK_INTERVAL_MS = 500;
  const HEARTBEAT_INTERVAL_MS = 3000;
  const COMPLETION_SETTLE_MS = 1200;

  let wasGenerating = false;
  let idleSince = 0;
  let completionSentForCurrentTurn = false;
  let selectedForNotifications = false;
  let stopped = false;
  let scheduled = false;
  let observer = null;
  let checkIntervalId = null;
  let heartbeatIntervalId = null;

  function isExtensionContextInvalid(error) {
    return String(error?.message || error || '').includes('Extension context invalidated');
  }

  function stopWatcher() {
    if (stopped) return;
    stopped = true;
    watcherState.active = false;

    try { observer?.disconnect(); } catch (_) {}
    if (checkIntervalId !== null) window.clearInterval(checkIntervalId);
    if (heartbeatIntervalId !== null) window.clearInterval(heartbeatIntervalId);

    window.removeEventListener('focus', sendHeartbeat);
    window.removeEventListener('pageshow', sendHeartbeat);

    if (window[WATCHER_KEY] === watcherState) {
      try { delete window[WATCHER_KEY]; } catch (_) {}
    }
  }

  watcherState.stop = stopWatcher;

  function safeSendMessage(message, callback) {
    if (stopped) return false;

    try {
      chrome.runtime.sendMessage(message, (response) => {
        if (stopped) return;
        try {
          if (chrome.runtime.lastError) {
            if (isExtensionContextInvalid(chrome.runtime.lastError)) stopWatcher();
            return;
          }
          callback?.(response);
        } catch (error) {
          if (isExtensionContextInvalid(error)) stopWatcher();
        }
      });
      return true;
    } catch (error) {
      if (isExtensionContextInvalid(error)) {
        stopWatcher();
        return false;
      }
      console.warn('[AIWorkerNotifier] extension message failed:', error);
      return false;
    }
  }

  function isVisible(element) {
    if (!element || !element.isConnected) return false;
    const style = window.getComputedStyle(element);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function hasVisibleStopControl() {
    const selectors = [
      'button[data-testid="stop-button"]',
      'button[aria-label="Stop streaming"]',
      'button[aria-label="Stop generating"]',
      'button[aria-label="응답 중지"]',
      'button[aria-label="생성 중지"]'
    ];

    for (const selector of selectors) {
      const controls = document.querySelectorAll(selector);
      for (const control of controls) {
        if (isVisible(control)) return true;
      }
    }
    return false;
  }

  function sendHeartbeat() {
    if (stopped) return;
    const generating = hasVisibleStopControl();
    safeSendMessage({
      type: 'heartbeat',
      title: document.title || 'ChatGPT',
      generating
    }, (response) => {
      selectedForNotifications = response?.selected === true;
    });
  }

  function sendCompletion() {
    if (stopped || !selectedForNotifications) return;
    safeSendMessage({
      type: 'completed',
      title: document.title || 'ChatGPT'
    });
  }

  function checkState() {
    if (stopped) return;
    const generating = hasVisibleStopControl();
    const now = Date.now();

    if (generating) {
      wasGenerating = true;
      idleSince = 0;
      completionSentForCurrentTurn = false;
      return;
    }

    if (!wasGenerating || completionSentForCurrentTurn) return;

    if (idleSince === 0) {
      idleSince = now;
      return;
    }

    if (now - idleSince < COMPLETION_SETTLE_MS) return;

    completionSentForCurrentTurn = true;
    wasGenerating = false;
    idleSince = 0;
    sendCompletion();
    sendHeartbeat();
  }

  observer = new MutationObserver(() => {
    if (stopped || scheduled) return;
    scheduled = true;
    window.setTimeout(() => {
      scheduled = false;
      checkState();
    }, 100);
  });

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['aria-label', 'data-testid', 'hidden']
  });

  checkIntervalId = window.setInterval(checkState, CHECK_INTERVAL_MS);
  heartbeatIntervalId = window.setInterval(sendHeartbeat, HEARTBEAT_INTERVAL_MS);
  window.addEventListener('focus', sendHeartbeat);
  window.addEventListener('pageshow', sendHeartbeat);

  checkState();
  sendHeartbeat();
})();
