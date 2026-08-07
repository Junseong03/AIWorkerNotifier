const BRIDGE_BASE = 'http://127.0.0.1:43127';
const HEARTBEAT_URL = `${BRIDGE_BASE}/api/tabs/heartbeat`;
const COMPLETION_URL = `${BRIDGE_BASE}/api/tabs/completed`;

async function postJson(url, payload) {
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'X-AIWorkerNotifier-Client': 'chatgpt-userscript'
      },
      body: JSON.stringify(payload),
      cache: 'no-store'
    });
    if (!response.ok && response.status !== 204) {
      console.warn('[AIWorkerNotifier] bridge returned', response.status, url);
    }
    return response;
  } catch (error) {
    console.warn('[AIWorkerNotifier] local bridge unavailable:', error);
    return null;
  }
}

function isChatGptUrl(url) {
  return typeof url === 'string' && (
    url.startsWith('https://chatgpt.com/') ||
    url.startsWith('https://chat.openai.com/')
  );
}

async function registerTab(tab, generating = false) {
  if (!tab || !Number.isInteger(tab.id) || !isChatGptUrl(tab.url)) return;
  await postJson(HEARTBEAT_URL, {
    tabId: `chrome-${tab.id}`,
    title: tab.title || 'ChatGPT',
    url: tab.url,
    generating: Boolean(generating)
  });
}

async function injectWatcher(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ['content.js']
    });
  } catch (_) {
    // Restricted, discarded, or not-yet-ready tabs are harmless; normal navigation injects later.
  }
}

async function scanExistingTabs() {
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (!isChatGptUrl(tab.url)) continue;
    await registerTab(tab, false);
    await injectWatcher(tab.id);
  }
}

chrome.runtime.onInstalled.addListener(() => {
  scanExistingTabs().catch(console.warn);
});

chrome.runtime.onStartup.addListener(() => {
  scanExistingTabs().catch(console.warn);
});

chrome.tabs.onCreated.addListener((tab) => {
  if (isChatGptUrl(tab.url)) registerTab(tab, false);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (!isChatGptUrl(tab.url)) return;
  if (changeInfo.url || changeInfo.title || changeInfo.status === 'complete') {
    registerTab(tab, false);
  }
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const tab = sender.tab;
  if (!tab || !Number.isInteger(tab.id) || !isChatGptUrl(tab.url)) return;

  if (message?.type === 'heartbeat') {
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

scanExistingTabs().catch(() => {});
