(() => {
  const WATCHER_KEY = '__AI_WORKER_NOTIFIER_CHATGPT_WATCHER_V2__';
  const WATCHER_VERSION = '0.1.8';
  const existing = window[WATCHER_KEY];

  if (existing?.version === WATCHER_VERSION && existing?.active === true) return;
  try { existing?.stop?.(); } catch (_) {}

  const watcherState = { version: WATCHER_VERSION, active: true, stop: null };
  window[WATCHER_KEY] = watcherState;

  const CHECK_INTERVAL_MS = 250;
  const HEARTBEAT_INTERVAL_MS = 3000;
  const SHORT_RESPONSE_FALLBACK_MS = 500;
  const SAME_SUBMIT_DEBOUNCE_MS = 1000;
  const STOP_SELECTORS = [
    'button[data-testid="stop-button"]',
    'button[aria-label="Stop streaming"]',
    'button[aria-label="Stop generating"]',
    'button[aria-label="응답 중지"]',
    'button[aria-label="생성 중지"]'
  ];
  const STOP_SELECTOR = STOP_SELECTORS.join(',');

  let requestPending = false;
  let requestStartedAt = 0;
  let generationSeen = false;
  let lastGenerating = false;
  let completionSentForCurrentTurn = false;
  let baselineAssistantCount = 0;
  let currentTurnId = '';
  let stopped = false;
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
    for (const selector of STOP_SELECTORS) {
      for (const control of document.querySelectorAll(selector)) {
        if (isVisible(control)) return true;
      }
    }
    return false;
  }

  function nodeContainsStopControl(node) {
    if (!(node instanceof Element)) return false;
    if (node.matches(STOP_SELECTOR)) return true;
    return Boolean(node.querySelector(STOP_SELECTOR));
  }

  function assistantTurnCount() {
    // 응답 본문은 읽지 않는다. assistant turn 컨테이너의 개수만 센다.
    return document.querySelectorAll('[data-message-author-role="assistant"]').length;
  }

  function newTurnId() {
    try {
      if (typeof crypto?.randomUUID === 'function') return crypto.randomUUID();
    } catch (_) {}
    return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  }

  function markRequestPending() {
    const now = Date.now();
    if (requestPending && !completionSentForCurrentTurn && now - requestStartedAt < SAME_SUBMIT_DEBOUNCE_MS) {
      return;
    }

    requestPending = true;
    requestStartedAt = now;
    generationSeen = false;
    lastGenerating = false;
    completionSentForCurrentTurn = false;
    baselineAssistantCount = assistantTurnCount();
    currentTurnId = newTurnId();
  }

  function ensureRequestFromGeneration() {
    if (requestPending && !completionSentForCurrentTurn) return;
    requestPending = true;
    requestStartedAt = Date.now();
    generationSeen = true;
    completionSentForCurrentTurn = false;
    baselineAssistantCount = assistantTurnCount();
    currentTurnId = newTurnId();
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

  function completeCurrentTurn(mode) {
    if (stopped || completionSentForCurrentTurn) return;
    if (!requestPending && !generationSeen) return;

    completionSentForCurrentTurn = true;
    const turnId = currentTurnId || newTurnId();
    safeSendMessage({
      type: 'completed',
      title: document.title || 'ChatGPT',
      turnId,
      detectedAtUtc: new Date().toISOString(),
      detectionMode: mode
    });

    requestPending = false;
    requestStartedAt = 0;
    generationSeen = false;
    lastGenerating = false;
    baselineAssistantCount = assistantTurnCount();
    currentTurnId = '';
    sendHeartbeat();
  }

  function checkState() {
    if (stopped) return;
    const generating = hasVisibleStopControl();

    if (generating) {
      if (!requestPending) ensureRequestFromGeneration();
      generationSeen = true;
      lastGenerating = true;
      return;
    }

    // 가장 신뢰할 수 있는 완료 신호: 이전 검사에서 Stop이 보였고 지금 사라졌다.
    if (generationSeen && lastGenerating) {
      completeCurrentTurn('stop-transition');
      return;
    }

    // Stop 버튼이 너무 짧게 나타나 DOM 최종 상태에서 놓친 경우의 보조 경로.
    // 응답 텍스트는 읽지 않고 assistant turn 컨테이너가 새로 생겼는지만 본다.
    if (
      requestPending &&
      !generationSeen &&
      requestStartedAt > 0 &&
      Date.now() - requestStartedAt >= SHORT_RESPONSE_FALLBACK_MS &&
      assistantTurnCount() > baselineAssistantCount
    ) {
      completeCurrentTurn('assistant-turn-fallback');
    }
  }

  observer = new MutationObserver((records) => {
    if (stopped) return;

    let stopAdded = false;
    let stopRemoved = false;

    for (const record of records) {
      if (record.type === 'childList') {
        for (const node of record.addedNodes) {
          if (nodeContainsStopControl(node)) stopAdded = true;
        }
        for (const node of record.removedNodes) {
          if (nodeContainsStopControl(node)) stopRemoved = true;
        }
      } else if (record.type === 'attributes') {
        const target = record.target;
        if (target instanceof Element && target.matches(STOP_SELECTOR)) {
          if (isVisible(target)) stopAdded = true;
        }
      }
    }

    if (stopAdded) {
      if (!requestPending) ensureRequestFromGeneration();
      generationSeen = true;
      lastGenerating = true;
    }

    // 추가와 삭제가 polling 사이에 모두 일어나도 MutationRecord에는 남는다.
    if (stopRemoved && generationSeen && !hasVisibleStopControl()) {
      completeCurrentTurn('stop-removed');
      return;
    }

    checkState();
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
