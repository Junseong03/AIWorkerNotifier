const BRIDGE_BASE = 'http://127.0.0.1:43127';
const SNAPSHOT_URL = `${BRIDGE_BASE}/api/tabs/snapshot`;
const REMOVE_URL = `${BRIDGE_BASE}/api/tabs/remove`;
const HEARTBEAT_URL = `${BRIDGE_BASE}/api/tabs/heartbeat`;
const COMPLETION_URL = `${BRIDGE_BASE}/api/tabs/completed`;
const SNAPSHOT_MIN_INTERVAL_MS = 2000;
const ALARM_NAME = 'ai-worker-notifier-chatgpt-tab-sync';

let syncInFlight = false;
let lastSnapshotAt = 0;

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
    // 브리지가 꺼져 있는 것은 정상적인 오프라인 상태다.
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
    title: tab.title || 'ChatGPT',
    url: tab.url
  };
}

async function injectWatcher(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ['content.js']
    });
  } catch (_) {
    // 로딩 중/폐기된 탭은 navigation 또는 다음 동기화에서 다시 붙는다.
  }
}

async function removeTrackedTab(tabId) {
  if (!Number.isInteger(tabId)) return;
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

    // Snapshot은 bridge에서 추가/갱신 전용이다. 누락된 탭을 삭제하지 않는다.
    // 삭제는 tabs.onRemoved / ChatGPT URL 이탈 이벤트로만 전달한다.
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

function ensureFallbackAlarm() {
  chrome.alarms.create(ALARM_NAME, { periodInMinutes: 1 });
}

chrome.runtime.onInstalled.addListener(() => {
  ensureFallbackAlarm();
  syncOpenChatGptTabs({ force: true, inject: true }).catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  ensureFallbackAlarm();
  syncOpenChatGptTabs({ force: true, inject: true }).catch(() => {});
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== ALARM_NAME) return;
  syncOpenChatGptTabs({ force: true, inject: false }).catch(() => {});
});

chrome.tabs.onCreated.addListener(() => {
  syncOpenChatGptTabs({ force: true, inject: false }).catch(() => {});
});

chrome.tabs.onRemoved.addListener((tabId) => {
  removeTrackedTab(tabId).catch(() => {});
});

chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  removeTrackedTab(removedTabId).catch(() => {});
  chrome.tabs.get(addedTabId)
    .then((tab) => {
      if (isChatGptUrl(tab.url)) {
        syncOpenChatGptTabs({ force: true, inject: true }).catch(() => {});
      }
    })
    .catch(() => {});
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.url && !isChatGptUrl(changeInfo.url)) {
    removeTrackedTab(tabId).catch(() => {});
    return;
  }

  if (changeInfo.url || changeInfo.title || changeInfo.status === 'complete') {
    syncOpenChatGptTabs({ force: true, inject: false }).catch(() => {});
  }
  if (isChatGptUrl(tab.url) && changeInfo.status === 'complete') {
    injectWatcher(tabId).catch(() => {});
  }
});

chrome.tabs.onActivated.addListener(() => {
  syncOpenChatGptTabs({ force: true, inject: false }).catch(() => {});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const tab = sender.tab;
  if (!tab || !Number.isInteger(tab.id) || !isChatGptUrl(tab.url)) return;

  if (message?.type === 'heartbeat') {
    // Heartbeat는 생성 상태 갱신용이다. 탭의 존재/삭제 판단에는 사용하지 않는다.
    syncOpenChatGptTabs({ force: false, inject: false }).catch(() => {});

    postJson(HEARTBEAT_URL, {
      tabId: `chrome-${tab.id}`,
      title: tab.title || message.title || 'ChatGPT',
      url: tab.url,
      generating: Boolean(message.generating)
    }).then(async (response) => {
      let selected = false;
      if (response?.ok) {
        try {
          selected = (await response.json()).selected === true;
        } catch (_) {}
      }
      sendResponse({ selected });
    });
    return true;
  }

  if (message?.type === 'completed') {
    postJson(COMPLETION_URL, {
      tabId: `chrome-${tab.id}`,
      title: tab.title || message.title || 'ChatGPT',
      url: tab.url
    }).then(() => sendResponse({ ok: true }));
    return true;
  }
});

ensureFallbackAlarm();
syncOpenChatGptTabs({ force: true, inject: true }).catch(() => {});
