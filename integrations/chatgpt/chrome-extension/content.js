(() => {
  const WATCHER_KEY = '__AI_WORKER_NOTIFIER_CHATGPT_WATCHER_V2__';
  const WATCHER_VERSION = '0.1.7';
  const existing = window[WATCHER_KEY];

  if (existing?.version === WATCHER_VERSION && existing?.active === true) return;
  try { existing?.stop?.(); } catch (_) {}

  const watcherState = { version: WATCHER_VERSION, active: true, stop: null };
  window[WATCHER_KEY] = watcherState;

  const CHECK_INTERVAL_MS = 100;
  const HEARTBEAT_INTERVAL_MS = 3000;
  const SHORT_RESPONSE_GRACE_MS = 650;
  const POST_GENERATION_SETTLE_MS = 100;

  let wasGenerating = false;
  let requestPending = false;
  let requestStartedAt = 0;
  let generationEndedAt = 0;
  let completionSentForCurrentTurn = false;
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
    document.removeEventListener('submit', onSubmit, true);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('keydown', onKeyDown, true);
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
      for (const control of document.querySelectorAll(selector)) {
        if (isVisible(control)) return true;
      }
    }
    return false;
  }

  function hasReadySendControl() {
    const selectors = [
      'button[data-testid="send-button"]',
      'button[aria-label="Send prompt"]',
      'button[aria-label="Send message"]',
      'button[aria-label="보내기"]'
    ];
    for (const selector of selectors) {
      for (const button of document.querySelectorAll(selector)) {
        if (!isVisible(button)) continue;
        if (button.disabled) continue;
        if (button.getAttribute('aria-disabled') === 'true') continue;
        return true;
      }
    }
    return false;
  }

  function markRequestPending() {
    requestPending = true;
    requestStartedAt = Date.now();
    generationEndedAt = 0;
    completionSentForCurrentTurn = false;
  }

  function onSubmit(event) {
    if (event.defaultPrevented) return;
    markRequestPending();
  }

  function onClick(event) {
    const button = event.target?.closest?.('button');
    if (!button) return;
    if (
      button.matches('[data-testid="send-button"]') ||
      button.getAttribute('aria-label') === 'Send prompt' ||
      button.getAttribute('aria-label') === 'Send message' ||
      button.getAttribute('aria-label') === '보내기'
    ) {
      markRequestPending();
    }
  }

  function onKeyDown(event) {
    if (event.defaultPrevented || event.isComposing) return;
    if (event.key !== 'Enter' || event.shiftKey || event.ctrlKey || event.altKey || event.metaKey) return;
    const target = event.target;
    if (!target) return;
    const editable = target.closest?.('textarea, [contenteditable="true"]');
    if (editable) markRequestPending();
  }

  function sendHeartbeat() {
    if (stopped) return;
    safeSendMessage({
      type: 'heartbeat',
      title: document.title || 'ChatGPT',
      generating: hasVisibleStopControl()
    });
  }

  function sendCompletion() {
    if (stopped) return;
    safeSendMessage({
      type: 'completed',
      title: document.title || 'ChatGPT'
    });
  }

  function checkState() {
    if (stopped) return;
    const now = Date.now();
    const generating = hasVisibleStopControl();

    if (generating) {
      wasGenerating = true;
      requestPending = true;
      if (requestStartedAt === 0) requestStartedAt = now;
      generationEndedAt = 0;
      completionSentForCurrentTurn = false;
      return;
    }

    if (wasGenerating && generationEndedAt === 0) {
      generationEndedAt = now;
    }

    if (completionSentForCurrentTurn) return;
    if (!requestPending && !wasGenerating) return;

    const readyToSendAgain = hasReadySendControl();
    if (!readyToSendAgain) return;

    if (wasGenerating) {
      if (generationEndedAt === 0 || now - generationEndedAt < POST_GENERATION_SETTLE_MS) return;
    } else {
      if (requestStartedAt === 0 || now - requestStartedAt < SHORT_RESPONSE_GRACE_MS) return;
    }

    completionSentForCurrentTurn = true;
    requestPending = false;
    wasGenerating = false;
    requestStartedAt = 0;
    generationEndedAt = 0;
    sendCompletion();
    sendHeartbeat();
  }

  observer = new MutationObserver(() => {
    if (stopped || scheduled) return;
    scheduled = true;
    window.setTimeout(() => {
      scheduled = false;
      checkState();
    }, 25);
  });

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['aria-label', 'data-testid', 'hidden', 'disabled', 'aria-disabled']
  });

  document.addEventListener('submit', onSubmit, true);
  document.addEventListener('click', onClick, true);
  document.addEventListener('keydown', onKeyDown, true);
  checkIntervalId = window.setInterval(checkState, CHECK_INTERVAL_MS);
  heartbeatIntervalId = window.setInterval(sendHeartbeat, HEARTBEAT_INTERVAL_MS);
  window.addEventListener('focus', sendHeartbeat);
  window.addEventListener('pageshow', sendHeartbeat);

  checkState();
  sendHeartbeat();
})();
