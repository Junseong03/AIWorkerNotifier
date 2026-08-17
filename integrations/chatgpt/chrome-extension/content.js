(() => {
  const WATCHER_KEY = '__AI_WORKER_NOTIFIER_CHATGPT_WATCHER_V2__';
  const WATCHER_VERSION = '0.1.15';
  const existing = window[WATCHER_KEY];

  // Re-injection must always replace an older watcher. An unpacked-extension
  // reload invalidates the old chrome.runtime context while the page itself can
  // stay alive, so version equality is not sufficient to prove that the old
  // watcher can still send extension messages.
  try { existing?.stop?.(); } catch (_) {}

  const watcherState = { version: WATCHER_VERSION, active: true, stop: null };
  window[WATCHER_KEY] = watcherState;

  const CHECK_INTERVAL_MS = 250;
  const HEARTBEAT_INTERVAL_MS = 3000;
  const STOP_ABSENCE_CONFIRM_MS = 500;
  const COMPOSER_TRANSITION_WINDOW_MS = 1500;
  const FINAL_ACTION_CONFIRM_MS = 500;
  const SAME_SUBMIT_DEBOUNCE_MS = 1000;
  const STOP_SELECTORS = [
    'button[data-testid="stop-button"]',
    'button[aria-label="Stop streaming"]',
    'button[aria-label="Stop generating"]',
    'button[aria-label="응답 중지"]',
    'button[aria-label="생성 중지"]'
  ];
  const STOP_SELECTOR = STOP_SELECTORS.join(',');
  const FINAL_ACTION_SELECTORS = [
    'button[data-testid="copy-turn-action-button"]',
    'button[data-testid="good-response-turn-action-button"]',
    'button[data-testid="bad-response-turn-action-button"]'
  ];

  let requestPending = false;
  let requestStartedAt = 0;
  let generationSeen = false;
  let lastGenerating = false;
  let stopMissingSince = 0;
  let completionSentForCurrentTurn = false;
  let currentTurnId = '';

  // 사용자가 답변 생성 중 composer를 편집하면 ChatGPT가 같은 영역의
  // Stop/Send 컨트롤을 재구성할 수 있다. 이때의 Stop 소실은 완료로 보지 않는다.
  // 입력 내용은 읽지 않고 input 이벤트 발생 시각만 기록한다.
  let lastComposerEditAt = 0;
  let stopRemovalTaintedByComposer = false;
  let finalActionSeenSince = 0;

  let stopped = false;
  let observer = null;
  let checkIntervalId = null;
  let heartbeatIntervalId = null;

  function extensionRuntimeAvailable() {
    try {
      return typeof chrome !== 'undefined' &&
        chrome !== null &&
        chrome.runtime !== undefined &&
        typeof chrome.runtime.sendMessage === 'function';
    } catch (_) {
      return false;
    }
  }

  function isExtensionContextInvalid(error) {
    const message = String(error?.message || error || '');
    return message.includes('Extension context invalidated') ||
      message.includes("Cannot read properties of undefined (reading 'sendMessage')") ||
      message.includes('Cannot access a chrome-extension:// URL of different extension');
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
    document.removeEventListener('input', onComposerInput, true);
    if (window[WATCHER_KEY] === watcherState) {
      try { delete window[WATCHER_KEY]; } catch (_) {}
    }
  }
  watcherState.stop = stopWatcher;

  function safeSendMessage(message, callback) {
    if (stopped) return false;
    if (!extensionRuntimeAvailable()) {
      console.info('[AIWorkerNotifier] extension context is unavailable; stopping stale watcher.');
      stopWatcher();
      return false;
    }

    try {
      chrome.runtime.sendMessage(message, (response) => {
        if (stopped) return;
        try {
          if (!extensionRuntimeAvailable()) {
            stopWatcher();
            return;
          }
          if (chrome.runtime.lastError) {
            if (isExtensionContextInvalid(chrome.runtime.lastError)) stopWatcher();
            return;
          }
          callback?.(response);
        } catch (error) {
          if (isExtensionContextInvalid(error) || !extensionRuntimeAvailable()) {
            stopWatcher();
          }
        }
      });
      return true;
    } catch (error) {
      if (isExtensionContextInvalid(error) || !extensionRuntimeAvailable()) {
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

  function isComposerEditable(target) {
    if (!(target instanceof Element)) return false;
    return Boolean(target.closest('textarea, [contenteditable="true"]'));
  }

  function getLatestAssistantTurnRoot() {
    const assistants = document.querySelectorAll('[data-message-author-role="assistant"]');
    if (assistants.length === 0) return null;
    const assistant = assistants[assistants.length - 1];
    return assistant.closest('article') || assistant.parentElement || assistant;
  }

  function hasLatestAssistantFinalAction() {
    const root = getLatestAssistantTurnRoot();
    if (!root) return false;
    for (const selector of FINAL_ACTION_SELECTORS) {
      if (root.querySelector(selector)) return true;
    }
    return false;
  }

  function newTurnId() {
    try {
      if (typeof crypto?.randomUUID === 'function') return crypto.randomUUID();
    } catch (_) {}
    return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  }

  function resetComposerTransitionState() {
    lastComposerEditAt = 0;
    stopRemovalTaintedByComposer = false;
    finalActionSeenSince = 0;
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
    stopMissingSince = 0;
    completionSentForCurrentTurn = false;
    currentTurnId = newTurnId();
    resetComposerTransitionState();
  }

  function ensureRequestFromGeneration() {
    if (requestPending && !completionSentForCurrentTurn) return;
    requestPending = true;
    requestStartedAt = Date.now();
    generationSeen = true;
    lastGenerating = true;
    stopMissingSince = 0;
    completionSentForCurrentTurn = false;
    currentTurnId = newTurnId();
    resetComposerTransitionState();
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

  function onComposerInput(event) {
    if (!generationSeen) return;
    if (!isComposerEditable(event.target)) return;

    // 프롬프트 문자열은 읽지 않는다. 후속질문 편집이 발생했다는 사실만 기록한다.
    lastComposerEditAt = Date.now();
    stopMissingSince = 0;
    finalActionSeenSince = 0;
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
    if (!generationSeen) return;

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
    stopMissingSince = 0;
    currentTurnId = '';
    resetComposerTransitionState();
    sendHeartbeat();
  }

  function markComposerTaintedStopRemoval(now) {
    stopRemovalTaintedByComposer = true;
    stopMissingSince = 0;
    finalActionSeenSince = 0;
    if (lastComposerEditAt === 0) lastComposerEditAt = now;
  }

  function checkTaintedCompletion(now) {
    if (!stopRemovalTaintedByComposer) return false;

    // 후속질문 입력으로 Stop이 사라진 뒤에는 Stop 부재만으로 완료하지 않는다.
    // 최신 assistant turn의 완료 후 액션 UI가 나타난 경우에만 보수적으로 완료한다.
    // 텍스트/프롬프트/응답 내용은 읽지 않는다.
    if (!hasLatestAssistantFinalAction()) {
      finalActionSeenSince = 0;
      return true;
    }

    if (finalActionSeenSince === 0) {
      finalActionSeenSince = now;
      return true;
    }

    if (now - finalActionSeenSince >= FINAL_ACTION_CONFIRM_MS) {
      completeCurrentTurn('assistant-final-action-after-composer-edit');
    }
    return true;
  }

  function checkState() {
    if (stopped) return;
    const now = Date.now();
    const generating = hasVisibleStopControl();

    if (generating) {
      if (!requestPending) ensureRequestFromGeneration();
      generationSeen = true;
      lastGenerating = true;
      stopMissingSince = 0;

      // 후속질문 입력 때문에 Stop이 잠깐 사라졌다가 다시 나타났다면
      // 이후의 Stop 제거는 다시 정상적인 완료 신호로 사용할 수 있다.
      if (stopRemovalTaintedByComposer) {
        stopRemovalTaintedByComposer = false;
        finalActionSeenSince = 0;
      }
      return;
    }

    if (!generationSeen || !lastGenerating) return;

    // composer 편집 직후 Stop이 없어졌다면 동일 영역의 Stop→Send 재구성으로 본다.
    if (
      lastComposerEditAt > 0 &&
      now - lastComposerEditAt <= COMPOSER_TRANSITION_WINDOW_MS
    ) {
      markComposerTaintedStopRemoval(now);
      return;
    }

    // 한 번 composer 영향으로 오염된 Stop 제거는 시간이 지났다고 다시 완료로 승격하지 않는다.
    // 실제 assistant 완료 UI를 별도로 확인해야 한다.
    if (checkTaintedCompletion(now)) return;

    // composer 편집과 무관한 평상시에는 Stop 부재를 짧게 재확인한다.
    if (stopMissingSince === 0) {
      stopMissingSince = now;
      return;
    }
    if (now - stopMissingSince >= STOP_ABSENCE_CONFIRM_MS) {
      completeCurrentTurn('stop-absence-confirmed');
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
          else stopRemoved = true;
        }
      }
    }

    if (stopAdded) {
      if (!requestPending) ensureRequestFromGeneration();
      generationSeen = true;
      lastGenerating = true;
      stopMissingSince = 0;
      if (stopRemovalTaintedByComposer) {
        stopRemovalTaintedByComposer = false;
        finalActionSeenSince = 0;
      }
    }

    if (stopRemoved && generationSeen && !hasVisibleStopControl()) {
      const now = Date.now();
      if (
        lastComposerEditAt > 0 &&
        now - lastComposerEditAt <= COMPOSER_TRANSITION_WINDOW_MS
      ) {
        markComposerTaintedStopRemoval(now);
        return;
      }

      if (stopRemovalTaintedByComposer) return;
      completeCurrentTurn('stop-removed');
    }
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
  document.addEventListener('input', onComposerInput, true);
  checkIntervalId = window.setInterval(checkState, CHECK_INTERVAL_MS);
  heartbeatIntervalId = window.setInterval(sendHeartbeat, HEARTBEAT_INTERVAL_MS);
  window.addEventListener('focus', sendHeartbeat);
  window.addEventListener('pageshow', sendHeartbeat);

  checkState();
  sendHeartbeat();
})();