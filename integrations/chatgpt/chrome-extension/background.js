const BRIDGE_BASE = 'http://127.0.0.1:43127';
const SNAPSHOT_URL = `${BRIDGE_BASE}/api/tabs/snapshot`;
const REMOVE_URL = `${BRIDGE_BASE}/api/tabs/remove`;
const HEARTBEAT_URL = `${BRIDGE_BASE}/api/tabs/heartbeat`;
const COMPLETION_URL = `${BRIDGE_BASE}/api/tabs/completed`;
const FOCUS_ACK_URL = `${BRIDGE_BASE}/api/tabs/focus-ack`;
const SNAPSHOT_MIN_INTERVAL_MS = 2000;
const FOCUS_POLL_INTERVAL_MS = 2000;
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

function isChatGptUrl(url) {
  return typeof url === 'string' && (
    url.startsWith('https://chatgpt.com/') ||
    url.startsWith('https://chat.openai.com/')
  );
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
    await postJson(SNAPSHOT_URL, { tabs: snapshot });
    lastSnapshotAt = Date.now();

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

  const key = `${requestId}:${tab.id}`;
  if (focusRequestsInFlight.has(key)) return;
  focusRequestsInFlight.add(key);

  let success = false;
  let error = '';
  try {
    await chrome.tabs.update(tab.id, { active: true });
    if (Number.isInteger(tab.windowId)) {
      await chrome.windows.update(tab.windowId, { focused: true });
    }
    success = true;
  } catch (reason) {
    error = String(reason?.message || reason || 'Chrome tab focus failed');
  }

  try {
    await postJson(FOCUS_ACK_URL, {
      requestId,
      tabId: `chrome-${tab.id}`,
      success,
      error
    });
  } finally {
    focusRequestsInFlight.delete(key);
  }
}

async function pollFocusRequests() {
  if (focusPollInFlight) return;
  focusPollInFlight = true;

  try {
    const allTabs = await chrome.tabs.query({});
    const chatGptTabs = allTabs.filter((tab) =>
      Number.isInteger(tab.id) && isChatGptUrl(tab.url)
    );

    for (const tab of chatGptTabs) {
      const response = await postJson(
        HEARTBEAT_URL,
        heartbeatPayload(tab, generatingByTab.get(tab.id) === true)
      );
      const focusRequestId = await readFocusRequestId(response);
      if (focusRequestId) {
        await applyFocusRequest(tab, focusRequestId);
      }
    }
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
