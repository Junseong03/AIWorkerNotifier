const BRIDGE_BASE = 'http://127.0.0.1:43127';
const SNAPSHOT_URL = `${BRIDGE_BASE}/api/tabs/snapshot`;
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
  } catch (error) {
    // 브리지가 꺼져 있을 때는 정상적인 오프라인 상태이므로 치명 오류로 취급하지 않는다.
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
    // 아직 로딩 중이거나 폐기된 탭은 navigation/content_script 경로에서 다시 붙는다.
  }
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

chrome.tabs.onRemoved.addListener(() => {
  syncOpenChatGptTabs({ force: true, inject: false }).catch(() => {});
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
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
    // 어느 한 ChatGPT 탭의 heartbeat만 살아 있어도 Chrome 자체 탭 목록을 다시 동기화한다.
    // 따라서 다른 탭의 content script가 잠시 재시작되어도 열린 탭 자체는 목록에서 사라지지 않는다.
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
