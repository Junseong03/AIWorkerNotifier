const BRIDGE_BASE = 'http://127.0.0.1:43127';
const SNAPSHOT_URL = `${BRIDGE_BASE}/api/tabs/snapshot`;
const REMOVE_URL = `${BRIDGE_BASE}/api/tabs/remove`;
const HEARTBEAT_URL = `${BRIDGE_BASE}/api/tabs/heartbeat`;
const COMPLETION_URL = `${BRIDGE_BASE}/api/tabs/completed`;
const FOCUS_ACK_URL = `${BRIDGE_BASE}/api/tabs/focus-ack`;
const SNAPSHOT_MIN_INTERVAL_MS = 2000;
const FOCUS_POLL_INTERVAL_MS = 1000;
const ALARM_NAME = 'ai-worker-notifier-chatgpt-tab-sync';

let syncInFlight = false;
let focusPollInFlight = false;
let lastSnapshotAt = 0;
let focusPollIntervalId = null;
const generatingByTab = new Map();
const focusRequestsInFlight = new Set();

async function postJson(url, payload) {
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'X-AIWorkerNotifier-Client': 'chatgpt-extension'
      },
      body: JSON.stringify(payload),
      cache: 'no-store'
    });
    if (!response.ok && response.status !== 204) {
      console.warn('[AIWorkerNotifier] bridge returned', response.status, url);
    }
    return response;
  } catch (_) {
    return null;
  }
}

function canonicalChatGptUrl(rawUrl) {
  if (typeof rawUrl !== 'string' || rawUrl.length === 0) return '';
  try {
    const parsed = new URL(rawUrl);
    if (parsed.protocol !== 'https:') return '';
    let host = parsed.hostname.toLowerCase();
    if (!['chatgpt.com', 'www.chatgpt.com', 'chat.openai.com'].includes(host)) {
      return '';
    }
    if (host === 'www.chatgpt.com' || host === 'chat.openai.com') {
      host = 'chatgpt.com';
    }
    let path = parsed.pathname || '/';
    if (path.length > 1) {
      path = path.replace(/\/+$/, '') || '/';
    }
    return `https://${host}${path}`;
  } catch (_) {
    return '';
  }
}

function isChatGptUrl(url) {
  return canonicalChatGptUrl(url) !== '';
}

function toSnapshotTab(tab) {
  if (!tab || !Number.isInteger(tab.id) || !isChatGptUrl(tab.url)) return null;
  return {
    tabId: `chrome-${tab.id}`,
    windowId: Number.isInteger(tab.windowId) ? tab.windowId : null,
    title: tab.title || 'ChatGPT',
    url: tab.url
  };
}

function heartbeatPayload(tab, generating = false) {
  return {
    tabId: `chrome-${tab.id}`,
    windowId: Number.isInteger(tab.windowId) ? tab.windowId : null,
    title: tab.title || 'ChatGPT',
    url: tab.url,
    generating: Boolean(generating)
  };
}

async function readFocusRequestId(response) {
  if (!response?.ok) return '';
  try {
    const payload = await response.json();
    return typeof payload.focusRequestId === 'string'
      ? payload.focusRequestId
      : '';
  } catch (_) {
    return '';
  }
}

async function readBrowserFocusAction(response) {
  if (!response?.ok || response.status === 204) return null;
  try {
    const payload = await response.json();
    if (
      typeof payload.focusRequestId !== 'string' ||
      payload.focusRequestId.length === 0 ||
      typeof payload.targetUrl !== 'string' ||
      canonicalChatGptUrl(payload.targetUrl) === ''
    ) {
      return null;
    }
    return {
      requestId: payload.focusRequestId,
      preferredTabId: typeof payload.preferredTabId === 'string'
        ? payload.preferredTabId
        : '',
      targetUrl: payload.targetUrl,
      openIfMissing: payload.openIfMissing === true
    };
  } catch (_) {
    return null;
  }
}

function numericChromeTabId(tabId) {
  const match = /^chrome-(\d+)$/.exec(tabId || '');
  if (!match) return null;
  const value = Number(match[1]);
  return Number.isInteger(value) ? value : null;
}

function matchingTargetTabs(allTabs, targetUrl) {
  const canonicalTarget = canonicalChatGptUrl(targetUrl);
  if (!canonicalTarget) return [];
  return allTabs.filter((tab) =>
    Number.isInteger(tab.id) &&
    canonicalChatGptUrl(tab.url) === canonicalTarget
  );
}

function chooseExistingTargetTab(matches, preferredTabId) {
  if (matches.length === 0) return null;
  const preferredNumericId = numericChromeTabId(preferredTabId);
  if (preferredNumericId !== null) {
    const preferred = matches.find((tab) => tab.id === preferredNumericId);
    if (preferred) return preferred;
  }

  return [...matches].sort((left, right) => {
    if (left.active !== right.active) return left.active ? -1 : 1;
    const rightLastAccessed = Number(right.lastAccessed || 0);
    const leftLastAccessed = Number(left.lastAccessed || 0);
    return rightLastAccessed - leftLastAccessed;
  })[0];
}

