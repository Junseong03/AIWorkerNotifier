(() => {
  if (window.__AI_WORKER_NOTIFIER_CHATGPT_WATCHER__) return;
  window.__AI_WORKER_NOTIFIER_CHATGPT_WATCHER__ = true;

  const CHECK_INTERVAL_MS = 500;
  const HEARTBEAT_INTERVAL_MS = 3000;
  const COMPLETION_SETTLE_MS = 1200;

  let wasGenerating = false;
  let idleSince = 0;
  let completionSentForCurrentTurn = false;
  let selectedForNotifications = false;

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
    const generating = hasVisibleStopControl();
    chrome.runtime.sendMessage({
      type: 'heartbeat',
      title: document.title || 'ChatGPT',
      generating
    }, (response) => {
      if (chrome.runtime.lastError) return;
      selectedForNotifications = response?.selected === true;
    });
  }

  function sendCompletion() {
    if (!selectedForNotifications) return;
    chrome.runtime.sendMessage({
      type: 'completed',
      title: document.title || 'ChatGPT'
    }, () => void chrome.runtime.lastError);
  }

  function checkState() {
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

  let scheduled = false;
  const observer = new MutationObserver(() => {
    if (scheduled) return;
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

  window.setInterval(checkState, CHECK_INTERVAL_MS);
  window.setInterval(sendHeartbeat, HEARTBEAT_INTERVAL_MS);
  window.addEventListener('focus', sendHeartbeat);
  window.addEventListener('pageshow', sendHeartbeat);

  checkState();
  sendHeartbeat();
})();
