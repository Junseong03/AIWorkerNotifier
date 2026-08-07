// ==UserScript==
// @name         AIWorkerNotifier - ChatGPT Completion Watcher
// @namespace    https://github.com/Junseong03/AIWorkerNotifier
// @version      0.2.0
// @description  ChatGPT 탭을 로컬 AIWorkerNotifier에 등록하고, 선택된 탭의 응답 완료 상태만 알립니다. 응답 내용은 읽지 않습니다.
// @match        https://chatgpt.com/*
// @match        https://chat.openai.com/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// ==/UserScript==

(function () {
  'use strict';

  const BRIDGE_BASE = 'http://127.0.0.1:43127';
  const HEARTBEAT_URL = `${BRIDGE_BASE}/api/tabs/heartbeat`;
  const COMPLETION_URL = `${BRIDGE_BASE}/api/tabs/completed`;
  const CHECK_INTERVAL_MS = 500;
  const HEARTBEAT_INTERVAL_MS = 3000;
  const COMPLETION_SETTLE_MS = 1200;

  const TAB_ID_KEY = 'aiWorkerNotifierChatGptTabId';
  let tabId = window.sessionStorage.getItem(TAB_ID_KEY);
  if (!tabId) {
    tabId = (window.crypto && typeof window.crypto.randomUUID === 'function')
      ? window.crypto.randomUUID()
      : `tab-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    window.sessionStorage.setItem(TAB_ID_KEY, tabId);
  }

  let wasGenerating = false;
  let idleSince = 0;
  let completionSentForCurrentTurn = false;
  let selectedForNotifications = false;
  let lastHeartbeatSignature = '';

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

  function postJson(url, payload, onSuccess) {
    GM_xmlhttpRequest({
      method: 'POST',
      url,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'X-AIWorkerNotifier-Client': 'chatgpt-userscript'
      },
      data: JSON.stringify(payload),
      timeout: 3000,
      onload: (response) => {
        if (response.status < 200 || response.status >= 300) {
          console.warn('[AIWorkerNotifier] bridge returned', response.status, url);
          return;
        }
        if (onSuccess) onSuccess(response);
      },
      onerror: () => console.warn('[AIWorkerNotifier] local bridge is unavailable.'),
      ontimeout: () => console.warn('[AIWorkerNotifier] local bridge timed out.')
    });
  }

  function currentTabMetadata(generating) {
    return {
      tabId,
      title: document.title || 'ChatGPT',
      url: window.location.href,
      generating: Boolean(generating)
    };
  }

  function sendHeartbeat(force) {
    const generating = hasVisibleStopControl();
    const metadata = currentTabMetadata(generating);
    const signature = `${metadata.title}|${metadata.url}|${metadata.generating}`;
    if (!force && signature === lastHeartbeatSignature) {
      // 목록에서 탭이 살아있음을 알리기 위해 정기 heartbeat는 계속 전송한다.
    }
    lastHeartbeatSignature = signature;

    postJson(HEARTBEAT_URL, metadata, (response) => {
      try {
        const result = JSON.parse(response.responseText || '{}');
        selectedForNotifications = result.selected === true;
      } catch (_) {
        selectedForNotifications = false;
      }
    });
  }

  function notifyCompletion() {
    if (!selectedForNotifications) return;

    postJson(COMPLETION_URL, {
      tabId,
      title: document.title || 'ChatGPT',
      url: window.location.href
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
    sendHeartbeat(true);
  }

  // DOM 변경은 상태 재확인의 신호로만 사용한다. 응답 텍스트는 읽지 않는다.
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
  window.setInterval(() => sendHeartbeat(false), HEARTBEAT_INTERVAL_MS);
  window.addEventListener('focus', () => sendHeartbeat(true));
  window.addEventListener('pageshow', () => sendHeartbeat(true));

  checkState();
  sendHeartbeat(true);
  console.info(`[AIWorkerNotifier] ChatGPT tab registered: ${tabId} (status-only DOM observation).`);
})();