async function foregroundWindow(windowId) {
  if (!Number.isInteger(windowId)) return;
  try {
    const window = await chrome.windows.get(windowId);
    if (window?.state === 'minimized') {
      await chrome.windows.update(windowId, { state: 'normal' });
    }
  } catch (_) {}
  await chrome.windows.update(windowId, { focused: true });
}

async function foregroundTab(tab) {
  if (!tab || !Number.isInteger(tab.id)) {
    throw new Error('Chrome tab is unavailable');
  }
  const activated = await chrome.tabs.update(tab.id, { active: true });
  const windowId = Number.isInteger(activated?.windowId)
    ? activated.windowId
    : tab.windowId;
  await foregroundWindow(windowId);
  return activated || tab;
}

async function createTargetTab(targetUrl) {
  let lastFocusedWindow = null;
  try {
    lastFocusedWindow = await chrome.windows.getLastFocused();
  } catch (_) {}

  if (
    lastFocusedWindow &&
    Number.isInteger(lastFocusedWindow.id) &&
    lastFocusedWindow.type === 'normal'
  ) {
    if (lastFocusedWindow.state === 'minimized') {
      await chrome.windows.update(lastFocusedWindow.id, { state: 'normal' });
    }
    const created = await chrome.tabs.create({
      windowId: lastFocusedWindow.id,
      url: targetUrl,
      active: true
    });
    await foregroundWindow(lastFocusedWindow.id);
    return created;
  }

  const createdWindow = await chrome.windows.create({
    url: targetUrl,
    focused: true,
    type: 'normal'
  });
  if (!createdWindow || !Number.isInteger(createdWindow.id)) {
    throw new Error('Chrome window could not be created');
  }
  const tabs = await chrome.tabs.query({ windowId: createdWindow.id });
  const created = tabs.find((tab) => tab.active) || tabs[0];
  if (!created) throw new Error('Chrome tab could not be created');
  return created;
}

async function postFocusAck({ requestId, tab, targetUrl, success, error, opened }) {
  const tabId = Number.isInteger(tab?.id) ? `chrome-${tab.id}` : '';
  const actualUrl = canonicalChatGptUrl(tab?.url) || canonicalChatGptUrl(targetUrl);
  await postJson(FOCUS_ACK_URL, {
    requestId,
    tabId,
    url: actualUrl,
    success,
    opened: Boolean(opened),
    error
  });
}

async function applyBrowserFocusAction(action, allTabs) {
  if (!action?.requestId || focusRequestsInFlight.has(action.requestId)) return;
  focusRequestsInFlight.add(action.requestId);

  let targetTab = null;
  let opened = false;
  let success = false;
  let error = '';
  try {
    const matches = matchingTargetTabs(allTabs, action.targetUrl);
    targetTab = chooseExistingTargetTab(matches, action.preferredTabId);

    if (targetTab) {
      targetTab = await foregroundTab(targetTab);
      success = true;
    } else if (action.openIfMissing) {
      targetTab = await createTargetTab(action.targetUrl);
      opened = true;
      targetTab = await foregroundTab(targetTab);
      success = true;
    } else {
      error = 'Matching Chrome tab was not found.';
    }
  } catch (reason) {
    error = String(reason?.message || reason || 'Chrome tab focus failed');
  }

  try {
    await postFocusAck({
      requestId: action.requestId,
      tab: targetTab,
      targetUrl: action.targetUrl,
      success,
      error,
      opened
    });
  } finally {
    focusRequestsInFlight.delete(action.requestId);
  }
}

async function injectWatcher(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ['content.js']
    });
  } catch (_) {}
}

async function removeTrackedTab(tabId) {
  if (!Number.isInteger(tabId)) return;
  generatingByTab.delete(tabId);
  await postJson(REMOVE_URL, { tabId: `chrome-${tabId}` });
}

async function syncOpenChatGptTabs({ force = false, inject = false } = {}) {
  const now = Date.now();
  if (!force && now - lastSnapshotAt < SNAPSHOT_MIN_INTERVAL_MS) return;
  if (syncInFlight) return;

  syncInFlight = true;
  try {
    const allTabs = await chrome.tabs.query({});
    const chatGptTabs = allTabs.filter((tab) => isChatGptUrl(tab.url));
    const snapshot = chatGptTabs.map(toSnapshotTab).filter(Boolean);
    const response = await postJson(SNAPSHOT_URL, { tabs: snapshot });
    lastSnapshotAt = Date.now();

    const focusAction = await readBrowserFocusAction(response);
    if (focusAction) {
      await applyBrowserFocusAction(focusAction, allTabs);
    }

    if (inject) {
      for (const tab of chatGptTabs) {
        await injectWatcher(tab.id);
      }
    }
  } finally {
    syncInFlight = false;
  }
}

