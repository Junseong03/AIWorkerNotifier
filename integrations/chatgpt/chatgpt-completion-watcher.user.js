// ==UserScript==
// @name         AIWorkerNotifier - ChatGPT Completion Watcher
// @namespace    https://github.com/Junseong03/AIWorkerNotifier
// @version      0.1.0
// @description  ChatGPT의 응답 생성 상태만 관찰하고 완료 시 로컬 AIWorkerNotifier에 알립니다. 응답 내용은 읽지 않습니다.
// @match        https://chatgpt.com/*
// @match        https://chat.openai.com/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// ==/UserScript==

(function () {
  'use strict';

  const BRIDGE_URL = 'http://127.0.0.1:43127/ai-worker-notifier/chatgpt/completed';
  const CHECK_INTERVAL_MS = 500;
  const COMPLETION_SETTLE_MS = 1200;

  let wasGenerating = false;
  let idleSince = 0;
  let completionSentForCurrentTurn = false;

  function isVisible(element) {
    if (!element || !element.isConnected) return false;
    const style = window.getComputedStyle(element);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function hasVisibleStopControl() {
    // ChatGPT가 생성 중일 때 표시하는 중지 컨트롤만 확인한다.
    // 메시지 본문, 코드블록, assistant textContent는 읽지 않는다.
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

  function notifyCompletion() {
    GM_xmlhttpRequest({
      method: 'POST',
      url: BRIDGE_URL,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      data: 'response-complete',
      timeout: 3000,
      onload: (response) => {
        if (response.status < 200 || response.status >= 300) {
          console.warn('[AIWorkerNotifier] completion bridge returned', response.status);
        }
      },
      onerror: () => console.warn('[AIWorkerNotifier] completion bridge is unavailable.'),
      ontimeout: () => console.warn('[AIWorkerNotifier] completion bridge timed out.')
    });
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
    notifyCompletion();
  }

  // DOM 변경을 신호로 사용하되, UI 변화가 없는 경우도 놓치지 않도록 저빈도 확인을 병행한다.
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
  checkState();
  console.info('[AIWorkerNotifier] ChatGPT completion watcher active (status-only DOM observation).');
})();