async function applyFocusRequest(tab, requestId) {
  if (!requestId || !tab || !Number.isInteger(tab.id)) return;

  const key = `legacy:${requestId}:${tab.id}`;
  if (focusRequestsInFlight.has(key)) return;
  focusRequestsInFlight.add(key);

  let success = false;
  let error = '';
  let focusedTab = tab;
  try {
    focusedTab = await foregroundTab(tab);
    success = true;
  } catch (reason) {
    error = String(reason?.message || reason || 'Chrome tab focus failed');
  }

  try {
    await postFocusAck({
      requestId,
      tab: focusedTab,
      targetUrl: tab.url,
      success,
      error,
      opened: false
    });
  } finally {
    focusRequestsInFlight.delete(key);
  }
}

async function pollFocusRequests() {
  if (focusPollInFlight) return;
  focusPollInFlight = true;
  try {
    await syncOpenChatGptTabs({ force: true, inject: false });
  } finally {
    focusPollInFlight = false;
  }
}

function ensureFocusPoller() {
  if (focusPollIntervalId !== null) return;
  focusPollIntervalId = setInterval(() => {
    pollFocusRequests().catch(() => {});
  }, FOCUS_POLL_INTERVAL_MS);
  pollFocusRequests().catch(() => {});
}

function ensureFallbackAlarm() {
  chrome.alarms.create(ALARM_NAME, { periodInMinutes: 1 });
}

chrome.runtime.onInstalled.addListener(() => {
  ensureFallbackAlarm();
  ensureFocusPoller();
  syncOpenChatGptTabs({ force: true, inject: true }).catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  ensureFallbackAlarm();
  ensureFocusPoller();
  syncOpenChatGptTabs({ force: true, inject: true }).catch(() => {});
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== ALARM_NAME) return;
  ensureFocusPoller();
  syncOpenChatGptTabs({ force: true, inject: false }).catch(() => {});
});

chrome.tabs.onCreated.addListener(() => {
  ensureFocusPoller();
  syncOpenChatGptTabs({ force: true, inject: false }).catch(() => {});
});

chrome.tabs.onRemoved.addListener((tabId) => {
  removeTrackedTab(tabId).catch(() => {});
});

chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  generatingByTab.delete(removedTabId);
  removeTrackedTab(removedTabId).catch(() => {});
  chrome.tabs.get(addedTabId)
    .then((tab) => {
      if (isChatGptUrl(tab.url)) {
        ensureFocusPoller();
        syncOpenChatGptTabs({ force: true, inject: true }).catch(() => {});
      }
    })
    .catch(() => {});
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.url && !isChatGptUrl(changeInfo.url)) {
    generatingByTab.delete(tabId);
    removeTrackedTab(tabId).catch(() => {});
    return;
  }

  if (changeInfo.url || changeInfo.title || changeInfo.status === 'complete') {
    ensureFocusPoller();
    syncOpenChatGptTabs({ force: true, inject: false }).catch(() => {});
  }
  if (isChatGptUrl(tab.url) && changeInfo.status === 'complete') {
    injectWatcher(tabId).catch(() => {});
  }
});

chrome.tabs.onActivated.addListener(() => {
  ensureFocusPoller();
  syncOpenChatGptTabs({ force: true, inject: false }).catch(() => {});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const tab = sender.tab;
  if (!tab || !Number.isInteger(tab.id) || !isChatGptUrl(tab.url)) return;

  if (message?.type === 'heartbeat') {
    generatingByTab.set(tab.id, Boolean(message.generating));
    ensureFocusPoller();
    syncOpenChatGptTabs({ force: false, inject: false }).catch(() => {});

    postJson(
      HEARTBEAT_URL,
      heartbeatPayload(tab, Boolean(message.generating))
    ).then(async (response) => {
      let selected = false;
      let focusRequestId = '';
      if (response?.ok) {
        try {
          const payload = await response.json();
          selected = payload.selected === true;
          focusRequestId = typeof payload.focusRequestId === 'string'
            ? payload.focusRequestId
            : '';
        } catch (_) {}
      }
      if (focusRequestId) {
        await applyFocusRequest(tab, focusRequestId);
      }
      sendResponse({ selected });
    });
    return true;
  }

  if (message?.type === 'completed') {
    postJson(COMPLETION_URL, {
      tabId: `chrome-${tab.id}`,
      windowId: Number.isInteger(tab.windowId) ? tab.windowId : null,
      title: tab.title || message.title || 'ChatGPT',
      url: tab.url,
      turnId: typeof message.turnId === 'string' ? message.turnId : '',
      detectedAtUtc: typeof message.detectedAtUtc === 'string' ? message.detectedAtUtc : '',
      detectionMode: typeof message.detectionMode === 'string' ? message.detectionMode : ''
    }).then((response) => sendResponse({ ok: Boolean(response?.ok) }));
    return true;
  }
});

ensureFallbackAlarm();
ensureFocusPoller();
syncOpenChatGptTabs({ force: true, inject: true }).catch(() => {});
